---
title: Android 重学系列 WMS在Activity启动中的职责(二)
top: false
cover: false
date: 2019-08-16 16:48:12
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
经过上文，我们熟悉了WMS中WindowContainer和WindowContainerController中各自的职责以及各自功能场景，本文将和大家论述一下在WMS在Actvity中的工作流程。

如果遇到问题，欢迎在[https://www.jianshu.com/p/c7cc335b880a](https://www.jianshu.com/p/c7cc335b880a)讨论。


# 正文
如果看过我写的[Activity启动流程(二)](https://www.jianshu.com/p/4d34de4418e0)一文中有一节，startActivityUnchecked当没有复用Activity时候，AMS会想办法生成一个新的Activity。此时，当然不可能只生成一个象征着Activity信息的ActivityRecord，同时也要生成一个新的Window供Activity使用。

当然，如果阅读过Android源码的人一定会明白，在Activity走onCreate的生命周期的时候，会调用Activity的attach方法生成一个PhoneWindow。但是有没有想过WMS在这之前又做了什么呢？

实际上在startActivityUnchecked这个方法中有一个可以的方法不知道有人注意到没有。如果先前跟着任玉刚,git袁这些大佬读过Activity的启动流程，就会注意到这个方法：ActivityStack.startActivityLocked。

不过在聊ActivityStack之前，我需要过一遍ActivityDisplay，ActivityStack，TaskRecord，ActivityRecord等类。此时时机已经成熟了。这四个数据结构都继承于ConfigurationContainer。

ConfigurationContainer是什么？上一篇文章有人细心一点就会注意到WindowContainer父类正是ConfigurationContainer。

## ConfigurationContainer家族
![ConfigurationContainer家族.png](/images/ConfigurationContainer家族.png)

通过这个UML类图能够进一步的了解到ActivityDisplay控制的集合是ActivityStack。

但是ActivityStack实际上并不是直接控制TaskRecord，而是通过StackWindowController控制下面的TaskStack，从而控制Task以及AppWindowToken，进而间接控制TaskRecord以及ActivityRecord。

那么我们从顶层往底层看每一个ConfigurationContainer的构造函数。

### ActivityDisplay
```java
    ActivityDisplay(ActivityStackSupervisor supervisor, Display display) {
        mSupervisor = supervisor;
        mDisplayId = display.getDisplayId();
        mDisplay = display;
        mWindowContainerController = createWindowContainerController();
        updateBounds();
    }

    protected DisplayWindowController createWindowContainerController() {
        return new DisplayWindowController(mDisplay, this);
    }
```

能够看到的是此时会把ActivityStackSupervisor 以及屏幕id信息绑定到当前的ActivityDisplay。同时调用createWindowContainerController，创建一个DisplayWindowController。

等等，不应该是直接对应到DisplayContent吗？我们看看DisplayWindowController的构造函数。
```java
    public DisplayWindowController(Display display, WindowContainerListener listener) {
        super(listener, WindowManagerService.getInstance());
        mDisplayId = display.getDisplayId();

        synchronized (mWindowMap) {
            final long callingIdentity = Binder.clearCallingIdentity();
            try {
                mRoot.createDisplayContent(display, this /* controller */);
            } finally {
                Binder.restoreCallingIdentity(callingIdentity);
            }

            if (mContainer == null) {
                throw new IllegalArgumentException("Trying to add display=" + display
                        + " dc=" + mRoot.getDisplayContent(mDisplayId));
            }
        }
    }
```
#### RootWindowContainer创建DisplayContent
这里面实际上调用了RootWindowContainer的createDisplayContent方法。
```java
DisplayContent createDisplayContent(final Display display, DisplayWindowController controller) {
        final int displayId = display.getDisplayId();

        // In select scenarios, it is possible that a DisplayContent will be created on demand
        // rather than waiting for the controller. In this case, associate the controller and return
        // the existing display.
        final DisplayContent existing = getDisplayContent(displayId);

        if (existing != null) {
            existing.setController(controller);
            return existing;
        }

        final DisplayContent dc =
                new DisplayContent(display, mService, mWallpaperController, controller);

        if (DEBUG_DISPLAY) Slog.v(TAG_WM, "Adding display=" + display);

        final DisplayInfo displayInfo = dc.getDisplayInfo();
        final Rect rect = new Rect();
        mService.mDisplaySettings.getOverscanLocked(displayInfo.name, displayInfo.uniqueId, rect);
        displayInfo.overscanLeft = rect.left;
        displayInfo.overscanTop = rect.top;
        displayInfo.overscanRight = rect.right;
        displayInfo.overscanBottom = rect.bottom;
        if (mService.mDisplayManagerInternal != null) {
            mService.mDisplayManagerInternal.setDisplayInfoOverrideFromWindowManager(
                    displayId, displayInfo);
            dc.configureDisplayPolicy();

            // Tap Listeners are supported for:
            // 1. All physical displays (multi-display).
            // 2. VirtualDisplays on VR, AA (and everything else).
            if (mService.canDispatchPointerEvents()) {
                if (DEBUG_DISPLAY) {
                    Slog.d(TAG,
                            "Registering PointerEventListener for DisplayId: " + displayId);
                }
                dc.mTapDetector = new TaskTapPointerEventListener(mService, dc);
                mService.registerPointerEventListener(dc.mTapDetector);
                if (displayId == DEFAULT_DISPLAY) {
                    mService.registerPointerEventListener(mService.mMousePositionTracker);
                }
            }
        }

        return dc;
    }
```
RootWindowContainer会尝试着查找当前已经存在的id对应的DisplayContent，没有，则生成新的id，并且把DisplayWindowController 传进去，同时设置Display相关信息，主要是overscan相关的信息。overscan这里先提及一下，是指过扫描区域，因为当屏幕如果把绘制区域绘制在物理屏幕边缘上，可能造成一点失真，如果你仔细看看你自己的手机，你会发现其实屏幕周围有点点黑色的边缘没有绘制上来，实际上就是这个overscan把区域限制住了。之后还会更加详细讲解。

别忘了DisplayContent的构造函数中会自动的添加自己到RootWindowContainer中。

为了要这么设计？AMS和WMS都在一个进程，按照道理应该都可以互相调用。实际上这种方式就是我们常说的组件化，尽量把两个不同职能，不同包之间的逻辑分开DisplayWindowController其实就是DisplayContent的代理类。

这种思路，其实很多大厂在实现组件化初期的时候尝试过。

因此我们能够得到一个对应：ActivityDisplay -> DisplayWindowController ->DisplayContent

并且控制着ActivityStack的集合。

### ActivityStack
```java
ActivityStack(ActivityDisplay display, int stackId, ActivityStackSupervisor supervisor,
            int windowingMode, int activityType, boolean onTop) {
        mStackSupervisor = supervisor;
        mService = supervisor.mService;
        mHandler = new ActivityStackHandler(mService.mHandler.getLooper());
        mWindowManager = mService.mWindowManager;
        mStackId = stackId;
        mCurrentUser = mService.mUserController.getCurrentUserId();
        mTmpRect2.setEmpty();
        // Set display id before setting activity and window type to make sure it won't affect
        // stacks on a wrong display.
        mDisplayId = display.mDisplayId;
        setActivityType(activityType);
        setWindowingMode(windowingMode);
        mWindowContainerController = createStackWindowController(display.mDisplayId, onTop,
                mTmpRect2);
        postAddToDisplay(display, mTmpRect2.isEmpty() ? null : mTmpRect2, onTop);
    }

    T createStackWindowController(int displayId, boolean onTop, Rect outBounds) {
        return (T) new StackWindowController(mStackId, this, displayId, onTop, outBounds,
                mStackSupervisor.mWindowManager);
    }
```
此时ActivityStack就开始和应用互相关联了。因此此时将会保存当前的StackId，当前进程的userId，窗口的mode，更加重要的是调用createStackWindowController创建了StackWindowController。
```java
    private void postAddToDisplay(ActivityDisplay activityDisplay, Rect bounds, boolean onTop) {
        mDisplayId = activityDisplay.mDisplayId;
        setBounds(bounds);
        onParentChanged();

        activityDisplay.addChild(this, onTop ? POSITION_TOP : POSITION_BOTTOM);
        if (inSplitScreenPrimaryWindowingMode()) {
            // If we created a docked stack we want to resize it so it resizes all other stacks
            // in the system.
            mStackSupervisor.resizeDockedStackLocked(
                    getOverrideBounds(), null, null, null, null, PRESERVE_WINDOWS);
        }
    }
```

当每一次生成一个ActivityStack的时候，会通过postAddToDisplay把当前的ActivityStack添加到目标的ActivityDisplay。

如果是分屏模式，可能需要记住ActivityStackSupervisor重新桌面下的dock的大小。dock是什么？在分屏模式下，有一半的屏幕会有一个dock stack在运行程序。一旦进入到这种分屏模式，就会重新计算窗体大小。

此时我们就能找到一个对应关系：ActivityStack->StackWindowController->TaskStack.
同时TaskStack会添加到DisplayContent的TaskWindowController。



### TaskRecord
我们来看看TaskRecord的类名：
```java
class TaskRecord extends ConfigurationContainer implements TaskWindowContainerListener
```
首先能看到上一节中TaskWindowContainerController的回调接口TaskWindowContainerListener是在这里实现的。

此时能够看到的是TaskRecord并没有是确定泛型是ActivityRecord。但是TaskRecord确实是用来管理ActivityRecord的。不过是通过一个list集合来控制：
```java
    /** List of all activities in the task arranged in history order */
    final ArrayList<ActivityRecord> mActivities;
```
能从注释上看到,这个集合是所有Activity在历史记录中的顺序。

```java
    TaskRecord(ActivityManagerService service, int _taskId, ActivityInfo info, Intent _intent,
            IVoiceInteractionSession _voiceSession, IVoiceInteractor _voiceInteractor) {
        mService = service;
        userId = UserHandle.getUserId(info.applicationInfo.uid);
        taskId = _taskId;
        lastActiveTime = SystemClock.elapsedRealtime();
        mAffiliatedTaskId = _taskId;
        voiceSession = _voiceSession;
        voiceInteractor = _voiceInteractor;
        isAvailable = true;
        mActivities = new ArrayList<>();
        mCallingUid = info.applicationInfo.uid;
        mCallingPackage = info.packageName;
        setIntent(_intent, info);
        setMinDimensions(info);
        touchActiveTime();
        mService.mTaskChangeNotificationController.notifyTaskCreated(_taskId, realActivity);
    }
```
能看到的是，在TaskRecord中将会保存taskId,userId,当前屏幕宽高，活跃时间等等。

### TaskRecord的创建
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStack.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java)

TaskRecord哪里创建的呢？为了活跃一下记忆，这边再一次提出来。当第一次创建应用的时候，并不存在Task，此时会调用ActivityStarter.startActivityUnchecked方法中的setTaskFromReuseOrCreateNewTask。

而这个方法会调用当前焦点ActivityStack的createTaskRecord。
```java
    TaskRecord createTaskRecord(int taskId, ActivityInfo info, Intent intent,
            IVoiceInteractionSession voiceSession, IVoiceInteractor voiceInteractor,
            boolean toTop, ActivityRecord activity, ActivityRecord source,
            ActivityOptions options) {
        final TaskRecord task = TaskRecord.create(
                mService, taskId, info, intent, voiceSession, voiceInteractor);
        // add the task to stack first, mTaskPositioner might need the stack association
        addTask(task, toTop, "createTaskRecord");
        final int displayId = mDisplayId != INVALID_DISPLAY ? mDisplayId : DEFAULT_DISPLAY;
        final boolean isLockscreenShown = mService.mStackSupervisor.getKeyguardController()
                .isKeyguardOrAodShowing(displayId);
        if (!mStackSupervisor.getLaunchParamsController()
                .layoutTask(task, info.windowLayout, activity, source, options)
                && !matchParentBounds() && task.isResizeable() && !isLockscreenShown) {
            task.updateOverrideConfiguration(getOverrideBounds());
        }
        task.createWindowContainer(toTop, (info.flags & FLAG_SHOW_FOR_ALL_USERS) != 0);
        return task;
    }
```
在这里面我们看到了几个关键的方法。TaskRecord借助工程生成了一个TaskRecord对象，接着会把Task插入到ActivityStack，并且调用createWindowContainer生成对应的WindowContainer。

```java
void addTask(final TaskRecord task, final boolean toTop, String reason) {
        addTask(task, toTop ? MAX_VALUE : 0, true /* schedulePictureInPictureModeChange */, reason);
        if (toTop) {
            // TODO: figure-out a way to remove this call.
            mWindowContainerController.positionChildAtTop(task.getWindowContainerController(),
                    true /* includingParents */);
        }
    }

    // TODO: This shouldn't allow automatic reparenting. Remove the call to preAddTask and deal
    // with the fall-out...
    void addTask(final TaskRecord task, int position, boolean schedulePictureInPictureModeChange,
            String reason) {
        // TODO: Is this remove really needed? Need to look into the call path for the other addTask
        mTaskHistory.remove(task);
        position = getAdjustedPositionForTask(task, position, null /* starting */);
        final boolean toTop = position >= mTaskHistory.size();
        final ActivityStack prevStack = preAddTask(task, reason, toTop);

        mTaskHistory.add(position, task);
        task.setStack(this);

        updateTaskMovement(task, toTop);

        postAddTask(task, prevStack, schedulePictureInPictureModeChange);
    }
```
我们能够看到，首先会从当前ActivityStack的历史中干掉可能存在重复的TaskRecord。此时会getAdjustedPositionForTask找到当前TaskRecord应该插入的位置，接着找一下这个Task是否已经绑定过ActivityStack，绑定过则要从原来的ActivityStack移除出来。最后再插入到ActivityStack的mTaskHistory中。


后面两个函数是Android7.0的画中画特性，唤起Supervisor处理这个特性时候Task需要完成的刷新工作。

#### getAdjustedPositionForTask
```java
    int getAdjustedPositionForTask(TaskRecord task, int suggestedPosition,
            ActivityRecord starting) {

        int maxPosition = mTaskHistory.size();
        if ((starting != null && starting.okToShowLocked())
                || (starting == null && task.okToShowLocked())) {
            // If the task or starting activity can be shown, then whatever position is okay.
            return Math.min(suggestedPosition, maxPosition);
        }

        // The task can't be shown, put non-current user tasks below current user tasks.
        while (maxPosition > 0) {
            final TaskRecord tmpTask = mTaskHistory.get(maxPosition - 1);
            if (!mStackSupervisor.isCurrentProfileLocked(tmpTask.userId)
                    || tmpTask.topRunningActivityLocked() == null) {
                break;
            }
            maxPosition--;
        }

        return  Math.min(suggestedPosition, maxPosition);
    }
```

从这一个函数能看到，Task一开始建议插入的位置，如果mLaunchTaskBehind这个标志位为false则是历史记录栈顶，否则则为历史记录栈底。如果是一般的Activity启动，都是历史记录栈顶位置。当然初次之外还要判断当前历史记录栈顶是否是当前用户可见，不可见则不断往下找可见的位置。


### StackWindowController.positionChildAtTop
当添加Task的时候，如果判断是栈顶的TaskRecord，则会做如下处理：
```java
public void positionChildAtTop(TaskWindowContainerController child, boolean includingParents) {
        if (child == null) {
            // TODO: Fix the call-points that cause this to happen.
            return;
        }

        synchronized(mWindowMap) {
            final Task childTask = child.mContainer;
            if (childTask == null) {
                Slog.e(TAG_WM, "positionChildAtTop: task=" + child + " not found");
                return;
            }
            mContainer.positionChildAt(POSITION_TOP, childTask, includingParents);

            if (mService.mAppTransition.isTransitionSet()) {
                childTask.setSendingToBottom(false);
            }
            mContainer.getDisplayContent().layoutAndAssignWindowLayersIfNeeded();
        }
    }
```
第一次Task的时候，还没存在对应的WindowContainer则不需要理会。但是如果本身Taskrecord是被复用的。则会找到Task对应的WindowContainer，插入到当前StackWindowController中对应的WindowContainer的顶部。此时则会把TaskRecord对应的Task添加到TaskStack对应的位置层级上。

#### TaskRecord创建Task
在TaskRecord创建的最后一步会调用createWindowContainer。
```java
    void createWindowContainer(boolean onTop, boolean showForAllUsers) {
        if (mWindowContainerController != null) {
            throw new IllegalArgumentException("Window container=" + mWindowContainerController
                    + " already created for task=" + this);
        }

        final Rect bounds = updateOverrideConfigurationFromLaunchBounds();
        setWindowContainerController(new TaskWindowContainerController(taskId, this,
                getStack().getWindowContainerController(), userId, bounds,
                mResizeMode, mSupportsPictureInPicture, onTop,
                showForAllUsers, lastTaskDescription));
    }

    protected void setWindowContainerController(TaskWindowContainerController controller) {
        if (mWindowContainerController != null) {
            throw new IllegalArgumentException("Window container=" + mWindowContainerController
                    + " already created for task=" + this);
        }

        mWindowContainerController = controller;
    }
```
很简单，此时就创建了一个Task对应到TaskRecord中。

讲到这里，是不是开始理解之前Activity启动中无法理解的部分，为什么调整TaskRecord会调整到窗体。因为TaskRecord本身就包含了对应的Task这个窗体容器。会随着TaskRecord调整而调整。

同样的，我们能够整理出一个对应的关系：TaskRecord -> TaskWindowContainerController ->Task

### ActivityRecord
同样的，我们来看看它的类名：
```java
final class ActivityRecord extends ConfigurationContainer implements AppWindowContainerListener 
```
首先我们能看到上一节中AppWindowContainerListener 回调接口是在ActivityRecord实现的，也就是说AppWindowContainerController的回调将会在这里处理。

接下来啊看看他的构造函数:
```java
ActivityRecord(ActivityManagerService _service, ProcessRecord _caller, int _launchedFromPid,
            int _launchedFromUid, String _launchedFromPackage, Intent _intent, String _resolvedType,
            ActivityInfo aInfo, Configuration _configuration,
            ActivityRecord _resultTo, String _resultWho, int _reqCode,
            boolean _componentSpecified, boolean _rootVoiceInteraction,
            ActivityStackSupervisor supervisor, ActivityOptions options,
            ActivityRecord sourceRecord) {
        service = _service;
        appToken = new Token(this, _intent);
        info = aInfo;
....

        // This starts out true, since the initial state of an activity is that we have everything,
        // and we shouldn't never consider it lacking in state to be removed if it dies.
        haveState = true;

        // If the class name in the intent doesn't match that of the target, this is
        // probably an alias. We have to create a new ComponentName object to keep track
        // of the real activity name, so that FLAG_ACTIVITY_CLEAR_TOP is handled properly.
        if (aInfo.targetActivity == null
                || (aInfo.targetActivity.equals(_intent.getComponent().getClassName())
                && (aInfo.launchMode == LAUNCH_MULTIPLE
                || aInfo.launchMode == LAUNCH_SINGLE_TOP))) {
            realActivity = _intent.getComponent();
        } else {
            realActivity = new ComponentName(aInfo.packageName, aInfo.targetActivity);
        }
        taskAffinity = aInfo.taskAffinity;
        stateNotNeeded = (aInfo.flags & FLAG_STATE_NOT_NEEDED) != 0;
        appInfo = aInfo.applicationInfo;
        nonLocalizedLabel = aInfo.nonLocalizedLabel;
        labelRes = aInfo.labelRes;
        if (nonLocalizedLabel == null && labelRes == 0) {
            ApplicationInfo app = aInfo.applicationInfo;
            nonLocalizedLabel = app.nonLocalizedLabel;
            labelRes = app.labelRes;
        }
        icon = aInfo.getIconResource();
        logo = aInfo.getLogoResource();
        theme = aInfo.getThemeResource();
        realTheme = theme;
        if (realTheme == 0) {
            realTheme = aInfo.applicationInfo.targetSdkVersion < HONEYCOMB
                    ? android.R.style.Theme : android.R.style.Theme_Holo;
        }
        if ((aInfo.flags & ActivityInfo.FLAG_HARDWARE_ACCELERATED) != 0) {
            windowFlags |= LayoutParams.FLAG_HARDWARE_ACCELERATED;
        }
        if ((aInfo.flags & FLAG_MULTIPROCESS) != 0 && _caller != null
                && (aInfo.applicationInfo.uid == SYSTEM_UID
                    || aInfo.applicationInfo.uid == _caller.info.uid)) {
            processName = _caller.processName;
        } else {
            processName = aInfo.processName;
        }

        if ((aInfo.flags & FLAG_EXCLUDE_FROM_RECENTS) != 0) {
            intent.addFlags(FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
        }

        packageName = aInfo.applicationInfo.packageName;
        launchMode = aInfo.launchMode;

        Entry ent = AttributeCache.instance().get(packageName,
                realTheme, com.android.internal.R.styleable.Window, userId);

        if (ent != null) {
            fullscreen = !ActivityInfo.isTranslucentOrFloating(ent.array);
            hasWallpaper = ent.array.getBoolean(R.styleable.Window_windowShowWallpaper, false);
            noDisplay = ent.array.getBoolean(R.styleable.Window_windowNoDisplay, false);
        } else {
            hasWallpaper = false;
            noDisplay = false;
        }

        setActivityType(_componentSpecified, _launchedFromUid, _intent, options, sourceRecord);

        immersive = (aInfo.flags & FLAG_IMMERSIVE) != 0;

        requestedVrComponent = (aInfo.requestedVrComponent == null) ?
                null : ComponentName.unflattenFromString(aInfo.requestedVrComponent);

        mShowWhenLocked = (aInfo.flags & FLAG_SHOW_WHEN_LOCKED) != 0;
        mTurnScreenOn = (aInfo.flags & FLAG_TURN_SCREEN_ON) != 0;

        mRotationAnimationHint = aInfo.rotationAnimation;
        lockTaskLaunchMode = aInfo.lockTaskLaunchMode;
        if (appInfo.isPrivilegedApp() && (lockTaskLaunchMode == LOCK_TASK_LAUNCH_MODE_ALWAYS
                || lockTaskLaunchMode == LOCK_TASK_LAUNCH_MODE_NEVER)) {
            lockTaskLaunchMode = LOCK_TASK_LAUNCH_MODE_DEFAULT;
        }

        if (options != null) {
            pendingOptions = options;
            mLaunchTaskBehind = options.getLaunchTaskBehind();

            final int rotationAnimation = pendingOptions.getRotationAnimationHint();
            // Only override manifest supplied option if set.
            if (rotationAnimation >= 0) {
                mRotationAnimationHint = rotationAnimation;
            }
            final PendingIntent usageReport = pendingOptions.getUsageTimeReport();
            if (usageReport != null) {
                appTimeTracker = new AppTimeTracker(usageReport);
            }
            final boolean useLockTask = pendingOptions.getLockTaskMode();
            if (useLockTask && lockTaskLaunchMode == LOCK_TASK_LAUNCH_MODE_DEFAULT) {
                lockTaskLaunchMode = LOCK_TASK_LAUNCH_MODE_IF_WHITELISTED;
            }
        }
    }
```
能大致的看到这个时候Activity的实例化，主要只是把启动的参数大量的设置进来。并且生成了一个很重要的对象Token。这个Token实际上就是一个IApplicationToken:
```java
static class Token extends IApplicationToken.Stub 
```
用于标识唯一的Activity。

不过就算在构造函数没有相应的逻辑，剩下的对应关系啊，我们也能写出来:
ActivityRecord->AppWindowContainer->AppWindowToken.

## ActivityRecord的创建与相关的WindowContainer的初始化
ActivityRecord作为Activity相关信息的承载者极为的重要。但是却没看见ActivityRecord究竟是在什么时候创建，没有看到ActivityRecord对应的WindowContainer在哪里创建

回顾一下，实际上ActivityRecord的生成是在ActivityStarter的startActivity中经过对进程，权限的校验才生成的。

当生成完了ActivityRecord，则会调用startActivityUnChecked，在这一步骤处理查找到对应Task或者新建Task，完成ActivityRecord和TaskRecord的绑定。

这里分主要分四种情况：
- 1.启动带了NEW_TASK的参数，另起一个TaskRecord，把ActivityRecord绑定在上面。
- 2.启动本身有着Activity的发起者，则把ActivityRecord绑定到发起者的TaskRecord。
- 3.启动带着mInTask，(几乎不见，在AMS测试代码中见到)
- 4.剩下的情况（几乎没有可能）

这四个方法都会调用addOrReparentStartingActivity方法，添加或者更换ActivityRecord的绑定。
```java
 private void addOrReparentStartingActivity(TaskRecord parent, String reason) {
        if (mStartActivity.getTask() == null || mStartActivity.getTask() == parent) {
            parent.addActivityToTop(mStartActivity);
        } else {
            mStartActivity.reparent(parent, parent.mActivities.size() /* top */, reason);
        }
    }
```

在之前那一篇章，主要这个方法是在Task可以复用的情形。这一次，我们来聊聊第一次创建的情形，走第一个分支的情况：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[TaskRecord.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/TaskRecord.java)
```java
 void addActivityToTop(ActivityRecord r) {
        addActivityAtIndex(mActivities.size(), r);
    }

 void addActivityAtIndex(int index, ActivityRecord r) {
        TaskRecord task = r.getTask();
        if (task != null && task != this) {
            throw new IllegalArgumentException("Can not add r=" + " to task=" + this
                    + " current parent=" + task);
        }

        r.setTask(this);

        // Remove r first, and if it wasn't already in the list and it's fullscreen, count it.
        if (!mActivities.remove(r) && r.fullscreen) {
            // Was not previously in list.
            numFullscreen++;
        }
        // Only set this based on the first activity
        if (mActivities.isEmpty()) {
            if (r.getActivityType() == ACTIVITY_TYPE_UNDEFINED) {
                // Normally non-standard activity type for the activity record will be set when the
                // object is created, however we delay setting the standard application type until
                // this point so that the task can set the type for additional activities added in
                // the else condition below.
                r.setActivityType(ACTIVITY_TYPE_STANDARD);
            }
            setActivityType(r.getActivityType());
            isPersistable = r.isPersistable();
            mCallingUid = r.launchedFromUid;
            mCallingPackage = r.launchedFromPackage;
            // Clamp to [1, max].
            maxRecents = Math.min(Math.max(r.info.maxRecents, 1),
                    ActivityManager.getMaxAppRecentsLimitStatic());
        } else {
            // Otherwise make all added activities match this one.
            r.setActivityType(getActivityType());
        }

        final int size = mActivities.size();

        if (index == size && size > 0) {
            final ActivityRecord top = mActivities.get(size - 1);
            if (top.mTaskOverlay) {
                // Place below the task overlay activity since the overlay activity should always
                // be on top.
                index--;
            }
        }

        index = Math.min(size, index);
        mActivities.add(index, r);

        updateEffectiveIntent();
        if (r.isPersistable()) {
            mService.notifyTaskPersisterLocked(this, false);
        }

        // Sync. with window manager
        updateOverrideConfigurationFromLaunchBounds();
        final AppWindowContainerController appController = r.getWindowContainerController();
        if (appController != null) {
            // Only attempt to move in WM if the child has a controller. It is possible we haven't
            // created controller for the activity we are starting yet.
            mWindowContainerController.positionChildAt(appController, index);
        }

        // Make sure the list of display UID whitelists is updated
        // now that this record is in a new task.
        mService.mStackSupervisor.updateUIDsPresentOnDisplay();
    }
```
我们能够很轻易的看到此时如果Task的mActivities的顶部只要不是mTaskOverlay的ActivityRecord，则直接加到顶部，否则加到下一个位置。


```java
public void positionChildAt(AppWindowContainerController childController, int position) {
        synchronized(mService.mWindowMap) {
            final AppWindowToken aToken = childController.mContainer;
            if (aToken == null) {
                Slog.w(TAG_WM,
                        "Attempted to position of non-existing app : " + childController);
                return;
            }

            final Task task = mContainer;
            if (task == null) {
                throw new IllegalArgumentException("positionChildAt: invalid task=" + this);
            }
            task.positionChildAt(position, aToken, false /* includeParents */);
        }
    }
```

同时判断到如果ActivityRecord本身已经存在了AppWindowContainerController ，则会调用TaskWindowContainerController，调用AppWindowContainerController ，把AppToken插入到对应的Task位置。


完成了TaskRecord的查找和ActivityRecord绑定，也就完成了Task和AppToken的查找和绑定。resumeFocusedStackTopActivityLocked将会准备进行跨进程通信。

而在resumeFocusedStackTopActivityLocked之前必定做了WMS相关的处理。也就是我在Activity启动流程中故意遗漏的startActivityLocked方法。


## ActivityStarter启动新的Activity

为了避免跨度太大，这里也上了原来的startActivityUnChecked部分逻辑。
```java
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
能看到此时mTargetStack就是指找到当前符合条件的焦点ActivityStack将会调用startActivityLocked方法。这里回顾一下，mStartActivity就是指新生成的ActivityRecord，topFocused是当前正在显示的Activity，newTask是根据Intent.flag找到符合标准的TaskRecord。

我们来看看startActivityLocked做了什么有趣的事情。

### ActivityStack startActivityLocked
```java
void startActivityLocked(ActivityRecord r, ActivityRecord focusedTopActivity,
            boolean newTask, boolean keepCurTransition, ActivityOptions options) {
        TaskRecord rTask = r.getTask();
        final int taskId = rTask.taskId;
        // mLaunchTaskBehind tasks get placed at the back of the task stack.
        if (!r.mLaunchTaskBehind && (taskForIdLocked(taskId) == null || newTask)) {
            // Last activity in task had been removed or ActivityManagerService is reusing task.
            // Insert or replace.
            // Might not even be in.
//核心事件1
            insertTaskAtTop(rTask, r);
        }
        TaskRecord task = null;
        if (!newTask) {
           ...
        }

        // Place a new activity at top of stack, so it is next to interact with the user.

        // If we are not placing the new activity frontmost, we do not want to deliver the
        // onUserLeaving callback to the actual frontmost activity
        final TaskRecord activityTask = r.getTask();
...
        task = activityTask;

        // TODO: Need to investigate if it is okay for the controller to already be created by the
        // time we get to this point. I think it is, but need to double check.
        // Use test in b/34179495 to trace the call path.
//核心事件2
        if (r.getWindowContainerController() == null) {
            r.createWindowContainer();
        }
        task.setFrontOfTask();

        if (!isHomeOrRecentsStack() || numActivities() > 0) {
    ...
            if ((r.intent.getFlags() & Intent.FLAG_ACTIVITY_NO_ANIMATION) != 0) {
...
            } else {
                int transit = TRANSIT_ACTIVITY_OPEN;
                if (newTask) {
                   ...
                        transit = TRANSIT_TASK_OPEN;
                    }
                }
                mWindowManager.prepareAppTransition(transit, keepCurTransition);
                mStackSupervisor.mNoAnimActivities.remove(r);
            }
            boolean doShow = true;
            if (newTask) {
                // Even though this activity is starting fresh, we still need
                // to reset it to make sure we apply affinities to move any
                // existing activities from other tasks in to it.
                // If the caller has requested that the target task be
                // reset, then do so.
                if ((r.intent.getFlags() & Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED) != 0) {
                    resetTaskIfNeededLocked(r, r);
                    doShow = topRunningNonDelayedActivityLocked(null) == r;
                }
            } else if (options != null && options.getAnimationType()
                    == ActivityOptions.ANIM_SCENE_TRANSITION) {
                doShow = false;
            }
            if (r.mLaunchTaskBehind) {
...
            } else if (SHOW_APP_STARTING_PREVIEW && doShow) {
                // Figure out if we are transitioning from another activity that is
                // "has the same starting icon" as the next one.  This allows the
                // window manager to keep the previous window it had previously
                // created, if it still had one.
                TaskRecord prevTask = r.getTask();
                ActivityRecord prev = prevTask.topRunningActivityWithStartingWindowLocked();
                if (prev != null) {
                    // We don't want to reuse the previous starting preview if:
                    // (1) The current activity is in a different task.
                    if (prev.getTask() != prevTask) {
                        prev = null;
                    }
                    // (2) The current activity is already displayed.
                    else if (prev.nowVisible) {
                        prev = null;
                    }
                }
//核心事件3
                r.showStartingWindow(prev, newTask, isTaskSwitch(r, focusedTopActivity));
            }
        } else {
...
        }
    }
```
在这个方法中，我把需要注意的部分抽出来，实际上分为三个核心事件。

### 核心事件1 把TaskRecord插入到mTaskHistory中
```java
    private void insertTaskAtTop(TaskRecord task, ActivityRecord starting) {
        // TODO: Better place to put all the code below...may be addTask...
        mTaskHistory.remove(task);
        // Now put task at top.
        final int position = getAdjustedPositionForTask(task, mTaskHistory.size(), starting);
        mTaskHistory.add(position, task);
        updateTaskMovement(task, true);
        mWindowContainerController.positionChildAtTop(task.getWindowContainerController(),
                true /* includingParents */);
    }

```
从TaskRecord创建小节可知，当第一次创建的时候只是做了把TaskRecord添加到mTaskHistory，创建对应的TaskWindowContainer，并没有添加到TaskStack中。在这个方法中则是把新生成的TaskWindowConatainer添加到对应的StackWindowConatainer。不过为了保证mTaskHistory和TaskWindowConatiner的统一，当移动TaskWindowConatiner的时候，也原地移动了TaskRecord在mTaskHistory的位置。

### 核心事件二 ActivityRecord创建对应的WindowContainer。
```java
        if (r.getWindowContainerController() == null) {
            r.createWindowContainer();
        }
```
当检测到ActivityRecord中没有自己的AppToken。则会调用ActivityRecord的创建方法：
```java
void createWindowContainer() {
        if (mWindowContainerController != null) {
            throw new IllegalArgumentException("Window container=" + mWindowContainerController
                    + " already created for r=" + this);
        }

        inHistory = true;

        final TaskWindowContainerController taskController = task.getWindowContainerController();

        // TODO(b/36505427): Maybe this call should be moved inside updateOverrideConfiguration()
        task.updateOverrideConfigurationFromLaunchBounds();
        // Make sure override configuration is up-to-date before using to create window controller.
        updateOverrideConfiguration();

        mWindowContainerController = new AppWindowContainerController(taskController, appToken,
                this, Integer.MAX_VALUE /* add on top */, info.screenOrientation, fullscreen,
                (info.flags & FLAG_SHOW_FOR_ALL_USERS) != 0, info.configChanges,
                task.voiceSession != null, mLaunchTaskBehind, isAlwaysFocusable(),
                appInfo.targetSdkVersion, mRotationAnimationHint,
                ActivityManagerService.getInputDispatchingTimeoutLocked(this) * 1000000L);

        task.addActivityToTop(this);

        // When an activity is started directly into a split-screen fullscreen stack, we need to
        // update the initial multi-window modes so that the callbacks are scheduled correctly when
        // the user leaves that mode.
        mLastReportedMultiWindowMode = inMultiWindowMode();
        mLastReportedPictureInPictureMode = inPinnedWindowingMode();
    }
```
能看到此时的逻辑其实和ActivityRecord绑定TaskRecord的逻辑十分相似。

> 别忘了，当我们创建了一个AppWindowContainerController，其构造函数就会创建一个AppWindowToken，并且添加到DisplayContent的mTokenMap中。

> 此时DisplayContent就会收集到新的WindowToken。以供后面的使用

### 核心事件三 showStartingWindow ActivityRecord开始展示闪屏
```java
void showStartingWindow(ActivityRecord prev, boolean newTask, boolean taskSwitch,
            boolean fromRecents) {
        if (mWindowContainerController == null) {
            return;
        }
        if (mTaskOverlay) {
            // We don't show starting window for overlay activities.
            return;
        }

        final CompatibilityInfo compatInfo =
                service.compatibilityInfoForPackageLocked(info.applicationInfo);
        final boolean shown = mWindowContainerController.addStartingWindow(packageName, theme,
                compatInfo, nonLocalizedLabel, labelRes, icon, logo, windowFlags,
                prev != null ? prev.appToken : null, newTask, taskSwitch, isProcessRunning(),
                allowTaskSnapshot(),
                mState.ordinal() >= RESUMED.ordinal() && mState.ordinal() <= STOPPED.ordinal(),
                fromRecents);
        if (shown) {
            mStartingWindowState = STARTING_WINDOW_SHOWN;
        }
    }
```
此时会添加第一个启动的启动Window，这个Window类似闪屏一样的存在。这个闪屏是指什么的？
```java
 <style name="Theme">
        <!-- Window attributes -->
        <item name="windowBackground">@drawable/screen_background_selector_dark</item>
```
实际上就是指这个。换句话说，最佳的闪屏页面的地方一定是这里。速度最快的也是这里，因为此时根本还没有启动我们的App应用进程，只是创建了一个PhoneWindow窗体在WindowManager并且通过Surface直接绘制出来。

是不是这样，进去看看AppWindowContainerController的方法。
```java
public boolean addStartingWindow(String pkg, int theme, CompatibilityInfo compatInfo,
            CharSequence nonLocalizedLabel, int labelRes, int icon, int logo, int windowFlags,
            IBinder transferFrom, boolean newTask, boolean taskSwitch, boolean processRunning,
            boolean allowTaskSnapshot, boolean activityCreated, boolean fromRecents) {
        synchronized(mWindowMap) {
...

            final WindowState mainWin = mContainer.findMainWindow();
            if (mainWin != null && mainWin.mWinAnimator.getShown()) {
                return false;
            }

            final TaskSnapshot snapshot = mService.mTaskSnapshotController.getSnapshot(
                    mContainer.getTask().mTaskId, mContainer.getTask().mUserId,
                    false /* restoreFromDisk */, false /* reducedResolution */);
            final int type = getStartingWindowType(newTask, taskSwitch, processRunning,
                    allowTaskSnapshot, activityCreated, fromRecents, snapshot);

            if (type == STARTING_WINDOW_TYPE_SNAPSHOT) {
                return createSnapshot(snapshot);
            }

            // If this is a translucent window, then don't show a starting window -- the current
            // effect (a full-screen opaque starting window that fades away to the real contents
            // when it is ready) does not work for this.
            if (DEBUG_STARTING_WINDOW) Slog.v(TAG_WM, "Checking theme of starting window: 0x"
                    + Integer.toHexString(theme));
            if (theme != 0) {
                AttributeCache.Entry ent = AttributeCache.instance().get(pkg, theme,
                        com.android.internal.R.styleable.Window, mService.mCurrentUserId);
                if (ent == null) {
...
                    return false;
                }
                final boolean windowIsTranslucent = ent.array.getBoolean(
                        com.android.internal.R.styleable.Window_windowIsTranslucent, false);
                final boolean windowIsFloating = ent.array.getBoolean(
                        com.android.internal.R.styleable.Window_windowIsFloating, false);
                final boolean windowShowWallpaper = ent.array.getBoolean(
                        com.android.internal.R.styleable.Window_windowShowWallpaper, false);
                final boolean windowDisableStarting = ent.array.getBoolean(
                        com.android.internal.R.styleable.Window_windowDisablePreview, false);
...
                if (windowIsTranslucent) {
                    return false;
                }
                if (windowIsFloating || windowDisableStarting) {
                    return false;
                }
                if (windowShowWallpaper) {
                    if (mContainer.getDisplayContent().mWallpaperController.getWallpaperTarget()
                            == null) {
...
                        windowFlags |= FLAG_SHOW_WALLPAPER;
                    } else {
                        return false;
                    }
                }
            }

            if (mContainer.transferStartingWindow(transferFrom)) {
                return true;
            }

            // There is no existing starting window, and we don't want to create a splash screen, so
            // that's it!
            if (type != STARTING_WINDOW_TYPE_SPLASH_SCREEN) {
                return false;
            }

...
            mContainer.startingData = new SplashScreenStartingData(mService, pkg, theme,
                    compatInfo, nonLocalizedLabel, labelRes, icon, logo, windowFlags,
                    mContainer.getMergedOverrideConfiguration());
            scheduleAddStartingWindow();
        }
        return true;
    }
```

很有意思，从这个StartingWindow，我大致能看到了Google工程师在UI体验上的努力了。

这里可以分为两个情况，第一个情况是使用快照，第二个情况是使用写在Apk包中的xml属性。

- 1.当允许使用快照，并且当前屏幕的横竖屏方向和快照的一致时候，将会获取保存WMS中TaskSnapshotController的Task中GraphicBuffer，把它绘制到屏幕上去。这里稍微有点跨度大了点。实际上就是把Task离开前的那一帧记录到TaskSnapshotController的缓存(TaskSnapshotCache)中,打开的时候，在启动app应用之前就会先把退出后台前的那一帧画面先绘制到屏幕上。

- 2.使用闪屏页面的时候，直接通过PackageManagerService读取配置文件中相关的信息，接着生成SplashScreenStartingData，启动绘制按下图标后的第一帧画面。接着会把这个工作放给WMS的动画Handler中异步执行。

### App 启动优化谬误纠正
这里面我们能够看到一个很熟悉的身影：
```java
Window_windowIsTranslucent
```
网上有些资料说，我们要做启动优化，就要把这个标志位设置为透明状态，让App启动一开始的时候是透明的。减少黑/白屏时间。实际上出处就在这里，当我们点击Home上的图标的第一帧实际上就是这个StartingWindow。

但是请注意这个时候我们根本还没有启动App进程(进程是后面的startSpecificActivityLocked方法才校验启动)，这种网上的优化方法压根是错误的。启动时间该长还是长，反而会导致一点，透明时间过长，又没办法响应点击事件(因为此时窗口没有焦点),用户以为手机卡主了，问题最后还是抛回给这个应用。



### PhoneWindowManager addSplashScreen创建启动窗口
PhoneWindowManager是WMS的核心类之一。这里面包含了大量的WMS的策略，继承于WindowManagerPolicy。
```java
    /** {@inheritDoc} */
    @Override
    public StartingSurface addSplashScreen(IBinder appToken, String packageName, int theme,
            CompatibilityInfo compatInfo, CharSequence nonLocalizedLabel, int labelRes, int icon,
            int logo, int windowFlags, Configuration overrideConfig, int displayId) {
...

        WindowManager wm = null;
        View view = null;

        try {
            Context context = mContext;
...

            if (theme != context.getThemeResId() || labelRes != 0) {
                try {
                    context = context.createPackageContext(packageName, CONTEXT_RESTRICTED);
                    context.setTheme(theme);
                } catch (PackageManager.NameNotFoundException e) {
                    // Ignore
                }
            }

            if (overrideConfig != null && !overrideConfig.equals(EMPTY)) {
...
                final TypedArray typedArray = overrideContext.obtainStyledAttributes(
                        com.android.internal.R.styleable.Window);
                final int resId = typedArray.getResourceId(R.styleable.Window_windowBackground, 0);
...
            }

            final PhoneWindow win = new PhoneWindow(context);
            win.setIsStartingWindow(true);

            CharSequence label = context.getResources().getText(labelRes, null);
            // Only change the accessibility title if the label is localized
            if (label != null) {
                win.setTitle(label, true);
            } else {
                win.setTitle(nonLocalizedLabel, false);
            }

            win.setType(
                WindowManager.LayoutParams.TYPE_APPLICATION_STARTING);

...
            win.setFlags(
                windowFlags|
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE|
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
                windowFlags|
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE|
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM);

            win.setDefaultIcon(icon);
            win.setDefaultLogo(logo);

            win.setLayout(WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT);

            final WindowManager.LayoutParams params = win.getAttributes();
            params.token = appToken;
            params.packageName = packageName;
            params.windowAnimations = win.getWindowStyle().getResourceId(
                    com.android.internal.R.styleable.Window_windowAnimationStyle, 0);
            params.privateFlags |=
                    WindowManager.LayoutParams.PRIVATE_FLAG_FAKE_HARDWARE_ACCELERATED;
            params.privateFlags |= WindowManager.LayoutParams.PRIVATE_FLAG_SHOW_FOR_ALL_USERS;

            if (!compatInfo.supportsScreen()) {
                params.privateFlags |= WindowManager.LayoutParams.PRIVATE_FLAG_COMPATIBLE_WINDOW;
            }

            params.setTitle("Splash Screen " + packageName);
            addSplashscreenContent(win, context);

            wm = (WindowManager) context.getSystemService(WINDOW_SERVICE);
            view = win.getDecorView();

...
            wm.addView(view, params);

..
            return view.getParent() != null ? new SplashScreenSurface(view, appToken) : null;
        } catch (WindowManager.BadTokenException e) {
...
        } catch (RuntimeException e) {
...
        } finally {
            if (view != null && view.getParent() == null) {
                Log.w(TAG, "view not successfully added to wm, removing view");
                wm.removeViewImmediate(view);
            }
        }

        return null;
    }

private void addSplashscreenContent(PhoneWindow win, Context ctx) {
        final TypedArray a = ctx.obtainStyledAttributes(R.styleable.Window);
        final int resId = a.getResourceId(R.styleable.Window_windowSplashscreenContent, 0);
        a.recycle();
        if (resId == 0) {
            return;
        }
        final Drawable drawable = ctx.getDrawable(resId);
        if (drawable == null) {
            return;
        }

        // We wrap this into a view so the system insets get applied to the drawable.
        final View v = new View(ctx);
        v.setBackground(drawable);
        win.setContentView(v);
    }
```
此时，我们能看到一个熟悉类，PhoneWindow。PhoneWindow对于每一个Android开发者来说都不陌生，实际上在Activity创建的时候，就是由这个PhoneWindow承载了我们的界面。

此刻，此时会生成一个PhoneWindow，接着会读取windowSplashscreenContent属性中的资源文件作为当前PhoneWindow的view。
```java
 <item name="android:windowSplashscreenContent"></item>
```

最后再把PhoneWindow的DecorView读取出来添加到WMS中。

接下来就会进入到正戏，WMS添加Window实例操作。


## 总结
经过这一篇文章的对Activity启动流程的各个线索串联起来，是不是对ActivityRecord，TaskRecord有了更加深刻的了解呢？

这里我们可以针对AMS，WMS的各个ConfigurationContainer之间的关系，添加画一个图。
![ConfigurationContainer之间联系.png](/images/ConfigurationContainer之间联系.png)


同时本文也点出了，网上App启动优化一些不是很正确的观点。实际上这就是阅读Android源码的优点。下面我们将会深入WMS的添加实例Window，我这中间会跳过setContentView这些源码流程，这一块内容挺多的应该要专门拖出来聊聊，而不应该放在WMS中囫囵吞枣般的过一遍。







