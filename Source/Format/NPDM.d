/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing of NPDM program metadata
*/

module Source.Format.NPDM;

// Std
import std.file : read;
import std.format : format;

// Signatures
enum uint NPDMMagic = 0x4154454D; // 'META'
enum uint ACIMagic = 0x30494341; // 'ACI0'

// Types
enum AddressSpaceType : ubyte {
    Bits32 = 0,
    Bits36 = 1,
    Bits32NoReserved = 2,
    Bits39 = 3,
}

struct NPDMHeader {
    uint Magic;
    uint SignatureKeyGeneration;
    uint Reserved0;
    ubyte Flags;
    ubyte Reserved1;
    ubyte MainThreadPriority;
    ubyte MainThreadCore;
    uint Reserved2;
    uint SystemResourceSize;
    uint Version;
    uint MainThreadStackSize;
    char[0x10] Name;
    char[0x10] ProductCode;
    ubyte[0x30] Reserved3;
    uint AciOffset;
    uint AciSize;
    uint AcidOffset;
    uint AcidSize;
}

struct ACIHeader {
    uint Magic;
    ubyte[0xC] Reserved0;
    ulong ProgramId;
    ulong Reserved1;
    uint FsAccessOffset;
    uint FsAccessSize;
    uint ServiceAccessOffset;
    uint ServiceAccessSize;
    uint KernelCapabilityOffset;
    uint KernelCapabilitySize;
    ulong Reserved2;
}

class NPDMFileError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Class
final class NPDMFile {
    private NPDMHeader header;
    private ACIHeader aci;

    static NPDMFile Load(string path) {
        return new NPDMFile(cast(const(ubyte)[]) read(path));
    }

    this(const(ubyte)[] data) {
        if (data.length < NPDMHeader.sizeof) {
            throw new NPDMFileError(format("NPDM is too small (0x%X bytes)!", data.length));
        }
        header = *cast(const(NPDMHeader)*) data.ptr;
        if (header.Magic != NPDMMagic) {
            throw new NPDMFileError(format("Invalid NPDM! wrong sig like 0x%08X", header.Magic));
        }
        if (header.AciOffset + ACIHeader.sizeof > data.length) {
            throw new NPDMFileError(format("NPDM ACI0 at 0x%X is outside the file!", header.AciOffset));
        }
        aci = *cast(const(ACIHeader)*) (data.ptr + header.AciOffset);
        if (aci.Magic != ACIMagic) {
            throw new NPDMFileError(format("Invalid NPDM ACI0! wrong sig like 0x%08X", aci.Magic));
        }

        // todo: Service Access Control / KernelCapability loading (and handling maybe? although its very minor)
    }

    const(NPDMHeader) Header() const nothrow @nogc {
        return header;
    }

    ulong ProgramId() const nothrow @nogc {
        return aci.ProgramId;
    }

    bool Is64Bit() const nothrow @nogc {
        return (header.Flags & 1) != 0;
    }

    AddressSpaceType AddressSpace() const nothrow @nogc {
        return cast(AddressSpaceType) ((header.Flags >> 1) & 7);
    }

    uint MainThreadStackSize() const nothrow @nogc {
        return header.MainThreadStackSize;
    }

    ubyte MainThreadPriority() const nothrow @nogc {
        return header.MainThreadPriority;
    }

    ubyte MainThreadCore() const nothrow @nogc {
        return header.MainThreadCore;
    }

    string Name() const {
        size_t length = 0;
        while (length < header.Name.length && header.Name[length] != 0) {
            length++;
        }
        return header.Name[0 .. length].idup;
    }
}
