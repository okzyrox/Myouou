/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Guest texture/samp into SDLGPU
 * if i do end up switching backend then I might change this later..
*/

module Source.Gpu.TextureCache;

// Std
import std.format : format;
import std.string : fromStringz;

// Deps
import bindbc.sdl;

// Core
import Source.Frontend.HostDisplay;
import Source.Gpu.MemoryManager;
import Source.Gpu.Texture;
import Source.Graphics.BlockLinear;
import Source.Util.Logger;

// Types
enum size_t MaxTextureBytes = 64 * 1024 * 1024;
enum uint TrackedPageShift = 12;

struct HostTextureFormat {
    SDL_GPUTextureFormat Format = SDL_GPU_TEXTUREFORMAT_INVALID;
    uint BlockWidth = 1;
    uint BlockHeight = 1;
    uint BytesPerBlock;

    bool Valid() const {
        return Format != SDL_GPU_TEXTUREFORMAT_INVALID;
    }
}

struct CachedTexture {
    SDL_GPUTexture* Texture;
    uint Width;
    uint Height;
    HostTextureFormat Format;
    TextureHeader Header;
    ulong CpuAddress;
    size_t GuestSize;
    bool Dirty;
}

HostTextureFormat ToHostFormat(const ref TextureHeader header) {
    const TextureComponent component = header.Component(0);
    const bool unorm = component == TextureComponent.Unorm;
    const bool float_ = component == TextureComponent.Float;
    switch (header.Format) {
        case TextureFormat.A8R8G8B8:
            if (unorm) {
                return HostTextureFormat(header.Srgb ? SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB : SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, 1, 1, 4);
            }
            if (component == TextureComponent.Snorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R8G8B8A8_SNORM, 1, 1, 4);
            }
            break;
        case TextureFormat.G8R8:
            if (unorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R8G8_UNORM, 1, 1, 2);
            }
            break;
        case TextureFormat.R8:
            if (unorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R8_UNORM, 1, 1, 1);
            }
            break;
        case TextureFormat.R16:
            if (unorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R16_UNORM, 1, 1, 2);
            }
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R16_FLOAT, 1, 1, 2);
            }
            break;
        case TextureFormat.R16G16:
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT, 1, 1, 4);
            }
            break;
        case TextureFormat.R16G16B16A16:
            if (unorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UNORM, 1, 1, 8);
            }
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, 1, 1, 8);
            }
            break;
        case TextureFormat.R32:
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R32_FLOAT, 1, 1, 4);
            }
            break;
        case TextureFormat.R32G32:
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R32G32_FLOAT, 1, 1, 8);
            }
            break;
        case TextureFormat.R32G32B32A32:
            if (float_) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT, 1, 1, 16);
            }
            break;
        case TextureFormat.A2B10G10R10:
            if (unorm) {
                return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R10G10B10A2_UNORM, 1, 1, 4);
            }
            break;
        case TextureFormat.B10G11R11:
            return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT, 1, 1, 4);
        case TextureFormat.BC1:
            return HostTextureFormat(header.Srgb ? SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB : SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM, 4, 4, 8);
        case TextureFormat.BC2:
            return HostTextureFormat(header.Srgb ? SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB : SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM, 4, 4, 16);
        case TextureFormat.BC3:
            return HostTextureFormat(header.Srgb ? SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB : SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM, 4, 4, 16);
        case TextureFormat.BC4:
            return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_BC4_R_UNORM, 4, 4, 8);
        case TextureFormat.BC5:
            return HostTextureFormat(SDL_GPU_TEXTUREFORMAT_BC5_RG_UNORM, 4, 4, 16);
        case TextureFormat.BC7:
            return HostTextureFormat(header.Srgb ? SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB : SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM, 4, 4, 16);
        default:
            break;
    }
    return HostTextureFormat.init;
}

// Class
final class TextureCache {
    private HostDisplay display;
    private GpuMemoryManager memory;
    private CachedTexture[string] textures;
    private SDL_GPUSampler*[string] samplers;
    private bool[string] failures;
    private bool[ulong] trackedPages;
    void delegate() BeforeUpload;
    private Logger log;

    this(HostDisplay display, GpuMemoryManager memory) {
        this.display = display;
        this.memory = memory;
        log = GetLogger("Gpu::TextureCache");
        memory.OnWrite = &GuestWritten;
    }

    private SDL_GPUDevice* Device() {
        return display.Device;
    }

    private void FailOnce(A...)(string key, string text, A args) {
        if (key in failures) {
            return;
        }
        failures[key] = true;
        log.Warn(text, args);
    }

    CachedTexture* Texture(const ref TextureHeader header) {
        const string key = format("%s", header.Words);
        if (CachedTexture* found = key in textures) {
            if (found.Dirty) {
                Reupload(*found);
            }
            return found;
        }

        if (header.Type != TextureType.Texture2D && header.Type != TextureType.Texture2DNoMipmap) {
            FailOnce(format("type%d", header.Type), "Texture type %s is not supported!!", header.Type);
            return null;
        }
        const HostTextureFormat hostFormat = ToHostFormat(header);
        if (!hostFormat.Valid) {
            FailOnce(format("format%X:%d", header.Format, header.Component(0)), "Texture format 0x%X (%s) has no host format!", header.Format, header.Component(0));
            return null;
        }

        const uint width = header.Width;
        const uint height = header.Height;
        size_t rowBytes;
        size_t blocksHigh;
        Layout(header, hostFormat, rowBytes, blocksHigh);
        ubyte[] pixels = new ubyte[rowBytes * blocksHigh];
        if (!ReadPixels(header, rowBytes, blocksHigh, pixels)) {
            return null;
        }

        SDL_GPUTextureCreateInfo info;
        info.type = SDL_GPU_TEXTURETYPE_2D;
        info.format = hostFormat.Format;
        info.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = width;
        info.height = height;
        SDL_GPUTexture* texture = SDL_CreateGPUTexture(Device, &info);
        if (texture is null) {
            log.Error("Texture creation failed: %s", fromStringz(SDL_GetError()));
            return null;
        }
        if (BeforeUpload !is null) {
            BeforeUpload();
        }
        display.UploadTexture(texture, pixels, width, height, width);

        log.Info("Uploaded texture %dx%d %s at gpu 0x%X (%d bytes)%s.", width, height, hostFormat.Format, header.Address, pixels.length, CornerTexels(pixels, rowBytes, blocksHigh, hostFormat));
        CachedTexture cached = CachedTexture(texture, width, height, hostFormat, header);
        Track(cached, rowBytes, blocksHigh);
        textures[key] = cached;
        return key in textures;
    }

    private static void Layout(const ref TextureHeader header, const ref HostTextureFormat hostFormat, out size_t rowBytes, out size_t rows) {
        const size_t blocksWide = (header.Width + hostFormat.BlockWidth - 1) / hostFormat.BlockWidth;
        rows = (header.Height + hostFormat.BlockHeight - 1) / hostFormat.BlockHeight;
        rowBytes = blocksWide * hostFormat.BytesPerBlock;
    }

    private static size_t GuestSize(const ref TextureHeader header, size_t rowBytes, size_t rows) {
        if (header.BlockLinear) {
            const size_t pitch = (rowBytes + GobWidth - 1) & ~(GobWidth - 1);
            return BlockLinearSize(pitch, rows, header.BlockHeightLog2);
        }
        return header.Pitch * rows;
    }

    private void Track(ref CachedTexture cached, size_t rowBytes, size_t rows) {
        cached.GuestSize = GuestSize(cached.Header, rowBytes, rows);
        // Texture memory is tracked in CPU address space so GPU mapping writes still get seen
        if (!memory.Translate(cached.Header.Address, cached.CpuAddress) || cached.GuestSize == 0) {
            return;
        }
        foreach (page; cached.CpuAddress >> TrackedPageShift .. ((cached.CpuAddress + cached.GuestSize - 1) >> TrackedPageShift) + 1) {
            trackedPages[page] = true;
        }
    }

    private void GuestWritten(ulong cpuAddress, size_t size) {
        if (size == 0) {
            return;
        }
        bool tracked = false;
        foreach (page; cpuAddress >> TrackedPageShift .. ((cpuAddress + size - 1) >> TrackedPageShift) + 1) {
            if (page in trackedPages) {
                tracked = true;
                break;
            }
        }
        if (!tracked) {
            return;
        }
        foreach (ref cached; textures) {
            if (cached.CpuAddress < cpuAddress + size && cpuAddress < cached.CpuAddress + cached.GuestSize) {
                cached.Dirty = true;
            }
        }
    }

    private void Reupload(ref CachedTexture cached) {
        cached.Dirty = false;
        size_t rowBytes;
        size_t rows;
        Layout(cached.Header, cached.Format, rowBytes, rows);
        ubyte[] pixels = new ubyte[rowBytes * rows];
        if (!ReadPixels(cached.Header, rowBytes, rows, pixels)) {
            return;
        }
        if (BeforeUpload !is null) {
            BeforeUpload();
        }
        display.UploadTexture(cached.Texture, pixels, cached.Width, cached.Height, cached.Width);
        log.Trace("Reuploaded texture %dx%d at gpu addr 0x%X.", cached.Width, cached.Height, cached.Header.Address);
    }

    private bool ReadPixels(const ref TextureHeader header, size_t rowBytes, size_t rows, ubyte[] pixels) {
        if (header.BlockLinear) {
            const size_t pitch = (rowBytes + GobWidth - 1) & ~(GobWidth - 1);
            const size_t size = GuestSize(header, rowBytes, rows);
            if (size > MaxTextureBytes) {
                FailOnce(format("size%X", header.Address), "Texture at gpu 0x%X is too large (%d bytes)!", header.Address, size);
                return false;
            }
            ubyte[] guest = new ubyte[size];
            memory.Read(header.Address, guest);
            BlockLinearDeswizzle(guest, pixels, rowBytes, rows, pitch, header.BlockHeightLog2);
            return true;
        }

        if (header.Version != TextureHeaderVersion.Pitch && header.Version != TextureHeaderVersion.PitchColorKey) {
            FailOnce(format("layout%d", header.Version), "Texture layout %s is not supported.", header.Version);
            return false;
        }
        const size_t pitch = header.Pitch;
        if (pitch < rowBytes || pitch * rows > MaxTextureBytes) {
            FailOnce(format("pitch%X", header.Address), "Texture at gpu 0x%X has a bad pitch (%d)!", header.Address, pitch);
            return false;
        }
        foreach (y; 0 .. rows) {
            memory.Read(header.Address + y * pitch, pixels[y * rowBytes .. (y + 1) * rowBytes]);
        }
        return true;
    }

    private static string CornerTexels(const(ubyte)[] pixels, size_t rowBytes, size_t rows, const ref HostTextureFormat hostFormat) {
        if (hostFormat.BlockWidth != 1 || rows == 0) {
            return "";
        }
        const size_t size = hostFormat.BytesPerBlock;
        const size_t last = (rows - 1) * rowBytes + rowBytes - size;
        return format(", first texel %(%02X%), last texel %(%02X%)", pixels[0 .. size], pixels[last .. last + size]);
    }

    private static SDL_GPUSamplerAddressMode AddressMode(WrapMode mode) {
        switch (mode) {
            case WrapMode.Wrap:
                return SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
            case WrapMode.Mirror:
                return SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
            default:
                // todo: SDL GPU has no border colour for border clamps
                return SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        }
    }

    private static SDL_GPUFilter Filter(TextureFilter filter) {
        return filter == TextureFilter.Linear ? SDL_GPU_FILTER_LINEAR : SDL_GPU_FILTER_NEAREST;
    }

    SDL_GPUSampler* Sampler(const ref SamplerHeader header) {
        const string key = format("%s", header.Words[0 .. 4]);
        if (SDL_GPUSampler** found = key in samplers) {
            return *found;
        }

        SDL_GPUSamplerCreateInfo info;
        info.minFilter = Filter(header.MinFilter);
        info.magFilter = Filter(header.MagFilter);
        info.mipmapMode = header.MipFilter == MipmapFilter.Linear ? SDL_GPU_SAMPLERMIPMAPMODE_LINEAR : SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        info.addressModeU = AddressMode(header.WrapU);
        info.addressModeV = AddressMode(header.WrapV);
        info.addressModeW = AddressMode(header.WrapP);
        info.minLOD = header.MinLod;
        info.maxLOD = header.MipFilter == MipmapFilter.None ? 0 : header.MaxLod;
        info.enableAnisotropy = header.MaxAnisotropy > 1;
        info.maxAnisotropy = header.MaxAnisotropy;
        SDL_GPUSampler* sampler = SDL_CreateGPUSampler(Device, &info);
        if (sampler is null) {
            log.Error("Sampler creation failed: %s", fromStringz(SDL_GetError()));
            return null;
        }
        log.Info("Created sampler: %s", header.DebugDesc());
        samplers[key] = sampler;
        return sampler;
    }
}
