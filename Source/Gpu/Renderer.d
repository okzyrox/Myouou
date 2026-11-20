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
import Source.Gpu.Shader.Translator;
import Source.Util.Logger;

// Types
enum uint MaxVertexAttributes = 32;
enum uint MaxVertexArrays = 32;
enum size_t MaxGuestBufferSize = 64 * 1024 * 1024;
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
}

struct VertexLayout {
    SDL_GPUVertexBufferDescription[MaxVertexArrays] Buffers;
    uint BufferCount;
    SDL_GPUVertexAttribute[MaxVertexAttributes] Attributes;
    uint AttributeCount;
    uint[MaxVertexArrays] GuestArrays;
}

struct DrawUploads {
    SDL_GPUBuffer*[] Buffers;
    SDL_GPUTransferBuffer*[] Transfers;
}

// Class
final class HostRenderer : GpuRenderer {
    private HostDisplay display;
    private GpuMemoryManager memory;
    // TODO: host render targets are never written back to guest memory
    private RenderTargetTexture[ulong] targets;
    private CachedShader[ulong] shaders;
    private SDL_GPUGraphicsPipeline*[string] pipelines;
    private bool[string] failures;
    private Logger log;

    this(HostDisplay display, GpuMemoryManager memory) {
        this.display = display;
        this.memory = memory;
        log = GetLogger("Gpu::Renderer");
        display.FindHostSurface = &FindSurface;
    }

    private SDL_GPUDevice* Device() {
        return display.Device;
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
        if (existing !is null && existing.Width == target.Width && existing.Height == target.Height && existing.Format == hostFormat)
            return existing;
        if (existing !is null)
            SDL_ReleaseGPUTexture(Device, existing.Texture);

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
        targets[address] = RenderTargetTexture(texture, target.Width, target.Height, hostFormat);
        return address in targets;
    }

    private bool FindSurface(ulong address, out HostSurface surface) {
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
    
    // TODO: depth and stencil
    bool Clear(Maxwell3D engine, uint argument) {
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

    // TODO: cache shader programs rather than reload every time
    private CachedShader* Shader(Maxwell3D engine, ShaderStage stage, ShaderStageKind kind) {
        const ulong address = engine.ShaderAddress(stage);
        const ulong[] program = ReadProgram(address);
        const ulong key = Hash(program) ^ stage;
        if (CachedShader* found = key in shaders)
            return found.Shader is null ? null : found;

        CachedShader cached;
        cached.Translation = TranslateShader(kind, program);
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
        info.numUniformBuffers = kind == ShaderStageKind.Vertex ? 1 : 0;
        cached.Shader = SDL_CreateGPUShader(Device, &info);
        if (cached.Shader is null)
            log.Error("Stage %d host shader creation failed: %s", stage, fromStringz(SDL_GetError()));
        else
            log.Info("Translated stage %d shader at gpu 0x%X (%d instructions, %d bytes of SPIR-V)", stage, address, cached.Translation.InstructionCount, spirv.length);
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
                slots[buffer] = layout.BufferCount;
                SDL_GPUVertexBufferDescription description;
                description.slot = layout.BufferCount;
                description.pitch = engine.Registers[Maxwell3DMethod.VertexArrays + buffer * 4] & 0xFFF;
                description.inputRate = SDL_GPU_VERTEXINPUTRATE_VERTEX;
                layout.Buffers[layout.BufferCount] = description;
                layout.GuestArrays[layout.BufferCount] = buffer;
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
    private SDL_GPUBuffer* UploadBuffer(SDL_GPUCopyPass* copy, const(ubyte)[] data, SDL_GPUBufferUsageFlags_ usage, ref DrawUploads uploads) {
        SDL_GPUBufferCreateInfo info;
        info.usage = usage;
        info.size = cast(uint) ((data.length + 3) & ~3);
        SDL_GPUBuffer* buffer = SDL_CreateGPUBuffer(Device, &info);
        if (buffer is null)
            return null;
        uploads.Buffers ~= buffer;

        SDL_GPUTransferBufferCreateInfo transferInfo;
        transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transferInfo.size = info.size;
        SDL_GPUTransferBuffer* transfer = SDL_CreateGPUTransferBuffer(Device, &transferInfo);
        if (transfer is null)
            return null;
        uploads.Transfers ~= transfer;
        ubyte* mapped = cast(ubyte*) SDL_MapGPUTransferBuffer(Device, transfer, false);
        mapped[0 .. data.length] = data[];
        mapped[data.length .. info.size] = 0;
        SDL_UnmapGPUTransferBuffer(Device, transfer);

        SDL_GPUTransferBufferLocation source;
        source.transferBuffer = transfer;
        SDL_GPUBufferRegion destination;
        destination.buffer = buffer;
        destination.size = info.size;
        SDL_UploadToGPUBuffer(copy, &source, &destination, false);
        return buffer;
    }

    private void Release(ref DrawUploads uploads) {
        foreach (buffer; uploads.Buffers)
            SDL_ReleaseGPUBuffer(Device, buffer);
        foreach (transfer; uploads.Transfers)
            SDL_ReleaseGPUTransferBuffer(Device, transfer);
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

    private bool UploadConstBuffers(Maxwell3D engine, ShaderStage stage, const(uint)[] indices, SDL_GPUCopyPass* copy, ref DrawUploads uploads, out SDL_GPUBuffer*[] result) {
        foreach (index; indices) {
            const ConstBufferBinding binding = engine.ConstBuffer(ConstBufferStage(stage), index);
            ubyte[] data = binding.Enabled ? ReadGuest(binding.Address, binding.Size) : null;
            if (data is null)
                data = new ubyte[16];
            SDL_GPUBuffer* buffer = UploadBuffer(copy, data, SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, uploads);
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

    private SDL_GPUGraphicsPipeline* Pipeline(Maxwell3D engine, CachedShader* vertex, CachedShader* fragment, const ref VertexLayout layout,
                                              SDL_GPUPrimitiveType primitive, const(RenderTargetTexture*)[] colorTargets, bool lowerLeft) {
        SDL_GPUColorTargetDescription[RenderTargetCount] descriptions;
        string key = format("%s|%s|%d", vertex.Shader, fragment.Shader, primitive);
        foreach (i, target; colorTargets) {
            const uint mask = engine.Registers[Maxwell3DMethod.ColorMask + i];
            descriptions[i].format = target.Format;
            descriptions[i].blendState.enableColourWriteMask = true;
            descriptions[i].blendState.colourWriteMask = cast(ubyte) (((mask & 1) ? SDL_GPU_COLORCOMPONENT_R : 0) | ((mask & 0x10) ? SDL_GPU_COLORCOMPONENT_G : 0)
                | ((mask & 0x100) ? SDL_GPU_COLORCOMPONENT_B : 0) | ((mask & 0x1000) ? SDL_GPU_COLORCOMPONENT_A : 0));
            key ~= format("|rt%d:%d", target.Format, mask);
        }
        foreach (i; 0 .. layout.BufferCount)
            key ~= format("|vb%d", layout.Buffers[i].pitch);
        foreach (i; 0 .. layout.AttributeCount)
            key ~= format("|va%d:%d:%d:%d", layout.Attributes[i].location, layout.Attributes[i].bufferSlot, layout.Attributes[i].format, layout.Attributes[i].offset);

        const bool cull = engine.Registers[Maxwell3DMethod.CullEnable] != 0;
        const uint cullFace = engine.Registers[Maxwell3DMethod.CullFace];
        const bool counterClockwise = (engine.Registers[Maxwell3DMethod.FrontFace] != GuestFrontFace.Clockwise) != lowerLeft;
        key ~= format("|cull%d:%X:%d", cull, cullFace, counterClockwise);

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

        SDL_GPUGraphicsPipeline* pipeline = SDL_CreateGPUGraphicsPipeline(Device, &info);
        if (pipeline is null)
            log.Error("Pipeline creation failed: %s", fromStringz(SDL_GetError()));
        else
            log.Info("Created pipeline #%d", pipelines.length + 1);
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

    // Draws
    bool Draw(Maxwell3D engine, uint topology, uint first, uint count, bool indexed) {
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

        CachedShader* vertex = Shader(engine, ShaderStage.VertexB, ShaderStageKind.Vertex);
        CachedShader* fragment = Shader(engine, ShaderStage.Fragment, ShaderStageKind.Fragment);
        if (vertex is null || fragment is null)
            return false;

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

        SDL_GPUGraphicsPipeline* pipeline = Pipeline(engine, vertex, fragment, layout, primitive, colorTargets, lowerLeft);
        if (pipeline is null)
            return false;

        DrawUploads uploads;
        scope (exit)
            Release(uploads);
            // todo: use shared command buffers/renderpass for batched draw
            // cause this is expensive..
        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(Device);
        SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(commands);
        bool Abort() {
            SDL_EndGPUCopyPass(copy);
            SDL_CancelGPUCommandBuffer(commands);
            return false;
        }

        SDL_GPUBufferBinding[MaxVertexArrays] vertexBindings;
        foreach (slot; 0 .. layout.BufferCount) {
            const uint guestArray = layout.GuestArrays[slot];
            const ulong start = engine.Address(Maxwell3DMethod.VertexArrays + guestArray * 4 + 1);
            const ulong limit = engine.Address(Maxwell3DMethod.VertexArrayLimits + guestArray * 2);
            const ubyte[] data = ReadGuest(start, limit >= start ? cast(size_t) (limit - start + 1) : 0);
            if (data is null) {
                FailOnce(format("va%d", guestArray), "Vertex array %d has bad range 0x%X..0x%X", guestArray, start, limit);
                return Abort();
            }
            vertexBindings[slot].buffer = UploadBuffer(copy, data, SDL_GPU_BUFFERUSAGE_VERTEX, uploads);
            if (vertexBindings[slot].buffer is null)
                return Abort();
        }

        SDL_GPUBuffer*[] vertexStorage;
        SDL_GPUBuffer*[] fragmentStorage;
        if (!UploadConstBuffers(engine, ShaderStage.VertexB, vertex.Translation.ConstBuffers, copy, uploads, vertexStorage)
            || !UploadConstBuffers(engine, ShaderStage.Fragment, fragment.Translation.ConstBuffers, copy, uploads, fragmentStorage))
            return Abort();

        SDL_GPUBuffer* indexBuffer;
        uint drawCount = count;
        if (indexed || fan) {
            const uint[] indices = DrawIndices(engine, first, count, indexed, fan);
            if (indices is null)
                return Abort();
            indexBuffer = UploadBuffer(copy, cast(const(ubyte)[]) indices, SDL_GPU_BUFFERUSAGE_INDEX, uploads);
            if (indexBuffer is null)
                return Abort();
            drawCount = cast(uint) indices.length;
        }
        SDL_EndGPUCopyPass(copy);

        SDL_GPUColorTargetInfo[RenderTargetCount] colorInfos;
        foreach (i, target; colorTargets) {
            colorInfos[i].texture = target.Texture;
            colorInfos[i].loadOp = SDL_GPU_LOADOP_LOAD;
            colorInfos[i].storeOp = SDL_GPU_STOREOP_STORE;
        }
        SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(commands, colorInfos.ptr, cast(uint) colorTargets.length, null);
        SDL_BindGPUGraphicsPipeline(pass, pipeline);
        SDL_SetGPUViewport(pass, &viewport);
        if (layout.BufferCount > 0)
            SDL_BindGPUVertexBuffers(pass, 0, vertexBindings.ptr, layout.BufferCount);
        if (vertexStorage.length > 0)
            SDL_BindGPUVertexStorageBuffers(pass, 0, vertexStorage.ptr, cast(uint) vertexStorage.length);
        if (fragmentStorage.length > 0)
            SDL_BindGPUFragmentStorageBuffers(pass, 0, fragmentStorage.ptr, cast(uint) fragmentStorage.length);
        SDL_PushGPUVertexUniformData(commands, 0, viewParams.ptr, viewParams.sizeof);
        if (indexBuffer !is null) {
            SDL_GPUBufferBinding indexBinding;
            indexBinding.buffer = indexBuffer;
            SDL_BindGPUIndexBuffer(pass, &indexBinding, SDL_GPU_INDEXELEMENTSIZE_32BIT);
            SDL_DrawGPUIndexedPrimitives(pass, drawCount, 1, 0, 0, 0);
        } else {
            SDL_DrawGPUPrimitives(pass, drawCount, 1, first, 0);
        }
        SDL_EndGPURenderPass(pass);
        SDL_SubmitGPUCommandBuffer(commands);
        return true;
    }
}
