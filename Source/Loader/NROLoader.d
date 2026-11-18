/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Loads NRO executables into memory
*/

module Source.Loader.NROLoader;

// Core
import Source.Emulator.GuestEnv;
import Source.Format.NRO;
import Source.Memory.Guest;
import Source.Wrapper.DynarmicJit;

// Types
enum HomebrewEntryType : uint {
    EndOfList = 0,
    MainThreadHandle = 1,
    NextLoadPath = 2,
    OverrideHeap = 3,
    OverrideService = 4,
    Argv = 5,
    SyscallAvailableHint = 6,
    AppletType = 7,
}

struct ConfigEntry {
    uint Key;
    uint Flags;
    ulong[2] Value;
}

struct Layout {
    ulong ImgBase = 0x0800_0000;
    ulong ReturnAddress = 0x0F00_0000;
    ulong StackBase = 0x1000_0000;
    size_t StackSize = 0x10_0000;
    ulong ContextBase = 0x1E00_0000;
    ulong TlsBase = 0x1F00_0000;
    ulong HeapBase = 0x2000_0000;
    size_t HeapSize = 0x200_0000;
    ulong MainThreadHandle = 0xF001;
    string Argv = "";
}

struct NROData {
    ulong ImgBase;
    size_t ImageSize;
    ulong EntryPoint;
    ulong StackTop;
    ulong TlsAddress;
    ulong ContextAddress;
    ulong HeapBase;
    size_t HeapSize;
    ulong ReturnAddress;
    ulong MainThreadHandle;
}

// Utils
private void MapMemorySegment(GuestMemory memory, NROFile nro, NROSegmentKind kind, ulong base, MemoryPermission permission, string id, MemoryType state) {
    const NROSegment segment = nro.Header.Segments[kind];
    if (segment.Size == 0)
        return;
    memory.Map(base + segment.FileOffset, segment.Size, permission, id, state);
    memory.WriteBytes(base + segment.FileOffset, nro.Segment(kind));
}

private void WriteContents(GuestMemory memory, in Layout layout) {
    const ulong argvAddress = layout.ContextBase + (GuestPageSize / 2);

    ConfigEntry[] entries = [
        ConfigEntry(HomebrewEntryType.MainThreadHandle, 1, [layout.MainThreadHandle, 0]),
        ConfigEntry(HomebrewEntryType.OverrideHeap, 1, [layout.HeapBase, layout.HeapSize]),
        ConfigEntry(HomebrewEntryType.Argv, 0, [0, argvAddress]),
        ConfigEntry(HomebrewEntryType.EndOfList, 0, [0, 0]),
    ];

    memory.WriteBytes(layout.ContextBase, cast(const(ubyte)[]) entries);
    memory.WriteBytes(argvAddress, cast(const(ubyte)[]) (layout.Argv ~ '\0'));
}

// Functions
NROData LoadNROToMemory(GuestMemory memory, NROFile nro, Layout layout = Layout.init) {
    const NROHeader header = nro.Header;
    const ulong base = layout.ImgBase;

    MapMemorySegment(memory, nro, NROSegmentKind.Text, base, MemoryPermission.ReadExecute, ".text", MemoryType.Code);
    MapMemorySegment(memory, nro, NROSegmentKind.Ro, base, MemoryPermission.Read, ".rodata", MemoryType.Code);

    const NROSegment data = header.Segments[NROSegmentKind.Data];
    memory.Map(base + data.FileOffset, data.Size + nro.BssSize, MemoryPermission.ReadWrite, ".data", MemoryType.CodeData);
    memory.WriteBytes(base + data.FileOffset, nro.Data);

    memory.Map(layout.StackBase, layout.StackSize, MemoryPermission.ReadWrite, "Stack", MemoryType.Stack);
    memory.Map(layout.TlsBase, GuestPageSize, MemoryPermission.ReadWrite, "Tls", MemoryType.ThreadLocal);
    memory.Map(layout.HeapBase, layout.HeapSize, MemoryPermission.ReadWrite, "Heap");
    memory.Map(layout.ContextBase, GuestPageSize, MemoryPermission.ReadWrite, "LoaderContext");

    NROData nroData;
    nroData.ImgBase = base;
    nroData.ImageSize = nro.ImageSize;
    nroData.EntryPoint = base;
    nroData.StackTop = layout.StackBase + layout.StackSize;
    nroData.TlsAddress = layout.TlsBase;
    nroData.ContextAddress = layout.ContextBase;
    nroData.HeapBase = layout.HeapBase;
    nroData.HeapSize = layout.HeapSize;
    nroData.ReturnAddress = layout.ReturnAddress;
    nroData.MainThreadHandle = layout.MainThreadHandle;

    WriteContents(memory, layout);
    return nroData;
}

void LoadEntry(GuestEnvironment environment, DynarmicJit jit, in NROData loaded) {
    environment.TpidrroEl0 = loaded.TlsAddress;
    environment.TpidrEl0 = 0;
    environment.ReturnAddress = loaded.ReturnAddress;
    environment.Exited = false;

    ulong[31] registers;
    registers[0] = loaded.ContextAddress;
    registers[1] = ulong.max;
    registers[30] = loaded.ReturnAddress;
    jit.Registers(registers);
    jit.Sp = loaded.StackTop;
    jit.Pc = loaded.EntryPoint;
}