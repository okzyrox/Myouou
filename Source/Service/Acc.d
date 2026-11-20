/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification,
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * acc: user accounts services
*/

module Source.Service.Acc;

// Std
import std.datetime : Clock;
import std.format : format;

// Core
import Source.Kernel.Ipc;
import Source.Kernel.Result;
import Source.Service.Service;
import Source.Util.Logger;

// Types
enum AccResult : uint {
    UserNotFound = MakeModuleResult(124, 100),
    InvalidBuffer = MakeModuleResult(124, 30),
}

enum size_t MaxUsers = 8;
enum size_t MaxNicknameLength = 0x20;
enum ulong UidHigh = 0x4D796F756F755500;
enum string DefaultAccountName = "Myouou";

struct AccountUid {
    ulong[2] Value;

    bool IsValid() const {
        return Value[0] != 0 || Value[1] != 0;
    }

    string Hex() const {
        return format("%016X%016X", Value[1], Value[0]);
    }
}

struct AccountBaseProfile {
    AccountUid Uid;
    ulong LastEditTimestamp;
    char[MaxNicknameLength] Nickname = '\0';
}

enum size_t UserDataSize = 0x80;

struct UserAccount {
    AccountUid Uid;
    string Nickname;
}

// State
final class AccountState {
    UserAccount[] Users;
    AccountUid LastOpened;

    private ulong createdTimestamp;
    private Logger log;

    this() {
        log = GetLogger("Account");
        createdTimestamp = Clock.currTime.toUnixTime;
        Users = [UserAccount(SlotUid(0), DefaultAccountName)];
        LastOpened = Users[0].Uid;
        log.Info("Account %s '%s'", Users[0].Uid.Hex, Users[0].Nickname);
    }

    static AccountUid SlotUid(size_t slot) {
        return AccountUid([slot + 1, UidHigh]);
    }

    const(UserAccount)* Find(AccountUid uid) const {
        foreach (ref user; Users) {
            if (user.Uid == uid) {
                return &user;
            }
        }
        return null;
    }

    AccountBaseProfile BaseProfile(const ref UserAccount user) const {
        AccountBaseProfile profile;
        profile.Uid = user.Uid;
        profile.LastEditTimestamp = createdTimestamp;
        profile.Nickname[0 .. user.Nickname.length] = user.Nickname[];
        return profile;
    }

    // todo
    ubyte[] Avatar(const ref UserAccount user) {
        return null;
    }
}

// Services
final class AccountService : IPCService {
    // acc:u0/1
    private string name;
    private AccountState state;

    this(string name, AccountState state) {
        this.name = name;
        this.state = state;
        Command(0, "GetUserCount", &GetUserCount);
        Command(1, "GetUserExistence", &GetUserExistence);
        Command(2, "ListAllUsers", &ListUsers);
        Command(3, "ListOpenUsers", &ListUsers);
        Command(4, "GetLastOpenedUser", &GetLastOpenedUser);
        Command(5, "GetProfile", &GetProfile);
        Command(50, "IsUserRegistrationRequestPermitted", &False);
        Command(51, "TrySelectUserWithoutInteraction", &TrySelectUserWithoutInteraction);
        Command(60, "ListOpenContextStoredUsers", &ListUsers);
        Command(100, "InitializeApplicationInfoV0", &Succeed);
        Command(101, "GetBaasAccountManagerForApplication", &GetBaasAccountManagerForApplication);
        Command(140, "InitializeApplicationInfo", &Succeed);
        Command(141, "ListQualifiedUsers", &ListUsers);
        Command(150, "IsUserAccountSwitchLocked", &False);
    }

    override string Name() const {
        return name;
    }

    private void GetUserCount(IpcContext context) {
        context.Push!int(cast(int) state.Users.length);
    }

    private void GetUserExistence(IpcContext context) {
        if (state.Find(context.Pop!AccountUid()) !is null) {
            True(context);
        } else {
            False(context);
        }
    }

    private void ListUsers(IpcContext context) {
        AccountUid[MaxUsers] list;
        foreach (i, user; state.Users) {
            list[i] = user.Uid;
        }
        context.WriteOutput(0, cast(const(ubyte)[]) list[]);
    }

    private void GetLastOpenedUser(IpcContext context) {
        context.Push(state.LastOpened);
    }

    private void GetProfile(IpcContext context) {
        const AccountUid uid = context.Pop!AccountUid();
        const(UserAccount)* user = state.Find(uid);
        if (user is null) {
            context.Result(AccResult.UserNotFound);
            return;
        }
        context.PushInterface(new ProfileService(state, *user));
    }

    private void TrySelectUserWithoutInteraction(IpcContext context) {
        context.Push(state.Users.length == 1 ? state.Users[0].Uid : AccountUid.init);
    }

    private void GetBaasAccountManagerForApplication(IpcContext context) {
        const AccountUid uid = context.Pop!AccountUid();
        if (state.Find(uid) is null) {
            context.Result(AccResult.UserNotFound);
            return;
        }
        context.PushInterface(new ManagerForApplicationService(uid));
    }
}

final class ProfileService : IPCService {
    private AccountState state;
    private UserAccount user;

    this(AccountState state, UserAccount user) {
        this.state = state;
        this.user = user;
        Command(0, "Get", &Get);
        Command(1, "GetBase", &GetBase);
        Command(10, "GetImageSize", &GetImageSize);
        Command(11, "LoadImage", &LoadImage);
    }

    override string Name() const {
        return "acc::IProfile";
    }

    private void Get(IpcContext context) {
        context.WriteOutput(0, new ubyte[UserDataSize]);
        context.Push(state.BaseProfile(user));
    }

    private void GetBase(IpcContext context) {
        context.Push(state.BaseProfile(user));
    }

    private void GetImageSize(IpcContext context) {
        context.Push!uint(cast(uint) state.Avatar(user).length);
    }

    private void LoadImage(IpcContext context) {
        const ubyte[] image = state.Avatar(user);
        if (context.OutputSize(0) < image.length) {
            context.Result(AccResult.InvalidBuffer);
            return;
        }
        context.WriteOutput(0, image);
        context.Push!uint(cast(uint) image.length);
    }
}

final class ManagerForApplicationService : IPCService {
    private AccountUid uid;

    this(AccountUid uid) {
        this.uid = uid;
        Command(0, "CheckAvailability", &CheckAvailability);
        Command(1, "GetAccountId", &GetAccountId);
    }

    override string Name() const {
        return "acc::IManagerForApplication";
    }

    private void CheckAvailability(IpcContext context) {
    }

    private void GetAccountId(IpcContext context) {
        context.Push!ulong(uid.Value[0] ^ uid.Value[1]);
    }
}
