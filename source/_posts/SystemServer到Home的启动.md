---
title: SystemServer到Home的启动
top: false
cover: false
date: 2019-03-15 23:17:48
img:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---

本文简书地址：https://www.jianshu.com/p/a59068928590 如果出错欢迎来到下面指出。
# 背景
很多老哥看了上一篇的博文有点云里雾里，没关系，这些东西贵在坚持，不懂多查查，自然就懂了。毕竟也不是什么高深的数学推导。之前已经写了Zygote进程的系统启动。等待着新的应用程序，通过socket通知Zygote孵化进程。

接下来我的源码会从Android 9.0 （Android P）开始分析。由于上一篇的，native源码没有太大的变化，就从我最熟悉的Android 7.0讲起来。接下来来Android P的java层源码和Android 7.0的源码有些变化，为了跟上时代，还是选择解析Android P的源码。


# 正文
此时，第一个诞生的应用程序就是桌面应用。跟着我们上一篇文章的思路，看看Android系统究竟是怎么启动的Home界面。

上一篇从系统启动到Activity中，还记得，在Zygote中第一个孵化的进程SystemServer吗？上一篇总结了，SystemServer启动了AMS，WMS，PMS，InputManager等，主要的，辅助的服务。

从上一篇的源码的解析，似乎并没有启动Home的为止，由此可以推理出SystemServer在准备好AMS之后会启动Home界面。是不是这样，我们再来看看里面的代码。

## SystemServer
接着上一篇来讲，从SystemServer的主函数开始。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/server/)/[SystemServer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/server/SystemServer.java)

```java
 public static void main(String[] args) {
        new SystemServer().run();
    }

    public SystemServer() {
        // Check for factory test mode.
        mFactoryTestMode = FactoryTest.getMode();
        // Remember if it's runtime restart(when sys.boot_completed is already set) or reboot
        mRuntimeRestart = "1".equals(SystemProperties.get("sys.boot_completed"));

        mRuntimeStartElapsedTime = SystemClock.elapsedRealtime();
        mRuntimeStartUptime = SystemClock.uptimeMillis();
    }
```

这个主函数做了初始化的设置，设置了是否从boot开机之后的标识位。

接着看看run方法：
```java
private void run() {
        try {
//1.记录好native上来的虚拟机参数
           ...
            Looper.prepareMainLooper();
            Looper.getMainLooper().setSlowLogThresholdMs(
                    SLOW_DISPATCH_THRESHOLD_MS, SLOW_DELIVERY_THRESHOLD_MS);

            // Initialize native services.
//初始化的android_servers.so里面包含了大量的native的android的服务
            System.loadLibrary("android_servers");

            // Check whether we failed to shut down last time we tried.
            // This call may not return.
            performPendingShutdown();

            // Initialize the system context.
            createSystemContext();

            // Create the system service manager.
            mSystemServiceManager = new SystemServiceManager(mSystemContext);
            mSystemServiceManager.setStartInfo(mRuntimeRestart,
                    mRuntimeStartElapsedTime, mRuntimeStartUptime);
            LocalServices.addService(SystemServiceManager.class, mSystemServiceManager);
            // Prepare the thread pool for init tasks that can be parallelized
            SystemServerInitThreadPool.get();
        } finally {
            traceEnd();  // InitBeforeStartServices
        }

        // Start services.
        try {
            traceBeginAndSlog("StartServices");
            startBootstrapServices();
            startCoreServices();
            startOtherServices();
            SystemServerInitThreadPool.shutdown();
        } catch (Throwable ex) {
            Slog.e("System", "******************************************");
            Slog.e("System", "************ Failure starting system services", ex);
            throw ex;
        } finally {
            traceEnd();
        }

        StrictMode.initVmDefaults(null);

        ...
        // Loop forever.
        Looper.loop();
        throw new RuntimeException("Main thread loop unexpectedly exited");
    }
```

这里可以初略分为4个步骤：
- 1.记录从zygote过来的虚拟机等runtime参数。初始化android_server的so库，android_server初始化了重要的系统服务的native层
- 2.为SystemServer设置Looper，并进入到loop的循环。等待其他应用的调用
- 3. 初始化SystemServer 的context以及初始化SystemServiceManager
- 4.启动各大主要的系统服务。

直接从第三步开始
## 初始化SystemServer以及SystemServiceManager
看看SystemServer创建整个进程的上下文：
```java
    private void createSystemContext() {
        ActivityThread activityThread = ActivityThread.systemMain();
        mSystemContext = activityThread.getSystemContext();
        mSystemContext.setTheme(DEFAULT_SYSTEM_THEME);

        final Context systemUiContext = activityThread.getSystemUiContext();
        systemUiContext.setTheme(DEFAULT_SYSTEM_THEME);
    }
```

在这里可以知道会通过ActivityThread这个类，
- 1.调用了systemMain方法初始化ActivityThread
- 2. 为系统设置默认主题

### 初始化SystemServicemanager
```java
 mSystemServiceManager = new SystemServiceManager(mSystemContext);
            mSystemServiceManager.setStartInfo(mRuntimeRestart,
                    mRuntimeStartElapsedTime, mRuntimeStartUptime);
            LocalServices.addService(SystemServiceManager.class, mSystemServiceManager);
```
SystemServiceManager作为所有Android服务的启动者和控制者，启动并且加入到LocalServices中。

LocalServices的作用，实际上和SystemServiceManager的作用很相似。LocalService的内部有一个ArrayMap，直接保存着对应服务的实例。

而SystemServiceManager往往是直接通过反射，直接调用带有Context参数的构造函数。


## 启动各大服务
在这一步骤，才是SystemServer核心需要去做的。
```java
try {
            traceBeginAndSlog("StartServices");
            startBootstrapServices();
            startCoreServices();
            startOtherServices();
            SystemServerInitThreadPool.shutdown();
        } catch (Throwable ex) {
            Slog.e("System", "******************************************");
            Slog.e("System", "************ Failure starting system services", ex);
            throw ex;
        } finally {
            traceEnd();
        }
```
在这里面分为三步：
第一步，启动Android启动后立即需要的服务
第二步，启动核心服务
第三步，启动其他服务

```java
private void startBootstrapServices() {
        ...
        Installer installer = mSystemServiceManager.startService(Installer.class);
        mSystemServiceManager.startService(DeviceIdentifiersPolicyService.class);
        mActivityManagerService = mSystemServiceManager.startService(
                ActivityManagerService.Lifecycle.class).getService();
        mActivityManagerService.setSystemServiceManager(mSystemServiceManager);
        mActivityManagerService.setInstaller(installer);

        mPowerManagerService = mSystemServiceManager.startService(PowerManagerService.class);
        mActivityManagerService.initPowerManagement();

        mSystemServiceManager.startService(RecoverySystemService.class);
 
        mSystemServiceManager.startService(LightsService.class);
        if (SystemProperties.getBoolean("config.enable_sidekick_graphics", false)) {
            mSystemServiceManager.startService(WEAR_SIDEKICK_SERVICE_CLASS);
        }
        mDisplayManagerService = mSystemServiceManager.startService(DisplayManagerService.class);
        mSystemServiceManager.startBootPhase(SystemService.PHASE_WAIT_FOR_DEFAULT_DISPLAY);
        traceEnd();

        mPackageManagerService = PackageManagerService.main(mSystemContext, installer,
                mFactoryTestMode != FactoryTest.FACTORY_TEST_OFF, mOnlyCore);
        mFirstBoot = mPackageManagerService.isFirstBoot();
        mPackageManager = mSystemContext.getPackageManager();
  
        if (!mRuntimeRestart && !isFirstBootOrUpgrade()) {
      
        if (!mOnlyCore) {
            boolean disableOtaDexopt = SystemProperties.getBoolean("config.disable_otadexopt",
                    false);
            if (!disableOtaDexopt) {
                traceBeginAndSlog("StartOtaDexOptService");
                try {
                    OtaDexoptService.main(mSystemContext, mPackageManagerService);
                } catch (Throwable e) {
                    reportWtf("starting OtaDexOptService", e);
                } finally {
                    traceEnd();
                }
            }
        }

        mSystemServiceManager.startService(UserManagerService.LifeCycle.class);
        AttributeCache.init(mSystemContext);
        mActivityManagerService.setSystemProcess();
        mDisplayManagerService.setupSchedulerPolicies();

        mSystemServiceManager.startService(new OverlayManagerService(mSystemContext, installer));
  
        mSensorServiceStart = SystemServerInitThreadPool.get().submit(() -> {
            TimingsTraceLog traceLog = new TimingsTraceLog(
                    SYSTEM_SERVER_TIMING_ASYNC_TAG, Trace.TRACE_TAG_SYSTEM_SERVER);
            traceLog.traceBegin(START_SENSOR_SERVICE);
            startSensorService();
        }, START_SENSOR_SERVICE);
    }
```
从此处可以清楚，我们Android系统立即需要的服务有如下几个：
- 1.Installer 在SystemServer端，等待installd的服务通过Binder连接进来。解释这个installd会通过installd.rc读取脚本，生成一个installd的进程。该进程的作用是用来安装软件用的。

- 2. DeviceIdentifiersPolicyService 该服务是为了验证设备身份用。

- 3.ActivityManagerService 这就是我们最为熟悉的AMS，贯穿整个APP应用的服务，可以说熟悉的不能再熟悉了。负责的主要功能是管理，启动应用的Activity。同时把install这个服务装载进去。

- 4. PowerManagerService 这是负责，协助管理电源的服务

- 5. RecoverySystemService 这是负责系统恢复的服务。可以通过socket向底层uncrypt解密进程通信，并且读取/data/cache下的系统升级包，最后系统通过/recovery分区进入到重置模式，开始安装或者重置Android系统。

- 6. LightsService 控制手机的灯的设备。

- 7. DisplayManagerService 这是从4.2开始作为手机管理显示的服务。

- 8. PackageManagerService 这也是个很重要的类，在我分析插件话框架的时候，有着极其重要地位。主要管理这个app应用的package的信息。

- 9. UserManagerService 也是很重要的类。早期的时候Android是一个单用户系统，而此时Android成为了多用户系统，而多用户就是通过这个类去管理

- 10.SensorService 传感器的初始化。

以上为Android系统启动时候，需要立即启动的服务。


## 启动核心服务

```java
    private void startCoreServices() {
       
        mSystemServiceManager.startService(BatteryService.class);
        mSystemServiceManager.startService(UsageStatsService.class);
        mActivityManagerService.setUsageStatsManager(
                LocalServices.getService(UsageStatsManagerInternal.class));
      
        // Tracks whether the updatable WebView is in a ready state and watches for update installs.
        if (mPackageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW)) {
            traceBeginAndSlog("StartWebViewUpdateService");
            mWebViewUpdateService = mSystemServiceManager.startService(WebViewUpdateService.class);
            traceEnd();
        }

        BinderCallsStatsService.start();
    }
```
被Android当成核心服务有一下三个：
- 1. BatteryService 监控电池，电量信息的服务
- 2. UsageStatsService 监控应用服务，常用的应用如检测应用使用时间等。
- 3.如果打开了webview标识位，则启动webview的更新服务

## 启动辅助服务
```java
private void startOtherServices() {
     
        try {
//启动系统各种核心服务
...

//等待到ActivityManagerService启动完成之后，进步处理各个服务
        mActivityManagerService.systemReady(() -> {
            Slog.i(TAG, "Making services ready");
            traceBeginAndSlog("StartActivityManagerReadyPhase");
            mSystemServiceManager.startBootPhase(
                    SystemService.PHASE_ACTIVITY_MANAGER_READY);
            traceEnd();
            traceBeginAndSlog("StartObservingNativeCrashes");
            try {
                mActivityManagerService.startObservingNativeCrashes();
            } catch (Throwable e) {
                reportWtf("observing native crashes", e);
            }
            traceEnd();

            // No dependency on Webview preparation in system server. But this should
            // be completed before allowing 3rd party
            final String WEBVIEW_PREPARATION = "WebViewFactoryPreparation";
            Future<?> webviewPrep = null;
            if (!mOnlyCore && mWebViewUpdateService != null) {
                webviewPrep = SystemServerInitThreadPool.get().submit(() -> {
                    Slog.i(TAG, WEBVIEW_PREPARATION);
                    TimingsTraceLog traceLog = new TimingsTraceLog(
                            SYSTEM_SERVER_TIMING_ASYNC_TAG, Trace.TRACE_TAG_SYSTEM_SERVER);
                    traceLog.traceBegin(WEBVIEW_PREPARATION);
                    ConcurrentUtils.waitForFutureNoInterrupt(mZygotePreload, "Zygote preload");
                    mZygotePreload = null;
                    mWebViewUpdateService.prepareWebViewInSystemServer();
                    traceLog.traceEnd();
                }, WEBVIEW_PREPARATION);
            }

            if (mPackageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
                traceBeginAndSlog("StartCarServiceHelperService");
                mSystemServiceManager.startService(CAR_SERVICE_HELPER_SERVICE_CLASS);
                traceEnd();
            }

            traceBeginAndSlog("StartSystemUI");
            try {
                startSystemUi(context, windowManagerF);
            } catch (Throwable e) {
                reportWtf("starting System UI", e);
            }
            traceEnd();
            traceBeginAndSlog("MakeNetworkManagementServiceReady");
            try {
                if (networkManagementF != null) networkManagementF.systemReady();
            } catch (Throwable e) {
                reportWtf("making Network Managment Service ready", e);
            }
            CountDownLatch networkPolicyInitReadySignal = null;
            if (networkPolicyF != null) {
                networkPolicyInitReadySignal = networkPolicyF
                        .networkScoreAndNetworkManagementServiceReady();
            }
            traceEnd();
            traceBeginAndSlog("MakeIpSecServiceReady");
            try {
                if (ipSecServiceF != null) ipSecServiceF.systemReady();
            } catch (Throwable e) {
                reportWtf("making IpSec Service ready", e);
            }
            traceEnd();
            traceBeginAndSlog("MakeNetworkStatsServiceReady");
            try {
                if (networkStatsF != null) networkStatsF.systemReady();
            } catch (Throwable e) {
                reportWtf("making Network Stats Service ready", e);
            }
            traceEnd();
            traceBeginAndSlog("MakeConnectivityServiceReady");
            try {
                if (connectivityF != null) connectivityF.systemReady();
            } catch (Throwable e) {
                reportWtf("making Connectivity Service ready", e);
            }
            traceEnd();
            traceBeginAndSlog("MakeNetworkPolicyServiceReady");
            try {
                if (networkPolicyF != null) {
                    networkPolicyF.systemReady(networkPolicyInitReadySignal);
                }
            } catch (Throwable e) {
                reportWtf("making Network Policy Service ready", e);
            }
            traceEnd();

            traceBeginAndSlog("StartWatchdog");
            Watchdog.getInstance().start();
            traceEnd();

    ...
        }, BOOT_TIMINGS_TRACE_LOG);
    }
```
而这个时候初始化许许多多的服务，如inputManager，network等等。剩下系统的调用的服务都将会在这里实现。

### ActivityManagerService.systemReady
接着在AMS的systemReady的回调中，初始化需要初始化的服务。而这个systemReady来回变动不少，在7.0版本的时候只有三行，现在把部分重要的功能放到systemReady中完成。

```java
  public void systemReady(final Runnable goingCallback, TimingsTraceLog traceLog) {


        synchronized (this) {
            // Only start up encryption-aware persistent apps; once user is
            // unlocked we'll come back around and start unaware apps
            startPersistentApps(PackageManager.MATCH_DIRECT_BOOT_AWARE);

            // Start up initial activity.
            mBooting = true;
            // Enable home activity for system user, so that the system can always boot. We don't
            // do this when the system user is not setup since the setup wizard should be the one
            // to handle home activity in this case.
            if (UserManager.isSplitSystemUser() &&
                    Settings.Secure.getInt(mContext.getContentResolver(),
                         Settings.Secure.USER_SETUP_COMPLETE, 0) != 0) {
                ComponentName cName = new ComponentName(mContext, SystemUserHomeActivity.class);
                try {
                    AppGlobals.getPackageManager().setComponentEnabledSetting(cName,
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, 0,
                            UserHandle.USER_SYSTEM);
                } catch (RemoteException e) {
                    throw e.rethrowAsRuntimeException();
                }
            }
            startHomeActivityLocked(currentUserId, "systemReady");
          }
...
}
```
systemReady这个方法为当前的进程配置到AMS进程列表中，初始化了PMS，为后续启动Home界面读取Launcher目录下的界面App做准备，最后获取UserController获取当前用户id，使用startHomeActivityLocked开始创建Home界面。


### ActivityManagerService.startHomeActivityLocked
```java
    boolean startHomeActivityLocked(int userId, String reason) {

...

        if (mFactoryTest == FactoryTest.FACTORY_TEST_LOW_LEVEL
                && mTopAction == null) {
            // We are running in factory test mode, but unable to find
            // the factory test app, so just sit around displaying the
            // error message and don't try to start anything.
            return false;
        }
        Intent intent = getHomeIntent();
        ActivityInfo aInfo = resolveActivityInfo(intent, STOCK_PM_FLAGS, userId);
        if (aInfo != null) {
            intent.setComponent(new ComponentName(aInfo.applicationInfo.packageName, aInfo.name));
            // Don't do this if the home app is currently being
            // instrumented.
            aInfo = new ActivityInfo(aInfo);
            aInfo.applicationInfo = getAppInfoForUser(aInfo.applicationInfo, userId);
            ProcessRecord app = getProcessRecordLocked(aInfo.processName,
                    aInfo.applicationInfo.uid, true);
            if (app == null || app.instr == null) {
                intent.setFlags(intent.getFlags() | FLAG_ACTIVITY_NEW_TASK);
                final int resolvedUserId = UserHandle.getUserId(aInfo.applicationInfo.uid);
                // For ANR debugging to verify if the user activity is the one that actually
                // launched.
                final String myReason = reason + ":" + userId + ":" + resolvedUserId;
                mActivityStartController.startHomeActivity(intent, aInfo, myReason);
            }
        } else {
            Slog.wtf(TAG, "No home screen found for " + intent, new Throwable());
        }

        return true;
    }
```

从这里可以清晰的知道主要做的事情有两个：
- 1.第一步，通过getHomeIntent通过PackageManagerService获取设置为界面的包。并且获取对应的ActivityInfo。
```java
Intent getHomeIntent() {
        Intent intent = new Intent(mTopAction, mTopData != null ? Uri.parse(mTopData) : null);
        intent.setComponent(mTopComponent);
        intent.addFlags(Intent.FLAG_DEBUG_TRIAGED_MISSING);
        if (mFactoryTest != FactoryTest.FACTORY_TEST_LOW_LEVEL) {
            intent.addCategory(Intent.CATEGORY_HOME);
        }
        return intent;
    }
```
HomeIntent原理解释添加一个Intent.CATEGORY_HOME的标识位，通过PMS去寻找，添加android.intent.category.HOME的AndroidManifest.xml的包。
```
<category android:name="android.intent.category.HOME" />
```

- 2.第二步，通过分配ProcessRecord并且通过ActivityStartController启动Home界面。

这个新的类，从android 9.0开始将ActivityStack的职责拆开一部分交给ActivityStartController。这个之后，我将整个Android 9.0的Activity启动重新讲解一遍，在ActivityThread取消了核心消息中心mH（一个Handler），把每个生命周期交给一个状态机去完成。这个之后再说专门开一篇文章说一说。

### ActivityStartController 的startHomeActivity
```java
    void startHomeActivity(Intent intent, ActivityInfo aInfo, String reason) {
        mSupervisor.moveHomeStackTaskToTop(reason);

        mLastHomeActivityStartResult = obtainStarter(intent, "startHomeActivity: " + reason)
                .setOutActivity(tmpOutRecord)
                .setCallingUid(0)
                .setActivityInfo(aInfo)
                .execute();
        mLastHomeActivityStartRecord = tmpOutRecord[0];
        if (mSupervisor.inResumeTopActivity) {
            // If we are in resume section already, home activity will be initialized, but not
            // resumed (to avoid recursive resume) and will stay that way until something pokes it
            // again. We need to schedule another resume.
            mSupervisor.scheduleResumeTopActivities();
        }
```
关键方法为两个moveHomeStackTaskToTop 以及scheduleResumeTopActivities
#### 1. moveHomeStackTaskToTop
```java
    void moveHomeStackTaskToTop() {
        if (!isActivityTypeHome()) {
            throw new IllegalStateException("Calling moveHomeStackTaskToTop() on non-home stack: "
                    + this);
        }
        final int top = mTaskHistory.size() - 1;
        if (top >= 0) {
            final TaskRecord task = mTaskHistory.get(top);
            if (DEBUG_TASKS || DEBUG_STACK) Slog.d(TAG_STACK,
                    "moveHomeStackTaskToTop: moving " + task);
            mTaskHistory.remove(top);
            mTaskHistory.add(top, task);
            updateTaskMovement(task, true);
        }
    }
```
这里是先从TaskHistory这个任务栈中，如果此时Activity栈有Activity的存在，则把Home的Activity更新到顶部。

#### 2.scheduleResumeTopActivities
```
    final void scheduleResumeTopActivities() {
        if (!mHandler.hasMessages(RESUME_TOP_ACTIVITY_MSG)) {
            mHandler.sendEmptyMessage(RESUME_TOP_ACTIVITY_MSG);
        }
    }
```

此时由AMS内部的Handler
```java
private final class ActivityStackSupervisorHandler extends Handler 
```
这个Handler就是在SystemServer生成的looper传进来。其中RESUME_TOP_ACTIVITY_MSG的分支将会调用resumeFocusedStackTopActivityLocked。
```java
    boolean resumeFocusedStackTopActivityLocked(
            ActivityStack targetStack, ActivityRecord target, ActivityOptions targetOptions) {

        if (!readyToResume()) {
            return false;
        }

        if (targetStack != null && isFocusedStack(targetStack)) {
            return targetStack.resumeTopActivityUncheckedLocked(target, targetOptions);
        }

        final ActivityRecord r = mFocusedStack.topRunningActivityLocked();
        if (r == null || !r.isState(RESUMED)) {
            mFocusedStack.resumeTopActivityUncheckedLocked(null, null);
        } else if (r.isState(RESUMED)) {
            // Kick off any lingering app transitions form the MoveTaskToFront operation.
            mFocusedStack.executeAppTransition(targetOptions);
        }

        return false;
    }
```

此时将会判断到，当前栈对应的ActivityRecord是否存在。此时是第一次打开的所以此时ActivityRecord还没有生成，将会走resumeTopActivityUncheckedLocked。
```java
    private boolean resumeTopActivityInnerLocked(ActivityRecord prev, ActivityOptions options) {
...
        if (prev != null && prev != next) {
...
        } else {
            // Whoops, need to restart this activity!
            if (!next.hasBeenLaunched) {
                next.hasBeenLaunched = true;
            } else {
                if (SHOW_APP_STARTING_PREVIEW) {
                    next.showStartingWindow(null /* prev */, false /* newTask */,
                            false /* taskSwich */);
                }
                if (DEBUG_SWITCH) Slog.v(TAG_SWITCH, "Restarting: " + next);
            }
            if (DEBUG_STATES) Slog.d(TAG_STATES, "resumeTopActivityLocked: Restarting " + next);
            mStackSupervisor.startSpecificActivityLocked(next, true, true);
        }

        if (DEBUG_STACK) mStackSupervisor.validateTopActivitiesLocked();
        return true;
    }
```

由于此时必定不存在Activity，此时必定通过ActivityStackSupervisor启动startSpecificActivityLocked。

此时通过startSpecificActivityLocked去启动Activity。接着如果是Android7.0的话，我之前的文章就解析过了。之后将会有一篇解析Android P Activity的启动。
## Launcher
这么，假设开始进入Google默认的Launcher3里面。那么我们又是怎么点击App应用，以及点击App应用图标进入到我们的应用中呢？

让我们看看Launcher界面中的onCreate中setupViews方法,这里我们只关注App Icon的容器,不去管拖拽，删除等逻辑，只管App信息是如何装载的


接下来，这个Home读取App数据的方式有点复杂，但是里面的很多东西值得借鉴，如果有兴趣的读者，可以去看看。

这里只说出其中的原理，以及几个关键职责的类。
- 1. LauncherModel管理Launcher界面的中的数据，统合管理App，AppWidget等的读取
- 2. AllAppList 存放AppInfo的对象
- 3. LoaderResults 这是读取数据之后的结果对象
- 4.LoaderTask 真正异步加载App信息的类
- 5.AllAppsContainerView App图标的容器
先来看看Launcher几处关键加载数据以及初始化的view的位置：
文件：/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[Launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/)/[launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/)/[Launcher.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/Launcher.java)


##### onCreate
```java
@Override
    protected void onCreate(Bundle savedInstanceState) {
    ...
        super.onCreate(savedInstanceState);
...      
        LauncherAppState app = LauncherAppState.getInstance(this);
        mOldConfig = new Configuration(getResources().getConfiguration());
        mModel = app.setLauncher(this);
     
        mAllAppsController = new AllAppsTransitionController(this);
        mStateManager = new LauncherStateManager(this);
        UiFactory.onCreate(this);

    

        mLauncherView = LayoutInflater.from(this).inflate(R.layout.launcher, null);
...
        setupViews();
     ...
        mAppTransitionManager = LauncherAppTransitionManager.newInstance(this);

...
        if (!mModel.startLoader(currentScreen)) {
            if (!internalStateHandled) {
                // If we are not binding synchronously, show a fade in animation when
                // the first page bind completes.
                mDragLayer.getAlphaProperty(ALPHA_INDEX_LAUNCHER_LOAD).setValue(0);
            }
        } else {
            // Pages bound synchronously.
            mWorkspace.setCurrentPage(currentScreen);

            setWorkspaceLoading(true);
        }

        // For handling default keys
        setDefaultKeyMode(DEFAULT_KEYS_SEARCH_LOCAL);

        setContentView(mLauncherView);
        getRootView().dispatchInsets();

        ...
    }
```
剩下的都是我们需要关注的核心方法。我们就以onCreate的方法，为主核心，开始分析google的Home界面的原理。

初始化大致分为三步：
- 1.初始化LauncherModel
- 2.初始化AllAppContainer
- 3. 调用startLoader开始加载

我们先看看LauncherAppState 的 setLauncher方法
文件：
/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[Launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/)/[launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/)/[LauncherAppState.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/LauncherAppState.java)

```java
    LauncherModel setLauncher(Launcher launcher) {
        getLocalProvider(mContext).setLauncherProviderChangeListener(launcher);
        mModel.initialize(launcher);
        return mModel;
    }

```
此时Launcher 初始化整个界面的核心Model，Laucher是通过init方法初始化。初始化好AllAppList。

##### 2.初始化app icon的view容器
```java
private void setupViews() {
...

        // Setup Apps
        mAppsView = findViewById(R.id.apps_view);

        // Setup the drag controller (drop targets have to be added in reverse order in priority)
        mDragController.setMoveTarget(mWorkspace);
        mDropTargetBar.setup(mDragController);

        mAllAppsController.setupViews(mAppsView);
    }
```
准备好基础数据容器，接下来就是初始化view。

mAppsView就是我们的App icon装载的容器view，通过AllAppsTransitionController这个类去控制。

#### LauncherModel. startLoader
```java
    public boolean startLoader(int synchronousBindPage) {
        // Enable queue before starting loader. It will get disabled in Launcher#finishBindingItems
        InstallShortcutReceiver.enableInstallQueue(InstallShortcutReceiver.FLAG_LOADER_RUNNING);
        synchronized (mLock) {
            // Don't bother to start the thread if we know it's not going to do anything
            if (mCallbacks != null && mCallbacks.get() != null) {
...
                } else {
                    startLoaderForResults(loaderResults);
                }
            }
        }
        return false;
    }
```

```
    public void startLoaderForResults(LoaderResults results) {
        synchronized (mLock) {
            stopLoader();
            mLoaderTask = new LoaderTask(mApp, mBgAllAppsList, sBgDataModel, results);
            runOnWorkerThread(mLoaderTask);
        }
    }
```

因为此时还没有加载过Home此时会调用下方的方法，启动LoadTask的方法，开启线程，加载app的数据。

### LoadTask
文件：
/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[Launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/)/[launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/)/[model](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/model/)/[LoaderTask.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/model/LoaderTask.java)

直接看看LoadTask中的run方法。
```java
public void run() {
        synchronized (this) {
            // Skip fast if we are already stopped.
            if (mStopped) {
                return;
            }
        }
      ...
      
        try (LauncherModel.LoaderTransaction transaction = mApp.getModel().beginLoader(this)) {
          ...
          loadAllApps();

          mResults.bindAllApps();
          ...
        } catch (CancellationException e) {
            // Loader stopped, ignore
            TraceHelper.partitionSection(TAG, "Cancelled");
        }
  
    }
```
这里，我们只关注读取App信息的方法。

```java
    private void loadAllApps() {
        final List<UserHandle> profiles = mUserManager.getUserProfiles();

        // Clear the list of apps
        mBgAllAppsList.clear();
        for (UserHandle user : profiles) {
            // Query for the set of apps
            final List<LauncherActivityInfo> apps = mLauncherApps.getActivityList(null, user);
            // Fail if we don't have any apps
            // TODO: Fix this. Only fail for the current user.
            if (apps == null || apps.isEmpty()) {
                return;
            }
            boolean quietMode = mUserManager.isQuietModeEnabled(user);
            // Create the ApplicationInfos
            for (int i = 0; i < apps.size(); i++) {
                LauncherActivityInfo app = apps.get(i);
                // This builds the icon bitmaps.
                mBgAllAppsList.add(new AppInfo(app, user, quietMode), app);
            }
        }

        if (FeatureFlags.LAUNCHER3_PROMISE_APPS_IN_ALL_APPS) {
            // get all active sessions and add them to the all apps list
            for (PackageInstaller.SessionInfo info :
                    mPackageInstaller.getAllVerifiedSessions()) {
                mBgAllAppsList.addPromiseApp(mApp.getContext(),
                        PackageInstallerCompat.PackageInstallInfo.fromInstallingState(info));
            }
        }

        mBgAllAppsList.added = new ArrayList<>();
    }
```
mBgAllAppsList实际上就是我上面提到的AllAppList对象，通过mLauncherApps（这是通过Context.LAUNCHER_SERVICE）读取到的App相关的数据，存储到这个对象中。

此时已经准备好了列表数据了。


### AllAppContainer
已经准备好了数据，通过LoadResult的bindApp方法回调到上层，刷新AllAppContainer的数据。

文件：
/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[Launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/)/[launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/)/[allapps](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/allapps/)/[AllAppsContainerView.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/allapps/AllAppsContainerView.java)

我们看看AllAppContainer的构造函数：
```java
 public AllAppsContainerView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);

...
        mAH = new AdapterHolder[2];
        mAH[AdapterHolder.MAIN] = new AdapterHolder(false /* isWork */);
        mAH[AdapterHolder.WORK] = new AdapterHolder(true /* isWork */);

        mAllAppsStore.addUpdateListener(this::onAppsUpdated);

...
    }
```
在这个容器中AdapterHolder这个对象十分重要，这可以看作就是我们常见的，用来展示的App icon的页面。

还记得上面的bindApp函数吗。通过这个方法将会回到Launcher上通过bindApplication，把数据绑定到AllAppContainer的AppStore中。一旦更新了就在这个AppStore中唤醒了onAppsUpdated方法。

```java
    private void onAppsUpdated() {
        if (FeatureFlags.ALL_APPS_TABS_ENABLED) {
            boolean hasWorkApps = false;
            for (AppInfo app : mAllAppsStore.getApps()) {
                if (mWorkMatcher.matches(app, null)) {
                    hasWorkApps = true;
                    break;
                }
            }
            rebindAdapters(hasWorkApps);
}
      
```

此时，就像我们正常的函数一样，将数据绑定到AdapterHolder中的RecyclerView。
```java
   private void rebindAdapters(boolean showTabs, boolean force) {
        if (showTabs == mUsingTabs && !force) {
            return;
        }
        replaceRVContainer(showTabs);
        mUsingTabs = showTabs;

        mAllAppsStore.unregisterIconContainer(mAH[AdapterHolder.MAIN].recyclerView);
        mAllAppsStore.unregisterIconContainer(mAH[AdapterHolder.WORK].recyclerView);

        if (mUsingTabs) {
            mAH[AdapterHolder.MAIN].setup(mViewPager.getChildAt(0), mPersonalMatcher);
            mAH[AdapterHolder.WORK].setup(mViewPager.getChildAt(1), mWorkMatcher);
            onTabChanged(mViewPager.getNextPage());
        } else {
            mAH[AdapterHolder.MAIN].setup(findViewById(R.id.apps_list_view), null);
            mAH[AdapterHolder.WORK].recyclerView = null;
        }
        setupHeader();

        mAllAppsStore.registerIconContainer(mAH[AdapterHolder.MAIN].recyclerView);
        mAllAppsStore.registerIconContainer(mAH[AdapterHolder.WORK].recyclerView);
    }
```
此时我们再看看AdapterHolder.setup的方法。
```java
        void setup(@NonNull View rv, @Nullable ItemInfoMatcher matcher) {
            appsList.updateItemFilter(matcher);
            recyclerView = (AllAppsRecyclerView) rv;
            recyclerView.setEdgeEffectFactory(createEdgeEffectFactory());
            recyclerView.setApps(appsList, mUsingTabs);
            recyclerView.setLayoutManager(layoutManager);
            recyclerView.setAdapter(adapter);
            recyclerView.setHasFixedSize(true);
            // No animations will occur when changes occur to the items in this RecyclerView.
            recyclerView.setItemAnimator(null);
            FocusedItemDecorator focusedItemDecorator = new FocusedItemDecorator(recyclerView);
            recyclerView.addItemDecoration(focusedItemDecorator);
            adapter.setIconFocusListener(focusedItemDecorator.getFocusListener());
            applyVerticalFadingEdgeEnabled(verticalFadingEdge);
            applyPadding();
        }
```

到这里，所以做过Android的读者都立即明白接下来的源码将从哪里入手。
我们直接看这个adapter适配器中的点击事件究竟是怎么做的。


#### AllAppsGridAdapter
文件：
/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[Launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/)/[launcher3](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/)/[allapps](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/allapps/)/[AllAppsGridAdapter.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/Launcher3/src/com/android/launcher3/allapps/AllAppsGridAdapter.java)
```java
    @Override
    public ViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
        switch (viewType) {
            case VIEW_TYPE_ICON:
                BubbleTextView icon = (BubbleTextView) mLayoutInflater.inflate(
                        R.layout.all_apps_icon, parent, false);
                icon.setOnClickListener(ItemClickHandler.INSTANCE);
                icon.setOnLongClickListener(ItemLongClickListener.INSTANCE_ALL_APPS);
                icon.setLongPressTimeout(ViewConfiguration.getLongPressTimeout());
                icon.setOnFocusChangeListener(mIconFocusListener);

                // Ensure the all apps icon height matches the workspace icons in portrait mode.
                icon.getLayoutParams().height = mLauncher.getDeviceProfile().allAppsCellHeightPx;
                return new ViewHolder(icon);
...
}
```

这里ItemClickHandler.INSTANCE就是核心：
```java
public static final OnClickListener INSTANCE = ItemClickHandler::onClick;

    private static void onClick(View v) {
        // Make sure that rogue clicks don't get through while allapps is launching, or after the
        // view has detached (it's possible for this to happen if the view is removed mid touch).
        if (v.getWindowToken() == null) {
            return;
        }

        Launcher launcher = Launcher.getLauncher(v.getContext());
        if (!launcher.getWorkspace().isFinishedSwitchingState()) {
            return;
        }

        Object tag = v.getTag();
        if (tag instanceof ShortcutInfo) {
            onClickAppShortcut(v, (ShortcutInfo) tag, launcher);
        } else if (tag instanceof FolderInfo) {
            if (v instanceof FolderIcon) {
                onClickFolderIcon(v);
            }
        } else if (tag instanceof AppInfo) {
            startAppShortcutOrInfoActivity(v, (AppInfo) tag, launcher);
        } else if (tag instanceof LauncherAppWidgetInfo) {
            if (v instanceof PendingAppWidgetHostView) {
                onClickPendingWidget((PendingAppWidgetHostView) v, launcher);
            }
        }
    }
```

这里就是处理各种点击事件的核心方法。而我们的tag必定是AppInfo，我们看看这个方法，
```java
private static void startAppShortcutOrInfoActivity(View v, ItemInfo item, Launcher launcher) {
        ...
        launcher.startActivitySafely(v, intent, item);
    }
```

从这里何以得知将会回调上Launcher的startActivitySafely方法。最后调用startActivitySafely。
```java
    public boolean startActivitySafely(View v, Intent intent, ItemInfo item) {
        if (mIsSafeModeEnabled && !Utilities.isSystemApp(this, intent)) {
            Toast.makeText(this, R.string.safemode_shortcut_error, Toast.LENGTH_SHORT).show();
            return false;
        }

        // Only launch using the new animation if the shortcut has not opted out (this is a
        // private contract between launcher and may be ignored in the future).
        boolean useLaunchAnimation = (v != null) &&
                !intent.hasExtra(INTENT_EXTRA_IGNORE_LAUNCH_ANIMATION);
        Bundle optsBundle = useLaunchAnimation
                ? getActivityLaunchOptionsAsBundle(v)
                : null;

        UserHandle user = item == null ? null : item.user;

        // Prepare intent
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (v != null) {
            intent.setSourceBounds(getViewBounds(v));
        }
        try {
            boolean isShortcut = Utilities.ATLEAST_MARSHMALLOW
                    && (item instanceof ShortcutInfo)
                    && (item.itemType == Favorites.ITEM_TYPE_SHORTCUT
                    || item.itemType == Favorites.ITEM_TYPE_DEEP_SHORTCUT)
                    && !((ShortcutInfo) item).isPromise();
            if (isShortcut) {
                // Shortcuts need some special checks due to legacy reasons.
                startShortcutIntentSafely(intent, optsBundle, item);
            } else if (user == null || user.equals(Process.myUserHandle())) {
                // Could be launching some bookkeeping activity
                startActivity(intent, optsBundle);
            } else {
                LauncherAppsCompat.getInstance(this).startActivityForProfile(
                        intent.getComponent(), user, intent.getSourceBounds(), optsBundle);
            }
            getUserEventDispatcher().logAppLaunch(v, intent);
            return true;
        } catch (ActivityNotFoundException|SecurityException e) {
            Toast.makeText(this, R.string.activity_not_found, Toast.LENGTH_SHORT).show();
            Log.e(TAG, "Unable to launch. tag=" + item + " intent=" + intent, e);
        }
        return false;
    }
```

关注到核心点，此时将会调用startActivity(intent, optsBundle);启动Activity。

此时问题来了，说好的检测AndroidManifest.xml呢？不是说好的调用这个方法必定回检测一次，不然会报异常吗？

记住此时是通过包名+category为MAIN的隐式调用，同时PMS将会在LauncherActivityInfo中做了进一步的解析。所以没有在插件化框架分析时候的苦恼了。

# 总结
老规矩，画两张张时序图总结一下。
![Home的启动.jpg](https://upload-images.jianshu.io/upload_images/9880421-530f9d793e7b7c9a.jpg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

完整的图，可以等到，之后我写Android P的Activity启动流程看，也可以参照我在插件化框架一文。

下面是Home app按钮点击的时序图
![Home数据的加载与点击.jpg](https://upload-images.jianshu.io/upload_images/9880421-e2ff96cbc0362c3f.jpg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


Google写的Home的界面还有挺多有趣的没有解析，但是这里我只关注App图标如何点击进来的。最后会通过startActivitySafely进来。

本文总结了SystemServer启动的核心服务，这些服务对于android来说重要，而且从startBootStrapServices中启动的服务里面的源码，也是作为常考的面试题。可以说是重中之重。之后有机会去阅读源码，会慢慢的全部解析一边。

然而这个系列主要是为了我个人的复习和巩固的，也是面向基础，个人作为巩固基础的系列，估计只会挑出PMS和AMS两者来解析。

下一篇，我将会解析Binder这个贯穿整个Android系统的驱动。只有真正的懂了它，才敢说对Android系统窥见了冰山一角。才会继续解析Activity的启动流程。























