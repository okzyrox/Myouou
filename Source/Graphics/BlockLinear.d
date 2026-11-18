/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Tegra 'Block Linear' format
*/

module Source.Graphics.BlockLinear;

// Types
enum size_t GobWidth = 64; // groups of bytes
enum size_t GobHeight = 8;
enum size_t GobSize = GobWidth * GobHeight; // kepler gob is 512b

// Functions
size_t GobOffset(size_t x, size_t y) pure nothrow @nogc @safe {
    // in a ROB, the next offset may be beyond the width val
    // if not a multiple of the block width (64b)
    return ((x % 64) / 32) * 256 + ((y % 8) / 2) * 64 + ((x % 32) / 16) * 32 + (y % 2) * 16 + (x % 16);
}

// ref: 18.7.1
size_t BlockLinearSize(size_t pitch, size_t height, uint blockHeightLog2) pure nothrow @nogc @safe {
    const size_t blockRows = GobHeight << blockHeightLog2;
    const size_t widthInGobs = (pitch + GobWidth - 1) / GobWidth;
    const size_t rowsOfBlocks = (height + blockRows - 1) / blockRows;
    return rowsOfBlocks * widthInGobs * (GobSize << blockHeightLog2);
}

void DeswizzleBlockLinear(const(ubyte)[] source, ubyte[] destination, size_t rowBytes, size_t blockHeight, size_t pitch, uint blockHeightLog2) {
    const size_t blockGobs = cast(size_t) 1 << blockHeightLog2;
    const size_t blockRows = GobHeight * blockGobs;
    const size_t widthInGobs = (pitch + GobWidth - 1) / GobWidth;
    const size_t blockSize = GobSize * blockGobs;
    const size_t blockRowSize = widthInGobs * blockSize;

    // GOBs are stacked vertically to make a Block
    // which is divided by the blockHeight surface parameter
    foreach (y; 0 .. blockHeight) {
        const size_t rowBase = (y / blockRows) * blockRowSize + ((y % blockRows) / GobHeight) * GobSize;
        ubyte[] line = destination[y * rowBytes .. (y + 1) * rowBytes];

        // Blocks are arranged into ROBs
        for (size_t x = 0; x < rowBytes; x += 16) {
            const size_t offset = rowBase + (x / GobWidth) * blockSize + GobOffset(x, y);
            const size_t length = rowBytes - x < 16 ? rowBytes - x : 16;
            if (offset + length > source.length)
                return;
            line[x .. x + length] = source[offset .. offset + length];
        }
    }
}
