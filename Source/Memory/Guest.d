/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * The guest memory
*/

module Source.Memory.Guest;

// Std
import std.format : format;

version (Windows) {
    import core.sys.windows.winbase : VirtualAlloc, VirtualFree;
    import core.sys.windows.winnt : MEM_COMMIT, MEM_DECOMMIT, MEM_RESERVE, PAGE_READWRITE;
} else version (Posix) {
    import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;
}

enum size_t GuestPageSize = 0x1000;
enum size_t HostPagesLimit = 0x10_0000;

// Types
enum MemoryPermission : ubyte {
    None = 0,
    Read = 1,
    Write = 2,
    Execute = 4,
    ReadWrite = Read | Write,
    ReadExecute = Read | Execute,
}

enum MemoryAccess {
    Read,
    Write,
    Execute,
}

enum MemoryType : uint {
    Free = 0x00,
    Io = 0x01,
    Static = 0x02,
    Code = 0x03,
    CodeData = 0x04,
    Normal = 0x05,
    Shared = 0x06,
    Alias = 0x07,
    AliasCode = 0x08,
    AliasCodeData = 0x09,
    Ipc = 0x0A,
    Stack = 0x0B,
    ThreadLocal = 0x0C,
    Transfered = 0x0D,
    SharedTransfered = 0x0E,
    SharedCode = 0x0F,
    Inaccessible = 0x10,
    NonSecureIpc = 0x11,
    NonDeviceIpc = 0x12,
    Kernel = 0x13,
    GeneratedCode = 0x14,
    CodeOut = 0x15
}

struct MemoryQuery {
    ulong Base;
    ulong Size;
    MemoryType MemType;
    uint Attribute;
    MemoryPermission Permission;
}

class GuestMemoryError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

class GuestMemoryFault : GuestMemoryError {
    ulong Address;
    size_t Size;
    MemoryAccess Access;

    this(ulong address, size_t size, MemoryAccess access, string file = __FILE__, size_t line = __LINE__) {
        Address = address;
        Size = size;
        Access = access;
        super(format("Guest memory error!. %s of %d bytes at 0x%X", access, size, address), file, line);
    }
}

// Host Pages
private ubyte[] AllocateHostPages(size_t size) {
    void* pointer;
    version (Windows) {
        pointer = VirtualAlloc(null, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    } else version (Posix) {
        pointer = mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (pointer == MAP_FAILED) {
            pointer = null;
        }
    }
    if (pointer is null) {
        throw new GuestMemoryError(format("Host couldnt allocate 0x%X bytes of guest memory!", size));
    }
    return (cast(ubyte*) pointer)[0 .. size];
}

private void ReleaseHostPages(ubyte[] bytes) {
    version (Windows) {
        VirtualFree(bytes.ptr, bytes.length, MEM_DECOMMIT);
    } else version (Posix) {
        munmap(bytes.ptr, bytes.length);
    }
}

// Classes
final class MemoryRegion {
    MemoryPermission Permission;
    MemoryType MemType;
    uint Attribute;
    ulong Base;
    string Name;
    ubyte[] Bytes;
    bool HostPages;

    this(ulong base, size_t size, MemoryPermission permission, string name, MemoryType memType = MemoryType.Normal) {
        const bool hostPages = size >= HostPagesLimit;
        // Page allocation helps with using "less" ram (by reserving it ahead of time with commited stuff)
        this(base, hostPages ? AllocateHostPages(size) : new ubyte[size], permission, name, memType);
        HostPages = hostPages;
    }

    this(ulong base, ubyte[] bytes, MemoryPermission permission, string name, MemoryType memType = MemoryType.Normal) {
        Base = base;
        Bytes = bytes;
        Permission = permission;
        Name = name;
        MemType = memType;
    }

    ulong End() const nothrow @nogc @safe {
        return Base + Bytes.length;
    }

    bool Contains(ulong address, size_t size) const nothrow @nogc @safe {
        return address >= Base && size <= Bytes.length && address - Base <= Bytes.length - size;
    }
}

final class GuestMemory {
    private MemoryRegion[] regions;
    private MemoryRegion previousRegion;

    MemoryRegion Map(ulong base, size_t size, MemoryPermission permission, string name, MemoryType memType = MemoryType.Normal) {
        CheckMappable(base, size, name);
        return Insert(new MemoryRegion(base, size, permission, name, memType));
    }

    MemoryRegion MapBacked(ulong base, ubyte[] bytes, MemoryPermission permission, string name, MemoryType memType) {
        CheckMappable(base, bytes.length, name);
        return Insert(new MemoryRegion(base, bytes, permission, name, memType));
    }

    bool IsFree(ulong base, size_t size) const nothrow @nogc {
        foreach (region; regions)
            if (region.Base < base + size && base < region.End())
                return false;
        return true;
    }

    bool IsMapped(ulong base, size_t size) nothrow @nogc {
        ulong address = base;
        while (address < base + size) {
            MemoryRegion region = Find(address);
            if (region is null)
                return false;
            address = region.End();
        }
        return true;
    }

    MemoryRegion[] Isolate(ulong base, size_t size) {
        if (size == 0 || !IsMapped(base, size))
            return null;

        SplitAt(base);
        SplitAt(base + size);

        MemoryRegion[] found;
        foreach (region; regions)
            if (region.Base >= base && region.End() <= base + size)
                found ~= region;
        return found;
    }

    bool Unmap(ulong base, size_t size) {
        MemoryRegion[] found = Isolate(base, size);
        if (found is null)
            return false;

        MemoryRegion[] kept;
        foreach (region; regions)
            if (region.Base < base || region.End() > base + size)
                kept ~= region;
        regions = kept;
        foreach (region; found) {
            if (region.HostPages) {
                ReleaseHostPages(region.Bytes);
            }
        }
        previousRegion = null;
        return true;
    }

    bool Protect(ulong base, size_t size, MemoryPermission permission) {
        MemoryRegion[] found = Isolate(base, size);
        if (found is null)
            return false;
        foreach (region; found)
            region.Permission = permission;
        return true;
    }

    bool SetAttribute(ulong base, size_t size, uint mask, uint value) {
        MemoryRegion[] found = Isolate(base, size);
        if (found is null)
            return false;
        foreach (region; found)
            region.Attribute = (region.Attribute & ~mask) | (value & mask);
        return true;
    }

    MemoryQuery Query(ulong address, ulong addressSpaceEnd) const nothrow @nogc {
        if (address >= addressSpaceEnd)
            return MemoryQuery(addressSpaceEnd, 0 - addressSpaceEnd, MemoryType.Inaccessible, 0, MemoryPermission.None);

        size_t memI = 0;
        while (memI < regions.length && regions[memI].End() <= address)
            memI++;

        if (memI == regions.length || regions[memI].Base > address) {
            const ulong start = memI == 0 ? 0 : regions[memI - 1].End();
            const ulong end = memI == regions.length ? addressSpaceEnd : regions[memI].Base;
            return MemoryQuery(start, end - start, MemoryType.Free, 0, MemoryPermission.None);
        }

        const MemoryRegion region = regions[memI];
        size_t first = memI;
        while (first > 0 && Coalesces(regions[first - 1], regions[first]))
            first--;
        size_t last = memI;
        while (last + 1 < regions.length && Coalesces(regions[last], regions[last + 1]))
            last++;

        const ulong start = regions[first].Base;
        return MemoryQuery(start, regions[last].End() - start, region.MemType, region.Attribute, region.Permission);
    }

    private static bool Coalesces(const MemoryRegion left, const MemoryRegion right) nothrow @nogc {
        return left.End() == right.Base && left.MemType == right.MemType && left.Permission == right.Permission && left.Attribute == right.Attribute;
    }

    private void CheckMappable(ulong base, size_t size, string name) {
        if (base % GuestPageSize != 0 || size == 0 || size % GuestPageSize != 0)
            throw new GuestMemoryError(format("Page of Region %s at 0x%X (0x%X bytes) is not aligned!", name, base, size));
        if (!IsFree(base, size))
            throw new GuestMemoryError(format("Region %s at 0x%X (0x%X bytes) is overlapping existing map!", name, base, size));
    }

    private MemoryRegion Insert(MemoryRegion reg) {
        size_t regI = 0;
        while (regI < regions.length && regions[regI].Base < reg.Base)
            regI++;
        regions = regions[0 .. regI] ~ reg ~ regions[regI .. $];
        previousRegion = null;
        return reg;
    }

    private void SplitAt(ulong address) {
        foreach (i, region; regions) {
            if (region.Base >= address || address >= region.End())
                continue;

            const size_t offset = cast(size_t) (address - region.Base);
            MemoryRegion upper = new MemoryRegion(address, region.Bytes[offset .. $], region.Permission, region.Name, region.MemType);
            upper.Attribute = region.Attribute;
            upper.HostPages = region.HostPages;
            region.Bytes = region.Bytes[0 .. offset];
            regions = regions[0 .. i + 1] ~ upper ~ regions[i + 1 .. $];
            previousRegion = null;
            return;
        }
    }

    const(MemoryRegion)[] Regions() const nothrow @nogc {
        return regions;
    }

    MemoryRegion Find(ulong address) nothrow @nogc {
        if (previousRegion !is null && previousRegion.Contains(address, 1))
            return previousRegion;

        size_t low = 0;
        size_t high = regions.length;
        while (low < high) {
            const size_t mid = (low + high) / 2;
            MemoryRegion foundRegion = regions[mid];
            if (address < foundRegion.Base)
                high = mid;
            else if (address >= foundRegion.End())
                low = mid + 1;
            else {
                previousRegion = foundRegion;
                return foundRegion;
            }
        }
        return null;
    }

    ubyte* Translate(ulong address, size_t size, MemoryPermission required) nothrow @nogc {
        MemoryRegion foundRegion = Find(address);
        if (foundRegion is null || !foundRegion.Contains(address, size))
            return null;
        if ((foundRegion.Permission & required) != required)
            return null;
        return foundRegion.Bytes.ptr + (address - foundRegion.Base);
    }

    T Read(T)(ulong address) {
        ubyte* pointer = Translate(address, T.sizeof, MemoryPermission.Read);
        if (pointer !is null)
            return *cast(T*) pointer;

        T value;
        ReadOverSpan(address, (cast(ubyte*) &value)[0 .. T.sizeof], MemoryPermission.Read, MemoryAccess.Read);
        return value;
    }

    void Write(T)(ulong address, T value) {
        ubyte* pointer = Translate(address, T.sizeof, MemoryPermission.Write);
        if (pointer !is null) {
            *cast(T*) pointer = value;
            return;
        }

        WriteOverSpan(address, (cast(const(ubyte)*) &value)[0 .. T.sizeof], MemoryPermission.Write, MemoryAccess.Write);
    }

    bool TryFetch(ulong address, out uint instruction) nothrow @nogc {
        ubyte* pointer = Translate(address, uint.sizeof, MemoryPermission.Execute);
        if (pointer is null)
            return false;
        instruction = *cast(uint*) pointer;
        return true;
    }

    void ReadBytes(ulong address, ubyte[] destination) {
        ReadOverSpan(address, destination, MemoryPermission.None, MemoryAccess.Read);
    }

    void WriteBytes(ulong address, const(ubyte)[] source) {
        WriteOverSpan(address, source, MemoryPermission.None, MemoryAccess.Write);
    }

    private void ReadOverSpan(ulong address, ubyte[] destination, MemoryPermission required, MemoryAccess access) {
        size_t done = 0;
        while (done < destination.length) {
            ubyte[] chunk = GetChunk(address + done, destination.length - done, required, access, destination.length);
            destination[done .. done + chunk.length] = chunk[];
            done += chunk.length;
        }
    }

    private void WriteOverSpan(ulong address, const(ubyte)[] source, MemoryPermission required, MemoryAccess access) {
        size_t done = 0;
        while (done < source.length) {
            ubyte[] chunk = GetChunk(address + done, source.length - done, required, access, source.length);
            chunk[] = source[done .. done + chunk.length];
            done += chunk.length;
        }
    }

    private ubyte[] GetChunk(ulong address, size_t remaining, MemoryPermission required, MemoryAccess access, size_t totalSize) {
        MemoryRegion foundRegion = Find(address);
        if (foundRegion is null || (foundRegion.Permission & required) != required)
            throw new GuestMemoryFault(address, totalSize, access);

        const size_t offset = cast(size_t) (address - foundRegion.Base);
        const size_t available = foundRegion.Bytes.length - offset;
        const size_t length = remaining < available ? remaining : available;
        return foundRegion.Bytes[offset .. offset + length];
    }
}
