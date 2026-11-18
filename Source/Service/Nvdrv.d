/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * nvdrv: some NVIDIA driver services / devices
*/

module Source.Service.Nvdrv;

// Std
import std.format : format;
import std.algorithm : startsWith;
import std.string : fromStringz;

// Core
import Source.Util.Logger;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Service.Service;

// Types
enum NvError : uint {
    Success = 0,
    NotImplemented = 1,
    NotSupported = 2,
    NotInitialized = 3,
    BadParameter = 4,
    Timeout = 5,
    InsufficientMemory = 6,
    ReadOnlyAttribute = 7,
    InvalidState = 8,
    InvalidAddress = 9,
    InvalidSize = 10,
    BadValue = 11,
    FileOperationFailed = 0x30003,
}

struct NvIoctl {
    uint Raw;

    uint Number() const {
        return Raw & 0xFF;
    }

    uint Group() const {
        return (Raw >> 8) & 0xFF;
    }

    size_t Size() const {
        return (Raw >> 16) & 0x3FFF;
    }

    bool HasInput() const {
        return (Raw & 0x4000_0000) != 0;
    }

    bool HasOutput() const {
        return (Raw & 0x8000_0000) != 0;
    }
}

struct NvMapObject {
    uint Handle;
    uint Id;
    uint Size;
    uint Align;
    uint HeapMask;
    uint Flags;
    ubyte Kind;
    ulong Address;
    bool Allocated;
}

private T Field(T)(const(ubyte)[] data, size_t offset) {
    if (offset + T.sizeof > data.length)
        return T.init;
    return *cast(const(T)*) (data.ptr + offset);
}

private void SetField(T)(ubyte[] data, size_t offset, T value) {
    if (offset + T.sizeof <= data.length)
        *cast(T*) (data.ptr + offset) = value;
}

// Devices
abstract class NvDevice {
    immutable string Path;
    protected Logger log;

    this(string path) {
        Path = path;
        log = GetLogger("nvdrv::" ~ (path.startsWith("/dev/") ? path[5 .. $] : path));
    }

    Logger Log() {
        return log;
    }

    NvError Ioctl(NvIoctl request, ubyte[] data) {
        log.Stub("No ioctl 0x%08X (group 0x%02X nr 0x%02X)", request.Raw, request.Group, request.Number);
        return NvError.Success;
    }

    KEvent QueryEvent(uint eventId) {
        return null;
    }
}

final class NvStubDevice : NvDevice {
    this(string path) {
        super(path);
    }
}

final class NvMapDevice : NvDevice {
    private NvMapObject*[uint] handles;
    private NvMapObject*[uint] ids;
    private uint nextHandle = 1;
    private uint nextId = 1;

    this() {
        super("/dev/nvmap");
    }

    NvMapObject* FromHandle(uint handle) {
        NvMapObject** found = handle in handles;
        return found is null ? null : *found;
    }

    NvMapObject* FromId(uint id) {
        NvMapObject** found = id in ids;
        return found is null ? null : *found;
    }

    override NvError Ioctl(NvIoctl request, ubyte[] data) {
        switch (request.Raw) {
            case 0xC0080101: return Create(data);
            case 0xC0080103: return FromIdIoctl(data);
            case 0xC0200104: return Alloc(data);
            case 0xC0180105: return Free(data);
            case 0xC00C0109: return Param(data);
            case 0xC008010E: return GetId(data);
            default: return super.Ioctl(request, data);
        }
    }

    private NvError Create(ubyte[] data) {
        const uint size = Field!uint(data, 0);
        if (size == 0)
            return NvError.BadValue;
        NvMapObject* map = new NvMapObject(nextHandle++, nextId++, size);
        handles[map.Handle] = map;
        ids[map.Id] = map;
        SetField!uint(data, 4, map.Handle);
        log.Trace("Create with size 0x%X. out handle %d", size, map.Handle);
        return NvError.Success;
    }

    private NvError FromIdIoctl(ubyte[] data) {
        NvMapObject* map = FromId(Field!uint(data, 0));
        if (map is null)
            return NvError.BadValue;
        SetField!uint(data, 4, map.Handle);
        return NvError.Success;
    }

    private NvError Alloc(ubyte[] data) {
        NvMapObject* map = FromHandle(Field!uint(data, 0));
        if (map is null)
            return NvError.BadValue;
        map.HeapMask = Field!uint(data, 4);
        map.Flags = Field!uint(data, 8);
        map.Align = Field!uint(data, 12);
        map.Kind = Field!ubyte(data, 16);
        map.Address = Field!ulong(data, 24);
        map.Allocated = true;
        log.Trace("Allocated handle (%d) at 0x%X (size 0x%X, 0x%X, kind 0x%X)", map.Handle, map.Address, map.Size, map.Align, map.Kind);
        return NvError.Success;
    }

    private NvError Free(ubyte[] data) {
        const uint handle = Field!uint(data, 0);
        NvMapObject* map = FromHandle(handle);
        if (map is null)
            return NvError.BadValue;
        SetField!ulong(data, 8, map.Address);
        SetField!uint(data, 16, map.Size);
        SetField!uint(data, 20, map.Flags);
        handles.remove(handle);
        ids.remove(map.Id);
        return NvError.Success;
    }

    private NvError Param(ubyte[] data) {
        NvMapObject* map = FromHandle(Field!uint(data, 0));
        if (map is null)
            return NvError.BadValue;
        uint value;
        switch (Field!uint(data, 4)) {
            case 1: value = map.Size; break;
            case 2: value = map.Align; break;
            case 3: value = cast(uint) map.Address; break;
            case 4: value = map.HeapMask; break;
            case 5: value = map.Kind; break;
            case 6: value = map.Allocated ? 1 : 0; break;
            default: return NvError.BadValue;
        }
        SetField!uint(data, 8, value);
        return NvError.Success;
    }

    private NvError GetId(ubyte[] data) {
        NvMapObject* map = FromHandle(Field!uint(data, 4));
        if (map is null)
            return NvError.BadValue;
        SetField!uint(data, 0, map.Id);
        return NvError.Success;
    }
}

final class NvHostCtrlDevice : NvDevice {
    private KEvent[uint] events;

    this() {
        super("/dev/nvhost-ctrl");
    }

    override NvError Ioctl(NvIoctl request, ubyte[] data) {
        switch (request.Number) {
            case 0x1B:
                log.Trace("GetConfig");
                return NvError.NotSupported;
            case 0x1C:
                log.Trace("EventSignal");
                return NvError.Success;
            case 0x1D:
            case 0x1E:
                SetField!uint(data, 12, Field!uint(data, 4));
                log.Trace("EventWait syncpoint %d threshold %d", Field!uint(data, 0), Field!uint(data, 4));
                return NvError.Success;
            case 0x1F:
            case 0x20:
            case 0x21:
                return NvError.Success;
            default:
                return super.Ioctl(request, data);
        }
    }

    override KEvent QueryEvent(uint eventId) {
        KEvent* found = eventId in events;
        if (found !is null)
            return *found;
        KEvent event = new KEvent(format("NvHostEvent%d", eventId), true);
        events[eventId] = event;
        return event;
    }
}

// State
final class NvState {
    NvMapDevice Map;
    NvHostCtrlDevice HostCtrl;
    private NvDevice[uint] files;
    private uint nextFd = 1;

    this() {
        Map = new NvMapDevice();
        HostCtrl = new NvHostCtrlDevice();
    }

    NvDevice Open(string path) {
        switch (path) {
            case "/dev/nvmap": return Map;
            case "/dev/nvhost-ctrl": return HostCtrl;
            default: return new NvStubDevice(path);
        }
    }

    uint AddFile(NvDevice device) {
        const uint fd = nextFd++;
        files[fd] = device;
        return fd;
    }

    NvDevice File(uint fd) {
        NvDevice* found = fd in files;
        return found is null ? null : *found;
    }

    bool CloseFile(uint fd) {
        return files.remove(fd);
    }
}

// Service
final class NvdrvService : IPCService {
    private NvState state;
    private string name;

    this(string name, NvState state) {
        this.name = name;
        this.state = state;
        Command(0, "Open", &Open);
        Command(1, "Ioctl", &Ioctl);
        Command(2, "Close", &Close);
        Command(3, "Initialize", (IpcContext c) => c.Push!uint(NvError.Success));
        Command(4, "QueryEvent", &QueryEvent);
        Command(6, "GetStatus", (IpcContext c) => c.Push!uint(NvError.Success));
        Command(8, "SetAruid", (IpcContext c) => c.Push!uint(NvError.Success));
        Command(9, "DumpGraphicsMemoryInfo", (IpcContext c) => c.Push!uint(NvError.Success));
        Command(11, "Ioctl2", &Ioctl);
        Command(12, "Ioctl3", &Ioctl);
        Command(13, "SetGraphicsFirmwareMemoryMarginEnabled", (IpcContext c) => c.Push!uint(NvError.Success));
    }

    override string Name() const {
        return name;
    }

    private void Open(IpcContext context) {
        const(ubyte)[] raw = context.ReadInput(0);
        const string path = fromStringz(cast(const(char)*) (raw ~ cast(ubyte) 0).ptr).idup;
        NvDevice device = state.Open(path);
        const uint fd = state.AddFile(device);
        Log.Trace("Open device %s. ret fd %d", path, fd);
        context.Push!uint(fd);
        context.Push!uint(NvError.Success);
    }

    private void Ioctl(IpcContext context) {
        const uint fd = context.Pop!uint();
        const NvIoctl request = NvIoctl(context.Pop!uint());
        NvDevice device = state.File(fd);
        if (device is null) {
            Log.Warn("Ioctl 0x%08X on unknown fd %d", request.Raw, fd);
            context.Push!uint(NvError.NotInitialized);
            return;
        }

        ubyte[] data = new ubyte[request.Size];
        if (request.HasInput) {
            const(ubyte)[] input = context.ReadInput(0);
            const size_t length = input.length < data.length ? input.length : data.length;
            data[0 .. length] = input[0 .. length];
        }

        const NvError result = device.Ioctl(request, data);
        if (request.HasOutput)
            context.WriteOutput(0, data);
        context.Push!uint(result);
    }

    private void Close(IpcContext context) {
        const uint fd = context.Pop!uint();
        context.Push!uint(state.CloseFile(fd) ? NvError.Success : NvError.BadValue);
    }

    private void QueryEvent(IpcContext context) {
        const uint fd = context.Pop!uint();
        const uint eventId = context.Pop!uint();
        NvDevice device = state.File(fd);
        KEvent event = device is null ? null : device.QueryEvent(eventId);
        if (event is null) {
            Log.Stub("QueryEvent's fd (%d) event 0x%X has no event!", fd, eventId);
            context.Push!uint(NvError.BadValue);
            return;
        }
        context.PushCopyHandle(event);
        context.Push!uint(NvError.Success);
    }
}
