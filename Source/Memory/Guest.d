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


enum size_t GuestPageSize = 0x1000;

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

// Classes
final class MemoryRegion {
    MemoryPermission Permission;
    ulong Base;
    string Name;
    ubyte[] Bytes;

    this(ulong base, size_t size, MemoryPermission permission, string name) {
        Base = base;
        Bytes = new ubyte[size];
        Permission = permission;
        Name = name;
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

    MemoryRegion Map(ulong base, size_t size, MemoryPermission permission, string name) {
        if (base % GuestPageSize != 0 || size == 0 || size % GuestPageSize != 0)
            throw new GuestMemoryError(format("Page of Region %s at 0x%X (0x%X bytes) is not aligned!", name, base, size));

        MemoryRegion reg = new MemoryRegion(base, size, permission, name);
        size_t regI = 0;
        while (regI < regions.length && regions[regI].Base < base)
            regI++;
        regions = regions[0 .. regI] ~ reg ~ regions[regI .. $];
        return reg;
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
