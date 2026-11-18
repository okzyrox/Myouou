/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * The D interface to the Dynarmic Wrapper.
*/

module Source.Wrapper.Dynarmic;

// Types
enum HaltReason : uint {
    None = 0x00000000,
    Step = 0x00000001,
    CacheInvalidation = 0x00000002,
    MemoryAbort = 0x00000004,
    UserDefined1 = 0x01000000,
    UserDefined2 = 0x02000000,
    UserDefined3 = 0x04000000,
    UserDefined4 = 0x08000000,
    UserDefined5 = 0x10000000,
    UserDefined6 = 0x20000000,
    UserDefined7 = 0x40000000,
    UserDefined8 = 0x80000000,
}

enum DynarmicException : uint {
    UnallocatedEncoding,
    ReservedValue,
    UnpredictableInstruction,
    WaitForInterrupt,
    WaitForEvent,
    SendEvent,
    SendEventLocal,
    Yield,
    Breakpoint,
    NoExecuteFault,
}

enum DataCacheOperation : uint {
    CleanAndInvalidateBySetWay,
    CleanAndInvalidateByVAToPoC,
    CleanBySetWay,
    CleanByVAToPoC,
    CleanByVAToPoU,
    CleanByVAToPoP,
    InvalidateBySetWay,
    InvalidateByVAToPoC,
    ZeroByVA,
}

enum InstructionCacheOperation : uint {
    InvalidateByVAToPoU,
    InvalidateAllToPoU,
    InvalidateAllToPoUInnerSharable,
}

enum OptimizationFlag : uint {
    None = 0x00000000,
    BlockLinking = 0x00000001,
    ReturnStackBuffer = 0x00000002,
    FastDispatch = 0x00000004,
    GetSetElimination = 0x00000008,
    ConstProp = 0x00000010,
    MiscIROpt = 0x00000020,
    AllSafe = 0x0000FFFF,
    UnsafeUnfuseFma = 0x00010000,
    UnsafeReducedErrorFp = 0x00020000,
    UnsafeInaccurateNaN = 0x00040000,
    UnsafeIgnoreStandardFpcrValue = 0x00080000,
    UnsafeIgnoreGlobalMonitor = 0x00100000,
}

// Utils
bool Has(HaltReason reasons, HaltReason reason) pure nothrow @nogc @safe {
    return (reasons & reason) != 0;
}

// Externs

struct MyououDynarmicJit;
struct MyououDynarmicMonitor;

extern (C) nothrow {
    alias MemoryReadCodeFn = bool function(void* userData, ulong vaddr, uint* outValue);
    alias MemoryRead8Fn = ubyte function(void* userData, ulong vaddr);
    alias MemoryRead16Fn = ushort function(void* userData, ulong vaddr);
    alias MemoryRead32Fn = uint function(void* userData, ulong vaddr);
    alias MemoryRead64Fn = ulong function(void* userData, ulong vaddr);
    alias MemoryRead128Fn = void function(void* userData, ulong vaddr, ulong* outValue);
    alias MemoryWrite8Fn = void function(void* userData, ulong vaddr, ubyte value);
    alias MemoryWrite16Fn = void function(void* userData, ulong vaddr, ushort value);
    alias MemoryWrite32Fn = void function(void* userData, ulong vaddr, uint value);
    alias MemoryWrite64Fn = void function(void* userData, ulong vaddr, ulong value);
    alias MemoryWrite128Fn = void function(void* userData, ulong vaddr, const(ulong)* value);
    alias MemoryWriteExclusive8Fn = bool function(void* userData, ulong vaddr, ubyte value, ubyte expected);
    alias MemoryWriteExclusive16Fn = bool function(void* userData, ulong vaddr, ushort value, ushort expected);
    alias MemoryWriteExclusive32Fn = bool function(void* userData, ulong vaddr, uint value, uint expected);
    alias MemoryWriteExclusive64Fn = bool function(void* userData, ulong vaddr, ulong value, ulong expected);
    alias MemoryWriteExclusive128Fn = bool function(void* userData, ulong vaddr, const(ulong)* value, const(ulong)* expected);
    alias IsReadOnlyMemoryFn = bool function(void* userData, ulong vaddr);
    alias InterpreterFallbackFn = void function(void* userData, ulong pc, size_t instructionCount);
    alias CallSvcFn = void function(void* userData, uint swi);
    alias ExceptionRaisedFn = void function(void* userData, ulong pc, uint exception);
    alias CacheOperationRaisedFn = void function(void* userData, uint operation, ulong value);
    alias InstructionSynchronizationBarrierRaisedFn = void function(void* userData);
    alias AddTicksFn = void function(void* userData, ulong ticks);
    alias GetTicksFn = ulong function(void* userData);
    alias LineSinkFn = void function(void* userData, const(char)* line, size_t length);
}

struct MyououDynarmicCallbacks {
    void* UserData;

    MemoryReadCodeFn MemoryReadCode;

    MemoryRead8Fn MemoryRead8;
    MemoryRead16Fn MemoryRead16;
    MemoryRead32Fn MemoryRead32;
    MemoryRead64Fn MemoryRead64;
    MemoryRead128Fn MemoryRead128;

    MemoryWrite8Fn MemoryWrite8;
    MemoryWrite16Fn MemoryWrite16;
    MemoryWrite32Fn MemoryWrite32;
    MemoryWrite64Fn MemoryWrite64;
    MemoryWrite128Fn MemoryWrite128;

    MemoryWriteExclusive8Fn MemoryWriteExclusive8;
    MemoryWriteExclusive16Fn MemoryWriteExclusive16;
    MemoryWriteExclusive32Fn MemoryWriteExclusive32;
    MemoryWriteExclusive64Fn MemoryWriteExclusive64;
    MemoryWriteExclusive128Fn MemoryWriteExclusive128;

    IsReadOnlyMemoryFn IsReadOnlyMemory;

    InterpreterFallbackFn InterpreterFallback;
    CallSvcFn CallSvc;
    ExceptionRaisedFn ExceptionRaised;
    CacheOperationRaisedFn DataCacheOperationRaised;
    CacheOperationRaisedFn InstructionCacheOperationRaised;
    InstructionSynchronizationBarrierRaisedFn InstructionSynchronizationBarrierRaised;

    AddTicksFn AddTicks;
    GetTicksFn GetTicksRemaining;
    GetTicksFn GetCntpct;
}

struct MyououDynarmicConfig {
    size_t ProcessorId;
    MyououDynarmicMonitor* GlobalMonitor;

    uint Optimizations;
    bool UnsafeOptimizations;

    bool HookDataCacheOperations;
    bool HookIsb;
    bool HookHintInstructions;

    uint CntfrqEl0;
    uint CtrEl0;
    uint DczidEl0;

    const(ulong)* TpidrroEl0;
    ulong* TpidrEl0;

    void** PageTable;
    size_t PageTableAddressSpaceBits;
    int PageTablePointerMaskBits;
    bool SilentlyMirrorPageTable;
    bool AbsoluteOffsetPageTable;
    ubyte DetectMisalignedAccessViaPageTable;
    bool OnlyDetectMisalignmentViaPageTableOnPageBoundary;

    bool HasFastmemPointer;
    size_t FastmemPointer;
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
}

extern (C) nothrow @nogc {
    void MyououDynarmicDefaultConfig(MyououDynarmicConfig* outConfig);

    MyououDynarmicJit* MyououDynarmicCreate(const(MyououDynarmicConfig)* config, const(MyououDynarmicCallbacks)* callbacks);
    void MyououDynarmicDestroy(MyououDynarmicJit* jit);

    uint MyououDynarmicRun(MyououDynarmicJit* jit);
    uint MyououDynarmicStep(MyououDynarmicJit* jit);

    void MyououDynarmicClearCache(MyououDynarmicJit* jit);
    void MyououDynarmicInvalidateCacheRange(MyououDynarmicJit* jit, ulong startAddress, size_t length);
    void MyououDynarmicReset(MyououDynarmicJit* jit);

    void MyououDynarmicHaltExecution(MyououDynarmicJit* jit, uint haltReason);
    void MyououDynarmicClearHalt(MyououDynarmicJit* jit, uint haltReason);

    ulong MyououDynarmicGetSP(const(MyououDynarmicJit)* jit);
    void MyououDynarmicSetSP(MyououDynarmicJit* jit, ulong value);
    ulong MyououDynarmicGetPC(const(MyououDynarmicJit)* jit);
    void MyououDynarmicSetPC(MyououDynarmicJit* jit, ulong value);

    ulong MyououDynarmicGetRegister(const(MyououDynarmicJit)* jit, size_t index);
    void MyououDynarmicSetRegister(MyououDynarmicJit* jit, size_t index, ulong value);
    void MyououDynarmicGetRegisters(const(MyououDynarmicJit)* jit, ulong* outValues);
    void MyououDynarmicSetRegisters(MyououDynarmicJit* jit, const(ulong)* values);

    void MyououDynarmicGetVector(const(MyououDynarmicJit)* jit, size_t index, ulong* outValue);
    void MyououDynarmicSetVector(MyououDynarmicJit* jit, size_t index, const(ulong)* value);
    void MyououDynarmicGetVectors(const(MyououDynarmicJit)* jit, ulong* outValues);
    void MyououDynarmicSetVectors(MyououDynarmicJit* jit, const(ulong)* values);

    uint MyououDynarmicGetFpcr(const(MyououDynarmicJit)* jit);
    void MyououDynarmicSetFpcr(MyououDynarmicJit* jit, uint value);
    uint MyououDynarmicGetFpsr(const(MyououDynarmicJit)* jit);
    void MyououDynarmicSetFpsr(MyououDynarmicJit* jit, uint value);
    uint MyououDynarmicGetPstate(const(MyououDynarmicJit)* jit);
    void MyououDynarmicSetPstate(MyououDynarmicJit* jit, uint value);

    void MyououDynarmicClearExclusiveState(MyououDynarmicJit* jit);
    bool MyououDynarmicIsExecuting(const(MyououDynarmicJit)* jit);

    void MyououDynarmicDumpDisassembly(const(MyououDynarmicJit)* jit);
    void MyououDynarmicDisassemble(const(MyououDynarmicJit)* jit, LineSinkFn sink, void* userData);

    MyououDynarmicMonitor* MyououDynarmicMonitorCreate(size_t processorCount);
    void MyououDynarmicMonitorDestroy(MyououDynarmicMonitor* monitor);
    size_t MyououDynarmicMonitorGetProcessorCount(const(MyououDynarmicMonitor)* monitor);
    void MyououDynarmicMonitorClear(MyououDynarmicMonitor* monitor);
    void MyououDynarmicMonitorClearProcessor(MyououDynarmicMonitor* monitor, size_t processorId);
}
