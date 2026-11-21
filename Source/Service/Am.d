/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * am: applet manager
*/

module Source.Service.Am;

// Std
import std.algorithm : min;

// Core
import Source.FileSystem.HostFileSystem;
import Source.FileSystem.Storage;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Service.Acc;
import Source.Service.Service;

// Types
enum AppletMessage : uint {
    ExitRequest = 4,
    FocusStateChanged = 15,
    OperationModeChanged = 30,
    PerformanceModeChanged = 31,
}

enum AppletFocusState : ubyte {
    InFocus = 1,
    OutOfFocus = 2,
    Background = 3,
}

enum AmResult : uint {
    NoDataInChannel = MakeModuleResult(128, 2),
    NoMessages = MakeModuleResult(128, 3),
    OutOfBounds = MakeModuleResult(128, 503),
}

enum LaunchParameterKind : uint {
    UserChannel = 1,
    PreselectedUser = 2,
    Unk1 = 3
}

enum uint PreselectedUserMagic = 0xC79497CA;
enum size_t PreselectedUserSize = 0x88;

final class AppletState {
    KEvent MessageEvent;
    uint[] Messages;
    AppletFocusState FocusState = AppletFocusState.InFocus;
    ubyte OperationMode = 0;
    bool ExitRequested;
    bool ExitLocked;
    uint PerformanceMode = 0;
    ulong AppletResourceUserId = 0x51;
    SwitchStorage Storage;
    ulong ProgramId;
    AccountUid PreselectedUser;
    bool[uint] PoppedLaunchParameters;

    this() {
        MessageEvent = new KEvent("AppletMessage");
        Post(AppletMessage.FocusStateChanged);
    }

    void Post(uint message) {
        Messages ~= message;
        MessageEvent.Signal();
    }

    bool Receive(out uint message) {
        if (Messages.length == 0)
            return false;
        message = Messages[0];
        Messages = Messages[1 .. $];
        if (Messages.length == 0)
            MessageEvent.Clear();
        return true;
    }
}

// Services
final class AppletOEService : IPCService {
    private AppletState state;

    this(AppletState state) {
        this.state = state;
        Command(0, "OpenApplicationProxy", &OpenApplicationProxy);
    }

    override string Name() const {
        return "appletOE";
    }

    private void OpenApplicationProxy(IpcContext context) {
        context.PushInterface(new ApplicationProxy(state));
    }
}

// ISystemAppletProxy
final class ApplicationProxy : IPCService {
    private AppletState state;

    this(AppletState state) {
        this.state = state;
        Command(0, "GetCommonStateGetter", (IpcContext c) => c.PushInterface(new CommonStateGetter(state)));
        Command(1, "GetSelfController", (IpcContext c) => c.PushInterface(new SelfController(state)));
        Command(2, "GetWindowController", (IpcContext c) => c.PushInterface(new WindowController(state)));
        Command(3, "GetAudioController", (IpcContext c) => c.PushInterface(new StubbedService("am::IAudioController")));
        Command(4, "GetDisplayController", (IpcContext c) => c.PushInterface(new StubbedService("am::IDisplayController")));
        Command(10, "GetProcessWindingController", (IpcContext c) => c.PushInterface(new StubbedService("am::IProcessWindingController")));
        Command(11, "GetLibraryAppletCreator", (IpcContext c) => c.PushInterface(new StubbedService("am::ILibraryAppletCreator")));
        Command(20, "GetApplicationFunctions", (IpcContext c) => c.PushInterface(new ApplicationFunctions(state)));
        Command(1000, "GetDebugFunctions", (IpcContext c) => c.PushInterface(new StubbedService("am::IDebugFunctions")));
    }

    override string Name() const {
        return "am::IApplicationProxy";
    }
}

// ICommonStateGetter
final class CommonStateGetter : IPCService {
    private AppletState state;
    private KEvent defaultResolutionChangeEvent;

    this(AppletState state) {
        this.state = state;
        defaultResolutionChangeEvent = new KEvent("DefaultDisplayResolutionChange");
        Command(0, "GetEventHandle", &GetEventHandle);
        Command(1, "ReceiveMessage", &ReceiveMessage);
        Command(5, "GetOperationMode", (IpcContext c) => c.Push!ubyte(state.OperationMode));
        Command(6, "GetPerformanceMode", (IpcContext c) => c.Push!uint(state.PerformanceMode));
        Command(8, "GetBootMode", (IpcContext c) => c.Push!ubyte(0));
        Command(9, "GetCurrentFocusState", (IpcContext c) => c.Push!ubyte(state.FocusState));
        Stub(50, "IsVrModeEnabled");
        Command(60, "GetDefaultDisplayResolution", &GetDefaultDisplayResolution);
        Command(61, "GetDefaultDisplayResolutionChangeEvent", (IpcContext c) => c.PushCopyHandle(defaultResolutionChangeEvent));
        Stub(66, "SetCpuBoostMode");
    }

    override string Name() const {
        return "am::ICommonStateGetter";
    }

    private void GetDefaultDisplayResolution(IpcContext context) {
        const bool docked = state.OperationMode == 1;
        context.Push!int(docked ? 1920 : 1280);
        context.Push!int(docked ? 1080 : 720);
    }

    private void GetEventHandle(IpcContext context) {
        context.PushCopyHandle(state.MessageEvent);
    }

    private void ReceiveMessage(IpcContext context) {
        uint message;
        if (!state.Receive(message)) {
            context.Result(AmResult.NoMessages);
            return;
        }
        context.Push!uint(message);
    }
}

// ISelfController
final class SelfController : IPCService {
    private AppletState state;

    this(AppletState state) {
        this.state = state;
        Command(0, "Exit", (IpcContext c) { this.state.ExitRequested = true; });
        Command(1, "LockExit", (IpcContext c) { this.state.ExitLocked = true; });
        Command(2, "UnlockExit", (IpcContext c) { this.state.ExitLocked = false; });
        Command(9, "GetLibraryAppletLaunchableEvent", (IpcContext c) => c.PushCopyHandle(new KEvent("LibraryAppletLaunchable", true)));
        Stub(10, "SetScreenShotPermission");
        Stub(11, "SetOperationModeChangedNotification");
        Stub(12, "SetPerformanceModeChangedNotification");
        Stub(13, "SetFocusHandlingMode");
        Stub(14, "SetRestartMessageEnabled");
        Stub(16, "SetOutOfFocusSuspendingEnabled");
        Command(40, "CreateManagedDisplayLayer", (IpcContext c) => c.Push!ulong(1));
        Stub(50, "SetHandlesRequestToDisplay");
        Stub(62, "SetIdleTimeDetectionExtension");
        Stub(68, "SetAutoSleepDisabled");
        Command(91, "GetAccumulatedSuspendedTickChangedEvent", (IpcContext c) => c.PushCopyHandle(new KEvent("AccumulatedSuspendedTickChanged")));
    }

    override string Name() const {
        return "am::ISelfController";
    }
}

// IWindowController
final class WindowController : IPCService {
    this(AppletState state) {
        Command(1, "GetAppletResourceUserId", (IpcContext c) => c.Push!ulong(state.AppletResourceUserId));
        Stub(10, "AcquireForegroundRights");
    }

    override string Name() const {
        return "am::IWindowController";
    }
}

// IApplicationFunctions
final class ApplicationFunctions : IPCService {
    private AppletState state;

    this(AppletState state) {
        this.state = state;
        Command(1, "PopLaunchParameter", &PopLaunchParameter);
        Command(20, "EnsureSaveData", &EnsureSaveData);
        Command(21, "GetDesiredLanguage", (IpcContext c) => c.Push!ulong(0x00000053552D6E65));
        Stub(22, "SetTerminateResult");
        Command(40, "NotifyRunning", (IpcContext c) => c.Push!ubyte(0));
        Stub(66, "InitializeGamePlayRecording");
        Stub(67, "SetGamePlayRecordingState");
    }

    override string Name() const {
        return "am::IApplicationFunctions";
    }

    private void PopLaunchParameter(IpcContext context) {
        const uint kind = context.Pop!uint();
        if (kind != LaunchParameterKind.PreselectedUser || kind in state.PoppedLaunchParameters || !state.PreselectedUser.IsValid) {
            context.Result(AmResult.NoDataInChannel);
            return;
        }
        // can only be popped once (as they are removed from the state usually)
        state.PoppedLaunchParameters[kind] = true;
        ubyte[] data = new ubyte[PreselectedUserSize];
        *cast(uint*) data.ptr = PreselectedUserMagic;
        data[4] = 1;
        data[8 .. 0x18] = (cast(const(ubyte)*) &state.PreselectedUser)[0 .. AccountUid.sizeof];
        context.PushInterface(new StorageService(data));
    }

    private void EnsureSaveData(IpcContext context) {
        const AccountUid uid = context.Pop!AccountUid();
        SaveDataAttribute attribute;
        attribute.UserId = uid.Value;
        attribute.Type = SaveDataType.Account;
        HostFileSystem existing;
        if (state.Storage !is null && state.Storage.OpenSaveData(SaveDataSpaceId.User, attribute, state.ProgramId, existing) != ResultSuccess) {
            state.Storage.CreateSaveData(SaveDataSpaceId.User, attribute, state.ProgramId);
        }
        context.Push!ulong(0);
    }
}

final class StorageService : IPCService {
    private ubyte[] data;

    this(ubyte[] data) {
        this.data = data;
        Command(0, "Open", (IpcContext c) => c.PushInterface(new StorageAccessorService(this.data)));
    }

    override string Name() const {
        return "am::IStorage";
    }
}

final class StorageAccessorService : IPCService {
    private ubyte[] data;

    this(ubyte[] data) {
        this.data = data;
        Command(0, "GetSize", (IpcContext c) => c.Push!long(this.data.length));
        Command(10, "Write", &Write);
        Command(11, "Read", &Read);
    }

    override string Name() const {
        return "am::IStorageAccessor";
    }

    private void Write(IpcContext context) {
        const long offset = context.Pop!long();
        const ubyte[] source = context.ReadInput(0);
        if (offset < 0 || offset + source.length > data.length) {
            context.Result(AmResult.OutOfBounds);
            return;
        }
        data[cast(size_t) offset .. cast(size_t) offset + source.length] = source[];
    }

    private void Read(IpcContext context) {
        const long offset = context.Pop!long();
        if (offset < 0 || offset > data.length) {
            context.Result(AmResult.OutOfBounds);
            return;
        }
        const size_t length = min(context.OutputSize(0), data.length - cast(size_t) offset);
        context.WriteOutput(0, data[cast(size_t) offset .. cast(size_t) offset + length]);
    }
}
