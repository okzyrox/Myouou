/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * nvdrv: GPU devices
*/

module Source.Service.NvGpu;

// Std
import core.bitop : bsr;

// Core
import Source.Gpu.Gpu;
import Source.Gpu.MemoryManager;
import Source.Kernel.Objects;
import Source.Service.Nvdrv;

// Types
struct NvFence {
    uint Id;
    uint Value;
}

struct GpuCharacteristics {
    uint Arch = 0x120;
    uint Impl = 0xB;
    uint Rev = 0xA1;
    uint NumGpc = 1;
    ulong L2CacheSize = 0x40000;
    ulong OnBoardVideoMemorySize = 0;
    uint NumTpcPerGpc = 2;
    uint BusType = 0x20;
    uint BigPageSize = 0x20000;
    uint CompressionPageSize = 0x20000;
    uint PdeCoverageBitCount = 0x1B;
    uint AvailableBigPageSizes = 0x30000;
    uint GpcMask = 1;
    uint SmArchSmVersion = 0x503;
    uint SmArchSpaVersion = 0x503;
    uint SmArchWarpCount = 0x80;
    uint GpuVaBitCount = 0x28;
    uint Reserved = 0;
    ulong Flags = 0x55;
    uint TwodClass = GpuClass.Twod;
    uint ThreedClass = GpuClass.ThreeD;
    uint ComputeClass = GpuClass.Compute;
    uint GpfifoClass = GpuClass.GpFifo;
    uint InlineToMemoryClass = GpuClass.InlineToMemory;
    uint DmaCopyClass = GpuClass.DmaCopy;
    uint MaxFbpsCount = 1;
    uint FbpEnMask = 0;
    uint MaxLtcPerFbp = 2;
    uint MaxLtsPerLtc = 1;
    uint MaxTexPerTpc = 0;
    uint MaxGpcCount = 1;
    uint RopL2EnMask0 = 0x21D70;
    uint RopL2EnMask1 = 0;
    ulong ChipName = 0x6230326D67;
    ulong GrCompbitStoreBaseHw = 0;
}

static assert(GpuCharacteristics.sizeof == 0xA0);

struct VaRegion {
    ulong Offset;
    uint PageSize;
    uint Padding;
    ulong Pages;
}

private T Get(T)(const(ubyte)[] data, size_t offset) {
    if (offset + T.sizeof > data.length)
        return T.init;
    return *cast(const(T)*) (data.ptr + offset);
}

private void Put(T)(ubyte[] data, size_t offset, T value) {
    if (offset + T.sizeof <= data.length)
        *cast(T*) (data.ptr + offset) = value;
}

private void PutBytes(T)(ubyte[] data, size_t offset, const ref T value) {
    const size_t end = offset + T.sizeof < data.length ? offset + T.sizeof : data.length;
    if (offset < end)
        data[offset .. end] = (cast(const(ubyte)*) &value)[0 .. end - offset];
}

// IOCTls.
enum CtrlGpuIoctl : uint {
    ZcullGetCtxSize = 0x01,
    ZcullGetInfo = 0x02,
    GetCharacteristics = 0x05,
    GetTpcMasks = 0x06,
    GetActiveSlotMask = 0x14,
    GetGpuTime = 0x1C,
}

enum AsGpuIoctl : uint {
    BindChannel = 0x01,
    AllocSpace = 0x02,
    FreeSpace = 0x03,
    UnmapBuffer = 0x05,
    MapBufferEx = 0x06,
    GetVaRegions = 0x08,
    InitializeEx = 0x09,
    Remap = 0x14,
}

enum ChannelIoctl : uint {
    SetNvmapFd = 0x01,
    SetTimeout = 0x03,
    SubmitGpfifo = 0x08,
    AllocObjCtx = 0x09,
    ZcullBind = 0x0B,
    SetErrorNotifier = 0x0C,
    SetPriority = 0x0D,
    AllocGpfifoEx2 = 0x1A,
    SubmitGpfifoEx = 0x1B,
    SetTimeslice = 0x1D,
}

// Devices
final class NvHostCtrlGpuDevice : NvDevice {
    private Gpu gpu;

    this(Gpu gpu) {
        super("/dev/nvhost-ctrl-gpu");
        this.gpu = gpu;
    }

    override NvError Ioctl(NvIoctl request, ubyte[] data) {
        return Ioctl3(request, data, null);
    }

    override NvError Ioctl3(NvIoctl request, ubyte[] data, ubyte[] inlineOutput) {
        switch (request.Number) {
            case CtrlGpuIoctl.ZcullGetCtxSize:
                Put!uint(data, 0, 1);
                return NvError.Success;
            case CtrlGpuIoctl.ZcullGetInfo:
                static immutable uint[10] zcullInfo = [0x20, 0x20, 0x400, 0x800, 0x20, 0x20, 0xC0, 0x20, 0x40, 0x10];
                foreach (i, value; zcullInfo)
                    Put!uint(data, i * 4, value);
                return NvError.Success;
            case CtrlGpuIoctl.GetCharacteristics: {
                const GpuCharacteristics characteristics;
                Put!ulong(data, 0, GpuCharacteristics.sizeof);
                PutBytes(data, 0x10, characteristics);
                PutBytes(inlineOutput, 0, characteristics);
                log.Trace("GetCharacteristics");
                return NvError.Success;
            }
            case CtrlGpuIoctl.GetTpcMasks:
                if (Get!uint(data, 0) != 0) {
                    Put!uint(data, 0x10, 3);
                    Put!uint(inlineOutput, 0, 3);
                }
                return NvError.Success;
            case CtrlGpuIoctl.GetActiveSlotMask:
                Put!uint(data, 0, 0x07);
                Put!uint(data, 4, 0x01);
                return NvError.Success;
            case CtrlGpuIoctl.GetGpuTime:
                Put!ulong(data, 0, gpu.Ticks());
                return NvError.Success;
            default:
                return super.Ioctl(request, data);
        }
    }
}

final class NvHostAsGpuDevice : NvDevice {
    private Gpu gpu;
    private NvMapDevice nvmap;
    private uint bigPageSize = 0x10000;

    this(Gpu gpu, NvMapDevice nvmap) {
        super("/dev/nvhost-as-gpu");
        this.gpu = gpu;
        this.nvmap = nvmap;
    }

    private GpuMemoryManager Memory() {
        return gpu.MemoryManager;
    }

    override NvError Ioctl(NvIoctl request, ubyte[] data) {
        return Ioctl3(request, data, null);
    }

    override NvError Ioctl3(NvIoctl request, ubyte[] data, ubyte[] inlineOutput) {
        switch (request.Number) {
            case AsGpuIoctl.BindChannel:
                return NvError.Success;
            case AsGpuIoctl.AllocSpace: return AllocSpace(data);
            case AsGpuIoctl.FreeSpace:
                Memory.FreeReservation(Get!ulong(data, 0));
                return NvError.Success;
            case AsGpuIoctl.UnmapBuffer:
                Memory.Unmap(Get!ulong(data, 0));
                return NvError.Success;
            case AsGpuIoctl.MapBufferEx: return MapBufferEx(data);
            case AsGpuIoctl.GetVaRegions: return GetVaRegions(data, inlineOutput);
            case AsGpuIoctl.InitializeEx:
                const uint requested = Get!uint(data, 0);
                if (requested >= 0x1000 && (requested & (requested - 1)) == 0)
                    bigPageSize = requested;
                log.Trace("InitializeEx with big page size 0x%X", bigPageSize);
                return NvError.Success;
            case AsGpuIoctl.Remap: return Remap(data);
            default:
                return super.Ioctl(request, data);
        }
    }

    private NvError AllocSpace(ubyte[] data) {
        const ulong pages = Get!uint(data, 0);
        const ulong pageSize = Get!uint(data, 4);
        const uint flags = Get!uint(data, 8);
        const ulong offsetOrAlign = Get!ulong(data, 0x10);
        const ulong size = pages * pageSize;
        const bool fixed = (flags & 1) != 0;
        const ulong address = Memory.Reserve(fixed ? offsetOrAlign : 0, size, fixed || offsetOrAlign == 0 ? pageSize : offsetOrAlign);
        Put!ulong(data, 0x10, address);
        return NvError.Success;
    }

    private NvError MapBufferEx(ubyte[] data) {
        const uint flags = Get!uint(data, 0);
        const uint handle = Get!uint(data, 8);
        const ulong pageSize = Get!uint(data, 0xC);
        const ulong bufferOffset = Get!ulong(data, 0x10);
        ulong mappingSize = Get!ulong(data, 0x18);
        ulong gpuAddress = Get!ulong(data, 0x20);

        NvMapObject* map = nvmap.FromHandle(handle);
        if (map is null) {
            log.Warn("MapBufferEx with unknown nvmap handle %d", handle);
            return NvError.BadValue;
        }
        if (mappingSize == 0)
            mappingSize = map.Size - bufferOffset;

        const bool fixed = (flags & 1) != 0;
        const bool remap = (flags & 0x100) != 0;
        if (!fixed && !remap)
            gpuAddress = Memory.Allocate(mappingSize, pageSize > bigPageSize ? pageSize : bigPageSize);

        Memory.Map(gpuAddress, map.Address + bufferOffset, mappingSize);
        Put!ulong(data, 0x20, gpuAddress);
        return NvError.Success;
    }

    private NvError GetVaRegions(ubyte[] data, ubyte[] inlineOutput) {
        VaRegion[2] regions = [
            VaRegion(0x0400_0000, 0x1000, 0, (GpuAddressSpaceStart - 0x0400_0000) / 0x1000),
            VaRegion(GpuAddressSpaceStart, bigPageSize, 0, (GpuAddressSpaceEnd - GpuAddressSpaceStart) / bigPageSize),
        ];
        Put!uint(data, 8, cast(uint) regions.sizeof);
        PutBytes(data, 0x10, regions);
        PutBytes(inlineOutput, 0, regions);
        return NvError.Success;
    }

    private NvError Remap(ubyte[] data) {
        const uint shift = bsr(bigPageSize);
        for (size_t offset = 0; offset + 0x14 <= data.length; offset += 0x14) { // remaps are biig pages
            const uint handle = Get!uint(data, offset + 4);
            const ulong mapOffset = cast(ulong) Get!uint(data, offset + 8) << shift;
            const ulong gpuAddress = cast(ulong) Get!uint(data, offset + 0xC) << shift;
            const ulong size = cast(ulong) Get!uint(data, offset + 0x10) << shift;
            if (handle == 0) {
                Memory.Unmap(gpuAddress, size);
                continue;
            }
            NvMapObject* map = nvmap.FromHandle(handle);
            if (map is null)
                return NvError.BadValue;
            Memory.Map(gpuAddress, map.Address + mapOffset, size);
        }
        return NvError.Success;
    }
}

final class NvHostGpuChannelDevice : NvDevice {
    private Gpu gpu;
    private uint syncpointId;
    private KEvent[uint] events;

    this(Gpu gpu, uint syncpointId) {
        super("/dev/nvhost-gpu");
        this.gpu = gpu;
        this.syncpointId = syncpointId;
    }

    override KEvent QueryEvent(uint eventId) {
        KEvent* found = eventId in events;
        if (found !is null)
            return *found;
        KEvent event = new KEvent("NvChannelEvent", false);
        events[eventId] = event;
        return event;
    }

    override NvError Ioctl(NvIoctl request, ubyte[] data) {
        return Ioctl2(request, data, null);
    }

    override NvError Ioctl2(NvIoctl request, ubyte[] data, const(ubyte)[] inlineInput) {
        switch (request.Number) {
            case ChannelIoctl.SetNvmapFd:
            case ChannelIoctl.SetTimeout:
            case ChannelIoctl.ZcullBind:
            case ChannelIoctl.SetErrorNotifier:
            case ChannelIoctl.SetPriority:
            case ChannelIoctl.SetTimeslice:
                return NvError.Success;
            case ChannelIoctl.SubmitGpfifo:
                return Submit(data, data.length > 0x18 ? data[0x18 .. $] : null);
            case ChannelIoctl.SubmitGpfifoEx:
                return Submit(data, inlineInput);
            case ChannelIoctl.AllocObjCtx:
                log.Trace("AllocObjCtx class 0x%X", Get!uint(data, 0));
                Put!ulong(data, 8, Get!uint(data, 0));
                return NvError.Success;
            case ChannelIoctl.AllocGpfifoEx2:
                Put!uint(data, 0xC, syncpointId);
                Put!uint(data, 0x10, gpu.Syncpoints[syncpointId]);
                log.Trace("AllocGpfifoEx2 with %d entries, syncpoint %d", Get!uint(data, 0), syncpointId);
                return NvError.Success;
            default:
                return super.Ioctl(request, data);
        }
    }

    private NvError Submit(ubyte[] data, const(ubyte)[] entryBytes) {
        const uint count = Get!uint(data, 8);
        // todo: fix fence wait flags being ignored
        const uint flags = Get!uint(data, 0xC);
        const size_t available = entryBytes.length / 8;
        const size_t used = count < available ? count : available;
        const(ulong)[] entries = (cast(const(ulong)*) entryBytes.ptr)[0 .. used];

        gpu.SubmitGpFifo(entries);

        uint value = gpu.Syncpoints[syncpointId];
        if ((flags & 2) != 0)
            value = gpu.IncrementSyncpoint(syncpointId, (flags & 0x100) != 0 ? Get!uint(data, 0x14) : 1);
        Put!uint(data, 0x10, syncpointId);
        Put!uint(data, 0x14, value);
        return NvError.Success;
    }
}
