/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Named loggers with filtering
*/

module Source.Util.Logger;

// Std
import std.algorithm : endsWith, startsWith;
import std.format : format;
import std.stdio;

// Types
enum LogLevel : ubyte {
    Trace,
    Info,
    Stub,
    Warning,
    Error,
}

private immutable string[] logLevelNames = ["TRACE", "INFO", "STUB", "WARN", "ERROR"];

// Global
private __gshared LogLevel minimumLevel = LogLevel.Trace;
private __gshared string[] mutedPatterns; // muted loggers
private __gshared string[] primaryPatterns;

// Log Level
abstract final class LogFilter {
    static void MinimumLevel(LogLevel level) {
        minimumLevel = level;
    }

    static LogLevel MinimumLevel() {
        return minimumLevel;
    }

    static void Mute(string pattern) {
        mutedPatterns ~= pattern;
    }

    static void Solo(string pattern) {
        primaryPatterns ~= pattern;
    }

    static void Reset() {
        minimumLevel = LogLevel.Trace;
        mutedPatterns = null;
        primaryPatterns = null;
    }

    static bool Matches(string name, string pattern) {
        if (pattern.endsWith("*"))
            return name.startsWith(pattern[0 .. $ - 1]);
        return name == pattern || name.startsWith(pattern ~ "::");
    }

    static bool Allows(string name, LogLevel level) {
        if (level < minimumLevel)
            return false;
        if (level >= LogLevel.Error)
            return true;
        foreach (pattern; mutedPatterns)
            if (Matches(name, pattern))
                return false;
        if (primaryPatterns.length == 0)
            return true;
        foreach (pattern; primaryPatterns)
            if (Matches(name, pattern))
                return true;
        return false;
    }
}

final class Logger {
    immutable string Name;

    this(string name) {
        Name = name;
    }

    bool IsEnabled(LogLevel level) const {
        return LogFilter.Allows(Name, level);
    }

    void Write(A...)(LogLevel level, string text, A args) const {
        if (!IsEnabled(level))
            return;
        static if (A.length == 0)
            const string message = text;
        else
            const string message = format(text, args);
        writefln("[%s] %-5s %s", Name, logLevelNames[level], message);
    }

    void Trace(A...)(string text, A args) const {
        Write(LogLevel.Trace, text, args);
    }

    void Info(A...)(string text, A args) const {
        Write(LogLevel.Info, text, args);
    }

    void Stub(A...)(string text, A args) const {
        Write(LogLevel.Stub, text, args);
    }

    void Warn(A...)(string text, A args) const {
        Write(LogLevel.Warning, text, args);
    }

    void Error(A...)(string text, A args) const {
        Write(LogLevel.Error, text, args);
    }
}

private __gshared Logger[string] loggersByName;

Logger GetLogger(string name) {
    Logger* found = name in loggersByName;
    if (found !is null)
        return *found;
    Logger created = new Logger(name);
    loggersByName[name] = created;
    return created;
}
