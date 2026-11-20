/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell texture and sampler descriptors
*/

module Source.Gpu.Texture;

// Std
import std.format : format;

// Types
enum uint DescriptorSize = 0x20;

enum TextureFormat : uint {
    R32G32B32A32 = 0x01,
    R32G32B32 = 0x02,
    R16G16B16A16 = 0x03,
    R32G32 = 0x04,
    A8R8G8B8 = 0x08,
    A2B10G10R10 = 0x09,
    R16G16 = 0x0C,
    R32 = 0x0F,
    A4B4G4R4 = 0x12,
    A1B5G5R5 = 0x14,
    B5G6R5 = 0x15,
    BC7 = 0x17,
    G8R8 = 0x18,
    R16 = 0x1B,
    R8 = 0x1D,
    B10G11R11 = 0x21,
    BC1 = 0x24,
    BC2 = 0x25,
    BC3 = 0x26,
    BC4 = 0x27,
    BC5 = 0x28,
    Z24S8 = 0x29,
    ZF32 = 0x2F,
}

enum TextureComponent : uint {
    Snorm = 1,
    Unorm = 2,
    Sint = 3,
    Uint = 4,
    Float = 7,
}

enum TextureSwizzle : uint {
    Zero = 0,
    R = 2,
    G = 3,
    B = 4,
    A = 5,
    OneInt = 6,
    OneFloat = 7,
}

enum TextureHeaderVersion : uint {
    Buffer1D = 0,
    PitchColorKey = 1,
    Pitch = 2,
    BlockLinear = 3,
    BlockLinearColorKey = 4,
}

enum TextureType : uint {
    Texture1D = 0,
    Texture2D = 1,
    Texture3D = 2,
    Cube = 3,
    Texture1DArray = 4,
    Texture2DArray = 5,
    Buffer1D = 6,
    Texture2DNoMipmap = 7,
    CubeArray = 8,
}

enum WrapMode : uint {
    Wrap = 0,
    Mirror = 1,
    ClampToEdge = 2,
    Border = 3,
    Clamp = 4,
    MirrorOnceClampToEdge = 5,
    MirrorOnceBorder = 6,
    MirrorOnceClamp = 7,
}

enum TextureFilter : uint {
    Nearest = 1,
    Linear = 2,
}

enum MipmapFilter : uint {
    None = 1,
    Nearest = 2,
    Linear = 3,
}

// Handles have a TIC index in <20 bits and a TSC index >12 
// only if TSC is unlinked..
struct TextureHandle {
    uint Raw;

    uint HeaderIndex() const { return Raw & 0xF_FFFF; }
    uint SamplerIndex() const { return Raw >> 20; }
}

struct TextureHeader {
    uint[8] Words;

    uint Format() const { return Words[0] & 0x7F; }
    TextureComponent Component(uint index) const { return cast(TextureComponent) ((Words[0] >> (7 + index * 3)) & 7); }
    TextureSwizzle Swizzle(uint index) const { return cast(TextureSwizzle) ((Words[0] >> (19 + index * 3)) & 7); }
    ulong Address() const { return (cast(ulong) (Words[2] & 0xFFFF) << 32) | Words[1]; }
    TextureHeaderVersion Version() const { return cast(TextureHeaderVersion) ((Words[2] >> 21) & 7); }
    bool BlockLinear() const { return Version == TextureHeaderVersion.BlockLinear || Version == TextureHeaderVersion.BlockLinearColorKey; }
    uint BlockHeightLog2() const { return (Words[3] >> 3) & 7; }
    uint BlockDepthLog2() const { return (Words[3] >> 6) & 7; }
    uint Pitch() const { return (Words[3] & 0xFFFF) << 5; }
    uint MaxMipLevel() const { return (Words[3] >> 28) & 0xF; }
    uint Width() const { return (Words[4] & 0xFFFF) + 1; }
    bool Srgb() const { return ((Words[4] >> 22) & 1) != 0; }
    TextureType Type() const { return cast(TextureType) ((Words[4] >> 23) & 0xF); }
    uint Height() const { return (Words[5] & 0xFFFF) + 1; }
    uint Depth() const { return ((Words[5] >> 16) & 0x3FFF) + 1; }
    bool NormalizedCoords() const { return ((Words[5] >> 31) & 1) != 0; }

    string DebugDesc() const {
        static immutable string[8] swizzleNames = ["0", "?", "R", "G", "B", "A", "1", "1"];
        const string layout = BlockLinear ? format("block-linear (block height %d)", 1 << BlockHeightLog2) : format("pitch %d", Pitch);
        return format("%s %dx%dx%d format %s (%s/%s/%s/%s) swizzle %s%s%s%s at gpu 0x%X, %s, mips %d%s",
            Type, Width, Height, Depth, NameOf(Format), Component(0), Component(1), Component(2), Component(3),
            swizzleNames[Swizzle(0)], swizzleNames[Swizzle(1)], swizzleNames[Swizzle(2)], swizzleNames[Swizzle(3)],
            Address, layout, MaxMipLevel + 1, Srgb ? ", sRGB" : "");
    }

    private static string NameOf(uint format) {
        foreach (member; __traits(allMembers, TextureFormat)) {
            if (__traits(getMember, TextureFormat, member) == format)
                return member;
        }
        return .format("0x%X", format);
    }
}

struct SamplerHeader {
    uint[8] Words;

    WrapMode WrapU() const { return cast(WrapMode) (Words[0] & 7); }
    WrapMode WrapV() const { return cast(WrapMode) ((Words[0] >> 3) & 7); }
    WrapMode WrapP() const { return cast(WrapMode) ((Words[0] >> 6) & 7); }
    bool DepthCompare() const { return ((Words[0] >> 9) & 1) != 0; }
    uint MaxAnisotropy() const { return 1 << ((Words[0] >> 20) & 7); }
    TextureFilter MagFilter() const { return cast(TextureFilter) (Words[1] & 3); }
    TextureFilter MinFilter() const { return cast(TextureFilter) ((Words[1] >> 4) & 3); }
    MipmapFilter MipFilter() const { return cast(MipmapFilter) ((Words[1] >> 6) & 3); }
    float MinLod() const { return (Words[2] & 0xFFF) / 256.0f; }
    float MaxLod() const { return ((Words[2] >> 12) & 0xFFF) / 256.0f; }
    float BorderColor(uint index) const { return *cast(const(float)*) &Words[4 + index]; }

    string DebugDesc() const {
        return format("wrap %s/%s/%s, filter mag %s min %s mip %s, lod %.2f..%.2f, anisotropy %dx%s",
            WrapU, WrapV, WrapP, MagFilter, MinFilter, MipFilter, MinLod, MaxLod, MaxAnisotropy, DepthCompare ? ", depth compare" : "");
    }
}
