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

// Class
final class HostDisplay {
    string Title = "Myouou";
    bool ShouldQuit;

    private SDL_Window* window;
    private SDL_Renderer* renderer;
    private SDL_Texture* texture;
    private int textureWidth;
    private int textureHeight;
    private SDL_PixelFormat textureFormat;
    private bool unavailable;
    private size_t frameCount;
    private Logger log;

    this() {
        log = GetLogger("Display");
    }

    bool IsOpen() const {
        return window !is null;
    }

    size_t Frames() const {
        return frameCount;
    }

    void SetTitle(string title) {
        Title = "Myouou - " ~ title;
    }

    private bool OpenDisplay(int width, int height) {
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
        if (!SDL_Init(SDL_INIT_VIDEO) || !SDL_CreateWindowAndRenderer(Title.toStringz, width, height, SDL_WINDOW_RESIZABLE, &window, &renderer)) {
            log.Error("SDL3 window creation failed (%s)!", fromStringz(SDL_GetError()));
            unavailable = true;
            return false;
        }

        SDL_SetRenderVSync(renderer, 1);
        SDL_SetRenderLogicalPresentation(renderer, width, height, SDL_LOGICAL_PRESENTATION_LETTERBOX);
        log.Info("Opened %dx%d window", width, height);
        return true;
    }

    private static SDL_PixelFormat HostFormat(GuestPixelFormat format) {
        switch (format) {
            case GuestPixelFormat.Rgbx8888: return SDL_PIXELFORMAT_XBGR8888;
            case GuestPixelFormat.Rgb888: return SDL_PIXELFORMAT_RGB24;
            case GuestPixelFormat.Rgb565: return SDL_PIXELFORMAT_RGB565;
            case GuestPixelFormat.Bgra8888: return SDL_PIXELFORMAT_ARGB8888;
            default: return SDL_PIXELFORMAT_ABGR8888;
        }
    }

    void Present(const(ubyte)[] pixels, int width, int height, int pitch, GuestPixelFormat format) {
        if (!OpenDisplay(width, height)) {
            return;
        }

        const SDL_PixelFormat hostFormat = HostFormat(format);
        if (texture is null || textureWidth != width || textureHeight != height || textureFormat != hostFormat) {
            if (texture !is null) {
                SDL_DestroyTexture(texture);
            }
            texture = SDL_CreateTexture(renderer, hostFormat, SDL_TEXTUREACCESS_STREAMING, width, height);
            if (texture is null) {
                log.Error("SDL3 texture creation failed: %s", fromStringz(SDL_GetError()));
                return;
            }
            SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST);
            SDL_SetRenderLogicalPresentation(renderer, width, height, SDL_LOGICAL_PRESENTATION_LETTERBOX);
            textureWidth = width;
            textureHeight = height;
            textureFormat = hostFormat;
        }

        SDL_UpdateTexture(texture, null, pixels.ptr, pitch);
        SDL_RenderClear(renderer);
        SDL_RenderTexture(renderer, texture, null, null);
        SDL_RenderPresent(renderer);
        frameCount++;
        UpdateEvents();
    }

    void UpdateEvents() {
        if (window is null)
            return;
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
                ShouldQuit = true;
            }
        }
    }

    void Close() {
        if (texture !is null) {
            SDL_DestroyTexture(texture);
        }
        if (renderer !is null) {
            SDL_DestroyRenderer(renderer);
        }
        if (window !is null) {
            SDL_DestroyWindow(window);
            SDL_Quit();
        }
        texture = null;
        renderer = null;
        window = null;
    }
}
