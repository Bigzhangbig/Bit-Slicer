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

#import "ZGRegisterEntries.h"
#import "ZGVariable.h"
#import "ZGNullability.h"

@implementation ZGRegisterEntries

void *ZGRegisterEntryValue(ZGRegisterEntry *entry)
{
	return entry->value;
}

#define ADD_GENERAL_REGISTER(entries, entryIndex, threadState, registerName, registerValue) \
do { \
	strncpy((char *)&entries[entryIndex].name, #registerName, sizeof(entries[entryIndex].name)); \
	entries[entryIndex].size = sizeof(registerValue); \
	memcpy(&entries[entryIndex].value, &(registerValue), entries[entryIndex].size); \
	entries[entryIndex].type = ZGRegisterGeneralPurpose; \
	entryIndex++; \
} while(0)

+ (int)getRegisterEntries:(ZGRegisterEntry *)entries fromGeneralPurposeThreadState:(zg_thread_state_t)threadState processType:(ZGProcessType)processType
{
	int entryIndex = 0;
	
	// Add general purpose registers
	for (size_t registerIndex = 0; registerIndex < sizeof(threadState.__x) / sizeof(*threadState.__x); registerIndex++)
	{
		const char *registerName = [[NSString stringWithFormat:@"x%zu", registerIndex] UTF8String];
		if (registerName == NULL) continue;
		
		strncpy((char *)&entries[entryIndex].name, registerName, sizeof(entries[entryIndex].name));
		entries[entryIndex].size = sizeof(*threadState.__x);
		memcpy(&entries[entryIndex].value, &threadState.__x[registerIndex], entries[entryIndex].size);
		entries[entryIndex].type = ZGRegisterGeneralPurpose;
		
		entryIndex++;
	}
	
	// Frame pointer register
	{
		ZGMemoryAddress fp = ZGBasePointerFromGeneralThreadState(&threadState, processType);
		ADD_GENERAL_REGISTER(entries, entryIndex, threadState, fp, fp);
	}
	
	// Link register
	{
		ZGMemoryAddress lr = ZGLinkRegisterFromGeneralThreadState(&threadState);
		ADD_GENERAL_REGISTER(entries, entryIndex, threadState, lr, lr);
	}
	
	// Stack pointer
	{
		ZGMemoryAddress sp = ZGStackPointerFromGeneralThreadState(&threadState);
		ADD_GENERAL_REGISTER(entries, entryIndex, threadState, sp, sp);
	}
	
	// Program counter
	{
		ZGMemoryAddress pc = ZGInstructionPointerFromGeneralThreadState(&threadState, processType);
		ADD_GENERAL_REGISTER(entries, entryIndex, threadState, pc, pc);
	}
	
	// Program status register
	ADD_GENERAL_REGISTER(entries, entryIndex, threadState, cpsr, threadState.__cpsr);
	
	entries[entryIndex].name[0] = 0;
	
	return entryIndex;
}

+ (int)getRegisterEntries:(ZGRegisterEntry *)entries fromVectorThreadState:(zg_vector_state_t)vectorState processType:(ZGProcessType)processType hasAVXSupport:(BOOL)hasAVXSupport
{
	int entryIndex = 0;
	
	// Add vector registers
	for (size_t registerIndex = 0; registerIndex < sizeof(vectorState.__v) / sizeof(*vectorState.__v); registerIndex++)
	{
		const char *registerName = [[NSString stringWithFormat:@"v%zu", registerIndex] UTF8String];
		if (registerName == NULL) continue;
		
		strncpy((char *)&entries[entryIndex].name, registerName, sizeof(entries[entryIndex].name));
		entries[entryIndex].size = sizeof(*vectorState.__v);
		memcpy(&entries[entryIndex].value, &vectorState.__v[registerIndex], entries[entryIndex].size);
		entries[entryIndex].type = ZGRegisterVector;
		
		entryIndex++;
	}
	
	// Add fpsr
	{
		const char *registerName = "fpsr";
		
		strncpy((char *)&entries[entryIndex].name, registerName, sizeof(entries[entryIndex].name));
		entries[entryIndex].size = sizeof(vectorState.__fpsr);
		memcpy(&entries[entryIndex].value, &vectorState.__fpsr, entries[entryIndex].size);
		entries[entryIndex].type = ZGRegisterVector;
		
		entryIndex++;
	}
	
	// Add fpcr
	{
		const char *registerName = "fpcr";
		
		strncpy((char *)&entries[entryIndex].name, registerName, sizeof(entries[entryIndex].name));
		entries[entryIndex].size = sizeof(vectorState.__fpcr);
		memcpy(&entries[entryIndex].value, &vectorState.__fpcr, entries[entryIndex].size);
		entries[entryIndex].type = ZGRegisterVector;
		
		entryIndex++;
	}
	
	entries[entryIndex].name[0] = 0;
	
	return entryIndex;
}

+ (BOOL)changeGeneralPurposeThreadState:(zg_thread_state_t *)threadState thread:(thread_act_t)thread registerName:(NSString *)registerName value:(const void *)rawValue size:(size_t)size
{
	NSArray<NSString *> *generalRegisters = @[@"x0", @"x1", @"x2", @"x3", @"x4", @"x5", @"x6", @"x7", @"x8", @"x9", @"x10", @"x11", @"x12", @"x13", @"x14", @"x15", @"x16", @"x17", @"x18", @"x19", @"x20", @"x21", @"x22", @"x23", @"x24", @"x25", @"x26", @"x27", @"x28"];
	
	if ([generalRegisters containsObject:registerName])
	{
		memcpy((uint64_t *)&threadState->__x + [generalRegisters indexOfObject:registerName], rawValue, MIN(size, sizeof(threadState->__x)));
		return YES;
	}
	else if ([registerName isEqualToString:@"fp"])
	{
		ZGMemoryAddress value = 0x0;
		memcpy(&value, rawValue, MIN(size, sizeof(value)));
		
		return ZGSetBasePointerFromGeneralThreadState(threadState, thread, value);
	}
	else if ([registerName isEqualToString:@"lr"])
	{
		ZGMemoryAddress value = 0x0;
		memcpy(&value, rawValue, MIN(size, sizeof(value)));
		
		return ZGSetLinkRegisterFromGeneralThreadState(threadState, thread, value);
	}
	else if ([registerName isEqualToString:@"sp"])
	{
		ZGMemoryAddress value = 0x0;
		memcpy(&value, rawValue, MIN(size, sizeof(value)));
		
		return ZGSetStackPointerFromGeneralThreadState(threadState, thread, value);
	}
	else if ([registerName isEqualToString:@"pc"])
	{
		ZGMemoryAddress value = 0x0;
		memcpy(&value, rawValue, MIN(size, sizeof(value)));
		
		return ZGSetInstructionPointerFromGeneralThreadState(threadState, thread, value, ZGProcessTypeARM64);
	}
	else if ([registerName isEqualToString:@"cpsr"])
	{
		memcpy((uint32_t *)&threadState->__cpsr, rawValue, MIN(size, sizeof(threadState->__cpsr)));
		return YES;
	}
	else
	{
		return NO;
	}
}

+ (BOOL)changeVectorThreadState:(zg_vector_state_t *)vectorState thread:(thread_act_t)thread registerName:(NSString *)registerName value:(const void *)rawValue size:(size_t)size
{
	NSArray<NSString *> *vectorRegisters = @[@"v0", @"v1", @"v2", @"v3", @"v4", @"v5", @"v6", @"v7", @"v8", @"v9", @"v10", @"v11", @"v12", @"v13", @"v14", @"v15", @"v16", @"v17", @"v18", @"v19", @"v20", @"v21", @"v22", @"v23", @"v24", @"v25", @"v26", @"v27", @"v28", @"v29", @"v30", @"v31"];
	
	if ([vectorRegisters containsObject:registerName])
	{
		memcpy((uint64_t *)&vectorState->__v + [vectorRegisters indexOfObject:registerName], rawValue, MIN(size, sizeof(vectorState->__v)));
		return YES;
	}
	else if ([registerName isEqualToString:@"fpsr"])
	{
		memcpy((uint32_t *)&vectorState->__fpsr, rawValue, MIN(size, sizeof(vectorState->__fpsr)));
		return YES;
	}
	else if ([registerName isEqualToString:@"fpcr"])
	{
		memcpy((uint32_t *)&vectorState->__fpcr, rawValue, MIN(size, sizeof(vectorState->__fpcr)));
		return YES;
	}
	else
	{
		return NO;
	}
}

+ (NSArray<ZGVariable *> *)registerVariablesFromVectorThreadState:(zg_vector_state_t)vectorState processType:(ZGProcessType)processType hasAVXSupport:(BOOL)hasAVXSupport
{
	NSMutableArray<ZGVariable *> *registerVariables = [[NSMutableArray alloc] init];
	
	ZGRegisterEntry entries[64];
	[ZGRegisterEntries getRegisterEntries:entries fromVectorThreadState:vectorState processType:processType hasAVXSupport:hasAVXSupport];
	
	for (ZGRegisterEntry *entry = entries; !ZG_REGISTER_ENTRY_IS_NULL(entry); entry++)
	{
		ZGVariable *variable =
		[[ZGVariable alloc]
		 initWithValue:entry->value
		 size:entry->size
		 address:0
		 type:ZGByteArray
		 qualifier:0
		 pointerSize:ZG_PROCESS_POINTER_SIZE(processType)
		 description:[[NSAttributedString alloc] initWithString:ZGUnwrapNullableObject(@(entry->name))]];
		
		[registerVariables addObject:variable];
	}
	
	return registerVariables;
}

+ (NSArray<ZGVariable *> *)registerVariablesFromGeneralPurposeThreadState:(zg_thread_state_t)threadState processType:(ZGProcessType)processType
{
	NSMutableArray<ZGVariable *> *registerVariables = [[NSMutableArray alloc] init];
	
	ZGRegisterEntry entries[ZG_MAX_REGISTER_ENTRIES];
	[ZGRegisterEntries getRegisterEntries:entries fromGeneralPurposeThreadState:threadState processType:processType];
	
	for (ZGRegisterEntry *entry = entries; !ZG_REGISTER_ENTRY_IS_NULL(entry); entry++)
	{
		ZGVariable *variable =
		[[ZGVariable alloc]
		 initWithValue:entry->value
		 size:entry->size
		 address:0
		 type:ZGByteArray
		 qualifier:0
		 pointerSize:ZG_PROCESS_POINTER_SIZE(processType)
		 description:[[NSAttributedString alloc] initWithString:ZGUnwrapNullableObject(@(entry->name))]];
		
		[registerVariables addObject:variable];
	}
	
	return registerVariables;
}

@end
