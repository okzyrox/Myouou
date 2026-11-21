/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell 3D translated (loosely) onto SDL3
*/

module Source.Gpu.Renderer;

// Std
import core.time : MonoTime;
import std.format : format;
import std.math : abs;
import std.string : fromStringz;

// Deps
import bindbc.sdl;

// Core
import Source.Frontend.HostDisplay;
import Source.Gpu.Maxwell3D;
import Source.Gpu.MemoryManager;
import Source.Gpu.Shader.Instructions;
import Source.Gpu.Shader.ShaderCache;
import Source.Gpu.Shader.Translator;
import Source.Gpu.Texture;
import Source.Gpu.TextureCache;
import Source.Graphics.BlockLinear;
import Source.Util.Logger;

// Types
enum uint MaxVertexAttributes = 32;
enum uint MaxVertexArrays = 32;
enum size_t MaxGuestBufferSize = 64 * 1024 * 1024;
enum size_t ZeroStrideVertexBytes = 0x100;
enum size_t MaxBatchedDraws = 1024;
enum size_t MaxBatchedBytes = 32 * 1024 * 1024;
enum size_t MaxShaderBytes = 0x10000;

enum GuestTopology : uint {
    Points = 0,
    Lines = 1,
    LineLoop = 2,
    LineStrip = 3,
    Triangles = 4,
    TriangleStrip = 5,
    TriangleFan = 6,
}

enum GuestFrontFace : uint {
    Clockwise = 0x900,
    CounterClockwise = 0x901,
}

enum GuestCullFace : uint {
    Front = 0x404,
    Back = 0x405,
    FrontAndBack = 0x408,
}

enum VertexAttributeType : uint {
    Snorm = 1,
    Unorm = 2,
    Sint = 3,
    Uint = 4,
    Uscaled = 5,
    Sscaled = 6,
    Float = 7,
}

enum VertexAttributeSize : uint {
    Size32x4 = 0x01,
    Size32x3 = 0x02,
    Size16x4 = 0x03,
    Size32x2 = 0x04,
    Size8x4 = 0x0A,
    Size16x2 = 0x0F,
    Size32 = 0x12,
    Size8x2 = 0x18,
}

struct CachedShader {
    TranslatedShader Translation;
    SDL_GPUShader* Shader;
}

struct RenderTargetTexture {
    SDL_GPUTexture* Texture;
    uint Width;
    uint Height;
    SDL_GPUTextureFormat Format;
    ulong GuestAddress;
    ulong GpuAddress;
    size_t GuestSize;
    size_t BytesPerPixel;
    uint BlockHeightLog2;
    bool BlockLinear;
    bool GuestDirty;
}

struct VertexLayout {
    SDL_GPUVertexBufferDescription[MaxVertexArrays] Buffers;
    uint BufferCount;
    SDL_GPUVertexAttribute[MaxVertexAttributes] Attributes;
    uint AttributeCount;
    uint[MaxVertexArrays] GuestArrays;
    bool[MaxVertexArrays] PerInstance;
}

struct StagedUpload {
    SDL_GPUBuffer* Buffer;
    size_t Offset;
    size_t Size;
}

struct PendingDraw {
    SDL_GPUGraphicsPipeline* Pipeline;
    SDL_GPUViewport Viewport;
    SDL_FColor BlendColor;
    ubyte StencilReference;
    float[4] ViewParams;
    SDL_GPUBufferBinding[MaxVertexArrays] VertexBindings;
    uint VertexBufferCount;
    SDL_GPUBuffer*[] VertexStorage;
    SDL_GPUBuffer*[] FragmentStorage;
    SDL_GPUTextureSamplerBinding[] VertexTextures;
    SDL_GPUTextureSamplerBinding[] FragmentTextures;
    SDL_GPUBuffer* IndexBuffer;
    uint DrawCount;
    uint Instances;
}

struct DrawBatch {
    SDL_GPUTexture*[RenderTargetCount] ColorTextures;
    size_t ColorCount;
    SDL_GPUTexture* DepthTexture;
    PendingDraw[] Draws;
    ubyte[] Staging;
    StagedUpload[] Uploads;
    SDL_GPUBuffer*[] Buffers;

    bool SameTargets(const(RenderTargetTexture*)[] colors, const(SDL_GPUTexture)* depth) const {
        if (colors.length != ColorCount || depth != DepthTexture) {
            return false;
        }
        foreach (i, target; colors) {
            if (target.Texture != ColorTextures[i]) {
                return false;
            }
        }
        return true;
    }

    void SetTargets(const(RenderTargetTexture*)[] colors, SDL_GPUTexture* depth) {
        ColorCount = colors.length;
        foreach (i, target; colors) {
            ColorTextures[i] = cast(SDL_GPUTexture*) target.Texture;
        }
        DepthTexture = depth;
    }
}

// Class
final class HostRenderer : GpuRenderer {
    private HostDisplay display;
    private GpuMemoryManager memory;
    // TODO: host render targets are never written back to guest memory
    private RenderTargetTexture[ulong] targets;
    private RenderTargetTexture[ulong] depthTargets;
    private bool[ulong] sampledTargets;
    private CachedShader[ulong] shaders;
    private SDL_GPUGraphicsPipeline*[string] pipelines;
    private bool[string] failures;
    private bool[string] describedTextures; // temp
    private TextureCache textureCache;
    private DrawBatch batch;
    private ShaderDiskCache diskCache;
    private Logger log;

    this(HostDisplay display, GpuMemoryManager memory) {
        this.display = display;
        this.memory = memory;
        log = GetLogger("Gpu::Renderer");
        display.FindHostSurface = &FindSurface;
        textureCache = new TextureCache(display, memory);
        textureCache.BeforeUpload = &Flush;
        memory.OnWrite = &GuestWritten;
    }

    private SDL_GPUDevice* Device() {
        return display.Device;
    }

    void UseShaderCache(ShaderDiskCache cache) {
        diskCache = cache;
    }

    private static double Milliseconds(MonoTime since) {
        return (MonoTime.currTime - since).total!"usecs" / 1000.0;
    }

    private bool Ready() {
        return display.GetOrInit(1280, 720) && Device !is null;
    }

    private void FailOnce(A...)(string key, string text, A args) {
        if (key in failures)
            return;
        failures[key] = true;
        log.Warn(text, args);
    }

    // Render targets
    private static SDL_GPUTextureFormat HostFormat(RenderTargetFormat format) {
        switch (format) {
            case RenderTargetFormat.Rgba8Unorm, RenderTargetFormat.Rgbx8Unorm: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
            case RenderTargetFormat.Rgba8Srgb: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB;
            case RenderTargetFormat.Bgra8Unorm: return SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
            case RenderTargetFormat.Bgra8Srgb: return SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
            case RenderTargetFormat.B5G6R5Unorm: return SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM;
            case RenderTargetFormat.Rgba16Float: return SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
            case RenderTargetFormat.Rgba32Float: return SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT;
            default: return SDL_GPU_TEXTUREFORMAT_INVALID;
        }
    }
    
    private RenderTargetTexture* Target(const ref RenderTarget target) {
        ulong address;
        if (!memory.Translate(target.Address, address))
            return null;
        const SDL_GPUTextureFormat hostFormat = HostFormat(target.Format);
        if (hostFormat == SDL_GPU_TEXTUREFORMAT_INVALID) {
            FailOnce(format("rt%X", target.Format), "Render target format 0x%X has no host format", target.Format);
            return null;
        }

        RenderTargetTexture* existing = address in targets;
        if (existing !is null && existing.Width == target.Width && existing.Height == target.Height && existing.Format == hostFormat) {
            if (existing.GuestDirty) {
                ReloadFromGuest(*existing);
            }
            return existing;
        }
        if (existing !is null) {
            Flush();
            SDL_ReleaseGPUTexture(Device, existing.Texture);
        }

        SDL_GPUTextureCreateInfo info;
        info.type = SDL_GPU_TEXTURETYPE_2D;
        info.format = hostFormat;
        info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = target.Width;
        info.height = target.Height;
        SDL_GPUTexture* texture = SDL_CreateGPUTexture(Device, &info);
        if (texture is null) {
            log.Error("Render target creation failed: %s", fromStringz(SDL_GetError()));
            return null;
        }
        log.Info("Host render target %dx%d format 0x%X for guest 0x%X", target.Width, target.Height, target.Format, address);
        RenderTargetTexture created = RenderTargetTexture(texture, target.Width, target.Height, hostFormat);
        created.GuestAddress = address;
        created.GpuAddress = target.Address;
        created.BytesPerPixel = target.BytesPerPixel;
        created.BlockHeightLog2 = target.BlockHeightLog2;
        created.BlockLinear = !target.PitchLinear;
        if (created.BlockLinear) {
            created.GuestSize = BlockLinearSize(GuestPitch(created), created.Height, created.BlockHeightLog2);
        }
        targets[address] = created;
        RenderTargetTexture* stored = address in targets;
        ReloadFromGuest(*stored);
        return stored;
    }

    // Guest writes
    private static size_t GuestPitch(const ref RenderTargetTexture target) {
        return (target.Width * target.BytesPerPixel + GobWidth - 1) & ~(GobWidth - 1);
    }

    private void GuestWritten(ulong cpuAddress, size_t size) {
        textureCache.GuestWritten(cpuAddress, size);
        foreach (ref target; targets) {
            // should hopefully encapsulate most possible changes?
            // unless a target is changed to the same size at the same address
            if (target.GuestSize != 0 && target.GuestAddress < cpuAddress + size && cpuAddress < target.GuestAddress + target.GuestSize) {
                target.GuestDirty = true;
            }
        }
    }

    private void ReloadFromGuest(ref RenderTargetTexture target) {
        target.GuestDirty = false;
        if (!target.BlockLinear || target.GuestSize == 0) {
            return;
        }
        Flush();
        const size_t rowBytes = target.Width * target.BytesPerPixel;
        ubyte[] guest = new ubyte[target.GuestSize];
        ubyte[] pixels = new ubyte[rowBytes * target.Height];
        memory.Read(target.GpuAddress, guest);
        BlockLinearDeswizzle(guest, pixels, rowBytes, target.Height, GuestPitch(target), target.BlockHeightLog2);
        display.UploadTexture(target.Texture, pixels, target.Width, target.Height, target.Width);
        log.Trace("Reloaded render target (%dx%d) at guest memory addr 0x%X.", target.Width, target.Height, target.GuestAddress);
    }

    private bool FindSurface(ulong address, out HostSurface surface) {
        Flush();
        RenderTargetTexture* target = address in targets;
        if (target is null)
            return false;
        surface = HostSurface(target.Texture, target.Width, target.Height);
        return true;
    }

    private bool BoundTargets(Maxwell3D engine, ref RenderTargetTexture*[RenderTargetCount] storage, out size_t count) {
        const uint control = engine.Registers[Maxwell3DMethod.RenderTargetControl];
        foreach (slot; 0 .. control & 0xF) {
            const uint index = (control >> (4 + slot * 3)) & 7;
            const RenderTarget guest = engine.Target(index);
            if (guest.Address == 0 || guest.Width == 0)
                break;
            RenderTargetTexture* target = Target(guest);
            if (target is null)
                return false;
            storage[count++] = target;
        }
        return true;
    }

    // Clears
    
    // Depth targets
    private SDL_GPUTextureFormat HostDepthFormat(uint format) {
        switch (format) {
            case 0x0A:
                return SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
            case 0x13:
                return SDL_GPU_TEXTUREFORMAT_D16_UNORM;
            case 0x14, 0x15, 0x16, 0x18:
                // D24S8 is not available on some hosts, so it falls back to D32float with stencil
                if (SDL_GPUTextureSupportsFormat(Device, SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT, SDL_GPU_TEXTURETYPE_2D, SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)) {
                    return SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
                }
                return SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
            case 0x19:
                return SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
            default:
                return SDL_GPU_TEXTUREFORMAT_INVALID;
        }
    }

    private static bool HasStencil(SDL_GPUTextureFormat format) {
        return format == SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT || format == SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
    }

    // todo: depth targets live only on the host, so guest reads or samples of them see nothing
    private RenderTargetTexture* ZetaTarget(Maxwell3D engine) {
        DepthTarget guest;
        if (!engine.Zeta(guest)) {
            return null;
        }
        ulong address;
        if (!memory.Translate(guest.Address, address)) {
            return null;
        }
        const SDL_GPUTextureFormat hostFormat = HostDepthFormat(guest.Format);
        if (hostFormat == SDL_GPU_TEXTUREFORMAT_INVALID) {
            FailOnce(format("zeta%X", guest.Format), "Depth format 0x%X has no host format!", guest.Format);
            return null;
        }

        RenderTargetTexture* existing = address in depthTargets;
        if (existing !is null && existing.Width == guest.Width && existing.Height == guest.Height && existing.Format == hostFormat) {
            return existing;
        }
        if (existing !is null) {
            Flush();
            SDL_ReleaseGPUTexture(Device, existing.Texture);
        }

        SDL_GPUTextureCreateInfo info;
        info.type = SDL_GPU_TEXTURETYPE_2D;
        info.format = hostFormat;
        info.usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
        info.width = guest.Width;
        info.height = guest.Height;
        SDL_GPUTexture* texture = SDL_CreateGPUTexture(Device, &info);
        if (texture is null) {
            log.Error("Depth target creation failed (%s)!", fromStringz(SDL_GetError()));
            return null;
        }
        log.Info("Got host depth target %dx%d format 0x%X (%s) for guest 0x%X!", guest.Width, guest.Height, guest.Format, hostFormat, address);
        depthTargets[address] = RenderTargetTexture(texture, guest.Width, guest.Height, hostFormat);
        return address in depthTargets;
    }

    // Clears
    bool Clear(Maxwell3D engine, uint argument) {
        Flush();
        const bool depth = (argument & 1) != 0;
        const bool stencil = (argument & 2) != 0;
        if ((depth || stencil) && Ready()) {
            ClearDepthStencil(engine, depth, stencil);
        }
        return ClearColor(engine, argument);
    }

    private void ClearDepthStencil(Maxwell3D engine, bool depth, bool stencil) {
        RenderTargetTexture* target = ZetaTarget(engine);
        if (target is null) {
            return;
        }
        SDL_GPUDepthStencilTargetInfo info;
        info.texture = target.Texture;
        info.clearDepth = engine.RegisterFloat(Maxwell3DMethod.ClearDepth);
        info.clearStencil = cast(ubyte) engine.Registers[Maxwell3DMethod.ClearStencil];
        info.loadOp = depth ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD;
        info.storeOp = SDL_GPU_STOREOP_STORE;
        info.stencilLoadOp = stencil ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD;
        info.stencilStoreOp = SDL_GPU_STOREOP_STORE;

        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(Device);
        SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(commands, null, 0, &info);
        SDL_EndGPURenderPass(pass);
        SDL_SubmitGPUCommandBuffer(commands);
    }

    private bool ClearColor(Maxwell3D engine, uint argument) {
        const uint index = (argument >> 6) & 0xF;
        if ((argument & 0x3C) == 0 || index >= RenderTargetCount)
            return true;
        if (!Ready())
            return false;

        const RenderTarget guest = engine.Target(index);
        if (guest.Address == 0 || guest.Width == 0 || guest.Height == 0)
            return true;
        RenderTargetTexture* target = Target(guest);
        if (target is null)
            return false;

        SDL_GPUColorTargetInfo colorTarget;
        colorTarget.texture = target.Texture;
        colorTarget.clearColour = SDL_FColor(engine.ClearColor(0), engine.ClearColor(1), engine.ClearColor(2), engine.ClearColor(3));
        colorTarget.loadOp = SDL_GPU_LOADOP_CLEAR;
        colorTarget.storeOp = SDL_GPU_STOREOP_STORE;

        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(Device);
        SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(commands, &colorTarget, 1, null);
        SDL_EndGPURenderPass(pass);
        SDL_SubmitGPUCommandBuffer(commands);
        return true;
    }

    // Shaders
    private static ulong Hash(const(ulong)[] words) {
        ulong hash = 0xCBF2_9CE4_8422_2325;
        foreach (word; words) {
            hash ^= word;
            hash *= 0x100_0000_01B3;
        }
        return hash;
    }

    private ulong[] ReadProgram(ulong address) {
        ulong[] program = new ulong[ShaderHeaderWords];
        memory.Read(address, cast(ubyte[]) program);
        ulong[4] group;
        size_t furthestTarget = 0;
        for (ulong offset = ShaderHeaderWords * 8; offset < MaxShaderBytes; offset += group.sizeof) {
            memory.Read(address + offset, cast(ubyte[]) group[]);
            program ~= group[];
            foreach (i, word; group[1 .. $]) {
                const size_t instructionAddress = cast(size_t) (offset - ShaderHeaderWords * 8) + (i + 1) * 8;
                const Instruction instruction = Instruction.Decode(word, instructionAddress);
                switch (instruction.Op) {
                    case Opcode.Bra, Opcode.Ssy, Opcode.Pbk, Opcode.Pcnt:
                        const long target = cast(long) instructionAddress + 8 + instruction.BranchOffset;
                        if (target > cast(long) furthestTarget)
                            furthestTarget = cast(size_t) target;
                        break;
                    case Opcode.Exit:
                        if (instruction.Unconditional && instructionAddress >= furthestTarget)
                            return program;
                        break;
                    default:
                        break;
                }
            }
        }
        return program;
    }

    private uint[uint] TextureSwizzles(Maxwell3D engine, ShaderStage stage, const(ulong)[] program) {
        uint[uint] swizzles;
        foreach (offset; TextureOffsets(program, ShaderHeaderWords)) {
            TextureHandle handle;
            TextureHeader header;
            // we have to bake these into the translated shader program
            // since sdlgpu doesnt have a swizzling component..
            if (engine.ReadTextureHandle(stage, offset, handle) && engine.ReadTextureHeader(handle.HeaderIndex, header)) {
                swizzles[offset] = header.PackedSwizzle;
            }
        }
        return swizzles;
    }

    // TODO: cache shader programs rather than reload every time
    private CachedShader* Shader(Maxwell3D engine, ShaderStage stage, ShaderStageKind kind) {
        const ulong address = engine.ShaderAddress(stage);
        const ulong[] program = ReadProgram(address);
        const uint[uint] swizzles = TextureSwizzles(engine, stage, program);
        ulong key = Hash(program) ^ stage;
        foreach (offset, swizzle; swizzles) {
            key ^= Hash([(cast(ulong) offset << 32) | swizzle]);
        }
        if (CachedShader* found = key in shaders)
            return found.Shader is null ? null : found;

        CachedShader cached;
        const MonoTime translateStart = MonoTime.currTime;
        const bool fromDisk = diskCache !is null && diskCache.Load(key, kind, cached.Translation);
        if (!fromDisk) {
            cached.Translation = TranslateShader(kind, program, swizzles);
            if (diskCache !is null) {
                diskCache.Store(key, cached.Translation);
            }
        }
        const double translateTime = Milliseconds(translateStart);
        if (!cached.Translation.Ok) {
            log.Error("Stage %d shader at gpu 0x%X failed to translate: %s", stage, address, cached.Translation.Error);
            foreach (line; DisassembleProgram(program, ShaderHeaderWords))
                log.Trace("  %s", line);
            shaders[key] = cached;
            return null;
        }

        const(ubyte)[] spirv = cast(const(ubyte)[]) cached.Translation.Spirv;
        SDL_GPUShaderCreateInfo info;
        info.code = spirv.ptr;
        info.codeSize = spirv.length;
        info.entryPoint = "main";
        info.format = SDL_GPU_SHADERFORMAT_SPIRV;
        info.stage = kind == ShaderStageKind.Vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;
        info.numStorageBuffers = cast(uint) cached.Translation.ConstBuffers.length;
        info.numSamplers = cast(uint) cached.Translation.Textures.length;
        info.numUniformBuffers = kind == ShaderStageKind.Vertex ? 1 : 0;
        const MonoTime hostStart = MonoTime.currTime;
        cached.Shader = SDL_CreateGPUShader(Device, &info);
        if (cached.Shader is null)
            log.Error("Stage %d host shader creation failed: %s", stage, fromStringz(SDL_GetError()));
        else
            log.Info("%s stage %d shader at gpu 0x%X (%d instructions, %d bytes of SPIR-V) in %.2f ms, host shader %.2f ms", fromDisk ? "Loaded cached" : "Translated", stage, address, cached.Translation.InstructionCount, spirv.length, translateTime, Milliseconds(hostStart));
        shaders[key] = cached;
        CachedShader* stored = key in shaders;
        return stored.Shader is null ? null : stored;
    }

    private bool SupportedStages(Maxwell3D engine) {
        if (!engine.ShaderEnabled(ShaderStage.VertexB) || !engine.ShaderEnabled(ShaderStage.Fragment)) {
            FailOnce("stages", "Draw without a vertex B and fragment program is not supported");
            return false;
        }
        foreach (stage; [ShaderStage.VertexA, ShaderStage.TessControl, ShaderStage.TessEval, ShaderStage.Geometry]) {
            if (engine.ShaderEnabled(stage)) {
                FailOnce("extra-stages", "Draws with vertex A, tessellation or geometry programs are not supported");
                return false;
            }
        }
        return true;
    }

    // Vertex input
    private static SDL_GPUVertexElementFormat AttributeFormat(uint size, uint type) {
        switch (type) {
            case VertexAttributeType.Float:
                switch (size) {
                    case VertexAttributeSize.Size32: return SDL_GPU_VERTEXELEMENTFORMAT_FLOAT;
                    case VertexAttributeSize.Size32x2: return SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
                    case VertexAttributeSize.Size32x3: return SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3;
                    case VertexAttributeSize.Size32x4: return SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
                    case VertexAttributeSize.Size16x2: return SDL_GPU_VERTEXELEMENTFORMAT_HALF2;
                    case VertexAttributeSize.Size16x4: return SDL_GPU_VERTEXELEMENTFORMAT_HALF4;
                    default: break;
                }
                break;
            case VertexAttributeType.Unorm:
                switch (size) {
                    case VertexAttributeSize.Size8x4: return SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM;
                    case VertexAttributeSize.Size8x2: return SDL_GPU_VERTEXELEMENTFORMAT_UBYTE2_NORM;
                    case VertexAttributeSize.Size16x4: return SDL_GPU_VERTEXELEMENTFORMAT_USHORT4_NORM;
                    case VertexAttributeSize.Size16x2: return SDL_GPU_VERTEXELEMENTFORMAT_USHORT2_NORM;
                    default: break;
                }
                break;
            case VertexAttributeType.Snorm:
                switch (size) {
                    case VertexAttributeSize.Size8x4: return SDL_GPU_VERTEXELEMENTFORMAT_BYTE4_NORM;
                    case VertexAttributeSize.Size8x2: return SDL_GPU_VERTEXELEMENTFORMAT_BYTE2_NORM;
                    case VertexAttributeSize.Size16x4: return SDL_GPU_VERTEXELEMENTFORMAT_SHORT4_NORM;
                    case VertexAttributeSize.Size16x2: return SDL_GPU_VERTEXELEMENTFORMAT_SHORT2_NORM;
                    default: break;
                }
                break;
            default:
                break;
        }
        return SDL_GPU_VERTEXELEMENTFORMAT_INVALID;
    }

    private bool BuildVertexLayout(Maxwell3D engine, uint attributeMask, out VertexLayout layout) {
        int[MaxVertexArrays] slots = -1;
        foreach (index; 0 .. MaxVertexAttributes) {
            if ((attributeMask & (1u << index)) == 0)
                continue;
            const uint raw = engine.Registers[Maxwell3DMethod.VertexAttributeFormats + index];
            const uint buffer = raw & 0x1F;
            const bool constant = (raw & (1 << 6)) != 0;
            const uint offset = (raw >> 7) & 0x3FFF;
            const uint size = (raw >> 21) & 0x3F;
            const uint type = (raw >> 27) & 0x7;
            const SDL_GPUVertexElementFormat elementFormat = AttributeFormat(size, type);
            if (constant || elementFormat == SDL_GPU_VERTEXELEMENTFORMAT_INVALID) {
                FailOnce(format("attr%X", raw), "Vertex attribute %d format 0x%08X (size 0x%X type %d%s) is not supported", index, raw, size, type, constant ? ", constant" : "");
                return false;
            }

            if (slots[buffer] < 0) {
                const bool perInstance = (engine.Registers[Maxwell3DMethod.VertexArrayInstanced + buffer] & 1) != 0;
                const uint divisor = engine.Registers[Maxwell3DMethod.VertexArrays + buffer * 4 + 3];
                if (perInstance && divisor > 1) {
                    // todo: instance divisors above 1, SDL GPU only steps once per instance
                    FailOnce(format("divisor%d", divisor), "Vertex array %d uses instance divisor %d, which is not supported", buffer, divisor);
                    return false;
                }
                slots[buffer] = layout.BufferCount;
                SDL_GPUVertexBufferDescription description;
                description.slot = layout.BufferCount;
                description.pitch = engine.Registers[Maxwell3DMethod.VertexArrays + buffer * 4] & 0xFFF;
                description.inputRate = perInstance ? SDL_GPU_VERTEXINPUTRATE_INSTANCE : SDL_GPU_VERTEXINPUTRATE_VERTEX;
                layout.Buffers[layout.BufferCount] = description;
                layout.GuestArrays[layout.BufferCount] = buffer;
                layout.PerInstance[layout.BufferCount] = perInstance;
                layout.BufferCount++;
            }

            SDL_GPUVertexAttribute attribute;
            attribute.location = index;
            attribute.bufferSlot = slots[buffer];
            attribute.format = elementFormat;
            attribute.offset = offset;
            layout.Attributes[layout.AttributeCount++] = attribute;
        }
        return true;
    }

    // Buffers
    // TODO: use a cache buffer for some of this data (sometimes)
    private SDL_GPUBuffer* UploadBuffer(const(ubyte)[] data, SDL_GPUBufferUsageFlags_ usage) {
        SDL_GPUBufferCreateInfo info;
        info.usage = usage;
        info.size = cast(uint) ((data.length + 3) & ~3);
        SDL_GPUBuffer* buffer = SDL_CreateGPUBuffer(Device, &info);
        if (buffer is null)
            return null;
        batch.Buffers ~= buffer;
        const size_t offset = batch.Staging.length;
        batch.Staging.length = offset + info.size;
        batch.Staging[offset .. offset + data.length] = data[];
        batch.Uploads ~= StagedUpload(buffer, offset, info.size);
        return buffer;
    }

    // Batches
    private void Flush() {
        if (batch.Draws.length == 0 && batch.Uploads.length == 0) {
            batch = DrawBatch.init;
            return;
        }
        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(Device);
        SDL_GPUTransferBuffer* transfer;
        if (batch.Staging.length != 0) {
            SDL_GPUTransferBufferCreateInfo transferInfo;
            transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
            transferInfo.size = cast(uint) batch.Staging.length;
            transfer = SDL_CreateGPUTransferBuffer(Device, &transferInfo);
            if (transfer is null) {
                log.Error("Batch transfer buffer creation failed (%s)!", fromStringz(SDL_GetError()));
                SDL_CancelGPUCommandBuffer(commands);
                ReleaseBatch();
                return;
            }
            ubyte* mapped = cast(ubyte*) SDL_MapGPUTransferBuffer(Device, transfer, false);
            mapped[0 .. batch.Staging.length] = batch.Staging[];
            SDL_UnmapGPUTransferBuffer(Device, transfer);

            SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(commands);
            foreach (upload; batch.Uploads) {
                SDL_GPUTransferBufferLocation source;
                source.transferBuffer = transfer;
                source.offset = cast(uint) upload.Offset;
                SDL_GPUBufferRegion destination;
                destination.buffer = upload.Buffer;
                destination.size = cast(uint) upload.Size;
                SDL_UploadToGPUBuffer(copy, &source, &destination, false);
            }
            SDL_EndGPUCopyPass(copy);
        }

        if (batch.Draws.length != 0) {
            SDL_GPUColorTargetInfo[RenderTargetCount] colorInfos;
            foreach (i; 0 .. batch.ColorCount) {
                colorInfos[i].texture = batch.ColorTextures[i];
                colorInfos[i].loadOp = SDL_GPU_LOADOP_LOAD;
                colorInfos[i].storeOp = SDL_GPU_STOREOP_STORE;
            }
            SDL_GPUDepthStencilTargetInfo depthInfo;
            const bool hasDepth = batch.DepthTexture !is null;
            if (hasDepth) {
                depthInfo.texture = batch.DepthTexture;
                depthInfo.loadOp = SDL_GPU_LOADOP_LOAD;
                depthInfo.storeOp = SDL_GPU_STOREOP_STORE;
                depthInfo.stencilLoadOp = SDL_GPU_LOADOP_LOAD;
                depthInfo.stencilStoreOp = SDL_GPU_STOREOP_STORE;
            }
            SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(commands, colorInfos.ptr, cast(uint) batch.ColorCount, hasDepth ? &depthInfo : null);
            foreach (ref draw; batch.Draws) {
                if (hasDepth) {
                    SDL_SetGPUStencilReference(pass, draw.StencilReference);
                }
                SDL_BindGPUGraphicsPipeline(pass, draw.Pipeline);
                SDL_SetGPUViewport(pass, &draw.Viewport);
                SDL_SetGPUBlendConstants(pass, draw.BlendColor);
                if (draw.VertexBufferCount > 0) {
                    SDL_BindGPUVertexBuffers(pass, 0, draw.VertexBindings.ptr, draw.VertexBufferCount);
                }
                if (draw.VertexStorage.length > 0) {
                    SDL_BindGPUVertexStorageBuffers(pass, 0, draw.VertexStorage.ptr, cast(uint) draw.VertexStorage.length);
                }
                if (draw.FragmentStorage.length > 0) {
                    SDL_BindGPUFragmentStorageBuffers(pass, 0, draw.FragmentStorage.ptr, cast(uint) draw.FragmentStorage.length);
                }
                if (draw.VertexTextures.length > 0) {
                    SDL_BindGPUVertexSamplers(pass, 0, draw.VertexTextures.ptr, cast(uint) draw.VertexTextures.length);
                }
                if (draw.FragmentTextures.length > 0) {
                    SDL_BindGPUFragmentSamplers(pass, 0, draw.FragmentTextures.ptr, cast(uint) draw.FragmentTextures.length);
                }
                SDL_PushGPUVertexUniformData(commands, 0, draw.ViewParams.ptr, draw.ViewParams.sizeof);
                if (draw.IndexBuffer !is null) {
                    SDL_GPUBufferBinding indexBinding;
                    indexBinding.buffer = draw.IndexBuffer;
                    SDL_BindGPUIndexBuffer(pass, &indexBinding, SDL_GPU_INDEXELEMENTSIZE_32BIT);
                    SDL_DrawGPUIndexedPrimitives(pass, draw.DrawCount, draw.Instances, 0, 0, 0);
                } else {
                    SDL_DrawGPUPrimitives(pass, draw.DrawCount, draw.Instances, 0, 0);
                }
            }
            SDL_EndGPURenderPass(pass);
        }
        SDL_SubmitGPUCommandBuffer(commands);
        if (transfer !is null) {
            SDL_ReleaseGPUTransferBuffer(Device, transfer);
        }
        ReleaseBatch();
    }

    private void ReleaseBatch() {
        foreach (buffer; batch.Buffers) {
            SDL_ReleaseGPUBuffer(Device, buffer);
        }
        batch = DrawBatch.init;
    }

    private ubyte[] ReadGuest(ulong address, size_t size) {
        if (size == 0 || size > MaxGuestBufferSize)
            return null;
        ubyte[] data = new ubyte[size];
        memory.Read(address, data);
        return data;
    }

    private uint[] ReadIndices(Maxwell3D engine, uint first, uint count) {
        const ulong address = engine.Address(Maxwell3DMethod.IndexAddressHigh);
        const uint indexFormat = engine.Registers[Maxwell3DMethod.IndexFormat];
        const size_t elementSize = indexFormat == 0 ? 1 : indexFormat == 1 ? 2 : 4;
        const ubyte[] raw = ReadGuest(address + first * elementSize, count * elementSize);
        if (raw is null)
            return null;
        uint[] indices = new uint[count];
        foreach (i; 0 .. count) {
            if (elementSize == 1)
                indices[i] = raw[i];
            else if (elementSize == 2)
                indices[i] = (cast(const(ushort)[]) raw)[i];
            else
                indices[i] = (cast(const(uint)[]) raw)[i];
        }
        return indices;
    }

    private uint[] DrawIndices(Maxwell3D engine, uint first, uint count, bool indexed, bool fan) {
        uint[] indices;
        if (indexed) {
            indices = ReadIndices(engine, first, count);
            if (indices is null)
                return null;
        } else {
            indices = new uint[count];
            foreach (i; 0 .. count)
                indices[i] = first + i;
        }
        if (!fan)
            return indices;
        uint[] list;
        foreach (i; 1 .. indices.length > 1 ? indices.length - 1 : 1)
            list ~= [indices[0], indices[i], indices[i + 1]];
        return list;
    }

    private bool UploadConstBuffers(Maxwell3D engine, ShaderStage stage, const(uint)[] indices, out SDL_GPUBuffer*[] result) {
        foreach (index; indices) {
            const ConstBufferBinding binding = engine.ConstBuffer(ConstBufferStage(stage), index);
            ubyte[] data = binding.Enabled ? ReadGuest(binding.Address, binding.Size) : null;
            if (data is null)
                data = new ubyte[16];
            SDL_GPUBuffer* buffer = UploadBuffer(data, SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ);
            if (buffer is null)
                return false;
            result ~= buffer;
        }
        return true;
    }

    // Pipelines
    private static SDL_GPUPrimitiveType Topology(uint topology, out bool fan) {
        switch (topology) {
            case GuestTopology.Points: return SDL_GPU_PRIMITIVETYPE_POINTLIST;
            case GuestTopology.Lines: return SDL_GPU_PRIMITIVETYPE_LINELIST;
            case GuestTopology.LineStrip: return SDL_GPU_PRIMITIVETYPE_LINESTRIP;
            case GuestTopology.Triangles: return SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
            case GuestTopology.TriangleStrip: return SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP;
            case GuestTopology.TriangleFan:
                fan = true;
                return SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
            default: return cast(SDL_GPUPrimitiveType) -1;
        }
    }

    private SDL_GPUBlendFactor BlendFactor(uint factor) {
        switch (factor) {
            case 0x1, 0x4000: return SDL_GPU_BLENDFACTOR_ZERO;
            case 0x2, 0x4001: return SDL_GPU_BLENDFACTOR_ONE;
            case 0x3, 0x4300: return SDL_GPU_BLENDFACTOR_SRC_COLOR;
            case 0x4, 0x4301: return SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_COLOR;
            case 0x5, 0x4302: return SDL_GPU_BLENDFACTOR_SRC_ALPHA;
            case 0x6, 0x4303: return SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
            case 0x7, 0x4304: return SDL_GPU_BLENDFACTOR_DST_ALPHA;
            case 0x8, 0x4305: return SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_ALPHA;
            case 0x9, 0x4306: return SDL_GPU_BLENDFACTOR_DST_COLOR;
            case 0xA, 0x4307: return SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_COLOR;
            case 0xB, 0x4308: return SDL_GPU_BLENDFACTOR_SRC_ALPHA_SATURATE;
            // should be constantalpha factors but sdlgpu doesnt support it from the looks of it
            case 0xE, 0xC001, 0xC003: return SDL_GPU_BLENDFACTOR_CONSTANT_COLOR;
            case 0xF, 0xC002, 0xC004: return SDL_GPU_BLENDFACTOR_ONE_MINUS_CONSTANT_COLOR;
            default:
                FailOnce(format("blendfactor%X", factor), "Unsupported blend factor 0x%X!", factor);
                return SDL_GPU_BLENDFACTOR_ONE;
        }
    }

    private SDL_GPUBlendOp BlendOp(uint equation) {
        switch (equation) {
            case 1, 0x8006: return SDL_GPU_BLENDOP_ADD;
            case 2, 0x800A: return SDL_GPU_BLENDOP_SUBTRACT;
            case 3, 0x800B: return SDL_GPU_BLENDOP_REVERSE_SUBTRACT;
            case 4, 0x8007: return SDL_GPU_BLENDOP_MIN;
            case 5, 0x8008: return SDL_GPU_BLENDOP_MAX;
            default:
                FailOnce(format("blendop%X", equation), "Unsupported blend equation 0x%X!", equation);
                return SDL_GPU_BLENDOP_ADD;
        }
    }

    private SDL_GPUCompareOp CompareOp(uint func) {
        switch (func) {
            case 1, 0x200: return SDL_GPU_COMPAREOP_NEVER;
            case 2, 0x201: return SDL_GPU_COMPAREOP_LESS;
            case 3, 0x202: return SDL_GPU_COMPAREOP_EQUAL;
            case 4, 0x203: return SDL_GPU_COMPAREOP_LESS_OR_EQUAL;
            case 5, 0x204: return SDL_GPU_COMPAREOP_GREATER;
            case 6, 0x205: return SDL_GPU_COMPAREOP_NOT_EQUAL;
            case 7, 0x206: return SDL_GPU_COMPAREOP_GREATER_OR_EQUAL;
            case 8, 0x207: return SDL_GPU_COMPAREOP_ALWAYS;
            default:
                FailOnce(format("compare%X", func), "Unsupported compare function 0x%X!", func);
                return SDL_GPU_COMPAREOP_ALWAYS;
        }
    }

    private SDL_GPUStencilOp StencilOp(uint op) {
        switch (op) {
            case 1, 0x1E00: return SDL_GPU_STENCILOP_KEEP;
            case 2, 0: return SDL_GPU_STENCILOP_ZERO;
            case 3, 0x1E01: return SDL_GPU_STENCILOP_REPLACE;
            case 4, 0x1E02: return SDL_GPU_STENCILOP_INCREMENT_AND_CLAMP;
            case 5, 0x1E03: return SDL_GPU_STENCILOP_DECREMENT_AND_CLAMP;
            case 6, 0x150A: return SDL_GPU_STENCILOP_INVERT;
            case 7, 0x8507: return SDL_GPU_STENCILOP_INCREMENT_AND_WRAP;
            case 8, 0x8508: return SDL_GPU_STENCILOP_DECREMENT_AND_WRAP;
            default:
                FailOnce(format("stencilop%X", op), "Unsupported stencil op 0x%X!", op);
                return SDL_GPU_STENCILOP_KEEP;
        }
    }

    private SDL_GPUStencilOpState StencilOpState(const ref StencilFace face) {
        SDL_GPUStencilOpState state;
        state.failOp = StencilOp(face.Fail);
        state.depthFailOp = StencilOp(face.DepthFail);
        state.passOp = StencilOp(face.Pass);
        state.compareOp = CompareOp(face.Func);
        return state;
    }

    
    private SDL_GPUDepthStencilState DepthStencilState(Maxwell3D engine, bool hasStencil) {
        SDL_GPUDepthStencilState state;
        state.enableDepthTest = engine.Registers[Maxwell3DMethod.DepthTestEnable] != 0;
        state.enableDepthWrite = engine.Registers[Maxwell3DMethod.DepthWriteEnable] != 0;
        state.compareOp = state.enableDepthTest ? CompareOp(engine.Registers[Maxwell3DMethod.DepthFunc]) : SDL_GPU_COMPAREOP_ALWAYS;
        if (hasStencil && engine.Registers[Maxwell3DMethod.StencilEnable] != 0) {
            const StencilFace front = engine.Stencil(false);
            const StencilFace back = engine.Stencil(true);
            state.enableStencilTest = true;
            state.frontStencilState = StencilOpState(front);
            state.backStencilState = StencilOpState(back);
            // todo: SDL has only one compare mask, write mask and reference for both faces
            // so the back face uses the front face..
            state.compareMask = cast(ubyte) front.CompareMask;
            state.writeMask = cast(ubyte) front.WriteMask;
        }
        return state;
    }

    private SDL_GPUGraphicsPipeline* Pipeline(Maxwell3D engine, CachedShader* vertex, CachedShader* fragment, const ref VertexLayout layout, SDL_GPUPrimitiveType primitive, const(RenderTargetTexture*)[] colorTargets, const(RenderTargetTexture)* depthTarget, bool lowerLeft) {
        SDL_GPUColorTargetDescription[RenderTargetCount] descriptions;
        string key = format("%s|%s|%d", vertex.Shader, fragment.Shader, primitive);
        foreach (i, target; colorTargets) {
            const uint mask = engine.Registers[Maxwell3DMethod.ColorMask + i];
            descriptions[i].format = target.Format;
            descriptions[i].blendState.enableColourWriteMask = true;
            descriptions[i].blendState.colourWriteMask = cast(ubyte) (((mask & 1) ? SDL_GPU_COLORCOMPONENT_R : 0) | ((mask & 0x10) ? SDL_GPU_COLORCOMPONENT_G : 0)
                | ((mask & 0x100) ? SDL_GPU_COLORCOMPONENT_B : 0) | ((mask & 0x1000) ? SDL_GPU_COLORCOMPONENT_A : 0));
            key ~= format("|rt%d:%d", target.Format, mask);
            const BlendState blend = engine.Blend(cast(uint) i);
            if (blend.Enabled) {
                descriptions[i].blendState.enableBlend = true;
                descriptions[i].blendState.colourBlendOp = BlendOp(blend.EquationRgb);
                descriptions[i].blendState.srcColourBlendFactor = BlendFactor(blend.SourceRgb);
                descriptions[i].blendState.dstColourBlendFactor = BlendFactor(blend.DestRgb);
                descriptions[i].blendState.alphaBlendOp = BlendOp(blend.EquationAlpha);
                descriptions[i].blendState.srcAlphaBlendFactor = BlendFactor(blend.SourceAlpha);
                descriptions[i].blendState.dstAlphaBlendFactor = BlendFactor(blend.DestAlpha);
                key ~= format("|blend%X:%X:%X:%X:%X:%X", blend.EquationRgb, blend.SourceRgb, blend.DestRgb, blend.EquationAlpha, blend.SourceAlpha, blend.DestAlpha);
            }
        }
        foreach (i; 0 .. layout.BufferCount)
            key ~= format("|vb%d", layout.Buffers[i].pitch);
        foreach (i; 0 .. layout.AttributeCount)
            key ~= format("|va%d:%d:%d:%d", layout.Attributes[i].location, layout.Attributes[i].bufferSlot, layout.Attributes[i].format, layout.Attributes[i].offset);

        const bool cull = engine.Registers[Maxwell3DMethod.CullEnable] != 0;
        const uint cullFace = engine.Registers[Maxwell3DMethod.CullFace];
        const bool counterClockwise = (engine.Registers[Maxwell3DMethod.FrontFace] != GuestFrontFace.Clockwise) != lowerLeft;
        key ~= format("|cull%d:%X:%d", cull, cullFace, counterClockwise);

        SDL_GPUDepthStencilState depthState;
        if (depthTarget !is null) {
            depthState = DepthStencilState(engine, HasStencil(depthTarget.Format));
            key ~= format("|zeta%d:%s", depthTarget.Format, depthState);
        }

        if (SDL_GPUGraphicsPipeline** found = key in pipelines)
            return *found;

        SDL_GPUGraphicsPipelineCreateInfo info;
        info.vertexShader = vertex.Shader;
        info.fragmentShader = fragment.Shader;
        info.vertexInputState.vertexBufferDescriptions = layout.Buffers.ptr;
        info.vertexInputState.numVertexBuffers = layout.BufferCount;
        info.vertexInputState.vertexAttributes = layout.Attributes.ptr;
        info.vertexInputState.numVertexAttributes = layout.AttributeCount;
        info.primitiveType = primitive;
        info.rasteriserState.fillMode = SDL_GPU_FILLMODE_FILL;
        info.rasteriserState.cullMode = !cull ? SDL_GPU_CULLMODE_NONE : cullFace == GuestCullFace.Front ? SDL_GPU_CULLMODE_FRONT : SDL_GPU_CULLMODE_BACK; // todo: should be Front and Back
        info.rasteriserState.frontFace = counterClockwise ? SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE : SDL_GPU_FRONTFACE_CLOCKWISE;
        info.targetInfo.colourTargetDescriptions = descriptions.ptr;
        info.targetInfo.numColourTargets = cast(uint) colorTargets.length;
        if (depthTarget !is null) {
            info.targetInfo.hasDepthStencilTarget = true;
            info.targetInfo.depthStencilFormat = depthTarget.Format;
            info.depthStencilState = depthState;
        }

        const MonoTime pipelineStart = MonoTime.currTime;
        SDL_GPUGraphicsPipeline* pipeline = SDL_CreateGPUGraphicsPipeline(Device, &info);
        if (pipeline is null)
            log.Error("Pipeline creation failed: %s", fromStringz(SDL_GetError()));
        else
            log.Info("Created pipeline #%d in %.2f ms", pipelines.length + 1, Milliseconds(pipelineStart));
        pipelines[key] = pipeline;
        return pipeline;
    }

    private SDL_GPUViewport Viewport(Maxwell3D engine, const(RenderTargetTexture)* target, bool lowerLeft, out float[4] viewParams) {
        float[6] transform;
        foreach (i; 0 .. 6)
            transform[i] = engine.RegisterFloat(Maxwell3DMethod.ViewportTransform + i);

        if (transform[0] == 0 || transform[1] == 0) {
            viewParams = [1.0f, 0.5f, 0.5f, 0];
            return SDL_GPUViewport(0, 0, target.Width, target.Height, 0, 1);
        }

        const bool flipY = (transform[1] > 0) != lowerLeft;
        viewParams = [flipY ? -1.0f : 1.0f, transform[2], transform[5], 0];
        float top = transform[4] - abs(transform[1]);
        if (lowerLeft)
            top = target.Height - (transform[4] + abs(transform[1]));
        return SDL_GPUViewport(transform[3] - abs(transform[0]), top, 2 * abs(transform[0]), 2 * abs(transform[1]), 0, 1);
    }

    // Textures
    private void DebugTextures(Maxwell3D engine, ShaderStage stage) {
        foreach (offset; TextureOffsets(ReadProgram(engine.ShaderAddress(stage)), ShaderHeaderWords)) {
            TextureHandle handle;
            if (!engine.ReadTextureHandle(stage, offset, handle)) {
                FailOnce(format("handle%d:%X", stage, offset), "Stage (%d) texture handle at offset 0x%X was not bound!", stage, offset);
                continue;
            }
            TextureHeader header;
            SamplerHeader sampler;
            const bool hasHeader = engine.ReadTextureHeader(handle.HeaderIndex, header);
            const bool hasSampler = engine.ReadSamplerHeader(engine.SamplerIndex(handle), sampler);
            const string key = format("%d:%X:%s:%s", stage, handle.Raw, header.Words, sampler.Words);
            if (key in describedTextures)
                continue;
            describedTextures[key] = true;
            log.Info("Stage %d texture at 0x%X, handle 0x%08X (TIC %d, TSC %d)", stage, offset, handle.Raw, handle.HeaderIndex, engine.SamplerIndex(handle));
            log.Info("TIC: %s", hasHeader ? header.DebugDesc() : "outside header");
            log.Info("TSC: %s", hasSampler ? sampler.DebugDesc() : "outside sampler");
        }
    }

    private SDL_GPUTexture* TargetAsTexture(const ref TextureHeader header) {
        ulong address;
        if (!memory.Translate(header.Address, address)) {
            return null;
        }
        RenderTargetTexture* target = address in targets;
        if (target is null || target.Width != header.Width || target.Height != header.Height) {
            return null;
        }
        if (target.GuestDirty) {
            ReloadFromGuest(*target);
        }
        if (address !in sampledTargets) {
            sampledTargets[address] = true;
            log.Info("Sampling host render target texture %dx%d at guest 0x%X.", target.Width, target.Height, address);
        }
        return target.Texture;
    }

    private bool TextureBindings(Maxwell3D engine, ShaderStage stage, const(uint)[] offsets, out SDL_GPUTextureSamplerBinding[] bindings) {
        // Bindings follow each texture's cbuf offset in order
        foreach (offset; offsets) { 
            TextureHandle handle;
            TextureHeader header;
            SamplerHeader samplerHeader;
            if (!engine.ReadTextureHandle(stage, offset, handle) || !engine.ReadTextureHeader(handle.HeaderIndex, header) || !engine.ReadSamplerHeader(engine.SamplerIndex(handle), samplerHeader)) {
                FailOnce(format("binding%d:%X", stage, offset), "Stage %d texture at cbuf offset 0x%X has no valid descriptors!", stage, offset);
                return false;
            }
            SDL_GPUSampler* sampler = textureCache.Sampler(samplerHeader);
            if (sampler is null) {
                return false;
            }
            SDL_GPUTexture* rendered = TargetAsTexture(header);
            if (rendered !is null) {
                bindings ~= SDL_GPUTextureSamplerBinding(rendered, sampler);
                continue;
            }
            CachedTexture* texture = textureCache.Texture(header);
            if (texture is null) {
                return false;
            }
            bindings ~= SDL_GPUTextureSamplerBinding(texture.Texture, sampler);
        }
        return true;
    }

    // Draws
    bool Draw(Maxwell3D engine, uint topology, uint first, uint count, bool indexed, uint instances) {
        if (count == 0)
            return true;
        if (!Ready() || !SupportedStages(engine))
            return false;

        bool fan;
        const SDL_GPUPrimitiveType primitive = Topology(topology, fan);
        if (primitive == cast(SDL_GPUPrimitiveType) -1) {
            FailOnce(format("topology%d", topology), "Topology %d is not supported", topology);
            return false;
        }

        DebugTextures(engine, ShaderStage.VertexB);
        DebugTextures(engine, ShaderStage.Fragment);

        CachedShader* vertex = Shader(engine, ShaderStage.VertexB, ShaderStageKind.Vertex);
        CachedShader* fragment = Shader(engine, ShaderStage.Fragment, ShaderStageKind.Fragment);
        if (vertex is null || fragment is null)
            return false;

        SDL_GPUTextureSamplerBinding[] vertexTextures;
        SDL_GPUTextureSamplerBinding[] fragmentTextures;
        if (!TextureBindings(engine, ShaderStage.VertexB, vertex.Translation.Textures, vertexTextures) || !TextureBindings(engine, ShaderStage.Fragment, fragment.Translation.Textures, fragmentTextures)) {
            return false;
        }

        RenderTargetTexture*[RenderTargetCount] targetStorage;
        size_t targetCount;
        if (!BoundTargets(engine, targetStorage, targetCount))
            return false;
        if (targetCount == 0)
            return true;
        RenderTargetTexture*[] colorTargets = targetStorage[0 .. targetCount];

        VertexLayout layout;
        if (!BuildVertexLayout(engine, vertex.Translation.AttributeMask, layout))
            return false;

        const bool lowerLeft = (engine.Registers[Maxwell3DMethod.WindowOrigin] & 1) != 0;
        float[4] viewParams;
        SDL_GPUViewport viewport = Viewport(engine, colorTargets[0], lowerLeft, viewParams);

        RenderTargetTexture* depthTarget = ZetaTarget(engine);
        if (depthTarget !is null && (depthTarget.Width != colorTargets[0].Width || depthTarget.Height != colorTargets[0].Height)) {
            FailOnce(format("zetasize%dx%d", depthTarget.Width, depthTarget.Height), "Depth target %dx%d doesnt match colour target %dx%d.", depthTarget.Width, depthTarget.Height, colorTargets[0].Width, colorTargets[0].Height);
            depthTarget = null;
        }

        SDL_GPUGraphicsPipeline* pipeline = Pipeline(engine, vertex, fragment, layout, primitive, colorTargets, depthTarget, lowerLeft);
        if (pipeline is null)
            return false;

        SDL_GPUTexture* depthTexture = depthTarget !is null ? depthTarget.Texture : null;
        if (!batch.SameTargets(colorTargets, depthTexture)) {
            Flush();
            batch.SetTargets(colorTargets, depthTexture);
        }
        bool EndDraw() {
            return false;
        }

        uint[] indices;
        uint lowest = first;
        uint highest = first + count - 1;
        if (indexed || fan) {
            indices = DrawIndices(engine, first, count, indexed, fan);
            if (indices is null)
                return EndDraw();
            if (indices.length == 0) {
                EndDraw();
                return true;
            }
            lowest = uint.max;
            highest = 0;
            foreach (index; indices) {
                lowest = index < lowest ? index : lowest;
                highest = index > highest ? index : highest;
            }
            foreach (ref index; indices) {
                index -= lowest;
            }
        }

        SDL_GPUBufferBinding[MaxVertexArrays] vertexBindings;
        ulong[MaxVertexArrays] uploadedStarts;
        size_t[MaxVertexArrays] uploadedSizes;
        foreach (slot; 0 .. layout.BufferCount) {
            const uint guestArray = layout.GuestArrays[slot];
            const ulong start = engine.Address(Maxwell3DMethod.VertexArrays + guestArray * 4 + 1);
            const ulong end = engine.Address(Maxwell3DMethod.VertexArrayLimits + guestArray * 2) + 1;
            const size_t stride = layout.Buffers[slot].pitch;
            const uint firstElement = layout.PerInstance[slot] ? 0 : lowest;
            const uint elementCount = layout.PerInstance[slot] ? instances : highest - lowest + 1;
            const ulong begin = start + cast(ulong) firstElement * stride;
            if (end <= begin) {
                FailOnce(format("va%d", guestArray), "Vertex array %d has bad range 0x%X..0x%X", guestArray, start, end);
                return EndDraw();
            }
            const size_t size = stride == 0 ? ZeroStrideVertexBytes : cast(size_t) elementCount * stride;
            const size_t available = size > end - begin ? cast(size_t) (end - begin) : size;

            foreach (previous; 0 .. slot) {
                if (uploadedStarts[previous] == begin && uploadedSizes[previous] == size) {
                    vertexBindings[slot].buffer = vertexBindings[previous].buffer;
                    break;
                }
            }
            uploadedStarts[slot] = begin;
            uploadedSizes[slot] = size;
            if (vertexBindings[slot].buffer !is null) {
                continue;
            }
            ubyte[] data = ReadGuest(begin, available);
            if (data is null) {
                FailOnce(format("va%d", guestArray), "Vertex array %d has bad range 0x%X..0x%X", guestArray, start, end);
                return EndDraw();
            }
            data.length = size;
            vertexBindings[slot].buffer = UploadBuffer(data, SDL_GPU_BUFFERUSAGE_VERTEX);
            if (vertexBindings[slot].buffer is null)
                return EndDraw();
        }

        SDL_GPUBuffer*[] vertexStorage;
        SDL_GPUBuffer*[] fragmentStorage;
        if (!UploadConstBuffers(engine, ShaderStage.VertexB, vertex.Translation.ConstBuffers, vertexStorage)
            || !UploadConstBuffers(engine, ShaderStage.Fragment, fragment.Translation.ConstBuffers, fragmentStorage))
            return EndDraw();

        SDL_GPUBuffer* indexBuffer;
        uint drawCount = count;
        if (indices.length != 0) {
            indexBuffer = UploadBuffer(cast(const(ubyte)[]) indices, SDL_GPU_BUFFERUSAGE_INDEX);
            if (indexBuffer is null)
                return EndDraw();
            drawCount = cast(uint) indices.length;
        }
        PendingDraw pending;
        pending.Pipeline = pipeline;
        pending.Viewport = viewport;
        pending.BlendColor = SDL_FColor(engine.BlendColor(0), engine.BlendColor(1), engine.BlendColor(2), engine.BlendColor(3));
        pending.StencilReference = cast(ubyte) engine.Stencil(false).Reference;
        pending.ViewParams = viewParams;
        pending.VertexBindings = vertexBindings;
        pending.VertexBufferCount = layout.BufferCount;
        pending.VertexStorage = vertexStorage;
        pending.FragmentStorage = fragmentStorage;
        pending.VertexTextures = vertexTextures;
        pending.FragmentTextures = fragmentTextures;
        pending.IndexBuffer = indexBuffer;
        pending.DrawCount = drawCount;
        pending.Instances = instances;
        batch.Draws ~= pending;
        if (batch.Draws.length >= MaxBatchedDraws || batch.Staging.length >= MaxBatchedBytes) {
            Flush();
        }
        return true;
    }
}
