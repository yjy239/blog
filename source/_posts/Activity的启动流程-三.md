---
title: Android 重学系列 Activity的启动流程(三)
top: false
cover: false
date: 2019-11-07 10:04:22
img:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---
# 前文提要
如果发现错误，请在本文指出：[https://www.jianshu.com/p/ac7b6a525b96](https://www.jianshu.com/p/ac7b6a525b96)

上一篇文章，跟随着源码深入了剖析了ActivityStack，TaskRecord在Activity启动的过程，怎么选择TaskRecord以及ActivityStack，以及是如何创建TaskRecord以及ActivityStack。当我们，确定的ActivityRecord，确定了TaskRecord，ActivityStack以及ActivityDisplay，已经决定好了ActivityRecord应该放在哪里，接下来就要通过Binder跨进程通信创建Activity。


# 正文
在我们操作完ActivityStack，TaskRecord在什么时候移动的前端，并且添加完ActivityRecord到TaskRecord之后。我们的数据结构已经处理完毕，还差跨进程启动Activity。但是启动Activity当然不可能凭空诞生，要我们自己编写逻辑，很容易能想到如下规则:
- 1.先暂定当前正在交互的Activity
- 2.检测Activity对应的进程是否存在
- 3.上述两步完成之后，才开始正在跨进程启动Activity。

接下来也是按照如下几步来处理。

# resumeTopActivityInnerLocked 启动Activity
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStack.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java)
这里我们只关注核心的内容。
```java
private boolean resumeTopActivityInnerLocked(ActivityRecord prev, ActivityOptions options) {
     ...
        final ActivityRecord next = topRunningActivityLocked(true /* focusableOnly */);

        final boolean hasRunningActivity = next != null;

        // TODO: Maybe this entire condition can get removed?
        if (hasRunningActivity && !isAttached()) {
            return false;
        }

        ....
    
        boolean lastResumedCanPip = false;
        ActivityRecord lastResumed = null;
        final ActivityStack lastFocusedStack = mStackSupervisor.getLastStack();
       ...
        final boolean resumeWhilePausing = (next.info.flags & FLAG_RESUME_WHILE_PAUSING) != 0
                && !lastResumedCanPip;
//停止Task内栈内的Activity
        boolean pausing = mStackSupervisor.pauseBackStacks(userLeaving, next, false);
        if (mResumedActivity != null) {
            pausing |= startPausingLocked(userLeaving, false, next, false);
        }
//判断到停止成功，则更新进程的lru数据
        if (pausing && !resumeWhilePausing) {
           ...
            if (next.app != null && next.app.thread != null) {
                mService.updateLruProcessLocked(next.app, true, null);
            }
  
            if (lastResumed != null) {
                lastResumed.setWillCloseOrEnterPip(true);
            }
            return true;
        } else if (mResumedActivity == next && next.isState(RESUMED)
                && mStackSupervisor.allResumedActivitiesComplete()) {
.....
            return true;
        }

       ....

        ActivityStack lastStack = mStackSupervisor.getLastStack();
        if (next.app != null && next.app.thread != null) {

            final boolean lastActivityTranslucent = lastStack != null
                    && (lastStack.inMultiWindowMode()
                    || (lastStack.mLastPausedActivity != null
                    && !lastStack.mLastPausedActivity.fullscreen));

//判断下一个即将即启动的ActivityRecord数据本省存在app等数据，则尝试resume
            synchronized(mWindowManager.getWindowManagerLock()) {
     
                if (!next.visible || next.stopped || lastActivityTranslucent) {
                    next.setVisibility(true);
                }

  
                next.startLaunchTickingLocked();

                ActivityRecord lastResumedActivity =
                        lastStack == null ? null :lastStack.mResumedActivity;
                final ActivityState lastState = next.getState();

                mService.updateCpuStats();

                next.setState(RESUMED, "resumeTopActivityInnerLocked");

                mService.updateLruProcessLocked(next.app, true, null);
                updateLRUListLocked(next);
                mService.updateOomAdjLocked();


       ....

                try {
                    final ClientTransaction transaction = ClientTransaction.obtain(next.app.thread,
                            next.appToken);
                    // Deliver all pending results.
                    ArrayList<ResultInfo> a = next.results;
                    if (a != null) {
                        final int N = a.size();
                        if (!next.finishing && N > 0) {
                            transaction.addCallback(ActivityResultItem.obtain(a));
                        }
                    }

                    if (next.newIntents != null) {
                        transaction.addCallback(NewIntentItem.obtain(next.newIntents,
                                false /* andPause */));
                    }


                    next.notifyAppResumed(next.stopped);

                    next.sleeping = false;
                    mService.getAppWarningsLocked().onResumeActivity(next);
                    mService.showAskCompatModeDialogLocked(next);
                    next.app.pendingUiClean = true;
                    next.app.forceProcessStateUpTo(mService.mTopProcessState);
                    next.clearOptionsLocked();
                    transaction.setLifecycleStateRequest(
                            ResumeActivityItem.obtain(next.app.repProcState,
                                    mService.isNextTransitionForward()));
                    mService.getLifecycleManager().scheduleTransaction(transaction);

                } catch (Exception e) {
              //resume失败，则尝试restart
                    next.setState(lastState, "resumeTopActivityInnerLocked");

                    
                    if (lastResumedActivity != null) {
                        lastResumedActivity.setState(RESUMED, "resumeTopActivityInnerLocked");
                    }

                    if (!next.hasBeenLaunched) {
                        next.hasBeenLaunched = true;
                    } else  if (SHOW_APP_STARTING_PREVIEW && lastStack != null
                            && lastStack.isTopStackOnDisplay()) {
                        next.showStartingWindow(null /* prev */, false /* newTask */,
                                false /* taskSwitch */);
                    }
                    mStackSupervisor.startSpecificActivityLocked(next, true, false);

                    return true;
                }
            }


            try {
                next.completeResumeLocked();
            } catch (Exception e) {
                requestFinishActivityLocked(next.appToken, Activity.RESULT_CANCELED, null,
                        "resume-exception", true);
                if (DEBUG_STACK) mStackSupervisor.validateTopActivitiesLocked();
                return true;
            }
        } else {
            // Whoops, need to restart this activity!
            if (!next.hasBeenLaunched) {
                next.hasBeenLaunched = true;
            } else {
                if (SHOW_APP_STARTING_PREVIEW) {
                    next.showStartingWindow(null /* prev */, false /* newTask */,
                            false /* taskSwich */);
                }
            
            }
     
            mStackSupervisor.startSpecificActivityLocked(next, true, true);
        }

...
        return true;
    }
```

在这个代码片段中，实际上可以看成在做两个步骤。
- 1.第一个调用Task栈内的所有Activity的onPause方法。
- 2.检测ActivityRecord是否为复用对象，是则回调onResume，不是则准备开始跨进程

## 调用Task栈内的所有Activity的onPause
在此时这个场景中，ActivityRecord next以及ActivityRecord prev是指同一个对象。因为在上一篇文章就有交代，在addOrReparentStartingActivity中会把ActivityRecord添加到Task的mActivities顶部。

因此此时从方法上传过来的和topRunningActivityLocked获取到的对象实际上都是我们新增加的ActivityRecord。
我们关注这一段代码
```java
    boolean pausing = mStackSupervisor.pauseBackStacks(userLeaving, next, false);
        if (mResumedActivity != null) {
            pausing |= startPausingLocked(userLeaving, false, next, false);
        }
```

让我们坠重一下对应的pauseBackStacks方法。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)

```java
 boolean pauseBackStacks(boolean userLeaving, ActivityRecord resuming, boolean dontWait) {
        boolean someActivityPaused = false;
        for (int displayNdx = mActivityDisplays.size() - 1; displayNdx >= 0; --displayNdx) {
            final ActivityDisplay display = mActivityDisplays.valueAt(displayNdx);
            for (int stackNdx = display.getChildCount() - 1; stackNdx >= 0; --stackNdx) {
                final ActivityStack stack = display.getChildAt(stackNdx);
                if (!isFocusedStack(stack) && stack.getResumedActivity() != null) {
                    if (DEBUG_STATES) Slog.d(TAG_STATES, "pauseBackStacks: stack=" + stack +
                            " mResumedActivity=" + stack.getResumedActivity());
                    someActivityPaused |= stack.startPausingLocked(userLeaving, false, resuming,
                            dontWait);
                }
            }
        }
        return someActivityPaused;
    }
```

能看到，这里面实际上会循环获取ActivityStackSupervisor中的ActivityDisplay中的ActivityStack。去调用每个stack的startPausingLocked方法。能发现，调用Activity的onPause方法，都是通过startPausingLocked这个核心方法。

```java
   final boolean startPausingLocked(boolean userLeaving, boolean uiSleeping,
            ActivityRecord resuming, boolean pauseImmediately) {
        if (mPausingActivity != null) {
            if (!shouldSleepActivities()) {
                completePauseLocked(false, resuming);
            }
        }
        ActivityRecord prev = mResumedActivity;

        if (prev == null) {
            if (resuming == null) {
                mStackSupervisor.resumeFocusedStackTopActivityLocked();
            }
            return false;
        }

        if (prev == resuming) {
            return false;
        }

        mPausingActivity = prev;
        mLastPausedActivity = prev;
...
        if (prev.app != null && prev.app.thread != null) {
            try {
                mService.updateUsageStats(prev, false);

                mService.getLifecycleManager().scheduleTransaction(prev.app.thread, prev.appToken,
                        PauseActivityItem.obtain(prev.finishing, userLeaving,
                                prev.configChangeFlags, pauseImmediately));
            } catch (Exception e) {
                mPausingActivity = null;
                mLastPausedActivity = null;
                mLastNoHistoryActivity = null;
            }
        } else {
            mPausingActivity = null;
            mLastPausedActivity = null;
            mLastNoHistoryActivity = null;
        }

        if (!uiSleeping && !mService.isSleepingOrShuttingDownLocked()) {
            mStackSupervisor.acquireLaunchWakelock();
        }

        if (mPausingActivity != null) {
            if (!uiSleeping) {
                prev.pauseKeyDispatchingLocked();
            } else if (DEBUG_PAUSE) {
                 Slog.v(TAG_PAUSE, "Key dispatch not paused for screen off");
            }

            if (pauseImmediately) {
                completePauseLocked(false, resuming);
                return false;

            } else {
                schedulePauseTimeout(prev);
                return true;
            }

        } else {
            if (resuming == null) {
                mStackSupervisor.resumeFocusedStackTopActivityLocked();
            }
            return false;
        }
    }
```
我们能看到实际上在这段代码十分简单：
- 1.首先判断当前需要停止的，和需要交互的ActivityRecord是不是同一个。是同一个则说明不需要停止ActivityRecord对应App端的Activity。

- 2.如果mResumedActivity的app以及app.thread都是不为空，说明该ActivityRecord已经启动过了。那么就能尝试着跨进程调用ActivityRecord对应的Activity的onPause方法。核心方法是下面:
```java
   mService.getLifecycleManager().scheduleTransaction(prev.app.thread, prev.appToken,
                        PauseActivityItem.obtain(prev.finishing, userLeaving,
                                prev.configChangeFlags, pauseImmediately));
```
能看到的是，里面有一个关键的对象PauseActivityItem。这个对象是用来跨进程通信，记住这个对象，十分重要，这个方法就是跨进程的核心方法，稍后会回来分析。

- 3.假如停止的mPausingActivity不为空，则按照标志位，来判断是否需要调用resume当前传下来的ActivityRecord。

这里值得注意一下的，此时有一个mResumedActivity对象。这个对象实际上在addOrReparentStartingActivity方法中会执行这么一个步骤addActivityAtIndex，设置完ActivityRecord设置完为止，就会调用setTask方法绑定当前的Task，其中就是这个方法：
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[TaskRecord.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/TaskRecord.java)
```java
  void setTask(TaskRecord task, boolean reparenting) {
        // Do nothing if the {@link TaskRecord} is the same as the current {@link getTask}.
        if (task != null && task == getTask()) {
            return;
        }

        final ActivityStack oldStack = getStack();//从TaskRecord找到ActivityStack
        final ActivityStack newStack = task != null ? task.getStack() : null;

        // Inform old stack (if present) of activity removal and new stack (if set) of activity
        // addition.
        if (oldStack != newStack) {
            if (!reparenting && oldStack != null) {
                oldStack.onActivityRemovedFromStack(this);
            }

            if (newStack != null) {
                newStack.onActivityAddedToStack(this);
            }
        }

        this.task = task;

        if (!reparenting) {
            onParentChanged();
        }
    }
```

在ActivityRecord绑定TaskRecord的时候，能够发现当ActivityRecord切换了绑定Stack或者当ActivityRecord还没有绑定TaskRecord的时候，都会调用onActivityAddedToStack，设置mResumedActivity。也是精力这个步骤，才能确定在startPausingLocked方法中确定当前正在resume的是哪个Activity，那么pause就只需要停止这个Activity。

## 检测ActivityRecord是否为复用对象，是则回调onResume，不是则准备开始跨进程
```java
next.app != null && next.app.thread != null
```
在下一段代码片段中我们首先能看到上述代码段。此时分为两种情况：
 - 1.当此时判断到下一个要启动的ActivityRecord，不存在app(ProcessRecord)对象以及app.thread（IApplicationThread象征着ActivityRecord）。而绑定这个对象是在后面的步骤，因此此时就能判断到是一个复用的Activity，直接尝试调用
```java
  transaction.setLifecycleStateRequest(
                            ResumeActivityItem.obtain(next.app.repProcState,
                                    mService.isNextTransitionForward()));
```
跨进程调用ActivityRecord对应Activity的onResume回调。

- 2.当判断到这两个对象为空，说明是新建的ActivityRecord，还没有和App端进行绑定。因此会调用
```java
mStackSupervisor.startSpecificActivityLocked(next, true, true);
```

# startSpecificActivityLocked检测ProcessRecord
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)

```java
void startSpecificActivityLocked(ActivityRecord r,
            boolean andResume, boolean checkConfig) {
        ProcessRecord app = mService.getProcessRecordLocked(r.processName,
                r.info.applicationInfo.uid, true);

        getLaunchTimeTracker().setLaunchTime(r);

        if (app != null && app.thread != null) {
            try {
                if ((r.info.flags&ActivityInfo.FLAG_MULTIPROCESS) == 0
                        || !"android".equals(r.info.packageName)) {
                    app.addPackage(r.info.packageName, r.info.applicationInfo.longVersionCode,
                            mService.mProcessStats);
                }
                realStartActivityLocked(r, app, andResume, checkConfig);
                return;
            } catch (RemoteException e) {
  
            }

        }

        mService.startProcessLocked(r.processName, r.info.applicationInfo, true, 0,
                "activity", r.intent.getComponent(), false, false, true);
    }
```

这一段的代码主要是检测Activity是否存在期待的进程。如果存在就调用realStartActivityLocked，开始跨进程。不存在则调用startProcessLocked，先通过socket联通Zygote，让Zygote孵化一个需要的进程，在重新进行startActivity。这个步骤我在很早就聊过了，这里不再赘述，我们把目光放到realStartActivityLocked跨进程启动Activity。

# realStartActivityLocked跨进程启动Activity

在这个方法中，我们只想关注，我们需要关注的。
```java
final boolean realStartActivityLocked(ActivityRecord r, ProcessRecord app,
            boolean andResume, boolean checkConfig) throws RemoteException {

        if (!allPausedActivitiesComplete()) {
    
            return false;
        }

        final TaskRecord task = r.getTask();
        final ActivityStack stack = task.getStack();

        beginDeferResume();

        try {
            r.startFreezingScreenLocked(app, 0);

            r.startLaunchTickingLocked();

            r.setProcess(app);

            if (getKeyguardController().isKeyguardLocked()) {
                r.notifyUnknownVisibilityLaunched();
            }

....

            int idx = app.activities.indexOf(r);
            if (idx < 0) {
                app.activities.add(r);
            }
            mService.updateLruProcessLocked(app, true, null);
            mService.updateOomAdjLocked();

....
            try {
                if (app.thread == null) {
                    throw new RemoteException();
                }
                List<ResultInfo> results = null;
                List<ReferrerIntent> newIntents = null;
                if (andResume) {
                    results = r.results;
                    newIntents = r.newIntents;
                }
           
                if (r.isActivityTypeHome()) {
                    // Home process is the root process of the task.
                    mService.mHomeProcess = task.mActivities.get(0).app;
                }
            ....

                // Create activity launch transaction.
                final ClientTransaction clientTransaction = ClientTransaction.obtain(app.thread,
                        r.appToken);
                clientTransaction.addCallback(LaunchActivityItem.obtain(new Intent(r.intent),
                        System.identityHashCode(r), r.info,
                        // TODO: Have this take the merged configuration instead of separate global
                        // and override configs.
                        mergedConfiguration.getGlobalConfiguration(),
                        mergedConfiguration.getOverrideConfiguration(), r.compat,
                        r.launchedFromPackage, task.voiceInteractor, app.repProcState, r.icicle,
                        r.persistentState, results, newIntents, mService.isNextTransitionForward(),
                        profilerInfo));

                // Set desired final state.
                final ActivityLifecycleItem lifecycleItem;
                if (andResume) {
                    lifecycleItem = ResumeActivityItem.obtain(mService.isNextTransitionForward());
                } else {
                    lifecycleItem = PauseActivityItem.obtain();
                }
                clientTransaction.setLifecycleStateRequest(lifecycleItem);

                // Schedule transaction.
                mService.getLifecycleManager().scheduleTransaction(clientTransaction);


....
            } catch (RemoteException e) {
                if (r.launchFailed) {
                    mService.appDiedLocked(app);
                    stack.requestFinishActivityLocked(r.appToken, Activity.RESULT_CANCELED, null,
                            "2nd-crash", false);
                    return false;
                }

                r.launchFailed = true;
                app.activities.remove(r);
                throw e;
            }
        } finally {
            endDeferResume();
        }

        r.launchFailed = false;
        if (stack.updateLRUListLocked(r)) {
        }

    ....
        return true;
    }
```

在真正的启动之前，AMS会先更新进程的在LRU中的缓存位置，接着会更新应用adj值，更新应用的优先级。做完这些行为之后才开始跨进程启动Activity。我们在这里在一次看到这几个类：ClientTransaction，LaunchActivityItem，ResumeActivityItem等等。

## ClientTransactionItem
这几个类实际上是，代表着AMS控制App远程端生命周期抽象成的状态机以及状态。在AMS跨进程控制Activity生命周期中涉及到了如下几个类：
- 1.ClientTransaction 客户端事务控制者
- 2.ClientLifecycleManager 客户端的生命周期事务控制者
- 3.TransactionExecutor 远程通信事务执行者
- 4.LaunchActivityItem 远程App端的onCreate生命周期事务
- 5.ResumeActivityItem 远程App端的onResume生命周期事务
- 6.PauseActivityItem 远程App端的onPause生命周期事务
- 7.StopActivityItem 远程App端的onStop生命周期事务
- 8.DestroyActivityItem 远程App端onDestroy生命周期事务。
- 9.ClientTransactionHandler App端对ClientTransaction的处理。


仅仅是这样列出就能很简单的看出了google工程师对Android生命周期设计上的优化。并且能看到的是，在这里面我们并不能看到七大生命周期中的onStart以及onRestart。实际上，onRestart复用了LaunchActivityItem重新启动Activity，而onStart只是在onCreate之后，App客户端本地调用。

但是这样还不足以弄清楚整个结构什么，我们看看对应的UML图。
![ClientTransaction.png](/images/ClientTransaction.png)

从这里我们清楚看到所有生命周期都是继承抽象出来的基类ClientTransactionItem。每当我们尝试着做着跨进程的操作，都会使用ClientTransactionItem这个基类。因此实际上还有ActivityResultItem,NewIntentItem等进行跨进程操作。

稍微理解了其中的类的结构，我们尝试着看看里面源码。我们抽出Activity启动的源码：
```java
   final ClientTransaction clientTransaction = ClientTransaction.obtain(app.thread,
                        r.appToken);
                clientTransaction.addCallback(LaunchActivityItem.obtain(new Intent(r.intent),
                        System.identityHashCode(r), r.info,
                        // TODO: Have this take the merged configuration instead of separate global
                        // and override configs.
                        mergedConfiguration.getGlobalConfiguration(),
                        mergedConfiguration.getOverrideConfiguration(), r.compat,
                        r.launchedFromPackage, task.voiceInteractor, app.repProcState, r.icicle,
                        r.persistentState, results, newIntents, mService.isNextTransitionForward(),
                        profilerInfo));

                final ActivityLifecycleItem lifecycleItem;
                if (andResume) {
 lifecycleItem = ResumeActivityItem.obtain(mService.isNextTransitionForward());
                } else {
                 ...
                }
                clientTransaction.setLifecycleStateRequest(lifecycleItem);

                // Schedule transaction.
                mService.getLifecycleManager().scheduleTransaction(clientTransaction);
```
在这段代码段中，AMS先创建一个LaunchActivityItem作为callback，ResumeActivityItem设置进lifeCycle的请求中。让我们跟踪一下源码scheduleTransaction。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ClientLifecycleManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ClientLifecycleManager.java)

```java
void scheduleTransaction(ClientTransaction transaction) throws RemoteException {
        final IApplicationThread client = transaction.getClient();
        transaction.schedule();
        if (!(client instanceof Binder)) {
            transaction.recycle();
        }
    }

```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[ClientTransaction.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/ClientTransaction.java)
```
    public void schedule() throws RemoteException {
        mClient.scheduleTransaction(this);
    }
```


我们看到此时将会获取IApplicationThread对象，而这个IApplicationThread是一个Binder的存根对象。实现它的ActivityThread的内部类，ApplicationThread。而从上面的UML图，能看到ClientTransaction实现了Parcel，因此能做到跨进程传送该对象。

```java
private class ApplicationThread extends IApplicationThread.Stub
```
可以清楚的知道此时ApplicationThread是一个本地Binder对象。到了AMS中这个接口就象征着远程代理对象。换句话说，此时会调用App端的scheduleTransaction方法。

实际上在Android高版本中
```java
public final class ActivityThread extends ClientTransactionHandler
```
ActivityThread将会继承ClientTransactionHandler。就会在基类中处理事件。此时首先会到ApplicationThread中的方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)
```java
 @Override
        public void scheduleTransaction(ClientTransaction transaction) throws RemoteException {
            ActivityThread.this.scheduleTransaction(transaction);
        }
```

此时我们能看到父类还是通过handler mH处理该方法：
```java
void scheduleTransaction(ClientTransaction transaction) {
        transaction.preExecute(this);
        sendMessage(ActivityThread.H.EXECUTE_TRANSACTION, transaction);
    }
```

在mH的handlerMessage中专门处理这个片段
```java
                case EXECUTE_TRANSACTION:
                    final ClientTransaction transaction = (ClientTransaction) msg.obj;
                    mTransactionExecutor.execute(transaction);
                    if (isSystem()) {
                        transaction.recycle();
                    }
                    break;
```

## TransactionExecutor
此时，App端将会把启动Activity的事务交给TransactionExecutor处理。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[TransactionExecutor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/TransactionExecutor.java)

```java
    public void execute(ClientTransaction transaction) {
        final IBinder token = transaction.getActivityToken();

        executeCallbacks(transaction);

        executeLifecycleState(transaction);
        mPendingActions.clear();
    }
```

能看到这里分为两步：
- 1.首先处理传递过来的ClientTransaction中的callback
- 2.接着处理ClientTransaction中的LifecycleStateRequest。

代入当前情景，就是先处理LaunchActivityItem接着处理ResumeActivityItem。也就对应着onCreate以及onResume。实际上这个过程中，google工程师把每一个状态又分为两个步骤去执行，一个是execute，之后会执行postExecute。

我们分别看看这两个步骤分别完成了什么：
### executeCallbacks处理LaunchActivityItem
```java
 public void executeCallbacks(ClientTransaction transaction) {
        final List<ClientTransactionItem> callbacks = transaction.getCallbacks();
        if (callbacks == null) {
            return;
        }

        final IBinder token = transaction.getActivityToken();
        ActivityClientRecord r = mTransactionHandler.getActivityClient(token);

        final ActivityLifecycleItem finalStateRequest = transaction.getLifecycleStateRequest();
        final int finalState = finalStateRequest != null ? finalStateRequest.getTargetState()
                : UNDEFINED;
        // Index of the last callback that requests some post-execution state.
        final int lastCallbackRequestingState = lastCallbackRequestingState(transaction);

        final int size = callbacks.size();
        for (int i = 0; i < size; ++i) {
            final ClientTransactionItem item = callbacks.get(i);
....
            item.execute(mTransactionHandler, token, mPendingActions);
            item.postExecute(mTransactionHandler, token, mPendingActions);
...
        }
    }
```
### LaunchActivityItem 跨进程通信到ActivityThread
可以看到是，循环处理添加进去的callback，由于此时只有一个对象LaunchActivityItem，会先后执行execute,以及postExecute。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[LaunchActivityItem.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/LaunchActivityItem.java)
 
```java
    public void execute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        ActivityClientRecord r = new ActivityClientRecord(token, mIntent, mIdent, mInfo,
                mOverrideConfig, mCompatInfo, mReferrer, mVoiceInteractor, mState, mPersistentState,
                mPendingResults, mPendingNewIntents, mIsForward,
                mProfilerInfo, client);
        client.handleLaunchActivity(r, pendingActions, null /* customIntent */);
        Trace.traceEnd(TRACE_TAG_ACTIVITY_MANAGER);
    }
```

此时的流程就和Android7.0的源码流程十分相似，client是指ActivityThread，生成一个AMS的ActivityRecord对应的ActivityClientRecord，调用handleLaunchActivity去调用onCreate方法。

到这里，就是我们十分熟悉的handleLaunchActivity方法了，实在不想说了。
```java
private Activity performLaunchActivity(ActivityClientRecord r, Intent customIntent) {
        ActivityInfo aInfo = r.activityInfo;
     ....
        ContextImpl appContext = createBaseContextForActivity(r);
        Activity activity = null;
        try {
            java.lang.ClassLoader cl = appContext.getClassLoader();
            activity = mInstrumentation.newActivity(
                    cl, component.getClassName(), r.intent);
...
        } catch (Exception e) {
  
        }

        try {
            Application app = r.packageInfo.makeApplication(false, mInstrumentation);

            if (activity != null) {
           
...
                appContext.setOuterContext(activity);
                activity.attach(appContext, this, getInstrumentation(), r.token,
                        r.ident, app, r.intent, r.activityInfo, title, r.parent,
                        r.embeddedID, r.lastNonConfigurationInstances, config,
                        r.referrer, r.voiceInteractor, window, r.configCallback);
...
                activity.mCalled = false;
                if (r.isPersistable()) {
                    mInstrumentation.callActivityOnCreate(activity, r.state, r.persistentState);
                } else {
                    mInstrumentation.callActivityOnCreate(activity, r.state);
                }
                if (!activity.mCalled) {
                    throw new SuperNotCalledException(
                        "Activity " + r.intent.getComponent().toShortString() +
                        " did not call through to super.onCreate()");
                }
                r.activity = activity;
            }
            r.setState(ON_CREATE);

            mActivities.put(r.token, r);

        } catch (SuperNotCalledException e) {
            throw e;

        } catch (Exception e) {
         ...
        }

        return activity;
    }
```

能看到这里有三个步骤：
- 1. 反射生成Activity实例
- 2.获取当前的应用的Application对象并且调用attach绑定
- 3.最后通过Instrument调用callActivityOnCreate调用到Activity实例中的onCreate方法。

回到LaunchActivityItem，LaunchActivityItem的postExecute没有实现任何的事件，让我们看看TransactionExecutor的executeLifecycleState。

## TransactionExecutor executeLifecycleState控制onResume生命周期
```java
private void executeLifecycleState(ClientTransaction transaction) {
        final ActivityLifecycleItem lifecycleItem = transaction.getLifecycleStateRequest();
        if (lifecycleItem == null) {
            return;
        }

        final IBinder token = transaction.getActivityToken();
        final ActivityClientRecord r = mTransactionHandler.getActivityClient(token);

        if (r == null) {
            return;
        }

        cycleToPath(r, lifecycleItem.getTargetState(), true /* excludeLastState */);
        lifecycleItem.execute(mTransactionHandler, token, mPendingActions);
        lifecycleItem.postExecute(mTransactionHandler, token, mPendingActions);
    }
```

此时调用getLifecycleStateRequest获取的正是之前设置进去的ResumeActivityItem。其思路和LaunchActivityItem十分相似，也是分两步执行，先执行execute，再执行postExecute。

## 调用onStart
但是请注意这个cycleToPath.
```java
 private void cycleToPath(ActivityClientRecord r, int finish,
            boolean excludeLastState) {
        final int start = r.getLifecycleState();
        final IntArray path = mHelper.getLifecyclePath(start, finish, excludeLastState);
        performLifecycleSequence(r, path);
    }
```
这个方法最后会调用下面这个方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[TransactionExecutorHelper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/TransactionExecutorHelper.java)
```java
public IntArray getLifecyclePath(int start, int finish, boolean excludeLastState) {
        if (start == UNDEFINED || finish == UNDEFINED) {
            throw new IllegalArgumentException("Can't resolve lifecycle path for undefined state");
        }
        if (start == ON_RESTART || finish == ON_RESTART) {
            throw new IllegalArgumentException(
                    "Can't start or finish in intermittent RESTART state");
        }
        if (finish == PRE_ON_CREATE && start != finish) {
            throw new IllegalArgumentException("Can only start in pre-onCreate state");
        }

        mLifecycleSequence.clear();
        if (finish >= start) {
            // just go there
            for (int i = start + 1; i <= finish; i++) {
                mLifecycleSequence.add(i);
            }
        } else { // finish < start, can't just cycle down
            if (start == ON_PAUSE && finish == ON_RESUME) {
....
            } else if (start <= ON_STOP && finish >= ON_START) {
                ....
            } else {
              ...
        }

  ...
        return mLifecycleSequence;
    }
```
此时的start是ON_CREATE，finish是ON_RESUME,因此此时会为mLifecycleSequence添加一个中间值ON_START方法。

此时performLifecycleSequence，将会执行ActivityThread中的handleStartActivity方法。
```java
public void handleStartActivity(ActivityClientRecord r,
            PendingTransactionActions pendingActions) {
        final Activity activity = r.activity;
        if (r.activity == null) {
            // TODO(lifecycler): What do we do in this case?
            return;
        }
        if (!r.stopped) {
            throw new IllegalStateException("Can't start activity that is not stopped.");
        }
        if (r.activity.mFinished) {
            // TODO(lifecycler): How can this happen?
            return;
        }

        // Start
        activity.performStart("handleStartActivity");
        r.setState(ON_START);

        if (pendingActions == null) {
            // No more work to do.
            return;
        }

        // Restore instance state
        if (pendingActions.shouldRestoreInstanceState()) {
            if (r.isPersistable()) {
                if (r.state != null || r.persistentState != null) {
                    mInstrumentation.callActivityOnRestoreInstanceState(activity, r.state,
                            r.persistentState);
                }
            } else if (r.state != null) {
                mInstrumentation.callActivityOnRestoreInstanceState(activity, r.state);
            }
        }

       ....
    }
```
此时将调用Activity的performStart方法。该方法将会调用Fragment的onStart以及通过Instrument调用onStart方法。

### ResumeActivityItem execute
```java
 @Override
    public void execute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        client.handleResumeActivity(token, true /* finalStateRequest */, mIsForward,
                "RESUME_ACTIVITY");
    }
```
此时就转移到了ActivityThread的handleResumeActivity方法中，而这个方法又调用了performResumeActivity
```java
public ActivityClientRecord performResumeActivity(IBinder token, boolean finalStateRequest,
            String reason) {
        final ActivityClientRecord r = mActivities.get(token);
    ....
        try {
            r.activity.onStateNotSaved();
            r.activity.mFragments.noteStateNotSaved();
            checkAndBlockForNetworkAccess();
            if (r.pendingIntents != null) {
                deliverNewIntents(r, r.pendingIntents);
                r.pendingIntents = null;
            }
            if (r.pendingResults != null) {
                deliverResults(r, r.pendingResults, reason);
                r.pendingResults = null;
            }
            r.activity.performResume(r.startsNotResumed, reason);

            r.state = null;
            r.persistentState = null;
            r.setState(ON_RESUME);
        } catch (Exception e) {
...
        }
        return r;
    }
```
我能看到如果pendingIntent的数据不为空则发送一个pendingIntent数据回到onActivityResult，接着调用Activity的onResume方法。


### ResumeActivityItem的postExecute
```java
@Override
    public void postExecute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        try {
            // TODO(lifecycler): Use interface callback instead of AMS.
            ActivityManager.getService().activityResumed(token);
        } catch (RemoteException ex) {
            throw ex.rethrowFromSystemServer();
        }
    }
```


此时service是指ActivityManagerService。
```java
public final void activityResumed(IBinder token) {
        final long origId = Binder.clearCallingIdentity();
        synchronized(this) {
            ActivityRecord.activityResumedLocked(token);
            mWindowManager.notifyAppResumedFinished(token);
        }
        Binder.restoreCallingIdentity(origId);
    }
```
能看到的是，此时把ActivityRecord中状态设置为resume状态，把对应的windowManager设置成resume完成状态。

这样子就完成了Activity的onResume方法。还记得我上面写的PauseActivityItem吗？此时代表着pause的生命周期，接下来我们探索一下onPause的流程。

### PauseActivityItem 处理execute
回顾一下上面的代码段：
```java
 mService.getLifecycleManager().scheduleTransaction(prev.app.thread, prev.appToken,
                        PauseActivityItem.obtain(prev.finishing, userLeaving,
                                prev.configChangeFlags, pauseImmediately));
```
当我们执行启动一个新的Activity时候，将会借助TransactionLifecycleManager其启动跨进程通信，那么原理和上面一致，我们可以直接到PauseActivityItem的execute方法中。
```java
@Override
    public void execute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        client.handlePauseActivity(token, mFinished, mUserLeaving, mConfigChanges, pendingActions,
                "PAUSE_ACTIVITY_ITEM");
    }
```
此时将会到达Activity的onPause方法。handlePauseActivity最终会达到performPauseActivity
```java
private Bundle performPauseActivity(ActivityClientRecord r, boolean finished, String reason,
            PendingTransactionActions pendingActions) {
        if (r.paused) {
            if (r.activity.mFinished) {
                return null;
            }
...
        }
        if (finished) {
            r.activity.mFinished = true;
        }

        final boolean shouldSaveState = !r.activity.mFinished && r.isPreHoneycomb();
        if (shouldSaveState) {
            callActivityOnSaveInstanceState(r);
        }

        performPauseActivityIfNeeded(r, reason);

        ArrayList<OnActivityPausedListener> listeners;
        synchronized (mOnPauseListeners) {
            listeners = mOnPauseListeners.remove(r.activity);
        }
        int size = (listeners != null ? listeners.size() : 0);
        for (int i = 0; i < size; i++) {
            listeners.get(i).onPaused(r.activity);
        }

        final Bundle oldState = pendingActions != null ? pendingActions.getOldState() : null;
        if (oldState != null) {
      
            if (r.isPreHoneycomb()) {
                r.state = oldState;
            }
        }

        return shouldSaveState ? r.state : null;
    }
```
能看到的是，如果此时需要保存当前的状态，将会在onPause中save起来。并且唤醒那些在监听onPause事件的接口。通过performPauseActivityIfNeeded会调到Activity中。并且通知Fragment中所有状态设置为onPause状态。

### PauseActivityItem 处理postExecute
```java
@Override
    public void postExecute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        if (mDontReport) {
            return;
        }
        try {
            ActivityManager.getService().activityPaused(token);
        } catch (RemoteException ex) {
            throw ex.rethrowFromSystemServer();
        }
    }
```
能看到的是此时会回调到AMS中的activityPaused，并且通知ActivityStack调用activityPausedLocked。提一句这个token是IApplicationToken.Stub用来唯一标示对应的ActivityRecord，并且通知对应的WindowManager做后续的处理。

### 调用完onPause，通知AMS调用onStop方法。
在这个activityPaused方法中，当执行完pause方法之后会执行completePauseLocked方法，执行onStop的一个步骤，之后将会调用Activity的onStop方法。
```java
private void completePauseLocked(boolean resumeNext, ActivityRecord resuming) {
        ActivityRecord prev = mPausingActivity;
        if (prev != null) {
            prev.setWillCloseOrEnterPip(false);
            final boolean wasStopping = prev.isState(STOPPING);
            prev.setState(PAUSED, "completePausedLocked");
            if (prev.finishing) {
                prev = finishCurrentActivityLocked(prev, FINISH_AFTER_VISIBLE, false,
                        "completedPausedLocked");
            } else if (prev.app != null) {
                if (mStackSupervisor.mActivitiesWaitingForVisibleActivity.remove(prev)) {

                }
                if (prev.deferRelaunchUntilPaused) {
                    prev.relaunchActivityLocked(false /* andResume */,
                            prev.preserveWindowOnDeferredRelaunch);
                } else if (wasStopping) {
                    prev.setState(STOPPING, "completePausedLocked");
                } else if (!prev.visible || shouldSleepOrShutDownActivities()) {
                    prev.setDeferHidingClient(false);
                    addToStopping(prev, true /* scheduleIdle */, false /* idleDelayed */);
                }
            } else {
                prev = null;
            }
          ...
        }
...
    }
```
我们能看到的是，此时一旦判断当前ActivityRecord已经绑定了App端的数据，说明已经启动了，并且当前的ActivityRecord的visible为false，或者点击了锁屏使其睡眠，都会调用addToStopping，把当前的ActivityRecord设置为onStop。具体表现上就是当Activity默认不是window透明的时候，这个标志就会为false。场景经常在Activity的Dialog中。

在addToStopping中，将会透过ActivityStackSupervisorHandler 这个Handler处理onStop方法。
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
...
        for (int i = 0; i < NS; i++) {
            r = stops.get(i);
            final ActivityStack stack = r.getStack();
            if (stack != null) {
                if (r.finishing) {
                    stack.finishCurrentActivityLocked(r, ActivityStack.FINISH_IMMEDIATELY, false,
                            "activityIdleInternalLocked");
                } else {
                    stack.stopActivityLocked(r);
                }
            }
        }

....

        return r;
    }
```

在ActivityStack中将会跨进程调用onStop
```java
 final void stopActivityLocked(ActivityRecord r) {
     ...
        if (r.app != null && r.app.thread != null) {
            adjustFocusedActivityStack(r, "stopActivity");
            r.resumeKeyDispatchingLocked();
            try {
                r.stopped = false;
                r.setState(STOPPING, "stopActivityLocked");
                if (!r.visible) {
                    r.setVisible(false);
                }
                mService.getLifecycleManager().scheduleTransaction(r.app.thread, r.appToken,
                        StopActivityItem.obtain(r.visible, r.configChangeFlags));
                if (shouldSleepOrShutDownActivities()) {
                    r.setSleeping(true);
                }
                Message msg = mHandler.obtainMessage(STOP_TIMEOUT_MSG, r);
                mHandler.sendMessageDelayed(msg, STOP_TIMEOUT);
            } catch (Exception e) {
            
                r.stopped = true;
                if (DEBUG_STATES) Slog.v(TAG_STATES, "Stop failed; moving to STOPPED: " + r);
                r.setState(STOPPED, "stopActivityLocked");
                if (r.deferRelaunchUntilPaused) {
                    destroyActivityLocked(r, true, "stop-except");
                }
            }
        }
    }
```
在这里面我再一次看到了核心的生命周期的类StopActivityItem。我们看看其execute以及postExecute方法。

## StopActivityItem的execute
```java
@Override
    public void execute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        client.handleStopActivity(token, mShowWindow, mConfigChanges, pendingActions,
                true /* finalStateRequest */, "STOP_ACTIVITY_ITEM");
    }
```
可以看到的是，此时将会执行ActivityThread的handleStopActivity，而它会调用如下方法:
```java
 private void performStopActivityInner(ActivityClientRecord r, StopInfo info, boolean keepShown,
            boolean saveState, boolean finalStateRequest, String reason) {
        if (r != null) {
            if (!keepShown && r.stopped) {
                if (r.activity.mFinished) {
                    return;
                }
                if (!finalStateRequest) {
...
                }
            }

            performPauseActivityIfNeeded(r, reason);

            if (info != null) {
                try {
                    info.setDescription(r.activity.onCreateDescription());
                } catch (Exception e) {
                    if (!mInstrumentation.onException(r.activity, e)) {
                        throw new RuntimeException(
                                "Unable to save state of activity "
                                + r.intent.getComponent().toShortString()
                                + ": " + e.toString(), e);
                    }
                }
            }

            if (!keepShown) {
                callActivityOnStop(r, saveState, reason);
            }
        }
    }
```
当没有进行onPause的时候，将会先惊醒onPause方法，接着再调用，callActivityOnStop调用performStop，调用所有Fragment的onStop以及设置WindowManagerGlobal的状态为暂停。最后通过Instrument调用Activity的onStop方法。


## 当调用Activity的finish
很常见的一个情况，就是当Activity调用finish的时候，将会最终会调用onDestory的生命周期，让我们稍微探索源码。

当开发者调用finish的方法最终会调用到AMS中finishActivity方法
```java
public final boolean finishActivity(IBinder token, int resultCode, Intent resultData,
            int finishTask) {
....

        synchronized(this) {
            ActivityRecord r = ActivityRecord.isInStackLocked(token);
            if (r == null) {
                return true;
            }
            TaskRecord tr = r.getTask();
            ActivityRecord rootR = tr.getRootActivity();

   ....
            final long origId = Binder.clearCallingIdentity();
            try {
                boolean res;
                final boolean finishWithRootActivity =
                        finishTask == Activity.FINISH_TASK_WITH_ROOT_ACTIVITY;
                if (finishTask == Activity.FINISH_TASK_WITH_ACTIVITY
                        || (finishWithRootActivity && r == rootR)) {
...
                } else {
                    res = tr.getStack().requestFinishActivityLocked(token, resultCode,
                            resultData, "app-request", true);
                   
                }
                return res;
            } finally {
                Binder.restoreCallingIdentity(origId);
            }
        }
    }
```
此时我们的finishtask一般不是FINISH_TASK_WITH_ACTIVITY，因此一般会走到下面的分支。此时将会拿到当前taskRecord对应的ActivityStack，开始调用requestFinishActivityLocked。

在requestFinishActivityLocked会通过token(上文介绍的IApplicationToken)找到唯一标示的ActivityRecord。接着调用finishActivityLocked
```java
 final boolean finishActivityLocked(ActivityRecord r, int resultCode, Intent resultData,
            String reason, boolean oomAdj, boolean pauseImmediately) {
        if (r.finishing) {
            return false;
        }

        mWindowManager.deferSurfaceLayout();
        try {
            r.makeFinishingLocked();
            final TaskRecord task = r.getTask();
            final ArrayList<ActivityRecord> activities = task.mActivities;
            final int index = activities.indexOf(r);
            if (index < (activities.size() - 1)) {
                task.setFrontOfTask();
                if ((r.intent.getFlags() & Intent.FLAG_ACTIVITY_CLEAR_WHEN_TASK_RESET) != 0) {
                    ActivityRecord next = activities.get(index+1);
                    next.intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_WHEN_TASK_RESET);
                }
            }
//停止事件的分发
            r.pauseKeyDispatchingLocked();
//调整焦点ActivityStack
            adjustFocusedActivityStack(r, "finishActivity");

            finishActivityResultsLocked(r, resultCode, resultData);

            final boolean endTask = index <= 0 && !task.isClearingToReuseTask();
            final int transit = endTask ? TRANSIT_TASK_CLOSE : TRANSIT_ACTIVITY_CLOSE;
            if (mResumedActivity == r) {
....
                r.setVisibility(false);

                if (mPausingActivity == null) {
                    startPausingLocked(false, false, null, pauseImmediately);
                }

                if (endTask) {
                    mService.getLockTaskController().clearLockedTask(task);
                }
            } else if (!r.isState(PAUSING)) {
  ....
                final int finishMode = (r.visible || r.nowVisible) ? FINISH_AFTER_VISIBLE
                        : FINISH_AFTER_PAUSE;
                final boolean removedActivity = finishCurrentActivityLocked(r, finishMode, oomAdj,
                        "finishActivityLocked") == null;

               ....
                return removedActivity;
            } else {
            }

            return false;
        } finally {
            mWindowManager.continueSurfaceLayout();
        }
    }
```
从finishActivityLocked方法中，实际上在finish的时候，按照2个情况处理。当

- 1.当前要finish的Activity刚好就是当前的正在交互的Activity，则调用onPause，在activityIdleInternalLocked调用onStop过程中，实际上还有这么一段代码段，
```java
for (int i = 0; i < NF; i++) {
            r = finishes.get(i);
            final ActivityStack stack = r.getStack();
            if (stack != null) {
                activityRemoved |= stack.destroyActivityLocked(r, true, "finish-idle");
            }
        }
```
从这里能看到会调用destroyActivityLocked，调用onDestroy方法。

- 2.当finish的Activity不是onPause，尝试调用finishCurrentActivityLocked，finish对应的Activity。
```java
final ActivityRecord finishCurrentActivityLocked(ActivityRecord r, int mode, boolean oomAdj,
            String reason) {

        final ActivityRecord next = mStackSupervisor.topRunningActivityLocked(
                true /* considerKeyguardState */);

        if (mode == FINISH_AFTER_VISIBLE && (r.visible || r.nowVisible)
                && next != null && !next.nowVisible) {
            if (!mStackSupervisor.mStoppingActivities.contains(r)) {
                addToStopping(r, false /* scheduleIdle */, false /* idleDelayed */);
            }
            if (DEBUG_STATES) Slog.v(TAG_STATES,
                    "Moving to STOPPING: "+ r + " (finish requested)");
            r.setState(STOPPING, "finishCurrentActivityLocked");
            if (oomAdj) {
                mService.updateOomAdjLocked();
            }
            return r;
        }

        // make sure the record is cleaned out of other places.
        mStackSupervisor.mStoppingActivities.remove(r);
        mStackSupervisor.mGoingToSleepActivities.remove(r);
        mStackSupervisor.mActivitiesWaitingForVisibleActivity.remove(r);
        final ActivityState prevState = r.getState();
        if (DEBUG_STATES) Slog.v(TAG_STATES, "Moving to FINISHING: " + r);

        r.setState(FINISHING, "finishCurrentActivityLocked");
        final boolean finishingActivityInNonFocusedStack
                = r.getStack() != mStackSupervisor.getFocusedStack()
                && prevState == PAUSED && mode == FINISH_AFTER_VISIBLE;

        if (mode == FINISH_IMMEDIATELY
                || (prevState == PAUSED
                    && (mode == FINISH_AFTER_PAUSE || inPinnedWindowingMode()))
                || finishingActivityInNonFocusedStack
                || prevState == STOPPING
                || prevState == STOPPED
                || prevState == ActivityState.INITIALIZING) {
            r.makeFinishingLocked();
            boolean activityRemoved = destroyActivityLocked(r, true, "finish-imm:" + reason);
....
            return activityRemoved ? null : r;
        }
....
        return r;
    }
```

能看到，此时将会尝试的调用addToStopping，会调到onStop方法，接着也会调用destroyActivityLocked，进行finish的核心操作。

### destroyActivityLocked

```java
final boolean destroyActivityLocked(ActivityRecord r, boolean removeFromApp, String reason) {

        if (r.isState(DESTROYING, DESTROYED)) {
            return false;
        }

        EventLog.writeEvent(EventLogTags.AM_DESTROY_ACTIVITY,
                r.userId, System.identityHashCode(r),
                r.getTask().taskId, r.shortComponentName, reason);

        boolean removedFromHistory = false;

        cleanUpActivityLocked(r, false, false);

        final boolean hadApp = r.app != null;

        if (hadApp) {
            if (removeFromApp) {
                r.app.activities.remove(r);
                if (mService.mHeavyWeightProcess == r.app && r.app.activities.size() <= 0) {
                    mService.mHeavyWeightProcess = null;
                    mService.mHandler.sendEmptyMessage(
                            ActivityManagerService.CANCEL_HEAVY_NOTIFICATION_MSG);
                }
                if (r.app.activities.isEmpty()) {
...
                    mService.updateLruProcessLocked(r.app, false, null);
                    mService.updateOomAdjLocked();
                }
            }

            boolean skipDestroy = false;

            try {
                mService.getLifecycleManager().scheduleTransaction(r.app.thread, r.appToken,
                        DestroyActivityItem.obtain(r.finishing, r.configChangeFlags));
            } catch (Exception e) {

                if (r.finishing) {
                    removeActivityFromHistoryLocked(r, reason + " exceptionInScheduleDestroy");
                    removedFromHistory = true;
                    skipDestroy = true;
                }
            }

            r.nowVisible = false;

            if (r.finishing && !skipDestroy) {
                r.setState(DESTROYING,
                        "destroyActivityLocked. finishing and not skipping destroy");
                Message msg = mHandler.obtainMessage(DESTROY_TIMEOUT_MSG, r);
                mHandler.sendMessageDelayed(msg, DESTROY_TIMEOUT);
            } else {
             
                r.setState(DESTROYED,
                        "destroyActivityLocked. not finishing or skipping destroy");

                r.app = null;
            }
        } else {
            if (r.finishing) {
                removeActivityFromHistoryLocked(r, reason + " hadNoApp");
                removedFromHistory = true;
            } else {
                r.setState(DESTROYED, "destroyActivityLocked. not finishing and had no app");

                r.app = null;
            }
        }

        r.configChangeFlags = 0;

        return removedFromHistory;
    }
```

我能够看到熟悉DestroyActivityItem这个代表着调用Activity的onResume的类。通过这个类做完跨进程通信之后，调用removeActivityFromHistoryLocked，清除TaskRecord中ActivityRecord，清除ActivityRecord中的Window对象，ProcessRecord等对象。

这里一样看看DestroyActivityItem的execute方法。

### DestroyActivityItem execute
```java
public void execute(ClientTransactionHandler client, IBinder token,
            PendingTransactionActions pendingActions) {
        client.handleDestroyActivity(token, mFinished, mConfigChanges,
                false /* getNonConfigInstance */, "DestroyActivityItem");
    }
```

此时将调用ActivityThread的handleDestroyActivity。
```java
 public void handleDestroyActivity(IBinder token, boolean finishing, int configChanges,
            boolean getNonConfigInstance, String reason) {
        ActivityClientRecord r = performDestroyActivity(token, finishing,
                configChanges, getNonConfigInstance, reason);
        if (r != null) {
            cleanUpPendingRemoveWindows(r, finishing);
            WindowManager wm = r.activity.getWindowManager();
            View v = r.activity.mDecor;
            if (v != null) {
                if (r.activity.mVisibleFromServer) {
                    mNumVisibleActivities--;
                }
                IBinder wtoken = v.getWindowToken();
                if (r.activity.mWindowAdded) {
                    if (r.mPreserveWindow) {
                        r.mPendingRemoveWindow = r.window;
                        r.mPendingRemoveWindowManager = wm;
                        r.window.clearContentView();
                    } else {
                        wm.removeViewImmediate(v);
                    }
                }
                if (wtoken != null && r.mPendingRemoveWindow == null) {
                    WindowManagerGlobal.getInstance().closeAll(wtoken,
                            r.activity.getClass().getName(), "Activity");
                } else if (r.mPendingRemoveWindow != null) {
                    WindowManagerGlobal.getInstance().closeAllExceptView(token, v,
                            r.activity.getClass().getName(), "Activity");
                }
                r.activity.mDecor = null;
            }
            if (r.mPendingRemoveWindow == null) {
                WindowManagerGlobal.getInstance().closeAll(token,
                        r.activity.getClass().getName(), "Activity");
            }

            Context c = r.activity.getBaseContext();
            if (c instanceof ContextImpl) {
                ((ContextImpl) c).scheduleFinalCleanup(
                        r.activity.getClass().getName(), "Activity");
            }
        }
        if (finishing) {
            try {
                ActivityManager.getService().activityDestroyed(token);
            } catch (RemoteException ex) {
                throw ex.rethrowFromSystemServer();
            }
        }
        mSomeActivitiesChanged = true;
    }
```
能看到当我们通过performDestroyActivity调用Activity的OnDestroy之后，将会清空Activity中设置的window数据以及设置的ContentView，最后通过activityDestroyed通知AMS。

最后通信到AMS中，发送一个Handler消息，10秒后把ActivityRecord从TaskRecord 中移除，如果此时TaskRecord已经不存在ActivityRecord，则从ActivityStack移除。

#### performDestroyActivity
```java
  ActivityClientRecord performDestroyActivity(IBinder token, boolean finishing,
            int configChanges, boolean getNonConfigInstance, String reason) {
        ActivityClientRecord r = mActivities.get(token);
        Class<? extends Activity> activityClass = null;
        if (localLOGV) Slog.v(TAG, "Performing finish of " + r);
        if (r != null) {
            activityClass = r.activity.getClass();
            r.activity.mConfigChangeFlags |= configChanges;
            if (finishing) {
                r.activity.mFinished = true;
            }

            performPauseActivityIfNeeded(r, "destroy");

            if (!r.stopped) {
                callActivityOnStop(r, false /* saveState */, "destroy");
            }
            if (getNonConfigInstance) {
                try {
                    r.lastNonConfigurationInstances
                            = r.activity.retainNonConfigurationInstances();
                } catch (Exception e) {
                    if (!mInstrumentation.onException(r.activity, e)) {
                        throw new RuntimeException(
                                "Unable to retain activity "
                                + r.intent.getComponent().toShortString()
                                + ": " + e.toString(), e);
                    }
                }
            }
            try {
                r.activity.mCalled = false;
                mInstrumentation.callActivityOnDestroy(r.activity);
                if (!r.activity.mCalled) {
                    throw new SuperNotCalledException(
                        "Activity " + safeToComponentShortString(r.intent) +
                        " did not call through to super.onDestroy()");
                }
                if (r.window != null) {
                    r.window.closeAllPanels();
                }
            } catch (SuperNotCalledException e) {
                throw e;
            } catch (Exception e) {
                if (!mInstrumentation.onException(r.activity, e)) {
                    throw new RuntimeException(
                            "Unable to destroy activity " + safeToComponentShortString(r.intent)
                            + ": " + e.toString(), e);
                }
            }
            r.setState(ON_DESTROY);
        }
        mActivities.remove(token);
        StrictMode.decrementExpectedActivityCount(activityClass);
        return r;
    }
```
能看到的是，此时当没有调用过onPause以及onStop将会调用一次，但是实际上这种情况不可能出现，都在上面的对应的PauseActivityItem以及StopActivityItem中调用过一次了。最后通Instrument调用callActivityOnDestroy，回调到Activity的performDestroy，最后关闭Activity的键盘，清空在ActivityThread的缓存。

在performDestroy调用Fragment的onDestroy，以及回调Activity的onDestroy。

这样就完成Activity的onDestroy流程。

#### onRestart
肯定有人觉得奇怪，七大声明周期之一的onRestart呢？他其实和onStart一样隐藏在TransactionExecutor 中。
来看看/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[TransactionExecutorHelper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/TransactionExecutorHelper.java)
：
```java
   public IntArray getLifecyclePath(int start, int finish, boolean excludeLastState) {
        if (start == UNDEFINED || finish == UNDEFINED) {
            throw new IllegalArgumentException("Can't resolve lifecycle path for undefined state");
        }
        if (start == ON_RESTART || finish == ON_RESTART) {
            throw new IllegalArgumentException(
                    "Can't start or finish in intermittent RESTART state");
        }
        if (finish == PRE_ON_CREATE && start != finish) {
            throw new IllegalArgumentException("Can only start in pre-onCreate state");
        }

        mLifecycleSequence.clear();
        if (finish >= start) {
            // just go there
...
        } else { // finish < start, can't just cycle down
            if (start == ON_PAUSE && finish == ON_RESUME) {
                // Special case when we can just directly go to resumed state.
                mLifecycleSequence.add(ON_RESUME);
            } else if (start <= ON_STOP && finish >= ON_START) {
                // Restart and go to required state.

                // Go to stopped state first.
                for (int i = start + 1; i <= ON_STOP; i++) {
                    mLifecycleSequence.add(i);
                }
                // Restart
                mLifecycleSequence.add(ON_RESTART);
                // Go to required state
                for (int i = ON_START; i <= finish; i++) {
                    mLifecycleSequence.add(i);
                }
            } else {
                // Relaunch and go to required state

                // Go to destroyed state first.
                for (int i = start + 1; i <= ON_DESTROY; i++) {
                    mLifecycleSequence.add(i);
                }
                // Go to required state
                for (int i = ON_CREATE; i <= finish; i++) {
                    mLifecycleSequence.add(i);
                }
            }
        }

...
        return mLifecycleSequence;
    }
```
注意这里的参数start是指当前Activity的状态，finish是指经过TransactionExecutor执行后，每一个`ActivityLifecycleItem `对应的目标Activity需要达到什么声明周期。

- 1.如果当前的Activity是`ON_PAUSE`状态，目标是`ON_RESUME`，此时只需要执行一个`ON_RESUME`

- 2.如果此时的状态是`ON_STOP`之后的状态，且目标是`ON_START`.一般来说此时都是执行的是`ResumeActivityItem` 需要从AMS让此时的Activity转化为可见。此时的`Activity`已经执行了onStop，就会把小于`ON_STOP`的状态添加进来(没有就跳过了),再把`ON_RESTART`声明周期添加进来，最后把`onStart`和`onResume`(因为`ResumeActivityItem` 目标就是`onResume`)添加进来

- 3.最后到达了TransactionExecutor中执行每一个`ActivityLifecycleItem `的生命周期，从而执行了ActivityThread的`onRestart`后执行，`onStart`,`onResume`



# 总结
本文着重说了Activity的生命周期的流程，所有的生命周期流程，就不是直接通过Binder跨进程通信，而是每一个需要通行都Activity处理的事务都抽象成了一个ClientTransactionItem处理，并且交由ClientTransaction统一分发处理。每一个ClientTransactionItem，都会把执行分为两步，execute以及postExecute。

可以说，Android对Activity的生命周期的思考从来没有停过，通过抽象以及实现Parcel灵活的实现了生命周期状态机的管理。

阅读了本文之后，就能知道我之前写的插件化，没有办法直接hook Android O的系统，因为在插件话基础模型中，有一个关键的步骤，就是hook ActivityThread的mH中的handlermessage方法。然而此时mH将不处理生命周期，因此会出现没办法偷梁换柱的情况的。但是处理的方式十分简单，就是hook handlerMessage中的处理事务的信号即可。
