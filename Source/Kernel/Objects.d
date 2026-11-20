/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Kernel objects and the handle table
*/

module Source.Kernel.Objects;

// Std
import core.time : Duration, MonoTime;
import std.format : format;

// Core
import Source.Memory.Guest;
import Source.Service.Service;

// Objects
abstract class KObject {
    abstract string Describe() const;

    bool IsSignaled() const {
        return false;
    }
}

final class KProcess : KObject {
    ulong Id;

    this(ulong id) {
        Id = id;
    }

    override string Describe() const {
        return format("KProcess(%d)", Id);
    }
}

enum ThreadState {
    Created,
    Runnable,
    Waiting,
    Terminated,
}

enum ThreadWait {
    None,
    Sleep,
    Objects,
    Mutex,
    CondVar,
}

final class KThread : KObject {
    ulong Id;
    uint Handle;
    int Priority = 0x2C;
    int IdealCore = 0;
    ulong AffinityMask = 1;
    ThreadState State = ThreadState.Created;

    ulong[31] Registers;
    ulong Sp;
    ulong Pc;
    uint Pstate;
    uint Fpcr;
    uint Fpsr;
    ulong[2][32] Vectors;
    ulong TlsAddress;
    ulong TpidrEl0;

    ThreadWait Wait;
    KObject[] WaitObjects;
    ulong WaitAddress;
    ulong MutexAddress;
    uint Tag;
    bool HasDeadline;
    MonoTime Deadline;
    bool CancelPending;

    this(ulong id) {
        Id = id;
    }

    override bool IsSignaled() const {
        return State == ThreadState.Terminated;
    }

    override string Describe() const {
        return format("KThread(%d)", Id);
    }
}

final class KEvent : KObject {
    string Name;
    bool Signaled;
    Duration Period;
    MonoTime NextSignal;

    this(string name, bool signaled = false) {
        Name = name;
        Signaled = signaled;
    }

    void Signal() {
        Signaled = true;
    }

    void Clear() {
        Signaled = false;
    }

    void Tick(MonoTime now) {
        if (Period <= Duration.zero || now < NextSignal) {
            return;
        }
        Signaled = true;
        NextSignal += Period;
        if (NextSignal <= now) {
            NextSignal = now + Period;
        }
    }

    override bool IsSignaled() const {
        return Signaled;
    }

    override string Describe() const {
        return format("KEvent(%s)", Name);
    }
}

final class KSharedMemory : KObject {
    string Name;
    ubyte[] Bytes;

    this(string name, size_t size) {
        Name = name;
        Bytes = new ubyte[size];
    }

    ulong GetU64(size_t offset) {
        return *cast(ulong*) (Bytes.ptr + offset);
    }

    void SetU64(size_t offset, ulong value) {
        *cast(ulong*) (Bytes.ptr + offset) = value;
    }

    uint GetU32(size_t offset) {
        return *cast(uint*) (Bytes.ptr + offset);
    }

    void SetU32(size_t offset, uint value) {
        *cast(uint*) (Bytes.ptr + offset) = value;
    }

    override string Describe() const {
        return format("KSharedMemory(%s, 0x%X)", Name, Bytes.length);
    }
}

final class KTransferMemory : KObject {
    ulong Address;
    ulong Size;
    MemoryPermission Permission;

    this(ulong address, ulong size, MemoryPermission permission) {
        Address = address;
        Size = size;
        Permission = permission;
    }

    override string Describe() const {
        return format("KTransferMemory(0x%X, 0x%X)", Address, Size);
    }
}

final class KSession : KObject {
    IPCService Service;
    bool IsDomain;
    IPCService[uint] Objects;
    private uint nextObjectId = 1;

    this(IPCService service) {
        Service = service;
    }

    uint AddObject(IPCService service) {
        const uint id = nextObjectId++;
        Objects[id] = service;
        return id;
    }

    IPCService Object(uint id) {
        IPCService* found = id in Objects;
        return found is null ? null : *found;
    }

    override string Describe() const {
        return format("KSession(%s%s)", Service.Name, IsDomain ? ", domain" : "");
    }
}

final class HandleTable {
    enum uint CurrentThread = 0xFFFF8000;
    enum uint CurrentProcess = 0xFFFF8001;

    KThread Thread;
    KProcess Process;

    private KObject[uint] objects;
    private uint next = 0x1001;

    this(KProcess process, KThread thread) {
        Process = process;
        Thread = thread;
    }

    uint Add(KObject value) {
        while (next in objects || next == 0)
            next++;
        const uint handle = next++;
        objects[handle] = value;
        return handle;
    }

    void Set(uint handle, KObject value) {
        objects[handle] = value;
    }

    T Get(T : KObject = KObject)(uint handle) {
        if (handle == CurrentThread)
            return cast(T) Thread;
        if (handle == CurrentProcess)
            return cast(T) Process;
        KObject* found = handle in objects;
        return found is null ? null : cast(T) *found;
    }

    bool Remove(uint handle) {
        return objects.remove(handle);
    }
}
