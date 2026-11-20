/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * psm: power and battery
*/

module Source.Service.Psm;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Service.Service;

// Types
enum ChargerType : uint {
    Unconnected = 0,
    EnoughPower = 1,
    LowPower = 2,
    NotSupported = 3,
}

enum BatteryVoltageState : uint {
    ShutdownRequired = 0,
    SleepRequired = 1,
    PsmBatteryChargeInfo = 2,
    Good = 3,
}

enum uint BatteryChargePercentage = 100;
enum double BatteryHealthPercentage = 100.0;

// Services
final class PsmService : IPCService {
    private bool chargingEnabled = true;
    private KEvent chargeInfoEvent;
    private KEvent calibratedEvent;

    this() {
        chargeInfoEvent = new KEvent("PsmBatteryChargeInfo");
        calibratedEvent = new KEvent("PsmBatteryChargeCalibrated");
        Command(0, "GetBatteryChargePercentage", (IpcContext c) => c.Push!uint(BatteryChargePercentage));
        Command(1, "GetChargerType", (IpcContext c) => c.Push!uint(ChargerType.EnoughPower));
        Command(2, "EnableBatteryCharging", (IpcContext c) { chargingEnabled = true; });
        Command(3, "DisableBatteryCharging", (IpcContext c) { chargingEnabled = false; });
        Command(4, "IsBatteryChargingEnabled", (IpcContext c) => c.Push!ubyte(chargingEnabled ? 1 : 0));
        Command(5, "AcquireControllerPowerSupply", &Succeed);
        Command(6, "ReleaseControllerPowerSupply", &Succeed);
        Command(7, "OpenSession", (IpcContext c) => c.PushInterface(new PsmSession()));
        Command(8, "EnableEnoughPowerChargeEmulation", &Succeed);
        Command(9, "DisableEnoughPowerChargeEmulation", &Succeed);
        Command(10, "EnableFastBatteryCharging", &Succeed);
        Command(11, "DisableFastBatteryCharging", &Succeed);
        Command(12, "GetBatteryVoltageState", (IpcContext c) => c.Push!uint(BatteryVoltageState.Good));
        Command(13, "GetRawBatteryChargePercentage", (IpcContext c) => c.Push!double(BatteryChargePercentage));
        Command(14, "IsEnoughPowerSupplied", &True);
        Command(15, "GetBatteryAgePercentage", (IpcContext c) => c.Push!double(BatteryHealthPercentage));
        Command(16, "GetBatteryChargeInfoEvent", (IpcContext c) => c.PushCopyHandle(chargeInfoEvent));
        Stub(17, "GetBatteryChargeInfoFields");
        Command(18, "GetBatteryChargeCalibratedEvent", (IpcContext c) => c.PushCopyHandle(calibratedEvent));
    }

    override string Name() const {
        return "psm";
    }
}

final class PsmSession : IPCService {
    private KEvent stateChangeEvent;

    this() {
        stateChangeEvent = new KEvent("PsmStateChange");
        Command(0, "BindStateChangeEvent", (IpcContext c) => c.PushCopyHandle(stateChangeEvent));
        Command(1, "UnbindStateChangeEvent", &Succeed);
        Command(2, "SetChargerTypeChangeEventEnabled", &Succeed);
        Command(3, "SetPowerSupplyChangeEventEnabled", &Succeed);
        Command(4, "SetBatteryVoltageStateChangeEventEnabled", &Succeed);
    }

    override string Name() const {
        return "psm::IPsmSession";
    }
}
