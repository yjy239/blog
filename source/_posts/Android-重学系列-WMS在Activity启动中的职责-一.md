---
title: Android 重学系列 WMS在Activity启动中的职责(一)
top: false
cover: false
date: 2019-08-15 15:32:20
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
好久没有继续写Android重学系列了。这次我们继续聊聊当Activity创建之后。Android接下来就会尝试的显示界面ui。此时就会牵扯到一个核心的服务WindowManagerService(当然Activity的启动也牵扯到了WMS,两者是互相纠缠但是职能不同)，窗口管理服务。我原本是想和大家聊聊SurfaceFlinger，但是可惜的是，还没到时候，而且属于学习起来需要一点OpenGL的知识，因此换一个方向，从上至下一点点剖析整个Android的显示系统。

因为Android的窗口也是显示系统中的一员，同时也在Activity启动中也嵌入了不少逻辑。因此本文将会从WMS的启动以及Activity的启动WMS在其中的角色这两个角度，来聊聊WMS在Android中的职能。

如果遇到问题请在[https://www.jianshu.com/p/1fd180ea5d0e](https://www.jianshu.com/p/1fd180ea5d0e)
联系本人,欢迎讨论。

注意以下源码全部来自Android9.0.
# 正文

## 概论
在重学系列的Android启动中，我介绍核心类ActivityRecord在整个Android系统中的变换与流转。但是并没有涉及这个Activity怎么显示到屏幕上的。也就说并没有提及WindowManagerService(以后称为WMS)，系统窗口服务。更加没有提及SurfaceFlinger这个系统渲染类。

Android的显示系统是一个十分大的体系。本文作为Android显示系统的第一篇，作为一个Android开发，时刻接触UI，我们有必要聊聊这个体系中，各个核心类的职责。

WMS是做什么的？WMS顾名思义就是系统的窗口管理者。

窗口是什么？从Activity用户交互界面角度看来，就是指应用的页面窗口。而从底层的SurfaceFlinger来看，WMS管理的每一个窗口都是一个可以从中获取到像素数据通过GPU/CPU渲染到屏幕的Layer。从WMS角度来看，每一个窗口都是一个WindowState，用于管理窗口状态。从每一个View来看，View的根布局存在一个ViewRootImpl，所有的view的渲染像素都保存在ViewRootImpl的Surface对象中。从I/O系统来看，WMS还必须响应触屏，键盘等事件的派发。

## WMS的启动
废话不多说，让我们先粗略的看看WMS的启动，我们能够从启动中窥探到WMS大致上控制了什么。还记的SystemServer启动的时候，我们初始化了很多服务吗，其中就有初始化WMS：
```java
 wm = WindowManagerService.main(context, inputManager,
                    mFactoryTestMode != FactoryTest.FACTORY_TEST_LOW_LEVEL,
                    !mFirstBoot, mOnlyCore, new PhoneWindowManager());
            ServiceManager.addService(Context.WINDOW_SERVICE, wm, /* allowIsolated= */ false,
                    DUMP_FLAG_PRIORITY_CRITICAL | DUMP_FLAG_PROTO);
            ServiceManager.addService(Context.INPUT_SERVICE, inputManager,
                    /* allowIsolated= */ false, DUMP_FLAG_PRIORITY_CRITICAL);
```
能看到此时WMS将会调用main方法，把InputManager(事件分发服务)传递到WMS中，并且生成了Window的窗口策略PhoneWindowManager。这个PhoneWindowManager实际上包含了计算窗口大小等策略，是一个核心类。

```java
    public static WindowManagerService main(final Context context, final InputManagerService im,
            final boolean haveInputMethods, final boolean showBootMsgs, final boolean onlyCore,
            WindowManagerPolicy policy) {
        DisplayThread.getHandler().runWithScissors(() ->
                sInstance = new WindowManagerService(context, im, haveInputMethods, showBootMsgs,
                        onlyCore, policy), 0);
        return sInstance;
    }
```
```java
private WindowManagerService(Context context, InputManagerService inputManager,
            boolean haveInputMethods, boolean showBootMsgs, boolean onlyCore,
            WindowManagerPolicy policy) {
        installLock(this, INDEX_WINDOW);
        mContext = context;
...
        LocalServices.getService(DisplayManagerInternal.class);
        mDisplaySettings = new DisplaySettings();
        mDisplaySettings.readSettingsLocked();

        mPolicy = policy;
        mAnimator = new WindowAnimator(this);
        mRoot = new RootWindowContainer(this);

        mWindowPlacerLocked = new WindowSurfacePlacer(this);
        mTaskSnapshotController = new TaskSnapshotController(this);

        mWindowTracing = WindowTracing.createDefaultAndStartLooper(context);

        LocalServices.addService(WindowManagerPolicy.class, mPolicy);

        if(mInputManager != null) {
            final InputChannel inputChannel = mInputManager.monitorInput(TAG_WM);
            mPointerEventDispatcher = inputChannel != null
                    ? new PointerEventDispatcher(inputChannel) : null;
        } else {
            mPointerEventDispatcher = null;
        }

        mDisplayManager = (DisplayManager)context.getSystemService(Context.DISPLAY_SERVICE);

        mKeyguardDisableHandler = new KeyguardDisableHandler(mContext, mPolicy);

        mPowerManager = (PowerManager)context.getSystemService(Context.POWER_SERVICE);
        mPowerManagerInternal = LocalServices.getService(PowerManagerInternal.class);

      ...
        mScreenFrozenLock = mPowerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "SCREEN_FROZEN");
        mScreenFrozenLock.setReferenceCounted(false);

        mAppTransition = new AppTransition(context, this);
        mAppTransition.registerListenerLocked(mActivityManagerAppTransitionNotifier);

        final AnimationHandler animationHandler = new AnimationHandler();
        animationHandler.setProvider(new SfVsyncFrameCallbackProvider());
        mBoundsAnimationController = new BoundsAnimationController(context, mAppTransition,
                AnimationThread.getHandler(), animationHandler);

        mActivityManager = ActivityManager.getService();
        mAmInternal = LocalServices.getService(ActivityManagerInternal.class);
        mAppOps = (AppOpsManager)context.getSystemService(Context.APP_OPS_SERVICE);
...

        mPmInternal = LocalServices.getService(PackageManagerInternal.class);
        final IntentFilter suspendPackagesFilter = new IntentFilter();
        ...

        // Get persisted window scale setting
      ...

        mSettingsObserver = new SettingsObserver();

        mHoldingScreenWakeLock = mPowerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ON_AFTER_RELEASE, TAG_WM);
        mHoldingScreenWakeLock.setReferenceCounted(false);

        mSurfaceAnimationRunner = new SurfaceAnimationRunner();

...
        mTaskPositioningController = new TaskPositioningController(
                this, mInputManager, mInputMonitor, mActivityManager, mH.getLooper());
        mDragDropController = new DragDropController(this, mH.getLooper());

        LocalServices.addService(WindowManagerInternal.class, new LocalService());
    }
```
能看到启动如下几个核心类。
- 1.WindowAnimator 窗口动画对象
- 2.RootWindowContainer 根部窗口容器，管理窗口上所有的子窗口
- 3.WindowSurfacePlacer 窗口大小大小测量者
- 4.AnimationHandler Window处理动画事件的Handler
- 5.PackageManagerInternal 包核心服务
- 6.DisplayManager 显示器管理者
- 7.PowerManager 电源管理者 
- 8.ActivityManager Activity操作相关的管理者


本文也将围绕RootWindowContainer 的父类WindowContainer 这个类进行讲解。

### 从WMS角度看Android显示体系的总览图
结合上面的构造函数，我这里弄出了一幅从WMS角度看Android系统的显示体系。
这里只是一个参考图，实际上在下面这幅图还有些不够准确。但是足以让人大致上了解到Android显示体系中，大体的研究方向，以及核心思想。

![从WMS看Android的显示体系.png](https://upload-images.jianshu.io/upload_images/9880421-123d24d7c51f1e12.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)




### WindowContainer与WindowContainerController
为了之后的逻辑能够更加轻易的整理。这边需要先理清楚WMS这两个核心类，WindowContainer,WindowContainerController。比起过去版本的Android系统(如4.4,7.0)，Android9.0在窗口管理体系上做了很大的努力的抽象。

> WindowContainer 在整个WMS中承担了所有可以看做Window容器的角色，其本身能够控制所有绑定进来的子WindowContainer。注意了，这里是指Window容器，而不是window本身。

> WindowContainerController 在整个WMS中承担着控制WindowContainer的角色。

下面是一个UML图
![WindowContainer大家族.png](https://upload-images.jianshu.io/upload_images/9880421-beffe3fa9c70150a.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到整个WMS几乎所有的核心操作需要核心类都在这里面了。

从名字我们就能窥探到在Activity启动流程中缺失的Window处理部分。也能从其泛型了解到每一个WindowContainer的关联。首先我们大致上来聊聊每一个WindowContainer的作用。

### WindowContainer
WindowContainer 作为每一个可以看做是Window的容器的抽象类。其核心作用就是提供共有的处理子WindowConatiner操作。其核心添加子WindowConatiner如下：
```java
protected final WindowList<E> mChildren = new WindowList<E>();


protected void addChild(E child, Comparator<E> comparator) {
        if (child.getParent() != null) {
            throw new IllegalArgumentException("addChild: container=" + child.getName()
                    + " is already a child of container=" + child.getParent().getName()
                    + " can't add to container=" + getName());
        }

        int positionToAdd = -1;
        if (comparator != null) {
            final int count = mChildren.size();
            for (int i = 0; i < count; i++) {
                if (comparator.compare(child, mChildren.get(i)) < 0) {
                    positionToAdd = i;
                    break;
                }
            }
        }

        if (positionToAdd == -1) {
            mChildren.add(child);
        } else {
            mChildren.add(positionToAdd, child);
        }
        onChildAdded(child);

        // Set the parent after we've actually added a child in case a subclass depends on this.
        child.setParent(this);
    }
```
能看到，在这个方法中，只要每一种Window容器都有自己的策略，通过这种策略调整插入的位置，最后才会进行插入子Window容器。并且获得父亲Window容器是什么。

实际上这种设计就是一个双向链表，只是更加的复杂。因此当WindowConatiner1实现的子类确定了什么泛型，说明这种WindowContainer控制的子WindowConatiner的类型也就确定了。

WindowContainer当然有其他重要的操作，这里先不聊。

#### DisplayContent
屏幕显示内容的WindowConatiner。其和逻辑显示屏幕id绑定在一起。一般的，我们应用程序是基于它之上创建的。
我们能够看到其泛型扩展的是DisplayChildWindowContainer:
```java
static class DisplayChildWindowContainer<E extends WindowContainer> extends WindowContainer<E> {

        DisplayChildWindowContainer(WindowManagerService service) {
            super(service);
        }

        @Override
        boolean fillsParent() {
            return true;
        }

        @Override
        boolean isVisible() {
            return true;
        }
    }
```
实现十分简单，DisplayContent必定是充满全父容器，且可见的。注意了，既然是代表的是逻辑上的显示屏那必定不可能存在子的显示屏，因此addChlid是禁止的：
```java
    @Override
    protected void addChild(DisplayChildWindowContainer child,
            Comparator<DisplayChildWindowContainer> comparator) {
        throw new UnsupportedOperationException("See DisplayChildWindowContainer");
    }

    @Override
    protected void addChild(DisplayChildWindowContainer child, int index) {
        throw new UnsupportedOperationException("See DisplayChildWindowContainer");
    }
```

了解这些不足够让我们对DisplayContent有一个粗略的了解，让我们看看构造函数:
```java
 DisplayContent(Display display, WindowManagerService service,
            WallpaperController wallpaperController, DisplayWindowController controller) {
        super(service);
        setController(controller);
        if (service.mRoot.getDisplayContent(display.getDisplayId()) != null) {
            throw new IllegalArgumentException("Display with ID=" + display.getDisplayId()
                    + " already exists=" + service.mRoot.getDisplayContent(display.getDisplayId())
                    + " new=" + display);
        }

        mDisplay = display;
        mDisplayId = display.getDisplayId();
        mWallpaperController = wallpaperController;
        display.getDisplayInfo(mDisplayInfo);
        display.getMetrics(mDisplayMetrics);
        isDefaultDisplay = mDisplayId == DEFAULT_DISPLAY;
        mDisplayFrames = new DisplayFrames(mDisplayId, mDisplayInfo,
                calculateDisplayCutoutForRotation(mDisplayInfo.rotation));
        initializeDisplayBaseInfo();
        mDividerControllerLocked = new DockedStackDividerController(service, this);
        mPinnedStackControllerLocked = new PinnedStackController(service, this);

        // We use this as our arbitrary surface size for buffer-less parents
        // that don't impose cropping on their children. It may need to be larger
        // than the display size because fullscreen windows can be shifted offscreen
        // due to surfaceInsets. 2 times the largest display dimension feels like an
        // appropriately arbitrary number. Eventually we would like to give SurfaceFlinger
        // layers the ability to match their parent sizes and be able to skip
        // such arbitrary size settings.
        mSurfaceSize = Math.max(mBaseDisplayHeight, mBaseDisplayWidth) * 2;

        final SurfaceControl.Builder b = mService.makeSurfaceBuilder(mSession)
                .setSize(mSurfaceSize, mSurfaceSize)
                .setOpaque(true);
        mWindowingLayer = b.setName("Display Root").build();
        mOverlayLayer = b.setName("Display Overlays").build();

        getPendingTransaction().setLayer(mWindowingLayer, 0)
                .setLayerStack(mWindowingLayer, mDisplayId)
                .show(mWindowingLayer)
                .setLayer(mOverlayLayer, 1)
                .setLayerStack(mOverlayLayer, mDisplayId)
                .show(mOverlayLayer);
        getPendingTransaction().apply();

        // These are the only direct children we should ever have and they are permanent.
        super.addChild(mBelowAppWindowsContainers, null);
        super.addChild(mTaskStackContainers, null);
        super.addChild(mAboveAppWindowsContainers, null);
        super.addChild(mImeWindowsContainers, null);

        // Add itself as a child to the root container.
        mService.mRoot.addChild(this, null);

        // TODO(b/62541591): evaluate whether this is the best spot to declare the
        // {@link DisplayContent} ready for use.
        mDisplayReady = true;
    }

    boolean isReady() {
        // The display is ready when the system and the individual display are both ready.
        return mService.mDisplayReady && mDisplayReady;
    }
```
此时能看到DisplayContent在构造函数中，首先会把相关的屏幕大小，密度，id等信息绑定。

接着实例化SurfaceControl这个对象。记住这个对象是核心，联通Window和Android渲染核心的类。

所有渲染像素都会保存在Surface中，因此这个实例化告诉Surface是，此时需要透明，并且此时渲染屏幕的大小公式为：Max（屏幕宽度，屏幕高度）*2。

在系统第一次生成Window的时候，Android系统并不希望裁减掉最初当前的显示范围。surfaceInsets代表着渲染的范围，此时其实充满屏幕的窗体能够移动。因此会选择最大尺寸*2，让窗体足够的控件显示。

包含了mWindowingLayer 和mOverlayLayer。OverLayer这些命名应该比较熟悉，实际上有点像View之上的Overlayer一样，为Window动画做铺垫。

##### DisplayContent控制的WindowContainer
接着会把如下几个WindowConatiner的添加到DisplayContent中:
- 1.mBelowAppWindowsContainers(类型NonAppWindowContainers)
一切的应该在Activity之下的Window容器，比如wrapper壁纸。

- 2.mTaskStackContainers(类型TaskStackContainers)
这里面一般是指应用的Activity。实际上也就是我们常说的Activity对应着整个系统栈的管理者

- 3.mAboveAppWindowsContainers(类型AboveAppWindowContainers)
这里是指一切在Activity之上的窗体容器，比如说StatusBar状态栏。

- 5.mImeWindowsContainers(类型NonMagnifiableWindowContainers)
这里是指如Dialog，输入键盘的窗体容器。

因此我能够依据顺序能够了解到，实际上在整个Android系统中，一旦开始绘制将会依照如下顺序进行绘制一个界面:
![系统窗体.png](https://upload-images.jianshu.io/upload_images/9880421-33a1fed7ec30fedb.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

最后统统添加到RootWindowContainer中。


当然既然有这些WindowContainer不可能不添加。这里替代掉addChild方法，一般使用addWindowToken来添加到对应的WindowConatiner中。关于addWindowToken详细会在之后聊到。


#### RootWindowContainer
RootWindowContainer 顾名思义，根部WindowContainer，一切WindowContainer的总管理者。其泛型确定了是DisplayContent。因此确切的说，这是专门用来管理逻辑显示屏幕对应区域的窗体容器。

当需要大范围的寻找子Window容器，可以通过RootWindowContainer 进行轮询查找。

### WindowToken
从名字上来看就知道这是一个句柄。这是一个关于Window的句柄。甚至可以推测WindowToken中肯定包含一个IBinder对象，来对应Android端的Window。具体这个IBinder是指哪一个，稍后就揭晓。

为了能够粗略的了解WindowToken，让我们先看看它的构造函数:
```java
    WindowToken(WindowManagerService service, IBinder _token, int type, boolean persistOnEmpty,
            DisplayContent dc, boolean ownerCanManageAppTokens, boolean roundedCornerOverlay) {
        super(service);
        token = _token;
        windowType = type;
        mPersistOnEmpty = persistOnEmpty;
        mOwnerCanManageAppTokens = ownerCanManageAppTokens;
        mRoundedCornerOverlay = roundedCornerOverlay;
        onDisplayChanged(dc);
    }
```

在这里面有一个核心的函数onDisplayChanged，当WindowToken生成了，说明应用端有一个新的Window诞生了，需要做addWindow到WindowManager的操作，此时需要告诉DisplayContent，窗体列表需要更新了。
```java
void onDisplayChanged(DisplayContent dc) {
        dc.reParentWindowToken(this);
        mDisplayContent = dc;

        // The rounded corner overlay should not be rotated. We ensure that by moving it outside
        // the windowing layer.
        if (mRoundedCornerOverlay) {
            mDisplayContent.reparentToOverlay(mPendingTransaction, mSurfaceControl);
        }

        // TODO(b/36740756): One day this should perhaps be hooked
        // up with goodToGo, so we don't move a window
        // to another display before the window behind
        // it is ready.

        super.onDisplayChanged(dc);
    }
```
##### WindowToken添加到DisplayContent中
此时调用了DisplayContent的reParentWindowToken方法,把当前的WindowToken绑定到DisplayContent中。

```java
/** Changes the display the input window token is housed on to this one. */
    void reParentWindowToken(WindowToken token) {
        final DisplayContent prevDc = token.getDisplayContent();
        if (prevDc == this) {
            return;
        }
        if (prevDc != null && prevDc.mTokenMap.remove(token.token) != null
                && token.asAppWindowToken() == null) {
            // Removed the token from the map, but made sure it's not an app token before removing
            // from parent.
            token.getParent().removeChild(token);
        }

        addWindowToken(token.token, token);
    }
```
此时一旦发现，如果这个WindowToken已经绑过了并且还呆在这个这个目标DisplayContent就没有必要继续添加。否则将会判断当前WindowToken是否已经绑定了父WindowContainer，把它从父WindowContainer移除出来。

接下来就是addWindowToken的逻辑。
```java
private void addWindowToken(IBinder binder, WindowToken token) {
        final DisplayContent dc = mService.mRoot.getWindowTokenDisplay(token);
        if (dc != null) {
            // We currently don't support adding a window token to the display if the display
            // already has the binder mapped to another token. If there is a use case for supporting
            // this moving forward we will either need to merge the WindowTokens some how or have
            // the binder map to a list of window tokens.
            throw new IllegalArgumentException("Can't map token=" + token + " to display="
                    + getName() + " already mapped to display=" + dc + " tokens=" + dc.mTokenMap);
        }
        if (binder == null) {
            throw new IllegalArgumentException("Can't map token=" + token + " to display="
                    + getName() + " binder is null");
        }
        if (token == null) {
            throw new IllegalArgumentException("Can't map null token to display="
                    + getName() + " binder=" + binder);
        }

        mTokenMap.put(binder, token);

        if (token.asAppWindowToken() == null) {
            // Add non-app token to container hierarchy on the display. App tokens are added through
            // the parent container managing them (e.g. Tasks).
            switch (token.windowType) {
                case TYPE_WALLPAPER:
                    mBelowAppWindowsContainers.addChild(token);
                    break;
                case TYPE_INPUT_METHOD:
                case TYPE_INPUT_METHOD_DIALOG:
                    mImeWindowsContainers.addChild(token);
                    break;
                default:
                    mAboveAppWindowsContainers.addChild(token);
                    break;
            }
        }
    }
```
首先会把所有的WindowToken添加到TokenMap中。这个数据结构很重要，后文会继续聊。

如果判断到这个WindowToken不是Activity对应的WindowToken根据WindowToken传进来的windowType来判断，如果是壁纸则添加到mBelowAppWindowsContainers，如果是输入法弹窗则添加到mImeWindowsContainers，剩下的如StatusBar添加到mAboveAppWindowsContainers。

此时的操作，是把所有游离的弹窗都收集到DisplayContent。毕竟无论是StatusBar，输入法还是壁纸都能够脱离Activity存在的。

而Activity对应的Window窗体又是什么时候添加的呢？这里先留给悬念。


#### AppWindowToken
从上面的WindowToken，我们能发现这么一个子类AppWindowToken。它实际上是专门指代Activity的Window。从源码的角度看来，就是指PhoneWindow对应到WMS的句柄对象。

我们还是粗略看看其构造函数

```java
AppWindowToken(WindowManagerService service, IApplicationToken token, boolean voiceInteraction,
            DisplayContent dc, long inputDispatchingTimeoutNanos, boolean fullscreen,
            boolean showForAllUsers, int targetSdk, int orientation, int rotationAnimationHint,
            int configChanges, boolean launchTaskBehind, boolean alwaysFocusable,
            AppWindowContainerController controller) {
        this(service, token, voiceInteraction, dc, fullscreen);
        setController(controller);
        mInputDispatchingTimeoutNanos = inputDispatchingTimeoutNanos;
        mShowForAllUsers = showForAllUsers;
        mTargetSdk = targetSdk;
        mOrientation = orientation;
        layoutConfigChanges = (configChanges & (CONFIG_SCREEN_SIZE | CONFIG_ORIENTATION)) != 0;
        mLaunchTaskBehind = launchTaskBehind;
        mAlwaysFocusable = alwaysFocusable;
        mRotationAnimationHint = rotationAnimationHint;

        // Application tokens start out hidden.
        setHidden(true);
        hiddenRequested = true;
    }

```

持有了一个IApplicationToken，判断该窗口隶属于哪个应用程序。此时传入了AppWindowContainerController 一个WindowConatinerController。这个将会控制着这个AppWindowToken。


当然这里需要和ActivityRecord区分对待，ActivityRecord是Acivity对应在AMS中的实例。而AppWindowToken是Activity窗体对应在WMS中的实例。

到了后面我们就能看到实际上ActivityRecord和AppWindowToken都通过一个IApplicationToken的Binder对象维系起来。

此时AppWindowToken会对应一个AppWindowContainerController 。

#### WindowState
WindowState实际上是WMS用来控制每一个Window的状态。里面包含了复杂的逻辑如计算当前窗体的大小，如控制Session的绑定等。详细的不展开，将会在后文聊到。

#### Task
Task这个名词让我们联想到Activity对应的栈。那么这个和TaskRecord又有什么区别呢?实际上我们我们仔细看Task的继承关系，Task是继承于WindowConatainer，确定了内部的泛型为AppWindowToken。
```java
class Task extends WindowContainer<AppWindowToken>
```

可以说，其本质上就是为了控制应用端Activity窗口对应的AppWindowToken的List集合。除此之外还包含了计算当前WindowContainer的边缘，大小，位置等。

让我们看看其构造函数：
```java
    Task(int taskId, TaskStack stack, int userId, WindowManagerService service, int resizeMode,
            boolean supportsPictureInPicture, TaskDescription taskDescription,
            TaskWindowContainerController controller) {
        super(service);
        mTaskId = taskId;
        mStack = stack;
        mUserId = userId;
        mResizeMode = resizeMode;
        mSupportsPictureInPicture = supportsPictureInPicture;
        setController(controller);
        setBounds(getOverrideBounds());
        mTaskDescription = taskDescription;

        // Tasks have no set orientation value (including SCREEN_ORIENTATION_UNSPECIFIED).
        setOrientation(SCREEN_ORIENTATION_UNSET);
    }
```
里面包含了当前Task的id。当前Task处于哪一个Task栈中，ActivityInfo对应的resizeMode，Task描述等等。

这里的Task和TaskRecord的关系其实就和AppWindowToken和ActivityRecord的关系一样。可以抽象的看成同一种对象在两种不同的服务的表现形式。

而TaskRecord和Task又是通过什么维系起来的呢？我们能够从构造函数中了解到，此时的Task和TaskRecord都有一个TaskId把两者联系起来。



#### TaskStack
TaskStack，从名字上看来，是一个Task的管理栈。从实现的角度来看其确定了泛型是Task。说明这是WMS管理Task的一个数据结构。当然每一个Stack都有自己的Id作为唯一的标识。

看看构造函数：
```java
   TaskStack(WindowManagerService service, int stackId, StackWindowController controller) {
        super(service);
        mStackId = stackId;
        setController(controller);
        mDockedStackMinimizeThickness = service.mContext.getResources().getDimensionPixelSize(
                com.android.internal.R.dimen.docked_stack_minimize_thickness);
        EventLog.writeEvent(EventLogTags.WM_STACK_CREATED, stackId);
    }
```
能够看到此时TaskStack又会对应一个StackId，对应一个Window容器控制者，StackWindowController 。


### WindowContainerController
作为WindowContainer的控制者。实际上其应用场景在Activity启动中十分广泛。

从上面的WindowConatiner，我们能够知道每一个WindowContainerController和WindowContainer都有如下的控制关系。

![WindowContainer和WindowContainerController关系.png](https://upload-images.jianshu.io/upload_images/9880421-7b5933aa10b2ade9.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

为了更加深刻的理解这几个数据结构，让我们也稍微过一下这些控制者们。

首先来看看所有窗体容器控制者的父类，WindowContainerController.

#### WindowContainerController
这个类很简单，直接放出整个类出来:
```java
class WindowContainerController<E extends WindowContainer, I extends WindowContainerListener>
        implements ConfigurationContainerListener {

    final WindowManagerService mService;
    final RootWindowContainer mRoot;
    final WindowHashMap mWindowMap;

    // The window container this controller owns.
    E mContainer;
    // Interface for communicating changes back to the owner.
    final I mListener;

    WindowContainerController(I listener, WindowManagerService service) {
        mListener = listener;
        mService = service;
        mRoot = mService != null ? mService.mRoot : null;
        mWindowMap = mService != null ? mService.mWindowMap : null;
    }

    void setContainer(E container) {
        if (mContainer != null && container != null) {
            throw new IllegalArgumentException("Can't set container=" + container
                    + " for controller=" + this + " Already set to=" + mContainer);
        }
        mContainer = container;
        if (mContainer != null && mListener != null) {
            mListener.registerConfigurationChangeListener(this);
        }
    }

    void removeContainer() {
        // TODO: See if most uses cases should support removeIfPossible here.
        //mContainer.removeIfPossible();
        if (mContainer == null) {
            return;
        }

        mContainer.setController(null);
        mContainer = null;
        if (mListener != null) {
            mListener.unregisterConfigurationChangeListener(this);
        }
    }

    @Override
    public void onOverrideConfigurationChanged(Configuration overrideConfiguration) {
        synchronized (mWindowMap) {
            if (mContainer == null) {
                return;
            }
            mContainer.onOverrideConfigurationChanged(overrideConfiguration);
        }
    }
}

```

从这个Controller，我们能够了解到，他的父类在构造函数的时候，会把RootWindowContainer传进来。并且传入mWindowMap这个Map数据结构。记住这个mWindowMap数据结构，它的重要性和上面的mTokenMap一样。

接着就能知道Controller每一次只会控制一个WindowContainer，只会监听当前WindowConatainer回调的onOverrideConfigurationChanged。

####  AppWindowContainerController 
从类的继承关系看来:
```java
public class AppWindowContainerController
        extends WindowContainerController<AppWindowToken, AppWindowContainerListener>
```
能从确定的泛型看到这个控制者，从父类角度来看，监听的AppWindowToken中回调AppWindowContainerListener。同时控制着AppWindowToken。究竟怎么控制，看看构造函数就清楚了。

```java
    public AppWindowContainerController(TaskWindowContainerController taskController,
            IApplicationToken token, AppWindowContainerListener listener, int index,
            int requestedOrientation, boolean fullscreen, boolean showForAllUsers, int configChanges,
            boolean voiceInteraction, boolean launchTaskBehind, boolean alwaysFocusable,
            int targetSdkVersion, int rotationAnimationHint, long inputDispatchingTimeoutNanos,
            WindowManagerService service) {
        super(listener, service);
        mHandler = new H(service.mH.getLooper());
        mToken = token;
        synchronized(mWindowMap) {
            AppWindowToken atoken = mRoot.getAppWindowToken(mToken.asBinder());
            if (atoken != null) {
                // TODO: Should this throw an exception instead?
                Slog.w(TAG_WM, "Attempted to add existing app token: " + mToken);
                return;
            }

            final Task task = taskController.mContainer;
            if (task == null) {
                throw new IllegalArgumentException("AppWindowContainerController: invalid "
                        + " controller=" + taskController);
            }

            atoken = createAppWindow(mService, token, voiceInteraction, task.getDisplayContent(),
                    inputDispatchingTimeoutNanos, fullscreen, showForAllUsers, targetSdkVersion,
                    requestedOrientation, rotationAnimationHint, configChanges, launchTaskBehind,
                    alwaysFocusable, this);
            if (DEBUG_TOKEN_MOVEMENT || DEBUG_ADD_REMOVE) Slog.v(TAG_WM, "addAppToken: " + atoken
                    + " controller=" + taskController + " at " + index);
            task.addChild(atoken, index);
        }
    }

```

从构造函数中就能看到如下逻辑：
- 1.首先会根据ActivityRecord中的IApplicationToken去RootWindContainer中查找有没有对应的AppWindowToken.如果这个窗口本身存在，那么必定会存在，不存在说明Activity在创建，需要调用createAppWindow 方法创建一个AppWindowToken对应上来。

但是AppWindowToken和ActivityRecord一样，数据结构上必须相似，也就说会跟着Task。如果找不到Task，说明此时是非法。找到则会通过Task的addChlid的方法添加到从构造函数传下来的位置。


#### TaskWindowContainerController 
相似的，看看Task的窗体管理者的构造函数:
```java
public TaskWindowContainerController(int taskId, TaskWindowContainerListener listener,
            StackWindowController stackController, int userId, Rect bounds, int resizeMode,
            boolean supportsPictureInPicture, boolean toTop, boolean showForAllUsers,
            TaskDescription taskDescription, WindowManagerService service) {
        super(listener, service);
        mTaskId = taskId;
        mHandler = new H(new WeakReference<>(this), service.mH.getLooper());

        synchronized(mWindowMap) {
            if (DEBUG_STACK) Slog.i(TAG_WM, "TaskWindowContainerController: taskId=" + taskId
                    + " stack=" + stackController + " bounds=" + bounds);

            final TaskStack stack = stackController.mContainer;
            if (stack == null) {
                throw new IllegalArgumentException("TaskWindowContainerController: invalid stack="
                        + stackController);
            }
            EventLog.writeEvent(WM_TASK_CREATED, taskId, stack.mStackId);
            final Task task = createTask(taskId, stack, userId, resizeMode,
                    supportsPictureInPicture, taskDescription);
            final int position = toTop ? POSITION_TOP : POSITION_BOTTOM;
            // We only want to move the parents to the parents if we are creating this task at the
            // top of its stack.
            stack.addTask(task, position, showForAllUsers, toTop /* moveParents */);
        }
    }
```
其逻辑和AppWindowContainerController很相似，每一个Task中都会添加到一个TaskStack中。Task的生成将会由TaskWindowContainerController的createTask控制。

#### StackWindowController 

同样的，看看StackWindowController 作为最顶层的数据结构，窗体又是怎么控制的。
```java
    public StackWindowController(int stackId, StackWindowListener listener,
            int displayId, boolean onTop, Rect outBounds, WindowManagerService service) {
        super(listener, service);
        mStackId = stackId;
        mHandler = new H(new WeakReference<>(this), service.mH.getLooper());

        synchronized (mWindowMap) {
            final DisplayContent dc = mRoot.getDisplayContent(displayId);
            if (dc == null) {
                throw new IllegalArgumentException("Trying to add stackId=" + stackId
                        + " to unknown displayId=" + displayId);
            }

            dc.createStack(stackId, onTop, this);
            getRawBounds(outBounds);
        }
    }
```

能看到的是，只要调用了StackWindowController构造函数，就必定根据当前的传入的stackId，尝试着通过DisplayContent创建一个Stack出来。

因此我们看看DisplayContent中的方法。
##### DisplayContent.createStack
文件:[http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/DisplayContent.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/DisplayContent.java)
```java
    TaskStack createStack(int stackId, boolean onTop, StackWindowController controller) {
        if (DEBUG_STACK) Slog.d(TAG_WM, "Create new stackId=" + stackId + " on displayId="
                + mDisplayId);

        final TaskStack stack = new TaskStack(mService, stackId, controller);
        mTaskStackContainers.addStackToDisplay(stack, onTop);
        return stack;
    }
```
此时就能看到了，这个时候将会生成一个TaskStack的对象。不过令我吃惊的是，居然没有对同一个StackId的情况做处理。这个地方虽然不太可能出现相同id的TaskStack，不过感觉还是不够严谨。


还记得我上面在addWindowToken中说过的话吗？addWindowToken只是处理游离在Activity外面的Window，如壁纸和输入法弹窗。而Activity相关的Window实际上是借由Stack生成的时候，把TaskStack这个WindowContainer添加到DisplayContent的内部类TaskStackContainers这个WindowContainer中。

实际上TaskStackContainers源码上的注释并不是很准确，实际上管理不光光只是Activity，而是管理着TaskStack这个总管理者。


我们稍微看看TaskStackContainers这个类。


#### TaskStackContainers
```java
private final class TaskStackContainers extends DisplayChildWindowContainer<TaskStack>
```
我们能够看到DisplayContent内部类TaskStackContainers 也是继承了DisplayChildWindowContainer。换句话说，实际上包含了上面的WindowContainer控制子WindowContainer的操作。

```java
void addStackToDisplay(TaskStack stack, boolean onTop) {
            addStackReferenceIfNeeded(stack);
            addChild(stack, onTop);
            stack.onDisplayChanged(DisplayContent.this);
        }

```

在添加的时候，我们看看addStackReferenceIfNeeded方法：
```java
private void addStackReferenceIfNeeded(TaskStack stack) {
            if (stack.isActivityTypeHome()) {
                if (mHomeStack != null) {
                    throw new IllegalArgumentException("addStackReferenceIfNeeded: home stack="
                            + mHomeStack + " already exist on display=" + this + " stack=" + stack);
                }
                mHomeStack = stack;
            }
            final int windowingMode = stack.getWindowingMode();
            if (windowingMode == WINDOWING_MODE_PINNED) {
                if (mPinnedStack != null) {
                    throw new IllegalArgumentException("addStackReferenceIfNeeded: pinned stack="
                            + mPinnedStack + " already exist on display=" + this
                            + " stack=" + stack);
                }
                mPinnedStack = stack;
            } else if (windowingMode == WINDOWING_MODE_SPLIT_SCREEN_PRIMARY) {
                if (mSplitScreenPrimaryStack != null) {
                    throw new IllegalArgumentException("addStackReferenceIfNeeded:"
                            + " split-screen-primary" + " stack=" + mSplitScreenPrimaryStack
                            + " already exist on display=" + this + " stack=" + stack);
                }
                mSplitScreenPrimaryStack = stack;
                mDividerControllerLocked.notifyDockedStackExistsChanged(true);
            }
        }
```

能够很轻易的发现，此时在TaskStackContainers 中会控制着当前逻辑屏幕主要的Stack，如Home，分屏等。这样就佐证了，实际上DisplayContent确实代表着逻辑显示屏幕。如果不是分屏的情况下，则会只有一个DisplayContent，也只有一个TaskStackContainers 。这个TaskContainer会控制着应用各个窗口的栈。

## 总结
根据上面WindowContainer之间的关系，WindowContainerController和WindowContainer之间的关系，我们能够构造出下面这个关系。

先来看看WindowContainer之间的关系：
![WindowContainer之间的联系.png](https://upload-images.jianshu.io/upload_images/9880421-f5b5f8a803d4b9ca.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


因为WMS的窗体管理体系在Android9.0比起Android4.4,7.0来说抽象出了不少的对象，如果事先没有先对这些对象有一定了解，直接冲到源码里面阅读一定会晕头转向。


如果仅仅只是阅读我的Activity的启动流程一文，一定会感觉到意犹未尽，甚至越来越糊涂，因为上一个系列并没有涉及到窗口相关的内容。

相信就算是看到这些WindowContainer的工作原理，大体上已经对WMS的工作有一点了解。只剩下把这些线索串起来，下一篇文章将会走一遍核心流程，看看WMS究竟是怎么在Activity启动流程中增加Window，把这些线索串起来，把Activity的启动流程串起来，相信会有不一样的理解。

## 后话
实际上，我阅读Android的显示体系已经花了挺久时间的，阅读到了底层更是需要对OpenGL es有一定的了解。一直没有多少把握写好Android显示体系的文章。因为涉及面实在太多了，有时候一个点看不太懂一看就是一个星期。WMS相对底层来说，就显得十分的可爱，没有c/c++那样的艰涩难懂。

当然，如果你对OpenGL es没有多少了解也没关系，可以跟着我写的OpenGL学习笔记一起学习一些基本的OpenGL，相信你会有不少收获。

