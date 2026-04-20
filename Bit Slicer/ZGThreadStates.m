/*
 * Copyright (c) 2014 Mayur Pawashe
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

#include "ZGThreadStates.h"
#include <sys/sysctl.h>
#import <Foundation/Foundation.h>

typedef arm_neon_state64_t zg_float_state_t;

bool ZGGetGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, mach_msg_type_number_t *stateCount)
{
	mach_msg_type_number_t localStateCount = ARM_THREAD_STATE64_COUNT;
	thread_state_flavor_t flavor = ARM_THREAD_STATE64;
	
	bool success = (thread_get_state(thread, flavor, (thread_state_t)threadState, &localStateCount) == KERN_SUCCESS);
	if (stateCount != NULL) *stateCount = localStateCount;
	return success;
}

bool ZGSetGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, mach_msg_type_number_t stateCount)
{
	thread_state_flavor_t flavor = ARM_THREAD_STATE64;
	
	return (thread_set_state(thread, flavor, (thread_state_t)threadState, stateCount) == KERN_SUCCESS);
}

bool ZGGetExceptionThreadState(zg_exception_state_t *exceptionState, thread_act_t thread, mach_msg_type_number_t *stateCount)
{
	// Not needing to use ARM_EXCEPTION_STATE64_V2_COUNT (macOS 15+) currently
	
	mach_msg_type_number_t localStateCount = ARM_EXCEPTION_STATE64_COUNT;
	thread_state_flavor_t flavor = ARM_EXCEPTION_STATE64;
	
	bool success = (thread_get_state(thread, flavor, (thread_state_t)exceptionState, &localStateCount) == KERN_SUCCESS);
	if (stateCount != NULL) *stateCount = localStateCount;
	return success;
}

// See lldb as a reference for logic pertaining to dealing with PAC and signing pointers
#if __has_feature(ptrauth_calls)
static bool ZGGetMaxAddressingBits(uint32_t *maxAddressingBits)
{
	static uint32_t gMaxAddressingBits = 0;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		size_t len = sizeof(uint32_t);
		if (sysctlbyname("machdep.virtual_address_size", &gMaxAddressingBits, &len, NULL, 0) != 0)
		{
			gMaxAddressingBits = 0;
		}
	});
	
	*maxAddressingBits = gMaxAddressingBits;
	return gMaxAddressingBits > 0;
}

static uint64_t ZGClearPACBits(uint64_t value)
{
	uint32_t maxAddressingBits = 0;
	if (!ZGGetMaxAddressingBits(&maxAddressingBits))
	{
		return value;
	}

	uint64_t mask = ((1ULL << maxAddressingBits) - 1);
	return value & mask; // high bits cleared to 0
}

#define SIGN_AND_SET_POINTER(setter, thread, threadState, instructionAddress) \
do { \
	zg_thread_state_t convertedThreadState; \
	{ \
		mach_msg_type_number_t convertedCount = ARM_THREAD_STATE64_COUNT; \
		kern_return_t result = thread_convert_thread_state(thread, THREAD_CONVERT_THREAD_STATE_TO_SELF, ARM_THREAD_STATE64, (thread_state_t)threadState, ARM_THREAD_STATE64_COUNT, (thread_state_t)&convertedThreadState, &convertedCount); \
		if (result != KERN_SUCCESS) \
		{ \
			return false; \
		} \
	} \
	\
	void *strippedPointer = ptrauth_strip((void *)instructionAddress, ptrauth_key_function_pointer); \
	ZGMemoryAddress strippedInstructionAddress = (ZGMemoryAddress)(uintptr_t)strippedPointer; \
	void *signedPointer = ptrauth_sign_unauthenticated((void *)strippedInstructionAddress, ptrauth_key_function_pointer, 0); \
	ZGMemoryAddress signedUnauthenticatedAddress = (ZGMemoryAddress)(uintptr_t)signedPointer; \
	\
	setter(convertedThreadState, (void *)signedUnauthenticatedAddress); \
	\
	{ \
		mach_msg_type_number_t finalCount = ARM_THREAD_STATE64_COUNT; \
		kern_return_t result = thread_convert_thread_state(thread, THREAD_CONVERT_THREAD_STATE_FROM_SELF, ARM_THREAD_STATE64, (thread_state_t)&convertedThreadState, ARM_THREAD_STATE64_COUNT, (thread_state_t)threadState, &finalCount); \
		if (result != KERN_SUCCESS) \
		{ \
			return false; \
		} \
	} \
} while (0)

#endif

ZGMemoryAddress ZGInstructionPointerFromGeneralThreadState(zg_thread_state_t *threadState, ZGProcessType type)
{
	(void)type;
	ZGMemoryAddress instructionPointer;
#if __has_feature(ptrauth_calls)
	uint64_t unstrippedAddress = (uint64_t)(threadState->__opaque_pc);
	instructionPointer = ZGClearPACBits((uint64_t)(unstrippedAddress));
#else
	instructionPointer = arm_thread_state64_get_pc(*threadState);
#endif
	
	return instructionPointer;
}

bool ZGSetInstructionPointerFromGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, ZGMemoryAddress instructionAddress, ZGProcessType type)
{
	(void)type;
	
#if __has_feature(ptrauth_calls)
	SIGN_AND_SET_POINTER(arm_thread_state64_set_pc_fptr, thread, threadState, instructionAddress);
#else
	(void)thread;
	arm_thread_state64_set_pc_fptr(*threadState, (void *)instructionAddress);
#endif
	
	return true;
}

ZGMemoryAddress ZGBasePointerFromGeneralThreadState(zg_thread_state_t *threadState, ZGProcessType type)
{
	(void)type;
	ZGMemoryAddress framePointer;
#if __has_feature(ptrauth_calls)
	framePointer = ZGClearPACBits((uint64_t)(threadState->__opaque_fp));
#else
	framePointer = arm_thread_state64_get_fp(*threadState);
#endif
	return framePointer;
}

bool ZGSetBasePointerFromGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, ZGMemoryAddress instructionAddress)
{
#if __has_feature(ptrauth_calls)
	SIGN_AND_SET_POINTER(arm_thread_state64_set_fp, thread, threadState, instructionAddress);
#else
	(void)thread;
	arm_thread_state64_set_fp(*threadState, instructionAddress);
#endif
	
	return true;
}

ZGMemoryAddress ZGLinkRegisterFromGeneralThreadState(zg_thread_state_t *threadState)
{
	ZGMemoryAddress linkRegister;
#if __has_feature(ptrauth_calls)
	linkRegister = ZGClearPACBits((uint64_t)(threadState->__opaque_lr));
#else
	linkRegister = arm_thread_state64_get_lr(*threadState);
#endif
	return linkRegister;
}

bool ZGSetLinkRegisterFromGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, ZGMemoryAddress instructionAddress)
{
#if __has_feature(ptrauth_calls)
	SIGN_AND_SET_POINTER(arm_thread_state64_set_lr_fptr, thread, threadState, instructionAddress);
#else
	(void)thread;
	arm_thread_state64_set_lr_fptr(*threadState, instructionAddress);
#endif
	
	return true;
}

ZGMemoryAddress ZGStackPointerFromGeneralThreadState(zg_thread_state_t *threadState)
{
	ZGMemoryAddress stackPointer;
#if __has_feature(ptrauth_calls)
	stackPointer = ZGClearPACBits((uint64_t)(threadState->__opaque_sp));
#else
	stackPointer = arm_thread_state64_get_sp(*threadState);
#endif
	return stackPointer;
}

bool ZGSetStackPointerFromGeneralThreadState(zg_thread_state_t *threadState, thread_act_t thread, ZGMemoryAddress instructionAddress)
{
#if __has_feature(ptrauth_calls)
	SIGN_AND_SET_POINTER(arm_thread_state64_set_sp, thread, threadState, instructionAddress);
#else
	(void)thread;
	arm_thread_state64_set_sp(*threadState, instructionAddress);
#endif
	
	return true;
}

bool ZGGetDebugThreadState(zg_debug_state_t *debugState, thread_act_t thread, mach_msg_type_number_t *stateCount)
{
	thread_state_flavor_t flavor = ARM_DEBUG_STATE64;
	mach_msg_type_number_t localStateCount = ARM_DEBUG_STATE64_COUNT;
	
	bool success = (thread_get_state(thread, flavor, (thread_state_t)debugState, &localStateCount) == KERN_SUCCESS);
	if (stateCount != NULL) *stateCount = localStateCount;
	return success;
}

bool ZGSetDebugThreadState(zg_debug_state_t *debugState, thread_act_t thread, mach_msg_type_number_t stateCount)
{
	thread_state_flavor_t flavor = ARM_DEBUG_STATE64;
	
	return (thread_set_state(thread, flavor, (thread_state_t)debugState, stateCount) == KERN_SUCCESS);
}

bool ZGGetVectorThreadState(zg_vector_state_t *vectorState, thread_act_t thread, mach_msg_type_number_t *stateCount, ZGProcessType type, bool *hasAVXSupport)
{
	(void)type;
	
	mach_msg_type_number_t localStateCount = ARM_NEON_STATE64_COUNT;
	bool success = (thread_get_state(thread, ARM_NEON_STATE64, (thread_state_t)vectorState, &localStateCount) == KERN_SUCCESS);
	
	if (hasAVXSupport != NULL) *hasAVXSupport = false;
	if (stateCount != NULL) *stateCount = localStateCount;
	
	return success;
}

bool ZGSetVectorThreadState(zg_vector_state_t *vectorState, thread_act_t thread, mach_msg_type_number_t stateCount, ZGProcessType type)
{
	(void)type;
	
	return (thread_set_state(thread, ARM_NEON_STATE64, (thread_state_t)vectorState, stateCount) == KERN_SUCCESS);
}
