/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * set set:sys
*/

module Source.Service.Set;

// Std
import std.algorithm : min;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;

// Types

// System Version Title
struct FirmwareVersion {
    ubyte Major;
    ubyte Minor;
    ubyte Micro;
    ubyte Padding1;
    ubyte RevisionMajor;
    ubyte RevisionMinor;
    ubyte[2] Padding2;
    char[0x20] Platform = '\0';
    char[0x40] VersionHash = '\0';
    char[0x18] DisplayVersion = '\0';
    char[0x80] DisplayTitle = '\0';
}

// We'll just emulate a 4.0.0 for now
// as i dont plan to get too involved in some newer services/svc's yet
enum ubyte EmulatedMajor = 4;
enum ubyte EmulatedMinor = 0;
enum ubyte EmulatedMicro = 0;

// Languages
immutable string[] LanguageCodes = ["ja", "en-US", "fr", "de", "it", "es", "zh-CN", "ko", "nl", "pt", "ru", "zh-TW", "en-GB", "fr-CA", "es-419", "zh-Hans", "zh-Hant"];
enum size_t LegacyLanguageCount = 15;
enum size_t DefaultLanguage = 1; // en-US

enum RegionCode : int {
    Japan = 0,
    Usa = 1,
    Europe = 2,
    Australia = 3,
    China = 4,
    Taiwan = 6
}

enum SetResult : uint {
    InvalidLanguage = MakeModuleResult(105, 625),
}

// Utils
FirmwareVersion FirmwareData() {
    FirmwareVersion firmware;
    firmware.Major = EmulatedMajor;
    firmware.Minor = EmulatedMinor;
    firmware.Micro = EmulatedMicro;
    firmware.RevisionMajor = 1;
    FillBuf(firmware.Platform[], "NX");
    FillBuf(firmware.DisplayVersion[], "4.0.0");
    FillBuf(firmware.DisplayTitle[], "MyououEmu Firmware for NX 4.0.0-1.0"); // typically starts with NintendoSDK, not sure if compatibility would be affected
    return firmware;
}

private void FillBuf(char[] destination, string text) {
    destination[0 .. text.length] = text[];
}

ulong LanguageCode(string text) {
    ulong code = 0;
    foreach (i, c; text) {
        code |= cast(ulong) c << (i * 8);
    }
    return code;
}

// Service
final class SetService : IPCService {
    this() {
        Command(0, "GetLanguageCode", (IpcContext c) => c.Push!ulong(LanguageCode(LanguageCodes[DefaultLanguage])));
        Command(1, "GetAvailableLanguageCodes", (IpcContext c) => WriteCodes(c, LegacyLanguageCount));
        Command(2, "MakeLanguageCode", &MakeLanguageCode);
        Command(3, "GetAvailableLanguageCodeCount", (IpcContext c) => c.Push!int(cast(int) LegacyLanguageCount));
        Command(4, "GetRegionCode", (IpcContext c) => c.Push!int(RegionCode.Usa));
        Command(5, "GetAvailableLanguageCodes2", (IpcContext c) => WriteCodes(c, LanguageCodes.length));
        Command(6, "GetAvailableLanguageCodeCount2", (IpcContext c) => c.Push!int(cast(int) LanguageCodes.length));
        Stub(7, "GetKeyCodeMap");
        Command(8, "GetQuestFlag", &False);
        Stub(9, "GetKeyCodeMap2");
    }

    override string Name() const {
        return "set"; // ISettingsServer
    }

    private static void WriteCodes(IpcContext context, size_t available) {
        const size_t count = min(available, context.OutputSize(0) / ulong.sizeof);
        ulong[] codes = new ulong[count];
        foreach (i; 0 .. count) {
            codes[i] = LanguageCode(LanguageCodes[i]);
        }
        context.WriteOutput(0, cast(const(ubyte)[]) codes);
        context.Push!int(cast(int) count);
    }

    private void MakeLanguageCode(IpcContext context) {
        const uint language = context.Pop!uint();
        if (language >= LanguageCodes.length) {
            context.Result(SetResult.InvalidLanguage);
            return;
        }
        context.Push!ulong(LanguageCode(LanguageCodes[language]));
    }
}

final class SetSysService : IPCService {
    this() {
        Command(3, "GetFirmwareVersion", &GetFirmwareVersion);
        Command(4, "GetFirmwareVersion2", &GetFirmwareVersion);
    }

    override string Name() const {
        return "set:sys"; // ISystemSettingsServer
    }

    private void GetFirmwareVersion(IpcContext context) {
        FirmwareVersion firmware = FirmwareData();
        context.WriteOutput(0, firmware);
    }
}
