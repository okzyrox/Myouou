/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * apm: performance management
*/

module Source.Service.Apm;

// Core
import Source.Kernel.Ipc;
import Source.Service.Service;

// Types
enum uint DefaultPerformanceConfiguration = 0x00010000;

// Service
final class ApmService : IPCService {
    private string name;

    this(string name) {
        this.name = name;
        Command(0, "OpenSession", &OpenSession);
        Command(1, "GetPerformanceMode", &GetPerformanceMode);
        Command(6, "IsEnoughPowerSupplied", &IsEnoughPowerSupplied);
    }

    override string Name() const {
        return name;
    }

    private void OpenSession(IpcContext context) {
        context.PushInterface(new ApmSession());
    }

    private void GetPerformanceMode(IpcContext context) {
        context.Push!uint(0);
    }

    private void IsEnoughPowerSupplied(IpcContext context) {
        context.Push!ubyte(1);
    }
}

final class ApmSession : IPCService {
    private uint[uint] configurations;

    this() {
        Command(0, "SetPerformanceConfiguration", &SetPerformanceConfiguration);
        Command(1, "GetPerformanceConfiguration", &GetPerformanceConfiguration);
        Stub(2, "SetCpuOverclockEnabled");
    }

    override string Name() const {
        return "apm::ISession";
    }

    private void SetPerformanceConfiguration(IpcContext context) {
        const uint mode = context.Pop!uint();
        configurations[mode] = context.Pop!uint();
    }

    private void GetPerformanceConfiguration(IpcContext context) {
        const uint mode = context.Pop!uint();
        context.Push!uint(configurations.get(mode, DefaultPerformanceConfiguration));
    }
}
