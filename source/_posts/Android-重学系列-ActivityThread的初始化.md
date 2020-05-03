---
title: Android 重学系列 ActivityThread的初始化
top: false
cover: false
date: 2019-11-28 17:48:28
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
当我们了解了一个进程是怎么诞生的，一个Activity是怎么诞生的，那么在这两个中间必定会存在Application的创建，其实在前面的文章已经和大家提到过关于ActivityThread和Application的初始化，本文就带领大家来看看ActivityThread和Application是如何初始化，又是如何绑定的；应用自己的ClassLoader如何加载；资源R文件如何重载的；以及思考MultiDex的设计思路。

遇到问题可以来本文下讨论：[https://www.jianshu.com/p/2b1d43ffeba6](https://www.jianshu.com/p/2b1d43ffeba6)


# 正文

## 进程的初始化
让我么回顾一下，当时[Activity启动流程](https://www.jianshu.com/p/ac7b6a525b96)在一文中，startSpecificActivityLocked检测进程是否启动一小节，我当时忽略了当没有进程时候的情况，本次因为是ActivityThread的初始化，那么必定会先走startProcessLocked先初始化进程。
```java
        mService.startProcessLocked(r.processName, r.info.applicationInfo, true, 0,
                "activity", r.intent.getComponent(), false, false, true);
```
最后会走到下面这个方法。

文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)

```java
   @GuardedBy("this")
    final ProcessRecord startProcessLocked(String processName, ApplicationInfo info,
            boolean knownToBeDead, int intentFlags, String hostingType, ComponentName hostingName,
            boolean allowWhileBooting, boolean isolated, int isolatedUid, boolean keepIfLarge,
            String abiOverride, String entryPoint, String[] entryPointArgs, Runnable crashHandler) {
        long startTime = SystemClock.elapsedRealtime();
        ProcessRecord app;
        if (!isolated) {
            app = getProcessRecordLocked(processName, info.uid, keepIfLarge);
            checkTime(startTime, "startProcess: after getProcessRecord");

            if ((intentFlags & Intent.FLAG_FROM_BACKGROUND) != 0) {
              ...
            } else {
               
                mAppErrors.resetProcessCrashTimeLocked(info);
                if (mAppErrors.isBadProcessLocked(info)) {
                    ...
                    mAppErrors.clearBadProcessLocked(info);
                    if (app != null) {
                        app.bad = false;
                    }
                }
            }
        } else {
            ...
        }

        // We don't have to do anything more if:
        // (1) There is an existing application record; and
        // (2) The caller doesn't think it is dead, OR there is no thread
        //     object attached to it so we know it couldn't have crashed; and
        // (3) There is a pid assigned to it, so it is either starting or
        //     already running.
        if (app != null && app.pid > 0) {
            if ((!knownToBeDead && !app.killed) || app.thread == null) {
...
                app.addPackage(info.packageName, info.versionCode, mProcessStats);
...
                return app;
            }

            // An application record is attached to a previous process,
            // clean it up now.

            killProcessGroup(app.uid, app.pid);
            handleAppDiedLocked(app, true, true);
        }

        String hostingNameStr = hostingName != null
                ? hostingName.flattenToShortString() : null;

        if (app == null) {
            app = newProcessRecordLocked(info, processName, isolated, isolatedUid);
            if (app == null) {
...
                return null;
            }
            app.crashHandler = crashHandler;
            app.isolatedEntryPoint = entryPoint;
            app.isolatedEntryPointArgs = entryPointArgs;
        } else {
    
            app.addPackage(info.packageName, info.versionCode, mProcessStats);
        }

        if (!mProcessesReady
                && !isAllowedWhileBooting(info)
                && !allowWhileBooting) {
            if (!mProcessesOnHold.contains(app)) {
                mProcessesOnHold.add(app);
            }

            return app;
        }

        final boolean success = startProcessLocked(app, hostingType, hostingNameStr, abiOverride);
        return success ? app : null;
    }
```
执行启动进程的行为，有如下几种可能：
- 1.本身还没有就没有诞生进程。
- 2.已经诞生了，但是因为一些crash等问题,或者安装好了一样的进程需要重新启动进程。

因此会先通过getProcessRecordLocked获取对应的ProcessRecord。这个对象其实就是AMS中象征着进程的对象。这个对象会保存在一个SparseArray 中，因为刚好是以int型uid作为key存储。

如果找到ProcessRecord，说明已经诞生出来过了。因此为了让进程回归到初始状态，会清空内部的错误栈信息，接着重新从ApplicationInfo读取最新的进程对应的进程版本号等信息，接着杀掉进程组，handleAppDiedLocked处理App的死亡，主要是清空TaskRecord，记录在ActivityStackSupervisor中所有的活跃Activity，销毁对应进程WMS中的Surface。

如果没有找到对应ProcessRecord，则调用newProcessRecordLocked创建一个新的进程对象，并把当前ProcessRecord添加到类型为SparseArray的mProcessMap。

接下来核心是另一个重载函数startProcessLocked。

#### AMS.startProcessLocked
```java
    private final boolean startProcessLocked(ProcessRecord app, String hostingType,
            String hostingNameStr, boolean disableHiddenApiChecks, String abiOverride) {
        if (app.pendingStart) {
            return true;
        }
        long startTime = SystemClock.elapsedRealtime();
        if (app.pid > 0 && app.pid != MY_PID) {
            checkTime(startTime, "startProcess: removing from pids map");
            synchronized (mPidsSelfLocked) {
                mPidsSelfLocked.remove(app.pid);
                mHandler.removeMessages(PROC_START_TIMEOUT_MSG, app);
            }
 
            app.setPid(0);
        }

....

            final String entryPoint = "android.app.ActivityThread";

            return startProcessLocked(hostingType, hostingNameStr, entryPoint, app, uid, gids,
                    runtimeFlags, mountExternal, seInfo, requiredAbi, instructionSet, invokeWith,
                    startTime);
        } catch (RuntimeException e) {
         ...
            return false;
        }
    }
```
中间设置很多准备启动的参数，我们只需要关注剩下这些代码。在这个当中，如果发现ProcessRecord不为空，则会拆调借助Handler实现的ANR为PROC_START_TIMEOUT_MSG的炸弹，不理解没关系，等下就有全部流程。

在设置的众多参数中有一个关键的参数entryPoint，字符串设置为android.app.ActivityThread。这种设计在Flutter也是这样，告诉你hook的类以及方法是什么。

```java
    private boolean startProcessLocked(String hostingType, String hostingNameStr, String entryPoint,
            ProcessRecord app, int uid, int[] gids, int runtimeFlags, int mountExternal,
            String seInfo, String requiredAbi, String instructionSet, String invokeWith,
            long startTime) {
        app.pendingStart = true;
        app.killedByAm = false;
        app.removed = false;
        app.killed = false;
        final long startSeq = app.startSeq = ++mProcStartSeqCounter;
        app.setStartParams(uid, hostingType, hostingNameStr, seInfo, startTime);
        if (mConstants.FLAG_PROCESS_START_ASYNC) {
            mProcStartHandler.post(() -> {
                try {
                    synchronized (ActivityManagerService.this) {
                        final String reason = isProcStartValidLocked(app, startSeq);
                        if (reason != null) {
                            app.pendingStart = false;
                            return;
                        }
                        app.usingWrapper = invokeWith != null
                                || SystemProperties.get("wrap." + app.processName) != null;
                        mPendingStarts.put(startSeq, app);
                    }
                    final ProcessStartResult startResult = startProcess(app.hostingType, entryPoint,
                            app, app.startUid, gids, runtimeFlags, mountExternal, app.seInfo,
                            requiredAbi, instructionSet, invokeWith, app.startTime);
                    synchronized (ActivityManagerService.this) {
                        handleProcessStartedLocked(app, startResult, startSeq);
                    }
                } catch (RuntimeException e) {
...
                    }
                }
            });
            return true;
        } else {
...
            return app.pid > 0;
        }
    }
```
在这个方法中，把fork进程分为两个步骤：
- 1.一般的startProcess调用Process.start通信Zygote进程，fork一个新进程。如果探测是hostType是webview则调用startWebView启动webview
- 2.handleProcessStartedLocked处理后续处理。

第一步骤中，我花了大量的篇幅描述了Zygote是如何孵化进程的，详细可以阅读我的第一篇重学系列[系统启动到Activity(下)](https://www.jianshu.com/p/e5231f99f2a1)这里就不多赘述，本文的读者只需要明白通过Zygote孵化之后就诞生了一个App进程，并且调用了ActivityThread类中的main方法；而WebView同样是由类似的方式管理通过一个WebViewZygote的对象孵化出来，有机会和大家聊聊。

我们来看看之前没有聊过的第二步骤handleProcessStartedLocked。

### AMS.handleProcessStartedLocked
经过上面的Socket通信之后，我们就能确切的获取到孵化进程是否成功，去做后续处理。
```java
    private boolean handleProcessStartedLocked(ProcessRecord app, int pid, boolean usingWrapper,
            long expectedStartSeq, boolean procAttached) {
        mPendingStarts.remove(expectedStartSeq);
...
        mBatteryStatsService.noteProcessStart(app.processName, app.info.uid);
...

        try {
            AppGlobals.getPackageManager().logAppProcessStartIfNeeded(app.processName, app.uid,
                    app.seInfo, app.info.sourceDir, pid);
        } catch (RemoteException ex) {
            // Ignore
        }

        if (app.persistent) {
            Watchdog.getInstance().processStarted(app.processName, pid);
        }

  ...
        app.setPid(pid);
        app.usingWrapper = usingWrapper;
        app.pendingStart = false;
        ProcessRecord oldApp;
        synchronized (mPidsSelfLocked) {
            oldApp = mPidsSelfLocked.get(pid);
        }
...
        synchronized (mPidsSelfLocked) {
            this.mPidsSelfLocked.put(pid, app);
//装载ANR炸弹
            if (!procAttached) {
                Message msg = mHandler.obtainMessage(PROC_START_TIMEOUT_MSG);
                msg.obj = app;
                mHandler.sendMessageDelayed(msg, usingWrapper
                        ? PROC_START_TIMEOUT_WITH_WRAPPER : PROC_START_TIMEOUT);
            }
        }
        return true;
    }
```
在过程中，电源服务收集启动进程的日志，把pid以及ProcessRecord存储到类型为map的mPidsSelfLocked。最后会设置一个PROC_START_TIMEOUT_MSG的延时消息发送到Handler中。而这个延时事件就是10秒。

假如我们试一试超过这个事件会怎么样？
#### 进程启动超时异常
```java
case PROC_START_TIMEOUT_MSG: {
                ProcessRecord app = (ProcessRecord)msg.obj;
                synchronized (ActivityManagerService.this) {
                    processStartTimedOutLocked(app);
                }
            } 
```
```java
    private final void processStartTimedOutLocked(ProcessRecord app) {
        final int pid = app.pid;
        boolean gone = false;
        synchronized (mPidsSelfLocked) {
            ProcessRecord knownApp = mPidsSelfLocked.get(pid);
            if (knownApp != null && knownApp.thread == null) {
                mPidsSelfLocked.remove(pid);
                gone = true;
            }
        }

        if (gone) {
                    pid, app.uid, app.processName);
            removeProcessNameLocked(app.processName, app.uid);
            if (mHeavyWeightProcess == app) {
                mHandler.sendMessage(mHandler.obtainMessage(CANCEL_HEAVY_NOTIFICATION_MSG,
                        mHeavyWeightProcess.userId, 0));
                mHeavyWeightProcess = null;
            }
            mBatteryStatsService.noteProcessFinish(app.processName, app.info.uid);

            cleanupAppInLaunchingProvidersLocked(app, true);
            mServices.processStartTimedOutLocked(app);
            app.kill("start timeout", true);
...
            removeLruProcessLocked(app);
            if (mBackupTarget != null && mBackupTarget.app.pid == pid) {
                mHandler.post(new Runnable() {
                @Override
                    public void run(){
                        try {
                            IBackupManager bm = IBackupManager.Stub.asInterface(
                                    ServiceManager.getService(Context.BACKUP_SERVICE));
                            bm.agentDisconnected(app.info.packageName);
                        } catch (RemoteException e) {
                            // Can't happen; the backup manager is local
                        }
                    }
                });
            }
            if (isPendingBroadcastProcessLocked(pid)) {

                skipPendingBroadcastLocked(pid);
            }
        } else {

        }
    }
```
能看到当启动进程超时事件执行的时候，会执行如下几个事情：
 - 1.清空mPidsSelfLocked中的缓存，清空mProcesMap中的缓存，如果是重量级进程，则会清空存储在AMS重量级进程中的缓存
- 2.关闭电源日志对应进程的的信息,清除已经那些等待进程初始化完毕之后要去加载的ContentProvider和Service
- 3.接着执行ProcessRecord的kill的方法，从Lru缓存中清除。
- 4.关闭那些备份服务的链接，最后清除掉当前进程存放在正在监听的广播并且准备发过来的信息。

因此，进程启动也有ANR。当进程启动超过10秒事件，也会理解退出。那么这个炸弹什么拆掉呢？接下来让我们来聊聊，进程诞生之后ActivityThread的第一个方法。

### ActivityThread的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)
```java
    public static void main(String[] args) {
...
        Looper.prepareMainLooper();

        ActivityThread thread = new ActivityThread();
        thread.attach(false, startSeq);

        if (sMainThreadHandler == null) {
            sMainThreadHandler = thread.getHandler();
        }

        if (false) {
            Looper.myLooper().setMessageLogging(new
                    LogPrinter(Log.DEBUG, "ActivityThread"));
        }

        Looper.loop();

        throw new RuntimeException("Main thread loop unexpectedly exited");
    }
```
ActivityThread的main方法中会先初始化一个prepareMainLooper，并且进行loop的事件循环。

在这个过程中，能看到之前我在上一篇文章Handler中聊过的Looper日志打印。在这个过程中调用了ActivityThread的attch方法进一步绑定，这里绑定了什么呢？先来看看attach方法。

## ActivityThread.attach
```java
  private void attach(boolean system, long startSeq) {
        sCurrentActivityThread = this;
        mSystemThread = system;
        if (!system) {
            ViewRootImpl.addFirstDrawHandler(new Runnable() {
                @Override
                public void run() {
                    ensureJitEnabled();
                }
            });
            android.ddm.DdmHandleAppName.setAppName("<pre-initialized>",
                                                    UserHandle.myUserId());
            RuntimeInit.setApplicationObject(mAppThread.asBinder());
            final IActivityManager mgr = ActivityManager.getService();
            try {
                mgr.attachApplication(mAppThread, startSeq);
            } catch (RemoteException ex) {
                throw ex.rethrowFromSystemServer();
            }
            // Watch for getting close to heap limit.
            BinderInternal.addGcWatcher(new Runnable() {
                @Override public void run() {
                    if (!mSomeActivitiesChanged) {
                        return;
                    }
                    Runtime runtime = Runtime.getRuntime();
                    long dalvikMax = runtime.maxMemory();
                    long dalvikUsed = runtime.totalMemory() - runtime.freeMemory();
                    if (dalvikUsed > ((3*dalvikMax)/4)) {
                        if (DEBUG_MEMORY_TRIM) Slog.d(TAG, "Dalvik max=" + (dalvikMax/1024)
                                + " total=" + (runtime.totalMemory()/1024)
                                + " used=" + (dalvikUsed/1024));
                        mSomeActivitiesChanged = false;
                        try {
                            mgr.releaseSomeActivities(mAppThread);
                        } catch (RemoteException e) {
                            throw e.rethrowFromSystemServer();
                        }
                    }
                }
            });
        } else {
            ....
        }

        // add dropbox logging to libcore
        DropBox.setReporter(new DropBoxReporter());

        ViewRootImpl.ConfigChangedCallback configChangedCallback
                = (Configuration globalConfig) -> {
            synchronized (mResourcesManager) {
                // We need to apply this change to the resources immediately, because upon returning
                // the view hierarchy will be informed about it.
                if (mResourcesManager.applyConfigurationToResourcesLocked(globalConfig,
                        null /* compat */)) {
                    updateLocaleListFromAppContext(mInitialApplication.getApplicationContext(),
                            mResourcesManager.getConfiguration().getLocales());

                    // This actually changed the resources! Tell everyone about it.
                    if (mPendingConfiguration == null
                            || mPendingConfiguration.isOtherSeqNewer(globalConfig)) {
                        mPendingConfiguration = globalConfig;
                        sendMessage(H.CONFIGURATION_CHANGED, globalConfig);
                    }
                }
            }
        };
        ViewRootImpl.addConfigCallback(configChangedCallback);
    }
```
当我们有之前的基础之后，读懂这一段就比较简单了：
- 1.注册ViewRootImpl在第一次调用onDraw时候的回调，此时要打开虚拟机的jit模式。注意这个jit并不是Skia SkSL的jit模式，只是虚拟机的jit模式。不过在Android 9.0中是空实现。
- 2.把ApplicationThread 绑定到AMS
- 3.通过BinderInternal不断的监听Java堆中是使用情况，如果使用情况超过3/4则会释放一部分的Activity
- 4.添加DropBox的打印器。DropBox实际上使用的是DropBoxManagerService，他会把日志记录在/data/system/dropbox中。一般记录一些一场行为，如anr，crash，watchdog(系统进程异常)，native_crash，lowmem(低内存)，strict_mode等待日志。
- 5.添加当资源环境发生配置时候的回调，能看到此时会根据Locale语言环境切换资源

我们先看看第二点看看这个过程中做了什么。

## 绑定ApplicationThread
```java
            final IActivityManager mgr = ActivityManager.getService();
            try {
                mgr.attachApplication(mAppThread, startSeq);
            } catch (RemoteException ex) {
                throw ex.rethrowFromSystemServer();
            }

```
这里能看到实际上是把ApplicationThread绑定到AMS。
```java
private class ApplicationThread extends IApplicationThread.Stub
```
ApplicationThread其实是一个Binder对象。

如果熟悉Activity启动流程的朋友就能明白，其实IActivityManager指的就是ActivityManagerService。这里不再介绍Binder如何运作的，我们直接看到ActivityManagerService中。



### AMS的attachApplicationLocked
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)

```java
     @Override
    public final void attachApplication(IApplicationThread thread, long startSeq) {
        synchronized (this) {
            int callingPid = Binder.getCallingPid();
            final int callingUid = Binder.getCallingUid();
            final long origId = Binder.clearCallingIdentity();
            attachApplicationLocked(thread, callingPid, callingUid, startSeq);
            Binder.restoreCallingIdentity(origId);
        }
    }
```
Binder.clearCallingIdentity以及Binder.getCallingPid的使用一般会和restoreCallingIdentity一起使用。当我们需要使用Binder通信到自己的进程的时候会这么使用。这两个Clear方法其实就是清空远程端的Binder的Pid和Uid并返回到java层，restoreCallingIdentity把这两个对象设置回来。

这里的核心方法就是attachApplicationLocked。



### AMS.attachApplicationLocked
```java
 private final boolean attachApplicationLocked(IApplicationThread thread,
            int pid, int callingUid, long startSeq) {

        // Find the application record that is being attached...  either via
        // the pid if we are running in multiple processes, or just pull the
        // next app record if we are emulating process with anonymous threads.
        ProcessRecord app;
        long startTime = SystemClock.uptimeMillis();
        if (pid != MY_PID && pid >= 0) {
            synchronized (mPidsSelfLocked) {
                app = mPidsSelfLocked.get(pid);
            }
        } else {
            app = null;
        }

        // It's possible that process called attachApplication before we got a chance to
        // update the internal state.
        if (app == null && startSeq > 0) {
            final ProcessRecord pending = mPendingStarts.get(startSeq);
            if (pending != null && pending.startUid == callingUid
                    && handleProcessStartedLocked(pending, pid, pending.usingWrapper,
                            startSeq, true)) {
                app = pending;
            }
        }

...


        if (app.thread != null) {
            handleAppDiedLocked(app, true, true);
        }

        // Tell the process all about itself.


        final String processName = app.processName;
        try {
            AppDeathRecipient adr = new AppDeathRecipient(
                    app, pid, thread);
            thread.asBinder().linkToDeath(adr, 0);
            app.deathRecipient = adr;
        } catch (RemoteException e) {
...
            return false;
        }


        app.makeActive(thread, mProcessStats);
        app.curAdj = app.setAdj = app.verifiedAdj = ProcessList.INVALID_ADJ;
        app.curSchedGroup = app.setSchedGroup = ProcessList.SCHED_GROUP_DEFAULT;
        app.forcingToImportant = null;
        updateProcessForegroundLocked(app, false, false);
        app.hasShownUi = false;
        app.debugging = false;
        app.cached = false;
        app.killedByAm = false;
        app.killed = false;


        app.unlocked = StorageManager.isUserKeyUnlocked(app.userId);

        mHandler.removeMessages(PROC_START_TIMEOUT_MSG, app);

        boolean normalMode = mProcessesReady || isAllowedWhileBooting(app.info);
        List<ProviderInfo> providers = normalMode ? generateApplicationProvidersLocked(app) : null;

        if (providers != null && checkAppInLaunchingProvidersLocked(app)) {
            Message msg = mHandler.obtainMessage(CONTENT_PROVIDER_PUBLISH_TIMEOUT_MSG);
            msg.obj = app;
            mHandler.sendMessageDelayed(msg, CONTENT_PROVIDER_PUBLISH_TIMEOUT);
        }


        try {
...
            if (app.isolatedEntryPoint != null) {
...
            } else if (app.instr != null) {
                ...
            } else {
                thread.bindApplication(processName, appInfo, providers, null, profilerInfo,
                        null, null, null, testMode,
                        mBinderTransactionTrackingEnabled, enableTrackAllocation,
                        isRestrictedBackupMode || !normalMode, app.persistent,
                        new Configuration(getGlobalConfiguration()), app.compat,
                        getCommonServicesLocked(app.isolated),
                        mCoreSettingsObserver.getCoreSettingsLocked(),
                        buildSerial, isAutofillCompatEnabled);
            }
            if (profilerInfo != null) {
                profilerInfo.closeFd();
                profilerInfo = null;
            }
            checkTime(startTime, "attachApplicationLocked: immediately after bindApplication");
            updateLruProcessLocked(app, false, null);
            checkTime(startTime, "attachApplicationLocked: after updateLruProcessLocked");
            app.lastRequestedGc = app.lastLowMemory = SystemClock.uptimeMillis();
        } catch (Exception e) {
    ...
            return false;
        }

        // Remove this record from the list of starting applications.
        mPersistentStartingProcesses.remove(app);
        if (DEBUG_PROCESSES && mProcessesOnHold.contains(app)) Slog.v(TAG_PROCESSES,
                "Attach application locked removing on hold: " + app);
        mProcessesOnHold.remove(app);

        boolean badApp = false;
        boolean didSomething = false;

        // See if the top visible activity is waiting to run in this process...
        if (normalMode) {
            try {
                if (mStackSupervisor.attachApplicationLocked(app)) {
                    didSomething = true;
                }
            } catch (Exception e) {
                Slog.wtf(TAG, "Exception thrown launching activities in " + app, e);
                badApp = true;
            }
        }

        // Find any services that should be running in this process...
        if (!badApp) {
            try {
                didSomething |= mServices.attachApplicationLocked(app, processName);
                checkTime(startTime, "attachApplicationLocked: after mServices.attachApplicationLocked");
            } catch (Exception e) {
      ...
            }
        }

        // Check if a next-broadcast receiver is in this process...
        if (!badApp && isPendingBroadcastProcessLocked(pid)) {
            try {
                didSomething |= sendPendingBroadcastsLocked(app);
                checkTime(startTime, "attachApplicationLocked: after sendPendingBroadcastsLocked");
            } catch (Exception e) {
...
            }
        }

        // Check whether the next backup agent is in this process...
        if (!badApp && mBackupTarget != null && mBackupTarget.app == app) {
...
            notifyPackageUse(mBackupTarget.appInfo.packageName,
                             PackageManager.NOTIFY_PACKAGE_USE_BACKUP);
            try {
                thread.scheduleCreateBackupAgent(mBackupTarget.appInfo,
                        compatibilityInfoForPackageLocked(mBackupTarget.appInfo),
                        mBackupTarget.backupMode);
            } catch (Exception e) {
...
            }
        }

...
        if (!didSomething) {
            updateOomAdjLocked();
        }

        return true;
    }
```

经过压缩流程，我们只需要关注这些代码逻辑。
- 1.从mPidsSelfLocked缓存对象中获取对应pid的ProcessRecord对象
- 2.如果此时找不到对应的ProcessRecord，则尝试通过handleProcessStartedLocked说明可能添加遗漏了，就尝试再添加到缓存中。一般走不到这里面。
- 3.如果当前的ProcessRecord还包含着thread对象，说明这个进程其实已经启动过了,而且还是经历了重新启动进程。因此需要通过handleAppDiedLocked先清理一次之前进程所有留在AMS，WMS中的缓存
- 4.重新绑定Binder死亡监听；同时设置ProcessRecord中的数据，把ApplicationThread和ProcessRecord绑定起来。
- 5.通过mHandler .removeMessages拆除进程启动超时炸弹
- 6.跨进程调用ApplicationThread的bindApplication方法。
- 7.启动那些之前已经在TaskRecord中活跃过的Activity，Service，Broadcast，ContentProvider。一般这种情况是指进程因为crash等原因重新启动。
- 8.调整adj值。这个值是当前进程的活跃度等级。

#### ApplicationThread.bindApplication

文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)

```java
        public final void bindApplication(String processName, ApplicationInfo appInfo,
                List<ProviderInfo> providers, ComponentName instrumentationName,
                ProfilerInfo profilerInfo, Bundle instrumentationArgs,
                IInstrumentationWatcher instrumentationWatcher,
                IUiAutomationConnection instrumentationUiConnection, int debugMode,
                boolean enableBinderTracking, boolean trackAllocation,
                boolean isRestrictedBackupMode, boolean persistent, Configuration config,
                CompatibilityInfo compatInfo, Map services, Bundle coreSettings,
                String buildSerial, boolean autofillCompatibilityEnabled) {

            if (services != null) {
                if (false) {
                    // Test code to make sure the app could see the passed-in services.
                    for (Object oname : services.keySet()) {
                        if (services.get(oname) == null) {
                            continue; // AM just passed in a null service.
                        }
                        String name = (String) oname;

                        // See b/79378449 about the following exemption.
                        switch (name) {
                            case "package":
                            case Context.WINDOW_SERVICE:
                                continue;
                        }

                        if (ServiceManager.getService(name) == null) {
                            Log.wtf(TAG, "Service " + name + " should be accessible by this app");
                        }
                    }
                }

                // Setup the service cache in the ServiceManager
                ServiceManager.initServiceCache(services);
            }

            setCoreSettings(coreSettings);

            AppBindData data = new AppBindData();
            data.processName = processName;
            data.appInfo = appInfo;
            data.providers = providers;
            data.instrumentationName = instrumentationName;
            data.instrumentationArgs = instrumentationArgs;
            data.instrumentationWatcher = instrumentationWatcher;
            data.instrumentationUiAutomationConnection = instrumentationUiConnection;
            data.debugMode = debugMode;
            data.enableBinderTracking = enableBinderTracking;
            data.trackAllocation = trackAllocation;
            data.restrictedBackupMode = isRestrictedBackupMode;
            data.persistent = persistent;
            data.config = config;
            data.compatInfo = compatInfo;
            data.initProfilerInfo = profilerInfo;
            data.buildSerial = buildSerial;
            data.autofillCompatibilityEnabled = autofillCompatibilityEnabled;
            sendMessage(H.BIND_APPLICATION, data);
        }
```

在这个过程中，实际上是初始化了ServiceManager一个隐藏的SystemService管理类，获取从AMS传输过来的字符串进行初始化。

学习到现在出现两个可以从App应用端获取系统SystemServer进程中的服务。
- SystemServiceRegistry 我们常用的Context.getService就是从这里面获取的
- ServiceManager一个不面向开发者的系统服务缓存

那么这两个是什么关系呢？其实阅读过我之前的文章就知道。在SystemServer初始化各种服务之后，会把每一个服务通过addService添加到本进程的ServiceManager中，换句话说，就是直接存放了一个key为服务名和value为IBinder的map值。

SystemServiceRegistry则是面向开发者的key，value的缓存IBinder的数据结构。可以通过Context.getSystemService获取。初始化AppBindData数据，发送BIND_APPLICATION，到主线程的Handler。

#### ActivityThread.handleBindApplication
```java
private void handleBindApplication(AppBindData data) {
        // Register the UI Thread as a sensitive thread to the runtime.
    ...
        synchronized (mResourcesManager) {
            /*
             * Update the system configuration since its preloaded and might not
             * reflect configuration changes. The configuration object passed
             * in AppBindData can be safely assumed to be up to date
             */
            mResourcesManager.applyConfigurationToResourcesLocked(data.config, data.compatInfo);
            mCurDefaultDisplayDpi = data.config.densityDpi;

            // This calls mResourcesManager so keep it within the synchronized block.
            applyCompatConfiguration(mCurDefaultDisplayDpi);
        }

        data.info = getPackageInfoNoCheck(data.appInfo, data.compatInfo);

        if (agent != null) {
            handleAttachAgent(agent, data.info);
        }

        /**
         * Switch this process to density compatibility mode if needed.
         */
        if ((data.appInfo.flags&ApplicationInfo.FLAG_SUPPORTS_SCREEN_DENSITIES)
                == 0) {
            mDensityCompatMode = true;
            Bitmap.setDefaultDensity(DisplayMetrics.DENSITY_DEFAULT);
        }
        updateDefaultDensity();

       ...
        final InstrumentationInfo ii;
        if (data.instrumentationName != null) {
            try {
                ii = new ApplicationPackageManager(null, getPackageManager())
                        .getInstrumentationInfo(data.instrumentationName, 0);
            } catch (PackageManager.NameNotFoundException e) {
        ...
            }

            mInstrumentationPackageName = ii.packageName;
            mInstrumentationAppDir = ii.sourceDir;
            mInstrumentationSplitAppDirs = ii.splitSourceDirs;
            mInstrumentationLibDir = getInstrumentationLibrary(data.appInfo, ii);
            mInstrumentedAppDir = data.info.getAppDir();
            mInstrumentedSplitAppDirs = data.info.getSplitAppDirs();
            mInstrumentedLibDir = data.info.getLibDir();
        } else {
            ii = null;
        }

        final ContextImpl appContext = ContextImpl.createAppContext(this, data.info);
        updateLocaleListFromAppContext(appContext,
                mResourcesManager.getConfiguration().getLocales());

...


        if (SystemProperties.getBoolean("dalvik.vm.usejitprofiles", false)) {
            BaseDexClassLoader.setReporter(DexLoadReporter.getInstance());
        }

...

        // Continue loading instrumentation.
        if (ii != null) {

...
        } else {
            mInstrumentation = new Instrumentation();
            mInstrumentation.basicInit(this);
        }

...

        // Allow disk access during application and provider setup. This could
        // block processing ordered broadcasts, but later processing would
        // probably end up doing the same disk access.
        Application app;
...
        try {
            // If the app is being launched for full backup or restore, bring it up in
            // a restricted environment with the base application class.
            app = data.info.makeApplication(data.restrictedBackupMode, null);

            // Propagate autofill compat state
            app.setAutofillCompatibilityEnabled(data.autofillCompatibilityEnabled);

            mInitialApplication = app;

            // don't bring up providers in restricted mode; they may depend on the
            // app's custom Application class
            if (!data.restrictedBackupMode) {
                if (!ArrayUtils.isEmpty(data.providers)) {
                    installContentProviders(app, data.providers);
                    // For process that contains content providers, we want to
                    // ensure that the JIT is enabled "at some point".
                    mH.sendEmptyMessageDelayed(H.ENABLE_JIT, 10*1000);
                }
            }

            // Do this after providers, since instrumentation tests generally start their
            // test thread at this point, and we don't want that racing.
            try {
                mInstrumentation.onCreate(data.instrumentationArgs);
            }
            catch (Exception e) {
                ...
            }
            try {
                mInstrumentation.callApplicationOnCreate(app);
            } catch (Exception e) {
                ...
            }
        } finally {
            ...
        }

...
        }
    }
```
这个方法有点长，我们关注比较核心的逻辑：
- 1.首先获取mResourcesManager实例(ActivityThread构造函数实例化)，给底层的资源设置dpi得到配置，更加详细的，可以看看[资源加载系列](https://www.jianshu.com/p/817a787910f2)

- 2.接着通过getPackageInfoNoCheck获取LoadedApk对象，这个对象在插件化一文中聊过，本质是一个apk在内存中的表现对象

- 3.通过createAppContext创建一个ContextImpl，这就是在整个App进程中第一个创建的Context

- 4.创建Instrumentation对象，这个对象一般是用于自动化测试的中间键。

- 5.通过makeApplication创建Application对象，接着通过installContentProviders启动所有的ContextProvider对象

- 6.回调mInstrumentation的ApplicationCreate方法，该方法最后会调用到Application的onCreate中。

在这个过程中，我们稍微看到了一处比较迷惑的地方。Application在bindApplication中执行了一次。其实我们在创建Activity时候performLaunchActivity中又创建了一次。
```
Application app = r.packageInfo.makeApplication(false, mInstrumentation);
```
以及在bindApplication中
```
app = data.info.makeApplication(data.restrictedBackupMode, null);
```
这两次有什么区别呢？假设这是一次，从零开始正常启动的进程，而不是重新启动的启动的。此时restrictedBackupMode这个标志代表重新启动时候的备份标志位。当我们是第一次启动进程的时候，这个标志位默认false。

为了更加彻底理解LoadedApk对象，我们先来看看Android是如何通过getPackageInfoNoCheck创建这个对象


#### getPackageInfoNoCheck创建LoadedApk
```java
    public final LoadedApk getPackageInfoNoCheck(ApplicationInfo ai,
            CompatibilityInfo compatInfo) {
        return getPackageInfo(ai, compatInfo, null, false, true, false);
    }
```
getPackageInfoNoCheck最后会调用getPackageInfo方法。

```java
    private LoadedApk getPackageInfo(ApplicationInfo aInfo, CompatibilityInfo compatInfo,
            ClassLoader baseLoader, boolean securityViolation, boolean includeCode,
            boolean registerPackage) {
        final boolean differentUser = (UserHandle.myUserId() != UserHandle.getUserId(aInfo.uid));
        synchronized (mResourcesManager) {
            WeakReference<LoadedApk> ref;
            if (differentUser) {
                // Caching not supported across users
                ref = null;
            } else if (includeCode) {
                ref = mPackages.get(aInfo.packageName);
            } else {
                ref = mResourcePackages.get(aInfo.packageName);
            }

            LoadedApk packageInfo = ref != null ? ref.get() : null;
            if (packageInfo == null || (packageInfo.mResources != null
                    && !packageInfo.mResources.getAssets().isUpToDate())) {
                ...
                packageInfo =
                    new LoadedApk(this, aInfo, compatInfo, baseLoader,
                            securityViolation, includeCode &&
                            (aInfo.flags&ApplicationInfo.FLAG_HAS_CODE) != 0, registerPackage);

                if (mSystemThread && "android".equals(aInfo.packageName)) {
                    packageInfo.installSystemApplicationInfo(aInfo,
                            getSystemContext().mPackageInfo.getClassLoader());
                }

                if (differentUser) {
                    // Caching not supported across users
                } else if (includeCode) {
                    mPackages.put(aInfo.packageName,
                            new WeakReference<LoadedApk>(packageInfo));
                } else {
                    mResourcePackages.put(aInfo.packageName,
                            new WeakReference<LoadedApk>(packageInfo));
                }
            }
            return packageInfo;
        }
    }
```
在这个过程中其实并没有太多特殊处理本质上LoadedApk保存了ApplicationInfo这些从AMS中解析出来包中所有的信息。并且把LoadedApk保存到mResourcePackages的这个带着弱引用的map中。


### 初始化Application 
文件 ：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[LoadedApk.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/LoadedApk.java)

```java
    public Application makeApplication(boolean forceDefaultAppClass,
            Instrumentation instrumentation) {
        if (mApplication != null) {
            return mApplication;
        }

        Application app = null;

        String appClass = mApplicationInfo.className;
        if (forceDefaultAppClass || (appClass == null)) {
            appClass = "android.app.Application";
        }

        try {
            java.lang.ClassLoader cl = getClassLoader();
            if (!mPackageName.equals("android")) {
                initializeJavaContextClassLoader();
            }
            ContextImpl appContext = ContextImpl.createAppContext(mActivityThread, this);
            app = mActivityThread.mInstrumentation.newApplication(
                    cl, appClass, appContext);
            appContext.setOuterContext(app);
        } catch (Exception e) {
           ...
        }
        mActivityThread.mAllApplications.add(app);
        mApplication = app;

        if (instrumentation != null) {
            try {
                instrumentation.callApplicationOnCreate(app);
            } catch (Exception e) {
                if (!instrumentation.onException(app, e)) {
                    Trace.traceEnd(Trace.TRACE_TAG_ACTIVITY_MANAGER);
                    throw new RuntimeException(
                        "Unable to create application " + app.getClass().getName()
                        + ": " + e.toString(), e);
                }
            }
        }

        // Rewrite the R 'constants' for all library apks.
        SparseArray<String> packageIdentifiers = getAssets(mActivityThread)
                .getAssignedPackageIdentifiers();
        final int N = packageIdentifiers.size();
        for (int i = 0; i < N; i++) {
            final int id = packageIdentifiers.keyAt(i);
            if (id == 0x01 || id == 0x7f) {
                continue;
            }

            rewriteRValues(getClassLoader(), packageIdentifiers.valueAt(i), id);
        }

        return app;
    }
```

能看到在LoadApk对象中会全局缓存一个Application对象。之后每一次调用这个方法读取之后，就会调用这个方法直接获取缓存中的Application对象。

当没有设置Application的class则会有默认的class，或者打开了备份服务之后强制使用默认Application。

接下来可以把分为几个步骤:
- 1.getClassLoader 装载ClassLoader，如果是系统应用则initializeJavaContextClassLoader装载另一个classLoader
- 2.createAppContext创建一个context对象
- 3.newApplication反射生成Application对象，并且调用了attachBaseContext方法，并且把Context和Application互相绑定
- 4.如果传入了instrumentation，最会调用Application.onCreate方法
- 5.rewriteRValues重写共享资源库中的资源id。这种资源库在资源章节中有聊过，这种资源共享库，packageId往往是0x00,此时的id将会依据编译的顺序获取，加载时候也是根据加载顺序获取，为此Android系统做了一个LookupTable进行一次映射。而rewriteRValues的作用就是反射这种共享资源库中的R文件的onResourceLoaded方法，重写里面的packageid，让app可以查找。稍后做进一步解析。

接着从classLoader的加载开始聊。

##### getClassLoader 装载Android的ClassLoader
```java
    public ClassLoader getClassLoader() {
        synchronized (this) {
            if (mClassLoader == null) {
                createOrUpdateClassLoaderLocked(null /*addedPaths*/);
            }
            return mClassLoader;
        }
    }
```
```java
    private void createOrUpdateClassLoaderLocked(List<String> addedPaths) {
        if (mPackageName.equals("android")) {
            if (mClassLoader != null) {
                return;
            }

            if (mBaseClassLoader != null) {
                mClassLoader = mBaseClassLoader;
            } else {
                mClassLoader = ClassLoader.getSystemClassLoader();
            }
            mAppComponentFactory = createAppFactory(mApplicationInfo, mClassLoader);

            return;
        }


        if (!Objects.equals(mPackageName, ActivityThread.currentPackageName()) && mIncludeCode) {
            try {
                ActivityThread.getPackageManager().notifyPackageUse(mPackageName,
                        PackageManager.NOTIFY_PACKAGE_USE_CROSS_PACKAGE);
            } catch (RemoteException re) {
                throw re.rethrowFromSystemServer();
            }
        }

        if (mRegisterPackage) {
            try {
                ActivityManager.getService().addPackageDependency(mPackageName);
            } catch (RemoteException e) {
                throw e.rethrowFromSystemServer();
            }
        }


        final List<String> zipPaths = new ArrayList<>(10);
        final List<String> libPaths = new ArrayList<>(10);

        boolean isBundledApp = mApplicationInfo.isSystemApp()
                && !mApplicationInfo.isUpdatedSystemApp();


        final String defaultSearchPaths = System.getProperty("java.library.path");
        final boolean treatVendorApkAsUnbundled = !defaultSearchPaths.contains("/vendor/lib");
        if (mApplicationInfo.getCodePath() != null
                && mApplicationInfo.isVendor() && treatVendorApkAsUnbundled) {
            isBundledApp = false;
        }

        makePaths(mActivityThread, isBundledApp, mApplicationInfo, zipPaths, libPaths);

        String libraryPermittedPath = mDataDir;

        if (isBundledApp) {

            libraryPermittedPath += File.pathSeparator
                    + Paths.get(getAppDir()).getParent().toString();

            libraryPermittedPath += File.pathSeparator + defaultSearchPaths;
        }

        final String librarySearchPath = TextUtils.join(File.pathSeparator, libPaths);

...

        final String zip = (zipPaths.size() == 1) ? zipPaths.get(0) :
                TextUtils.join(File.pathSeparator, zipPaths);



        boolean needToSetupJitProfiles = false;
        if (mClassLoader == null) {
..

            mClassLoader = ApplicationLoaders.getDefault().getClassLoader(zip,
                    mApplicationInfo.targetSdkVersion, isBundledApp, librarySearchPath,
                    libraryPermittedPath, mBaseClassLoader,
                    mApplicationInfo.classLoaderName);
            mAppComponentFactory = createAppFactory(mApplicationInfo, mClassLoader);
...
            needToSetupJitProfiles = true;
        }

        if (!libPaths.isEmpty() && SystemProperties.getBoolean(PROPERTY_NAME_APPEND_NATIVE, true)) {
...
            try {
                ApplicationLoaders.getDefault().addNative(mClassLoader, libPaths);
            } finally {
...
            }
        }


        List<String> extraLibPaths = new ArrayList<>(3);
        String abiSuffix = VMRuntime.getRuntime().is64Bit() ? "64" : "";
        if (!defaultSearchPaths.contains("/vendor/lib")) {
            extraLibPaths.add("/vendor/lib" + abiSuffix);
        }
        if (!defaultSearchPaths.contains("/odm/lib")) {
            extraLibPaths.add("/odm/lib" + abiSuffix);
        }
        if (!defaultSearchPaths.contains("/product/lib")) {
            extraLibPaths.add("/product/lib" + abiSuffix);
        }
        if (!extraLibPaths.isEmpty()) {
...
            try {
                ApplicationLoaders.getDefault().addNative(mClassLoader, extraLibPaths);
            } finally {
...
            }
        }

        if (addedPaths != null && addedPaths.size() > 0) {
            final String add = TextUtils.join(File.pathSeparator, addedPaths);
            ApplicationLoaders.getDefault().addPath(mClassLoader, add);
            needToSetupJitProfiles = true;
        }


        if (needToSetupJitProfiles && !ActivityThread.isSystem()) {
            setupJitProfileSupport();
        }
    }v
```

在这个过程实际上做的事情就一件就是插件化一文中提到过的Android中ClassLoader的组成.
![ClassLoader设计.jpg](/images/ClassLoader设计.jpg)

在应用进程初期还不会存在Application ClassLoader对象。只有开始实例化Application的时候，才会装载Android应用独有的ClassLoader对象。还能看到，如果包名是系统的android开始，则不会加载应用的ClassLoader对象。

当是应用的时候，判断到当前的App是BundleApp，说明有部分代码是在Google服务上，会预先设置好未来下载dex的目录，之后会从里面加载。

接着执行如下2个事情:
- 1.ApplicationLoaders.getDefault().getClassLoader根据从PMS中解析出来的ApplicationInfo中所有资源的路径，生成一个Application ClassLoader
- 2.ApplicationLoaders.getDefault().addNative 添加系统中得到so，以及应用中的so。并且调用系统中过的so库

##### ApplicationLoaders.getDefault().getClassLoader
```java
    private ClassLoader getClassLoader(String zip, int targetSdkVersion, boolean isBundled,
                                       String librarySearchPath, String libraryPermittedPath,
                                       ClassLoader parent, String cacheKey,
                                       String classLoaderName) {

        ClassLoader baseParent = ClassLoader.getSystemClassLoader().getParent();

        synchronized (mLoaders) {
            if (parent == null) {
                parent = baseParent;
            }

            if (parent == baseParent) {
                ClassLoader loader = mLoaders.get(cacheKey);
                if (loader != null) {
                    return loader;
                }

                ClassLoader classloader = ClassLoaderFactory.createClassLoader(
                        zip,  librarySearchPath, libraryPermittedPath, parent,
                        targetSdkVersion, isBundled, classLoaderName);

                GraphicsEnvironment.getInstance().setLayerPaths(
                        classloader, librarySearchPath, libraryPermittedPath);

                mLoaders.put(cacheKey, classloader);
                return classloader;
            }

            ClassLoader loader = ClassLoaderFactory.createClassLoader(
                    zip, null, parent, classLoaderName);
            return loader;
        }
    }
```
此时的parent在新建一个应用Application的时候为null。此时parent就是获取getSystemClassLoader的parent。

此时baseParent就必定是parent。先尝试从mLoaders通过key(此时为apk包路径名)找缓存，最后通过ClassLoaderFactory.createClassLoader创造classLoader，最后添加到缓存中。

那么我们就有必要看看着几个ClassLoader是否是我在插件化所说那样的。

##### ClassLoader的构成
文件：/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[ojluni](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/)/[lang](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/lang/)/[ClassLoader.java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/lang/ClassLoader.java)
```java
public abstract class ClassLoader {

    static private class SystemClassLoader {
        public static ClassLoader loader = ClassLoader.createSystemClassLoader();
    }
    private static ClassLoader createSystemClassLoader() {
        String classPath = System.getProperty("java.class.path", ".");
        String librarySearchPath = System.getProperty("java.library.path", "");
        return new PathClassLoader(classPath, librarySearchPath, BootClassLoader.getInstance());
    }

    @CallerSensitive
    public static ClassLoader getSystemClassLoader() {
        return SystemClassLoader.loader;
    }

}
```
getSystemClassLoader通过一个单例获取一个SystemClassLoader，而这个系统加载器就是PathClassLoader。而这个对象就是继承关系如下：
```java
class PathClassLoader extends BaseDexClassLoader 
```
```java
public class BaseDexClassLoader extends ClassLoader 
```
此时能看到一切的Classloader基础都是BaseDexClassLoader，而DexClassLoader用于加载外部dex文件也是如此。而PathClassLoader是系统中默认初始化好的类加载器，用于加载路径下的dex文件。因此在系统应用中，默认都是PathClassLoader。


让我们情景代入一下，getSystemClassLoader的parent实际上就是BootLoader，也就是上图中启动类加载器。接下来看看ClassLoader工厂的createClassLoader方法。

##### ClassLoaderFactory.createClassLoader
```java
    public static boolean isPathClassLoaderName(String name) {
        return name == null || PATH_CLASS_LOADER_NAME.equals(name) ||
                DEX_CLASS_LOADER_NAME.equals(name);
    }

    public static ClassLoader createClassLoader(String dexPath,
            String librarySearchPath, ClassLoader parent, String classloaderName) {
        if (isPathClassLoaderName(classloaderName)) {
            return new PathClassLoader(dexPath, librarySearchPath, parent);
        } else if (isDelegateLastClassLoaderName(classloaderName)) {
            return new DelegateLastClassLoader(dexPath, librarySearchPath, parent);
        }

        throw new AssertionError("Invalid classLoaderName: " + classloaderName);
    }


    public static ClassLoader createClassLoader(String dexPath,
            String librarySearchPath, String libraryPermittedPath, ClassLoader parent,
            int targetSdkVersion, boolean isNamespaceShared, String classloaderName) {

        final ClassLoader classLoader = createClassLoader(dexPath, librarySearchPath, parent,
                classloaderName);

        boolean isForVendor = false;
        for (String path : dexPath.split(":")) {
            if (path.startsWith("/vendor/")) {
                isForVendor = true;
                break;
            }
        }

        String errorMessage = createClassloaderNamespace(classLoader,
                                                         targetSdkVersion,
                                                         librarySearchPath,
                                                         libraryPermittedPath,
                                                         isNamespaceShared,
                                                         isForVendor);

        return classLoader;
    }
```
在这个工厂中，能看到如果传递下来的名字是null或者名字是PathClassLoader或者DexClassLoader则会默认创建PathClassLoader，并且通过native方法createClassloaderNamespace加载native层ClassLoader。

而ClassLoader有一个机制叫做双亲委托，当前的ClassLoader不会立即查找类而是不断委托的根部，最后找不到才往下层查找。

如果从双亲委托的角度来看，本质上一般的App应用中，一层是BootClassLoader就是指Bootstrap，另一层就是PathClassLoader就是我们的App类加载器。


### Android的R文件重载

有一个方法rewriteRValues很多人都忽视掉。一般来说这个方法很少走。但是，如果是跟着我上一篇文章资源加载文章走下来，就会知道，其实在Android中有一种特殊的库，是只有资源没有代码的资源共享库。而这种库的packageID一般都为0x00.通过底层构建LookUpTable，把编译时期和加载时期不一致的packageID映射起来。然而这样还是没办法正常找到资源，因为我们通常会通过R.xx.xxx来加载资源共享库。因此需要把资源共享库中的内容,合并到当前包名才行。
```java
    private void rewriteRValues(ClassLoader cl, String packageName, int id) {
        final Class<?> rClazz;
        try {
            rClazz = cl.loadClass(packageName + ".R");
        } catch (ClassNotFoundException e) {
            return;
        }

        final Method callback;
        try {
            callback = rClazz.getMethod("onResourcesLoaded", int.class);
        } catch (NoSuchMethodException e) {
            return;
        }

        Throwable cause;
        try {
            callback.invoke(null, id);
            return;
        } catch (IllegalAccessException e) {
            cause = e;
        } catch (InvocationTargetException e) {
            cause = e.getCause();
        }

        throw new RuntimeException("Failed to rewrite resource references for " + packageName,
                cause);
    }
```
能看到会反射调用当前包名对应的R文件中onResourcesLoaded方法。如果我们翻开R.java是根本找不到这个方法的。只有当链接了资源共享库的R.java才会存在。

为此，我翻阅了AS的打包工具aapt的源码，有机会可以尝试着详细的过一遍源码。这里先上一个资源R文件生成流程的时序图:
![aapt R.java生成的工作流程.png](/images/aapt_R.java生成的工作流程.png)


从上图可以得知，其核心逻辑如下：当aapt的main方法解析到p参数中引用的资源，将会调用doPackage，开始尝试的调用writeSymbolClass打包生成R.java文件，把每一个R文件中资源的int值赋值上。

在doPackage中一个核心逻辑就是
```java
err = writeResourceSymbols(bundle, assets, assets->getPackage(), true,            
bundle->getBuildSharedLibrary() || bundle->getBuildAppAsSharedLibrary());
```
能看到只要你编译的是资源共享库，而这个标志位的打开则是依赖aapt资源打包命令："-shared-lib"。

那么这个方法做的事情是什么呢？其核心逻辑如下：
```java
            Class<?>[] declaredClasses = rClazz.getDeclaredClasses();
            for (Class<?> clazz : declaredClasses) {
                try {
                    if (clazz.getSimpleName().equals("styleable")) {
                        for (Field field : clazz.getDeclaredFields()) {
                            if (field.getType() == int[].class) {
                                rewriteIntArrayField(field, id);
                            }
                        }

                    } else {
                        for (Field field : clazz.getDeclaredFields()) {
                            rewriteIntField(field, id);
                        }
                    }
                } catch (Exception e) {
...
                }
            }

```

能看到其实就是通过反射，把R文件中的packageId的值复写，把非法的0x00复写成当前资源库加载之后的packageID的数值，这样App就能正常访问资源共享文件。

## 总结
在进程初始化过程中做了如下的事情:
- 1.把每一个生成的进程分配一个ProcessRecord对象，以pid为key缓存起来
- 2.每一个进程都会有自己ANR，只是这个时候进程不会出现自己ANR的框。在这个过程中AMS会有一个10秒延时事件，如果进程启动后没有即使拆除这个炸弹，将会退出。

在ActivityThread初始化过程中，做了如下的事情：
- 1.把ActivityThread中作为跨进程通信的中介ApplicationThread和AMS对应的ProcessRecord绑定起来。
- 2.重新绑定死亡监听
- 3.拆除进程启动炸弹
- 4.调用bindApplication，初始化Application
- 5.启动之前已经启动过的四大组件


在Application初始化过程中，做了如下几个步骤：
- 1.加载资源配置
- 2.生成LoadedApk对象
- 3. makeApplication 加载PathClassLoader，创建一个ContextImpl对象
- 4.反射生成Application对象，并调用attachBaseContext
- 5. rewriteRValues 重写资源库中的packageID。
- 6.调用Applcation的onCreate方法。

## 思考
理解了这个逻辑之后，我们来聊聊MultiDex的原理。大家都知道Android加载dex有65536个方法的限制，此时一般解决的方式就是MultiDex。而这个库内部在做什么呢？为什么使用的时候，需要把install方法放在attachBaseContext中呢？

本质上十分简单，实际上做的就是dex的加载。这个过程就是hook PathClassLoader的pathList对象中的dexElements对象，把拆分出小的dex文件加载到主的dex中。

思路本质上就是化整为零，你一个dex超过65536方法对吧，那就拆成几个小的，一一加载进来，这样就变相突破了限制。

知道了MultiDex的原理之后，我们就不难理解为什么要把install方法放在attachBaseContext中。因为attachBaseContext这个回调是整个App生命周期最早的换掉。此时也刚好了加载了自己的PathClassLoader，连Application.onCreate都没有调用，就能办到在不影响业务的前提下，加载类。

那么这么做有什么坏处呢？在主线程加载dex文件会出现ANR等卡顿现象。有不少团队为了解决这个问题，使用了异步线程或者异步进程调用install方法，但是这样就会出现dex还没加载到内存，但是想要调用了，就出现类无法找到异常。

为了处理这个问题，有些厂商就是hook Activity的启动流程，当没有找到这个类的时候将会出现一个中间页或者等待等。

随着眼界的开放，如果只是为了提升启动速度，其实可以通过redex对dex进行重排，把一开始使用的dex排到主dex中，少用的dex排到其他分dex中，这样异步调用MultiDex.install的方法就能跳过这些不自然的交互。

所有的核心技术都在我写的插件化基础框架都有解析过[横向浅析Small,RePlugin两个插件化框架](https://www.jianshu.com/p/d824056f510b)











