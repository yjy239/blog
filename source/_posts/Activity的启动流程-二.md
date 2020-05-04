---
title: Android 重学系列 Activity的启动流程(二)
top: false
cover: false
date: 2019-06-09 20:39:52
img:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---

# 正文
如果遇到错误，请在本文指出：[https://www.jianshu.com/p/4d34de4418e0](https://www.jianshu.com/p/4d34de4418e0)

上篇，讲述的在正式启动前，做了权限判断，再准备ActivityRecord，本文将介绍在Activity启动中，Activity的栈的变化。

## startActivityUnchecked 初步处理Activity的栈
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStarter.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStarter.java)

在这个方法中，就是面试常问的启动模式，几种模式混搭在一次，在栈内的情况。

这里我分为7个步骤来详细剖析Activity栈的算法。

### 初始化计算Activity栈
```java
    private int startActivityUnchecked(final ActivityRecord r, ActivityRecord sourceRecord,
            IVoiceInteractionSession voiceSession, IVoiceInteractor voiceInteractor,
            int startFlags, boolean doResume, ActivityOptions options, TaskRecord inTask,
            ActivityRecord[] outActivity) {

        setInitialState(r, options, inTask, doResume, startFlags, sourceRecord, voiceSession,
                voiceInteractor);


        computeLaunchingTaskFlags();

        computeSourceStack();

        mIntent.setFlags(mLaunchFlags);

        ActivityRecord reusedActivity = getReusableIntentActivity();

```

### setInitialState初始化如下的数据
```java
 private void setInitialState(ActivityRecord r, ActivityOptions options, TaskRecord inTask,
            boolean doResume, int startFlags, ActivityRecord sourceRecord,
            IVoiceInteractionSession voiceSession, IVoiceInteractor voiceInteractor) {
        reset(false /* clearRequest */);

        mStartActivity = r;
        mIntent = r.intent;
        mOptions = options;
        mCallingUid = r.launchedFromUid;
        mSourceRecord = sourceRecord;
        mVoiceSession = voiceSession;
        mVoiceInteractor = voiceInteractor;
//获取一个优先的逻辑显示器，是否是vr模式(相关源码会在之后说DisplayService)
        mPreferredDisplayId = getPreferedDisplayId(mSourceRecord, mStartActivity, options);

        mLaunchParams.reset();

        mSupervisor.getLaunchParamsController().calculate(inTask, null /*layout*/, r, sourceRecord,
                options, mLaunchParams);

        mLaunchMode = r.launchMode;

        mLaunchFlags = adjustLaunchFlagsToDocumentMode(
                r, LAUNCH_SINGLE_INSTANCE == mLaunchMode,
                LAUNCH_SINGLE_TASK == mLaunchMode, mIntent.getFlags());
        mLaunchTaskBehind = r.mLaunchTaskBehind
                && !isLaunchModeOneOf(LAUNCH_SINGLE_TASK, LAUNCH_SINGLE_INSTANCE)
                && (mLaunchFlags & FLAG_ACTIVITY_NEW_DOCUMENT) != 0;

        sendNewTaskResultRequestIfNeeded();

        if ((mLaunchFlags & FLAG_ACTIVITY_NEW_DOCUMENT) != 0 && r.resultTo == null) {
            mLaunchFlags |= FLAG_ACTIVITY_NEW_TASK;
        }

        // If we are actually going to launch in to a new task, there are some cases where
        // we further want to do multiple task.
        if ((mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) != 0) {
            if (mLaunchTaskBehind
                    || r.info.documentLaunchMode == DOCUMENT_LAUNCH_ALWAYS) {
                mLaunchFlags |= FLAG_ACTIVITY_MULTIPLE_TASK;
            }
        }

        // We'll invoke onUserLeaving before onPause only if the launching
        // activity did not explicitly state that this is an automated launch.
        mSupervisor.mUserLeaving = (mLaunchFlags & FLAG_ACTIVITY_NO_USER_ACTION) == 0;
        if (DEBUG_USER_LEAVING) Slog.v(TAG_USER_LEAVING,
                "startActivity() => mUserLeaving=" + mSupervisor.mUserLeaving);

        // If the caller has asked not to resume at this point, we make note
        // of this in the record so that we can skip it when trying to find
        // the top running activity.
        mDoResume = doResume;
        if (!doResume || !r.okToShowLocked()) {
            r.delayedResume = true;
            mDoResume = false;
        }

        if (mOptions != null) {
            if (mOptions.getLaunchTaskId() != -1 && mOptions.getTaskOverlay()) {
                r.mTaskOverlay = true;
                if (!mOptions.canTaskOverlayResume()) {
                    final TaskRecord task = mSupervisor.anyTaskForIdLocked(
                            mOptions.getLaunchTaskId());
                    final ActivityRecord top = task != null ? task.getTopActivity() : null;
                    if (top != null && !top.isState(RESUMED)) {

                        // The caller specifies that we'd like to be avoided to be moved to the
                        // front, so be it!
                        mDoResume = false;
                        mAvoidMoveToFront = true;
                    }
                }
            } else if (mOptions.getAvoidMoveToFront()) {
                mDoResume = false;
                mAvoidMoveToFront = true;
            }
        }

        mNotTop = (mLaunchFlags & FLAG_ACTIVITY_PREVIOUS_IS_TOP) != 0 ? r : null;

        mInTask = inTask;
        // In some flows in to this function, we retrieve the task record and hold on to it
        // without a lock before calling back in to here...  so the task at this point may
        // not actually be in recents.  Check for that, and if it isn't in recents just
        // consider it invalid.
        if (inTask != null && !inTask.inRecents) {
            Slog.w(TAG, "Starting activity in task not in recents: " + inTask);
            mInTask = null;
        }

        mStartFlags = startFlags;
        // If the onlyIfNeeded flag is set, then we can do this if the activity being launched
        // is the same as the one making the call...  or, as a special case, if we do not know
        // the caller then we count the current top activity as the caller.
        if ((startFlags & START_FLAG_ONLY_IF_NEEDED) != 0) {
            ActivityRecord checkedCaller = sourceRecord;
            if (checkedCaller == null) {
                checkedCaller = mSupervisor.mFocusedStack.topRunningNonDelayedActivityLocked(
                        mNotTop);
            }
            if (!checkedCaller.realActivity.equals(r.realActivity)) {
                // Caller is not the same as launcher, so always needed.
                mStartFlags &= ~START_FLAG_ONLY_IF_NEEDED;
            }
        }

        mNoAnimation = (mLaunchFlags & FLAG_ACTIVITY_NO_ANIMATION) != 0;
    }
```

不难看到，在这个方法中，把整个参数赋值给ActivityStarter的全局变量，以供之后所有的流程使用。我们能看到这里能看到此时会稍微对一些Intent启动的flag进行处理。这里稍微展开一些值得注意的细节聊聊。

- 1.getPreferedDisplayId(mSourceRecord, mStartActivity, options); 该方法通过启动的ActivityRecord来判断是否是VR模式。是则直接返回一个主displayId，否则从AMS获取DisplayId。这个DisplayId简单的说就是一个索引，可以通过它从SurfaceFlinger的Binder远程对象，从而找到一个逻辑显示器。

- 2.mSupervisor.getLaunchParamsController().calculate()该方法实际上获取注册在LaunchParamsController中LaunchParamsModifier进行计算其表现在屏幕上的区域。实际上最基础有两个LaunchParamsModifier
- 1.TaskLaunchParamsModifier
- 2.ActivityLaunchParamsModifier

我们查看源码可以看到真正控制窗口大小变化(修改TaskRecord的Rect值，位置)的是TaskLaunchParamsModifier。而ActivityLaunchParamsModifier将当前的区域大小记录到LaunchParam中。我们平常可能很少这么使用，实际上在ActivityOptions的setLaunchBounds中能够控制新建的Activity的窗体大小和位置。

因此我们能够猜测文档经常所说的任务(也就是TaskRecord)是不是指Activity的窗体在AMS中的对象

- 3.adjustLaunchFlagsToDocumentMode
在Activity启动的flag中有一个FLAG_ACTIVITY_NEW_DOCUMENT。 这个flag如下：
> 给启动的Activity开一个新的任务记录，当使用new_document或者android: documentLaunchMode的时候,相同的实例会在最近任务表中产生不同的记录。
> 直接从new_document回退，直接回退桌面，想要改变这个行为，添加FLAG

可能有点抽象，看看这个gif。
![new_doucment.gif](/images/new_doucment.gif)

从这里的现象能够看到实际上new_document新建了一个新的历史记录以及一个新的栈。我们看看adjustLaunchFlagsToDocumentMode这个方法是怎么初步处理new_document的。

```java
private int adjustLaunchFlagsToDocumentMode(ActivityRecord r, boolean launchSingleInstance,
            boolean launchSingleTask, int launchFlags) {
        if ((launchFlags & Intent.FLAG_ACTIVITY_NEW_DOCUMENT) != 0 &&
                (launchSingleInstance || launchSingleTask)) {
            launchFlags &=
                    ~(Intent.FLAG_ACTIVITY_NEW_DOCUMENT | FLAG_ACTIVITY_MULTIPLE_TASK);
        } else {
            switch (r.info.documentLaunchMode) {
                case ActivityInfo.DOCUMENT_LAUNCH_NONE:
                    break;
                case ActivityInfo.DOCUMENT_LAUNCH_INTO_EXISTING:
                    launchFlags |= Intent.FLAG_ACTIVITY_NEW_DOCUMENT;
                    break;
                case ActivityInfo.DOCUMENT_LAUNCH_ALWAYS:
                    launchFlags |= Intent.FLAG_ACTIVITY_NEW_DOCUMENT;
                    break;
                case ActivityInfo.DOCUMENT_LAUNCH_NEVER:
                    launchFlags &= ~FLAG_ACTIVITY_MULTIPLE_TASK;
                    break;
            }
        }
        return launchFlags;
    }
```

这里面做了两个处理：
> 1.当存在new_document的时候，但是launchMode是singleTask或者singleInstanceTask的时候，将会关闭new_document以及MULTIPLE_TASK。因此你会发现此时使用了singleTask或者singleInstanceTask，将不会打开新的历史记录以及Activity栈。

> 2.当判断到在AndroidManifest中设置了documentLaunchMode，则为其添加flag到启动项中。
可以看到的是：
> - 如果读取到的是NONE不添加flag
> - 读取到INTO_EXISTING或者LAUNCH_ALWAYS 添加FLAG_ACTIVITY_NEW_DOCUMENT
>- 读取到NEVER，则关闭FLAG_ACTIVITY_MULTIPLE_TASK

如下面的情况：
![singleTask,Instance的doucment.gif](/images/singleTask,Instance的doucment.gif)

- 4. mLaunchTaskBehind 这个标志位判断是否新建的Activity盖在原来的Activity栈上。因此在原来的基础上判断了不是singleTask或者singleInstance，同时能打开new_document.

- 5.如果打开Acitivty的mLaunchTaskBehind标志为true且是new_document没有指向下一个Activity数据，则默认添加的FLAG_ACTIVITY_NEW_TASK。

- 6.接着如果发现FLAG_ACTIVITY_NEW_TASK打开了，设置了DOCUMENT_LAUNCH_ALWAYS或者mLaunchTaskBehind标志为true，则继续加上FLAG_ACTIVITY_MULTIPLE_TASK。

#### 小节
注意，在非singleTask和singleInstance下使用new_document，刚好经过5和6步骤，因此出现了第一幅gif图的情况，打开了一个新的栈。

这里又出现了两个新的FLAG_ACTIVITY_MULTIPLE_TASK和FLAG_ACTIVITY_NEW_TASK。

这两个标志位一般是在创建新的任务栈才会使用。

FLAG_ACTIVITY_NEW_TASK：
> 新活动会成为历史栈中的新任务（一组活动）的开始。
> 如果新活动已存在于一个为它运行的任务中，那么不会启动，只会把该任务移到屏幕最前。
> 如果需要有返回flag则不能这个flag。

因此这个flag经常用在桌面开发里面。

FLAG_ACTIVITY_MULTIPLE_TASK：
> 用于创建一个新任务，并启动一个活动放进去
一般这个标志位会和FLAG_ACTIVITY_NEW_TASK或者FLAG_ACTIVITY_NEW_DOCUMENT一起使用。

- 7. FLAG_ACTIVITY_NO_USER_ACTION判断这个标志位，从而设定mUserLeaving。FLAG_ACTIVITY_NO_USER_ACTION一般是用来阻止顶部Activity的onUserLeaveHint回调,在它被新启动的活动造成paused状态时.

- 8.如果在启动的时候设置了TaskId，则通过id找到任务，判断ActivityRecord的状态来设置mDoResume和mAvoidMoveToFront。

-9. 当Activity已经被启动了设置了START_FLAG_ONLY_IF_NEEDED，则找到当前正在使用的Activity栈。调用topRunningNonDelayedActivityLocked运行当前顶部的Activity。
```java
ActivityRecord topRunningNonDelayedActivityLocked(ActivityRecord notTop) {
        for (int taskNdx = mTaskHistory.size() - 1; taskNdx >= 0; --taskNdx) {
            final TaskRecord task = mTaskHistory.get(taskNdx);
            final ArrayList<ActivityRecord> activities = task.mActivities;
            for (int activityNdx = activities.size() - 1; activityNdx >= 0; --activityNdx) {
                ActivityRecord r = activities.get(activityNdx);
                if (!r.finishing && !r.delayedResume && r != notTop && r.okToShowLocked()) {
                    return r;
                }
            }
        }
        return null;
    }
```
这里出现了另外一个数据对象TaskRecord和TaskHistroy。这辆对象象征着Activity的任务对象以及任务历史。

### computeLaunchingTaskFlags 计算Task的flag

```java
private void computeLaunchingTaskFlags() {
        ///存在要打开TaskRecord
        if (mSourceRecord == null && mInTask != null && mInTask.getStack() != null) {
            final Intent baseIntent = mInTask.getBaseIntent();
            final ActivityRecord root = mInTask.getRootActivity();
            if (baseIntent == null) {
                ActivityOptions.abort(mOptions);
                throw new IllegalArgumentException("Launching into task without base intent: "
                        + mInTask);
            }

       ///当启动的的模式是singleTask或者singleInstance，必须保证是根部
            if (isLaunchModeOneOf(LAUNCH_SINGLE_INSTANCE, LAUNCH_SINGLE_TASK)) {
                if (!baseIntent.getComponent().equals(mStartActivity.intent.getComponent())) {
                    ActivityOptions.abort(mOptions);
                    throw new IllegalArgumentException("Trying to launch singleInstance/Task "
                            + mStartActivity + " into different task " + mInTask);
                }
                if (root != null) {
                    ActivityOptions.abort(mOptions);
                    throw new IllegalArgumentException("Caller with mInTask " + mInTask
                            + " has root " + root + " but target is singleInstance/Task");
                }
            }

         //根不为空时候设置为新建一个新的任务栈
            if (root == null) {
                final int flagsOfInterest = FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK
                        | FLAG_ACTIVITY_NEW_DOCUMENT | FLAG_ACTIVITY_RETAIN_IN_RECENTS;
                mLaunchFlags = (mLaunchFlags & ~flagsOfInterest)
                        | (baseIntent.getFlags() & flagsOfInterest);
                mIntent.setFlags(mLaunchFlags);
                mInTask.setIntent(mStartActivity);
                mAddingToTask = true;

            } else if ((mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) != 0) {
                mAddingToTask = false;

            } else {
                mAddingToTask = true;
            }
//设置复用的TaskRecord为当前栈
            mReuseTask = mInTask;
        } else {
            mInTask = null;
         //当根部不为空的时候，则不会去启动当前这个任务
            if ((mStartActivity.isResolverActivity() || mStartActivity.noDisplay) && mSourceRecord != null
                    && mSourceRecord.inFreeformWindowingMode())  {
                mAddingToTask = true;
            }
        }

        //不存在要打开的TaskRecord
        if (mInTask == null) {
            if (mSourceRecord == null) {
                // This activity is not being started from another...  in this
                // case we -always- start a new task.
                if ((mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) == 0 && mInTask == null) {
                    Slog.w(TAG, "startActivity called from non-Activity context; forcing " +
                            "Intent.FLAG_ACTIVITY_NEW_TASK for: " + mIntent);
                    mLaunchFlags |= FLAG_ACTIVITY_NEW_TASK;
                }
            } else if (mSourceRecord.launchMode == LAUNCH_SINGLE_INSTANCE) {
                // The original activity who is starting us is running as a single
                // instance...  this new activity it is starting must go on its
                // own task.
                mLaunchFlags |= FLAG_ACTIVITY_NEW_TASK;
            } else if (isLaunchModeOneOf(LAUNCH_SINGLE_INSTANCE, LAUNCH_SINGLE_TASK)) {
                // The activity being started is a single instance...  it always
                // gets launched into its own task.
                mLaunchFlags |= FLAG_ACTIVITY_NEW_TASK;
            }
        }
    }

```

在这里分为两种情况：
- 1.一种是本身知道TaskRecord，要启动的任务是哪个
当要启动的目标TaskRecord，singleTask/singleInstance的启动模式必须要知道根部。否则的话，如果根部Activity为空则启动一个新的任务栈，把当前的任务栈作为复用对象。根部不为空，则把mInTask设置空，当作新建任务。


- 2.一种是不知道将要启动TaskRecord是哪个，往往用于新建。 
此时会判断调用方的ActivityRecord为空，或者调用方本身是一个singleInstance，或者启动模式为singleTask或者singleInstance则重新启动一个新的任务作为开始。

这里有个函数稍微注意下TaskRecord.getRootActivity：
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[TaskRecord.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/TaskRecord.java)

```java
    /** Returns the first non-finishing activity from the root. */
    ActivityRecord getRootActivity() {
        for (int i = 0; i < mActivities.size(); i++) {
            final ActivityRecord r = mActivities.get(i);
            if (r.finishing) {
                continue;
            }
            return r;
        }
        return null;
    }
```
我们实际上能看到一个TaskRecord存储着一个mActivities的ActivityRecord集合。换句话说这个TaskRecord就是象征我上面说的任务。因此这个函数就是找到第一个没有被finish的Activity

### computeSourceStack 获取调用方的Activity栈
```java
    private void computeSourceStack() {
        if (mSourceRecord == null) {
            mSourceStack = null;
            return;
        }
        if (!mSourceRecord.finishing) {
            mSourceStack = mSourceRecord.getStack();
            return;
        }

        if ((mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) == 0) {
...
            mLaunchFlags |= FLAG_ACTIVITY_NEW_TASK;
            mNewTaskInfo = mSourceRecord.info;

            // It is not guaranteed that the source record will have a task associated with it. For,
            // example, if this method is being called for processing a pending activity launch, it
            // is possible that the activity has been removed from the task after the launch was
            // enqueued.
            final TaskRecord sourceTask = mSourceRecord.getTask();
            mNewTaskIntent = sourceTask != null ? sourceTask.intent : null;
        }
        mSourceRecord = null;
        mSourceStack = null;
    }
```

此时我们能够看到，是从ActivityRecord拿到ActivityStack对象。如果调用方没有被finish则返回当前的ActivityStack。被finish了则添加一个NEW_TASK启动一个新的任务。

### getReusableIntentActivity获取能够复用的Activity
看到这个名字就知道是专门处理singleTask，singleTop这些栈内唯一的启动模式
```java
/**
     * Decide whether the new activity should be inserted into an existing task. Returns null
     * if not or an ActivityRecord with the task into which the new activity should be added.
     */
    private ActivityRecord getReusableIntentActivity() {
//根据启动模式是否能够放进已经存在的Task
        boolean putIntoExistingTask = ((mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) != 0 &&
                (mLaunchFlags & FLAG_ACTIVITY_MULTIPLE_TASK) == 0)
                || isLaunchModeOneOf(LAUNCH_SINGLE_INSTANCE, LAUNCH_SINGLE_TASK);
      
        putIntoExistingTask &= mInTask == null && mStartActivity.resultTo == null;
        ActivityRecord intentActivity = null;
        if (mOptions != null && mOptions.getLaunchTaskId() != -1) {
            final TaskRecord task = mSupervisor.anyTaskForIdLocked(mOptions.getLaunchTaskId());
            intentActivity = task != null ? task.getTopActivity() : null;
        } else if (putIntoExistingTask) {
            if (LAUNCH_SINGLE_INSTANCE == mLaunchMode) {

               intentActivity = mSupervisor.findActivityLocked(mIntent, mStartActivity.info,
                       mStartActivity.isActivityTypeHome());
            } else if ((mLaunchFlags & FLAG_ACTIVITY_LAUNCH_ADJACENT) != 0) {
           
                intentActivity = mSupervisor.findActivityLocked(mIntent, mStartActivity.info,
                        !(LAUNCH_SINGLE_TASK == mLaunchMode));
            } else {

                intentActivity = mSupervisor.findTaskLocked(mStartActivity, mPreferredDisplayId);
            }
        }
        return intentActivity;
    }
```
如果上一段代码是为了找可以复用任务，而这段代码则是去寻找是否有可以复用的ActivityRecord。

这里逻辑如下：
putIntoExistingTask是一个是否能放入已经存早的任务的标志位。其判断的依据是FLAG_ACTIVITY_NEW_TASK打开了，但是要关闭FLAG_ACTIVITY_MULTIPLE_TASK；或者singleTask/singleInstance的启动模式(因为只有这两种启动模式才会去任务的栈内寻找复用的Activity)。

接着还要保证没有目标任务以及调用方本身没有要指向下一个ActivityRecord。

首先判断到有复用的任务(TaskRecord),则直接取出当前的任务的栈顶作为复用。

如果putIntoExistingTask为true分情况讨论
- 1.当启动模式为singleInstance的时候，调用findActivityLocked查找是否存在可以复用的ActivityRecord，参数为mStartActivity.isActivityTypeHome()
- 2.当打开了FLAG_ACTIVITY_LAUNCH_ADJACENT的时候，还是调用findActivityLocked，参数为是否为singleTask的boolean判断值
- 3.否则则直接findTaskLocked，传入当前的主要逻辑显示器id。

那么核心就是这个findActivityLocked和findTaskLocked方法。稍微追踪一下。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)
```java
ActivityRecord findActivityLocked(Intent intent, ActivityInfo info,
            boolean compareIntentFilters) {
        for (int displayNdx = mActivityDisplays.size() - 1; displayNdx >= 0; --displayNdx) {
            final ActivityDisplay display = mActivityDisplays.valueAt(displayNdx);
            for (int stackNdx = display.getChildCount() - 1; stackNdx >= 0; --stackNdx) {
                final ActivityStack stack = display.getChildAt(stackNdx);
                final ActivityRecord ar = stack.findActivityLocked(
                        intent, info, compareIntentFilters);
                if (ar != null) {
                    return ar;
                }
            }
        }
        return null;
    }
```
这个方法和之前的isAnyStackLock相似，也是从mActivityDisplays获取ActivityDisplay，接着不断的从ActivityStack循环寻找和当前ActivityInfo相匹配的ActivityRecord。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStack.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java)

```java
ActivityRecord findActivityLocked(Intent intent, ActivityInfo info,
                                      boolean compareIntentFilters) {
        ComponentName cls = intent.getComponent();
        if (info.targetActivity != null) {
            cls = new ComponentName(info.packageName, info.targetActivity);
        }
        final int userId = UserHandle.getUserId(info.applicationInfo.uid);

        for (int taskNdx = mTaskHistory.size() - 1; taskNdx >= 0; --taskNdx) {
            final TaskRecord task = mTaskHistory.get(taskNdx);
            final ArrayList<ActivityRecord> activities = task.mActivities;

            for (int activityNdx = activities.size() - 1; activityNdx >= 0; --activityNdx) {
                ActivityRecord r = activities.get(activityNdx);
                if (!r.okToShowLocked()) {
                    continue;
                }
                if (!r.finishing && r.userId == userId) {
                    if (compareIntentFilters) {
                        if (r.intent.filterEquals(intent)) {
                            return r;
                        }
                    } else {
                        if (r.intent.getComponent().equals(cls)) {
                            return r;
                        }
                    }
                }
            }
        }
        return null;
    }
```

我们可以发现，在ActivityStack实际存着一个TaskRecord的集合mTaskHistory。从名字我们可以猜测这是TaskRecord的历史栈，究竟有什么TaskRecord存在过ActivityStack。这样，我们再次从TaskRecord获取ActivityRecord列表，来查找是否存在一个可以用来复用的Activity。

这样我们就能理清楚一个包含关系：
ActivityDisplay- -> ActivityStack -> TaskRecord -> ActivityRecord

##### findTaskLocked
这段则是去寻找匹配的TaskRecord。
```java
ActivityRecord findTaskLocked(ActivityRecord r, int displayId) {
        mTmpFindTaskResult.r = null;
        mTmpFindTaskResult.matchedByRootAffinity = false;
        ActivityRecord affinityMatch = null;
    
        for (int displayNdx = mActivityDisplays.size() - 1; displayNdx >= 0; --displayNdx) {
            final ActivityDisplay display = mActivityDisplays.valueAt(displayNdx);
            for (int stackNdx = display.getChildCount() - 1; stackNdx >= 0; --stackNdx) {
                final ActivityStack stack = display.getChildAt(stackNdx);
                if (!r.hasCompatibleActivityType(stack)) {

                    continue;
                }
                stack.findTaskLocked(r, mTmpFindTaskResult);
            
                if (mTmpFindTaskResult.r != null) {
                    if (!mTmpFindTaskResult.matchedByRootAffinity) {
                        return mTmpFindTaskResult.r;
                    } else if (mTmpFindTaskResult.r.getDisplayId() == displayId) {
                        // Note: since the traversing through the stacks is top down, the floating
                        // tasks should always have lower priority than any affinity-matching tasks
                        // in the fullscreen stacks
                        affinityMatch = mTmpFindTaskResult.r;
                    } else if (DEBUG_TASKS && mTmpFindTaskResult.matchedByRootAffinity) {
...
                    }
                }
            }
        }


        return affinityMatch;
    }
```
根据我们上面的包含关系是从TaskRecord来查找ActivityRecord，但是这里是通过ActivityRecord反向查找匹配的TaskRecord。因此逻辑复杂点。

因为包含关系还是依旧，所以会通过ActivityDisplay来找到对应的ActivityStack

```java
void findTaskLocked(ActivityRecord target, FindTaskResult result) {
        Intent intent = target.intent;
        ActivityInfo info = target.info;
        ComponentName cls = intent.getComponent();
        if (info.targetActivity != null) {
            cls = new ComponentName(info.packageName, info.targetActivity);
        }
        final int userId = UserHandle.getUserId(info.applicationInfo.uid);
        boolean isDocument = intent != null & intent.isDocument();
        // If documentData is non-null then it must match the existing task data.
        Uri documentData = isDocument ? intent.getData() : null;

        for (int taskNdx = mTaskHistory.size() - 1; taskNdx >= 0; --taskNdx) {
            final TaskRecord task = mTaskHistory.get(taskNdx);
            if (task.voiceSession != null) {
              
                continue;
            }
            if (task.userId != userId) {
                // Looking for a different task.

                continue;
            }

            // Overlays should not be considered as the task's logical top activity.
            final ActivityRecord r = task.getTopActivity(false /* includeOverlays */);
            if (r == null || r.finishing || r.userId != userId ||
                    r.launchMode == ActivityInfo.LAUNCH_SINGLE_INSTANCE) {
                continue;
            }
            if (!r.hasCompatibleActivityType(target)) {
                continue;
            }

            final Intent taskIntent = task.intent;
            final Intent affinityIntent = task.affinityIntent;
            final boolean taskIsDocument;
            final Uri taskDocumentData;
            if (taskIntent != null && taskIntent.isDocument()) {
                taskIsDocument = true;
                taskDocumentData = taskIntent.getData();
            } else if (affinityIntent != null && affinityIntent.isDocument()) {
                taskIsDocument = true;
                taskDocumentData = affinityIntent.getData();
            } else {
                taskIsDocument = false;
                taskDocumentData = null;
            }

            if (taskIntent != null && taskIntent.getComponent() != null &&
                    taskIntent.getComponent().compareTo(cls) == 0 &&
                    Objects.equals(documentData, taskDocumentData)) {
                result.r = r;
                result.matchedByRootAffinity = false;
                break;
            } else if (affinityIntent != null && affinityIntent.getComponent() != null &&
                    affinityIntent.getComponent().compareTo(cls) == 0 &&
                    Objects.equals(documentData, taskDocumentData)) {
                result.r = r;
                result.matchedByRootAffinity = false;
                break;
            } else if (!isDocument && !taskIsDocument
                    && result.r == null && task.rootAffinity != null) {
                if (task.rootAffinity.equals(target.taskAffinity)) {
                    result.r = r;
                    result.matchedByRootAffinity = true;
                }
            } else if (DEBUG_TASKS) Slog.d(TAG_TASKS, "Not a match: " + task);
        }
    }
```

因为一个TaskRecord会包含大量的ActivityRecord，这里并不是真的去循环匹配，而是循环ActivityStack中mTaskHistory，去拿到每个Taskrecord的顶部ActivityRecord去匹配。

当我们发现顶部运行的ActivityRecord是singleInstance启动模式，则跳过这个TaskRecord。去找下一个没有结束且是相同的userId的TaskRecord。

这里稍微注意一下，因为设定了new_document和taskAffinity会Activity的任务造成影响，因此需要分情况处理。
- 1.当没设置taskAffinity，则取出TaskRecord的taskIntent，如果类名匹配，还有在intent中设置的Data数据相符则取出。
- 2.当设置taskAffinity，则取出TaskRecord的affinityIntent，如果类名匹配，还有在intent中设置的Data数据相符则取出。
- 3.当taskIntent / affinityIntent为空或者task没有打开new_document标志位，就会取出默认的taskAffinity去匹配名字，相符合则取出。


###### 情景代入
```java
 if (LAUNCH_SINGLE_INSTANCE == mLaunchMode) {

               intentActivity = mSupervisor.findActivityLocked(mIntent, mStartActivity.info,
                       mStartActivity.isActivityTypeHome());
            } else if ((mLaunchFlags & FLAG_ACTIVITY_LAUNCH_ADJACENT) != 0) {
           
                intentActivity = mSupervisor.findActivityLocked(mIntent, mStartActivity.info,
                        !(LAUNCH_SINGLE_TASK == mLaunchMode));
            } else {

                intentActivity = mSupervisor.findTaskLocked(mStartActivity, mPreferredDisplayId);
            }
```
这里的mStartActivity就是在上面init步骤的时候，把从上一篇文章初始化好的activityRecord设置进来。

换算到当前代码情景，当putIntoExistingTask为true寻找复用ActivityRecord大致上可以为如下几个步骤：
- 1.当此时是singleInstance，则需要判断是不是home。因为home也一般都是类似singleInstance模式。换句说，是home的时候将会除了查找包名一致之外，还会继续匹配intent里面的意图筛选。不是home的时候则是找到包名就返回。

- 2.当打开了FLAG_ACTIVITY_LAUNCH_ADJACENT标志位，这个标志位一般是在分屏时候使用，新活动会显示在旧活动旁边。此时我们会发现，此时因为要分屏，那个singleTask会造成影响。所以在筛选的ActivityRecord时候，如果不是singleTask则不需要经过意图筛选直接通过类名返回，否则则通过意图筛选再返回ActivityRecord。

- 3.当以上两者都不是，那么只是普通的singleTask模式或者singleInstance模式，为了减少时间复杂度，直接通过displayId去查找对应的Task的顶部正在运行的ActivityRecord。找到并且匹配taskAffinity则返回。


### 当复用的reuseActivity不为空
```java
 if (reusedActivity != null) {
...
            final boolean clearTopAndResetStandardLaunchMode =
                    (mLaunchFlags & (FLAG_ACTIVITY_CLEAR_TOP | FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
                            == (FLAG_ACTIVITY_CLEAR_TOP | FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                    && mLaunchMode == LAUNCH_MULTIPLE;

            if (mStartActivity.getTask() == null && !clearTopAndResetStandardLaunchMode) {
                mStartActivity.setTask(reusedActivity.getTask());
            }

            if (reusedActivity.getTask().intent == null) {
                reusedActivity.getTask().setIntent(mStartActivity);
            }

            if ((mLaunchFlags & FLAG_ACTIVITY_CLEAR_TOP) != 0
                    || isDocumentLaunchesIntoExisting(mLaunchFlags)
                    || isLaunchModeOneOf(LAUNCH_SINGLE_INSTANCE, LAUNCH_SINGLE_TASK)) {
                final TaskRecord task = reusedActivity.getTask();
                final ActivityRecord top = task.performClearTaskForReuseLocked(mStartActivity,
                        mLaunchFlags);

                if (reusedActivity.getTask() == null) {
                    reusedActivity.setTask(task);
                }

                if (top != null) {
                    if (top.frontOfTask) {
                        top.getTask().setIntent(mStartActivity);
                    }
                    deliverNewIntent(top);
                }
            }

            mSupervisor.sendPowerHintForLaunchStartIfNeeded(false /* forceSend */, reusedActivity);

            reusedActivity = setTargetStackAndMoveToFrontIfNeeded(reusedActivity);

            final ActivityRecord outResult =
                    outActivity != null && outActivity.length > 0 ? outActivity[0] : null;
            if (outResult != null && (outResult.finishing || outResult.noDisplay)) {
                outActivity[0] = reusedActivity;
            }

            if ((mStartFlags & START_FLAG_ONLY_IF_NEEDED) != 0) {
                resumeTargetStackIfNeeded();
                return START_RETURN_INTENT_TO_CALLER;
            }

            if (reusedActivity != null) {
                setTaskFromIntentActivity(reusedActivity);

                if (!mAddingToTask && mReuseTask == null) {
                    resumeTargetStackIfNeeded();
                    if (outActivity != null && outActivity.length > 0) {
                        outActivity[0] = reusedActivity;
                    }

                    return mMovedToFront ? START_TASK_TO_FRONT : START_DELIVERED_TO_TOP;
                }
            }
        }

        if (mStartActivity.packageName == null) {
....
            return START_CLASS_NOT_FOUND;
        }
```

这里拆分3个步骤说明：
- 1.如果当前的启动模式是standard(对应LAUNCH_MULTIPLE)，并且打开了FLAG_ACTIVITY_CLEAR_TOP和FLAG_ACTIVITY_RESET_TASK_IF_NEEDED，则说明要清空当前栈当前ActivityRecord一直到栈顶的数据，但是此时暂时不处理，仅仅设置了clearTopAndResetStandardLaunchMode一个boolean值。当这个boolean是false的时候，说明不用清掉Task上面的信息，因此，能够直接设置原来的TaskRecord进去

- 2.当打开了FLAG_ACTIVITY_CLEAR_TOP标志位，或者打开了document标志位，或者打开了singleTask / singleInstance说明此时需要清掉TaskRecord的数据。最后调用deliverNewIntent。其中核心函数是performClearTaskForReuseLocked方法。这个方法就是清掉我们常说的singleTask顶部Activity，并且让当前Activity置顶。

文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[TaskRecord.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/TaskRecord.java)
```java
    ActivityRecord performClearTaskForReuseLocked(ActivityRecord newR, int launchFlags) {
        mReuseTask = true;
        final ActivityRecord result = performClearTaskLocked(newR, launchFlags);
        mReuseTask = false;
        return result;
    }

  final ActivityRecord performClearTaskLocked(ActivityRecord newR, int launchFlags) {
        int numActivities = mActivities.size();
        for (int activityNdx = numActivities - 1; activityNdx >= 0; --activityNdx) {
            ActivityRecord r = mActivities.get(activityNdx);
            if (r.finishing) {
                continue;
            }
            if (r.realActivity.equals(newR.realActivity)) {
                // Here it is!  Now finish everything in front...
                final ActivityRecord ret = r;

                for (++activityNdx; activityNdx < numActivities; ++activityNdx) {
                    r = mActivities.get(activityNdx);
                    if (r.finishing) {
                        continue;
                    }
                    ActivityOptions opts = r.takeOptionsLocked();
                    if (opts != null) {
                        ret.updateOptionsLocked(opts);
                    }
                    if (mStack != null && mStack.finishActivityLocked(
                            r, Activity.RESULT_CANCELED, null, "clear-task-stack", false)) {
                        --activityNdx;
                        --numActivities;
                    }
                }


                if (ret.launchMode == ActivityInfo.LAUNCH_MULTIPLE
                        && (launchFlags & Intent.FLAG_ACTIVITY_SINGLE_TOP) == 0
                        && !ActivityStarter.isDocumentLaunchesIntoExisting(launchFlags)) {
                    if (!ret.finishing) {
                        if (mStack != null) {
                            mStack.finishActivityLocked(
                                    ret, Activity.RESULT_CANCELED, null, "clear-task-top", false);
                        }
                        return null;
                    }
                }

                return ret;
            }
        }

        return null;
    }
```
实际上，这个mActivities这个ArrayList。存放着当前任务内所有的Activity。此时当作一个栈的话，就是从尾部开始往头部循环查找。那么这个算法分为两步：

> - 从mActivities尾部往头部查找到被复用的Activity
> - 找到被复用的Activity在往尾部依次循环，并且调用ActivityStack的finish的方法结束这个Activity，并且减少引用。

但是这里有个特殊处理，如果是standard启动的话，并且FLAG_ACTIVITY_SINGLE_TOP打开了。此时也会结束当前的Activity。那么此时调用不了deliverNewIntent，也就说这种方式实现类似singleTop的效果是不会会调onNewIntent。而是会当作重新启动。


- 3.经过上面的步骤，不管是否已经清除栈顶的数据。接下来都会，确定已经是要加入到对应的筛选出来栈中。

因此需要开始加入到栈中，但是根据我上面列出来的在AMS中的包含关系，我们先要找到ActivityDisplay之后，再找到其中TaskRecord，最后再把ActivityRecord加入其中。

必定是这个逻辑，那么在这个情况复用的ActivityRecord找到了，为了保证其正确性，就要对TaskRecord做重新处理，把当前的TaskRecord放到最顶部，究竟哪里算是顶部，接下来看看核心方法之一setTargetStackAndMoveToFrontIfNeeded。


##### setTargetStackAndMoveToFrontIfNeeded
```java
private ActivityRecord setTargetStackAndMoveToFrontIfNeeded(ActivityRecord intentActivity) {
        mTargetStack = intentActivity.getStack();
        mTargetStack.mLastPausedActivity = null;
//获取顶部信息
        final ActivityStack focusStack = mSupervisor.getFocusedStack();
        ActivityRecord curTop = (focusStack == null)
                ? null : focusStack.topRunningNonDelayedActivityLocked(mNotTop);

        final TaskRecord topTask = curTop != null ? curTop.getTask() : null;
//顶部复用栈的信息合法
        if (topTask != null
                && (topTask != intentActivity.getTask() || topTask != focusStack.topTask())
                && !mAvoidMoveToFront) {
            mStartActivity.intent.addFlags(Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT);
            if (mSourceRecord == null || (mSourceStack.getTopActivity() != null &&
                    mSourceStack.getTopActivity().getTask() == mSourceRecord.getTask())) {
                
                if (mLaunchTaskBehind && mSourceRecord != null) {
                    intentActivity.setTaskToAffiliateWith(mSourceRecord.getTask());
                }

               
                final boolean willClearTask =
                        (mLaunchFlags & (FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK))
                            == (FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK);
                if (!willClearTask) {
                    final ActivityStack launchStack = getLaunchStack(
                            mStartActivity, mLaunchFlags, mStartActivity.getTask(), mOptions);
                    final TaskRecord intentTask = intentActivity.getTask();
                    if (launchStack == null || launchStack == mTargetStack) {
                      
                        mTargetStack.moveTaskToFrontLocked(intentTask, mNoAnimation, mOptions,
                                mStartActivity.appTimeTracker, "bringingFoundTaskToFront");
                        mMovedToFront = true;
                    } else if (launchStack.inSplitScreenWindowingMode()) {
                        if ((mLaunchFlags & FLAG_ACTIVITY_LAUNCH_ADJACENT) != 0) {

                            intentTask.reparent(launchStack, ON_TOP,
                                    REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                    "launchToSide");
                        } else {
                            
                            mTargetStack.moveTaskToFrontLocked(intentTask,
                                    mNoAnimation, mOptions, mStartActivity.appTimeTracker,
                                    "bringToFrontInsteadOfAdjacentLaunch");
                        }
                        mMovedToFront = launchStack != launchStack.getDisplay()
                                .getTopStackInWindowingMode(launchStack.getWindowingMode());
                    } else if (launchStack.mDisplayId != mTargetStack.mDisplayId) {

                        intentActivity.getTask().reparent(launchStack, ON_TOP,
                                REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                "reparentToDisplay");
                        mMovedToFront = true;
                    } else if (launchStack.isActivityTypeHome()
                            && !mTargetStack.isActivityTypeHome()) {

                        intentActivity.getTask().reparent(launchStack, ON_TOP,
                                REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                "reparentingHome");
                        mMovedToFront = true;
                    }
                    mOptions = null;

                    intentActivity.showStartingWindow(null /* prev */, false /* newTask */,
                            true /* taskSwitch */);
                }
            }
        }

        mTargetStack = intentActivity.getStack();
        if (!mMovedToFront && mDoResume) {
       
            mTargetStack.moveToFront("intentActivityFound");
        }

        mSupervisor.handleNonResizableTaskIfNeeded(intentActivity.getTask(),
                WINDOWING_MODE_UNDEFINED, DEFAULT_DISPLAY, mTargetStack);


        if ((mLaunchFlags & FLAG_ACTIVITY_RESET_TASK_IF_NEEDED) != 0) {
            return mTargetStack.resetTaskIfNeededLocked(intentActivity, mStartActivity);
        }
        return intentActivity;
    }
```

- 1.首先找到当前AMS的焦点ActivityStack，也就是正在和用户交互的ActivityStack找到mTaskHistory的顶部正在运行的ActivityRecord。同时找到对应的TaskRecord。

- 2.当发现顶部的TaskRecord不为空，同时顶部的Task和要服用的Task不是同一个时候，并且此时mAvoidMoveToFront为false的时候(mAvoidMoveToFront是在init的步骤初始化好的，这个参数是由ActivityOptions设置的，一般是false)。当判断从此时的intent的启动flag，没有打开FLAG_ACTIVITY_NEW_TASK以及FLAG_ACTIVITY_CLEAR_TASK，说明不用清空顶部的栈内所有的信息信息，会分为几种情况，把当前的Task移动栈顶。将会在下面的场景回归继续分析。


- 3.不管有没有清空，最后都需要把当前的栈ActivityStack移动到最前方，注意这里的最前端是指和人交互最直接，最顶层的位置。

- 4.接下来判断FLAG_ACTIVITY_RESET_TASK_IF_NEEDED标志位，这个标志一个的时候，没办法做到什么，一般几个标志位一起联动，来判断当前是否需要重置当前的mHistoryTask或者新建一个栈。

大致分为这四步骤，接下来让我们看看整个流程是值得注意的步骤怎么处理的。
#### 剖析setTargetStackAndMoveToFrontIfNeeded
先看看第二步骤中值得注意的方法getLaunchStack，获取当前即将要启动的栈。
```java

    private ActivityStack getLaunchStack(ActivityRecord r, int launchFlags, TaskRecord task,
            ActivityOptions aOptions) {
        if (mReuseTask != null) {
            return mReuseTask.getStack();
        }

        if (((launchFlags & FLAG_ACTIVITY_LAUNCH_ADJACENT) == 0)
                 || mPreferredDisplayId != DEFAULT_DISPLAY) {
            // We don't pass in the default display id into the get launch stack call so it can do a
            // full resolution.
            final int candidateDisplay =
                    mPreferredDisplayId != DEFAULT_DISPLAY ? mPreferredDisplayId : INVALID_DISPLAY;
            return mSupervisor.getLaunchStack(r, aOptions, task, ON_TOP, candidateDisplay);
        }

        final ActivityStack parentStack = task != null ? task.getStack(): mSupervisor.mFocusedStack;

        if (parentStack != mSupervisor.mFocusedStack) {
            // If task's parent stack is not focused - use it during adjacent launch.
            return parentStack;
        } else {
            if (mSupervisor.mFocusedStack != null && task == mSupervisor.mFocusedStack.topTask()) {
                return mSupervisor.mFocusedStack;
            }

            if (parentStack != null && parentStack.inSplitScreenPrimaryWindowingMode()) {

                final int activityType = mSupervisor.resolveActivityType(r, mOptions, task);
                return parentStack.getDisplay().getOrCreateStack(
                        WINDOWING_MODE_SPLIT_SCREEN_SECONDARY, activityType, ON_TOP);
            } else {

                final ActivityStack dockedStack =
                        mSupervisor.getDefaultDisplay().getSplitScreenPrimaryStack();
                if (dockedStack != null && !dockedStack.shouldBeVisible(r)) {

                    return mSupervisor.getLaunchStack(r, aOptions, task, ON_TOP);
                } else {
                    return dockedStack;
                }
            }
        }
    }
```

如果当前要复用的Task不为空的时候，直接复用。但是实际上Activity存在分屏操作等特殊情况，因此可能需要特殊处理。

所以分为以下3个步骤：
- 1.先判断当前有没有打开FLAG_ACTIVITY_LAUNCH_ADJACENT标志位，并且当前的显示器id和当前的主屏id不一致。此时将会判断mPreferredDisplayId是否是默认的主屏幕id，不是则取当前屏幕id，不然则是无效id。接着调用mSupervisor.getLaunchStack进一步的确认真正的ActivityStack。

- 2.不然实际上是打开了FLAG_ACTIVITY_LAUNCH_ADJACENT标志位，如果加上NEW_TASK就可能会启动到分屏。

则获取当前即将启动的ActivityRecord对应的task，如果为空则获取把当前的Task设置为当前焦点TaskRecord。当前的焦点ActivityStack和当前父亲ActivityStack（为当前taskrecord或者当前焦点的taskrecord，取决于当前的taskrecord是否为空）是不是同一个说明可以直接到分屏，就直接返回ActivityStack。

如果是同一个当前的TaskRecord和焦点ActivityStack的顶部历史Task是同一个，说明不用直接到分屏，而是直接返回ActivityStack。

如果当前的TaskRecord和当前焦点的ActivityStack的mHistoryTask的顶部不是同一个，且当前父亲ActivityStack不为空，且打开了inSplitScreenPrimaryWindowingMode(分屏模式)则说明此时想当前的task想要显示到顶部，却没办法，此时需要从ActivityStack中根据情况获取或者新建ActivityStack。

如果为空，则获取桌面的ActivityStack。

因此这一段的意思实际上就是根据分屏情况以及FLAG_ACTIVITY_LAUNCH_ADJACENT获取合理的ActivityStack。

其中值得注意的有mSupervisor.getLaunchStack这个函数，从ActivityStackSupervisor中进一步获取ActivityStack。

#### ActivityStackSupervisor 创建与获取ActivityStack
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStackSupervisor.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java)

```java
<T extends ActivityStack> T getLaunchStack(@Nullable ActivityRecord r,
            @Nullable ActivityOptions options, @Nullable TaskRecord candidateTask, boolean onTop,
            int candidateDisplayId) {
        int taskId = INVALID_TASK_ID;
        int displayId = INVALID_DISPLAY;
       
        if (options != null) {
            taskId = options.getLaunchTaskId();
            displayId = options.getLaunchDisplayId();

        }


        if (taskId != INVALID_TASK_ID) {
            options.setLaunchTaskId(INVALID_TASK_ID);
            final TaskRecord task = anyTaskForIdLocked(taskId,
                    MATCH_TASK_IN_STACKS_OR_RECENT_TASKS_AND_RESTORE, options, onTop);
            options.setLaunchTaskId(taskId);
            if (task != null) {
                return task.getStack();
            }
        }

        final int activityType = resolveActivityType(r, options, candidateTask);
        T stack = null;

        if (displayId == INVALID_DISPLAY) {
            displayId = candidateDisplayId;
        }
        if (displayId != INVALID_DISPLAY && canLaunchOnDisplay(r, displayId)) {
            if (r != null) {
                stack = (T) getValidLaunchStackOnDisplay(displayId, r);
                if (stack != null) {
                    return stack;
                }
            }
            final ActivityDisplay display = getActivityDisplayOrCreateLocked(displayId);
            if (display != null) {
                stack = display.getOrCreateStack(r, options, candidateTask, activityType, onTop);
                if (stack != null) {
                    return stack;
                }
            }
        }


        stack = null;
        ActivityDisplay display = null;
        if (candidateTask != null) {
            stack = candidateTask.getStack();
        }
        if (stack == null && r != null) {
            stack = r.getStack();
        }
        if (stack != null) {
            display = stack.getDisplay();
            if (display != null && canLaunchOnDisplay(r, display.mDisplayId)) {
                final int windowingMode =
                        display.resolveWindowingMode(r, options, candidateTask, activityType);
                if (stack.isCompatible(windowingMode, activityType)) {
                    return stack;
                }
                if (windowingMode == WINDOWING_MODE_FULLSCREEN_OR_SPLIT_SCREEN_SECONDARY
                        && display.getSplitScreenPrimaryStack() == stack
                        && candidateTask == stack.topTask()) {

                    return stack;
                }
            }
        }

        if (display == null
                || !canLaunchOnDisplay(r, display.mDisplayId)
                // TODO: Can be removed once we figure-out how non-standard types should launch
                // outside the default display.
                || (activityType != ACTIVITY_TYPE_STANDARD
                && activityType != ACTIVITY_TYPE_UNDEFINED)) {
            display = getDefaultDisplay();
        }

        return display.getOrCreateStack(r, options, candidateTask, activityType, onTop);
    }
```

这里又可以分为以下几个步骤：

- 1.如果ActivityOption中配置了taskId，则通过taskId从ActivityStack的mHistory中获取对应的TaskRecord,并且返回TaskRecord对应的ActivityStack。

- 2.如果没有taskId，则只能从当前的displayId去查找id。如果是ActivityOptions中是无效的displayId则从获取从方法中传下来的displayId获取。

此时在验证一次displayId，如果有效，且当前的ActivityRecord是可以被启动在显示器上，则通过getValidLaunchStackOnDisplay方法从ActivityDisplay只能够获取与当前模式兼容的ActivityStack，不为空则返回。

如果当前的ActivityRecord为空，说明此时情况特殊，没有任何合适的ActivityStack则调用getActivityDisplayOrCreateLocked或者创建获取对应的ActivityDisplay，最后通过getOrCreateStack创建获取ActivityStack。

- 3.当传下来的taskId和displayId都是非法的时候，就没有办法从这两个线索去搜索合适的ActivityStack。说明此时可能是分屏情况，一个有Activity，一个完全没启动。

AMS接下来会按照方式，先从当前的TaskRecord中获取到对应的栈，如果Activity的启动和Window当前的模式兼容则直接返回。如果不兼容，说明此时可能处于分屏，判断到当前的分屏的Task是当前task，且是历史栈中的顶部，则获取分屏的信息。

- 4.最后，这样还没办法处理，说明此时处于一切的初始状态，调用getOrCreateStack创建ActivityStack。

那么，我们追溯到了ActivityStack这个重要的数据结构的创建了。先来看看怎么通过getActivityDisplayOrCreateLocked创建获取ActivityStack。

##### getActivityDisplayOrCreateLocked 获取或者创建ActivityDisplay
```java
  ActivityDisplay getActivityDisplayOrCreateLocked(int displayId) {
        ActivityDisplay activityDisplay = mActivityDisplays.get(displayId);
        if (activityDisplay != null) {
            return activityDisplay;
        }
        if (mDisplayManager == null) {

            return null;
        }
        final Display display = mDisplayManager.getDisplay(displayId);
        if (display == null) {
            return null;
        }

        activityDisplay = new ActivityDisplay(this, display);
        attachDisplay(activityDisplay);
        calculateDefaultMinimalSizeOfResizeableTasks(activityDisplay);
        mWindowManager.onDisplayAdded(displayId);
        return activityDisplay;
    }
```

从这里我们就能看到在创建或者获取ActivityStack中涉及一个核心的服务DisplayManager。该服务是用来管理显示，具体点就是管理各种显示器的。这一块就会放到WMS中的解析。现在只需要明白，根据id获取逻辑显示器。

首先从mActivityDisplays缓存查找对应的id的ActivityDisplay，找不到则通过DisplayManagerService去找对应id的逻辑显示器。还找不到，说明根本没有在DisplayManagerService中注册这种显示器，直接返回空。找到逻辑显示器，说明此AMS刚开始启动或者这种显示器第一次使用，因此需要新建一个ActivityDisplay。

因此创建ActivityDisplay分为四步骤:
- 1.新建一个对象
- 2.通过attachDisplay把新建ActivityDisplay添加到mActivityDisplays
- 3.通过default_minimal_size_resizable_task设置全局mDefaultMinSizeOfResizeableTask大小，这个大小象征着Activity如果没有指定大小，就指定这个默认大小。
- 4.把当前的displayId绑定到WindowManagerService中。

别忘了，此时我们目的是要获取ActivityDisplay中的ActivityStack。因此我们接下来看看getOrCreateStack，又是如何创建处理ActivityStack的。

##### getOrCreateStack 从ActivityDisplay获取ActivityStack
```java
    <T extends ActivityStack> T getOrCreateStack(int windowingMode, int activityType,
            boolean onTop) {
        if (!alwaysCreateStack(windowingMode, activityType)) {
            T stack = getStack(windowingMode, activityType);
            if (stack != null) {
                return stack;
            }
        }
        return createStack(windowingMode, activityType, onTop);
    }
```

能看到的是这里有个alwaysCreateStack，判断当前是否总是需要创建ActivityStack。当判断为否则尝试着从缓存中获取合适的。如果找不到则创建一个ActivityStack。

```java
private boolean alwaysCreateStack(int windowingMode, int activityType) {
        return activityType == ACTIVITY_TYPE_STANDARD
                && (windowingMode == WINDOWING_MODE_FULLSCREEN
                || windowingMode == WINDOWING_MODE_FREEFORM
                || windowingMode == WINDOWING_MODE_SPLIT_SCREEN_SECONDARY);
    }
```
当Activity的启动方式是standard启动模式，并且window的模式是全屏，或者分屏第二个屏幕，或者是自由窗口模式(在7.0之后，Android系统支持类似PC操作系统的窗口模式)，则判断需要总要创建新的ActivityStack。
##### ActivityDisplay获取ActivityStack getStack
```java
<T extends ActivityStack> T getStack(int windowingMode, int activityType) {
        if (activityType == ACTIVITY_TYPE_HOME) {
            return (T) mHomeStack;
        } else if (activityType == ACTIVITY_TYPE_RECENTS) {
            return (T) mRecentsStack;
        }
        if (windowingMode == WINDOWING_MODE_PINNED) {
            return (T) mPinnedStack;
        } else if (windowingMode == WINDOWING_MODE_SPLIT_SCREEN_PRIMARY) {
            return (T) mSplitScreenPrimaryStack;
        }

        for (int i = mStacks.size() - 1; i >= 0; --i) {
            final ActivityStack stack = mStacks.get(i);
            if (stack.isCompatible(windowingMode, activityType)) {
                return (T) stack;
            }
        }
        return null;
    }
```

我们能够看到，ActivityStack在9.0中比起7.0复杂了很多。这里面根据windowMode以及activityType，ActivityDisplay把ActivityStack区分为如下几种ActivityStack：
- 1.mHomeStack 象征着桌面的Activity栈
- 2.mRecentsStack 象征着应用中最近使用的ActivityStack
- 3.mPinnedStack
- 4.mSplitScreenPrimaryStack 分屏后主屏幕的ActivityStack
- 5.没有指定，直接循环获取，和当前的windowMode以及activityType相符的stack返回(当activityType不是普通的模式或者未声明的时候，只需要匹配activityType，否则则匹配windowMode)。

##### ActivityDisplay创建ActivityStack

```java
<T extends ActivityStack> T createStack(int windowingMode, int activityType, boolean onTop) {

        ....

        final int stackId = getNextStackId();
        return createStackUnchecked(windowingMode, activityType, stackId, onTop);
    }
```
可以看到，ActivityStack的id设置是依次增加的。

```java
@VisibleForTesting
    <T extends ActivityStack> T createStackUnchecked(int windowingMode, int activityType,
            int stackId, boolean onTop) {
        if (windowingMode == WINDOWING_MODE_PINNED) {
            return (T) new PinnedActivityStack(this, stackId, mSupervisor, onTop);
        }
        return (T) new ActivityStack(
                        this, stackId, mSupervisor, windowingMode, activityType, onTop);
    }
```

可以看到实际上ActivityStack分为两种类型一种是普通的ActivityStack，一种是PinnedActivityStack。而PinnedActivityStack是一种固定显示的栈，其默认的activityType是standard，windowMode是WINDOWING_MODE_PINNED。

#### setTargetStackAndMoveToFrontIfNeeded 场景回归
回到当前的场景，获得了即将要登陆的ActivityStack之后，setTargetStackAndMoveToFrontIfNeeded，会做第二步极其重要的事情，就是移动当前的ActivityStack到最顶部，也就是人机交互的栈顶。我们重新看看源码，
```java
  if (!willClearTask) {
                    final ActivityStack launchStack = getLaunchStack(
                            mStartActivity, mLaunchFlags, mStartActivity.getTask(), mOptions);
                    final TaskRecord intentTask = intentActivity.getTask();
                    if (launchStack == null || launchStack == mTargetStack) {
                      
                        mTargetStack.moveTaskToFrontLocked(intentTask, mNoAnimation, mOptions,
                                mStartActivity.appTimeTracker, "bringingFoundTaskToFront");
                        mMovedToFront = true;
                    } else if (launchStack.inSplitScreenWindowingMode()) {
                        if ((mLaunchFlags & FLAG_ACTIVITY_LAUNCH_ADJACENT) != 0) {

                            intentTask.reparent(launchStack, ON_TOP,
                                    REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                    "launchToSide");
                        } else {
                            
                            mTargetStack.moveTaskToFrontLocked(intentTask,
                                    mNoAnimation, mOptions, mStartActivity.appTimeTracker,
                                    "bringToFrontInsteadOfAdjacentLaunch");
                        }
                        mMovedToFront = launchStack != launchStack.getDisplay()
                                .getTopStackInWindowingMode(launchStack.getWindowingMode());
                    } else if (launchStack.mDisplayId != mTargetStack.mDisplayId) {

                        intentActivity.getTask().reparent(launchStack, ON_TOP,
                                REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                "reparentToDisplay");
                        mMovedToFront = true;
                    } else if (launchStack.isActivityTypeHome()
                            && !mTargetStack.isActivityTypeHome()) {

                        intentActivity.getTask().reparent(launchStack, ON_TOP,
                                REPARENT_MOVE_STACK_TO_FRONT, ANIMATE, DEFER_RESUME,
                                "reparentingHome");
                        mMovedToFront = true;
                    }
                    mOptions = null;

                    intentActivity.showStartingWindow(null /* prev */, false /* newTask */,
                            true /* taskSwitch */);
                }
            }
        }
```
当确定不需要清空Activity栈内的信息时候，将会获取登陆ActivityStack。这个ActivityStack的获取是如果显式的设置了复用目标，则使用，不然则是获取在init中初始好的启动的调用方ActivityStack，当然如果遇到分屏，虚拟屏等特殊情况另说。

此时将会依据即将登陆的ActivityStack和当前ActivityRecord对应的ActivityStack做比较。可以分为以下几种情况：
- 1.当要启动的栈与目标一致，或者要启动的栈为空。
- 2.要启动的栈的windowMode为分屏模式
- 3.要启动的栈displayId和当前的ActivityRecord不一致
- 4.要启动的栈是Home，而当前的ActivityRecord不是。

在情况2-3都会通过reparent，把Task迁移到launchStack中。

稍微看看情况一
#### 情况一当要启动的栈与目标一致，或者要启动的栈为空
此时正是我们正常的启动流程。也就是说会唤起moveTaskToFrontLocked方法。把当前的栈移动到用户交互的栈顶。
```java
final void moveTaskToFrontLocked(TaskRecord tr, boolean noAnimation, ActivityOptions options,
            AppTimeTracker timeTracker, String reason) {
...

        final ActivityStack topStack = getDisplay().getTopStack();
        final ActivityRecord topActivity = topStack != null ? topStack.getTopActivity() : null;
        final int numTasks = mTaskHistory.size();
        final int index = mTaskHistory.indexOf(tr);
...

        try {
            getDisplay().deferUpdateImeTarget();

            insertTaskAtTop(tr, null);
            final ActivityRecord top = tr.getTopActivity();
            if (top == null || !top.okToShowLocked()) {
                if (top != null) {
                    mStackSupervisor.mRecentTasks.add(top.getTask());
                }
                ActivityOptions.abort(options);
                return;
            }

    
            final ActivityRecord r = topRunningActivityLocked();
            mStackSupervisor.moveFocusableActivityStackToFrontLocked(r, reason);
 ....
            mStackSupervisor.resumeFocusedStackTopActivityLocked();
...
        } finally {
...
        }
    }

```

我们可以看到这个核心的算法实际上很简单，实际上就是首先先从mHistoryTasks找到对应的TaskRecord。如果找不到则立即返回，找到了则调用insertTaskAtTop，把这个TaskRecord插入到mHistoryTask顶部，如果此时的顶部ActivityRecord暂时不能显示，把TaskRecord添加到ActivityStackSupervisor的mRecentTasks，最近使用的Activity的任务列表中，这样就相当于调用过。

接着调用moveFocusableActivityStackToFrontLocked，处理ActivityStack这个方法最后会调用ActivityStack的moveToFront。

> moveToFront方法做的事情有两件，第一件把ActivityStackSupervisor的FocusStack设置为当前的ActivityStack，第二件事，把当前这个ActivityStack设置ActivityDisplay中的mStacks (存放着ActivityStack的ArrayList)的前端。

最后再调用resumeFocusedStackTopActivityLocked启动Activity的Resume
这样就完成了当发现有复用ActivityRecord时候，TaskRecord和ActivityStack的移动到交互栈顶。

#### 场景回归startActivityUnchecked的复用Activity情况
在setTargetStackAndMoveToFrontIfNeeded中什么时候需要移动TaskRecord以及ActivityStack呢？主要还是当前顶部的ActivityRecord对应的TaskRecord既不是目标启动的栈，也不是当前的焦点的栈对应顶部TaskRecord。也就是说，可能需要移动把复用的TaskRecord进行一次Task之间的移动。

```java
 private void setTaskFromIntentActivity(ActivityRecord intentActivity) {
        if ((mLaunchFlags & (FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK))
                == (FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK)) {.
            final TaskRecord task = intentActivity.getTask();
            task.performClearTaskLocked();
            mReuseTask = task;
            mReuseTask.setIntent(mStartActivity);
        } else if ((mLaunchFlags & FLAG_ACTIVITY_CLEAR_TOP) != 0
                || isLaunchModeOneOf(LAUNCH_SINGLE_INSTANCE, LAUNCH_SINGLE_TASK)) {
            ActivityRecord top = intentActivity.getTask().performClearTaskLocked(mStartActivity,
                    mLaunchFlags);
            if (top == null) {
                mAddingToTask = true;

                mSourceRecord = intentActivity;
                final TaskRecord task = mSourceRecord.getTask();
                if (task != null && task.getStack() == null) {
                    mTargetStack = computeStackFocus(mSourceRecord, false /* newTask */,
                            mLaunchFlags, mOptions);
                    mTargetStack.addTask(task,
                            !mLaunchTaskBehind /* toTop */, "startActivityUnchecked");
                }
            }
        } else if (mStartActivity.realActivity.equals(intentActivity.getTask().realActivity)) {
            if (((mLaunchFlags & FLAG_ACTIVITY_SINGLE_TOP) != 0
                        || LAUNCH_SINGLE_TOP == mLaunchMode)
                    && intentActivity.realActivity.equals(mStartActivity.realActivity)) {
                if (intentActivity.frontOfTask) {
                    intentActivity.getTask().setIntent(mStartActivity);
                }
                deliverNewIntent(intentActivity);
            } else if (!intentActivity.getTask().isSameIntentFilter(mStartActivity)) {
                mAddingToTask = true;
                mSourceRecord = intentActivity;
            }
        } else if ((mLaunchFlags & FLAG_ACTIVITY_RESET_TASK_IF_NEEDED) == 0) {
            mAddingToTask = true;
            mSourceRecord = intentActivity;
        } else if (!intentActivity.getTask().rootWasReset) {
            intentActivity.getTask().setIntent(mStartActivity);
        }
    }
```
当不是上面的情况，需要 setTaskFromIntentActivity，进一步做处理。
- 如果打开FLAG_ACTIVITY_NEW_TASK 以及FLAG_ACTIVITY_CLEAR_TASK，则设置mReuseTask为当前的Task。
- 如果打开了FLAG_ACTIVITY_CLEAR_TOP的标志位，同时singleInstance或者singleTask的一种，则清空Task，拿到顶部的Task，最后重新添加到ActivityStack
- 3.要启动的Activity和当前的Activity是同一个，同时打开了singleTop标志位，以及singleTop启动，直接调用onNewIntent.如果是相同过滤条件，则把启动SourceRecord设置为当前ActivityRecord。

最后再调用resumeTargetStackIfNeeded，resume当前复用的Activity。

## startActivityUnchecked当没有复用Activity时候
在处理完FLAG_ACTIVITY_SINGLE_TOP这种情况之后，将会处理正常启动的Activity。
```java
 int result = START_SUCCESS;
        if (mStartActivity.resultTo == null && mInTask == null && !mAddingToTask
                && (mLaunchFlags & FLAG_ACTIVITY_NEW_TASK) != 0) {
            newTask = true;
            result = setTaskFromReuseOrCreateNewTask(taskToAffiliate, topStack);
        } else if (mSourceRecord != null) {
            result = setTaskFromSourceRecord();
        } else if (mInTask != null) {
            result = setTaskFromInTask();
        } else {
            setTaskToCurrentTopOrCreateNewTask();
        }
...
mTargetStack.startActivityLocked(mStartActivity, topFocused, newTask, mKeepCurTransition,
                mOptions);
         mOptions);
        if (mDoResume) {
            final ActivityRecord topTaskActivity =
                    mStartActivity.getTask().topRunningActivityLocked();
            if (!mTargetStack.isFocusable()
                    || (topTaskActivity != null && topTaskActivity.mTaskOverlay
                    && mStartActivity != topTaskActivity)) {
           ....
            } else {
                if (mTargetStack.isFocusable() && !mSupervisor.isFocusedStack(mTargetStack)) {
                    mTargetStack.moveToFront("startActivityUnchecked");
                }
                mSupervisor.resumeFocusedStackTopActivityLocked(mTargetStack, mStartActivity,
                        mOptions);
            }
        } else if (mStartActivity != null) {
...
        }
```

此时能看到为了找到，真正需要的ActivityStack启动Activity。因此这里分为三种情况：
- 1.当启动的flag打开了FLAG_ACTIVITY_NEW_TASK，并且mAddingToTask为false。当前的Task根部没有任何的Activity这个标志位true，不是如果打开了
new_task为false，否则为true。或者是使用了自由窗口模式，复用Task的时候为null也为true。因此这个标志位起作用一般是当一个Task 中为空，才会新建一个TaskRecord。

- 2.当mSourceRecord不为空，把新的ActivityRecord绑定到启动者的TaskRecord上

- 3.剩下的情况：启动时带了mInTask，ActivityRecord绑定到mInTask。都不是则直接找焦点的ActivityStack上栈顶的Task，直接绑定(几乎不可能发生)。

### 第一种情况打开了FLAG_ACTIVITY_NEW_TASK
当我们打开了FLAG_ACTIVITY_NEW_TASK，computeStackFocus获取目标的ActivityStack。这个方法已经在上面分析过了。
```java
private int setTaskFromReuseOrCreateNewTask(
            TaskRecord taskToAffiliate, ActivityStack topStack) {
        mTargetStack = computeStackFocus(mStartActivity, true, mLaunchFlags, mOptions);
        if (mReuseTask == null) {
            final TaskRecord task = mTargetStack.createTaskRecord(
                    mSupervisor.getNextTaskIdForUserLocked(mStartActivity.userId),
                    mNewTaskInfo != null ? mNewTaskInfo : mStartActivity.info,
                    mNewTaskIntent != null ? mNewTaskIntent : mIntent, mVoiceSession,
                    mVoiceInteractor, !mLaunchTaskBehind /* toTop */, mStartActivity, mSourceRecord,
                    mOptions);
            addOrReparentStartingActivity(task, "setTaskFromReuseOrCreateNewTask - mReuseTask");
            updateBounds(mStartActivity.getTask(), mLaunchParams.mBounds);

...
        } else {
            addOrReparentStartingActivity(mReuseTask, "setTaskFromReuseOrCreateNewTask");
        }
....
        if (mDoResume) {
            mTargetStack.moveToFront("reuseOrNewTask");
        }
        return START_SUCCESS;
    }

 private void addOrReparentStartingActivity(TaskRecord parent, String reason) {
        if (mStartActivity.getTask() == null || mStartActivity.getTask() == parent) {
            parent.addActivityToTop(mStartActivity);
        } else {
            mStartActivity.reparent(parent, parent.mActivities.size() /* top */, reason);
        }
    }
```
这里代入情景，如果是分屏，则判断是否打开FLAG_ACTIVITY_LAUNCH_ADJACENT。根据这个标志位不同到本ActivityStack还是对面。如果是普通的启动获取的当前要启动的ActivityRecord对应的ActivityStack。FLAG_ACTIVITY_NEW_TASK是否生成新的Task的依据是mReuseTask是否设置。而这个对象本质上是ActivityOptions设置的，一般的为空。

最后判断启动的Task为空或者和启动的Task一致，则调用TaskRecord的addActivityToTop把当前要启动的Activity放到TaskRecord的顶部，否则则调用ActivityRecord的reparent。
```java
 void reparent(TaskRecord newTask, int position, String reason) {
        final TaskRecord prevTask = task;
        if (prevTask == newTask) {
            throw new IllegalArgumentException(reason + ": task=" + newTask
                    + " is already the parent of r=" + this);
        }
        if (prevTask != null && newTask != null && prevTask.getStack() != newTask.getStack()) {
            throw new IllegalArgumentException(reason + ": task=" + newTask
                    + " is in a different stack (" + newTask.getStackId() + ") than the parent of"
                    + " r=" + this + " (" + prevTask.getStackId() + ")");
        }
mWindowContainerController.reparent(newTask.getWindowContainerController(), position);
        final ActivityStack prevStack = prevTask.getStack();

        if (prevStack != newTask.getStack()) {
            prevStack.onActivityRemovedFromStack(this);
        }
        // Remove the activity from the old task and add it to the new task.
        prevTask.removeActivity(this, true /* reparenting */);

        newTask.addActivityAtIndex(position, this);
    }
```
能看到，这个方法是清空TaskRecord原来存在其中的ActivityRecord，并且添加到当前新的TaskRecord的顶部。以完成TaskRecord的切换。

### 当mSourceRecord不为空
```java
 private int setTaskFromSourceRecord() {
        if (mService.getLockTaskController().isLockTaskModeViolation(mSourceRecord.getTask())) {
            Slog.e(TAG, "Attempted Lock Task Mode violation mStartActivity=" + mStartActivity);
            return START_RETURN_LOCK_TASK_MODE_VIOLATION;
        }

        final TaskRecord sourceTask = mSourceRecord.getTask();
        final ActivityStack sourceStack = mSourceRecord.getStack();
        // We only want to allow changing stack in two cases:
        // 1. If the target task is not the top one. Otherwise we would move the launching task to
        //    the other side, rather than show two side by side.
        // 2. If activity is not allowed on target display.
        final int targetDisplayId = mTargetStack != null ? mTargetStack.mDisplayId
                : sourceStack.mDisplayId;
        final boolean moveStackAllowed = sourceStack.topTask() != sourceTask
                || !mStartActivity.canBeLaunchedOnDisplay(targetDisplayId);
        if (moveStackAllowed) {
            mTargetStack = getLaunchStack(mStartActivity, mLaunchFlags, mStartActivity.getTask(),
                    mOptions);
            if (mTargetStack == null && targetDisplayId != sourceStack.mDisplayId) {
                mTargetStack = mService.mStackSupervisor.getValidLaunchStackOnDisplay(
                        sourceStack.mDisplayId, mStartActivity);
            }
            if (mTargetStack == null) {
                mTargetStack = mService.mStackSupervisor.getNextValidLaunchStackLocked(
                        mStartActivity, -1 /* currentFocus */);
            }
        }

        if (mTargetStack == null) {
            mTargetStack = sourceStack;
        } else if (mTargetStack != sourceStack) {
            sourceTask.reparent(mTargetStack, ON_TOP, REPARENT_MOVE_STACK_TO_FRONT, !ANIMATE,
                    DEFER_RESUME, "launchToSide");
        }

        final TaskRecord topTask = mTargetStack.topTask();
        if (topTask != sourceTask && !mAvoidMoveToFront) {
            mTargetStack.moveTaskToFrontLocked(sourceTask, mNoAnimation, mOptions,
                    mStartActivity.appTimeTracker, "sourceTaskToFront");
        } else if (mDoResume) {
            mTargetStack.moveToFront("sourceStackToFront");
        }

        if (!mAddingToTask && (mLaunchFlags & FLAG_ACTIVITY_CLEAR_TOP) != 0) {
            ActivityRecord top = sourceTask.performClearTaskLocked(mStartActivity, mLaunchFlags);
            mKeepCurTransition = true;
            if (top != null) {
                ActivityStack.logStartActivity(AM_NEW_INTENT, mStartActivity, top.getTask());
                deliverNewIntent(top);
                mTargetStack.mLastPausedActivity = null;
                if (mDoResume) {
                    mSupervisor.resumeFocusedStackTopActivityLocked();
                }
                ActivityOptions.abort(mOptions);
                return START_DELIVERED_TO_TOP;
            }
        } else if (!mAddingToTask && (mLaunchFlags & FLAG_ACTIVITY_REORDER_TO_FRONT) != 0) {
            final ActivityRecord top = sourceTask.findActivityInHistoryLocked(mStartActivity);
            if (top != null) {
                final TaskRecord task = top.getTask();
                task.moveActivityToFrontLocked(top);
                top.updateOptionsLocked(mOptions);
                ActivityStack.logStartActivity(AM_NEW_INTENT, mStartActivity, task);
                deliverNewIntent(top);
                mTargetStack.mLastPausedActivity = null;
                if (mDoResume) {
                    mSupervisor.resumeFocusedStackTopActivityLocked();
                }
                return START_DELIVERED_TO_TOP;
            }
        }

        addOrReparentStartingActivity(sourceTask, "setTaskFromSourceRecord");

        return START_SUCCESS;
    }
```
这个应该是最常见的情况，分步骤说明

-  1.启动栈的顶部TaskRecord和启动方的TaskRecord不一致或者启动方的不允许显示。则需要移动到其他的ActivityStack。因此此时比较特殊，因此按照上面解析的逻辑，是从有效的displayId中查找与当前模式兼容的ActivityStack，找不到则创建一个ActivityDisplay，再创建对应的ActivityStack。

- 2.mTargetStack为空，则是默认的情况。设置为当前的启动方的ActivityStack。发现目标ActivityStack和启动的ActivityStack不是一个，则需要把启动方TaskRecord，重绑到目标的ActivityStack。

- 3.把目标ActivityStack移动到最前方。也就是设置为焦点ActivityStack，同时设置到ActivityDisplay集合的顶部

- 4 mAddingToTask为false，打开了FLAG_ACTIVITY_CLEAR_TOP，则清除启动方的TaskRecord中的顶部。顶部不为空，则调用newIntent，需要resume，再调用resume。

- 5.mAddingToTask为false，打开了FLAG_ACTIVITY_REORDER_TO_FRONT标志位。这个标志位是在setTargetStackAndMoveToFrontIfNeeded默认设置的。说明此时有复用，但是栈相同，此时会从TaskRecord中获取复用的ActivityRecord。最后调用onNewIntent。

- 6.不过经历什么步骤，都会通过startActivityLocked要把TaskRecord添加到mHistoryTasks顶部。

最后调用ActivityStackSupervisor的resumeFocusedStackTopActivityLocked(因为方法此时传下来默认是true)。

至此就完成了ActivityStack以及TaskRecord如何转化到交互的栈顶流程。


# 小节
限于篇幅问题，本片总结将会之后一起放出。






