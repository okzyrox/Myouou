/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * AES-128 (ECB, CTR and XTS)
*/

module Source.Crypto.Aes;

// Types
enum size_t AesBlockSize = 16;

// Tables
private ubyte Rotl8(ubyte value, uint shift) pure nothrow @nogc @safe {
    return cast(ubyte) ((value << shift) | (value >> (8 - shift)));
}

private ubyte[256] BuildSBox() pure nothrow @nogc @safe {
    ubyte[256] box;
    ubyte p = 1;
    ubyte q = 1;
    do {
        p = cast(ubyte) (p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1B : 0));
        q = cast(ubyte) (q ^ (q << 1));
        q = cast(ubyte) (q ^ (q << 2));
        q = cast(ubyte) (q ^ (q << 4));
        if ((q & 0x80) != 0) {
            q ^= 0x09;
        }
        box[p] = cast(ubyte) (q ^ Rotl8(q, 1) ^ Rotl8(q, 2) ^ Rotl8(q, 3) ^ Rotl8(q, 4) ^ 0x63);
    } while (p != 1);
    box[0] = 0x63;
    return box;
}

private ubyte[256] BuildInverse(const ubyte[256] box) pure nothrow @nogc @safe {
    ubyte[256] inverse;
    foreach (i; 0 .. 256) {
        inverse[box[i]] = cast(ubyte) i;
    }
    return inverse;
}

private immutable ubyte[256] SBox = BuildSBox();
private immutable ubyte[256] InvSBox = BuildInverse(SBox);
private immutable ubyte[11] Rcon = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36];

private ubyte XTime(ubyte value) pure nothrow @nogc @safe {
    return cast(ubyte) ((value << 1) ^ ((value & 0x80) != 0 ? 0x1B : 0));
}

private ubyte Mul(ubyte a, ubyte b) pure nothrow @nogc @safe {
    ubyte result = 0;
    while (b != 0) {
        if ((b & 1) != 0) {
            result ^= a;
        }
        a = XTime(a);
        b >>= 1;
    }
    return result;
}

// Cipher
struct Aes128 {
    private ubyte[176] roundKeys;

    // might not be accurate for larger sections...

    this(const(ubyte)[] key) pure nothrow @nogc @safe {
        assert(key.length == AesBlockSize);
        roundKeys[0 .. 16] = key[];
        foreach (i; 4 .. 44) {
            ubyte[4] word = roundKeys[(i - 1) * 4 .. i * 4];
            if (i % 4 == 0) {
                const ubyte first = word[0];
                word[0] = cast(ubyte) (SBox[word[1]] ^ Rcon[i / 4]);
                word[1] = SBox[word[2]];
                word[2] = SBox[word[3]];
                word[3] = SBox[first];
            }
            foreach (j; 0 .. 4) {
                roundKeys[i * 4 + j] = cast(ubyte) (roundKeys[(i - 4) * 4 + j] ^ word[j]);
            }
        }
    }

    private void AddRoundKey(ubyte[] state, size_t round) const pure nothrow @nogc @safe {
        foreach (i; 0 .. 16) {
            state[i] ^= roundKeys[round * 16 + i];
        }
    }

    void EncryptBlock(ubyte[] state) const pure nothrow @nogc @safe {
        assert(state.length == AesBlockSize);
        AddRoundKey(state, 0);
        foreach (round; 1 .. 11) {
            ubyte[16] shifted;
            foreach (row; 0 .. 4) {
                foreach (column; 0 .. 4) {
                    shifted[row + 4 * column] = SBox[state[row + 4 * ((column + row) % 4)]];
                }
            }
            if (round != 10) {
                foreach (column; 0 .. 4) {
                    const ubyte a0 = shifted[4 * column];
                    const ubyte a1 = shifted[4 * column + 1];
                    const ubyte a2 = shifted[4 * column + 2];
                    const ubyte a3 = shifted[4 * column + 3];
                    shifted[4 * column] = cast(ubyte) (XTime(a0) ^ XTime(a1) ^ a1 ^ a2 ^ a3);
                    shifted[4 * column + 1] = cast(ubyte) (a0 ^ XTime(a1) ^ XTime(a2) ^ a2 ^ a3);
                    shifted[4 * column + 2] = cast(ubyte) (a0 ^ a1 ^ XTime(a2) ^ XTime(a3) ^ a3);
                    shifted[4 * column + 3] = cast(ubyte) (XTime(a0) ^ a0 ^ a1 ^ a2 ^ XTime(a3));
                }
            }
            state[] = shifted[];
            AddRoundKey(state, round);
        }
    }

    void DecryptBlock(ubyte[] state) const pure nothrow @nogc @safe {
        assert(state.length == AesBlockSize);
        AddRoundKey(state, 10);
        foreach_reverse (round; 0 .. 10) {
            ubyte[16] shifted;
            foreach (row; 0 .. 4) {
                foreach (column; 0 .. 4) {
                    shifted[row + 4 * ((column + row) % 4)] = InvSBox[state[row + 4 * column]];
                }
            }
            state[] = shifted[];
            AddRoundKey(state, round);
            if (round != 0) {
                foreach (column; 0 .. 4) {
                    const ubyte a0 = state[4 * column];
                    const ubyte a1 = state[4 * column + 1];
                    const ubyte a2 = state[4 * column + 2];
                    const ubyte a3 = state[4 * column + 3];
                    state[4 * column] = cast(ubyte) (Mul(a0, 14) ^ Mul(a1, 11) ^ Mul(a2, 13) ^ Mul(a3, 9));
                    state[4 * column + 1] = cast(ubyte) (Mul(a0, 9) ^ Mul(a1, 14) ^ Mul(a2, 11) ^ Mul(a3, 13));
                    state[4 * column + 2] = cast(ubyte) (Mul(a0, 13) ^ Mul(a1, 9) ^ Mul(a2, 14) ^ Mul(a3, 11));
                    state[4 * column + 3] = cast(ubyte) (Mul(a0, 11) ^ Mul(a1, 13) ^ Mul(a2, 9) ^ Mul(a3, 14));
                }
            }
        }
    }
}

// Modes
void AesEcbDecrypt(const(ubyte)[] key, ubyte[] data) pure nothrow @nogc @safe {
    const Aes128 aes = Aes128(key);
    for (size_t i = 0; i + AesBlockSize <= data.length; i += AesBlockSize) {
        aes.DecryptBlock(data[i .. i + AesBlockSize]);
    }
}

void AesEcbEncrypt(const(ubyte)[] key, ubyte[] data) pure nothrow @nogc @safe {
    const Aes128 aes = Aes128(key);
    for (size_t i = 0; i + AesBlockSize <= data.length; i += AesBlockSize) {
        aes.EncryptBlock(data[i .. i + AesBlockSize]);
    }
}

private void IncrementBigEndian(ref ubyte[16] counter) pure nothrow @nogc @safe {
    foreach_reverse (i; 0 .. 16) {
        if (++counter[i] != 0) {
            break;
        }
    }
}

void AesCtrCrypt(const(ubyte)[] key, ubyte[16] counter, ubyte[] data) pure nothrow @nogc @safe {
    const Aes128 aes = Aes128(key);
    for (size_t i = 0; i < data.length; i += AesBlockSize) {
        ubyte[16] stream = counter;
        aes.EncryptBlock(stream[]);
        const size_t length = data.length - i < AesBlockSize ? data.length - i : AesBlockSize;
        foreach (j; 0 .. length) {
            data[i + j] ^= stream[j];
        }
        IncrementBigEndian(counter);
    }
}

private void XtsTweak(ulong sector, bool nintendoTweak, ref ubyte[16] tweak) pure nothrow @nogc @safe {
    tweak[] = 0;
    foreach (i; 0 .. 8) {
        const ubyte value = cast(ubyte) (sector >> (i * 8));
        if (nintendoTweak) {
            tweak[15 - i] = value;
        } else {
            tweak[i] = value;
        }
    }
}

private void XtsMultiply(ref ubyte[16] tweak) pure nothrow @nogc @safe {
    ubyte carry = 0;
    foreach (i; 0 .. 16) {
        const ubyte next = tweak[i] >> 7;
        tweak[i] = cast(ubyte) ((tweak[i] << 1) | carry);
        carry = next;
    }
    if (carry != 0) {
        tweak[0] ^= 0x87;
    }
}

private void AesXts(const(ubyte)[] key, ubyte[] data, ulong sector, size_t sectorSize, bool nintendoTweak, bool decrypt) pure nothrow @nogc @safe {
    assert(key.length == AesBlockSize * 2);
    const Aes128 dataKey = Aes128(key[0 .. 16]);
    const Aes128 tweakKey = Aes128(key[16 .. 32]);
    for (size_t offset = 0; offset + sectorSize <= data.length; offset += sectorSize) {
        ubyte[16] tweak;
        XtsTweak(sector++, nintendoTweak, tweak);
        tweakKey.EncryptBlock(tweak[]);
        for (size_t i = offset; i + AesBlockSize <= offset + sectorSize; i += AesBlockSize) {
            ubyte[] block = data[i .. i + AesBlockSize];
            block[] ^= tweak[];
            if (decrypt) {
                dataKey.DecryptBlock(block);
            } else {
                dataKey.EncryptBlock(block);
            }
            block[] ^= tweak[];
            XtsMultiply(tweak);
        }
    }
}

void AesXtsDecrypt(const(ubyte)[] key, ubyte[] data, ulong sector, size_t sectorSize, bool nintendoTweak = true) pure nothrow @nogc @safe {
    AesXts(key, data, sector, sectorSize, nintendoTweak, true);
}

void AesXtsEncrypt(const(ubyte)[] key, ubyte[] data, ulong sector, size_t sectorSize, bool nintendoTweak = true) pure nothrow @nogc @safe {
    AesXts(key, data, sector, sectorSize, nintendoTweak, false);
}