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

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
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
    NoMessages = MakeModuleResult(128, 3),
}

final class AppletState {
    KEvent MessageEvent;
    uint[] Messages;
    AppletFocusState FocusState = AppletFocusState.InFocus;
    ubyte OperationMode = 0;
    uint PerformanceMode = 0;
    ulong AppletResourceUserId = 0x51;

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
        Command(1, "GetSelfController", (IpcContext c) => c.PushInterface(new SelfController()));
        Command(2, "GetWindowController", (IpcContext c) => c.PushInterface(new WindowController(state)));
        Command(3, "GetAudioController", (IpcContext c) => c.PushInterface(new StubbedService("am::IAudioController")));
        Command(4, "GetDisplayController", (IpcContext c) => c.PushInterface(new StubbedService("am::IDisplayController")));
        Command(10, "GetProcessWindingController", (IpcContext c) => c.PushInterface(new StubbedService("am::IProcessWindingController")));
        Command(11, "GetLibraryAppletCreator", (IpcContext c) => c.PushInterface(new StubbedService("am::ILibraryAppletCreator")));
        Command(20, "GetApplicationFunctions", (IpcContext c) => c.PushInterface(new ApplicationFunctions()));
        Command(1000, "GetDebugFunctions", (IpcContext c) => c.PushInterface(new StubbedService("am::IDebugFunctions")));
    }

    override string Name() const {
        return "am::IApplicationProxy";
    }
}

// ICommonStateGetter
final class CommonStateGetter : IPCService {
    private AppletState state;

    this(AppletState state) {
        this.state = state;
        Command(0, "GetEventHandle", &GetEventHandle);
        Command(1, "ReceiveMessage", &ReceiveMessage);
        Command(5, "GetOperationMode", (IpcContext c) => c.Push!ubyte(state.OperationMode));
        Command(6, "GetPerformanceMode", (IpcContext c) => c.Push!uint(state.PerformanceMode));
        Command(8, "GetBootMode", (IpcContext c) => c.Push!ubyte(0));
        Command(9, "GetCurrentFocusState", (IpcContext c) => c.Push!ubyte(state.FocusState));
        Stub(50, "IsVrModeEnabled");
        Stub(60, "GetDefaultDisplayResolution");
        Stub(66, "SetCpuBoostMode");
    }

    override string Name() const {
        return "am::ICommonStateGetter";
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
    this() {
        Stub(0, "Exit");
        Stub(1, "LockExit");
        Stub(2, "UnlockExit");
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
    this() {
        Stub(20, "EnsureSaveData");
        Command(21, "GetDesiredLanguage", (IpcContext c) => c.Push!ulong(0x00000053552D6E65));
        Stub(22, "SetTerminateResult");
        Command(40, "NotifyRunning", (IpcContext c) => c.Push!ubyte(0));
        Stub(66, "InitializeGamePlayRecording");
        Stub(67, "SetGamePlayRecordingState");
    }

    override string Name() const {
        return "am::IApplicationFunctions";
    }
}
