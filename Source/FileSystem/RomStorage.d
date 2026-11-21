/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Read-only data storages (like romfs)
*/

module Source.FileSystem.RomStorage;

// Std
import std.format : format;
import std.stdio : File;

// Core
import Source.Crypto.Aes : AesBlockSize;
import Source.Format.NCA;

// Types
interface RomStorage {
    string Label() const;
    ulong Size() const;
    size_t Read(ulong offset, ubyte[] destination);
}

// Storages
final class MemoryStorage : RomStorage {
    private const(ubyte)[] data;
    private string label;

    this(const(ubyte)[] data, string label) {
        this.data = data;
        this.label = label;
    }

    string Label() const {
        return label;
    }

    ulong Size() const {
        return data.length;
    }

    size_t Read(ulong offset, ubyte[] destination) {
        if (offset >= data.length) {
            return 0;
        }
        const size_t length = destination.length < data.length - offset ? destination.length : cast(size_t) (data.length - offset);
        destination[0 .. length] = data[cast(size_t) offset .. cast(size_t) offset + length];
        return length;
    }
}

final class NCASectionStorage : RomStorage {
    private File file;
    private ulong ncaOffset;
    private NCAInfo info;
    private NCASection section;
    private string label;

    this(string containerPath, ulong ncaOffset, NCAInfo info, size_t index, string label) {
        file = File(containerPath, "rb");
        this.ncaOffset = ncaOffset;
        this.info = info;
        section = info.Sections[index];
        this.label = label;
        if (section.Encryption != NCAEncryption.None && section.Encryption != NCAEncryption.AesCtr) {
            throw new NCAError(format("NCA section %d uses %s, which storage reads do not support yet!", index, section.Encryption));
        }
    }

    string Label() const {
        return label;
    }

    ulong Size() const {
        return section.DataSize;
    }

    size_t Read(ulong offset, ubyte[] destination) {
        // todo: cache decrypted content
        if (offset >= section.DataSize || destination.length == 0) {
            return 0;
        }
        const size_t length = destination.length < section.DataSize - offset ? destination.length : cast(size_t) (section.DataSize - offset);
        const ulong start = section.Offset + section.DataOffset + offset;
        const ulong aligned = start & ~cast(ulong) (AesBlockSize - 1);
        const size_t padding = cast(size_t) (start - aligned);
        ubyte[] raw = new ubyte[(padding + length + AesBlockSize - 1) & ~(AesBlockSize - 1)];
        file.seek(ncaOffset + aligned);
        const size_t read = file.rawRead(raw).length;
        if (read < padding + length) {
            throw new NCAError(format("NCA section read at 0x%X ran past the end of %s!", start, label));
        }
        info.DecryptSection(section, aligned, raw);
        destination[0 .. length] = raw[padding .. padding + length];
        return length;
    }
}
