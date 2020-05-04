---
title: Android 重学系列 SurfaceFlinger 的初始化
top: false
cover: false
date: 2020-01-19 14:19:41
img:
tag:
description:
author: yjy239
summary:
categories: SurfaceFlinger
tags:
- Android
- Android Framework
---
# 前言
本片来看看SurfaceFlinger的初始化。从SurfaceFlinger的初始化，来对整个SurfaceFlinger的有一个总览。记住以下代码全部来自Android 9.0

遇到问题可以来本文下讨论:[https://www.jianshu.com/p/9dac91bbb9c9](https://www.jianshu.com/p/9dac91bbb9c9)


# 正文

## bp 文件的初步浏览
要明白SurfaceFlinger的启动需要看看SurfaceFlinger模块目录下的bp文件：
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[Android.bp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/Android.bp)

其实bp最后都会转化为nija文件进行编译，因此和gn文件从某种程度上很相似，我们来看看这个bp文件就大致知道SurfaceFlinger涉及了什么模块，这里只列举出比较重要的模块
```bp
....
cc_defaults {
    name: "libsurfaceflinger_defaults",
    defaults: ["surfaceflinger_defaults"],
    cflags: [
        "-DGL_GLEXT_PROTOTYPES",
        "-DEGL_EGLEXT_PROTOTYPES",
    ],
    shared_libs: [
        "android.frameworks.vr.composer@1.0",
        "android.hardware.configstore-utils",
        "android.hardware.configstore@1.0",
        "android.hardware.configstore@1.1",
        "android.hardware.graphics.allocator@2.0",
        "android.hardware.graphics.composer@2.1",
        "android.hardware.graphics.composer@2.2",
        "android.hardware.power@1.0",
        "libbase",
        "libbinder",
        "libbufferhubqueue",
        "libcutils",
        "libdl",
        "libEGL",
        "libfmq",
        "libGLESv1_CM",
        "libGLESv2",
        "libgui",
        "libhardware",
        "libhidlbase",
        "libhidltransport",
        "libhwbinder",
        "liblayers_proto",
        "liblog",
        "libpdx_default_transport",
        "libprotobuf-cpp-lite",
        "libsync",
        "libtimestats_proto",
        "libui",
        "libutils",
        "libvulkan",
    ],
    static_libs: [
        "libserviceutils",
        "libtrace_proto",
        "libvkjson",
        "libvr_manager",
        "libvrflinger",
    ],
    header_libs: [
        "android.hardware.graphics.composer@2.1-command-buffer",
        "android.hardware.graphics.composer@2.2-command-buffer",
    ],
    export_static_lib_headers: [
        "libserviceutils",
    ],
    export_shared_lib_headers: [
        "android.hardware.graphics.allocator@2.0",
        "android.hardware.graphics.composer@2.1",
        "android.hardware.graphics.composer@2.2",
        "libhidlbase",
        "libhidltransport",
        "libhwbinder",
    ],
}

cc_library_headers {
....
}

filegroup {
    name: "libsurfaceflinger_sources",
    srcs: [
      ...//cpp 源代码文件
    ],
}

cc_library_shared {
    name: "libsurfaceflinger",
    defaults: ["libsurfaceflinger_defaults"],
...
}

cc_binary {
    name: "surfaceflinger",
    defaults: ["surfaceflinger_defaults"],
    init_rc: ["surfaceflinger.rc"],
    srcs: ["main_surfaceflinger.cpp"],
    whole_static_libs: [
        "libsigchain",
    ],
    shared_libs: [
        "android.frameworks.displayservice@1.0",
        "android.hardware.configstore-utils",
        "android.hardware.configstore@1.0",
        "android.hardware.graphics.allocator@2.0",
        "libbinder",
        "libcutils",
        "libdisplayservicehidl",
        "libhidlbase",
        "libhidltransport",
        "liblayers_proto",
        "liblog",
        "libsurfaceflinger",
        "libtimestats_proto",
        "libutils",
    ],
    static_libs: [
        "libserviceutils",
        "libtrace_proto",
    ],
    ldflags: ["-Wl,--export-dynamic"],

...
}
...
```
这里就先不讲解bp文件的编写。我们把每一个大括号都当作gn中的模块，就很好理解。能看到在SurfaceFlinger中导入了如下几个比较核心的东西：
- 1.android.hardware.graphics.allocator@2.0 图元生成器抽象硬件层的实现
- 2. android.hardware.graphics.composer@2.x hwc图层合成抽象硬件层实现
- 3.binder，opengles，hwbinder(抽象硬件层的binder)等。

- 4.设定了SurfaceFlinger的在Android启动初期需要加载的init.rc文件：surfaceflinger.rc。
- 5.SurfaceFlinger的主函数入口main_surfaceflinger.cpp

### surfaceflinger.rc
头三点可能不太好理解，什么是硬件抽象层，先把疑问放在这里。我们先来阅读我们熟悉的init.rc文件：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[surfaceflinger.rc](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/surfaceflinger.rc)
```
service surfaceflinger /system/bin/surfaceflinger
    class core animation
    user system
    group graphics drmrpc readproc
    onrestart restart zygote
    writepid /dev/stune/foreground/tasks
    socket pdx/system/vr/display/client     stream 0666 system graphics u:object_r:pdx_display_client_endpoint_socket:s0
    socket pdx/system/vr/display/manager    stream 0666 system graphics u:object_r:pdx_display_manager_endpoint_socket:s0
    socket pdx/system/vr/display/vsync      stream 0666 system graphics u:object_r:pdx_display_vsync_endpoint_socket:s0
```
能看到这里面能看到处理打开了surfaceflinger之外，同时还启动了三个socket，这三个socket还在init进程解析init.rc服务时候自动创建的socket文件描述符，并且会通过vr模块启动。vr并非是这一系列的重点，我以后有时间可能会去解析。


### SurfaceFlinger 启动入口main_surfaceflinger
接下来去看看SF进程的入口文件:
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[main_surfaceflinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/main_surfaceflinger.cpp)
```cpp
int main(int, char**) {
    signal(SIGPIPE, SIG_IGN);

    hardware::configureRpcThreadpool(1 /* maxThreads */,
            false /* callerWillJoin */);

    startGraphicsAllocatorService();

    // When SF is launched in its own process, limit the number of
    // binder threads to 4.
    ProcessState::self()->setThreadPoolMaxThreadCount(4);

    // start the thread pool
    sp<ProcessState> ps(ProcessState::self());
    ps->startThreadPool();

    // instantiate surfaceflinger
    sp<SurfaceFlinger> flinger = new SurfaceFlinger();

    setpriority(PRIO_PROCESS, 0, PRIORITY_URGENT_DISPLAY);

    set_sched_policy(0, SP_FOREGROUND);

    // Put most SurfaceFlinger threads in the system-background cpuset
    // Keeps us from unnecessarily using big cores
    // Do this after the binder thread pool init
    if (cpusets_enabled()) set_cpuset_policy(0, SP_SYSTEM);

    // initialize before clients can connect
    flinger->init();

    // publish surface flinger
    sp<IServiceManager> sm(defaultServiceManager());
    sm->addService(String16(SurfaceFlinger::getServiceName()), flinger, false,
                   IServiceManager::DUMP_FLAG_PRIORITY_CRITICAL);

    // publish GpuService
    sp<GpuService> gpuservice = new GpuService();
    sm->addService(String16(GpuService::SERVICE_NAME), gpuservice, false);

    startDisplayService(); // dependency on SF getting registered above

    struct sched_param param = {0};
    param.sched_priority = 2;
    if (sched_setscheduler(0, SCHED_FIFO, &param) != 0) {
        ALOGE("Couldn't set SCHED_FIFO");
    }

    // run surface flinger in this thread
    flinger->run();

    return 0;
}
```
能够在这里看到有如下几个核心方法：
- 1.startGraphicsAllocatorService 初始化Hal层的图元生成器服务
- 2.初始化ProcessState，也就是把该进程映射到Binder驱动程序
- 3.SurfaceFlinger实例化
- 4.set_sched_policy设置为前台进程
- 5.SurfaceFlinger调用init方法
- 6.因为SurfaceFlinger本质上也是一个Binder服务，因此添加到ServiceManager进程中。
- 7.初始化GpuService，也添加到ServiceManager进程中
- 8.启动DisplayService
- 9.sched_setscheduler 把进程调度模式设置为实时进程的FIFO
- 10.调用SurfaceFlinger的run方法。


值得注意的有三点：
- 1.初始化GraphicsAllocator服务和Display服务
- 2.set_sched_policy和sched_setscheduler设置进程
- 3.SurfaceFlinger的init和run方法

首先第一点Hal硬件抽象层先不介绍，放到下一章统一介绍。我们来注重关注看看第二点SurfaceFlinger的进程策略和第三点SF的初始化。

### SurfaceFlinger 进程调度策略

SurfaceFlinger作为Android整个进程最为核心进程之一，但是它并非像App一样前台显示，而是在背后运行，那么有什么办法保证它不被干掉呢？同时保证他的优先级，让CPU不断的优先把资源让渡给SF呢？让SF不断的抢到机会让渲染任务在16ms完成呢？

这里就需要介绍一下Linux内核的进程管理。

#### Linux的进程调度简介
在Linux中把进程分为两大类：
- 1.实时进程 是指需要尽快执行那种
- 2.普通进程 是指大部分不同进程

而在这两种进程中又有分为两大类进程调度策略：
- 1.实时调度策略：SCHED_FIFO、SCHED_RR、SCHED_DEADLINE。
SCHED_FIFO先入先出策略，按照优先级排列进程；SCHED_RR 轮流调度策略，按照完成顺序不断把任务添加到队尾，让渡任务给队首；SCHED_DEADLINE 按照任务的deadline策略。

- 2.普通调度策略：SCHED_NORMAL，SCHED_BATCH，SCHED_IDLE
SCHED_NORMAL 普通进程调度策略，SCHED_BATCH后台进程策略，SCHED_IDLE 只有特别空闲才会跑策略。

而这里面所有的策略都是由task_struct结构体下面这个属性负责的：
```cpp
const struct sched_class *sched_class;
```
而这个class分为如下几种：
- 1.stop_sched_class 优先级最高的策略，会中断其他进程
- 2.dl_sched_class deadline 策略
- 3.rt_sched_class 根据rt算法或者FIFO策略
- 4.fair_sched_class 依据公平算法cfs的普通进程调度策略
- 5.idle_sched_class 空闲进程的调度策略

简单聊一下公平算法cfs：
公平算法根据每一个普通进程的vruntime，找到最小vruntime从红黑树移除出来运行，最后又放回红黑树中，算法如下：
> 虚拟运行时间 vruntime += 实际运行时间 delta_exec * NICE_0_LOAD/ 权重
这样根据实际运行时间，实际运行时间短的分配权重高，长的权重少，这样就变相公平。

每个进程当设置了不同的调度策略将会挂载到不同的进度策略类别队列中。当调用了__scheme方法之后，就会调用pick_next_task，这个时候按照如下图所示的，按照顺序遍历整个调度策略的链表，如下图：
![进程调度.jpeg](/images/进程调度.jpeg)

当有了这些基础知识之后，我们就能很简单的理解整个SF了。SF被设置为SP_FOREGROUND，设置为前台进程，加入到前台进程组中。接着SCHED_FIFO优先级策略。这样就能保证SF在较高优先级下，运行进程，同时保证只要每一次遍历进程调度类的时候，必定会先让渡给SF，接着让渡给我们App应用。


## SurfaceFlinger的初始化
在看进程初始化之前，我们先来看看SurfaceFlinger的UML图。
![SurfaceFlinger UML.png](/images/SurfaceFlinger_UML.png)

能看到整个SF体系基础关系还是比较复杂。我们把目光放在最为关键的两个类：
- 1.ISurfaceComposer 所用面向SF之外进程的Binder操作回调，而这里面我挑选比较重要几个回调放在UML图中，记住他们之后分析会遇到。
- 2.HWC2::ComposerCallback 这是面向底层硬件的回调，这个Callback中包含了三个很关键的回调：
- 1.Hotplug 显示屏的热插拔通知上层SF进程
- 2.Refresh 底层硬件通知上层SF进程 HWC的刷新
- 3.Vsync 底层通知上层SF 进程 同步信号来了

有了这两个大的回调机制，SF就能通过这两者分别和硬件层以及App进程进行通信，这样SF的初步桥梁才形成了。

有了初步的印象之后，我们进一步的去看看，SF的构造函数：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)
```cpp
SurfaceFlinger::SurfaceFlinger(SurfaceFlinger::SkipInitializationTag)
      : BnSurfaceComposer(),
        mTransactionFlags(0),
        mTransactionPending(false),
        mAnimTransactionPending(false),
        mLayersRemoved(false),
        mLayersAdded(false),
        mRepaintEverything(0),
        mBootTime(systemTime()),
        mBuiltinDisplays(),
        mVisibleRegionsDirty(false),
        mGeometryInvalid(false),
        mAnimCompositionPending(false),
        mDebugRegion(0),
        mDebugDDMS(0),
        mDebugDisableHWC(0),
        mDebugDisableTransformHint(0),
        mDebugInSwapBuffers(0),
        mLastSwapBufferTime(0),
        mDebugInTransaction(0),
        mLastTransactionTime(0),
        mBootFinished(false),
        mForceFullDamage(false),
        mPrimaryDispSync("PrimaryDispSync"),
        mPrimaryHWVsyncEnabled(false),
        mHWVsyncAvailable(false),
        mHasPoweredOff(false),
        mNumLayers(0),
        mVrFlingerRequestsDisplay(false),
        mMainThreadId(std::this_thread::get_id()),
        mCreateBufferQueue(&BufferQueue::createBufferQueue),
        mCreateNativeWindowSurface(&impl::NativeWindowSurface::create) 
```
在这里面我们关注集合比较核心初始对象：
- 1.BnSurfaceComposer SurfaceFlinger的父类
- 2.mPrimaryDispSync 主要的信号同步处理器
- 3.BufferQueue 图元消费队列

```cpp
SurfaceFlinger::SurfaceFlinger() : SurfaceFlinger(SkipInitialization) {

    vsyncPhaseOffsetNs = getInt64< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::vsyncEventPhaseOffsetNs>(1000000);

    sfVsyncPhaseOffsetNs = getInt64< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::vsyncSfEventPhaseOffsetNs>(1000000);

    hasSyncFramework = getBool< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::hasSyncFramework>(true);

    dispSyncPresentTimeOffset = getInt64< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::presentTimeOffsetFromVSyncNs>(0);

    useHwcForRgbToYuv = getBool< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::useHwcForRGBtoYUV>(false);

    maxVirtualDisplaySize = getUInt64<ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::maxVirtualDisplaySize>(0);

    // Vr flinger is only enabled on Daydream ready devices.
    useVrFlinger = getBool< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::useVrFlinger>(false);

    maxFrameBufferAcquiredBuffers = getInt64< ISurfaceFlingerConfigs,
            &ISurfaceFlingerConfigs::maxFrameBufferAcquiredBuffers>(2);

    hasWideColorDisplay =
            getBool<ISurfaceFlingerConfigs, &ISurfaceFlingerConfigs::hasWideColorDisplay>(false);

    V1_1::DisplayOrientation primaryDisplayOrientation =
        getDisplayOrientation< V1_1::ISurfaceFlingerConfigs, &V1_1::ISurfaceFlingerConfigs::primaryDisplayOrientation>(
            V1_1::DisplayOrientation::ORIENTATION_0);

    switch (primaryDisplayOrientation) {
        case V1_1::DisplayOrientation::ORIENTATION_90:
            mPrimaryDisplayOrientation = DisplayState::eOrientation90;
            break;
        case V1_1::DisplayOrientation::ORIENTATION_180:
            mPrimaryDisplayOrientation = DisplayState::eOrientation180;
            break;
        case V1_1::DisplayOrientation::ORIENTATION_270:
            mPrimaryDisplayOrientation = DisplayState::eOrientation270;
            break;
        default:
            mPrimaryDisplayOrientation = DisplayState::eOrientationDefault;
            break;
    }
...
    mPrimaryDispSync.init(SurfaceFlinger::hasSyncFramework, SurfaceFlinger::dispSyncPresentTimeOffset);

    // debugging stuff...
    char value[PROPERTY_VALUE_MAX];

...

    property_get("debug.sf.enable_hwc_vds", value, "0");
    mUseHwcVirtualDisplays = atoi(value);


    property_get("ro.sf.disable_triple_buffer", value, "1");
    mLayerTripleBufferingDisabled = atoi(value);


    const size_t defaultListSize = MAX_LAYERS;
    auto listSize = property_get_int32("debug.sf.max_igbp_list_size", int32_t(defaultListSize));
    mMaxGraphicBufferProducerListSize = (listSize > 0) ? size_t(listSize) : defaultListSize;

    property_get("debug.sf.early_phase_offset_ns", value, "0");
    const int earlyWakeupOffsetOffsetNs = atoi(value);

    mVsyncModulator.setPhaseOffsets(sfVsyncPhaseOffsetNs - earlyWakeupOffsetOffsetNs,
            sfVsyncPhaseOffsetNs);

....
}
```
SF构造函数初始化做了如下几件事情：
- 1.初始化了vsyncPhaseOffsetNs，sfVsyncPhaseOffsetNs两个相位差，分别是指app的以及sf的相位差。关于相位差的基本概念在第一节有和大家聊过，等到专门专题和大家聊聊
- 2.设置SF的渲染方向，是哪一个角度。
- 3.mPrimaryDispSync 主显示屏信号同步器初始化
- 4.根据Android的全局配置，判断是否需要打开三重缓冲，HWC合成机制


### PrimaryDispSync init
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DispSync.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DispSync.cpp)
```cpp
void DispSync::init(bool hasSyncFramework, int64_t dispSyncPresentTimeOffset) {
    mIgnorePresentFences = !hasSyncFramework;
    mPresentTimeOffset = dispSyncPresentTimeOffset;
    mThread->run("DispSync", PRIORITY_URGENT_DISPLAY + PRIORITY_MORE_FAVORABLE);

    // set DispSync to SCHED_FIFO to minimize jitter
    struct sched_param param = {0};
    param.sched_priority = 2;
    if (sched_setscheduler(mThread->getTid(), SCHED_FIFO, &param) != 0) {
        ALOGE("Couldn't set SCHED_FIFO for DispSyncThread");
    }

    reset();
    beginResync();

    if (kTraceDetailedInfo) {
        if (!mIgnorePresentFences && kEnableZeroPhaseTracer) {
            mZeroPhaseTracer = std::make_unique<ZeroPhaseTracer>();
            addEventListener("ZeroPhaseTracer", 0, mZeroPhaseTracer.get());
        }
    }
}
```
在这个过程中初始化了DispSyncThread这个线程并且运行起来，并且初始化一些简单的数据。同时设置这个线程调度的优先类为FIFO。注意在Linux内核中，根本不会关心Thread和Process这两者区别，对于内核来说都是task_struct(任务)，区别仅仅只是初始化Thread的时候，会调用clone系统调用，并且把父亲任务指向进程，并且指向进程中所有的堆栈达到共享数据的目的。

这样就保证了相位计算的有限度十分高。我们对这个类有个总体的印象即可。


### SurfaceFlinger onFirstRef
从main函数还能看到，SF实际上是一个智能指针。sp强引用指针。这种指针在初始化的时候对应类型的构造函数的时候，会调用onFirstRef方法，进一步实例化内部需要的对象。
```cpp
void SurfaceFlinger::onFirstRef()
{
    mEventQueue->init(this);
}

```
这个方法调用了mEventQueue的init方法。而这个对象就是如下一个线程安全的MessageQueue对象。
```cpp
mutable std::unique_ptr<MessageQueue> mEventQueue{std::make_unique<impl::MessageQueue>()};
```

而在SF中的这个MessageQueue其实和Android 应用层开发的MessageQueue设计十分相似，只是有的角色做的事情稍微有点不同。

SurfaceFlinger的MessageQueue机制的角色:
- 1.MessageQueue 同样作为消息队列向外暴露操作接口，并不像应用层的MessageQueue一样作为Message链表的队列缓存，而是提供了相应的发送消息的接口以及等待消息方法。

- 2.native的Looper 是整个MessageQueue真正的核心，以epoll_event为核心，event_fd为辅助构建了一套快速的消息回调机制。

- 3.native的Handler 则是实现handleMessage方法，当Looper回调时候，将会调用Handler中handleMessage方法处理回调函数。

为了加深印象，我这里放出Android应用层MessageQueue和Looper的对应关系来和SF中MessageQueue设计的比较

![Looper设计图.png](/images/Looper设计图.png)


#### MessageQueue init
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/MessageQueue.cpp)

```cpp
void MessageQueue::init(const sp<SurfaceFlinger>& flinger) {
    mFlinger = flinger;
    mLooper = new Looper(true);
    mHandler = new Handler(*this);
}
```
能看到在MessageQueue中实例化了Looper和Handler。Looper其实和之前我将的Looper的原理一致，关键看看其回调函数：
```cpp
void MessageQueue::Handler::handleMessage(const Message& message) {
    switch (message.what) {
        case INVALIDATE:
            android_atomic_and(~eventMaskInvalidate, &mEventMask);
            mQueue.mFlinger->onMessageReceived(message.what);
            break;
        case REFRESH:
            android_atomic_and(~eventMaskRefresh, &mEventMask);
            mQueue.mFlinger->onMessageReceived(message.what);
            break;
    }
}
```
能看到注册了两种不同的图元刷新监听，一个是invalidate局部刷新，一个是refresh重新刷新。最后都会回调到SF的onMessageReceived中。换句话说，每当我们需要图元刷新的时候，就会通过mEventQueue的post方法，把数据异步加载到Handler中进行刷新。

了解到这一点之后，就暂时足够了，我们继续往下阅读在main方法中的SF的init方法。


### SurfaceFlinger init
```cpp
void SurfaceFlinger::init() {

    Mutex::Autolock _l(mStateLock);

    // start the EventThread
    mEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync, SurfaceFlinger::vsyncPhaseOffsetNs,
                                             true, "app");
    mEventThread = std::make_unique<impl::EventThread>(mEventThreadSource.get(),
                                                       [this]() { resyncWithRateLimit(); },
                                                       impl::EventThread::InterceptVSyncsCallback(),
                                                       "appEventThread");
    mSfEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync,
                                             SurfaceFlinger::sfVsyncPhaseOffsetNs, true, "sf");

    mSFEventThread =
            std::make_unique<impl::EventThread>(mSfEventThreadSource.get(),
                                                [this]() { resyncWithRateLimit(); },
                                                [this](nsecs_t timestamp) {
                                                    mInterceptor->saveVSyncEvent(timestamp);
                                                },
                                                "sfEventThread");
    mEventQueue->setEventThread(mSFEventThread.get());
    mVsyncModulator.setEventThread(mSFEventThread.get());

    // Get a RenderEngine for the given display / config (can't fail)
    getBE().mRenderEngine =
            RE::impl::RenderEngine::create(HAL_PIXEL_FORMAT_RGBA_8888,
                                           hasWideColorDisplay
                                                   ? RE::RenderEngine::WIDE_COLOR_SUPPORT
                                                   : 0);

    getBE().mHwc.reset(
            new HWComposer(std::make_unique<Hwc2::impl::Composer>(getBE().mHwcServiceName)));
    getBE().mHwc->registerCallback(this, getBE().mComposerSequenceId);
    // 该方法第一次进来无效，这是SF重启发现有屏幕插进来，一般不会走进来
    processDisplayHotplugEventsLocked();


    //第一次进来还没有链接进来的Display的Binder对象，跳过
    getDefaultDisplayDeviceLocked()->makeCurrent();

//打开vr功能相关模块
...

    mEventControlThread = std::make_unique<impl::EventControlThread>(
            [this](bool enabled) { setVsyncEnabled(HWC_DISPLAY_PRIMARY, enabled); });

    // initialize our drawing state
    mDrawingState = mCurrentState;

    // set initial conditions (e.g. unblank default device)
    initializeDisplays();

    getBE().mRenderEngine->primeCache();

    // Inform native graphics APIs whether the present timestamp is supported:
    if (getHwComposer().hasCapability(
            HWC2::Capability::PresentFenceIsNotReliable)) {
        mStartPropertySetThread = new StartPropertySetThread(false);
    } else {
        mStartPropertySetThread = new StartPropertySetThread(true);
    }

    if (mStartPropertySetThread->Start() != NO_ERROR) {
 ...
    }

    mLegacySrgbSaturationMatrix = getBE().mHwc->getDataspaceSaturationMatrix(HWC_DISPLAY_PRIMARY,
            Dataspace::SRGB_LINEAR);

}
```

在init过程中初始化不少重要的对象：
- 1.DispSyncSource 的初始化
- 2.EventThread 的初始化
- 3.EventQueue 监听初始化
- 4.渲染引擎的初始化
- 5.初始化HWComposer
- 6.EventControlThread初始化
- 7.初始化和链接DisplayService

我们展示不需要过多的深入的理解每一个类是怎么做怎么实现的，我之后会慢慢和大家聊聊。


#### DispSyncSource 和EventThread的初始化
一般都会把这两者放在一起聊。我们把初始化堪称两部分，一部分是app的EventThread，一部分是SF的EventThread。


##### app的EventThread
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[EventThread.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/EventThread.cpp)

```cpp
    mEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync, SurfaceFlinger::vsyncPhaseOffsetNs,
                                             true, "app");
    mEventThread = std::make_unique<impl::EventThread>(mEventThreadSource.get(),
                                                       [this]() { resyncWithRateLimit(); },
                                                       impl::EventThread::InterceptVSyncsCallback(),
                                                       "appEventThread");
```


能看到实际上mEventThread本质上就是一个DisSyncSource对象，我们看看他的构造函数：
```cpp
class DispSyncSource final : public VSyncSource, private DispSync::Callback {
public:
    DispSyncSource(DispSync* dispSync, nsecs_t phaseOffset, bool traceVsync,
        const char* name) :
            mName(name),
            mValue(0),
            mTraceVsync(traceVsync),
            mVsyncOnLabel(String8::format("VsyncOn-%s", name)),
            mVsyncEventLabel(String8::format("VSYNC-%s", name)),
            mDispSync(dispSync),
            mCallbackMutex(),
            mVsyncMutex(),
            mPhaseOffset(phaseOffset),
            mEnabled(false) {}

    ~DispSyncSource() override = default;
...
}
```
在这个中设置两个关键参数，一个是上面初始化好的DispSync显示同步信号，一个是app的DispSyncSource相位差，这个相位差就是1000000。

接着初始化EventThread，把app的DispSyncSource作为参数,进行实例化
```cpp
EventThread::EventThread(VSyncSource* src, ResyncWithRateLimitCallback resyncWithRateLimitCallback,
                         InterceptVSyncsCallback interceptVSyncsCallback, const char* threadName)
      : mVSyncSource(src),
        mResyncWithRateLimitCallback(resyncWithRateLimitCallback),
        mInterceptVSyncsCallback(interceptVSyncsCallback) {
    for (auto& event : mVSyncEvent) {
        event.header.type = DisplayEventReceiver::DISPLAY_EVENT_VSYNC;
        event.header.id = 0;
        event.header.timestamp = 0;
        event.vsync.count = 0;
    }

    mThread = std::thread(&EventThread::threadMain, this);

    pthread_setname_np(mThread.native_handle(), threadName);

    pid_t tid = pthread_gettid_np(mThread.native_handle());

    // Use SCHED_FIFO to minimize jitter
    constexpr int EVENT_THREAD_PRIORITY = 2;
    struct sched_param param = {0};
    param.sched_priority = EVENT_THREAD_PRIORITY;
    if (pthread_setschedparam(mThread.native_handle(), SCHED_FIFO, &param) != 0) {
        ALOGE("Couldn't set SCHED_FIFO for EventThread");
    }

    set_sched_policy(tid, SP_FOREGROUND);
}
```
能够看到在这个过程中做的事情和DispSync的方法很相似。首先实例化一个内部线程，并且设置这个线程的启动后的方法，以及设置该线程为FIFO策略并且设置为前台线程，使用更高的优先级Task。

```cpp
void EventThread::threadMain() NO_THREAD_SAFETY_ANALYSIS {
    std::unique_lock<std::mutex> lock(mMutex);
    while (mKeepRunning) {
        DisplayEventReceiver::Event event;
        Vector<sp<EventThread::Connection> > signalConnections;
        signalConnections = waitForEventLocked(&lock, &event);

        // dispatch events to listeners...
        const size_t count = signalConnections.size();
        for (size_t i = 0; i < count; i++) {
            const sp<Connection>& conn(signalConnections[i]);
            // now see if we still need to report this event
            status_t err = conn->postEvent(event);
            if (err == -EAGAIN || err == -EWOULDBLOCK) {
                // The destination doesn't accept events anymore, it's probably
                // full. For now, we just drop the events on the floor.
                // FIXME: Note that some events cannot be dropped and would have
                // to be re-sent later.
                // Right-now we don't have the ability to do this.
                ALOGW("EventThread: dropping event (%08x) for connection %p", event.header.type,
                      conn.get());
            } else if (err < 0) {
                // handle any other error on the pipe as fatal. the only
                // reasonable thing to do is to clean-up this connection.
                // The most common error we'll get here is -EPIPE.
                removeDisplayEventConnectionLocked(signalConnections[i]);
            }
        }
    }
}
```
能看到在这个过程中，会通过waitForEventLocked阻塞等待外部链接进来的EventThread的Connection，链接进来。一般是应用程序注册了Choreographer之后，就会注册DisplayEventReceiver，此时会对应DisplayEventReceiverDispatch一个Looper的callback，同时会通过Binder把当前为当前对象注册一个COnnect给SF进程的EventThread。当唤醒之后，经过检测将会调用postEvent把同步信号同步给App应用。

在waitForEventLocked等待循环的过程中，每一次同步信号的发出都会调用构造函数进来的回调interceptVSyncsCallback，也就是：
```cpp
resyncWithRateLimit();
```
同时会根据条件判断，当前是否打开同步信号。

有初步的概念即可，之后有专门的文章专门聊聊。


#### sf的EventThread初始化
```cpp
    mSfEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync,
                                             SurfaceFlinger::sfVsyncPhaseOffsetNs, true, "sf");

    mSFEventThread =
            std::make_unique<impl::EventThread>(mSfEventThreadSource.get(),
                                                [this]() { resyncWithRateLimit(); },
                                                [this](nsecs_t timestamp) {
                                                    mInterceptor->saveVSyncEvent(timestamp);
                                                },
                                                "sfEventThread");
    mEventQueue->setEventThread(mSFEventThread.get());
    mVsyncModulator.setEventThread(mSFEventThread.get());
```
同理有着极其相似的逻辑，不过sf的EventThread监听的是本进程的，其先去看看mEventQueue这个SF中的MessageQueue的setEventThread方法

##### MessageQueue setEventThread
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/MessageQueue.cpp)

```cpp
void MessageQueue::setEventThread(android::EventThread* eventThread) {
    if (mEventThread == eventThread) {
        return;
    }

    if (mEventTube.getFd() >= 0) {
        mLooper->removeFd(mEventTube.getFd());
    }

    mEventThread = eventThread;
    mEvents = eventThread->createEventConnection();
    mEvents->stealReceiveChannel(&mEventTube);
    mLooper->addFd(mEventTube.getFd(), 0, Looper::EVENT_INPUT, MessageQueue::cb_eventReceiver,
                   this);
}
```

在这个过程中能看到和App应用极其相似的逻辑。首先通过eventThread的createEventConnection创建一个Connection，是的EventThread可以从waitForEventLocked能够监听到这个链接。
```cpp
sp<BnDisplayEventConnection> EventThread::createEventConnection() const {
    return new Connection(const_cast<EventThread*>(this));
}
```

```cpp
EventThread::Connection::Connection(EventThread* eventThread)
      : count(-1), mEventThread(eventThread), mChannel(gui::BitTube::DefaultSize) {}

EventThread::Connection::~Connection() {
    // do nothing here -- clean-up will happen automatically
    // when the main thread wakes up
}

void EventThread::Connection::onFirstRef() {
    // NOTE: mEventThread doesn't hold a strong reference on us
    mEventThread->registerDisplayEventConnection(this);
}
```
初始化了一个BitTube对象，以及把当前的Connection注册到EventThread中，让waitForEvent可以监听到新的监听进来了。BitTube是什么呢？


##### BitTube
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[BitTube.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/BitTube.cpp)

它本质上就是一个封装过的socketpair。socketpair是什么？解释一下就类似于管道，一对可以互相通信的socket.可以从1号写入，0号读取。也可以从0号写入，1号读取。是一个全双工的通道。
```cpp
static const size_t DEFAULT_SOCKET_BUFFER_SIZE = 4 * 1024;


BitTube::BitTube(size_t bufsize) {
    init(bufsize, bufsize);
}

BitTube::BitTube(DefaultSizeType) : BitTube(DEFAULT_SOCKET_BUFFER_SIZE) {}

void BitTube::init(size_t rcvbuf, size_t sndbuf) {
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets) == 0) {
        size_t size = DEFAULT_SOCKET_BUFFER_SIZE;
        setsockopt(sockets[0], SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        setsockopt(sockets[1], SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        // sine we don't use the "return channel", we keep it small...
        setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
        setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
        fcntl(sockets[0], F_SETFL, O_NONBLOCK);
        fcntl(sockets[1], F_SETFL, O_NONBLOCK);
        mReceiveFd = sockets[0];
        mSendFd = sockets[1];
    } else {
        mReceiveFd = -errno;
        ALOGE("BitTube: pipe creation failed (%s)", strerror(-mReceiveFd));
    }
}
```

在BitTube中设定了0是接受，1是写入。其实就和管道一致。



接着调用EventThread::Connection的stealReceiveChannel：
```cpp
status_t EventThread::Connection::stealReceiveChannel(gui::BitTube* outChannel) {
    outChannel->setReceiveFd(mChannel.moveReceiveFd());
    return NO_ERROR;
}
int BitTube::getFd() const {
    return mReceiveFd;
}

```
此时将会设置一个直接的接受的fd为公开，然后Looper将会注册这个接受端是否有数据从发送端到来。

当waitForEvent接触等待后，将会调用Connection的postEvent方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[EventThread.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/EventThread.cpp)
```cpp
status_t EventThread::Connection::postEvent(const DisplayEventReceiver::Event& event) {
    ssize_t size = DisplayEventReceiver::sendEvents(&mChannel, &event, 1);
    return size < 0 ? status_t(size) : status_t(NO_ERROR);
}
```
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[DisplayEventReceiver.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/DisplayEventReceiver.cpp)
```cpp
ssize_t DisplayEventReceiver::sendEvents(gui::BitTube* dataChannel,
        Event const* events, size_t count)
{
    return gui::BitTube::sendObjects(dataChannel, events, count);
}
```
这样就完成了从发送端到接收端的过程监听。把监听事件丢给epoll处理。当有数据唤醒时候就会进入到MessageQueue的回调中.

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/MessageQueue.cpp)
```cpp
int MessageQueue::cb_eventReceiver(int fd, int events, void* data) {
    MessageQueue* queue = reinterpret_cast<MessageQueue*>(data);
    return queue->eventReceiver(fd, events);
}

int MessageQueue::eventReceiver(int /*fd*/, int /*events*/) {
    ssize_t n;
    DisplayEventReceiver::Event buffer[8];
    while ((n = DisplayEventReceiver::getEvents(&mEventTube, buffer, 8)) > 0) {
        for (int i = 0; i < n; i++) {
            if (buffer[i].header.type == DisplayEventReceiver::DISPLAY_EVENT_VSYNC) {
                mHandler->dispatchInvalidate();
                break;
            }
        }
    }
    return 1;
}
```
此时MessageQueue就会调用Handler中的dispatchInvalidate，也就调用到了SF的onMessageReceived中的布局刷新回调。

#### 渲染引擎的初始化
```cpp
    getBE().mRenderEngine =
            RE::impl::RenderEngine::create(HAL_PIXEL_FORMAT_RGBA_8888,
                                           hasWideColorDisplay
                                                   ? RE::RenderEngine::WIDE_COLOR_SUPPORT
                                                   : 0);
```
在SF中有一个SurfaceFlingerBE对象会一起初始化。将会一个RenderEngine创建给SurfaceFlingerBE。实际上SurfaceFlingerBE可以看做是SF的影子，它控制着所有硬件那一块的接口。而SF则是对应上整个Android系统的刷新机制。

```cpp
std::unique_ptr<RenderEngine> RenderEngine::create(int hwcFormat, uint32_t featureFlags) {
    // initialize EGL for the default display
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!eglInitialize(display, nullptr, nullptr)) {
        LOG_ALWAYS_FATAL("failed to initialize EGL");
    }

    GLExtensions& extensions = GLExtensions::getInstance();
    extensions.initWithEGLStrings(eglQueryStringImplementationANDROID(display, EGL_VERSION),
                                  eglQueryStringImplementationANDROID(display, EGL_EXTENSIONS));

    // The code assumes that ES2 or later is available if this extension is
    // supported.
    EGLConfig config = EGL_NO_CONFIG;
    if (!extensions.hasNoConfigContext()) {
        config = chooseEglConfig(display, hwcFormat, /*logConfig*/ true);
    }

    EGLint renderableType = 0;
    if (config == EGL_NO_CONFIG) {
        renderableType = EGL_OPENGL_ES2_BIT;
    } else if (!eglGetConfigAttrib(display, config, EGL_RENDERABLE_TYPE, &renderableType)) {
        LOG_ALWAYS_FATAL("can't query EGLConfig RENDERABLE_TYPE");
    }
    EGLint contextClientVersion = 0;
    if (renderableType & EGL_OPENGL_ES2_BIT) {
        contextClientVersion = 2;
    } else if (renderableType & EGL_OPENGL_ES_BIT) {
        contextClientVersion = 1;
    } else {
        LOG_ALWAYS_FATAL("no supported EGL_RENDERABLE_TYPEs");
    }

    std::vector<EGLint> contextAttributes;
    contextAttributes.reserve(6);
    contextAttributes.push_back(EGL_CONTEXT_CLIENT_VERSION);
    contextAttributes.push_back(contextClientVersion);
    bool useContextPriority = overrideUseContextPriorityFromConfig(extensions.hasContextPriority());
    if (useContextPriority) {
        contextAttributes.push_back(EGL_CONTEXT_PRIORITY_LEVEL_IMG);
        contextAttributes.push_back(EGL_CONTEXT_PRIORITY_HIGH_IMG);
    }
    contextAttributes.push_back(EGL_NONE);

    EGLContext ctxt = eglCreateContext(display, config, nullptr, contextAttributes.data());

    // if can't create a GL context, we can only abort.
    LOG_ALWAYS_FATAL_IF(ctxt == EGL_NO_CONTEXT, "EGLContext creation failed");

    // now figure out what version of GL did we actually get
    // NOTE: a dummy surface is not needed if KHR_create_context is supported

    EGLConfig dummyConfig = config;
    if (dummyConfig == EGL_NO_CONFIG) {
        dummyConfig = chooseEglConfig(display, hwcFormat, /*logConfig*/ true);
    }
    EGLint attribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE, EGL_NONE};
    EGLSurface dummy = eglCreatePbufferSurface(display, dummyConfig, attribs);
    LOG_ALWAYS_FATAL_IF(dummy == EGL_NO_SURFACE, "can't create dummy pbuffer");
    EGLBoolean success = eglMakeCurrent(display, dummy, dummy, ctxt);
    LOG_ALWAYS_FATAL_IF(!success, "can't make dummy pbuffer current");

    extensions.initWithGLStrings(glGetString(GL_VENDOR), glGetString(GL_RENDERER),
                                 glGetString(GL_VERSION), glGetString(GL_EXTENSIONS));

    GlesVersion version = parseGlesVersion(extensions.getVersion());

    // initialize the renderer while GL is current

    std::unique_ptr<RenderEngine> engine;
    switch (version) {
        case GLES_VERSION_1_0:
        case GLES_VERSION_1_1:
            LOG_ALWAYS_FATAL("SurfaceFlinger requires OpenGL ES 2.0 minimum to run.");
            break;
        case GLES_VERSION_2_0:
        case GLES_VERSION_3_0:
            engine = std::make_unique<GLES20RenderEngine>(featureFlags);
            break;
    }
    engine->setEGLHandles(display, config, ctxt);

....
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, dummy);
    return engine;
}
```

实际上这就是一个最经典的openGL es的初始化流程。它做了如下几个事情:
- 1.初始化EGLDisplay ，获得当前系统默认的显示屏对象
- 2.初始化EGL的版本
- 3.chooseEglConfig选择处理EGL的配置。这里的逻辑比较有意思，先通过eglGetConfigs查找可返回的EGL配置的数目，接着调用eglChooseConfig从所有配置项中得到最为推荐的配置数组，最后通过遍历查询，把系统中符合当前配置项中所有的配置都添加进来
- 4.eglCreateContext 初始化EGL上下文
- 5.设置GL版本号
- 6.eglCreatePbufferSurface创建一个dump的Surface，开辟一段可以缓存帧数据的空间，并用eglMakeCurrent把EGLDisplay和dump链接起来，其目的就是为了检查OpenGL es是否有问题。
- 6.setEGLHandles 设置EGLDisplay，上下文和配置为全局配置
- 7.eglMakeCurrent 把EGLDisplay设置为当前OpenGL es的环境，销毁dump这个Surface。

通过这里，我们完全看到一个工业级别的OpenGL es是如何初始化的。


#### HWComposer的初始化

这个对象十分十分的重要，它联通的硬件抽象层，硬件层和SF，作为绘制的核心类。可以看做为HardwareCompose硬件合成。也就是我们常说的HWC。
```cpp
    getBE().mHwc.reset(
            new HWComposer(std::make_unique<Hwc2::impl::Composer>(getBE().mHwcServiceName)));
    getBE().mHwc->registerCallback(this, getBE().mComposerSequenceId);
```

本文不会过于详细的解析HWC是如何联通硬件抽象层hal中。我们来简单的看看其中的逻辑。能看到HWComposer中传入一个Hwc2::impl::Composer对象，先看看这个对象:
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[ComposerHal.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/ComposerHal.cpp)
```cpp
Composer::Composer(const std::string& serviceName)
    : mWriter(kWriterInitialSize),
      mIsUsingVrComposer(serviceName == std::string("vr"))
{
    mComposer = V2_1::IComposer::getService(serviceName);

    mComposer->createClient(
            [&](const auto& tmpError, const auto& tmpClient)
            {
                if (tmpError == Error::NONE) {
                    mClient = tmpClient;
                }
            });
...

    // 2.2 support is optional
    sp<IComposer> composer_2_2 = IComposer::castFrom(mComposer);
    if (composer_2_2 != nullptr) {
        mClient_2_2 = IComposerClient::castFrom(mClient);
...
    }

    if (mIsUsingVrComposer) {
        sp<IVrComposerClient> vrClient = IVrComposerClient::castFrom(mClient);
....
    }
}
```
能看到Composer对象中又会持有一个mComposer对象。这个对象可以暂且理解类似为Binder，从抽象层(hal)服务端传送过来的IComposer接口对象。之后所有要和硬件层进行交互，只需要操作这个IComposer对象即可。接着调用IComposer的createClient创建开一个Client对象。如果里面有2.2版本的IComposer对象则会把2.1版本的IComposer转化过去。

这样软件层Composer就和硬件抽象层的Composer对应起来。等待HWComposer的操作。先暂时理解到这里，下一篇文章将会解析硬件抽象层是怎么来到软件层。接下来我会把硬件抽象层简称为hal层。

##### HWComposer的非hal层初始化与监听
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[HWComposer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWComposer.cpp)
```cpp
HWComposer::HWComposer(std::unique_ptr<android::Hwc2::Composer> composer)
      : mHwcDevice(std::make_unique<HWC2::Device>(std::move(composer))) {}
```
在这个结构中能看到HWComposer还会初始化一个HWC2::Device对象，这个设备对象才是真正操作hal层的对应的对象。HWC2::Device对象很简单，几乎没有逻辑就跳过。
```cpp
Device::Device(std::unique_ptr<android::Hwc2::Composer> composer) : mComposer(std::move(composer)) {
    loadCapabilities();
}

```

##### HWComposer的监听
```cpp
getBE().mHwc->registerCallback(this, getBE().mComposerSequenceId);
```
接下来会注册SF的监听到HWC中。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[HWComposer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWComposer.cpp)
```cpp
void HWComposer::registerCallback(HWC2::ComposerCallback* callback,
                                  int32_t sequenceId) {
    mHwcDevice->registerCallback(callback, sequenceId);
}
```
文件:[http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWC2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWC2.cpp)

```cpp
void Device::registerCallback(ComposerCallback* callback, int32_t sequenceId) {
    if (mRegisteredCallback) {
        ALOGW("Callback already registered. Ignored extra registration "
                "attempt.");
        return;
    }
    mRegisteredCallback = true;
    sp<ComposerCallbackBridge> callbackBridge(
            new ComposerCallbackBridge(callback, sequenceId));
    mComposer->registerCallback(callbackBridge);
}
```

能看到HWC将会借助一个ComposerCallbackBridge对象把对象注册到hal层中进行监听，这个对象的思路其实和ServiceDispatcher，ReceiverDispatcher十分相似，也是本身回调无法传入Binder，这里是进入hal层，转而使用一个包裹的可以传入底层协议的hal对象进行回调。

```cpp
class ComposerCallbackBridge : public Hwc2::IComposerCallback {
public:
    ComposerCallbackBridge(ComposerCallback* callback, int32_t sequenceId)
            : mCallback(callback), mSequenceId(sequenceId) {}

    Return<void> onHotplug(Hwc2::Display display,
                           IComposerCallback::Connection conn) override
    {
        HWC2::Connection connection = static_cast<HWC2::Connection>(conn);
        mCallback->onHotplugReceived(mSequenceId, display, connection);
        return Void();
    }

    Return<void> onRefresh(Hwc2::Display display) override
    {
        mCallback->onRefreshReceived(mSequenceId, display);
        return Void();
    }

    Return<void> onVsync(Hwc2::Display display, int64_t timestamp) override
    {
        mCallback->onVsyncReceived(mSequenceId, display, timestamp);
        return Void();
    }

private:
    ComposerCallback* mCallback;
    int32_t mSequenceId;
};
```
能看到很简单的思路，每当hal层发生回调的时候，如刷新请求等时候，就会调用callback对应的onRefreshReceived，onVsyncReceived，onHotplugReceived三个方法。还记得最上面的SF的UML图吗？SF实际上实现了ComposerCallback。也就是说，此时SF就通过了ComposerBridge联通了hal层。

这样就能做到从hal通知到软件层。


#### EventControlThread的初始化
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[EventControlThread.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/EventControlThread.cpp)

```cpp
EventControlThread::EventControlThread(EventControlThread::SetVSyncEnabledFunction function)
      : mSetVSyncEnabled(function) {
    pthread_setname_np(mThread.native_handle(), "EventControlThread");

    pid_t tid = pthread_gettid_np(mThread.native_handle());
    setpriority(PRIO_PROCESS, tid, ANDROID_PRIORITY_URGENT_DISPLAY);
    set_sched_policy(tid, SP_FOREGROUND);
}

void EventControlThread::threadMain() NO_THREAD_SAFETY_ANALYSIS {
    auto keepRunning = true;
    auto currentVsyncEnabled = false;

    while (keepRunning) {
        mSetVSyncEnabled(currentVsyncEnabled);

        std::unique_lock<std::mutex> lock(mMutex);
        mCondition.wait(lock, [this, currentVsyncEnabled, keepRunning]() NO_THREAD_SAFETY_ANALYSIS {
            return currentVsyncEnabled != mVsyncEnabled || keepRunning != mKeepRunning;
        });
        currentVsyncEnabled = mVsyncEnabled;
        keepRunning = mKeepRunning;
    }
}
```
能看到EventControlThread其实就是对整个HWC的EventThread的控制。因为mSetVSyncEnabled其实对应的是
```cpp
setVsyncEnabled(HWC_DISPLAY_PRIMARY, enabled);
```
不过简单很多，是因为它只对HWC负责。


#### initializeDisplays 准备初始化显示屏数据异步消息

```cpp
void SurfaceFlinger::initializeDisplays() {
    class MessageScreenInitialized : public MessageBase {
        SurfaceFlinger* flinger;
    public:
        explicit MessageScreenInitialized(SurfaceFlinger* flinger) : flinger(flinger) { }
        virtual bool handler() {
            flinger->onInitializeDisplays();
            return true;
        }
    };
    sp<MessageBase> msg = new MessageScreenInitialized(this);
    postMessageAsync(msg);  // we may be called from main thread, use async message
}
```
这种写法在底层十分常见，能直观的看到Handler的回调机制。
```cpp
status_t SurfaceFlinger::postMessageAsync(const sp<MessageBase>& msg,
        nsecs_t reltime, uint32_t /* flags */) {
    return mEventQueue->postMessage(msg, reltime);
}
```
可以看到在这里借助SF的异步机制调用到下一次Looper回来之后才会调用。还记得这个时候mEventQueue中的Looper仅仅只是初始化，还没循环阻塞起来进行监听吗？需要等到mEventQueue进行了Looper。因此这个时候不会立即进入Handler中进行回调。而是会继续下一个步骤。


#### SF 的 run
此时SF的init方法已经结束了。当经过startDisplayService的注册hal层的DisplayService方法之后，接着在main_surfaceflinger中会继续走surfaceFlinger的run方法。
```cpp
void SurfaceFlinger::run() {
    do {
        waitForEvent();
    } while (true);
}

void SurfaceFlinger::waitForEvent() {
    mEventQueue->waitMessage();
}
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/MessageQueue.cpp)

```cpp
void MessageQueue::waitMessage() {
    do {
        IPCThreadState::self()->flushCommands();
        int32_t ret = mLooper->pollOnce(-1);
        switch (ret) {
            case Looper::POLL_WAKE:
            case Looper::POLL_CALLBACK:
                continue;
            case Looper::POLL_ERROR:
                ALOGE("Looper::POLL_ERROR");
                continue;
            case Looper::POLL_TIMEOUT:
                // timeout (should not happen)
                continue;
            default:
                // should not happen
                ALOGE("Looper::pollOnce() returned unknown status %d", ret);
                continue;
        }
    } while (true);
}
```
进入这个死循环之后，会处理一下Binder过来的消息，接着通过epoll等待有人唤醒epoll。


### SF 初始化显示屏模块
有想过，为什么SF要这么做吗？为什么在init的时候就提前把mEventQueue的消息循环起来？而是等到最后再run呢？其实其目的很简单，就是为了做一件事，就为了让注册到硬件层中ComposerCallback进行回调。等到回调之后再执行刚刚因为run起来而执行的异步消息。

下一篇文章，我将带领你们看看高通msm8996在hal层是如何实现回调。我们从常识推断，一个手机通电，屏幕驱动一定是最早那几个启动的常用服务(除了Linux内核这些之外)。因此当SF启动之后，在底层一定会准备好一个通知，一旦SF注册了监听一定会回调。还记得ComposerCallbackBridge中回调，实际上应对上的是SF对应的，屏幕热插拔回调：onHotplugReceived。

```cpp
void SurfaceFlinger::onHotplugReceived(int32_t sequenceId, hwc2_display_t display,
                                       HWC2::Connection connection) {
    ALOGV("onHotplugReceived(%d, %" PRIu64 ", %s)", sequenceId, display,
          connection == HWC2::Connection::Connected ? "connected" : "disconnected");

    // Ignore events that do not have the right sequenceId.
    if (sequenceId != getBE().mComposerSequenceId) {
        return;
    }

    ConditionalLock lock(mStateLock, std::this_thread::get_id() != mMainThreadId);

    mPendingHotplugEvents.emplace_back(HotplugEvent{display, connection});

    if (std::this_thread::get_id() == mMainThreadId) {
        // Process all pending hot plug events immediately if we are on the main thread.
        processDisplayHotplugEventsLocked();
    }

    setTransactionFlags(eDisplayTransactionNeeded);
}
```
从这一段代码段，能看到HWC2::Connection 代表当前的链接状态，而hwc2_display_t则是来自hal层的结构体，象征着屏幕。此时构建一个新的结构体压入mPendingHotplugEvents 集合中。等待SF消化这个集合中的数据

这里可能出现两个不同的线程一个是来自hwBinder(实际也是一个Binder驱动，只是专门负责和硬件交流罢了)，一个可能是来自自己线程。我们就默认是当前线程即可，就会执行processDisplayHotplugEventsLocked。

```cpp
void SurfaceFlinger::processDisplayHotplugEventsLocked() {
    for (const auto& event : mPendingHotplugEvents) {
        auto displayType = determineDisplayType(event.display, event.connection);
        if (displayType == DisplayDevice::DISPLAY_ID_INVALID) {
            continue;
        }

        if (getBE().mHwc->isUsingVrComposer() && displayType == DisplayDevice::DISPLAY_EXTERNAL) {
            continue;
        }

        getBE().mHwc->onHotplug(event.display, displayType, event.connection);

        if (event.connection == HWC2::Connection::Connected) {
            if (!mBuiltinDisplays[displayType].get()) {
                mBuiltinDisplays[displayType] = new BBinder();
                // All non-virtual displays are currently considered secure.
                DisplayDeviceState info(displayType, true);
                info.displayName = displayType == DisplayDevice::DISPLAY_PRIMARY ?
                        "Built-in Screen" : "External Screen";
                mCurrentState.displays.add(mBuiltinDisplays[displayType], info);
                mInterceptor->saveDisplayCreation(info);
            }
        } else {

            ssize_t idx = mCurrentState.displays.indexOfKey(mBuiltinDisplays[displayType]);
            if (idx >= 0) {
                const DisplayDeviceState& info(mCurrentState.displays.valueAt(idx));
                mInterceptor->saveDisplayDeletion(info.displayId);
                mCurrentState.displays.removeItemsAt(idx);
            }
            mBuiltinDisplays[displayType].clear();
        }

        processDisplayChangesLocked();
    }

    mPendingHotplugEvents.clear();
}
```
- 1.此时会调用mHwc->onHotplug主动通知HWComposer。

- 2.如果此时显示屏是告诉SF是插入了一个屏幕，则需要屏幕id作为index，为mBuiltinDisplays赋值一个BBinder，等待DisplayerManagerService的调用。并且保存当前的状态。把当前屏幕加入到mCurrentState的display

- 3.如果此时屏幕关闭或者拔出，则销毁当前mBuiltinDisplays对应index中屏幕的信息以及信息。

- 4.processDisplayChangesLocked 处理屏幕状态发生变化后的处理。

这里稍微提一句mBuiltinDisplays本质上就是一个大小为2数组。但是设定两个不同的类型：
- DISPLAY_PRIMARY 数值为0 是指主屏幕
- DISPLAY_EXTERNAL  数值为1 指额外屏幕


### HWComposer 主动处理onHotplug
```cpp
void HWComposer::onHotplug(hwc2_display_t displayId, int32_t displayType,
                           HWC2::Connection connection) {
    if (displayType >= HWC_NUM_PHYSICAL_DISPLAY_TYPES) {
        return;
    }

    mHwcDevice->onHotplug(displayId, connection);
    if (connection == HWC2::Connection::Connected) {
        mDisplayData[displayType].hwcDisplay = mHwcDevice->getDisplayById(displayId);
        mHwcDisplaySlots[displayId] = displayType;
    }
}
```
能看到实际上在这个过程中会把链接上的屏幕保存到mDisplayData和mHwcDisplaySlots两个数组中。不过核心还是把事情委托下层的mHwcDevice的事情。经过上面的阅读，本质上就是HWC::Device:
```cpp
void Device::onHotplug(hwc2_display_t displayId, Connection connection) {
    if (connection == Connection::Connected) {
        auto oldDisplay = getDisplayById(displayId);
        if (oldDisplay != nullptr && oldDisplay->isConnected()) {
            ALOGI("Hotplug connecting an already connected display."
                    " Clearing old display state.");
        }
        mDisplays.erase(displayId);

        DisplayType displayType;
        auto intError = mComposer->getDisplayType(displayId,
                reinterpret_cast<Hwc2::IComposerClient::DisplayType *>(
                        &displayType));
        auto error = static_cast<Error>(intError);
        if (error != Error::None) {
...
            return;
        }

        auto newDisplay = std::make_unique<Display>(
                *mComposer.get(), mCapabilities, displayId, displayType);
        newDisplay->setConnected(true);
        mDisplays.emplace(displayId, std::move(newDisplay));
    } else if (connection == Connection::Disconnected) {
        auto display = getDisplayById(displayId);
        if (display) {
            display->setConnected(false);
        } else {
            ...
        }
    }
}
```
其实这里面的逻辑很简单，就是记录下一个还没有链接过的屏幕，并且初始化为HWC::Display一个屏幕对象，并设置好状态。并且保存到mDisplays中。到这里就完成了从硬件层的硬件对象到软件层的映射。

从有限信息里面可以得知hwc2_display_t 会对应上一个HWC::Display对象。但是在hal层是不是真的这个对象呢？等到后面再来看。

#### processDisplayChangesLocked 尝试为屏幕分配图元Surface
```cpp
void SurfaceFlinger::processDisplayChangesLocked() {

    const KeyedVector<wp<IBinder>, DisplayDeviceState>& curr(mCurrentState.displays);
    const KeyedVector<wp<IBinder>, DisplayDeviceState>& draw(mDrawingState.displays);
    if (!curr.isIdenticalTo(draw)) {
        mVisibleRegionsDirty = true;
        const size_t cc = curr.size();
        size_t dc = draw.size();

        for (size_t i = 0; i < dc;) {
            const ssize_t j = curr.indexOfKey(draw.keyAt(i));
            if (j < 0) {
                const sp<const DisplayDevice> defaultDisplay(getDefaultDisplayDeviceLocked());
                if (defaultDisplay != nullptr) defaultDisplay->makeCurrent();
                sp<DisplayDevice> hw(getDisplayDeviceLocked(draw.keyAt(i)));
                if (hw != nullptr) hw->disconnect(getHwComposer());
                if (draw[i].type < DisplayDevice::NUM_BUILTIN_DISPLAY_TYPES)
                    mEventThread->onHotplugReceived(draw[i].type, false);
                mDisplays.removeItem(draw.keyAt(i));
            } else {
        ...
            ++i;
        }

        // find displays that were added
        // (ie: in current state but not in drawing state)
        for (size_t i = 0; i < cc; i++) {
            if (draw.indexOfKey(curr.keyAt(i)) < 0) {
                const DisplayDeviceState& state(curr[i]);

                sp<DisplaySurface> dispSurface;
                sp<IGraphicBufferProducer> producer;
                sp<IGraphicBufferProducer> bqProducer;
                sp<IGraphicBufferConsumer> bqConsumer;
                mCreateBufferQueue(&bqProducer, &bqConsumer, false);

                int32_t hwcId = -1;
                if (state.isVirtualDisplay()) {
                 ...
                } else {
                    hwcId = state.type;
                    dispSurface = new FramebufferSurface(*getBE().mHwc, hwcId, bqConsumer);
                    producer = bqProducer;
                }

                const wp<IBinder>& display(curr.keyAt(i));
                if (dispSurface != nullptr) {
                    mDisplays.add(display,
                                  setupNewDisplayDeviceInternal(display, hwcId, state, dispSurface,
                                                                producer));
                    if (!state.isVirtualDisplay()) {
                        mEventThread->onHotplugReceived(state.type, true);
                    }
                }
            }
        }
    }

    mDrawingState.displays = mCurrentState.displays;
}
```
这个方法很长，我省略了一部分，先关注剩下这部分符合第一次初始化进来的逻辑。

能看到在SF中有两个显示屏的State。一个是mCurrentState当前持有所有的显示屏数据的mCurrentState，换句话说SF当前的状态。另一个是mDrawingState，也就是SF需要绘制的状态。

SF每一次绘制只会绘制在mDrawingState中的屏幕和图元，而不是mCurrentState。但是每一次执行该方法的时候会为mDrawingState中的display设置为mCurrentState的display。

因此第一次回调的时候，一定不会在mDrawingState找到mCurrentState中的显示屏数据。先调用getDisplayDeviceLocked尝试设置默认屏幕也就是主屏幕为当前要绘制的屏幕。关闭其他屏幕。但是此时主屏幕都还没有初始化好，这段逻辑也就没用。

核心逻辑在遍历下面那个mCurrentState中。我们不去管虚拟屏幕，我们只关注接进来主屏幕。

在这个过程，出现一个十分重要的对象mCreateBufferQueue，这是就是我之前篇章聊到过图元队列，里面包含着生产者和消费者，最后赋值给FramebufferSurface。

换句话，当我们需要思考图元消费逻辑，就需要从FramebufferSurface开始探索。

最后要进行很核心的逻辑，把display对应的BBinder和通过setupNewDisplayDeviceInternal生产的DisplayService设置到mDisplays这个map缓存中。

如果，如果不是虚拟屏幕，此时将会进行调用EventThread的onHotplugReceived。这里不要弄混淆ComposerCallback一样的HotPlugin回调。这个是EventThread是发送vysnc，用于唤醒waitForEvent的阻塞：
```cpp
void EventThread::onHotplugReceived(int type, bool connected) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (type < DisplayDevice::NUM_BUILTIN_DISPLAY_TYPES) {
        DisplayEventReceiver::Event event;
        event.header.type = DisplayEventReceiver::DISPLAY_EVENT_HOTPLUG;
        event.header.id = type;
        event.header.timestamp = systemTime();
        event.hotplug.connected = connected;
        mPendingEvents.add(event);
        mCondition.notify_all();
    }
}
```
能看到此时会唤起阻塞住线程mCondition。具体做了什么，之后再聊。

#### setupNewDisplayDeviceInternal
```cpp
sp<DisplayDevice> SurfaceFlinger::setupNewDisplayDeviceInternal(
        const wp<IBinder>& display, int hwcId, const DisplayDeviceState& state,
        const sp<DisplaySurface>& dispSurface, const sp<IGraphicBufferProducer>& producer) {
    bool hasWideColorGamut = false;
    std::unordered_map<ColorMode, std::vector<RenderIntent>> hwcColorModes;

    if (hasWideColorDisplay) {
        std::vector<ColorMode> modes = getHwComposer().getColorModes(hwcId);
        for (ColorMode colorMode : modes) {
            switch (colorMode) {
                case ColorMode::DISPLAY_P3:
                case ColorMode::ADOBE_RGB:
                case ColorMode::DCI_P3:
                    hasWideColorGamut = true;
                    break;
                default:
                    break;
            }

            std::vector<RenderIntent> renderIntents = getHwComposer().getRenderIntents(hwcId,
                                                                                       colorMode);
            hwcColorModes.emplace(colorMode, renderIntents);
        }
    }

    HdrCapabilities hdrCapabilities;
    getHwComposer().getHdrCapabilities(hwcId, &hdrCapabilities);

    auto nativeWindowSurface = mCreateNativeWindowSurface(producer);
    auto nativeWindow = nativeWindowSurface->getNativeWindow();

    /*
     * Create our display's surface
     */
    std::unique_ptr<RE::Surface> renderSurface = getRenderEngine().createSurface();
    renderSurface->setCritical(state.type == DisplayDevice::DISPLAY_PRIMARY);
    renderSurface->setAsync(state.type >= DisplayDevice::DISPLAY_VIRTUAL);
    renderSurface->setNativeWindow(nativeWindow.get());
    const int displayWidth = renderSurface->queryWidth();
    const int displayHeight = renderSurface->queryHeight();
    if (state.type >= DisplayDevice::DISPLAY_VIRTUAL) {
        nativeWindow->setSwapInterval(nativeWindow.get(), 0);
    }

    // virtual displays are always considered enabled
    auto initialPowerMode = (state.type >= DisplayDevice::DISPLAY_VIRTUAL) ? HWC_POWER_MODE_NORMAL
                                                                           : HWC_POWER_MODE_OFF;

    sp<DisplayDevice> hw =
            new DisplayDevice(this, state.type, hwcId, state.isSecure, display, nativeWindow,
                              dispSurface, std::move(renderSurface), displayWidth, displayHeight,
                              hasWideColorGamut, hdrCapabilities,
                              getHwComposer().getSupportedPerFrameMetadata(hwcId),
                              hwcColorModes, initialPowerMode);

    if (maxFrameBufferAcquiredBuffers >= 3) {
        nativeWindowSurface->preallocateBuffers();
    }

    ColorMode defaultColorMode = ColorMode::NATIVE;
    Dataspace defaultDataSpace = Dataspace::UNKNOWN;
    if (hasWideColorGamut) {
        defaultColorMode = ColorMode::SRGB;
        defaultDataSpace = Dataspace::SRGB;
    }
    setActiveColorModeInternal(hw, defaultColorMode, defaultDataSpace,
                               RenderIntent::COLORIMETRIC);
    if (state.type < DisplayDevice::DISPLAY_VIRTUAL) {
        hw->setActiveConfig(getHwComposer().getActiveConfigIndex(state.type));
    }
    hw->setLayerStack(state.layerStack);
    hw->setProjection(state.orientation, state.viewport, state.frame);
    hw->setDisplayName(state.displayName);

    return hw;
}
```

 这里面的核心结构有两个，一个是通过图元生产者构建一个nativeWindow，同时让RenderEngine渲染引擎生成一个RE::Surface对象，并从RE::Surface获取宽高信息，layer栈，并全部收集到DisplayDevice。

数据结构有点乱，当我们需要找到一个屏幕的图元渲染Surface该怎么找呢？总结就是，先从mDisplays 通过displayID找到DisplayDevice，DisplayDevice能找到对应的nativeWindow，最后能找到E::Surface。

好了，关于显示屏数据结构已经准备好了，我们来看看在等待队列中消息做了什么？

#### onInitializeDisplays

```cpp
void SurfaceFlinger::onInitializeDisplays() {
    // reset screen orientation and use primary layer stack
    Vector<ComposerState> state;
    Vector<DisplayState> displays;
    DisplayState d;
    d.what = DisplayState::eDisplayProjectionChanged |
             DisplayState::eLayerStackChanged;
    d.token = mBuiltinDisplays[DisplayDevice::DISPLAY_PRIMARY];
    d.layerStack = 0;
    d.orientation = DisplayState::OrientationDefault;
    d.frame.makeInvalid();
    d.viewport.makeInvalid();
    d.width = 0;
    d.height = 0;
    displays.add(d);
    setTransactionState(state, displays, 0);
    setPowerModeInternal(getDisplayDevice(d.token), HWC_POWER_MODE_NORMAL,
                         /*stateLockHeld*/ false);

    const auto& activeConfig = getBE().mHwc->getActiveConfig(HWC_DISPLAY_PRIMARY);
    const nsecs_t period = activeConfig->getVsyncPeriod();
    mAnimFrameTracker.setDisplayRefreshPeriod(period);

    setCompositorTimingSnapped(0, period, 0);
}
```
在这里能看到其实就是收集主屏幕相关的信息，通过setTransactionState设置和调整mCurrentState中的display中属性的状态。这里因为篇幅原因，等到遇到再聊。


## 总结
本文详细的剖析了SF的hal层之上的SurfaceFlinger的初始化，让我们对SF有了一个整体的概括印象。明白每一个重要角色将会负担什么？
- 1. PrimaryDispSync EventThread MessageQueue组成了Vysnc同步信号的发放逻辑。

![EventThread.png](/images/EventThread.png)


- 2.SF 有一个SFBE作为面向硬件设备操作的对象。里面包含两个及其重要的角色HWComposer，以及RenderEngine。HWComposer里面包裹这和hal通信的媒介HWC::Device,同时HWComposer会把SF注册到hal层，等待硬件的回调。RenderEngine则是为渲染图元做出了画面承载体的准备，和准备了OpenGL es相关的环境。

用一副图对SF进行总结。
![SF初始化结构.png](/images/SF初始化结构.png)

记住这幅图，就对SF有了一个大体的印象，之后我们剖析整个SF的细节，将会从这个图的某一处进行学习和探索。

