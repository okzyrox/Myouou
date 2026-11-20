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
final class HostAudioStream {
    immutable uint SampleRate;
    immutable uint Channels;

    private SDL_AudioStream* stream;

    this(SDL_AudioStream* stream, uint sampleRate, uint channels) {
        this.stream = stream;
        SampleRate = sampleRate;
        Channels = channels;
    }

    bool IsOpen() const {
        return stream !is null;
    }

    void Queue(const(short)[] samples) {
        if (stream is null || samples.length == 0) {
            return;
        }
        SDL_PutAudioStreamData(stream, samples.ptr, cast(int) (samples.length * short.sizeof));
    }

    size_t QueuedBytes() {
        if (stream is null) {
            return 0;
        }
        return cast(size_t) SDL_GetAudioStreamQueued(stream);
    }

    void Clear() {
        if (stream !is null) {
            SDL_ClearAudioStream(stream);
        }
    }

    void Close() {
        if (stream is null) {
            return;
        }
        SDL_DestroyAudioStream(stream);
        stream = null;
    }
}

final class HostAudio {
    private SDL_AudioDeviceID device;
    private HostAudioStream[] streams;
    private bool unavailable;
    private Logger log;

    this() {
        log = GetLogger("Audio");
    }

    HostAudioStream OpenStream(uint sampleRate, uint channels) {
        if (!OpenDevice()) {
            return null;
        }
        SDL_AudioSpec spec;
        spec.format = SDL_AUDIO_S16;
        spec.channels = cast(int) channels;
        spec.freq = cast(int) sampleRate;
        SDL_AudioStream* stream = SDL_CreateAudioStream(&spec, null);
        if (stream is null || !SDL_BindAudioStream(device, stream)) {
            log.Error("SDL3 audio stream creation failed (%s)!", fromStringz(SDL_GetError()));
            if (stream !is null) {
                SDL_DestroyAudioStream(stream);
            }
            return null;
        }
        HostAudioStream opened = new HostAudioStream(stream, sampleRate, channels);
        streams ~= opened;
        log.Info("Opened audio stream %dHz, %d channels.", sampleRate, channels);
        return opened;
    }

    private bool OpenDevice() {
        if (device != 0) {
            return true;
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
        device = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null);
        if (device == 0) {
            log.Error("SDL3 audio device open failed (%s)!", fromStringz(SDL_GetError()));
            SDL_QuitSubSystem(SDL_INIT_AUDIO);
            unavailable = true;
            return false;
        }
        SDL_ResumeAudioDevice(device);
        log.Info("Opened audio output device.");
        return true;
    }

    void Close() {
        foreach (stream; streams) {
            stream.Close();
        }
        streams = null;
        if (device == 0) {
            return;
        }
        SDL_CloseAudioDevice(device);
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        device = 0;
    }
}
