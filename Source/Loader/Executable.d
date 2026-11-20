/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Common interface for executable formats
*/

module Source.Loader.Executable;

// Core
import Source.Emulator.GuestEnv;
import Source.Kernel.Kernel;
import Source.Memory.Guest;
import Source.Wrapper.DynarmicJit;

// Types
enum uint DefaultMainThreadHandle = 0xF001;

// Initial cpu state of the main thread
struct ProgramEntry {
    ulong EntryPoint;
    ulong StackTop;
    ulong TlsAddress;
    ulong ReturnAddress;
    ulong[2] Arguments; // X0, X1
}

interface Executable {
    string FormatName() const;
    void Describe();
    ProgramEntry Load(GuestMemory memory, HorizonKernel kernel);
}

struct ExecutableFormat {
    string Name;
    bool function(const(ubyte)[] header) Matches;
    Executable function(string path) Open;
}

class ExecutableError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

// Functions
void StartProgram(GuestEnvironment environment, DynarmicJit jit, in ProgramEntry entry) {
    environment.TpidrroEl0 = entry.TlsAddress;
    environment.TpidrEl0 = 0;
    environment.ReturnAddress = entry.ReturnAddress;
    environment.Exited = false;

    ulong[31] registers;
    registers[0] = entry.Arguments[0];
    registers[1] = entry.Arguments[1];
    registers[30] = entry.ReturnAddress;
    jit.Registers(registers);
    jit.Sp = entry.StackTop;
    jit.Pc = entry.EntryPoint;
}
