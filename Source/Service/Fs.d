/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * fsp-srv: filesystemproxy over emustorage
*/

module Source.Service.Fs;

// Std
import std.algorithm : min;

// Core
import Source.FileSystem.HostFileSystem;
import Source.FileSystem.Storage;
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
enum uint FsOpenRead = 1;
enum uint FsOpenWrite = 2;
enum uint FsOpenAppend = 4;
enum size_t DirectoryEntrySize = 0x310;

struct FsTimeStampRaw {
    ulong Created;
    ulong Modified;
    ulong Accessed;
    ubyte IsValid;
    ubyte[7] Padding;
}

static assert(FsTimeStampRaw.sizeof == 0x20);

// Utils
private string PathArgument(IpcContext context, size_t index) {
    const ubyte[] raw = context.ReadInput(index);
    size_t length = 0;
    // pointer (x) bufs with nul pad
    while (length < raw.length && raw[length] != 0) {
        length++;
    }
    return (cast(const(char)[]) raw[0 .. length]).idup;
}

// Services
final class FileSystemProxyService : IPCService {
    private SwitchStorage storage;
    private ulong programId;

    this(SwitchStorage storage, ulong programId) {
        this.storage = storage;
        this.programId = programId;
        Command(1, "SetCurrentProcess", &Succeed);
        Command(11, "OpenBisFileSystem", &OpenBisFileSystem);
        Command(18, "OpenSdCardFileSystem", &OpenSdCardFileSystem);
        Command(22, "CreateSaveDataFileSystem", &CreateSaveDataFileSystem);
        Command(23, "CreateSaveDataFileSystemBySystemSaveDataId", &CreateSaveDataFileSystem);
        Command(51, "OpenSaveDataFileSystem", &OpenSaveDataFileSystem);
        Command(52, "OpenSaveDataFileSystemBySystemSaveDataId", &OpenSaveDataFileSystem);
        Command(53, "OpenReadOnlySaveDataFileSystem", &OpenSaveDataFileSystem);
        Stub(200, "OpenDataStorageByCurrentProcess"); // game romfs
        Command(1003, "DisableAutoSaveDataCreation", &Succeed);
        Command(1005, "GetGlobalAccessLogMode", &GetGlobalAccessLogMode);
        Command(1006, "OutputAccessLogToSdCard", &Succeed);

        // todo: savedata info
    }

    override string Name() const {
        return "fsp-srv";
    }

    private void OpenSdCardFileSystem(IpcContext context) {
        context.PushInterface(new FileSystemService(storage.SdCard));
    }

    private void OpenBisFileSystem(IpcContext context) {
        const uint partition = context.Pop!uint();
        HostFileSystem fileSystem = storage.Partition(partition);
        if (fileSystem is null) {
            Log.Stub("OpenBisFileSystem: partition %d is not supported yet.", partition);
            context.Result(FsResult.UnsupportedOperation);
            return;
        }
        context.PushInterface(new FileSystemService(fileSystem));
    }

    private void CreateSaveDataFileSystem(IpcContext context) {
        const SaveDataAttribute attribute = context.Pop!SaveDataAttribute();
        const ubyte[0x40] creation = context.Pop!(ubyte[0x40])();
        context.Result(storage.CreateSaveData(creation[0x24], attribute, programId));
    }

    private void OpenSaveDataFileSystem(IpcContext context) {
        const ubyte spaceId = context.Pop!ubyte();
        const SaveDataAttribute attribute = context.Pop!SaveDataAttribute();
        HostFileSystem fileSystem;
        const uint result = storage.OpenSaveData(spaceId, attribute, programId, fileSystem);
        if (result != ResultSuccess) {
            context.Result(result);
            return;
        }
        context.PushInterface(new FileSystemService(fileSystem));
    }

    private void GetGlobalAccessLogMode(IpcContext context) {
        context.Push!uint(0);
    }
}

final class FileSystemService : IPCService {
    private HostFileSystem fileSystem;

    this(HostFileSystem fileSystem) {
        this.fileSystem = fileSystem;
        Command(0, "CreateFile", &CreateFile);
        Command(1, "DeleteFile", &DeleteFile);
        Command(2, "CreateDirectory", &CreateDirectory);
        Command(3, "DeleteDirectory", &DeleteDirectory);
        Command(4, "DeleteDirectoryRecursively", &DeleteDirectoryRecursively);
        Command(5, "RenameFile", &RenameFile);
        Command(6, "RenameDirectory", &RenameDirectory);
        Command(7, "GetEntryType", &GetEntryType);
        Command(8, "OpenFile", &OpenFile);
        Command(9, "OpenDirectory", &OpenDirectory);
        Command(10, "Commit", &Commit);
        Command(11, "GetFreeSpaceSize", &GetFreeSpaceSize);
        Command(12, "GetTotalSpaceSize", &GetTotalSpaceSize);
        Command(13, "CleanDirectoryRecursively", &CleanDirectoryRecursively);
        Command(14, "GetFileTimeStampRaw", &GetFileTimeStampRaw);
    }

    override string Name() const {
        return "fs::IFileSystem(" ~ fileSystem.Label ~ ")";
    }

    private void CreateFile(IpcContext context) {
        context.Pop!uint();
        const long size = context.Pop!long();
        context.Result(fileSystem.CreateFile(PathArgument(context, 0), size < 0 ? 0 : size));
    }

    private void DeleteFile(IpcContext context) {
        context.Result(fileSystem.DeleteFile(PathArgument(context, 0)));
    }

    private void CreateDirectory(IpcContext context) {
        context.Result(fileSystem.CreateDirectory(PathArgument(context, 0)));
    }

    private void DeleteDirectory(IpcContext context) {
        context.Result(fileSystem.DeleteDirectory(PathArgument(context, 0), false));
    }

    private void DeleteDirectoryRecursively(IpcContext context) {
        context.Result(fileSystem.DeleteDirectory(PathArgument(context, 0), true));
    }

    private void RenameFile(IpcContext context) {
        context.Result(fileSystem.Rename(PathArgument(context, 0), PathArgument(context, 1), false));
    }

    private void RenameDirectory(IpcContext context) {
        context.Result(fileSystem.Rename(PathArgument(context, 0), PathArgument(context, 1), true));
    }

    private void GetEntryType(IpcContext context) {
        FsEntryType type;
        const uint result = fileSystem.EntryType(PathArgument(context, 0), type);
        context.Result(result);
        if (result == ResultSuccess) {
            context.Push!uint(type);
        }
    }

    private void OpenFile(IpcContext context) {
        const uint mode = context.Pop!uint();
        const string path = PathArgument(context, 0);
        FsEntryType type;
        uint result = fileSystem.EntryType(path, type);
        if (result == ResultSuccess && type != FsEntryType.File) {
            result = FsResult.PathNotFound;
        }
        if (result != ResultSuccess) {
            context.Result(result);
            return;
        }
        context.PushInterface(new FileService(fileSystem, path, mode));
    }

    private void OpenDirectory(IpcContext context) {
        const uint filter = context.Pop!uint();
        const string path = PathArgument(context, 0);
        FsEntry[] entries;
        const uint result = fileSystem.List(path, filter, entries);
        if (result != ResultSuccess) {
            context.Result(result);
            return;
        }
        context.PushInterface(new DirectoryService(entries));
    }

    private void Commit(IpcContext context) {
    }

    private void GetFreeSpaceSize(IpcContext context) {
        context.Push!long(fileSystem.FreeSpace);
    }

    private void GetTotalSpaceSize(IpcContext context) {
        context.Push!long(fileSystem.TotalSpace);
    }

    private void CleanDirectoryRecursively(IpcContext context) {
        context.Result(fileSystem.CleanDirectory(PathArgument(context, 0)));
    }

    private void GetFileTimeStampRaw(IpcContext context) {
        FsTimeStamp stamp;
        const uint result = fileSystem.TimeStamp(PathArgument(context, 0), stamp);
        context.Result(result);
        if (result == ResultSuccess) {
            context.Push(FsTimeStampRaw(stamp.Created, stamp.Modified, stamp.Accessed, 1));
        }
    }
}

final class FileService : IPCService {
    private HostFileSystem fileSystem;
    private string path;
    private uint mode; // todo: enforce modes (like readonly)

    this(HostFileSystem fileSystem, string path, uint mode) {
        this.fileSystem = fileSystem;
        this.path = path;
        this.mode = mode;
        Command(0, "Read", &Read);
        Command(1, "Write", &Write);
        Command(2, "Flush", &Flush);
        Command(3, "SetSize", &SetSize);
        Command(4, "GetSize", &GetSize);
    }

    override string Name() const {
        return "fs::IFile";
    }

    private void Read(IpcContext context) {
        context.Pop!uint();
        const long offset = context.Pop!long();
        const long size = context.Pop!long();
        if (offset < 0 || size < 0) {
            context.Result(FsResult.InvalidOffset);
            return;
        }
        ubyte[] data = new ubyte[min(cast(size_t) size, context.OutputSize(0))];
        size_t read;
        const uint result = fileSystem.Read(path, offset, data, read);
        context.Result(result);
        if (result != ResultSuccess) {
            return;
        }
        context.WriteOutput(0, data[0 .. read]);
        context.Push!long(read);
    }

    private void Write(IpcContext context) {
        context.Pop!uint();
        const long offset = context.Pop!long();
        const long size = context.Pop!long();
        if (offset < 0 || size < 0) {
            context.Result(FsResult.InvalidOffset);
            return;
        }
        const ubyte[] data = context.ReadInput(0);
        context.Result(fileSystem.Write(path, offset, data[0 .. min(cast(size_t) size, data.length)]));
    }

    private void Flush(IpcContext context) {
    }

    private void SetSize(IpcContext context) {
        const long size = context.Pop!long();
        context.Result(fileSystem.SetSize(path, size < 0 ? 0 : size));
    }

    private void GetSize(IpcContext context) {
        ulong size;
        const uint result = fileSystem.FileSize(path, size);
        context.Result(result);
        if (result == ResultSuccess) {
            context.Push!long(size);
        }
    }
}

final class DirectoryService : IPCService {
    private FsEntry[] entries; // entries are only captured as a snapshot on open
    private size_t position;

    this(FsEntry[] entries) {
        this.entries = entries;
        Command(0, "Read", &Read);
        Command(1, "GetEntryCount", &GetEntryCount);
    }

    override string Name() const {
        return "fs::IDirectory";
    }

    private void Read(IpcContext context) {
        const size_t capacity = context.OutputSize(0) / DirectoryEntrySize;
        const size_t count = min(capacity, entries.length - position);
        ubyte[] buffer = new ubyte[count * DirectoryEntrySize];
        foreach (i; 0 .. count) {
            const FsEntry entry = entries[position + i];
            ubyte[] slot = buffer[i * DirectoryEntrySize .. (i + 1) * DirectoryEntrySize];
            const size_t nameLength = min(entry.Name.length, 0x300);
            slot[0 .. nameLength] = cast(const(ubyte)[]) entry.Name[0 .. nameLength];
            slot[0x304] = cast(ubyte) entry.Type;
            *cast(ulong*) (slot.ptr + 0x308) = entry.Size;
        }
        position += count;
        context.WriteOutput(0, buffer);
        context.Push!long(count);
    }

    private void GetEntryCount(IpcContext context) {
        context.Push!long(entries.length);
    }
}
