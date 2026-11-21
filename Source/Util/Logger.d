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
import std.file : mkdirRecurse;
import std.format : format;
import std.path : dirName;
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

// Defaults
enum string LogFolder = "sandbox/logs";
enum string MainLogFile = LogFolder ~ "/log.txt";

// Global
private __gshared LogLevel minimumLevel = LogLevel.Trace;
private __gshared string[] mutedPatterns; // muted loggers
private __gshared string[] primaryPatterns;
private __gshared string defaultFilePath;
private __gshared File[string] openFiles;
private __gshared Object fileLock;

shared static this() {
    fileLock = new Object();
}

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
        if (pattern.endsWith("*")) {
            return name.startsWith(pattern[0 .. $ - 1]);
        }
        return name == pattern || name.startsWith(pattern ~ "::");
    }

    static bool Allows(string name, LogLevel level) {
        if (level < minimumLevel) {
            return false;
        }
        if (level >= LogLevel.Error) {
            return true;
        }
        foreach (pattern; mutedPatterns) {
            if (Matches(name, pattern)) {
                return false;
            }
        }
        if (primaryPatterns.length == 0) {
            return true;
        }
        foreach (pattern; primaryPatterns) {
            if (Matches(name, pattern)) {
                return true;
            }
        }
            
        return false;
    }
}

// Log Files
abstract final class LogFile {
    static void Default(string path) {
        defaultFilePath = path;
    }

    static string Default() {
        return defaultFilePath;
    }

    static void CloseAll() {
        synchronized (fileLock) {
            foreach (ref file; openFiles) {
                file.close();
            }
            openFiles = null;
        }
    }

    static void WriteLine(string path, string line) {
        synchronized (fileLock) {
            File* file = path in openFiles;
            if (file is null) {
                try {
                    mkdirRecurse(dirName(path));
                    openFiles[path] = File(path, "w");
                } catch (Exception error) {
                    stderr.writefln("Could not open log file at %s. Err: %s.", path, error.msg);
                    openFiles[path] = File.init;
                }
                file = path in openFiles;
            }
            if (!file.isOpen) {
                return;
            }
            file.writeln(line);
            // todo: flush less?
            file.flush();
        }
    }
}

final class Logger {
    immutable string Name;
    private string filePath;
    private bool ownFile;

    this(string name) {
        Name = name;
    }

    void SetFile(string path) {
        filePath = path;
        ownFile = true;
    }

    void InheritFile() {
        filePath = null;
        ownFile = false;
    }

    string FilePath() const {
        return ownFile ? filePath : defaultFilePath;
    }

    bool IsEnabled(LogLevel level) const {
        return LogFilter.Allows(Name, level);
    }

    void Write(A...)(LogLevel level, string text, A args) const {
        if (!IsEnabled(level)) {
            return;
        }
        static if (A.length == 0)
            const string message = text;
        else
            const string message = format(text, args);
        const string line = format("[%s] %-5s %s", Name, logLevelNames[level], message);
        writeln(line);
        const string path = FilePath();
        if (path.length != 0) {
            LogFile.WriteLine(path, line);
        }
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
    if (found !is null) {
        return *found;
    }
    Logger created = new Logger(name);
    loggersByName[name] = created;
    return created;
}
