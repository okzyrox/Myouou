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
import Source.Util.Logger;
import Source.Wrapper.Dynarmic;
import Source.Wrapper.DynarmicJit;
import Source.Emulator.Execution;

int main(string[] args) {
    LogLevel logLevel = LogLevel.Info;
    LogFilter.MinimumLevel(logLevel);
    LogFile.Default(MainLogFile);
    scope (exit) {
        LogFile.CloseAll();
    }

    if (args.length > 1) {
        return RunFile(args[1]);
    } else {
        writefln("No file provided!");
    }

    // TestEnvironment env = new TestEnvironment();
    // DynarmicJit cpu = new DynarmicJit(env);
    // env.RemainingTicks = 1;

    // env.MemoryWrite32(0, 0xD37EF420);
    // env.MemoryWrite32(4, 0x14000000);

    // cpu.Register(0, 1);
    // cpu.Register(1, 3);
    // cpu.Pc = 0;

    // cpu.Run();
    // writefln("r0: %d", cpu.Register(0)); //r1 * 4
    // writefln("r1: %d", cpu.Register(1)); //r1

    // loadSDL();
    // SDL_Init(SDL_INIT_VIDEO);

    // writeln("Hi SDL!!");

    // SDL_Quit();
    return 0;
}
