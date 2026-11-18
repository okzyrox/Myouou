/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loading and executing an NRO until it needs the kernel.
*/

module Source.Emulator.NROExec;

// Std
import std.stdio;

// Core
import Source.Emulator.GuestEnv;
import Source.Format.NRO;
import Source.Kernel.Kernel;
import Source.Kernel.Svc;
import Source.Loader.NROLoader;
import Source.Memory.Guest;
import Source.Wrapper.Dynarmic;
import Source.Wrapper.DynarmicJit;

// Utils
void DebugNROFile(NROFile nro) {
    const NROHeader header = nro.Header;
    writefln("NRO Version %d", header.Version);
    foreach (kind; [NROSegmentKind.Text, NROSegmentKind.Ro, NROSegmentKind.Data]) {
        const NROSegment segment = header.Segments[kind];
        writefln("Section: %-5s 0x%06X size 0x%06X", kind, segment.FileOffset, segment.Size);
    }
    if (nro.HasAssets) {
        const NacpInfo nacp = nro.Nacp;
        writefln("%s by %s, app version: %s", nacp.Title, nacp.Author, nacp.DisplayVersion);
        writefln("NACP 0x%X, RomFS 0x%X", nro.Icon.length, nro.NacpData.length, nro.RomFs.length);
    }
}

void DebugRegs(DynarmicJit jit) {
    const ulong[31] regs = jit.Registers;
    foreach (i; 0 .. 31) {
        writef("  X%-2d 0x%016X", i, regs[i]);
        if (i % 4 == 2)
            writeln();
    }
    writefln("\nSP  0x%016X\nPC  0x%016X", jit.Sp, jit.Pc);
}

// Main
size_t svcLimit = 20_000;
int RunFile(string path) {
    NROFile nro = NROFile.Load(path);
    DebugNROFile(nro);

    GuestMemory memory = new GuestMemory();
    NROData loaded = LoadNROToMemory(memory, nro);
    GuestEnvironment environment = new GuestEnvironment(memory);

    DynarmicJit jit = environment.CreateJit();
    HorizonKernel kernel = new HorizonKernel(environment, cast(uint) loaded.MainThreadHandle);
    LoadEntry(environment, jit, loaded);

    writefln("Loaded 0x%X, 0x%X. top 0x%X", loaded.ImgBase, loaded.EntryPoint, loaded.StackTop);

    HaltReason haltResult;
    size_t svcCount = 0;
    while (true) {
        haltResult = jit.Run();
        if (!haltResult.Has(SvcHalt))
            break;

        jit.ClearHalt(SvcHalt);
        svcCount++;
        bool wasStubbed = kernel.HandleSvc(environment.PreviousSvc);
        if (!wasStubbed) {
            writefln("Stopped at %s (0x%X).", GetSvcName(environment.PreviousSvc), jit.Pc - 4);
            DebugRegs(jit);
            kernel.Display.Close();
            return 0;
        }
        if (kernel.Display.IsOpen) {
            if (svcCount % 0x1000 == 0)
                kernel.Display.UpdateEvents();
            if (kernel.Display.ShouldQuit) {
                writefln("Window manually closed.");
                kernel.Display.Close();
                return 0;
            }
        }
        else if (svcCount >= svcLimit) {
            DebugRegs(jit);
            return 1;
        }
    }
    kernel.Display.Close();

    if (haltResult.Has(ExitHalt)) {
        writefln("Guest returned to loader where X0 = 0x%X", jit.Register(0));
        return 0;
    }

    if (haltResult.Has(GuestExceptionHalt)) {
        writefln("Guest raised %s at 0x%X.", environment.LastException, environment.ExceptionPC);
        DebugRegs(jit);
        return 1;
    }

    writefln("Halt: %s", haltResult);
    DebugRegs(jit);
    return 1;
}
