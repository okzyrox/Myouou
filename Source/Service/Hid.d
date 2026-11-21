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
import Source.Frontend.Input;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Service.Service;

// Types
enum size_t HidSharedMemorySize = 0x40000;
enum size_t NpadSharedOffset = 0x9A00;
enum size_t NpadEntrySize = 0x5000;
enum size_t LifoEntrySize = 0x30;
// ringlifo data
enum size_t NpadFullKeyLifo = 0x28;
enum size_t NpadHandheldLifo = 0x378;
enum size_t LifoHeaderSize = 0x20;
enum ulong LifoCapacity = 17; // * entry size
enum size_t NpadNo1Index = 0;
enum size_t NpadHandheldIndex = 8;

enum NpadStyleTag : uint {
    FullKey = 1 << 0, // Pro Controller
    Handheld = 1 << 1, // Joy Con in Handheld
}

enum NpadAttribute : uint {
    IsConnected = 1 << 0,
    IsWired = 1 << 1,
    IsLeftConnected = 1 << 2,
    IsLeftWired = 1 << 3,
    IsRightConnected = 1 << 4,
    IsRightWired = 1 << 5,
}

struct NpadCommonState {
    ulong SamplingNumber;
    ulong Buttons;
    int LeftX;
    int LeftY;
    int RightX;
    int RightY;
    uint Attributes;
    uint Reserved;
}

final class HidState {
    KSharedMemory SharedMemory;
    KEvent[uint] StyleSetUpdateEvents;
    NpadInput LastInput;
    private ulong samplingNumber;

    this() {
        SharedMemory = new KSharedMemory("HidSharedMemory", HidSharedMemorySize);
        SharedMemory.SetU32(NpadBase(NpadNo1Index), NpadStyleTag.FullKey);
        SharedMemory.SetU32(NpadBase(NpadHandheldIndex), NpadStyleTag.Handheld);
        WriteNpadInput(NpadInput.init);
    }

    void WriteNpadInput(NpadInput input) {
        LastInput = input;
        NpadCommonState state;
        state.SamplingNumber = samplingNumber++;
        state.Buttons = input.Buttons;
        state.LeftX = input.LeftX;
        state.LeftY = input.LeftY;
        state.RightX = input.RightX;
        state.RightY = input.RightY;

        state.Attributes = NpadAttribute.IsConnected | NpadAttribute.IsLeftConnected | NpadAttribute.IsRightConnected;
        PushLifo(NpadBase(NpadNo1Index) + NpadFullKeyLifo, state);

        state.Attributes |= NpadAttribute.IsWired | NpadAttribute.IsLeftWired | NpadAttribute.IsRightWired;
        PushLifo(NpadBase(NpadHandheldIndex) + NpadHandheldLifo, state);
    }

    private static size_t NpadBase(size_t index) {
        return NpadSharedOffset + index * NpadEntrySize;
    }

    private void PushLifo(size_t lifo, const ref NpadCommonState state) {
        const ulong lifoEnd = (SharedMemory.GetU64(lifo + 0x10) + 1) % LifoCapacity;
        const ulong count = SharedMemory.GetU64(lifo + 0x18);
        const size_t entry = lifo + LifoHeaderSize + cast(size_t) lifoEnd * LifoEntrySize;

        SharedMemory.SetU64(entry, state.SamplingNumber);
        SharedMemory.Bytes[entry + 8 .. entry + 8 + NpadCommonState.sizeof] = (cast(const(ubyte)*) &state)[0 .. NpadCommonState.sizeof];
        SharedMemory.SetU64(lifo + 0x08, LifoCapacity);
        SharedMemory.SetU64(lifo + 0x10, lifoEnd);
        SharedMemory.SetU64(lifo + 0x18, count < LifoCapacity ? count + 1 : LifoCapacity);
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
        Command(203, "CreateActiveVibrationDeviceList", (IpcContext c) => c.PushInterface(new ActiveVibrationDeviceListService()));
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

final class ActiveVibrationDeviceListService : IPCService {
    this() {
        Stub(0, "ActivateVibrationDevice");
    }

    override string Name() const {
        return "hid::IActiveVibrationDeviceList";
    }
}
