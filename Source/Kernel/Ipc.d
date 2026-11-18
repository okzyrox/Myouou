/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * HIPC and CMIF message handling
*/

module Source.Kernel.Ipc;

// Std
import std.algorithm : min;
import std.format : format;
import std.stdio;

// Core
import Source.Kernel.Kernel;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
enum size_t IpcBufferSize = 0x100;
enum uint CmifInMagic = 0x49434653;
enum uint CmifOutMagic = 0x4F434653;
enum ushort PointerBufferSize = 0x8000;

enum IpcCommandType : ushort {
    Invalid = 0,
    LegacyRequest = 1,
    Close = 2,
    LegacyControl = 3,
    Request = 4,
    Control = 5,
    RequestWithContext = 6,
    ControlWithContext = 7,
}

enum DomainCommand : ubyte {
    SendMessage = 1,
    Close = 2,
}

enum ControlMethod : uint {
    ConvertCurrentObjectToDomain = 0,
    CopyFromCurrentDomain = 1,
    CloneCurrentObject = 2,
    QueryPointerBufferSize = 3,
    CloneCurrentObjectEx = 4,
}

struct IpcBufferDescriptor {
    ulong Address;
    ulong Size;
    uint Mode;
}

struct IpcStaticDescriptor {
    ulong Address;
    ulong Size;
    uint Index;
}

final class IpcMessage {
    ushort Type;
    bool HasPid;
    ulong Pid;
    uint[] CopyHandles;
    uint[] MoveHandles;
    IpcStaticDescriptor[] SendStatics;
    IpcStaticDescriptor[] RecvStatics;
    IpcBufferDescriptor[] SendBuffers;
    IpcBufferDescriptor[] RecvBuffers;
    IpcBufferDescriptor[] ExchangeBuffers;

    bool HasDomainHeader;
    ubyte DomainMethodId;
    uint ObjectId;
    uint[] InObjects;

    uint Magic;
    uint MethodId;
    const(ubyte)[] Payload;
}

final class IpcResponse {
    uint Result;
    ubyte[] Data;
    uint[] CopyHandles;
    uint[] MoveHandles;
    uint[] OutObjects;
}

private struct WordReader {
    const(ubyte)[] Buffer;
    size_t Offset;

    uint Next() {
        if (Offset + 4 > Buffer.length)
            throw new Exception("IPC message overruns the TLS buffer");
        const uint value = *cast(const(uint)*) (Buffer.ptr + Offset);
        Offset += 4;
        return value;
    }
}

// Utils
private T ReadAt(T)(const(ubyte)[] buffer, size_t offset) {
    if (offset + T.sizeof > buffer.length)
        return T.init;
    return *cast(const(T)*) (buffer.ptr + offset);
}

private void WriteAt(T)(ubyte[] buffer, size_t offset, T value) {
    *cast(T*) (buffer.ptr + offset) = value;
}

private size_t Align16(size_t value) pure nothrow @nogc @safe {
    return (value + 15) & ~cast(size_t) 15;
}

// Functions
IpcMessage ParseRequest(const(ubyte)[] buffer, bool isDomain) {
    IpcMessage message = new IpcMessage();
    WordReader reader = WordReader(buffer, 0);

    const uint header0 = reader.Next();
    const uint header1 = reader.Next();
    message.Type = cast(ushort) (header0 & 0xFFFF);
    const uint sendStaticCount = (header0 >> 16) & 0xF;
    const uint sendBufferCount = (header0 >> 20) & 0xF;
    const uint recvBufferCount = (header0 >> 24) & 0xF;
    const uint exchangeBufferCount = (header0 >> 28) & 0xF;
    const uint dataWordCount = header1 & 0x3FF;
    const uint recvStaticMode = (header1 >> 10) & 0xF;

    if ((header1 >> 31) != 0) {
        const uint special = reader.Next();
        message.HasPid = (special & 1) != 0;
        const uint copyCount = (special >> 1) & 0xF;
        const uint moveCount = (special >> 5) & 0xF;
        if (message.HasPid) {
            const ulong low = reader.Next();
            const ulong high = reader.Next();
            message.Pid = low | (high << 32);
        }
        foreach (i; 0 .. copyCount)
            message.CopyHandles ~= reader.Next();
        foreach (i; 0 .. moveCount)
            message.MoveHandles ~= reader.Next();
    }

    foreach (i; 0 .. sendStaticCount) {
        const uint packed = reader.Next();
        const ulong low = reader.Next();
        const ulong address = low | ((cast(ulong) (packed >> 12) & 0xF) << 32) | ((cast(ulong) (packed >> 6) & 0x3F) << 36);
        message.SendStatics ~= IpcStaticDescriptor(address, packed >> 16, packed & 0x3F);
    }

    IpcBufferDescriptor ReadBuffer() {
        const ulong sizeLow = reader.Next();
        const ulong addressLow = reader.Next();
        const uint packed = reader.Next();
        const ulong address = addressLow | ((cast(ulong) (packed >> 28) & 0xF) << 32) | ((cast(ulong) (packed >> 2) & 0x3FFFFF) << 36);
        const ulong size = sizeLow | ((cast(ulong) (packed >> 24) & 0xF) << 32);
        return IpcBufferDescriptor(address, size, packed & 3);
    }

    foreach (i; 0 .. sendBufferCount)
        message.SendBuffers ~= ReadBuffer();
    foreach (i; 0 .. recvBufferCount)
        message.RecvBuffers ~= ReadBuffer();
    foreach (i; 0 .. exchangeBufferCount)
        message.ExchangeBuffers ~= ReadBuffer();

    const size_t dataStart = reader.Offset;
    const size_t dataEnd = min(dataStart + dataWordCount * 4, buffer.length);

    const size_t recvStaticCount = recvStaticMode < 2 ? 0 : recvStaticMode == 2 ? 1 : recvStaticMode - 2;
    reader.Offset = dataEnd;
    foreach (i; 0 .. recvStaticCount) {
        const ulong low = reader.Next();
        const uint packed = reader.Next();
        message.RecvStatics ~= IpcStaticDescriptor(low | (cast(ulong) (packed & 0xFFFF) << 32), packed >> 16, cast(uint) i);
    }

    const bool isRequest = message.Type == IpcCommandType.Request || message.Type == IpcCommandType.RequestWithContext;
    const bool isControl = message.Type == IpcCommandType.Control || message.Type == IpcCommandType.ControlWithContext;
    if (!isRequest && !isControl)
        return message;

    size_t cursor = Align16(dataStart);
    size_t payloadEnd = dataEnd;
    if (isDomain && isRequest) {
        message.HasDomainHeader = true;
        message.DomainMethodId = ReadAt!ubyte(buffer, cursor);
        const ubyte inObjectCount = ReadAt!ubyte(buffer, cursor + 1);
        const ushort domainDataSize = ReadAt!ushort(buffer, cursor + 2);
        message.ObjectId = ReadAt!uint(buffer, cursor + 4);
        cursor += 16;
        payloadEnd = min(cursor + domainDataSize, buffer.length);
        foreach (i; 0 .. inObjectCount)
            message.InObjects ~= ReadAt!uint(buffer, payloadEnd + i * 4);
        if (message.DomainMethodId == DomainCommand.Close)
            return message;
    }

    message.Magic = ReadAt!uint(buffer, cursor);
    message.MethodId = ReadAt!uint(buffer, cursor + 8);
    const size_t payloadStart = min(cursor + 16, payloadEnd);
    message.Payload = buffer[payloadStart .. payloadEnd];
    return message;
}

ubyte[] BuildResponse(IpcResponse response, bool domainReply) {
    ubyte[] buffer = new ubyte[IpcBufferSize];
    size_t offset = 8;

    const bool hasSpecial = response.CopyHandles.length != 0 || response.MoveHandles.length != 0;
    if (hasSpecial) {
        WriteAt!uint(buffer, offset, cast(uint) ((response.CopyHandles.length << 1) | (response.MoveHandles.length << 5)));
        offset += 4;
        foreach (handle; response.CopyHandles) {
            WriteAt!uint(buffer, offset, handle);
            offset += 4;
        }
        foreach (handle; response.MoveHandles) {
            WriteAt!uint(buffer, offset, handle);
            offset += 4;
        }
    }

    const size_t dataStart = offset;
    size_t cursor = Align16(dataStart);
    if (domainReply) {
        WriteAt!uint(buffer, cursor, cast(uint) response.OutObjects.length);
        cursor += 16;
    }

    WriteAt!uint(buffer, cursor, CmifOutMagic);
    WriteAt!uint(buffer, cursor + 4, 0);
    WriteAt!uint(buffer, cursor + 8, response.Result);
    WriteAt!uint(buffer, cursor + 12, 0);
    cursor += 16;

    if (cursor + response.Data.length + response.OutObjects.length * 4 > buffer.length)
        throw new Exception(format("IPC response of 0x%X bytes doesnt fit TLS buffer!", response.Data.length));

    buffer[cursor .. cursor + response.Data.length] = response.Data[];
    cursor += response.Data.length;
    
     
    if (domainReply) {
        foreach (objectId; response.OutObjects) {
            WriteAt!uint(buffer, cursor, objectId);
            cursor += 4;
        }
    }

    const uint dataWords = cast(uint) ((cursor - dataStart + 3) / 4);
    WriteAt!uint(buffer, 0, 0);
    WriteAt!uint(buffer, 4, dataWords | (hasSpecial ? 1u << 31 : 0));
    return buffer;
}

uint ProcessSyncRequest(HorizonKernel kernel, KSession session, ulong messageAddress) {
    ubyte[IpcBufferSize] raw;
    kernel.Memory.ReadBytes(messageAddress, raw[]);

    IpcMessage message = ParseRequest(raw[], session.IsDomain);
    IpcResponse response = new IpcResponse();
    bool domainReply = false;

    switch (message.Type) {
        case IpcCommandType.Close:
            session.Service.Log.Trace("session closed");
            return ResultSuccess;

        case IpcCommandType.Control:
        case IpcCommandType.ControlWithContext:
            HandleControl(kernel, session, message, response);
            break;

        case IpcCommandType.Request:
        case IpcCommandType.RequestWithContext:
            IPCService target = session.Service;
            if (message.HasDomainHeader) {
                domainReply = true;
                target = session.Object(message.ObjectId);
                if (message.DomainMethodId == DomainCommand.Close) {
                    if (target !is null)
                        target.Log.Trace("domain object %d was closed.", message.ObjectId);
                    session.Objects.remove(message.ObjectId);
                    break;
                }
                if (target is null) {
                    response.Result = CmifResult.TargetNotFound;
                    break;
                }
            }

            if (message.Magic != CmifInMagic) {
                response.Result = CmifResult.InvalidHeader;
                break;
            }

            target.Dispatch(new IpcContext(kernel, session, target, message, response));
            break;

        default:
            session.Service.Log.Stub("unsupported message %d", message.Type);
            response.Result = CmifResult.InvalidHeader;
            break;
    }

    kernel.Memory.WriteBytes(messageAddress, BuildResponse(response, domainReply));
    return ResultSuccess;
}

private void HandleControl(HorizonKernel kernel, KSession session, IpcMessage message, IpcResponse response) {
    void Push(T)(T value) {
        response.Data ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
    }

    switch (message.MethodId) {
        case ControlMethod.ConvertCurrentObjectToDomain:
            session.IsDomain = true;
            Push!uint(session.AddObject(session.Service));
            break;
        case ControlMethod.CloneCurrentObject:
        case ControlMethod.CloneCurrentObjectEx:
            response.MoveHandles ~= kernel.Handles.Add(session);
            break;
        case ControlMethod.QueryPointerBufferSize:
            Push!ushort(PointerBufferSize);
            break;
        default:
            session.Service.Log.Stub("control method %d", message.MethodId);
            response.Result = CmifResult.UnknownMethodId;
            return;
    }

    session.Service.Log.Trace("method %s", cast(ControlMethod) message.MethodId);
}

final class IpcContext {
    HorizonKernel Kernel;
    KSession Session;
    IPCService Service;
    IpcMessage Request;
    IpcResponse Response;
    private size_t currentReadOffset;

    this(HorizonKernel kernel, KSession session, IPCService service, IpcMessage request, IpcResponse response) {
        Kernel = kernel;
        Session = session;
        Service = service;
        Request = request;
        Response = response;
    }

    uint MethodId() const {
        return Request.MethodId;
    }

    void Result(uint value) {
        Response.Result = value;
    }

    T Pop(T)() {
        currentReadOffset = (currentReadOffset + T.alignof - 1) & ~(T.alignof - 1);
        T value = ReadAt!T(Request.Payload, currentReadOffset);
        currentReadOffset += T.sizeof;
        return value;
    }

    void Push(T)(T value) {
        while (Response.Data.length % T.alignof != 0)
            Response.Data ~= 0;
        Response.Data ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
    }

    void PushInterface(IPCService service) {
        if (Session.IsDomain)
            Response.OutObjects ~= Session.AddObject(service);
        else
            Response.MoveHandles ~= Kernel.Handles.Add(new KSession(service));
    }

    void PushCopyHandle(KObject value) {
        Response.CopyHandles ~= Kernel.Handles.Add(value);
    }

    void PushMoveHandle(KObject value) {
        Response.MoveHandles ~= Kernel.Handles.Add(value);
    }

    T InObject(T : IPCService)(size_t index) {
        if (index >= Request.InObjects.length)
            return null;
        return cast(T) Session.Object(Request.InObjects[index]);
    }

    ubyte[] ReadInput(size_t index) {
        ulong address;
        ulong size;
        if (index < Request.SendBuffers.length && Request.SendBuffers[index].Size != 0) {
            address = Request.SendBuffers[index].Address;
            size = Request.SendBuffers[index].Size;
        }
        else if (index < Request.SendStatics.length) {
            address = Request.SendStatics[index].Address;
            size = Request.SendStatics[index].Size;
        }
        else
            return null;

        ubyte[] data = new ubyte[cast(size_t) size];
        Kernel.Memory.ReadBytes(address, data);
        return data;
    }

    size_t OutputSize(size_t index) {
        if (index < Request.RecvBuffers.length && Request.RecvBuffers[index].Size != 0)
            return cast(size_t) Request.RecvBuffers[index].Size;
        if (index < Request.RecvStatics.length)
            return cast(size_t) Request.RecvStatics[index].Size;
        return 0;
    }

    size_t WriteOutput(size_t index, const(ubyte)[] data) {
        ulong address;
        size_t capacity;
        if (index < Request.RecvBuffers.length && Request.RecvBuffers[index].Size != 0) {
            address = Request.RecvBuffers[index].Address;
            capacity = cast(size_t) Request.RecvBuffers[index].Size;
        }
        else if (index < Request.RecvStatics.length) {
            address = Request.RecvStatics[index].Address;
            capacity = cast(size_t) Request.RecvStatics[index].Size;
        }
        else
            return 0;

        const size_t length = min(capacity, data.length);
        Kernel.Memory.WriteBytes(address, data[0 .. length]);
        return length;
    }

    size_t WriteOutput(T)(size_t index, const ref T value) if (!is(T : const(ubyte)[])) {
        return WriteOutput(index, (cast(const(ubyte)*) &value)[0 .. T.sizeof]);
    }
}
