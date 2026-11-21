/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Tegra GPU command processing
*/

module Source.Gpu.Gpu;

// Std
import core.time : MonoTime;

// Core
import Source.Gpu.Engines;
import Source.Gpu.Maxwell3D;
import Source.Gpu.MemoryManager;
import Source.Memory.Guest;
import Source.Util.Logger;

// Types
enum uint MaxSyncpoints = 192;
enum uint SubchannelCount = 8;

enum GpuClass : uint {
    Twod = 0x902D,
    ThreeD = 0xB197,
    Compute = 0xB1C0,
    GpFifo = 0xB06F,
    InlineToMemory = 0xA140,
    DmaCopy = 0xB0B5,
}

enum PushOpcode : uint {
    Grp0 = 0,
    Incrementing = 1,
    Grp2 = 2,
    NonIncrementing = 3,
    Immediate = 4,
    IncrementOnce = 5,
}

enum PullerMethod : uint {
    BindObject = 0x00,
    Nop = 0x02,
    SemaphoreAddressHigh = 0x04,
    SemaphoreAddressLow = 0x05,
    SemaphorePayload = 0x06,
    SemaphoreOperation = 0x07,
    NonStallInterrupt = 0x08,
    FbFlush = 0x09,
    MemOpA = 0x0A,
    MemOpB = 0x0B,
    SetReference = 0x14,
    SyncpointPayload = 0x1C,
    SyncpointOperation = 0x1D,
    WaitForIdle = 0x1E,
    PullerEngineMethods = 0x40,
}

struct GpFifoEntry {
    ulong Raw;

    ulong Address() const {
        return Raw & 0xFF_FFFF_FFFC;
    }

    uint WordCount() const {
        return cast(uint) ((Raw >> 42) & 0x1F_FFFF);
    }
}

// Class
final class Gpu {
    GpuMemoryManager MemoryManager;
    Maxwell3D ThreeD;
    uint[MaxSyncpoints] Syncpoints;

    private GpuEngine[uint] engines;
    private GpuEngine[SubchannelCount] bound;
    private uint[0x40] pullerRegisters;
    private MonoTime startTime;
    private Logger log;

    this(GuestMemory memory) {
        MemoryManager = new GpuMemoryManager(memory);
        ThreeD = new Maxwell3D(this);
        engines[GpuClass.ThreeD] = ThreeD;
        engines[GpuClass.Compute] = new RegisterEngine(this, "Compute", 0x1000);
        engines[GpuClass.Twod] = new RegisterEngine(this, "Fermi2D", 0x1000);
        engines[GpuClass.InlineToMemory] = new InlineToMemoryEngine(this);
        engines[GpuClass.DmaCopy] = new DmaCopyEngine(this);
        startTime = MonoTime.currTime;
        log = GetLogger("Gpu");
    }

    ulong Ticks() const {
        return cast(ulong) ((MonoTime.currTime - startTime).total!"nsecs");
    }

    uint IncrementSyncpoint(uint id, uint amount = 1) {
        if (id >= MaxSyncpoints)
            return 0;
        Syncpoints[id] += amount;
        return Syncpoints[id];
    }

    void WriteReport(ulong address, ulong value, bool shortReport) {
        if (shortReport) {
            MemoryManager.Write!uint(address, cast(uint) value);
            return;
        }
        MemoryManager.Write!ulong(address, value);
        MemoryManager.Write!ulong(address + 8, Ticks());
    }

    void SubmitGpFifo(const(ulong)[] entries) {
        // todo: move to a GPU thread
        foreach (raw; entries) {
            const GpFifoEntry entry = GpFifoEntry(raw);
            const uint count = entry.WordCount;
            if (count == 0)
                continue;
            uint[] words = new uint[count];
            MemoryManager.Read(entry.Address, cast(ubyte[]) words);
            ProcessPushBuffer(words);
        }
        ThreeD.FlushDraws();
    }

    private void ProcessPushBuffer(const(uint)[] words) {
        size_t i = 0;
        while (i < words.length) {
            const uint header = words[i++];
            const uint method = header & 0x1FFF;
            const uint subchannel = (header >> 13) & 0x7;
            const uint argument = (header >> 16) & 0x1FFF;
            const PushOpcode opcode = cast(PushOpcode) (header >> 29);

            switch (opcode) {
                case PushOpcode.Immediate:
                    CallMethod(subchannel, method, argument, true);
                    break;
                case PushOpcode.Incrementing:
                case PushOpcode.NonIncrementing:
                case PushOpcode.IncrementOnce:
                    foreach (n; 0 .. argument) {
                        if (i >= words.length)
                            return;
                        uint target = method;
                        if (opcode == PushOpcode.Incrementing)
                            target = method + n;
                        else if (opcode == PushOpcode.IncrementOnce && n > 0)
                            target = method + 1;
                        CallMethod(subchannel, target, words[i++], n + 1 == argument);
                    }
                    break;
                case PushOpcode.Grp0:
                case PushOpcode.Grp2:
                    if (header != 0)
                        log.Stub("Unknown pushbuffer opcode %d (header 0x%08X)", opcode, header);
                    break;
                default:
                    log.Warn("Bad pushbuffer 0x%08X", header);
                    return;
            }
        }
    }

    void CallMethod(uint subchannel, uint method, uint argument, bool isLastCall) {
        if (method < PullerMethod.PullerEngineMethods) {
            CallPullerMethod(subchannel, method, argument);
            return;
        }
        GpuEngine engine = bound[subchannel];
        if (engine is null) {
            log.Warn("Method 0x%X on unbound subchannel %d", method, subchannel);
            return;
        }
        engine.CallMethod(method, argument, isLastCall);
    }

    private void CallPullerMethod(uint subchannel, uint method, uint argument) {
        pullerRegisters[method] = argument;
        switch (method) {
            case PullerMethod.BindObject:
                GpuEngine* engine = argument in engines;
                if (engine is null) {
                    log.Warn("Unknown class 0x%X bound to subchannel %d", argument, subchannel);
                    return;
                }
                bound[subchannel] = *engine;
                log.Trace("Bound class 0x%X (%s) to subchannel %d", argument, engine.Name, subchannel);
                break;
            case PullerMethod.SemaphoreOperation:
                SemaphoreOperation(argument);
                break;
            case PullerMethod.SyncpointOperation:
                const uint id = (argument >> 8) & 0xFF;
                if ((argument & 1) != 0)
                    IncrementSyncpoint(id);
                break;
            default:
                break;
        }
    }

    private void SemaphoreOperation(uint argument) {
        const ulong address = (cast(ulong) pullerRegisters[PullerMethod.SemaphoreAddressHigh] << 32) | pullerRegisters[PullerMethod.SemaphoreAddressLow];
        const uint payload = pullerRegisters[PullerMethod.SemaphorePayload];
        switch (argument & 0x1F) {
            case 2:
                WriteReport(address, payload, (argument & (1 << 24)) != 0);
                break;
            default:
                // todo: fix semaphore acquires being skipped, as they wont be safe in async
                break;
        }
    }
}
