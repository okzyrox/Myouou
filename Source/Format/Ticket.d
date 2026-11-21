/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Parsing of etickets
*/

module Source.Format.Ticket;

// Std
import std.format : format;

// Types
enum TicketSignatureType : uint {
    Rsa4096Sha1 = 0x10000,
    Rsa2048Sha1 = 0x10001,
    EcdsaSha1 = 0x10002,
    Rsa4096Sha256 = 0x10003,
    Rsa2048Sha256 = 0x10004,
    EcdsaSha256 = 0x10005,
}

enum TitleKeyType : ubyte {
    Common = 0,
    Personalized = 1,
}

enum size_t TicketBodySize = 0x180;

class TicketError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}

// Utils
private size_t SignatureBlockSize(uint type) {
    switch (type) {
        case TicketSignatureType.Rsa4096Sha1, TicketSignatureType.Rsa4096Sha256:
            return 4 + 0x200 + 0x3C;
        case TicketSignatureType.Rsa2048Sha1, TicketSignatureType.Rsa2048Sha256:
            return 4 + 0x100 + 0x3C;
        case TicketSignatureType.EcdsaSha1, TicketSignatureType.EcdsaSha256:
            return 4 + 0x3C + 0x40;
        default:
            throw new TicketError(format("Unknown ticket signature type: 0x%X!", type));
    }
}

// Class
final class Ticket {
    string Issuer;
    TitleKeyType KeyType;
    ubyte MasterKeyRevision;
    ubyte[16] RightsId;
    ubyte[0x100] TitleKeyBlock;

    this(const(ubyte)[] data) {
        if (data.length < 4) {
            throw new TicketError("Ticket is too small!");
        }
        const size_t bodyAt = SignatureBlockSize(*cast(const(uint)*) data.ptr);
        if (data.length < bodyAt + TicketBodySize) {
            throw new TicketError(format("Ticket is truncated (0x%X bytes but we need 0x%X)!", data.length, bodyAt + TicketBodySize));
        }
        const(ubyte)[] ticketBody = data[bodyAt .. bodyAt + TicketBodySize];
        size_t issuerLength = 0;
        while (issuerLength < 0x40 && ticketBody[issuerLength] != 0) {
            issuerLength++;
        }
        Issuer = (cast(const(char)[]) ticketBody[0 .. issuerLength]).idup;
        TitleKeyBlock = ticketBody[0x40 .. 0x140];
        KeyType = cast(TitleKeyType) ticketBody[0x141];
        MasterKeyRevision = ticketBody[0x145];
        RightsId = ticketBody[0x160 .. 0x170];
    }

    bool IsCommon() const {
        return KeyType == TitleKeyType.Common;
    }

    const(ubyte)[] EncryptedTitleKey() const {
        return IsCommon ? TitleKeyBlock[0 .. 16] : null;
    }
}
