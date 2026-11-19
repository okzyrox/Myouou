/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * GPU virtual memory address space
*/

module Source.Gpu.MemoryManager;

// Std
import std.algorithm : sort;

// Core
import Source.Memory.Guest;
import Source.Util.Logger;

// Types
enum ulong GpuSmallPageSize = 0x1000;
enum ulong GpuBigPageSize = 0x20000;
enum ulong GpuAddressSpaceStart = 0x1_0000_0000;
enum ulong GpuAddressSpaceEnd = 0x100_0000_0000;

struct GpuMapping {
    ulong GpuAddress;
    ulong Size;
    ulong CpuAddress;
}

struct GpuReservation {
    ulong GpuAddress;
    ulong Size;
}

// Class
final class GpuMemoryManager {
    GuestMemory Memory;

    private GpuMapping[] mappings;
    private GpuReservation[] reservations;
    private ulong nextAddress = GpuAddressSpaceStart;
    private Logger log;

    this(GuestMemory memory) {
        Memory = memory;
        log = GetLogger("Gpu::MemoryManager");
    }

    ulong Allocate(ulong size, ulong alignment) {
        if (alignment < GpuSmallPageSize)
            alignment = GpuSmallPageSize;
        const ulong address = (nextAddress + alignment - 1) & ~(alignment - 1);
        nextAddress = address + ((size + GpuSmallPageSize - 1) & ~(GpuSmallPageSize - 1));
        return address;
    }

    ulong Reserve(ulong address, ulong size, ulong alignment) {
        if (address == 0)
            address = Allocate(size, alignment);
        else if (address + size > nextAddress)
            nextAddress = address + size;
        reservations ~= GpuReservation(address, size);
        log.Trace("Reserved 0x%X bytes at gpu addr 0x%X", size, address);
        return address;
    }

    void FreeReservation(ulong address) {
        foreach (i, reservation; reservations) {
            if (reservation.GpuAddress == address) {
                reservations = reservations[0 .. i] ~ reservations[i + 1 .. $];
                break;
            }
        }
        Unmap(address);
    }

    ulong Map(ulong gpuAddress, ulong cpuAddress, ulong size) {
        if (gpuAddress == 0)
            gpuAddress = Allocate(size, GpuBigPageSize);
        Unmap(gpuAddress, size);
        mappings ~= GpuMapping(gpuAddress, size, cpuAddress);
        mappings.sort!((a, b) => a.GpuAddress < b.GpuAddress);
        log.Trace("Mapped gpu 0x%X to cpu 0x%X (0x%X bytes)", gpuAddress, cpuAddress, size);
        return gpuAddress;
    }

    void Unmap(ulong gpuAddress, ulong size = 0) {
        GpuMapping[] kept;
        foreach (mapping; mappings) {
            const bool hit = size == 0 ? mapping.GpuAddress == gpuAddress : mapping.GpuAddress < gpuAddress + size && gpuAddress < mapping.GpuAddress + mapping.Size;
            if (!hit) {
                kept ~= mapping;
                continue;
            }
            if (size != 0 && mapping.GpuAddress < gpuAddress)
                kept ~= GpuMapping(mapping.GpuAddress, gpuAddress - mapping.GpuAddress, mapping.CpuAddress);
            if (size != 0 && mapping.GpuAddress + mapping.Size > gpuAddress + size) {
                const ulong cut = gpuAddress + size - mapping.GpuAddress;
                kept ~= GpuMapping(gpuAddress + size, mapping.Size - cut, mapping.CpuAddress + cut);
            }
        }
        mappings = kept;
    }

    const(GpuMapping)* Find(ulong gpuAddress) const {
        size_t low = 0;
        size_t high = mappings.length;
        while (low < high) {
            const size_t middle = (low + high) / 2;
            const GpuMapping* mapping = &mappings[middle];
            if (gpuAddress < mapping.GpuAddress)
                high = middle;
            else if (gpuAddress >= mapping.GpuAddress + mapping.Size)
                low = middle + 1;
            else
                return mapping;
        }
        return null;
    }

    bool Translate(ulong gpuAddress, out ulong cpuAddress) const {
        const(GpuMapping)* mapping = Find(gpuAddress);
        if (mapping is null)
            return false;
        cpuAddress = mapping.CpuAddress + (gpuAddress - mapping.GpuAddress);
        return true;
    }

    void Read(ulong gpuAddress, ubyte[] destination) {
        size_t done = 0;
        while (done < destination.length) {
            const(GpuMapping)* mapping = Find(gpuAddress + done);
            if (mapping is null) {
                log.Warn("Tried to read from an unmapped gpu address (0x%X)!", gpuAddress + done);
                destination[done .. $] = 0;
                return;
            }
            const ulong offset = gpuAddress + done - mapping.GpuAddress;
            const size_t chunk = cast(size_t) (mapping.Size - offset < destination.length - done ? mapping.Size - offset : destination.length - done);
            Memory.ReadBytes(mapping.CpuAddress + offset, destination[done .. done + chunk]);
            done += chunk;
        }
    }

    void Write(ulong gpuAddress, const(ubyte)[] source) {
        size_t done = 0;
        while (done < source.length) {
            const(GpuMapping)* mapping = Find(gpuAddress + done);
            if (mapping is null) {
                log.Warn("Tried to write to an unmapped gpu address (0x%X)!", gpuAddress + done);
                return;
            }
            const ulong offset = gpuAddress + done - mapping.GpuAddress;
            const size_t chunk = cast(size_t) (mapping.Size - offset < source.length - done ? mapping.Size - offset : source.length - done);
            Memory.WriteBytes(mapping.CpuAddress + offset, source[done .. done + chunk]);
            done += chunk;
        }
    }

    T Read(T)(ulong gpuAddress) {
        T value;
        Read(gpuAddress, (cast(ubyte*) &value)[0 .. T.sizeof]);
        return value;
    }

    void Write(T)(ulong gpuAddress, T value) {
        Write(gpuAddress, (cast(const(ubyte)*) &value)[0 .. T.sizeof]);
    }
}
