/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * GPU engine classes
*/

module Source.Gpu.Engines;

// Core
import Source.Gpu.Gpu;
import Source.Gpu.MemoryManager;
import Source.Graphics.BlockLinear;
import Source.Util.Logger;

// Base
abstract class GpuEngine {
    immutable string Name;
    uint[] Registers;
    protected Gpu gpu;
    protected Logger log;

    this(Gpu gpu, string name, size_t registerCount) {
        this.gpu = gpu;
        Name = name;
        Registers = new uint[registerCount];
        log = GetLogger("Gpu::" ~ name);
    }

    void CallMethod(uint method, uint argument, bool isLastCall) {
        if (method < Registers.length)
            Registers[method] = argument;
    }

    ulong Address(uint highMethod) const {
        return (cast(ulong) Registers[highMethod] << 32) | Registers[highMethod + 1];
    }
}

final class RegisterEngine : GpuEngine {
    this(Gpu gpu, string name, size_t registerCount) {
        super(gpu, name, registerCount);
    }
}

enum InlineMethod : uint {
    LineLengthIn = 0x60,
    LineCount = 0x61,
    OffsetOutUpper = 0x62,
    OffsetOut = 0x63,
    PitchOut = 0x64,
    DstBlockSize = 0x65,
    DstWidth = 0x66,
    DstHeight = 0x67,
    DstDepth = 0x68,
    DstLayer = 0x69,
    DstOriginX = 0x6A,
    DstOriginY = 0x6B,
    LaunchDma = 0x6C,
    LoadInlineData = 0x6D,
}

struct InlineUpload {
    private ubyte[] buffer;
    private size_t expected;

    bool Handles(uint method) const {
        return method == InlineMethod.LaunchDma || method == InlineMethod.LoadInlineData;
    }

    void Call(GpuMemoryManager memory, const(uint)[] registers, uint method, uint argument) {
        if (method == InlineMethod.LaunchDma) {
            expected = cast(size_t) registers[InlineMethod.LineLengthIn] * registers[InlineMethod.LineCount];
            buffer.length = 0;
            if (expected == 0)
                return;
            buffer.reserve(expected + 4);
            return;
        }

        buffer ~= (cast(const(ubyte)*) &argument)[0 .. 4];
        if (buffer.length >= expected && expected != 0) {
            Flush(memory, registers);
            expected = 0;
        }
    }

    private void Flush(GpuMemoryManager memory, const(uint)[] registers) {
        const ulong destination = (cast(ulong) registers[InlineMethod.OffsetOutUpper] << 32) | registers[InlineMethod.OffsetOut];
        const size_t lineLength = registers[InlineMethod.LineLengthIn];
        const size_t lineCount = registers[InlineMethod.LineCount];
        const bool pitchLayout = (registers[InlineMethod.LaunchDma] & 1) != 0;

        if (pitchLayout || lineCount == 1 && registers[InlineMethod.DstHeight] <= 1) {
            const size_t pitch = registers[InlineMethod.PitchOut] != 0 ? registers[InlineMethod.PitchOut] : lineLength;
            if (pitch == lineLength || lineCount == 1) {
                memory.Write(destination, buffer[0 .. lineLength * lineCount]);
                return;
            }
            foreach (y; 0 .. lineCount)
                memory.Write(destination + y * pitch, buffer[y * lineLength .. (y + 1) * lineLength]);
            return;
        }

        const uint blockHeightLog2 = (registers[InlineMethod.DstBlockSize] >> 4) & 0xF;
        const size_t widthBytes = registers[InlineMethod.DstWidth];
        const size_t height = registers[InlineMethod.DstHeight];
        const size_t pitch = (widthBytes + GobWidth - 1) & ~(GobWidth - 1);
        const size_t originX = registers[InlineMethod.DstOriginX];
        const size_t originY = registers[InlineMethod.DstOriginY];
        ubyte[] surface = new ubyte[BlockLinearSize(pitch, height, blockHeightLog2)];
        memory.Read(destination, surface);
        foreach (y; 0 .. lineCount) {
            foreach (x; 0 .. lineLength) {
                const size_t offset = BlockLinearOffset(originX + x, originY + y, pitch, blockHeightLog2);
                if (offset < surface.length)
                    surface[offset] = buffer[y * lineLength + x];
            }
        }
        memory.Write(destination, surface);
    }
}

final class InlineToMemoryEngine : GpuEngine {
    private InlineUpload upload;

    this(Gpu gpu) {
        super(gpu, "InlineToMemory", 0x80);
    }

    override void CallMethod(uint method, uint argument, bool isLastCall) {
        super.CallMethod(method, argument, isLastCall);
        if (upload.Handles(method))
            upload.Call(gpu.MemoryManager, Registers, method, argument);
    }
}

// DMA copy
enum DmaMethod : uint {
    LaunchDma = 0xC0,
    SemaphoreAddressHigh = 0x90,
    SemaphoreAddressLow = 0x91,
    SemaphorePayload = 0x92,
    OffsetInUpper = 0x100,
    OffsetOutUpper = 0x102,
    PitchIn = 0x104,
    PitchOut = 0x105,
    LineLengthIn = 0x106,
    LineCount = 0x107,
    RemapConstA = 0x1C0,
    RemapComponents = 0x1C2,
    DstBlockSize = 0x1C3,
    DstWidth = 0x1C4,
    DstHeight = 0x1C5,
    DstOrigin = 0x1C8,
    SrcBlockSize = 0x1CA,
    SrcWidth = 0x1CB,
    SrcHeight = 0x1CC,
    SrcOrigin = 0x1CF,
}

final class DmaCopyEngine : GpuEngine {
    this(Gpu gpu) {
        super(gpu, "DmaCopy", 0x200);
    }

    override void CallMethod(uint method, uint argument, bool isLastCall) {
        super.CallMethod(method, argument, isLastCall);
        if (method == DmaMethod.LaunchDma)
            Launch(argument);
    }

    private size_t BytesPerElement() const {
        if ((Registers[DmaMethod.LaunchDma] & (1 << 10)) == 0)
            return 1;
        const uint components = Registers[DmaMethod.RemapComponents];
        const size_t componentSize = ((components >> 16) & 3) + 1;
        const size_t componentCount = ((components >> 20) & 3) + 1;
        return componentSize * componentCount;
    }

    private void Launch(uint launch) {
        const ulong source = Address(DmaMethod.OffsetInUpper);
        const ulong destination = Address(DmaMethod.OffsetOutUpper);
        const bool sourcePitch = (launch & (1 << 7)) != 0;
        const bool destinationPitch = (launch & (1 << 8)) != 0;
        const bool multiLine = (launch & (1 << 9)) != 0;
        const size_t bpp = BytesPerElement();
        const size_t lineBytes = Registers[DmaMethod.LineLengthIn] * bpp;
        const size_t lineCount = multiLine ? Registers[DmaMethod.LineCount] : 1;

        if (!multiLine || sourcePitch && destinationPitch) {
            const size_t sourceStride = multiLine ? Registers[DmaMethod.PitchIn] : lineBytes;
            const size_t destinationStride = multiLine ? Registers[DmaMethod.PitchOut] : lineBytes;
            ubyte[] line = new ubyte[lineBytes];
            foreach (y; 0 .. lineCount) {
                gpu.MemoryManager.Read(source + y * sourceStride, line);
                gpu.MemoryManager.Write(destination + y * destinationStride, line);
            }
        } else {
            CopySwizzled(source, destination, sourcePitch, destinationPitch, lineBytes, lineCount, bpp);
        }

        const uint semaphore = (launch >> 3) & 3;
        if (semaphore != 0)
            gpu.WriteReport(Address(DmaMethod.SemaphoreAddressHigh), Registers[DmaMethod.SemaphorePayload], semaphore == 1);
    }

    private void CopySwizzled(ulong source, ulong destination, bool sourcePitch, bool destinationPitch, size_t lineBytes, size_t lineCount, size_t bpp) {
        const uint blockBase = sourcePitch ? DmaMethod.DstBlockSize : DmaMethod.SrcBlockSize;
        const uint blockHeightLog2 = (Registers[blockBase] >> 4) & 0xF;
        const size_t surfacePitch = (Registers[blockBase + 1] * bpp + GobWidth - 1) & ~(GobWidth - 1);
        const size_t surfaceHeight = Registers[blockBase + 2];
        const uint origin = Registers[sourcePitch ? DmaMethod.DstOrigin : DmaMethod.SrcOrigin];
        const size_t originX = (origin & 0xFFFF) * bpp;
        const size_t originY = origin >> 16;
        const size_t linearPitch = Registers[sourcePitch ? DmaMethod.PitchIn : DmaMethod.PitchOut];
        const ulong linearAddress = sourcePitch ? source : destination;
        const ulong tiledAddress = sourcePitch ? destination : source;

        ubyte[] tiled = new ubyte[BlockLinearSize(surfacePitch, surfaceHeight, blockHeightLog2)];
        ubyte[] linear = new ubyte[linearPitch * lineCount];
        gpu.MemoryManager.Read(tiledAddress, tiled);
        if (sourcePitch)
            gpu.MemoryManager.Read(linearAddress, linear);

        foreach (y; 0 .. lineCount) {
            foreach (x; 0 .. lineBytes) {
                const size_t tiledOffset = BlockLinearOffset(originX + x, originY + y, surfacePitch, blockHeightLog2);
                const size_t linearOffset = y * linearPitch + x;
                if (tiledOffset >= tiled.length || linearOffset >= linear.length)
                    continue;
                if (sourcePitch)
                    tiled[tiledOffset] = linear[linearOffset];
                else
                    linear[linearOffset] = tiled[tiledOffset];
            }
        }

        if (sourcePitch)
            gpu.MemoryManager.Write(tiledAddress, tiled);
        else
            gpu.MemoryManager.Write(linearAddress, linear);
    }
}
