/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * audren: audio renderer and audio device services
*/

module Source.Service.Audio;

// Std
import core.time : Duration, MonoTime, dur;
import std.algorithm : min;

// Core
import Source.Audio.AudioRenderer;
import Source.Frontend.HostAudio;
import Source.Memory.Guest;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Kernel.Scheduler;
import Source.Service.Service;

// Types
enum AudioResult : uint {
    InvalidParameter = MakeModuleResult(153, 41),
    InvalidUpdateInfo = MakeModuleResult(153, 42),
}

enum AudioRendererState : uint {
    Started = 0,
    Stopped = 1,
}

enum size_t DeviceNameSize = 0x100;
enum size_t MaxCatchUpFrames = 8;
enum size_t MinQueuedFrames = 2;
enum size_t MaxQueuedFrames = 8;

immutable string[] AudioDeviceNames = ["AudioStereoJackOutput", "AudioBuiltInSpeakerOutput", "AudioTvOutput"];
enum string ActiveAudioDeviceName = "AudioTvOutput";

// State
final class AudioState {
    HostAudio Output;
    GuestMemory Memory;
    Scheduler Threading;

    this(GuestMemory memory, Scheduler threading, HostAudio output) {
        Threading = threading;
        Memory = memory;
        Output = output;
    }
}

// Utils
private bool IsValidParameter(const ref AudioRendererParameter parameter) {
    if (parameter.SampleRate != 32_000 && parameter.SampleRate != 48_000) {
        return false;
    }
    if (parameter.SampleCount == 0 || parameter.SampleCount > 0x400) {
        return false;
    }
    return parameter.MixBufferCount != 0 && parameter.VoiceCount != 0 && parameter.SinkCount != 0;
}

private ulong WorkBufferSize(const ref AudioRendererParameter parameter) {
    const ulong mixes = parameter.SubmixCount + 1;
    ulong size = 0x4000;
    size += cast(ulong) (parameter.MixBufferCount + 6) * parameter.SampleCount * float.sizeof * 2;
    // temp values
    size += cast(ulong) parameter.VoiceCount * 0x400;
    size += mixes * 0x940;
    size += cast(ulong) parameter.SinkCount * 0x200;
    size += cast(ulong) parameter.EffectCount * 0x800;
    size += cast(ulong) parameter.SplitterCount * 0x100 + cast(ulong) parameter.SplitterDestinationCount * 0xE0;
    size += cast(ulong) (parameter.PerformanceFrameCount + 1) * 0x1000;
    size += parameter.ExternalContextSize;
    return AlignUp(size, 0x1000);
}

// Services
final class AudioRendererManagerService : IPCService {
    private AudioState state;

    this(AudioState state) {
        this.state = state;
        Command(0, "OpenAudioRenderer", &OpenAudioRenderer);
        Command(1, "GetWorkBufferSize", &GetWorkBufferSize);
        Command(2, "GetAudioDeviceService", &GetAudioDeviceService);
        Command(4, "GetAudioDeviceServiceWithRevisionInfo", &GetAudioDeviceService);
    }

    override string Name() const {
        return "audren:u";
    }

    private void OpenAudioRenderer(IpcContext context) {
        const AudioRendererParameter parameter = context.Pop!AudioRendererParameter();
        const ulong workBufferSize = context.Pop!ulong();
        if (!IsValidParameter(parameter)) {
            Log.Error("OpenAudioRenderer: got invalid parameters (%dHz, %d samples, %d voices)!", parameter.SampleRate, parameter.SampleCount, parameter.VoiceCount);
            context.Result(AudioResult.InvalidParameter);
            return;
        }
        Log.Info("Opened Audio renderer of %dHz (w/ %d samples, %d voices, %d sinks, %d effects).buffer 0x%X", parameter.SampleRate, parameter.SampleCount, parameter.VoiceCount, parameter.SinkCount, parameter.EffectCount, workBufferSize);
        context.PushInterface(new AudioRendererService(state, parameter));
    }

    private void GetWorkBufferSize(IpcContext context) {
        const AudioRendererParameter parameter = context.Pop!AudioRendererParameter();
        context.Push!ulong(WorkBufferSize(parameter));
    }

    private void GetAudioDeviceService(IpcContext context) {
        context.PushInterface(new AudioDeviceService());
    }
}

final class AudioRendererService : IPCService {
    private AudioState state;
    private AudioRendererParameter parameter;
    private AudioRenderer renderer;
    private KEvent systemEvent;
    private bool started;
    private uint renderingTimeLimit = 100;
    private Duration frameDuration;
    private MonoTime lastRender;

    this(AudioState state, AudioRendererParameter parameter) {
        this.state = state;
        this.parameter = parameter;
        renderer = new AudioRenderer(state.Memory, parameter);
        frameDuration = dur!"usecs"(cast(long) parameter.SampleCount * 1_000_000 / parameter.SampleRate);
        systemEvent = new KEvent("AudioRendererSystem", true);
        state.Threading.AddPeriodic(systemEvent, frameDuration);
        Command(0, "GetSampleRate", (IpcContext c) => c.Push!uint(this.parameter.SampleRate));
        Command(1, "GetSampleCount", (IpcContext c) => c.Push!uint(this.parameter.SampleCount));
        Command(2, "GetMixBufferCount", (IpcContext c) => c.Push!uint(this.parameter.MixBufferCount));
        Command(3, "GetState", (IpcContext c) => c.Push!uint(started ? AudioRendererState.Started : AudioRendererState.Stopped));
        Command(4, "RequestUpdate", &RequestUpdate);
        Command(5, "Start", &Start);
        Command(6, "Stop", &Stop);
        Command(7, "QuerySystemEvent", (IpcContext c) => c.PushCopyHandle(systemEvent));
        Command(8, "SetRenderingTimeLimit", (IpcContext c) { renderingTimeLimit = c.Pop!uint(); });
        Command(9, "GetRenderingTimeLimit", (IpcContext c) => c.Push!uint(renderingTimeLimit));
        Command(10, "RequestUpdateAuto", &RequestUpdate);
        Stub(11, "ExecuteAudioRendererRendering");
    }

    override string Name() const {
        return "audren::IAudioRenderer";
    }

    private void Start(IpcContext context) {
        started = true;
        lastRender = MonoTime.currTime;
        state.Output.Open(parameter.SampleRate, OutputChannels);
    }

    private void Stop(IpcContext context) {
        started = false;
    }

    private void RequestUpdate(IpcContext context) {
        ubyte[] output;
        if (!renderer.Update(context.ReadInput(0), output)) {
            context.Result(AudioResult.InvalidUpdateInfo);
            return;
        }
        context.WriteOutput(0, output[0 .. min(output.length, context.OutputSize(0))]);
        if (started) {
            Render();
        }
    }

    private void Render() {
        const MonoTime now = MonoTime.currTime;
        size_t due = cast(size_t) ((now - lastRender) / frameDuration);
        if (due > MaxCatchUpFrames) {
            due = MaxCatchUpFrames;
            lastRender = now;
        } else {
            lastRender += frameDuration * due;
        }

        const size_t frameBytes = parameter.SampleCount * OutputChannels * short.sizeof;
        const size_t queued = state.Output.QueuedBytes;
        if (state.Output.IsOpen && queued < frameBytes * MinQueuedFrames) {
            due++;
        }
        foreach (_; 0 .. due) {
            const short[] samples = renderer.Render();
            if (state.Output.QueuedBytes < frameBytes * MaxQueuedFrames) {
                state.Output.Queue(samples);
            }
        }
    }
}

final class AudioDeviceService : IPCService {
    private KEvent systemEvent;
    private KEvent inputEvent;
    private KEvent outputEvent;
    private float volume = 1.0f;

    this() {
        systemEvent = new KEvent("AudioDeviceSystem", true);
        inputEvent = new KEvent("AudioDeviceInput");
        outputEvent = new KEvent("AudioDeviceOutput");
        Command(0, "ListAudioDeviceName", &ListAudioDeviceName);
        Command(1, "SetAudioDeviceOutputVolume", &SetAudioDeviceOutputVolume);
        Command(2, "GetAudioDeviceOutputVolume", (IpcContext c) => c.Push!float(volume));
        Command(3, "GetActiveAudioDeviceName", &GetActiveAudioDeviceName);
        Command(4, "QueryAudioDeviceSystemEvent", (IpcContext c) => c.PushCopyHandle(systemEvent));
        Command(5, "GetActiveChannelCount", (IpcContext c) => c.Push!uint(OutputChannels));
        Command(6, "ListAudioDeviceNameAuto", &ListAudioDeviceName);
        Command(7, "SetAudioDeviceOutputVolumeAuto", &SetAudioDeviceOutputVolume);
        Command(8, "GetAudioDeviceOutputVolumeAuto", (IpcContext c) => c.Push!float(volume));
        Command(10, "GetActiveAudioDeviceNameAuto", &GetActiveAudioDeviceName);
        Command(11, "QueryAudioDeviceInputEvent", (IpcContext c) => c.PushCopyHandle(inputEvent));
        Command(12, "QueryAudioDeviceOutputEvent", (IpcContext c) => c.PushCopyHandle(outputEvent));
    }

    override string Name() const {
        return "audren::IAudioDevice";
    }

    private void ListAudioDeviceName(IpcContext context) {
        const size_t count = min(AudioDeviceNames.length, context.OutputSize(0) / DeviceNameSize);
        ubyte[] names = new ubyte[count * DeviceNameSize];
        foreach (i; 0 .. count) {
            names[i * DeviceNameSize .. i * DeviceNameSize + AudioDeviceNames[i].length] = cast(const(ubyte)[]) AudioDeviceNames[i];
        }
        context.WriteOutput(0, names);
        context.Push!uint(cast(uint) count);
    }

    private void SetAudioDeviceOutputVolume(IpcContext context) {
        volume = context.Pop!float();
    }

    private void GetActiveAudioDeviceName(IpcContext context) {
        ubyte[] name = new ubyte[min(DeviceNameSize, context.OutputSize(0))];
        const size_t length = min(ActiveAudioDeviceName.length, name.length);
        name[0 .. length] = cast(const(ubyte)[]) ActiveAudioDeviceName[0 .. length];
        context.WriteOutput(0, name);
    }
}
