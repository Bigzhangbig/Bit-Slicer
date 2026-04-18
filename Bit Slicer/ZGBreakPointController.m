/*
 * Copyright (c) 2012 Mayur Pawashe
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// For information about x86 debug registers, see:
// http://en.wikipedia.org/wiki/X86_debug_register

// General summary of watchpoints:
// We set up an exception handler for catching breakpoint's and run a server that listens for exceptions coming in
// We add a hardware watchpoint when the user requests it.
// Determine number of bytes we want to watch: 1, 2, 4, 8 (note: 32-bit processes cannot use byte-size of 8)
// Iterate through each thread's registers, and:
//		Checking for availability and enabling our breakpoint in dr7 (we always add a local breakpoint to every thread of a process).
//		Modifying bits in dr7 indicating our watchpoint byte length (again: 1, 2, 4, or 8)
//		Modifying dr0 - dr3 with our memory address of interest
// Any time we obtain or set thread information, we suspend the task before doing so and resume it when we're done (I suppose we could just only suspend the thread instead)
// We catch a breakpoint exception, make sure it matches with one of our breakpoints, restore what we've written to registers in all threads, and clear the dr6 status register
// Also grab the EIP (for 32-bit processes) or RIP (for 64-bit processes) program counters, this is the address of the instruction *after* the one we're interested in

// For instruction breakpoints, we modify the instruction's first byte to 0xCC, fake the disassembler values to the user.
// When a breakpoint hits, we suspend the task, and let the user decide to continue when he wants
// At continuation, we restore the breakpoint's first byte, turn on single-stepping by modifying flags register, and at the next step we restore our breakpoint and continue like usual
// Note: There are some trick cases if the user decides to jump to an address or manually single-step or step-over

#import "ZGBreakPointController.h"
#import "ZGVirtualMemory.h"
#import "ZGThreadStates.h"
#import "ZGVariable.h"
#import "ZGProcess.h"
#import "ZGDebugThread.h"
#import "ZGBreakPoint.h"
#import "ZGRegistersState.h"
#import "ZGInstruction.h"
#import "ZGDebuggerUtilities.h"
#import "ZGProcessList.h"
#import "ZGRunningProcess.h"
#import "ZGScriptingInterpreter.h"
#import "ZGScriptManager.h"
#import "ZGDebugLogging.h"
#import "NSArrayAdditions.h"
#import "ZGRegisterEntries.h"
#import "ZGMachBinary.h"
#import "ZGCodeInjectionHandler.h"
#import "ZGAppTerminationState.h"

#import <mach/task.h>
#import <mach/thread_act.h>
#import <mach/mach_port.h>
#import <mach/mach.h>

extern boolean_t mach_exc_server(mach_msg_header_t *InHeadP, mach_msg_header_t *OutHeadP);

@implementation ZGBreakPointController
{
	NSArray<ZGBreakPoint *> *_breakPoints;
	mach_port_t _exceptionPort;
	ZGScriptingInterpreter * _Nonnull _scriptingInterpreter;
	dispatch_source_t _Nullable _watchPointTimer;
	dispatch_source_t _Nullable _hardwareBreakpointTimer;
	NSMutableDictionary<NSNumber *, NSMutableArray<ZGCodeInjectionHandler *> *> *_codeInjectionMappings;
	BOOL _delayedTermination;
}

static ZGBreakPointController *gBreakPointController;
+ (instancetype)createBreakPointControllerOnceWithScriptingInterpreter:(ZGScriptingInterpreter *)scriptingInterpreter
{
	assert(gBreakPointController == nil);
	
	gBreakPointController = [(ZGBreakPointController *)[self alloc] initWithScriptingInterpreter:scriptingInterpreter];
	return gBreakPointController;
}

- (id)initWithScriptingInterpreter:(ZGScriptingInterpreter *)scriptingInterpreter
{
	self = [super init];
	if (self != nil)
	{
		_breakPoints = @[];
		_scriptingInterpreter = scriptingInterpreter;
	}
	return self;
}

#define DISABLE_WATCHPOINT(debugState, debugRegisterIndex) debugState.__wcr[debugRegisterIndex] &= ~((uint32_t)1u)
#define ENABLE_WATCHPOINT(debugState, debugRegisterIndex) debugState.__wcr[debugRegisterIndex] |= ((uint32_t)1u)

- (void)removeWatchPoint:(ZGBreakPoint *)breakPoint
{
	thread_act_array_t threadList = NULL;
	mach_msg_type_number_t threadListCount = 0;
	if (task_threads(breakPoint.process.processTask, &threadList, &threadListCount) != KERN_SUCCESS)
	{
		ZG_LOG(@"ERROR: task_threads failed on removing watchpoint");
		return;
	}
	
	for (ZGDebugThread *debugThread in breakPoint.debugThreads)
	{
		BOOL foundDebugThread = NO;
		for (mach_msg_type_number_t threadIndex = 0; threadIndex < threadListCount; threadIndex++)
		{
			if (threadList[threadIndex] == debugThread.thread)
			{
				foundDebugThread = YES;
				break;
			}
		}
		
		if (!foundDebugThread)
		{
			continue;
		}
		
		zg_debug_state_t debugState;
		mach_msg_type_number_t stateCount;
		if (!ZGGetDebugThreadState(&debugState, debugThread.thread, &stateCount))
		{
			ZG_LOG(@"ERROR: Grabbing debug state failed in %s: continuing...", __PRETTY_FUNCTION__);
			continue;
		}
	
		uint8_t debugRegisterIndex = debugThread.registerIndex;
		DISABLE_WATCHPOINT(debugState, debugRegisterIndex);
		
		if (!ZGSetDebugThreadState(&debugState, debugThread.thread, stateCount))
		{
			ZG_LOG(@"ERROR: Failure in setting thread state registers in %s", __PRETTY_FUNCTION__);
		}
	}
	
	if (!ZGDeallocateMemory(current_task(), (mach_vm_address_t)threadList, threadListCount * sizeof(thread_act_t)))
	{
		ZG_LOG(@"Failed to deallocate thread list in %s", __PRETTY_FUNCTION__);
	}
	
	// we may still catch exceptions momentarily for our breakpoint if the data is being acccessed frequently, so do not remove it immediately
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
		if (self->_watchPointTimer != NULL)
		{
			BOOL shouldKeepTimer = [[self breakPoints] zgHasObjectMatchingCondition:^(ZGBreakPoint *watchPoint){ return (BOOL)(watchPoint.type != ZGBreakPointWatchData && watchPoint != breakPoint); }];
			if (!shouldKeepTimer)
			{
				dispatch_source_cancel((dispatch_source_t _Nonnull)self->_watchPointTimer);
				self->_watchPointTimer = NULL;
			}
		}
		[self removeBreakPoint:breakPoint];
	});
}

#define IS_WATCHPOINT_REGISTER_AVAILABLE(debugState, registerIndex) ((debugState.__wcr[registerIndex] & 1u) == 0)
#define IS_BREAKPOINT_REGISTER_AVAILABLE(debugState, registerIndex) ((debugState.__bcr[registerIndex] & 1u) == 0)
#define DISABLE_SINGLE_STEP(debugState) debugState.__mdscr_el1 &= ~((uint32_t)0x1)
#define ENABLE_SINGLE_STEP(debugState) debugState.__mdscr_el1 |= (uint32_t)0x1

- (BOOL)handleWatchPointsWithTask:(mach_port_t)task inThread:(mach_port_t)thread
{
	BOOL handledWatchPoint = NO;
	for (ZGBreakPoint *breakPoint in [self breakPoints])
	{
		if (breakPoint.type != ZGBreakPointWatchData)
		{
			continue;
		}
		
		if (breakPoint.task != task)
		{
			continue;
		}
		
		ZGSuspendTask(task);
		
		for (ZGDebugThread *debugThread in breakPoint.debugThreads)
		{
			if (debugThread.thread != thread)
			{
				continue;
			}

			// Normally I'd set this to YES after isWatchPointAvailable is YES below, however, it is possible this will miss a watchpoint just being removed.
			// To be safe, we will just pretend we handled the watchpoint so that we don't crash the target process
			handledWatchPoint = YES;

			zg_debug_state_t debugState;
			mach_msg_type_number_t debugStateCount;
			if (!ZGGetDebugThreadState(&debugState, thread, &debugStateCount))
			{
				continue;
			}
			
			uint8_t debugRegisterIndex = debugThread.registerIndex;
			BOOL isWatchPointAvailable = ZG_PROCESS_TYPE_IS_ARM64(breakPoint.process.type) && !IS_WATCHPOINT_REGISTER_AVAILABLE(debugState, debugRegisterIndex);
			
			if (!isWatchPointAvailable)
			{
				if (breakPoint.needsToRestore)
				{
					ENABLE_WATCHPOINT(debugState, debugRegisterIndex);
					
					// Disable single-stepping
					DISABLE_SINGLE_STEP(debugState);
					
					if (!ZGSetDebugThreadState(&debugState, debugThread.thread, debugStateCount))
					{
						ZG_LOG(@"ERROR: Failure in setting debug thread registers for restoring watchpoint in handle watchpoint...Not good.");
					}
				}
				
				continue;
			}
			
			// We will need to disable the watchpoint, enable single stepping, and re-enable the watchpoint
			// When a watchpoint is hit on arm64 the instruction that does the access isn't actually yet executed
			DISABLE_WATCHPOINT(debugState, debugRegisterIndex);
			
			// Enable single-stepping
			ENABLE_SINGLE_STEP(debugState);
			
			breakPoint.needsToRestore = YES;
			
			if (!ZGSetDebugThreadState(&debugState, debugThread.thread, debugStateCount))
			{
				ZG_LOG(@"ERROR: Failure in setting debug thread registers for clearing dr6 in handle watchpoint...Not good.");
			}
			
			zg_thread_state_t threadState;
			mach_msg_type_number_t threadStateCount;
			if (!ZGGetGeneralThreadState(&threadState, thread, &threadStateCount))
			{
				continue;
			}
			
			ZGMemoryAddress hitInstructionAddress = ZGInstructionPointerFromGeneralThreadState(&threadState, breakPoint.process.type);
			ZGMemoryAddress relocatedInstructionAddress = hitInstructionAddress + 0x1;
			
			zg_vector_state_t vectorState;
			bool hasAVXSupport = NO;
			BOOL retrievedVectorState = ZGGetVectorThreadState(&vectorState, thread, NULL, breakPoint.process.type, &hasAVXSupport);
			
			ZGRegistersState *registersState = [[ZGRegistersState alloc] initWithGeneralPurposeThreadState:threadState vectorState:vectorState hasVectorState:retrievedVectorState hasAVXSupport:hasAVXSupport processType:breakPoint.process.type];
			
			dispatch_async(dispatch_get_main_queue(), ^{
				@synchronized(self)
				{
					id <ZGBreakPointDelegate> delegate = breakPoint.delegate;
					[delegate dataAccessedByBreakPoint:breakPoint fromInstructionPointer:relocatedInstructionAddress withRegistersState:registersState];
				}
			});
		}
		
		ZGResumeTask(task);
	}
	
	return handledWatchPoint;
}

- (NSArray<ZGBreakPoint *> *)removeSingleStepBreakPointsFromBreakPoint:(ZGBreakPoint *)breakPoint
{
	NSMutableArray<ZGBreakPoint *> *removedBreakPoints = [NSMutableArray array];
	
	for (ZGBreakPoint *candidateBreakPoint in [self breakPoints])
	{
		if (candidateBreakPoint.type == ZGBreakPointSingleStepInstruction && candidateBreakPoint.task == breakPoint.task && candidateBreakPoint.thread == breakPoint.thread)
		{
			[removedBreakPoints addObject:candidateBreakPoint];
			[self removeBreakPoint:candidateBreakPoint];
		}
	}
	
	return removedBreakPoints;
}

#define DISABLE_HARDWARE_BREAKPOINT(debugState, debugRegisterIndex) debugState.__bcr[debugRegisterIndex] &= ~((uint32_t)1u)
#define ENABLE_HARDWARE_BREAKPOINT(debugState, debugRegisterIndex) debugState.__bcr[debugRegisterIndex] |= ((uint32_t)1u)

- (void)resumeFromBreakPoint:(ZGBreakPoint *)breakPoint
{
	zg_thread_state_t threadState;
	mach_msg_type_number_t threadStateCount;
	if (!ZGGetGeneralThreadState(&threadState, breakPoint.thread, &threadStateCount))
	{
		ZG_LOG(@"ERROR: Grabbing thread state failed in %s", __PRETTY_FUNCTION__);
	}
	
	ZGMemoryAddress instructionPointer = ZGInstructionPointerFromGeneralThreadState(&threadState, breakPoint.process.type);
	
	BOOL needsToWriteDebugState = NO;
	zg_debug_state_t debugState = {0};
	mach_msg_type_number_t debugStateCount = 0;
	
	BOOL shouldSingleStep = NO;
	
	// Check if breakpoint still exists at the current instruction pointer
	// Take account if the user moved the instruction pointer or if an arm64 HW breakpoint advanced past the breakpoint
	if (breakPoint.type == ZGBreakPointInstruction && [[self breakPoints] containsObject:breakPoint] && breakPoint.variable.address == instructionPointer)
	{
		if (!breakPoint.usesHardware)
		{
			// Restore our instruction
			ZGWriteBytesOverwritingProtection(breakPoint.process.processTask, breakPoint.variable.address, breakPoint.variable.rawValue, sizeof(gBreakpointOpcode));
		}
		else
		{
			for (ZGDebugThread *debugThread in breakPoint.debugThreads)
			{
				if (debugThread.thread != breakPoint.thread)
				{
					continue;
				}
				
				if (!needsToWriteDebugState)
				{
					if (!ZGGetDebugThreadState(&debugState, breakPoint.thread, &debugStateCount))
					{
						ZG_LOG(@"ERROR: Grabbing debug state failed in %s", __PRETTY_FUNCTION__);
					}
					needsToWriteDebugState = YES;
				}
				
				uint8_t debugRegisterIndex = debugThread.registerIndex;
				DISABLE_HARDWARE_BREAKPOINT(debugState, debugRegisterIndex);
			}
		}
		
		breakPoint.needsToRestore = YES;
		
		if (!breakPoint.dead)
		{
			// Ensure single-stepping, so on next instruction we can restore our breakpoint
			shouldSingleStep = YES;
		}
		else
		{
			[self removeBreakPoint:breakPoint];
		}
	}
	else
	{
		shouldSingleStep = [[self breakPoints] zgHasObjectMatchingCondition:^(ZGBreakPoint *candidateBreakPoint) {
			return (BOOL)(candidateBreakPoint.type == ZGBreakPointSingleStepInstruction && candidateBreakPoint.thread == breakPoint.thread && candidateBreakPoint.task == breakPoint.task);
		}];
	}
	
	if (shouldSingleStep)
	{
		if (!needsToWriteDebugState)
		{
			if (!ZGGetDebugThreadState(&debugState, breakPoint.thread, &debugStateCount))
			{
				ZG_LOG(@"ERROR: Grabbing debug state failed in %s", __PRETTY_FUNCTION__);
			}
			needsToWriteDebugState = YES;
		}
		
		ENABLE_SINGLE_STEP(debugState);
	}
	
	if (!ZGSetGeneralThreadState(&threadState, breakPoint.thread, threadStateCount))
	{
		ZG_LOG(@"Failure in setting registers thread state for thread %u, %s", breakPoint.thread, __PRETTY_FUNCTION__);
	}
	
	if (needsToWriteDebugState && !ZGSetDebugThreadState(&debugState, breakPoint.thread, debugStateCount))
	{
		ZG_LOG(@"Failure in setting registers debug state for thread %u, %s", breakPoint.thread, __PRETTY_FUNCTION__);
	}
	
	ZGResumeTask(breakPoint.process.processTask);
}

- (void)revertInstructionBackToNormal:(ZGBreakPoint *)breakPoint
{
	if (!breakPoint.usesHardware)
	{
		ZGWriteBytesOverwritingProtection(breakPoint.process.processTask, breakPoint.variable.address, breakPoint.variable.rawValue, sizeof(gBreakpointOpcode));
	}
	else
	{
		for (ZGDebugThread *debugThread in breakPoint.debugThreads)
		{
			zg_debug_state_t debugState;
			mach_msg_type_number_t debugStateCount;
			if (!ZGGetDebugThreadState(&debugState, debugThread.thread, &debugStateCount))
			{
				ZG_LOG(@"ERROR: Grabbing debug state failed in handling instruction.. %s", __PRETTY_FUNCTION__);
				continue;
			}
			
			uint8_t debugRegisterIndex = debugThread.registerIndex;
			DISABLE_HARDWARE_BREAKPOINT(debugState, debugRegisterIndex);
			
			if (!ZGSetDebugThreadState(&debugState, debugThread.thread, debugStateCount))
			{
				ZG_LOG(@"Failure in setting registers debug state for removing hardware breakpoint for thread %u, %s", debugThread.thread, __PRETTY_FUNCTION__);
			}
		}
	}
}

- (void)removeInstructionBreakPoint:(ZGBreakPoint *)breakPoint
{
	if (breakPoint.condition != NULL)
	{
		// Mark breakpoint as dead. if the breakpoint is called frequently (esp. with a falsely evaluated condition), it will be removed when resuming from a breakpoint
		// We handle a breakpoint by reverting the instruction back to normal, single stepping, then reverting the instruction opcode back to being breaked
		// If we just removed the breakpoint immediately here, and the process single steps, the handler won't know why the exception was raised
		// Our work around here is giving the process a little delay (perhaps a better way might be to add a single-stepping breakpoint and remove it from there)
		breakPoint.dead = YES;
		
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^(void) {
			if ([[self breakPoints] containsObject:breakPoint])
			{
				ZGSuspendTask(breakPoint.process.processTask);
				
				[self revertInstructionBackToNormal:breakPoint];
				[self removeBreakPoint:breakPoint];
				
				ZGResumeTask(breakPoint.process.processTask);
			}
			
			id <ZGBreakPointDelegate> delegate = breakPoint.delegate;
			if ([delegate respondsToSelector:@selector(conditionalInstructionBreakPointWasRemoved)])
			{
				[delegate conditionalInstructionBreakPointWasRemoved];
			}
			
			if (self->_delayedTermination && [self breakPoints].count == 0)
			{
				[self->_appTerminationState decreaseLifeCount];
			}
		});
	}
	else
	{
		ZGSuspendTask(breakPoint.process.processTask);
		
		[self revertInstructionBackToNormal:breakPoint];
		[self removeBreakPoint:breakPoint];
		
		ZGResumeTask(breakPoint.process.processTask);
	}
}

- (ZGBreakPoint *)removeBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process
{
	ZGBreakPoint *targetBreakPoint = nil;
	for (ZGBreakPoint *breakPoint in [self breakPoints])
	{
		if (breakPoint.type == ZGBreakPointInstruction && breakPoint.process.processTask == process.processTask	&& breakPoint.variable.address == instruction.variable.address)
		{
			targetBreakPoint = breakPoint;
			break;
		}
	}
	
	if (targetBreakPoint != nil)
	{
		[self removeInstructionBreakPoint:targetBreakPoint];
	}
	
	return targetBreakPoint;
}

- (BOOL)handleInstructionBreakPointsWithTask:(mach_port_t)task inThread:(mach_port_t)thread
{
	BOOL handledInstructionBreakPoint = NO;
	NSArray<ZGBreakPoint *> *breakPoints = [self breakPoints];
	
	ZGSuspendTask(task);
	
	zg_thread_state_t threadState;
	mach_msg_type_number_t threadStateCount;
	if (!ZGGetGeneralThreadState(&threadState, thread, &threadStateCount))
	{
		ZG_LOG(@"ERROR: Grabbing thread state failed in obtaining instruction address, skipping. %s", __PRETTY_FUNCTION__);
	}
	
	BOOL needsToWriteDebugState = NO;
	zg_debug_state_t debugState = {0};
	mach_msg_type_number_t debugStateCount = 0;
	
	BOOL hitBreakPoint = NO;
	NSMutableArray<ZGBreakPoint *> *breakPointsToNotify = [[NSMutableArray alloc] init];
	
	for (ZGBreakPoint *breakPoint in breakPoints)
	{
		if (breakPoint.type != ZGBreakPointInstruction)
		{
			continue;
		}
		
		if (breakPoint.task != task)
		{
			continue;
		}
		
		BOOL foundSingleStepBreakPoint = [[self breakPoints] zgHasObjectMatchingCondition:^(ZGBreakPoint *candidateBreakPoint) {
			return (BOOL)((candidateBreakPoint.needsToRestore || candidateBreakPoint.type == ZGBreakPointSingleStepInstruction) && candidateBreakPoint.task == task && candidateBreakPoint.thread == thread);
		}];
		
		// If we encounter an emulated breakpoint and a single step breakpoint, prioritize handling the latter
		if (breakPoint.emulated && foundSingleStepBreakPoint)
		{
			continue;
		}
		
		breakPoint.thread = thread;
		
		// Remove single-stepping
		if (!needsToWriteDebugState)
		{
			if (!ZGGetDebugThreadState(&debugState, thread, &debugStateCount))
			{
				ZG_LOG(@"ERROR: Grabbing debug state failed in handling instruction for removing single step from breakpoint.. %s", __PRETTY_FUNCTION__);
			}
			
			needsToWriteDebugState = YES;
		}
		
		DISABLE_SINGLE_STEP(debugState);
		
		ZGMemoryAddress foundInstructionAddress = 0x0;
		ZGMemoryAddress instructionPointer = ZGInstructionPointerFromGeneralThreadState(&threadState, breakPoint.process.type);
		
		foundInstructionAddress = instructionPointer;
		
		if (foundInstructionAddress == breakPoint.variable.address)
		{
			if (breakPoint.usesHardware)
			{
				hitBreakPoint = YES;
				ZGSuspendTask(task);
				
				[breakPointsToNotify addObject:breakPoint];
			}
			else
			{
				void *opcode = NULL;
				ZGMemorySize opcodeSize = sizeof(gBreakpointOpcode);
				
				if (ZGReadBytes(breakPoint.process.processTask, foundInstructionAddress, &opcode, &opcodeSize))
				{
					if (memcmp(opcode, gBreakpointOpcode, opcodeSize) == 0)
					{
						hitBreakPoint = YES;
						ZGSuspendTask(task);
						
						[breakPointsToNotify addObject:breakPoint];
					}
					
					ZGFreeBytes(opcode, opcodeSize);
				}
			}
			
			handledInstructionBreakPoint = YES;
		}
		
		if (breakPoint.needsToRestore)
		{
			// Restore our breakpoint
			if (!breakPoint.usesHardware)
			{
				ZGWriteBytesOverwritingProtection(breakPoint.process.processTask, breakPoint.variable.address, gBreakpointOpcode, sizeof(gBreakpointOpcode));
			}
			else
			{
				for (ZGDebugThread *debugThread in breakPoint.debugThreads)
				{
					if (debugThread.thread != thread)
					{
						continue;
					}
					
					if (!needsToWriteDebugState)
					{
						if (!ZGGetDebugThreadState(&debugState, thread, &debugStateCount))
						{
							ZG_LOG(@"ERROR: Grabbing debug state failed in handling instruction for enabling hardware breakpoint.. %s", __PRETTY_FUNCTION__);
						}
						
						needsToWriteDebugState = YES;
					}
					
					ENABLE_HARDWARE_BREAKPOINT(debugState, debugThread.registerIndex);
				}
			}
			
			breakPoint.needsToRestore = NO;
			handledInstructionBreakPoint = YES;
		}
	}
	
	for (ZGBreakPoint *candidateBreakPoint in breakPoints)
	{
		if (candidateBreakPoint.type != ZGBreakPointSingleStepInstruction)
		{
			continue;
		}
		
		if (candidateBreakPoint.task != task || candidateBreakPoint.thread != thread)
		{
			continue;
		}
		
		// Remove single-stepping
		if (!needsToWriteDebugState)
		{
			if (!ZGGetDebugThreadState(&debugState, thread, &debugStateCount))
			{
				ZG_LOG(@"ERROR: Grabbing debug state failed in handling instruction for disabling single step in candidate breakpoint.. %s", __PRETTY_FUNCTION__);
			}
			
			needsToWriteDebugState = YES;
		}
		
		DISABLE_SINGLE_STEP(debugState);
		
		if (!hitBreakPoint)
		{
			ZGSuspendTask(task);
			
			candidateBreakPoint.variable = [[ZGVariable alloc] initWithValue:NULL size:1 address:ZGInstructionPointerFromGeneralThreadState(&threadState, candidateBreakPoint.process.type) type:ZGByteArray qualifier:0 pointerSize:candidateBreakPoint.process.pointerSize];
			
			[breakPointsToNotify addObject:candidateBreakPoint];
			
			hitBreakPoint = YES;
		}
		
		[self removeBreakPoint:candidateBreakPoint];
		
		handledInstructionBreakPoint = YES;
	}
	
	// Handle an edge case for HW breakpoints on arm64 where the break'd instruction could already be executed
	// This can be determined from the esr register by comparing the btype to see instruction pointer will be post-execution
	// In this case we will suspend the task but not alter the instruction pointer.
	if (!hitBreakPoint)
	{
		zg_exception_state_t exceptionState;
		mach_msg_type_number_t exceptionStateCount;
		BOOL fetchedExceptionState = NO;
		
		for (ZGBreakPoint *breakPoint in breakPoints)
		{
			if (breakPoint.type != ZGBreakPointInstruction)
			{
				continue;
			}
			
			if (breakPoint.task != task)
			{
				continue;
			}
			
			if (!breakPoint.usesHardware)
			{
				continue;
			}
			
			if (!fetchedExceptionState)
			{
				if (!ZGGetExceptionThreadState(&exceptionState, thread, &exceptionStateCount))
				{
					ZG_LOG(@"ERROR: Grabbing exception state failed, skipping. %s", __PRETTY_FUNCTION__);
				}
				
				fetchedExceptionState = YES;
				
				uint32_t esr = exceptionState.__esr;
				uint32_t ec = (esr >> 26) & 0x3F;
				uint32_t btype = (esr >> 24) & 0x3;
				
				if (ec != 0x32 || btype != 0b10)
				{
					break;
				}
			}
			
			ZGMemoryAddress instructionPointer = ZGInstructionPointerFromGeneralThreadState(&threadState, breakPoint.process.type);
			
			const ZGMemorySize armInstructionSize = 0x4;
			if (breakPoint.variable.address < armInstructionSize || instructionPointer != breakPoint.variable.address + armInstructionSize)
			{
				continue;
			}
			
			breakPoint.thread = thread;
			
			hitBreakPoint = YES;
			ZGSuspendTask(task);
			
			[breakPointsToNotify addObject:breakPoint];
			
			handledInstructionBreakPoint = YES;
		}
	}
	
	if (handledInstructionBreakPoint)
	{
		if (!ZGSetGeneralThreadState(&threadState, thread, threadStateCount))
		{
			ZG_LOG(@"Failure in setting registers thread state for catching instruction breakpoint for thread %u, %s", thread, __PRETTY_FUNCTION__);
		}
		
		if (needsToWriteDebugState && !ZGSetDebugThreadState(&debugState, thread, debugStateCount))
		{
			ZG_LOG(@"Failure in setting registers debug state for catching instruction breakpoint for thread %u, %s", thread, __PRETTY_FUNCTION__);
		}
	}
	
	ZGRegisterEntry registerEntries[ZG_MAX_REGISTER_ENTRIES];
	BOOL retrievedRegisterEntries = NO;
	BOOL retrievedVectorState = NO;
	bool hasAVXSupport = NO;
	zg_vector_state_t vectorState = {};
	
	// We should notify delegates if a breakpoint hits after we modify thread states
	for (ZGBreakPoint *breakPoint in breakPointsToNotify)
	{
		BOOL canNotifyDelegate = !breakPoint.dead;
		
		if (canNotifyDelegate && !retrievedRegisterEntries)
		{
			ZGProcessType processType = breakPoint.process.type;
			
			int numberOfGeneralPurposeEntries = [ZGRegisterEntries getRegisterEntries:registerEntries fromGeneralPurposeThreadState:threadState processType:processType];
			
			retrievedVectorState = ZGGetVectorThreadState(&vectorState, thread, NULL, processType, &hasAVXSupport);
			if (retrievedVectorState)
			{
				[ZGRegisterEntries getRegisterEntries:registerEntries + numberOfGeneralPurposeEntries fromVectorThreadState:vectorState processType:processType hasAVXSupport:hasAVXSupport];
			}
			
			retrievedRegisterEntries = YES;
		}
		
		if (canNotifyDelegate && breakPoint.condition != NULL)
		{
			NSError *error = nil;
			if (![_scriptingInterpreter evaluateCondition:(PyObject * _Nonnull)breakPoint.condition process:breakPoint.process registerEntries:registerEntries error:&error])
			{
				if (error == nil)
				{
					canNotifyDelegate = NO;
				}
				else
				{
					breakPoint.error = error;
				}
			}
		}
		
		if (canNotifyDelegate)
		{
			ZGProcessType processType = breakPoint.process.type;
			
			dispatch_async(dispatch_get_main_queue(), ^{
				@synchronized(self)
				{
					id <ZGBreakPointDelegate> delegate = breakPoint.delegate;
					if (delegate != nil)
					{
						ZGRegistersState *registersState = [[ZGRegistersState alloc] initWithGeneralPurposeThreadState:threadState vectorState:vectorState hasVectorState:retrievedVectorState hasAVXSupport:hasAVXSupport processType:processType];
						
						breakPoint.registersState = registersState;
						
						[delegate breakPointDidHit:breakPoint];
					}
					else
					{
						[self resumeFromBreakPoint:breakPoint];
					}
				}
			});
		}
		else
		{
			[self resumeFromBreakPoint:breakPoint];
		}
	}
	
	ZGResumeTask(task);
	
	return handledInstructionBreakPoint;
}

kern_return_t  catch_mach_exception_raise_state(mach_port_t __unused exception_port, exception_type_t __unused exception, exception_data_t __unused code, mach_msg_type_number_t __unused code_count, int * __unused flavor, thread_state_t __unused in_state, mach_msg_type_number_t __unused in_state_count, thread_state_t __unused out_state, mach_msg_type_number_t * __unused out_state_count)
{
	return KERN_FAILURE;
}

kern_return_t  catch_mach_exception_raise_state_identity(mach_port_t __unused exception_port, mach_port_t __unused thread, mach_port_t __unused task, exception_type_t __unused exception, exception_data_t __unused code, mach_msg_type_number_t __unused code_count, int * __unused flavor, thread_state_t __unused in_state, mach_msg_type_number_t __unused in_state_count, thread_state_t __unused out_state, mach_msg_type_number_t * __unused out_state_count)
{
	return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise(mach_port_t __unused exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, exception_data_t __unused code, mach_msg_type_number_t __unused code_count)
{
	BOOL handledWatchPoint = NO;
	BOOL handledInstructionBreakPoint = NO;
	
	if (exception == EXC_BREAKPOINT)
	{
		@autoreleasepool
		{
			handledWatchPoint = [gBreakPointController handleWatchPointsWithTask:task inThread:thread];
			handledInstructionBreakPoint = [gBreakPointController handleInstructionBreakPointsWithTask:task inThread:thread];
		}
	}
	
	return (handledWatchPoint || handledInstructionBreakPoint) ? KERN_SUCCESS : KERN_FAILURE;
}

- (NSArray<ZGBreakPoint *> *)removeObserver:(id)observer
{
	return [self removeObserver:observer runningProcess:nil withProcessID:-1 atAddress:0];
}

- (NSArray<ZGBreakPoint *> *)removeObserver:(id)observer withProcessID:(pid_t)processID atAddress:(ZGMemoryAddress)address
{
	return [self removeObserver:observer runningProcess:nil withProcessID:processID atAddress:address];
}

- (NSArray<ZGBreakPoint *> *)removeObserver:(id)observer runningProcess:(ZGRunningProcess *)process
{
	return [self removeObserver:observer runningProcess:process withProcessID:-1 atAddress:0];
}

- (NSArray<ZGBreakPoint *> *)removeObserver:(id)observer runningProcess:(ZGRunningProcess *)process withProcessID:(pid_t)processID atAddress:(ZGMemoryAddress)address
{
	NSMutableArray<ZGBreakPoint *> *removedBreakPoints = [NSMutableArray array];
	@synchronized(self)
	{
		NSArray<ZGRunningProcess *> *runningProcesses = [[[ZGProcessList alloc] init] runningProcesses];
		for (ZGBreakPoint *breakPoint in [self breakPoints])
		{
			if (processID <= 0 || (processID == breakPoint.process.processID && breakPoint.variable.address == address))
			{
				// Also check for code injection handlers which we will automatically remove when removing another observer
				id<ZGBreakPointDelegate> breakPointDelegate = breakPoint.delegate;
				if ((breakPointDelegate == observer || ([breakPointDelegate isKindOfClass:[ZGCodeInjectionHandler class]] && [(ZGCodeInjectionHandler *)breakPointDelegate owner] == observer)) && (!process || breakPoint.process.processID == process.processIdentifier))
				{
					BOOL isDead = ![runningProcesses zgHasObjectMatchingCondition:^(ZGRunningProcess *runningProcess) {
						return (BOOL)(runningProcess.processIdentifier == breakPoint.process.processID);
					}];
					
					breakPoint.delegate = nil;
					
					if (isDead || breakPoint.type == ZGBreakPointSingleStepInstruction)
					{
						[removedBreakPoints addObject:breakPoint];
						[self removeBreakPoint:breakPoint];
					}
					else if (breakPoint.type == ZGBreakPointWatchData)
					{
						[removedBreakPoints addObject:breakPoint];
						
						ZGSuspendTask(breakPoint.task);
						[self removeWatchPoint:breakPoint];
						ZGResumeTask(breakPoint.task);
					}
					else if (breakPoint.type == ZGBreakPointInstruction)
					{
						if (_appTerminationState != nil && !_delayedTermination && breakPoint.condition != NULL)
						{
							_delayedTermination = YES;
							[_appTerminationState increaseLifeCount];
						}
						
						[removedBreakPoints addObject:breakPoint];
						
						[self removeInstructionBreakPoint:breakPoint];
					}
				}
			}
		}
	}
	
	return removedBreakPoints;
}

- (BOOL)setUpExceptionPortForProcess:(ZGProcess *)process
{
	if (_exceptionPort == MACH_PORT_NULL)
	{
		if (mach_port_allocate(current_task(), MACH_PORT_RIGHT_RECEIVE, &_exceptionPort) != KERN_SUCCESS)
		{
			NSLog(@"ERROR: Could not allocate mach port for adding breakpoint");
			_exceptionPort = MACH_PORT_NULL;
			return NO;
		}
		
		if (mach_port_insert_right(current_task(), _exceptionPort, _exceptionPort, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS)
		{
			NSLog(@"ERROR: Could not insert send right for watchpoint");
			if (!ZGDeallocatePort(_exceptionPort))
			{
				NSLog(@"ERROR: Could not deallocate exception port in adding breakpoint");
			}
			_exceptionPort = MACH_PORT_NULL;
			return NO;
		}
	}
	
	if (task_set_exception_ports(process.processTask, EXC_MASK_BREAKPOINT, _exceptionPort, (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES), MACHINE_THREAD_STATE) != KERN_SUCCESS)
	{
		NSLog(@"ERROR: task_set_exception_ports failed on adding breakpoint");
		return NO;
	}
	
	static dispatch_once_t once = 0;
	dispatch_once(&once, ^{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			// Not exactly clear what to pass in for the size
			if (mach_msg_server(mach_exc_server, 2048, self->_exceptionPort, MACH_MSG_TIMEOUT_NONE) != MACH_MSG_SUCCESS)
			{
				NSLog(@"mach_msg_server() returned on error!");
			}
		});
    });
	
	return YES;
}

- (BOOL)updateThreadListInWatchpoint:(ZGBreakPoint *)watchPoint type:(ZGWatchPointType)watchPointType
{
	ZGMemoryMap processTask = watchPoint.process.processTask;
	ZGProcessType processType = watchPoint.process.type;
	ZGMemorySize watchSize = watchPoint.watchSize;
	ZGVariable *variable = watchPoint.variable;
	NSArray<ZGDebugThread *> *oldDebugThreads = watchPoint.debugThreads;
	
	thread_act_array_t threadList = NULL;
	mach_msg_type_number_t threadListCount = 0;
	if (task_threads(processTask, &threadList, &threadListCount) != KERN_SUCCESS)
	{
		ZG_LOG(@"ERROR: task_threads failed on adding watchpoint");
		return NO;
	}
	
	static uint8_t maxHardwareRegistersAvailableResult = 0;
	{
		static dispatch_once_t maxHardwareRegistersOnceToken;
		dispatch_once(&maxHardwareRegistersOnceToken, ^{
			int value = 0;
			size_t size = sizeof(value);
			int result = sysctlbyname("hw.optional.watchpoint", &value, &size, NULL, 0);
			maxHardwareRegistersAvailableResult = (result == 0 && value != 0) ? (uint8_t)value : 4;
		});
	}
	
	const uint8_t maxHardwareRegistersAvailable = maxHardwareRegistersAvailableResult;
	
	BOOL suspendedTask = NO;
	
	NSMutableArray<ZGDebugThread *> *newDebugThreads = [[NSMutableArray alloc] init];
	
	for (mach_msg_type_number_t threadIndex = 0; threadIndex < threadListCount; threadIndex++)
	{
		ZGDebugThread *existingThread = nil;
		for (ZGDebugThread *debugThread in oldDebugThreads)
		{
			if (debugThread.thread == threadList[threadIndex])
			{
				existingThread = debugThread;
				break;
			}
		}
		
		if (existingThread != nil)
		{
			[newDebugThreads addObject:existingThread];
			continue;
		}
		
		if (!suspendedTask)
		{
			ZGSuspendTask(processTask);
			suspendedTask = YES;
		}
		
		zg_debug_state_t debugState;
		mach_msg_type_number_t stateCount;
		if (!ZGGetDebugThreadState(&debugState, threadList[threadIndex], &stateCount))
		{
			ZG_LOG(@"ERROR: ZGGetDebugThreadState failed on adding watchpoint for thread %u, %s", threadList[threadIndex], __PRETTY_FUNCTION__);
			continue;
		}
		
		BOOL foundRegisterIndex = NO;
		uint8_t debugRegisterIndex = 0;
		for (uint8_t registerIndex = 0; registerIndex < maxHardwareRegistersAvailable; registerIndex++)
		{
			if (ZG_PROCESS_TYPE_IS_ARM64(processType) && IS_WATCHPOINT_REGISTER_AVAILABLE(debugState, registerIndex))
			{
				debugRegisterIndex = registerIndex;
				foundRegisterIndex = YES;
				break;
			}
		}
		
		if (!foundRegisterIndex)
		{
			ZG_LOG(@"Failed to find available debug register for thread %u, %s", threadList[threadIndex], __PRETTY_FUNCTION__);
			continue;
		}
		
		ZGDebugThread *debugThread = [[ZGDebugThread alloc] initWithThread:threadList[threadIndex] registerIndex:debugRegisterIndex];
		
		if (ZG_PROCESS_TYPE_IS_ARM64(processType))
		{
			// Reference: https://developer.arm.com/documentation/ddi0344/k/debug/debug-register-descriptions/watchpoint-control-registers
			// And DNBArchImplARM64.cpp in lldb source
			
			debugState.__wvr[debugRegisterIndex] = variable.address;
			
			uint32_t byteAddressSelect = (uint32_t)((1 << watchSize) - 1) << 5;
			
			uint32_t userModeMask = ((uint32_t)(2u << 1));
			
			uint32_t readMask = ((uint32_t)(1u << 3));
			uint32_t writeMask = ((uint32_t)(1u << 4));
			uint32_t enableMask = (uint32_t)1u;
			
			uint32_t accessMask = (watchPointType == ZGWatchPointWrite) ? writeMask : (readMask | writeMask);
			
			debugState.__wcr[debugRegisterIndex] = byteAddressSelect | userModeMask | enableMask | accessMask;
		}
		
		if (!ZGSetDebugThreadState(&debugState, threadList[threadIndex], stateCount))
		{
			ZG_LOG(@"Failure in setting registers thread state for adding watchpoint for thread %u", threadList[threadIndex]);
			continue;
		}
		
		[newDebugThreads addObject:debugThread];
	}
	
	if (!ZGDeallocateMemory(current_task(), (mach_vm_address_t)threadList, threadListCount * sizeof(thread_act_t)))
	{
		ZG_LOG(@"Failed to deallocate thread list in %s...", __PRETTY_FUNCTION__);
	}
	
	if (suspendedTask)
	{
		ZGResumeTask(processTask);
	}
	
	watchPoint.debugThreads = newDebugThreads;
	
	if (newDebugThreads.count == 0)
	{
		ZG_LOG(@"ERROR: Failed to set watch variable: no threads found.");
		return NO;
	}
	
	return YES;
}

- (BOOL)updateThreadListInHardwareBreakPoint:(ZGBreakPoint *)breakPoint
{
	ZGMemoryMap processTask = breakPoint.process.processTask;
	ZGProcessType processType = breakPoint.process.type;
	ZGVariable *variable = breakPoint.variable;
	ZGMemorySize breakPointSize = variable.size;
	NSArray<ZGDebugThread *> *oldDebugThreads = breakPoint.debugThreads;
	
	thread_act_array_t threadList = NULL;
	mach_msg_type_number_t threadListCount = 0;
	if (task_threads(processTask, &threadList, &threadListCount) != KERN_SUCCESS)
	{
		ZG_LOG(@"ERROR: task_threads failed on adding hardware breakpoint");
		return NO;
	}
	
	static uint8_t maxHardwareRegistersAvailableResult = 0;
	{
		static dispatch_once_t maxHardwareRegistersOnceToken;
		dispatch_once(&maxHardwareRegistersOnceToken, ^{
			int value = 0;
			size_t size = sizeof(value);
			int result = sysctlbyname("hw.optional.breakpoint", &value, &size, NULL, 0);
			maxHardwareRegistersAvailableResult = (result == 0 && value != 0) ? (uint8_t)value : 6;
		});
	}
	
	const uint8_t maxHardwareRegistersAvailable = maxHardwareRegistersAvailableResult;
	
	BOOL suspendedTask = NO;
	
	NSMutableArray<ZGDebugThread *> *newDebugThreads = [[NSMutableArray alloc] init];
	
	for (mach_msg_type_number_t threadIndex = 0; threadIndex < threadListCount; threadIndex++)
	{
		ZGDebugThread *existingThread = nil;
		for (ZGDebugThread *debugThread in oldDebugThreads)
		{
			if (debugThread.thread == threadList[threadIndex])
			{
				existingThread = debugThread;
				break;
			}
		}
		
		if (existingThread != nil)
		{
			[newDebugThreads addObject:existingThread];
			continue;
		}
		
		if (!suspendedTask)
		{
			ZGSuspendTask(processTask);
			suspendedTask = YES;
		}
		
		zg_debug_state_t debugState;
		mach_msg_type_number_t stateCount;
		if (!ZGGetDebugThreadState(&debugState, threadList[threadIndex], &stateCount))
		{
			ZG_LOG(@"ERROR: ZGGetDebugThreadState failed on adding hardware breakpoint for thread %u, %s", threadList[threadIndex], __PRETTY_FUNCTION__);
			continue;
		}
		
		BOOL foundRegisterIndex = NO;
		uint8_t debugRegisterIndex = 0;
		for (uint8_t registerIndex = 0; registerIndex < maxHardwareRegistersAvailable; registerIndex++)
		{
			if (ZG_PROCESS_TYPE_IS_ARM64(processType) && IS_BREAKPOINT_REGISTER_AVAILABLE(debugState, registerIndex))
			{
				debugRegisterIndex = registerIndex;
				foundRegisterIndex = YES;
				break;
			}
		}
		
		if (!foundRegisterIndex)
		{
			ZG_LOG(@"Failed to find available debug register for thread %u, %s", threadList[threadIndex], __PRETTY_FUNCTION__);
			continue;
		}
		
		ZGDebugThread *debugThread = [[ZGDebugThread alloc] initWithThread:threadList[threadIndex] registerIndex:debugRegisterIndex];
		
		if (ZG_PROCESS_TYPE_IS_ARM64(processType))
		{
			debugState.__bvr[debugRegisterIndex] = variable.address;
			
			uint32_t byteAddressSelect = (uint32_t)((1 << breakPointSize) - 1) << 5;
			
			uint32_t userModeMask = ((uint32_t)(2u << 1));
			
			uint32_t readMask = ((uint32_t)(1u << 3));
			uint32_t enableMask = (uint32_t)1u;
			
			uint32_t accessMask = readMask;
			
			debugState.__bcr[debugRegisterIndex] = byteAddressSelect | userModeMask | enableMask | accessMask;
		}
		
		if (!ZGSetDebugThreadState(&debugState, threadList[threadIndex], stateCount))
		{
			ZG_LOG(@"Failure in setting registers thread state for adding watchpoint for thread %u", threadList[threadIndex]);
			continue;
		}
		
		[newDebugThreads addObject:debugThread];
	}
	
	if (!ZGDeallocateMemory(current_task(), (mach_vm_address_t)threadList, threadListCount * sizeof(thread_act_t)))
	{
		ZG_LOG(@"Failed to deallocate thread list in %s...", __PRETTY_FUNCTION__);
	}
	
	if (suspendedTask)
	{
		ZGResumeTask(processTask);
	}
	
	breakPoint.debugThreads = newDebugThreads;
	
	if (newDebugThreads.count == 0)
	{
		ZG_LOG(@"ERROR: Failed to set hardware breakpoint variable: no threads found.");
		return NO;
	}
	
	return YES;
}

- (BOOL)addWatchpointOnVariable:(ZGVariable *)variable inProcess:(ZGProcess *)process watchPointType:(ZGWatchPointType)watchPointType delegate:(id <ZGBreakPointDelegate>)delegate getBreakPoint:(ZGBreakPoint * __autoreleasing *)returnedBreakPoint
{
	@synchronized(self)
	{
		if (![self setUpExceptionPortForProcess:process])
		{
			return NO;
		}
		
		ZGMemorySize watchSize = 0;
		if (variable.size <= 1)
		{
			watchSize = 1;
		}
		else if (variable.size == 2)
		{
			watchSize = 2;
		}
		else if (variable.size <= 4 || !ZG_PROCESS_TYPE_IS_64_BIT(process.type))
		{
			watchSize = 4;
		}
		else
		{
			watchSize = 8;
		}
		
		ZGBreakPoint *breakPoint = [[ZGBreakPoint alloc] initWithProcess:process type:ZGBreakPointWatchData delegate:delegate];
		breakPoint.variable = variable;
		breakPoint.watchSize = watchSize;
		
		if (![self updateThreadListInWatchpoint:breakPoint type:watchPointType])
		{
			return NO;
		}

		if (self->_watchPointTimer == NULL && (self->_watchPointTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue())) != NULL)
		{
			dispatch_source_t watchPointTimer = self->_watchPointTimer;
			
			dispatch_source_set_timer(watchPointTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
			dispatch_source_set_event_handler(watchPointTimer, ^{
				for (ZGBreakPoint *existingBreakPoint in [self breakPoints])
				{
					if (existingBreakPoint.type != ZGBreakPointWatchData)
					{
						continue;
					}
					
					if (!existingBreakPoint.dead && ![self updateThreadListInWatchpoint:existingBreakPoint type:watchPointType])
					{
						existingBreakPoint.dead = YES;
					}
				}
			});
			dispatch_resume(watchPointTimer);
		}

		[self addBreakPoint:breakPoint];
		
		if (returnedBreakPoint != NULL)
		{
			*returnedBreakPoint = breakPoint;
		}
	}
	
	return YES;
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process usesHardware:(BOOL)usesHardware callback:(PyObject *)callback delegate:(id)delegate
{
	return [self addBreakPointOnInstruction:instruction inProcess:process thread:0 basePointer:0 hidden:NO emulated:NO usesHardware:usesHardware allowSoftwareFallback:NO condition:NULL callback:callback delegate:delegate];
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process usesHardware:(BOOL)usesHardware condition:(PyObject *)condition delegate:(id)delegate
{
	return [self addBreakPointOnInstruction:instruction inProcess:process thread:0 basePointer:0 hidden:NO emulated:NO usesHardware:usesHardware allowSoftwareFallback:NO condition:condition callback:NULL delegate:delegate];
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process thread:(thread_act_t)thread basePointer:(ZGMemoryAddress)basePointer usesHardware:(BOOL)usesHardware allowSoftwareFallback:(BOOL)allowSoftwareFallback delegate:(id)delegate
{
	return [self addBreakPointOnInstruction:instruction inProcess:process thread:thread basePointer:basePointer hidden:YES emulated:NO usesHardware:usesHardware allowSoftwareFallback:allowSoftwareFallback condition:NULL callback:NULL delegate:delegate];
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process thread:(thread_act_t)thread basePointer:(ZGMemoryAddress)basePointer usesHardware:(BOOL)usesHardware callback:(PyObject *)callback delegate:(id)delegate
{
	return [self addBreakPointOnInstruction:instruction inProcess:process thread:thread basePointer:basePointer hidden:YES emulated:NO usesHardware:usesHardware allowSoftwareFallback:NO condition:NULL callback:callback delegate:delegate];
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process emulated:(BOOL)emulated usesHardware:(BOOL)usesHardware delegate:(id)delegate
{
	return [self addBreakPointOnInstruction:instruction inProcess:process thread:0 basePointer:0 hidden:NO emulated:emulated usesHardware:usesHardware allowSoftwareFallback:NO condition:NULL callback:NULL delegate:delegate];
}

- (BOOL)addBreakPointOnInstruction:(ZGInstruction *)instruction inProcess:(ZGProcess *)process thread:(thread_act_t)thread basePointer:(ZGMemoryAddress)basePointer hidden:(BOOL)isHidden emulated:(BOOL)emulated usesHardware:(BOOL)usesHardware allowSoftwareFallback:(BOOL)allowSoftwareFallback condition:(PyObject *)condition callback:(PyObject *)callback delegate:(id)delegate
{
	if (![self setUpExceptionPortForProcess:process])
	{
		return NO;
	}
	
	BOOL breakPointAlreadyExists = [[self breakPoints] zgHasObjectMatchingCondition:^(ZGBreakPoint *breakPoint) {
		return (BOOL)(breakPoint.type == ZGBreakPointInstruction && breakPoint.task == process.processTask && breakPoint.variable.address == instruction.variable.address);
	}];
	
	if (breakPointAlreadyExists)
	{
		return NO;
	}
	
	ZGSuspendTask(process.processTask);
	
	ZGVariable *variable = [instruction.variable copy];
	
	ZGBreakPoint *breakPoint = [[ZGBreakPoint alloc] initWithProcess:process type:ZGBreakPointInstruction delegate:delegate];
	
	breakPoint.variable = variable;
	breakPoint.hidden = isHidden;
	breakPoint.emulated = emulated;
	breakPoint.thread = thread;
	breakPoint.basePointer = basePointer;
	breakPoint.usesHardware = usesHardware;
	
	breakPoint.condition = condition;
	breakPoint.callback = callback;
	
	[self addBreakPoint:breakPoint];
	
	bool (^addSoftwareBreakpoint)(void) = ^{
		return ZGWriteBytesIgnoringProtection(process.processTask, variable.address, gBreakpointOpcode, sizeof(gBreakpointOpcode));
	};
	
	BOOL success;
	if (breakPoint.usesHardware)
	{
		success = [self updateThreadListInHardwareBreakPoint:breakPoint];
		
		if (!success)
		{
			// Try again with software breakpoint if allowed
			if (allowSoftwareFallback)
			{
				[self removeBreakPoint:breakPoint];
				
				success = addSoftwareBreakpoint();
			}
		}
		else
		{
			@synchronized(self)
			{
				if (self->_hardwareBreakpointTimer == NULL && (self->_hardwareBreakpointTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue())) != NULL)
				{
					dispatch_source_t hardwareBreakpointTimer = self->_hardwareBreakpointTimer;
					
					dispatch_source_set_timer(hardwareBreakpointTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
					dispatch_source_set_event_handler(hardwareBreakpointTimer, ^{
						for (ZGBreakPoint *existingBreakPoint in [self breakPoints])
						{
							if (existingBreakPoint.type != ZGBreakPointInstruction || !existingBreakPoint.usesHardware)
							{
								continue;
							}
							
							if (!existingBreakPoint.dead && ![self updateThreadListInHardwareBreakPoint:existingBreakPoint])
							{
								existingBreakPoint.dead = YES;
							}
						}
					});
					dispatch_resume(hardwareBreakpointTimer);
				}
			}
		}
	}
	else
	{
		success = addSoftwareBreakpoint();
	}
	
	if (!success)
	{
		[self removeBreakPoint:breakPoint];
	}
	
	ZGResumeTask(process.processTask);
	
	return success;
}

- (ZGBreakPoint *)addSingleStepBreakPointFromBreakPoint:(ZGBreakPoint *)breakPoint
{
	ZGBreakPoint *singleStepBreakPoint = [[ZGBreakPoint alloc] initWithProcess:breakPoint.process type:ZGBreakPointSingleStepInstruction delegate:breakPoint.delegate];
	singleStepBreakPoint.thread = breakPoint.thread;
	
	[self addBreakPoint:singleStepBreakPoint];
	
	return singleStepBreakPoint;
}

- (void)addBreakPoint:(ZGBreakPoint *)breakPoint
{
	@synchronized(self)
	{
		NSMutableArray<ZGBreakPoint *> *currentBreakPoints = [NSMutableArray arrayWithArray:[self breakPoints]];
		[currentBreakPoints addObject:breakPoint];
		_breakPoints = [NSArray arrayWithArray:currentBreakPoints];
	}
}

- (void)removeBreakPoint:(ZGBreakPoint *)breakPoint
{
	@synchronized(self)
	{
		if (_hardwareBreakpointTimer != NULL && breakPoint.type == ZGBreakPointInstruction && breakPoint.usesHardware)
		{
			BOOL shouldKeepTimer = [_breakPoints zgHasObjectMatchingCondition:^(ZGBreakPoint *nextBreakPoint){ return (BOOL)(nextBreakPoint.type == ZGBreakPointInstruction && breakPoint != nextBreakPoint && nextBreakPoint.usesHardware); }];
			if (!shouldKeepTimer)
			{
				dispatch_source_cancel((dispatch_source_t _Nonnull)_hardwareBreakpointTimer);
				_hardwareBreakpointTimer = NULL;
			}
		}
		
		NSMutableArray<ZGBreakPoint *> *currentBreakPoints = [NSMutableArray arrayWithArray:[self breakPoints]];
		[currentBreakPoints removeObject:breakPoint];
		
		// Remove any code injection handlers associated with this breakpoint
		// Need to check the breakpoint is emulated to ignore single stepping breakpoints
		if (breakPoint.emulated)
		{
			NSNumber *breakPointKey = @(breakPoint.variable.address);
			NSMutableArray<ZGCodeInjectionHandler *> *codeInjectionHandlers = _codeInjectionMappings[breakPointKey];
			if (codeInjectionHandlers != nil)
			{
				ZGProcess *breakPointProcess = breakPoint.process;
				NSMutableArray *newCodeInjectionHandlers = [NSMutableArray array];
				for (ZGCodeInjectionHandler *injectionHandler in codeInjectionHandlers)
				{
					if (injectionHandler.process.processTask != breakPointProcess.processTask)
					{
						[newCodeInjectionHandlers addObject:injectionHandler];
					}
				}
				
				_codeInjectionMappings[breakPointKey] = newCodeInjectionHandlers;
			}
		}
		
		_breakPoints = [NSArray arrayWithArray:currentBreakPoints];
	}
}

- (NSArray<ZGBreakPoint *> *)breakPoints
{
	@synchronized(self)
	{
		return _breakPoints;
	}
}

- (BOOL)addCodeInjectionHandler:(ZGCodeInjectionHandler *)codeInjectionHandler
{
	ZGProcess *process = codeInjectionHandler.process;
	
	ZGInstruction *toIslandInstruction = codeInjectionHandler.toIslandInstruction;
	
	[self removeBreakPointOnInstruction:toIslandInstruction inProcess:process];
	
	if (![self addBreakPointOnInstruction:toIslandInstruction inProcess:process emulated:YES usesHardware:codeInjectionHandler.usesHardwareBreakpoints delegate:codeInjectionHandler])
	{
		return NO;
	}
	
	ZGInstruction *fromIslandInstruction = codeInjectionHandler.fromIslandInstruction;
	
	[self removeBreakPointOnInstruction:fromIslandInstruction inProcess:process];
		
	if (![self addBreakPointOnInstruction:fromIslandInstruction inProcess:process emulated:YES usesHardware:codeInjectionHandler.usesHardwareBreakpoints delegate:codeInjectionHandler])
	{
		[self removeBreakPointOnInstruction:toIslandInstruction inProcess:process];
		return NO;
	}
	
	@synchronized(self)
	{
		if (_codeInjectionMappings == nil)
		{
			_codeInjectionMappings = [NSMutableDictionary dictionary];
		}
		
		NSNumber *toIslandMemoryAddressKey = @(toIslandInstruction.variable.address);
		NSMutableArray<ZGCodeInjectionHandler *> *toIslandHandlers = _codeInjectionMappings[toIslandMemoryAddressKey];
		if (toIslandHandlers == nil)
		{
			toIslandHandlers = [NSMutableArray array];
		}
		
		[toIslandHandlers addObject:codeInjectionHandler];
		
		_codeInjectionMappings[toIslandMemoryAddressKey] = toIslandHandlers;
		
		NSNumber *fromIslandMemoryAddressKey = @(fromIslandInstruction.variable.address);
		NSMutableArray<ZGCodeInjectionHandler *> *fromIslandHandlers = _codeInjectionMappings[fromIslandMemoryAddressKey];
		if (fromIslandHandlers == nil)
		{
			fromIslandHandlers = [NSMutableArray array];
		}
		
		[fromIslandHandlers addObject:codeInjectionHandler];
		
		_codeInjectionMappings[fromIslandMemoryAddressKey] = fromIslandHandlers;
	}
	
	return YES;
}

- (ZGCodeInjectionHandler * _Nullable)codeInjectionHandlerForInstruction:(ZGInstruction *)instruction process:(ZGProcess *)process
{
	return [self codeInjectionHandlerForMemoryAddress:instruction.variable.address process:process];
}

- (ZGCodeInjectionHandler * _Nullable)codeInjectionHandlerForMemoryAddress:(ZGMemoryAddress)memoryAddress process:(ZGProcess *)process
{
	@synchronized(self)
	{
		for (ZGCodeInjectionHandler *codeInjectionHandler in _codeInjectionMappings[@(memoryAddress)])
		{
			if (codeInjectionHandler.process.processTask == process.processTask)
			{
				return codeInjectionHandler;
			}
		}
	}
	return nil;
}

@end
