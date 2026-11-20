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
import core.time : dur;
import std.algorithm : min;

// Core
import Source.Frontend.HostAudio;
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

enum MemPoolState : uint {
    Invalid = 0,
    New = 1,
    RequestDetach = 2,
    Detached = 3,
    RequestAttach = 4,
    Attached = 5,
    Released = 6,
}

enum size_t MemPoolInSize = 0x20;
enum size_t VoiceInSize = 0x170;
enum size_t EffectInSize = 0xC0;
enum size_t SinkInSize = 0x140;
enum size_t MemPoolOutSize = 0x10;
enum size_t VoiceOutSize = 0x10;
enum size_t EffectOutSize = 0x10;
enum size_t SinkOutSize = 0x20;
enum size_t PerformanceOutSize = 0x10;
enum size_t BehaviorOutSize = 0xB0;
enum size_t DeviceNameSize = 0x100;
enum uint OutputChannels = 2;

immutable string[] AudioDeviceNames = ["AudioStereoJackOutput", "AudioBuiltInSpeakerOutput", "AudioTvOutput"];
enum string ActiveAudioDeviceName = "AudioTvOutput";

struct AudioRendererParameter {
    uint SampleRate;
    uint SampleCount;
    uint MixBufferCount;
    uint SubmixCount;
    uint VoiceCount;
    uint SinkCount;
    uint EffectCount;
    uint PerformanceFrameCount;
    ubyte VoiceDropEnable;
    ubyte[3] Padding;
    uint SplitterCount;
    uint SplitterDestinationCount;
    uint ExternalContextSize;
    uint Revision;
}

struct UpdateDataHeader {
    uint Revision;
    uint BehaviorSize;
    uint MemPoolsSize;
    uint VoicesSize;
    uint VoiceResourcesSize;
    uint EffectsSize;
    uint MixesSize;
    uint SinksSize;
    uint PerformanceSize;
    uint SplitterSize;
    uint RenderInfoSize;
    uint[4] Padding;
    uint TotalSize;
}

static assert(UpdateDataHeader.sizeof == 0x40);

// State
final class AudioState {
    HostAudio Output;
    Scheduler Threading;

    this(HostAudio output, Scheduler threading) {
        Output = output;
        Threading = threading;
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

private uint NextMemPoolState(uint state) {
    switch (state) {
        case MemPoolState.RequestAttach: return MemPoolState.Attached;
        case MemPoolState.RequestDetach: return MemPoolState.Detached;
        default: return state;
    }
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
    private KEvent systemEvent;
    private bool started;
    private uint renderingTimeLimit = 100;

    this(AudioState state, AudioRendererParameter parameter) {
        this.state = state;
        this.parameter = parameter;
        systemEvent = new KEvent("AudioRendererSystem", true);
        state.Threading.AddPeriodic(systemEvent, dur!"usecs"(cast(long) parameter.SampleCount * 1_000_000 / parameter.SampleRate));
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
        state.Output.Open(parameter.SampleRate, OutputChannels);
    }

    private void Stop(IpcContext context) {
        started = false;
    }

    private void RequestUpdate(IpcContext context) {
        const ubyte[] input = context.ReadInput(0);
        if (input.length < UpdateDataHeader.sizeof) {
            context.Result(AudioResult.InvalidUpdateInfo);
            return;
        }
        const UpdateDataHeader inHeader = ReadValue!UpdateDataHeader(input, 0);
        const size_t memPoolCount = inHeader.MemPoolsSize / MemPoolInSize;
        const size_t voiceCount = inHeader.VoicesSize / VoiceInSize;
        const size_t effectCount = inHeader.EffectsSize / EffectInSize;
        const size_t sinkCount = inHeader.SinksSize / SinkInSize;

        // todo: actually mix voices into sdl
        UpdateDataHeader outHeader;
        outHeader.Revision = inHeader.Revision;
        outHeader.MemPoolsSize = cast(uint) (memPoolCount * MemPoolOutSize);
        outHeader.VoicesSize = cast(uint) (voiceCount * VoiceOutSize);
        outHeader.EffectsSize = cast(uint) (effectCount * EffectOutSize);
        outHeader.SinksSize = cast(uint) (sinkCount * SinkOutSize);
        outHeader.PerformanceSize = cast(uint) PerformanceOutSize;
        outHeader.BehaviorSize = cast(uint) BehaviorOutSize;
        outHeader.TotalSize = cast(uint) (UpdateDataHeader.sizeof + outHeader.MemPoolsSize + outHeader.VoicesSize + outHeader.EffectsSize + outHeader.SinksSize + outHeader.PerformanceSize + outHeader.BehaviorSize);

        ubyte[] output = new ubyte[outHeader.TotalSize];
        *cast(UpdateDataHeader*) output.ptr = outHeader;

        const size_t memPoolsIn = UpdateDataHeader.sizeof + inHeader.BehaviorSize;
        foreach (i; 0 .. memPoolCount) {
            const uint poolState = ReadValue!uint(input, memPoolsIn + i * MemPoolInSize + 0x10);
            *cast(uint*) (output.ptr + UpdateDataHeader.sizeof + i * MemPoolOutSize) = NextMemPoolState(poolState);
        }

        context.WriteOutput(0, output[0 .. min(output.length, context.OutputSize(0))]);
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
