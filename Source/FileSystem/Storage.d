/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Emustorage in a sandbox fs
*/

module Source.FileSystem.Storage;

// Std
import std.array : replace;
import std.file : exists, getcwd, isDir, mkdirRecurse, read;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirSeparator;
import std.uni : toLower;

// Core
import Source.FileSystem.RomStorage;
import Source.FileSystem.HostFileSystem;
import Source.Kernel.Result;
import Source.Util.Logger;

// Types
enum string StorageFolder = "sandbox/fs";
enum string ShaderCacheFolder = "sandbox/shadercache";
enum string HomebrewFolder = "sdmc/switch"; // QoL alias

enum BisPartitionId : uint {
    UserDataRoot = 20,
    // 21-26 - BootConfigAndPackage
    CalibrationBinary = 27,
    CalibrationFile = 28,

    SafeMode = 29,
    User = 30,
    System = 31,
}

enum SaveDataSpaceId : ubyte {
    System = 0,
    User = 1,
    SdSystem = 2,
    Temporary = 3,
    SdUser = 4,
    ProperSystem = 100,
    SafeMode = 101,
}

enum SaveDataType : ubyte {
    System = 0,
    Account = 1,
    Bcat = 2,
    Device = 3,
    Temporary = 4,
    Cache = 5,
    SystemBcat = 6,
}

struct SaveDataAttribute {
    ulong ApplicationId;
    ulong[2] UserId;
    ulong SystemSaveDataId;
    SaveDataType Type;
    ubyte Rank;
    ushort Index;
    uint Padding;
    ulong[3] Reserved;
}

static assert(SaveDataAttribute.sizeof == 0x40);

// BIS
immutable string[] NandFolders = [
    "system/Contents/registered",
    "system/Contents/placehld",
    "user/Contents/registered",
    "user/Contents/placehld",
    "system/save",
    "user/save",
    "safe", // SafeMode partition
    "prodinfof", // CalibrationFile partition
];

immutable string[] SdCardFolders = [
    "switch", // temp
    "Nintendo/Contents/registered",
    "Nintendo/Contents/placehld",
    "Nintendo/save",
];

// Class
final class SwitchStorage {
    immutable string Root;
    HostFileSystem SdCard;
    RomStorage ProgramRomFS;

    private HostFileSystem[BisPartitionId] partitions;
    private Logger log;

    this(string root = buildPath(getcwd(), StorageFolder)) {
        Root = root;
        log = GetLogger("Storage");
        PrepareFolders("nand", NandFolders);
        PrepareFolders("sdmc", SdCardFolders);
        SdCard = new HostFileSystem(buildPath(root, "sdmc"), "sdmc");
        partitions[BisPartitionId.System] = new HostFileSystem(buildPath(root, "nand", "system"), "nand:system");
        partitions[BisPartitionId.User] = new HostFileSystem(buildPath(root, "nand", "user"), "nand:user");
        partitions[BisPartitionId.SafeMode] = new HostFileSystem(buildPath(root, "nand", "safe"), "nand:safe");
        partitions[BisPartitionId.CalibrationFile] = new HostFileSystem(buildPath(root, "nand", "prodinfof"), "nand:prodinfof");
        log.Info("Storage root %s (nand, sdmc)", root);
    }

    string ExposeToSDMC(string hostPath) {
        // Hacky fix for NRO loaded outside
        const string absolute = buildNormalizedPath(absolutePath(hostPath));
        const string sdRoot = buildNormalizedPath(SdCard.Root) ~ dirSeparator;
        string guestPath;
        if (absolute.length > sdRoot.length && absolute[0 .. sdRoot.length].toLower == sdRoot.toLower) {
            guestPath = "/" ~ absolute[sdRoot.length .. $].replace(dirSeparator, "/");
        } else {
            guestPath = "/switch/" ~ baseName(absolute);
            SdCard.MapFile(guestPath, absolute);
        }
        log.Info("Homebrew sdmc:%s", guestPath);
        return "sdmc:" ~ guestPath;
    }

    bool SaveDataFolder(ubyte spaceId, const ref SaveDataAttribute attribute, ulong currentProgram, out string folder) const {
        // Running program has id 0
        const ulong application = attribute.ApplicationId != 0 ? attribute.ApplicationId : currentProgram;
        const string user = format("%016X%016X", attribute.UserId[1], attribute.UserId[0]);
        string area;
        switch (spaceId) {
            case SaveDataSpaceId.System, SaveDataSpaceId.ProperSystem, SaveDataSpaceId.SafeMode:
                area = buildPath(Root, "nand", "system", "save");
                break;
            case SaveDataSpaceId.User:
                area = buildPath(Root, "nand", "user", "save");
                break;
            case SaveDataSpaceId.SdSystem, SaveDataSpaceId.SdUser:
                area = buildPath(Root, "sdmc", "Nintendo", "save");
                break;
            case SaveDataSpaceId.Temporary:
                folder = buildPath(Root, "nand", "user", "temp", format("%016X", application));
                return true;
            default:
                return false;
        }
        switch (attribute.Type) {
            case SaveDataType.System, SaveDataType.SystemBcat:
                folder = buildPath(area, format("%016X", attribute.SystemSaveDataId));
                return true;
            case SaveDataType.Account, SaveDataType.Device:
                folder = buildPath(area, user, format("%016X", application));
                return true;
            case SaveDataType.Bcat:
                folder = buildPath(area, "bcat", format("%016X", application));
                return true;
            case SaveDataType.Cache:
                folder = buildPath(area, "cache", format("%016X", application), format("%d", attribute.Index));
                return true;
            default:
                return false;
        }
    }

    uint CreateSaveData(ubyte spaceId, const ref SaveDataAttribute attribute, ulong currentProgram) {
        string folder;
        if (!SaveDataFolder(spaceId, attribute, currentProgram, folder)) {
            return FsResult.InvalidPath;
        }
        if (exists(folder)) {
            return FsResult.PathAlreadyExists;
        }
        mkdirRecurse(folder);
        log.Info("Created save data %s", folder);
        return ResultSuccess;
    }

    uint OpenSaveData(ubyte spaceId, const ref SaveDataAttribute attribute, ulong currentProgram, out HostFileSystem fileSystem) {
        string folder;
        if (!SaveDataFolder(spaceId, attribute, currentProgram, folder)) {
            return FsResult.InvalidPath;
        }
        if (!exists(folder) || !isDir(folder)) {
            return FsResult.TargetNotFound;
        }
        fileSystem = new HostFileSystem(folder, format("save:%016X", attribute.ApplicationId != 0 ? attribute.ApplicationId : currentProgram));
        return ResultSuccess;
    }

    ubyte[] ProfileImage(string userHex) const {
        // May change later.
        const string path = buildPath(Root, "nand", "system", "save", "8000000000000010", "su", "avators", userHex ~ ".jpg");
        if (!exists(path)) {
            return null;
        }
        return cast(ubyte[]) read(path);
    }

    HostFileSystem Partition(uint id) {
        HostFileSystem* found = cast(BisPartitionId) id in partitions;
        return found is null ? null : *found;
    }

    private void PrepareFolders(string name, const(string)[] folders) {
        foreach (folder; folders) {
            const string path = buildPath(Root, name, folder);
            if (!exists(path)) {
                mkdirRecurse(path);
            }
        }
    }
}
