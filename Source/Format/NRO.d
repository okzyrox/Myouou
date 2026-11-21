/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing of NRO executables
*/

module Source.Format.NRO;

// Std
import std.file : read;
import std.format : format;

// Core
import Source.Format.Utils.General;

// Signatures
enum uint NROMagic = 0x304F524E;
enum uint ModuleHeaderMagic = 0x30444F4D;
enum uint AssetMagic = 0x54455341;
enum size_t NroPageSize = 0x1000;

// Types
enum NROSegmentKind : size_t {
    Text = 0,
    Ro = 1,
    Data = 2,
}

struct NROSegment {
    uint FileOffset;
    uint Size;
}

struct NROHeader {
    uint EntryBranch;
    uint ModuleHeaderOffset;
    ulong Padding;
    uint Magic;
    uint Version;
    uint Size;
    uint Flags;
    NROSegment[3] Segments; // Text, ro and data
    uint BssSize;
    uint Reserved0; // AdditionalHeaderOffset
    ubyte[0x20] ModuleId;
    uint DsoHandleOffset;
    uint Reserved1;
    NROSegment Embedded; // ?? sob
    NROSegment DynStr;
    NROSegment DynSym;
}

// rocrt::ModuleHeader
struct ModuleHeader {
    uint Magic;
    int DynamicOffset;
    int BssStartOffset;
    int BssEndOffset;
    int ExceptionInfoStartOffset;
    int ExceptionInfoEndOffset;
    int ModuleOffset;
}

struct AssetSection {
    ulong Offset;
    ulong Size;
}

struct AssetHeader {
    uint Magic; //ASET
    uint Version;
    AssetSection Icon; // JPG 256x256
    AssetSection Nacp;
    AssetSection RomFs;
}

struct NacpInfo {
    string Title; // 0x0 200
    string Author; // 0x200 100
        // no multi string yet
    string DisplayVersion; // 0x3060 10
    // and a lot more...
}

class NROFileError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Class
final class NROFile {
    private NROHeader header;
    private ModuleHeader modHeader;
    private AssetHeader assets;

    private bool hasAssets;
    private const(ubyte)[] data;

    private this(const(ubyte)[] data) {
        this.data = data;
        Validate();
    }

    static NROFile Load(string path) {
        return new NROFile(cast(const(ubyte)[]) read(path));
    }

    static NROFile Parse(const(ubyte)[] data) {
        return new NROFile(data);
    }

    const(NROHeader) Header() const nothrow @nogc {
        return header;
    }

    const(ModuleHeader) ModHeader() const nothrow @nogc {
        return modHeader;
    }

    const(ubyte)[] FileData() const nothrow @nogc {
        return data;
    }

    const(ubyte)[] Segment(NROSegmentKind kind) const nothrow @nogc {
        const NROSegment segment = header.Segments[kind];
        return data[segment.FileOffset .. segment.FileOffset + segment.Size];
    }

    const(ubyte)[] Text() const nothrow @nogc {
        return Segment(NROSegmentKind.Text);
    }

    const(ubyte)[] Ro() const nothrow @nogc {
        return Segment(NROSegmentKind.Ro);
    }

    const(ubyte)[] Data() const nothrow @nogc {
        return Segment(NROSegmentKind.Data);
    }

    size_t BssOffset() const nothrow @nogc {
        const NROSegment segment = header.Segments[NROSegmentKind.Data];
        return segment.FileOffset + segment.Size;
    }

    size_t BssSize() const nothrow @nogc {
        return AlignValue(header.BssSize, NroPageSize);
    }

    size_t ImageSize() const nothrow @nogc {
        return AlignValue(BssOffset() + BssSize(), NroPageSize);
    }

    const(ubyte)[] ModuleId() const nothrow @nogc {
        return header.ModuleId[];
    }

    bool HasAssets() const nothrow @nogc {
        return hasAssets;
    }

    const(AssetHeader) Assets() const nothrow @nogc {
        return assets;
    }

    const(ubyte)[] Icon() const nothrow @nogc {
        return AssetData(assets.Icon);
    }

    const(ubyte)[] NacpData() const nothrow @nogc {
        return AssetData(assets.Nacp);
    }

    const(ubyte)[] RomFs() const nothrow @nogc {
        return AssetData(assets.RomFs);
    }

    NacpInfo Nacp() const {
        NacpInfo info;
        const size_t nacpMax = 0x3070;
        const(ubyte)[] nacp = NacpData();
        if (nacp.length < nacpMax)
            return info;

        foreach (index; 0 .. 16) {
            // may replace this with a match for the location for each type and such
            // so that its automatic
            // shrug
            const(ubyte)[] entry = nacp[index * 0x300 .. (index + 1) * 0x300];
            string title = LimitedStr(entry[0 .. 0x200]);
            if (title.length == 0)
                continue;
            info.Title = title;
            info.Author = LimitedStr(entry[0x200 .. 0x300]);
            break;
        }
        info.DisplayVersion = LimitedStr(nacp[0x3060 .. nacpMax]);
        return info;
    }

    private const(ubyte)[] AssetData(AssetSection section) const nothrow @nogc {
        if (!hasAssets || section.Size == 0)
            return null;
        const size_t start = header.Size + cast(size_t) section.Offset;
        return data[start .. start + cast(size_t) section.Size];
    }

    private void Validate() {
        header = *cast(const(NROHeader)*) data.ptr;
        if (header.Magic != NROMagic)
            throw new NROFileError(format("Invalid NRO! wrong sig like 0x%08X", header.Magic));
        if (header.Size > data.length)
            throw new NROFileError(format("NRO size 0x%X exceeds data 0x%X", header.Size, data.length));

        size_t expectedOffset = 0;
        foreach (kind, segment; header.Segments) {
            if (segment.FileOffset != expectedOffset)
                throw new NROFileError(format("Segment %s starts at 0x%X, expected 0x%X", cast(NROSegmentKind) kind, segment.FileOffset, expectedOffset));
            if (segment.FileOffset % NroPageSize != 0 || segment.Size % NroPageSize != 0)
                throw new NROFileError(format("Page of segment %s is not aligned!", cast(NROSegmentKind) kind));
            if (cast(size_t) segment.FileOffset + segment.Size > header.Size)
                throw new NROFileError(format("Segment %s exceeds NRO image.", cast(NROSegmentKind) kind));
            expectedOffset = segment.FileOffset + segment.Size;
        }

        if (header.ModuleHeaderOffset + ModuleHeader.sizeof <= header.Size) {
            modHeader = *cast(const(ModuleHeader)*) (data.ptr + header.ModuleHeaderOffset);
            if (modHeader.Magic != ModuleHeaderMagic)
                throw new NROFileError(format("Invalid ModuleHeader magic 0x%08X at 0x%X", modHeader.Magic, header.ModuleHeaderOffset));
        }

        ValidateAssets();
    }

    private void ValidateAssets() {
        if (data.length < cast(size_t) header.Size + AssetHeader.sizeof)
            return;

        const AssetHeader candidate = *cast(const(AssetHeader)*) (data.ptr + header.Size);
        if (candidate.Magic != AssetMagic)
            return;

        foreach (section; [candidate.Icon, candidate.Nacp, candidate.RomFs]) {
            if (header.Size + section.Offset + section.Size > data.length)
                throw new NROFileError("NRO asset section exceeds the file itself!");
        }

        assets = candidate;
        hasAssets = true;
    }

    // used for NACP strings
    private static string LimitedStr(const(ubyte)[] bytes) {
        size_t len = 0;
        while (len < bytes.length && bytes[len] != 0)
            len++;
        return (cast(const(char)[]) bytes[0 .. len]).idup;
    }
}
