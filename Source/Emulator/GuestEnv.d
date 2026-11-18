/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * cpu
*/

module Source.Emulator.GuestEnv;

// Std
import core.time : MonoTime;

// Core
import Source.Memory.Guest;
import Source.Wrapper.Dynarmic;
import Source.Wrapper.DynarmicJit;

enum ulong Freq = 19_200_000;

// Types
enum HaltReason SvcHalt = HaltReason.UserDefined2;
enum HaltReason ExitHalt = HaltReason.UserDefined3;
enum HaltReason GuestExceptionHalt = HaltReason.UserDefined4;

// Class
final class GuestEnvironment : DynarmicCallbacks {
    GuestMemory Memory;
    DynarmicJit Jit;
    DynarmicMonitor Monitor;

    ulong TpidrroEl0;
    ulong TpidrEl0;
    ulong ReturnAddress;

    uint PreviousSvc;
    bool Exited;
    ulong ExceptionPC;
    DynarmicException LastException;

    private MonoTime startTime;

    this(GuestMemory memory) {
        Memory = memory;
        startTime = MonoTime.currTime;
    }

    DynarmicConfig CreateConfig() {
        DynarmicConfig config = DefaultDynarmicConfig();
        config.CntfrqEl0 = cast(uint) Freq;
        config.TpidrroEl0 = &TpidrroEl0;
        config.TpidrEl0 = &TpidrEl0;
        config.EnableCycleCounting = false;
        return config;
    }

    DynarmicJit CreateJit() {
        Monitor = new DynarmicMonitor(1);
        Jit = new DynarmicJit(this, CreateConfig(), Monitor);
        return Jit;
    }

    override bool MemoryReadCode(ulong vaddr, out uint value) {
        return Memory.TryFetch(vaddr, value);
    }

    override ubyte MemoryRead8(ulong vaddr) {
        return Memory.Read!ubyte(vaddr);
    }

    override ushort MemoryRead16(ulong vaddr) {
        return Memory.Read!ushort(vaddr);
    }

    override uint MemoryRead32(ulong vaddr) {
        return Memory.Read!uint(vaddr);
    }

    override ulong MemoryRead64(ulong vaddr) {
        return Memory.Read!ulong(vaddr);
    }

    override Vector128 MemoryRead128(ulong vaddr) {
        return [Memory.Read!ulong(vaddr), Memory.Read!ulong(vaddr + 8)];
    }

    override void MemoryWrite8(ulong vaddr, ubyte value) {
        Memory.Write(vaddr, value);
    }

    override void MemoryWrite16(ulong vaddr, ushort value) {
        Memory.Write(vaddr, value);
    }

    override void MemoryWrite32(ulong vaddr, uint value) {
        Memory.Write(vaddr, value);
    }

    override void MemoryWrite64(ulong vaddr, ulong value) {
        Memory.Write(vaddr, value);
    }

    override void MemoryWrite128(ulong vaddr, Vector128 value) {
        Memory.Write(vaddr, value[0]);
        Memory.Write(vaddr + 8, value[1]);
    }

    override bool IsReadOnlyMemory(ulong vaddr) {
        MemoryRegion region = Memory.Find(vaddr);
        return region !is null && (region.Permission & MemoryPermission.Write) == 0;
    }

    override void InterpreterFallback(ulong pc, size_t instructionCount) {
        throw new Exception("fallback!!");
    }

    override void CallSvc(uint swi) {
        PreviousSvc = swi;
        Jit.HaltExecution(SvcHalt);
    }

    override void ExceptionRaised(ulong pc, DynarmicException exception) {
        if (exception == DynarmicException.NoExecuteFault && pc == ReturnAddress) {
            Exited = true;
            Jit.HaltExecution(ExitHalt);
            return;
        }

        ExceptionPC = pc;
        LastException = exception;
        Jit.HaltExecution(GuestExceptionHalt);
    }

    override ulong GetCntpct() {
        long dur = (MonoTime.currTime - startTime).total!"hnsecs";
        return cast(ulong) dur * (Freq / 1_000) / 10_000;
    }
}
