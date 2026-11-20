/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Guest filesystems mapped out
*/

module Source.FileSystem.HostFileSystem;

// Std
import std.algorithm : min, sort;
import std.array : split;
import std.file : DirEntry, FileException, SpanMode, dirEntries, exists, getAvailableDiskSpace, getSize, getTimes, isDir, isFile, mkdir, rename, rmdir, rmdirRecurse, remove, write;
import std.datetime : SysTime;
import std.path : baseName, buildPath;
import std.stdio : File;

// Core
import Source.Kernel.Result;

// Types
enum FsResult : uint {
    PathNotFound = MakeModuleResult(2, 1),
    PathAlreadyExists = MakeModuleResult(2, 2),
    TargetNotFound = MakeModuleResult(2, 1002),
    DirectoryNotEmpty = MakeModuleResult(2, 8),
    InvalidPath = MakeModuleResult(2, 6001),
    InvalidOffset = MakeModuleResult(2, 6061),
    UnsupportedOperation = MakeModuleResult(2, 6300),
}

enum FsEntryType : uint {
    Directory = 0,
    File = 1,
}

struct FsEntry {
    string Name;
    FsEntryType Type;
    ulong Size;
}

struct FsTimeStamp {
    ulong Created;
    ulong Modified;
    ulong Accessed;
}

// About 64GiB~
enum ulong ReportedTotalSpace = 64UL * 1024 * 1024 * 1024;

// Class
final class HostFileSystem {
    immutable string Root;
    immutable string Label;

    private string[string] mappedFiles;

    this(string root, string label) {
        Root = root;
        Label = label;
    }

    bool Resolve(string guestPath, out string hostPath) const {
        if (guestPath.length == 0 || guestPath[0] != '/') {
            return false;
        }
        string[] parts = [Root];
        foreach (part; guestPath.split("/")) {
            if (part.length == 0) {
                continue;
            }
            if (part == "." || part == ".." || part.length > 0x300) {
                // todo: handle without escaping
                return false;
            }
            parts ~= part;
        }
        if (const(string)* mapped = NormalisePathParts(parts[1 .. $]) in mappedFiles) {
            hostPath = *mapped;
            return true;
        }
        hostPath = buildPath(parts);
        return true;
    }

    // Exposes a host file outside at a guestpath
    void MapFile(string guestPath, string hostPath) {
        mappedFiles[NormalisePathParts(guestPath.split("/"))] = hostPath;
    }

    private bool IsMapped(string guestPath) const {
        return (NormalisePathParts(guestPath.split("/")) in mappedFiles) !is null;
    }

    private static string NormalisePathParts(const(string)[] parts) {
        string normalised;
        foreach (part; parts) {
            if (part.length != 0) {
                normalised ~= "/" ~ part;
            }
        }
        return normalised;
    }

    uint EntryType(string guestPath, out FsEntryType type) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host)) {
            return FsResult.PathNotFound;
        }
        type = isDir(host) ? FsEntryType.Directory : FsEntryType.File;
        return ResultSuccess;
    }

    uint CreateFile(string guestPath, ulong size) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (exists(host)) {
            return FsResult.PathAlreadyExists;
        }
        if (!ParentExists(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() {
            File file = File(host, "wb");
            if (size > 0) {
                file.seek(size - 1);
                file.rawWrite([cast(ubyte) 0]);
            }
            file.close();
        });
    }

    uint DeleteFile(string guestPath) const {
        if (IsMapped(guestPath)) {
            return FsResult.UnsupportedOperation;
        }
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isFile(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() => remove(host));
    }

    uint CreateDirectory(string guestPath) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (exists(host)) {
            return FsResult.PathAlreadyExists;
        }
        if (!ParentExists(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() => mkdir(host));
    }

    uint DeleteDirectory(string guestPath, bool recursive) const {
        string host;
        if (!Resolve(guestPath, host) || host == Root) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isDir(host)) {
            return FsResult.PathNotFound;
        }
        if (!recursive && !dirEntries(host, SpanMode.shallow).empty) {
            return FsResult.DirectoryNotEmpty;
        }
        return GuardFSAction(() {
            if (recursive) {
                rmdirRecurse(host);
            } else {
                rmdir(host);
            }
        });
    }

    uint CleanDirectory(string guestPath) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isDir(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() {
            foreach (DirEntry entry; dirEntries(host, SpanMode.shallow)) {
                if (entry.isDir) {
                    rmdirRecurse(entry.name);
                } else {
                    remove(entry.name);
                }
            }
        });
    }

    uint Rename(string fromPath, string toPath, bool directory) const {
        if (IsMapped(fromPath) || IsMapped(toPath)) {
            return FsResult.UnsupportedOperation;
        }
        string from;
        string to;
        if (!Resolve(fromPath, from) || !Resolve(toPath, to)) {
            return FsResult.InvalidPath;
        }
        if (!exists(from) || isDir(from) != directory) {
            return FsResult.PathNotFound;
        }
        if (exists(to)) {
            return FsResult.PathAlreadyExists;
        }
        return GuardFSAction(() => rename(from, to));
    }

    uint FileSize(string guestPath, out ulong size) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isFile(host)) {
            return FsResult.PathNotFound;
        }
        size = getSize(host);
        return ResultSuccess;
    }

    uint Read(string guestPath, ulong offset, ubyte[] destination, out size_t read) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isFile(host)) {
            return FsResult.PathNotFound;
        }
        size_t count;
        const uint result = GuardFSAction(() {
            File file = File(host, "rb");
            const ulong size = file.size;
            if (offset < size) {
                file.seek(offset);
                count = file.rawRead(destination[0 .. cast(size_t) min(destination.length, size - offset)]).length;
            }
            file.close();
        });
        read = count;
        return result;
    }

    uint Write(string guestPath, ulong offset, const(ubyte)[] source) const {
        if (IsMapped(guestPath)) {
            return FsResult.UnsupportedOperation;
        }
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isFile(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() {
            File file = File(host, "r+b");
            file.seek(offset);
            file.rawWrite(source);
            file.close();
        });
    }

    uint SetSize(string guestPath, ulong size) const {
        if (IsMapped(guestPath)) {
            return FsResult.UnsupportedOperation;
        }
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isFile(host)) {
            return FsResult.PathNotFound;
        }
        return GuardFSAction(() {
            ubyte[] data = new ubyte[cast(size_t) size];
            File file = File(host, "rb");
            file.rawRead(data[0 .. cast(size_t) min(size, file.size)]);
            file.close();
            write(host, data);
        });
    }

    uint List(string guestPath, uint filter, out FsEntry[] entries) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host) || !isDir(host)) {
            return FsResult.PathNotFound;
        }
        FsEntry[] found;
        const uint result = GuardFSAction(() {
            foreach (DirEntry entry; dirEntries(host, SpanMode.shallow)) {
                const bool directory = entry.isDir;
                if ((directory && (filter & 1) == 0) || (!directory && (filter & 2) == 0)) {
                    continue;
                }
                found ~= FsEntry(baseName(entry.name), directory ? FsEntryType.Directory : FsEntryType.File, directory ? 0 : entry.size);
            }
        });
        found.sort!((a, b) => a.Name < b.Name);
        entries = found;
        return result;
    }

    uint TimeStamp(string guestPath, out FsTimeStamp stamp) const {
        string host;
        if (!Resolve(guestPath, host)) {
            return FsResult.InvalidPath;
        }
        if (!exists(host)) {
            return FsResult.PathNotFound;
        }
        SysTime accessed;
        SysTime modified;
        getTimes(host, accessed, modified);
        stamp = FsTimeStamp(modified.toUnixTime, modified.toUnixTime, accessed.toUnixTime);
        return ResultSuccess;
    }

    ulong FreeSpace() const {
        // doesnt entirely accustom to host file system storage space
        // :ohwell:
        try {
            return getAvailableDiskSpace(Root);
        } catch (Exception) {
            return ReportedTotalSpace / 2;
        }
    }

    ulong TotalSpace() const {
        return ReportedTotalSpace;
    }

    private static bool ParentExists(string host) {
        import std.path : dirName;
        const string parent = dirName(host);
        return exists(parent) && isDir(parent);
    }

    private static uint GuardFSAction(scope void delegate() action) {
        try {
            action();
            return ResultSuccess;
        } catch (FileException) {
            return FsResult.PathNotFound;
        } catch (Exception) {
            return FsResult.UnsupportedOperation;
        }
    }
}
