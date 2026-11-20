/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * HLE service base
*/

module Source.Service.Service;

// Core
import Source.Util.Logger;
import Source.Kernel.Ipc;
import Source.Kernel.Result;

// Types
alias IpcCommand = void delegate(IpcContext context);

abstract class IPCService {
    private IpcCommand[uint] commands;
    private string[uint] commandNames;
    private Logger logger;

    abstract string Name() const;

    Logger Log() {
        if (logger is null)
            logger = GetLogger(Name);
        return logger;
    }

    protected void Command(uint id, string name, IpcCommand handler) {
        commands[id] = handler;
        commandNames[id] = name;
    }

    protected void Stub(uint id, string name) {
        Command(id, name, null);
    }

    void Dispatch(IpcContext context) {
        const uint id = context.MethodId;
        IpcCommand* handler = id in commands;
        if (handler is null) {
            Log.Stub("#%d (unknown)", id);
            return;
        }

        if (*handler is null) {
            Log.Stub("%s", commandNames[id]);
            return;
        }

        (*handler)(context);
        Log.Trace("%s -> %s", commandNames[id], FormatResult(context.Response.Result));
    }

    // Utils
    void Succeed(IpcContext context) {
    }

    void True(IpcContext context) {
        context.Push!ubyte(1);
    }

    void False(IpcContext context) {
        context.Push!ubyte(0);
    }
}

// Utils
string GetServiceNameFromRaw(ulong raw) pure @safe {
    char[] svcName;
    foreach (i; 0..8) {
        const char c = cast(char)((raw >> (i*8)) & 0xFF);
        if (c == 0) {
            break;
        }
        svcName ~= c;
    }
    return svcName.idup;
}

// Service
final class StubbedService : IPCService {
    private string name;

    this(string name) {
        this.name = name;
    }

    override string Name() const {
        return name;
    }
}
