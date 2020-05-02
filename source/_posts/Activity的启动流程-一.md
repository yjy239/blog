---
title: Android 重学系列 Activity的启动流程(一)
top: false
cover: false
date: 2019-06-09 20:39:30
img:
description:
author: yjy239
summary:
tags:
- Android Framework
- Android
---

如果遇到错误，请在本文地址： [https://www.jianshu.com/p/91feec107d4b](https://www.jianshu.com/p/91feec107d4b)

# 背景
经过前期的奋斗，我们终于来到Android开发者熟悉的部分，四大组件之一的Activity。Activity可以说是每个Android程序员最为熟悉的组件，其承载App应用和人交互的桥梁。因此想要明白Android我们必须要把Activity摸透。由于我在3年前已经写过一次Activity的启动流程的解析，因此这次我尝试着尽可能的看到详细的源码，来和大家聊聊在Android 9.0中的Activity的启动。

# 正文

## 比较Android9.0和Android 7.0
首先看看startActivity在Android7.0的时序图。
![Activity的启动流程.jpg](/images/Activity的启动流程.jpg)

这里实际上就是从Android诞生之初，一直到Android 9.0的启动主要脉络。实际上外面的文章已经讲得滚瓜烂熟。包括我也看这些源码了这个不下10遍，应该更多。

本文会继续看看Android 9.0的Acitvity启动流程的源码。看看Android 9.0比起7.0来说进步在哪里。

我们先上时序图：
![Android9.0中Activity启动流程.png](/images/Android9.0中Activity启动流程.png)

注意：红色线代表跨越Binder一次进程


从时序图上，无论怎么Android的启动架构怎么演变，其根本流程都没有变。Android都是通过Binder通行到AMS，接着经过AMS的一系列中栈处理之后，把ActivityRecord返回到AppThread(App进程中)。

Android9.0看起来确实比Android7.0的经历的步骤更多，但是我们深入看源码发现Android9.0比起7.0的易读（如果对4.4的启动流程可以看我毕业那篇文章）。

主要的原因，我们可以从Android 9.0的时序图中可以到，在Android 9.0中，AMS不再是通过简单的调用IPC来控制App端的Activity生命周期。而是通过一个状态设计模式，将每个Activity每一个生命周期都抽象成一个状态，接着通过状态机去管理整个生命周期。

实际上这种思想在我平时写代码的时候，也经常用到。往往用在需求比较复杂，而且状态比较多，还会不断切换那种。

本文将会着重打讨论AMS中的流程。再次聊App进程准备工作也未免有点滥竽充数的嫌疑。让我们站在更高的高度，去看看AMS在启动中的细节以及设计思路。

提示：从上面几篇文章能看到，实际上AMS隶属于SystemServer进程。和App进程不在同一处。

## 启动流程中AMS内的各个角色
在Activity中启动中，AMS担任最为重要的角色，下面列出的都是AMS中承担各个主要功能的类
- 1. ActivityStack 代表着Activity的栈(不精准稍后会具体解释)
- 2.ActivityStarter 代表着Activity正式启动的控制类
- 3.ActivityManagerService 代表着一切Activity行为在系统中的控制中心
- 4.ActivityStackSupervisor 代表着ActivityStack的监控中心

实际上对于我们来说在整个Activity的启动需要关注这么四个核心类。
而在这里面往往涉及到Activity栈的变化，而这个过程涉及到的核心类有：
- 1.ActivityRecord 
- 2.TaskRecord 
- 3.mRecentTasks 
- 4.mTaskHistory 
- 5.ProcessRecord 

我们稍微根据源码时序图，来看看AMS中的启动流程。上面的数据结构将会一一剖析。

### AMS跨进程通信创建Activity，第一步。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)

```java
public final int startActivityAsUser(IApplicationThread caller, String callingPackage,
            Intent intent, String resolvedType, IBinder resultTo, String resultWho, int requestCode,
            int startFlags, ProfilerInfo profilerInfo, Bundle bOptions, int userId,
            boolean validateIncomingUser) {
        enforceNotIsolatedCaller("startActivity");

        userId = mActivityStartController.checkTargetUser(userId, validateIncomingUser,
                Binder.getCallingPid(), Binder.getCallingUid(), "startActivityAsUser");


        return mActivityStartController.obtainStarter(intent, "startActivityAsUser")
                .setCaller(caller)//调用方的AppThread的IBinder
                .setCallingPackage(callingPackage)//调用方的包名
                .setResolvedType(resolvedType)//调用type
                .setResultTo(resultTo)//调用方的ActivityClientRecord的binder（实际上是AMS的ActivityRecord对应在App端的binder对象）
                .setResultWho(resultWho)//调用方的标示
                .setRequestCode(requestCode)//需要返回的requestCode
                .setStartFlags(startFlags)//启动标志位
                .setProfilerInfo(profilerInfo)//启动时带上的权限文件对象
                .setActivityOptions(bOptions)//ActivityOptions的Activity的启动项,在一般的App中此时是null，不需要关注
                .setMayWait(userId)//是否是同步打开Actvivity 默认一般是true
                .execute();//执行方法。
```

从这里面节能很清晰的明白，在启动过程中需要什么参数。比起当初Android7.0的源码看来设计上确实进步不少，虽然看起来像是一个建造者设计模式。但是实际上工厂设计模式+享元设计+链式调用。通过obtainStarter把DefaultFactory从mStarterPool中获取一个ActivityStarter(池子中最多设置3个)，接着通过链式调用，把启动时需要的参数传递进去。

当设置完成之后，我们直接看看execute方法.

### ActivityStarter 正式开始启动Activity
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStarter.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStarter.java)

```java
 int execute() {
        try {
            // TODO(b/64750076): Look into passing request directly to these methods to allow
            // for transactional diffs and preprocessing.
            if (mRequest.mayWait) {
                return startActivityMayWait(mRequest.caller, mRequest.callingUid,
                        mRequest.callingPackage, mRequest.intent, mRequest.resolvedType,
                        mRequest.voiceSession, mRequest.voiceInteractor, mRequest.resultTo,
                        mRequest.resultWho, mRequest.requestCode, mRequest.startFlags,
                        mRequest.profilerInfo, mRequest.waitResult, mRequest.globalConfig,
                        mRequest.activityOptions, mRequest.ignoreTargetSecurity, mRequest.userId,
                        mRequest.inTask, mRequest.reason,
                        mRequest.allowPendingRemoteAnimationRegistryLookup);
            } else {
           ...
            }
        } finally {
            onExecutionComplete();
        }
    }
```

从execute我们可以看到，在这个过程Google工程师灵活的运用了try-final机制，通过onExecutionComplete在ActivityStartController清除数据放回startPool池子中。提一句实际上这种设计，我在Glide等经典第三方库已经看到了无数遍。

此时我们是一个同步操作，所以看看startActivityMayWait方法。

## startActivityMayWait
这段我们分为三段来看：
##### 1.从PackageManagerService准备activity需要的数据
```java
private int startActivityMayWait(IApplicationThread caller, int callingUid,
            String callingPackage, Intent intent, String resolvedType,
            IVoiceInteractionSession voiceSession, IVoiceInteractor voiceInteractor,
            IBinder resultTo, String resultWho, int requestCode, int startFlags,
            ProfilerInfo profilerInfo, WaitResult outResult,
            Configuration globalConfig, SafeActivityOptions options, boolean ignoreTargetSecurity,
            int userId, TaskRecord inTask, String reason,
            boolean allowPendingRemoteAnimationRegistryLookup) {
      ....
      
        ResolveInfo rInfo = mSupervisor.resolveIntent(intent, resolvedType, userId,
                0 /* matchFlags */,
                        computeResolveFilterUid(
                                callingUid, realCallingUid, mRequest.filterCallingUid));
        if (rInfo == null) {
            UserInfo userInfo = mSupervisor.getUserInfo(userId);
            if (userInfo != null && userInfo.isManagedProfile()) {
                // Special case for managed profiles, if attempting to launch non-cryto aware
                // app in a locked managed profile from an unlocked parent allow it to resolve
                // as user will be sent via confirm credentials to unlock the profile.
                UserManager userManager = UserManager.get(mService.mContext);
                boolean profileLockedAndParentUnlockingOrUnlocked = false;
                long token = Binder.clearCallingIdentity();
                try {
                    UserInfo parent = userManager.getProfileParent(userId);
                    profileLockedAndParentUnlockingOrUnlocked = (parent != null)
                            && userManager.isUserUnlockingOrUnlocked(parent.id)
                            && !userManager.isUserUnlockingOrUnlocked(userId);
                } finally {
                    Binder.restoreCallingIdentity(token);
                }
                if (profileLockedAndParentUnlockingOrUnlocked) {
                    rInfo = mSupervisor.resolveIntent(intent, resolvedType, userId,
                            PackageManager.MATCH_DIRECT_BOOT_AWARE
                                    | PackageManager.MATCH_DIRECT_BOOT_UNAWARE,
                            computeResolveFilterUid(
                                    callingUid, realCallingUid, mRequest.filterCallingUid));
                }
            }
        }
        // Collect information about the target of the Intent.
        ActivityInfo aInfo = mSupervisor.resolveActivity(intent, rInfo, startFlags, profilerInfo);
```
可以大致分为以下3步：
1.从ActivityStackSupervisor调用PMS获取ResolveInfo。
```java
private ResolveInfo resolveIntentInternal(Intent intent, String resolvedType,
            int flags, int userId, boolean resolveForStart, int filterCallingUid) {
        try {

            if (!sUserManager.exists(userId)) return null;
            final int callingUid = Binder.getCallingUid();
            flags = updateFlagsForResolve(flags, userId, intent, filterCallingUid, resolveForStart);
            mPermissionManager.enforceCrossUserPermission(callingUid, userId,
                    false /*requireFullPermission*/, false /*checkShell*/, "resolve intent");

            final List<ResolveInfo> query = queryIntentActivitiesInternal(intent, resolvedType,
                    flags, filterCallingUid, userId, resolveForStart, true /*allowDynamicSplits*/);

            final ResolveInfo bestChoice =
                    chooseBestActivity(intent, resolvedType, flags, query, userId);
            return bestChoice;
        } finally {
          ....
        }
    }
```
从上面代码，我们可以看到，这个方法是通过intent来从找到一个最合适的选择。我们可以推测，实际上这个ResolveInfo是指当我们安装了App之后，加载到PackageManagerService(后面称PMS)系统中的AndroidManifest.xml的数据。

queryIntentActivitiesInternal分步骤来说：
- 1.查看当前Intent是否是显式Intent。是则取出其中的class对象和AndroidManifest的进行匹配，匹配成功返回。
- 2.如果没有指定包名则全系统的查找匹配intent
- 3.如果指定包名，则从当前的包名寻找匹配规则相符合的intent的Activity

因此此时可能会匹配多个合适的Intent，再通过chooseBestActivity进一步筛选Activity。

为什么加上这一段，实际上这一段有一个关键的逻辑就是AppLink。开发经常用到，在AndroidManifest中设置好schme等Intent参数，让外部app来唤醒我们自己的app。
当唤醒的目的地只有一个直接返回，如果有多个则替换intent中的类，变成系统的ResolveActivity。用来选择我们的目的App，如下图。
![AppLink.png](/images/AppLink.png)

- 2.查不到ResolveInfo则尝试从直接启动中获取
自Android 5.0之后。Android系统将开始支持多用户系统，这些用户的配置都由UserManager控制，其中AccountManager则是控制每个用户下的账号。

在Android7.0之后，为应用新增了一种启动模式Direct Boot(直接启动模式)。这种模式是指设备启动后进入的一个新模式，直到用户解锁（unlock）设备此阶段结束。这种模式，会为程序创建Device protected storage私有的存储空间。

这种模式比较特殊，我们需要在AndroidManifest中设置 android:directBootAware="true"。

因此，这种模式下，需要唤醒特殊的Activity，确定此时已经解锁，需要从特殊的私有空间去查找对应的ResolveInfo。

- 3.通过PMS的getActivityInfo读取ActivityInfo

当我们确定好了ResolveInfo，就要AMS就通过resolveActivity从PMS读取ResolveInfo中的Activity信息。
```java
   ActivityInfo resolveActivity(Intent intent, ResolveInfo rInfo, int startFlags,
            ProfilerInfo profilerInfo) {
        final ActivityInfo aInfo = rInfo != null ? rInfo.activityInfo : null;
        if (aInfo != null) {
            intent.setComponent(new ComponentName(
                    aInfo.applicationInfo.packageName, aInfo.name));

            // Don't debug things in the system process
            if (!aInfo.processName.equals("system")) {
                if ((startFlags & ActivityManager.START_FLAG_DEBUG) != 0) {
                    mService.setDebugApp(aInfo.processName, true, false);
                }

   ...
        return aInfo;
    }
```
找到后，就显示的设置ComponentName，包名和类名。


##### 2.处理重量级进程
```java
  synchronized (mService) {
            final ActivityStack stack = mSupervisor.mFocusedStack;
            stack.mConfigWillChange = globalConfig != null
                    && mService.getGlobalConfiguration().diff(globalConfig) != 0;
...

            final long origId = Binder.clearCallingIdentity();

            if (aInfo != null &&
                    (aInfo.applicationInfo.privateFlags
                            & ApplicationInfo.PRIVATE_FLAG_CANT_SAVE_STATE) != 0 &&
                    mService.mHasHeavyWeightFeature) {
                // This may be a heavy-weight process!  Check to see if we already
                // have another, different heavy-weight process running.
                if (aInfo.processName.equals(aInfo.applicationInfo.packageName)) {
                    final ProcessRecord heavy = mService.mHeavyWeightProcess;
                    if (heavy != null && (heavy.info.uid != aInfo.applicationInfo.uid
                            || !heavy.processName.equals(aInfo.processName))) {
                        int appCallingUid = callingUid;
                        if (caller != null) {
                            ProcessRecord callerApp = mService.getRecordForAppLocked(caller);
                            if (callerApp != null) {
                                appCallingUid = callerApp.info.uid;
                            } else {
                                Slog.w(TAG, "Unable to find app for caller " + caller
                                        + " (pid=" + callingPid + ") when starting: "
                                        + intent.toString());
                                SafeActivityOptions.abort(options);
                                return ActivityManager.START_PERMISSION_DENIED;
                            }
                        }

                        IIntentSender target = mService.getIntentSenderLocked(
                                ActivityManager.INTENT_SENDER_ACTIVITY, "android",
                                appCallingUid, userId, null, null, 0, new Intent[] { intent },
                                new String[] { resolvedType }, PendingIntent.FLAG_CANCEL_CURRENT
                                        | PendingIntent.FLAG_ONE_SHOT, null);

                        Intent newIntent = new Intent();
                        if (requestCode >= 0) {
                            // Caller is requesting a result.
                            newIntent.putExtra(HeavyWeightSwitcherActivity.KEY_HAS_RESULT, true);
                        }
                        newIntent.putExtra(HeavyWeightSwitcherActivity.KEY_INTENT,
                                new IntentSender(target));
                        if (heavy.activities.size() > 0) {
                            ActivityRecord hist = heavy.activities.get(0);
                            newIntent.putExtra(HeavyWeightSwitcherActivity.KEY_CUR_APP,
                                    hist.packageName);
                            newIntent.putExtra(HeavyWeightSwitcherActivity.KEY_CUR_TASK,
                                    hist.getTask().taskId);
                        }
                        newIntent.putExtra(HeavyWeightSwitcherActivity.KEY_NEW_APP,
                                aInfo.packageName);
                        newIntent.setFlags(intent.getFlags());
                        newIntent.setClassName("android",
                                HeavyWeightSwitcherActivity.class.getName());
                        intent = newIntent;
                        resolvedType = null;
                        caller = null;
                        callingUid = Binder.getCallingUid();
                        callingPid = Binder.getCallingPid();
                        componentSpecified = true;
                        rInfo = mSupervisor.resolveIntent(intent, null /*resolvedType*/, userId,
                                0 /* matchFlags */, computeResolveFilterUid(
                                        callingUid, realCallingUid, mRequest.filterCallingUid));
                        aInfo = rInfo != null ? rInfo.activityInfo : null;
                        if (aInfo != null) {
                            aInfo = mService.getActivityInfoForUser(aInfo, userId);
                        }
                    }
                }
            }
```

这个重量级进程实际上很早就存在，但是允许我们设置是在sdk 28(Android 9.0)之后才能开放给我们。

重量级的进程一般是指在整个系统唯一存在一个进程，不会正常走保存恢复机制，而是一直运行在后台，不会被后台杀死，因此需要用户显示退出进入该进程。

而这段代码就是当后台已经启动了一个重量进程的时候，用户又一次想要启动另一个重量级进程，就会弹出一个界面让用户进行选择。
![重量级应用的选择.png](/images/重量级应用的选择.png)
就是这个弹窗选择界面。这种行为一般是给游戏这种极其消耗资源的进程处理。


## 3.进行下一步的启动
```java
 final ActivityRecord[] outRecord = new ActivityRecord[1];
            int res = startActivity(caller, intent, ephemeralIntent, resolvedType, aInfo, rInfo,
                    voiceSession, voiceInteractor, resultTo, resultWho, requestCode, callingPid,
                    callingUid, callingPackage, realCallingPid, realCallingUid, startFlags, options,
                    ignoreTargetSecurity, componentSpecified, outRecord, inTask, reason,
                    allowPendingRemoteAnimationRegistryLookup);

...
 if (outResult != null) {
                outResult.result = res;

                final ActivityRecord r = outRecord[0];

                switch(res) {
                    case START_SUCCESS: {
                        mSupervisor.mWaitingActivityLaunched.add(outResult);
                        do {
                            try {
                                mService.wait();
                            } catch (InterruptedException e) {
                            }
                        } while (outResult.result != START_TASK_TO_FRONT
                                && !outResult.timeout && outResult.who == null);
                        if (outResult.result == START_TASK_TO_FRONT) {
                            res = START_TASK_TO_FRONT;
                        }
                        break;
                    }
                    case START_DELIVERED_TO_TOP: {
                        outResult.timeout = false;
                        outResult.who = r.realActivity;
                        outResult.totalTime = 0;
                        outResult.thisTime = 0;
                        break;
                    }
                    case START_TASK_TO_FRONT: {
                        // ActivityRecord may represent a different activity, but it should not be
                        // in the resumed state.
                        if (r.nowVisible && r.isState(RESUMED)) {
                            outResult.timeout = false;
                            outResult.who = r.realActivity;
                            outResult.totalTime = 0;
                            outResult.thisTime = 0;
                        } else {
                            outResult.thisTime = SystemClock.uptimeMillis();
                            mSupervisor.waitActivityVisible(r.realActivity, outResult);
                            // Note: the timeout variable is not currently not ever set.
                            do {
                                try {
                                    mService.wait();
                                } catch (InterruptedException e) {
                                }
                            } while (!outResult.timeout && outResult.who == null);
                        }
                        break;
                    }
                }
            }
```

我们可以看到进行下一个的启动之后，如果返回的状态码START_SUCCESS，就会阻塞AMS，等待唤醒。这种同步的处理才让该函数名为mayWait。然而这种情况十分少见。此时被唤醒必定是App启动完成之后，binder驱动找回AMS事务唤醒读取数据的时刻。在整个源码中这种情况只用做测试。毕竟要跨越2次进程才让AMS继续工作这是不可能出现在正常系统中。

因此我们把目光放在startActivity这个核心方法中。


## startActivity处理ActivityInfo转化为ActivityRecord

这里分为3步聊聊：
### 1.准备ActivtyRecord的基础数据
```java
private int startActivity(IApplicationThread caller, Intent intent, Intent ephemeralIntent,
            String resolvedType, ActivityInfo aInfo, ResolveInfo rInfo,
            IVoiceInteractionSession voiceSession, IVoiceInteractor voiceInteractor,
            IBinder resultTo, String resultWho, int requestCode, int callingPid, int callingUid,
            String callingPackage, int realCallingPid, int realCallingUid, int startFlags,
            SafeActivityOptions options,
            boolean ignoreTargetSecurity, boolean componentSpecified, ActivityRecord[] outActivity,
            TaskRecord inTask, boolean allowPendingRemoteAnimationRegistryLookup) {
        int err = ActivityManager.START_SUCCESS;
        // Pull the optional Ephemeral Installer-only bundle out of the options early.
        final Bundle verificationBundle
                = options != null ? options.popAppVerificationBundle() : null;

        ProcessRecord callerApp = null;
        if (caller != null) {
            callerApp = mService.getRecordForAppLocked(caller);
            if (callerApp != null) {
                callingPid = callerApp.pid;
                callingUid = callerApp.info.uid;
            } else {
               ...
            }
        }

        final int userId = aInfo != null && aInfo.applicationInfo != null
                ? UserHandle.getUserId(aInfo.applicationInfo.uid) : 0;

        ....
        ActivityRecord sourceRecord = null;
        ActivityRecord resultRecord = null;
        if (resultTo != null) {
            sourceRecord = mSupervisor.isInAnyStackLocked(resultTo);
...
            if (sourceRecord != null) {
                if (requestCode >= 0 && !sourceRecord.finishing) {
                    resultRecord = sourceRecord;
                }
            }
        }

   ....
    }
```

为了实例化ActivityRecord，Android系统通过IApplicationThread获取当前Activity所处在进程数据。

> 也就是调用 mService.getRecordForAppLocked(caller); 获取ProcessRecord。
##### AMS寻找进程
我们追踪一下AMS是怎么通过IApplicationThread这个AppThread远程binder对象获得的。
```
    private final int getLRURecordIndexForAppLocked(IApplicationThread thread) {
        final IBinder threadBinder = thread.asBinder();
        // Find the application record.
        for (int i=mLruProcesses.size()-1; i>=0; i--) {
            final ProcessRecord rec = mLruProcesses.get(i);
            if (rec.thread != null && rec.thread.asBinder() == threadBinder) {
                return i;
            }
        }
        return -1;
    }

 ProcessRecord getRecordForAppLocked(IApplicationThread thread) {
        if (thread == null) {
            return null;
        }

        int appIndex = getLRURecordIndexForAppLocked(thread);
        if (appIndex >= 0) {
            return mLruProcesses.get(appIndex);
        }

        // Validation: if it isn't in the LRU list, it shouldn't exist, but let's
        // double-check that.
        final IBinder threadBinder = thread.asBinder();
        final ArrayMap<String, SparseArray<ProcessRecord>> pmap = mProcessNames.getMap();
        for (int i = pmap.size()-1; i >= 0; i--) {
            final SparseArray<ProcessRecord> procs = pmap.valueAt(i);
            for (int j = procs.size()-1; j >= 0; j--) {
                final ProcessRecord proc = procs.valueAt(j);
                if (proc.thread != null && proc.thread.asBinder() == threadBinder) {
                    Slog.wtf(TAG, "getRecordForApp: exists in name list but not in LRU list: "
                            + proc);
                    return proc;
                }
            }
        }

        return null;
    }
```
从这里我们稍微能看出Google对性能的追求。在整个AMS中，有两个数据结构存储着进程对象：
##### 1.mLruProcesses 一个LRU的ArrayList存储着数据。这个数据结构虽然不是我们常用的LRUMap(LinkHashMap 经过处理后能够自动处理LRU算法，将会在算法专栏和大家聊聊)最近最少使用算法。但是Google 工程师选择自己处理。

##### 2.mProcessNames 存储着所有进程的数据，可以通过Binde的引用名反过来找到进程的数据。
所以用我们常用的话来说，AMS在进程查找中用了二级缓存。

趁热打铁看看进程是怎么更新的LRU算法：
```java

    final void updateLruProcessLocked(ProcessRecord app, boolean activityChange,
            ProcessRecord client) {
        final boolean hasActivity = app.activities.size() > 0 || app.hasClientActivities
                || app.treatLikeActivity || app.recentTasks.size() > 0;
        final boolean hasService = false; // not impl yet. app.services.size() > 0;
        if (!activityChange && hasActivity) {
            // The process has activities, so we are only allowing activity-based adjustments
            // to move it.  It should be kept in the front of the list with other
            // processes that have activities, and we don't want those to change their
            // order except due to activity operations.
            return;
        }

        mLruSeq++;
        final long now = SystemClock.uptimeMillis();
        app.lastActivityTime = now;

        // First a quick reject: if the app is already at the position we will
        // put it, then there is nothing to do.
        //步骤一
        if (hasActivity) {
            final int N = mLruProcesses.size();
            if (N > 0 && mLruProcesses.get(N-1) == app) {
...
                return;
            }
        } else {
            if (mLruProcessServiceStart > 0
                    && mLruProcesses.get(mLruProcessServiceStart-1) == app) {
...
                return;
            }
        }
      //获取最近使用相同ProcessRecord的索引
        int lrui = mLruProcesses.lastIndexOf(app);

....

        if (lrui >= 0) {
            if (lrui < mLruProcessActivityStart) {
                mLruProcessActivityStart--;
            }
            if (lrui < mLruProcessServiceStart) {
                mLruProcessServiceStart--;
            }
        ...
            mLruProcesses.remove(lrui);
        }

       ...

        int nextIndex;
        if (hasActivity) {
            //处理Activity详细看下面带着Activity的进程情况套路
        } else if (hasService) {
            // Process has services, put it at the top of the service list.
...
            mLruProcesses.add(mLruProcessActivityStart, app);
            nextIndex = mLruProcessServiceStart;
            mLruProcessActivityStart++;
        } else  {
//详细看处理没有Actvity以及Service的进程
        }

        // If the app is currently using a content provider or service,
        // bump those processes as well.
        for (int j=app.connections.size()-1; j>=0; j--) {
            ConnectionRecord cr = app.connections.valueAt(j);
            if (cr.binding != null && !cr.serviceDead && cr.binding.service != null
                    && cr.binding.service.app != null
                    && cr.binding.service.app.lruSeq != mLruSeq
                    && !cr.binding.service.app.persistent) {
                nextIndex = updateLruProcessInternalLocked(cr.binding.service.app, now, nextIndex,
                        "service connection", cr, app);
            }
        }
        for (int j=app.conProviders.size()-1; j>=0; j--) {
            ContentProviderRecord cpr = app.conProviders.get(j).provider;
            if (cpr.proc != null && cpr.proc.lruSeq != mLruSeq && !cpr.proc.persistent) {
                nextIndex = updateLruProcessInternalLocked(cpr.proc, now, nextIndex,
                        "provider reference", cpr, app);
            }
        }
    }
```
##### 额外知识的补充
要看懂这一段逻辑，我们必须要普及一个基础知识，Android的uid和userId。

> 虽然Android是沿用Linux内核，其uid充满着迷惑性。android的uid和Linux的uid有区别。在Linux中uid和task_struct(进程描述符)是一对一绑定一起，代表着当前进程用户的使用者id。而Android相似却不同，Android在framework层的userid是在PMS按照时候通过PackageParser.Package.scanPackageDirtyLI()分配好的.

每一次获取Uid都是经过下面这一段算法：
```java
public static int getUid(@UserIdInt int userId, @AppIdInt int appId) {
        if (MU_ENABLED) {//是否支持多用户
            //PER_USER_RANGE  为 100000
            return userId * PER_USER_RANGE + (appId % PER_USER_RANGE);
        } else {
            return appId;
        }
    }
```

通过userId获取uid
```java
public static final int getUserId(int uid) {
        if (MU_ENABLED) {
            return uid / PER_USER_RANGE;
        } else {
            return 0;
        }
    }
```
> userId * 100000 + (appId % 100000)
这样就能把uid和userId互相转化。

因此这种设计导致了uid可以共享，虽然用的少，但是实际上确实存在。当包名相同，但是为组件在AndroidManifest设置了android:process这个标签，就能在不同的进程共享一个uid。也能设置android:shareUserid,不同包名时候可以共享(相同包名，相同签名则会覆盖)。这里就继续不探究，后续会在PMS解析之后再来详细看看。

##### 回到进程的LRU算法
我们先要弄明白一般的LRU算法是为了让最近最少用的放到队尾，最近最常用放在队头，目的是为了在某种常用这个对象，能够减少搜索时间，从而达到性能优化目的。

而这个进程的LRU算法稍微有点不一样。最近最常用的放在队末，最近最少用放在队首。

因此在循环的时候，AMS是从队末开始搜索进程对象(ProcessRecord)。弄懂设计原型，再来看看Google工程师的设计。

每一次通过update方法调整进程在LRU算法，首先会判断当前进程是否包含Activity或者Service。

不管包含着什么，只要发现当前要查找的ProcessRecord在队末，则立即返回。接着再次搜索最近一次使用相同的进程的索引，并且删除。

同时这里可以看到在这个LRU中有两个位置标签
- 1. mLruProcessActivityStart
- 2. mLruProcessServiceStart

这两个位置标签把整个LRU的list切割为3部分，从mLruProcessActivityStart到队末，就是带着Activity的进程集合，mLruProcessServiceStart到mLruProcessActivityStart就是带着service的集合，从mLruProcessServiceStart到队首则是上面两者都不带。

因此在调整的时候，我们带着Activity的进程只需要调整mLruProcessActivityStart到队末那一段。带着service只需要调整mLruProcessServiceStart到mLruProcessActivityStart这一段。

因此当我们删除ProcessRecord这两个索引必须向后移动。

接下来分情况讨论：
- 1.带着Activity的进程：
```java
final int N = mLruProcesses.size();
            if ((app.activities.size() == 0 || app.recentTasks.size() > 0)
                    && mLruProcessActivityStart < (N - 1)) {
...
                mLruProcesses.add(N - 1, app);
                // To keep it from spamming the LRU list (by making a bunch of clients),
                // we will push down any other entries owned by the app.
                final int uid = app.info.uid;
                for (int i = N - 2; i > mLruProcessActivityStart; i--) {
                    ProcessRecord subProc = mLruProcesses.get(i);
                    if (subProc.info.uid == uid) {
                        if (mLruProcesses.get(i - 1).info.uid != uid) {
...
                            ProcessRecord tmp = mLruProcesses.get(i);
                            mLruProcesses.set(i, mLruProcesses.get(i - 1));
                            mLruProcesses.set(i - 1, tmp);
                            i--;
                        }
                    } else {
                        // A gap, we can stop here.
                        break;
                    }
                }
            } else {
...
                mLruProcesses.add(app);
            }
            nextIndex = mLruProcessServiceStart;
```
从这里我们看到当要添加进LRU或者重新调整ProcessRecord会判断当前进程中有没有最近使用的TaskRecord集合或者ProcessRecord中的Activity集合大于0.则插入到队末。

接着开始循环后面的集合，查看有没有ProcessRecord和当前的共享一个uid。找到有个这个共享的，则交换位置，让共享uid的进程往队末靠，这样就是实现了LRU关键算法。

最后nextIndex设置为mLruProcessServiceStart

- 2.当插入的进程是有service的。
直接插入到mLruProcessActivityStart的位置，并且mLruProcessActivityStart加一，让Activity的集合向后移动。
最后nextIndex = mLruProcessServiceStart;

- 3.当插入的进程是没有Activity和Service的。
```java
            // Process not otherwise of interest, it goes to the top of the non-service area.
            int index = mLruProcessServiceStart;
            if (client != null) {
                // If there is a client, don't allow the process to be moved up higher
                // in the list than that client.
                int clientIndex = mLruProcesses.lastIndexOf(client);
....
                if (clientIndex <= lrui) {
                    // Don't allow the client index restriction to push it down farther in the
                    // list than it already is.
                    clientIndex = lrui;
                }
                if (clientIndex >= 0 && index > clientIndex) {
                    index = clientIndex;
                }
            }
...
            mLruProcesses.add(index, app);
            nextIndex = index-1;
            mLruProcessActivityStart++;
            mLruProcessServiceStart++;
```
这里又分为有没有带上client，和没有client端，带上client端这种情况一般是service通过Binder绑定了远程端的进程并且在重启Service情况下。这个client是指远程端的ProcessRecord。因此这里有两种情况，一种是本身远程端就带着Activity/Service，一种就是都没有带。

- 1.当没有带上client端
那么当前进程将会插在mLruProcessServiceStart，之后这个位置并且mLruProcessServiceStart和mLruProcessActivityStart都向后移动一位。
nextindex此时为移动前mLruProcessServiceStart - 1.

- 2.当带上client端
当client端本身存在，并且比当前的进程在LRU位置考后（更加靠近前端），或者不存在，则设置clientIndex(为client原先在LRU中位置)为设置为当前进程调整前在LRU的位置。

如果client不存在，则插入位置为mLruProcessServiceStart。

接着判断如果client如果存在，且client位置比当前进程的原先的位置靠前，并且当前位置mLruProcessServiceStart小，比则插入位置为原先的位置。

如果当client存在，且比当前进程(app)靠后，且client的位置比mLruProcessServiceStart小，插入的位置是mLruProcessServiceStart。

如果当client存在，且比当前进程(app)靠后，且client的位置比mLruProcessServiceStart大，插入的位置是client的在LRU位置。

nextIndex设置为mLruProcessServiceStart -1，或者client在LRU位置-1.

##### 进程的LRU后续算法
处理了Activity和Service，会继续后续处理。处理进程中Service绑定远程端，ContentProvider。

```java
 for (int j=app.connections.size()-1; j>=0; j--) {
            ConnectionRecord cr = app.connections.valueAt(j);
            if (cr.binding != null && !cr.serviceDead && cr.binding.service != null
                    && cr.binding.service.app != null
                    && cr.binding.service.app.lruSeq != mLruSeq
                    && !cr.binding.service.app.persistent) {
                nextIndex = updateLruProcessInternalLocked(cr.binding.service.app, now, nextIndex,
                        "service connection", cr, app);
            }
        }
        for (int j=app.conProviders.size()-1; j>=0; j--) {
            ContentProviderRecord cpr = app.conProviders.get(j).provider;
            if (cpr.proc != null && cpr.proc.lruSeq != mLruSeq && !cpr.proc.persistent) {
                nextIndex = updateLruProcessInternalLocked(cpr.proc, now, nextIndex,
                        "provider reference", cpr, app);
            }
        }
```

```java
private int updateLruProcessInternalLocked(ProcessRecord app, long now, int index,
            String what, Object obj, ProcessRecord srcApp) {
        app.lastActivityTime = now;

        if (app.activities.size() > 0 || app.recentTasks.size() > 0) {
      
            return index;
        }

        int lrui = mLruProcesses.lastIndexOf(app);
        if (lrui < 0) {
            return index;
        }

        if (lrui >= index) {
    
            return index;
        }

        if (lrui >= mLruProcessActivityStart) {
            return index;
        }

        mLruProcesses.remove(lrui);
        if (index > 0) {
            index--;
        }

        mLruProcesses.add(index, app);
        return index;
```
这里的逻辑联动上面的函数：
- 1.当service的远程进程存在Activity就不存移动了。
- 2.当service的远程进程或者ContentProvider不存在在LRU中也不调整了。
- 3.当service的远程进程或者ContentProvider比nextIndex的位置大也不调整。
- 4.当service的远程进程或者ContentProvider在mLruProcessActivityStart后面也不调整。
- 5.否则就逐个添加mLruProcessServiceStart之后；不带Activity/Service的进程插在mLruProcessServiceStart之前或者client之后。

用一副图表示整个进程的LRU计算就是如下
![Android进程LRU缓存调整.png](/images/Android进程LRU缓存调整.png)


以上就是进程处理LRU全部内容。这也为什么Google工程师选择使用ArrayList而不是用LinkHashMap做LRU处理。因为Google工程机为这个LRU做了浮标，划分了调整的区域，这样就能进一步的压缩搜索和调整时间。

接下来让我继续回到AMS的startActivity方法。

## isInAnyStackLocked
上面的长篇大论只是为了找到缓存在AMS中的进程。接下来我们要j检验对应Activity的栈。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)

这个方法中传进来一个关键的resultTo的Binder代理对象。不同的是，这个指代并不是任何Activity，而是指代在启动Activity时候，绑定的WindowManager
Binder代理，之后就会看到了。
```java
ActivityRecord isInAnyStackLocked(IBinder token) {
        int numDisplays = mActivityDisplays.size();
        for (int displayNdx = 0; displayNdx < numDisplays; ++displayNdx) {
            final ActivityDisplay display = mActivityDisplays.valueAt(displayNdx);
            for (int stackNdx = display.getChildCount() - 1; stackNdx >= 0; --stackNdx) {
                final ActivityStack stack = display.getChildAt(stackNdx);
                final ActivityRecord r = stack.isInStackLocked(token);
                if (r != null) {
                    return r;
                }
            }
        }
        return null;
    }
```

能看到的是，如果启动的时候，带的调用方WindowManager的Binder代理对象。此时说明此时Activity很可能是和当前的Activity在同一个进程。那么Android将会从mActivityDisplays获取ActivityDisplay对象，从中找到我们需要ActivityStack，从名字就能明白，这就是就是我们的Activity栈。

这个mActivityDisplays是个什么数据结构，实际上这是一个联通Activity的display逻辑显示器和Activity关联。换句话说，就是WindowManager和Activity关联起来的一个数据结构。在ActivityDisplay保存这个ActivityStack，为了WIndowManager能够跟着ActivityStack变化而变化。


这里的场景是，先拿到当前的ActivityStack,并且从中获取到启动者的ActivityRecord(Activity在AMS保存着信息)。

## startActivity根据当前启动flag做第一次调整
```java
 final int launchFlags = intent.getFlags();

        if ((launchFlags & Intent.FLAG_ACTIVITY_FORWARD_RESULT) != 0 && sourceRecord != null) {
            // Transfer the result target from the source activity to the new
            // one being started, including any failures.
            if (requestCode >= 0) {
                SafeActivityOptions.abort(options);
                return ActivityManager.START_FORWARD_AND_REQUEST_CONFLICT;
            }
            resultRecord = sourceRecord.resultTo;//这个resultTo是指Activity中的属性，和上面的不一样。
            if (resultRecord != null && !resultRecord.isInStackLocked()) {
                resultRecord = null;
            }
            resultWho = sourceRecord.resultWho;
            requestCode = sourceRecord.requestCode;
            sourceRecord.resultTo = null;
            if (resultRecord != null) {
                resultRecord.removeResultsLocked(sourceRecord, resultWho, requestCode);
            }
            if (sourceRecord.launchedFromUid == callingUid) {
                callingPackage = sourceRecord.launchedFromPackage;
            }
        }

...

final ActivityStack resultStack = resultRecord == null ? null : resultRecord.getStack();
...
```
这一段代码就是第一次获取intent中的启动flag。首先处理的flag是FORWARD_RESULT。

这个intent的flag用的不多，意思是透传requestCode。也就是说当设置了这个flag，那么被启动的这个Activity将不会接受这个requestCode。而是透传到启动的下一个Activity。但是作为透传者不能设置任何的requestCode，设置了则会报错 FORWARD_RESULT_FLAG used while also requesting a result。
![FORWARD_RESULT_FLAG异常.png](/images/FORWARD_RESULT_FLAG异常.png)

了解到用法，我们可以直接从这里看到当我们设置了requestCode大于0则，会立即返回错误。否则的话当成并没有发送这个requestcode。此时将会取出启动这个sourceRecord的requestCode，resultWho设置给下一个Activity，把唤起的包名更换为sourceRecord，这样就完成了透传动作。

同时，这个已经启动过的sourceRecord清空掉resultTo，保证透传的目标为这个新建的。



## startActivity校验权限，生成ActivityRecord
```java
 boolean abort = !mSupervisor.checkStartAnyActivityPermission(intent, aInfo, resultWho,
                requestCode, callingPid, callingUid, callingPackage, ignoreTargetSecurity,
                inTask != null, callerApp, resultRecord, resultStack);
        abort |= !mService.mIntentFirewall.checkStartActivity(intent, callingUid,
                callingPid, resolvedType, aInfo.applicationInfo);

        // Merge the two options bundles, while realCallerOptions takes precedence.
        ActivityOptions checkedOptions = options != null
                ? options.getOptions(intent, aInfo, callerApp, mSupervisor)
                : null;
        if (allowPendingRemoteAnimationRegistryLookup) {
            checkedOptions = mService.getActivityStartController()
                    .getPendingRemoteAnimationRegistry()
                    .overrideOptionsIfNeeded(callingPackage, checkedOptions);
        }
        if (mService.mController != null) {
            try {
                // The Intent we give to the watcher has the extra data
                // stripped off, since it can contain private information.
                Intent watchIntent = intent.cloneFilter();
                abort |= !mService.mController.activityStarting(watchIntent,
                        aInfo.applicationInfo.packageName);
            } catch (RemoteException e) {
                mService.mController = null;
            }
        }

        mInterceptor.setStates(userId, realCallingPid, realCallingUid, startFlags, callingPackage);
        if (mInterceptor.intercept(intent, rInfo, aInfo, resolvedType, inTask, callingPid,
                callingUid, checkedOptions)) {
            // activity start was intercepted, e.g. because the target user is currently in quiet
            // mode (turn off work) or the target application is suspended
            intent = mInterceptor.mIntent;
            rInfo = mInterceptor.mRInfo;
            aInfo = mInterceptor.mAInfo;
            resolvedType = mInterceptor.mResolvedType;
            inTask = mInterceptor.mInTask;
            callingPid = mInterceptor.mCallingPid;
            callingUid = mInterceptor.mCallingUid;
            checkedOptions = mInterceptor.mActivityOptions;
        }

        if (abort) {
            if (resultRecord != null) {
                resultStack.sendActivityResultLocked(-1, resultRecord, resultWho, requestCode,
                        RESULT_CANCELED, null);
            }
            ActivityOptions.abort(checkedOptions);
            return START_ABORTED;
        }

        // If permissions need a review before any of the app components can run, we
        // launch the review activity and pass a pending intent to start the activity
        // we are to launching now after the review is completed.
        if (mService.mPermissionReviewRequired && aInfo != null) {
            if (mService.getPackageManagerInternalLocked().isPermissionsReviewRequired(
                    aInfo.packageName, userId)) {
                IIntentSender target = mService.getIntentSenderLocked(
                        ActivityManager.INTENT_SENDER_ACTIVITY, callingPackage,
                        callingUid, userId, null, null, 0, new Intent[]{intent},
                        new String[]{resolvedType}, PendingIntent.FLAG_CANCEL_CURRENT
                                | PendingIntent.FLAG_ONE_SHOT, null);

                final int flags = intent.getFlags();
                Intent newIntent = new Intent(Intent.ACTION_REVIEW_PERMISSIONS);
                newIntent.setFlags(flags
                        | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
                newIntent.putExtra(Intent.EXTRA_PACKAGE_NAME, aInfo.packageName);
                newIntent.putExtra(Intent.EXTRA_INTENT, new IntentSender(target));
                if (resultRecord != null) {
                    newIntent.putExtra(Intent.EXTRA_RESULT_NEEDED, true);
                }
                intent = newIntent;

                resolvedType = null;
                callingUid = realCallingUid;
                callingPid = realCallingPid;

                rInfo = mSupervisor.resolveIntent(intent, resolvedType, userId, 0,
                        computeResolveFilterUid(
                                callingUid, realCallingUid, mRequest.filterCallingUid));
                aInfo = mSupervisor.resolveActivity(intent, rInfo, startFlags,
                        null /*profilerInfo*/);

         
            }
        }


        if (rInfo != null && rInfo.auxiliaryInfo != null) {
            intent = createLaunchIntent(rInfo.auxiliaryInfo, ephemeralIntent,
                    callingPackage, verificationBundle, resolvedType, userId);
            resolvedType = null;
            callingUid = realCallingUid;
            callingPid = realCallingPid;

            aInfo = mSupervisor.resolveActivity(intent, rInfo, startFlags, null /*profilerInfo*/);
        }

        ActivityRecord r = new ActivityRecord(mService, callerApp, callingPid, callingUid,
                callingPackage, intent, resolvedType, aInfo, mService.getGlobalConfiguration(),
                resultRecord, resultWho, requestCode, componentSpecified, voiceSession != null,
                mSupervisor, checkedOptions, sourceRecord);
        if (outActivity != null) {
            outActivity[0] = r;
        }
```

在这个代码片段中，有两个关键函数做权限判断。
- 1.checkStartAnyActivityPermission
这个函数最后调用到PermissionManagerService中，对当前的uid精心检验是否合法。

- 2.mInterceptor.intercept 该函数是一个拦截器对当前的参数精心拦截，里面的拦截判断主要有三点：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStartInterceptor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStartInterceptor.java)

```java
boolean intercept(Intent intent, ResolveInfo rInfo, ActivityInfo aInfo, String resolvedType,
            TaskRecord inTask, int callingPid, int callingUid, ActivityOptions activityOptions) {
        mUserManager = UserManager.get(mServiceContext);

        mIntent = intent;
        mCallingPid = callingPid;
        mCallingUid = callingUid;
        mRInfo = rInfo;
        mAInfo = aInfo;
        mResolvedType = resolvedType;
        mInTask = inTask;
        mActivityOptions = activityOptions;

        if (interceptSuspendedPackageIfNeeded()) {
            return true;
        }
        if (interceptQuietProfileIfNeeded()) {
            return true;
        }
        if (interceptHarmfulAppIfNeeded()) {
            return true;
        }
        return interceptWorkProfileChallengeIfNeeded();
    }
```
- 1.当当前要启动的包被管理员是否被挂起，不允许操作

- 2.当此时的用户在安静模式，这个安静模式不是指音量，而是指UserManager中设置的requestQuietModeEnabled，在这个模式下，应用不会真正的运行。关闭安静模式时候就有个弹窗。

-3.当前的应用被判断为有害

以上三种情况下，只要想要打开Activity都会有个新的ActivityInfo替代原来的Activity，用来提示用户。

还有一种常见情况，当我们的权限判断弹窗并不是直接拦截，而是等到Activity启动后，作为一个弹窗拦截在上面的情况。
```java
        if (mService.mPermissionReviewRequired && aInfo != null) {
            if (mService.getPackageManagerInternalLocked().isPermissionsReviewRequired(
                    aInfo.packageName, userId)) {
                IIntentSender target = mService.getIntentSenderLocked(
                        ActivityManager.INTENT_SENDER_ACTIVITY, callingPackage,
                        callingUid, userId, null, null, 0, new Intent[]{intent},
                        new String[]{resolvedType}, PendingIntent.FLAG_CANCEL_CURRENT
                                | PendingIntent.FLAG_ONE_SHOT, null);

                final int flags = intent.getFlags();
                Intent newIntent = new Intent(Intent.ACTION_REVIEW_PERMISSIONS);
                newIntent.setFlags(flags
                        | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
                newIntent.putExtra(Intent.EXTRA_PACKAGE_NAME, aInfo.packageName);
                newIntent.putExtra(Intent.EXTRA_INTENT, new IntentSender(target));
                if (resultRecord != null) {
                    newIntent.putExtra(Intent.EXTRA_RESULT_NEEDED, true);
                }
                intent = newIntent;

                resolvedType = null;
                callingUid = realCallingUid;
                callingPid = realCallingPid;

                rInfo = mSupervisor.resolveIntent(intent, resolvedType, userId, 0,
                        computeResolveFilterUid(
                                callingUid, realCallingUid, mRequest.filterCallingUid));
                aInfo = mSupervisor.resolveActivity(intent, rInfo, startFlags,
                        null /*profilerInfo*/);

         
            }
        }
```
此时，就能看到熟悉IIntentSender这个类。如果阅读过pendingIntent源码的朋友，就能知道pendingItent本质上IIntentSender就是这个类在延后操作。这里将不会铺开讲，之后会详细分析pendingIntent。这样就能附着一个intent等到Activity启动后在弹出一个弹窗Activity。

最后在根据这些数据生成一个新的ActivityRecord(这个ActivityRecord是目标对象的ActivityRecord)，并且把发起者的sourceRecord和当前的作为参数传入。正式开始操作ActivityStack。因此，我们可以知道Activity在AMS中将会对应一个ActivityRecord。


### 小节
本文就先分析到这里，稍后会重点分析ActvityStack在intent的各种startflag下的变化。

本文总结进程的缓存LRU算法，实际上就是分成三段进行管理，包含Activity，Service，两者不包含的。在通过ContentProvider以及Service绑定的远程端，再对两者可能链接到的进程进行管缓存理。因此我们可以清楚，在四大组件中只有Boardcast不会对进程LRU的优先进行影响。

不过请注意，四大组件都会Android系统中进程adj调度产生影响，两者不同。

于此同时通过Activitstarter.startActivity的方法为目标Activity准备好了ActivityRecord，目标对象是什么。接下来就是如何把这个ActivityRecord插入栈中。














