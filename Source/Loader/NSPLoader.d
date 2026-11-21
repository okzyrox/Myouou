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
import Source.Crypto.Keys;
import Source.Format.NCA;
import Source.Format.PFS0;
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
            DescribeNcas(archive, ncas, compressed);
            throw new ExecutableError(format("NSP has NCA files!"));
        }
        throw new ExecutableError(format("NSP (%s) has no ExeFS content (of %d files)!", path, archive.Files.length));
    }

    private static void DescribeNcas(PFS0Archive archive, string[] ncas, size_t compressed) {
        KeySet keys = new KeySet();
        foreach (name; ncas) {
            NCAInfo info;
            try {
                info = NCAInfo.Parse(archive.ReadRange(name, 0, NCAHeaderSize), keys);
            } catch (NCAError error) {
                writefln("NCA %s: %s", name, error.msg);
                continue;
            }
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
    }
}
