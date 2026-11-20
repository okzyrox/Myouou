/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * Coop guest thread scheduling on the single JIT
*/

module Source.Kernel.Scheduler;

// Std
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;

// Core
import Source.Emulator.GuestEnv;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Memory.Guest;
import Source.Util.Logger;
import Source.Wrapper.DynarmicJit;

// Types
enum ulong TlsSlotSize = 0x200;
enum uint MutexWaitersBit = 0x4000_0000;
enum Duration TimeSlice = dur!"msecs"(2);
enum Duration MaxIdleSleep = dur!"msecs"(10);

// Class
final class Scheduler {
    KThread Current;
    KThread[] Threads;
    KEvent[] PeriodicEvents;

    private GuestEnvironment environment;
    private DynarmicJit jit;
    private GuestMemory memory;
    private HandleTable handles;
    private ulong tlsBase;
    private size_t tlsSlots = 1;
    // Threads will take turns with the JIT, and will switch only if the running thread is blocked, yields or used up the slice its in
    // todo: however it doesnt do any preemtpion for guest code , so other threads might get ignored too much
    private ulong nextId = 2;
    private MonoTime sliceStart;
    private Logger log;

    this(GuestEnvironment environment, GuestMemory memory, HandleTable handles, KThread main) {
        this.environment = environment;
        this.jit = environment.Jit;
        this.memory = memory;
        this.handles = handles;
        main.State = ThreadState.Runnable;
        Current = main;
        Threads = [main];
        sliceStart = MonoTime.currTime;
        log = GetLogger("Scheduler");
    }

    // Timers
    void AddPeriodic(KEvent event, Duration period) {
        event.Period = period;
        event.NextSignal = MonoTime.currTime + period;
        PeriodicEvents ~= event;
    }

    // Threads
    KThread Create(ulong entry, ulong argument, ulong stackTop, int priority, int core) {
        if (tlsBase == 0) {
            tlsBase = environment.TpidrroEl0;
        }
        KThread thread = new KThread(nextId++);
        thread.Priority = priority;
        thread.IdealCore = core < 0 ? 0 : core;
        thread.Registers[0] = argument;
        thread.Pc = entry;
        thread.Sp = stackTop;
        thread.Fpcr = jit.Fpcr;
        thread.TlsAddress = AllocateTls();
        Threads ~= thread;
        return thread;
    }

    private ulong AllocateTls() {
        const ulong address = tlsBase + tlsSlots++ * TlsSlotSize;
        const ulong page = address & ~cast(ulong) (GuestPageSize - 1);
        if (!memory.IsMapped(page, GuestPageSize)) {
            // todo: make tls slot reused on exit
            memory.Map(page, GuestPageSize, MemoryPermission.ReadWrite, "Tls", MemoryType.ThreadLocal);
        }
        memory.WriteBytes(address, new ubyte[TlsSlotSize]);
        return address;
    }

    void Start(KThread thread) {
        thread.State = ThreadState.Runnable;
    }

    void Exit() {
        Current.State = ThreadState.Terminated;
        Current.Wait = ThreadWait.None;
        log.Trace("Thread %d exited", Current.Id);
    }

    // Waiting
    void Block(ThreadWait wait, long timeout) {
        Current.State = ThreadState.Waiting;
        Current.Wait = wait;
        Current.HasDeadline = timeout >= 0;
        if (Current.HasDeadline) {
            Current.Deadline = MonoTime.currTime + dur!"nsecs"(timeout);
        }
    }

    void Wake(KThread thread, uint result) {
        thread.State = ThreadState.Runnable;
        thread.Wait = ThreadWait.None;
        thread.WaitObjects = null;
        thread.HasDeadline = false;
        thread.Registers[0] = result;
    }

    KThread[] Waiters(ThreadWait wait, ulong address) {
        KThread[] found;
        foreach (thread; Threads) {
            if (thread.State == ThreadState.Waiting && thread.Wait == wait && (wait == ThreadWait.Mutex ? thread.MutexAddress : thread.WaitAddress) == address) {
                found ~= thread;
            }
        }
        return found;
    }

    void ReleaseMutex(ulong address) {
        KThread[] waiters = Waiters(ThreadWait.Mutex, address);
        if (waiters.length == 0) {
            memory.Write!uint(address, 0);
            return;
        }
        KThread next = waiters[0];
        memory.Write!uint(address, next.Tag | (waiters.length > 1 ? MutexWaitersBit : 0));
        Wake(next, ResultSuccess);
    }

    void SignalCondVar(KThread thread) {
        thread.HasDeadline = false;
        const uint value = memory.Read!uint(thread.MutexAddress);
        // A signalled condvar waiter takes the mutex if free, otherwise itll queue on it
        if (value == 0) {
            memory.Write!uint(thread.MutexAddress, thread.Tag);
            Wake(thread, ResultSuccess);
            return;
        }
        memory.Write!uint(thread.MutexAddress, value | MutexWaitersBit);
        thread.Wait = ThreadWait.Mutex;
    }

    private void Poll() {
        const MonoTime now = MonoTime.currTime;
        foreach (event; PeriodicEvents) {
            event.Tick(now);
        }
        foreach (thread; Threads) {
            if (thread.State != ThreadState.Waiting) {
                continue;
            }
            if (thread.Wait == ThreadWait.Objects) {
                foreach (i, waitable; thread.WaitObjects) {
                    if (waitable.IsSignaled()) {
                        Wake(thread, ResultSuccess);
                        thread.Registers[1] = i;
                        break;
                    }
                }
            }
            if (thread.State == ThreadState.Waiting && thread.HasDeadline && now >= thread.Deadline) {
                Wake(thread, thread.Wait == ThreadWait.Sleep ? ResultSuccess : KernelResult.TimedOut);
            }
        }
    }

    // Switching
    private void Save(KThread thread) {
        thread.Registers = jit.Registers;
        thread.Sp = jit.Sp;
        thread.Pc = jit.Pc;
        thread.Pstate = jit.Pstate;
        thread.Fpcr = jit.Fpcr;
        thread.Fpsr = jit.Fpsr;
        thread.Vectors = jit.Vectors;
        thread.TlsAddress = environment.TpidrroEl0;
        thread.TpidrEl0 = environment.TpidrEl0;
    }

    private void Load(KThread thread) {
        jit.Registers(thread.Registers);
        jit.Sp = thread.Sp;
        jit.Pc = thread.Pc;
        jit.Pstate = thread.Pstate;
        jit.Fpcr = thread.Fpcr;
        jit.Fpsr = thread.Fpsr;
        jit.Vectors(thread.Vectors);
        jit.ClearExclusiveState();
        environment.TpidrroEl0 = thread.TlsAddress;
        environment.TpidrEl0 = thread.TpidrEl0;
        handles.Thread = thread;
    }

    private KThread PickNext() {
        size_t start = 0;
        foreach (i, thread; Threads) {
            if (thread is Current) {
                start = i + 1;
            }
        }
        foreach (offset; 0 .. Threads.length) {
            KThread thread = Threads[(start + offset) % Threads.length];
            if (thread.State == ThreadState.Runnable) {
                return thread;
            }
        }
        return null;
    }

    bool Reschedule(bool yield) {
        const MonoTime now = MonoTime.currTime;
        if (Current.State == ThreadState.Runnable && !yield && now - sliceStart < TimeSlice) {
            return true;
        }

        Save(Current);
        while (true) {
            Poll();
            KThread next = PickNext();
            if (next !is null) {
                if (next !is Current) {
                    log.Trace("Switch thread %d -> %d", Current.Id, next.Id);
                }
                Current = next;
                Load(next);
                sliceStart = MonoTime.currTime;
                return true;
            }
            if (!Idle()) {
                return false;
            }
        }
    }

    private bool Idle() {
        bool anyDeadline = false;
        MonoTime nearest;
        bool anyAlive = false;
        foreach (thread; Threads) {
            if (thread.State == ThreadState.Terminated) {
                continue;
            }
            anyAlive = true;
            if (thread.State == ThreadState.Waiting && thread.HasDeadline && (!anyDeadline || thread.Deadline < nearest)) {
                nearest = thread.Deadline;
                anyDeadline = true;
            }
        }
        if (!anyAlive) {
            log.Info("All guest threads have exited.");
            return false;
        }
        foreach (event; PeriodicEvents) {
            if (!anyDeadline || event.NextSignal < nearest) {
                nearest = event.NextSignal;
                anyDeadline = true;
            }
        }
        if (!anyDeadline) {
            log.Error("Deadlock: every guest thread is blocked without a timeout!");
            foreach (thread; Threads) {
                if (thread.State == ThreadState.Waiting) {
                    log.Error("  thread %d waiting on %s (address 0x%X, mutex 0x%X)...", thread.Id, thread.Wait, thread.WaitAddress, thread.MutexAddress);
                }
            }
            return false;
        }
        const Duration remaining = nearest - MonoTime.currTime;
        if (remaining > Duration.zero) {
            Thread.sleep(remaining < MaxIdleSleep ? remaining : MaxIdleSleep);
        }
        return true;
    }
}
