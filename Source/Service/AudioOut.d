/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * audout: audio output services
*/

module Source.Service.AudioOut;

// Std
import core.time : Duration, MonoTime, dur;
import std.algorithm : min;

// Core
import Source.Frontend.HostAudio;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Service.Audio;
import Source.Service.Service;

// Types
enum AudioOutState : uint {
    Started = 0,
    Stopped = 1,
}

enum uint AudioOutSampleRate = 48_000;
enum uint AudioOutChannels = 2;
enum uint PcmFormatInt16 = 2;
enum string DefaultAudioOutName = "DeviceOut";
enum Duration AudioOutPollInterval = dur!"msecs"(5);

struct AudioOutBufferInfo {
    ulong Next;
    ulong Samples;
    ulong Capacity;
    ulong Size;
    ulong Offset;
}

struct QueuedAudioOutBuffer {
    ulong Tag;
    short[] Samples;
    ulong EndPosition;
    bool Pushed;
}

// Services
final class AudioOutManagerService : IPCService {
    private AudioState state;

    this(AudioState state) {
        this.state = state;
        Command(0, "ListAudioOuts", &ListAudioOuts);
        Command(1, "OpenAudioOut", &OpenAudioOut);
        Command(2, "ListAudioOutsAuto", &ListAudioOuts);
        Command(3, "OpenAudioOutAuto", &OpenAudioOut);
    }

    override string Name() const {
        return "audout:u";
    }

    private void ListAudioOuts(IpcContext context) {
        if (context.OutputSize(0) < DefaultAudioOutName.length) {
            context.Push!uint(0);
            return;
        }
        context.WriteName(DefaultAudioOutName, DeviceNameSize);
        context.Push!uint(1);
    }

    private void OpenAudioOut(IpcContext context) {
        uint sampleRate = context.Pop!uint();
        uint channels = context.Pop!ushort();
        if (sampleRate == 0) {
            sampleRate = AudioOutSampleRate;
        }
        if (channels == 0) {
            channels = AudioOutChannels;
        }
        if (sampleRate != AudioOutSampleRate || (channels != 1 && channels != 2 && channels != 6)) {
            Log.Error("OpenAudioOut: unsupported %dHz with %d channels!", sampleRate, channels);
            context.Result(AudioResult.InvalidParameter);
            return;
        }
        Log.Info("Opened audio out %dHz, %d channels.", sampleRate, channels);
        context.WriteName(DefaultAudioOutName, DeviceNameSize);
        context.Push!uint(sampleRate);
        context.Push!uint(channels);
        context.Push!uint(PcmFormatInt16);
        context.Push!uint(AudioOutState.Stopped);
        context.PushInterface(new AudioOutService(state, sampleRate, channels));
    }
}

final class AudioOutService : IPCService {
    private AudioState state;
    private uint sampleRate;
    private uint channels;
    private bool started;
    private float volume = 1.0f;
    private KEvent bufferEvent;
    private HostAudioStream output;
    private QueuedAudioOutBuffer[] queued;
    private ulong[] released;
    private ulong pushedBytes;
    private ulong playhead;
    private ulong playedSamples;
    private MonoTime lastPoll;

    this(AudioState state, uint sampleRate, uint channels) {
        this.state = state;
        this.sampleRate = sampleRate;
        this.channels = channels;
        bufferEvent = new KEvent("AudioOutBuffer");
        state.Threading.AddPoller(&Poll, AudioOutPollInterval);
        Command(0, "GetAudioOutState", (IpcContext c) => c.Push!uint(started ? AudioOutState.Started : AudioOutState.Stopped));
        Command(1, "StartAudioOut", &StartAudioOut);
        Command(2, "StopAudioOut", &StopAudioOut);
        Command(3, "AppendAudioOutBuffer", &AppendAudioOutBuffer);
        Command(4, "RegisterBufferEvent", (IpcContext c) => c.PushCopyHandle(bufferEvent));
        Command(5, "GetReleasedAudioOutBuffers", &GetReleasedAudioOutBuffers);
        Command(6, "ContainsAudioOutBuffer", &ContainsAudioOutBuffer);
        Command(7, "AppendAudioOutBufferAuto", &AppendAudioOutBuffer);
        Command(8, "GetReleasedAudioOutBuffersAuto", &GetReleasedAudioOutBuffers);
        Command(9, "GetAudioOutBufferCount", (IpcContext c) => c.Push!uint(cast(uint) queued.length));
        Command(10, "GetAudioOutPlayedSampleCount", (IpcContext c) => c.Push!ulong(playedSamples));
        Command(11, "FlushAudioOutBuffers", &FlushAudioOutBuffers);
        Command(12, "SetAudioOutVolume", (IpcContext c) { volume = c.Pop!float(); });
        Command(13, "GetAudioOutVolume", (IpcContext c) => c.Push!float(volume));
    }

    override string Name() const {
        return "audout::IAudioOut";
    }

    private void StartAudioOut(IpcContext context) {
        if (started) {
            return;
        }
        started = true;
        lastPoll = MonoTime.currTime;
        if (output is null) {
            output = state.Output.OpenStream(sampleRate, channels);
        }
        PushPending();
    }

    private void StopAudioOut(IpcContext context) {
        started = false;
    }

    private void AppendAudioOutBuffer(IpcContext context) {
        const ulong tag = context.Pop!ulong();
        const AudioOutBufferInfo info = ReadValue!AudioOutBufferInfo(context.ReadInput(0), 0);
        QueuedAudioOutBuffer buffer;
        buffer.Tag = tag;
        buffer.Samples = new short[cast(size_t) (info.Size / short.sizeof)];
        const ulong address = info.Samples + info.Offset;
        ubyte[] raw = cast(ubyte[]) buffer.Samples;
        if (raw.length != 0 && state.Memory.IsMapped(address, raw.length)) {
            state.Memory.ReadBytes(address, raw);
        }
        queued ~= buffer;
        if (started) {
            PushPending();
        }
    }

    private void GetReleasedAudioOutBuffers(IpcContext context) {
        Poll();
        const size_t count = min(released.length, context.OutputSize(0) / ulong.sizeof);
        context.WriteOutput(0, cast(const(ubyte)[]) released[0 .. count]);
        released = released[count .. $].dup;
        if (released.length == 0) {
            bufferEvent.Clear();
        }
        context.Push!uint(cast(uint) count);
    }

    private void ContainsAudioOutBuffer(IpcContext context) {
        const ulong tag = context.Pop!ulong();
        bool found = false;
        foreach (ref buffer; queued) {
            if (buffer.Tag == tag) {
                found = true;
                break;
            }
        }
        context.Push!ubyte(found ? 1 : 0);
    }

    private void FlushAudioOutBuffers(IpcContext context) {
        const bool flushed = queued.length != 0;
        foreach (ref buffer; queued) {
            released ~= buffer.Tag;
        }
        queued = null;
        playhead = pushedBytes;
        if (output !is null) {
            output.Clear();
        }
        if (flushed) {
            bufferEvent.Signal();
        }
        context.Push!ubyte(flushed ? 1 : 0);
    }

    private void PushPending() {
        foreach (ref buffer; queued) {
            if (buffer.Pushed) {
                continue;
            }
            if (volume != 1.0f) {
                foreach (ref sample; buffer.Samples) {
                    const float scaled = sample * volume;
                    sample = cast(short) (scaled > short.max ? short.max : (scaled < short.min ? short.min : scaled));
                }
            }
            if (output !is null) {
                output.Queue(buffer.Samples);
            }
            pushedBytes += buffer.Samples.length * short.sizeof;
            buffer.EndPosition = pushedBytes;
            buffer.Pushed = true;
        }
    }

    private void Poll() {
        if (!started) {
            return;
        }
        const MonoTime now = MonoTime.currTime;
        if (output !is null) {
            const size_t waiting = output.QueuedBytes;
            playhead = pushedBytes > waiting ? pushedBytes - waiting : 0;
        } else {
            const ulong bytesPerSecond = cast(ulong) sampleRate * channels * short.sizeof;
            playhead = min(pushedBytes, playhead + (now - lastPoll).total!"usecs" * bytesPerSecond / 1_000_000);
        }
        lastPoll = now;

        size_t done = 0;
        while (done < queued.length && queued[done].Pushed && queued[done].EndPosition <= playhead) {
            released ~= queued[done].Tag;
            playedSamples += queued[done].Samples.length / channels;
            done++;
        }
        if (done != 0) {
            queued = queued[done .. $].dup;
            bufferEvent.Signal();
        }
    }
}
