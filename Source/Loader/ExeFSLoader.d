/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loads an ExeFS folder into memory
*/

module Source.Loader.ExeFSLoader;

// Std
import std.file : exists, isDir, isFile, read;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.stdio;

// Core
import Source.Format.NPDM;
import Source.Format.NSO;
import Source.Kernel.Kernel;
import Source.Loader.Executable;
import Source.Loader.NROLoader : Layout;
import Source.Loader.NSOLoader;
import Source.Memory.Guest;

// Types
immutable string[] ExeFSModuleNames = [
    // In most titles.
    "rtld", 
    "main", 
    // Usually in game titles only.
    "subsdk0", "subsdk1", "subsdk2", "subsdk3", "subsdk4", "subsdk5", "subsdk6", "subsdk7", "subsdk8", "subsdk9",
    // In most titles as well.
    "sdk",
];
enum string NPDMFileName = "main.npdm";
enum ulong ExeFSCodeBase = 0x0800_0000;
enum ulong ExeFSTlsOffset = 0x4000_0000;
enum size_t DefaultMainStackSize = 0x10_0000;

struct ExeFSModule {
    string Name;
    NSOFile Image;
}

interface ExeFSSource {
    string Label() const;
    bool Has(string name);
    const(ubyte)[] Read(string name);
}

final class FolderSource : ExeFSSource {
    private string folder;

    this(string folder) {
        this.folder = folder;
    }

    string Label() const {
        return folder;
    }

    bool Has(string name) {
        const string path = buildPath(folder, name);
        return exists(path) && isFile(path);
    }

    const(ubyte)[] Read(string name) {
        return cast(const(ubyte)[]) read(buildPath(folder, name));
    }
}

// Class
final class ExeFSExecutable : Executable {
    enum string Name = "ExeFS";
    enum string Extension = ".npdm";

    private ExeFSSource source;
    private string formatName;
    private string formatExtension;
    private NPDMFile npdm;
    private ExeFSModule[] modules;

    this(string folder) {
        this(new FolderSource(folder), Name, Extension);
    }

    this(ExeFSSource source, string formatName, string formatExtension) {
        this.source = source;
        this.formatName = formatName;
        this.formatExtension = formatExtension;
        if (source.Has(NPDMFileName)) {
            npdm = new NPDMFile(source.Read(NPDMFileName));
        }
        bool hasMain = false;
        foreach (name; ExeFSModuleNames) {
            if (!source.Has(name)) {
                continue;
            }
            ExeFSModule loadedModule = ExeFSModule(name, new NSOFile(source.Read(name)));
            writefln("Loaded ExeFS module: %s.", loadedModule.Name);
            modules ~= loadedModule;
            hasMain |= name == "main";
        }
        if (!hasMain) {
            throw new ExecutableError("ExeFS has no main module: " ~ source.Label);
        }
    }

    static bool Matches(const(ubyte)[] header) {
        return header.length >= uint.sizeof && *cast(const(uint)*) header.ptr == NPDMMagic;
    }

    static bool MatchesFolder(string path) {
        return isDir(path) && exists(buildPath(path, "main"));
    }

    static Executable Open(string path) {
        return new ExeFSExecutable(isDir(path) ? path : dirName(path));
    }

    string FormatName() const {
        return formatName;
    }

    string FormatExtension() const {
        return formatExtension;
    }

    string TitleKey() const {
        if (npdm !is null) {
            return format("%016X", npdm.ProgramId);
        }
        string key;
        foreach (c; baseName(source.Label)) {
            key ~= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ? c : '_';
        }
        return key.length != 0 ? key : "exefs";
    }

    void Describe() {
        if (npdm !is null) {
            writefln("NPDM file: '%s', program %016X.", npdm.Name, npdm.ProgramId);
        } else {
            writefln("Unknown: %s!", NPDMFileName);
        }
        foreach (ref module_; modules) {
            writefln("%-2s Module %-10s | module id %s", "", module_.Name, module_.Image.ModuleIdHex);
        }
    }

    ProgramEntry Load(GuestMemory memory, HorizonKernel kernel) {
        Layout layout;
        size_t stackSize = DefaultMainStackSize;
        if (npdm !is null) {
            if (npdm.AddressSpace != AddressSpaceType.Bits39 || !npdm.Is64Bit) {
                // todo
                writefln("Warn: Unsupported address space for ExeFS (%s)!", npdm.AddressSpace);
            }
            kernel.ProgramId = npdm.ProgramId;
            kernel.Applet.ProgramId = npdm.ProgramId;
            kernel.Threading.Current.Priority = npdm.MainThreadPriority;
            if (npdm.MainThreadStackSize != 0) {
                stackSize = AlignPage(npdm.MainThreadStackSize);
            }
        }

        ulong next = ExeFSCodeBase;
        foreach (ref module_; modules) {
            const size_t size = MapNSOModule(memory, module_.Image, next, module_.Name);
            writefln("Loaded %-8s at 0x%X (0x%X bytes).", module_.Name, next, size);
            next += size;
        }

        const ulong stackBase = kernel.Space.StackBase;
        const ulong tlsBase = kernel.Space.StackBase + ExeFSTlsOffset;
        memory.Map(stackBase, stackSize, MemoryPermission.ReadWrite, "Stack", MemoryType.Stack);
        memory.Map(tlsBase, GuestPageSize, MemoryPermission.ReadWrite, "Tls", MemoryType.ThreadLocal);

        const ulong entry = ExeFSCodeBase + modules[0].Image.Layout(NSOSegmentKind.Text).MemoryOffset;
        return ProgramEntry(entry, stackBase + stackSize, tlsBase, layout.ReturnAddress, [0, DefaultMainThreadHandle]);
    }
}
