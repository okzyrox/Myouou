/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * General format utility functions
*/

module Source.Format.Utils.General;

/// Data (as T) at an offset.
public T At(T)(const(ubyte)[] data, size_t offset) {
    return *cast(const(T)*) (data.ptr + offset);
}

/// Align a value, amazing i know.
public size_t AlignValue(size_t value, size_t alignment) pure nothrow @nogc @safe {
    return (value + alignment - 1) & ~(alignment - 1);
}