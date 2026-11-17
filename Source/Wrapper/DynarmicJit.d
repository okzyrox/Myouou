/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * The D interface to the JIT for Dynarmic.
*/

module Source.Wrapper.DynarmicJit;

import Source.Wrapper.Dynarmic;

alias DynarmicConfig = MyououDynarmicConfig;
alias Vector128 = ulong[2];

enum HaltReason CallbackErrorHalt = HaltReason.UserDefined8;

DynarmicConfig DefaultDynarmicConfig() nothrow @nogc {
    DynarmicConfig config;
    MyououDynarmicDefaultConfig(&config);
    return config;
}

class DynarmicError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

abstract class DynarmicCallbacks {
    bool MemoryReadCode(ulong vaddr, out uint value) {
        value = MemoryRead32(vaddr);
        return true;
    }

    abstract ubyte MemoryRead8(ulong vaddr);
    abstract ushort MemoryRead16(ulong vaddr);
    abstract uint MemoryRead32(ulong vaddr);
    abstract ulong MemoryRead64(ulong vaddr);
    abstract Vector128 MemoryRead128(ulong vaddr);

    abstract void MemoryWrite8(ulong vaddr, ubyte value);
    abstract void MemoryWrite16(ulong vaddr, ushort value);
    abstract void MemoryWrite32(ulong vaddr, uint value);
    abstract void MemoryWrite64(ulong vaddr, ulong value);
    abstract void MemoryWrite128(ulong vaddr, Vector128 value);

    bool MemoryWriteExclusive8(ulong vaddr, ubyte value, ubyte expected) {
        if (MemoryRead8(vaddr) != expected)
            return false;
        MemoryWrite8(vaddr, value);
        return true;
    }

    bool MemoryWriteExclusive16(ulong vaddr, ushort value, ushort expected) {
        if (MemoryRead16(vaddr) != expected)
            return false;
        MemoryWrite16(vaddr, value);
        return true;
    }

    bool MemoryWriteExclusive32(ulong vaddr, uint value, uint expected) {
        if (MemoryRead32(vaddr) != expected)
            return false;
        MemoryWrite32(vaddr, value);
        return true;
    }

    bool MemoryWriteExclusive64(ulong vaddr, ulong value, ulong expected) {
        if (MemoryRead64(vaddr) != expected)
            return false;
        MemoryWrite64(vaddr, value);
        return true;
    }

    bool MemoryWriteExclusive128(ulong vaddr, Vector128 value, Vector128 expected) {
        if (MemoryRead128(vaddr) != expected)
            return false;
        MemoryWrite128(vaddr, value);
        return true;
    }

    bool IsReadOnlyMemory(ulong vaddr) {
        return false;
    }

    abstract void InterpreterFallback(ulong pc, size_t instructionCount);
    abstract void CallSvc(uint swi);
    abstract void ExceptionRaised(ulong pc, DynarmicException exception);

    void DataCacheOperationRaised(DataCacheOperation operation, ulong value) {
    }

    void InstructionCacheOperationRaised(InstructionCacheOperation operation, ulong value) {
    }

    void InstructionSynchronizationBarrierRaised() {
    }

    void AddTicks(ulong ticks) {
    }

    ulong GetTicksRemaining() {
        return ulong.max;
    }

    ulong GetCntpct() {
        return 0;
    }
}

final class DynarmicMonitor {
    private MyououDynarmicMonitor* handle;

    this(size_t processorCount) {
        handle = MyououDynarmicMonitorCreate(processorCount);
        if (handle is null)
            throw new DynarmicError("Failed to create dynarmic exclusive monitor");
    }

    ~this() {
        Dispose();
    }

    void Dispose() nothrow @nogc {
        if (handle is null)
            return;
        MyououDynarmicMonitorDestroy(handle);
        handle = null;
    }

    MyououDynarmicMonitor* Handle() nothrow @nogc {
        return handle;
    }

    size_t ProcessorCount() const nothrow @nogc {
        return MyououDynarmicMonitorGetProcessorCount(handle);
    }

    void Clear() nothrow @nogc {
        MyououDynarmicMonitorClear(handle);
    }

    void ClearProcessor(size_t processorId) nothrow @nogc {
        MyououDynarmicMonitorClearProcessor(handle, processorId);
    }
}

final class DynarmicJit {
    private MyououDynarmicJit* handle;
    private DynarmicCallbacks callbacks;
    private DynarmicMonitor monitor;
    private Throwable currentError;

    this(DynarmicCallbacks callbacks, DynarmicMonitor monitor = null) {
        this(callbacks, DefaultDynarmicConfig(), monitor);
    }

    this(DynarmicCallbacks callbacks, DynarmicConfig config, DynarmicMonitor monitor = null) {
        if (callbacks is null)
            throw new DynarmicError("Dynarmic callbacks must not be null");

        this.callbacks = callbacks;
        this.monitor = monitor;
        if (monitor !is null)
            config.GlobalMonitor = monitor.Handle;

        MyououDynarmicCallbacks native = CreateNativeCallbacks(cast(void*) this);
        handle = MyououDynarmicCreate(&config, &native);
        if (handle is null)
            throw new DynarmicError("Failed to create dynarmic JIT");
    }

    ~this() {
        Dispose();
    }

    void Dispose() nothrow @nogc {
        if (handle is null)
            return;
        MyououDynarmicDestroy(handle);
        handle = null;
    }

    DynarmicCallbacks Callbacks() nothrow @nogc {
        return callbacks;
    }

    HaltReason Run() {
        return Finish(cast(HaltReason) MyououDynarmicRun(handle));
    }

    HaltReason Step() {
        return Finish(cast(HaltReason) MyououDynarmicStep(handle));
    }

    void ClearCache() nothrow @nogc {
        MyououDynarmicClearCache(handle);
    }

    void InvalidateCacheRange(ulong startAddress, size_t length) nothrow @nogc {
        MyououDynarmicInvalidateCacheRange(handle, startAddress, length);
    }

    void Reset() nothrow @nogc {
        MyououDynarmicReset(handle);
    }

    void HaltExecution(HaltReason reason = HaltReason.UserDefined1) nothrow @nogc {
        MyououDynarmicHaltExecution(handle, reason);
    }

    void ClearHalt(HaltReason reason = HaltReason.UserDefined1) nothrow @nogc {
        MyououDynarmicClearHalt(handle, reason);
    }

    ulong Sp() const nothrow @nogc {
        return MyououDynarmicGetSP(handle);
    }

    void Sp(ulong value) nothrow @nogc {
        MyououDynarmicSetSP(handle, value);
    }

    ulong Pc() const nothrow @nogc {
        return MyououDynarmicGetPC(handle);
    }

    void Pc(ulong value) nothrow @nogc {
        MyououDynarmicSetPC(handle, value);
    }

    ulong Register(size_t index) const nothrow @nogc
    in (index < 31) {
        return MyououDynarmicGetRegister(handle, index);
    }

    void Register(size_t index, ulong value) nothrow @nogc
    in (index < 31) {
        MyououDynarmicSetRegister(handle, index, value);
    }

    ulong[31] Registers() const nothrow @nogc {
        ulong[31] values;
        MyououDynarmicGetRegisters(handle, values.ptr);
        return values;
    }

    void Registers(const ref ulong[31] values) nothrow @nogc {
        MyououDynarmicSetRegisters(handle, values.ptr);
    }

    Vector128 Vector(size_t index) const nothrow @nogc
    in (index < 32) {
        Vector128 value;
        MyououDynarmicGetVector(handle, index, value.ptr);
        return value;
    }

    void Vector(size_t index, Vector128 value) nothrow @nogc
    in (index < 32) {
        MyououDynarmicSetVector(handle, index, value.ptr);
    }

    Vector128[32] Vectors() const nothrow @nogc {
        Vector128[32] values;
        MyououDynarmicGetVectors(handle, values[0].ptr);
        return values;
    }

    void Vectors(const ref Vector128[32] values) nothrow @nogc {
        MyououDynarmicSetVectors(handle, values[0].ptr);
    }

    uint Fpcr() const nothrow @nogc {
        return MyououDynarmicGetFpcr(handle);
    }

    void Fpcr(uint value) nothrow @nogc {
        MyououDynarmicSetFpcr(handle, value);
    }

    uint Fpsr() const nothrow @nogc {
        return MyououDynarmicGetFpsr(handle);
    }

    void Fpsr(uint value) nothrow @nogc {
        MyououDynarmicSetFpsr(handle, value);
    }

    uint Pstate() const nothrow @nogc {
        return MyououDynarmicGetPstate(handle);
    }

    void Pstate(uint value) nothrow @nogc {
        MyououDynarmicSetPstate(handle, value);
    }

    void ClearExclusiveState() nothrow @nogc {
        MyououDynarmicClearExclusiveState(handle);
    }

    bool IsExecuting() const nothrow @nogc {
        return MyououDynarmicIsExecuting(handle);
    }

    void DumpDisassembly() const nothrow @nogc {
        MyououDynarmicDumpDisassembly(handle);
    }

    string[] Disassemble() const {
        string[] lines;
        MyououDynarmicDisassemble(handle, &CollectLine, &lines);
        return lines;
    }

    private HaltReason Finish(HaltReason reason) {
        if (currentError is null)
            return reason;

        Throwable error = currentError;
        currentError = null;
        MyououDynarmicClearHalt(handle, CallbackErrorHalt);
        throw error;
    }

    private void Fault(Throwable error) nothrow @nogc {
        if (currentError is null)
            currentError = error;
        MyououDynarmicHaltExecution(handle, CallbackErrorHalt);
    }
}

private MyououDynarmicCallbacks CreateNativeCallbacks(void* userData) nothrow @nogc {
    MyououDynarmicCallbacks native;
    native.UserData = userData;
    native.MemoryReadCode = &ThunkMemoryReadCode;
    native.MemoryRead8 = &ThunkMemoryRead8;
    native.MemoryRead16 = &ThunkMemoryRead16;
    native.MemoryRead32 = &ThunkMemoryRead32;
    native.MemoryRead64 = &ThunkMemoryRead64;
    native.MemoryRead128 = &ThunkMemoryRead128;
    native.MemoryWrite8 = &ThunkMemoryWrite8;
    native.MemoryWrite16 = &ThunkMemoryWrite16;
    native.MemoryWrite32 = &ThunkMemoryWrite32;
    native.MemoryWrite64 = &ThunkMemoryWrite64;
    native.MemoryWrite128 = &ThunkMemoryWrite128;
    native.MemoryWriteExclusive8 = &ThunkMemoryWriteExclusive8;
    native.MemoryWriteExclusive16 = &ThunkMemoryWriteExclusive16;
    native.MemoryWriteExclusive32 = &ThunkMemoryWriteExclusive32;
    native.MemoryWriteExclusive64 = &ThunkMemoryWriteExclusive64;
    native.MemoryWriteExclusive128 = &ThunkMemoryWriteExclusive128;
    native.IsReadOnlyMemory = &ThunkIsReadOnlyMemory;
    native.InterpreterFallback = &ThunkInterpreterFallback;
    native.CallSvc = &ThunkCallSvc;
    native.ExceptionRaised = &ThunkExceptionRaised;
    native.DataCacheOperationRaised = &ThunkDataCacheOperationRaised;
    native.InstructionCacheOperationRaised = &ThunkInstructionCacheOperationRaised;
    native.InstructionSynchronizationBarrierRaised = &ThunkInstructionSynchronizationBarrierRaised;
    native.AddTicks = &ThunkAddTicks;
    native.GetTicksRemaining = &ThunkGetTicksRemaining;
    native.GetCntpct = &ThunkGetCntpct;
    return native;
}

private T Guarded(T)(void* userData, scope T delegate(DynarmicCallbacks) action) nothrow {
    DynarmicJit jit = cast(DynarmicJit) userData;
    try {
        return action(jit.callbacks);
    }
    catch (Throwable error) { // bad
        jit.Fault(error);
        static if (!is(T == void))
            return T.init;
    }
}

extern (C) nothrow {
    // Guarded aliases.
    private bool ThunkMemoryReadCode(void* userData, ulong vaddr, uint* outValue) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryReadCode(vaddr, *outValue));
    }

    private ubyte ThunkMemoryRead8(void* userData, ulong vaddr) {
        return Guarded!ubyte(userData, (DynarmicCallbacks c) => c.MemoryRead8(vaddr));
    }

    private ushort ThunkMemoryRead16(void* userData, ulong vaddr) {
        return Guarded!ushort(userData, (DynarmicCallbacks c) => c.MemoryRead16(vaddr));
    }

    private uint ThunkMemoryRead32(void* userData, ulong vaddr) {
        return Guarded!uint(userData, (DynarmicCallbacks c) => c.MemoryRead32(vaddr));
    }

    private ulong ThunkMemoryRead64(void* userData, ulong vaddr) {
        return Guarded!ulong(userData, (DynarmicCallbacks c) => c.MemoryRead64(vaddr));
    }

    private void ThunkMemoryRead128(void* userData, ulong vaddr, ulong* outValue) {
        Vector128 value = Guarded!Vector128(userData, (DynarmicCallbacks c) => c.MemoryRead128(vaddr));
        outValue[0 .. 2] = value[];
    }

    private void ThunkMemoryWrite8(void* userData, ulong vaddr, ubyte value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.MemoryWrite8(vaddr, value));
    }

    private void ThunkMemoryWrite16(void* userData, ulong vaddr, ushort value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.MemoryWrite16(vaddr, value));
    }

    private void ThunkMemoryWrite32(void* userData, ulong vaddr, uint value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.MemoryWrite32(vaddr, value));
    }

    private void ThunkMemoryWrite64(void* userData, ulong vaddr, ulong value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.MemoryWrite64(vaddr, value));
    }

    private void ThunkMemoryWrite128(void* userData, ulong vaddr, const(ulong)* value) {
        Vector128 vector = value[0 .. 2];
        Guarded!void(userData, (DynarmicCallbacks c) => c.MemoryWrite128(vaddr, vector));
    }

    private bool ThunkMemoryWriteExclusive8(void* userData, ulong vaddr, ubyte value, ubyte expected) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryWriteExclusive8(vaddr, value, expected));
    }

    private bool ThunkMemoryWriteExclusive16(void* userData, ulong vaddr, ushort value, ushort expected) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryWriteExclusive16(vaddr, value, expected));
    }

    private bool ThunkMemoryWriteExclusive32(void* userData, ulong vaddr, uint value, uint expected) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryWriteExclusive32(vaddr, value, expected));
    }

    private bool ThunkMemoryWriteExclusive64(void* userData, ulong vaddr, ulong value, ulong expected) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryWriteExclusive64(vaddr, value, expected));
    }

    private bool ThunkMemoryWriteExclusive128(void* userData, ulong vaddr, const(ulong)* value, const(ulong)* expected) {
        Vector128 newValue = value[0 .. 2];
        Vector128 expectedValue = expected[0 .. 2];
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.MemoryWriteExclusive128(vaddr, newValue, expectedValue));
    }

    private bool ThunkIsReadOnlyMemory(void* userData, ulong vaddr) {
        return Guarded!bool(userData, (DynarmicCallbacks c) => c.IsReadOnlyMemory(vaddr));
    }

    private void ThunkInterpreterFallback(void* userData, ulong pc, size_t instructionCount) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.InterpreterFallback(pc, instructionCount));
    }

    private void ThunkCallSvc(void* userData, uint swi) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.CallSvc(swi));
    }

    private void ThunkExceptionRaised(void* userData, ulong pc, uint exception) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.ExceptionRaised(pc, cast(DynarmicException) exception));
    }

    private void ThunkDataCacheOperationRaised(void* userData, uint operation, ulong value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.DataCacheOperationRaised(cast(DataCacheOperation) operation, value));
    }

    private void ThunkInstructionCacheOperationRaised(void* userData, uint operation, ulong value) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.InstructionCacheOperationRaised(cast(InstructionCacheOperation) operation, value));
    }

    private void ThunkInstructionSynchronizationBarrierRaised(void* userData) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.InstructionSynchronizationBarrierRaised());
    }

    private void ThunkAddTicks(void* userData, ulong ticks) {
        Guarded!void(userData, (DynarmicCallbacks c) => c.AddTicks(ticks));
    }

    private ulong ThunkGetTicksRemaining(void* userData) {
        return Guarded!ulong(userData, (DynarmicCallbacks c) => c.GetTicksRemaining());
    }

    private ulong ThunkGetCntpct(void* userData) {
        return Guarded!ulong(userData, (DynarmicCallbacks c) => c.GetCntpct());
    }

    private void CollectLine(void* userData, const(char)* line, size_t length) {
        try {
            (*cast(string[]*) userData) ~= line[0 .. length].idup;
        }
        catch (Exception) {
        }
    }
}
