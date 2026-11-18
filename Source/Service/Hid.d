/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * hid: HID
*/

module Source.Service.Hid;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Service.Service;

// Types
enum size_t HidSharedMemorySize = 0x40000;

final class HidState {
    KSharedMemory SharedMemory;
    KEvent[uint] StyleSetUpdateEvents;

    this() {
        SharedMemory = new KSharedMemory("HidSharedMemory", HidSharedMemorySize);
    }

    KEvent StyleSetUpdateEvent(uint npadId) {
        KEvent* found = npadId in StyleSetUpdateEvents;
        if (found !is null)
            return *found;
        KEvent event = new KEvent("NpadStyleSetUpdate", true);
        StyleSetUpdateEvents[npadId] = event;
        return event;
    }
}

// Servce
final class HidService : IPCService {
    private HidState state;

    this(HidState state) {
        this.state = state;
        Command(0, "CreateAppletResource", (IpcContext c) => c.PushInterface(new AppletResource(state)));
        Stub(1, "ActivateDebugPad");
        Stub(11, "ActivateTouchScreen");
        Stub(21, "ActivateMouse");
        Stub(31, "ActivateKeyboard");
        Stub(32, "SendKeyboardLockKeyEvent");
        Stub(40, "AcquireXpadIdEventHandle");
        Stub(66, "StartSixAxisSensor");
        Stub(67, "StopSixAxisSensor");
        Stub(79, "SetGyroscopeZeroDriftMode");
        Stub(100, "SetSupportedNpadStyleSet");
        Command(101, "GetSupportedNpadStyleSet", (IpcContext c) => c.Push!uint(0x1F));
        Stub(102, "SetSupportedNpadIdType");
        Stub(103, "ActivateNpad");
        Stub(104, "DeactivateNpad");
        Command(106, "AcquireNpadStyleSetUpdateEventHandle", &AcquireNpadStyleSetUpdateEventHandle);
        Stub(109, "ActivateNpadWithRevision");
        Stub(120, "SetNpadJoyHoldType");
        Command(121, "GetNpadJoyHoldType", (IpcContext c) => c.Push!ulong(0));
        Stub(122, "SetNpadJoyAssignmentModeSingleByDefault");
        Stub(124, "SetNpadJoyAssignmentModeDual");
        Stub(128, "SetNpadHandheldActivationMode");
        Stub(200, "GetVibrationDeviceInfo");
        Stub(201, "SendVibrationValue");
        Stub(203, "CreateActiveVibrationDeviceList");
        Stub(206, "SendVibrationValues");
        Stub(1000, "SetNpadCommunicationMode");
    }

    override string Name() const {
        return "hid";
    }

    private void AcquireNpadStyleSetUpdateEventHandle(IpcContext context) {
        const uint npadId = context.Pop!uint();
        context.PushCopyHandle(state.StyleSetUpdateEvent(npadId));
    }
}

final class AppletResource : IPCService {
    this(HidState state) {
        Command(0, "GetSharedMemoryHandle", (IpcContext c) => c.PushCopyHandle(state.SharedMemory));
    }

    override string Name() const {
        return "hid::IAppletResource";
    }
}
