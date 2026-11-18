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

// Core
import Source.Kernel.Ipc;
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

// Service
final class SetSysService : IPCService {
    this() {
        Command(3, "GetFirmwareVersion", &GetFirmwareVersion);
        Command(4, "GetFirmwareVersion2", &GetFirmwareVersion);
    }

    override string Name() const {
        return "set:sys";
    }

    private void GetFirmwareVersion(IpcContext context) {
        FirmwareVersion firmware = FirmwareData();
        context.WriteOutput(0, firmware);
    }
}
