/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Audio renderer mixing
*/

module Source.Audio.AudioRenderer;

// Std
import std.algorithm : min;

// Core
import Source.Memory.Guest;
import Source.Service.Service : ReadValue, Store;

// Types
enum MemPoolState : uint {
    Invalid = 0,
    New = 1,
    RequestDetach = 2,
    Detached = 3,
    RequestAttach = 4,
    Attached = 5,
    Released = 6,
}

enum VoicePlayState : ubyte {
    Started = 0,
    Stopped = 1,
    Paused = 2,
}

enum SampleFormat : ubyte {
    Invalid = 0,
    Int8 = 1,
    Int16 = 2,
    Int24 = 3,
    Int32 = 4,
    Float = 5,
    Adpcm = 6,
}

enum size_t MemPoolInSize = 0x20;
enum size_t ChannelInSize = 0x70;
enum size_t VoiceInSize = 0x170;
enum size_t EffectInSize = 0xC0;
enum size_t MixInSize = 0x930;
enum size_t SinkInSize = 0x140;
enum size_t WaveBufferInSize = 0x38;
enum size_t MemPoolOutSize = 0x10;
enum size_t VoiceOutSize = 0x10;
enum size_t EffectOutSize = 0x10;
enum size_t SinkOutSize = 0x20;
enum size_t PerformanceOutSize = 0x10;
enum size_t BehaviorOutSize = 0xB0;
enum size_t MaxMixBuffers = 24;
enum size_t MaxVoiceChannels = 6;
enum size_t WaveBuffersPerVoice = 4;
enum uint FinalMixId = 0;
enum uint OutputChannels = 2;

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

struct WaveBuffer {
    ulong Address;
    ulong Size;
    int StartSample;
    int EndSample;
    bool Looping;
    bool Valid;
}

struct VoiceState {
    bool InUse;
    VoicePlayState PlayState = VoicePlayState.Stopped;
    SampleFormat Format;
    uint SampleRate;
    uint ChannelCount;
    float Pitch;
    float Volume;
    uint DestinationMix;
    uint[MaxVoiceChannels] ChannelIds;
    WaveBuffer[WaveBuffersPerVoice] Buffers;
    size_t Current;
    double Offset = 0;
    ulong PlayedSamples;
    uint ConsumedBuffers;
    float[] Decoded;
    ptrdiff_t DecodedSlot = -1;
}

struct ChannelResource {
    bool InUse;
    float[MaxMixBuffers] Mix;
}

// Utils
private uint NextMemPoolState(uint state) {
    switch (state) {
        case MemPoolState.RequestAttach: return MemPoolState.Attached;
        case MemPoolState.RequestDetach: return MemPoolState.Detached;
        default: return state;
    }
}

// Class
final class AudioRenderer {
    AudioRendererParameter Parameter;

    private GuestMemory memory;
    private VoiceState[] voices;
    private ChannelResource[uint] channels;
    private float finalVolume = 1.0f;
    private ubyte[OutputChannels] outputInputs = [0, 1];
    private float[][] mixBuffers;

    this(GuestMemory memory, AudioRendererParameter parameter) {
        this.memory = memory;
        Parameter = parameter;
        voices = new VoiceState[parameter.VoiceCount];
        mixBuffers = new float[][min(parameter.MixBufferCount, MaxMixBuffers)];
        foreach (ref buffer; mixBuffers) {
            buffer = new float[parameter.SampleCount];
        }
    }

    // Update
    bool Update(const(ubyte)[] input, out ubyte[] output) {
        if (input.length < UpdateDataHeader.sizeof) {
            return false;
        }
        const UpdateDataHeader header = ReadValue!UpdateDataHeader(input, 0);
        const size_t memPoolsAt = UpdateDataHeader.sizeof + header.BehaviorSize;
        const size_t channelsAt = memPoolsAt + header.MemPoolsSize;
        const size_t voicesAt = channelsAt + header.VoiceResourcesSize;
        const size_t effectsAt = voicesAt + header.VoicesSize;
        const size_t mixesAt = effectsAt + header.EffectsSize + header.SplitterSize;
        const size_t sinksAt = mixesAt + header.MixesSize;

        const size_t memPoolCount = header.MemPoolsSize / MemPoolInSize;
        const size_t voiceCount = header.VoicesSize / VoiceInSize;
        const size_t effectCount = header.EffectsSize / EffectInSize;
        const size_t sinkCount = header.SinksSize / SinkInSize;

        foreach (i; 0 .. header.VoiceResourcesSize / ChannelInSize) {
            UpdateChannel(input, channelsAt + i * ChannelInSize);
        }
        foreach (i; 0 .. voiceCount) {
            UpdateVoice(input, voicesAt + i * VoiceInSize, i);
        }
        foreach (i; 0 .. header.MixesSize / MixInSize) {
            UpdateMix(input, mixesAt + i * MixInSize);
        }
        foreach (i; 0 .. sinkCount) {
            UpdateSink(input, sinksAt + i * SinkInSize);
        }

        UpdateDataHeader outHeader;
        outHeader.Revision = header.Revision;
        outHeader.MemPoolsSize = cast(uint) (memPoolCount * MemPoolOutSize);
        outHeader.VoicesSize = cast(uint) (voiceCount * VoiceOutSize);
        outHeader.EffectsSize = cast(uint) (effectCount * EffectOutSize);
        outHeader.SinksSize = cast(uint) (sinkCount * SinkOutSize);
        outHeader.PerformanceSize = cast(uint) PerformanceOutSize;
        outHeader.BehaviorSize = cast(uint) BehaviorOutSize;
        outHeader.TotalSize = cast(uint) (UpdateDataHeader.sizeof + outHeader.MemPoolsSize + outHeader.VoicesSize + outHeader.EffectsSize + outHeader.SinksSize + outHeader.PerformanceSize + outHeader.BehaviorSize);

        output = new ubyte[outHeader.TotalSize];
        Store(output, 0, outHeader);
        size_t at = UpdateDataHeader.sizeof;
        foreach (i; 0 .. memPoolCount) {
            const uint poolState = ReadValue!uint(input, memPoolsAt + i * MemPoolInSize + 0x10);
            Store!uint(output, at + i * MemPoolOutSize, NextMemPoolState(poolState));
        }
        at += outHeader.MemPoolsSize;
        foreach (i; 0 .. voiceCount) {
            const uint id = ReadValue!uint(input, voicesAt + i * VoiceInSize);
            if (id < voices.length) {
                Store!ulong(output, at + i * VoiceOutSize, voices[id].PlayedSamples);
                Store!uint(output, at + i * VoiceOutSize + 8, voices[id].ConsumedBuffers);
            }
        }
        return true;
    }

    private void UpdateChannel(const(ubyte)[] input, size_t at) {
        const uint id = ReadValue!uint(input, at);
        ChannelResource resource;
        resource.Mix = ReadValue!(float[MaxMixBuffers])(input, at + 0x4);
        resource.InUse = ReadValue!ubyte(input, at + 0x64) != 0;
        channels[id] = resource;
    }

    private void UpdateVoice(const(ubyte)[] input, size_t at, size_t index) {
        const uint id = ReadValue!uint(input, at);
        if (id >= voices.length) {
            return;
        }
        if (ReadValue!ubyte(input, at + 0x9) == 0) {
            if (id == index) {
                voices[id].InUse = false;
            }
            return;
        }
        VoiceState* voice = &voices[id];
        if (ReadValue!ubyte(input, at + 0x8) != 0) {
            *voice = VoiceState.init;
            voice.Current = ReadValue!short(input, at + 0x40) & (WaveBuffersPerVoice - 1);
        }
        voice.InUse = ReadValue!ubyte(input, at + 0x9) != 0;
        voice.Format = cast(SampleFormat) ReadValue!ubyte(input, at + 0xB);
        voice.SampleRate = ReadValue!uint(input, at + 0xC);
        voice.ChannelCount = min(ReadValue!uint(input, at + 0x18), MaxVoiceChannels);
        voice.Pitch = ReadValue!float(input, at + 0x1C);
        voice.Volume = ReadValue!float(input, at + 0x20);
        voice.DestinationMix = ReadValue!uint(input, at + 0x58);
        voice.ChannelIds = ReadValue!(uint[MaxVoiceChannels])(input, at + 0x140);

        const VoicePlayState playState = cast(VoicePlayState) ReadValue!ubyte(input, at + 0xA);
        if (playState == VoicePlayState.Stopped && voice.PlayState != VoicePlayState.Stopped) {
            Flush(*voice);
        }
        voice.PlayState = playState;

        foreach (i; 0 .. WaveBuffersPerVoice) {
            const size_t bufferAt = at + 0x60 + i * WaveBufferInSize;
            const bool sentToServer = ReadValue!ubyte(input, bufferAt + 0x1A) != 0;
            if (sentToServer || voice.Buffers[i].Valid) {
                continue;
            }
            WaveBuffer buffer;
            buffer.Address = ReadValue!ulong(input, bufferAt);
            buffer.Size = ReadValue!ulong(input, bufferAt + 0x8);
            buffer.StartSample = ReadValue!int(input, bufferAt + 0x10);
            buffer.EndSample = ReadValue!int(input, bufferAt + 0x14);
            buffer.Looping = ReadValue!ubyte(input, bufferAt + 0x18) != 0;
            buffer.Valid = buffer.Address != 0 && buffer.EndSample > buffer.StartSample;
            voice.Buffers[i] = buffer;
        }
    }

    private void UpdateMix(const(ubyte)[] input, size_t at) {
        if (ReadValue!ubyte(input, at + 0xC) == 0 || ReadValue!uint(input, at + 0x10) != FinalMixId) {
            return;
        }
        finalVolume = ReadValue!float(input, at);
    }

    private void UpdateSink(const(ubyte)[] input, size_t at) {
        if (ReadValue!ubyte(input, at) != 1 || ReadValue!ubyte(input, at + 0x1) == 0) {
            return;
        }
        const uint inputCount = ReadValue!uint(input, at + 0x124);
        if (inputCount == 0) {
            return;
        }
        const ubyte[6] inputs = ReadValue!(ubyte[6])(input, at + 0x128);
        outputInputs[0] = inputs[0];
        outputInputs[1] = inputCount > 1 ? inputs[1] : inputs[0];
    }

    private void Flush(ref VoiceState voice) {
        foreach (_; 0 .. WaveBuffersPerVoice) {
            if (!voice.Buffers[voice.Current].Valid) {
                break;
            }
            Consume(voice);
        }
        voice.Offset = 0;
    }

    private void Consume(ref VoiceState voice) {
        voice.Buffers[voice.Current].Valid = false;
        voice.ConsumedBuffers++;
        voice.Current = (voice.Current + 1) % WaveBuffersPerVoice;
        voice.DecodedSlot = -1;
    }

    // Render
    short[] Render() {
        foreach (buffer; mixBuffers) {
            buffer[] = 0;
        }
        foreach (ref voice; voices) {
            if (voice.InUse && voice.PlayState == VoicePlayState.Started && voice.ChannelCount != 0) {
                MixVoice(voice);
            }
        }

        short[] samples = new short[Parameter.SampleCount * OutputChannels];
        foreach (s; 0 .. Parameter.SampleCount) {
            foreach (c; 0 .. OutputChannels) {
                const size_t source = outputInputs[c];
                const float value = source < mixBuffers.length ? mixBuffers[source][s] * finalVolume : 0;
                samples[s * OutputChannels + c] = cast(short) (value > short.max ? short.max : (value < short.min ? short.min : value));
            }
        }
        return samples;
    }

    private void MixVoice(ref VoiceState voice) {
        const double step = cast(double) voice.SampleRate * (voice.Pitch > 0 ? voice.Pitch : 1.0f) / Parameter.SampleRate;
        const size_t channelCount = voice.ChannelCount;
        foreach (s; 0 .. Parameter.SampleCount) {
            if (!Prepare(voice)) {
                return;
            }
            // todo: need to handle submixes to work alongside the main one
            const size_t frames = voice.Decoded.length / channelCount;
            const size_t index = cast(size_t) voice.Offset;
            const size_t next = min(index + 1, frames - 1);
            const float fraction = cast(float) (voice.Offset - index);
            foreach (c; 0 .. channelCount) {
                ChannelResource* resource = voice.ChannelIds[c] in channels;
                if (resource is null || !resource.InUse) {
                    continue;
                }
                const float a = voice.Decoded[index * channelCount + c];
                const float b = voice.Decoded[next * channelCount + c];
                const float sample = (a + (b - a) * fraction) * voice.Volume;
                foreach (m, buffer; mixBuffers) {
                    if (resource.Mix[m] != 0) {
                        buffer[s] += sample * resource.Mix[m];
                    }
                }
            }
            const ulong before = cast(ulong) voice.Offset;
            voice.Offset += step;
            voice.PlayedSamples += cast(ulong) voice.Offset - before;
        }
    }

    private bool Prepare(ref VoiceState voice) {
        foreach (_; 0 .. WaveBuffersPerVoice + 1) {
            WaveBuffer* buffer = &voice.Buffers[voice.Current];
            if (!buffer.Valid) {
                return false;
            }
            if (voice.DecodedSlot != voice.Current) {
                voice.Decoded = Decode(*buffer, voice.Format, voice.ChannelCount);
                voice.DecodedSlot = voice.Current;
            }
            const size_t frames = voice.Decoded.length / voice.ChannelCount;
            if (frames != 0 && voice.Offset < frames) {
                return true;
            }
            voice.Offset = frames == 0 ? 0 : voice.Offset - frames;
            if (buffer.Looping && frames != 0) {
                continue;
            }
            Consume(voice);
        }
        return false;
    }

    private float[] Decode(const ref WaveBuffer buffer, SampleFormat format, uint channelCount) {
        const size_t frames = buffer.EndSample - buffer.StartSample;
        float[] decoded = new float[frames * channelCount];
        switch (format) {
            case SampleFormat.Int16: {
                ubyte[] raw = new ubyte[decoded.length * short.sizeof];
                const ulong address = buffer.Address + cast(ulong) buffer.StartSample * channelCount * short.sizeof;
                if (!memory.IsMapped(address, raw.length)) {
                    break;
                }
                memory.ReadBytes(address, raw);
                const short[] pcm = cast(const(short)[]) raw;
                foreach (i, value; pcm) {
                    decoded[i] = value;
                }
                break;
            }
            case SampleFormat.Float: {
                ubyte[] raw = new ubyte[decoded.length * float.sizeof];
                const ulong address = buffer.Address + cast(ulong) buffer.StartSample * channelCount * float.sizeof;
                if (!memory.IsMapped(address, raw.length)) {
                    break;
                }
                memory.ReadBytes(address, raw);
                const float[] pcm = cast(const(float)[]) raw;
                foreach (i, value; pcm) {
                    decoded[i] = value * short.max;
                }
                break;
            }
            default:
                // todo: handle other audio formats
                // although we still will consider them "played"
                decoded[] = 0;
                break;
        }
        return decoded;
    }
}
