/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loads NSP / PFS0 packages
*/

module Source.Loader.NSPLoader;

// Std
import std.algorithm : endsWith;
import std.format : format;
import std.stdio : writefln;
import std.uni : toLower;

// Core
import Source.Crypto.Aes : AesBlockSize;
import Source.Crypto.Keys;
import Source.FileSystem.RomStorage;
import Source.Format.NCA;
import Source.Format.PFS0;
import Source.Format.Ticket;
import Source.Loader.ExeFSLoader;
import Source.Loader.Executable;

// Sources
final class PFS0Source : ExeFSSource {
    private PFS0Archive archive;

    this(PFS0Archive archive) {
        this.archive = archive;
    }

    string Label() const {
        return archive.Path;
    }

    bool Has(string name) {
        return archive.Has(name);
    }

    const(ubyte)[] Read(string name) {
        return archive.Read(name);
    }
}

// Class
final class NSPExecutable {
    enum string Name = "NSP";
    enum string Extension = ".nsp";

    static bool Matches(const(ubyte)[] header) {
        return header.length >= uint.sizeof && *cast(const(uint)*) header.ptr == PFS0Magic;
    }

    static Executable Open(string path) {
        PFS0Archive archive;
        try {
            archive = PFS0Archive.Open(path);
        } catch (PFS0FileError error) {
            throw new ExecutableError(error.msg);
        }
        if (archive.Has("main")) {
            return new ExeFSExecutable(new PFS0Source(archive), Name, Extension);
        }
        string[] ncas;
        size_t compressed = 0;
        foreach (ref file; archive.Files) {
            if (file.Name.toLower.endsWith(".nca")) {
                ncas ~= file.Name;
            } else if (file.Name.toLower.endsWith(".ncz")) {
                compressed++;
            }
        }
        if (ncas.length != 0 || compressed != 0) {
            NCAInfo[string] parsed = DescribeNcas(archive, ncas, compressed);
            foreach (name; ncas) {
                NCAInfo* info = name in parsed;
                if (info is null || info.ContentType != NCAContentType.Program || !info.Sections[0].Present || info.Sections[0].FsType != NCAFsType.PartitionFs) {
                    continue;
                }
                if (!info.KeysReady) {
                    throw new ExecutableError(format("Program NCA %s cannot be decrypted (%s)!", name, info.KeyError));
                }
                PFS0Archive exefs;
                try {
                    exefs = new PFS0Archive(ReadSectionData(archive, name, *info, 0), path ~ "/" ~ name ~ "/exefs");
                } catch (NCAError error) {
                    throw new ExecutableError(format("Program NCA %s ExeFS could not be read (%s)!", name, error.msg));
                } catch (PFS0FileError error) {
                    throw new ExecutableError(format("Program NCA %s ExeFS did not decrypt to a PFS0 (%s)!", name, error.msg));
                }
                writefln("Running ExeFS from program NCA %s.", name);
                ExeFSExecutable executable = new ExeFSExecutable(new PFS0Source(exefs), Name, Extension);
                foreach (index, ref section; info.Sections) {
                    if (section.Present && section.FsType == NCAFsType.RomFs) {
                        executable.RomFS = new NCASectionStorage(path, archive.Find(name).Offset, *info, index, name ~ " section " ~ format("%d", index));
                        break;
                    }
                }
                return executable;
            }
            throw new ExecutableError(format("NSP has %d NCA files but no readable program NCA!", ncas.length + compressed));
        }
        throw new ExecutableError(format("NSP (%s) has no ExeFS content (of %d files)!", path, archive.Files.length));
    }

    private static ubyte[] ReadSectionData(PFS0Archive archive, string name, NCAInfo info, size_t index) {
        // todo: ROMFS mounting
        const NCASection section = info.Sections[index];
        const ulong alignment = section.Encryption == NCAEncryption.AesXts ? NCASectorSize : AesBlockSize;
        const ulong start = section.Offset + section.DataOffset;
        const ulong aligned = section.Offset + ((start - section.Offset) & ~(alignment - 1));
        const size_t padding = cast(size_t) (start - aligned);
        const size_t length = cast(size_t) ((section.DataSize + padding + alignment - 1) & ~(alignment - 1));
        ubyte[] raw = archive.ReadRange(name, aligned, length);
        info.DecryptSection(section, aligned, raw);
        return raw[padding .. padding + cast(size_t) section.DataSize];
    }

    private static void LoadTickets(PFS0Archive archive, KeySet keys) {
        foreach (ref file; archive.Files) {
            if (!file.Name.toLower.endsWith(".tik")) {
                continue;
            }
            Ticket ticket;
            try {
                ticket = new Ticket(archive.Read(file.Name));
            } catch (TicketError error) {
                writefln("Ticket %s: %s", file.Name, error.msg);
                continue;
            }
            if (!ticket.IsCommon) {
                writefln("Ticket %s is a console personalised key, so its title key must come from title keys!!!", file.Name);
                continue;
            }
            if (keys.TitleKey(ticket.RightsId).length == 0) {
                keys.AddTitleKey(ticket.RightsId, ticket.EncryptedTitleKey);
                writefln("Ticket %s: title key for rights %s (issued by the issuer: %s).", file.Name, HexString(ticket.RightsId), ticket.Issuer);
            }
        }
    }

    private static NCAInfo[string] DescribeNcas(PFS0Archive archive, string[] ncas, size_t compressed) {
        KeySet keys = new KeySet();
        LoadTickets(archive, keys);
        NCAInfo[string] parsed;
        foreach (name; ncas) {
            NCAInfo info;
            try {
                info = NCAInfo.Parse(archive.ReadRange(name, 0, NCAHeaderSize), keys);
            } catch (NCAError error) {
                writefln("NCA %s: %s", name, error.msg);
                continue;
            }
            parsed[name] = info;
            writefln("NCA %s: %s %s, (program %016X, keygen %d) %s", name, info.Magic == NCA3Magic ? "NCA3" : "NCA2", info.ContentType, info.ProgramId, info.KeyGeneration, info.KeysReady ? "keys ok via " ~ info.KeySource : "keys missing (" ~ info.KeyError ~ ")");
            foreach (i, ref section; info.Sections) {
                if (!section.Present) {
                    continue;
                }
                writefln("%-4s [%d]: %s, %s hash, %s (at 0x%X size 0x%X, data 0x%X size 0x%X)", "", i, section.FsType, section.HashType, section.Encryption, section.Offset, section.Size, section.DataOffset, section.DataSize);
            }
        }
        if (compressed != 0) {
            writefln("%d compressed NCZ file arent supported.", compressed);
        }
        return parsed;
    }
}
