/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Minimal SPIRV 1.0 module builder
 * Mainly inspired by Ryujinxs compiler for SPIRV/glsl but as far as I wanted to manually translate it over.
*/

module Source.Gpu.Shader.Spirv;

// Std
import std.format : format;

// Types
enum SpvOp : ushort {
    Nop = 0,
    Name = 5,
    ExtInstImport = 11,
    ExtInst = 12,
    MemoryModel = 14,
    EntryPoint = 15,
    ExecutionMode = 16,
    Capability = 17,
    TypeVoid = 19,
    TypeBool = 20,
    TypeInt = 21,
    TypeFloat = 22,
    TypeVector = 23,
    TypeImage = 25,
    TypeSampledImage = 27,
    TypeArray = 28,
    TypeRuntimeArray = 29,
    TypeStruct = 30,
    TypePointer = 32,
    TypeFunction = 33,
    ConstantTrue = 41,
    ConstantFalse = 42,
    Constant = 43,
    ConstantComposite = 44,
    Function = 54,
    FunctionEnd = 56,
    Variable = 59,
    Load = 61,
    Store = 62,
    AccessChain = 65,
    Decorate = 71,
    MemberDecorate = 72,
    CompositeConstruct = 80,
    CompositeExtract = 81,
    ImageSampleImplicitLod = 87,
    ImageSampleExplicitLod = 88,
    ImageFetch = 95,
    Image = 100,
    ConvertFToU = 109,
    ConvertFToS = 110,
    ConvertSToF = 111,
    ConvertUToF = 112,
    Bitcast = 124,
    SNegate = 126,
    FNegate = 127,
    IAdd = 128,
    FAdd = 129,
    ISub = 130,
    FSub = 131,
    IMul = 132,
    FMul = 133,
    FDiv = 136,
    IsNan = 156,
    LogicalEqual = 164,
    LogicalNotEqual = 165,
    LogicalOr = 166,
    LogicalAnd = 167,
    LogicalNot = 168,
    Select = 169,
    IEqual = 170,
    INotEqual = 171,
    UGreaterThan = 172,
    SGreaterThan = 173,
    UGreaterThanEqual = 174,
    SGreaterThanEqual = 175,
    ULessThan = 176,
    SLessThan = 177,
    ULessThanEqual = 178,
    SLessThanEqual = 179,
    FOrdEqual = 180,
    FUnordEqual = 181,
    FOrdNotEqual = 182,
    FUnordNotEqual = 183,
    FOrdLessThan = 184,
    FUnordLessThan = 185,
    FOrdGreaterThan = 186,
    FUnordGreaterThan = 187,
    FOrdLessThanEqual = 188,
    FUnordLessThanEqual = 189,
    FOrdGreaterThanEqual = 190,
    FUnordGreaterThanEqual = 191,
    ShiftRightLogical = 194,
    ShiftRightArithmetic = 195,
    ShiftLeftLogical = 196,
    BitwiseOr = 197,
    BitwiseXor = 198,
    BitwiseAnd = 199,
    Not = 200,
    LoopMerge = 246,
    SelectionMerge = 247,
    Label = 248,
    Branch = 249,
    BranchConditional = 250,
    Switch = 251,
    Kill = 252,
    Return = 253,
}

enum SpvStorage : uint {
    UniformConstant = 0,
    Input = 1,
    Uniform = 2,
    Output = 3,
    Function = 7,
}

enum SpvDecoration : uint {
    Block = 2,
    BufferBlock = 3,
    ArrayStride = 6,
    BuiltIn = 11,
    NoPerspective = 13,
    Flat = 14,
    NonWritable = 24,
    Location = 30,
    Binding = 33,
    DescriptorSet = 34,
    Offset = 35,
}

enum SpvBuiltIn : uint {
    Position = 0,
    PointSize = 1,
    FragCoord = 15,
    FrontFacing = 17,
    FragDepth = 22,
    VertexIndex = 42,
    InstanceIndex = 43,
}

enum SpvExecutionModel : uint {
    Vertex = 0,
    Fragment = 4,
}

enum SpvExecutionMode : uint {
    OriginUpperLeft = 7,
}

enum uint SpvDim2D = 1;
enum uint SpvImageOperandsLod = 0x2;

enum uint SpvMagic = 0x0723_0203;
enum uint SpvVersion10 = 0x0001_0000;
enum uint SpvCapabilityShader = 1;
enum uint SpvAddressingLogical = 0;
enum uint SpvMemoryModelGlsl450 = 1;

enum GlslStd : uint {
    Round = 1,
    RoundEven = 2,
    Trunc = 3,
    FAbs = 4,
    Floor = 8,
    Ceil = 9,
    Sin = 13,
    Cos = 14,
    Exp2 = 29,
    Log2 = 30,
    Sqrt = 31,
    InverseSqrt = 32,
    FMin = 37,
    UMin = 38,
    SMin = 39,
    FMax = 40,
    UMax = 41,
    SMax = 42,
    FClamp = 43,
    Fma = 50,
}

// Class
final class SpirvBuilder {
    uint Void, Bool, Uint, Int, Float, Vec4, Uvec4, GlslExt;

    private uint nextId = 1;
    private uint[] capabilities;
    private uint[] extensions;
    private uint[] memoryModel;
    private uint[] entryPoints;
    private uint[] executionModes;
    private uint[] debugNames;
    private uint[] annotations;
    private uint[] globals;
    private uint[] functionVariables;
    private uint[] code;
    private uint[string] cache;

    this() {
        Emit(capabilities, SpvOp.Capability, [SpvCapabilityShader]);
        GlslExt = NewId();
        Emit(extensions, SpvOp.ExtInstImport, [GlslExt] ~ StringWords("GLSL.std.450"));
        Emit(memoryModel, SpvOp.MemoryModel, [SpvAddressingLogical, SpvMemoryModelGlsl450]);
        Void = TypeVoid();
        Bool = Type("bool", SpvOp.TypeBool, []);
        Uint = Type("uint", SpvOp.TypeInt, [32, 0]);
        Int = Type("int", SpvOp.TypeInt, [32, 1]);
        Float = Type("float", SpvOp.TypeFloat, [32]);
        Vec4 = TypeVector(Float, 4);
        Uvec4 = TypeVector(Uint, 4);
    }

    uint NewId() {
        return nextId++;
    }

    static uint[] StringWords(string text) {
        uint[] words = new uint[text.length / 4 + 1];
        foreach (i, character; text)
            words[i / 4] |= cast(uint) cast(ubyte) character << ((i % 4) * 8);
        return words;
    }

    private static void Emit(ref uint[] section, SpvOp op, const(uint)[] operands) {
        section ~= cast(uint) ((operands.length + 1) << 16) | op;
        section ~= operands;
    }

    private uint Type(string key, SpvOp op, const(uint)[] operands) {
        if (uint* found = key in cache)
            return *found;
        const uint id = NewId();
        Emit(globals, op, [id] ~ operands);
        cache[key] = id;
        return id;
    }

    private uint ConstantValue(string key, SpvOp op, uint type, const(uint)[] values) {
        if (uint* found = key in cache)
            return *found;
        const uint id = NewId();
        Emit(globals, op, [type, id] ~ values);
        cache[key] = id;
        return id;
    }

    uint TypeVoid() {
        return Type("void", SpvOp.TypeVoid, []);
    }

    uint TypeVector(uint component, uint count) {
        return Type(format("vec%d_%d", component, count), SpvOp.TypeVector, [component, count]);
    }

    uint TypePointer(SpvStorage storage, uint type) {
        return Type(format("ptr%d_%d", storage, type), SpvOp.TypePointer, [storage, type]);
    }

    uint TypeFunction(uint returnType) {
        return Type(format("fn%d", returnType), SpvOp.TypeFunction, [returnType]);
    }

    uint TypeRuntimeArray(uint element) {
        return Type(format("rta%d", element), SpvOp.TypeRuntimeArray, [element]);
    }

    uint TypeImage2D() {
        return Type("image2d", SpvOp.TypeImage, [Float, SpvDim2D, 0, 0, 0, 1, 0]);
    }

    uint TypeSampledImage(uint image) {
        return Type(format("sampled%d", image), SpvOp.TypeSampledImage, [image]);
    }

    uint TypeStructUnique(const(uint)[] members) {
        const uint id = NewId();
        Emit(globals, SpvOp.TypeStruct, [id] ~ members);
        return id;
    }

    uint ConstantUint(uint value) {
        return ConstantValue(format("cu%d", value), SpvOp.Constant, Uint, [value]);
    }

    uint ConstantInt(int value) {
        return ConstantValue(format("ci%d", value), SpvOp.Constant, Int, [cast(uint) value]);
    }

    uint ConstantFloat(float value) {
        const uint bits = *cast(uint*) &value;
        return ConstantValue(format("cf%08X", bits), SpvOp.Constant, Float, [bits]);
    }

    uint ConstantBool(bool value) {
        return ConstantValue(value ? "true" : "false", value ? SpvOp.ConstantTrue : SpvOp.ConstantFalse, Bool, []);
    }

    uint GlobalVariable(uint pointerType, SpvStorage storage) {
        const uint id = NewId();
        Emit(globals, SpvOp.Variable, [pointerType, id, storage]);
        return id;
    }

    uint FunctionVariable(uint pointerType) {
        const uint id = NewId();
        Emit(functionVariables, SpvOp.Variable, [pointerType, id, SpvStorage.Function]);
        return id;
    }

    void Decorate(uint target, SpvDecoration decoration, const(uint)[] values = null) {
        Emit(annotations, SpvOp.Decorate, [target, decoration] ~ values);
    }

    void MemberDecorate(uint structType, uint member, SpvDecoration decoration, const(uint)[] values = null) {
        Emit(annotations, SpvOp.MemberDecorate, [structType, member, decoration] ~ values);
    }

    void Name(uint target, string name) {
        Emit(debugNames, SpvOp.Name, [target] ~ StringWords(name));
    }

    void EntryPoint(SpvExecutionModel model, uint func, string name, const(uint)[] interfaceIds) {
        Emit(entryPoints, SpvOp.EntryPoint, [model, func] ~ StringWords(name) ~ interfaceIds);
    }

    void ExecutionMode(uint func, SpvExecutionMode mode) {
        Emit(executionModes, SpvOp.ExecutionMode, [func, mode]);
    }

    void Op(SpvOp op, const(uint)[] operands) {
        Emit(code, op, operands);
    }

    uint Value(SpvOp op, uint resultType, const(uint)[] operands) {
        const uint id = NewId();
        Emit(code, op, [resultType, id] ~ operands);
        return id;
    }

    uint Ext(uint resultType, GlslStd instruction, const(uint)[] operands) {
        return Value(SpvOp.ExtInst, resultType, [GlslExt, instruction] ~ operands);
    }

    uint Load(uint type, uint pointer) {
        return Value(SpvOp.Load, type, [pointer]);
    }

    void Store(uint pointer, uint value) {
        Op(SpvOp.Store, [pointer, value]);
    }

    uint Label() {
        const uint id = NewId();
        Op(SpvOp.Label, [id]);
        return id;
    }

    void Label(uint id) {
        Op(SpvOp.Label, [id]);
    }

    // OpVar is hopefully after the entry lavel at [0 .. 2]
    uint[] Finish(uint func, uint functionType, uint[] body) {
        uint[] header = [SpvMagic, SpvVersion10, 0, nextId, 0];
        uint[] functionCode;
        Emit(functionCode, SpvOp.Function, [Void, func, 0, functionType]);
        return header ~ capabilities ~ extensions ~ memoryModel ~ entryPoints ~ executionModes ~ debugNames ~ annotations ~ globals ~ functionCode ~ body[0 .. 2] ~ functionVariables ~ body[2 .. $];
    }

    uint[] TakeCode() {
        uint[] result = code;
        code = null;
        return result;
    }
}
