/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loading and running an executable
*/

module Source.Emulator.Execution;

// Std
import std.file : exists, getcwd, isFile;
import std.path : buildPath, extension;
import std.stdio;
import std.uni : toLower;

// Core
import Source.Emulator.GuestEnv;
import Source.FileSystem.Storage;
import Source.Kernel.Kernel;
import Source.Kernel.Svc;
import Source.Loader.Executable;
import Source.Loader.NROLoader;
import Source.Memory.Guest;
import Source.Wrapper.Dynarmic;
import Source.Wrapper.DynarmicJit;

// Types
enum size_t HeaderProbeSize = 0x1000; // should be enough for most formats?
immutable ExecutableFormat[] ExecutableFormats = [
    ExecutableFormat("NRO", &NROExecutable.Matches, &NROExecutable.Open),
];

// Utils
void DebugRegs(DynarmicJit jit) {
    const ulong[31] regs = jit.Registers;
    foreach (i; 0 .. 31) {
        writef("  X%-2d 0x%016X", i, regs[i]);
        if (i % 4 == 2) {
            writeln();
        }
    }
    writefln("\nSP  0x%016X\nPC  0x%016X", jit.Sp, jit.Pc);
}

string ResolveExecutablePath(string path) {
    // Only for installed homebrew, just as a nice qol.
    if (exists(path) || extension(path).toLower != ".nro") {
        return path;
    }
    const string installed = buildPath(getcwd(), StorageFolder, HomebrewFolder, path);
    if (exists(installed) && isFile(installed)) {
        return installed;
    }
    return path;
}

Executable OpenExecutable(string path) {
    File file = File(path, "rb");
    ubyte[] header = new ubyte[HeaderProbeSize];
    header = file.rawRead(header);
    file.close();

    foreach (format; ExecutableFormats) {
        // headermatched rather than extension matched just in case
        if (format.Matches(header)) {
            return format.Open(path);
        }
    }
    throw new ExecutableError("Unrecognised executable format: " ~ path);
}

// Main
int RunFile(string path) {
    path = ResolveExecutablePath(path);
    if (!exists(path) || !isFile(path)) {
        writefln("File not found: %s", path);
        return 1;
    }

    Executable executable;
    try {
        executable = OpenExecutable(path);
    } catch (ExecutableError error) {
        writefln("%s", error.msg);
        return 1;
    }
    writefln("File Format: %s", executable.FormatName);
    executable.Describe();

    GuestMemory memory = new GuestMemory();
    GuestEnvironment environment = new GuestEnvironment(memory);
    DynarmicJit jit = environment.CreateJit();

    HorizonKernel kernel = new HorizonKernel(environment, DefaultMainThreadHandle);
    const ProgramEntry entry = executable.Load(memory, kernel);
    StartProgram(environment, jit, entry);

    HaltReason haltResult;
    size_t svcCount = 0;
    while (true) {
        haltResult = jit.Run();
        if (!haltResult.Has(SvcHalt)) {
            break;
        }

        jit.ClearHalt(SvcHalt);
        svcCount++;
        bool wasStubbed = kernel.HandleSvc(environment.PreviousSvc);
        if (!wasStubbed) {
            writefln("Stopped at %s (0x%X).", GetSvcName(environment.PreviousSvc), jit.Pc - 4);
            DebugRegs(jit);
            kernel.Shutdown();
            return 0;
        }
        if (kernel.Display.IsOpen) {
            if (svcCount % 0x1000 == 0) {
                kernel.Display.UpdateEvents();
            }
            if (kernel.Display.ShouldQuit) {
                writefln("Window manually closed.");
                kernel.Shutdown();
                return 0;
            }
        }
        else if (svcCount >= 20_000) {
            DebugRegs(jit);
            return 1;
        }
    }
    kernel.Shutdown();

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
