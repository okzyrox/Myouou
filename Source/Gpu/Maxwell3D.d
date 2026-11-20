/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell B 3D engine
*/

module Source.Gpu.Maxwell3D;

// Core
import Source.Gpu.Engines;
import Source.Gpu.Gpu;
import Source.Gpu.Macro;
import Source.Gpu.Texture;
import Source.Graphics.BlockLinear;

// Types
enum uint Maxwell3DRegisterCount = 0xE00;
enum uint RenderTargetCount = 8;
enum uint ShaderStageCount = 6;
enum uint ConstBufferStageCount = 5;
enum uint ConstBuffersPerStage = 18;

enum Maxwell3DMethod : uint {
    MacroUploadAddress = 0x45,
    MacroUploadData = 0x46,
    MacroEntryAddress = 0x47,
    MacroEntryData = 0x48,
    SyncInfo = 0xB2,
    RenderTargets = 0x200,
    ViewportTransform = 0x280,
    VertexBufferFirst = 0x35D,
    VertexBufferCount = 0x35E,
    ClearColor = 0x360,
    ClearDepth = 0x364,
    ClearStencil = 0x368,
    VertexAttributeFormats = 0x458,
    RenderTargetControl = 0x487,
    LinkedTsc = 0x48D,
    WindowOrigin = 0x4EB,
    TexSamplerPoolHigh = 0x557,
    TexSamplerPoolLow = 0x558,
    TexSamplerPoolLimit = 0x559,
    TexHeaderPoolHigh = 0x55D,
    TexHeaderPoolLow = 0x55E,
    TexHeaderPoolLimit = 0x55F,
    ProgramRegionHigh = 0x582,
    ProgramRegionLow = 0x583,
    DrawEnd = 0x585,
    DrawBegin = 0x586,
    IndexAddressHigh = 0x5F2,
    IndexFormat = 0x5F6,
    IndexBufferFirst = 0x5F7,
    IndexBufferCount = 0x5F8,
    CullEnable = 0x646,
    FrontFace = 0x647,
    CullFace = 0x648,
    ClearSurface = 0x674,
    ColorMask = 0x680,
    QueryAddressHigh = 0x6C0,
    QueryAddressLow = 0x6C1,
    QuerySequence = 0x6C2,
    QueryGet = 0x6C3,
    VertexArrays = 0x700,
    VertexArrayLimits = 0x7C0,
    ShaderStages = 0x800,
    ConstBufferSize = 0x8E0,
    ConstBufferAddressHigh = 0x8E1,
    ConstBufferAddressLow = 0x8E2,
    ConstBufferOffset = 0x8E3,
    ConstBufferData = 0x8E4,
    ConstBufferDataEnd = 0x8F4,
    ConstBufferBind = 0x904,
    ConstBufferBindEnd = 0x92C,
    TexConstBufferIndex = 0x982,
    MacroStart = 0xE00,
}

enum ShaderStage : uint {
    VertexA = 0,
    VertexB = 1,
    TessControl = 2,
    TessEval = 3,
    Geometry = 4,
    Fragment = 5,
}

uint ConstBufferStage(ShaderStage stage) {
    return stage == ShaderStage.VertexA ? 0 : stage - 1;
}

struct ConstBufferBinding {
    ulong Address;
    uint Size;
    bool Enabled;
}

interface GpuRenderer {
    bool Clear(Maxwell3D engine, uint argument);
    bool Draw(Maxwell3D engine, uint topology, uint first, uint count, bool indexed);
}

enum RenderTargetFormat : uint {
    Rgba32Float = 0xC0,
    Rgba16Float = 0xCA,
    Bgra8Unorm = 0xCF,
    Bgra8Srgb = 0xD0,
    Rgba8Unorm = 0xD5,
    Rgba8Srgb = 0xD6,
    Rgbx8Unorm = 0xE6,
    B5G6R5Unorm = 0xE8,
}

struct RenderTarget {
    ulong Address;
    uint Width;
    uint Height;
    RenderTargetFormat Format;
    uint BlockHeightLog2;
    bool PitchLinear;

    size_t BytesPerPixel() const {
        switch (Format) {
            case RenderTargetFormat.Rgba32Float: return 16;
            case RenderTargetFormat.Rgba16Float: return 8;
            case RenderTargetFormat.B5G6R5Unorm: return 2;
            default: return 4;
        }
    }

    size_t Pitch() const {
        if (PitchLinear)
            return Width;
        return (Width * BytesPerPixel + GobWidth - 1) & ~(GobWidth - 1);
    }

    size_t SurfaceSize() const {
        return PitchLinear ? Pitch * Height : BlockLinearSize(Pitch, Height, BlockHeightLog2);
    }

    size_t Offset(size_t x, size_t y) const {
        return PitchLinear ? y * Pitch + x * BytesPerPixel : BlockLinearOffset(x * BytesPerPixel, y, Pitch, BlockHeightLog2);
    }
}

// Class
final class Maxwell3D : GpuEngine, MacroHost {
    MacroEngine Macros;
    GpuRenderer Renderer;

    private InlineUpload upload;
    private uint executingMacro;
    private uint[] macroArguments;
    private ConstBufferBinding[ConstBuffersPerStage][ConstBufferStageCount] constBuffers;
    private bool indexedDraw;

    this(Gpu gpu) {
        super(gpu, "Maxwell3D", Maxwell3DRegisterCount);
        Macros = new MacroEngine(this);
    }

    uint ReadRegister(uint method) {
        return method < Registers.length ? Registers[method] : 0;
    }

    void CallMethodFromMacro(uint method, uint argument) {
        CallMethod(method, argument, true);
    }

    override void CallMethod(uint method, uint argument, bool isLastCall) {
        if (method >= Maxwell3DMethod.MacroStart) {
            CallMacro(method, argument, isLastCall);
            return;
        }

        switch (method) {
            case Maxwell3DMethod.MacroUploadData:
                Macros.Code[Registers[Maxwell3DMethod.MacroUploadAddress]++ % MacroEngine.CodeSize] = argument;
                return;
            case Maxwell3DMethod.MacroEntryData:
                Macros.Entries[Registers[Maxwell3DMethod.MacroEntryAddress]++ % MacroEngine.EntryCount] = argument;
                return;
            case Maxwell3DMethod.ConstBufferData: .. case Maxwell3DMethod.ConstBufferDataEnd - 1:
                WriteConstBuffer(argument);
                return;
            default:
                break;
        }

        super.CallMethod(method, argument, isLastCall);
        if (method >= Maxwell3DMethod.ConstBufferBind && method < Maxwell3DMethod.ConstBufferBindEnd && (method - Maxwell3DMethod.ConstBufferBind) % 8 == 0) {
            BindConstBuffer((method - Maxwell3DMethod.ConstBufferBind) / 8, argument);
            return;
        }
        if (upload.Handles(method)) {
            upload.Call(gpu.MemoryManager, Registers, method, argument);
            return;
        }

        switch (method) {
            case Maxwell3DMethod.SyncInfo:
                if ((argument & (1 << 16)) != 0)
                    gpu.IncrementSyncpoint(argument & 0xFFFF);
                break;
            case Maxwell3DMethod.ClearSurface:
                Clear(argument);
                break;
            case Maxwell3DMethod.QueryGet:
                Query(argument);
                break;
            case Maxwell3DMethod.DrawBegin:
                indexedDraw = false;
                break;
            case Maxwell3DMethod.IndexBufferCount:
                indexedDraw = true;
                break;
            case Maxwell3DMethod.DrawEnd:
                Draw();
                break;
            default:
                break;
        }
    }

    // State accessors
    ConstBufferBinding ConstBuffer(uint stage, uint index) const {
        if (stage >= ConstBufferStageCount || index >= ConstBuffersPerStage)
            return ConstBufferBinding.init;
        return constBuffers[stage][index];
    }

    bool ShaderEnabled(ShaderStage stage) const {
        return (Registers[Maxwell3DMethod.ShaderStages + stage * 0x10] & 1) != 0;
    }

    ulong ShaderAddress(ShaderStage stage) const {
        return Address(Maxwell3DMethod.ProgramRegionHigh) + Registers[Maxwell3DMethod.ShaderStages + stage * 0x10 + 1];
    }

    float RegisterFloat(uint method) const {
        return *cast(const(float)*) &Registers[method];
    }

    float ClearColor(uint component) const {
        return RegisterFloat(Maxwell3DMethod.ClearColor + component);
    }

    RenderTarget Target(uint index) const {
        const uint base = Maxwell3DMethod.RenderTargets + index * 0x10;
        RenderTarget target;
        target.Address = Address(base);
        target.Width = Registers[base + 2];
        target.Height = Registers[base + 3];
        target.Format = cast(RenderTargetFormat) Registers[base + 4];
        target.BlockHeightLog2 = (Registers[base + 5] >> 4) & 0xF;
        target.PitchLinear = (Registers[base + 5] & (1 << 12)) != 0;
        return target;
    }

    // Textures
    bool ReadTextureHandle(ShaderStage stage, uint offset, out TextureHandle handle) {
        const ConstBufferBinding binding = ConstBuffer(ConstBufferStage(stage), Registers[Maxwell3DMethod.TexConstBufferIndex]);
        if (!binding.Enabled || offset + 4 > binding.Size)
            return false;
        handle = TextureHandle(gpu.MemoryManager.Read!uint(binding.Address + offset));
        return true;
    }

    uint SamplerIndex(TextureHandle handle) const {
        return Registers[Maxwell3DMethod.LinkedTsc] != 0 ? handle.HeaderIndex : handle.SamplerIndex;
    }

    bool ReadTextureHeader(uint index, out TextureHeader header) {
        if (index > Registers[Maxwell3DMethod.TexHeaderPoolLimit])
            return false;
        gpu.MemoryManager.Read(Address(Maxwell3DMethod.TexHeaderPoolHigh) + index * DescriptorSize, cast(ubyte[]) header.Words[]);
        return true;
    }

    bool ReadSamplerHeader(uint index, out SamplerHeader header) {
        if (index > Registers[Maxwell3DMethod.TexSamplerPoolLimit])
            return false;
        gpu.MemoryManager.Read(Address(Maxwell3DMethod.TexSamplerPoolHigh) + index * DescriptorSize, cast(ubyte[]) header.Words[]);
        return true;
    }

    // Methods
    private void Draw() {
        const uint topology = Registers[Maxwell3DMethod.DrawBegin] & 0xFFFF;
        const uint first = indexedDraw ? Registers[Maxwell3DMethod.IndexBufferFirst] : Registers[Maxwell3DMethod.VertexBufferFirst];
        const uint count = indexedDraw ? Registers[Maxwell3DMethod.IndexBufferCount] : Registers[Maxwell3DMethod.VertexBufferCount];
        log.Trace("Draw: topology %d, first %d count %d%s", topology, first, count, indexedDraw ? " (indexed)" : "");
        if (Renderer !is null)
            Renderer.Draw(this, topology, first, count, indexedDraw);
    }

    private void BindConstBuffer(uint stage, uint argument) {
        const uint index = (argument >> 4) & 0x1F;
        if (stage >= ConstBufferStageCount || index >= ConstBuffersPerStage)
            return;
        ConstBufferBinding binding;
        binding.Enabled = (argument & 1) != 0;
        binding.Address = Address(Maxwell3DMethod.ConstBufferAddressHigh);
        binding.Size = Registers[Maxwell3DMethod.ConstBufferSize];
        constBuffers[stage][index] = binding;
    }

    private void CallMacro(uint method, uint argument, bool isLastCall) {
        if (executingMacro == 0)
            executingMacro = method;
        macroArguments ~= argument;
        if (!isLastCall)
            return;
        const uint index = (executingMacro - Maxwell3DMethod.MacroStart) >> 1;
        uint[] arguments = macroArguments;
        executingMacro = 0;
        macroArguments = null;
        Macros.Execute(index, arguments);
    }

    private void WriteConstBuffer(uint argument) {
        const ulong address = Address(Maxwell3DMethod.ConstBufferAddressHigh);
        gpu.MemoryManager.Write!uint(address + Registers[Maxwell3DMethod.ConstBufferOffset], argument);
        Registers[Maxwell3DMethod.ConstBufferOffset] += 4;
    }

    private void Query(uint argument) {
        const uint operation = argument & 3;
        if (operation == 1)
            return;
        const ulong value = operation == 2 ? 0 : Registers[Maxwell3DMethod.QuerySequence];
        // TODO: track counters, so every query reports the sequence
        gpu.WriteReport(Address(Maxwell3DMethod.QueryAddressHigh), value, (argument & (1 << 28)) != 0);
    }

    // clear fallback
    private static ubyte PackUnorm8(float value) {
        if (!(value > 0))
            return 0;
        if (value >= 1)
            return 255;
        return cast(ubyte) (value * 255 + 0.5f);
    }

    private ubyte[] ClearPixel(const ref RenderTarget target) const {
        float[4] color;
        foreach (i; 0 .. 4)
            color[i] = ClearColor(i);

        switch (target.Format) {
            case RenderTargetFormat.Rgba32Float:
                return (cast(ubyte*) color.ptr)[0 .. 16].dup;
            case RenderTargetFormat.Bgra8Unorm:
            case RenderTargetFormat.Bgra8Srgb:
                return [PackUnorm8(color[2]), PackUnorm8(color[1]), PackUnorm8(color[0]), PackUnorm8(color[3])];
            case RenderTargetFormat.B5G6R5Unorm: {
                const uint packed = (PackUnorm8(color[0]) >> 3) << 11 | (PackUnorm8(color[1]) >> 2) << 5 | PackUnorm8(color[2]) >> 3;
                return [cast(ubyte) packed, cast(ubyte) (packed >> 8)];
            }
            case RenderTargetFormat.Rgba8Unorm:
            case RenderTargetFormat.Rgba8Srgb:
            case RenderTargetFormat.Rgbx8Unorm:
                return [PackUnorm8(color[0]), PackUnorm8(color[1]), PackUnorm8(color[2]), PackUnorm8(color[3])];
            default:
                log.Stub("Clear of render target format 0x%X", target.Format);
                return null;
        }
    }

    private void Clear(uint argument) {
        if (Renderer !is null && Renderer.Clear(this, argument))
            return;
        const uint componentMask = (argument >> 2) & 0xF;
        const uint index = (argument >> 6) & 0xF;
        if (componentMask == 0 || index >= RenderTargetCount)
            return;

        const RenderTarget target = Target(index);
        if (target.Address == 0 || target.Width == 0 || target.Height == 0)
            return;
        const ubyte[] pixel = ClearPixel(target);
        if (pixel is null)
            return;
        log.Trace("Clear RT%d at gpu 0x%X %dx%d format 0x%X mask 0x%X", index, target.Address, target.Width, target.Height, target.Format, componentMask);

        ubyte[] surface = new ubyte[target.SurfaceSize];
        const bool fullMask = componentMask == 0xF || target.Format == RenderTargetFormat.B5G6R5Unorm;
        if (fullMask) {
            for (size_t i = 0; i + pixel.length <= surface.length; i += pixel.length)
                surface[i .. i + pixel.length] = pixel[];
            gpu.MemoryManager.Write(target.Address, surface);
            return;
        }

        // TODO: make masked clear components in memory order
        gpu.MemoryManager.Read(target.Address, surface);
        const size_t componentBytes = pixel.length / 4;
        foreach (y; 0 .. target.Height) {
            foreach (x; 0 .. target.Width) {
                const size_t offset = target.Offset(x, y);
                foreach (component; 0 .. 4) {
                    if ((componentMask & (1 << component)) == 0)
                        continue;
                    const size_t start = offset + component * componentBytes;
                    surface[start .. start + componentBytes] = pixel[component * componentBytes .. (component + 1) * componentBytes];
                }
            }
        }
        gpu.MemoryManager.Write(target.Address, surface);
    }
}
