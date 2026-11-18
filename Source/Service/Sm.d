/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * sm: service manager
*/

module Source.Service.Sm;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
alias ServiceFactory = IPCService delegate();

enum SmResult : uint {
    NotAllowed = MakeModuleResult(21, 2),
    InvalidServiceName = MakeModuleResult(21, 6),
}

final class ServiceRegistry {
    private ServiceFactory[string] serviceFactories;

    void Register(string name, ServiceFactory factory) {
        serviceFactories[name] = factory;
    }

    void Register(T : IPCService)(string[] services...) {
        foreach (name; services)
            serviceFactories[name] = () => cast(IPCService) new T();
    }

    bool ServiceExists(string name) const {
        return (name in serviceFactories) !is null;
    }

    IPCService Create(string name) {
        ServiceFactory* factory = name in serviceFactories;
        if (factory is null)
            return new StubbedService(name);
        return (*factory)();
    }
}

// Service
final class SmService : IPCService {
    private ServiceRegistry registry;
    private bool registered;

    this(ServiceRegistry registry) {
        this.registry = registry;
        Command(0, "RegisterClient", &RegisterClient);
        Command(1, "GetService", &GetService);
        Command(2, "RegisterService", &RegisterService);
        Command(3, "UnregisterService", &UnregisterService);
        Stub(4, "DetachClient");
    }

    override string Name() const {
        return "sm:";
    }

    private void RegisterClient(IpcContext context) {
        registered = true;
    }

    private void GetService(IpcContext context) {
        const string name = GetServiceNameFromRaw(context.Pop!ulong());
        if (!registered) {
            context.Result(SmResult.NotAllowed);
            return;
        }
        if (name.length == 0) {
            context.Result(SmResult.InvalidServiceName);
            return;
        }

        if (!registry.ServiceExists(name))
            Log.Stub("GetService %s has no implementation", name);
        else
            Log.Trace("GetService %s", name);
        context.PushInterface(registry.Create(name));
    }

    private void RegisterService(IpcContext context) {
        // ServiceName, bool IsLight, s32 MaxSession
        Log.Stub("RegisterService %s", GetServiceNameFromRaw(context.Pop!ulong()));
    }

    private void UnregisterService(IpcContext context) {
        // ServiceName
        Log.Stub("UnregisterService %s", GetServiceNameFromRaw(context.Pop!ulong()));
    }
}
