---
title: Android 重学系列 SurfaceView和TextureView 源码浅析(上)
top: false
cover: false
date: 2020-04-12 17:42:38
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android
- Android Framework
---
# 前言
时隔一个月，回来继续写文章了。这个月写了一个关于自定义Camera的需求，想了想干脆实现一个滤镜相机好了，以回顾之前学习OpenGL es的知识。

Android重学系列原定计划是，先解析View的绘制流程，接着解析Skia的核心原理。既然遇上了这个Camera的需求，以及后续自定义视频的需求。不如乘热打铁，先来聊一聊SurfaceView和TextureView的核心原理，顺便开启Skia源码的初始化之旅。本文暂时不会聊Camera自定义的经验之说，先打好基础再来聊会印象深刻很多。

如果遇到问题可以来这里聊一聊：[https://www.jianshu.com/p/bbec5c1aa00e](https://www.jianshu.com/p/bbec5c1aa00e)


# 正文
面试的时候，经常会有人问SurfaceView的核心原理是什么？TextureView和SurfaceView的区别是什么呢？有这么一个说法，回答道SurfaceView在绘制的View中挖了一个洞，让自己的需要绘制内容填充到洞中里面。如此抽象回答，有没有探索过背后的真实原理呢？接下来让我们来研读一下吧。

## SurfaceView的源码设计浅析
SurfaceView一般是用来干啥的？这是一个控制单个Surface的View。还记得和大家聊过的SurfaceFlinger系列文章吗？在SF第一定律中，我就聊到过所有的图元都是以Surface为基本单位进行传输。

实际上在Activity中一个大的ViewRootImpl中，本质上就是一个超级的SurfaceView，通过View绘制三大流程的获得结果后，把像素传送到SF进程中进行处理。那么SurfaceView也是同理的思路，控制一个自己Surface把数据传送到SF处理。如下图：

从这种设计上来看SurfaceView和整个ViewRootImpl有一种各自为政的感觉。因此ViewRootImpl很多行为都难以控制SurfaceView也是可以理解了。

设计层面上，聊了这么多。我们直接看看源码。

## SurfaceView 源码浅析
那么View的源码该如何看？我个人认为想要明白View的原理，核心有如下几个部分：
- 1.构造函数中参数的解析
- 2.阅读onMeasure,onLayout,onDraw三个View的绘制流程
- 3.阅读在Activity的onResume时候调用的onAttachedToWindow，以及在onDestroy调用的onDetachedFromWindow。看看View在View在预备和销毁做了什么事情
- 4.阅读View自己的独有的api实现。

关于SurfaceView如何使用可以看这一篇文章[Skia的初探](https://www.jianshu.com/p/b2e696fa0903)

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[SurfaceView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/SurfaceView.java)

那么我们现在先来看看SurfaceView的构造函数。
```java
    public SurfaceView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        mRenderNode.requestPositionUpdates(this);

        setWillNotDraw(true);
    }
```
- 1.RenderNode的requestPositionUpdates
- 2.setWillNotDraw 关闭onDraw的回调。一般这个标志位的设置，都是ViewGroup默认设置的，目的是不让ViewGroup调用onDraw方法，降低性能消耗。

RenderNode 是什么东西？这里先简单理解为，每一个View对应在硬件加速开启下的一个绘制节点。当我们打开了硬件加速了，绘制流程将不会走到drawSoftware，转而调用mHardwareRenderer的draw方法进行绘制。

为了让软硬件绘制能够同步，Android会先对其进行相关的参数存储下来。requestPositionUpdates在这里是指我们需要把SurfaceView对应RendNode位置进行更新。

这里不展开讨论，到后面会有专题和大家聊聊。

### SurfaceView的 onMeasure,onLayout,onDraw
每一个View都会经历各自的3大绘制流程，这个流程收到自己设置的大小和位置以及父布局的大小和位置的印象。SurfaceView会稍稍有点不同。提到SurfaceView就会提到SurfaceHolder。我们来看看SurfaceHolder是如何影响SurfaceView的绘制流程的。

#### SurfaceView onMeasure
```java
 @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int width = mRequestedWidth >= 0
                ? resolveSizeAndState(mRequestedWidth, widthMeasureSpec, 0)
                : getDefaultSize(0, widthMeasureSpec);
        int height = mRequestedHeight >= 0
                ? resolveSizeAndState(mRequestedHeight, heightMeasureSpec, 0)
                : getDefaultSize(0, heightMeasureSpec);
        setMeasuredDimension(width, height);
    }
```
在onMeasure中实际上这个宽高，除了受到父布局之外，还受到mRequestedWidth和mRequestedHeight影响。这两个参数从哪里来的呢？

本质上就是受到SurfaceHolder中的setFixedSize影响
```java
   @Override
        public void setFixedSize(int width, int height) {
            if (mRequestedWidth != width || mRequestedHeight != height) {
                mRequestedWidth = width;
                mRequestedHeight = height;
                requestLayout();
            }
        }
```
换句话说，SurfaceView的宽高将会通过SurfaceHolder的变化而变化。


####  SurfaceView draw
```java
 @Override
    public void draw(Canvas canvas) {
        if (mDrawFinished && !isAboveParent()) {
            // draw() is not called when SKIP_DRAW is set
            if ((mPrivateFlags & PFLAG_SKIP_DRAW) == 0) {
                // punch a whole in the view-hierarchy below us
                canvas.drawColor(0, PorterDuff.Mode.CLEAR);
            }
        }
        super.draw(canvas);
    }

   @Override
    protected void dispatchDraw(Canvas canvas) {
        if (mDrawFinished && !isAboveParent()) {
            // draw() is not called when SKIP_DRAW is set
            if ((mPrivateFlags & PFLAG_SKIP_DRAW) == PFLAG_SKIP_DRAW) {
                // punch a whole in the view-hierarchy below us
                canvas.drawColor(0, PorterDuff.Mode.CLEAR);
            }
        }
        super.dispatchDraw(canvas);
    }
```
onLayout继承View的逻辑并没有可说的。假设我们把SurfaceView的setWillNotDraw标志关闭了，走到了dispatchDraw和draw方法。

为了避免SurfaceView被Canvas合成影响，会判断当前Surface的Layer层级，如果是小于0的应用图层说明是不是浮在应用之上，直接清空Canvas中的像素。

如果是SurfaceView一些属性设置结束后，会打开mDrawFinished标志，清空背景颜色。

```
    private boolean isAboveParent() {
        return mSubLayer >= 0;
    }
```

因此在SurfaceView的draw流程中不会做任何事情。

### SurfaceView onAttachedToWindow
```java
    private final ViewTreeObserver.OnScrollChangedListener mScrollChangedListener
            = new ViewTreeObserver.OnScrollChangedListener() {
                    @Override
                    public void onScrollChanged() {
                        updateSurface();
                    }
            };

    private final ViewTreeObserver.OnPreDrawListener mDrawListener =
            new ViewTreeObserver.OnPreDrawListener() {
                @Override
                public boolean onPreDraw() {
                    // reposition ourselves where the surface is
                    mHaveFrame = getWidth() > 0 && getHeight() > 0;
                    updateSurface();
                    return true;
                }
            };


protected void onAttachedToWindow() {
        super.onAttachedToWindow();

        getViewRootImpl().addWindowStoppedCallback(this);
        mWindowStopped = false;

        mViewVisibility = getVisibility() == VISIBLE;
        updateRequestedVisibility();

        mAttachedToWindow = true;
        mParent.requestTransparentRegion(SurfaceView.this);
        if (!mGlobalListenersAdded) {
            ViewTreeObserver observer = getViewTreeObserver();
            observer.addOnScrollChangedListener(mScrollChangedListener);
            observer.addOnPreDrawListener(mDrawListener);
            mGlobalListenersAdded = true;
        }
    }
```
当Activity resume开始构建View的显示tree时候，会调用每一个View的onAttachedToWindow方法，此时，会为SurfaceView添加两个监听，一个是滑动，一个是准备调用draw时候的监听。两者都会调用updateSurface，用于更新SurfaceView的内部Surface的属性。

addWindowStoppedCallback 监听Activity的stop流程，设置标志为监听
```
    /** @hide */
    @Override
    public void windowStopped(boolean stopped) {
        mWindowStopped = stopped;
        updateRequestedVisibility();
        updateSurface();
    }
```

到目前为止，我们都没有看到SurfaceView从哪里诞生出Surface的，但是可以猜测在draw之前的阶段会调用一次updateSurface，生成一个新的Surface。

### SurfaceView onDetachedFromWindow
```java
    protected void onDetachedFromWindow() {
        ViewRootImpl viewRoot = getViewRootImpl();
        // It's possible to create a SurfaceView using the default constructor and never
        // attach it to a view hierarchy, this is a common use case when dealing with
        // OpenGL. A developer will probably create a new GLSurfaceView, and let it manage
        // the lifecycle. Instead of attaching it to a view, he/she can just pass
        // the SurfaceHolder forward, most live wallpapers do it.
        if (viewRoot != null) {
            viewRoot.removeWindowStoppedCallback(this);
        }

        mAttachedToWindow = false;
        if (mGlobalListenersAdded) {
            ViewTreeObserver observer = getViewTreeObserver();
            observer.removeOnScrollChangedListener(mScrollChangedListener);
            observer.removeOnPreDrawListener(mDrawListener);
            mGlobalListenersAdded = false;
        }

        while (mPendingReportDraws > 0) {
            notifyDrawFinished();
        }

        mRequestedVisible = false;

        updateSurface();
        if (mSurfaceControl != null) {
            mSurfaceControl.destroy();
        }
        mSurfaceControl = null;

        mHaveFrame = false;

        super.onDetachedFromWindow();
    }
```

首先清除了对ActivityStop的监听，其次是移除所有对Viewtree滑动和准备绘制的监听，以及检测还有多少draw没有执行，一口气都消费了，最后调用updateSurface更新Surface的状态。并销毁所有的数据。

到这里我们还是能看到核心方法updateSurface。那么就让我们看看核心方法updateSurface中完成了什么事情。

### SurfaceView updateSurface
```java
 /** @hide */
    protected void updateSurface() {
        if (!mHaveFrame) {
            return;
        }
        ViewRootImpl viewRoot = getViewRootImpl();
        if (viewRoot == null || viewRoot.mSurface == null || !viewRoot.mSurface.isValid()) {
            return;
        }

        mTranslator = viewRoot.mTranslator;
        if (mTranslator != null) {
            mSurface.setCompatibilityTranslator(mTranslator);
        }

        int myWidth = mRequestedWidth;
        if (myWidth <= 0) myWidth = getWidth();
        int myHeight = mRequestedHeight;
        if (myHeight <= 0) myHeight = getHeight();

        final boolean formatChanged = mFormat != mRequestedFormat;
        final boolean visibleChanged = mVisible != mRequestedVisible;
        final boolean creating = (mSurfaceControl == null || formatChanged || visibleChanged)
                && mRequestedVisible;
        final boolean sizeChanged = mSurfaceWidth != myWidth || mSurfaceHeight != myHeight;
        final boolean windowVisibleChanged = mWindowVisibility != mLastWindowVisibility;
        boolean redrawNeeded = false;

        if (creating || formatChanged || sizeChanged || visibleChanged || windowVisibleChanged) {
            getLocationInWindow(mLocation);

...

            try {
                final boolean visible = mVisible = mRequestedVisible;
                mWindowSpaceLeft = mLocation[0];
                mWindowSpaceTop = mLocation[1];
                mSurfaceWidth = myWidth;
                mSurfaceHeight = myHeight;
                mFormat = mRequestedFormat;
                mLastWindowVisibility = mWindowVisibility;

                mScreenRect.left = mWindowSpaceLeft;
                mScreenRect.top = mWindowSpaceTop;
                mScreenRect.right = mWindowSpaceLeft + getWidth();
                mScreenRect.bottom = mWindowSpaceTop + getHeight();
                if (mTranslator != null) {
                    mTranslator.translateRectInAppWindowToScreen(mScreenRect);
                }

                final Rect surfaceInsets = getParentSurfaceInsets();
                mScreenRect.offset(surfaceInsets.left, surfaceInsets.top);

                if (creating) {
                    mSurfaceSession = new SurfaceSession(viewRoot.mSurface);
                    mDeferredDestroySurfaceControl = mSurfaceControl;

                    updateOpaqueFlag();
                    final String name = "SurfaceView - " + viewRoot.getTitle().toString();

                    mSurfaceControl = new SurfaceControlWithBackground(
                            name,
                            (mSurfaceFlags & SurfaceControl.OPAQUE) != 0,
                            new SurfaceControl.Builder(mSurfaceSession)
                                    .setSize(mSurfaceWidth, mSurfaceHeight)
                                    .setFormat(mFormat)
                                    .setFlags(mSurfaceFlags));
                } else if (mSurfaceControl == null) {
                    return;
                }

                boolean realSizeChanged = false;

                mSurfaceLock.lock();
                try {
                    mDrawingStopped = !visible;


                    SurfaceControl.openTransaction();
                    try {
                        mSurfaceControl.setLayer(mSubLayer);
                        if (mViewVisibility) {
                            mSurfaceControl.show();
                        } else {
                            mSurfaceControl.hide();
                        }

                        // While creating the surface, we will set it's initial
                        // geometry. Outside of that though, we should generally
                        // leave it to the RenderThread.
                        //
                        // There is one more case when the buffer size changes we aren't yet
                        // prepared to sync (as even following the transaction applying
                        // we still need to latch a buffer).
                        // b/28866173
                        if (sizeChanged || creating || !mRtHandlingPositionUpdates) {
                            mSurfaceControl.setPosition(mScreenRect.left, mScreenRect.top);
                            mSurfaceControl.setMatrix(mScreenRect.width() / (float) mSurfaceWidth,
                                    0.0f, 0.0f,
                                    mScreenRect.height() / (float) mSurfaceHeight);
                        }
                        if (sizeChanged) {
                            mSurfaceControl.setSize(mSurfaceWidth, mSurfaceHeight);
                        }
                    } finally {
                        SurfaceControl.closeTransaction();
                    }

                    if (sizeChanged || creating) {
                        redrawNeeded = true;
                    }

                    mSurfaceFrame.left = 0;
                    mSurfaceFrame.top = 0;
                    if (mTranslator == null) {
                        mSurfaceFrame.right = mSurfaceWidth;
                        mSurfaceFrame.bottom = mSurfaceHeight;
                    } else {
                        float appInvertedScale = mTranslator.applicationInvertedScale;
                        mSurfaceFrame.right = (int) (mSurfaceWidth * appInvertedScale + 0.5f);
                        mSurfaceFrame.bottom = (int) (mSurfaceHeight * appInvertedScale + 0.5f);
                    }

                    final int surfaceWidth = mSurfaceFrame.right;
                    final int surfaceHeight = mSurfaceFrame.bottom;
                    realSizeChanged = mLastSurfaceWidth != surfaceWidth
                            || mLastSurfaceHeight != surfaceHeight;
                    mLastSurfaceWidth = surfaceWidth;
                    mLastSurfaceHeight = surfaceHeight;
                } finally {
                    mSurfaceLock.unlock();
                }

                try {
                    redrawNeeded |= visible && !mDrawFinished;

                    SurfaceHolder.Callback callbacks[] = null;

                    final boolean surfaceChanged = creating;
                    if (mSurfaceCreated && (surfaceChanged || (!visible && visibleChanged))) {
                        mSurfaceCreated = false;
                        if (mSurface.isValid()) {
...
                            callbacks = getSurfaceCallbacks();
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceDestroyed(mSurfaceHolder);
                            }
                            // Since Android N the same surface may be reused and given to us
                            // again by the system server at a later point. However
                            // as we didn't do this in previous releases, clients weren't
                            // necessarily required to clean up properly in
                            // surfaceDestroyed. This leads to problems for example when
                            // clients don't destroy their EGL context, and try
                            // and create a new one on the same surface following reuse.
                            // Since there is no valid use of the surface in-between
                            // surfaceDestroyed and surfaceCreated, we force a disconnect,
                            // so the next connect will always work if we end up reusing
                            // the surface.
                            if (mSurface.isValid()) {
                                mSurface.forceScopedDisconnect();
                            }
                        }
                    }

                    if (creating) {
                        mSurface.copyFrom(mSurfaceControl);
                    }

                    if (sizeChanged && getContext().getApplicationInfo().targetSdkVersion
                            < Build.VERSION_CODES.O) {
                        // Some legacy applications use the underlying native {@link Surface} object
                        // as a key to whether anything has changed. In these cases, updates to the
                        // existing {@link Surface} will be ignored when the size changes.
                        // Therefore, we must explicitly recreate the {@link Surface} in these
                        // cases.
                        mSurface.createFrom(mSurfaceControl);
                    }

                    if (visible && mSurface.isValid()) {
                        if (!mSurfaceCreated && (surfaceChanged || visibleChanged)) {
                            mSurfaceCreated = true;
                            mIsCreating = true;

                            if (callbacks == null) {
                                callbacks = getSurfaceCallbacks();
                            }
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceCreated(mSurfaceHolder);
                            }
                        }
                        if (creating || formatChanged || sizeChanged
                                || visibleChanged || realSizeChanged) {

                            if (callbacks == null) {
                                callbacks = getSurfaceCallbacks();
                            }
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceChanged(mSurfaceHolder, mFormat, myWidth, myHeight);
                            }
                        }
                        if (redrawNeeded) {

                            if (callbacks == null) {
                                callbacks = getSurfaceCallbacks();
                            }

                            mPendingReportDraws++;
                            viewRoot.drawPending();
                            SurfaceCallbackHelper sch =
                                    new SurfaceCallbackHelper(this::onDrawFinished);
                            sch.dispatchSurfaceRedrawNeededAsync(mSurfaceHolder, callbacks);
                        }
                    }
                } finally {
                    mIsCreating = false;
                    if (mSurfaceControl != null && !mSurfaceCreated) {
                        mSurface.release();

                        mSurfaceControl.destroy();
                        mSurfaceControl = null;
                    }
                }
            } catch (Exception ex) {
                Log.e(TAG, "Exception configuring surface", ex);
            }

        } else {
            // Calculate the window position in case RT loses the window
            // and we need to fallback to a UI-thread driven position update
            getLocationInSurface(mLocation);
            final boolean positionChanged = mWindowSpaceLeft != mLocation[0]
                    || mWindowSpaceTop != mLocation[1];
            final boolean layoutSizeChanged = getWidth() != mScreenRect.width()
                    || getHeight() != mScreenRect.height();
            if (positionChanged || layoutSizeChanged) { // Only the position has changed
                mWindowSpaceLeft = mLocation[0];
                mWindowSpaceTop = mLocation[1];
                // For our size changed check, we keep mScreenRect.width() and mScreenRect.height()
                // in view local space.
                mLocation[0] = getWidth();
                mLocation[1] = getHeight();

                mScreenRect.set(mWindowSpaceLeft, mWindowSpaceTop,
                        mWindowSpaceLeft + mLocation[0], mWindowSpaceTop + mLocation[1]);

                if (mTranslator != null) {
                    mTranslator.translateRectInAppWindowToScreen(mScreenRect);
                }

                if (mSurfaceControl == null) {
                    return;
                }

                if (!isHardwareAccelerated() || !mRtHandlingPositionUpdates) {
                    try {

                        setParentSpaceRectangle(mScreenRect, -1);
                    } catch (Exception ex) {
                        Log.e(TAG, "Exception configuring surface", ex);
                    }
                }
            }
        }
    }
```
这里面的逻辑有点长，是依赖标志为实现SurfaceView中对应行为。其实我们可以把它切割为2个部分进行理解：
- 1.SurfaceView的创建
- 2.SurfaceView大小变化
- 3.SurfaceView的销毁

#### updateSurface SurfaceView的创建
```java
           getLocationInWindow(mLocation);

...

            try {
                final boolean visible = mVisible = mRequestedVisible;
                mWindowSpaceLeft = mLocation[0];
                mWindowSpaceTop = mLocation[1];
                mSurfaceWidth = myWidth;
                mSurfaceHeight = myHeight;
                mFormat = mRequestedFormat;
                mLastWindowVisibility = mWindowVisibility;

                mScreenRect.left = mWindowSpaceLeft;
                mScreenRect.top = mWindowSpaceTop;
                mScreenRect.right = mWindowSpaceLeft + getWidth();
                mScreenRect.bottom = mWindowSpaceTop + getHeight();
                if (mTranslator != null) {
                    mTranslator.translateRectInAppWindowToScreen(mScreenRect);
                }

                final Rect surfaceInsets = getParentSurfaceInsets();
                mScreenRect.offset(surfaceInsets.left, surfaceInsets.top);

                if (creating) {
                    mSurfaceSession = new SurfaceSession(viewRoot.mSurface);
                    mDeferredDestroySurfaceControl = mSurfaceControl;

                    updateOpaqueFlag();
                    final String name = "SurfaceView - " + viewRoot.getTitle().toString();

                    mSurfaceControl = new SurfaceControlWithBackground(
                            name,
                            (mSurfaceFlags & SurfaceControl.OPAQUE) != 0,
                            new SurfaceControl.Builder(mSurfaceSession)
                                    .setSize(mSurfaceWidth, mSurfaceHeight)
                                    .setFormat(mFormat)
                                    .setFlags(mSurfaceFlags));
                } else if (mSurfaceControl == null) {
                    return;
                }
                try {
                    redrawNeeded |= visible && !mDrawFinished;

                    SurfaceHolder.Callback callbacks[] = null;

                    final boolean surfaceChanged = creating;
                    if (mSurfaceCreated && (surfaceChanged || (!visible && visibleChanged))) {
                        mSurfaceCreated = false;
                        if (mSurface.isValid()) {
...
                            callbacks = getSurfaceCallbacks();
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceDestroyed(mSurfaceHolder);
                            }
                            if (mSurface.isValid()) {
                                mSurface.forceScopedDisconnect();
                            }
                        }
                    }

                    if (creating) {
                        mSurface.copyFrom(mSurfaceControl);
                    }

                    if (sizeChanged && getContext().getApplicationInfo().targetSdkVersion
                            < Build.VERSION_CODES.O) {
                        mSurface.createFrom(mSurfaceControl);
                    }

                    if (visible && mSurface.isValid()) {
                        if (!mSurfaceCreated && (surfaceChanged || visibleChanged)) {
                            mSurfaceCreated = true;
                            mIsCreating = true;

                            if (callbacks == null) {
                                callbacks = getSurfaceCallbacks();
                            }
                            for (SurfaceHolder.Callback c : callbacks) {
                                c.surfaceCreated(mSurfaceHolder);
                            }
                        }
                        ...
                        if (redrawNeeded) {

                            if (callbacks == null) {
                                callbacks = getSurfaceCallbacks();
                            }

                            mPendingReportDraws++;
                            viewRoot.drawPending();
                            SurfaceCallbackHelper sch =
                                    new SurfaceCallbackHelper(this::onDrawFinished);
                            sch.dispatchSurfaceRedrawNeededAsync(mSurfaceHolder, callbacks);
                        }
                    }
                } finally {
                    mIsCreating = false;
                    if (mSurfaceControl != null && !mSurfaceCreated) {
                        mSurface.release();

                        mSurfaceControl.destroy();
                        mSurfaceControl = null;
                    }
                }
            } catch (Exception ex) {
                Log.e(TAG, "Exception configuring surface", ex);
            }
```
在这个过程中做了如下的事情：
- 1.首先通过ViewTree的构造确定整个View的显示范围和位置，进行处理。
- 2.以当前ViewRootImpl的Surface创建一个SurfaceSession，同时创建一个SurfaceControlWithBackground对象。最后通过copyFrom的方式，把SurfaceControlWithBackground中对应的Surface内容拷贝到当前这个空的Surface中。
- 3.回调SurfaceHolder.Callback 中的surfaceCreated回调。告诉监听者已经创建了Surface。

这里面出现了两个比较重要的类型：
- 1.SurfaceSession Java层用于和SF通信的会话
- 2.SurfaceControlWithBackground 父类为SurfaceControl的Surface控制器

这两类我们都已经在SF系列中和大家详细的解析过他们对应的native层。


### SurfaceSession Surface的会话层
顾名思义，Surface需要和谁进行会话，如果阅读过我之前写的SF解析系列就会明白是向SF进程通信，更加准确一点，是指SF进程中的SurfaceComposerClient进行通信，从而修改Layer中的属性。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[SurfaceSession.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/SurfaceSession.java)

```
public final class SurfaceSession {
    // Note: This field is accessed by native code.
    private long mNativeClient; // SurfaceComposerClient*

    private static native long nativeCreate();
    private static native long nativeCreateScoped(long surfacePtr);
    private static native void nativeDestroy(long ptr);
    private static native void nativeKill(long ptr);

    /** Create a new connection with the surface flinger. */
    public SurfaceSession() {
        mNativeClient = nativeCreate();
    }

    public SurfaceSession(Surface root) {
        mNativeClient = nativeCreateScoped(root.mNativeObject);
    }

    /* no user serviceable parts here ... */
    @Override
    protected void finalize() throws Throwable {
        try {
            if (mNativeClient != 0) {
                nativeDestroy(mNativeClient);
            }
        } finally {
            super.finalize();
        }
    }

    public void kill() {
        nativeKill(mNativeClient);
    }
}
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_SurfaceSession.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_SurfaceSession.cpp)

```cpp
static jlong nativeCreateScoped(JNIEnv* env, jclass clazz, jlong surfaceObject) {
    Surface *parent = reinterpret_cast<Surface*>(surfaceObject);
    SurfaceComposerClient* client = new SurfaceComposerClient(parent->getIGraphicBufferProducer());
    client->incStrong((void*)nativeCreate);
    return reinterpret_cast<jlong>(client);
}
```
能看到此时拿到的就是传进来ViewRootImpl的SurfaceComposerClient，对应在SF进程也就是Client对象。所有的通信都是借助SurfaceComposerClient通信到SF进程。

关于SurfaceComposerClient具体如何工作这里不做讨论，详细的请看[系统启动动画](https://www.jianshu.com/p/a79de4a6d83c)一文。

### SurfaceControlWithBackground  Surface控制器
```java
 class SurfaceControlWithBackground extends SurfaceControl {
        SurfaceControl mBackgroundControl;
        private boolean mOpaque = true;
        public boolean mVisible = false;

        public SurfaceControlWithBackground(String name, boolean opaque, SurfaceControl.Builder b)
                       throws Exception {
            super(b.setName(name).build());

            mBackgroundControl = b.setName("Background for -" + name)
                    .setFormat(OPAQUE)
                    .setColorLayer(true)
                    .build();
            mOpaque = opaque;
        }

        @Override
        public void setAlpha(float alpha) {
            super.setAlpha(alpha);
            mBackgroundControl.setAlpha(alpha);
        }
```
能看到真正在运作的实际上是mBackgroundControl对象，内部的一个SurfaceControl。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[SurfaceControl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/SurfaceControl.java)
```java
        public SurfaceControl build() {
            if (mWidth <= 0 || mHeight <= 0) {
                throw new IllegalArgumentException(
                        "width and height must be set");
            }
            return new SurfaceControl(mSession, mName, mWidth, mHeight, mFormat,
                    mFlags, mParent, mWindowType, mOwnerUid);
        }

```

```java
    private SurfaceControl(SurfaceSession session, String name, int w, int h, int format, int flags,
            SurfaceControl parent, int windowType, int ownerUid)
                    throws OutOfResourcesException, IllegalArgumentException {
        if (session == null) {
            throw new IllegalArgumentException("session must not be null");
        }
        if (name == null) {
            throw new IllegalArgumentException("name must not be null");
        }

        if ((flags & SurfaceControl.HIDDEN) == 0) {
...
        }

        mName = name;
        mWidth = w;
        mHeight = h;
        mNativeObject = nativeCreate(session, name, w, h, format, flags,
            parent != null ? parent.mNativeObject : 0, windowType, ownerUid);
        if (mNativeObject == 0) {
            throw new OutOfResourcesException(
                    "Couldn't allocate SurfaceControl native object");
        }

        mCloseGuard.open("release");
    }
```
能看到此时SurfaceControl在native层调用nativeCreate生成了一个新的对象。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_SurfaceControl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_SurfaceControl.cpp)

```cpp
static jlong nativeCreate(JNIEnv* env, jclass clazz, jobject sessionObj,
        jstring nameStr, jint w, jint h, jint format, jint flags, jlong parentObject,
        jint windowType, jint ownerUid) {
    ScopedUtfChars name(env, nameStr);
    sp<SurfaceComposerClient> client(android_view_SurfaceSession_getClient(env, sessionObj));
    SurfaceControl *parent = reinterpret_cast<SurfaceControl*>(parentObject);
    sp<SurfaceControl> surface;
    status_t err = client->createSurfaceChecked(
            String8(name.c_str()), w, h, format, &surface, flags, parent, windowType, ownerUid);
    if (err == NAME_NOT_FOUND) {
        jniThrowException(env, "java/lang/IllegalArgumentException", NULL);
        return 0;
    } else if (err != NO_ERROR) {
        jniThrowException(env, OutOfResourcesException, NULL);
        return 0;
    }

    surface->incStrong((void *)nativeCreate);
    return reinterpret_cast<jlong>(surface.get());
}
```
能看到此时就是本质上就是在native层创建一个对应的SurfaceControl对象进行控制。这个对象在SF系列中和大家聊过了，可以用于生成一个Surface，控制一个Surface的行为，最后通过SurfaceSession通信到SF进程。


### SurfaceView 独特api lockCanvas和unlockCanvasAndPost
当我们需要绘制SurfaceView之前，会先调用lockCanvas，通过SurfaceView生成一个Canvas，接着在Canvas上使用对应的api，对SKBitmap进行绘制。最后把SkBitmap绘制的结果通过unlockCanvasAndPost，把数据发送到SF进程进行渲染。换句话说，这就是SurfaceView绘制图像的核心api，我们理解其原理，就能明白SurfaceView的渲染机制。

```java
 @Override
        public Canvas lockCanvas() {
            return internalLockCanvas(null, false);
        }

        @Override
        public Canvas lockCanvas(Rect inOutDirty) {
            return internalLockCanvas(inOutDirty, false);
        }
        private Canvas internalLockCanvas(Rect dirty, boolean hardware) {
            mSurfaceLock.lock();

            Canvas c = null;
            if (!mDrawingStopped && mSurfaceControl != null) {
                try {
                    if (hardware) {
                        c = mSurface.lockHardwareCanvas();
                    } else {
                        c = mSurface.lockCanvas(dirty);
                    }
                } catch (Exception e) {
                    Log.e(LOG_TAG, "Exception locking surface", e);
                }
            }


            if (c != null) {
                mLastLockTime = SystemClock.uptimeMillis();
                return c;
            }

            // If the Surface is not ready to be drawn, then return null,
            // but throttle calls to this function so it isn't called more
            // than every 100ms.
            long now = SystemClock.uptimeMillis();
            long nextTime = mLastLockTime + 100;
            if (nextTime > now) {
                try {
                    Thread.sleep(nextTime-now);
                } catch (InterruptedException e) {
                }
                now = SystemClock.uptimeMillis();
            }
            mLastLockTime = now;
            mSurfaceLock.unlock();

            return null;
        }
```
lockCanvas其实可以得出大致上分为2个逻辑：
- 1.打开了硬件加速则调用Surface的lockHardwareCanvas生成一个硬件加速的DisplayListCanvas。
- 2.关闭了硬件加速，也就是软件渲染。则调用lockCanvas生成一个软件渲染的CompatibleCanvas。

如果能获得Surface，则说明Surface已经准备好了可以绘制，则直接返回。如果没有，说明Surface还没有准备好，就不能让App进程请求过于频繁，让当前进程必须100ms之后才能再一次请求生成一个Canvas。

这里我们暂时不讨论DisplayListCanvas的硬件渲染Canvas生成原理，后面会有专门的文章进行讨论。先来看看软件渲染的Canvas是如何生成的。

### Surface lockCanvas
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[Surface.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/Surface.java)

```java
    private final Canvas mCanvas = new CompatibleCanvas();

    public Canvas lockCanvas(Rect inOutDirty)
            throws Surface.OutOfResourcesException, IllegalArgumentException {
        synchronized (mLock) {
            checkNotReleasedLocked();
            if (mLockedObject != 0) {
                throw new IllegalArgumentException("Surface was already locked");
            }
            mLockedObject = nativeLockCanvas(mNativeObject, mCanvas, inOutDirty);
            return mCanvas;
        }
    }
```

能看到实际上在每一个Surface都会带着一个CompatibleCanvas，准备着进行软件绘制内容。CompatibleCanvas实际上是继承Canvas的。在这个过程中先对Canvas进行lock之后，再返回给你。

我们先来看看Canvas本质上是什么东西？

#### Canvas的实例化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[graphics](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/)/[graphics](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/graphics/)/[Canvas.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/graphics/Canvas.java)
```java
    public Canvas() {
        if (!isHardwareAccelerated()) {
            // 0 means no native bitmap
            mNativeCanvasWrapper = nInitRaster(null);
            mFinalizer = NoImagePreloadHolder.sRegistry.registerNativeAllocation(
                    this, mNativeCanvasWrapper);
        } else {
            mFinalizer = null;
        }
    }
```

因为此时是软件绘制的Canvas。这个构造函数实际上会通过nInitRaster方法在native层中生成一个对应的Canvas。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_graphics_Canvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_graphics_Canvas.cpp)
```cpp
// Native wrapper constructor used by Canvas(Bitmap)
static jlong initRaster(JNIEnv* env, jobject, jobject jbitmap) {
    SkBitmap bitmap;
    if (jbitmap != NULL) {
        GraphicsJNI::getSkBitmap(env, jbitmap, &bitmap);
    }
    return reinterpret_cast<jlong>(Canvas::create_canvas(bitmap));
}
```
此时传入了一个空对象，因此不会走到getSkBitmap通过获取Java层的bitmap
从而获取原来的Bitmap对象填充到即将生成的Canvas中。

而是,拿到一个空白的SkBitmap，直接走到Canvas::create_canvas(bitmap)创建新的Canvas。

#### Skia层的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[SkiaCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/SkiaCanvas.cpp)
```cpp
Canvas* Canvas::create_canvas(const SkBitmap& bitmap) {
    return new SkiaCanvas(bitmap);
}

SkiaCanvas::SkiaCanvas(const SkBitmap& bitmap) {
    sk_sp<SkColorSpace> cs = bitmap.refColorSpace();
    mCanvasOwned =
            std::unique_ptr<SkCanvas>(new SkCanvas(bitmap, SkCanvas::ColorBehavior::kLegacy));
    if (cs.get() == nullptr || cs->isSRGB()) {
        if (!uirenderer::Properties::isSkiaEnabled()) {
            ...
        } else {
            mCanvas = mCanvasOwned.get();
        }
    } else {
...
    }
}
```
我们只关注Skia使用打开的逻辑。还记得我在Skia初探聊过原理的吗？此时能看到SkiaCanvas中包含着SkCanvas对象。这也是为什么在那一篇文章说获取底层的Canvas对象强转为SkCanvas，那是谬误的手法了吧。

##### SkCanvas初始化
```cpp
SkCanvas::SkCanvas(const SkBitmap& bitmap, ColorBehavior)
    : fMCStack(sizeof(MCRec), fMCRecStorage, sizeof(fMCRecStorage))
    , fProps(SkSurfaceProps::kLegacyFontHost_InitType)
    , fAllocator(nullptr)
{
    inc_canvas();

    SkBitmap tmp(bitmap);
    *const_cast<SkImageInfo*>(&tmp.info()) = tmp.info().makeColorSpace(nullptr);
    sk_sp<SkBaseDevice> device(new SkBitmapDevice(tmp, fProps, nullptr));
    this->init(device.get(), kDefault_InitFlags);
}

```
增加了SkCanvas的引用计数之后。
- 1.创建一个SkImageInfo 设置好当前SkBitmap 图像参数。SkImageInfo这个对象很简单，实际上控制了整个SkBitmap的宽高以及颜色空间，颜色类型等信息。
- 2.初始化一个SkBitmapDevice。SkBitmapDevice 继承于SkDevice是整个SkiaCanvas绘制的核心，它承载了Canvas的绝大部分绘制api。
- 3.就会调用init方法通过SkBitmapDevice初始化SkCanvas。

#### SkCanvas init
文件：/[external](http://androidxref.com/9.0.0_r3/xref/external/)/[skia](http://androidxref.com/9.0.0_r3/xref/external/skia/)/[src](http://androidxref.com/9.0.0_r3/xref/external/skia/src/)/[core](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/)/[SkCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/SkCanvas.cpp)
```cpp
SkBaseDevice* SkCanvas::init(SkBaseDevice* device, InitFlags flags) {
    if (device && device->forceConservativeRasterClip()) {
        flags = InitFlags(flags | kConservativeRasterClip_InitFlag);
    }

    fAllowSimplifyClip = false;
    fSaveCount = 1;
    fMetaData = nullptr;

    fMCRec = (MCRec*)fMCStack.push_back();
    new (fMCRec) MCRec;
    fMCRec->fRasterClip.setDeviceClipRestriction(&fClipRestrictionRect);
    fIsScaleTranslate = true;

    SkASSERT(sizeof(DeviceCM) <= sizeof(fDeviceCMStorage));
    fMCRec->fLayer = (DeviceCM*)fDeviceCMStorage;
    new (fDeviceCMStorage) DeviceCM(sk_ref_sp(device), nullptr, fMCRec->fMatrix, nullptr, nullptr);

    fMCRec->fTopLayer = fMCRec->fLayer;

    fSurfaceBase = nullptr;

    if (device) {
        // The root device and the canvas should always have the same pixel geometry
        SkASSERT(fProps.pixelGeometry() == device->surfaceProps().pixelGeometry());
        fMCRec->fRasterClip.setRect(device->getGlobalBounds());
        fDeviceClipBounds = qr_clip_bounds(device->getGlobalBounds());

        device->androidFramework_setDeviceClipRestriction(&fClipRestrictionRect);
    }

    return device;
}
```
在这里我们能够看到几个十分重要的对象的初始化：
- 1.fMCStack Skia的绘制状态栈的初始化。先设置一个初始的fMCRec 状态。并且new一个MCRec在push_back回来的地址中，把SkiaBaseDevice存在MCRec其中。
- 2.初始化SkDevice。SkDevice设置设置裁剪区域。

Skia可以看成是类似一个个Layer的绘制，每一次绘制在对应的层级绘制都会保存对应的状态,如旋转，缩放，裁剪等变换。我们先看看两个比较重要的对象MCRec以及DeviceCM。

```cpp
class SkCanvas::MCRec {
public:
    SkDrawFilter*   fFilter;    // the current filter (or null)
    DeviceCM*       fLayer;
    DeviceCM*           fTopLayer;
    SkConservativeClip  fRasterClip;
    SkMatrix            fMatrix;
...
};
```
- 1.SkDrawFilter 标记此时绘制的是什么类型，圆形，椭圆，线条，图像等标示位。
- 2.fLayer 代表当前MCRec状态集拥有的所有的绘制状态。
- 3.fTopLayer DeviceCM代表当前最顶部开始可以绘制的状态栈.当绘制的层级比最顶部的还高，则忽略绘制。
- 4.fRasterClip  SkConservativeClip绘制的裁剪区域
- 5.fMatrix SkMatrix 代表几何变换的矩阵

```cpp
struct DeviceCM {
    DeviceCM*                      fNext;
    sk_sp<SkBaseDevice>            fDevice;
    SkRasterClip                   fClip;
    std::unique_ptr<const SkPaint> fPaint; // may be null (in the future)
    SkMatrix                       fStashedMatrix; // original CTM; used by imagefilter in saveLayer
    sk_sp<SkImage>                 fClipImage;
    SkMatrix                       fClipMatrix;

....
};
```
注意这里面出现了两个裁剪类SkRasterClip以及SkConservativeClip。SkConservativeClip是一个初步的裁剪。SkRasterClip这个类持有一个SkRegion以及SkAAClip主要的职责是允许进行光栅化后的裁剪优化，除了裁剪之外还能进行抗锯齿。

DeviceCM中还带着SkBaseDevice，DeviceCM链表，以及SkPaint也就是我们在Java层对应的paint画笔。还有图像对应的变换矩阵，以及裁剪后的图像和矩阵。

#### SkCanvas 裁剪区域的初始化
我们熟悉这些对象到这里即可。后面之后会有更多的解析。我们继续看看Clip的初始化。
```cpp
 if (device) {
        // The root device and the canvas should always have the same pixel geometry
        SkASSERT(fProps.pixelGeometry() == device->surfaceProps().pixelGeometry());
        fMCRec->fRasterClip.setRect(device->getGlobalBounds());
        fDeviceClipBounds = qr_clip_bounds(device->getGlobalBounds());

        device->androidFramework_setDeviceClipRestriction(&fClipRestrictionRect);
    }
```
首先给当前的状态fMCRec设置裁剪区域。

接着看看内联函数qr_clip_bounds
```cpp
static inline SkRect qr_clip_bounds(const SkIRect& bounds) {
    if (bounds.isEmpty()) {
        return SkRect::MakeEmpty();
    }

    // Expand bounds out by 1 in case we are anti-aliasing.  We store the
    // bounds as floats to enable a faster quick reject implementation.
    SkRect dst;
    SkNx_cast<float>(Sk4i::Load(&bounds.fLeft) + Sk4i(-1,-1,1,1)).store(&dst.fLeft);
    return dst;
}
```
这里我们可以联动OpenGL 系列文章中的思想。顶点坐标是在[-1,1]之间变化，在这里也是同理。并且初始化绘制目标区域最左侧应该在SkIRect中的哪里。这里这么做就是为了让整个顶点归一化到-1到1之间，能够做到更快的计算裁剪区域。

```cpp
#define FOR_EACH_TOP_DEVICE( code )                       \
    do {                                                  \
        DeviceCM* layer = fMCRec->fTopLayer;              \
        while (layer) {                                   \
            SkBaseDevice* device = layer->fDevice.get();  \
            if (device) {                                 \
                code;                                     \
            }                                             \
            layer = layer->fNext;                         \
        }                                                 \
    } while (0)

void SkCanvas::androidFramework_setDeviceClipRestriction(const SkIRect& rect) {
    fClipRestrictionRect = rect;
    if (fClipRestrictionRect.isEmpty()) {
        // we notify the device, but we *dont* resolve deferred saves (since we're just
        // removing the restriction if the rect is empty. how I hate this api.
        FOR_EACH_TOP_DEVICE(device->androidFramework_setDeviceClipRestriction(&fClipRestrictionRect));
    } else {
...
    }
}
```
能看到实际上实际上就是就是从fTopLayer开始遍历其中的SkDevice。

文件：/[external](http://androidxref.com/9.0.0_r3/xref/external/)/[skia](http://androidxref.com/9.0.0_r3/xref/external/skia/)/[src](http://androidxref.com/9.0.0_r3/xref/external/skia/src/)/[core](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/)/[SkBitmapDevice.cpp](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/SkBitmapDevice.cpp)
此时是SkBitmapDevice，androidFramework_setDeviceClipRestriction会直接调用onSetDeviceClipRestriction。
```cpp
void SkBitmapDevice::onSetDeviceClipRestriction(SkIRect* mutableClipRestriction) {
    fRCStack.setDeviceClipRestriction(mutableClipRestriction);
    if (!mutableClipRestriction->isEmpty()) {
        SkRegion rgn(*mutableClipRestriction);
        fRCStack.clipRegion(rgn, SkClipOp::kIntersect);
    }
}
```
这里面实际上很简单，就是给当前的SkBitmapDevice设置初始的裁剪区域。到这里，就完成了Canvas的初始化。我们继续回到Surface的Lock方法中


### Surface nativeLockCanvas Canvas锁定映射底层内存
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_Surface.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_Surface.cpp)

```cpp
static jlong nativeLockCanvas(JNIEnv* env, jclass clazz,
        jlong nativeObject, jobject canvasObj, jobject dirtyRectObj) {
    sp<Surface> surface(reinterpret_cast<Surface *>(nativeObject));

    if (!isSurfaceValid(surface)) {
        doThrowIAE(env);
        return 0;
    }

    Rect dirtyRect(Rect::EMPTY_RECT);
    Rect* dirtyRectPtr = NULL;

    if (dirtyRectObj) {
        dirtyRect.left   = env->GetIntField(dirtyRectObj, gRectClassInfo.left);
        dirtyRect.top    = env->GetIntField(dirtyRectObj, gRectClassInfo.top);
        dirtyRect.right  = env->GetIntField(dirtyRectObj, gRectClassInfo.right);
        dirtyRect.bottom = env->GetIntField(dirtyRectObj, gRectClassInfo.bottom);
        dirtyRectPtr = &dirtyRect;
    }

    ANativeWindow_Buffer outBuffer;
    status_t err = surface->lock(&outBuffer, dirtyRectPtr);
    if (err < 0) {
        const char* const exception = (err == NO_MEMORY) ?
                OutOfResourcesException :
                "java/lang/IllegalArgumentException";
        jniThrowException(env, exception, NULL);
        return 0;
    }

    SkImageInfo info = SkImageInfo::Make(outBuffer.width, outBuffer.height,
                                         convertPixelFormat(outBuffer.format),
                                         outBuffer.format == PIXEL_FORMAT_RGBX_8888
                                                 ? kOpaque_SkAlphaType : kPremul_SkAlphaType,
                                         GraphicsJNI::defaultColorSpace());

    SkBitmap bitmap;
    ssize_t bpr = outBuffer.stride * bytesPerPixel(outBuffer.format);
    bitmap.setInfo(info, bpr);
    if (outBuffer.width > 0 && outBuffer.height > 0) {
        bitmap.setPixels(outBuffer.bits);
    } else {
        // be safe with an empty bitmap.
        bitmap.setPixels(NULL);
    }

    Canvas* nativeCanvas = GraphicsJNI::getNativeCanvas(env, canvasObj);
    nativeCanvas->setBitmap(bitmap);

    if (dirtyRectPtr) {
        nativeCanvas->clipRect(dirtyRect.left, dirtyRect.top,
                dirtyRect.right, dirtyRect.bottom, SkClipOp::kIntersect);
    }

    if (dirtyRectObj) {
        env->SetIntField(dirtyRectObj, gRectClassInfo.left,   dirtyRect.left);
        env->SetIntField(dirtyRectObj, gRectClassInfo.top,    dirtyRect.top);
        env->SetIntField(dirtyRectObj, gRectClassInfo.right,  dirtyRect.right);
        env->SetIntField(dirtyRectObj, gRectClassInfo.bottom, dirtyRect.bottom);
    }

    // Create another reference to the surface and return it.  This reference
    // should be passed to nativeUnlockCanvasAndPost in place of mNativeObject,
    // because the latter could be replaced while the surface is locked.
    sp<Surface> lockedSurface(surface);
    lockedSurface->incStrong(&sRefBaseOwner);
    return (jlong) lockedSurface.get();
}
```
到这里如何联系就是Java层的Canvas，SF的GraphicBuffer以及Skia最核心的内容。
- 1.首先校验Surface是否联通了SF进程，是否有效
- 2.设置Surface的变化的dirty区域。
- 3.通过surface的lock方法，把GraphicBuffer中的匿名内存和ANativeWindow_Buffer outBuffer中的缓存内存联系起来。
- 4.创建SkImageInfo，把需要绘制区域的宽高，颜色格式保存起来。
- 5.把SkImageInfo设置到SkBitmap中。并且把outBuffer和SkBitmap联系起来。
- 6.同时把SkBitmap设置到Canvas，此时就是SkiaCanvas中。
- 7.按照SurfaceView的宽高裁剪Canvas中的区域。
- 8.返回一个lockedSurface临时Surface对象，包裹着在native中映射好了的Surface。


到这里有一个十分核心的知识点：如果看过我写的SF系列文章[Android 重学系列 GraphicBuffer的诞生](https://www.jianshu.com/p/3bfc0053d254)
，就能知道lock方法本质上就是把GraphicBuffer中ion驱动申请的DMA共享内存和外部某个内存联系起来。而在这里就是把GraphicBuffer中的内存和ANativeWindow_Buffer关联起来，这样就做到了共享内存和ANativeWindow关联起来。接着把ANativeWindow_Buffer和SkBitmap关联起来，换句话说就把SkCanvas和GraphicBuffer关联起来。通过这种手段，把三者全部关联起来。之后，当ViewRootImpl进行View的绘制时候，就会把对应的像素通过Skia的绘制，同时保存到GraphicBuffer中。

因此Canvas的nativeLock方法才是整个Android渲染体系的枢纽。

还有一个地方值得注意，
```cpp
    SkBitmap bitmap;
    ssize_t bpr = outBuffer.stride * bytesPerPixel(outBuffer.format);
    bitmap.setInfo(info, bpr);
```
> 绘制区域的像素范围 = outBuffer的读取像素步长 * 每个颜色格式下像素的大小。

在Skia初探一文中有讨论过其中的实践。

### Surface unlockCanvasAndPost 解映射以及发送图元到SF进程
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[Surface.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/Surface.java)

```java
    public void unlockCanvasAndPost(Canvas canvas) {
        synchronized (mLock) {
            checkNotReleasedLocked();

            if (mHwuiContext != null) {
              ...
            } else {
                unlockSwCanvasAndPost(canvas);
            }
        }
    }
```
这里我们还是不需要关注硬件绘制，先来关注软件绘制。
```java
    private void unlockSwCanvasAndPost(Canvas canvas) {
        if (canvas != mCanvas) {
            throw new IllegalArgumentException("canvas object must be the same instance that "
                    + "was previously returned by lockCanvas");
        }
        if (mNativeObject != mLockedObject) {
            Log.w(TAG, "WARNING: Surface's mNativeObject (0x" +
                    Long.toHexString(mNativeObject) + ") != mLockedObject (0x" +
                    Long.toHexString(mLockedObject) +")");
        }
        if (mLockedObject == 0) {
            throw new IllegalStateException("Surface was not locked");
        }
        try {
            nativeUnlockCanvasAndPost(mLockedObject, canvas);
        } finally {
            nativeRelease(mLockedObject);
            mLockedObject = 0;
        }
    }
```
这里只会调用nativeUnlockCanvasAndPost，把映射好的Surface native对象以及Canvas传入。最后调用nativeRelease解开native中Surface的映射。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_Surface.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_Surface.cpp)
```
static void nativeUnlockCanvasAndPost(JNIEnv* env, jclass clazz,
        jlong nativeObject, jobject canvasObj) {
    sp<Surface> surface(reinterpret_cast<Surface *>(nativeObject));
    if (!isSurfaceValid(surface)) {
        return;
    }

    // detach the canvas from the surface
    Canvas* nativeCanvas = GraphicsJNI::getNativeCanvas(env, canvasObj);
    nativeCanvas->setBitmap(SkBitmap());

    // unlock surface
    status_t err = surface->unlockAndPost();
    if (err < 0) {
        doThrowIAE(env);
    }
}
```
此时为了不然后续有其他的线程干扰Canvas的绘制结果，会先设置新的SkBitmap重新填充到SkiaCanvas中。接着调用surface的unlockAndPost的解开映射并且把GraphicBuffer发送到SF进程。关于unlockAndPost的解析，可以阅读[Android 重学系列 GraphicBuffer的诞生](https://www.jianshu.com/p/3bfc0053d254)一文。

#### Surface nativeRelease
```cpp
static void nativeRelease(JNIEnv* env, jclass clazz, jlong nativeObject) {
    sp<Surface> sur(reinterpret_cast<Surface *>(nativeObject));
    sur->decStrong(&sRefBaseOwner);
}
```
降低当前native层的Surface引用计数，把当前的锁定的临时Surface释放掉。


### 总结
先来看看Canvas的设计：
![Canvas.jpg](/images/Canvas.jpg)

实际上整个过程就是SurfaceView屏蔽了onDraw方法。通过自己的对Surface的lock操作以及unlockAndPost的方式把数据发送到SF进程中。

其次我们还学习了Skia绘制的入口，本质上ViewRootImpl还是SurfaceView借助Skia进行绘制的时候，会调用Canvas的lock方法获取锁定映射好的Canvas，ViewRootImpl通过Skia操作在Canvas上绘制，由于Canvas中SkBitmap是联通GraphicBuffer中的内存的，因此绘制的结果才能通过GraphicBuffer同步到SF进程中。


而这里就是和TextureView的根本区别，下一篇我们来解析TextureView。





