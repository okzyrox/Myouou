/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * ssl: tls connections
*/

module Source.Service.Ssl;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
enum SslResult : uint {
    NoConnection = MakeModuleResult(123, 208),
    NetworkDown = MakeModuleResult(123, 212),
}

// Services
final class SslService : IPCService {
    private uint interfaceVersion;

    this() {
        Command(0, "CreateContext", &CreateContext);
        Command(1, "GetContextCount", (IpcContext c) => c.Push!uint(0));
        Stub(2, "GetCertificates");
        Command(3, "GetCertificateBufSize", (IpcContext c) => c.Push!uint(0));
        Stub(4, "DebugIoctl");
        Command(5, "SetInterfaceVersion", (IpcContext c) { interfaceVersion = c.Pop!uint(); });
        Stub(6, "FlushSessionCache");
        Stub(7, "SetDebugOption");
        Command(8, "GetDebugOption", (IpcContext c) => c.Push!uint(0));
        Stub(9, "ClearTls12FallbackFlag");
    }

    override string Name() const {
        return "ssl";
    }

    private void CreateContext(IpcContext context) {
        const uint sslVersion = context.Pop!uint();
        Log.Info("CreateContext: ssl version 0x%X", sslVersion);
        context.PushInterface(new SslContextService());
    }
}

final class SslContextService : IPCService {
    private ulong nextPkiId = 1;
    private uint[uint] options;

    this() {
        Command(0, "SetOption", &SetOption);
        Command(1, "GetOption", &GetOption);
        Command(2, "CreateConnection", (IpcContext c) => c.PushInterface(new SslConnectionService()));
        Command(3, "GetConnectionCount", (IpcContext c) => c.Push!uint(0));
        Command(4, "ImportServerPki", &ImportPki);
        Command(5, "ImportClientPki", &ImportPki);
        Command(6, "RemoveServerPki", &Succeed);
        Command(7, "RemoveClientPki", &Succeed);
        Command(8, "RegisterInternalPki", &ImportPki);
        Command(9, "AddPolicyOid", &Succeed);
        Command(10, "ImportCrl", &ImportPki);
        Command(11, "RemoveCrl", &Succeed);
        Command(12, "ImportClientCertKeyPki", &ImportPki);
        Command(13, "GeneratePrivateKeyAndCert", &Succeed);
    }

    override string Name() const {
        return "ssl::ISslContext";
    }

    private void SetOption(IpcContext context) {
        const uint option = context.Pop!uint();
        options[option] = context.Pop!uint();
    }

    private void GetOption(IpcContext context) {
        context.Push!uint(options.get(context.Pop!uint(), 0));
    }

    private void ImportPki(IpcContext context) {
        context.Push!ulong(nextPkiId++);
    }
}

final class SslConnectionService : IPCService {
    private uint[uint] options;

    this() {
        Command(0, "SetSocketDescriptor", (IpcContext c) => c.Push!uint(c.Pop!uint()));
        Command(1, "SetHostName", &Succeed);
        Command(2, "SetVerifyOption", &Succeed);
        Command(3, "SetIoMode", &Succeed);
        Command(4, "GetSocketDescriptor", (IpcContext c) => c.Push!uint(0));
        Command(5, "GetHostName", (IpcContext c) => c.Push!uint(0));
        Command(6, "GetVerifyOption", (IpcContext c) => c.Push!uint(0));
        Command(7, "GetIoMode", (IpcContext c) => c.Push!uint(0));
        Command(8, "DoHandshake", &NoConnection);
        Command(9, "DoHandshakeGetServerCert", &NoConnection);
        Command(10, "Read", &NoConnection);
        Command(11, "Write", &NoConnection);
        Command(12, "Pending", (IpcContext c) => c.Push!uint(0));
        Command(13, "Peek", &NoConnection);
        Command(14, "Poll", &NoConnection);
        Command(15, "GetVerifyCertError", &Succeed);
        Command(16, "GetNeededServerCertBufferSize", (IpcContext c) => c.Push!uint(0));
        Command(17, "SetSessionCacheMode", &Succeed);
        Command(18, "GetSessionCacheMode", (IpcContext c) => c.Push!uint(0));
        Command(19, "FlushSessionCache", &Succeed);
        Command(20, "SetRenegotiationMode", &Succeed);
        Command(21, "GetRenegotiationMode", (IpcContext c) => c.Push!uint(0));
        Command(22, "SetOption", &SetOption);
        Command(23, "GetOption", &GetOption);
    }

    override string Name() const {
        return "ssl::ISslConnection";
    }

    private void NoConnection(IpcContext context) {
        Log.Stub("No connection, so method %d failed.", context.MethodId);
        context.Result(SslResult.NoConnection);
    }

    private void SetOption(IpcContext context) {
        const uint option = context.Pop!uint();
        options[option] = context.Pop!uint();
    }

    private void GetOption(IpcContext context) {
        context.Push!uint(options.get(context.Pop!uint(), 0));
    }
}
