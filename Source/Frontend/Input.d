/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Keyboard to npad
*/

module Source.Frontend.Input;

// Std
import std.file : exists, readText, thisExePath, write, getcwd;
import std.path : buildPath, dirName;
import std.string : indexOf, lineSplitter, strip, toLower, toStringz;

// Deps
import bindbc.sdl;

// Core
import Source.Util.Logger;

// Types
enum NpadButton : ulong {
    A = 1UL << 0,
    B = 1UL << 1,
    X = 1UL << 2,
    Y = 1UL << 3,
    // Trigger
    StickL = 1UL << 4,
    StickR = 1UL << 5,
    L = 1UL << 6,
    R = 1UL << 7,
    ZL = 1UL << 8,
    ZR = 1UL << 9,
    Plus = 1UL << 10,
    Minus = 1UL << 11,
    // DPAD
    Left = 1UL << 12,
    Up = 1UL << 13,
    Right = 1UL << 14,
    Down = 1UL << 15,
    // Sticks
    StickLLeft = 1UL << 16,
    StickLUp = 1UL << 17,
    StickLRight = 1UL << 18,
    StickLDown = 1UL << 19,
    StickRLeft = 1UL << 20,
    StickRUp = 1UL << 21,
    StickRRight = 1UL << 22,
    StickRDown = 1UL << 23,
    // Sidebt
    LeftSL = 1UL << 24,
    LeftSR = 1UL << 25,
    RightSL = 1UL << 26,
    RightSR = 1UL << 27,
}

enum int StickMax = 0x7FFF;

struct NpadInput {
    ulong Buttons;
    int LeftX;
    int LeftY;
    int RightX;
    int RightY;
}

struct KeyBinding {
    string KeyName;
    NpadButton Button;
    SDL_Scancode Scancode;
}

enum string DefaultOptions = "# Keybind Maps are listed below. Format: <Key>,<Button>
Return,Plus
Backspace,Minus
X,A
Z,B
S,X
A,Y
Q,L
E,R
1,ZL
3,ZR
Up,Up
Down,Down
Left,Left
Right,Right
I,StickLUp
J,StickLLeft
K,StickLDown
L,StickLRight
Keypad 8,StickRUp
Keypad 4,StickRLeft
Keypad 5,StickRDown
Keypad 6,StickRRight
";

// Class
final class InputConfig {
    string Path;
    KeyBinding[] Bindings;

    private bool resolved;
    private bool[SDL_SCANCODE_COUNT] pressed;
    private Logger log;

    this() {
        log = GetLogger("Input");
        Path = buildPath(getcwd(), "options.txt");
    }

    void Load() {
        if (!exists(Path)) {
            write(Path, DefaultOptions);
            log.Info("Created default keymap.");
        }
        Bindings = Parse(readText(Path));
        resolved = false;
        log.Info("Loaded key bindings from %s", Path);
    }

    private KeyBinding[] Parse(string text) {
        KeyBinding[] result;
        size_t lineNumber;
        foreach (rawLine; text.lineSplitter) {
            const string line = rawLine.strip;
            lineNumber++;
            if (line.length == 0 || line[0] == '#')
                continue;

            const ptrdiff_t split = line.indexOf(',');
            if (split <= 0) {
                log.Warn("options.txt:%d: Expected <Key>,<Button>, got '%s'", lineNumber, line);
                continue;
            }
            const string key = line[0 .. split].strip;
            const string button = line[split + 1 .. $].strip;
            NpadButton parsed;
            if (!ParseButton(button, parsed)) {
                continue;
            }
            result ~= KeyBinding(key, parsed, SDL_SCANCODE_UNKNOWN);
        }
        return result;
    }

    private static bool ParseButton(string name, out NpadButton button) {
        const string wanted = name.toLower;
        foreach (member; __traits(allMembers, NpadButton)) {
            if (member.toLower == wanted) {
                button = __traits(getMember, NpadButton, member);
                return true;
            }
        }
        return false;
    }

    private void Resolve() {
        foreach (ref binding; Bindings) {
            binding.Scancode = SDL_GetScancodeFromName(binding.KeyName.toStringz);
            if (binding.Scancode == SDL_SCANCODE_UNKNOWN)
                log.Warn("Unknown keyboard key '%s'", binding.KeyName);
        }
        resolved = true;
    }

    void HandleScancode(SDL_Scancode scancode) {
        if (scancode < pressed.length)
            pressed[scancode] = true;
    }

    NpadInput Poll() {
        if (!resolved)
            Resolve();

        int keyCount;
        const(bool)* keys = SDL_GetKeyboardState(&keyCount);
        NpadInput input;
        if (keys is null)
            return input;

        foreach (binding; Bindings) {
            if (binding.Scancode == SDL_SCANCODE_UNKNOWN)
                continue;
            const bool held = binding.Scancode < keyCount && keys[binding.Scancode];
            const bool tapped = binding.Scancode < pressed.length && pressed[binding.Scancode];
            if (held || tapped)
                input.Buttons |= binding.Button;
        }
        pressed[] = false;

        input.LeftX = Axis(input.Buttons, NpadButton.StickLRight, NpadButton.StickLLeft);
        input.LeftY = Axis(input.Buttons, NpadButton.StickLUp, NpadButton.StickLDown);
        input.RightX = Axis(input.Buttons, NpadButton.StickRRight, NpadButton.StickRLeft);
        input.RightY = Axis(input.Buttons, NpadButton.StickRUp, NpadButton.StickRDown);
        return input;
    }

    private static int Axis(ulong buttons, NpadButton positive, NpadButton negative) {
        int value;
        if (buttons & positive)
            value += StickMax;
        if (buttons & negative)
            value -= StickMax;
        return value;
    }
}
