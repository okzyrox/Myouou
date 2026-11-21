/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loads NSO executables into memory
*/

module Source.Loader.NSOLoader;

// Std
import std.path : baseName, stripExtension;
import std.stdio;

// Core
import Source.Format.NSO;
import Source.Kernel.Kernel;
import Source.Loader.Executable;
import Source.Loader.NROLoader : Layout;
import Source.Memory.Guest;

// Utils
private size_t AlignPage(size_t value) {
    return (value + GuestPageSize - 1) & ~(GuestPageSize - 1);
}

private void MapSegment(GuestMemory memory, NSOFile nso, NSOSegmentKind kind, ulong base, size_t extra, MemoryPermission permission, string name, MemoryType type) {
    const NSOSegment segment = nso.Layout(kind);
    const size_t size = AlignPage(segment.Size + extra);
    if (size == 0) {
        return;
    }
    memory.Map(base + segment.MemoryOffset, size, permission, name, type);
    memory.WriteBytes(base + segment.MemoryOffset, nso.Segment(kind));
}

// Class
// todo: a single module only, no rtld/subsdk/sdk or npdm process settings yet
final class NSOExecutable : Executable {
    private string path;
    private NSOFile nso;

    this(string path) {
        this.path = path;
        nso = NSOFile.Load(path);
    }

    static bool Matches(const(ubyte)[] header) {
        return header.length >= uint.sizeof && *cast(const(uint)*) header.ptr == NSOMagic;
    }

    static Executable Open(string path) {
        return new NSOExecutable(path);
    }

    enum string Name = "NSO";
    enum string Extension = ".nso";

    string FormatName() const {
        return Name;
    }

    string FormatExtension() const {
        return Extension;
    }

    string TitleKey() const {
        string key;
        foreach (c; stripExtension(baseName(path))) {
            key ~= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ? c : '_';
        }
        return key.length != 0 ? key : "nso";
    }

    void Describe() {
        const NSOHeader header = nso.Header;
        writefln("NSO Version %d, flags 0x%X", header.Version, header.Flags);
        foreach (kind; [NSOSegmentKind.Text, NSOSegmentKind.Ro, NSOSegmentKind.Data]) {
            const NSOSegment segment = nso.Layout(kind);
            writefln("Section: %-5s 0x%06X size 0x%06X (file 0x%06X)", kind, segment.MemoryOffset, segment.Size, segment.FileOffset);
        }
        writefln("Bss 0x%X, module id %s", header.BssSize, nso.ModuleIdHex);
    }

    ProgramEntry Load(GuestMemory memory, HorizonKernel kernel) {
        Layout layout;
        const ulong base = layout.ImgBase;
        MapSegment(memory, nso, NSOSegmentKind.Text, base, 0, MemoryPermission.ReadExecute, ".text", MemoryType.Code);
        MapSegment(memory, nso, NSOSegmentKind.Ro, base, 0, MemoryPermission.Read, ".rodata", MemoryType.Code);
        MapSegment(memory, nso, NSOSegmentKind.Data, base, nso.BssSize, MemoryPermission.ReadWrite, ".data", MemoryType.CodeData);
        memory.Map(layout.StackBase, layout.StackSize, MemoryPermission.ReadWrite, "Stack", MemoryType.Stack);
        memory.Map(layout.TlsBase, GuestPageSize, MemoryPermission.ReadWrite, "Tls", MemoryType.ThreadLocal);
        writefln("Loaded 0x%X, 0x%X. top 0x%X", base, base + nso.Layout(NSOSegmentKind.Text).MemoryOffset, layout.StackBase + layout.StackSize);

        return ProgramEntry(base + nso.Layout(NSOSegmentKind.Text).MemoryOffset, layout.StackBase + layout.StackSize, layout.TlsBase, layout.ReturnAddress, [0, layout.MainThreadHandle]);
    }
}
