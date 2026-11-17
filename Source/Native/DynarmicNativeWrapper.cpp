/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 * 
 * The CPP side of the Dynarmic JIT Wrapper.
*/

#define MYOUOU_DYNARMIC_WRAPPER_H
#include "DynarmicNativeWrapper.h"

#include <array>
#include <cstdint>
#include <memory>
#include <new>
#include <optional>
#include <string>

#include "dynarmic/interface/A64/a64.h"
#include "dynarmic/interface/A64/config.h"
#include "dynarmic/interface/exclusive_monitor.h"

struct MyououDynarmicMonitor {
    explicit MyououDynarmicMonitor(size_t processorCount) : Monitor(processorCount) {}

    Dynarmic::ExclusiveMonitor Monitor;
};

namespace {

using Dynarmic::A64::Vector;
using Dynarmic::A64::VAddr;

Vector ToVector(const uint64_t* value) {
    return Vector{value[0], value[1]};
}

// Inspirred by TouchHLEs Dynarmic JIT

class NativeCallbacks final : public Dynarmic::A64::UserCallbacks {
public:
    explicit NativeCallbacks(const MyououDynarmicCallbacks& callbacks): Callbacks(callbacks) {}

    std::optional<std::uint32_t> MemoryReadCode(VAddr vaddr) override {
        if (!Callbacks.MemoryReadCode) {
            return MemoryRead32(vaddr);
        }
        std::uint32_t value = 0;
        if (!Callbacks.MemoryReadCode(Callbacks.UserData, vaddr, &value)) {
            return std::nullopt;
        }
        return value;
    }

    std::uint8_t MemoryRead8(VAddr vaddr) override {
        return Callbacks.MemoryRead8(Callbacks.UserData, vaddr);
    }

    std::uint16_t MemoryRead16(VAddr vaddr) override {
        return Callbacks.MemoryRead16(Callbacks.UserData, vaddr);
    }

    std::uint32_t MemoryRead32(VAddr vaddr) override {
        return Callbacks.MemoryRead32(Callbacks.UserData, vaddr);
    }

    std::uint64_t MemoryRead64(VAddr vaddr) override {
        return Callbacks.MemoryRead64(Callbacks.UserData, vaddr);
    }

    Vector MemoryRead128(VAddr vaddr) override {
        Vector value{};
        Callbacks.MemoryRead128(Callbacks.UserData, vaddr, value.data());
        return value;
    }

    void MemoryWrite8(VAddr vaddr, std::uint8_t value) override {
        Callbacks.MemoryWrite8(Callbacks.UserData, vaddr, value);
    }

    void MemoryWrite16(VAddr vaddr, std::uint16_t value) override {
        Callbacks.MemoryWrite16(Callbacks.UserData, vaddr, value);
    }

    void MemoryWrite32(VAddr vaddr, std::uint32_t value) override {
        Callbacks.MemoryWrite32(Callbacks.UserData, vaddr, value);
    }

    void MemoryWrite64(VAddr vaddr, std::uint64_t value) override {
        Callbacks.MemoryWrite64(Callbacks.UserData, vaddr, value);
    }

    void MemoryWrite128(VAddr vaddr, Vector value) override {
        Callbacks.MemoryWrite128(Callbacks.UserData, vaddr, value.data());
    }

    bool MemoryWriteExclusive8(VAddr vaddr, std::uint8_t value, std::uint8_t expected) override {
        return Callbacks.MemoryWriteExclusive8 && Callbacks.MemoryWriteExclusive8(Callbacks.UserData, vaddr, value, expected);
    }

    bool MemoryWriteExclusive16(VAddr vaddr, std::uint16_t value, std::uint16_t expected) override {
        return Callbacks.MemoryWriteExclusive16 && Callbacks.MemoryWriteExclusive16(Callbacks.UserData, vaddr, value, expected);
    }

    bool MemoryWriteExclusive32(VAddr vaddr, std::uint32_t value, std::uint32_t expected) override {
        return Callbacks.MemoryWriteExclusive32 && Callbacks.MemoryWriteExclusive32(Callbacks.UserData, vaddr, value, expected);
    }

    bool MemoryWriteExclusive64(VAddr vaddr, std::uint64_t value, std::uint64_t expected) override {
        return Callbacks.MemoryWriteExclusive64 && Callbacks.MemoryWriteExclusive64(Callbacks.UserData, vaddr, value, expected);
    }

    bool MemoryWriteExclusive128(VAddr vaddr, Vector value, Vector expected) override {
        return Callbacks.MemoryWriteExclusive128 && Callbacks.MemoryWriteExclusive128(Callbacks.UserData, vaddr, value.data(), expected.data());
    }

    bool IsReadOnlyMemory(VAddr vaddr) override {
        return Callbacks.IsReadOnlyMemory && Callbacks.IsReadOnlyMemory(Callbacks.UserData, vaddr);
    }

    void InterpreterFallback(VAddr pc, size_t instructionCount) override {
        Callbacks.InterpreterFallback(Callbacks.UserData, pc, instructionCount);
    }

    void CallSVC(std::uint32_t swi) override {
        Callbacks.CallSvc(Callbacks.UserData, swi);
    }

    void ExceptionRaised(VAddr pc, Dynarmic::A64::Exception exception) override {
        Callbacks.ExceptionRaised(Callbacks.UserData, pc, static_cast<std::uint32_t>(exception));
    }

    void DataCacheOperationRaised(Dynarmic::A64::DataCacheOperation operation, VAddr value) override {
        if (Callbacks.DataCacheOperationRaised) {
            Callbacks.DataCacheOperationRaised(Callbacks.UserData, static_cast<std::uint32_t>(operation), value);
        }
    }

    void InstructionCacheOperationRaised(Dynarmic::A64::InstructionCacheOperation operation, VAddr value) override {
        if (Callbacks.InstructionCacheOperationRaised) {
            Callbacks.InstructionCacheOperationRaised(Callbacks.UserData, static_cast<std::uint32_t>(operation), value);
        }
    }

    void InstructionSynchronizationBarrierRaised() override {
        if (Callbacks.InstructionSynchronizationBarrierRaised) {
            Callbacks.InstructionSynchronizationBarrierRaised(Callbacks.UserData);
        }
    }

    void AddTicks(std::uint64_t ticks) override {
        if (Callbacks.AddTicks) {
            Callbacks.AddTicks(Callbacks.UserData, ticks);
        }
    }

    std::uint64_t GetTicksRemaining() override {
        return Callbacks.GetTicksRemaining ? Callbacks.GetTicksRemaining(Callbacks.UserData) : 0;
    }

    std::uint64_t GetCNTPCT() override {
        return Callbacks.GetCntpct ? Callbacks.GetCntpct(Callbacks.UserData) : 0;
    }

private:
    MyououDynarmicCallbacks Callbacks;
};

bool HasRequiredCallbacks(const MyououDynarmicConfig& config, const MyououDynarmicCallbacks& callbacks) {
    const bool memCallback = 
        callbacks.MemoryRead8 && callbacks.MemoryRead16 
            && callbacks.MemoryRead32 && callbacks.MemoryRead64 && callbacks.MemoryRead128
            && callbacks.MemoryWrite8 && callbacks.MemoryWrite16 && callbacks.MemoryWrite32 
            && callbacks.MemoryWrite64 && callbacks.MemoryWrite128;
    const bool canControl = callbacks.InterpreterFallback && callbacks.CallSvc && callbacks.ExceptionRaised;
    const bool timing = !config.EnableCycleCounting || (callbacks.AddTicks && callbacks.GetTicksRemaining);
    return memCallback && canControl && timing;
}

Dynarmic::A64::UserConfig ToUserConfig(const MyououDynarmicConfig& config, Dynarmic::A64::UserCallbacks* callbacks) {
    Dynarmic::A64::UserConfig result{};
    result.callbacks = callbacks;
    result.processor_id = config.ProcessorId;
    result.global_monitor = config.GlobalMonitor ? &config.GlobalMonitor->Monitor : nullptr;
    result.optimizations = static_cast<Dynarmic::OptimizationFlag>(config.Optimizations);
    result.unsafe_optimizations = config.UnsafeOptimizations;
    result.hook_data_cache_operations = config.HookDataCacheOperations;
    result.hook_isb = config.HookIsb;
    result.hook_hint_instructions = config.HookHintInstructions;
    result.cntfrq_el0 = config.CntfrqEl0;
    result.ctr_el0 = config.CtrEl0;
    result.dczid_el0 = config.DczidEl0;
    result.tpidrro_el0 = config.TpidrroEl0;
    result.tpidr_el0 = config.TpidrEl0;
    result.page_table = config.PageTable;
    result.page_table_address_space_bits = config.PageTableAddressSpaceBits;
    result.page_table_pointer_mask_bits = config.PageTablePointerMaskBits;
    result.silently_mirror_page_table = config.SilentlyMirrorPageTable;
    result.absolute_offset_page_table = config.AbsoluteOffsetPageTable;
    result.detect_misaligned_access_via_page_table = config.DetectMisalignedAccessViaPageTable;
    result.only_detect_misalignment_via_page_table_on_page_boundary = config.OnlyDetectMisalignmentViaPageTableOnPageBoundary;
    result.fastmem_pointer = config.HasFastmemPointer ? std::optional<uintptr_t>{config.FastmemPointer} : std::nullopt;
    result.recompile_on_fastmem_failure = config.RecompileOnFastmemFailure;
    result.fastmem_address_space_bits = config.FastmemAddressSpaceBits;
    result.silently_mirror_fastmem = config.SilentlyMirrorFastmem;
    result.fastmem_exclusive_access = config.FastmemExclusiveAccess;
    result.recompile_on_exclusive_fastmem_failure = config.RecompileOnExclusiveFastmemFailure;
    result.define_unpredictable_behaviour = config.DefineUnpredictableBehaviour;
    result.wall_clock_cntpct = config.WallClockCntpct;
    result.check_halt_on_memory_access = config.CheckHaltOnMemoryAccess;
    result.enable_cycle_counting = config.EnableCycleCounting;
    result.code_cache_size = config.CodeCacheSize;
    return result;
}

}

struct MyououDynarmicJit {
    MyououDynarmicJit(const MyououDynarmicConfig& config, const MyououDynarmicCallbacks& callbacks): Callbacks(callbacks), Jit(ToUserConfig(config, &Callbacks)) {}

    NativeCallbacks Callbacks;
    Dynarmic::A64::Jit Jit;
};

extern "C" {

// Base

void MyououDynarmicDefaultConfig(MyououDynarmicConfig* outConfig) {
    const Dynarmic::A64::UserConfig defaults{};
    MyououDynarmicConfig result{};
    result.ProcessorId = defaults.processor_id;
    result.GlobalMonitor = nullptr;
    result.Optimizations = static_cast<std::uint32_t>(defaults.optimizations);
    result.UnsafeOptimizations = defaults.unsafe_optimizations;
    result.HookDataCacheOperations = defaults.hook_data_cache_operations;
    result.HookIsb = defaults.hook_isb;
    result.HookHintInstructions = defaults.hook_hint_instructions;
    result.CntfrqEl0 = defaults.cntfrq_el0;
    result.CtrEl0 = defaults.ctr_el0;
    result.DczidEl0 = defaults.dczid_el0;
    result.TpidrroEl0 = defaults.tpidrro_el0;
    result.TpidrEl0 = defaults.tpidr_el0;
    result.PageTable = defaults.page_table;
    result.PageTableAddressSpaceBits = defaults.page_table_address_space_bits;
    result.PageTablePointerMaskBits = defaults.page_table_pointer_mask_bits;
    result.SilentlyMirrorPageTable = defaults.silently_mirror_page_table;
    result.AbsoluteOffsetPageTable = defaults.absolute_offset_page_table;
    result.DetectMisalignedAccessViaPageTable = defaults.detect_misaligned_access_via_page_table;
    result.OnlyDetectMisalignmentViaPageTableOnPageBoundary = defaults.only_detect_misalignment_via_page_table_on_page_boundary;
    result.HasFastmemPointer = defaults.fastmem_pointer.has_value();
    result.FastmemPointer = defaults.fastmem_pointer.value_or(0);
    result.RecompileOnFastmemFailure = defaults.recompile_on_fastmem_failure;
    result.FastmemAddressSpaceBits = defaults.fastmem_address_space_bits;
    result.SilentlyMirrorFastmem = defaults.silently_mirror_fastmem;
    result.FastmemExclusiveAccess = defaults.fastmem_exclusive_access;
    result.RecompileOnExclusiveFastmemFailure = defaults.recompile_on_exclusive_fastmem_failure;
    result.DefineUnpredictableBehaviour = defaults.define_unpredictable_behaviour;
    result.WallClockCntpct = defaults.wall_clock_cntpct;
    result.CheckHaltOnMemoryAccess = defaults.check_halt_on_memory_access;
    result.EnableCycleCounting = defaults.enable_cycle_counting;
    result.CodeCacheSize = defaults.code_cache_size;
    *outConfig = result;
}

// todo: move to d?
MyououDynarmicJit* MyououDynarmicCreate(const MyououDynarmicConfig* config, const MyououDynarmicCallbacks* callbacks) {
    if (!config || !callbacks || !HasRequiredCallbacks(*config, *callbacks)) {
        return nullptr;
    }
    try {
        return new MyououDynarmicJit(*config, *callbacks);
    } catch (...) {
        return nullptr;
    }
}

void MyououDynarmicDestroy(MyououDynarmicJit* jit) {
    delete jit;
}

// State

uint32_t MyououDynarmicRun(MyououDynarmicJit* jit) {
    return static_cast<std::uint32_t>(jit->Jit.Run());
}

uint32_t MyououDynarmicStep(MyououDynarmicJit* jit) {
    return static_cast<std::uint32_t>(jit->Jit.Step());
}

void MyououDynarmicClearCache(MyououDynarmicJit* jit) {
    jit->Jit.ClearCache();
}

void MyououDynarmicInvalidateCacheRange(MyououDynarmicJit* jit, uint64_t startAddress, size_t length) {
    jit->Jit.InvalidateCacheRange(startAddress, length);
}

void MyououDynarmicReset(MyououDynarmicJit* jit) {
    jit->Jit.Reset();
}

void MyououDynarmicHaltExecution(MyououDynarmicJit* jit, uint32_t haltReason) {
    jit->Jit.HaltExecution(static_cast<Dynarmic::HaltReason>(haltReason));
}

void MyououDynarmicClearHalt(MyououDynarmicJit* jit, uint32_t haltReason) {
    jit->Jit.ClearHalt(static_cast<Dynarmic::HaltReason>(haltReason));
}

uint64_t MyououDynarmicGetSP(const MyououDynarmicJit* jit) {
    return jit->Jit.GetSP();
}

void MyououDynarmicSetSP(MyououDynarmicJit* jit, uint64_t value) {
    jit->Jit.SetSP(value);
}

uint64_t MyououDynarmicGetPC(const MyououDynarmicJit* jit) {
    return jit->Jit.GetPC();
}

void MyououDynarmicSetPC(MyououDynarmicJit* jit, uint64_t value) {
    jit->Jit.SetPC(value);
}

uint64_t MyououDynarmicGetRegister(const MyououDynarmicJit* jit, size_t index) {
    return jit->Jit.GetRegister(index);
}

void MyououDynarmicSetRegister(MyououDynarmicJit* jit, size_t index, uint64_t value) {
    jit->Jit.SetRegister(index, value);
}

void MyououDynarmicGetRegisters(const MyououDynarmicJit* jit, uint64_t* outValues) {
    const auto registers = jit->Jit.GetRegisters();
    std::memcpy(outValues, registers.data(), sizeof(registers));
}

void MyououDynarmicSetRegisters(MyououDynarmicJit* jit, const uint64_t* values) {
    std::array<std::uint64_t, 31> registers{};
    std::memcpy(registers.data(), values, sizeof(registers));
    jit->Jit.SetRegisters(registers);
}

void MyououDynarmicGetVector(const MyououDynarmicJit* jit, size_t index, uint64_t* outValue) {
    const Vector vector = jit->Jit.GetVector(index);
    outValue[0] = vector[0];
    outValue[1] = vector[1];
}

void MyououDynarmicSetVector(MyououDynarmicJit* jit, size_t index, const uint64_t* value) {
    jit->Jit.SetVector(index, ToVector(value));
}

void MyououDynarmicGetVectors(const MyououDynarmicJit* jit, uint64_t* outValues) {
    const auto vectors = jit->Jit.GetVectors();
    std::memcpy(outValues, vectors.data(), sizeof(vectors));
}

void MyououDynarmicSetVectors(MyououDynarmicJit* jit, const uint64_t* values) {
    std::array<Vector, 32> vectors{};
    std::memcpy(vectors.data(), values, sizeof(vectors));
    jit->Jit.SetVectors(vectors);
}

uint32_t MyououDynarmicGetFpcr(const MyououDynarmicJit* jit) {
    return jit->Jit.GetFpcr();
}

void MyououDynarmicSetFpcr(MyououDynarmicJit* jit, uint32_t value) {
    jit->Jit.SetFpcr(value);
}

uint32_t MyououDynarmicGetFpsr(const MyououDynarmicJit* jit) {
    return jit->Jit.GetFpsr();
}

void MyououDynarmicSetFpsr(MyououDynarmicJit* jit, uint32_t value) {
    jit->Jit.SetFpsr(value);
}

uint32_t MyououDynarmicGetPstate(const MyououDynarmicJit* jit) {
    return jit->Jit.GetPstate();
}

void MyououDynarmicSetPstate(MyououDynarmicJit* jit, uint32_t value) {
    jit->Jit.SetPstate(value);
}

void MyououDynarmicClearExclusiveState(MyououDynarmicJit* jit) {
    jit->Jit.ClearExclusiveState();
}

bool MyououDynarmicIsExecuting(const MyououDynarmicJit* jit) {
    return jit->Jit.IsExecuting();
}

void MyououDynarmicDumpDisassembly(const MyououDynarmicJit* jit) {
    jit->Jit.DumpDisassembly();
}

void MyououDynarmicDisassemble(const MyououDynarmicJit* jit, MyououDynarmicLineSink sink, void* userData) {
    if (!sink) {
        return;
    }
    for (const std::string& line : jit->Jit.Disassemble()) {
        sink(userData, line.c_str(), line.size());
    }
}

MyououDynarmicMonitor* MyououDynarmicMonitorCreate(size_t processorCount) {
    try {
        return new MyououDynarmicMonitor(processorCount);
    } catch (...) {
        return nullptr;
    }
}

void MyououDynarmicMonitorDestroy(MyououDynarmicMonitor* monitor) {
    delete monitor;
}

size_t MyououDynarmicMonitorGetProcessorCount(const MyououDynarmicMonitor* monitor) {
    return monitor->Monitor.GetProcessorCount();
}

void MyououDynarmicMonitorClear(MyououDynarmicMonitor* monitor) {
    monitor->Monitor.Clear();
}

void MyououDynarmicMonitorClearProcessor(MyououDynarmicMonitor* monitor, size_t processorId) {
    monitor->Monitor.ClearProcessor(processorId);
}

}
