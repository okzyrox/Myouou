/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Maxwell shader to SPIRV translator
*/

module Source.Gpu.Shader.Translator;

// Std
import std.format : format;

// Core
import Source.Gpu.Shader.Instructions;
import Source.Gpu.Shader.Spirv;

// Types
enum ShaderStageKind {
    Vertex,
    Fragment,
}

enum uint ShaderHeaderWords = 10;
enum uint MaxShaderInstructions = 0x4000;
enum uint MaxVaryings = 32;
enum uint MaxColorTargets = 8;
enum uint EntryAddress = 8;

enum AttributeOffset : uint {
    Position = 0x70,
    Generic = 0x80,
    GenericEnd = 0x280,
    InstanceId = 0x2F8,
    VertexId = 0x2FC,
    FrontFacing = 0x3FC,
}

private immutable GlslStd[4] RoundingModes = [GlslStd.RoundEven, GlslStd.Floor, GlslStd.Ceil, GlslStd.Trunc];

struct TranslatedShader {
    ShaderStageKind Stage;
    uint[] Spirv;
    bool Ok;
    string Error;
    uint AttributeMask;
    uint ColorTargetMask;
    uint[] ConstBuffers;
    size_t InstructionCount;
}

class ShaderTranslationException : Exception {
    this(string message) {
        super(message);
    }
}

TranslatedShader TranslateShader(ShaderStageKind stage, const(ulong)[] program) {
    TranslatedShader result;
    result.Stage = stage;
    try {
        ShaderTranslator translator = new ShaderTranslator(stage, program);
        result.Spirv = translator.Translate();
        result.AttributeMask = translator.attributeMask;
        result.ColorTargetMask = translator.colorTargetMask;
        result.ConstBuffers = translator.constBufferOrder;
        result.InstructionCount = translator.instructionCount;
        result.Ok = true;
    } catch (ShaderTranslationException exception) {
        result.Error = exception.msg;
    }
    return result;
}

// Translator
private final class ShaderTranslator {
    ShaderStageKind stage;
    const(ulong)[] program;
    SpirvBuilder b;

    uint attributeMask;
    uint colorTargetMask;
    uint[] constBufferOrder;
    size_t instructionCount;

    private uint[256] registers;
    private uint[7] predicates;
    private uint[32] attributeInputs;
    private uint[MaxVaryings] varyings;
    private uint[MaxColorTargets] colorOutputs;
    private uint[uint] constBuffers;
    private uint position;
    private uint fragCoord;
    private uint vertexIndex;
    private uint instanceIndex;
    private uint frontFacing;
    private uint viewParams;
    private uint[] interfaceIds;
    private bool terminated;

    this(ShaderStageKind stage, const(ulong)[] program) {
        this.stage = stage;
        this.program = program;
        b = new SpirvBuilder();
    }

    private void Fail(A...)(string text, A args) {
        throw new ShaderTranslationException(format(text, args));
    }

    // Registers & predicates
    private uint RegisterVariable(uint index) {
        if (registers[index] == 0) {
            registers[index] = b.FunctionVariable(b.TypePointer(SpvStorage.Function, b.Uint));
            b.Name(registers[index], format("R%d", index));
        }
        return registers[index];
    }

    private uint Reg(uint index) {
        if (index == RegisterZero)
            return b.ConstantUint(0);
        return b.Load(b.Uint, RegisterVariable(index));
    }

    private void SetReg(uint index, uint value) {
        if (index != RegisterZero)
            b.Store(RegisterVariable(index), value);
    }

    private uint ToFloat(uint value) {
        return b.Value(SpvOp.Bitcast, b.Float, [value]);
    }

    private uint ToUint(uint value) {
        return b.Value(SpvOp.Bitcast, b.Uint, [value]);
    }

    private uint RegF(uint index) {
        return ToFloat(Reg(index));
    }

    private void SetRegF(uint index, uint value) {
        SetReg(index, ToUint(value));
    }

    private uint PredicateVariable(uint index) {
        if (predicates[index] == 0) {
            predicates[index] = b.FunctionVariable(b.TypePointer(SpvStorage.Function, b.Bool));
            b.Name(predicates[index], format("P%d", index));
        }
        return predicates[index];
    }

    private uint Pred(uint index, bool negate) {
        uint value = index == PredicateTrue ? b.ConstantBool(true) : b.Load(b.Bool, PredicateVariable(index));
        if (negate)
            value = b.Value(SpvOp.LogicalNot, b.Bool, [value]);
        return value;
    }

    private void SetPred(uint index, uint value) {
        if (index != PredicateTrue)
            b.Store(PredicateVariable(index), value);
    }

    private uint SecondPred(const ref Instruction instruction) {
        return Pred(instruction.SecondPredicate, instruction.SecondPredicateNegated);
    }

    // Buffers
    private uint ConstBufferVariable(uint index) {
        if (uint* found = index in constBuffers)
            return *found;
        const uint array = b.TypeRuntimeArray(b.Uint);
        b.Decorate(array, SpvDecoration.ArrayStride, [4]);
        const uint block = b.TypeStructUnique([array]);
        b.Decorate(block, SpvDecoration.BufferBlock);
        b.MemberDecorate(block, 0, SpvDecoration.Offset, [0]);
        b.MemberDecorate(block, 0, SpvDecoration.NonWritable);
        const uint variable = b.GlobalVariable(b.TypePointer(SpvStorage.Uniform, block), SpvStorage.Uniform);
        b.Decorate(variable, SpvDecoration.DescriptorSet, [stage == ShaderStageKind.Vertex ? 0 : 2]); // fragment storage buffers at set 2
        b.Decorate(variable, SpvDecoration.Binding, [cast(uint) constBufferOrder.length]);
        b.Name(variable, format("cbuf%d", index));
        constBuffers[index] = variable;
        constBufferOrder ~= index;
        return variable;
    }

    private uint ConstBufferWord(uint index, uint wordIndex) {
        const uint pointer = b.Value(SpvOp.AccessChain, b.TypePointer(SpvStorage.Uniform, b.Uint), [ConstBufferVariable(index), b.ConstantUint(0), wordIndex]);
        return b.Load(b.Uint, pointer);
    }

    private uint Cbuf(uint index, uint byteOffset) {
        return ConstBufferWord(index, b.ConstantUint(byteOffset / 4));
    }

    // Interface
    private uint InterfaceVariable(SpvStorage storage, uint type) {
        const uint variable = b.GlobalVariable(b.TypePointer(storage, type), storage);
        interfaceIds ~= variable;
        return variable;
    }

    private uint BuiltIn(SpvStorage storage, uint type, SpvBuiltIn builtIn, string name) {
        const uint variable = InterfaceVariable(storage, type);
        b.Decorate(variable, SpvDecoration.BuiltIn, [builtIn]);
        b.Name(variable, name);
        return variable;
    }

    private uint AttributeInput(uint index) {
        if (attributeInputs[index] == 0) {
            attributeInputs[index] = InterfaceVariable(SpvStorage.Input, b.Vec4);
            b.Decorate(attributeInputs[index], SpvDecoration.Location, [index]);
            b.Name(attributeInputs[index], format("attr%d", index));
            attributeMask |= 1u << index;
        }
        return attributeInputs[index];
    }

    private uint Varying(uint index) {
        if (index >= MaxVaryings)
            Fail("Varying %d out of range", index);
        if (varyings[index] == 0) {
            const SpvStorage storage = stage == ShaderStageKind.Vertex ? SpvStorage.Output : SpvStorage.Input;
            varyings[index] = InterfaceVariable(storage, b.Vec4);
            b.Decorate(varyings[index], SpvDecoration.Location, [index]);
            b.Name(varyings[index], format("varying%d", index));
        }
        return varyings[index];
    }

    private uint Position() {
        if (position == 0)
            position = BuiltIn(SpvStorage.Output, b.Vec4, SpvBuiltIn.Position, "position");
        return position;
    }

    private uint FragCoord() {
        if (fragCoord == 0)
            fragCoord = BuiltIn(SpvStorage.Input, b.Vec4, SpvBuiltIn.FragCoord, "fragCoord");
        return fragCoord;
    }

    private uint ColorOutput(uint index) {
        if (colorOutputs[index] == 0) {
            colorOutputs[index] = InterfaceVariable(SpvStorage.Output, b.Vec4);
            b.Decorate(colorOutputs[index], SpvDecoration.Location, [index]);
            b.Name(colorOutputs[index], format("color%d", index));
            colorTargetMask |= 1u << index;
        }
        return colorOutputs[index];
    }

    private uint ViewParams() {
        if (viewParams == 0) {
            const uint block = b.TypeStructUnique([b.Vec4]);
            b.Decorate(block, SpvDecoration.Block);
            b.MemberDecorate(block, 0, SpvDecoration.Offset, [0]);
            viewParams = b.GlobalVariable(b.TypePointer(SpvStorage.Uniform, block), SpvStorage.Uniform);
            b.Decorate(viewParams, SpvDecoration.DescriptorSet, [1]);
            b.Decorate(viewParams, SpvDecoration.Binding, [0]);
            b.Name(viewParams, "viewParams");
        }
        return viewParams;
    }

    private uint Component(uint variable, SpvStorage storage, uint component) {
        return b.Value(SpvOp.AccessChain, b.TypePointer(storage, b.Float), [variable, b.ConstantUint(component)]);
    }
    private static bool IsPosition(uint offset) {
        return offset >= AttributeOffset.Position && offset < AttributeOffset.Generic;
    }

    private static bool IsVarying(uint offset) {
        return offset >= AttributeOffset.Generic && offset < AttributeOffset.Generic + MaxVaryings * 16;
    }

    private static uint GenericIndex(uint offset) {
        return (offset - AttributeOffset.Generic) / 16;
    }

    private static uint ComponentIndex(uint offset) {
        return (offset / 4) % 4;
    }

    private uint LoadAttribute(uint offset) {
        if (stage == ShaderStageKind.Vertex) {
            if (offset >= AttributeOffset.Generic && offset < AttributeOffset.GenericEnd)
                return ToUint(b.Load(b.Float, Component(AttributeInput(GenericIndex(offset)), SpvStorage.Input, ComponentIndex(offset))));
            if (offset == AttributeOffset.VertexId) {
                if (vertexIndex == 0)
                    vertexIndex = BuiltIn(SpvStorage.Input, b.Int, SpvBuiltIn.VertexIndex, "vertexIndex");
                return ToUint(b.Load(b.Int, vertexIndex));
            }
            if (offset == AttributeOffset.InstanceId) {
                if (instanceIndex == 0)
                    instanceIndex = BuiltIn(SpvStorage.Input, b.Int, SpvBuiltIn.InstanceIndex, "instanceIndex");
                return ToUint(b.Load(b.Int, instanceIndex));
            }

            // doesnt do all of the offsets
            // im lazy
            return b.ConstantUint(0);
        }

        if (IsPosition(offset))
            return ToUint(b.Load(b.Float, Component(FragCoord(), SpvStorage.Input, ComponentIndex(offset))));
        if (IsVarying(offset))
            return ToUint(b.Load(b.Float, Component(Varying(GenericIndex(offset)), SpvStorage.Input, ComponentIndex(offset))));
        if (offset == AttributeOffset.FrontFacing) {
            if (frontFacing == 0)
                frontFacing = BuiltIn(SpvStorage.Input, b.Bool, SpvBuiltIn.FrontFacing, "frontFacing");
            return b.Value(SpvOp.Select, b.Uint, [b.Load(b.Bool, frontFacing), b.ConstantUint(uint.max), b.ConstantUint(0)]);
        }
        return b.ConstantUint(0);
    }

    private void StoreAttribute(uint offset, uint value) {
        if (stage != ShaderStageKind.Vertex)
            Fail("AST outside of a vertex shader");
        if (IsPosition(offset))
            b.Store(Component(Position(), SpvStorage.Output, ComponentIndex(offset)), ToFloat(value));
        else if (IsVarying(offset))
            b.Store(Component(Varying(GenericIndex(offset)), SpvStorage.Output, ComponentIndex(offset)), ToFloat(value));
    }

    // Operand helpers
    private uint FloatOperandB(const ref Instruction instruction) {
        switch (instruction.Op) {
            case Opcode.FaddReg, Opcode.FmulReg, Opcode.FmnmxReg, Opcode.FsetpReg, Opcode.FsetReg, Opcode.FfmaReg,
                 Opcode.MovReg, Opcode.RroReg, Opcode.F2fReg, Opcode.F2iReg:
                return RegF(instruction.SrcB);
            case Opcode.FaddCbuf, Opcode.FmulCbuf, Opcode.FmnmxCbuf, Opcode.FsetpCbuf, Opcode.FsetCbuf, Opcode.FfmaCr,
                 Opcode.MovCbuf, Opcode.RroCbuf, Opcode.F2fCbuf, Opcode.F2iCbuf:
                return ToFloat(Cbuf(instruction.CbufIndex, instruction.CbufOffset));
            case Opcode.FfmaRc:
                return RegF(instruction.SrcC);
            default:
                return b.ConstantFloat(instruction.Imm20Float);
        }
    }

    private uint IntOperandB(const ref Instruction instruction) {
        switch (instruction.Op) {
            case Opcode.IaddReg, Opcode.IscaddReg, Opcode.IsetpReg, Opcode.LopReg, Opcode.Lop3Reg, Opcode.SelReg,
                 Opcode.ShlReg, Opcode.ShrReg, Opcode.I2fReg, Opcode.I2iReg:
                return Reg(instruction.SrcB);
            case Opcode.IaddCbuf, Opcode.IscaddCbuf, Opcode.IsetpCbuf, Opcode.LopCbuf, Opcode.Lop3Cbuf, Opcode.SelCbuf,
                 Opcode.ShlCbuf, Opcode.ShrCbuf, Opcode.I2fCbuf, Opcode.I2iCbuf:
                return Cbuf(instruction.CbufIndex, instruction.CbufOffset);
            default:
                return b.ConstantUint(cast(uint) instruction.Imm20Signed);
        }
    }

    private uint AbsNeg(uint value, bool absolute, bool negate) {
        if (absolute)
            value = b.Ext(b.Float, GlslStd.FAbs, [value]);
        if (negate)
            value = b.Value(SpvOp.FNegate, b.Float, [value]);
        return value;
    }

    private uint Saturate(uint value, bool saturate) {
        if (!saturate)
            return value;
        return b.Ext(b.Float, GlslStd.FClamp, [value, b.ConstantFloat(0), b.ConstantFloat(1)]);
    }

    private uint FloatCompare(uint condition, uint lhs, uint rhs) {
        static immutable SpvOp[16] ops = [
            SpvOp.Nop, SpvOp.FOrdLessThan, SpvOp.FOrdEqual, SpvOp.FOrdLessThanEqual,
            SpvOp.FOrdGreaterThan, SpvOp.FOrdNotEqual, SpvOp.FOrdGreaterThanEqual, SpvOp.Nop,
            SpvOp.Nop, SpvOp.FUnordLessThan, SpvOp.FUnordEqual, SpvOp.FUnordLessThanEqual,
            SpvOp.FUnordGreaterThan, SpvOp.FUnordNotEqual, SpvOp.FUnordGreaterThanEqual, SpvOp.Nop,
        ];
        if (condition == 0)
            return b.ConstantBool(false);
        if (condition == 15)
            return b.ConstantBool(true);
        if (condition == 7 || condition == 8) {
            const uint nanA = b.Value(SpvOp.IsNan, b.Bool, [lhs]);
            const uint nanB = b.Value(SpvOp.IsNan, b.Bool, [rhs]);
            const uint anyNan = b.Value(SpvOp.LogicalOr, b.Bool, [nanA, nanB]);
            return condition == 8 ? anyNan : b.Value(SpvOp.LogicalNot, b.Bool, [anyNan]);
        }
        return b.Value(ops[condition], b.Bool, [lhs, rhs]);
    }

    private uint IntCompare(uint condition, bool signed, uint lhs, uint rhs) {
        switch (condition) {
            case 0: return b.ConstantBool(false);
            case 1: return b.Value(signed ? SpvOp.SLessThan : SpvOp.ULessThan, b.Bool, [lhs, rhs]);
            case 2: return b.Value(SpvOp.IEqual, b.Bool, [lhs, rhs]);
            case 3: return b.Value(signed ? SpvOp.SLessThanEqual : SpvOp.ULessThanEqual, b.Bool, [lhs, rhs]);
            case 4: return b.Value(signed ? SpvOp.SGreaterThan : SpvOp.UGreaterThan, b.Bool, [lhs, rhs]);
            case 5: return b.Value(SpvOp.INotEqual, b.Bool, [lhs, rhs]);
            case 6: return b.Value(signed ? SpvOp.SGreaterThanEqual : SpvOp.UGreaterThanEqual, b.Bool, [lhs, rhs]);
            default: return b.ConstantBool(true);
        }
    }

    private uint Combine(uint operation, uint lhs, uint rhs) {
        switch (operation) {
            case 0: return b.Value(SpvOp.LogicalAnd, b.Bool, [lhs, rhs]);
            case 1: return b.Value(SpvOp.LogicalOr, b.Bool, [lhs, rhs]);
            case 2: return b.Value(SpvOp.LogicalNotEqual, b.Bool, [lhs, rhs]);
            default: Fail("Unknown predicate combine %d", operation); return 0;
        }
    }

    private void WritePredicatePair(const ref Instruction instruction, uint result) {
        const uint other = SecondPred(instruction);
        const uint operation = cast(uint) instruction.Bits(45, 2);
        const uint inverted = b.Value(SpvOp.LogicalNot, b.Bool, [result]);
        SetPred(cast(uint) instruction.Bits(3, 3), Combine(operation, result, other));
        SetPred(cast(uint) instruction.Bits(0, 3), Combine(operation, inverted, other));
    }

    private uint LogicOp(uint operation, uint lhs, uint rhs) {
        switch (operation) {
            case 0: return b.Value(SpvOp.BitwiseAnd, b.Uint, [lhs, rhs]);
            case 1: return b.Value(SpvOp.BitwiseOr, b.Uint, [lhs, rhs]);
            case 2: return b.Value(SpvOp.BitwiseXor, b.Uint, [lhs, rhs]);
            default: return rhs;
        }
    }

    private uint Lut3(uint lut, uint a, uint bValue, uint c) {
        uint result = b.ConstantUint(0);
        const uint notA = b.Value(SpvOp.Not, b.Uint, [a]);
        const uint notB = b.Value(SpvOp.Not, b.Uint, [bValue]);
        const uint notC = b.Value(SpvOp.Not, b.Uint, [c]);
        foreach (term; 0 .. 8) {
            if ((lut & (1 << term)) == 0)
                continue;
            uint value = b.Value(SpvOp.BitwiseAnd, b.Uint, [(term & 4) ? a : notA, (term & 2) ? bValue : notB]);
            value = b.Value(SpvOp.BitwiseAnd, b.Uint, [value, (term & 1) ? c : notC]);
            result = b.Value(SpvOp.BitwiseOr, b.Uint, [result, value]);
        }
        return result;
    }

    private void Epilogue() {
        if (stage == ShaderStageKind.Vertex)
            VertexEpilogue();
        else
            FragmentEpilogue();
    }

    private uint Extract(uint composite, uint index) {
        return b.Value(SpvOp.CompositeExtract, b.Float, [composite, index]);
    }

    private void VertexEpilogue() {
        if (position == 0)
            return;
        const uint params = b.Load(b.Vec4, b.Value(SpvOp.AccessChain, b.TypePointer(SpvStorage.Uniform, b.Vec4), [ViewParams(), b.ConstantUint(0)]));
        const uint value = b.Load(b.Vec4, Position());
        const uint x = Extract(value, 0);
        const uint y = b.Value(SpvOp.FMul, b.Float, [Extract(value, 1), Extract(params, 0)]);
        const uint z = Extract(value, 2);
        const uint w = Extract(value, 3);
        const uint depth = b.Ext(b.Float, GlslStd.Fma, [z, Extract(params, 1), b.Value(SpvOp.FMul, b.Float, [w, Extract(params, 2)])]);
        b.Store(Position(), b.Value(SpvOp.CompositeConstruct, b.Vec4, [x, y, depth, w]));
    }

    private void FragmentEpilogue() {
        const uint outputMap = cast(uint) program[9];
        uint registerIndex = 0;
        foreach (target; 0 .. MaxColorTargets) {
            const uint mask = (outputMap >> (target * 4)) & 0xF;
            if (mask == 0)
                continue;
            uint[4] components;
            foreach (component; 0 .. 4) {
                if ((mask & (1 << component)) != 0)
                    components[component] = RegF(registerIndex++);
                else
                    components[component] = b.ConstantFloat(component == 3 ? 1 : 0);
            }
            b.Store(ColorOutput(target), b.Value(SpvOp.CompositeConstruct, b.Vec4, components[]));
        }
    }

    // Instruction translation
    private void Emit(const ref Instruction instruction) {
        switch (instruction.Op) {
            // below is really messy
            case Opcode.Nop, Opcode.Depbar, Opcode.Ssy, Opcode.Pbk, Opcode.Pcnt, Opcode.Sync, Opcode.Brk, Opcode.Cont, Opcode.Bra:
                return;

            case Opcode.Exit:
                Epilogue();
                b.Op(SpvOp.Return, []);
                terminated = true;
                return;

            case Opcode.Kil:
                if (stage != ShaderStageKind.Fragment)
                    Fail("KIL outside of a fragment shader");
                b.Op(SpvOp.Kill, []);
                terminated = true;
                return;

            case Opcode.MovReg:
                SetReg(instruction.Dest, Reg(instruction.SrcB));
                return;
            case Opcode.MovCbuf:
                SetReg(instruction.Dest, Cbuf(instruction.CbufIndex, instruction.CbufOffset));
                return;
            case Opcode.MovImm:
                SetReg(instruction.Dest, b.ConstantUint(cast(uint) instruction.Imm20Signed));
                return;
            case Opcode.Mov32i:
                SetReg(instruction.Dest, b.ConstantUint(instruction.Imm32));
                return;

            case Opcode.Ald: {
                if (instruction.SrcA != RegisterZero || instruction.Bit(32))
                    Fail("Indexed or output ALD at 0x%X", instruction.Address);
                const uint offset = cast(uint) instruction.Bits(20, 10);
                foreach (word; 0 .. instruction.Bits(47, 2) + 1)
                    SetReg(instruction.Dest + cast(uint) word, LoadAttribute(offset + cast(uint) word * 4));
                return;
            }
            case Opcode.Ast: {
                if (instruction.SrcA != RegisterZero)
                    Fail("Indexed AST at 0x%X", instruction.Address);
                const uint offset = cast(uint) instruction.Bits(20, 10);
                foreach (word; 0 .. instruction.Bits(47, 2) + 1)
                    StoreAttribute(offset + cast(uint) word * 4, Reg(instruction.Dest + cast(uint) word));
                return;
            }
            case Opcode.Ipa: {
                if (instruction.SrcA != RegisterZero || instruction.Bit(38))
                    Fail("Indexed IPA at 0x%X", instruction.Address);
                const uint offset = cast(uint) instruction.Bits(28, 10);
                uint value = ToFloat(LoadAttribute(offset));
                value = Saturate(value, instruction.Bit(51));
                SetRegF(instruction.Dest, value);
                return;
            }

            case Opcode.FaddReg, Opcode.FaddCbuf, Opcode.FaddImm: {
                const uint a = AbsNeg(RegF(instruction.SrcA), instruction.Bit(46), instruction.Bit(48));
                const uint bValue = AbsNeg(FloatOperandB(instruction), instruction.Bit(49), instruction.Bit(45));
                SetRegF(instruction.Dest, Saturate(b.Value(SpvOp.FAdd, b.Float, [a, bValue]), instruction.Bit(50)));
                return;
            }
            case Opcode.Fadd32i: {
                const uint a = AbsNeg(RegF(instruction.SrcA), instruction.Bit(54), instruction.Bit(56));
                const float immediate = instruction.Imm32Float;
                SetRegF(instruction.Dest, b.Value(SpvOp.FAdd, b.Float, [a, b.ConstantFloat(immediate)]));
                return;
            }
            case Opcode.FmulReg, Opcode.FmulCbuf, Opcode.FmulImm: {
                const uint a = RegF(instruction.SrcA);
                const uint bValue = AbsNeg(FloatOperandB(instruction), false, instruction.Bit(48));
                SetRegF(instruction.Dest, Saturate(b.Value(SpvOp.FMul, b.Float, [a, bValue]), instruction.Bit(50)));
                return;
            }
            case Opcode.Fmul32i: {
                const float immediate = instruction.Imm32Float;
                const uint value = b.Value(SpvOp.FMul, b.Float, [RegF(instruction.SrcA), b.ConstantFloat(immediate)]);
                SetRegF(instruction.Dest, Saturate(value, instruction.Bit(55)));
                return;
            }
            case Opcode.FfmaReg, Opcode.FfmaCr, Opcode.FfmaRc, Opcode.FfmaImm: {
                const uint a = RegF(instruction.SrcA);
                const uint bValue = AbsNeg(FloatOperandB(instruction), false, instruction.Bit(48));
                uint c;
                if (instruction.Op == Opcode.FfmaRc)
                    c = ToFloat(Cbuf(instruction.CbufIndex, instruction.CbufOffset));
                else
                    c = RegF(instruction.SrcC);
                c = AbsNeg(c, false, instruction.Bit(49));
                SetRegF(instruction.Dest, Saturate(b.Ext(b.Float, GlslStd.Fma, [a, bValue, c]), instruction.Bit(50)));
                return;
            }
            case Opcode.Ffma32i: {
                const float immediate = instruction.Imm32Float;
                const uint a = AbsNeg(RegF(instruction.SrcA), false, instruction.Bit(56));
                const uint c = AbsNeg(RegF(instruction.Dest), false, instruction.Bit(57));
                const uint value = b.Ext(b.Float, GlslStd.Fma, [a, b.ConstantFloat(immediate), c]);
                SetRegF(instruction.Dest, Saturate(value, instruction.Bit(55)));
                return;
            }
            case Opcode.FmnmxReg, Opcode.FmnmxCbuf, Opcode.FmnmxImm: {
                const uint a = AbsNeg(RegF(instruction.SrcA), instruction.Bit(46), instruction.Bit(48));
                const uint bValue = AbsNeg(FloatOperandB(instruction), instruction.Bit(49), instruction.Bit(45));
                const uint selectMin = SecondPred(instruction);
                const uint minimum = b.Ext(b.Float, GlslStd.FMin, [a, bValue]);
                const uint maximum = b.Ext(b.Float, GlslStd.FMax, [a, bValue]);
                SetRegF(instruction.Dest, b.Value(SpvOp.Select, b.Float, [selectMin, minimum, maximum]));
                return;
            }
            case Opcode.Mufu: {
                uint value = AbsNeg(RegF(instruction.SrcA), instruction.Bit(46), instruction.Bit(48));
                switch (instruction.Bits(20, 4)) {
                    case 0: value = b.Ext(b.Float, GlslStd.Cos, [value]); break;
                    case 1: value = b.Ext(b.Float, GlslStd.Sin, [value]); break;
                    case 2: value = b.Ext(b.Float, GlslStd.Exp2, [value]); break;
                    case 3: value = b.Ext(b.Float, GlslStd.Log2, [value]); break;
                    case 4: value = b.Value(SpvOp.FDiv, b.Float, [b.ConstantFloat(1), value]); break;
                    case 5: value = b.Ext(b.Float, GlslStd.InverseSqrt, [value]); break;
                    case 8: value = b.Ext(b.Float, GlslStd.Sqrt, [value]); break;
                    default: Fail("MUFU op %d", instruction.Bits(20, 4));
                }
                SetRegF(instruction.Dest, Saturate(value, instruction.Bit(50)));
                return;
            }
            case Opcode.RroReg, Opcode.RroCbuf, Opcode.RroImm:
                SetRegF(instruction.Dest, AbsNeg(FloatOperandB(instruction), instruction.Bit(49), instruction.Bit(45)));
                return;

            case Opcode.FsetpReg, Opcode.FsetpCbuf, Opcode.FsetpImm: {
                const uint a = AbsNeg(RegF(instruction.SrcA), instruction.Bit(7), instruction.Bit(43));
                const uint bValue = AbsNeg(FloatOperandB(instruction), instruction.Bit(44), instruction.Bit(6));
                WritePredicatePair(instruction, FloatCompare(cast(uint) instruction.Bits(48, 4), a, bValue));
                return;
            }
            case Opcode.FsetReg, Opcode.FsetCbuf, Opcode.FsetImm: {
                const uint a = AbsNeg(RegF(instruction.SrcA), instruction.Bit(54), instruction.Bit(43));
                const uint bValue = AbsNeg(FloatOperandB(instruction), instruction.Bit(44), instruction.Bit(53));
                const uint compared = FloatCompare(cast(uint) instruction.Bits(48, 4), a, bValue);
                const uint other = SecondPred(instruction);
                const uint result = Combine(cast(uint) instruction.Bits(45, 2), compared, other);
                const uint trueValue = instruction.Bit(52) ? b.ConstantUint(0x3F80_0000) : b.ConstantUint(uint.max);
                SetReg(instruction.Dest, b.Value(SpvOp.Select, b.Uint, [result, trueValue, b.ConstantUint(0)]));
                return;
            }
            case Opcode.IsetpReg, Opcode.IsetpCbuf, Opcode.IsetpImm: {
                const uint compared = IntCompare(cast(uint) instruction.Bits(49, 3), instruction.Bit(48), Reg(instruction.SrcA), IntOperandB(instruction));
                WritePredicatePair(instruction, compared);
                return;
            }
            case Opcode.SelReg, Opcode.SelCbuf, Opcode.SelImm: {
                const uint condition = SecondPred(instruction);
                SetReg(instruction.Dest, b.Value(SpvOp.Select, b.Uint, [condition, Reg(instruction.SrcA), IntOperandB(instruction)]));
                return;
            }

            case Opcode.IaddReg, Opcode.IaddCbuf, Opcode.IaddImm: {
                uint a = Reg(instruction.SrcA);
                uint bValue = IntOperandB(instruction);
                if (instruction.Bit(49))
                    a = b.Value(SpvOp.SNegate, b.Uint, [a]);
                if (instruction.Bit(48))
                    bValue = b.Value(SpvOp.SNegate, b.Uint, [bValue]);
                SetReg(instruction.Dest, b.Value(SpvOp.IAdd, b.Uint, [a, bValue]));
                return;
            }
            case Opcode.Iadd32i: {
                uint a = Reg(instruction.SrcA);
                if (instruction.Bit(56))
                    a = b.Value(SpvOp.SNegate, b.Uint, [a]);
                SetReg(instruction.Dest, b.Value(SpvOp.IAdd, b.Uint, [a, b.ConstantUint(instruction.Imm32)]));
                return;
            }
            case Opcode.IscaddReg, Opcode.IscaddCbuf, Opcode.IscaddImm: {
                const uint shifted = b.Value(SpvOp.ShiftLeftLogical, b.Uint, [Reg(instruction.SrcA), b.ConstantUint(cast(uint) instruction.Bits(39, 5))]);
                SetReg(instruction.Dest, b.Value(SpvOp.IAdd, b.Uint, [shifted, IntOperandB(instruction)]));
                return;
            }
            case Opcode.ShlReg, Opcode.ShlCbuf, Opcode.ShlImm: {
                const uint amount = b.Value(SpvOp.BitwiseAnd, b.Uint, [IntOperandB(instruction), b.ConstantUint(31)]);
                SetReg(instruction.Dest, b.Value(SpvOp.ShiftLeftLogical, b.Uint, [Reg(instruction.SrcA), amount]));
                return;
            }
            case Opcode.ShrReg, Opcode.ShrCbuf, Opcode.ShrImm: {
                const uint amount = b.Value(SpvOp.BitwiseAnd, b.Uint, [IntOperandB(instruction), b.ConstantUint(31)]);
                const SpvOp op = instruction.Bit(48) ? SpvOp.ShiftRightArithmetic : SpvOp.ShiftRightLogical;
                SetReg(instruction.Dest, b.Value(op, b.Uint, [Reg(instruction.SrcA), amount]));
                return;
            }
            case Opcode.LopReg, Opcode.LopCbuf, Opcode.LopImm: {
                uint a = Reg(instruction.SrcA);
                uint bValue = IntOperandB(instruction);
                if (instruction.Bit(39))
                    a = b.Value(SpvOp.Not, b.Uint, [a]);
                if (instruction.Bit(40))
                    bValue = b.Value(SpvOp.Not, b.Uint, [bValue]);
                SetReg(instruction.Dest, LogicOp(cast(uint) instruction.Bits(41, 2), a, bValue));
                return;
            }
            case Opcode.Lop32i: {
                uint a = Reg(instruction.SrcA);
                uint bValue = b.ConstantUint(instruction.Imm32);
                if (instruction.Bit(55))
                    a = b.Value(SpvOp.Not, b.Uint, [a]);
                if (instruction.Bit(56))
                    bValue = b.Value(SpvOp.Not, b.Uint, [bValue]);
                SetReg(instruction.Dest, LogicOp(cast(uint) instruction.Bits(53, 2), a, bValue));
                return;
            }
            case Opcode.Lop3Reg, Opcode.Lop3Cbuf, Opcode.Lop3Imm: {
                const uint lut = cast(uint) (instruction.Op == Opcode.Lop3Reg ? instruction.Bits(28, 8) : instruction.Bits(48, 8));
                SetReg(instruction.Dest, Lut3(lut, Reg(instruction.SrcA), IntOperandB(instruction), Reg(instruction.SrcC)));
                return;
            }

            case Opcode.I2fReg, Opcode.I2fCbuf, Opcode.I2fImm: {
                const uint source = IntOperandB(instruction);
                const uint value = b.Value(instruction.Bit(13) ? SpvOp.ConvertSToF : SpvOp.ConvertUToF, b.Float,
                    [instruction.Bit(13) ? b.Value(SpvOp.Bitcast, b.Int, [source]) : source]);
                SetRegF(instruction.Dest, AbsNeg(value, instruction.Bit(49), instruction.Bit(45)));
                return;
            }
            case Opcode.F2iReg, Opcode.F2iCbuf, Opcode.F2iImm: {
                uint value = AbsNeg(FloatOperandB(instruction), instruction.Bit(49), instruction.Bit(45));
                value = b.Ext(b.Float, RoundingModes[instruction.Bits(39, 2)], [value]);
                if (instruction.Bit(12))
                    SetReg(instruction.Dest, ToUint(b.Value(SpvOp.ConvertFToS, b.Int, [value])));
                else
                    SetReg(instruction.Dest, b.Value(SpvOp.ConvertFToU, b.Uint, [value]));
                return;
            }
            case Opcode.F2fReg, Opcode.F2fCbuf, Opcode.F2fImm: {
                uint value = AbsNeg(FloatOperandB(instruction), instruction.Bit(49), instruction.Bit(45));
                if (instruction.Bit(42))
                    value = b.Ext(b.Float, RoundingModes[instruction.Bits(39, 2)], [value]);
                SetRegF(instruction.Dest, Saturate(value, instruction.Bit(50)));
                return;
            }
            case Opcode.I2iReg, Opcode.I2iCbuf, Opcode.I2iImm:
                SetReg(instruction.Dest, IntOperandB(instruction));
                return;

            case Opcode.Ldc: {
                const uint index = cast(uint) instruction.Bits(36, 5);
                const int offset = cast(int) (cast(uint) instruction.Bits(20, 16) << 16) >> 16;
                const uint address = b.Value(SpvOp.IAdd, b.Uint, [Reg(instruction.SrcA), b.ConstantUint(cast(uint) offset)]);
                const uint word = b.Value(SpvOp.ShiftRightLogical, b.Uint, [address, b.ConstantUint(2)]);
                SetReg(instruction.Dest, ConstBufferWord(index, word));
                if (instruction.Bits(48, 3) == 5)
                    SetReg(instruction.Dest + 1, ConstBufferWord(index, b.Value(SpvOp.IAdd, b.Uint, [word, b.ConstantUint(1)])));
                return;
            }
            case Opcode.S2r:
                SetReg(instruction.Dest, b.ConstantUint(0));
                return;

            default:
                Fail("Unsupported instruction %s (%016X) at 0x%X", instruction.Name, instruction.Raw, instruction.Address);
        }
    }

    private void EmitPredicated(const ref Instruction instruction) {
        if (instruction.Unconditional) {
            Emit(instruction);
            return;
        }
        const uint condition = Pred(instruction.Predicate, instruction.PredicateNegated);
        const uint body = b.NewId();
        const uint merge = b.NewId();
        b.Op(SpvOp.SelectionMerge, [merge, 0]);
        b.Op(SpvOp.BranchConditional, [condition, body, merge]);
        b.Label(body);
        terminated = false;
        Emit(instruction);
        if (!terminated)
            b.Op(SpvOp.Branch, [merge]);
        terminated = false;
        b.Label(merge);
    }

    private static bool IsFlowPush(Opcode op) {
        return op == Opcode.Ssy || op == Opcode.Pbk || op == Opcode.Pcnt;
    }

    private static bool IsFlowJump(Opcode op) {
        return op == Opcode.Bra || op == Opcode.Sync || op == Opcode.Brk || op == Opcode.Cont;
    }

    private static Opcode PushFor(Opcode op) {
        switch (op) {
            case Opcode.Sync: return Opcode.Ssy;
            case Opcode.Brk: return Opcode.Pbk;
            default: return Opcode.Pcnt;
        }
    }

    private static size_t NextAddress(size_t address) {
        size_t next = address + 8;
        if (IsScheduleWord(next / 8))
            next += 8;
        return next;
    }

    private Instruction InstructionAt(size_t address) {
        const size_t word = ShaderHeaderWords + address / 8;
        if (address / 8 > MaxShaderInstructions || word >= program.length || IsScheduleWord(address / 8))
            Fail("Control flow reaches 0x%X outside of the program", address);
        return Instruction.Decode(program[word], address);
    }

    private static size_t JumpTarget(const ref Instruction instruction) {
        size_t target = cast(size_t) (cast(long) instruction.Address + 8 + instruction.BranchOffset);
        if (IsScheduleWord(target / 8))
            target += 8;
        return target;
    }

    private bool HasControlFlow() {
        foreach (i; ShaderHeaderWords .. program.length) {
            const size_t index = i - ShaderHeaderWords;
            if (IsScheduleWord(index))
                continue;
            const Instruction instruction = Instruction.Decode(program[i], index * 8);
            if (IsFlowPush(instruction.Op) || IsFlowJump(instruction.Op))
                return true;
            if (instruction.Op == Opcode.Exit && instruction.Unconditional)
                return false;
        }
        return false;
    }

    private struct FlowEntry {
        Opcode Kind;
        size_t Target;
    }

    private struct PendingPath {
        size_t Address;
        FlowEntry[] Stack;
    }

    private FlowEntry[][size_t] stackAt;
    private size_t[size_t] jumpTargets;
    private bool[size_t] leaders;

    private static ptrdiff_t FindPush(const(FlowEntry)[] stack, Opcode kind) {
        foreach_reverse (i, entry; stack)
            if (entry.Kind == kind)
                return i;
        return -1;
    }

    private void AnalyzeFlow() {
        PendingPath[] pending = [PendingPath(EntryAddress, null)];
        leaders[EntryAddress] = true;
        while (pending.length > 0) {
            PendingPath path = pending[$ - 1];
            pending.length--;
            size_t address = path.Address;
            FlowEntry[] stack = path.Stack;

            while (true) {
                if (FlowEntry[]* seen = address in stackAt) {
                    if (*seen != stack)
                        Fail("Inconsistent SSY/PBK stack at 0x%X", address);
                    break;
                }
                stackAt[address] = stack.dup;
                const Instruction instruction = InstructionAt(address);
                const size_t next = NextAddress(address);

                if (IsFlowPush(instruction.Op)) {
                    if (instruction.Bit(5))
                        Fail("%s through a constant buffer at 0x%X", instruction.Name, address);
                    stack = stack ~ FlowEntry(instruction.Op, JumpTarget(instruction));
                    address = next;
                    continue;
                }

                if (IsFlowJump(instruction.Op)) {
                    if (instruction.Bits(0, 5) != 0xF)
                        Fail("%s with a condition code test at 0x%X", instruction.Name, address);
                    size_t target;
                    FlowEntry[] targetStack = stack;
                    if (instruction.Op == Opcode.Bra) {
                        if (instruction.Bit(5))
                            Fail("BRA through a constant buffer at 0x%X", address);
                        target = JumpTarget(instruction);
                    } else {
                        const ptrdiff_t found = FindPush(stack, PushFor(instruction.Op));
                        if (found < 0)
                            Fail("%s at 0x%X has no matching push", instruction.Name, address);
                        target = stack[found].Target;
                        targetStack = stack[0 .. found];
                    }
                    jumpTargets[address] = target;
                    leaders[target] = true;
                    pending ~= PendingPath(target, targetStack);
                    if (instruction.Unconditional)
                        break;
                    leaders[next] = true;
                    address = next;
                    continue;
                }

                if ((instruction.Op == Opcode.Exit || instruction.Op == Opcode.Kil) && instruction.Unconditional)
                    break;
                address = next;
            }
        }
    }

    private void TranslateFlow() {
        AnalyzeFlow();
        uint[size_t] blockLabels;
        foreach (address; leaders.byKey)
            if (address in stackAt)
                blockLabels[address] = b.NewId();

        const uint pcVariable = b.FunctionVariable(b.TypePointer(SpvStorage.Function, b.Uint));
        b.Name(pcVariable, "pc");
        const uint header = b.NewId();
        const uint body = b.NewId();
        const uint switchMerge = b.NewId();
        const uint continueBlock = b.NewId();
        const uint loopMerge = b.NewId();

        b.Store(pcVariable, b.ConstantUint(EntryAddress));
        b.Op(SpvOp.Branch, [header]);
        b.Label(header);
        b.Op(SpvOp.LoopMerge, [loopMerge, continueBlock, 0]);
        b.Op(SpvOp.Branch, [body]);
        b.Label(body);
        const uint pc = b.Load(b.Uint, pcVariable);
        b.Op(SpvOp.SelectionMerge, [switchMerge, 0]);
        uint[] switchOperands = [pc, switchMerge];
        foreach (address, label; blockLabels)
            switchOperands ~= [cast(uint) address, label];
        b.Op(SpvOp.Switch, switchOperands);

        foreach (start, label; blockLabels) {
            b.Label(label);
            terminated = false;
            size_t address = start;
            while (true) {
                const Instruction instruction = InstructionAt(address);
                instructionCount++;
                const size_t next = NextAddress(address);
                if (!IsFlowJump(instruction.Op))
                    EmitPredicated(instruction);
                if (terminated)
                    break;

                if (IsFlowJump(instruction.Op)) {
                    const uint target = b.ConstantUint(cast(uint) jumpTargets[address]);
                    uint value = target;
                    if (!instruction.Unconditional)
                        value = b.Value(SpvOp.Select, b.Uint, [Pred(instruction.Predicate, instruction.PredicateNegated), target, b.ConstantUint(cast(uint) next)]);
                    b.Store(pcVariable, value);
                    b.Op(SpvOp.Branch, [switchMerge]);
                    break;
                }
                if (next !in stackAt)
                    Fail("Block at 0x%X falls off the end of the program", start);
                if (next in leaders) {
                    b.Store(pcVariable, b.ConstantUint(cast(uint) next));
                    b.Op(SpvOp.Branch, [switchMerge]);
                    break;
                }
                address = next;
            }
        }

        b.Label(switchMerge);
        b.Op(SpvOp.Branch, [continueBlock]);
        b.Label(continueBlock);
        b.Op(SpvOp.Branch, [header]);
        b.Label(loopMerge);
        b.Op(SpvOp.Return, []);
        terminated = true;
    }

    private void TranslateLinear() {
        foreach (i; ShaderHeaderWords .. program.length) {
            const size_t index = i - ShaderHeaderWords;
            if (IsScheduleWord(index))
                continue;
            if (index > MaxShaderInstructions)
                Fail("Shader has no reachable EXIT");
            const Instruction instruction = Instruction.Decode(program[i], index * 8);
            instructionCount++;
            EmitPredicated(instruction);
            if (instruction.Op == Opcode.Exit && instruction.Unconditional)
                break;
            if (terminated) {
                b.Label();
                terminated = false;
            }
        }
        if (!terminated) {
            Epilogue();
            b.Op(SpvOp.Return, []);
        }
    }

    uint[] Translate() {
        if (program.length <= ShaderHeaderWords)
            Fail("Shader program is too short");

        const uint mainType = b.TypeFunction(b.Void);
        const uint main = b.NewId();
        b.Name(main, "main");
        b.Label();

        if (HasControlFlow())
            TranslateFlow();
        else
            TranslateLinear();
        b.Op(SpvOp.FunctionEnd, []);

        if (stage == ShaderStageKind.Vertex) {
            b.EntryPoint(SpvExecutionModel.Vertex, main, "main", interfaceIds);
        } else {
            b.EntryPoint(SpvExecutionModel.Fragment, main, "main", interfaceIds);
            b.ExecutionMode(main, SpvExecutionMode.OriginUpperLeft);
        }
        return b.Finish(main, mainType, b.TakeCode());
    }
}
