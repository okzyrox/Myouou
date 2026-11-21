/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Disk cache of translated shaders
*/

module Source.Gpu.Shader.ShaderCache;

// Std
import std.file : exists, mkdirRecurse, read, write;
import std.format : format;
import std.path : buildPath;

// Core
import Source.Gpu.Shader.Translator;
import Source.Util.Logger;

// Types
enum uint ShaderCacheMagic = 0x4353_594D;
// should be bumped when the translator output changes
enum uint ShaderCacheVersion = 1;
enum size_t ShaderCacheHeaderWords = 8;

// Class
final class ShaderDiskCache {
    immutable string Folder;

    private Logger log;

    this(string folder) {
        Folder = folder;
        log = GetLogger("Gpu::ShaderCache");
        if (!exists(folder)) {
            mkdirRecurse(folder);
        }
        log.Info("Shader cache at %s", folder);
    }

    private string PathFor(ulong key) const {
        return buildPath(Folder, format("%016X.bin", key));
    }

    bool Load(ulong key, ShaderStageKind stage, out TranslatedShader shader) {
        const string path = PathFor(key);
        if (!exists(path)) {
            return false;
        }
        uint[] words;
        try {
            const ubyte[] raw = cast(const(ubyte)[]) read(path);
            if (raw.length % uint.sizeof != 0) {
                return false;
            }
            words = (cast(const(uint)[]) raw).dup;
        } catch (Exception exception) {
            log.Warn("Could not read cached shader %s (%s)!", path, exception.msg);
            return false;
        }
        if (words.length < ShaderCacheHeaderWords || words[0] != ShaderCacheMagic || words[1] != ShaderCacheVersion || words[2] != stage) {
            return false;
        }
        const size_t constBufferCount = words[6];
        const size_t textureCount = words[7];
        const size_t spirvStart = ShaderCacheHeaderWords + constBufferCount + textureCount;
        if (spirvStart >= words.length) {
            return false;
        }
        shader.Stage = stage;
        shader.AttributeMask = words[3];
        shader.ColorTargetMask = words[4];
        shader.InstructionCount = words[5];
        shader.ConstBuffers = words[ShaderCacheHeaderWords .. ShaderCacheHeaderWords + constBufferCount];
        shader.Textures = words[ShaderCacheHeaderWords + constBufferCount .. spirvStart];
        shader.Spirv = words[spirvStart .. $];
        shader.Ok = true;
        return true;
    }

    void Store(ulong key, const ref TranslatedShader shader) {
        if (!shader.Ok) {
            return;
        }
        uint[] words = [ShaderCacheMagic, ShaderCacheVersion, shader.Stage, shader.AttributeMask, shader.ColorTargetMask, cast(uint) shader.InstructionCount, cast(uint) shader.ConstBuffers.length, cast(uint) shader.Textures.length];
        words ~= shader.ConstBuffers;
        words ~= shader.Textures;
        words ~= shader.Spirv;
        try {
            write(PathFor(key), cast(const(void)[]) words);
        } catch (Exception exception) {
            log.Warn("Could not write cached shader %016X (%s)!", key, exception.msg);
        }
    }
}
