/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Host audio output over SDL3
*/

module Source.Frontend.HostAudio;

// Std
import std.string : fromStringz;

// Deps
import bindbc.sdl;
import bindbc.loader : LoadMsg;

// Core
import Source.Util.Logger;

// Class
final class HostAudio {
    private SDL_AudioStream* stream;
    private uint sampleRate;
    private uint channels;
    private bool unavailable;
    private Logger log;

    this() {
        log = GetLogger("Audio");
    }

    bool IsOpen() const {
        return stream !is null;
    }

    bool Open(uint sampleRate, uint channels) {
        if (stream !is null) {
            return this.sampleRate == sampleRate && this.channels == channels;
        }
        if (unavailable) {
            return false;
        }

        const LoadMsg loaded = loadSDL();
        if (loaded != LoadMsg.success) {
            log.Error("SDL3 could not be loaded (%s)!", loaded);
            unavailable = true;
            return false;
        }
        if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) {
            log.Error("SDL3 audio init failed (%s)!", fromStringz(SDL_GetError()));
            unavailable = true;
            return false;
        }

        SDL_AudioSpec spec;
        spec.format = SDL_AUDIO_S16;
        spec.channels = cast(int) channels;
        spec.freq = cast(int) sampleRate;
        stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
        if (stream is null) {
            log.Error("SDL3 audio stream creation failed (%s)!", fromStringz(SDL_GetError()));
            SDL_QuitSubSystem(SDL_INIT_AUDIO);
            unavailable = true;
            return false;
        }
        this.sampleRate = sampleRate;
        this.channels = channels;
        SDL_ResumeAudioStreamDevice(stream);
        log.Info("Opened audio output %dHz, %d channels.", sampleRate, channels);
        return true;
    }

    void Queue(const(short)[] samples) {
        if (stream is null || samples.length == 0) {
            return;
        }
        // todo: queue
        SDL_PutAudioStreamData(stream, samples.ptr, cast(int) (samples.length * short.sizeof));
    }

    size_t QueuedBytes() {
        if (stream is null) {
            return 0;
        }
        return cast(size_t) SDL_GetAudioStreamQueued(stream);
    }

    void Close() {
        if (stream is null) {
            return;
        }
        SDL_DestroyAudioStream(stream);
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        stream = null;
    }
}
