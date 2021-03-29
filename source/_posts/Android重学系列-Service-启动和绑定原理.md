---
title: Android重学系列 Service 启动和绑定原理
top: false
cover: false
date: 2020-08-09 00:23:57
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---
# 前言
我们已经了解了BroadcastReceiver的原理，我们再来看看四大组件之一的Service是怎么启动的，以及怎么运行的原理。

# 正文
启动Service的入口就是startService和bindService方法。我们先来看看startService在ContextImpl中做了什么。

## startService原理
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)

```java
    @Override
    public ComponentName startService(Intent service) {
        warnIfCallingFromSystemProcess();
        return startServiceCommon(service, false, mUser);
    }

    @Override
    public ComponentName startForegroundService(Intent service) {
        warnIfCallingFromSystemProcess();
        return startServiceCommon(service, true, mUser);
    }

    private ComponentName startServiceCommon(Intent service, boolean requireForeground,
            UserHandle user) {
        try {
            validateServiceIntent(service);
            service.prepareToLeaveProcess(this);
            ComponentName cn = ActivityManager.getService().startService(
                mMainThread.getApplicationThread(), service, service.resolveTypeIfNeeded(
                            getContentResolver()), requireForeground,
                            getOpPackageName(), user.getIdentifier());
            if (cn != null) {
                if (cn.getPackageName().equals("!")) {
                    throw new SecurityException(
                            "Not allowed to start service " + service
                            + " without permission " + cn.getClassName());
                } else if (cn.getPackageName().equals("!!")) {
                    throw new SecurityException(
                            "Unable to start service " + service
                            + ": " + cn.getClassName());
                } else if (cn.getPackageName().equals("?")) {
                    throw new IllegalStateException(
                            "Not allowed to start service " + service + ": " + cn.getClassName());
                }
            return cn;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
此时调用的就是AMS的startService方法。

## AMS startService
```java
    public ComponentName startService(IApplicationThread caller, Intent service,
            String resolvedType, boolean requireForeground, String callingPackage, int userId)
            throws TransactionTooLargeException {
....

        synchronized(this) {
            final int callingPid = Binder.getCallingPid();
            final int callingUid = Binder.getCallingUid();
            final long origId = Binder.clearCallingIdentity();
            ComponentName res;
            try {
                res = mServices.startServiceLocked(caller, service,
                        resolvedType, callingPid, callingUid,
                        requireForeground, callingPackage, userId);
            } finally {
                Binder.restoreCallingIdentity(origId);
            }
            return res;
        }
    }
```
mServices是一个ActiveServices对象。这个对象是在AMS的构造函数中初始化好的。

这里调用了ActiveServices的startServiceLocked。

### ActiveServices startServiceLocked
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActiveServices.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActiveServices.java)

```java
    ComponentName startServiceLocked(IApplicationThread caller, Intent service, String resolvedType,
            int callingPid, int callingUid, boolean fgRequired, String callingPackage, final int userId)
            throws TransactionTooLargeException {


        final boolean callerFg;
        if (caller != null) {
            final ProcessRecord callerApp = mAm.getRecordForAppLocked(caller);

            callerFg = callerApp.setSchedGroup != ProcessList.SCHED_GROUP_BACKGROUND;
        } else {
            callerFg = true;
        }

        ServiceLookupResult res =
            retrieveServiceLocked(service, resolvedType, callingPackage,
                    callingPid, callingUid, userId, true, callerFg, false, false);
        if (res == null) {
            return null;
        }
        if (res.record == null) {
            return new ComponentName("!", res.permission != null
                    ? res.permission : "private to package");
        }

        ServiceRecord r = res.record;

 ...

        if (unscheduleServiceRestartLocked(r, callingUid, false)) {

        }
        r.lastActivity = SystemClock.uptimeMillis();
        r.startRequested = true;
        r.delayedStop = false;
        r.fgRequired = fgRequired;
        r.pendingStarts.add(new ServiceRecord.StartItem(r, false, r.makeNextStartId(),
                service, neededGrants, callingUid));

        if (fgRequired) {
mAm.mAppOpsService.startOperation(AppOpsManager.getToken(mAm.mAppOpsService),
                    AppOpsManager.OP_START_FOREGROUND, r.appInfo.uid, r.packageName, true);
        }

        final ServiceMap smap = getServiceMapLocked(r.userId);
        boolean addToStarting = false;
        if (!callerFg && !fgRequired && r.app == null
                && mAm.mUserController.hasStartedUserState(r.userId)) {
...
}
        ComponentName cmp = startServiceInnerLocked(smap, service, r, callerFg, addToStarting);
        return cmp;
    }
```
核心流程有如下三个：
- 1.retrieveServiceLocked 从ActiveServices中获取ServiceLookupResult 需要启动Service对象
- 2.往ServiceRecord对象的pendingStarts几个中添加一个ServiceRecord.StartItem对象。而这个对象就是之后Service声明周期中onCommandStart的回调参数
- 3.startServiceInnerLocked 执行Service的启动的流程。

注意这里addToStarting是一个比较关键的判断，addToStarting默认为false。
```java
        if (!callerFg && !fgRequired && r.app == null
                && mAm.mUserController.hasStartedUserState(r.userId)) {
            ProcessRecord proc = mAm.getProcessRecordLocked(r.processName, r.appInfo.uid, false);
            if (proc == null || proc.curProcState > ActivityManager.PROCESS_STATE_RECEIVER) {
                if (r.delayed) {

                    return r.name;
                }
                if (smap.mStartingBackground.size() >= mMaxStartingBackground) {

                    smap.mDelayedStartList.add(r);
                    r.delayed = true;
                    return r.name;
                }

                addToStarting = true;
            } else if (proc.curProcState >= ActivityManager.PROCESS_STATE_SERVICE) {

                addToStarting = true;

            } else if (DEBUG_DELAYED_STARTS) {

            }
        } else if (DEBUG_DELAYED_STARTS) {

        }
```
如果此时不是启动前台服务，则需要进一步进行处理。如果ProcessRecord为空或者curProcState大于PROCESS_STATE_RECEIVER这个优先级数值；也就是优先级更小。

为了避免此时App应用是没有任何的前台ui，或者App应用还没有声明。避免有的App通过startService进行应用的包活或者拉起应用。就会进行如下能够存在的最大后台服务数量，则放入mDelayedStartList中进行延时启动后台服务，现在直接返回了。

不然则说明能够允许启动后台服务， 就设置为addToStarting为true。


### ActiveServices  retrieveServiceLocked
```java
    private ServiceLookupResult retrieveServiceLocked(Intent service,
            String resolvedType, String callingPackage, int callingPid, int callingUid, int userId,
            boolean createIfNeeded, boolean callingFromFg, boolean isBindExternal,
            boolean allowInstant) {
        ServiceRecord r = null;


        userId = mAm.mUserController.handleIncomingUser(callingPid, callingUid, userId, false,
                ActivityManagerService.ALLOW_NON_FULL_IN_PROFILE, "service", null);

        ServiceMap smap = getServiceMapLocked(userId);
        final ComponentName comp = service.getComponent();
        if (comp != null) {
            r = smap.mServicesByName.get(comp);

        }
        if (r == null && !isBindExternal) {
            Intent.FilterComparison filter = new Intent.FilterComparison(service);
            r = smap.mServicesByIntent.get(filter);

        }
        if (r != null && (r.serviceInfo.flags & ServiceInfo.FLAG_EXTERNAL_SERVICE) != 0
                && !callingPackage.equals(r.packageName)) {

            r = null;

        }
        if (r == null) {
            try {
                int flags = ActivityManagerService.STOCK_PM_FLAGS
                        | PackageManager.MATCH_DEBUG_TRIAGED_MISSING;
                if (allowInstant) {
                    flags |= PackageManager.MATCH_INSTANT;
                }

                ResolveInfo rInfo = mAm.getPackageManagerInternalLocked().resolveService(service,
                        resolvedType, flags, userId, callingUid);
                ServiceInfo sInfo =
                    rInfo != null ? rInfo.serviceInfo : null;
                if (sInfo == null) {

                    return null;
                }
                ComponentName name = new ComponentName(
                        sInfo.applicationInfo.packageName, sInfo.name);
                if ((sInfo.flags & ServiceInfo.FLAG_EXTERNAL_SERVICE) != 0) {
                    if (isBindExternal) {
                        if (!sInfo.exported) {

                        }
                        if ((sInfo.flags & ServiceInfo.FLAG_ISOLATED_PROCESS) == 0) {

                        }

                        ApplicationInfo aInfo = AppGlobals.getPackageManager().getApplicationInfo(
                                callingPackage, ActivityManagerService.STOCK_PM_FLAGS, userId);

                        sInfo = new ServiceInfo(sInfo);
                        sInfo.applicationInfo = new ApplicationInfo(sInfo.applicationInfo);
                        sInfo.applicationInfo.packageName = aInfo.packageName;
                        sInfo.applicationInfo.uid = aInfo.uid;
                        name = new ComponentName(aInfo.packageName, name.getClassName());
                        service.setComponent(name);
                    } else {

                    }
                } else if (isBindExternal) {

                }
                if (userId > 0) {
                    if (mAm.isSingleton(sInfo.processName, sInfo.applicationInfo,
                            sInfo.name, sInfo.flags)
                            && mAm.isValidSingletonCall(callingUid, sInfo.applicationInfo.uid)) {
                        userId = 0;
                        smap = getServiceMapLocked(0);
                    }
                    sInfo = new ServiceInfo(sInfo);
                    sInfo.applicationInfo = mAm.getAppInfoForUser(sInfo.applicationInfo, userId);
                }
                r = smap.mServicesByName.get(name);

                if (r == null && createIfNeeded) {
                    final Intent.FilterComparison filter
                            = new Intent.FilterComparison(service.cloneFilter());
                    final ServiceRestarter res = new ServiceRestarter();
                    final BatteryStatsImpl.Uid.Pkg.Serv ss;
                    final BatteryStatsImpl stats = mAm.mBatteryStatsService.getActiveStatistics();
                    synchronized (stats) {
                        ss = stats.getServiceStatsLocked(
                                sInfo.applicationInfo.uid, sInfo.packageName,
                                sInfo.name);
                    }
                    r = new ServiceRecord(mAm, ss, name, filter, sInfo, callingFromFg, res);
                    res.setService(r);
                    smap.mServicesByName.put(name, r);
                    smap.mServicesByIntent.put(filter, r);

                    for (int i=mPendingServices.size()-1; i>=0; i--) {
                        final ServiceRecord pr = mPendingServices.get(i);
                        if (pr.serviceInfo.applicationInfo.uid == sInfo.applicationInfo.uid
                                && pr.name.equals(name)) {

                            mPendingServices.remove(i);
                        }
                    }

                }
            } catch (RemoteException ex) {
                // pm is in same process, this will never happen.
            }
        }
        if (r != null) {
...
            return new ServiceLookupResult(r, null);
        }
        return null;
    }
```
- 1.通过UserController.handleIncomingUser获取的userId，从getServiceMapLocked方法通过userId中获取ServiceMap对象。这个对象保存了已经启动过所有的Service对象。
  - 1.1.ServiceMap保存如下几种用于查询映射结构:
```java
        final ArrayMap<ComponentName, ServiceRecord> mServicesByName = new ArrayMap<>();
        final ArrayMap<Intent.FilterComparison, ServiceRecord> mServicesByIntent = new ArrayMap<>();
```
通过ComponentName也就是包名和类名查找ServiceRecord；通过Intent意图过滤找到ServiceRecord。·
  - 1.2.如果能够获取到，则直接获取ServiceMap中的ServiceRecord对象，并包裹成ServiceLookupResult对象返回。

- 2.如果Intent中的ComponentName不为空，ServiceMap则通过ComponentName查询缓存ServiceRecord。

- 3.如果还是找不到，且isBindExternal为false(此时就是false)，则通过过滤条件从ServiceMap查找缓存ServiceRecord。

- 4.如果设置了FLAG_EXTERNAL_SERVICE，且ServiceRecord找到了，但是此时ServiceRecord中的包名和调用方的包名不一致，则把找到的缓存ServiceRecord设置为空。如果设置了FLAG_EXTERNAL_SERVICE这个flag，也就是设置了`android:externalService`这个xml标签。这个标签代表了Service可以绑定调用方的进程；因此这个标志位支持跨进程绑定但是不支持跨包绑定。

- 5.如果找不到ServiceRecord，那么需要新建一个ServiceRecord。
  - 5.1.先通过PMS的resolveService方法，从PMS中获取一个ResolveInfo对象。这个对象能够获取安装时候通过解析AndroidManifest.xml到的ServiceInfo对象。

  - 5.2.并且isBindExternal为true。此时会封装一个新的ServiceInfo，并且通过Intent的setComponent，获取此时真正需要启动Service对应的包名和类名。在这里isBindExternal为false，startService并不会走这个逻辑。

  - 5.3.因为可能会在5.2的时候获取真实需要启动的包名，此时再通过mServicesByName找一次是否能找到缓存的Service。

  - 5.4.到了这个步骤说明真的找不到了ServiceRecord对象。先生成Intent.FilterComparison对象。把ComponentName作为key和ServiceRecord作为value保存到mServicesByName；把Intent.FilterComparison作为key，ServiceRecord作为value保存到mServicesByIntent。

  - 5.5.如果在mPendingServices队列中发现了这个需要新生成的Service对象对应的包名类名，就从mPendingServices中移除一样的包名类名。

  - 5.6.最后校验权限返回ServiceLookupResult。


### ActiveServices startServiceInnerLocked
```java
    ComponentName startServiceInnerLocked(ServiceMap smap, Intent service, ServiceRecord r,
            boolean callerFg, boolean addToStarting) throws TransactionTooLargeException {
        ServiceState stracker = r.getTracker();
        if (stracker != null) {
            stracker.setStarted(true, mAm.mProcessStats.getMemFactorLocked(), r.lastActivity);
        }
        r.callStart = false;
        synchronized (r.stats.getBatteryStats()) {
            r.stats.startRunningLocked();
        }
        String error = bringUpServiceLocked(r, service.getFlags(), callerFg, false, false);
        if (error != null) {
            return new ComponentName("!!", error);
        }

        if (r.startRequested && addToStarting) {
            boolean first = smap.mStartingBackground.size() == 0;
            smap.mStartingBackground.add(r);
            r.startingBgTimeout = SystemClock.uptimeMillis() + mAm.mConstants.BG_START_TIMEOUT;
...
            if (first) {
                smap.rescheduleDelayedStartsLocked();
            }
        } else if (callerFg || r.fgRequired) {
            smap.ensureNotStartingBackgroundLocked(r);
        }

        return r.name;
    }
```
核心方法是bringUpServiceLocked。如果bringUpServiceLocked返回了异常，就返回一个特殊的ComponentName对象。

addToStarting为true，说明此时是一个能够启动的后台服务，则ServiceRecord添加到mStartingBackground中。如果mStartingBackground的数量为0，则直接调用ServiceMap的rescheduleDelayedStartsLocked启动后台服务。


#### ActiveServices bringUpServiceLocked
```java
    private String bringUpServiceLocked(ServiceRecord r, int intentFlags, boolean execInFg,
            boolean whileRestarting, boolean permissionsReviewRequired)
            throws TransactionTooLargeException {

        if (r.app != null && r.app.thread != null) {
            sendServiceArgsLocked(r, execInFg, false);
            return null;
        }

        if (!whileRestarting && mRestartingServices.contains(r)) {
            return null;
        }

        if (mRestartingServices.remove(r)) {
            clearRestartingIfNeededLocked(r);
        }

        if (r.delayed) {
            getServiceMapLocked(r.userId).mDelayedStartList.remove(r);
            r.delayed = false;
        }


        if (!mAm.mUserController.hasStartedUserState(r.userId)) {

            bringDownServiceLocked(r);
            return msg;
        }

        try {
            AppGlobals.getPackageManager().setPackageStoppedState(
                    r.packageName, false, r.userId);
        } catch (RemoteException e) {
        } catch (IllegalArgumentException e) {

        }

        final boolean isolated = (r.serviceInfo.flags&ServiceInfo.FLAG_ISOLATED_PROCESS) != 0;
        final String procName = r.processName;
        String hostingType = "service";
        ProcessRecord app;

        if (!isolated) {
            app = mAm.getProcessRecordLocked(procName, r.appInfo.uid, false);

            if (app != null && app.thread != null) {
                try {
                    app.addPackage(r.appInfo.packageName, r.appInfo.longVersionCode, mAm.mProcessStats);
                    realStartServiceLocked(r, app, execInFg);
                    return null;
                } catch (TransactionTooLargeException e) {
                } catch (RemoteException e) {

                }

            }
        } else {

            app = r.isolatedProc;
            if (WebViewZygote.isMultiprocessEnabled()
                    && r.serviceInfo.packageName.equals(WebViewZygote.getPackageName())) {
                hostingType = "webview_service";
            }
        }


        if (app == null && !permissionsReviewRequired) {
            if ((app=mAm.startProcessLocked(procName, r.appInfo, true, intentFlags,
                    hostingType, r.name, false, isolated, false)) == null) {

                bringDownServiceLocked(r);
                return msg;
            }
            if (isolated) {
                r.isolatedProc = app;
            }
        }

        if (r.fgRequired) {
            mAm.tempWhitelistUidLocked(r.appInfo.uid,
                    SERVICE_START_FOREGROUND_TIMEOUT, "fg-service-launch");
        }

        if (!mPendingServices.contains(r)) {
            mPendingServices.add(r);
        }

        if (r.delayedStop) {
            r.delayedStop = false;
            if (r.startRequested) {
                stopServiceLocked(r);
            }
        }

        return null;
    }
```
- 1.如果ServiceRecord已经保存了app远程端的Binder对象，说明该Service已经启动过了，则直接执行sendServiceArgsLocked执行Service的其他声明周期。

- 2.如果ServiceRecord的delay属性为true，则从mDelayedStartList移除该ServiceRecord，delay设置为true。说明此时开始启动服务了。

- 3.如果AndroidManifest中的service标签设置了`android:isolatedProcess`,说明这个Service需要启动在另一个隔离的进程中执行。我们先只考虑false的情况，此时说明是app在app进程中启动Service。
  - 3.1.getProcessRecordLocked获取当前App进程的ProcessRecord，如果ProcessRecord不为空，则说明该进程已经启动了。此时为ProcessRecord的addPackage后，调用realStartServiceLocked 启动Service。

- 4.如果`android:isolatedProcess`为true，说明每一次启动Service都应该是一个新的隔离进程。把ServiceRecord设置给app。那么app这个ProcessRecord对象就是空，此时permissionsReviewRequired就是false。每执行一次这个startProcessLocked方法，说明`android:isolatedProcess`标志为每一次都是启动app进程对象。
  - 4.1.调用一次bringDownServiceLocked方法
  - 4.2.mPendingServices如果不包含需要启动的ServiceRecord，则添加到mPendingService中保存。

##### realStartServiceLocked
```java
    private final void realStartServiceLocked(ServiceRecord r,
            ProcessRecord app, boolean execInFg) throws RemoteException {
        if (app.thread == null) {
            throw new RemoteException();
        }

        r.app = app;
        r.restartTime = r.lastActivity = SystemClock.uptimeMillis();

        final boolean newService = app.services.add(r);
        bumpServiceExecutingLocked(r, execInFg, "create");
        mAm.updateLruProcessLocked(app, false, null);
        updateServiceForegroundLocked(r.app, /* oomAdj= */ false);
        mAm.updateOomAdjLocked();

        boolean created = false;
        try {

            synchronized (r.stats.getBatteryStats()) {
                r.stats.startLaunchedLocked();
            }
            mAm.notifyPackageUse(r.serviceInfo.packageName,
                                 PackageManager.NOTIFY_PACKAGE_USE_SERVICE);
            app.forceProcessStateUpTo(ActivityManager.PROCESS_STATE_SERVICE);
            app.thread.scheduleCreateService(r, r.serviceInfo,
                    mAm.compatibilityInfoForPackageLocked(r.serviceInfo.applicationInfo),
                    app.repProcState);
            r.postNotification();
            created = true;
        } catch (DeadObjectException e) {
            Slog.w(TAG, "Application dead when creating service " + r);
            mAm.appDiedLocked(app);
            throw e;
        } finally {
            if (!created) {
                // Keep the executeNesting count accurate.
                final boolean inDestroying = mDestroyingServices.contains(r);
                serviceDoneExecutingLocked(r, inDestroying, inDestroying);

                // Cleanup.
                if (newService) {
                    app.services.remove(r);
                    r.app = null;
                }

                // Retry.
                if (!inDestroying) {
                    scheduleServiceRestartLocked(r, false);
                }
            }
        }

        if (r.whitelistManager) {
            app.whitelistManager = true;
        }

        requestServiceBindingsLocked(r, execInFg);

        updateServiceClientActivitiesLocked(app, null, true);

        if (r.startRequested && r.callStart && r.pendingStarts.size() == 0) {
            r.pendingStarts.add(new ServiceRecord.StartItem(r, false, r.makeNextStartId(),
                    null, null, 0));
        }

        sendServiceArgsLocked(r, execInFg, true);

        if (r.delayed) {
            getServiceMapLocked(r.userId).mDelayedStartList.remove(r);
            r.delayed = false;
        }

        if (r.delayedStop) {
            r.delayedStop = false;
            if (r.startRequested) {
                stopServiceLocked(r);
            }
        }
    }
```
- 1.启动Service前，先把ServiceRecord添加到ProcessRecord的services集合，说明这个Service正在运行了。bumpServiceExecutingLocked埋入Service的ANR消息，更新当前App应用的adj优先级
- 2.跨进程调用App端的ApplicationThread的scheduleCreateService方法，创建Service对象，执行onCreate
- 3.如果创建的过程中失败了，说明可能App端要么死掉，要么就是创建过程发生了异常，此时会调用serviceDoneExecutingLocked方法，执行Service的完成事务的任务。
- 4.如果发现保存已经销毁的Service对象集合mDestroyingServices并没有这个Service，就会再一次的尝试启动。
- 5.requestServiceBindingLocked 执行服务绑定的Connection对象。注意此时是startService，因此不会有任何挂载的Connection对象。只有bindService才会执行。
- 6.sendServiceArgsLocked 执行Service发送数据
- 7.移除mDelayedStartList中的ServiceRecord

这几个关键的步骤，让我们依次的考察，先来看看scheduleCreateService中做了什么。

#### bumpServiceExecutingLocked
```java
    private final void bumpServiceExecutingLocked(ServiceRecord r, boolean fg, String why) {

        boolean timeoutNeeded = true;
        if ((mAm.mBootPhase < SystemService.PHASE_THIRD_PARTY_APPS_CAN_START)
                && (r.app != null) && (r.app.pid == android.os.Process.myPid())) {

            timeoutNeeded = false;
        }

        long now = SystemClock.uptimeMillis();
        if (r.executeNesting == 0) {
            r.executeFg = fg;
            ServiceState stracker = r.getTracker();
            if (stracker != null) {
                stracker.setExecuting(true, mAm.mProcessStats.getMemFactorLocked(), now);
            }
            if (r.app != null) {
                r.app.executingServices.add(r);
                r.app.execServicesFg |= fg;
                if (timeoutNeeded && r.app.executingServices.size() == 1) {
                    scheduleServiceTimeoutLocked(r.app);
                }
            }
        } else if (r.app != null && fg && !r.app.execServicesFg) {
            r.app.execServicesFg = true;
            if (timeoutNeeded) {
                scheduleServiceTimeoutLocked(r.app);
            }
        }
        r.executeFg |= fg;
        r.executeNesting++;
        r.executingStart = now;
    }
```
如果第一次启动就走第一个if的分支：
- 1.ProcessRecord的executingServices 正在执行任务的Service集合添加ServiceRecord对象
- 2.执行scheduleServiceTimeoutLocked ANR超时埋点。

###### scheduleServiceTimeoutLocked
```java
    void scheduleServiceTimeoutLocked(ProcessRecord proc) {
        if (proc.executingServices.size() == 0 || proc.thread == null) {
            return;
        }
        Message msg = mAm.mHandler.obtainMessage(
                ActivityManagerService.SERVICE_TIMEOUT_MSG);
        msg.obj = proc;
        mAm.mHandler.sendMessageDelayed(msg,
                proc.execServicesFg ? SERVICE_TIMEOUT : SERVICE_BACKGROUND_TIMEOUT);
    }
```
能看到和BroadcastReceiver的ANR思路一样，通过一个延时的Handler，如果达到时间了还没有移除这个Handler消息则报ANR异常。

这里根据启动前台和后台分为两种超时时间：
```java
  
    // How long we wait for a service to finish executing.
    static final int SERVICE_TIMEOUT = 20*1000;

    // How long we wait for a service to finish executing.
    static final int SERVICE_BACKGROUND_TIMEOUT = SERVICE_TIMEOUT * 10;

    // How long the startForegroundService() grace period is to get around to
    // calling startForeground() before we ANR + stop it.
    static final int SERVICE_START_FOREGROUND_TIMEOUT = 10*1000;
```
前台分别是10秒，后台服务不属于后台进程组(判断adj是否在SCHED_GROUP_BACKGROUND)是20秒，后台服务属于后台进程组 200秒。

#### ApplicationThread scheduleCreateService
```java
        public final void scheduleCreateService(IBinder token,
                ServiceInfo info, CompatibilityInfo compatInfo, int processState) {
            updateProcessState(processState, false);
            CreateServiceData s = new CreateServiceData();
            s.token = token;
            s.info = info;
            s.compatInfo = compatInfo;

            sendMessage(H.CREATE_SERVICE, s);
        }
```
把数据封装成CreateServiceData后，通过Handler调用如下方法：
```java
    private void handleCreateService(CreateServiceData data) {

        unscheduleGcIdler();

        LoadedApk packageInfo = getPackageInfoNoCheck(
                data.info.applicationInfo, data.compatInfo);
        Service service = null;
        try {
            java.lang.ClassLoader cl = packageInfo.getClassLoader();
            service = packageInfo.getAppFactory()
                    .instantiateService(cl, data.info.name, data.intent);
        } catch (Exception e) {

        }

        try {
            ContextImpl context = ContextImpl.createAppContext(this, packageInfo);
            context.setOuterContext(service);

            Application app = packageInfo.makeApplication(false, mInstrumentation);
            service.attach(context, this, data.info.name, data.token, app,
                    ActivityManager.getService());
            service.onCreate();
            mServices.put(data.token, service);
            try {
                ActivityManager.getService().serviceDoneExecuting(
                        data.token, SERVICE_DONE_EXECUTING_ANON, 0, 0);
            } catch (RemoteException e) {
                throw e.rethrowFromSystemServer();
            }
        } catch (Exception e) {
        }
    }
```
- 1.通过AppComponentFactory反射创建一个全新的Service对象
- 2.通过ContextImpl.createAppContext 创建一个新的Context。
- 3.获取LoadedApk中的Application对象，调用Service的attach方法绑定Context。
- 4.调用Service的onCreate方法
- 5.Service以ServiceRecord的token为key缓存到mServices这个Map对象中中
- 5.调用AMS的serviceDoneExecuting方法。

透三点的核心原理可以看我写的的Application创建和BroadcastReceiver原理两篇文章。来看看Service中都做了什么？

##### Service attach
```java
    public final void attach(
            Context context,
            ActivityThread thread, String className, IBinder token,
            Application application, Object activityManager) {
        attachBaseContext(context);
        mThread = thread;           // NOTE:  unused - remove?
        mClassName = className;
        mToken = token;
        mApplication = application;
        mActivityManager = (IActivityManager)activityManager;
        mStartCompatibility = getApplicationInfo().targetSdkVersion
                < Build.VERSION_CODES.ECLAIR;
    }
```
很简单就是保存了传递过来的参数，值得注意的是这个IBinder对象其实就是指ServiceRecord对象。

接着执行Service.onCreate这个空实现的方法。

##### AMS serviceDoneExecuting
```java
    public void serviceDoneExecuting(IBinder token, int type, int startId, int res) {
        synchronized(this) {
            mServices.serviceDoneExecutingLocked((ServiceRecord)token, type, startId, res);
        }
    }
```
本质上还是调用了ActiveServices的serviceDoneExecutingLocked方法。
```java
    void serviceDoneExecutingLocked(ServiceRecord r, int type, int startId, int res) {
        boolean inDestroying = mDestroyingServices.contains(r);
        if (r != null) {
            if (type == ActivityThread.SERVICE_DONE_EXECUTING_START) {
....
            } else if (type == ActivityThread.SERVICE_DONE_EXECUTING_STOP) {
....
                } else if (r.executeNesting != 1) {
....
                }
            }
            final long origId = Binder.clearCallingIdentity();
            serviceDoneExecutingLocked(r, inDestroying, inDestroying);
            Binder.restoreCallingIdentity(origId);
        } else {
...
        }
    }
```
type是SERVICE_DONE_EXECUTING_ANON，所不会做更多的处理。 最后执行了serviceDoneExecutingLocked方法。

###### ActiveServices serviceDoneExecutingLocked
```java
    private void serviceDoneExecutingLocked(ServiceRecord r, boolean inDestroying,
            boolean finishing) {

        r.executeNesting--;
        if (r.executeNesting <= 0) {
            if (r.app != null) {

                r.app.execServicesFg = false;
                r.app.executingServices.remove(r);
                if (r.app.executingServices.size() == 0) {
                    mAm.mHandler.removeMessages(ActivityManagerService.SERVICE_TIMEOUT_MSG, r.app);
                } else if (r.executeFg) {

                    for (int i=r.app.executingServices.size()-1; i>=0; i--) {
                        if (r.app.executingServices.valueAt(i).executeFg) {
                            r.app.execServicesFg = true;
                            break;
                        }
                    }
                }
                if (inDestroying) {

                    mDestroyingServices.remove(r);
                    r.bindings.clear();
                }
                mAm.updateOomAdjLocked(r.app, true);
            }
            r.executeFg = false;
            if (r.tracker != null) {
                r.tracker.setExecuting(false, mAm.mProcessStats.getMemFactorLocked(),
                        SystemClock.uptimeMillis());
                if (finishing) {
                    r.tracker.clearCurrentOwner(r, false);
                    r.tracker = null;
                }
            }
            if (finishing) {
                if (r.app != null && !r.app.persistent) {
                    r.app.services.remove(r);
                    if (r.whitelistManager) {
                        updateWhitelistManagerLocked(r.app);
                    }
                }
                r.app = null;
            }
        }
    }
```
- 1.executeNesting 递减一之后小于等于0，说明该ServiceRecord只执行了一次启动。接着移除executingServices中的ServiceRecord，说明正在执行的Service已经处理完毕了。
- 2.如果executingServices大小为0，则移除ActivityManagerService.SERVICE_TIMEOUT_MSG这个Handler消息，也就是拆开了ANR的消息
- 3.如果执行的是结束Service的方法，则从ProcessRecord的services移除ServiceRecord。

#### ActiveServices sendServiceArgsLocked
```java
    private final void sendServiceArgsLocked(ServiceRecord r, boolean execInFg,
            boolean oomAdjusted) throws TransactionTooLargeException {
        final int N = r.pendingStarts.size();
        if (N == 0) {
            return;
        }

        ArrayList<ServiceStartArgs> args = new ArrayList<>();

        while (r.pendingStarts.size() > 0) {
            ServiceRecord.StartItem si = r.pendingStarts.remove(0);
            if (si.intent == null && N > 1) {
                continue;
            }
            si.deliveredTime = SystemClock.uptimeMillis();
            r.deliveredStarts.add(si);
            si.deliveryCount++;
...
            bumpServiceExecutingLocked(r, execInFg, "start");
            if (!oomAdjusted) {
                oomAdjusted = true;
                mAm.updateOomAdjLocked(r.app, true);
            }
            if (r.fgRequired && !r.fgWaiting) {
                if (!r.isForeground) {
                    scheduleServiceForegroundTransitionTimeoutLocked(r);
                } else {
                    r.fgRequired = false;
                }
            }
            int flags = 0;
            if (si.deliveryCount > 1) {
                flags |= Service.START_FLAG_RETRY;
            }
            if (si.doneExecutingCount > 0) {
                flags |= Service.START_FLAG_REDELIVERY;
            }
            args.add(new ServiceStartArgs(si.taskRemoved, si.id, flags, si.intent));
        }

        ParceledListSlice<ServiceStartArgs> slice = new ParceledListSlice<>(args);
        slice.setInlineCountLimit(4);
        Exception caughtException = null;
        try {
            r.app.thread.scheduleServiceArgs(r, slice);
        } catch (TransactionTooLargeException e) {
            caughtException = e;
        } catch (RemoteException e) {

            caughtException = e;
        } catch (Exception e) {
            Slog.w(TAG, "Unexpected exception", e);
            caughtException = e;
        }

...
    }
```
- 1.遍历所有保存在ServiceRecord.pendingStarts中的ServiceRecord.StartItem对象，把ServiceRecord.StartItem保存到ServiceRecord的deliveredStarts中，说明这些数据正在分发。
  - 1.1.调用bumpServiceExecutingLocked方法继续埋下ANR的Handler定时消息
  - 1.2.更新当前进程的adj应用优先级
  - 1.3.以ServiceRecord.StartItem的Intent,flag,id构成用于在App端分发ServiceStartArgs对象，并保存到slice这个ParceledListSlice<ServiceStartArgs>对象中.
  - 1.4.跨进程通信，调用ApplicationThread的scheduleServiceArgs方法。


#### ActivityThread scheduleServiceArgs
```java
        public final void scheduleServiceArgs(IBinder token, ParceledListSlice args) {
            List<ServiceStartArgs> list = args.getList();

            for (int i = 0; i < list.size(); i++) {
                ServiceStartArgs ssa = list.get(i);
                ServiceArgsData s = new ServiceArgsData();
                s.token = token;
                s.taskRemoved = ssa.taskRemoved;
                s.startId = ssa.startId;
                s.flags = ssa.flags;
                s.args = ssa.args;

                sendMessage(H.SERVICE_ARGS, s);
            }
        }
```
这个方法不断的循环遍历List<ServiceStartArgs>分发SERVICE_ARGS消息，这个消息通过主线程的Looper调用handleServiceArgs。

###### handleServiceArgs
```java
    private void handleServiceArgs(ServiceArgsData data) {
        Service s = mServices.get(data.token);
        if (s != null) {
            try {
                if (data.args != null) {
                    data.args.setExtrasClassLoader(s.getClassLoader());
                    data.args.prepareToEnterProcess();
                }
                int res;
                if (!data.taskRemoved) {
                    res = s.onStartCommand(data.args, data.flags, data.startId);
                } else {
                    s.onTaskRemoved(data.args);
                    res = Service.START_TASK_REMOVED_COMPLETE;
                }

                QueuedWork.waitToFinish();

                try {
                    ActivityManager.getService().serviceDoneExecuting(
                            data.token, SERVICE_DONE_EXECUTING_START, data.startId, res);
                } catch (RemoteException e) {
                    throw e.rethrowFromSystemServer();
                }
                ensureJitEnabled();
            } catch (Exception e) {
...
            }
        }
    }
```
- 1.从mServices获取到已经实例化的Service对象，如果ServiceArgsData的taskRemoved为false(都为false，除非是进程销毁时候才会出现taskRemoved是true)，则回调Service的onStartCommand；否则则回调onTaskRemoved方法
- 2.QueuedWork调用waitToFinish方法，阻塞SharePreference把所有的数据写入到磁盘中。
- 3.serviceDoneExecuting 移除ANR超时消息

## bindService 原理

bindService在开发中用的不是很多，这里稍微提一下他的使用。
首先申明一个ServiceConnection对象，用于绑定服务端的Service。
```java
   private ServiceConnection conn = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
 
            MyBinder myBinder = MyBinder.Stub.asInterface(binder);
            service = myBinder.getService();
            int num = service.getRandomNumber();

        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            isBound = false;
        }
    };

```
```java
            Intent intent = new Intent(this, TestService.class);
            bindService(intent, conn, BIND_AUTO_CREATE);
```
调用bindService的方法绑定到某个Service中。当服务端的service成功回调onBind方法，我们只需要返回对应的Binder对象。就能使用调用bindService的客户端在ServiceConnection的onServiceConnected的回调中获得Binder对象。

之后就能通过这个Binder调用本进程或者其他进程的的方法了。实际上我们可以把这个过程看成一个多对多的服务-客户端模型。多个客户端通过Binder向多服务端Service通信，每一次我们都可以通过ComponentName判断不同服务返回来的Binder对象。


### bindService的入口  bindServiceCommon
```java
    private boolean bindServiceCommon(Intent service, ServiceConnection conn, int flags, Handler
            handler, UserHandle user) {

        IServiceConnection sd;
        if (conn == null) {
            throw new IllegalArgumentException("connection is null");
        }
        if (mPackageInfo != null) {
            sd = mPackageInfo.getServiceDispatcher(conn, getOuterContext(), handler, flags);
        } else {
            throw new RuntimeException("Not supported in system context");
        }
        validateServiceIntent(service);
        try {
            IBinder token = getActivityToken();
            if (token == null && (flags&BIND_AUTO_CREATE) == 0 && mPackageInfo != null
                    && mPackageInfo.getApplicationInfo().targetSdkVersion
                    < android.os.Build.VERSION_CODES.ICE_CREAM_SANDWICH) {
                flags |= BIND_WAIVE_PRIORITY;
            }
            service.prepareToLeaveProcess(this);
            int res = ActivityManager.getService().bindService(
                mMainThread.getApplicationThread(), getActivityToken(), service,
                service.resolveTypeIfNeeded(getContentResolver()),
                sd, flags, getOpPackageName(), user.getIdentifier());
            if (res < 0) {
                throw new SecurityException(
                        "Not allowed to bind to service " + service);
            }
            return res != 0;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
- 1.作为参数的ServiceConnection不能为空。
- 2.通过LoadedApk的getServiceDispatcher方法把ServiceConnection转化IServiceConnection对象。
- 3.调用AMS的bindService方法。

### LoadedApk getServiceDispatcher
```java
    public final IServiceConnection getServiceDispatcher(ServiceConnection c,
            Context context, Handler handler, int flags) {
        synchronized (mServices) {
            LoadedApk.ServiceDispatcher sd = null;
            ArrayMap<ServiceConnection, LoadedApk.ServiceDispatcher> map = mServices.get(context);
            if (map != null) {
                sd = map.get(c);
            }
            if (sd == null) {
                sd = new ServiceDispatcher(c, context, handler, flags);

                if (map == null) {
                    map = new ArrayMap<>();
                    mServices.put(context, map);
                }
                map.put(c, sd);
            } else {
                sd.validate(context, handler);
            }
            return sd.getIServiceConnection();
        }
    }
```
这里面很简单，和BroadcastReceiver的思路很像。动态注册的BroadcastReceiver会封装成一个ReceiverDispatcher，而这里把ServiceConnection封装成LoadedApk.ServiceDispatcher对象。

并且会把ServiceDispatcher作为value，ServiceConnection作为key缓存一个map中。并且以context为key，把这个临时的map作为value缓存起来。这样一个Context就映射有了多个ServiceDispatcher对象，也就可以注册多个监听被绑定Service状态的监听者了。

### 核心对象ServiceDispatcher的介绍
```java
    static final class ServiceDispatcher {
        private final ServiceDispatcher.InnerConnection mIServiceConnection;
        private final ServiceConnection mConnection;
        private final Context mContext;
        private final Handler mActivityThread;
        private final ServiceConnectionLeaked mLocation;
        private final int mFlags;

        private RuntimeException mUnbindLocation;

        private boolean mForgotten;

        private static class ConnectionInfo {
            IBinder binder;
            IBinder.DeathRecipient deathMonitor;
        }

        private static class InnerConnection extends IServiceConnection.Stub {
            final WeakReference<LoadedApk.ServiceDispatcher> mDispatcher;

            InnerConnection(LoadedApk.ServiceDispatcher sd) {
                mDispatcher = new WeakReference<LoadedApk.ServiceDispatcher>(sd);
            }

            public void connected(ComponentName name, IBinder service, boolean dead)
                    throws RemoteException {
                LoadedApk.ServiceDispatcher sd = mDispatcher.get();
                if (sd != null) {
                    sd.connected(name, service, dead);
                }
            }
        }

        private final ArrayMap<ComponentName, ServiceDispatcher.ConnectionInfo> mActiveConnections
            = new ArrayMap<ComponentName, ServiceDispatcher.ConnectionInfo>();

        ServiceDispatcher(ServiceConnection conn,
                Context context, Handler activityThread, int flags) {
            mIServiceConnection = new InnerConnection(this);
            mConnection = conn;
            mContext = context;
            mActivityThread = activityThread;
            mLocation = new ServiceConnectionLeaked(null);
            mLocation.fillInStackTrace();
            mFlags = flags;
        }

...
        ServiceConnectionLeaked getLocation() {
            return mLocation;
        }

        ServiceConnection getServiceConnection() {
            return mConnection;
        }

        IServiceConnection getIServiceConnection() {
            return mIServiceConnection;
        }

....

        public void connected(ComponentName name, IBinder service, boolean dead) {
            if (mActivityThread != null) {
                mActivityThread.post(new RunConnection(name, service, 0, dead));
            } else {
                doConnected(name, service, dead);
            }
        }

        public void death(ComponentName name, IBinder service) {
            if (mActivityThread != null) {
                mActivityThread.post(new RunConnection(name, service, 1, false));
            } else {
                doDeath(name, service);
            }
        }

        public void doConnected(ComponentName name, IBinder service, boolean dead) {
            ServiceDispatcher.ConnectionInfo old;
            ServiceDispatcher.ConnectionInfo info;

            synchronized (this) {
                if (mForgotten) {

                    return;
                }
                old = mActiveConnections.get(name);
                if (old != null && old.binder == service) {
                    return;
                }

                if (service != null) {
                    info = new ConnectionInfo();
                    info.binder = service;
                    info.deathMonitor = new DeathMonitor(name, service);
                    try {
                        service.linkToDeath(info.deathMonitor, 0);
                        mActiveConnections.put(name, info);
                    } catch (RemoteException e) {

                        mActiveConnections.remove(name);
                        return;
                    }

                } else {
                    mActiveConnections.remove(name);
                }

                if (old != null) {
                    old.binder.unlinkToDeath(old.deathMonitor, 0);
                }
            }

            if (old != null) {
                mConnection.onServiceDisconnected(name);
            }
            if (dead) {
                mConnection.onBindingDied(name);
            }

            if (service != null) {
                mConnection.onServiceConnected(name, service);
            } else {

                mConnection.onNullBinding(name);
            }
        }

        public void doDeath(ComponentName name, IBinder service) {
            synchronized (this) {
                ConnectionInfo old = mActiveConnections.get(name);
                if (old == null || old.binder != service) {
                    // Death for someone different than who we last
                    // reported...  just ignore it.
                    return;
                }
                mActiveConnections.remove(name);
                old.binder.unlinkToDeath(old.deathMonitor, 0);
            }

            mConnection.onServiceDisconnected(name);
        }

        private final class RunConnection implements Runnable {
            RunConnection(ComponentName name, IBinder service, int command, boolean dead) {
                mName = name;
                mService = service;
                mCommand = command;
                mDead = dead;
            }

            public void run() {
                if (mCommand == 0) {
                    doConnected(mName, mService, mDead);
                } else if (mCommand == 1) {
                    doDeath(mName, mService);
                }
            }

            final ComponentName mName;
            final IBinder mService;
            final int mCommand;
            final boolean mDead;
        }

        private final class DeathMonitor implements IBinder.DeathRecipient
        {
            DeathMonitor(ComponentName name, IBinder service) {
                mName = name;
                mService = service;
            }

            public void binderDied() {
                death(mName, mService);
            }

            final ComponentName mName;
            final IBinder mService;
        }
    }
```
这个类我们可以对照BroadcastReceiver的原理进行对照学习。
- ServiceDispatcher.InnerConnection 这个InnerConnection对象是用于监听被绑定服务的状态，是一个Binder对象，也就说可以跨进程监听被绑定的服务状态。

一旦ServiceConnection的声明周期发生了变化，InnerConnection首先会得知状态的变化，从而回调ServiceDispatcher进行处理。

- ServiceDispatcher 是整个Service分发ServiceConnection事件的核心。注意，它持有3个关键对象：
  - mIServiceConnection 代表当前ServiceDispatcher对象对应的Binder对象
  - mActiveConnections 集合。每一次当一个新的Service返回了绑定成功的消息后，就会把这个Service的类名等信息保存到mActiveConnections中。
  - mConnection 就是bindService注册进来的监听者，每当被绑定的Service发生了变化，就会通过这个接口回调。



### AMS bindService
```java
   public int bindService(IApplicationThread caller, IBinder token, Intent service,
            String resolvedType, IServiceConnection connection, int flags, String callingPackage,
            int userId) throws TransactionTooLargeException {
...
        synchronized(this) {
            return mServices.bindServiceLocked(caller, token, service,
                    resolvedType, connection, flags, callingPackage, userId);
        }
    }
```
核心就是调用了ActiveServices的bindServiceLocked方法。

```java
    int bindServiceLocked(IApplicationThread caller, IBinder token, Intent service,
            String resolvedType, final IServiceConnection connection, int flags,
            String callingPackage, final int userId) throws TransactionTooLargeException {

        final ProcessRecord callerApp = mAm.getRecordForAppLocked(caller);

        ActivityRecord activity = null;
        if (token != null) {
            activity = ActivityRecord.isInStackLocked(token);
            if (activity == null) {
                return 0;
            }
        }

....
        ServiceLookupResult res =
            retrieveServiceLocked(service, resolvedType, callingPackage, Binder.getCallingPid(),
                    Binder.getCallingUid(), userId, true, callerFg, isBindExternal, allowInstant);
        if (res == null) {
            return 0;
        }
        if (res.record == null) {
            return -1;
        }
        ServiceRecord s = res.record;

        boolean permissionsReviewRequired = false;

//此时config_permissionReviewRequired 是false
        if (mAm.mPermissionReviewRequired) {
...
        }

        final long origId = Binder.clearCallingIdentity();

        try {

...

            AppBindRecord b = s.retrieveAppBindingLocked(service, callerApp);
            ConnectionRecord c = new ConnectionRecord(b, activity,
                    connection, flags, clientLabel, clientIntent);

            IBinder binder = connection.asBinder();
            ArrayList<ConnectionRecord> clist = s.connections.get(binder);
            if (clist == null) {
                clist = new ArrayList<ConnectionRecord>();
                s.connections.put(binder, clist);
            }
            clist.add(c);
            b.connections.add(c);
            if (activity != null) {
                if (activity.connections == null) {
                    activity.connections = new HashSet<ConnectionRecord>();
                }
                activity.connections.add(c);
            }
            b.client.connections.add(c);
            if ((c.flags&Context.BIND_ABOVE_CLIENT) != 0) {
                b.client.hasAboveClient = true;
            }
            if ((c.flags&Context.BIND_ALLOW_WHITELIST_MANAGEMENT) != 0) {
                s.whitelistManager = true;
            }
            if (s.app != null) {
                updateServiceClientActivitiesLocked(s.app, c, true);
            }
            clist = mServiceConnections.get(binder);
            if (clist == null) {
                clist = new ArrayList<ConnectionRecord>();
                mServiceConnections.put(binder, clist);
            }
            clist.add(c);

            if ((flags&Context.BIND_AUTO_CREATE) != 0) {
                s.lastActivity = SystemClock.uptimeMillis();
                if (bringUpServiceLocked(s, service.getFlags(), callerFg, false,
                        permissionsReviewRequired) != null) {
                    return 0;
                }
            }

            if (s.app != null) {
                if ((flags&Context.BIND_TREAT_LIKE_ACTIVITY) != 0) {
                    s.app.treatLikeActivity = true;
                }
                if (s.whitelistManager) {
                    s.app.whitelistManager = true;
                }
                mAm.updateLruProcessLocked(s.app, s.app.hasClientActivities
                        || s.app.treatLikeActivity, b.client);
                mAm.updateOomAdjLocked(s.app, true);
            }


            if (s.app != null && b.intent.received) {

                try {
                    c.conn.connected(s.name, b.intent.binder, false);
                } catch (Exception e) {

                }

                if (b.intent.apps.size() == 1 && b.intent.doRebind) {
                    requestServiceBindingLocked(s, b.intent, callerFg, true);
                }
            } else if (!b.intent.requested) {
                requestServiceBindingLocked(s, b.intent, callerFg, false);
            }

            getServiceMapLocked(s.userId).ensureNotStartingBackgroundLocked(s);

        } finally {
            Binder.restoreCallingIdentity(origId);
        }

        return 1;
    }
```
- 1.ServiceRecord调用retrieveAppBindingLocked 根据当前的ServiceRecord,Intent 生成一个IntentBindRecord对象后，以Intent.FilterComparison为key，IntentBindRecord为value保存到ServiceRecord的bindings中。如果bindings通过IntentFilter找到对应存在的IntentBindRecord则直接获取。
```java
    final ArrayMap<Intent.FilterComparison, IntentBindRecord> bindings
            = new ArrayMap<Intent.FilterComparison, IntentBindRecord>();

    public AppBindRecord retrieveAppBindingLocked(Intent intent,
            ProcessRecord app) {
        Intent.FilterComparison filter = new Intent.FilterComparison(intent);
        IntentBindRecord i = bindings.get(filter);
        if (i == null) {
            i = new IntentBindRecord(this, filter);
            bindings.put(filter, i);
        }
        AppBindRecord a = i.apps.get(app);
        if (a != null) {
            return a;
        }
        a = new AppBindRecord(this, i, app);
        i.apps.put(app, a);
        return a;
    }
```
在从IntentBindRecord的apps集合中查找AppBindRecord对象，找到返回，找不到则生成全新返回。
```java
    final ArrayMap<ProcessRecord, AppBindRecord> apps
            = new ArrayMap<ProcessRecord, AppBindRecord>();
```

如果能够从bindings集合，通过意图过滤找到对应的IntentBindRecord，又通过IntentBindRecord的apps集合，通过ProcessRecord找到AppBindRecord对象。

而AppBindRecord这个对象最终会保存了所有的IServiceConnection。通过这样的关系就能通过Intent意图和ProcessRecord进程对象找到需要发送绑定监听对象。


- 2.retrieveServiceLocked 从ServiceMap或者PMS中解析出需要绑定或者启动的ServiceRecord对象，并包裹成ServiceLookupResult对象返回。

- 3.把IServiceConnection通过ConnectionRecord包裹起来。并且获取ServiceRecord中的connections这个ArrayMap集合。
```java
    final ArrayMap<IBinder, ArrayList<ConnectionRecord>> connections
            = new ArrayMap<IBinder, ArrayList<ConnectionRecord>>();
```
在每一个ServiceRecord中，以IBinder对象为key(也就是IServiceConnection)，并且保存以ConnectionRecord集合为value。保存一个Binder对应多个ServiceDispatcher的情况。

最后把这个包装了IServiceConnection的ConnectionRecord保存到connections的value的list中。


- 4.AppBinderRecord的connections集合也保存了ConnectionRecord对象。

- 5.如果当前调用bindService的ContextImpl是一个Activity，那么就会在对应的ActivityToken的HashSet<ConnectionRecord>中保存ConnectionRecord。

- 6.在ProcessRecord创建或者获取ArraySet<ConnectionRecord>对象，并把新的ConnectionRecord保存到这个Set中。

- 7.同样在ActiveServices中有一个和ServiceRecord相同的connections集合。

- 8.如果打开了Context.BIND_AUTO_CREATE这标志位，说明此时bindService执行中发现Service没有启动，则调用bringUpServiceLocked进行启动Service。如果bringUpServiceLocked成功的启动了Service，就不继续走下面的逻辑，直接返回了。

- 9.下面就是Service默认是已经创建，Service的进程存活，且IntentBindRecord的receiver为true。则会调用ConnectionRecord中的IServiceConnection这个Binder对象的跨进程方法connected，也就是调用ServiceDispatcher的InnerConnection的connected方法。

我们来考察一下之前在bringUpServiceLocked中忽略过的绑定Service逻辑，也就是在realStartServiceLocked调用的requestServiceBindingLocked方法。


#### requestServiceBindingLocked
```java
    private final void requestServiceBindingsLocked(ServiceRecord r, boolean execInFg)
            throws TransactionTooLargeException {
        for (int i=r.bindings.size()-1; i>=0; i--) {
            IntentBindRecord ibr = r.bindings.valueAt(i);
            if (!requestServiceBindingLocked(r, ibr, execInFg, false)) {
                break;
            }
        }
    }
```
能看到实际上那个就是获取ServiceRecord中所有的IntentBindRecord，调用requestServiceBindingLocked方法进行绑定。

```java
    private final boolean requestServiceBindingLocked(ServiceRecord r, IntentBindRecord i,
            boolean execInFg, boolean rebind) throws TransactionTooLargeException {
        if (r.app == null || r.app.thread == null) {
            return false;
        }

        if ((!i.requested || rebind) && i.apps.size() > 0) {
            try {
                bumpServiceExecutingLocked(r, execInFg, "bind");
                r.app.forceProcessStateUpTo(ActivityManager.PROCESS_STATE_SERVICE);
                r.app.thread.scheduleBindService(r, i.intent.getIntent(), rebind,
                        r.app.repProcState);
                if (!rebind) {
                    i.requested = true;
                }
                i.hasBound = true;
                i.doRebind = false;
            } catch (TransactionTooLargeException e) {
...
            } catch (RemoteException e) {
...
                return false;
            }
        }
        return true;
    }
```
核心方法就是跨进程调用ApplicationThread的scheduleBindService方法。

#### ActivityThread handleBindService

这个方法会通过ActivityThread主线程handler发送绑定服务的消息，也就是handleBindService

```java
    private void handleBindService(BindServiceData data) {
        Service s = mServices.get(data.token);

        if (s != null) {
            try {
                data.intent.setExtrasClassLoader(s.getClassLoader());
                data.intent.prepareToEnterProcess();
                try {
                    if (!data.rebind) {
                        IBinder binder = s.onBind(data.intent);
                        ActivityManager.getService().publishService(
                                data.token, data.intent, binder);
                    } else {
                        s.onRebind(data.intent);
                        ActivityManager.getService().serviceDoneExecuting(
                                data.token, SERVICE_DONE_EXECUTING_ANON, 0, 0);
                    }
                    ensureJitEnabled();
                } catch (RemoteException ex) {
                    throw ex.rethrowFromSystemServer();
                }
            } catch (Exception e) {
...
            }
        }
    }
```
- 1.调用Service的onBind方法，获取从Service中返回的允许客户端操作的Binder对象。跨进程调用AMS的publishService方法，把需要返回的Binder返回给客户端。
- 2.如果从BindServiceData中判断到当前的Service需要重新绑定则回调onRebind方法。调用serviceDoneExecuting方法告诉AMS已经接受了当前的执行任务。从而拆下ANR消息。

#### AMS publishService
```java
    public void publishService(IBinder token, Intent intent, IBinder service) {
...
        synchronized(this) {

            mServices.publishServiceLocked((ServiceRecord)token, intent, service);
        }
    }
```

```java
    void publishServiceLocked(ServiceRecord r, Intent intent, IBinder service) {
        final long origId = Binder.clearCallingIdentity();
        try {

            if (r != null) {
                Intent.FilterComparison filter
                        = new Intent.FilterComparison(intent);
                IntentBindRecord b = r.bindings.get(filter);
                if (b != null && !b.received) {
                    b.binder = service;
                    b.requested = true;
                    b.received = true;
                    for (int conni=r.connections.size()-1; conni>=0; conni--) {
                        ArrayList<ConnectionRecord> clist = r.connections.valueAt(conni);
                        for (int i=0; i<clist.size(); i++) {
                            ConnectionRecord c = clist.get(i);
                            if (!filter.equals(c.binding.intent.intent)) {
                                continue;
                            }

                            try {
                                c.conn.connected(r.name, service, false);
                            } catch (Exception e) {

                            }
                        }
                    }
                }

                serviceDoneExecutingLocked(r, mDestroyingServices.contains(r), false);
            }
        } finally {
            Binder.restoreCallingIdentity(origId);
        }
    }
```
- 此时就会获得Intent的意图，通过ServiceRecord的bindings中找到IntentBindRecord，IntentBindRecord设置receiver为true。

- 遍历ServiceRecord的connections集合中所有的ConnectionRecord，如果发现Service的Intent意图过滤不匹配则进入下一个loop中；如果符合意图，则调用ConnectionRecord的IServiceConnection的connected方法。这个方法就会跨进程调用的ServiceDisptacher中InnerConnection的connected方法,把从Service的onBind返回的Binder对象传递到InnerConnection中。

- serviceDoneExecutingLocked 执行完成任务行为，拆除Service的ANR消息。

### InnerConnection 接受connect的行为
```java

            public void connected(ComponentName name, IBinder service, boolean dead)
                    throws RemoteException {
                LoadedApk.ServiceDispatcher sd = mDispatcher.get();
                if (sd != null) {
                    sd.connected(name, service, dead);
                }
            }
```
当InnerConnection接受到了connected的调用，这里就会调用ServiceDispatcher的connected，把IBinder传递过来。注意这个IBinder就是从Service的onBind方法返回的Binder对象。

```java
        public void connected(ComponentName name, IBinder service, boolean dead) {
            if (mActivityThread != null) {
                mActivityThread.post(new RunConnection(name, service, 0, dead));
            } else {
                doConnected(name, service, dead);
            }
        }
```
核心就是调用doConnected，或者调用RunConnection Runnable对象执行其中的run方法。

##### RunConnection run
```java
            public void run() {
                if (mCommand == 0) {
                    doConnected(mName, mService, mDead);
                } else if (mCommand == 1) {
                    doDeath(mName, mService);
                }
            }

```
这里根据mCommand来执行doConnected进行ServiceConnection的绑定回调还是解绑回调。

这里是绑定，mCommand也为1。我们直接看doConnected。

###### ServiceDispatcher doConnected
```java
        public void doConnected(ComponentName name, IBinder service, boolean dead) {
            ServiceDispatcher.ConnectionInfo old;
            ServiceDispatcher.ConnectionInfo info;

            synchronized (this) {
                old = mActiveConnections.get(name);
                if (old != null && old.binder == service) {

                    return;
                }

                if (service != null) {
                    info = new ConnectionInfo();
                    info.binder = service;
                    info.deathMonitor = new DeathMonitor(name, service);
                    try {
                        service.linkToDeath(info.deathMonitor, 0);
                        mActiveConnections.put(name, info);
                    } catch (RemoteException e) {
                        mActiveConnections.remove(name);
                        return;
                    }

                } else {
                    mActiveConnections.remove(name);
                }

                if (old != null) {
                    old.binder.unlinkToDeath(old.deathMonitor, 0);
                }
            }

            if (old != null) {
                mConnection.onServiceDisconnected(name);
            }
            if (dead) {
                mConnection.onBindingDied(name);
            }
            if (service != null) {
                mConnection.onServiceConnected(name, service);
            } else {

                mConnection.onNullBinding(name);
            }
        }
```
- 1.把传递给客户端的Binder 封装到ConnectionInfo中。如果通过ComponentName查找到，本次发送给客户端的Binder和上一次的对象一致则直接返回。

- 2.为当前的Binder通过linkToDeath绑定Binder的死亡监听。如果这个发送给客户端操作的Binder对象死亡了，则会回调DeathMonitor，移除mActiveConnections中的对应Service名字的ConnectionInfo。这样就移除了还在活跃的Binder的缓存对象。

- 3.mActiveConnections 根据当前传递过来的Service的ComponentName为key，保存ConnectionInfo。

- 4.如果上一次的Binder对象不为空则解绑死亡监听，先回调onServiceDisconnected方法，告诉这个Binder已经解开了链接。如果此时Serice还是经历了stop的方法需要销毁了，还会执行onBindingDied方法，告诉客户端，远程端已经死亡了。

- 5.如果是新的不同对象，则会调用onServiceConnected分发Binder对象，告诉客户端已经绑定了。


## Service的销毁
Service还能通过stopService结束当前的服务。
```java
    private boolean stopServiceCommon(Intent service, UserHandle user) {
        try {
            validateServiceIntent(service);
            service.prepareToLeaveProcess(this);
            int res = ActivityManager.getService().stopService(
                mMainThread.getApplicationThread(), service,
                service.resolveTypeIfNeeded(getContentResolver()), user.getIdentifier());
            if (res < 0) {
                throw new SecurityException(
                        "Not allowed to stop service " + service);
            }
            return res != 0;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
核心就是调用AMS的stopService方法。而这个方法实际上就是调用ActiveServices的stopService方法。

#### ActiveServices stopServiceLocked
```java
    private void stopServiceLocked(ServiceRecord service) {
...
        bringDownServiceIfNeededLocked(service, false, false);
    }
```
```java
    private final void bringDownServiceIfNeededLocked(ServiceRecord r, boolean knowConn,
            boolean hasConn) {

...

        bringDownServiceLocked(r);
    }
```
核心就是bringDownServiceLocked方法。

##### bringDownServiceLocked
```java
    private final void bringDownServiceLocked(ServiceRecord r) {

        for (int conni=r.connections.size()-1; conni>=0; conni--) {
            ArrayList<ConnectionRecord> c = r.connections.valueAt(conni);
            for (int i=0; i<c.size(); i++) {
                ConnectionRecord cr = c.get(i);

                cr.serviceDead = true;
                try {
                    cr.conn.connected(r.name, null, true);
                } catch (Exception e) {

                }
            }
        }


        if (r.app != null && r.app.thread != null) {
            for (int i=r.bindings.size()-1; i>=0; i--) {
                IntentBindRecord ibr = r.bindings.valueAt(i);

                if (ibr.hasBound) {
                    try {
                        bumpServiceExecutingLocked(r, false, "bring down unbind");
                        mAm.updateOomAdjLocked(r.app, true);
                        ibr.hasBound = false;
                        ibr.requested = false;
                        r.app.thread.scheduleUnbindService(r,
                                ibr.intent.getIntent());
                    } catch (Exception e) {
                        serviceProcessGoneLocked(r);
                    }
                }
            }
        }


        if (r.fgRequired) {

            r.fgRequired = false;
            r.fgWaiting = false;
            mAm.mAppOpsService.finishOperation(AppOpsManager.getToken(mAm.mAppOpsService),
                    AppOpsManager.OP_START_FOREGROUND, r.appInfo.uid, r.packageName);
            mAm.mHandler.removeMessages(
                    ActivityManagerService.SERVICE_FOREGROUND_TIMEOUT_MSG, r);
...
        }


        r.destroyTime = SystemClock.uptimeMillis();


        final ServiceMap smap = getServiceMapLocked(r.userId);
        ServiceRecord found = smap.mServicesByName.remove(r.name);

...
        smap.mServicesByIntent.remove(r.intent);
        r.totalRestartCount = 0;
        unscheduleServiceRestartLocked(r, 0, true);

        for (int i=mPendingServices.size()-1; i>=0; i--) {
            if (mPendingServices.get(i) == r) {
                mPendingServices.remove(i);
            }
        }

...


        if (r.app != null) {
...
            if (r.app.thread != null) {
                updateServiceForegroundLocked(r.app, false);
                try {
                    bumpServiceExecutingLocked(r, false, "destroy");
                    mDestroyingServices.add(r);
                    r.destroying = true;
                    mAm.updateOomAdjLocked(r.app, true);
                    r.app.thread.scheduleStopService(r);
                } catch (Exception e) {

                    serviceProcessGoneLocked(r);
                }
            } else {
              
            }
        } else {

        }

        if (r.bindings.size() > 0) {
            r.bindings.clear();
        }
...
    }
```
这个过程很简单，可以根据三个循环分为三个部分：
- 1.在销毁之前，遍历ServiceRecord中所有的InnerConnection远程链接，并且调用connected方法，传递一个空的Binder对象，销毁存储在LoadedApk.ServiceDispatcher活跃的绑定监听。

- 2.遍历ServiceRecord所有的bindings存储的绑定的IntentBindRecord。先调用bumpServiceExecutingLocked埋下一个ANR消息。并且跨进程调用对应进程的scheduleUnbindService方法，把IntentBindRecord中存储的启动的意图传递过去。

- 3.如果是前台的服务还会移除SERVICE_FOREGROUND_TIMEOUT_MSG，前台服务执行任务超时ANR。

- 4.如果进程还存活，则bumpServiceExecutingLocked埋下销毁Service的ANR。更新进程的adj优先级后，跨进程调用scheduleStopService方法。

我们来看看在ApplicationThread中的scheduleUnbindService和scheduleStopService。

#### ActivityThread handleUnbindService
scheduleUnbindService最后会调用scheduleUnbindService方法。
```java

    private void handleUnbindService(BindServiceData data) {
        Service s = mServices.get(data.token);
        if (s != null) {
            try {
                data.intent.setExtrasClassLoader(s.getClassLoader());
                data.intent.prepareToEnterProcess();
                boolean doRebind = s.onUnbind(data.intent);
                try {
                    if (doRebind) {
                        ActivityManager.getService().unbindFinished(
                                data.token, data.intent, doRebind);
                    } else {
                        ActivityManager.getService().serviceDoneExecuting(
                                data.token, SERVICE_DONE_EXECUTING_ANON, 0, 0);
                    }
                } catch (RemoteException ex) {
                    throw ex.rethrowFromSystemServer();
                }
            } catch (Exception e) {

            }
        }
    }
```
从mServices缓存中获取Service对象，并执行onUnbind方法回调。如果onUnbind返回true说明需要重新绑定，则调用unbindFinished方法；否则则调用serviceDoneExecuting完成当前任务的执行。

#### ActivityThread handleStopService
```java
    private void handleStopService(IBinder token) {
        Service s = mServices.remove(token);
        if (s != null) {
            try {

                s.onDestroy();
                s.detachAndCleanUp();
                Context context = s.getBaseContext();
                if (context instanceof ContextImpl) {
                    final String who = s.getClassName();
                    ((ContextImpl) context).scheduleFinalCleanup(who, "Service");
                }

                QueuedWork.waitToFinish();

                try {
                    ActivityManager.getService().serviceDoneExecuting(
                            token, SERVICE_DONE_EXECUTING_STOP, 0, 0);
                } catch (RemoteException e) {
                }
            } catch (Exception e) {

            }
        } else {
        }
    }
```
- 1.调用Service的onDestroy方法
- 2.Service的detachAndCleanUp  销毁保存在Service中的ServiceRecord这个Binder对象
- 3.QueuedWork 等待SP的写入消息的落盘
- 4.serviceDoneExecuting 通知ActiveServices的移除销毁ANR的Handler消息

## 总结

Service的启动原理实际上很简单，我这边分为startService和bindService两个方法将进行总结。

startService实际上和bindService执行流程十分相似。只是bindService多执行了几个步骤，直接上bindService和stopService的时序图:
![Service.png](/images/Service.png)


### bindService 与 startService

bindService绑定服务，如果在bindService方法就是BIND_AUTO_CREATE的标志位，就会包含了startService的逻辑。这里就用BIND_AUTO_CREATE的逻辑来统一说说整个流程都做了什么。

- 1.在bindService进入AMS之前，就会调用LoadedApk.getServiceDispatcher获取一个ServiceDispatcher对象。

  - 1.1.而ServiceDispatcher这个对象包含了一个InnerConnection Binder对象。这个对象是用于直接沟通AMS的那边的回调，直接回调到ServiceConnection中。
  - 1.2.ServiceDispatcher中本身就有mServices缓存，它缓存了已经启动过的ServiceDispatcher。是以当前ContextImpl为value，以`ArrayMap<ServiceConnection, LoadedApk.ServiceDispatcher>`为value的Map。这样就会在同一个上下文中创建相同的服务分发者。

- 2.进入AMS后，首先会通过`retrieveServiceLocked `从AMS中查找两个级别的缓存，一个是缓存在AMS中的缓存，一个是缓存在PMS的缓存。
  - 2.1.AMS的缓存的缓存中又分为两个缓存。一个是通过类名+包名查找ServiceRecord；一个是通过意图过滤器查找Service。
  - 2.2.PMS中则是通过解析apk的AndroidManifest.xml的xml标签获得的。

- 3.如果发现ServiceRecord已经绑定了ProcessRecord说明已经启动过了，则调用scheduleServiceArgs，触发Service的onStartCommand返回。

- 4.如果发现没有绑定过则说明需要启动过，则scheduleCreateService，调用ActivityThread的handleCreateService，依次执行Service的attach方法绑定ServiceRecord以及onCreate方法，并把新的Service缓存起来。

- 5.在AMS的`bindServiceLocked`中，会把IServiceConnection绑定到ServiceRecord的`ArrayMap<Intent.FilterComparison, IntentBindRecord>  bindings`集合中。注意在IntentBindRecord集合中就保存了一个特殊的集合`ArrayMap<ProcessRecord, AppBindRecord>`，而AppBindRecord实际上就是持有了核心的ConnectionRecord集合。而ConnectionRecord就是正在的持有IServiceConnection。

弄的这么复杂，Google官方实际上指向做一件事：可以通过意图确定当前缓存的IServiceConnection 所指向的客户端进程，客户端的监听Service绑定接口对象。

- 6.`requestServiceBindingsLocked`方法会遍历所有绑定在ServiceRecord的binding集合，并且调用每一个ServiceRecord对应的Service的onBind的方法。

- 7.onBind返回 Service服务端允许客户端操作的Binder对象，则调用AMS的publishService。在AMS中则会查找ServiceRecord的bindings集合，遍历每一个IServiceConnection.connected 尝试回调在`bindService `方法中绑定的ServiceConnection接口。

- 8.IServiceConnection Binder对象在客户端实际上对应就是`ServiceDispatcher`中的`InnerConnection`对象。这个对象在`connected`方法会调用`RunConnection`的run方法，他会调用ActivityThread的Handler中执行`doConnected`把服务端分发过来Binder缓存到mActiveConnections，最后回调`ServiceConnection.onServiceConnected`

- 9.当启动和绑定都完成后，就会调用`sendServiceArgsLocked `方法。这个方法就是调用`ActivityThread. scheduleServiceArgs`方法。而这个方法最终调用Service的onStartCommand方法。注意这里分发的Intent就是之前启动service的Intent。当然onStartCommand会根据返回值在serviceDoneExecuting方法中决定了当Service执行完onStartCommand是否需要重启：

- START_STICKY 如果Service调用了onStartCommand之后被销毁，会重新启动，如果中间没任何命令传递给Service，此时Intent为null。

- START_NOT_STICKY 如果Service调用了onStartCommand之后被销毁，不会重启。

- START_REDELIVER_INTENT 如果Service调用了onStartCommand之后被销毁，会重新启动，如果中间没任何命令传递给Service，此时Intent为初始数。

- START_STICKY_COMPATIBILITY 兼容模式，不保证onStartCommand之后销毁会重启。

在这个过程中又几个比较重要的缓存对象：

![Service缓存图解.png](/images/Service缓存图解.png)


### Service销毁

在`bringDownServiceLocked`做了三件事情:
- 1.调用所有ServiceConnection的回调，回调onServiceDisconnected方法，并从活跃的Binder集合中移除
- 2.回调Service的onUnBind方法
- 3.回调Service的onDestroy方法和detachAndCleanUp销毁ServiceRecord

### Service 的ANR与注意
Service的ANR实际上是由`bumpServiceExecutingLocked `方法埋下的一个超时的ANR，超时时间根据是启动后台服务还是前台服务：
- 前台服务是10秒
- 后台服务 不过进程不是在ProcessList.SCHED_GROUP_BACKGROUND进程组中是 20秒
- 后台服务 不过进程在ProcessList.SCHED_GROUP_BACKGROUND进程组中是 200秒

当每一个Service执行完一个任务之后，都会执行serviceDoneExecutingLocked方法，把ActiveServices中的Handler的ANR倒计时消息移除。

有一点比较有意思的一点，启动服务有一个常见的问题，当通过startService启动Service的时候，会爆出错误。
```java
  Not allowed to start service Intent{xxxx}
```
禁止打开后台服务。在上面也有体现：如果startService返回的包名不是正常的包名而是一个`?`则会爆出这种错误。
```java
        if (forcedStandby || (!r.startRequested && !fgRequired)) {
            // Before going further -- if this app is not allowed to start services in the
            // background, then at this point we aren't going to let it period.
            final int allowed = mAm.getAppStartModeLocked(r.appInfo.uid, r.packageName,
                    r.appInfo.targetSdkVersion, callingPid, false, false, forcedStandby);
            if (allowed != ActivityManager.APP_START_MODE_NORMAL) {
...

                UidRecord uidRec = mAm.mActiveUids.get(r.appInfo.uid);
                return new ComponentName("?", "app is in background uid " + uidRec);
            }
        }
```


能看到如果此时fgRequired为false也就是非前台服务，会走入getAppStartModeLocked的校验。
```java
  int getAppStartModeLocked(int uid, String packageName, int packageTargetSdk,
            int callingPid, boolean alwaysRestrict, boolean disabledOnly, boolean forcedStandby) {
        UidRecord uidRec = mActiveUids.get(uid);

        if (uidRec == null || alwaysRestrict || forcedStandby || uidRec.idle) {
            boolean ephemeral;
            ...
             
                final int startMode = (alwaysRestrict)
                        ? appRestrictedInBackgroundLocked(uid, packageName, packageTargetSdk)
                        : appServicesRestrictedInBackgroundLocked(uid, packageName,
                                packageTargetSdk);
               ...
                return startMode;
             
        }
        return ActivityManager.APP_START_MODE_NORMAL;
    }
```
mActiveUids收集的是启动的活跃应用进程uid。
- uidRec为空，必定是没有启动或者是后台进程
- uidRec.idle为true，说明此时是启动过了但是呆在了后台超过60秒，从前台变化为后台进程。

这两个情况都会appServicesRestrictedInBackgroundLocked进行校验：
```java
    int appRestrictedInBackgroundLocked(int uid, String packageName, int packageTargetSdk) {

        if (packageTargetSdk >= Build.VERSION_CODES.O) {
            return ActivityManager.APP_START_MODE_DELAYED_RIGID;
        }
        int appop = mAppOpsService.noteOperation(AppOpsManager.OP_RUN_IN_BACKGROUND,
                uid, packageName);

        switch (appop) {
            case AppOpsManager.MODE_ALLOWED:
                // If force-background-check is enabled, restrict all apps that aren't whitelisted.
                if (mForceBackgroundCheck &&
                        !UserHandle.isCore(uid) &&
                        !isOnDeviceIdleWhitelistLocked(uid, /*allowExceptIdleToo=*/ true)) {
                    return ActivityManager.APP_START_MODE_DELAYED;
                }
           ...
    }
```
校验出了不在白名单中，就会返回APP_START_MODE_DELAYED。此时不是APP_START_MODE_NORMAL就会返回带了`?`的包名从而报错。



一般的，我们还会作如下处理从startService改成startForegroundService。但是这样就又爆出了全新的错误。

```java
Context.startForegroundService() did not then call Service.startForeground()

android.app.ActivityThread$H.handleMessage(ActivityThread.java:2204)
```
写高版本的service 稍不注意都会遇到这种情况。这是因为你没有在Service中使用startForeground方法。如果我们超过10秒没有一般我们都会使用startForeground启动一个通知，告诉用户正在前台运行。

而startForeground实际上是移除超时ANR的行为。

但是有时候，就算startForeground还是会报错，即使把时机尽可能的提前了，放在了onCreate中，还是会报错了。

我们能够看到实际上这个过程中每当执行完Service的onStartCommand，就会等待SP写入到磁盘的阻塞，也有可能是这个时候的写入时间过长了导致的ANR,详情可看[SharedPreferences源码解析](https://www.jianshu.com/p/ca1a2129523b)。

另一种可能就是因为整个流程都是在主线程中执行的，看看主线程有没有其他太过耗时的行为，导致来不及移除前台服务的ANR消息。

## 后记

到这里Service已经全部解析了，接下来我们来看看四大组件最后一个ContentProvider。












