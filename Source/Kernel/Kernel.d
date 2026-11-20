/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * HLE kernel
*/

module Source.Kernel.Kernel;

// Std
import core.thread : Thread;
import core.time : dur;
import std.algorithm : min;
import std.format : format;
import std.random : uniform;
import std.stdio;
import std.array : byPair;

// Core
import Source.Util.Logger;
import Source.Emulator.GuestEnv;
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Kernel.Scheduler;
import Source.Kernel.Svc;
import Source.Memory.Guest;
import Source.Wrapper.DynarmicJit;

// Services
import Source.Service.Acc;
import Source.Service.Am;
import Source.Service.Audio;
import Source.Service.AudioOut;
import Source.Service.Apm;
import Source.Service.Fs;
import Source.Gpu.Gpu;
import Source.Gpu.Renderer;
import Source.Service.Hid;
import Source.Service.Nvdrv;
import Source.Service.Psm;
import Source.Service.Service;
import Source.Service.Set;
import Source.Service.Sm;
import Source.Service.Time;
import Source.Service.Vi;

// Mapped
import Source.FileSystem.Storage;

// Frontend
import Source.Frontend.HostAudio;
import Source.Frontend.HostDisplay;

// Types
enum InfoType : uint {
    CoreMask = 0,
    PriorityMask = 1,
    AliasRegionAddress = 2,
    AliasRegionSize = 3,
    HeapRegionAddress = 4,
    HeapRegionSize = 5,
    TotalMemorySize = 6,
    UsedMemorySize = 7,
    DebuggerAttached = 8,
    ResourceLimit = 9,
    IdleTickCount = 10,
    RandomEntropy = 11,
    AslrRegionAddress = 12,
    AslrRegionSize = 13,
    StackRegionAddress = 14,
    StackRegionSize = 15,
    SystemResourceSizeTotal = 16,
    SystemResourceSizeUsed = 17,
    ProgramId = 18,
    InitialProcessIdRange = 19,
    UserExceptionContextAddress = 20,
    TotalNonSystemMemorySize = 21,
    UsedNonSystemMemorySize = 22,
    IsApplication = 23,
    FreeThreadCount = 24,
    ThreadTickCount = 25,
    IsSvcPermitted = 26,
    IoRegionHint = 27,
    AliasRegionExtraSize = 28,
}

enum BreakReason : uint { // temp
    Panic = 0,
    Assert = 1,
    User = 2,
    PreLoadDll = 3,
    PostLoadDll = 4,
    PreUnloadDll = 5,
    PostUnloadDll = 6,
    CppException = 7,
}

struct AddressSpace {
    ulong AslrBase = 0x0800_0000;
    ulong AslrSize = 0x7F_F800_0000;
    ulong HeapBase = 0x1_0000_0000;
    ulong HeapSize = 0x1_0000_0000;
    ulong AliasBase = 0x2_0000_0000;
    ulong AliasSize = 0x10_0000_0000;
    ulong StackBase = 0x12_0000_0000;
    ulong StackSize = 0x1_0000_0000;
    ulong TotalMemory = 0x2000_0000;

    ulong End() const pure nothrow @nogc @safe {
        return AslrBase + AslrSize;
    }
}

struct GuestMemoryInfo {
    ulong Address;
    ulong Size;
    uint Type;
    uint Attribute;
    uint Permission;
    uint IpcRefCount;
    uint DeviceRefCount;
    uint Padding;
}

// Class
final class HorizonKernel {
    GuestEnvironment Environment;
    GuestMemory Memory;
    DynarmicJit Jit;
    HandleTable Handles;
    Scheduler Threading;
    ServiceRegistry Services;
    AddressSpace Space;
    // Host
    HostDisplay DisplayOnHost;
    HostAudio AudioOnHost;
    // States
    AppletState Applet;
    HidState Hid;
    Gpu Graphics;
    NvState Nv;
    ViState Vi;
    TimeState Time;
    SwitchStorage Storage;
    AccountState Accounts;
    AudioState Audio;

    ulong ProgramId = 0x0100_0000_0000_100D;
    Logger SvcLog;
    Logger KernelLog;
    Logger GuestLog;

    private ulong heapSize;

    this(GuestEnvironment environment, uint mainThreadHandle) {
        Environment = environment;
        SvcLog = GetLogger("SVC");
        KernelLog = GetLogger("Kernel");
        GuestLog = GetLogger("Guest");
        Memory = environment.Memory;
        Jit = environment.Jit;

        KProcess process = new KProcess(0x51);
        KThread mainThread = new KThread(1);
        Handles = new HandleTable(process, mainThread);
        Handles.Set(mainThreadHandle, mainThread);
        mainThread.Handle = mainThreadHandle;
        Threading = new Scheduler(environment, Memory, Handles, mainThread);

        DisplayOnHost = new HostDisplay();
        AudioOnHost = new HostAudio();
        Graphics = new Gpu(Memory);
        Graphics.ThreeD.Renderer = new HostRenderer(DisplayOnHost, Graphics.MemoryManager);

        Applet = new AppletState();
        Hid = new HidState();
        DisplayOnHost.OnInputCallback = &Hid.WriteNpadInput;
        Audio = new AudioState(Memory, Threading, AudioOnHost);
        Nv = new NvState(Graphics);
        Vi = new ViState(Memory, Nv, DisplayOnHost);
        Time = new TimeState();
        Storage = new SwitchStorage();
        Accounts = new AccountState();
        
        Applet.Storage = Storage;
        Applet.ProgramId = ProgramId;
        Applet.PreselectedUser = Accounts.Users[0].Uid;
        Services = new ServiceRegistry();
        RegisterServices();
    }

    private void RegisterServices() {
        Services.Register!SetSysService("set:sys");
        Services.Register("appletOE", () => cast(IPCService) new AppletOEService(Applet));
        foreach (name; ["apm", "apm:am", "apm:p"])
            Services.Register(name, ApmFactory(name));
        Services.Register("psm", () => cast(IPCService) new PsmService());
        Services.Register("hid", () => cast(IPCService) new HidService(Hid));
        foreach (name; ["nvdrv", "nvdrv:a", "nvdrv:s", "nvdrv:t"])
            Services.Register(name, NvdrvFactory(name));
        foreach (viService; ["vi:u": 0, "vi:s": 1, "vi:m": 2].byPair) {
            Services.Register(viService[0], ViFactory(viService[0], viService[1]));
        }
        foreach (name; ["acc:u0", "acc:u1"]) {
            Services.Register(name, AccountFactory(name));
        }
        foreach (name; ["time:u", "time:a", "time:s"]) {
            Services.Register(name, TimeFactory(name));
        }

        Services.Register("audren:u", () => cast(IPCService) new AudioRendererManagerService(Audio));
        Services.Register("audout:u", () => cast(IPCService) new AudioOutManagerService(Audio));
        Services.Register("fsp-srv", () => cast(IPCService) new FileSystemProxyService(Storage, ProgramId));
    }

    // todo: refactor factories to each service individually?
    private static ServiceFactory ApmFactory(string name) {
        return () => cast(IPCService) new ApmService(name);
    }

    private ServiceFactory NvdrvFactory(string name) {
        return () => cast(IPCService) new NvdrvService(name, Nv);
    }

    private ServiceFactory ViFactory(string name, uint commandId) {
        return () => cast(IPCService) new ViRootService(name, commandId, Vi);
    }

    private ServiceFactory AccountFactory(string name) {
        return () => cast(IPCService) new AccountService(name, Accounts);
    }

    private ServiceFactory TimeFactory(string name) {
        return () => cast(IPCService) new TimeStaticService(name, Time);
    }

    void Shutdown() {
        Audio.Output.Close();
        DisplayOnHost.Close();
    }

    bool HandleSvc(uint id) {
        const ulong[31] arguments = Jit.Registers;
        bool keepRunning = true;
        bool yield = false;
        uint result = ResultSuccess;

        switch (id) {
            case Svc.SetHeapSize: result = SetHeapSize(); break;
            case Svc.SetMemoryPermission: result = SetMemoryPermission(); break;
            case Svc.SetMemoryAttribute: result = SetMemoryAttribute(); break;
            case Svc.MapMemory: result = MapMemory(); break;
            case Svc.UnmapMemory: result = UnmapMemory(); break;
            case Svc.QueryMemory: result = QueryMemory(); break;
            case Svc.ExitProcess: keepRunning = ExitProcess(); break;
            case Svc.CreateThread: result = CreateThread(); break;
            case Svc.StartThread: result = StartThread(); break;
            case Svc.ExitThread: Threading.Exit(); break;
            case Svc.SleepThread: result = SleepThread(yield); break;
            case Svc.GetThreadPriority: result = GetThreadPriority(); break;
            case Svc.SetThreadPriority: result = SetThreadPriority(); break;
            case Svc.GetThreadCoreMask: result = GetThreadCoreMask(); break;
            case Svc.SetThreadCoreMask: result = ResultSuccess; break;
            case Svc.GetCurrentProcessorNumber: result = GetCurrentProcessorNumber(); break;
            case Svc.SignalEvent: result = SignalEvent(); break;
            case Svc.ClearEvent: result = ClearEvent(); break;
            case Svc.MapSharedMemory: result = MapSharedMemory(); break;
            case Svc.UnmapSharedMemory: result = UnmapSharedMemory(); break;
            case Svc.CreateTransferMemory: result = CreateTransferMemory(); break;
            case Svc.CloseHandle: result = CloseHandle(); break;
            case Svc.ResetSignal: result = ResetSignal(); break;
            case Svc.WaitSynchronization: result = WaitSynchronization(); break;
            case Svc.CancelSynchronization: result = CancelSynchronization(); break;
            case Svc.ArbitrateLock: result = ArbitrateLock(); break;
            case Svc.ArbitrateUnlock: result = ArbitrateUnlock(); break;
            case Svc.WaitProcessWideKeyAtomic: result = WaitProcessWideKeyAtomic(); break;
            case Svc.SignalProcessWideKey: result = SignalProcessWideKey(); break;
            case Svc.GetSystemTick:
                OutVal(0, Environment.GetCntpct());
                return true;
            case Svc.ConnectToNamedPort: result = ConnectToNamedPort(); break;
            case Svc.SendSyncRequest: result = SendSyncRequest(); break;
            case Svc.GetProcessId: result = GetProcessId(); break;
            case Svc.GetThreadId: result = GetThreadId(); break;
            case Svc.Break: keepRunning = Break(); break;
            case Svc.OutputDebugString: result = OutputDebugString(); break;
            case Svc.ReturnFromException: keepRunning = ReturnFromException(); break;
            case Svc.GetInfo: result = GetInfo(); break;
            case Svc.FlushEntireDataCache: result = ResultSuccess; break;
            case Svc.FlushDataCache: result = ResultSuccess; break;
            case Svc.CreateEvent: result = CreateEvent(); break;
            case Svc.MapTransferMemory: result = ResultSuccess; break;
            case Svc.UnmapTransferMemory: result = ResultSuccess; break;
            default:
                return StubSvcId(Jit, id);
        }

        if (!keepRunning)
            return false;

        Jit.Register(0, result);
        SvcLog.Trace("0x%02X %-32s in: X0=0x%X X1=0x%X X2=0x%X -> %s", id, GetSvcName(id), arguments[0], arguments[1], arguments[2], FormatResult(result));
        return Threading.Reschedule(yield);
    }

    private ulong GetArg(size_t index) {
        return Jit.Register(index);
    }

    private void OutVal(size_t index, ulong value) {
        Jit.Register(index, value);
    }

    private static bool IsPageAligned(ulong value) {
        return value % GuestPageSize == 0;
    }

    string ReadCString(ulong address, size_t maxLength) {
        char[] text;
        foreach (i; 0 .. maxLength) {
            const char c = cast(char) Memory.Read!ubyte(address + i);
            if (c == 0)
                break;
            text ~= c;
        }
        return text.idup;
    }

    private void Invalidate(ulong address, ulong size) {
        Jit.InvalidateCacheRange(address, cast(size_t) size);
    }

    private uint SetHeapSize() {
        const ulong size = GetArg(1);
        if (size % 0x20_0000 != 0 || size > Space.HeapSize)
            return KernelResult.InvalidSize;

        if (size != heapSize) {
            ubyte[] preserved;
            if (heapSize != 0) {
                preserved = new ubyte[cast(size_t) min(heapSize, size)];
                Memory.ReadBytes(Space.HeapBase, preserved);
                Memory.Unmap(Space.HeapBase, heapSize);
            }
            if (size != 0) {
                Memory.Map(Space.HeapBase, cast(size_t) size, MemoryPermission.ReadWrite, "Heap", MemoryType.Normal);
                Memory.WriteBytes(Space.HeapBase, preserved);
            }
            Invalidate(Space.HeapBase, heapSize > size ? heapSize : size);
            heapSize = size;
        }

        OutVal(1, Space.HeapBase);
        return ResultSuccess;
    }

    private uint SetMemoryPermission() {
        const ulong address = GetArg(0);
        const ulong size = GetArg(1);
        const uint permission = cast(uint) GetArg(2);
        if (!IsPageAligned(address))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size))
            return KernelResult.InvalidSize;
        if ((permission & ~cast(uint) MemoryPermission.ReadWrite) != 0 || permission == MemoryPermission.Write)
            return KernelResult.InvalidNewMemoryPermission;
        if (!Memory.Protect(address, cast(size_t) size, cast(MemoryPermission) permission))
            return KernelResult.InvalidCurrentMemory;
        Invalidate(address, size);
        return ResultSuccess;
    }

    private uint SetMemoryAttribute() {
        const ulong address = GetArg(0);
        const ulong size = GetArg(1);
        const uint mask = cast(uint) GetArg(2);
        const uint value = cast(uint) GetArg(3);
        if (!IsPageAligned(address))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size))
            return KernelResult.InvalidSize;
        if ((mask | value) != mask || ((mask | value) & ~0x18u) != 0)
            return KernelResult.InvalidCombination;
        if (!Memory.SetAttribute(address, cast(size_t) size, mask, value))
            return KernelResult.InvalidCurrentMemory;
        return ResultSuccess;
    }

    private uint MapMemory() {
        const ulong destination = GetArg(0);
        const ulong source = GetArg(1);
        const ulong size = GetArg(2);
        if (!IsPageAligned(destination) || !IsPageAligned(source))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size))
            return KernelResult.InvalidSize;
        if (!Memory.IsFree(destination, cast(size_t) size))
            return KernelResult.InvalidMemoryRegion;

        MemoryRegion[] sources = Memory.Isolate(source, cast(size_t) size);
        if (sources.length != 1)
            return KernelResult.InvalidCurrentMemory;

        Memory.MapBacked(destination, sources[0].Bytes, sources[0].Permission, "Alias", MemoryType.Stack);
        sources[0].Permission = MemoryPermission.None;
        Invalidate(source, size);
        return ResultSuccess;
    }

    private uint UnmapMemory() {
        const ulong destination = GetArg(0);
        const ulong source = GetArg(1);
        const ulong size = GetArg(2);
        if (!IsPageAligned(destination) || !IsPageAligned(source))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size))
            return KernelResult.InvalidSize;
        if (!Memory.Unmap(destination, cast(size_t) size))
            return KernelResult.InvalidMemoryRegion;
        Memory.Protect(source, cast(size_t) size, MemoryPermission.ReadWrite);
        Invalidate(destination, size);
        Invalidate(source, size);
        return ResultSuccess;
    }

    private uint QueryMemory() {
        const ulong infoAddress = GetArg(0);
        const ulong address = GetArg(2);
        const MemoryQuery query = Memory.Query(address, Space.End());

        GuestMemoryInfo info;
        info.Address = query.Base;
        info.Size = query.Size;
        info.Type = query.MemType;
        info.Attribute = query.Attribute;
        info.Permission = query.Permission;
        Memory.WriteBytes(infoAddress, (cast(const(ubyte)*) &info)[0 .. info.sizeof]);
        OutVal(1, 0);
        return ResultSuccess;
    }

    private bool ExitProcess() {
        KernelLog.Info("Guest exited the process");
        return false;
    }

    // Threads
    private uint CreateThread() {
        const ulong entry = GetArg(1);
        const ulong argument = GetArg(2);
        const ulong stackTop = GetArg(3);
        const int priority = cast(int) GetArg(4);
        const int core = cast(int) GetArg(5);
        if (priority < 0 || priority > 0x3F) {
            return KernelResult.InvalidCombination;
        }
        KThread thread = Threading.Create(entry, argument, stackTop, priority, core);
        thread.Handle = Handles.Add(thread);
        OutVal(1, thread.Handle);
        KernelLog.Trace("Created thread %d (handle 0x%X, entry 0x%X, stack 0x%X) of priority 0x%X", thread.Id, thread.Handle, entry, stackTop, priority);
        return ResultSuccess;
    }

    private uint StartThread() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(0));
        if (thread is null) {
            return KernelResult.InvalidHandle;
        }
        if (thread.State != ThreadState.Created) {
            return KernelResult.InvalidState;
        }
        Threading.Start(thread);
        return ResultSuccess;
    }

    private uint SleepThread(ref bool yield) {
        const long nanoseconds = cast(long) GetArg(0);
        if (nanoseconds <= 0) {
            yield = true;
            return ResultSuccess;
        }
        Threading.Block(ThreadWait.Sleep, nanoseconds);
        return ResultSuccess;
    }

    private uint GetThreadPriority() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(1));
        if (thread is null)
            return KernelResult.InvalidHandle;
        OutVal(1, thread.Priority);
        return ResultSuccess;
    }

    private uint SetThreadPriority() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(0));
        if (thread is null)
            return KernelResult.InvalidHandle;
        thread.Priority = cast(int) GetArg(1);
        return ResultSuccess;
    }

    private uint GetThreadCoreMask() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(2));
        if (thread is null)
            return KernelResult.InvalidHandle;
        OutVal(1, thread.IdealCore);
        OutVal(2, thread.AffinityMask);
        return ResultSuccess;
    }

    private uint GetCurrentProcessorNumber() {
        OutVal(0, 0);
        return ResultSuccess;
    }

    private uint SignalEvent() {
        KEvent event = Handles.Get!KEvent(cast(uint) GetArg(0));
        if (event is null)
            return KernelResult.InvalidHandle;
        event.Signal();
        return ResultSuccess;
    }

    private uint ClearEvent() {
        KEvent event = Handles.Get!KEvent(cast(uint) GetArg(0));
        if (event is null)
            return KernelResult.InvalidHandle;
        event.Clear();
        return ResultSuccess;
    }

    private uint ResetSignal() {
        KEvent event = Handles.Get!KEvent(cast(uint) GetArg(0));
        if (event is null)
            return KernelResult.InvalidHandle;
        if (!event.Signaled)
            return KernelResult.InvalidState;
        event.Clear();
        return ResultSuccess;
    }

    private uint CreateEvent() {
        KEvent event = new KEvent("UserEvent");
        OutVal(1, Handles.Add(event));
        OutVal(2, Handles.Add(event));
        return ResultSuccess;
    }

    private uint MapSharedMemory() {
        KSharedMemory sharedMemory = Handles.Get!KSharedMemory(cast(uint) GetArg(0));
        const ulong address = GetArg(1);
        const ulong size = GetArg(2);
        const uint permission = cast(uint) GetArg(3);
        if (sharedMemory is null)
            return KernelResult.InvalidHandle;
        if (!IsPageAligned(address))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size) || size > sharedMemory.Bytes.length)
            return KernelResult.InvalidSize;
        if (!Memory.IsFree(address, cast(size_t) size))
            return KernelResult.InvalidMemoryRegion;

        Memory.MapBacked(address, sharedMemory.Bytes[0 .. cast(size_t) size], cast(MemoryPermission) permission, sharedMemory.Name, MemoryType.Shared);
        Invalidate(address, size);
        return ResultSuccess;
    }

    private uint UnmapSharedMemory() {
        const ulong address = GetArg(1);
        const ulong size = GetArg(2);
        if (Handles.Get!KSharedMemory(cast(uint) GetArg(0)) is null)
            return KernelResult.InvalidHandle;
        if (!Memory.Unmap(address, cast(size_t) size))
            return KernelResult.InvalidMemoryRegion;
        Invalidate(address, size);
        return ResultSuccess;
    }

    private uint CreateTransferMemory() {
        const ulong address = GetArg(1);
        const ulong size = GetArg(2);
        const uint permission = cast(uint) GetArg(3);
        if (!IsPageAligned(address))
            return KernelResult.InvalidAddress;
        if (size == 0 || !IsPageAligned(size))
            return KernelResult.InvalidSize;
        if (!Memory.IsMapped(address, cast(size_t) size))
            return KernelResult.InvalidCurrentMemory;
        OutVal(1, Handles.Add(new KTransferMemory(address, size, cast(MemoryPermission) permission)));
        return ResultSuccess;
    }

    private uint CloseHandle() {
        const uint handle = cast(uint) GetArg(0);
        if (handle == HandleTable.CurrentThread || handle == HandleTable.CurrentProcess)
            return ResultSuccess;
        return Handles.Remove(handle) ? ResultSuccess : KernelResult.InvalidHandle;
    }

    // Synchronization
    private uint WaitSynchronization() {
        const ulong handlesAddress = GetArg(1);
        const ulong count = GetArg(2);
        const long timeout = cast(long) GetArg(3);
        if (count > 0x40) {
            return KernelResult.OutOfRange;
        }

        KObject[] waitables;
        foreach (i; 0 .. count) {
            KObject waitable = Handles.Get(Memory.Read!uint(handlesAddress + i * 4));
            if (waitable is null) {
                return KernelResult.InvalidHandle;
            }
            if (waitable.IsSignaled()) {
                OutVal(1, i);
                return ResultSuccess;
            }
            waitables ~= waitable;
        }

        KThread current = Threading.Current;
        if (current.CancelPending) {
            current.CancelPending = false;
            return KernelResult.Cancelled;
        }
        if (timeout == 0) {
            return KernelResult.TimedOut;
        }
        current.WaitObjects = waitables;
        Threading.Block(ThreadWait.Objects, timeout);
        return KernelResult.TimedOut;
    }

    private uint CancelSynchronization() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(0));
        if (thread is null) {
            return KernelResult.InvalidHandle;
        }
        if (thread.State == ThreadState.Waiting && thread.Wait == ThreadWait.Objects) {
            Threading.Wake(thread, KernelResult.Cancelled);
        } else {
            thread.CancelPending = true;
        }
        return ResultSuccess;
    }

    private uint ArbitrateLock() {
        const uint ownerHandle = cast(uint) GetArg(0);
        const ulong address = GetArg(1);
        const uint tag = cast(uint) GetArg(2);
        if (Memory.Read!uint(address) != (ownerHandle | MutexWaitersBit)) {
            // owner handle is held if the guest is waiting with the waitersbit
            return ResultSuccess;
        }
        if (Handles.Get!KThread(ownerHandle) is null) {
            return KernelResult.InvalidHandle;
        }
        KThread current = Threading.Current;
        current.MutexAddress = address;
        current.Tag = tag;
        Threading.Block(ThreadWait.Mutex, -1);
        return ResultSuccess;
    }

    private uint ArbitrateUnlock() {
        Threading.ReleaseMutex(GetArg(0));
        return ResultSuccess;
    }

    private uint WaitProcessWideKeyAtomic() {
        const ulong mutexAddress = GetArg(0);
        const ulong key = GetArg(1);
        const uint tag = cast(uint) GetArg(2);
        const long timeout = cast(long) GetArg(3);
        Threading.ReleaseMutex(mutexAddress);
        KThread current = Threading.Current;
        current.WaitAddress = key;
        current.MutexAddress = mutexAddress;
        current.Tag = tag;
        Memory.Write!uint(key, 1);
        Threading.Block(ThreadWait.CondVar, timeout);
        return KernelResult.TimedOut;
    }

    private uint SignalProcessWideKey() {
        const ulong key = GetArg(0);
        const int count = cast(int) GetArg(1);
        KThread[] waiters = Threading.Waiters(ThreadWait.CondVar, key);
        const size_t woken = count <= 0 || count > waiters.length ? waiters.length : count;
        foreach (thread; waiters[0 .. woken]) {
            Threading.SignalCondVar(thread);
        }
        if (woken == waiters.length) {
            Memory.Write!uint(key, 0);
        }
        return ResultSuccess;
    }

    private uint ConnectToNamedPort() {
        const string name = ReadCString(GetArg(1), 12);
        if (name != "sm:") { // todo: make available ports as array
            SvcLog.Stub("ConnectToNamedPort: no port named %s", name);
            return KernelResult.NotFound;
        }
        OutVal(1, Handles.Add(new KSession(new SmService(Services))));
        return ResultSuccess;
    }

    private uint SendSyncRequest() {
        KSession session = Handles.Get!KSession(cast(uint) GetArg(0));
        if (session is null)
            return KernelResult.InvalidHandle;
        return ProcessSyncRequest(this, session, Environment.TpidrroEl0);
    }

    private uint GetProcessId() {
        KObject target = Handles.Get(cast(uint) GetArg(1));
        if (target is null)
            return KernelResult.InvalidHandle;
        OutVal(1, Handles.Process.Id);
        return ResultSuccess;
    }

    private uint GetThreadId() {
        KThread thread = Handles.Get!KThread(cast(uint) GetArg(1));
        if (thread is null)
            return KernelResult.InvalidHandle;
        OutVal(1, thread.Id);
        return ResultSuccess;
    }

    private bool Break() {
        const uint reason = cast(uint) GetArg(0);
        const ulong address = GetArg(1);
        const ulong size = GetArg(2);
        const bool notificationOnly = (reason & 0x8000_0000) != 0;
        const BreakReason kind = cast(BreakReason) (reason & 0x7FFF_FFFF);

        string detail;
        if (size == 4)
            detail = format(", result %s", FormatResult(Memory.Read!uint(address)));
        else if (size != 0)
            detail = format(", info 0x%X (0x%X bytes)", address, size);

        SvcLog.Error("Break: %s%s%s", kind, detail, notificationOnly ? " (notification)" : "");
        if (notificationOnly) {
            Jit.Register(0, ResultSuccess);
            return true;
        }
        return false;
    }

    private uint OutputDebugString() {
        const ulong address = GetArg(0);
        const ulong size = GetArg(1);
        ubyte[] text = new ubyte[cast(size_t) min(size, 0x1000)];
        Memory.ReadBytes(address, text);
        GuestLog.Info("%s", cast(string) text);
        return ResultSuccess;
    }

    private bool ReturnFromException() {
        SvcLog.Error("ReturnFromException %s", FormatResult(cast(uint) GetArg(0)));
        return false;
    }

    private uint GetInfo() {
        const uint infoTyp = cast(uint) GetArg(1);
        const uint handle = cast(uint) GetArg(2);
        const ulong subType = GetArg(3);
        ulong value;

        switch (infoTyp) {
            case InfoType.CoreMask: value = 0xF; break;
            case InfoType.PriorityMask: value = 0xFFFF_FFFF_FFFF_FFFF; break;
            case InfoType.AliasRegionAddress: value = Space.AliasBase; break;
            case InfoType.AliasRegionSize: value = Space.AliasSize; break;
            case InfoType.HeapRegionAddress: value = Space.HeapBase; break;
            case InfoType.HeapRegionSize: value = Space.HeapSize; break;
            case InfoType.TotalMemorySize: value = Space.TotalMemory; break;
            case InfoType.TotalNonSystemMemorySize: value = Space.TotalMemory; break;
            case InfoType.UsedMemorySize: value = GetUsedMemory(); break;
            case InfoType.UsedNonSystemMemorySize: value = GetUsedMemory(); break;
            case InfoType.DebuggerAttached: value = 0; break;
            case InfoType.ResourceLimit: value = 0; break;
            case InfoType.IdleTickCount: value = 0; break;
            case InfoType.RandomEntropy:
                if (subType > 3)
                    return KernelResult.InvalidCombination;
                value = uniform!ulong();
                break;
            case InfoType.AslrRegionAddress: value = Space.AslrBase; break;
            case InfoType.AslrRegionSize: value = Space.AslrSize; break;
            case InfoType.StackRegionAddress: value = Space.StackBase; break;
            case InfoType.StackRegionSize: value = Space.StackSize; break;
            case InfoType.SystemResourceSizeTotal: value = 0; break;
            case InfoType.SystemResourceSizeUsed: value = 0; break;
            case InfoType.ProgramId: value = ProgramId; break;
            case InfoType.UserExceptionContextAddress: value = 0; break;
            case InfoType.IsApplication: value = 1; break;
            case InfoType.FreeThreadCount: value = 0x60; break;
            case InfoType.ThreadTickCount: value = Environment.GetCntpct(); break;
            case InfoType.IsSvcPermitted: value = 1; break;
            case InfoType.AliasRegionExtraSize: value = 0; break;
            default:
                SvcLog.Stub("GetInfo: unknown type 0x%X (handle 0x%X  sub 0x%X)", infoTyp, handle, subType);
                return KernelResult.InvalidEnumValue;
        }

        OutVal(1, value);
        return ResultSuccess;
    }

    private ulong GetUsedMemory() {
        ulong total;
        foreach (region; Memory.Regions)
            total += region.Bytes.length;
        return total;
    }
}
