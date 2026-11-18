/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * vi: visual interface services
*/

module Source.Service.Vi;

// Core
import Source.Frontend.HostDisplay;
import Source.Graphics.BufferQueue;
import Source.Graphics.Parcel;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Memory.Guest;
import Source.Service.Nvdrv;
import Source.Service.Service;

// Types
enum ViResult : uint {
    InvalidArgument = MakeModuleResult(114, 1),
    NotFound = MakeModuleResult(114, 7),
}

enum DisplayId : ulong {
    Default = 0,
    External,
    Edid,
    Internal,
    Null
}

enum uint DisplayWidth = 1280;
enum uint DisplayHeight = 720;

struct NativeWindow {
    uint Magic = 2;
    uint ProcessId = 1;
    uint BinderId;
    uint[3] Reserved;
    char[8] Driver = "dispdrv\0";
    ulong Padding;
}

// State
final class ViState {
    HostDisplay Display;
    KEvent VsyncEvent;
    private GuestMemory memory;
    private NvState nv;
    private BufferQueue[int] binders;
    private BufferQueue[ulong] layers;
    private int nextBinderId = 1;
    private ulong nextLayerId = 0x100;

    this(GuestMemory memory, NvState nv, HostDisplay display) {
        this.memory = memory;
        this.nv = nv;
        Display = display;
        VsyncEvent = new KEvent("DisplayVsync", true);
    }

    ulong AllocateLayerId() {
        return nextLayerId++;
    }

    BufferQueue Layer(ulong layerId) {
        BufferQueue* found = layerId in layers;
        if (found !is null)
            return *found;
        BufferQueue queue = new BufferQueue(nextBinderId++, layerId, memory, nv, Display, VsyncEvent);
        binders[queue.BinderId] = queue;
        layers[layerId] = queue;
        return queue;
    }

    BufferQueue Binder(int id) {
        BufferQueue* found = id in binders;
        return found is null ? null : *found;
    }

    void CloseLayer(ulong layerId) {
        BufferQueue* found = layerId in layers;
        if (found is null)
            return;
        binders.remove((*found).BinderId);
        layers.remove(layerId);
    }
}

// Utils
private string DisplayName(const ref char[0x40] raw) {
    size_t length;
    while (length < raw.length && raw[length] != 0 && raw[length] != char.init)
        length++;
    return raw[0 .. length].idup;
}

private void WriteNativeWindow(IpcContext context, BufferQueue queue) {
    NativeWindow window;
    window.BinderId = queue.BinderId;
    ParcelWriter parcel;
    parcel.WriteData((cast(const(ubyte)*) &window)[0 .. window.sizeof]);
    context.WriteOutput(0, parcel.Serialize());
    context.Push!ulong(ParcelHeaderSize + window.sizeof);
}

// Services
final class ViRootService : IPCService {
    private string name;

    this(string name, uint commandId, ViState state) {
        this.name = name;
        Command(commandId, "GetDisplayService", (IpcContext c) => c.PushInterface(new ApplicationDisplayService(state)));
    }

    override string Name() const {
        return name;
    }
}

final class ApplicationDisplayService : IPCService {
    private ViState state;

    this(ViState state) {
        this.state = state;
        Command(100, "GetRelayService", (IpcContext c) => c.PushInterface(new HOSBinderDriver(state)));
        Command(101, "GetSystemDisplayService", (IpcContext c) => c.PushInterface(new SystemDisplayService(state)));
        Command(102, "GetManagerDisplayService", (IpcContext c) => c.PushInterface(new ManagerDisplayService(state)));
        Command(103, "GetIndirectDisplayTransactionService", (IpcContext c) => c.PushInterface(new HOSBinderDriver(state)));
        Command(1000, "ListDisplays", &ListDisplays);
        Command(1010, "OpenDisplay", &OpenDisplay);
        Command(1011, "OpenDefaultDisplay", (IpcContext c) => c.Push!ulong(DisplayId.Default));
        Stub(1020, "CloseDisplay");
        Stub(1101, "SetDisplayEnabled");
        Command(1102, "GetDisplayResolution", &GetDisplayResolution);
        Command(2020, "OpenLayer", &OpenLayer);
        Command(2021, "CloseLayer", (IpcContext c) => state.CloseLayer(c.Pop!ulong()));
        Command(2030, "CreateStrayLayer", &CreateStrayLayer);
        Command(2031, "DestroyStrayLayer", (IpcContext c) => state.CloseLayer(c.Pop!ulong()));
        Stub(2101, "SetLayerScalingMode");
        Command(2102, "ConvertScalingMode", (IpcContext c) => c.Push!ulong(c.Pop!uint()));
        Command(5202, "GetDisplayVsyncEvent", (IpcContext c) => c.PushCopyHandle(state.VsyncEvent));
    }

    override string Name() const {
        return "vi::IApplicationDisplayService";
    }

    private void ListDisplays(IpcContext context) {
        ubyte[0x60] entry;
        entry[0 .. 7] = cast(const(ubyte)[]) "Default";
        entry[0x40] = 1;
        *cast(ulong*) (entry.ptr + 0x48) = 1;
        *cast(ulong*) (entry.ptr + 0x50) = DisplayWidth;
        *cast(ulong*) (entry.ptr + 0x58) = DisplayHeight;
        context.WriteOutput(0, entry[]);
        context.Push!ulong(1);
    }

    private void OpenDisplay(IpcContext context) {
        const char[0x40] raw = context.Pop!(char[0x40])();
        const string name = DisplayName(raw);
        Log.Trace("OpenDisplay %s", name);
        context.Push!ulong(DisplayId.Default);
    }

    private void GetDisplayResolution(IpcContext context) {
        context.Push!ulong(DisplayWidth);
        context.Push!ulong(DisplayHeight);
    }

    private void OpenLayer(IpcContext context) {
        const char[0x40] raw = context.Pop!(char[0x40])();
        const ulong layerId = context.Pop!ulong();
        const ulong appletRUID = context.Pop!ulong(); //todo: differentiate to am:ISelfController:CreateManagedDisplayLayer
        BufferQueue queue = state.Layer(layerId);
        Log.Trace("Opening Layer %d on %s for AppletRUID 0x%X -> binder %d", layerId, DisplayName(raw), appletRUID, queue.BinderId);
        WriteNativeWindow(context, queue);
    }

    private void CreateStrayLayer(IpcContext context) {
        context.Pop!uint();
        context.Pop!ulong();
        const ulong layerId = state.AllocateLayerId();
        BufferQueue queue = state.Layer(layerId);
        context.Push!ulong(layerId);
        WriteNativeWindow(context, queue);
    }
}

final class SystemDisplayService : IPCService {
    this(ViState state) {
        Command(1200, "GetZOrderCountMin", (IpcContext c) => c.Push!ulong(0));
        Command(1202, "GetZOrderCountMax", (IpcContext c) => c.Push!ulong(255));
        Command(1203, "GetDisplayLogicalResolution", (IpcContext c) { c.Push!uint(DisplayWidth); c.Push!uint(DisplayHeight); });
        Stub(2201, "SetLayerPosition");
        Stub(2203, "SetLayerSize");
        Stub(2205, "SetLayerZ");
        Stub(2207, "SetLayerVisibility");
        Command(2312, "CreateStrayLayer", (IpcContext c) {
            c.Pop!uint();
            c.Pop!ulong();
            const ulong layerId = state.AllocateLayerId();
            c.Push!ulong(layerId);
            WriteNativeWindow(c, state.Layer(layerId));
        });
        Stub(3200, "GetDisplayMode");
    }

    override string Name() const {
        return "vi::ISystemDisplayService";
    }
}

final class ManagerDisplayService : IPCService {
    this(ViState state) {
        Command(2010, "CreateManagedLayer", (IpcContext c) => c.Push!ulong(state.AllocateLayerId()));
        Command(2011, "DestroyManagedLayer", (IpcContext c) => state.CloseLayer(c.Pop!ulong()));
        Stub(2012, "CreateStrayLayer");
        Stub(6000, "AddToLayerStack");
        Stub(6002, "SetLayerVisibility");
        Stub(7000, "SetContentVisibility");
    }

    override string Name() const {
        return "vi::IManagerDisplayService";
    }
}

final class HOSBinderDriver : IPCService {
    private ViState state;

    this(ViState state) {
        this.state = state;
        Command(0, "TransactParcel", &TransactParcel);
        Command(1, "AdjustRefcount", &AdjustRefcount);
        Command(2, "GetNativeHandle", &GetNativeHandle);
        Command(3, "TransactParcelAuto", &TransactParcel);
    }

    override string Name() const {
        return "vi::IHOSBinderDriver";
    }

    private void TransactParcel(IpcContext context) {
        const int id = context.Pop!int();
        const uint code = context.Pop!uint();
        BufferQueue queue = state.Binder(id);
        if (queue is null) {
            Log.Warn("Unknown transaction %d on unknown %d", code, id);
            context.Result(ViResult.NotFound);
            return;
        }
        context.WriteOutput(0, queue.Transact(code, context.ReadInput(0)));
    }

    private void AdjustRefcount(IpcContext context) {
        const int id = context.Pop!int();
        const int amount = context.Pop!int();
        const int type = context.Pop!int();
        BufferQueue queue = state.Binder(id);
        if (queue !is null)
            queue.AdjustRefcount(amount, type);
    }

    private void GetNativeHandle(IpcContext context) {
        const int id = context.Pop!int();
        BufferQueue queue = state.Binder(id);
        if (queue is null) {
            context.Result(ViResult.NotFound);
            return;
        }
        context.PushCopyHandle(queue.BufferEvent);
    }
}
