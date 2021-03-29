---
title: Android 重学系列 View的绘制流程(二) 绘制的准备
top: false
cover: false
date: 2020-05-16 17:45:41
img:
tag:
description:
author: yjy239
summary:
categories: View的绘制流程
tags: 
- Android
- Android Framework
---

# 前言
经过对SurfaceFlinger，SurfaceView的源码的阅读后。这里我们接着这一篇文章[View的初始化](https://www.jianshu.com/p/003dc36af9db)继续来聊聊View的绘制流程。View的绘制流程总所周知有三步骤，onMeasure，onLayout，onDraw。本文就来聊聊onMeasure相关的知识点。

然而在这个步骤之前还有比较重要的准备步骤，onAttachWindow （View绑定窗口的绘制信息）以及onApplyWindowInsets(分发窗体的间距消费)，硬件渲染的准备。当View剥离出View树进行销毁，就会调用onDetachWindow周期。

本文就围绕准备绘制的前三点进行分析。

# 正文
当通过setContentView完成了View的实例化后，此时执行完了Activity的onCreate生命周期。就会走到onResume生命周期中。


在Activity的onResume回调处理后，会继续回到ActivityThread的handleResumeActivity方法。handleResumeActivity将会调用WM的addView的方法。接下来的流程，我在WMS系列文章中有和大家详细的聊过，建议阅读这一篇文章：[WMS在Activity启动中的职责 添加窗体(三)](https://www.jianshu.com/p/157e8bbfa45a)。

其中的核心就是调用ViewRootImpl的setView方法。在聊ViewRootImpl的setView方法之前，ViewRootImpl这个类中有一个类View.AttachInfo贯穿了整个View绘制的逻辑，我们先来看看。

### View.AttachInfo
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)
```java
/**
     * A set of information given to a view when it is attached to its parent
     * window.
     */
    final static class AttachInfo {
        interface Callbacks {
            void playSoundEffect(int effectId);
            boolean performHapticFeedback(int effectId, boolean always);
        }

        /**
         * InvalidateInfo is used to post invalidate(int, int, int, int) messages
         * to a Handler. This class contains the target (View) to invalidate and
         * the coordinates of the dirty rectangle.
         *
         * For performance purposes, this class also implements a pool of up to
         * POOL_LIMIT objects that get reused. This reduces memory allocations
         * whenever possible.
         */
        static class InvalidateInfo {
            private static final int POOL_LIMIT = 10;

            private static final SynchronizedPool<InvalidateInfo> sPool =
                    new SynchronizedPool<InvalidateInfo>(POOL_LIMIT);

            View target;

            int left;
            int top;
            int right;
            int bottom;

            public static InvalidateInfo obtain() {
                InvalidateInfo instance = sPool.acquire();
                return (instance != null) ? instance : new InvalidateInfo();
            }

            public void recycle() {
                target = null;
                sPool.release(this);
            }
        }

        final IWindowSession mSession;

        final IWindow mWindow;

        final IBinder mWindowToken;

        Display mDisplay;

        final Callbacks mRootCallbacks;

        IWindowId mIWindowId;
        WindowId mWindowId;

        /**
         * The top view of the hierarchy.
         */
        View mRootView;

        IBinder mPanelParentWindowToken;

        boolean mHardwareAccelerated;
        boolean mHardwareAccelerationRequested;
        ThreadedRenderer mThreadedRenderer;
        List<RenderNode> mPendingAnimatingRenderNodes;

        /**
         * The state of the display to which the window is attached, as reported
         * by {@link Display#getState()}.  Note that the display state constants
         * declared by {@link Display} do not exactly line up with the screen state
         * constants declared by {@link View} (there are more display states than
         * screen states).
         */
        int mDisplayState = Display.STATE_UNKNOWN;

        /**
         * Scale factor used by the compatibility mode
         */
        float mApplicationScale;

        /**
         * Indicates whether the application is in compatibility mode
         */
        boolean mScalingRequired;

        /**
         * Left position of this view's window
         */
        int mWindowLeft;

        /**
         * Top position of this view's window
         */
        int mWindowTop;

        /**
         * Indicates whether views need to use 32-bit drawing caches
         */
        boolean mUse32BitDrawingCache;

        /**
         * For windows that are full-screen but using insets to layout inside
         * of the screen areas, these are the current insets to appear inside
         * the overscan area of the display.
         */
        final Rect mOverscanInsets = new Rect();

        /**
         * For windows that are full-screen but using insets to layout inside
         * of the screen decorations, these are the current insets for the
         * content of the window.
         */
        final Rect mContentInsets = new Rect();

        /**
         * For windows that are full-screen but using insets to layout inside
         * of the screen decorations, these are the current insets for the
         * actual visible parts of the window.
         */
        final Rect mVisibleInsets = new Rect();

        /**
         * For windows that are full-screen but using insets to layout inside
         * of the screen decorations, these are the current insets for the
         * stable system windows.
         */
        final Rect mStableInsets = new Rect();

        final DisplayCutout.ParcelableWrapper mDisplayCutout =
                new DisplayCutout.ParcelableWrapper(DisplayCutout.NO_CUTOUT);

        /**
         * For windows that include areas that are not covered by real surface these are the outsets
         * for real surface.
         */
        final Rect mOutsets = new Rect();

        /**
         * In multi-window we force show the navigation bar. Because we don't want that the surface
         * size changes in this mode, we instead have a flag whether the navigation bar size should
         * always be consumed, so the app is treated like there is no virtual navigation bar at all.
         */
        boolean mAlwaysConsumeNavBar;

        /**
         * The internal insets given by this window.  This value is
         * supplied by the client (through
         * {@link ViewTreeObserver.OnComputeInternalInsetsListener}) and will
         * be given to the window manager when changed to be used in laying
         * out windows behind it.
         */
        final ViewTreeObserver.InternalInsetsInfo mGivenInternalInsets
                = new ViewTreeObserver.InternalInsetsInfo();

        /**
         * Set to true when mGivenInternalInsets is non-empty.
         */
        boolean mHasNonEmptyGivenInternalInsets;

        /**
         * All views in the window's hierarchy that serve as scroll containers,
         * used to determine if the window can be resized or must be panned
         * to adjust for a soft input area.
         */
        final ArrayList<View> mScrollContainers = new ArrayList<View>();

        final KeyEvent.DispatcherState mKeyDispatchState
                = new KeyEvent.DispatcherState();

        /**
         * Indicates whether the view's window currently has the focus.
         */
        boolean mHasWindowFocus;

        /**
         * The current visibility of the window.
         */
        int mWindowVisibility;

        /**
         * Indicates the time at which drawing started to occur.
         */
        long mDrawingTime;

        /**
         * Indicates whether or not ignoring the DIRTY_MASK flags.
         */
        boolean mIgnoreDirtyState;

        /**
         * This flag tracks when the mIgnoreDirtyState flag is set during draw(),
         * to avoid clearing that flag prematurely.
         */
        boolean mSetIgnoreDirtyState = false;

        /**
         * Indicates whether the view's window is currently in touch mode.
         */
        boolean mInTouchMode;

        /**
         * Indicates whether the view has requested unbuffered input dispatching for the current
         * event stream.
         */
        boolean mUnbufferedDispatchRequested;

        /**
         * Indicates that ViewAncestor should trigger a global layout change
         * the next time it performs a traversal
         */
        boolean mRecomputeGlobalAttributes;

        /**
         * Always report new attributes at next traversal.
         */
        boolean mForceReportNewAttributes;

        /**
         * Set during a traveral if any views want to keep the screen on.
         */
        boolean mKeepScreenOn;

        /**
         * Set during a traveral if the light center needs to be updated.
         */
        boolean mNeedsUpdateLightCenter;

        /**
         * Bitwise-or of all of the values that views have passed to setSystemUiVisibility().
         */
        int mSystemUiVisibility;

        /**
         * Hack to force certain system UI visibility flags to be cleared.
         */
        int mDisabledSystemUiVisibility;

        /**
         * Last global system UI visibility reported by the window manager.
         */
        int mGlobalSystemUiVisibility = -1;

        /**
         * True if a view in this hierarchy has an OnSystemUiVisibilityChangeListener
         * attached.
         */
        boolean mHasSystemUiListeners;

        /**
         * Set if the window has requested to extend into the overscan region
         * via WindowManager.LayoutParams.FLAG_LAYOUT_IN_OVERSCAN.
         */
        boolean mOverscanRequested;

        /**
         * Set if the visibility of any views has changed.
         */
        boolean mViewVisibilityChanged;

        /**
         * Set to true if a view has been scrolled.
         */
        boolean mViewScrollChanged;

        /**
         * Set to true if a pointer event is currently being handled.
         */
        boolean mHandlingPointerEvent;

        /**
         * Global to the view hierarchy used as a temporary for dealing with
         * x/y points in the transparent region computations.
         */
        final int[] mTransparentLocation = new int[2];

        /**
         * Global to the view hierarchy used as a temporary for dealing with
         * x/y points in the ViewGroup.invalidateChild implementation.
         */
        final int[] mInvalidateChildLocation = new int[2];

        /**
         * Global to the view hierarchy used as a temporary for dealing with
         * computing absolute on-screen location.
         */
        final int[] mTmpLocation = new int[2];

        /**
         * Global to the view hierarchy used as a temporary for dealing with
         * x/y location when view is transformed.
         */
        final float[] mTmpTransformLocation = new float[2];

        /**
         * The view tree observer used to dispatch global events like
         * layout, pre-draw, touch mode change, etc.
         */
        final ViewTreeObserver mTreeObserver;

        /**
         * A Canvas used by the view hierarchy to perform bitmap caching.
         */
        Canvas mCanvas;

        /**
         * The view root impl.
         */
        final ViewRootImpl mViewRootImpl;

        /**
         * A Handler supplied by a view's {@link android.view.ViewRootImpl}. This
         * handler can be used to pump events in the UI events queue.
         */
        final Handler mHandler;

        /**
         * Temporary for use in computing invalidate rectangles while
         * calling up the hierarchy.
         */
        final Rect mTmpInvalRect = new Rect();

        /**
         * Temporary for use in computing hit areas with transformed views
         */
        final RectF mTmpTransformRect = new RectF();

        /**
         * Temporary for use in computing hit areas with transformed views
         */
        final RectF mTmpTransformRect1 = new RectF();

        /**
         * Temporary list of rectanges.
         */
        final List<RectF> mTmpRectList = new ArrayList<>();

        /**
         * Temporary for use in transforming invalidation rect
         */
        final Matrix mTmpMatrix = new Matrix();

        /**
         * Temporary for use in transforming invalidation rect
         */
        final Transformation mTmpTransformation = new Transformation();

        /**
         * Temporary for use in querying outlines from OutlineProviders
         */
        final Outline mTmpOutline = new Outline();

        /**
         * Temporary list for use in collecting focusable descendents of a view.
         */
        final ArrayList<View> mTempArrayList = new ArrayList<View>(24);

        /**
         * The id of the window for accessibility purposes.
         */
        int mAccessibilityWindowId = AccessibilityWindowInfo.UNDEFINED_WINDOW_ID;

        /**
         * Flags related to accessibility processing.
         *
         * @see AccessibilityNodeInfo#FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
         * @see AccessibilityNodeInfo#FLAG_REPORT_VIEW_IDS
         */
        int mAccessibilityFetchFlags;

        /**
         * The drawable for highlighting accessibility focus.
         */
        Drawable mAccessibilityFocusDrawable;

        /**
         * The drawable for highlighting autofilled views.
         *
         * @see #isAutofilled()
         */
        Drawable mAutofilledDrawable;

        /**
         * Show where the margins, bounds and layout bounds are for each view.
         */
        boolean mDebugLayout = SystemProperties.getBoolean(DEBUG_LAYOUT_PROPERTY, false);

        /**
         * Point used to compute visible regions.
         */
        final Point mPoint = new Point();

        /**
         * Used to track which View originated a requestLayout() call, used when
         * requestLayout() is called during layout.
         */
        View mViewRequestingLayout;

        /**
         * Used to track views that need (at least) a partial relayout at their current size
         * during the next traversal.
         */
        List<View> mPartialLayoutViews = new ArrayList<>();

        /**
         * Swapped with mPartialLayoutViews during layout to avoid concurrent
         * modification. Lazily assigned during ViewRootImpl layout.
         */
        List<View> mEmptyPartialLayoutViews;

        /**
         * Used to track the identity of the current drag operation.
         */
        IBinder mDragToken;

        /**
         * The drag shadow surface for the current drag operation.
         */
        public Surface mDragSurface;


        /**
         * The view that currently has a tooltip displayed.
         */
        View mTooltipHost;

        /**
         * Creates a new set of attachment information with the specified
         * events handler and thread.
         *
         * @param handler the events handler the view must use
         */
        AttachInfo(IWindowSession session, IWindow window, Display display,
                ViewRootImpl viewRootImpl, Handler handler, Callbacks effectPlayer,
                Context context) {
            mSession = session;
            mWindow = window;
            mWindowToken = window.asBinder();
            mDisplay = display;
            mViewRootImpl = viewRootImpl;
            mHandler = handler;
            mRootCallbacks = effectPlayer;
            mTreeObserver = new ViewTreeObserver(context);
        }
    }
```
AttachInfo实际上就是整个Android Framework在进行View绘制流程中绑定的一个全局的信息。它决定了整个Android整个View 树该怎么渲染。
下面介绍一下核心的属性：

- 1.Callbacks 内部接口，实现者是ViewRootImpl，能发出一些简单的按键声响
- 2.InvalidateInfo 内部类。这个类记录了整个View树哪一部分是脏区，需要进行刷新的部分。
- 3.IWindowSession mSession 一个WindowSession对象，联通了IMS，WMS等服务。是一个面向服务的门面操作者。
- 4.IWindow mWindow 对应WMS的客户端，也就是一个跨进程通信的Window对象
- 5.IBinder mWindowToken 当前AttachInfo对应Window的Token。这个句柄会在WMS有对应的记录。
- 6.Display mDisplay 通过DisplayManager获取的对象，里面记录了屏幕属性。
- 7.View mRootView 整个View树的根布局
- 8.boolean mHardwareAccelerated 是否需要硬件加速
- 9.ThreadedRenderer mThreadedRenderer 硬件渲染的核心对象
- 10.mDisplayState 当前屏幕的状态，如果状态发生了变更，ViewRootImpl也同时需要变更。
- 11.mApplicationScale 根据Display对象来判断，当前的View绘制过程中是否需要进行放大。
- 12.mWindowLeft等 当前AttachInfo对应的View所对应的Window的坐标
- 13.mUse32BitDrawingCache 绘制是否使用32位缓存
- 14.mOverscanInsets，mContentInsets，mVisibleInsets 等Insect，这些就是之前WMS第四篇文章聊过的，过扫描区域，内容区域，可视区域等
- 15.boolean mAlwaysConsumeNavBar 这个标志位一半是多窗口显示的时候告诉Android系统不需要一直显示导航栏
- 16.mScrollContainers 那些可以滚动的View，或者可以因为软键盘变化平移的View
- 17.mHasWindowFocus 该窗口是否有焦点
- 18.mInTouchMode 该View是否是touch mode
- 19.mKeepScreenOn 刷新的时候，是否保持屏幕点亮
- 20.mSystemUiVisibility 系统的ui如statusBar等是否显示
- 21.ViewTreeObserver mTreeObserver 监听View树的绘制
- 22.Canvas mCanvas; 用于View 树的bitmap的缓存

差不多这些就够了。能看到这些所有的信息都是View在绘制流程中需要注意的。

## ViewRootImpl setView
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)
```java
    public void setView(View view, WindowManager.LayoutParams attrs, View panelParentView) {
        synchronized (this) {
            if (mView == null) {
                mView = view;

                mAttachInfo.mDisplayState = mDisplay.getState();
                mDisplayManager.registerDisplayListener(mDisplayListener, mHandler);

                mViewLayoutDirectionInitial = mView.getRawLayoutDirection();
                mFallbackEventHandler.setView(view);
                mWindowAttributes.copyFrom(attrs);
                if (mWindowAttributes.packageName == null) {
                    mWindowAttributes.packageName = mBasePackageName;
                }
                attrs = mWindowAttributes;
                setTag();


                // Keep track of the actual window flags supplied by the client.
                mClientWindowLayoutFlags = attrs.flags;

                setAccessibilityFocus(null, null);

                if (view instanceof RootViewSurfaceTaker) {
                    mSurfaceHolderCallback =
                            ((RootViewSurfaceTaker)view).willYouTakeTheSurface();
                    if (mSurfaceHolderCallback != null) {
                        mSurfaceHolder = new TakenSurfaceHolder();
                        mSurfaceHolder.setFormat(PixelFormat.UNKNOWN);
                        mSurfaceHolder.addCallback(mSurfaceHolderCallback);
                    }
                }

                // Compute surface insets required to draw at specified Z value.
                // TODO: Use real shadow insets for a constant max Z.
                if (!attrs.hasManualSurfaceInsets) {
                    attrs.setSurfaceInsets(view, false /*manual*/, true /*preservePrevious*/);
                }

                CompatibilityInfo compatibilityInfo =
                        mDisplay.getDisplayAdjustments().getCompatibilityInfo();
                mTranslator = compatibilityInfo.getTranslator();

                // If the application owns the surface, don't enable hardware acceleration
                if (mSurfaceHolder == null) {
                    // While this is supposed to enable only, it can effectively disable
                    // the acceleration too.
                    enableHardwareAcceleration(attrs);
                    final boolean useMTRenderer = MT_RENDERER_AVAILABLE
                            && mAttachInfo.mThreadedRenderer != null;
                    if (mUseMTRenderer != useMTRenderer) {
                        // Shouldn't be resizing, as it's done only in window setup,
                        // but end just in case.
                        endDragResizing();
                        mUseMTRenderer = useMTRenderer;
                    }
                }

                boolean restore = false;
                if (mTranslator != null) {
                    mSurface.setCompatibilityTranslator(mTranslator);
                    restore = true;
                    attrs.backup();
                    mTranslator.translateWindowLayout(attrs);
                }

                if (!compatibilityInfo.supportsScreen()) {
                    attrs.privateFlags |= WindowManager.LayoutParams.PRIVATE_FLAG_COMPATIBLE_WINDOW;
                    mLastInCompatMode = true;
                }

                mSoftInputMode = attrs.softInputMode;
                mWindowAttributesChanged = true;
                mWindowAttributesChangesFlag = WindowManager.LayoutParams.EVERYTHING_CHANGED;
                mAttachInfo.mRootView = view;
                mAttachInfo.mScalingRequired = mTranslator != null;
                mAttachInfo.mApplicationScale =
                        mTranslator == null ? 1.0f : mTranslator.applicationScale;
                if (panelParentView != null) {
                    mAttachInfo.mPanelParentWindowToken
                            = panelParentView.getApplicationWindowToken();
                }
                mAdded = true;
                int res; /* = WindowManagerImpl.ADD_OKAY; */

                // Schedule the first layout -before- adding to the window
                // manager, to make sure we do the relayout before receiving
                // any other events from the system.
                requestLayout();
                if ((mWindowAttributes.inputFeatures
                        & WindowManager.LayoutParams.INPUT_FEATURE_NO_INPUT_CHANNEL) == 0) {
                    mInputChannel = new InputChannel();
                }
                mForceDecorViewVisibility = (mWindowAttributes.privateFlags
                        & PRIVATE_FLAG_FORCE_DECOR_VIEW_VISIBILITY) != 0;
                try {
                    mOrigWindowType = mWindowAttributes.type;
                    mAttachInfo.mRecomputeGlobalAttributes = true;
                    collectViewAttributes();
                    res = mWindowSession.addToDisplay(mWindow, mSeq, mWindowAttributes,
                            getHostVisibility(), mDisplay.getDisplayId(), mWinFrame,
                            mAttachInfo.mContentInsets, mAttachInfo.mStableInsets,
                            mAttachInfo.mOutsets, mAttachInfo.mDisplayCutout, mInputChannel);
                } catch (RemoteException e) {
                    mAdded = false;
                    mView = null;
                    mAttachInfo.mRootView = null;
                    mInputChannel = null;
                    mFallbackEventHandler.setView(null);
                    unscheduleTraversals();
                    setAccessibilityFocus(null, null);
                    throw new RuntimeException("Adding window failed", e);
                } finally {
                    if (restore) {
                        attrs.restore();
                    }
                }

                if (mTranslator != null) {
                    mTranslator.translateRectInScreenToAppWindow(mAttachInfo.mContentInsets);
                }
                mPendingOverscanInsets.set(0, 0, 0, 0);
                mPendingContentInsets.set(mAttachInfo.mContentInsets);
                mPendingStableInsets.set(mAttachInfo.mStableInsets);
                mPendingDisplayCutout.set(mAttachInfo.mDisplayCutout);
                mPendingVisibleInsets.set(0, 0, 0, 0);
                mAttachInfo.mAlwaysConsumeNavBar =
                        (res & WindowManagerGlobal.ADD_FLAG_ALWAYS_CONSUME_NAV_BAR) != 0;
                mPendingAlwaysConsumeNavBar = mAttachInfo.mAlwaysConsumeNavBar;
                if (res < WindowManagerGlobal.ADD_OKAY) {
                    mAttachInfo.mRootView = null;
                    mAdded = false;
                    mFallbackEventHandler.setView(null);
                    unscheduleTraversals();
                    setAccessibilityFocus(null, null);
...

                if (view instanceof RootViewSurfaceTaker) {
                    mInputQueueCallback =
                        ((RootViewSurfaceTaker)view).willYouTakeTheInputQueue();
                }
                if (mInputChannel != null) {
                    if (mInputQueueCallback != null) {
                        mInputQueue = new InputQueue();
                        mInputQueueCallback.onInputQueueCreated(mInputQueue);
                    }
                    mInputEventReceiver = new WindowInputEventReceiver(mInputChannel,
                            Looper.myLooper());
                }

                view.assignParent(this);
                mAddedTouchMode = (res & WindowManagerGlobal.ADD_FLAG_IN_TOUCH_MODE) != 0;
                mAppVisible = (res & WindowManagerGlobal.ADD_FLAG_APP_VISIBLE) != 0;

                if (mAccessibilityManager.isEnabled()) {
                    mAccessibilityInteractionConnectionManager.ensureConnection();
                }

                if (view.getImportantForAccessibility() == View.IMPORTANT_FOR_ACCESSIBILITY_AUTO) {
                    view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
                }

                // Set up the input pipeline.
                CharSequence counterSuffix = attrs.getTitle();
                mSyntheticInputStage = new SyntheticInputStage();
                InputStage viewPostImeStage = new ViewPostImeInputStage(mSyntheticInputStage);
                InputStage nativePostImeStage = new NativePostImeInputStage(viewPostImeStage,
                        "aq:native-post-ime:" + counterSuffix);
                InputStage earlyPostImeStage = new EarlyPostImeInputStage(nativePostImeStage);
                InputStage imeStage = new ImeInputStage(earlyPostImeStage,
                        "aq:ime:" + counterSuffix);
                InputStage viewPreImeStage = new ViewPreImeInputStage(imeStage);
                InputStage nativePreImeStage = new NativePreImeInputStage(viewPreImeStage,
                        "aq:native-pre-ime:" + counterSuffix);

                mFirstInputStage = nativePreImeStage;
                mFirstPostImeInputStage = earlyPostImeStage;
                mPendingInputEventQueueLengthCounterName = "aq:pending:" + counterSuffix;
            }
        }
    }
```
这里面完成的事情，除去性能跟踪的逻辑，如下三件大事情，源码分散开了，这里统筹起来：
- 1.根据当前从DisplayManager获取到的Display的状态，绑定到AttachInfo中。并且把ViewRootImpl的Handler注册到DisplayManager中监听回调。从Display中获取当前屏幕的兼容信息，并获取坐标转化器。如果获取到，说明此时需要屏幕中的内容需要进行缩放。最后把这些信息都存放到AttachInfo中的mApplicationScale，并在AttachInfo记录根部View(DecorView)

- 2.根据传递的WindowManager.LayoutParams设置软键盘模式，并调用requestLayout触发下一轮的View 树的遍历。接着调用WindowSession的addToDisplay方法，把当前的Window添加到WMS的服务上进行处理。并从addToDisplay获取到的几个如mContentInsets，记录在mAttachInfo以及ViewRootImpl中。

- 3.清空AccessibilityService(Android的无障碍服务)的焦点。并且校验服务是否还在链接监听中。

- 4.如果还没有InputChannel，则创建一个InputChannel，并且进行点击事件的监听。这个对象就是通过socket监听IMS服务发送的点击事件，最后传递到我们的Activity中。关于这个对象的设计，我们暂时不去深究，后面会有专门的IMS的源码解析专题。

在这几个中，最重要的是第二点。它承载了核心的View的树的构建与遍历逻辑。关于addToDisplay方法的详细解析可以看看我写的[WMS在Activity启动中的职责 添加窗体(三)](https://www.jianshu.com/p/157e8bbfa45a)。
接下来我们顺着requestLayout看看究竟做了什么。

## requestLayout 请求下一次的View树遍历
```java
    @Override
    public void requestLayout() {
        if (!mHandlingLayoutInLayoutRequest) {
            checkThread();
            mLayoutRequested = true;
            scheduleTraversals();
        }
    }

    void checkThread() {
        if (mThread != Thread.currentThread()) {
            throw new CalledFromWrongThreadException(
                    "Only the original thread that created a view hierarchy can touch its views.");
        }
    }
```
我们就能看到这个过程中，就能看到为什么异步调用requestLayout方法就爆异常。在每一次调用requestLayout都会调用checkThread进行一次是否是主线程调用的。

如果正在走onLayout的方法，mHandlingLayoutInLayoutRequest的标志位为true，禁止调用requestLayout。如果调用了requestlayout之后，mLayoutRequested就会设置为true。最后调用scheduleTraversals，进行Handler下一个Looper的处理View树的遍历和绘制。

## scheduleTraversals 
```java
    void scheduleTraversals() {
        if (!mTraversalScheduled) {
            mTraversalScheduled = true;
            mTraversalBarrier = mHandler.getLooper().getQueue().postSyncBarrier();
            mChoreographer.postCallback(
                    Choreographer.CALLBACK_TRAVERSAL, mTraversalRunnable, null);
            if (!mUnbufferedInputDispatch) {
                scheduleConsumeBatchedInput();
            }
            notifyRendererOfFramePending();
            pokeDrawLockIfNeeded();
        }
    }
```
- 1.首先把mTraversalScheduled设置为true。接下来会调用postSyncBarrier方法设置同步屏障。关于这个方法，我在[Handler与相关系统调用的剖析(上)](https://www.jianshu.com/p/416de2a3a1d6)一文中有提到过。

- 2.通过mChoreographer的postCallback方法发送一个CALLBACK_TRAVERSAL，监听Vsync信号的到来，接着执行mTraversalRunnable这个runnable方法。关于这一段的原理，可以看我写的[Vsync同步信号原理](https://www.jianshu.com/p/82c0556e9c76)一文有详细的讲解流程。

- 3.scheduleConsumeBatchedInput 处理没有处理完的按键消息发送
- 4.notifyRendererOfFramePending 通知硬件渲染机制，尝试进行当前的状态进行动画绘制。

- 5.pokeDrawLockIfNeeded 如果发现当前屏幕的状态出于休眠低消耗doze状态，则会通过PowerManager.WakeLock强制点亮屏幕(通过WMS查询当前Window 对应的WindowState，在这里面有一个点亮屏幕的对象)。

关键还是View 树的遍历绘制流程，为了可以彻底的理解这个过程，我们看看Handler的同步屏障运作原理。

#### Handler 同步屏障的原理解析
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[MessageQueue.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/MessageQueue.java)
```java
    public int postSyncBarrier() {
        return postSyncBarrier(SystemClock.uptimeMillis());
    }

    private int postSyncBarrier(long when) {
        synchronized (this) {
            final int token = mNextBarrierToken++;
            final Message msg = Message.obtain();
            msg.markInUse();
            msg.when = when;
            msg.arg1 = token;

            Message prev = null;
            Message p = mMessages;
            if (when != 0) {
                while (p != null && p.when <= when) {
                    prev = p;
                    p = p.next;
                }
            }
            if (prev != null) { // invariant: p == prev.next
                msg.next = p;
                prev.next = msg;
            } else {
                msg.next = p;
                mMessages = msg;
            }
            return token;
        }
    }
```
能看到这个方法实际上很简单，就是把一个记录为当前时刻的msg插入到mMessages链表中。当然这种同步屏障消息和普通的消息最大的区别，我们可以回到普通方法的入队看看做了什么：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[Handler.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/Handler.java)

```java
    private boolean enqueueMessage(MessageQueue queue, Message msg, long uptimeMillis) {
        msg.target = this;
        if (mAsynchronous) {
            msg.setAsynchronous(true);
        }
        return queue.enqueueMessage(msg, uptimeMillis);
    }
```
实际上，每一个从Handler入队的消息，target都是指向Handler，其目的就是为了回调到Handler的回调中。而最大区别就是这里，普通的消息设置了target，而消息屏障的消息则没有设置target。

当Looper被唤醒的时候，会调用Looper的loop方法中 Message.next的进行msg的遍历，会执行如下片段：
```java
                if (msg != null && msg.target == null) {
                    // Stalled by a barrier.  Find the next asynchronous message in the queue.
                    do {
                        prevMsg = msg;
                        msg = msg.next;
                    } while (msg != null && !msg.isAsynchronous());
                }
```
在这个代码中，判断到msg.target为null就走进来。接下来优先执行打开了isAsynchronous 异步标志的Handler信息。把其他消息执行向后挪动。那么我们可以猜测接下去的handler遍历View树并绘制的消息是一个异步消息。

我们回过头来看看下面这个方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)

```java
            mChoreographer.postCallback(
                    Choreographer.CALLBACK_TRAVERSAL, mTraversalRunnable, null);
```
mChoreographer中的postCallback这个方法根据我之前写的文章最终会调用到FrameDisplayEventReceiver.onVsync中。并在这个回调中通过Handler在doFrame方法调用mTraversalRunnable的run方法。
```java
@Override
        public void onVsync(long timestampNanos, int builtInDisplayId, int frame) {
....
            mTimestampNanos = timestampNanos;
            mFrame = frame;
            Message msg = Message.obtain(mHandler, this);
            msg.setAsynchronous(true);
            mHandler.sendMessageAtTime(msg, timestampNanos / TimeUtils.NANOS_PER_MS);
        }
```
能看到接受了Vsync信号回调后的Message，就是一个Asynchronous异步消息。能够在同步屏障内执行。

```java
            AnimationUtils.lockAnimationClock(frameTimeNanos / TimeUtils.NANOS_PER_MS);

            mFrameInfo.markInputHandlingStart();
            doCallbacks(Choreographer.CALLBACK_INPUT, frameTimeNanos);

            mFrameInfo.markAnimationsStart();
            doCallbacks(Choreographer.CALLBACK_ANIMATION, frameTimeNanos);

            mFrameInfo.markPerformTraversalsStart();
            doCallbacks(Choreographer.CALLBACK_TRAVERSAL, frameTimeNanos);

            doCallbacks(Choreographer.CALLBACK_COMMIT, frameTimeNanos);
```
能看到Choreographer.CALLBACK_TRAVERSAL这种消息是倒数第二个执行的顺序，并在doCallbacks中执行了mTraversalRunnable方法。

其实这就是Android是如何把View的绘制消息尽可能的提高消息处理的优先级原理。其原理和flutter的绘制机制十分相似。既然知道mTraversalRunnable是如何执行的,我们看看runnable内部做了什么。

### TraversalRunnable
```java
    final class TraversalRunnable implements Runnable {
        @Override
        public void run() {
            doTraversal();
        }
    }

    void doTraversal() {
        if (mTraversalScheduled) {
            mTraversalScheduled = false;
            mHandler.getLooper().getQueue().removeSyncBarrier(mTraversalBarrier);

  
            performTraversals();

            if (mProfile) {
                Debug.stopMethodTracing();
                mProfile = false;
            }
        }
    }
```
能看到，在这个过程中首先通过removeSyncBarrier移除了mTraversalBarrier这个同步屏障。这样就能继续执行Handler的接下来的消息。但是这个时候还在Handler的执行的一个方法中，所以并不会被其他消息打断View树的绘制优先级。

接下来就是整个View树的绘制核心，performTraversals。

## performTraversals
这个方法十分长，这里我们把它分为4大部分，绘制准备，onAttachWindow绑定窗口,onApplyWindowInsets分发窗体间距,准备硬件渲染Surface,onMeasure，onLayout，onDraw。

### 绘制准备onAttachWindow
接下来，我这边先抛开硬件渲染的流程，集中理解软件渲染的流程。

```java
    private void performTraversals() {
        // cache mView since it is used so much below...
        final View host = mView;


        if (host == null || !mAdded)
            return;

        mIsInTraversal = true;
        mWillDrawSoon = true;
        boolean windowSizeMayChange = false;
        boolean newSurface = false;
        boolean surfaceChanged = false;
        WindowManager.LayoutParams lp = mWindowAttributes;

        int desiredWindowWidth;
        int desiredWindowHeight;

        final int viewVisibility = getHostVisibility();
        final boolean viewVisibilityChanged = !mFirst
                && (mViewVisibility != viewVisibility || mNewSurfaceNeeded

                || mAppVisibilityChanged);
        mAppVisibilityChanged = false;
        final boolean viewUserVisibilityChanged = !mFirst &&
                ((mViewVisibility == View.VISIBLE) != (viewVisibility == View.VISIBLE));

        WindowManager.LayoutParams params = null;
        if (mWindowAttributesChanged) {
            mWindowAttributesChanged = false;
            surfaceChanged = true;
            params = lp;
        }
        CompatibilityInfo compatibilityInfo =
                mDisplay.getDisplayAdjustments().getCompatibilityInfo();
        if (compatibilityInfo.supportsScreen() == mLastInCompatMode) {
            params = lp;
            mFullRedrawNeeded = true;
            mLayoutRequested = true;
            if (mLastInCompatMode) {
                params.privateFlags &= ~WindowManager.LayoutParams.PRIVATE_FLAG_COMPATIBLE_WINDOW;
                mLastInCompatMode = false;
            } else {
                params.privateFlags |= WindowManager.LayoutParams.PRIVATE_FLAG_COMPATIBLE_WINDOW;
                mLastInCompatMode = true;
            }
        }

        mWindowAttributesChangesFlag = 0;

        Rect frame = mWinFrame;
        if (mFirst) {
            mFullRedrawNeeded = true;
            mLayoutRequested = true;

            final Configuration config = mContext.getResources().getConfiguration();
            if (shouldUseDisplaySize(lp)) {
                // NOTE -- system code, won't try to do compat mode.
                Point size = new Point();
                mDisplay.getRealSize(size);
                desiredWindowWidth = size.x;
                desiredWindowHeight = size.y;
            } else {
                desiredWindowWidth = mWinFrame.width();
                desiredWindowHeight = mWinFrame.height();
            }

            mAttachInfo.mUse32BitDrawingCache = true;
            mAttachInfo.mHasWindowFocus = false;
            mAttachInfo.mWindowVisibility = viewVisibility;
            mAttachInfo.mRecomputeGlobalAttributes = false;
            mLastConfigurationFromResources.setTo(config);
            mLastSystemUiVisibility = mAttachInfo.mSystemUiVisibility;

            if (mViewLayoutDirectionInitial == View.LAYOUT_DIRECTION_INHERIT) {
                host.setLayoutDirection(config.getLayoutDirection());
            }
            host.dispatchAttachedToWindow(mAttachInfo, 0);
            mAttachInfo.mTreeObserver.dispatchOnWindowAttachedChange(true);
            dispatchApplyInsets(host);
        } else {
            desiredWindowWidth = frame.width();
            desiredWindowHeight = frame.height();
            if (desiredWindowWidth != mWidth || desiredWindowHeight != mHeight) {
                mFullRedrawNeeded = true;
                mLayoutRequested = true;
                windowSizeMayChange = true;
            }
        }

        if (viewVisibilityChanged) {
            mAttachInfo.mWindowVisibility = viewVisibility;
            host.dispatchWindowVisibilityChanged(viewVisibility);
            if (viewUserVisibilityChanged) {
                host.dispatchVisibilityAggregated(viewVisibility == View.VISIBLE);
            }
            if (viewVisibility != View.VISIBLE || mNewSurfaceNeeded) {
                endDragResizing();
                destroyHardwareResources();
            }
            if (viewVisibility == View.GONE) {
                mHasHadWindowFocus = false;
            }
        }

        if (mAttachInfo.mWindowVisibility != View.VISIBLE) {
            host.clearAccessibilityFocus();
        }
....
    }
```
在这个过程中，我们可以把情况分为2种，第一种ViewRootImpl首次渲染，第二种ViewRootImpl非首次渲染。

首次渲染可以分为如下几个步骤：
- 1.如果通过shouldUseDisplaySize判断到此时是System的ui，如statusbar，音量等，就会设置desiredWindowWidth和desiredWindowHeight为屏幕的宽高。
- 2.如果不是System的ui，则设置从Session.addToDislpay中获取到的mWindowFrame设置为屏幕的当前准备渲染的宽高。

- 3.setLayoutDirection，设置整个View树的渲染方向。如果对海外开发熟悉的朋友应该知道marginStart和marginLeft之前的区别。前者可以根据地域的阅读喜欢设定如文字是从左到右还是从右到左的渲染。

- 4.调用dispatchAttachedToWindow 分发从当前的根部View(DecorView)开始，往下进行onAttachWindow的方法。

如果非首次渲染：
步骤就简单很多了：
- 1.直接设置了desiredWindowWidth和desiredWindowHeight为mWindowFrame的宽高。
- 2.此时会直接判断DecorView是否还可见，如果可见则回调从根部DecorView分发下去的dispatchWindowVisibilityChanged的方法改变Window的可见性。

如果不可见，则清空无障碍服务的焦点。

在这个准备流程中，值得注意的点有三点：
- 1.mWindowFrame 是如何计算出来的，和屏幕宽高有什么差距
- 2.首次渲染调用的dispatchAttachedToWindow，分发AttachInfo做了什么行为。
- 3.dispatchWindowVisibilityChanged分发了什么事件。

让我们一一来解析一边。

#### addToDisplay 初步计算屏幕区域
关于这个函数，我在[WMS在Activity启动中的职责 添加窗体](https://www.jianshu.com/p/157e8bbfa45a)一文中，我已经剖析过了这个函数是如何把第一次渲染的Window添加到WMS中进行管理的。

这一次，我们把目光放在addToDisplay中的初步计算区域的方法PhoneWindowManager.getLayoutHintLw。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[policy](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/policy/)/[PhoneWindowManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/policy/PhoneWindowManager.java)
```java
    public boolean getLayoutHintLw(WindowManager.LayoutParams attrs, Rect taskBounds,
            DisplayFrames displayFrames, Rect outFrame, Rect outContentInsets, Rect outStableInsets,
            Rect outOutsets, DisplayCutout.ParcelableWrapper outDisplayCutout) {
        final int fl = PolicyControl.getWindowFlags(null, attrs);
        final int pfl = attrs.privateFlags;
        final int requestedSysUiVis = PolicyControl.getSystemUiVisibility(null, attrs);
        final int sysUiVis = requestedSysUiVis | getImpliedSysUiFlagsForLayout(attrs);
        final int displayRotation = displayFrames.mRotation;
        final int displayWidth = displayFrames.mDisplayWidth;
        final int displayHeight = displayFrames.mDisplayHeight;

        final boolean useOutsets = outOutsets != null && shouldUseOutsets(attrs, fl);
        if (useOutsets) {
            int outset = ScreenShapeHelper.getWindowOutsetBottomPx(mContext.getResources());
            if (outset > 0) {
                if (displayRotation == Surface.ROTATION_0) {
                    outOutsets.bottom += outset;
                } else if (displayRotation == Surface.ROTATION_90) {
                    outOutsets.right += outset;
                } else if (displayRotation == Surface.ROTATION_180) {
                    outOutsets.top += outset;
                } else if (displayRotation == Surface.ROTATION_270) {
                    outOutsets.left += outset;
                }
            }
        }

        final boolean layoutInScreen = (fl & FLAG_LAYOUT_IN_SCREEN) != 0;
        final boolean layoutInScreenAndInsetDecor = layoutInScreen &&
                (fl & FLAG_LAYOUT_INSET_DECOR) != 0;
        final boolean screenDecor = (pfl & PRIVATE_FLAG_IS_SCREEN_DECOR) != 0;

        if (layoutInScreenAndInsetDecor && !screenDecor) {
            int availRight, availBottom;
            if (canHideNavigationBar() &&
                    (sysUiVis & View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION) != 0) {
                outFrame.set(displayFrames.mUnrestricted);
                availRight = displayFrames.mUnrestricted.right;
                availBottom = displayFrames.mUnrestricted.bottom;
            } else {
                outFrame.set(displayFrames.mRestricted);
                availRight = displayFrames.mRestricted.right;
                availBottom = displayFrames.mRestricted.bottom;
            }
            outStableInsets.set(displayFrames.mStable.left, displayFrames.mStable.top,
                    availRight - displayFrames.mStable.right,
                    availBottom - displayFrames.mStable.bottom);

            if ((sysUiVis & View.SYSTEM_UI_FLAG_LAYOUT_STABLE) != 0) {
                if ((fl & FLAG_FULLSCREEN) != 0) {
                    outContentInsets.set(displayFrames.mStableFullscreen.left,
                            displayFrames.mStableFullscreen.top,
                            availRight - displayFrames.mStableFullscreen.right,
                            availBottom - displayFrames.mStableFullscreen.bottom);
                } else {
                    outContentInsets.set(outStableInsets);
                }
            } else if ((fl & FLAG_FULLSCREEN) != 0 || (fl & FLAG_LAYOUT_IN_OVERSCAN) != 0) {
                outContentInsets.setEmpty();
            } else {
                outContentInsets.set(displayFrames.mCurrent.left, displayFrames.mCurrent.top,
                        availRight - displayFrames.mCurrent.right,
                        availBottom - displayFrames.mCurrent.bottom);
            }

            if (taskBounds != null) {
                calculateRelevantTaskInsets(taskBounds, outContentInsets,
                        displayWidth, displayHeight);
                calculateRelevantTaskInsets(taskBounds, outStableInsets,
                        displayWidth, displayHeight);
                outFrame.intersect(taskBounds);
            }
            outDisplayCutout.set(displayFrames.mDisplayCutout.calculateRelativeTo(outFrame)
                    .getDisplayCutout());
            return mForceShowSystemBars;
        } else {
            if (layoutInScreen) {
                outFrame.set(displayFrames.mUnrestricted);
            } else {
                outFrame.set(displayFrames.mStable);
            }
            if (taskBounds != null) {
                outFrame.intersect(taskBounds);
            }

            outContentInsets.setEmpty();
            outStableInsets.setEmpty();
            outDisplayCutout.set(DisplayCutout.NO_CUTOUT);
            return mForceShowSystemBars;
        }
    }
```
这里面出现了[计算窗体的大小](https://www.jianshu.com/p/e83496ca788c)一文中出现过的几个参数。关于SystemUI几个标志位，这里有一篇文章写的挺全的
[管理System UI (状态栏 + 导航栏)](https://www.jianshu.com/p/e27e7f09d1f7)

我们可以看到实际上第一次计算窗体的区域，是根据SystemUI的标志位进行了处理：
- 1.首先根据当前的window的旋转方向，设置好当前Window应该旋转多少度后显示。
- 2.如果判断到打开了FLAG_LAYOUT_IN_SCREEN，FLAG_LAYOUT_INSET_DECOR标志位，关闭了PRIVATE_FLAG_IS_SCREEN_DECOR标志位。则会走如下分支：
  - 1.如果允许隐藏导航栏，同时打开了SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION标志位。则把区域设置为我在计算窗体大小一节说过的，outFrame设置为mUnrestricted区域，正式屏幕大小，但是不包含过扫描区域。
  - 2.否则，outFrame则设置为mRestricted区域。这个区域是屏幕大小，但是如果状态栏无法隐藏，就是减去状态栏的高度，当然不包含过扫描区域。

接下来outStableInsets 稳定区域嵌入区域，内容嵌入区域。也就是说基于这些嵌入区域垫在左边，接着的位置才是真正的Stable，Content区域。

- 3.接着第二大点的逻辑，如果不满足上述标志的处理，如果打开了FLAG_LAYOUT_IN_SCREEN标志位，则设置mUnrestricted为mWindowFrame区域。否则则是mStable。

其他的逻辑暂时不管。我们可以总结了一点，mUnrestricted是最大的扫描区域。其次是restricted区域，可以包含导航栏以及状态栏，但是这两个区域可以内容重叠。接下里就是Stable区域，也就是稳定内容区域。实际上不同沉浸式模式就是改变ViewRootImpl显示区域在这三个显示区域之间切换。

#### ViewGroup dispatchAttachedToWindow
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewGroup.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewGroup.java)

```java
    void dispatchAttachedToWindow(AttachInfo info, int visibility) {
        mGroupFlags |= FLAG_PREVENT_DISPATCH_ATTACHED_TO_WINDOW;
        super.dispatchAttachedToWindow(info, visibility);
        mGroupFlags &= ~FLAG_PREVENT_DISPATCH_ATTACHED_TO_WINDOW;

        final int count = mChildrenCount;
        final View[] children = mChildren;
        for (int i = 0; i < count; i++) {
            final View child = children[i];
            child.dispatchAttachedToWindow(info,
                    combineVisibility(visibility, child.getVisibility()));
        }
        final int transientCount = mTransientIndices == null ? 0 : mTransientIndices.size();
        for (int i = 0; i < transientCount; ++i) {
            View view = mTransientViews.get(i);
            view.dispatchAttachedToWindow(info,
                    combineVisibility(visibility, view.getVisibility()));
        }
    }
```
由于在ViewRootImpl中第一个布局是一个DecorView，它同时是一个ViewGroup也是一个FrameLayout.能看到这个付哦凑成很简单，实际上就是遍历绑定在ViewGroup中所有子View的dispatchAttachedToWindow方法。

#### View dispatchAttachedToWindow
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)

```java
    void dispatchAttachedToWindow(AttachInfo info, int visibility) {
        mAttachInfo = info;
        if (mOverlay != null) {
            mOverlay.getOverlayView().dispatchAttachedToWindow(info, visibility);
        }
        mWindowAttachCount++;

        mPrivateFlags |= PFLAG_DRAWABLE_STATE_DIRTY;
        if (mFloatingTreeObserver != null) {
            info.mTreeObserver.merge(mFloatingTreeObserver);
            mFloatingTreeObserver = null;
        }

        registerPendingFrameMetricsObservers();

        if ((mPrivateFlags&PFLAG_SCROLL_CONTAINER) != 0) {
            mAttachInfo.mScrollContainers.add(this);
            mPrivateFlags |= PFLAG_SCROLL_CONTAINER_ADDED;
        }
        // Transfer all pending runnables.
        if (mRunQueue != null) {
            mRunQueue.executeActions(info.mHandler);
            mRunQueue = null;
        }
        performCollectViewAttributes(mAttachInfo, visibility);
        onAttachedToWindow();

        ListenerInfo li = mListenerInfo;
        final CopyOnWriteArrayList<OnAttachStateChangeListener> listeners =
                li != null ? li.mOnAttachStateChangeListeners : null;
        if (listeners != null && listeners.size() > 0) {

            for (OnAttachStateChangeListener listener : listeners) {
                listener.onViewAttachedToWindow(this);
            }
        }

        int vis = info.mWindowVisibility;
        if (vis != GONE) {
            onWindowVisibilityChanged(vis);
            if (isShown()) {
                onVisibilityAggregated(vis == VISIBLE);
            }
        }

        onVisibilityChanged(this, visibility);

        if ((mPrivateFlags&PFLAG_DRAWABLE_STATE_DIRTY) != 0) {
            // If nobody has evaluated the drawable state yet, then do it now.
            refreshDrawableState();
        }
        needGlobalAttributesUpdate(false);

        notifyEnterOrExitForAutoFillIfNeeded(true);
    }
```
- 1.首先把ViewRootImpl的AttachInfo分发到View的mAttachInfo中，接着继续分发到View的浮层OverLayer中。这个浮层挺有用的，不占用过多层级，适合给View添加没有任何行为的图标等。

- 2.把View自己的mFloatingTreeObserver(如果存在)也就是ViewTreeObserver对象，合并到全局的ViewRootImpl的ViewTreeObserver监听中。

- 3.registerPendingFrameMetricsObservers 设置硬件渲染的掉帧和渲染完成监听。
```java
    private void registerPendingFrameMetricsObservers() {
        if (mFrameMetricsObservers != null) {
            ThreadedRenderer renderer = getThreadedRenderer();
            if (renderer != null) {
                for (FrameMetricsObserver fmo : mFrameMetricsObservers) {
                    renderer.addFrameMetricsObserver(fmo);
                }
            } else {
...
            }
        }
    }

```
- 4.判断是否打开了通过setScrollContainer方法打开了PFLAG_SCROLL_CONTAINER标志位。这个标志位设定了View是否能在键盘弹出的时候进行向上移动。其效果和adjustPan类似。也可以通过xml的android:isScrollContainer设置。

- 5.执行View中通过post方法设置进来的Runnable方法。有一种使用方式十分常见：
```java
view.post(new Runnable());
```
这样就能保证这个Runnable对象在主线程中处理。其原理很简单：
```java
    public boolean post(Runnable action) {
        final AttachInfo attachInfo = mAttachInfo;
        if (attachInfo != null) {
            return attachInfo.mHandler.post(action);
        }

        getRunQueue().post(action);
        return true;
    }
```
实际上就是判断如果当前的View绑定了mAttachInfo，则把事件委托给ViewRootImpl的Handler处理。否则将会把事件预存到HandlerActionQueue中，直到真正开始渲染之前消费。

- 6.performCollectViewAttributes收集View可见属性：
```java
    void performCollectViewAttributes(AttachInfo attachInfo, int visibility) {
        if ((visibility & VISIBILITY_MASK) == VISIBLE) {
            if ((mViewFlags & KEEP_SCREEN_ON) == KEEP_SCREEN_ON) {
                attachInfo.mKeepScreenOn = true;
            }
            attachInfo.mSystemUiVisibility |= mSystemUiVisibility;
            ListenerInfo li = mListenerInfo;
            if (li != null && li.mOnSystemUiVisibilityChangeListener != null) {
                attachInfo.mHasSystemUiListeners = true;
            }
        }
    }
```
能看到只要有一个View的mKeepScreenOn为true则全局为ture。如果有一个View设置了SystemUI可见那么全局可见，其实这里是收集每一个View对SystemUI设置的标志位行为。

- 7.调用onAttachedToWindow方法，接着回调所有的监听onAttachedToWindow行为的回调。
```java
    protected void onAttachedToWindow() {
        if ((mPrivateFlags & PFLAG_REQUEST_TRANSPARENT_REGIONS) != 0) {
            mParent.requestTransparentRegion(this);
        }

        mPrivateFlags3 &= ~PFLAG3_IS_LAID_OUT;

        jumpDrawablesToCurrentState();

        resetSubtreeAccessibilityStateChanged();

        rebuildOutline();

        if (isFocused()) {
            InputMethodManager imm = InputMethodManager.peekInstance();
            if (imm != null) {
                imm.focusIn(this);
            }
        }
    }

```
这里面的工作不多，主要是处理Drawable中设置了几种状态的情况，选定一种；并且打上一个标志位，告诉Accessibility无障碍服务整个View层次结构重建了；重新构建View 的ViewOutlineProvider，也就是外框(可以用于实现圆角，QMUI也是通过这种方式实现的)；如果打上了foucs标志位，则告诉InputMethodManager(软键盘管理器)以此View为焦点弹出。

- 8.如果View不是Gone,会调用onWindowVisibilityChanged设置当前窗口的可见性时候需要的处理。
```java
    protected void onWindowVisibilityChanged(@Visibility int visibility) {
        if (visibility == VISIBLE) {
            initialAwakenScrollBars();
        }
    }
    private boolean initialAwakenScrollBars() {
        return mScrollCache != null &&
                awakenScrollBars(mScrollCache.scrollBarDefaultDelayBeforeFade * 4, true);
    }
```
能看到实际上就是唤醒Scrollbar(上下滚动的滑轮)的显示时间。这里的默认时间为300毫秒淡入淡出。

- 9.onVisibilityAggregated 这里主要的工作是为了调用AutofillManager中关注的View那些是显示的。提一句，AutofillManager这个系统服务是用于自动化填充字符串的服务，这里暂时不讨论。感兴趣可以看看官方网站的介绍[https://developer.android.google.cn/reference/android/view/autofill/AutofillManager.html](https://developer.android.google.cn/reference/android/view/autofill/AutofillManager.html)以及[一个完整例子](https://blog.csdn.net/weixin_34245169/article/details/88022291?utm_medium=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase&depth_1-utm_source=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase)。

- 10.调用onVisibilityChanged方法回调。我们编写View的时候可以重写这个方法监听是否可见。

- 11.在上面添加了PFLAG_DRAWABLE_STATE_DIRTY标志位。此时就会执行refreshDrawableState 刷新Drawable的状态内容。

- 12.notifyEnterOrExitForAutoFillIfNeeded 实际上就是AutofillManager调用了notifyViewEntered方法，告诉AutofillManager服务已经遍历到这个层级。


#### dispatchWindowVisibilityChanged
```java
    public void dispatchWindowVisibilityChanged(@Visibility int visibility) {
        onWindowVisibilityChanged(visibility);
    }

    protected void onWindowVisibilityChanged(@Visibility int visibility) {
        if (visibility == VISIBLE) {
            initialAwakenScrollBars();
        }
    }
```
实际上这里的逻辑和上面的Window的Attach步骤几乎一致。说明只要Window从不可视到可视都会尝试的显示一次滚轮。


#### ViewRootImpl 绘制准备分发WindowInsets
```java
        getRunQueue().executeActions(mAttachInfo.mHandler);

        boolean insetsChanged = false;

        boolean layoutRequested = mLayoutRequested && (!mStopped || mReportNextDraw);
        if (layoutRequested) {

            final Resources res = mView.getContext().getResources();

            if (mFirst) {
                mAttachInfo.mInTouchMode = !mAddedTouchMode;
                ensureTouchModeLocally(mAddedTouchMode);
            } else {
                if (!mPendingOverscanInsets.equals(mAttachInfo.mOverscanInsets)) {
                    insetsChanged = true;
                }
                if (!mPendingContentInsets.equals(mAttachInfo.mContentInsets)) {
                    insetsChanged = true;
                }
                if (!mPendingStableInsets.equals(mAttachInfo.mStableInsets)) {
                    insetsChanged = true;
                }
                if (!mPendingDisplayCutout.equals(mAttachInfo.mDisplayCutout)) {
                    insetsChanged = true;
                }
                if (!mPendingVisibleInsets.equals(mAttachInfo.mVisibleInsets)) {
                    mAttachInfo.mVisibleInsets.set(mPendingVisibleInsets);
                }
                if (!mPendingOutsets.equals(mAttachInfo.mOutsets)) {
                    insetsChanged = true;
                }
                if (mPendingAlwaysConsumeNavBar != mAttachInfo.mAlwaysConsumeNavBar) {
                    insetsChanged = true;
                }
                if (lp.width == ViewGroup.LayoutParams.WRAP_CONTENT
                        || lp.height == ViewGroup.LayoutParams.WRAP_CONTENT) {
                    windowSizeMayChange = true;

                    if (shouldUseDisplaySize(lp)) {
                        Point size = new Point();
                        mDisplay.getRealSize(size);
                        desiredWindowWidth = size.x;
                        desiredWindowHeight = size.y;
                    } else {
                        Configuration config = res.getConfiguration();
                        desiredWindowWidth = dipToPx(config.screenWidthDp);
                        desiredWindowHeight = dipToPx(config.screenHeightDp);
                    }
                }
            }

            windowSizeMayChange |= measureHierarchy(host, lp, res,
                    desiredWindowWidth, desiredWindowHeight);
        }

        if (collectViewAttributes()) {
            params = lp;
        }
        if (mAttachInfo.mForceReportNewAttributes) {
            mAttachInfo.mForceReportNewAttributes = false;
            params = lp;
        }

        if (mFirst || mAttachInfo.mViewVisibilityChanged) {
            mAttachInfo.mViewVisibilityChanged = false;
            int resizeMode = mSoftInputMode &
                    WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST;
            if (resizeMode == WindowManager.LayoutParams.SOFT_INPUT_ADJUST_UNSPECIFIED) {
                final int N = mAttachInfo.mScrollContainers.size();
                for (int i=0; i<N; i++) {
                    if (mAttachInfo.mScrollContainers.get(i).isShown()) {
                        resizeMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE;
                    }
                }
                if (resizeMode == 0) {
                    resizeMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN;
                }
                if ((lp.softInputMode &
                        WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST) != resizeMode) {
                    lp.softInputMode = (lp.softInputMode &
                            ~WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST) |
                            resizeMode;
                    params = lp;
                }
            }
        }

        if (params != null) {
            if ((host.mPrivateFlags & View.PFLAG_REQUEST_TRANSPARENT_REGIONS) != 0) {
                if (!PixelFormat.formatHasAlpha(params.format)) {
                    params.format = PixelFormat.TRANSLUCENT;
                }
            }
            mAttachInfo.mOverscanRequested = (params.flags
                    & WindowManager.LayoutParams.FLAG_LAYOUT_IN_OVERSCAN) != 0;
        }

        if (mApplyInsetsRequested) {
            mApplyInsetsRequested = false;
            mLastOverscanRequested = mAttachInfo.mOverscanRequested;
            dispatchApplyInsets(host);
            if (mLayoutRequested) {
                windowSizeMayChange |= measureHierarchy(host, lp,
                        mView.getContext().getResources(),
                        desiredWindowWidth, desiredWindowHeight);
            }
        }

        if (layoutRequested) {
            mLayoutRequested = false;
        }

        boolean windowShouldResize = layoutRequested && windowSizeMayChange
            && ((mWidth != host.getMeasuredWidth() || mHeight != host.getMeasuredHeight())
                || (lp.width == ViewGroup.LayoutParams.WRAP_CONTENT &&
                        frame.width() < desiredWindowWidth && frame.width() != mWidth)
                || (lp.height == ViewGroup.LayoutParams.WRAP_CONTENT &&
                        frame.height() < desiredWindowHeight && frame.height() != mHeight));
        windowShouldResize |= mDragResizing && mResizeMode == RESIZE_MODE_FREEFORM;


        windowShouldResize |= mActivityRelaunched;


        final boolean computesInternalInsets =
                mAttachInfo.mTreeObserver.hasComputeInternalInsetsListeners()
                || mAttachInfo.mHasNonEmptyGivenInternalInsets;

        boolean insetsPending = false;
        int relayoutResult = 0;
        boolean updatedConfiguration = false;

        final int surfaceGenerationId = mSurface.getGenerationId();

        final boolean isViewVisible = viewVisibility == View.VISIBLE;
        final boolean windowRelayoutWasForced = mForceNextWindowRelayout;

```
- 1.在ViewRootImpl中也有自己的RunQueue。也是通过post的方法传递进来。不过这个任务队列是专门用来处理从IMS接受到的点击事件等。

- 2.mLayoutRequested 这个标志位在requestLayout设置为true。同时mStopped为false。所以此时会走到layoutRequested 的分支中。
    - 1.此时是首次渲染，则会根据ADD_FLAG_IN_TOUCH_MODE这个标志位设置相反的状态到mAttachInfo.mInTouchMode。这个标志位其实标志着正在进行按键导航而不是触摸屏。
    - 2.如果不是首次渲染，则校验当前通过上面的addToDisplay获取的当前各个显示区域和当前的显示区域进行比较，只要有一处发生了变化insetsChanged为true。最后如果判断到WindowManager.LayoutParams的宽高都是WRAP_CONTENT，则windowSizeMayChange强制设置为true。并重新更新全局的宽高。

不管哪一种情况都会走到measureHierarchy方法中，重新进行通过performMeasure对View树中每一个层级中View的宽高的变化校验。关于performMeasure相关的内容，我们放到下一篇区聊聊。

- 3.如果调用了View.requestApplyInsets方法，则会调用dispatchApplyInsets方法分发Inset，如果是requestLayout开始调用使得mLayoutRequested为true，则调用measureHierarchy判断是否发生了变化。

- 4.接着处理这个标志位，windowShouldResize。windowShouldResize标志位代表着窗口是否重新计算大小。这里的判断mWindowFrame是宽高比窗口的小同时和当前的宽高不相同则为true。如果ViewRootImpl发现Activity是重新登陆或者第一次登陆也会强制设置为true。

这个过程中值得注意的是Inset的分发。

#### dispatchApplyInsets
```java
    void dispatchApplyInsets(View host) {
        WindowInsets insets = getWindowInsets(true /* forceConstruct */);
        final boolean dispatchCutout = (mWindowAttributes.layoutInDisplayCutoutMode
                == LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS);
        if (!dispatchCutout) {
            insets = insets.consumeDisplayCutout();
        }
        host.dispatchApplyWindowInsets(insets);
    }
```
很简单，通过getWindowInsets获取到一个WindowInsets对象。如果LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS没有打开，就是指窗口没有使用刘海屏的挖孔区域，则调用WindowInsets.consumeDisplayCutout消费这段区域，扩充起来。最后通过DecorView分发下去。

那么有三个函数值得注意：
- 1.getWindowInsets 这个函数获取了哪个区域的内容
- 2.consumeDisplayCutout WindowInsets是如何消费区域的
- 3.dispatchApplyWindowInsets ViewGroup的分发做了什么。

##### getWindowInsets
```java
    /* package */ WindowInsets getWindowInsets(boolean forceConstruct) {
        if (mLastWindowInsets == null || forceConstruct) {
            mDispatchContentInsets.set(mAttachInfo.mContentInsets);
            mDispatchStableInsets.set(mAttachInfo.mStableInsets);
            mDispatchDisplayCutout = mAttachInfo.mDisplayCutout.get();

            Rect contentInsets = mDispatchContentInsets;
            Rect stableInsets = mDispatchStableInsets;
            DisplayCutout displayCutout = mDispatchDisplayCutout;

            if (!forceConstruct
                    && (!mPendingContentInsets.equals(contentInsets) ||
                        !mPendingStableInsets.equals(stableInsets) ||
                        !mPendingDisplayCutout.get().equals(displayCutout))) {
                contentInsets = mPendingContentInsets;
                stableInsets = mPendingStableInsets;
                displayCutout = mPendingDisplayCutout.get();
            }
            Rect outsets = mAttachInfo.mOutsets;
            if (outsets.left > 0 || outsets.top > 0 || outsets.right > 0 || outsets.bottom > 0) {
                contentInsets = new Rect(contentInsets.left + outsets.left,
                        contentInsets.top + outsets.top, contentInsets.right + outsets.right,
                        contentInsets.bottom + outsets.bottom);
            }
            contentInsets = ensureInsetsNonNegative(contentInsets, "content");
            stableInsets = ensureInsetsNonNegative(stableInsets, "stable");
            mLastWindowInsets = new WindowInsets(contentInsets,
                    null /* windowDecorInsets */, stableInsets,
                    mContext.getResources().getConfiguration().isScreenRound(),
                    mAttachInfo.mAlwaysConsumeNavBar, displayCutout);
        }
        return mLastWindowInsets;
    }
```
注意，这里的outOutsets就是上文getLayoutHintL方法中的mOutSets参数。mOutSets这个对象实际上是由后面的Session的relayout方法获取的。如果非首次渲染，还会通过ScreenShapeHelper.getWindowOutsetBottomPx获取com.android.internal.R.integer.config_windowOutsetBottom这个资源设定的间距区域。

能看到实际上这个过程就是把Window中每一种区域的Inset都设置到WindowInsets中。

#### consumeDisplayCutout
那么consumeDisplayCutout就很好理解了：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[WindowInsets.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/WindowInsets.java)

```java
    public WindowInsets consumeDisplayCutout() {
        final WindowInsets result = new WindowInsets(this);
        result.mDisplayCutout = null;
        result.mDisplayCutoutConsumed = true;
        return result;
    }
```
实际上就把刘海屏幕的距离屏幕的间距区域给抹平了。

#### ViewGroup dispatchApplyWindowInsets
```java
    public WindowInsets dispatchApplyWindowInsets(WindowInsets insets) {
        insets = super.dispatchApplyWindowInsets(insets);
        if (!insets.isConsumed()) {
            final int count = getChildCount();
            for (int i = 0; i < count; i++) {
                insets = getChildAt(i).dispatchApplyWindowInsets(insets);
                if (insets.isConsumed()) {
                    break;
                }
            }
        }
        return insets;
    }
```
其实ViewGroup很简单，先处理View的dispatchApplyWindowInsets方法。接着遍历每一个子View的dispatchApplyWindowInsets方法。判断这个View是否需要消费Inset，一旦是需要消费就跳出遍历。

```java
    public boolean isConsumed() {
        return mSystemWindowInsetsConsumed && mWindowDecorInsetsConsumed && mStableInsetsConsumed
                && mDisplayCutoutConsumed;
    }
```
能看到在WindowInsets中只要有4个区域的需要消费了就是true。那么我们注重看一下View的dispatchApplyWindowInsets方法。

#### View dispatchApplyWindowInsets
```java
    public WindowInsets dispatchApplyWindowInsets(WindowInsets insets) {
        try {
            mPrivateFlags3 |= PFLAG3_APPLYING_INSETS;
            if (mListenerInfo != null && mListenerInfo.mOnApplyWindowInsetsListener != null) {
                return mListenerInfo.mOnApplyWindowInsetsListener.onApplyWindowInsets(this, insets);
            } else {
                return onApplyWindowInsets(insets);
            }
        } finally {
            mPrivateFlags3 &= ~PFLAG3_APPLYING_INSETS;
        }
    }
```
这里其实很简单，每一次经历这个方法先打开PFLAG3_APPLYING_INSETS标志位后关闭。如果有mOnApplyWindowInsetsListener的回调，则根据回调onApplyWindowInsets的结果返回。这里关注一下，默认情况onApplyWindowInsets方法。

```java
    public WindowInsets onApplyWindowInsets(WindowInsets insets) {
        if ((mPrivateFlags3 & PFLAG3_FITTING_SYSTEM_WINDOWS) == 0) {
            if (fitSystemWindows(insets.getSystemWindowInsets())) {
                return insets.consumeSystemWindowInsets();
            }
        } else {
            if (fitSystemWindowsInt(insets.getSystemWindowInsets())) {
                return insets.consumeSystemWindowInsets();
            }
        }
        return insets;
    }
```
注意在这个方法中，会判断PFLAG3_FITTING_SYSTEM_WINDOWS标志位是否开启。也就会走到if上方的分支。注意这里传入到fitSystemWindowsInt中进行判断的，实际上是整个WindowInsets中的mSystemWindowInsets对象,但是这里并不是操作这个对象，而是拷贝一份进行判断。因此不会影响到WindowInsets获取到的mSystemWindowInsets数值。

##### fitSystemWindows
```java
    protected boolean fitSystemWindows(Rect insets) {
        if ((mPrivateFlags3 & PFLAG3_APPLYING_INSETS) == 0) {
            if (insets == null) {
                return false;
            }

            try {
                mPrivateFlags3 |= PFLAG3_FITTING_SYSTEM_WINDOWS;
                return dispatchApplyWindowInsets(new WindowInsets(insets)).isConsumed();
            } finally {
                mPrivateFlags3 &= ~PFLAG3_FITTING_SYSTEM_WINDOWS;
            }
        } else {
            return fitSystemWindowsInt(insets);
        }
    }
```
由于每一次经历dispatchApplyInsets都会打开PFLAG3_APPLYING_INSETS标志位，就会走到下面的分支。
```java
    private boolean fitSystemWindowsInt(Rect insets) {
        if ((mViewFlags & FITS_SYSTEM_WINDOWS) == FITS_SYSTEM_WINDOWS) {
            mUserPaddingStart = UNDEFINED_PADDING;
            mUserPaddingEnd = UNDEFINED_PADDING;
            Rect localInsets = sThreadLocal.get();
            if (localInsets == null) {
                localInsets = new Rect();
                sThreadLocal.set(localInsets);
            }
            boolean res = computeFitSystemWindows(insets, localInsets);
            mUserPaddingLeftInitial = localInsets.left;
            mUserPaddingRightInitial = localInsets.right;
            internalSetPadding(localInsets.left, localInsets.top,
                    localInsets.right, localInsets.bottom);
            return res;
        }
        return false;
    }
```
在这里就会判断FITS_SYSTEM_WINDOWS这个标志位是否开启，没有开启则返回false。这个标志位是什么时候开启的呢？其实就是我们熟悉的在xml布局文件中添加的fitsSystemWindows标签：
```java
                case com.android.internal.R.styleable.View_fitsSystemWindows:
                    if (a.getBoolean(attr, false)) {
                        viewFlagValues |= FITS_SYSTEM_WINDOWS;
                        viewFlagMasks |= FITS_SYSTEM_WINDOWS;
                    }
                    break;
```

这里面的关键的行为有2点：
- 1.从线程私有数据中获取localInsets，并且通过computeFitSystemWindows计算是否fitSystemWindows，从而消费掉SystemWindowInsets，让应用置顶。
- 2.internalSetPadding 把inset作为padding设置到View中。

注意这个方法的返回，决定了WindowInsets中的consumeSystemWindowInsets方法是否执行。

###### computeFitSystemWindows
```java
    protected boolean computeFitSystemWindows(Rect inoutInsets, Rect outLocalInsets) {
        WindowInsets innerInsets = computeSystemWindowInsets(new WindowInsets(inoutInsets),
                outLocalInsets);
        inoutInsets.set(innerInsets.getSystemWindowInsets());
        return innerInsets.isSystemWindowInsetsConsumed();
    }

    public WindowInsets computeSystemWindowInsets(WindowInsets in, Rect outLocalInsets) {
        if ((mViewFlags & OPTIONAL_FITS_SYSTEM_WINDOWS) == 0
                || mAttachInfo == null
                || ((mAttachInfo.mSystemUiVisibility & SYSTEM_UI_LAYOUT_FLAGS) == 0
                && !mAttachInfo.mOverscanRequested)) {
            outLocalInsets.set(in.getSystemWindowInsets());
            return in.consumeSystemWindowInsets().inset(outLocalInsets);
        } else {
            final Rect overscan = mAttachInfo.mOverscanInsets;
            outLocalInsets.set(overscan);
            return in.inset(outLocalInsets);
        }
    }
```
- 1.不需要fitSystemWindow，也不需要全屏，同时不需要过扫描区域的覆盖。则会先调用consumeSystemWindowInsets，后调用inset计算新的WindowInsets的大小。
- 2.负责调用inset把mOverscanInsets设置到WindowInsets后返回。


当返回后就调用isSystemWindowInsetsConsumed进行判断：
```java
    boolean isSystemWindowInsetsConsumed() {
        return mSystemWindowInsetsConsumed;
    }
```
很简单，就是判断一次标志位是否打开。



#### WindowInsets计算原理
到这里，似乎还是可能对WindowInsets是什么，以及计算了什么东西还有点迷惑。我们来看看WindowInsets中inset方法。
```java
    public WindowInsets inset(Rect r) {
        return inset(r.left, r.top, r.right, r.bottom);
    }

    public WindowInsets inset(int left, int top, int right, int bottom) {
        Preconditions.checkArgumentNonnegative(left);
        Preconditions.checkArgumentNonnegative(top);
        Preconditions.checkArgumentNonnegative(right);
        Preconditions.checkArgumentNonnegative(bottom);

        WindowInsets result = new WindowInsets(this);
        if (!result.mSystemWindowInsetsConsumed) {
            result.mSystemWindowInsets =
                    insetInsets(result.mSystemWindowInsets, left, top, right, bottom);
        }
        if (!result.mWindowDecorInsetsConsumed) {
            result.mWindowDecorInsets =
                    insetInsets(result.mWindowDecorInsets, left, top, right, bottom);
        }
        if (!result.mStableInsetsConsumed) {
            result.mStableInsets = insetInsets(result.mStableInsets, left, top, right, bottom);
        }
        if (mDisplayCutout != null) {
            result.mDisplayCutout = result.mDisplayCutout.inset(left, top, right, bottom);
            if (result.mDisplayCutout.isEmpty()) {
                result.mDisplayCutout = null;
            }
        }
        return result;
    }
```
到这里我们能看到，实际上WindowInsets管理了Window中每块区域距离屏幕边缘的区域。为什么说是间距区域呢？实际上可以从addToDisplay中能看到真正的内容区域都是先加上间距区域后才是整个屏幕区域宽高。分别是
- 1.系统ui间距区域
- 2.Decor内容间距区域
- 3.Stable内容间距区域
- 4.DisplayCutout 刘海间距区域

注意这里的逻辑，如果判断不需要消费对应区域的Insets间距区，就会通过inset方法WindowInsets对每一个间距进行调整，就能让App应用中的内容抹除这些距离，从而实现如沉浸式的模式，适配刘海屏。

```java
    private static Rect insetInsets(Rect insets, int left, int top, int right, int bottom) {
        int newLeft = Math.max(0, insets.left - left);
        int newTop = Math.max(0, insets.top - top);
        int newRight = Math.max(0, insets.right - right);
        int newBottom = Math.max(0, insets.bottom - bottom);
        if (newLeft == left && newTop == top && newRight == right && newBottom == bottom) {
            return insets;
        }
        return new Rect(newLeft, newTop, newRight, newBottom);
    }
```
进一步的来看这个方法，实际上是对insets的四个方向的区域都减去对应的大小。让整个Rect变得更小，但是不能低于0.

#### internalSetPadding
这一段代码就是整个xml布局文件中fitSystemWindows标志位的核心
```java
    protected void internalSetPadding(int left, int top, int right, int bottom) {
        mUserPaddingLeft = left;
        mUserPaddingRight = right;
        mUserPaddingBottom = bottom;

        final int viewFlags = mViewFlags;
        boolean changed = false;

        // Common case is there are no scroll bars.
        if ((viewFlags & (SCROLLBARS_VERTICAL|SCROLLBARS_HORIZONTAL)) != 0) {
            if ((viewFlags & SCROLLBARS_VERTICAL) != 0) {
                final int offset = (viewFlags & SCROLLBARS_INSET_MASK) == 0
                        ? 0 : getVerticalScrollbarWidth();
                switch (mVerticalScrollbarPosition) {
                    case SCROLLBAR_POSITION_DEFAULT:
                        if (isLayoutRtl()) {
                            left += offset;
                        } else {
                            right += offset;
                        }
                        break;
                    case SCROLLBAR_POSITION_RIGHT:
                        right += offset;
                        break;
                    case SCROLLBAR_POSITION_LEFT:
                        left += offset;
                        break;
                }
            }
            if ((viewFlags & SCROLLBARS_HORIZONTAL) != 0) {
                bottom += (viewFlags & SCROLLBARS_INSET_MASK) == 0
                        ? 0 : getHorizontalScrollbarHeight();
            }
        }

        if (mPaddingLeft != left) {
            changed = true;
            mPaddingLeft = left;
        }
        if (mPaddingTop != top) {
            changed = true;
            mPaddingTop = top;
        }
        if (mPaddingRight != right) {
            changed = true;
            mPaddingRight = right;
        }
        if (mPaddingBottom != bottom) {
            changed = true;
            mPaddingBottom = bottom;
        }

        if (changed) {
            requestLayout();
            invalidateOutline();
        }
    }
```
这里根据消费后的insets，还剩下多少的insets还是设置整个View默认padding数值。一般来说都是设置了toppadding和bottompadding。如果遇到ScrollView这种可能可能横向滚动的View，也会根据剩下的Insets给当前的View设置padding数值。

#### WindowInsets 沉浸式和非沉浸式Padding设置的原理
那么通过什么判断走到这个方法进行Padding的设置呢？
```java
    public static final int SYSTEM_UI_LAYOUT_FLAGS =
            SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;

```

一般来说，普通的ui显示SYSTEM_UI_LAYOUT_FLAGS这个标志位都是关闭的，因此会走到computeSystemWindowInsets上面的分支。

如果设置了透明状态栏，透明导航栏SYSTEM_UI_LAYOUT_FLAGS这个标志位就会打开，走computeSystemWindowInsets下面的分支。因此会返回2个完全不同的结果到上层，进行internalSetPadding设置Padding。

这样透明状态栏就能返回一个(0,0,0,0)的padding，而普通ui显示，则会返回一个(0,状态栏高度相同的间距区域,0,0)。那么是哪里进行设置的呢？

其实实在上方setView中调用collectViewAttributes，获取View的参数。其中getImpliedSystemUiVisibility方法，就是把两个WindowManager.LayoutParams特殊的标志位转化为View的标志位：
```java
    private int getImpliedSystemUiVisibility(WindowManager.LayoutParams params) {
        int vis = 0;
        // Translucent decor window flags imply stable system ui visibility.
        if ((params.flags & WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS) != 0) {
            vis |= View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;
        }
        if ((params.flags & WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION) != 0) {
            vis |= View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
        }
        return vis;
    }
```
通过这种方式，让设置了透明标志位天生获取到的四个padding方向大小就是0.而没有透明(也就是沉浸式)的UI带了(0,状态栏高度相同的间距区域,0,0)四个方向的padding。

注意这个过程中，实际上非沉浸式判断到mAttachInfo.mSystemUiVisibility & SYSTEM_UI_LAYOUT_FLAGS)为0(也就是没打开)，从而是给DecorView这个根布局添加了一个paddingTop的数值是的沉浸式和非沉浸式出现了ui上表现的偏差。

#### 沉浸式下fitsSystemWindows设置原理
弄清楚了沉浸式和非沉浸式之间的区别设置的Padding区别后。fitWindowInsets虽然也是通过computeSystemWindowInsets获取到四个方向的padding，但是原理上是不一样的。

这里我们可以追溯会setContentView中装载DecorView方法。详情可以看[View的初始化](https://www.jianshu.com/p/003dc36af9db)一文。

```java
 private void installDecor() {
        mForceDecorInstall = false;
...
        if (mContentParent == null) {
            mContentParent = generateLayout(mDecor);

            mDecor.makeOptionalFitsSystemWindows();
```
而DecorView中makeOptionalFitsSystemWindows就是核心。位于ViewGroup下面这个方法。
```java
    public void makeOptionalFitsSystemWindows() {
        super.makeOptionalFitsSystemWindows();
        final int count = mChildrenCount;
        final View[] children = mChildren;
        for (int i = 0; i < count; i++) {
            children[i].makeOptionalFitsSystemWindows();
        }
    }

```

```java
    public void makeOptionalFitsSystemWindows() {
        setFlags(OPTIONAL_FITS_SYSTEM_WINDOWS, OPTIONAL_FITS_SYSTEM_WINDOWS);
    }
```
换句话说每一个DecorView的第一层级的子View都带上了OPTIONAL_FITS_SYSTEM_WINDOWS标志位，同时因为带上了这个标志位。由于判断到此时是沉浸式模式SYSTEM_UI_LAYOUT_FLAGS打开了。因此默认不给根布局加padding。

而到了自定义的Xml的根布局之后，因为打开了FITS_SYSTEM_WINDOWS标志位，则fitSystemWindowsInt会开始默认处理Insets的逻辑中。又因为没有打开OPTIONAL_FITS_SYSTEM_WINDOWS标志位，最后给当前这个自定义的布局添加了一个Padding。

#### WindowInsets 具体例子
结合一下上下文，如果此时打开了透明状态栏标志位
```java
getWindow().addFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS)
```
如果我们使用的主题是NoActionBar。则会有如下的表现形式：
![translate_statusbar.png](/images/translate_statusbar.png)
能看到我们什么都没有做的时候，发现整个内容区域都是置顶的，和状态栏重合了。一般我们都会怎么解决呢？
```xml
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    xmlns:tools="http://schemas.android.com/tools"
    android:id="@+id/pp"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:fitsSystemWindows="true"
    android:orientation="vertical">
```
一般我们都会在根布局加一个fitsSystemWindows的标志位，这样内容布局就会在透明状态栏之下。如下图：
![after_fitsw.png](/images/after_fitsw.png)


这里我们为了更加清晰的探索整个过程，我从ViewRootImpl，View.AttachInfo反射了几个关键的属性（反射的是Android 7.0.大体上变化不多，就是少了刘海间距区域）。

下面是没有fitsSystemWindows标志位，透明状态栏的参数：
![translate_statusbar_params.png](/images/translate_statusbar_params.png)



- 1.能看到所有的Insets如mContentInsets，mStableInsets，mVisibleInsets都是左右底为0，上为72.只有代表过扫描区域mOverscanInsets的是0，这些数据都是通过addToDisplay(实际上就是WMS的addWindow)获取到的。

- 2.mWindowFrame就是上文一直提到过的，绘制准备阶段需要绘制的大小，也就是全屏幕的高度。

- 3.而在布局文件中也没有设置padding，所以padding都为0。

- 4.默认情况下，所有区域的消费只有mWindowDecorInsetsConsumed，也就是Decor内容区域消费了间距。

接下来看看打开了fitsSystemWindows标志位的参数：
![fitsystemwindow_params.png](/images/fitsystemwindow_params.png)

能看到实际上这个过程中只有打了fitSystemWindows标志位的View，自带了一个高度差和WindowInsets一致的mPaddingTop。也就符合上述的逻辑。正是因为这个PaddingTop的存在，透明的状态栏下方的颜色就是背景色。

其他的参数其实在addToDisplay中已经决定好了Insets的大小，因此会都一致。

请注意这里的标志位，只有mWindowDecorInsetsConsumed设置为true，其他都为false。由于Android 9.0这些属性和方法不少是hidden的，因此我反射的是Android 7.0的，除了没有刘海区域，几乎逻辑还是一致。

那么问题来了，为什么透明状态栏的标志位一旦打开，整个内容布局就顶上了呢？这里的就需要看下面的relayoutWindow方法了。、




### 重新计算Window大小以及根据大小准备对应的Surface
```java
        if (mFirst || windowShouldResize || insetsChanged ||
                viewVisibilityChanged || params != null || mForceNextWindowRelayout) {
            mForceNextWindowRelayout = false;

            if (isViewVisible) {

                insetsPending = computesInternalInsets && (mFirst || viewVisibilityChanged);
            }
            if (mSurfaceHolder != null) {
                mSurfaceHolder.mSurfaceLock.lock();
                mDrawingAllowed = true;
            }

            boolean hwInitialized = false;
            boolean contentInsetsChanged = false;
            boolean hadSurface = mSurface.isValid();

            try {

                if (mAttachInfo.mThreadedRenderer != null) {
                    if (mAttachInfo.mThreadedRenderer.pauseSurface(mSurface)) {
                        mDirty.set(0, 0, mWidth, mHeight);
                    }
                    mChoreographer.mFrameInfo.addFlags(FrameInfo.FLAG_WINDOW_LAYOUT_CHANGED);
                }
                relayoutResult = relayoutWindow(params, viewVisibility, insetsPending);



                if (!mPendingMergedConfiguration.equals(mLastReportedMergedConfiguration)) {

                    performConfigurationChange(mPendingMergedConfiguration, !mFirst,
                            INVALID_DISPLAY /* same display */);
                    updatedConfiguration = true;
                }

                final boolean overscanInsetsChanged = !mPendingOverscanInsets.equals(
                        mAttachInfo.mOverscanInsets);
                contentInsetsChanged = !mPendingContentInsets.equals(
                        mAttachInfo.mContentInsets);
                final boolean visibleInsetsChanged = !mPendingVisibleInsets.equals(
                        mAttachInfo.mVisibleInsets);
                final boolean stableInsetsChanged = !mPendingStableInsets.equals(
                        mAttachInfo.mStableInsets);
                final boolean cutoutChanged = !mPendingDisplayCutout.equals(
                        mAttachInfo.mDisplayCutout);
                final boolean outsetsChanged = !mPendingOutsets.equals(mAttachInfo.mOutsets);
                final boolean surfaceSizeChanged = (relayoutResult
                        & WindowManagerGlobal.RELAYOUT_RES_SURFACE_RESIZED) != 0;
                surfaceChanged |= surfaceSizeChanged;
                final boolean alwaysConsumeNavBarChanged =
                        mPendingAlwaysConsumeNavBar != mAttachInfo.mAlwaysConsumeNavBar;
                if (contentInsetsChanged) {
                    mAttachInfo.mContentInsets.set(mPendingContentInsets);
                }
                if (overscanInsetsChanged) {
                    mAttachInfo.mOverscanInsets.set(mPendingOverscanInsets);

                    contentInsetsChanged = true;
                }
                if (stableInsetsChanged) {
                    mAttachInfo.mStableInsets.set(mPendingStableInsets);
                    contentInsetsChanged = true;
                }
                if (cutoutChanged) {
                    mAttachInfo.mDisplayCutout.set(mPendingDisplayCutout);

                    contentInsetsChanged = true;
                }
                if (alwaysConsumeNavBarChanged) {
                    mAttachInfo.mAlwaysConsumeNavBar = mPendingAlwaysConsumeNavBar;
                    contentInsetsChanged = true;
                }
                if (contentInsetsChanged || mLastSystemUiVisibility !=
                        mAttachInfo.mSystemUiVisibility || mApplyInsetsRequested
                        || mLastOverscanRequested != mAttachInfo.mOverscanRequested
                        || outsetsChanged) {
                    mLastSystemUiVisibility = mAttachInfo.mSystemUiVisibility;
                    mLastOverscanRequested = mAttachInfo.mOverscanRequested;
                    mAttachInfo.mOutsets.set(mPendingOutsets);
                    mApplyInsetsRequested = false;
                    dispatchApplyInsets(host);
                }
                if (visibleInsetsChanged) {
                    mAttachInfo.mVisibleInsets.set(mPendingVisibleInsets);
                }

                if (!hadSurface) {
                    if (mSurface.isValid()) {
                        newSurface = true;
                        mFullRedrawNeeded = true;
                        mPreviousTransparentRegion.setEmpty();

                        if (mAttachInfo.mThreadedRenderer != null) {
                            try {
                                hwInitialized = mAttachInfo.mThreadedRenderer.initialize(
                                        mSurface);
                                if (hwInitialized && (host.mPrivateFlags
                                        & View.PFLAG_REQUEST_TRANSPARENT_REGIONS) == 0) {
                                    mSurface.allocateBuffers();
                                }
                            } catch (OutOfResourcesException e) {
                                handleOutOfResourcesException(e);
                                return;
                            }
                        }
                    }
                } else if (!mSurface.isValid()) {

                    if (mLastScrolledFocus != null) {
                        mLastScrolledFocus.clear();
                    }
                    mScrollY = mCurScrollY = 0;
                    if (mView instanceof RootViewSurfaceTaker) {
                        ((RootViewSurfaceTaker) mView).onRootViewScrollYChanged(mCurScrollY);
                    }
                    if (mScroller != null) {
                        mScroller.abortAnimation();
                    }
                    // Our surface is gone
                    if (mAttachInfo.mThreadedRenderer != null &&
                            mAttachInfo.mThreadedRenderer.isEnabled()) {
                        mAttachInfo.mThreadedRenderer.destroy();
                    }
                } else if ((surfaceGenerationId != mSurface.getGenerationId()
                        || surfaceSizeChanged || windowRelayoutWasForced)
                        && mSurfaceHolder == null
                        && mAttachInfo.mThreadedRenderer != null) {
                    mFullRedrawNeeded = true;
                    try {
                        mAttachInfo.mThreadedRenderer.updateSurface(mSurface);
                    } catch (OutOfResourcesException e) {
                        handleOutOfResourcesException(e);
                        return;
                    }
                }

                final boolean freeformResizing = (relayoutResult
                        & WindowManagerGlobal.RELAYOUT_RES_DRAG_RESIZING_FREEFORM) != 0;
                final boolean dockedResizing = (relayoutResult
                        & WindowManagerGlobal.RELAYOUT_RES_DRAG_RESIZING_DOCKED) != 0;
                final boolean dragResizing = freeformResizing || dockedResizing;
                if (mDragResizing != dragResizing) {
                    if (dragResizing) {
                        mResizeMode = freeformResizing
                                ? RESIZE_MODE_FREEFORM
                                : RESIZE_MODE_DOCKED_DIVIDER;
                        // TODO: Need cutout?
                        startDragResizing(mPendingBackDropFrame,
                                mWinFrame.equals(mPendingBackDropFrame), mPendingVisibleInsets,
                                mPendingStableInsets, mResizeMode);
                    } else {
                        endDragResizing();
                    }
                }
                if (!mUseMTRenderer) {
                    if (dragResizing) {
                        mCanvasOffsetX = mWinFrame.left;
                        mCanvasOffsetY = mWinFrame.top;
                    } else {
                        mCanvasOffsetX = mCanvasOffsetY = 0;
                    }
                }
            } catch (RemoteException e) {
            }


            mAttachInfo.mWindowLeft = frame.left;
            mAttachInfo.mWindowTop = frame.top;

            if (mWidth != frame.width() || mHeight != frame.height()) {
                mWidth = frame.width();
                mHeight = frame.height();
            }

            if (mSurfaceHolder != null) {
                if (mSurface.isValid()) {
                    mSurfaceHolder.mSurface = mSurface;
                }
                mSurfaceHolder.setSurfaceFrameSize(mWidth, mHeight);
                mSurfaceHolder.mSurfaceLock.unlock();
                if (mSurface.isValid()) {
                    if (!hadSurface) {
                        mSurfaceHolder.ungetCallbacks();

                        mIsCreating = true;
                        SurfaceHolder.Callback callbacks[] = mSurfaceHolder.getCallbacks();
                        if (callbacks != null) {
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceCreated(mSurfaceHolder);
                            }
                        }
                        surfaceChanged = true;
                    }
                    if (surfaceChanged || surfaceGenerationId != mSurface.getGenerationId()) {
                        SurfaceHolder.Callback callbacks[] = mSurfaceHolder.getCallbacks();
                        if (callbacks != null) {
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceChanged(mSurfaceHolder, lp.format,
                                        mWidth, mHeight);
                            }
                        }
                    }
                    mIsCreating = false;
                } else if (hadSurface) {
                    mSurfaceHolder.ungetCallbacks();
                    SurfaceHolder.Callback callbacks[] = mSurfaceHolder.getCallbacks();
                    if (callbacks != null) {
                        for (SurfaceHolder.Callback c : callbacks) {
                            c.surfaceDestroyed(mSurfaceHolder);
                        }
                    }
                    mSurfaceHolder.mSurfaceLock.lock();
                    try {
                        mSurfaceHolder.mSurface = new Surface();
                    } finally {
                        mSurfaceHolder.mSurfaceLock.unlock();
                    }
                }
            }

            final ThreadedRenderer threadedRenderer = mAttachInfo.mThreadedRenderer;
            if (threadedRenderer != null && threadedRenderer.isEnabled()) {
                if (hwInitialized
                        || mWidth != threadedRenderer.getWidth()
                        || mHeight != threadedRenderer.getHeight()
                        || mNeedsRendererSetup) {
                    threadedRenderer.setup(mWidth, mHeight, mAttachInfo,
                            mWindowAttributes.surfaceInsets);
                    mNeedsRendererSetup = false;
                }
            }

```
在这里完成的事情有如下几件事：
- 1. 把设置在WindowManager.LayoutParams中参数(如透明状态栏等标志位)传递到relayoutWindow 方法中对整个PhoneWindow的大小进行计算。关于这一块的内容本文就不多讲了，可以阅读我写的[计算窗体的大小](https://www.jianshu.com/p/e83496ca788c)一文有详细讲解整个计算流程，以及状态栏下的内容是怎么通过WindowManager.LayoutParams参数进行区域的确定。


- 2.发现如果各个区域可视的状态发生了变化则需要重新分发一次WindowInsets重新给合适的View设置padding。

- 3.更新Surface的状态。如果发现mThreadedRenderer不为空，且Surface有效，并且还没有初始化，则调用mThreadedRenderer.initialize初始化硬件渲染的Surface。

- 4.如果发现Surface失效了，则会调用mThreadedRenderer.destroy销毁硬件渲染对象。

- 5.如果发现Surface的大小更新了，则会mThreadedRenderer.updateSurface更新硬件渲染对应Surface下的大小。

- 6.mSurfaceHolder如果不为空，则按照对应的行为，依次回调surfaceCreated，surfaceChanged，surfaceDestroyed返回给监听者。

- 7.发现如果硬件渲染需要装载Surface初始化，则调用threadedRenderer.setup方法进行初始化。

## 总结
到这里，View的绘制流程准备就完毕了。

在进行onMeasure之前，会执行比较重要的准备步骤，这里涉及到了整个ViewRootImpl的绘制范围。可以大致分为五个简单的步骤：
- 1. addToDisplay 初步计算Window的各个间距屏幕数值
- 2.dispatchAttachedToWindow
- 3.dispatchApplyWindowInsets
- 4.relayoutWindow 计算窗体的大小以及位置
- 5.准备硬件渲染

### addToDisplay总结
本质上，就是调用WMS的addWindow方法。这个过程会把当前的PhoneWindow的远程对象保存到WMS中进行管理。同时会把IMS服务也通过这个方法保存会App端。在这里还做了另一件重要的事情，那就是把窗体中每个不同区域距离屏幕的间距获取出来，返回给App端进行消费处理。

在这之后就会通过Choreographer监听Vsync的同步信号，开始真正的View树遍历与绘制。

### dispatchAttachedToWindow的总结

dispatchAttachedToWindow本质上是View第一次绑定到整个ViewRootImpl中的View的绘制树中调用的方法。其核心实际上就是绑定同步了贯通ViewRootImpl绘制流程的参数。如WindowInests，窗体是否可见，根部布局，硬件渲染对象，屏幕状态，以及WindowSession的Binder通信者等等。有了这个贯通绘制的上下文，ViewRootImpl就能更好的管理每一个View的绘制。

在分发的过程中，也会对AutoFillManagerService进行初始化。以及对View的外框绘制对象Outline进行初始化。


### dispatchApplyWindowInsets的总结
这个过程实际上就是处理如fitSysytemWindows标志位的状态。本质上是Android窗体之间本身就会和屏幕有自己的间距。但是可以在这个步骤消费掉，抹除这些间距。常见的如刘海屏的适配，透明导航栏和透明状态栏的适配。

当我们没有打开这些特殊的WindowManager.LayoutParams的标志位的时候，整个屏幕是正常结构，内容区域在状态栏区域之下。

之所以在透明状态栏，透明状态栏下设置fitSysytemWindow才起作用，而没有任何标志位的普通显示的View树不起作用。是因为在ViewRootImpl的setView阶段，解析了WindowManager.LayoutParams中的两个特殊沉浸式flags，转化为View中的flag。

而在分发消费Insets的过程中，computeSystemWindowInsets判断了应该计算返回多少大小的Inset区域，进而给当前View四个方向的padding设置对应的数值。这才是fitSysytemWindows的核心思想。

如果设置了透明状态栏，由于判断到SYSTEM_UI_LAYOUT_FLAGS默认是打开（因为这个标志位包含了隐藏导航栏和全屏）就会返回(0,0,0,0)的四个padding数值。普通状态栏则会返回(0,状态栏高度,0,0)给Decorview这个布局。

fitSystemWindows标志位只有在沉浸式模式才有效，是因为在非沉浸式模式下，已经在DecorView的子层级中把这个Insets消费了。永远不会到达我们自定义的布局中进行padding的设置。而fitSystemWindows在沉浸式中起效，主要是因为该View没有打上OPTIONAL_FITS_SYSTEM_WINDOWS标志位，同时打了FITS_SYSTEM_WINDOWS标志位。

而OPTIONAL_FITS_SYSTEM_WINDOWS标志位，在沉浸式模式下就会跳开计算Insets的大小。这就是这个注解的来源。

#### relayoutWindow总结
当我们准备好了Window的大小，以及距离绘制区域的padding数值，就开始把数据交给WMS的relayoutWindow方法，基于整个Android的系统的计算。其中状态栏，和内容区域的真正摆放位置也是在这个方法中决定的。

详情请看[Android 重学系列 WMS在Activity启动中的职责 计算窗体的大小(四)](https://www.jianshu.com/p/e83496ca788c)

#### 准备硬件渲染总结
初始化可以分为如下3个步骤：
- 1.mThreadedRenderer.initialize
- 2.mThreadedRenderer.updateSurface
- 3.threadedRenderer.setup

销毁则是
- 4.mThreadedRenderer.destroy

记住硬件渲染对象初始化3个步骤以及销毁。之后会有专题进行分析。

## 后话
之前零零散散的知识和文章可以看到要开始串联起来了。这个沉浸式和非沉浸式的计算模式倒是有点绕。不过明白了之后，以前感觉黑箱的操作也明了了。也知道在5年前刚入行时候，感觉在低版本机子设置paddingTop从而达到沉浸式的样式有点low觉得背后有什么魔法。实际上经过文章一分析，确实也是靠着padding做事情，看来很多东西看起来复杂，实际上也不过如此。






