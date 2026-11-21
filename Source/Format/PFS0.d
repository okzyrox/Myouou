/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing of partition fs archives
*/

module Source.Format.PFS0;

// Std
import std.format : format;
import std.stdio : File;

// Signatures
enum uint PFS0Magic = 0x30534650; // 'PFS0'

// Types
enum uint MaxPFS0Files = 0x10000;
enum uint MaxPFS0StringTable = 0x100_0000;

struct PFS0Header {
    uint Magic;
    uint FileCount;
    uint StringTableSize;
    uint Reserved;
}

struct PFS0Entry {
    ulong Offset;
    ulong Size;
    uint NameOffset;
    uint Reserved;
}

struct PFS0FileEntry {
    string Name;
    ulong Offset;
    ulong Size;
}

class PFS0FileError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Class
final class PFS0Archive {
    immutable string Path;
    PFS0FileEntry[] Files;
    private const(ubyte)[] memory;

    static PFS0Archive Open(string path) {
        return new PFS0Archive(path);
    }

    this(string path) {
        Path = path;
        File file = File(path, "rb");
        scope (exit) {
            file.close();
        }
        Parse(file.size, (ulong offset, ubyte[] destination) {
            file.seek(offset);
            return file.rawRead(destination).length == destination.length;
        });
    }

    this(const(ubyte)[] data, string label) {
        Path = label;
        memory = data;
        Parse(data.length, (ulong offset, ubyte[] destination) {
            if (offset > memory.length || destination.length > memory.length - offset) {
                return false;
            }
            destination[] = memory[cast(size_t) offset .. cast(size_t) offset + destination.length];
            return true;
        });
    }

    private void Parse(ulong fileSize, scope bool delegate(ulong offset, ubyte[] destination) readAt) {
        PFS0Header header;
        if (!readAt(0, (cast(ubyte*) &header)[0 .. PFS0Header.sizeof]) || header.Magic != PFS0Magic) {
            throw new PFS0FileError(format("Invalid PFS0! Wrong sig like 0x%08X", header.Magic));
        }
        if (header.FileCount > MaxPFS0Files || header.StringTableSize > MaxPFS0StringTable) {
            throw new PFS0FileError(format("PFS0 header is unreasonable.. (%d files w/ 0x%X string table)!", header.FileCount, header.StringTableSize));
        }

        PFS0Entry[] entries = new PFS0Entry[header.FileCount];
        ubyte[] strings = new ubyte[header.StringTableSize];
        const ulong entriesAt = PFS0Header.sizeof;
        const ulong stringsAt = entriesAt + entries.length * PFS0Entry.sizeof;
        if ((entries.length != 0 && !readAt(entriesAt, cast(ubyte[]) entries)) || (strings.length != 0 && !readAt(stringsAt, strings))) {
            throw new PFS0FileError("PFS0 entry / string table is truncated!");
        }

        const ulong dataStart = PFS0Header.sizeof + entries.length * PFS0Entry.sizeof + strings.length;
        foreach (i, entry; entries) {
            if (entry.NameOffset >= strings.length) {
                throw new PFS0FileError(format("PFS0 entry %d has a bad name offset 0x%X!", i, entry.NameOffset));
            }
            size_t end = entry.NameOffset;
            while (end < strings.length && strings[end] != 0) {
                end++;
            }
            const ulong offset = dataStart + entry.Offset;
            if (offset + entry.Size > fileSize) {
                throw new PFS0FileError(format("PFS0 entry %d is outside the file!", i));
            }
            Files ~= PFS0FileEntry((cast(const(char)[]) strings[entry.NameOffset .. end]).idup, offset, entry.Size);
        }
    }

    const(PFS0FileEntry)* Find(string name) const {
        foreach (ref entry; Files) {
            if (entry.Name == name) {
                return &entry;
            }
        }
        return null;
    }

    bool Has(string name) const {
        return Find(name) !is null;
    }

    ubyte[] Read(string name) const {
        const(PFS0FileEntry)* entry = Find(name);
        if (entry is null) {
            throw new PFS0FileError(format("PFS0 has no file '%s'!", name));
        }
        return ReadRange(name, 0, cast(size_t) entry.Size);
    }

    ubyte[] ReadRange(string name, ulong offset, size_t length) const {
        const(PFS0FileEntry)* entry = Find(name);
        if (entry is null) {
            throw new PFS0FileError(format("PFS0 has no file '%s'!", name));
        }
        if (offset > entry.Size) {
            throw new PFS0FileError(format("PFS0 read at 0x%X is past the end of '%s'!", offset, name));
        }
        if (length > entry.Size - offset) {
            length = cast(size_t) (entry.Size - offset);
        }
        ubyte[] data = new ubyte[length];
        if (data.length == 0) {
            return data;
        }
        if (memory !is null) { // temp
            data[] = memory[cast(size_t) (entry.Offset + offset) .. cast(size_t) (entry.Offset + offset) + length];
            return data;
        }
        File file = File(Path, "rb");
        scope (exit) {
            file.close();
        }
        file.seek(entry.Offset + offset);
        if (file.rawRead(data).length != data.length) {
            throw new PFS0FileError(format("PFS0 file '%s' is truncated...", name));
        }
        return data;
    }
}
