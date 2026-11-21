/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Key sets
*/

module Source.Crypto.Keys;

// Std
import std.array : split;
import std.file : exists, getcwd, readText;
import std.format : format;
import std.path : buildPath;
import std.string : indexOf, lineSplitter, strip, toLower;

// Core
import Source.Util.Logger;

// Types
enum string KeysFolder = "sandbox/keys";
enum string ProdKeysFile = "prod.keys";
enum string TitleKeysFile = "title.keys";

// Utils
private bool ParseHex(const(char)[] text, out ubyte[] bytes) {
    if (text.length == 0 || text.length % 2 != 0) {
        return false;
    }
    bytes = new ubyte[text.length / 2];
    foreach (i; 0 .. bytes.length) {
        int value = 0;
        foreach (c; text[i * 2 .. i * 2 + 2]) {
            int digit;
            if (c >= '0' && c <= '9') {
                digit = c - '0';
            } else if (c >= 'a' && c <= 'f') {
                digit = c - 'a' + 10;
            } else if (c >= 'A' && c <= 'F') {
                digit = c - 'A' + 10;
            } else {
                return false;
            }
            value = value * 16 + digit;
        }
        bytes[i] = cast(ubyte) value;
    }
    return true;
}

string HexString(const(ubyte)[] bytes) {
    return format("%(%02x%)", bytes);
}

// Class
final class KeySet {
    immutable string Folder;

    private ubyte[][string] keys;
    private ubyte[][string] titleKeys;
    private Logger log;

    this(string folder = buildPath(getcwd(), KeysFolder)) {
        Folder = folder;
        log = GetLogger("Keys");
        Load();
    }

    private void Load() {
        const string prodPath = buildPath(Folder, ProdKeysFile);
        const string titlePath = buildPath(Folder, TitleKeysFile);
        if (exists(prodPath)) {
            ParseInto(readText(prodPath), keys, prodPath);
        } else {
            log.Warn("There is no %s in %s!", ProdKeysFile, Folder);
        }
        if (exists(titlePath)) {
            ParseInto(readText(titlePath), titleKeys, titlePath);
        }
        log.Info("Loaded %d keys and %d title keys.", keys.length, titleKeys.length);
    }

    void ParseInto(string text, ref ubyte[][string] target, string source) {
        size_t lineNumber = 0;
        foreach (line; text.lineSplitter) {
            lineNumber++;
            const(char)[] content = line;
            foreach (marker; ["#", ";", "//"]) {
                const ptrdiff_t comment = content.indexOf(marker);
                if (comment >= 0) {
                    content = content[0 .. comment];
                }
            }
            content = content.strip;
            if (content.length == 0) {
                continue;
            }
            ptrdiff_t separator = content.indexOf('=');

            if (separator < 0) {
                separator = content.indexOf(',');
                if (separator < 0) {
                    // Invalid kv
                    continue;
                }
            }
            const string name = content[0 .. separator].strip.toLower.idup;
            ubyte[] value;
            if (name.length == 0 || !ParseHex(content[separator + 1 .. $].strip, value)) {
                log.Warn("%s:%d has a bad key value!", source, lineNumber);
                continue;
            }
            target[name] = value;
        }
    }

    void AddKey(string name, const(ubyte)[] value) {
        keys[name.toLower] = value.dup;
    }

    void AddTitleKey(const(ubyte)[] rightsId, const(ubyte)[] value) {
        titleKeys[HexString(rightsId)] = value.dup;
    }

    size_t Count() const {
        return keys.length;
    }

    size_t TitleKeyCount() const {
        return titleKeys.length;
    }

    bool Has(string name) const {
        return (name.toLower in keys) !is null;
    }

    const(ubyte)[] Get(string name) const {
        const(ubyte[])* found = name.toLower in keys;
        return found is null ? null : *found;
    }

    const(ubyte)[] TitleKey(const(ubyte)[] rightsId) const {
        const(ubyte[])* found = HexString(rightsId) in titleKeys;
        return found is null ? null : *found;
    }
}