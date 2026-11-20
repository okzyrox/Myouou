/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell MME interpreter
*/

module Source.Gpu.Macro;

// Core
import Source.Util.Logger;

// Types
enum MacroOperation : uint {
    Alu = 0,
    AddImmediate = 1,
    ExtractInsert = 2,
    ExtractShiftLeftImmediate = 3,
    ExtractShiftLeftRegister = 4,
    Read = 5,
    Unused = 6,
    Branch = 7,
}

enum MacroResult : uint {
    IgnoreAndFetch = 0,
    Move = 1,
    MoveAndSetMethod = 2,
    FetchAndSend = 3,
    MoveAndSend = 4,
    FetchAndSetMethod = 5,
    MoveAndSetMethodFetchAndSend = 6,
    MoveAndSetMethodSend = 7,
}

enum MacroAlu : uint {
    Add = 0,
    AddWithCarry = 1,
    Subtract = 2,
    SubtractWithBorrow = 3,
    Xor = 8,
    Or = 9,
    And = 10,
    AndNot = 11,
    Nand = 12,
}

struct MacroOpcode {
    uint Raw;

    MacroOperation Operation() const { return cast(MacroOperation) (Raw & 7); }
    MacroResult Result() const { return cast(MacroResult) ((Raw >> 4) & 7); }
    bool BranchNotZero() const { return ((Raw >> 4) & 1) != 0; }
    bool BranchAnnul() const { return ((Raw >> 5) & 1) != 0; }
    bool IsExit() const { return ((Raw >> 7) & 1) != 0; }
    uint Dst() const { return (Raw >> 8) & 7; }
    uint SrcA() const { return (Raw >> 11) & 7; }
    uint SrcB() const { return (Raw >> 14) & 7; }
    int Immediate() const { return cast(int) Raw >> 14; }
    MacroAlu AluOperation() const { return cast(MacroAlu) ((Raw >> 17) & 0x1F); }
    uint SrcBit() const { return (Raw >> 17) & 0x1F; }
    uint Size() const { return (Raw >> 22) & 0x1F; }
    uint DstBit() const { return (Raw >> 27) & 0x1F; }
    uint Mask() const { return Size >= 32 ? uint.max : (1u << Size) - 1; }
}

interface MacroHost {
    uint ReadRegister(uint method);
    void CallMethodFromMacro(uint method, uint argument);
}

// Class
final class MacroEngine {
    enum size_t CodeSize = 0x2000;
    enum size_t EntryCount = 0x80;
    enum size_t StepLimit = 1_000_000;

    uint[CodeSize] Code;
    uint[EntryCount] Entries;

    private MacroHost host;
    private uint[8] registers;
    private const(uint)[] parameters;
    private size_t nextParameter;
    private bool carry;
    private uint methodAddress;
    private uint methodIncrement;
    private uint pc;
    private bool hasDelayedPc;
    private uint delayedPc;
    private size_t steps;
    private Logger log;

    this(MacroHost host) {
        this.host = host;
        log = GetLogger("Gpu::Macro");
    }

    void Execute(uint index, const(uint)[] arguments) {
        if (index >= EntryCount) {
            log.Warn("Macro %d went out of range!", index);
            return;
        }
        registers[] = 0;
        parameters = arguments;
        nextParameter = 1;
        registers[1] = arguments.length > 0 ? arguments[0] : 0;
        carry = false;
        methodAddress = 0;
        methodIncrement = 0;
        hasDelayedPc = false;
        pc = Entries[index] * 4;
        steps = 0;

        while (Step(false)) {
            if (++steps > StepLimit) {
                log.Error("Macro %d did not exit!", index);
                return;
            }
        }
    }

    private uint Fetch() {
        if (nextParameter >= parameters.length) {
            log.Warn("Macro tried to fetch past its parameters (%d)!", parameters.length);
            return 0;
        }
        return parameters[nextParameter++];
    }

    private void SetRegister(uint index, uint value) {
        if (index != 0)
            registers[index] = value;
    }

    private void SetMethodAddress(uint value) {
        methodAddress = value & 0xFFF;
        methodIncrement = (value >> 12) & 0x3F;
    }

    private void Send(uint value) {
        host.CallMethodFromMacro(methodAddress, value);
        methodAddress += methodIncrement;
    }

    private uint Alu(MacroAlu operation, uint a, uint b) {
        ulong wide;
        switch (operation) {
            case MacroAlu.Add:
                wide = cast(ulong) a + b;
                carry = wide > uint.max;
                return cast(uint) wide;
            case MacroAlu.AddWithCarry:
                wide = cast(ulong) a + b + (carry ? 1 : 0);
                carry = wide > uint.max;
                return cast(uint) wide;
            case MacroAlu.Subtract:
                wide = cast(ulong) a - b;
                carry = wide < 0x1_0000_0000;
                return cast(uint) wide;
            case MacroAlu.SubtractWithBorrow:
                wide = cast(ulong) a - b - (carry ? 0 : 1);
                carry = wide < 0x1_0000_0000;
                return cast(uint) wide;
            case MacroAlu.Xor: return a ^ b;
            case MacroAlu.Or: return a | b;
            case MacroAlu.And: return a & b;
            case MacroAlu.AndNot: return a & ~b;
            case MacroAlu.Nand: return ~(a & b);
            default:
                log.Warn("Unknown macro ALU op %d", operation);
                return 0;
        }
    }

    private void ProcessResult(MacroResult result, uint dst, uint value) {
        final switch (result) {
            case MacroResult.IgnoreAndFetch:
                SetRegister(dst, Fetch());
                break;
            case MacroResult.Move:
                SetRegister(dst, value);
                break;
            case MacroResult.MoveAndSetMethod:
                SetRegister(dst, value);
                SetMethodAddress(value);
                break;
            case MacroResult.FetchAndSend:
                SetRegister(dst, Fetch());
                Send(value);
                break;
            case MacroResult.MoveAndSend:
                SetRegister(dst, value);
                Send(value);
                break;
            case MacroResult.FetchAndSetMethod:
                SetRegister(dst, Fetch());
                SetMethodAddress(value);
                break;
            case MacroResult.MoveAndSetMethodFetchAndSend:
                SetRegister(dst, value);
                SetMethodAddress(value);
                Send(Fetch());
                break;
            case MacroResult.MoveAndSetMethodSend:
                SetRegister(dst, value);
                SetMethodAddress(value);
                Send((value >> 12) & 0x3F);
                break;
        }
    }

    private bool Step(bool isDelaySlot) {
        const uint baseAddress = pc;
        const MacroOpcode opcode = MacroOpcode(Code[(pc / 4) % CodeSize]);
        pc += 4;
        if (hasDelayedPc) {
            pc = delayedPc;
            hasDelayedPc = false;
        }

        switch (opcode.Operation) {
            case MacroOperation.Alu:
                ProcessResult(opcode.Result, opcode.Dst, Alu(opcode.AluOperation, registers[opcode.SrcA], registers[opcode.SrcB]));
                break;
            case MacroOperation.AddImmediate:
                ProcessResult(opcode.Result, opcode.Dst, registers[opcode.SrcA] + opcode.Immediate);
                break;
            case MacroOperation.ExtractInsert: {
                uint destination = registers[opcode.SrcA];
                const uint source = (registers[opcode.SrcB] >> opcode.SrcBit) & opcode.Mask;
                destination &= ~(opcode.Mask << opcode.DstBit);
                destination |= source << opcode.DstBit;
                ProcessResult(opcode.Result, opcode.Dst, destination);
                break;
            }
            case MacroOperation.ExtractShiftLeftImmediate: {
                const uint shift = registers[opcode.SrcA];
                const uint source = registers[opcode.SrcB];
                ProcessResult(opcode.Result, opcode.Dst, ((source >> shift) & opcode.Mask) << opcode.DstBit);
                break;
            }
            case MacroOperation.ExtractShiftLeftRegister: {
                const uint shift = registers[opcode.SrcA];
                const uint source = registers[opcode.SrcB];
                ProcessResult(opcode.Result, opcode.Dst, ((source >> opcode.SrcBit) & opcode.Mask) << shift);
                break;
            }
            case MacroOperation.Read:
                ProcessResult(opcode.Result, opcode.Dst, host.ReadRegister(registers[opcode.SrcA] + opcode.Immediate));
                break;
            case MacroOperation.Branch: {
                const uint value = registers[opcode.SrcA];
                const bool taken = opcode.BranchNotZero ? value != 0 : value == 0;
                if (taken) {
                    const uint target = baseAddress + opcode.Immediate * 4;
                    if (opcode.BranchAnnul) {
                        pc = target;
                        return true;
                    }
                    delayedPc = target;
                    hasDelayedPc = true;
                    return Step(true);
                }
                break;
            }
            default:
                log.Warn("Unknown macro operation: %d", opcode.Operation);
                break;
        }

        if (opcode.IsExit && !isDelaySlot) {
            Step(true);
            return false;
        }
        return true;
    }
}
