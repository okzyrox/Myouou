/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Host window for guest frames
*/

module Source.Frontend.HostDisplay;

// Std
import std.string : fromStringz, toStringz;

// Deps
import bindbc.sdl;
import bindbc.loader : LoadMsg;

// Core
import Source.Frontend.Input;
import Source.Util.Logger;

// Types
enum GuestPixelFormat : uint {
    Rgba8888 = 1,
    Rgbx8888 = 2,
    Rgb888 = 3,
    Rgb565 = 4,
    Bgra8888 = 5,
}

uint BytesPerPixel(GuestPixelFormat format) pure nothrow @nogc @safe {
    switch (format) {
        case GuestPixelFormat.Rgb565: return 2;
        case GuestPixelFormat.Rgb888: return 3;
        default: return 4;
    }
}

struct HostSurface {
    SDL_GPUTexture* Texture;
    uint Width;
    uint Height;
}

// Class
final class HostDisplay {
    string Title = "Myouou";
    bool ShouldQuit;
    InputConfig Input;
    void delegate(NpadInput) OnInputCallback;
    bool delegate(ulong address, out HostSurface surface) FindHostSurface;

    private SDL_Window* window;
    private SDL_GPUDevice* device;
    private SDL_GPUTexture* frameTexture;
    private uint frameWidth;
    private uint frameHeight;
    private SDL_GPUTextureFormat frameFormat;
    private bool unavailable;
    private size_t frameCount;
    private Logger log;

    this() {
        log = GetLogger("Display");
        Input = new InputConfig();
        Input.Load();
    }

    bool IsOpen() const {
        return window !is null;
    }

    size_t Frames() const {
        return frameCount;
    }

    SDL_GPUDevice* Device() {
        return device;
    }

    void SetTitle(string title) {
        Title = "Myouou - " ~ title;
    }

    bool GetOrInit(int width, int height) {
        if (window !is null)
            return true;
        if (unavailable)
            return false;

        const LoadMsg loaded = loadSDL();
        if (loaded != LoadMsg.success) {
            log.Error("SDL3 could not be loaded (%s)!", loaded);
            unavailable = true;
            return false;
        }

        if (!SDL_Init(SDL_INIT_VIDEO)) {
            log.Error("SDL3 video init failed (%s)!", fromStringz(SDL_GetError()));
            unavailable = true;
            return false;
        }

        device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, null);
        if (device is null) {
            log.Error("SDL3 GPU device creation failed (%s)!", fromStringz(SDL_GetError()));
            unavailable = true;
            return false;
        }
        window = SDL_CreateWindow(Title.toStringz, width, height, SDL_WINDOW_RESIZABLE);
        if (window is null || !SDL_ClaimWindowForGPUDevice(device, window)) {
            log.Error("SDL3 window creation failed (%s)!", fromStringz(SDL_GetError()));
            unavailable = true;
            return false;
        }
        SDL_SetGPUSwapchainParameters(device, window, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_VSYNC);
        log.Info("Opened %dx%d window using the %s GPU driver", width, height, fromStringz(SDL_GetGPUDeviceDriver(device)));
        return true;
    }

    private static SDL_GPUTextureFormat FrameFormat(GuestPixelFormat format) {
        switch (format) {
            case GuestPixelFormat.Rgb565: return SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM;
            case GuestPixelFormat.Bgra8888: return SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
            default: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        }
    }

    private static ubyte[] ExpandRGB888(const(ubyte)[] pixels, int width, int height, int pitch) {
        ubyte[] expanded = new ubyte[cast(size_t) width * height * 4];
        foreach (y; 0 .. height) {
            foreach (x; 0 .. width) {
                const size_t source = cast(size_t) y * pitch + x * 3;
                const size_t destination = (cast(size_t) y * width + x) * 4;
                expanded[destination .. destination + 3] = pixels[source .. source + 3];
                expanded[destination + 3] = 0xFF;
            }
        }
        return expanded;
    }

    bool UploadTexture(SDL_GPUTexture* texture, const(ubyte)[] pixels, uint width, uint height, uint pixelsPerRow) {
        SDL_GPUTransferBufferCreateInfo transferInfo;
        transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transferInfo.size = cast(uint) pixels.length;
        SDL_GPUTransferBuffer* transfer = SDL_CreateGPUTransferBuffer(device, &transferInfo);
        if (transfer is null) {
            return false;
        }
        void* mapped = SDL_MapGPUTransferBuffer(device, transfer, false);
        (cast(ubyte*) mapped)[0 .. pixels.length] = pixels[];
        SDL_UnmapGPUTransferBuffer(device, transfer);

        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(device);
        SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(commands);
        SDL_GPUTextureTransferInfo source;
        source.transferBuffer = transfer;
        source.pixelsPerRow = pixelsPerRow;
        source.rowsPerLayer = height;
        SDL_GPUTextureRegion destination;
        destination.texture = texture;
        destination.w = width;
        destination.h = height;
        destination.d = 1;
        SDL_UploadToGPUTexture(copy, &source, &destination, false);
        SDL_EndGPUCopyPass(copy);
        SDL_SubmitGPUCommandBuffer(commands);
        SDL_ReleaseGPUTransferBuffer(device, transfer);
        return true;
    }

    void Present(const(ubyte)[] pixels, int width, int height, int pitch, GuestPixelFormat format) {
        if (!GetOrInit(width, height)) {
            return;
        }

        const(ubyte)[] data = pixels;
        uint pixelsPerRow = pitch / BytesPerPixel(format);
        if (format == GuestPixelFormat.Rgb888) {
            data = ExpandRGB888(pixels, width, height, pitch);
            pixelsPerRow = width;
        }

        const SDL_GPUTextureFormat hostFormat = FrameFormat(format);
        if (frameTexture is null || frameWidth != width || frameHeight != height || frameFormat != hostFormat) {
            if (frameTexture !is null)
                SDL_ReleaseGPUTexture(device, frameTexture);
            SDL_GPUTextureCreateInfo info;
            info.type = SDL_GPU_TEXTURETYPE_2D;
            info.format = hostFormat;
            info.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
            info.width = width;
            info.height = height;
            info.layerCountOrDepth = 1;
            info.numLevels = 1;
            frameTexture = SDL_CreateGPUTexture(device, &info);
            if (frameTexture is null) {
                log.Error("SDL3 texture creation failed: %s", fromStringz(SDL_GetError()));
                return;
            }
            frameWidth = width;
            frameHeight = height;
            frameFormat = hostFormat;
        }

        const size_t needed = cast(size_t) pixelsPerRow * height * (format == GuestPixelFormat.Rgb888 ? 4 : BytesPerPixel(format));
        if (data.length < needed) {
            return;
        }
        UploadTexture(frameTexture, data[0 .. needed], width, height, pixelsPerRow);
        PresentTexture(frameTexture, width, height);
    }

    bool PresentGuestSurface(ulong address) {
        HostSurface surface;
        if (FindHostSurface is null || !FindHostSurface(address, surface))
            return false;
        PresentTexture(surface.Texture, surface.Width, surface.Height);
        return true;
    }

    void PresentTexture(SDL_GPUTexture* texture, uint width, uint height) {
        SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(device);
        SDL_GPUTexture* swapchain;
        uint swapWidth;
        uint swapHeight;
        if (!SDL_WaitAndAcquireGPUSwapchainTexture(commands, window, &swapchain, &swapWidth, &swapHeight) || swapchain is null) {
            SDL_CancelGPUCommandBuffer(commands);
            UpdateEvents();
            return;
        }

        const float scale = swapWidth * height < swapHeight * width ? cast(float) swapWidth / width : cast(float) swapHeight / height;
        const uint drawWidth = cast(uint) (width * scale);
        const uint drawHeight = cast(uint) (height * scale);

        SDL_GPUBlitInfo blit;
        blit.source.texture = texture;
        blit.source.w = width;
        blit.source.h = height;
        blit.destination.texture = swapchain;
        blit.destination.x = (swapWidth - drawWidth) / 2;
        blit.destination.y = (swapHeight - drawHeight) / 2;
        blit.destination.w = drawWidth;
        blit.destination.h = drawHeight;
        blit.loadOp = SDL_GPU_LOADOP_CLEAR;
        blit.clearColour = SDL_FColor(0, 0, 0, 1);
        blit.filter = SDL_GPU_FILTER_NEAREST;
        SDL_BlitGPUTexture(commands, &blit);
        SDL_SubmitGPUCommandBuffer(commands);
        frameCount++;
        UpdateEvents();
    }

    void UpdateEvents() {
        if (window is null) {
            return;
        }
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
                ShouldQuit = true;
            }
            else if (event.type == SDL_EVENT_KEY_DOWN) {
                Input.HandleScancode(event.key.scancode);
            }
        }
        if (OnInputCallback !is null) {
            OnInputCallback(Input.Poll());
        }
    }

    void Close() {
        if (device !is null) {
            SDL_WaitForGPUIdle(device);
            if (frameTexture !is null)
                SDL_ReleaseGPUTexture(device, frameTexture);
            if (window !is null)
                SDL_ReleaseWindowFromGPUDevice(device, window);
            SDL_DestroyGPUDevice(device);
        }
        if (window !is null) {
            SDL_DestroyWindow(window);
            SDL_Quit();
        }
        frameTexture = null;
        device = null;
        window = null;
    }
}
