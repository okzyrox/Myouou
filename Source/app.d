/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * 
*/

// Std
import std.stdio;

// Deps
import bindbc.sdl;

// Core
import Source.Wrapper.Dynarmic;
import Source.Wrapper.DynarmicJit;

final class TestEnvironment : DynarmicCallbacks {
    ulong RemainingTicks;

    // Memory 
    ubyte[4096] Memory;
    private T LoadMem(T)(ulong vaddr) {
        if (vaddr + T.sizeof > Memory.length)
            return 0;
        return *cast(T*) &Memory[vaddr];
    }

    private void StoreMem(T)(ulong vaddr, T value) {
        if (vaddr + T.sizeof > Memory.length)
            return;
        *cast(T*) &Memory[vaddr] = value;
    }

    // Callbacks
    override ubyte MemoryRead8(ulong vaddr) {
        return LoadMem!ubyte(vaddr);
    }
    override ushort MemoryRead16(ulong vaddr) {
        return LoadMem!ushort(vaddr);
    }
    override uint MemoryRead32(ulong vaddr) {
        return LoadMem!uint(vaddr);
    }
    override ulong MemoryRead64(ulong vaddr) {
        return LoadMem!ulong(vaddr);
    }
    override Vector128 MemoryRead128(ulong vaddr) {
        return [LoadMem!ulong(vaddr), LoadMem!ulong(vaddr + 8)];
    }

    override void MemoryWrite8(ulong vaddr, ubyte value) {
        StoreMem(vaddr, value);
    }
    override void MemoryWrite16(ulong vaddr, ushort value) {
        StoreMem(vaddr, value);
    }
    override void MemoryWrite32(ulong vaddr, uint value) {
        StoreMem(vaddr, value);
    }
    override void MemoryWrite64(ulong vaddr, ulong value) {
        StoreMem(vaddr, value);
    }
    override void MemoryWrite128(ulong vaddr, Vector128 value) {
        StoreMem(vaddr, value[0]);
        StoreMem(vaddr + 8, value[1]);
    }

    override void InterpreterFallback(ulong pc, size_t instructionCount) {
        assert(false, "fallback somehow!");
    }

    override void CallSvc(uint swi) {
        // do nothing
    }

    override void ExceptionRaised(ulong pc, DynarmicException exception) {
        // do something
    }

    override void AddTicks(ulong ticks) {
        RemainingTicks = ticks > RemainingTicks ? 0 : RemainingTicks - ticks;
    }

    override ulong GetTicksRemaining() {
        return RemainingTicks;
    }
}

void main() {
    TestEnvironment env = new TestEnvironment();
    DynarmicJit cpu = new DynarmicJit(env);
    env.RemainingTicks = 1;

    env.MemoryWrite32(0, 0xD37EF420);
    env.MemoryWrite32(4, 0x14000000);

    cpu.Register(0, 1);
    cpu.Register(1, 3);
    cpu.Pc = 0;

    cpu.Run();
    writefln("r0: %d", cpu.Register(0)); //r1 * 4
    writefln("r1: %d", cpu.Register(1)); //r1

    // loadSDL();
    // SDL_Init(SDL_INIT_VIDEO);

    // writeln("Hi SDL!!");

    // SDL_Quit();
}
