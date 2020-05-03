---
title: Android 重学系列 系统启动动画
top: false
cover: false
date: 2020-01-25 23:32:19
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---
# 前言
经过上一篇文章的探索和学习，相信大家对Hal 层的运作原理以及SF如何监听Hal层返回的回调有一定的了解。

原本应该是聊如何申请图元的，但是感觉和前文的逻辑割裂有点大，还是继续按照SF初始化，开机的逻辑顺序继续走下去。这一次就让我们聊聊系统启动动画吧。

带着这个疑问去阅读，开机的时候没有Activity为什么可以播放开机动画呢？注意Android系统中存在几个开机动画，这里不去聊Linux开机动画，我们只聊Android渲染系统中的开机动画，也就是我们打开手机时候的那个动画。

如果遇到问题，可以到本文来讨论[https://www.jianshu.com/p/a79de4a6d83c](https://www.jianshu.com/p/a79de4a6d83c)


# 正文

## 解析init.rc service的原理
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/)/[bootanimation](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/bootanimation/)/[bootanim.rc](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/bootanimation/bootanim.rc)
```
service bootanim /system/bin/bootanimation
    class core animation
    user graphics
    group graphics audio
    disabled
    oneshot
    writepid /dev/stune/top-app/tasks
```
开机就启动进程，那肯定就要从rc里面找。负责开机动画的进程是bootanimation。上面是他的rc文件。值得注意的是，设置了disable标志位。

我们翻翻看在init进程,是怎么解析service的。在Android9.0中实际上会把service，action，import等都会进行字符串解析额，最后分散在三个链表等待执行。

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[init](http://androidxref.com/9.0.0_r3/xref/system/core/init/)/[service.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/init/service.cpp)
```cpp
const Service::OptionParserMap::Map& Service::OptionParserMap::map() const {
    constexpr std::size_t kMax = std::numeric_limits<std::size_t>::max();
    // clang-format off
    static const Map option_parsers = {
        {"capabilities",
                        {1,     kMax, &Service::ParseCapabilities}},
        {"class",       {1,     kMax, &Service::ParseClass}},
        {"console",     {0,     1,    &Service::ParseConsole}},
        {"critical",    {0,     0,    &Service::ParseCritical}},
        {"disabled",    {0,     0,    &Service::ParseDisabled}},
        {"enter_namespace",
                        {2,     2,    &Service::ParseEnterNamespace}},
        {"group",       {1,     NR_SVC_SUPP_GIDS + 1, &Service::ParseGroup}},
        {"interface",   {2,     2,    &Service::ParseInterface}},
        {"ioprio",      {2,     2,    &Service::ParseIoprio}},
        {"priority",    {1,     1,    &Service::ParsePriority}},
        {"keycodes",    {1,     kMax, &Service::ParseKeycodes}},
        {"oneshot",     {0,     0,    &Service::ParseOneshot}},
        {"onrestart",   {1,     kMax, &Service::ParseOnrestart}},
        {"override",    {0,     0,    &Service::ParseOverride}},
        {"oom_score_adjust",
                        {1,     1,    &Service::ParseOomScoreAdjust}},
        {"memcg.swappiness",
                        {1,     1,    &Service::ParseMemcgSwappiness}},
        {"memcg.soft_limit_in_bytes",
                        {1,     1,    &Service::ParseMemcgSoftLimitInBytes}},
        {"memcg.limit_in_bytes",
                        {1,     1,    &Service::ParseMemcgLimitInBytes}},
        {"namespace",   {1,     2,    &Service::ParseNamespace}},
        {"rlimit",      {3,     3,    &Service::ParseProcessRlimit}},
        {"seclabel",    {1,     1,    &Service::ParseSeclabel}},
        {"setenv",      {2,     2,    &Service::ParseSetenv}},
        {"shutdown",    {1,     1,    &Service::ParseShutdown}},
        {"socket",      {3,     6,    &Service::ParseSocket}},
        {"file",        {2,     2,    &Service::ParseFile}},
        {"user",        {1,     1,    &Service::ParseUser}},
        {"writepid",    {1,     kMax, &Service::ParseWritepid}},
    };
    // clang-format on
    return option_parsers;
}
```
在这个map中写好了每一个命令对应的解析方法指针。我们直接看看disable做了什么：
```cpp
Result<Success> Service::ParseDisabled(const std::vector<std::string>& args) {
    flags_ |= SVC_DISABLED;
    flags_ |= SVC_RC_DISABLED;
    return Success();
}
```
很简单就是设置了DISABLED的flag。

当解析完毕将会尝试着执行解析好的service的命令。
```cpp
Result<Success> Service::Start() {
    bool disabled = (flags_ & (SVC_DISABLED | SVC_RESET));
    flags_ &= (~(SVC_DISABLED|SVC_RESTARTING|SVC_RESET|SVC_RESTART|SVC_DISABLED_START));

    if (flags_ & SVC_RUNNING) {
        if ((flags_ & SVC_ONESHOT) && disabled) {
            flags_ |= SVC_RESTART;
        }
        // It is not an error to try to start a service that is already running.
        return Success();
    }

    bool needs_console = (flags_ & SVC_CONSOLE);
    if (needs_console) {
        if (console_.empty()) {
            console_ = default_console;
        }


        int console_fd = open(console_.c_str(), O_RDWR | O_CLOEXEC);
        if (console_fd < 0) {
            flags_ |= SVC_DISABLED;
            return ErrnoError() << "Couldn't open console '" << console_ << "'";
        }
        close(console_fd);
    }

  ...

    pid_t pid = -1;
    if (namespace_flags_) {
        pid = clone(nullptr, nullptr, namespace_flags_ | SIGCHLD, nullptr);
    } else {
        pid = fork();
    }

    if (pid == 0) {
...
    }

    if (pid < 0) {
        pid_ = 0;
        return ErrnoError() << "Failed to fork";
    }

    ...
    return Success();
}
```
能看到如果没有disable，reset这些标志位阻碍，将会通过fork系统生成一个新的进程。但是这里disable了，因此不会走下来，而是会把解析结果保存起来。保存在ServiceList对象中的services_  vector集合。

到这里似乎逻辑断开了，我们先把思路阻塞到这里。稍后就能看到。


## SF启动开机动画
在SF的init方法中，我为了独立出一节出来，故意有一段没有解析。如下：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)

```cpp
    if (getHwComposer().hasCapability(
            HWC2::Capability::PresentFenceIsNotReliable)) {
        mStartPropertySetThread = new StartPropertySetThread(false);
    } else {
        mStartPropertySetThread = new StartPropertySetThread(true);
    }

    if (mStartPropertySetThread->Start() != NO_ERROR) {
        ALOGE("Run StartPropertySetThread failed!");
    }
```
这个方法是干什么的呢？我第一次看的时候差点看漏了，差点找不到哪里启动开机动画，其实是把事情交给了StartPropertySetThread完成。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[StartPropertySetThread.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/StartPropertySetThread.cpp)

```cpp
StartPropertySetThread::StartPropertySetThread(bool timestampPropertyValue):
        Thread(false), mTimestampPropertyValue(timestampPropertyValue) {}

status_t StartPropertySetThread::Start() {
    return run("SurfaceFlinger::StartPropertySetThread", PRIORITY_NORMAL);
}

bool StartPropertySetThread::threadLoop() {
    // Set property service.sf.present_timestamp, consumer need check its readiness
    property_set(kTimestampProperty, mTimestampPropertyValue ? "1" : "0");
    // Clear BootAnimation exit flag
    property_set("service.bootanim.exit", "0");
    // Start BootAnimation if not started
    property_set("ctl.start", "bootanim");
    // Exit immediately
    return false;
}
```
能看到在这里设置了两个系统属性，一个是service.bootanim.exit设置为0，另一个则是开机的关键，设置了ctl.start中的参数为bootanim。这样就能启动开机动画的进程。

为什么如此呢？我们还是要回到init进程的main函数中。
文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[init](http://androidxref.com/9.0.0_r3/xref/system/core/init/)/[init.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/init/init.cpp)
```cpp
int main(int argc, char** argv) {
  ....
   ...
    start_property_service();
...

    const BuiltinFunctionMap function_map;
    Action::set_function_map(&function_map);

    subcontexts = InitializeSubcontexts();

    ActionManager& am = ActionManager::GetInstance();
    ServiceList& sm = ServiceList::GetInstance();

    LoadBootScripts(am, sm);

    // Turning this on and letting the INFO logging be discarded adds 0.2s to
    // Nexus 9 boot time, so it's disabled by default.
    if (false) DumpState();

    am.QueueEventTrigger("early-init");

    // Queue an action that waits for coldboot done so we know ueventd has set up all of /dev...
    am.QueueBuiltinAction(wait_for_coldboot_done_action, "wait_for_coldboot_done");
    // ... so that we can start queuing up actions that require stuff from /dev.
    am.QueueBuiltinAction(MixHwrngIntoLinuxRngAction, "MixHwrngIntoLinuxRng");
    am.QueueBuiltinAction(SetMmapRndBitsAction, "SetMmapRndBits");
    am.QueueBuiltinAction(SetKptrRestrictAction, "SetKptrRestrict");
    am.QueueBuiltinAction(keychord_init_action, "keychord_init");
    am.QueueBuiltinAction(console_init_action, "console_init");

    // Trigger all the boot actions to get us started.
    am.QueueEventTrigger("init");

    // Repeat mix_hwrng_into_linux_rng in case /dev/hw_random or /dev/random
    // wasn't ready immediately after wait_for_coldboot_done
    am.QueueBuiltinAction(MixHwrngIntoLinuxRngAction, "MixHwrngIntoLinuxRng");

    // Don't mount filesystems or start core system services in charger mode.
    std::string bootmode = GetProperty("ro.bootmode", "");
    if (bootmode == "charger") {
        am.QueueEventTrigger("charger");
    } else {
        am.QueueEventTrigger("late-init");
    }

    // Run all property triggers based on current state of the properties.
    am.QueueBuiltinAction(queue_property_triggers_action, "queue_property_triggers");

...
    return 0;
}
```
我们忽律掉最下面init.cpp监听epoll消息的逻辑，其实在这个过程中还通过start_property_service启动了一个检测Android全局配置属性变化服务。

文件：[http://androidxref.com/9.0.0_r3/xref/system/core/init/property_service.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/init/property_service.cpp)
```cpp
void start_property_service() {
    selinux_callback cb;
    cb.func_audit = SelinuxAuditCallback;
    selinux_set_callback(SELINUX_CB_AUDIT, cb);

    property_set("ro.property_service.version", "2");

    property_set_fd = CreateSocket(PROP_SERVICE_NAME, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
                                   false, 0666, 0, 0, nullptr);
    if (property_set_fd == -1) {
        ...
    }

    listen(property_set_fd, 8);

    register_epoll_handler(property_set_fd, handle_property_set_fd);
}
```
能看到在这个过程中，设置了版本号为2，启动了一个名字为property_service的socket服务。然后对这个服务进行监听，把property_set_fd注册到poll中，注册一个handle_property_set_fd回调事件。

我们先来看看property_set中做了什么事情：
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/)/[system_property_set.cpp](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/system_property_set.cpp)

```cpp
int __system_property_set(const char* key, const char* value) {
  if (key == nullptr) return -1;
  if (value == nullptr) value = "";

  if (g_propservice_protocol_version == 0) {
    detect_protocol_version();
  }

  if (g_propservice_protocol_version == kProtocolVersion1) {
    ....
  } else {

    if (strlen(value) >= PROP_VALUE_MAX && strncmp(key, "ro.", 3) != 0) return -1;
    // Use proper protocol
    PropertyServiceConnection connection;
    if (!connection.IsValid()) {
      errno = connection.GetLastError();
    ...
      return -1;
    }

    SocketWriter writer(&connection);
    if (!writer.WriteUint32(PROP_MSG_SETPROP2).WriteString(key).WriteString(value).Send()) {
      errno = connection.GetLastError();
      ...
      return -1;
    }

    int result = -1;
    if (!connection.RecvInt32(&result)) {
      errno = connection.GetLastError();
 ...
      return -1;
    }

  ...

    return 0;
  }
}
```
因为版本号为2.其实它就会走下面的分之，此时能看到这不是简单的写入文件，而是写到了一个socket 中。

而这个socket是什么？
```cpp
static const char property_service_socket[] = "/dev/socket/" PROP_SERVICE_NAME;

PropertyServiceConnection() : last_error_(0) {
    socket_ = ::socket(AF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (socket_ == -1) {
      last_error_ = errno;
      return;
    }

    const size_t namelen = strlen(property_service_socket);
    sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    strlcpy(addr.sun_path, property_service_socket, sizeof(addr.sun_path));
    addr.sun_family = AF_LOCAL;
    socklen_t alen = namelen + offsetof(sockaddr_un, sun_path) + 1;

    if (TEMP_FAILURE_RETRY(connect(socket_, reinterpret_cast<sockaddr*>(&addr), alen)) == -1) {
      last_error_ = errno;
      close(socket_);
      socket_ = -1;
    }
  }
```
我们能看到他的地址其实是dev/socket下的property_service。也就是刚好是上面注册的socket。


关键来看这个方法：
```cpp
static void handle_property_set_fd() {
    static constexpr uint32_t kDefaultSocketTimeout = 2000; /* ms */

    int s = accept4(property_set_fd, nullptr, nullptr, SOCK_CLOEXEC);
    if (s == -1) {
        return;
    }

    ucred cr;
    socklen_t cr_size = sizeof(cr);
    if (getsockopt(s, SOL_SOCKET, SO_PEERCRED, &cr, &cr_size) < 0) {
        close(s);
        return;
    }

    SocketConnection socket(s, cr);
    uint32_t timeout_ms = kDefaultSocketTimeout;

    uint32_t cmd = 0;
    if (!socket.RecvUint32(&cmd, &timeout_ms)) {
        
        socket.SendUint32(PROP_ERROR_READ_CMD);
        return;
    }

    switch (cmd) {
    case PROP_MSG_SETPROP: {
      ...
      }

    case PROP_MSG_SETPROP2: {
        std::string name;
        std::string value;
        if (!socket.RecvString(&name, &timeout_ms) ||
            !socket.RecvString(&value, &timeout_ms)) {
          
          socket.SendUint32(PROP_ERROR_READ_DATA);
          return;
        }

        const auto& cr = socket.cred();
        std::string error;
        uint32_t result = HandlePropertySet(name, value, socket.source_context(), cr, &error);
        if (result != PROP_SUCCESS) {
            ...
        }
        socket.SendUint32(result);
        break;
      }

    default:
        socket.SendUint32(PROP_ERROR_INVALID_CMD);
        break;
    }
}
```
从上面得知，首先会写入PROP_MSG_SETPROP2一个命令，此时就会走到下面这个分之，接着通过RecvString读取数据内容，执行HandlePropertySet。
```cpp
uint32_t HandlePropertySet(const std::string& name, const std::string& value,
                           const std::string& source_context, const ucred& cr, std::string* error) {
...
    if (StartsWith(name, "ctl.")) {
        if (!CheckControlPropertyPerms(name, value, source_context, cr)) {
            *error = StringPrintf("Invalid permissions to perform '%s' on '%s'", name.c_str() + 4,
                                  value.c_str());
            return PROP_ERROR_HANDLE_CONTROL_MESSAGE;
        }

        HandleControlMessage(name.c_str() + 4, value, cr.pid);
        return PROP_SUCCESS;
    }

...

    return PropertySet(name, value, error);
}

```
在SF中输送了两个属性过来，其中使用HandleControlMessage对ctl.进行了特殊处理。

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[init](http://androidxref.com/9.0.0_r3/xref/system/core/init/)/[init.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/init/init.cpp)
```
static const std::map<std::string, ControlMessageFunction>& get_control_message_map() {
    // clang-format off
    static const std::map<std::string, ControlMessageFunction> control_message_functions = {
        {"start",             {ControlTarget::SERVICE,   DoControlStart}},
        {"stop",              {ControlTarget::SERVICE,   DoControlStop}},
        {"restart",           {ControlTarget::SERVICE,   DoControlRestart}},
        {"interface_start",   {ControlTarget::INTERFACE, DoControlStart}},
        {"interface_stop",    {ControlTarget::INTERFACE, DoControlStop}},
        {"interface_restart", {ControlTarget::INTERFACE, DoControlRestart}},
    };
    // clang-format on

    return control_message_functions;
}

static Result<Success> DoControlStart(Service* service) {
    return service->Start();
}


void HandleControlMessage(const std::string& msg, const std::string& name, pid_t pid) {
    const auto& map = get_control_message_map();
    const auto it = map.find(msg);

    if (it == map.end()) {
    ...
        return;
    }

    std::string cmdline_path = StringPrintf("proc/%d/cmdline", pid);
    std::string process_cmdline;
    if (ReadFileToString(cmdline_path, &process_cmdline)) {
        std::replace(process_cmdline.begin(), process_cmdline.end(), '\0', ' ');
        process_cmdline = Trim(process_cmdline);
    } else {
        process_cmdline = "unknown process";
    }

...
    const ControlMessageFunction& function = it->second;

    if (function.target == ControlTarget::SERVICE) {
        Service* svc = ServiceList::GetInstance().FindService(name);
        if (svc == nullptr) {
...
            return;
        }
        if (auto result = function.action(svc); !result) {
...
        }

        return;
    }

....
}
```
这里面的逻辑十分简单，本质上就是继续获取从property_set传递过来后续的字符串。也就是ctl.xxx点后面的命令对应的方法。并且先通过serviceList找到解析好的服务，调用缓存在map中命令start对应的方法指针，也就是service的start。就重新走到上面Service::Start fork出进程的逻辑中。

## BootAnimation进程启动
```cpp
int main()
{
    setpriority(PRIO_PROCESS, 0, ANDROID_PRIORITY_DISPLAY);

    bool noBootAnimation = bootAnimationDisabled();
    ALOGI_IF(noBootAnimation,  "boot animation disabled");
    if (!noBootAnimation) {

        sp<ProcessState> proc(ProcessState::self());
        ProcessState::self()->startThreadPool();

        waitForSurfaceFlinger();

        // create the boot animation object
        sp<BootAnimation> boot = new BootAnimation(new AudioAnimationCallbacks());
        ALOGV("Boot animation set up. Joining pool.");

        IPCThreadState::self()->joinThreadPool();
    }
    ALOGV("Boot animation exit");
    return 0;
}
```
首先默认当前noBootAnimation是false。因此会初始化Binder的驱动，调用waitForSurfaceFlinger从serviceManager中查找SF进程，找到才生成一个BootAnimation对象准备执行开机动画，并设置了一个音轨的回调。

### BootAnimation 初始化
接下来就会揭开本片文章的秘密，为什么没有Activity还是能够显示界面。其核心原理是什么。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/)/[bootanimation](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/bootanimation/)/[BootAnimation.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/cmds/bootanimation/BootAnimation.cpp)
```cpp
BootAnimation::BootAnimation(sp<Callbacks> callbacks)
        : Thread(false), mClockEnabled(true), mTimeIsAccurate(false),
        mTimeFormat12Hour(false), mTimeCheckThread(NULL), mCallbacks(callbacks) {
    mSession = new SurfaceComposerClient();
...
}
```
在这个构造函数中，生成了一个十分重要的对象SurfaceComposerClient。因为SurfaceComposerClient是一个sp强智能指针，会继续走到onFirstRef中。


```cpp
void SurfaceComposerClient::onFirstRef() {
    sp<ISurfaceComposer> sf(ComposerService::getComposerService());
    if (sf != 0 && mStatus == NO_INIT) {
        auto rootProducer = mParent.promote();
        sp<ISurfaceComposerClient> conn;
        conn = (rootProducer != nullptr) ? sf->createScopedConnection(rootProducer) :
                sf->createConnection();
        if (conn != 0) {
            mClient = conn;
            mStatus = NO_ERROR;
        }
    }
}
```
先拿到一个单例的ComposerService 服务对象，接着通过ISurfaceComposer通过createScopedConnection通信创建一个ISurfaceComposerClient。

ISurfaceComposer指代的是什么，ISurfaceComposerClient又是指什么呢？

#### ComposerService的初始化
```cpp
/*static*/ sp<ISurfaceComposer> ComposerService::getComposerService() {
    ComposerService& instance = ComposerService::getInstance();
    Mutex::Autolock _l(instance.mLock);
    if (instance.mComposerService == NULL) {
        ComposerService::getInstance().connectLocked();
        assert(instance.mComposerService != NULL);
        ALOGD("ComposerService reconnected");
    }
    return instance.mComposerService;
}

```
能看到它实际上是一个单例设计,返回了ISurfaceComposer对象。

```cpp
ComposerService::ComposerService()
: Singleton<ComposerService>() {
    Mutex::Autolock _l(mLock);
    connectLocked();
}

void ComposerService::connectLocked() {
    const String16 name("SurfaceFlinger");
    while (getService(name, &mComposerService) != NO_ERROR) {
        usleep(250000);
    }
    assert(mComposerService != NULL);

    // Create the death listener.
    class DeathObserver : public IBinder::DeathRecipient {
        ComposerService& mComposerService;
        virtual void binderDied(const wp<IBinder>& who) {
            ALOGW("ComposerService remote (surfaceflinger) died [%p]",
                  who.unsafe_get());
            mComposerService.composerServiceDied();
        }
     public:
        explicit DeathObserver(ComposerService& mgr) : mComposerService(mgr) { }
    };

    mDeathObserver = new DeathObserver(*const_cast<ComposerService*>(this));
    IInterface::asBinder(mComposerService)->linkToDeath(mDeathObserver);
}
```
能看到在这个过程中，会从ServiceManager查找SF在Binder驱动中映射的服务。并且绑定上另一个死亡代理，用于销毁ComposerService中的资源。

到此时SF的binder接口已经对着BootAnimation暴露了。

了解ISurfaceComposer 本质上就是SF的远程端口，接下来再看看ISurfaceComposerClient是什么。

#### ISurfaceComposer createConnection
实际调用的是SF的createConnection
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)
```cpp
sp<ISurfaceComposerClient> SurfaceFlinger::createConnection() {
    return initClient(new Client(this));
}
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[Client.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/Client.cpp)
```cpp
class Client : public BnSurfaceComposerClient
```
```cpp
Client::Client(const sp<SurfaceFlinger>& flinger)
    : Client(flinger, nullptr)
{
}
```
本质上就是一个实现了BnSurfaceComposerClient的Client对象。之后关于渲染的对象将会从中生成。



### BootAnimation onFirstRef
```cpp
void BootAnimation::onFirstRef() {
    status_t err = mSession->linkToComposerDeath(this);
    ALOGE_IF(err, "linkToComposerDeath failed (%s) ", strerror(-err));
    if (err == NO_ERROR) {
        run("BootAnimation", PRIORITY_DISPLAY);
    }
}
```
当通过SurfaceComposerClient链接到远程Binder服务后，就会执行run方法。


文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[SurfaceComposerClient.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/SurfaceComposerClient.cpp)

```cpp
status_t SurfaceComposerClient::linkToComposerDeath(
        const sp<IBinder::DeathRecipient>& recipient,
        void* cookie, uint32_t flags) {
    sp<ISurfaceComposer> sf(ComposerService::getComposerService());
    return IInterface::asBinder(sf)->linkToDeath(recipient, cookie, flags);
}
```
能看到本质上是生成一个ComposerService BpBinder对象，并且进行Binder的死亡代理绑定。



### BootAnimation run
本质上BootAnimation还是一个线程：
```
class BootAnimation : public Thread, public IBinder::DeathRecipient
```
因此执行run之后，会先执行readyToRun，接着执行treadLoop方法。注意这两个方法都已经在线程中了。

#### BootAnimation readyToRun 准备渲染流程
```cpp
status_t BootAnimation::readyToRun() {
    mAssets.addDefaultAssets();

    sp<IBinder> dtoken(SurfaceComposerClient::getBuiltInDisplay(
            ISurfaceComposer::eDisplayIdMain));
    DisplayInfo dinfo;
    status_t status = SurfaceComposerClient::getDisplayInfo(dtoken, &dinfo);
    if (status)
        return -1;

    // create the native surface
    sp<SurfaceControl> control = session()->createSurface(String8("BootAnimation"),
            dinfo.w, dinfo.h, PIXEL_FORMAT_RGB_565);

    SurfaceComposerClient::Transaction t;
    t.setLayer(control, 0x40000000)
        .apply();

    sp<Surface> s = control->getSurface();

    // initialize opengl and egl
    const EGLint attribs[] = {
            EGL_RED_SIZE,   8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE,  8,
            EGL_DEPTH_SIZE, 0,
            EGL_NONE
    };
    EGLint w, h;
    EGLint numConfigs;
    EGLConfig config;
    EGLSurface surface;
    EGLContext context;

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);

    eglInitialize(display, 0, 0);
    eglChooseConfig(display, attribs, &config, 1, &numConfigs);
    surface = eglCreateWindowSurface(display, config, s.get(), NULL);
    context = eglCreateContext(display, config, NULL, NULL);
    eglQuerySurface(display, surface, EGL_WIDTH, &w);
    eglQuerySurface(display, surface, EGL_HEIGHT, &h);

    if (eglMakeCurrent(display, surface, surface, context) == EGL_FALSE)
        return NO_INIT;

    mDisplay = display;
    mContext = context;
    mSurface = surface;
    mWidth = w;
    mHeight = h;
    mFlingerSurfaceControl = control;
    mFlingerSurface = s;

    // If the device has encryption turned on or is in process
    // of being encrypted we show the encrypted boot animation.
    char decrypt[PROPERTY_VALUE_MAX];
    property_get("vold.decrypt", decrypt, "");

    bool encryptedAnimation = atoi(decrypt) != 0 ||
        !strcmp("trigger_restart_min_framework", decrypt);

    if (!mShuttingDown && encryptedAnimation) {
        static const char* encryptedBootFiles[] =
            {PRODUCT_ENCRYPTED_BOOTANIMATION_FILE, SYSTEM_ENCRYPTED_BOOTANIMATION_FILE};
        for (const char* f : encryptedBootFiles) {
            if (access(f, R_OK) == 0) {
                mZipFileName = f;
                return NO_ERROR;
            }
        }
    }
    static const char* bootFiles[] =
        {PRODUCT_BOOTANIMATION_FILE, OEM_BOOTANIMATION_FILE, SYSTEM_BOOTANIMATION_FILE};
    static const char* shutdownFiles[] =
        {PRODUCT_SHUTDOWNANIMATION_FILE, OEM_SHUTDOWNANIMATION_FILE, SYSTEM_SHUTDOWNANIMATION_FILE};

    for (const char* f : (!mShuttingDown ? bootFiles : shutdownFiles)) {
        if (access(f, R_OK) == 0) {
            mZipFileName = f;
            return NO_ERROR;
        }
    }
    return NO_ERROR;
}
```
在准备渲染流程中，做的事情有如下几个步骤：
- 1.SurfaceComposerClient::getBuiltInDisplay 从SF中查询可用的物理屏幕
- 2.SurfaceComposerClient::getDisplayInfo 从SF中获取屏幕的详细信息
- 3.session()->createSurface 通过Client创建绘制平面控制中心
- 4.t.setLayer(control, 0x40000000) 设置当前layer的层级
- 5.control->getSurface 获取真正的绘制平面对象
- 6.eglGetDisplay 获取opengl es的默认主屏幕，加载OpenGL es
- 7.eglInitialize 初始化屏幕对象和着色器缓存
- 8.eglChooseConfig 自动筛选出最合适的配置
- 9.eglCreateWindowSurface 从Surface中创建一个opengl es的surface
- 10.eglCreateContext 创建当前opengl es 的上下文
- 11.eglQuerySurface 查找当前环境的宽高属性
- 12.eglMakeCurrent 把上下文Context，屏幕display还有渲染面surface,线程关联起来。
- 13.从如下几个目录查找zip文件，分为两种模式，一种是加密文件的动画，一种是普通压缩文件动画：
```cpp
static const char OEM_BOOTANIMATION_FILE[] = "/oem/media/bootanimation.zip";
static const char PRODUCT_BOOTANIMATION_FILE[] = "/product/media/bootanimation.zip";
static const char SYSTEM_BOOTANIMATION_FILE[] = "/system/media/bootanimation.zip";
static const char PRODUCT_ENCRYPTED_BOOTANIMATION_FILE[] = "/product/media/bootanimation-encrypted.zip";
static const char SYSTEM_ENCRYPTED_BOOTANIMATION_FILE[] = "/system/media/bootanimation-encrypted.zip";
static const char OEM_SHUTDOWNANIMATION_FILE[] = "/oem/media/shutdownanimation.zip";
static const char PRODUCT_SHUTDOWNANIMATION_FILE[] = "/product/media/shutdownanimation.zip";
static const char SYSTEM_SHUTDOWNANIMATION_FILE[] = "/system/media/shutdownanimation.zip";
```
在这些zip包中其实就是一张张图片。播放的时候，解压这些zip包，一张张的图片想动画一样播出。

从第6点开始就是opengl es开发初四话流程的套路。其实真的核心的准备核心还是前5点。opengles的环境真正和Android系统关联起来是是第9点创建opengles的surface时候和Android的本地窗口互相绑定。

#### BootAnimation threadLoop
```cpp
bool BootAnimation::threadLoop()
{
    bool r;
    // We have no bootanimation file, so we use the stock android logo
    // animation.
    if (mZipFileName.isEmpty()) {
        r = android();
    } else {
        r = movie();
    }

    eglMakeCurrent(mDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(mDisplay, mContext);
    eglDestroySurface(mDisplay, mSurface);
    mFlingerSurface.clear();
    mFlingerSurfaceControl.clear();
    eglTerminate(mDisplay);
    eglReleaseThread();
    IPCThreadState::self()->stopProcess();
    return r;
}
```
在这里如果设定了bootanimation的zip压缩包则会走movie解压播放zip中的动画，否则就会走android默认动画。


#### BootAnimation moive
既然老罗解析了Android默认的动画，我就去解析Android自定义动画的核心原理。
```cpp
bool BootAnimation::movie()
{
    Animation* animation = loadAnimation(mZipFileName);
    if (animation == NULL)
        return false;

...
    mUseNpotTextures = false;
    String8 gl_extensions;
    const char* exts = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
    if (!exts) {
        glGetError();
    } else {
        gl_extensions.setTo(exts);
        if ((gl_extensions.find("GL_ARB_texture_non_power_of_two") != -1) ||
            (gl_extensions.find("GL_OES_texture_npot") != -1)) {
            mUseNpotTextures = true;
        }
    }

    // Blend required to draw time on top of animation frames.
//设置混合颜色模式 后面是1 - 原图的四个颜色分量
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
//设置颜色过度模式，非平滑模式
    glShadeModel(GL_FLAT);
    glDisable(GL_DITHER);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
//绑定纹理
    glBindTexture(GL_TEXTURE_2D, 0);
//启动纹理
    glEnable(GL_TEXTURE_2D);
//控制纹理如何与片元颜色进行计算的 设置纹理环境，纹理代替片元
    glTexEnvx(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
//设置横纵两轴的边界外以重复模式绘制纹理
    glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
//为线性过滤
    glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    bool clockFontInitialized = false;
    if (mClockEnabled) {
        clockFontInitialized =
            (initFont(&animation->clockFont, CLOCK_FONT_ASSET) == NO_ERROR);
        mClockEnabled = clockFontInitialized;
    }

    if (mClockEnabled && !updateIsTimeAccurate()) {
        mTimeCheckThread = new TimeCheckThread(this);
        mTimeCheckThread->run("BootAnimation::TimeCheckThread", PRIORITY_NORMAL);
    }

    playAnimation(*animation);

    if (mTimeCheckThread != nullptr) {
        mTimeCheckThread->requestExit();
        mTimeCheckThread = nullptr;
    }

    releaseAnimation(animation);

    if (clockFontInitialized) {
        glDeleteTextures(1, &animation->clockFont.texture.name);
    }

    return false;
}
```
大致分为三步骤：
- 1.loadAnimation 解析zip包的动画数据
- 2.初始化纹理设置
- 3.playAnimation 播放解析好的纹理数据
- 4.releaseAnimation 播放完毕释放资源

#### loadAnimation
```cpp
BootAnimation::Animation* BootAnimation::loadAnimation(const String8& fn)
{
    if (mLoadedFiles.indexOf(fn) >= 0) {
        ALOGE("File \"%s\" is already loaded. Cyclic ref is not allowed",
            fn.string());
        return NULL;
    }
    ZipFileRO *zip = ZipFileRO::open(fn);
    if (zip == NULL) {
        ALOGE("Failed to open animation zip \"%s\": %s",
            fn.string(), strerror(errno));
        return NULL;
    }

    Animation *animation =  new Animation;
    animation->fileName = fn;
    animation->zip = zip;
    animation->clockFont.map = nullptr;
    mLoadedFiles.add(animation->fileName);

    parseAnimationDesc(*animation);
    if (!preloadZip(*animation)) {
        return NULL;
    }

    mLoadedFiles.remove(fn);
    return animation;
}

```
关键方法有两个，第一个是parseAnimationDesc，第二个是preloadZip。

#### parseAnimationDesc 解析zip包中的描述文件
```cpp
bool BootAnimation::parseAnimationDesc(Animation& animation)
{
    String8 desString;

    if (!readFile(animation.zip, "desc.txt", desString)) {
        return false;
    }
    char const* s = desString.string();

    // Parse the description file
    for (;;) {
        const char* endl = strstr(s, "\n");
        if (endl == NULL) break;
        String8 line(s, endl - s);
        const char* l = line.string();
        int fps = 0;
        int width = 0;
        int height = 0;
        int count = 0;
        int pause = 0;
        char path[ANIM_ENTRY_NAME_MAX];
        char color[7] = "000000"; // default to black if unspecified
        char clockPos1[TEXT_POS_LEN_MAX + 1] = "";
        char clockPos2[TEXT_POS_LEN_MAX + 1] = "";

        char pathType;
        if (sscanf(l, "%d %d %d", &width, &height, &fps) == 3) {
            // ALOGD("> w=%d, h=%d, fps=%d", width, height, fps);
            animation.width = width;
            animation.height = height;
            animation.fps = fps;
        } else if (sscanf(l, " %c %d %d %s #%6s %16s %16s",
                          &pathType, &count, &pause, path, color, clockPos1, clockPos2) >= 4) {
            //ALOGD("> type=%c, count=%d, pause=%d, path=%s, color=%s, clockPos1=%s, clockPos2=%s",
            //    pathType, count, pause, path, color, clockPos1, clockPos2);
            Animation::Part part;
            part.playUntilComplete = pathType == 'c';
            part.count = count;
            part.pause = pause;
            part.path = path;
            part.audioData = NULL;
            part.animation = NULL;
            if (!parseColor(color, part.backgroundColor)) {
                ALOGE("> invalid color '#%s'", color);
                part.backgroundColor[0] = 0.0f;
                part.backgroundColor[1] = 0.0f;
                part.backgroundColor[2] = 0.0f;
            }
            parsePosition(clockPos1, clockPos2, &part.clockPosX, &part.clockPosY);
            animation.parts.add(part);
        }
        else if (strcmp(l, "$SYSTEM") == 0) {
            // ALOGD("> SYSTEM");
            Animation::Part part;
            part.playUntilComplete = false;
            part.count = 1;
            part.pause = 0;
            part.audioData = NULL;
            part.animation = loadAnimation(String8(SYSTEM_BOOTANIMATION_FILE));
            if (part.animation != NULL)
                animation.parts.add(part);
        }
        s = ++endl;
    }

    return true;
}
```
想要正常解析开机动画，需要有一个desc.txt。有一个例子如下：
```
241 63 60
c 1 30 part0
c 1 0 part1
c 0 0 part2
c 1 64 part3
c 1 15 part4
```

该文件头三个字符串定义了宽高，和帧数。找到\n结束后就到下一行中去。
接下来的部分就是动画每一部分，第一个字符串c是指是否一直播放到结束；第而个则是指pause，是暂停的帧数；第三个int是指当前帧数中有加载目录下多少画面，最后一个代表资源路径。

把每一部分当成一个part保存在Animation中。

当然在Android 9.0版本中还能设置更多的选项如音频等。


#### preloadZip预加载zip

```cpp
bool BootAnimation::preloadZip(Animation& animation)
{
    // read all the data structures
    const size_t pcount = animation.parts.size();
    void *cookie = NULL;
    ZipFileRO* zip = animation.zip;
    if (!zip->startIteration(&cookie)) {
        return false;
    }

    ZipEntryRO entry;
    char name[ANIM_ENTRY_NAME_MAX];
    while ((entry = zip->nextEntry(cookie)) != NULL) {
        const int foundEntryName = zip->getEntryFileName(entry, name, ANIM_ENTRY_NAME_MAX);
        if (foundEntryName > ANIM_ENTRY_NAME_MAX || foundEntryName == -1) {
            continue;
        }

        const String8 entryName(name);
        const String8 path(entryName.getPathDir());
        const String8 leaf(entryName.getPathLeaf());
        if (leaf.size() > 0) {
            if (entryName == CLOCK_FONT_ZIP_NAME) {
                FileMap* map = zip->createEntryFileMap(entry);
                if (map) {
                    animation.clockFont.map = map;
                }
                continue;
            }

            for (size_t j = 0; j < pcount; j++) {
                if (path == animation.parts[j].path) {
                    uint16_t method;
                    // supports only stored png files
                    if (zip->getEntryInfo(entry, &method, NULL, NULL, NULL, NULL, NULL)) {
                        if (method == ZipFileRO::kCompressStored) {
                            FileMap* map = zip->createEntryFileMap(entry);
                            if (map) {
                                Animation::Part& part(animation.parts.editItemAt(j));
                                if (leaf == "audio.wav") {
                                    // a part may have at most one audio file
                                    part.audioData = (uint8_t *)map->getDataPtr();
                                    part.audioLength = map->getDataLength();
                                } else if (leaf == "trim.txt") {
                                    part.trimData.setTo((char const*)map->getDataPtr(),
                                                        map->getDataLength());
                                } else {
                                    Animation::Frame frame;
                                    frame.name = leaf;
                                    frame.map = map;
                                    frame.trimWidth = animation.width;
                                    frame.trimHeight = animation.height;
                                    frame.trimX = 0;
                                    frame.trimY = 0;
                                    part.frames.add(frame);
                                }
                            }
                        } else {
...
                        }
                    }
                }
            }
        }
    }

    for (Animation::Part& part : animation.parts) {
        const char* trimDataStr = part.trimData.string();
        for (size_t frameIdx = 0; frameIdx < part.frames.size(); frameIdx++) {
            const char* endl = strstr(trimDataStr, "\n");
            // No more trimData for this part.
            if (endl == NULL) {
                break;
            }
            String8 line(trimDataStr, endl - trimDataStr);
            const char* lineStr = line.string();
            trimDataStr = ++endl;
            int width = 0, height = 0, x = 0, y = 0;
            if (sscanf(lineStr, "%dx%d+%d+%d", &width, &height, &x, &y) == 4) {
                Animation::Frame& frame(part.frames.editItemAt(frameIdx));
                frame.trimWidth = width;
                frame.trimHeight = height;
                frame.trimX = x;
                frame.trimY = y;
            } else {
                break;
            }
        }
    }

    mCallbacks->init(animation.parts);

    zip->endIteration(cookie);

    return true;
}
```
这里面做了两件事情：
- 1.首先，解压zip包中所有的资源，注入到每一个Animation parts中。让其拥有真正的资源地址。
- 2.根据每一个parts中的资源数据和头信息，生成一个个Frame保存在Animation中。


### playAnimation 播放动画
```cpp
bool BootAnimation::playAnimation(const Animation& animation)
{
    const size_t pcount = animation.parts.size();
    nsecs_t frameDuration = s2ns(1) / animation.fps;
    const int animationX = (mWidth - animation.width) / 2;
    const int animationY = (mHeight - animation.height) / 2;

    ALOGD("%sAnimationShownTiming start time: %" PRId64 "ms", mShuttingDown ? "Shutdown" : "Boot",
            elapsedRealtime());
    for (size_t i=0 ; i<pcount ; i++) {
        const Animation::Part& part(animation.parts[i]);
        const size_t fcount = part.frames.size();
        glBindTexture(GL_TEXTURE_2D, 0);

        // Handle animation package
        if (part.animation != NULL) {
            playAnimation(*part.animation);
            if (exitPending())
                break;
            continue; //to next part
        }

        for (int r=0 ; !part.count || r<part.count ; r++) {
            // Exit any non playuntil complete parts immediately
            if(exitPending() && !part.playUntilComplete)
                break;

            mCallbacks->playPart(i, part, r);

            glClearColor(
                    part.backgroundColor[0],
                    part.backgroundColor[1],
                    part.backgroundColor[2],
                    1.0f);

            for (size_t j=0 ; j<fcount && (!exitPending() || part.playUntilComplete) ; j++) {
                const Animation::Frame& frame(part.frames[j]);
                nsecs_t lastFrame = systemTime();

                if (r > 0) {
                    glBindTexture(GL_TEXTURE_2D, frame.tid);
                } else {
                    if (part.count != 1) {
                        glGenTextures(1, &frame.tid);
                        glBindTexture(GL_TEXTURE_2D, frame.tid);
                        glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                        glTexParameterx(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                    }
                    int w, h;
                    initTexture(frame.map, &w, &h);
                }

                const int xc = animationX + frame.trimX;
                const int yc = animationY + frame.trimY;
                Region clearReg(Rect(mWidth, mHeight));
                clearReg.subtractSelf(Rect(xc, yc, xc+frame.trimWidth, yc+frame.trimHeight));
                if (!clearReg.isEmpty()) {
                    Region::const_iterator head(clearReg.begin());
                    Region::const_iterator tail(clearReg.end());
                    glEnable(GL_SCISSOR_TEST);
                    while (head != tail) {
                        const Rect& r2(*head++);
                        glScissor(r2.left, mHeight - r2.bottom, r2.width(), r2.height());
                        glClear(GL_COLOR_BUFFER_BIT);
                    }
                    glDisable(GL_SCISSOR_TEST);
                }
                glDrawTexiOES(xc, mHeight - (yc + frame.trimHeight),
                              0, frame.trimWidth, frame.trimHeight);
                if (mClockEnabled && mTimeIsAccurate && validClock(part)) {
                    drawClock(animation.clockFont, part.clockPosX, part.clockPosY);
                }

                eglSwapBuffers(mDisplay, mSurface);

                nsecs_t now = systemTime();
                nsecs_t delay = frameDuration - (now - lastFrame);
                //ALOGD("%lld, %lld", ns2ms(now - lastFrame), ns2ms(delay));
                lastFrame = now;

                if (delay > 0) {
                    struct timespec spec;
                    spec.tv_sec  = (now + delay) / 1000000000;
                    spec.tv_nsec = (now + delay) % 1000000000;
                    int err;
                    do {
                        err = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &spec, NULL);
                    } while (err<0 && errno == EINTR);
                }

                checkExit();
            }

            usleep(part.pause * ns2us(frameDuration));

            // For infinite parts, we've now played them at least once, so perhaps exit
            if(exitPending() && !part.count)
                break;
        }

    }

    // Free textures created for looping parts now that the animation is done.
    for (const Animation::Part& part : animation.parts) {
        if (part.count != 1) {
            const size_t fcount = part.frames.size();
            for (size_t j = 0; j < fcount; j++) {
                const Animation::Frame& frame(part.frames[j]);
                glDeleteTextures(1, &frame.tid);
            }
        }
    }

    return true;
}
```
能看到在这个过程中，如果没有设置c标志为则不会播放。否则将会循环每一个每一个part中对应frame的个数。当是frame的第一帧的时候将会初始化纹理，设置好纹理需要加载的数据以及宽高，并且绑定当前frame的id为渲染纹理的句柄。

找到动画的动画的启动位置，其位置就是整个屏幕的宽高-动画绘制区域宽高的1/2，保证整个动画刚好在大小适应的位置。

获取到区域之后，通过glScissor进行裁剪。glDrawTexiOES绘制纹理位置，最后进行opengles 缓冲区交换。计算当前已经消耗的时间和每一帧进行比对，再进行延时处理。

最后处理pause的数据，查看需要暂停沉睡多少帧。


最后的最后，销毁每一个绑定在frame.id上的纹理。以及调用checkExit检测是否需要退出该进程。

#### releaseAnimation
```cpp
void BootAnimation::releaseAnimation(Animation* animation) const
{
    for (Vector<Animation::Part>::iterator it = animation->parts.begin(),
         e = animation->parts.end(); it != e; ++it) {
        if (it->animation)
            releaseAnimation(it->animation);
    }
    if (animation->zip)
        delete animation->zip;
    delete animation;
}
```
销毁animation中part以及zip映射的内存。

那么什么时候才是整个进程真正销毁呢？那一般就是桌面进程准备显示了，那就应该销毁BootAnimation进程了。我们可以猜测就在桌面的Activity 进入了Resume之后进行销毁的。

### BootAnimation 进程的销毁
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)
```java
  public void handleResumeActivity(IBinder token, boolean finalStateRequest, boolean isForward,
            String reason) {
...
        Looper.myQueue().addIdleHandler(new Idler());
    }
```
在执行完Resume之后，会添加一次IdleHandler对象。让进程空闲执行。

```java
public final boolean queueIdle() {
            ActivityClientRecord a = mNewActivities;
            boolean stopProfiling = false;
         ...
            if (a != null) {
                mNewActivities = null;
                IActivityManager am = ActivityManager.getService();
                ActivityClientRecord prev;
                do {
   
                    if (a.activity != null && !a.activity.mFinished) {
                        try {
                            am.activityIdle(a.token, a.createdConfig, stopProfiling);
                            a.createdConfig = null;
                        } catch (RemoteException ex) {
                            throw ex.rethrowFromSystemServer();
                        }
                    }
                    prev = a;
                    a = a.nextIdle;
                    prev.nextIdle = null;
                } while (a != null);
            }
...
            return false;
        }
```
该方法将会通信到AMS中。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)
```java
    @Override
    public final void activityIdle(IBinder token, Configuration config, boolean stopProfiling) {
        final long origId = Binder.clearCallingIdentity();
        synchronized (this) {
            ActivityStack stack = ActivityRecord.getStackLocked(token);
            if (stack != null) {
                ActivityRecord r =
                        mStackSupervisor.activityIdleInternalLocked(token, false /* fromTimeout */,
                                false /* processPausingActivities */, config);
                if (stopProfiling) {
                    if ((mProfileProc == r.app) && mProfilerInfo != null) {
                        clearProfilerLocked();
                    }
                }
            }
        }
        Binder.restoreCallingIdentity(origId);
    }
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)
```java
    final ActivityRecord activityIdleInternalLocked(final IBinder token, boolean fromTimeout,
            boolean processPausingActivities, Configuration config) {
        if (DEBUG_ALL) Slog.v(TAG, "Activity idle: " + token);

        ArrayList<ActivityRecord> finishes = null;
        ArrayList<UserState> startingUsers = null;
        int NS = 0;
        int NF = 0;
        boolean booting = false;
        boolean activityRemoved = false;

        ActivityRecord r = ActivityRecord.forTokenLocked(token);
        if (r != null) {
           ....
            mHandler.removeMessages(IDLE_TIMEOUT_MSG, r);
            r.finishLaunchTickingLocked();
            if (fromTimeout) {
                reportActivityLaunchedLocked(fromTimeout, r, -1, -1);
            }

            if (config != null) {
                r.setLastReportedGlobalConfiguration(config);
            }

            // We are now idle.  If someone is waiting for a thumbnail from
            // us, we can now deliver.
            r.idle = true;

            if (isFocusedStack(r.getStack()) || fromTimeout) {
                booting = checkFinishBootingLocked();
            }
        }

....
        }

....
        return r;
    }
```
能看到此时将会执行checkFinishBootingLocked检测BootAnimation是否关闭。
```java
    private boolean checkFinishBootingLocked() {
        final boolean booting = mService.mBooting;
        boolean enableScreen = false;
        mService.mBooting = false;
        if (!mService.mBooted) {
            mService.mBooted = true;
            enableScreen = true;
        }
        if (booting || enableScreen) {
            mService.postFinishBooting(booting, enableScreen);
        }
        return booting;
    }
```
这里很简单，就是一个全局的标志位判断,接下来就回到AMS中
```java
    void postFinishBooting(boolean finishBooting, boolean enableScreen) {
        mHandler.sendMessage(mHandler.obtainMessage(FINISH_BOOTING_MSG,
                finishBooting ? 1 : 0, enableScreen ? 1 : 0));
    }
```
进入AMS的Handler中
```java
            case FINISH_BOOTING_MSG: {
                if (msg.arg1 != 0) {
                    finishBooting();
                }
                if (msg.arg2 != 0) {
                    enableScreenAfterBoot();
                }
                break;
            }
```
会执行finishBooting继续设置一个标志位。这个标志用来判断不需要其他时候有其他进程来执行结束BootAnimation进程的操作。
```java
    void enableScreenAfterBoot() {
       
        mWindowManager.enableScreenAfterBoot();

        ...
    }
```
此时就会走到WMS中的enableScreenAfterBoot。因为WMS作为窗体管理服务，肯定有渲染相关的服务在里面。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[WindowManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/WindowManagerService.java)
```java
  public void enableScreenAfterBoot() {
        synchronized(mWindowMap) {
...
            if (mSystemBooted) {
                return;
            }
            mSystemBooted = true;
            hideBootMessagesLocked();
            mH.sendEmptyMessageDelayed(H.BOOT_TIMEOUT, 30 * 1000);
        }

        mPolicy.systemBooted();

        performEnableScreen();
    }
```

```java
    private void performEnableScreen() {
        synchronized(mWindowMap) {
         
...

            try {
                IBinder surfaceFlinger = ServiceManager.getService("SurfaceFlinger");
                if (surfaceFlinger != null) {
                    Parcel data = Parcel.obtain();
                    data.writeInterfaceToken("android.ui.ISurfaceComposer");
                    surfaceFlinger.transact(IBinder.FIRST_CALL_TRANSACTION, // BOOT_FINISHED
                            data, null, 0);
                    data.recycle();
                }
            } catch (RemoteException ex) {
                ...
            }

         ...

        try {
            mActivityManager.bootAnimationComplete();
        } catch (RemoteException e) {
        }

...
    }
```
关键是通信到SF中，传入了FIRST_CALL_TRANSACTION命令，而这个命令实际上就是BOOT_FINISHED。
```cpp
BOOT_FINISHED = IBinder::FIRST_CALL_TRANSACTION,
```

我们去SF的基类看看做了什么。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[ISurfaceComposer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/ISurfaceComposer.cpp)
```cpp
        case BOOT_FINISHED: {
            CHECK_INTERFACE(ISurfaceComposer, data, reply);
            bootFinished();
            return NO_ERROR;
        }
```
其实就是SF中的bootFinished方法。
```cpp
void SurfaceFlinger::bootFinished()
{
    if (mStartPropertySetThread->join() != NO_ERROR) {
        ALOGE("Join StartPropertySetThread failed!");
    }
    const nsecs_t now = systemTime();
    const nsecs_t duration = now - mBootTime;
    ALOGI("Boot is finished (%ld ms)", long(ns2ms(duration)) );

    // wait patiently for the window manager death
    const String16 name("window");
    sp<IBinder> window(defaultServiceManager()->getService(name));
    if (window != 0) {
        window->linkToDeath(static_cast<IBinder::DeathRecipient*>(this));
    }

....

    property_set("service.bootanim.exit", "1");

    const int LOGTAG_SF_STOP_BOOTANIM = 60110;
    LOG_EVENT_LONG(LOGTAG_SF_STOP_BOOTANIM,
                   ns2ms(systemTime(SYSTEM_TIME_MONOTONIC)));

    sp<LambdaMessage> readProperties = new LambdaMessage([&]() {
        readPersistentProperties();
    });
    postMessageAsync(readProperties);
}
```
在此刻，SF绑定了对WMS的Binder死亡代理。不过关键还是设置了service.bootanim.exit这个全局属性。而这个属性刚好就是BootAnimation在checkExit方法中不断循环检测。
```cpp
void BootAnimation::checkExit() {
    // Allow surface flinger to gracefully request shutdown
    char value[PROPERTY_VALUE_MAX];
    property_get(EXIT_PROP_NAME, value, "0");
    int exitnow = atoi(value);
    if (exitnow) {
        requestExit();
        mCallbacks->shutdown();
    }
}
```
requestExit其实就是退出该BootAnimation线程的threadLoop方法，这样整个main方法就不会阻塞住，就会一直运行整个main到底结束整个进程。



## 总结
用一幅图总结：

![开机动画启动原理.jpg](/images/开机动画启动原理.jpg)



这些其实都是普通的OpenGL es的操作。但是似乎把Android渲染系统部分给屏蔽掉了。我们似乎没有办法继续探索下去了？不得不说封装的太棒了，压根没有感受到OpenGL es适配了平台的特性。

回答开头的疑问，为什么我们不需要Activity也能渲染呢，由始至终都没有看到Activity的存在？其实Activity本身并不是负责渲染，它不过是集UI交互的大成者。真正负责渲染的，其实是由Surface联通SF进行交互渲染的。我们日常开发(不打开硬件加速)似乎有没有看到OpenGL es的身影。

其实我们可以做一个大胆的猜测，其实Android的渲染很可能分为2个部分，一个是借助OpenGL es进行渲染，另一个则是通过Skia画笔绘制好像素之后进行渲染。究竟是不是这样呢？不妨留一个悬念，下一篇文章，将会带领大家阅读Android在封装OpenGL es上做了什么努力。

