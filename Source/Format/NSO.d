/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing of NSO executables
*/

module Source.Format.NSO;

// Std
import std.file : read;
import std.format : format;

// Core
import Source.Format.Utils.Lz4;

// Signatures
enum uint NSOMagic = 0x304F534E; // 'NSO0'

// Types
enum NSOSegmentKind : size_t {
    Text = 0,
    Ro = 1,
    Data = 2,
}

// todo: the other flags and flag checking
enum uint NSOFlagTextCompressed = 1 << 0;
enum uint NSOFlagRoCompressed = 1 << 1;
enum uint NSOFlagDataCompressed = 1 << 2;

struct NSOSegment {
    uint FileOffset;
    uint MemoryOffset;
    uint Size;
}

struct NSORelativeRange {
    uint Offset;
    uint Size;
}

struct NSOHeader {
    uint Magic;
    uint Version;
    uint Reserved0;
    uint Flags;
    NSOSegment Text;
    uint ModuleNameOffset;
    NSOSegment Ro;
    uint ModuleNameSize;
    NSOSegment Data;
    uint BssSize;
    ubyte[0x20] ModuleId;
    uint[3] CompressedSizes;
    ubyte[0x1C] Reserved1;
    NSORelativeRange ApiInfo;
    NSORelativeRange DynStr;
    NSORelativeRange DynSym;
    ubyte[0x20][3] Hashes;
}

class NSOFileError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Class
final class NSOFile {
    private NSOHeader header;
    private ubyte[][3] segments;

    static NSOFile Load(string path) {
        return new NSOFile(cast(const(ubyte)[]) read(path));
    }

    this(const(ubyte)[] data) {
        if (data.length < NSOHeader.sizeof) {
            throw new NSOFileError(format("NSO is too small (0x%X bytes)!", data.length));
        }
        header = *cast(const(NSOHeader)*) data.ptr;
        if (header.Magic != NSOMagic) {
            throw new NSOFileError(format("Invalid NSO! wrong sig like 0x%08X", header.Magic));
        }
        const NSOSegment[3] layout = [header.Text, header.Ro, header.Data];
        foreach (i; 0 .. 3) {
            segments[i] = ReadSegment(data, layout[i], header.CompressedSizes[i], (header.Flags & (1u << i)) != 0, i);
        }
    }

    private static ubyte[] ReadSegment(const(ubyte)[] data, const ref NSOSegment segment, uint fileSize, bool compressed, size_t index) {
        if (segment.Size == 0) {
            return null;
        }
        const size_t stored = compressed ? fileSize : segment.Size;
        if (segment.FileOffset + stored > data.length) {
            throw new NSOFileError(format("NSO segment %d at 0x%X (0x%X bytes) is outside the file!", index, segment.FileOffset, stored));
        }
        const(ubyte)[] raw = data[segment.FileOffset .. segment.FileOffset + stored];
        if (!compressed) {
            return raw.dup;
        } else {
            try {
                return Lz4DecompressBlock(raw, segment.Size);
            } catch (Lz4Error error) {
                throw new NSOFileError(format("NSO segment %d failed to decompress (%s)!", index, error.msg));
            }
        }
    }

    const(NSOHeader) Header() const nothrow @nogc {
        return header;
    }

    const(ubyte)[] Segment(NSOSegmentKind kind) const nothrow @nogc {
        return segments[kind];
    }

    NSOSegment Layout(NSOSegmentKind kind) const nothrow @nogc {
        final switch (kind) {
            case NSOSegmentKind.Text: return header.Text;
            case NSOSegmentKind.Ro: return header.Ro;
            case NSOSegmentKind.Data: return header.Data;
        }
    }

    uint BssSize() const nothrow @nogc {
        return header.BssSize;
    }

    size_t ImageSize() const nothrow @nogc {
        const ulong end = cast(ulong) header.Data.MemoryOffset + header.Data.Size + header.BssSize;
        return cast(size_t) ((end + 0xFFF) & ~0xFFFUL);
    }

    string ModuleIdHex() const {
        return format("%(%02X%)", header.ModuleId[0 .. 0x20]);
    }
}
