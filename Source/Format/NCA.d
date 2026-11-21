/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing/key derivs of NCA archives
*/

module Source.Format.NCA;

// Std
import std.format : format;

// Core
import Source.Format.Utils.General;
import Source.Crypto.Aes;
import Source.Crypto.Keys;

// Signatures
enum uint NCA3Magic = 0x3341434E; // 'NCA3'
enum uint NCA2Magic = 0x3241434E; // 'NCA2'
immutable string[3] KeyAreaKeyNames = ["key_area_key_application", "key_area_key_ocean", "key_area_key_system"];

// Types
enum size_t NCAHeaderSize = 0xC00;
enum size_t NCASectorSize = 0x200;
enum size_t NCAMediaUnit = 0x200;
enum size_t NCASectionCount = 4;

enum NCAContentType : ubyte {
    Program = 0,
    Meta = 1,
    Control = 2,
    Manual = 3,
    Data = 4,
    PublicData = 5,
}

enum NCAFsType : ubyte {
    RomFs = 0,
    PartitionFs = 1,
}

enum NCAHashType : ubyte {
    Auto = 0,
    None = 1,
    HierarchicalSha256 = 2,
    HierarchicalIntegrity = 3,
}

enum NCAEncryption : ubyte {
    Auto = 0,
    None = 1,
    AesXts = 2,
    AesCtr = 3,
    AesCtrEx = 4,
}


struct NCASection {
    bool Present;
    ulong Offset;
    ulong Size;
    NCAFsType FsType;
    NCAHashType HashType;
    NCAEncryption Encryption;
    ubyte[8] CtrUpper;
    ulong DataOffset;
    ulong DataSize;
}

class NCAError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}


// Class
// todo: NCA0...
final class NCAInfo {
    uint Magic;
    ubyte Distribution;
    NCAContentType ContentType;
    ubyte KeyGeneration;
    ubyte KeyAreaIndex;
    ulong ContentSize;
    ulong ProgramId;
    uint ContentIndex;
    uint SdkVersion;
    ubyte[16] RightsId;
    NCASection[NCASectionCount] Sections;
    ubyte[16][4] KeyArea;
    ubyte[16] TitleKey;
    bool KeysReady;
    string KeyError;

    static NCAInfo Parse(const(ubyte)[] encrypted, const KeySet keys) {
        if (encrypted.length < NCAHeaderSize) {
            throw new NCAError(format("NCA header is too small (0x%X bytes)!", encrypted.length));
        }
        const(ubyte)[] headerKey = keys.Get("header_key");
        if (headerKey.length != 32) {
            throw new NCAError("NCA headers couldn't be decrypted!");
        }

        ubyte[] header = encrypted[0 .. NCAHeaderSize].dup;
        AesXtsDecrypt(headerKey, header, 0, NCASectorSize);
        const uint magic = At!uint(header, 0x200);
        if (magic == NCA2Magic) {
            header = encrypted[0 .. NCAHeaderSize].dup;
            AesXtsDecrypt(headerKey, header[0 .. 0x400], 0, NCASectorSize);
            foreach (i; 0 .. NCASectionCount) {
                AesXtsDecrypt(headerKey, header[0x400 + i * 0x200 .. 0x600 + i * 0x200], 0, NCASectorSize);
            }
        } else if (magic != NCA3Magic) {
            throw new NCAError(format("NCA header wasnt able to decrypt (has magic 0x%08X), maybe not an NCA?", magic));
        }

        NCAInfo info = new NCAInfo();
        info.Magic = magic;
        info.Distribution = header[0x204];
        info.ContentType = cast(NCAContentType) header[0x205];
        const ubyte oldGeneration = header[0x206];
        // stupid stupid format
        // i hate everything
        info.KeyAreaIndex = header[0x207];
        info.ContentSize = At!ulong(header, 0x208);
        info.ProgramId = At!ulong(header, 0x210);
        info.ContentIndex = At!uint(header, 0x218);
        info.SdkVersion = At!uint(header, 0x21C);
        const ubyte newGeneration = header[0x220];
        info.KeyGeneration = oldGeneration > newGeneration ? oldGeneration : newGeneration;
        info.RightsId = header[0x230 .. 0x240];

        foreach (i; 0 .. NCASectionCount) {
            const uint start = At!uint(header, 0x240 + i * 0x10);
            const uint end = At!uint(header, 0x244 + i * 0x10);
            if (end <= start) {
                continue;
            }
            const(ubyte)[] fs = header[0x400 + i * 0x200 .. 0x600 + i * 0x200];
            NCASection section;
            section.Present = true;
            section.Offset = cast(ulong) start * NCAMediaUnit;
            section.Size = cast(ulong) (end - start) * NCAMediaUnit;
            section.FsType = cast(NCAFsType) fs[0x2];
            section.HashType = cast(NCAHashType) fs[0x3];
            section.Encryption = cast(NCAEncryption) fs[0x4];
            section.CtrUpper = fs[0x140 .. 0x148];
            if (section.HashType == NCAHashType.HierarchicalSha256) { // ??????????????????????????????????????????
                const uint layers = At!uint(fs, 0x2C);
                if (layers >= 1 && layers <= 5) {
                    section.DataOffset = At!ulong(fs, 0x30 + (layers - 1) * 0x10);
                    section.DataSize = At!ulong(fs, 0x38 + (layers - 1) * 0x10);
                }
            } else if (section.HashType == NCAHashType.HierarchicalIntegrity) {
                section.DataOffset = At!ulong(fs, 0x18 + 5 * 0x18);
                section.DataSize = At!ulong(fs, 0x20 + 5 * 0x18);
            } else {
                section.DataSize = section.Size;
            }
            info.Sections[i] = section;
        }

        info.DeriveKeys(header[0x300 .. 0x340], keys);
        return info;
    }

    ubyte MasterKeyRevision() const {
        return KeyGeneration > 0 ? cast(ubyte) (KeyGeneration - 1) : 0;
    }

    bool HasRightsId() const {
        foreach (value; RightsId) {
            if (value != 0) {
                return true;
            }
        }
        return false;
    }

    private void DeriveKeys(const(ubyte)[] encryptedKeyArea, const KeySet keys) {
        if (HasRightsId) {
            const string kekName = format("titlekek_%02x", MasterKeyRevision);
            const(ubyte)[] kek = keys.Get(kekName);
            const(ubyte)[] encryptedTitleKey = keys.TitleKey(RightsId);
            if (encryptedTitleKey.length != 16) {
                KeyError = format("title.keys has no title key for rights id %s.", HexString(RightsId));
                return;
            }
            if (kek.length != 16) {
                KeyError = format("prod.keys is missing %s.", kekName);
                return;
            }
            TitleKey = encryptedTitleKey[0 .. 16];
            AesEcbDecrypt(kek, TitleKey[]);
            KeysReady = true;
            return;
        }
        if (KeyAreaIndex >= KeyAreaKeyNames.length) {
            KeyError = format("unknown key area index %d.", KeyAreaIndex);
            return;
        }
        const string kaekName = format("%s_%02x", KeyAreaKeyNames[KeyAreaIndex], MasterKeyRevision);
        const(ubyte)[] kaek = keys.Get(kaekName);
        if (kaek.length != 16) {
            KeyError = format("prod.keys is missing %s.", kaekName);
            return;
        }
        foreach (i; 0 .. 4) {
            KeyArea[i] = encryptedKeyArea[i * 16 .. (i + 1) * 16];
            AesEcbDecrypt(kaek, KeyArea[i][]);
        }
        KeysReady = true;
    }

    ubyte[16] SectionCounter(const ref NCASection section, ulong absoluteOffset) const {
        ubyte[16] counter;
        foreach (i; 0 .. 8) {
            counter[i] = section.CtrUpper[7 - i];
        }
        const ulong block = absoluteOffset >> 4;
        foreach (i; 0 .. 8) {
            counter[15 - i] = cast(ubyte) (block >> (i * 8));
        }
        return counter;
    }

    void DecryptSection(const ref NCASection section, ulong absoluteOffset, ubyte[] data) const {
        if (section.Encryption == NCAEncryption.None) {
            return;
        }
        if (!KeysReady) {
            throw new NCAError("NCA keys are not available: " ~ KeyError);
        }
        switch (section.Encryption) {
            case NCAEncryption.AesCtr:
                if (absoluteOffset % AesBlockSize != 0) {
                    throw new NCAError(format("NCA section read at 0x%X is not block aligned!", absoluteOffset));
                }
                AesCtrCrypt(CtrKey, SectionCounter(section, absoluteOffset), data);
                return;
            case NCAEncryption.AesXts:
                if ((absoluteOffset - section.Offset) % NCASectorSize != 0) {
                    throw new NCAError(format("NCA section read at 0x%X is not sector aligned!", absoluteOffset));
                }
                AesXtsDecrypt(KeyArea[0] ~ KeyArea[1], data, (absoluteOffset - section.Offset) / NCASectorSize, NCASectorSize);
                return;
            default:
                throw new NCAError(format("Unsupported NCA section encryption (%s)!", section.Encryption));
        }
    }

    const(ubyte)[] CtrKey() const {
        return HasRightsId ? TitleKey[] : KeyArea[2][];
    }

    string KeySource() const {
        if (!KeysReady) {
            return KeyError;
        }
        if (HasRightsId) {
            return format("title key for %s (titlekek_%02x)", HexString(RightsId), MasterKeyRevision);
        }
        return format("key area (%s_%02x)", KeyAreaKeyNames[KeyAreaIndex], MasterKeyRevision);
    }
}