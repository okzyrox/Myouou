/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * time: host based system clocks and times
 * most emus just use a faked time in some cases so i might do the same at some point
*/

module Source.Service.Time;

// Std
import std.format : format;
import core.time : MonoTime;
import std.datetime : Clock, DateTime, LocalTime, SysTime, unixTimeToStdTime;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
enum TimeResult : uint {
    InvalidArgument = MakeModuleResult(116, 901),
}

struct SteadyClockTimePoint {
    long TimePoint;
    ubyte[16] SourceId;
}

struct SystemClockContext {
    long Offset;
    SteadyClockTimePoint Timestamp;
}

struct CalendarTime {
    short Year;
    byte Month;
    byte Day;
    byte Hour;
    byte Minute;
    byte Second;
    byte Padding;
}

struct CalendarAdditionalInfo {
    uint DayOfWeek;
    uint DayOfYear;
    char[8] TimeZoneName = '\0';
    uint IsDaylightSavingTime;
    int UtcOffset;
}

struct LocationName {
    char[0x24] Name = '\0';
}

static assert(SteadyClockTimePoint.sizeof == 0x18);
static assert(SystemClockContext.sizeof == 0x20);
static assert(CalendarTime.sizeof == 8);
static assert(CalendarAdditionalInfo.sizeof == 0x18);

// todo: handle more locations
enum string HostLocationName = "UTC";
enum size_t TimeZoneRuleSize = 0x4000;

final class TimeState {
    immutable ubyte[16] SourceId = [0x4D, 0x79, 0x6F, 0x75, 0x6F, 0x75, 0x53, 0x74, 0x65, 0x61, 0x64, 0x79, 0x43, 0x6C, 0x6B, 0x01];
    private MonoTime start;

    this() {
        start = MonoTime.currTime;
    }

    SteadyClockTimePoint Now() const {
        return SteadyClockTimePoint((MonoTime.currTime - start).total!"seconds", SourceId);
    }
}

// Utils
long HostPosixTime() {
    return Clock.currTime.toUnixTime;
}

void ToCalendar(long posixTime, out CalendarTime calendar, out CalendarAdditionalInfo info) {
    const SysTime time = SysTime(unixTimeToStdTime(posixTime), LocalTime());
    calendar.Year = time.year;
    calendar.Month = cast(byte) time.month;
    calendar.Day = cast(byte) time.day;
    calendar.Hour = cast(byte) time.hour;
    calendar.Minute = cast(byte) time.minute;
    calendar.Second = cast(byte) time.second;
    info.DayOfWeek = cast(uint) time.dayOfWeek;
    info.DayOfYear = time.dayOfYear - 1;
    info.IsDaylightSavingTime = time.dstInEffect ? 1 : 0;
    info.UtcOffset = cast(int) time.utcOffset.total!"seconds";
    const string name = ZoneName(info.UtcOffset);
    info.TimeZoneName[0 .. name.length] = name[];
    // does not handle time zone rules.
}

private string ZoneName(int offset) {
    if (offset == 0) {
        return "UTC";
    }
    const int minutes = (offset < 0 ? -offset : offset) / 60;
    if (minutes % 60 == 0) {
        return format("UTC%s%d", offset < 0 ? "-" : "+", minutes / 60);
    }
    return format("%s%02d%02d", offset < 0 ? "-" : "+", minutes / 60, minutes % 60);
}

bool FromCalendar(const ref CalendarTime calendar, out long posixTime) {
    try {
        const DateTime date = DateTime(calendar.Year, calendar.Month, calendar.Day, calendar.Hour, calendar.Minute, calendar.Second);
        posixTime = SysTime(date, LocalTime()).toUnixTime;
        return true;
    } catch (Exception) {
        return false;
    }
}

// Services
final class TimeStaticService : IPCService {
    // "static" service since the clock state needs to be shared statically
    private string name;
    private TimeState state;

    this(string name, TimeState state) {
        this.name = name;
        this.state = state;
        Command(0, "GetStandardUserSystemClock", &GetStandardUserSystemClock);
        Command(1, "GetStandardNetworkSystemClock", &GetStandardNetworkSystemClock);
        Command(2, "GetStandardSteadyClock", &GetStandardSteadyClock);
        Command(3, "GetTimeZoneService", &GetTimeZoneService);
        Command(4, "GetStandardLocalSystemClock", &GetStandardLocalSystemClock);
        Command(5, "GetEphemeralNetworkSystemClock", &GetStandardNetworkSystemClock);
        Command(100, "IsStandardUserSystemClockAutomaticCorrectionEnabled", &IsStandardUserSystemClockAutomaticCorrectionEnabled);
        Command(300, "CalculateMonotonicSystemClockBaseTimePoint", &CalculateMonotonicSystemClockBaseTimePoint);
    }

    override string Name() const {
        return name;
    }

    private void GetStandardUserSystemClock(IpcContext context) {
        context.PushInterface(new SystemClockService("time::IUserSystemClock", state));
    }

    private void GetStandardNetworkSystemClock(IpcContext context) {
        context.PushInterface(new SystemClockService("time::INetworkSystemClock", state));
    }

    private void GetStandardLocalSystemClock(IpcContext context) {
        context.PushInterface(new SystemClockService("time::ILocalSystemClock", state));
    }

    private void GetStandardSteadyClock(IpcContext context) {
        context.PushInterface(new SteadyClockService(state));
    }

    private void GetTimeZoneService(IpcContext context) {
        context.PushInterface(new TimeZoneService());
    }

    private void IsStandardUserSystemClockAutomaticCorrectionEnabled(IpcContext context) {
        context.Push!ubyte(0);
    }

    private void CalculateMonotonicSystemClockBaseTimePoint(IpcContext context) {
        context.Push!long(HostPosixTime() - state.Now().TimePoint);
    }
}

final class SystemClockService : IPCService {
    private string name;
    private TimeState state;

    this(string name, TimeState state) {
        this.name = name;
        this.state = state;
        Command(0, "GetCurrentTime", &GetCurrentTime);
        Stub(1, "SetCurrentTime");
        Command(2, "GetSystemClockContext", &GetSystemClockContext);
        Stub(3, "SetSystemClockContext");
    }

    override string Name() const {
        return name;
    }

    private void GetCurrentTime(IpcContext context) {
        context.Push!long(HostPosixTime());
    }

    private void GetSystemClockContext(IpcContext context) {
        const SteadyClockTimePoint now = state.Now();
        context.Push(SystemClockContext(HostPosixTime() - now.TimePoint, now));
    }
}

final class SteadyClockService : IPCService {
    private TimeState state;

    this(TimeState state) {
        this.state = state;
        Command(0, "GetCurrentTimePoint", &GetCurrentTimePoint);
        Command(2, "GetTestOffset", &GetZero);
        Stub(3, "SetTestOffset");
        Command(100, "GetRtcValue", &GetRtcValue);
        Command(200, "GetInternalOffset", &GetZero);
    }

    override string Name() const {
        return "time::ISteadyClock";
    }

    private void GetCurrentTimePoint(IpcContext context) {
        context.Push(state.Now());
    }

    private void GetZero(IpcContext context) {
        context.Push!long(0);
    }

    private void GetRtcValue(IpcContext context) {
        context.Push!long(HostPosixTime());
    }
}

final class TimeZoneService : IPCService {
    this() {
        Command(0, "GetDeviceLocationName", &GetDeviceLocationName);
        Stub(1, "SetDeviceLocationName");
        Command(2, "GetTotalLocationNameCount", &GetTotalLocationNameCount);
        Command(3, "LoadLocationNameList", &LoadLocationNameList);
        Command(4, "LoadTimeZoneRule", &LoadTimeZoneRule);
        Command(100, "ToCalendarTime", &ToCalendarTime);
        Command(101, "ToCalendarTimeWithMyRule", &ToCalendarTime);
        Command(201, "ToPosixTime", &ToPosixTime);
        Command(202, "ToPosixTimeWithMyRule", &ToPosixTime);
    }

    override string Name() const {
        return "time::ITimeZoneService";
    }

    private static LocationName HostLocation() {
        LocationName location;
        location.Name[0 .. HostLocationName.length] = HostLocationName[];
        return location;
    }

    private void GetDeviceLocationName(IpcContext context) {
        context.Push(HostLocation());
    }

    private void GetTotalLocationNameCount(IpcContext context) {
        context.Push!uint(1);
    }

    private void LoadLocationNameList(IpcContext context) {
        const LocationName location = HostLocation();
        context.Push!uint(context.WriteOutput(0, location) == LocationName.sizeof ? 1 : 0);
    }

    private void LoadTimeZoneRule(IpcContext context) {
        context.WriteOutput(0, new ubyte[TimeZoneRuleSize]);
    }

    private void ToCalendarTime(IpcContext context) {
        CalendarTime calendar;
        CalendarAdditionalInfo info;
        ToCalendar(context.Pop!long(), calendar, info);
        context.Push(calendar);
        context.Push(info);
    }

    private void ToPosixTime(IpcContext context) {
        const CalendarTime calendar = context.Pop!CalendarTime();
        long posixTime;
        if (!FromCalendar(calendar, posixTime)) {
            context.Result(TimeResult.InvalidArgument);
            return;
        }
        const size_t written = context.WriteOutput(0, posixTime);
        context.Push!uint(written == long.sizeof ? 1 : 0);
    }
}
