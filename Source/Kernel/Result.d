/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Result codes
*/

module Source.Kernel.Result;

// Std
import std.format : format;

// Types
enum uint ResultSuccess = 0;

// Utils
uint MakeModuleResult(uint moduleId, uint description) pure nothrow @nogc @safe {
    return (moduleId & 0x1FF) | ((description & 0x1FFF) << 9);
}

uint ResultModule(uint result) pure nothrow @nogc @safe {
    return result & 0x1FF;
}

uint ResultDescription(uint result) pure nothrow @nogc @safe {
    return (result >> 9) & 0x1FFF;
}

string FormatResult(uint result) pure @safe {
    if (result == ResultSuccess) {
        return "OK";
    } else {
        return format("Err 0x%X (%04d-%04d)", result, 2000 + ResultModule(result), ResultDescription(result));
    }
}

// Results

// https://switchbrew.org/wiki/Error_codes
enum KernelResult : uint {
    OutOfSessions = MakeModuleResult(1, 7),
    InvalidArgument = MakeModuleResult(1, 14),
    NotImplemented = MakeModuleResult(1, 33),
    InvalidSize = MakeModuleResult(1, 101),
    InvalidAddress = MakeModuleResult(1, 102),
    OutOfResource = MakeModuleResult(1, 103),
    OutOfMemory = MakeModuleResult(1, 104),
    OutOfHandles = MakeModuleResult(1, 105),
    InvalidCurrentMemory = MakeModuleResult(1, 106),
    InvalidNewMemoryPermission = MakeModuleResult(1, 108),
    InvalidMemoryRegion = MakeModuleResult(1, 110),
    InvalidHandle = MakeModuleResult(1, 114),
    InvalidPointer = MakeModuleResult(1, 115),
    InvalidCombination = MakeModuleResult(1, 116),
    TimedOut = MakeModuleResult(1, 117),
    Cancelled = MakeModuleResult(1, 118),
    OutOfRange = MakeModuleResult(1, 119),
    InvalidEnumValue = MakeModuleResult(1, 120),
    NotFound = MakeModuleResult(1, 121),
    SessionClosed = MakeModuleResult(1, 123),
    InvalidState = MakeModuleResult(1, 125),
}

// sf:
enum CmifResult : uint {
    InvalidHeader = MakeModuleResult(10, 202),
    UnknownMethodId = MakeModuleResult(10, 221),
    TargetNotFound = MakeModuleResult(10, 301),
}
