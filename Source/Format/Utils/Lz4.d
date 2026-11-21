/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * LZ4 block decompression
*/

module Source.Format.Utils.Lz4;

// Std
import std.format : format;

// Types
class Lz4Error : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Utils
private size_t ReadSourceLength(const(ubyte)[] source, ref size_t position, size_t length) {
    if (length != 15) {
        return length;
    }
    ubyte val;
    do {
        if (position >= source.length) {
            throw new Lz4Error("LZ4 length runs past the end of the input!");
        }
        val = source[position++];
        length += val;
    } while (val == 255);
    return length;
}

// Functions
ubyte[] Lz4DecompressBlock(const(ubyte)[] source, size_t outputSize) {
    ubyte[] output = new ubyte[outputSize];
    size_t input = 0;
    size_t written = 0;
    while (input < source.length) {
        const ubyte token = source[input++];

        const size_t literals = ReadSourceLength(source, input, token >> 4);
        if (input + literals > source.length || written + literals > output.length) {
            throw new Lz4Error(format("LZ4 run of %d bytes is OOB at 0x%X!", literals, input));
        }
        output[written .. written + literals] = source[input .. input + literals];
        input += literals;
        written += literals;
        if (input >= source.length) {
            break;
        }

        if (input + 2 > source.length) {
            throw new Lz4Error("LZ4 match offset runs past the end of the input!");
        }
        const size_t offset = source[input] | (source[input + 1] << 8);
        input += 2;
        if (offset == 0 || offset > written) {
            throw new Lz4Error(format("LZ4 match offset 0x%X is invalid at output 0x%X!", offset, written));
        }
        const size_t match = ReadSourceLength(source, input, token & 0xF) + 4;
        if (written + match > output.length) {
            throw new Lz4Error(format("LZ4 match of %d bytes overflows the output at 0x%X!", match, written));
        }
        foreach (i; 0 .. match) {
            output[written + i] = output[written - offset + i];
        }
        written += match;
    }
    if (written != output.length) {
        throw new Lz4Error(format("LZ4 block decompressed to 0x%X bytes, expected 0x%X!", written, output.length));
    }
    return output;
}
