/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell shader instruction decoder
*/

module Source.Gpu.Shader.Instructions;

// Std
import std.algorithm : sort;
import std.format : format;

// Types
enum Opcode {
    Unknown,
    Al2p, Ald, Ast, Bra, Brk, Cont, Depbar, Exit, Kil, Nop, Pbk, Pcnt, Ssy, Sync,
    F2fReg, F2fCbuf, F2fImm, F2iReg, F2iCbuf, F2iImm, I2fReg, I2fCbuf, I2fImm, I2iReg, I2iCbuf, I2iImm,
    FaddReg, FaddCbuf, FaddImm, Fadd32i,
    FfmaReg, FfmaRc, FfmaCr, FfmaImm, Ffma32i,
    FmnmxReg, FmnmxCbuf, FmnmxImm,
    FmulReg, FmulCbuf, FmulImm, Fmul32i,
    FsetReg, FsetCbuf, FsetImm,
    FsetpReg, FsetpCbuf, FsetpImm,
    IaddReg, IaddCbuf, IaddImm, Iadd32i,
    IscaddReg, IscaddCbuf, IscaddImm,
    IsetpReg, IsetpCbuf, IsetpImm,
    IcmpReg, IcmpCr, IcmpRc, IcmpImm,
    Fswzadd, Shfl,
    Ipa, Ld, Ldc, St,
    LopReg, LopCbuf, LopImm, Lop32i,
    Lop3Reg, Lop3Cbuf, Lop3Imm,
    MovReg, MovCbuf, MovImm, Mov32i,
    Mufu, RroReg, RroCbuf, RroImm,
    S2r, SelReg, SelCbuf, SelImm,
    ShlReg, ShlCbuf, ShlImm, ShrReg, ShrCbuf, ShrImm,
    PsetpInst, Tex, Texs, Tld, Tlds,
    XmadReg, XmadRc, XmadCr, XmadImm,
}

private struct OpcodePattern {
    Opcode Op;
    string Name;
    string Bits;
    ushort Mask;
    ushort Value;
    int Fixed;
}

private immutable OpcodePattern[] rawPatterns = [
    OpcodePattern(Opcode.Al2p, "AL2P", "1110111110100---"),
    OpcodePattern(Opcode.Ald, "ALD", "1110111111011---"),
    OpcodePattern(Opcode.Ast, "AST", "1110111111110---"),
    OpcodePattern(Opcode.Bra, "BRA", "111000100100----"),
    OpcodePattern(Opcode.Brk, "BRK", "111000110100----"),
    OpcodePattern(Opcode.Cont, "CONT", "111000110101----"),
    OpcodePattern(Opcode.Depbar, "DEPBAR", "1111000011110---"),
    OpcodePattern(Opcode.Exit, "EXIT", "111000110000----"),
    OpcodePattern(Opcode.Kil, "KIL", "111000110011----"),
    OpcodePattern(Opcode.Nop, "NOP", "0101000010110---"),
    OpcodePattern(Opcode.Pbk, "PBK", "111000101010----"),
    OpcodePattern(Opcode.Pcnt, "PCNT", "111000101011----"),
    OpcodePattern(Opcode.Ssy, "SSY", "111000101001----"),
    OpcodePattern(Opcode.Sync, "SYNC", "1111000011111---"),
    OpcodePattern(Opcode.F2fReg, "F2F", "0101110010101---"),
    OpcodePattern(Opcode.F2fCbuf, "F2F", "0100110010101---"),
    OpcodePattern(Opcode.F2fImm, "F2F", "0011100-10101---"),
    OpcodePattern(Opcode.F2iReg, "F2I", "0101110010110---"),
    OpcodePattern(Opcode.F2iCbuf, "F2I", "0100110010110---"),
    OpcodePattern(Opcode.F2iImm, "F2I", "0011100-10110---"),
    OpcodePattern(Opcode.I2fReg, "I2F", "0101110010111---"),
    OpcodePattern(Opcode.I2fCbuf, "I2F", "0100110010111---"),
    OpcodePattern(Opcode.I2fImm, "I2F", "0011100-10111---"),
    OpcodePattern(Opcode.I2iReg, "I2I", "0101110011100---"),
    OpcodePattern(Opcode.I2iCbuf, "I2I", "0100110011100---"),
    OpcodePattern(Opcode.I2iImm, "I2I", "0011100-11100---"),
    OpcodePattern(Opcode.FaddReg, "FADD", "0101110001011---"),
    OpcodePattern(Opcode.FaddCbuf, "FADD", "0100110001011---"),
    OpcodePattern(Opcode.FaddImm, "FADD", "0011100-01011---"),
    OpcodePattern(Opcode.Fadd32i, "FADD32I", "000010----------"),
    OpcodePattern(Opcode.FfmaReg, "FFMA", "010110011-------"),
    OpcodePattern(Opcode.FfmaRc, "FFMA", "010100011-------"),
    OpcodePattern(Opcode.FfmaCr, "FFMA", "010010011-------"),
    OpcodePattern(Opcode.FfmaImm, "FFMA", "0011001-1-------"),
    OpcodePattern(Opcode.Ffma32i, "FFMA32I", "000011----------"),
    OpcodePattern(Opcode.FmnmxReg, "FMNMX", "0101110001100---"),
    OpcodePattern(Opcode.FmnmxCbuf, "FMNMX", "0100110001100---"),
    OpcodePattern(Opcode.FmnmxImm, "FMNMX", "0011100-01100---"),
    OpcodePattern(Opcode.FmulReg, "FMUL", "0101110001101---"),
    OpcodePattern(Opcode.FmulCbuf, "FMUL", "0100110001101---"),
    OpcodePattern(Opcode.FmulImm, "FMUL", "0011100-01101---"),
    OpcodePattern(Opcode.Fmul32i, "FMUL32I", "00011110--------"),
    OpcodePattern(Opcode.FsetReg, "FSET", "01011000--------"),
    OpcodePattern(Opcode.FsetCbuf, "FSET", "01001000--------"),
    OpcodePattern(Opcode.FsetImm, "FSET", "0011000---------"),
    OpcodePattern(Opcode.FsetpReg, "FSETP", "010110111011----"),
    OpcodePattern(Opcode.FsetpCbuf, "FSETP", "010010111011----"),
    OpcodePattern(Opcode.FsetpImm, "FSETP", "0011011-1011----"),
    OpcodePattern(Opcode.IaddReg, "IADD", "0101110000010---"),
    OpcodePattern(Opcode.IaddCbuf, "IADD", "0100110000010---"),
    OpcodePattern(Opcode.IaddImm, "IADD", "0011100-00010---"),
    OpcodePattern(Opcode.Iadd32i, "IADD32I", "0001110---------"),
    OpcodePattern(Opcode.IscaddReg, "ISCADD", "0101110000011---"),
    OpcodePattern(Opcode.IscaddCbuf, "ISCADD", "0100110000011---"),
    OpcodePattern(Opcode.IscaddImm, "ISCADD", "0011100-00011---"),
    OpcodePattern(Opcode.IsetpReg, "ISETP", "010110110110----"),
    OpcodePattern(Opcode.IsetpCbuf, "ISETP", "010010110110----"),
    OpcodePattern(Opcode.IsetpImm, "ISETP", "0011011-0110----"),
    OpcodePattern(Opcode.Fswzadd, "FSWZADD", "0101000011111---"),
    OpcodePattern(Opcode.Shfl, "SHFL", "1110111100010---"),
    OpcodePattern(Opcode.IcmpReg, "ICMP", "010110110100----"),
    OpcodePattern(Opcode.IcmpCr, "ICMP", "010010110100----"),
    OpcodePattern(Opcode.IcmpRc, "ICMP", "010100110100----"),
    OpcodePattern(Opcode.IcmpImm, "ICMP", "0011011-0100----"),
    OpcodePattern(Opcode.Ipa, "IPA", "11100000--------"),
    OpcodePattern(Opcode.Ld, "LD", "100-------------"),
    OpcodePattern(Opcode.Ldc, "LDC", "1110111110010---"),
    OpcodePattern(Opcode.St, "ST", "101-------------"),
    OpcodePattern(Opcode.LopReg, "LOP", "0101110001000---"),
    OpcodePattern(Opcode.LopCbuf, "LOP", "0100110001000---"),
    OpcodePattern(Opcode.LopImm, "LOP", "0011100-01000---"),
    OpcodePattern(Opcode.Lop32i, "LOP32I", "000001----------"),
    OpcodePattern(Opcode.Lop3Reg, "LOP3", "0101101111100---"),
    OpcodePattern(Opcode.Lop3Cbuf, "LOP3", "0000001---------"),
    OpcodePattern(Opcode.Lop3Imm, "LOP3", "001111----------"),
    OpcodePattern(Opcode.MovReg, "MOV", "0101110010011---"),
    OpcodePattern(Opcode.MovCbuf, "MOV", "0100110010011---"),
    OpcodePattern(Opcode.MovImm, "MOV", "0011100-10011---"),
    OpcodePattern(Opcode.Mov32i, "MOV32I", "000000010000----"),
    OpcodePattern(Opcode.Mufu, "MUFU", "0101000010000---"),
    OpcodePattern(Opcode.RroReg, "RRO", "0101110010010---"),
    OpcodePattern(Opcode.RroCbuf, "RRO", "0100110010010---"),
    OpcodePattern(Opcode.RroImm, "RRO", "0011100-10010---"),
    OpcodePattern(Opcode.S2r, "S2R", "1111000011001---"),
    OpcodePattern(Opcode.SelReg, "SEL", "0101110010100---"),
    OpcodePattern(Opcode.SelCbuf, "SEL", "0100110010100---"),
    OpcodePattern(Opcode.SelImm, "SEL", "0011100-10100---"),
    OpcodePattern(Opcode.ShlReg, "SHL", "0101110001001---"),
    OpcodePattern(Opcode.ShlCbuf, "SHL", "0100110001001---"),
    OpcodePattern(Opcode.ShlImm, "SHL", "0011100-01001---"),
    OpcodePattern(Opcode.ShrReg, "SHR", "0101110000101---"),
    OpcodePattern(Opcode.ShrCbuf, "SHR", "0100110000101---"),
    OpcodePattern(Opcode.ShrImm, "SHR", "0011100-00101---"),
    OpcodePattern(Opcode.PsetpInst, "PSETP", "0101000010010---"),
    OpcodePattern(Opcode.Tex, "TEX", "110000----------"),
    OpcodePattern(Opcode.Texs, "TEXS", "1101-00---------"),
    OpcodePattern(Opcode.Tld, "TLD", "11011100--11----"),
    OpcodePattern(Opcode.Tlds, "TLDS", "1101-01---------"),
    OpcodePattern(Opcode.XmadReg, "XMAD", "0101101100------"),
    OpcodePattern(Opcode.XmadRc, "XMAD", "010100010-------"),
    OpcodePattern(Opcode.XmadCr, "XMAD", "0100111---------"),
    OpcodePattern(Opcode.XmadImm, "XMAD", "0011011-00------"),
];

private OpcodePattern[] BuildPatterns() {
    OpcodePattern[] result;
    foreach (pattern; rawPatterns) {
        OpcodePattern built = pattern;
        foreach (i, bit; pattern.Bits) {
            const ushort position = cast(ushort) (1 << (15 - i));
            if (bit == '-')
                continue;
            built.Mask |= position;
            built.Fixed++;
            if (bit == '1')
                built.Value |= position;
        }
        result ~= built;
    }
    result.sort!((a, b) => a.Fixed > b.Fixed);
    return result;
}

private immutable OpcodePattern[] patterns;

shared static this() {
    patterns = cast(immutable) BuildPatterns();
}

private const(OpcodePattern)* Match(ulong raw) {
    // most specific wins usually as its by the fixed bits
    const ushort top = cast(ushort) (raw >> 48);
    foreach (ref pattern; patterns) {
        if ((top & pattern.Mask) == pattern.Value)
            return &pattern;
    }
    return null;
}

enum uint RegisterZero = 255;
enum uint PredicateTrue = 7;

float BitsToFloat(uint bits) {
    return *cast(float*) &bits;
}

struct Instruction {
    ulong Raw;
    Opcode Op;
    string Name;
    size_t Address;

    static Instruction Decode(ulong raw, size_t address) {
        const(OpcodePattern)* pattern = Match(raw);
        if (pattern is null)
            return Instruction(raw, Opcode.Unknown, "???", address);
        return Instruction(raw, pattern.Op, pattern.Name, address);
    }

    ulong Bits(uint start, uint count) const {
        return (Raw >> start) & ((1UL << count) - 1);
    }

    bool Bit(uint position) const {
        return ((Raw >> position) & 1) != 0;
    }

    uint Dest() const { return cast(uint) Bits(0, 8); }
    uint SrcA() const { return cast(uint) Bits(8, 8); }
    uint SrcB() const { return cast(uint) Bits(20, 8); }
    uint SrcC() const { return cast(uint) Bits(39, 8); }
    uint Predicate() const { return cast(uint) Bits(16, 3); }
    bool PredicateNegated() const { return Bit(19); }
    bool Unconditional() const { return Predicate == PredicateTrue && !PredicateNegated; }
    uint SecondPredicate() const { return cast(uint) Bits(39, 3); }
    bool SecondPredicateNegated() const { return Bit(42); }

    uint CbufIndex() const { return cast(uint) Bits(34, 5); }
    uint CbufOffset() const { return cast(uint) Bits(20, 14) * 4; }

    float Imm20Float() const {
        return BitsToFloat(cast(uint) (Bits(20, 19) << 12) | (Bit(56) ? 0x8000_0000 : 0));
    }

    int Imm20Signed() const {
        const int value = cast(int) Bits(20, 19);
        return Bit(56) ? value - (1 << 19) : value;
    }

    uint Imm32() const { return cast(uint) Bits(20, 32); }
    float Imm32Float() const { return BitsToFloat(Imm32); }
    uint TextureOffset() const { return cast(uint) Bits(36, 13) * 4; }

    int BranchOffset() const {
        return cast(int) cast(uint) Bits(20, 24) << 8 >> 8;
    }

    string Disassemble() const {
        string guard = Unconditional ? "" : format("@%sP%d ", PredicateNegated ? "!" : "", Predicate);
        return format("%04X: %016X  %s%s d=R%d a=R%d b=R%d c=R%d", Address, Raw, guard, Name, Dest, SrcA, SrcB, SrcC);
    }
}

// Every 4 64bit word holds schedule control for the next three (0-3) insts
// I guess
bool IsScheduleWord(size_t index) {
    return index % 4 == 0;
}

string[] DisassembleProgram(const(ulong)[] program, size_t headerWords) {
    string[] lines;
    foreach (i; headerWords .. program.length) {
        const size_t index = i - headerWords;
        if (IsScheduleWord(index))
            continue;
        lines ~= Instruction.Decode(program[i], index * 8).Disassemble();
    }
    return lines;
}

bool IsTextureOp(Opcode op) {
    return op == Opcode.Tex || op == Opcode.Texs || op == Opcode.Tld || op == Opcode.Tlds;
}

uint[] TextureOffsets(const(ulong)[] program, size_t headerWords) {
    uint[] offsets;
    foreach (i; headerWords .. program.length) {
        const size_t index = i - headerWords;
        if (IsScheduleWord(index))
            continue;
        const Instruction instruction = Instruction.Decode(program[i], index * 8);
        if (!IsTextureOp(instruction.Op))
            continue;
        bool seen = false;
        foreach (offset; offsets)
            seen |= offset == instruction.TextureOffset;
        if (!seen)
            offsets ~= instruction.TextureOffset;
    }
    return offsets;
}
