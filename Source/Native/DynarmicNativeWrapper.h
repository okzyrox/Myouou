/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 * 
 * The CPP side of the Dynarmic JIT Wrapper.
*/

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Microsoft Specifiers copied from Raylib :)
#if defined(_WIN32)
#if defined(MYOUOU_DYNARMIC_WRAPPER_H)
#define MYOUOU_DYNARMIC_API __declspec(dllexport) // building as ".dll"
#else
#define MYOUOU_DYNARMIC_API __declspec(dllimport) // using as ".dll"
#endif
#else
#define MYOUOU_DYNARMIC_API __attribute__((visibility("default"))) // unix ".so" / ".dylib"
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MyououDynarmicJit MyououDynarmicJit;
typedef struct MyououDynarmicMonitor MyououDynarmicMonitor;

typedef struct MyououDynarmicCallbacks {
    void* UserData;

    bool (*MemoryReadCode)(void* userData, uint64_t vaddr, uint32_t* outValue);

    uint8_t (*MemoryRead8)(void* userData, uint64_t vaddr);
    uint16_t (*MemoryRead16)(void* userData, uint64_t vaddr);
    uint32_t (*MemoryRead32)(void* userData, uint64_t vaddr);
    uint64_t (*MemoryRead64)(void* userData, uint64_t vaddr);
    void (*MemoryRead128)(void* userData, uint64_t vaddr, uint64_t* outValue);

    void (*MemoryWrite8)(void* userData, uint64_t vaddr, uint8_t value);
    void (*MemoryWrite16)(void* userData, uint64_t vaddr, uint16_t value);
    void (*MemoryWrite32)(void* userData, uint64_t vaddr, uint32_t value);
    void (*MemoryWrite64)(void* userData, uint64_t vaddr, uint64_t value);
    void (*MemoryWrite128)(void* userData, uint64_t vaddr, const uint64_t* value);

    bool (*MemoryWriteExclusive8)(void* userData, uint64_t vaddr, uint8_t value, uint8_t expected);
    bool (*MemoryWriteExclusive16)(void* userData, uint64_t vaddr, uint16_t value, uint16_t expected);
    bool (*MemoryWriteExclusive32)(void* userData, uint64_t vaddr, uint32_t value, uint32_t expected);
    bool (*MemoryWriteExclusive64)(void* userData, uint64_t vaddr, uint64_t value, uint64_t expected);
    bool (*MemoryWriteExclusive128)(void* userData, uint64_t vaddr, const uint64_t* value, const uint64_t* expected);

    bool (*IsReadOnlyMemory)(void* userData, uint64_t vaddr);

    void (*InterpreterFallback)(void* userData, uint64_t pc, size_t instructionCount);
    void (*CallSvc)(void* userData, uint32_t swi);
    void (*ExceptionRaised)(void* userData, uint64_t pc, uint32_t exception);
    void (*DataCacheOperationRaised)(void* userData, uint32_t operation, uint64_t value);
    void (*InstructionCacheOperationRaised)(void* userData, uint32_t operation, uint64_t value);
    void (*InstructionSynchronizationBarrierRaised)(void* userData);

    void (*AddTicks)(void* userData, uint64_t ticks);
    uint64_t (*GetTicksRemaining)(void* userData);
    uint64_t (*GetCntpct)(void* userData);
} MyououDynarmicCallbacks;

typedef struct MyououDynarmicConfig {
    size_t ProcessorId;
    MyououDynarmicMonitor* GlobalMonitor;

    uint32_t Optimizations;
    bool UnsafeOptimizations;

    bool HookDataCacheOperations;
    bool HookIsb;
    bool HookHintInstructions;

    uint32_t CntfrqEl0;
    uint32_t CtrEl0;
    uint32_t DczidEl0;

    const uint64_t* TpidrroEl0;
    uint64_t* TpidrEl0;

    void** PageTable;
    size_t PageTableAddressSpaceBits;
    int32_t PageTablePointerMaskBits;
    bool SilentlyMirrorPageTable;
    bool AbsoluteOffsetPageTable;
    uint8_t DetectMisalignedAccessViaPageTable;
    bool OnlyDetectMisalignmentViaPageTableOnPageBoundary;

    bool HasFastmemPointer;
    uintptr_t FastmemPointer;
    bool RecompileOnFastmemFailure;
    size_t FastmemAddressSpaceBits;
    bool SilentlyMirrorFastmem;
    bool FastmemExclusiveAccess;
    bool RecompileOnExclusiveFastmemFailure;

    bool DefineUnpredictableBehaviour;
    bool WallClockCntpct;
    bool CheckHaltOnMemoryAccess;
    bool EnableCycleCounting;

    size_t CodeCacheSize;
} MyououDynarmicConfig;

typedef void (*MyououDynarmicLineSink)(void* userData, const char* line, size_t length);

MYOUOU_DYNARMIC_API void MyououDynarmicDefaultConfig(MyououDynarmicConfig* outConfig);

MYOUOU_DYNARMIC_API MyououDynarmicJit* MyououDynarmicCreate(const MyououDynarmicConfig* config, const MyououDynarmicCallbacks* callbacks);
MYOUOU_DYNARMIC_API void MyououDynarmicDestroy(MyououDynarmicJit* jit);

MYOUOU_DYNARMIC_API uint32_t MyououDynarmicRun(MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API uint32_t MyououDynarmicStep(MyououDynarmicJit* jit);

MYOUOU_DYNARMIC_API void MyououDynarmicClearCache(MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicInvalidateCacheRange(MyououDynarmicJit* jit, uint64_t startAddress, size_t length);
MYOUOU_DYNARMIC_API void MyououDynarmicReset(MyououDynarmicJit* jit);

MYOUOU_DYNARMIC_API void MyououDynarmicHaltExecution(MyououDynarmicJit* jit, uint32_t haltReason);
MYOUOU_DYNARMIC_API void MyououDynarmicClearHalt(MyououDynarmicJit* jit, uint32_t haltReason);

MYOUOU_DYNARMIC_API uint64_t MyououDynarmicGetSP(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicSetSP(MyououDynarmicJit* jit, uint64_t value);
MYOUOU_DYNARMIC_API uint64_t MyououDynarmicGetPC(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicSetPC(MyououDynarmicJit* jit, uint64_t value);

MYOUOU_DYNARMIC_API uint64_t MyououDynarmicGetRegister(const MyououDynarmicJit* jit, size_t index);
MYOUOU_DYNARMIC_API void MyououDynarmicSetRegister(MyououDynarmicJit* jit, size_t index, uint64_t value);
MYOUOU_DYNARMIC_API void MyououDynarmicGetRegisters(const MyououDynarmicJit* jit, uint64_t* outValues);
MYOUOU_DYNARMIC_API void MyououDynarmicSetRegisters(MyououDynarmicJit* jit, const uint64_t* values);

MYOUOU_DYNARMIC_API void MyououDynarmicGetVector(const MyououDynarmicJit* jit, size_t index, uint64_t* outValue);
MYOUOU_DYNARMIC_API void MyououDynarmicSetVector(MyououDynarmicJit* jit, size_t index, const uint64_t* value);
MYOUOU_DYNARMIC_API void MyououDynarmicGetVectors(const MyououDynarmicJit* jit, uint64_t* outValues);
MYOUOU_DYNARMIC_API void MyououDynarmicSetVectors(MyououDynarmicJit* jit, const uint64_t* values);

MYOUOU_DYNARMIC_API uint32_t MyououDynarmicGetFpcr(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicSetFpcr(MyououDynarmicJit* jit, uint32_t value);
MYOUOU_DYNARMIC_API uint32_t MyououDynarmicGetFpsr(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicSetFpsr(MyououDynarmicJit* jit, uint32_t value);
MYOUOU_DYNARMIC_API uint32_t MyououDynarmicGetPstate(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicSetPstate(MyououDynarmicJit* jit, uint32_t value);

MYOUOU_DYNARMIC_API void MyououDynarmicClearExclusiveState(MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API bool MyououDynarmicIsExecuting(const MyououDynarmicJit* jit);

MYOUOU_DYNARMIC_API void MyououDynarmicDumpDisassembly(const MyououDynarmicJit* jit);
MYOUOU_DYNARMIC_API void MyououDynarmicDisassemble(const MyououDynarmicJit* jit, MyououDynarmicLineSink sink, void* userData);

MYOUOU_DYNARMIC_API MyououDynarmicMonitor* MyououDynarmicMonitorCreate(size_t processorCount);
MYOUOU_DYNARMIC_API void MyououDynarmicMonitorDestroy(MyououDynarmicMonitor* monitor);
MYOUOU_DYNARMIC_API size_t MyououDynarmicMonitorGetProcessorCount(const MyououDynarmicMonitor* monitor);
MYOUOU_DYNARMIC_API void MyououDynarmicMonitorClear(MyououDynarmicMonitor* monitor);
MYOUOU_DYNARMIC_API void MyououDynarmicMonitorClearProcessor(MyououDynarmicMonitor* monitor, size_t processorId);

#ifdef __cplusplus
}
#endif
