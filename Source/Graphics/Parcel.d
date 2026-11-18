/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Android binder parcels
 * ref: https://developer.android.com/reference/kotlin/android/os/Parcel
*/

module Source.Graphics.Parcel;

// Std
import std.algorithm : min;

// Types
enum size_t ParcelHeaderSize = 0x10;

struct ParcelReader {
    const(ubyte)[] Payload;
    size_t Offset;

    static ParcelReader FromRaw(const(ubyte)[] raw) {
        if (raw.length < ParcelHeaderSize)
            return ParcelReader.init;
        const uint payloadSize = *cast(const(uint)*) raw.ptr;
        const uint payloadOffset = *cast(const(uint)*) (raw.ptr + 4);
        const size_t start = min(payloadOffset, raw.length);
        const size_t end = min(start + payloadSize, raw.length);
        return ParcelReader(raw[start .. end], 0);
    }

    bool Empty() const {
        return Offset >= Payload.length;
    }

    const(ubyte)[] ReadData(size_t length) {
        const size_t start = min(Offset, Payload.length);
        const size_t end = min(start + length, Payload.length);
        Offset = start + ((length + 3) & ~cast(size_t) 3);
        return Payload[start .. end];
    }

    T Read(T)() {
        const(ubyte)[] data = ReadData(T.sizeof);
        T value;
        // risky for some types but should be good for most service cases & android standard primitives
        (cast(ubyte*) &value)[0 .. data.length] = data[];
        return value;
    }

    string ReadInterfaceToken() {
        Read!int();
        const int length = Read!int();
        if (length <= 0)
            return null;
        const(ubyte)[] raw = ReadData((cast(size_t) length + 1) * 2);
        char[] text;
        for (size_t i = 0; i + 1 < raw.length && text.length < length; i += 2)
            text ~= cast(char) raw[i];
        return text.idup;
    }

    const(ubyte)[] ReadFlattenedObject() {
        const int length = Read!int();
        const int fdCount = Read!int();
        if (length <= 0 || fdCount != 0)
            return null;
        return ReadData(length);
    }
}

struct ParcelWriter {
    ubyte[] Payload;

    void WriteData(const(ubyte)[] data) {
        Payload ~= data;
        while (Payload.length % 4 != 0)
            Payload ~= 0;
    }

    void Write(T)(T value) {
        WriteData((cast(const(ubyte)*) &value)[0 .. T.sizeof]);
    }

    void WriteFlattenedObject(const(ubyte)[] data) {
        Write!int(cast(int) data.length);
        Write!int(0);
        WriteData(data);
    }

    void WriteFlattenedObject(T)(const ref T value) {
        WriteFlattenedObject((cast(const(ubyte)*) &value)[0 .. T.sizeof]);
    }

    ubyte[] Serialize() const {
        ubyte[] raw = new ubyte[ParcelHeaderSize + Payload.length];
        *cast(uint*) raw.ptr = cast(uint) Payload.length;
        *cast(uint*) (raw.ptr + 4) = cast(uint) ParcelHeaderSize;
        *cast(uint*) (raw.ptr + 8) = 0;
        *cast(uint*) (raw.ptr + 12) = cast(uint) (ParcelHeaderSize + Payload.length);
        raw[ParcelHeaderSize .. $] = Payload[];
        return raw;
    }
}
