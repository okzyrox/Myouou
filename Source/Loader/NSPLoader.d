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
import std.uni : toLower;

// Core
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
        size_t archiveCount = 0;
        foreach (ref file; archive.Files) {
            if (file.Name.toLower.endsWith(".nca") || file.Name.toLower.endsWith(".ncz")) {
                archiveCount++;
            }
        }
        if (archiveCount != 0) {
            throw new ExecutableError(format("NSP has encrypted (%d) NCA files. Sucks to suck!", archiveCount, path));
        }
        throw new ExecutableError(format("NSP (%s) has no ExeFS content (of %d files)!", archive.Files.length, path));
    }
}
