/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * aoc:u: dlc addon content
*/

module Source.Service.Aoc;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Objects;
import Source.Kernel.Result;
import Source.Service.Service;

// Types
enum AocResult : uint {
    NoPurchasedProductInfo = MakeModuleResult(166, 400),
}

// Utils
ulong AddOnContentBaseId(ulong programId) {
    return (programId & ~0xFFFUL) + 0x1000;
}

// Services
final class AddOnContentManagerService : IPCService {
    private ulong programId;
    private KEvent listChangedEvent;

    this(ulong programId) {
        this.programId = programId;
        listChangedEvent = new KEvent("AocListChanged");
        // nothing is installed
        Command(0, "CountAddOnContentByApplicationId", (IpcContext c) => c.Push!uint(0));
        Command(1, "ListAddOnContentByApplicationId", (IpcContext c) => c.Push!uint(0));
        Command(2, "CountAddOnContent", (IpcContext c) => c.Push!uint(0));
        Command(3, "ListAddOnContent", (IpcContext c) => c.Push!uint(0));
        Command(4, "GetAddOnContentBaseIdByApplicationId", (IpcContext c) => c.Push!ulong(AddOnContentBaseId(c.Pop!ulong())));
        Command(5, "GetAddOnContentBaseId", (IpcContext c) => c.Push!ulong(AddOnContentBaseId(this.programId)));
        Command(6, "PrepareAddOnContentByApplicationId", &Succeed);
        Command(7, "PrepareAddOnContent", &Succeed);
        Command(8, "GetAddOnContentListChangedEvent", (IpcContext c) => c.PushCopyHandle(listChangedEvent));
        Command(10, "GetAddOnContentListChangedEventWithProcessId", (IpcContext c) => c.PushCopyHandle(listChangedEvent));
        Command(11, "NotifyMountAddOnContent", &Succeed);
        Command(12, "NotifyUnmountAddOnContent", &Succeed);
        Command(50, "CheckAddOnContentMountStatus", &Succeed);
        Command(100, "CreateEcPurchasedEventManager", (IpcContext c) => c.PushInterface(new PurchaseEventManagerService()));
        Command(101, "CreatePermanentEcPurchasedEventManager", (IpcContext c) => c.PushInterface(new PurchaseEventManagerService()));
    }

    override string Name() const {
        return "aoc:u";
    }
}

final class PurchaseEventManagerService : IPCService {
    private KEvent purchasedEvent;

    this() {
        purchasedEvent = new KEvent("AocPurchased");
        Command(0, "SetDefaultDeliveryTarget", &Succeed);
        Command(1, "SetDeliveryTarget", &Succeed);
        Command(2, "GetPurchasedEventReadableHandle", (IpcContext c) => c.PushCopyHandle(purchasedEvent));
        Command(3, "PopPurchasedProductInfo", (IpcContext c) => c.Result(AocResult.NoPurchasedProductInfo));
        Command(4, "PopPurchasedProductInfoWithUid", (IpcContext c) => c.Result(AocResult.NoPurchasedProductInfo));
    }

    override string Name() const {
        return "aoc::IPurchaseEventManager";
    }
}
