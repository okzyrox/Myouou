/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Android Surface IGraphicBufferProducer over vi
 * (effectively translated over from Android Surface, sorry... )
*/

module Source.Graphics.BufferQueue;

// Core
import Source.Util.Logger;
import Source.Frontend.HostDisplay;
import Source.Graphics.BlockLinear;
import Source.Graphics.Parcel;
import Source.Kernel.Objects;
import Source.Memory.Guest;
import Source.Service.Nvdrv;

// Types
enum ProducerTransaction : uint {
    RequestBuffer = 1,
    SetBufferCount = 2,
    DequeueBuffer = 3,
    DetachBuffer = 4,
    DetachNextBuffer = 5,
    AttachBuffer = 6,
    QueueBuffer = 7,
    CancelBuffer = 8,
    Query = 9,
    Connect = 10,
    Disconnect = 11,
    SetSidebandStream = 12,
    AllocateBuffers = 13,
    SetPreallocatedBuffer = 14,
}

enum BufferSlotState {
    Free,
    Dequeued,
    Queued,
}

enum NvSurfaceLayout : uint {
    Pitch = 1,
    Tiled = 2,
    BlockLinear = 3,
}

enum size_t MaxBufferSlots = 64;
enum size_t MultiFenceSize = 0x24;
enum size_t QueueInputTransformOffset = 0x20;

struct QueueBufferOutput {
    uint Width;
    uint Height;
    uint TransformHint;
    uint PendingBuffers;
}

struct GraphicBufferInfo {
    uint Width;
    uint Height;
    uint Stride;
    GuestPixelFormat Format;
    uint NvMapId;
    uint PlaneWidth;
    uint PlaneHeight;
    NvSurfaceLayout Layout;
    uint Pitch;
    uint Offset;
    uint BlockHeightLog2;

    static GraphicBufferInfo Parse(const(ubyte)[] raw) {
        uint At(size_t offset) {
            return offset + 4 <= raw.length ? *cast(const(uint)*) (raw.ptr + offset) : 0;
        }

        GraphicBufferInfo info;
        info.Width = At(0x04);
        info.Height = At(0x08);
        info.Stride = At(0x0C);
        info.Format = cast(GuestPixelFormat) At(0x10);
        info.NvMapId = At(0x2C);
        info.PlaneWidth = At(0x5C);
        info.PlaneHeight = At(0x60);
        info.Layout = cast(NvSurfaceLayout) At(0x6C);
        info.Pitch = At(0x70);
        info.Offset = At(0x78);
        info.BlockHeightLog2 = At(0x80);
        return info;
    }
}

struct BufferSlot {
    BufferSlotState State;
    ubyte[] GraphicBuffer;
    GraphicBufferInfo Info;
}

// Class
final class BufferQueue {
    immutable int BinderId;
    ulong LayerId;
    KEvent BufferEvent;
    uint DefaultWidth = 1280;
    uint DefaultHeight = 720;

    private BufferSlot[MaxBufferSlots] slots;
    private size_t nextSlot;
    private bool connected;
    private int strongRefs;
    private int weakRefs;
    private GuestMemory memory;
    private NvState nv;
    private HostDisplay display;
    private KEvent vsyncEvent;
    private ubyte[] frame;
    private Logger log;

    this(int binderId, ulong layerId, GuestMemory memory, NvState nv, HostDisplay display, KEvent vsyncEvent) {
        BinderId = binderId;
        LayerId = layerId;
        this.memory = memory;
        this.nv = nv;
        this.display = display;
        this.vsyncEvent = vsyncEvent;
        BufferEvent = new KEvent("BufferQueue", true);
        log = GetLogger("vi::BufferQueue");
    }

    void AdjustRefcount(int amount, int type) {
        if (type == 0)
            weakRefs += amount;
        else
            strongRefs += amount;
    }

    ubyte[] Transact(uint code, const(ubyte)[] rawInput) {
        ParcelReader input = ParcelReader.FromRaw(rawInput);
        ParcelWriter output;
        input.ReadInterfaceToken();

        int status = 0;
        switch (code) {
            case ProducerTransaction.RequestBuffer: status = RequestBuffer(input, output); break;
            case ProducerTransaction.SetBufferCount: break;
            case ProducerTransaction.DequeueBuffer: status = DequeueBuffer(input, output); break;
            case ProducerTransaction.QueueBuffer: status = QueueBuffer(input, output); break;
            case ProducerTransaction.CancelBuffer: status = CancelBuffer(input); break;
            case ProducerTransaction.Query: status = Query(input, output); break;
            case ProducerTransaction.Connect: status = Connect(output); break;
            case ProducerTransaction.Disconnect: connected = false; break;
            case ProducerTransaction.SetPreallocatedBuffer: status = SetPreallocatedBuffer(input); break;
            default:
                log.Stub("pt %d", code);
                break;
        }

        output.Write!int(status);
        log.Trace("%s -> status %d", cast(ProducerTransaction) code, status);
        return output.Serialize();
    }

    private bool ValidSlot(int slot) const {
        return slot >= 0 && slot < MaxBufferSlots;
    }

    private int RequestBuffer(ref ParcelReader input, ref ParcelWriter output) {
        const int slot = input.Read!int();
        if (!ValidSlot(slot))
            return -22;
        if (slots[slot].GraphicBuffer.length == 0) {
            output.Write!int(0);
            return 0;
        }
        output.Write!int(1);
        output.WriteFlattenedObject(slots[slot].GraphicBuffer);
        return 0;
    }

    private int DequeueBuffer(ref ParcelReader input, ref ParcelWriter output) {
        foreach (i; 0 .. MaxBufferSlots) {
            const size_t slot = (nextSlot + i) % MaxBufferSlots;
            if (slots[slot].State != BufferSlotState.Free || slots[slot].GraphicBuffer.length == 0)
                continue;

            slots[slot].State = BufferSlotState.Dequeued;
            nextSlot = slot + 1;
            const ubyte[MultiFenceSize] fence;
            output.Write!int(cast(int) slot);
            output.Write!int(1);
            output.WriteFlattenedObject(fence[]);
            return 0;
        }

        log.Warn("DequeueBuffer couldnt find a free slot to dequeue");
        output.Write!int(-1);
        output.Write!int(0);
        return -11;
    }

    private int QueueBuffer(ref ParcelReader input, ref ParcelWriter output) {
        const int slot = input.Read!int();
        if (!ValidSlot(slot)) {
            return -22;
        }
        const(ubyte)[] queued = input.ReadFlattenedObject();
        const uint transform = queued.length >= QueueInputTransformOffset + uint.sizeof ? *cast(const(uint)*) (queued.ptr + QueueInputTransformOffset) : 0;
        slots[slot].State = BufferSlotState.Queued;
        Present(slots[slot], transform);
        slots[slot].State = BufferSlotState.Free;
        BufferEvent.Signal();
        vsyncEvent.Signal();

        const QueueBufferOutput result = QueueBufferOutput(DefaultWidth, DefaultHeight, 0, 0);
        output.WriteData((cast(const(ubyte)*) &result)[0 .. result.sizeof]);
        return 0;
    }

    private int CancelBuffer(ref ParcelReader input) {
        const int slot = input.Read!int();
        if (!ValidSlot(slot)) {
            return -22;
        }
        slots[slot].State = BufferSlotState.Free;
        BufferEvent.Signal();
        return 0;
    }

    private int Query(ref ParcelReader input, ref ParcelWriter output) {
        const int what = input.Read!int();
        int value;
        switch (what) {
            case 0: value = DefaultWidth; break;
            case 1: value = DefaultHeight; break;
            case 2: value = GuestPixelFormat.Rgba8888; break;
            case 3: value = 1; break;
            default: value = 0; break;
        }
        output.Write!int(value);
        return 0;
    }

    private int Connect(ref ParcelWriter output) {
        connected = true;
        const QueueBufferOutput result = QueueBufferOutput(DefaultWidth, DefaultHeight, 0, 0);
        output.WriteData((cast(const(ubyte)*) &result)[0 .. result.sizeof]);
        return 0;
    }

    private int SetPreallocatedBuffer(ref ParcelReader input) {
        const int slot = input.Read!int();
        if (!ValidSlot(slot)) {
            return -22;
        }
        const int hasBuffer = input.Read!int();
        if (hasBuffer == 0) {
            slots[slot] = BufferSlot.init;
            return 0;
        }

        const(ubyte)[] raw = input.ReadFlattenedObject();
        slots[slot].GraphicBuffer = raw.dup;
        slots[slot].Info = GraphicBufferInfo.Parse(raw);
        slots[slot].State = BufferSlotState.Free;
        const GraphicBufferInfo info = slots[slot].Info;
        log.Trace("Preallocated a buffer (%d)!: %dx%d format %s, nvmap %d +0x%X, pitch 0x%X, layout %s, blockheight %d", slot, info.Width, info.Height, info.Format, info.NvMapId, info.Offset, info.Pitch, info.Layout, 1 << info.BlockHeightLog2);
        return 0;
    }

    private void Present(ref BufferSlot slot, uint transform) {
        const GraphicBufferInfo info = slot.Info;
        NvMapObject* map = nv.Map.FromId(info.NvMapId);
        if (map is null || !map.Allocated) {
            log.Warn("Queued buffer references an unknown nvmap id: %d", info.NvMapId);
            return;
        }

        if (display.PresentGuestSurface(map.Address + info.Offset, transform))
            return;

        const uint width = info.PlaneWidth != 0 ? info.PlaneWidth : info.Width;
        const uint height = info.PlaneHeight != 0 ? info.PlaneHeight : info.Height;
        const size_t rowBytes = cast(size_t) width * BytesPerPixel(info.Format);
        const size_t pitch = info.Pitch != 0 ? info.Pitch : rowBytes;
        const bool blFormat = info.Layout == NvSurfaceLayout.BlockLinear;
        const size_t surfaceSize = blFormat ? BlockLinearSize(pitch, height, info.BlockHeightLog2) : pitch * height;

        ubyte[] surface = new ubyte[surfaceSize];
        memory.ReadBytes(map.Address + info.Offset, surface);

        if (blFormat) {
            if (frame.length != rowBytes * height) {
                frame = new ubyte[rowBytes * height];
            }

            // deswizzle GOBs for the display
            // using sdl3 but might change out for native ogl/vk later
            BlockLinearDeswizzle(surface, frame, rowBytes, height, pitch, info.BlockHeightLog2);
            display.Present(frame, width, height, cast(int) rowBytes, info.Format, transform);
        } else {
            display.Present(surface, width, height, cast(int) pitch, info.Format, transform);
        }
    }
}
