/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * lm: guest log messages
*/

module Source.Service.Lm;

// Std
import std.format : format;
import std.string : strip;

// Core
import Source.Kernel.Ipc;
import Source.Service.Service;
import Source.Util.Logger;

// Types
enum string GameLogFile = LogFolder ~ "/game_log.txt";

enum LogPacketFlags : ubyte {
    Head = 1 << 0,
    Tail = 1 << 1,
}

enum LogSeverity : ubyte {
    Trace = 0,
    Info = 1,
    Warning = 2,
    Error = 3,
    Fatal = 4,
}

enum LogChunkKey : ubyte {
    SessionBegin = 0,
    SessionEnd = 1,
    TextLog = 2,
    LineNumber = 3,
    FileName = 4,
    FunctionName = 5,
    ModuleName = 6,
    ThreadName = 7,
    DropCount = 8,
    UserSystemClock = 9,
    ProcessName = 10,
}

enum size_t LogPacketHeaderSize = 0x18;

// Utils
private ulong ReadLeb128(const(ubyte)[] data, ref size_t offset) {
    ulong value = 0;
    uint shift = 0;
    while (offset < data.length) {
        const ubyte next = data[offset++];
        value |= cast(ulong) (next & 0x7F) << shift;
        if ((next & 0x80) == 0 || shift >= 63) {
            break;
        }
        shift += 7;
    }
    return value;
}

// Services
final class LogService : IPCService {
    this() {
        Command(0, "OpenLogger", (IpcContext c) => c.PushInterface(new LoggerService()));
    }

    override string Name() const {
        return "lm";
    }
}

final class LoggerService : IPCService {
    private string text;
    private string fileName;
    private string functionName;
    private ulong lineNumber;
    private Logger guestLog;

    this() {
        guestLog = GetLogger("Guest::lm");
        guestLog.SetFile(GameLogFile);
        Command(0, "Log", &Log_);
        Command(1, "SetDestination", &Succeed);
    }

    override string Name() const {
        return "lm::ILogger";
    }

    private void Log_(IpcContext context) {
        const(ubyte)[] packet = context.ReadInput(0);
        if (packet.length < LogPacketHeaderSize) {
            return;
        }
        const ubyte flags = packet[0x10];
        const ubyte severity = packet[0x12];
        const uint payloadSize = *cast(const(uint)*) (packet.ptr + 0x14);
        const(ubyte)[] payload = packet[LogPacketHeaderSize .. $];
        if (payload.length > payloadSize) {
            payload = payload[0 .. payloadSize];
        }
        if ((flags & LogPacketFlags.Head) != 0) {
            text = null;
            fileName = null;
            functionName = null;
            lineNumber = 0;
        }

        size_t offset = 0;
        while (offset < payload.length) {
            const ulong key = ReadLeb128(payload, offset);
            const ulong size = ReadLeb128(payload, offset);
            if (size > payload.length - offset) {
                break;
            }
            const(ubyte)[] chunk = payload[offset .. offset + cast(size_t) size];
            offset += cast(size_t) size;
            switch (key) {
                case LogChunkKey.TextLog:
                    text ~= cast(const(char)[]) chunk;
                    break;
                case LogChunkKey.FileName:
                    fileName = (cast(const(char)[]) chunk).idup;
                    break;
                case LogChunkKey.FunctionName:
                    functionName = (cast(const(char)[]) chunk).idup;
                    break;
                case LogChunkKey.LineNumber:
                    lineNumber = 0;
                    foreach_reverse (value; chunk.length > 8 ? chunk[0 .. 8] : chunk) {
                        lineNumber = (lineNumber << 8) | value;
                    }
                    break;
                default:
                    break;
            }
        }

        if ((flags & LogPacketFlags.Tail) == 0) {
            return;
        }
        string location = functionName.length != 0 ? format(" [%s %s:%d]", functionName, fileName, lineNumber) : "";
        const string message = (cast(string) text).strip ~ location;
        switch (severity) {
            case LogSeverity.Warning:
                guestLog.Warn("%s", message);
                break;
            case LogSeverity.Error, LogSeverity.Fatal:
                guestLog.Error("%s", message);
                break;
            default:
                guestLog.Info("%s", message);
                break;
        }
    }
}
