---
title: Android 重学系列 View的绘制流程(三) onDraw
top: false
cover: false
date: 2020-06-14 21:26:51
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
之前已经和大家聊了onLayout的流程，本文将会继续聊一聊onDraw中做了什么？本文将集中关注软件渲染，关于Canvas的api源码解析暂时不会在本文聊，会专门开一个Skia源码解析进行分析。


# 正文
performTravel的方法走完onMeasure和onLayout流程后会走到下面这段代码段。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)

```java
        if (mFirst) {
            if (sAlwaysAssignFocus || !isInTouchMode()) {
                if (mView != null) {
                    if (!mView.hasFocus()) {
                        mView.restoreDefaultFocus();
                    } else {
...
                    }
                }
            } else {

                View focused = mView.findFocus();
                if (focused instanceof ViewGroup
                        && ((ViewGroup) focused).getDescendantFocusability()
                                == ViewGroup.FOCUS_AFTER_DESCENDANTS) {
                    focused.restoreDefaultFocus();
                }
            }
        }

        final boolean changedVisibility = (viewVisibilityChanged || mFirst) && isViewVisible;
        final boolean hasWindowFocus = mAttachInfo.mHasWindowFocus && isViewVisible;
        final boolean regainedFocus = hasWindowFocus && mLostWindowFocus;
        if (regainedFocus) {
            mLostWindowFocus = false;
        } else if (!hasWindowFocus && mHadWindowFocus) {
            mLostWindowFocus = true;
        }

        if (changedVisibility || regainedFocus) {

            boolean isToast = (mWindowAttributes == null) ? false
                    : (mWindowAttributes.type == WindowManager.LayoutParams.TYPE_TOAST);
...
        }

        mFirst = false;
        mWillDrawSoon = false;
        mNewSurfaceNeeded = false;
        mActivityRelaunched = false;
        mViewVisibility = viewVisibility;
        mHadWindowFocus = hasWindowFocus;

        if (hasWindowFocus && !isInLocalFocusMode()) {
            final boolean imTarget = WindowManager.LayoutParams
                    .mayUseInputMethod(mWindowAttributes.flags);
            if (imTarget != mLastWasImTarget) {
                mLastWasImTarget = imTarget;
                InputMethodManager imm = InputMethodManager.peekInstance();
                if (imm != null && imTarget) {
                    imm.onPreWindowFocus(mView, hasWindowFocus);
                    imm.onPostWindowFocus(mView, mView.findFocus(),
                            mWindowAttributes.softInputMode,
                            !mHasHadWindowFocus, mWindowAttributes.flags);
                }
            }
        }
```
在进入onDraw的流程之前，会先处理焦点。这个过程中可以分为2大步骤：

- 1.如果是第一次渲染，则说明之前的宽高都是都为0.在requestFocus方法中会有这个判断把整个焦点集中拦截下来：
```java
    private boolean canTakeFocus() {
        return ((mViewFlags & VISIBILITY_MASK) == VISIBLE)
                && ((mViewFlags & FOCUSABLE) == FOCUSABLE)
                && ((mViewFlags & ENABLED_MASK) == ENABLED)
                && (sCanFocusZeroSized || !isLayoutValid() || hasSize());
    }
```
而在每一次onMeasure之前，都会尝试集中一次焦点的遍历。其中requestFocusNoSearch方法中，如果没有测量过就会直接返回false。因为每一次更换焦点或者集中焦点都可能伴随着如背景drawable，statelistDrawable等切换。没有测量过就没有必要做这无用功(详情请看[View的绘制流程(三) onMeasure](https://www.jianshu.com/p/4f8b5c559311)
)。

因此此时为了弥补之前拒绝焦点的行为，会重新进行一次restoreDefaultFocus的行为进行requestFocus处理。

- 2.如果存在窗体焦点，同时不是打开了FLAG_LOCAL_FOCUS_MODE标志（这是一种特殊情况，一般打上这个标志位只有在startingWindow的快照中才会有，startingWindow具体是什么可以看看[WMS在Activity启动中的职责 添加窗体(三)](https://www.jianshu.com/p/157e8bbfa45a)）。

则会调用InputMethodManager的onPostWindowFocus方法启动带了android.view.InputMethod这个action的软键盘服务。详细的这里暂时不展开讨论。


## onDraw流程

```java
        if ((relayoutResult & WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME) != 0) {
            reportNextDraw();
        }

        boolean cancelDraw = mAttachInfo.mTreeObserver.dispatchOnPreDraw() || !isViewVisible;

        if (!cancelDraw && !newSurface) {
            if (mPendingTransitions != null && mPendingTransitions.size() > 0) {
                for (int i = 0; i < mPendingTransitions.size(); ++i) {
                    mPendingTransitions.get(i).startChangingAnimations();
                }
                mPendingTransitions.clear();
            }

            performDraw();
        } else {
            if (isViewVisible) {
                scheduleTraversals();
            } else if (mPendingTransitions != null && mPendingTransitions.size() > 0) {
                for (int i = 0; i < mPendingTransitions.size(); ++i) {
                    mPendingTransitions.get(i).endChangingAnimations();
                }
                mPendingTransitions.clear();
            }
        }

        mIsInTraversal = false;
```
- 1.判断到如果是第一次调用draw方法，则会调用reportNextDraw。
```java
    private void reportNextDraw() {
        if (mReportNextDraw == false) {
            drawPending();
        }
        mReportNextDraw = true;
    }

    void drawPending() {
        mDrawsNeededToReport++;
    }
```
能看到实际上就是设置mReportNextDraw为true。我们回顾一下前两个流程mReportNextDraw参与了标志位的判断。在执行onMeasure和onLayout有两个大前提，一个是mStop为false，一个是mReportNextDraw为true。只要满足其一就会执行。

这么做的目的只有一个，保证调用一次onDraw方法。为什么会这样呢？performDraw是整个Draw流程的入口。然而在这个入口，必须要保证cancelDraw为false以及newSurface为false。

注意，如果是第一次渲染因为会添加进新的Surface，此时newSurface为true(可以看[View的绘制流程(二) 绘制的准备](https://www.jianshu.com/p/2f4e7e9e5cc0))。所以会走到下面的分之，如果串口可见则调用scheduleTraversals执行下一次Loop的绘制流程。否则判断是否有需要执行的LayoutTransitions layout动画就执行了。

因此第一次是不会走到onDraw，是从第二次Looper之后View的绘制流程才会执行onDraw。

我们继续关注performDraw的逻辑。


### ViewRootImpl performDraw
```java
    private void performDraw() {
        if (mAttachInfo.mDisplayState == Display.STATE_OFF && !mReportNextDraw) {
            return;
        } else if (mView == null) {
            return;
        }

        final boolean fullRedrawNeeded = mFullRedrawNeeded || mReportNextDraw;
        mFullRedrawNeeded = false;

        mIsDrawing = true;
        Trace.traceBegin(Trace.TRACE_TAG_VIEW, "draw");

        boolean usingAsyncReport = false;
        if (mReportNextDraw && mAttachInfo.mThreadedRenderer != null
                && mAttachInfo.mThreadedRenderer.isEnabled()) {
            usingAsyncReport = true;
            mAttachInfo.mThreadedRenderer.setFrameCompleteCallback((long frameNr) -> {
                pendingDrawFinished();
            });
        }

        try {
            boolean canUseAsync = draw(fullRedrawNeeded);
            if (usingAsyncReport && !canUseAsync) {
                mAttachInfo.mThreadedRenderer.setFrameCompleteCallback(null);
                usingAsyncReport = false;
            }
        } finally {
            mIsDrawing = false;
            Trace.traceEnd(Trace.TRACE_TAG_VIEW);
        }

        if (mAttachInfo.mPendingAnimatingRenderNodes != null) {
            final int count = mAttachInfo.mPendingAnimatingRenderNodes.size();
            for (int i = 0; i < count; i++) {
                mAttachInfo.mPendingAnimatingRenderNodes.get(i).endAllAnimators();
            }
            mAttachInfo.mPendingAnimatingRenderNodes.clear();
        }

        if (mReportNextDraw) {
            mReportNextDraw = false;

            if (mWindowDrawCountDown != null) {
                try {
                    mWindowDrawCountDown.await();
                } catch (InterruptedException e) {
                    Log.e(mTag, "Window redraw count down interrupted!");
                }
                mWindowDrawCountDown = null;
            }

            if (mAttachInfo.mThreadedRenderer != null) {
                mAttachInfo.mThreadedRenderer.setStopped(mStopped);
            }

            if (mSurfaceHolder != null && mSurface.isValid()) {
                SurfaceCallbackHelper sch = new SurfaceCallbackHelper(this::postDrawFinished);
                SurfaceHolder.Callback callbacks[] = mSurfaceHolder.getCallbacks();

                sch.dispatchSurfaceRedrawNeededAsync(mSurfaceHolder, callbacks);
            } else if (!usingAsyncReport) {
                if (mAttachInfo.mThreadedRenderer != null) {
                    mAttachInfo.mThreadedRenderer.fence();
                }
                pendingDrawFinished();
            }
        }
    }
```
我们把整个流程抽象出来实际上就是可以分为如下几个步骤：
对于软件渲染：
- 1.调用draw方法，遍历View的层级。
- 2.如果Surface是生效的，则在SurfaceHolder.Callback的surfaceRedrawNeededAsync回调中调用pendingDrawFinished。
- 3.如果是强制同步渲染，则会直接调用pendingDrawFinished。

对于硬件渲染：
- 1.调用draw方法，遍历View的层级。
- 2.通过监听mThreadedRenderer的setFrameCompleteCallback回调执行pendingDrawFinished方法。

我们先关注软件渲染的流程。也就是draw和pendingDrawFinished。

### ViewRootImpl draw
```java
    private boolean draw(boolean fullRedrawNeeded) {
        Surface surface = mSurface;
        if (!surface.isValid()) {
            return false;
        }

        if (!sFirstDrawComplete) {
            synchronized (sFirstDrawHandlers) {
                sFirstDrawComplete = true;
                final int count = sFirstDrawHandlers.size();
                for (int i = 0; i< count; i++) {
                    mHandler.post(sFirstDrawHandlers.get(i));
                }
            }
        }

        scrollToRectOrFocus(null, false);

        if (mAttachInfo.mViewScrollChanged) {
            mAttachInfo.mViewScrollChanged = false;
            mAttachInfo.mTreeObserver.dispatchOnScrollChanged();
        }

        boolean animating = mScroller != null && mScroller.computeScrollOffset();
        final int curScrollY;
        if (animating) {
            curScrollY = mScroller.getCurrY();
        } else {
            curScrollY = mScrollY;
        }
        if (mCurScrollY != curScrollY) {
            mCurScrollY = curScrollY;
            fullRedrawNeeded = true;
            if (mView instanceof RootViewSurfaceTaker) {
                ((RootViewSurfaceTaker) mView).onRootViewScrollYChanged(mCurScrollY);
            }
        }

        final float appScale = mAttachInfo.mApplicationScale;
        final boolean scalingRequired = mAttachInfo.mScalingRequired;

        final Rect dirty = mDirty;
        if (mSurfaceHolder != null) {
            dirty.setEmpty();
            if (animating && mScroller != null) {
                mScroller.abortAnimation();
            }
            return false;
        }

        if (fullRedrawNeeded) {
            mAttachInfo.mIgnoreDirtyState = true;
            dirty.set(0, 0, (int) (mWidth * appScale + 0.5f), (int) (mHeight * appScale + 0.5f));
        }


        mAttachInfo.mTreeObserver.dispatchOnDraw();

        int xOffset = -mCanvasOffsetX;
        int yOffset = -mCanvasOffsetY + curScrollY;
        final WindowManager.LayoutParams params = mWindowAttributes;
        final Rect surfaceInsets = params != null ? params.surfaceInsets : null;
        if (surfaceInsets != null) {
            xOffset -= surfaceInsets.left;
            yOffset -= surfaceInsets.top;

            dirty.offset(surfaceInsets.left, surfaceInsets.right);
        }

...

        mAttachInfo.mDrawingTime =
                mChoreographer.getFrameTimeNanos() / TimeUtils.NANOS_PER_MS;

        boolean useAsyncReport = false;
        if (!dirty.isEmpty() || mIsAnimating || accessibilityFocusDirty) {
            if (mAttachInfo.mThreadedRenderer != null && mAttachInfo.mThreadedRenderer.isEnabled()) {
                boolean invalidateRoot = accessibilityFocusDirty || mInvalidateRootRequested;
                mInvalidateRootRequested = false;

                mIsAnimating = false;

                if (mHardwareYOffset != yOffset || mHardwareXOffset != xOffset) {
                    mHardwareYOffset = yOffset;
                    mHardwareXOffset = xOffset;
                    invalidateRoot = true;
                }

                if (invalidateRoot) {
                    mAttachInfo.mThreadedRenderer.invalidateRoot();
                }

                dirty.setEmpty();

                final boolean updated = updateContentDrawBounds();

                if (mReportNextDraw) {
                    mAttachInfo.mThreadedRenderer.setStopped(false);
                }

                if (updated) {
                    requestDrawWindow();
                }

                useAsyncReport = true;

                final FrameDrawingCallback callback = mNextRtFrameCallback;
                mNextRtFrameCallback = null;
                mAttachInfo.mThreadedRenderer.draw(mView, mAttachInfo, this, callback);
            } else {

                if (mAttachInfo.mThreadedRenderer != null &&
                        !mAttachInfo.mThreadedRenderer.isEnabled() &&
                        mAttachInfo.mThreadedRenderer.isRequested() &&
                        mSurface.isValid()) {

                    try {
                        mAttachInfo.mThreadedRenderer.initializeIfNeeded(
                                mWidth, mHeight, mAttachInfo, mSurface, surfaceInsets);
                    } catch (OutOfResourcesException e) {
                        handleOutOfResourcesException(e);
                        return false;
                    }

                    mFullRedrawNeeded = true;
                    scheduleTraversals();
                    return false;
                }

                if (!drawSoftware(surface, mAttachInfo, xOffset, yOffset,
                        scalingRequired, dirty, surfaceInsets)) {
                    return false;
                }
            }
        }

        if (animating) {
            mFullRedrawNeeded = true;
            scheduleTraversals();
        }
        return useAsyncReport;
    }
```
大致上完成了如下流程：
- 1.如果surface无效则直接返回

- 2. sFirstDrawHandlers这个存储着runnable静态对象。实际上是在ActivityThread启动后调用attach方法通过addFirstDrawHandler添加进来的目的只是为了启动jit模式。

- 3.scrollToRectOrFocus 处理滑动区域或者焦点区域。如果发生了滑动则回调TreeObserver.dispatchOnScrollChanged。接下来则通过全局的mScroller通过computeScrollOffset判断是否需要滑动动画。如果需要执行动画，则调用DeocView的onRootViewScrollYChanged，进行Y轴上的动画执行。

- 4.通过ViewTreeObserver的dispatchOnDraw开始分发draw开始绘制的监听者。

- 5.判断是否存在surface面上偏移量，有就矫正一次脏区，把偏移量添加上去。

接下来则会进入到硬件渲染和软件渲染的分支。但是进一步进行调用draw的流程有几个前提条件：脏区不为空，需要执行动画，辅助服务发生了焦点变化

- 6.如果ThreadedRenderer不为空且可用。ThreadedRenderer通过onPreDraw回调到ViewRootImpl，更新mHardwareYOffset，mHardwareXOffset。如果这两个参数发生了变化，则说明整个发生了硬件绘制的区域变化，需要从头遍历一次所有的区域设置为无效区域，mThreadedRenderer.invalidateRoot。

最后调用ThreadedRenderer.draw方法执行硬件渲染绘制。并且设置通过registerRtFrameCallback设置进来的callback设置到ThreadedRenderer中。

- 7.如果此时ThreadedRenderer不可用但是不为空，说明此时需要对ThreadedRenderer进行初始化，调用scheduleTraversals在下一轮的绘制流程中才进行硬件渲染。


- 8.如果以上情况都不满足，说明是软件渲染，则调用drawSoftware进行软件渲染。

- 9.如果不许要draw方法遍历全局的View树，则判断是否需要执行滑动动画，需要则调用scheduleTraversals进入下一轮的绘制。


本文先抛开硬件渲染，来看看软件渲染drawSoftware中做了什么。还有scrollToRectOrFocus滑动中做了什么？

#### ViewRootImpl scrollToRectOrFocus
```java
    boolean scrollToRectOrFocus(Rect rectangle, boolean immediate) {
        final Rect ci = mAttachInfo.mContentInsets;
        final Rect vi = mAttachInfo.mVisibleInsets;
        int scrollY = 0;
        boolean handled = false;

        if (vi.left > ci.left || vi.top > ci.top
                || vi.right > ci.right || vi.bottom > ci.bottom) {

            final View focus = mView.findFocus();
            if (focus == null) {
                return false;
            }
            View lastScrolledFocus = (mLastScrolledFocus != null) ? mLastScrolledFocus.get() : null;
            if (focus != lastScrolledFocus) {

                rectangle = null;
            }

            if (focus == lastScrolledFocus && !mScrollMayChange && rectangle == null) {

            } else {
                mLastScrolledFocus = new WeakReference<View>(focus);
                mScrollMayChange = false;
                if (focus.getGlobalVisibleRect(mVisRect, null)) {
                    if (rectangle == null) {
                        focus.getFocusedRect(mTempRect);
                        if (mView instanceof ViewGroup) {
                            ((ViewGroup) mView).offsetDescendantRectToMyCoords(
                                    focus, mTempRect);
                        }
                    } else {
                        mTempRect.set(rectangle);
                    }
                    if (mTempRect.intersect(mVisRect)) {
                        if (mTempRect.height() >
                                (mView.getHeight()-vi.top-vi.bottom)) {
                        }
                        else if (mTempRect.top < vi.top) {
                            scrollY = mTempRect.top - vi.top;
                        } else if (mTempRect.bottom > (mView.getHeight()-vi.bottom)) {
                            scrollY = mTempRect.bottom - (mView.getHeight()-vi.bottom);
                        } else {
                            scrollY = 0;
                        }
                        handled = true;
                    }
                }
            }
        }

        if (scrollY != mScrollY) {
            if (!immediate) {
                if (mScroller == null) {
                    mScroller = new Scroller(mView.getContext());
                }
                mScroller.startScroll(0, mScrollY, 0, scrollY-mScrollY);
            } else if (mScroller != null) {
                mScroller.abortAnimation();
            }
            mScrollY = scrollY;
        }

        return handled;
    }
```
能看到在这个过程中实际上就是处理两个区域mVisibleInsets可见区域以及mContentInsets内容区域。

实际上这个过程就是从根部节点开始寻找焦点，然后整个画面定格在焦点处。因为mVisibleInsets一般是屏幕中出去过扫描区的大小，但是内容区域就不一定了，可能内容会超出屏幕大小，因此会通过mScroller滑动定位。

计算原理如下，分为2个情况：
- 1.可视区域的顶部比起获得了焦点的view的顶部要低，说明这个view在屏幕外了，需要向下滑动：
> scrollY = mTempRect.top - vi.top;
- 2.如果焦点view的底部比起可视区域要比可视区域的低，说明需要向上滑动,注意滑动之后需要展示view，因此滑动的距离要减去view的高度:
> scrollY = mTempRect.bottom - (mView.getHeight()-vi.bottom);
稍微变一下如下：
> scrollY = mTempRect.bottom +vi.bottom - mView.getHeight();

### ViewRootImpl drawSoftware
```java
    private boolean drawSoftware(Surface surface, AttachInfo attachInfo, int xoff, int yoff,
            boolean scalingRequired, Rect dirty, Rect surfaceInsets) {

        final Canvas canvas;

        int dirtyXOffset = xoff;
        int dirtyYOffset = yoff;
        if (surfaceInsets != null) {
            dirtyXOffset += surfaceInsets.left;
            dirtyYOffset += surfaceInsets.top;
        }

        try {
            dirty.offset(-dirtyXOffset, -dirtyYOffset);
            final int left = dirty.left;
            final int top = dirty.top;
            final int right = dirty.right;
            final int bottom = dirty.bottom;

            canvas = mSurface.lockCanvas(dirty);

            if (left != dirty.left || top != dirty.top || right != dirty.right
                    || bottom != dirty.bottom) {
                attachInfo.mIgnoreDirtyState = true;
            }

            canvas.setDensity(mDensity);
        } catch (Surface.OutOfResourcesException e) {
            handleOutOfResourcesException(e);
            return false;
        } catch (IllegalArgumentException e) {
            mLayoutRequested = true;    // ask wm for a new surface next time.
            return false;
        } finally {
            dirty.offset(dirtyXOffset, dirtyYOffset);  // Reset to the original value.
        }

        try {

            if (!canvas.isOpaque() || yoff != 0 || xoff != 0) {
                canvas.drawColor(0, PorterDuff.Mode.CLEAR);
            }

            dirty.setEmpty();
            mIsAnimating = false;
            mView.mPrivateFlags |= View.PFLAG_DRAWN;

            try {
                canvas.translate(-xoff, -yoff);
                if (mTranslator != null) {
                    mTranslator.translateCanvas(canvas);
                }
                canvas.setScreenDensity(scalingRequired ? mNoncompatDensity : 0);
                attachInfo.mSetIgnoreDirtyState = false;

                mView.draw(canvas);

                drawAccessibilityFocusedDrawableIfNeeded(canvas);
            } finally {
                if (!attachInfo.mSetIgnoreDirtyState) {
                    attachInfo.mIgnoreDirtyState = false;
                }
            }
        } finally {
            try {
                surface.unlockCanvasAndPost(canvas);
            } catch (IllegalArgumentException e) {
                Log.e(mTag, "Could not unlock surface", e);
                mLayoutRequested = true;    // ask wm for a new surface next time.
                //noinspection ReturnInsideFinallyBlock
                return false;
            }

        }
        return true;
    }
```
这里面的逻辑和上面硬件渲染逻辑有点相似：
- 1.同样还是根据全局的surface的偏移量对整个dirty区域进行偏移
- 2.通过Surface.lockCanvas方法映射一个Canvas对象，之后所有的绘制行为都在这个Canvas对象上。关于这个方法，详细的原理可以看看我写的[SurfaceView和TextureView 源码浅析(上)](https://www.jianshu.com/p/bbec5c1aa00e)。
- 3.获得Canvas后，由于上面是对整个surface的偏移，因此Canvas作为surface映射出来的绘制对象也需要进行一次偏移。
- 4.调用DecorView的draw方法，开始对整个View树遍历。
- 5.遍历完整个View树后，说明所有的信息已经会知道Canvas了，就可以通过surface.unlockCanvasAndPost，把记录在SkCanvas中的像素数据发送到SF中渲染到屏幕中。关于第五点详细的可以阅读[SurfaceView和TextureView 源码浅析(上)](https://www.jianshu.com/p/bbec5c1aa00e)。后续的步骤可以阅读我写的[SF系列文章](https://www.jianshu.com/p/c954bcceb22a)。

我们继续来要来看看draw方法做了什么。

##### DecorView draw
```java
    @Override
    public void draw(Canvas canvas) {
        super.draw(canvas);

        if (mMenuBackground != null) {
            mMenuBackground.draw(canvas);
        }
    }
```
能看到整个DecorView实际上就是调用了父类的draw方法后，专门给menu栏的drawable绘制到Canvas中。


##### View draw
```java
    public void draw(Canvas canvas) {
        final int privateFlags = mPrivateFlags;
        final boolean dirtyOpaque = (privateFlags & PFLAG_DIRTY_MASK) == PFLAG_DIRTY_OPAQUE &&
                (mAttachInfo == null || !mAttachInfo.mIgnoreDirtyState);
        mPrivateFlags = (privateFlags & ~PFLAG_DIRTY_MASK) | PFLAG_DRAWN;

        int saveCount;

        if (!dirtyOpaque) {
            drawBackground(canvas);
        }

        // skip step 2 & 5 if possible (common case)
        final int viewFlags = mViewFlags;
        boolean horizontalEdges = (viewFlags & FADING_EDGE_HORIZONTAL) != 0;
        boolean verticalEdges = (viewFlags & FADING_EDGE_VERTICAL) != 0;
        if (!verticalEdges && !horizontalEdges) {

            if (!dirtyOpaque) onDraw(canvas);

            dispatchDraw(canvas);

            drawAutofilledHighlight(canvas);

            // Overlay is part of the content and draws beneath Foreground
            if (mOverlay != null && !mOverlay.isEmpty()) {
                mOverlay.getOverlayView().dispatchDraw(canvas);
            }

            onDrawForeground(canvas);

            drawDefaultFocusHighlight(canvas);

            return;
        }

        boolean drawTop = false;
        boolean drawBottom = false;
        boolean drawLeft = false;
        boolean drawRight = false;

        float topFadeStrength = 0.0f;
        float bottomFadeStrength = 0.0f;
        float leftFadeStrength = 0.0f;
        float rightFadeStrength = 0.0f;

        int paddingLeft = mPaddingLeft;

        final boolean offsetRequired = isPaddingOffsetRequired();
        if (offsetRequired) {
            paddingLeft += getLeftPaddingOffset();
        }

        int left = mScrollX + paddingLeft;
        int right = left + mRight - mLeft - mPaddingRight - paddingLeft;
        int top = mScrollY + getFadeTop(offsetRequired);
        int bottom = top + getFadeHeight(offsetRequired);

        if (offsetRequired) {
            right += getRightPaddingOffset();
            bottom += getBottomPaddingOffset();
        }

        final ScrollabilityCache scrollabilityCache = mScrollCache;
        final float fadeHeight = scrollabilityCache.fadingEdgeLength;
        int length = (int) fadeHeight;

        if (verticalEdges && (top + length > bottom - length)) {
            length = (bottom - top) / 2;
        }

        if (horizontalEdges && (left + length > right - length)) {
            length = (right - left) / 2;
        }

        if (verticalEdges) {
            topFadeStrength = Math.max(0.0f, Math.min(1.0f, getTopFadingEdgeStrength()));
            drawTop = topFadeStrength * fadeHeight > 1.0f;
            bottomFadeStrength = Math.max(0.0f, Math.min(1.0f, getBottomFadingEdgeStrength()));
            drawBottom = bottomFadeStrength * fadeHeight > 1.0f;
        }

        if (horizontalEdges) {
            leftFadeStrength = Math.max(0.0f, Math.min(1.0f, getLeftFadingEdgeStrength()));
            drawLeft = leftFadeStrength * fadeHeight > 1.0f;
            rightFadeStrength = Math.max(0.0f, Math.min(1.0f, getRightFadingEdgeStrength()));
            drawRight = rightFadeStrength * fadeHeight > 1.0f;
        }

        saveCount = canvas.getSaveCount();

        int solidColor = getSolidColor();
        if (solidColor == 0) {
            if (drawTop) {
                canvas.saveUnclippedLayer(left, top, right, top + length);
            }

            if (drawBottom) {
                canvas.saveUnclippedLayer(left, bottom - length, right, bottom);
            }

            if (drawLeft) {
                canvas.saveUnclippedLayer(left, top, left + length, bottom);
            }

            if (drawRight) {
                canvas.saveUnclippedLayer(right - length, top, right, bottom);
            }
        } else {
            scrollabilityCache.setFadeColor(solidColor);
        }

        // Step 3, draw the content
        if (!dirtyOpaque) onDraw(canvas);

        // Step 4, draw the children
        dispatchDraw(canvas);

        // Step 5, draw the fade effect and restore layers
        final Paint p = scrollabilityCache.paint;
        final Matrix matrix = scrollabilityCache.matrix;
        final Shader fade = scrollabilityCache.shader;

        if (drawTop) {
            matrix.setScale(1, fadeHeight * topFadeStrength);
            matrix.postTranslate(left, top);
            fade.setLocalMatrix(matrix);
            p.setShader(fade);
            canvas.drawRect(left, top, right, top + length, p);
        }

        if (drawBottom) {
            matrix.setScale(1, fadeHeight * bottomFadeStrength);
            matrix.postRotate(180);
            matrix.postTranslate(left, bottom);
            fade.setLocalMatrix(matrix);
            p.setShader(fade);
            canvas.drawRect(left, bottom - length, right, bottom, p);
        }

        if (drawLeft) {
            matrix.setScale(1, fadeHeight * leftFadeStrength);
            matrix.postRotate(-90);
            matrix.postTranslate(left, top);
            fade.setLocalMatrix(matrix);
            p.setShader(fade);
            canvas.drawRect(left, top, left + length, bottom, p);
        }

        if (drawRight) {
            matrix.setScale(1, fadeHeight * rightFadeStrength);
            matrix.postRotate(90);
            matrix.postTranslate(right, top);
            fade.setLocalMatrix(matrix);
            p.setShader(fade);
            canvas.drawRect(right - length, top, right, bottom, p);
        }

        canvas.restoreToCount(saveCount);

        drawAutofilledHighlight(canvas);

        // Overlay is part of the content and draws beneath Foreground
        if (mOverlay != null && !mOverlay.isEmpty()) {
            mOverlay.getOverlayView().dispatchDraw(canvas);
        }

        // Step 6, draw decorations (foreground, scrollbars)
        onDrawForeground(canvas);

    }
```
大致上draw方法分为如下几个步骤：

- 1.首先在draw方法中先校验mPrivateFlags中打开的标志位。还记得上一篇文章聊过的PFLAG_DIRTY_MASK的掩码实际上控制的是dirty以及透明两个标志位。
```java
final boolean dirtyOpaque = (privateFlags & PFLAG_DIRTY_MASK) == PFLAG_DIRTY_OPAQUE &&
                (mAttachInfo == null || !mAttachInfo.mIgnoreDirtyState);
        mPrivateFlags = (privateFlags & ~PFLAG_DIRTY_MASK) | PFLAG_DRAWN;
```
首先校验PFLAG_DIRTY_OPAQUE也就是透明标志位是否开启了，开启了dirtyOpaque则为true。同时打开PFLAG_DRAWN标志位，说明该View已经调用过了draw方法了。

- 2.如果dirtyOpaque为false说明不是透明则调用drawBackground，进行背景的绘制。

- 3.校验是否有横竖方向的边缘阴影需要绘制，如果不需要则以此执行如下三个流程：
    - 1.执行该View重写的onDraw流程，进行绘制
    - 2.dispatchDraw 把绘制行为分发到子View中
    - 3.判断是否有overlay，有则绘制每一个View的浮层的dispatchDraw
    - 4.onDrawForeground 绘制View的前景drawable
    - 5.drawDefaultFocusHighlight 绘制默认的焦点高亮。

- 4.如果需要绘制上下左右四个方向的滑轮，则执行如下几个步骤：
    - 1.计算滑轮的上下左右四个方向，根据是横向还是竖向计算其长度
    - 2.把这一块内容作为Canvas的非裁剪区域绘制到外面区域
    - 3.执行3.1以及3.2的步骤
    - 4.根据绘制的上下左右四个方向，对滑轮进行旋转
    - 5.执行3.3-3.5的步骤

我们关注核心行为3.1onDraw以及3.2dispatchDraw 以及drawBackground中完成了什么事情.

##### View drawBackground
```java
    private void drawBackground(Canvas canvas) {
        final Drawable background = mBackground;
        if (background == null) {
            return;
        }

        setBackgroundBounds();

        // Attempt to use a display list if requested.
        if (canvas.isHardwareAccelerated() && mAttachInfo != null
                && mAttachInfo.mThreadedRenderer != null) {
            mBackgroundRenderNode = getDrawableRenderNode(background, mBackgroundRenderNode);

            final RenderNode renderNode = mBackgroundRenderNode;
            if (renderNode != null && renderNode.isValid()) {
                setBackgroundRenderNodeProperties(renderNode);
                ((DisplayListCanvas) canvas).drawRenderNode(renderNode);
                return;
            }
        }

        final int scrollX = mScrollX;
        final int scrollY = mScrollY;
        if ((scrollX | scrollY) == 0) {
            background.draw(canvas);
        } else {
            canvas.translate(scrollX, scrollY);
            background.draw(canvas);
            canvas.translate(-scrollX, -scrollY);
        }
    }
```
能看到这里面绘制的逻辑分为硬件渲染和软件渲染：
- 硬件渲染首先会通过getDrawableRenderNode方法获取一个drawable渲染的renderNode，接着调用canvas的drawRenderNode。从之前我分析的TextureView一文中可以了解到硬件渲染，Canvas实质上就是DisplayListCanvas。

- 软件渲染则是调用draable的draw方法，把像素绘制到canvas智商。


##### getDrawableRenderNode
```java
    private RenderNode getDrawableRenderNode(Drawable drawable, RenderNode renderNode) {
        if (renderNode == null) {
            renderNode = RenderNode.create(drawable.getClass().getName(), this);
        }

        final Rect bounds = drawable.getBounds();
        final int width = bounds.width();
        final int height = bounds.height();
        final DisplayListCanvas canvas = renderNode.start(width, height);

        canvas.translate(-bounds.left, -bounds.top);

        try {
            drawable.draw(canvas);
        } finally {
            renderNode.end(canvas);
        }

        renderNode.setLeftTopRightBottom(bounds.left, bounds.top, bounds.right, bounds.bottom);
        renderNode.setProjectBackwards(drawable.isProjected());
        renderNode.setProjectionReceiver(true);
        renderNode.setClipToBounds(false);
        return renderNode;
    }
```
能看到在绘制一个硬件渲染的drawable对象时候，会先生成一个RenderNode，调用start之后获取Drawable对象对应DisplayListCanvas，在调用drawable的draw方法，把信息绘制到DisplayListCanvas，最后返回renderNode。

再把这个drawable对应的renderNode添加到当前View的Canvas中。

#### ViewGroup dispatchDraw
View默认是留下一个onDraw的空方法。我们看看dispatchDraw中做了什么。
```java
    protected void dispatchDraw(Canvas canvas) {
        boolean usingRenderNodeProperties = canvas.isRecordingFor(mRenderNode);
        final int childrenCount = mChildrenCount;
        final View[] children = mChildren;
        int flags = mGroupFlags;

        if ((flags & FLAG_RUN_ANIMATION) != 0 && canAnimate()) {
            final boolean buildCache = !isHardwareAccelerated();
            for (int i = 0; i < childrenCount; i++) {
                final View child = children[i];
                if ((child.mViewFlags & VISIBILITY_MASK) == VISIBLE) {
                    final LayoutParams params = child.getLayoutParams();
                    attachLayoutAnimationParameters(child, params, i, childrenCount);
                    bindLayoutAnimation(child);
                }
            }

            final LayoutAnimationController controller = mLayoutAnimationController;
            if (controller.willOverlap()) {
                mGroupFlags |= FLAG_OPTIMIZE_INVALIDATE;
            }

            controller.start();

            mGroupFlags &= ~FLAG_RUN_ANIMATION;
            mGroupFlags &= ~FLAG_ANIMATION_DONE;

            if (mAnimationListener != null) {
                mAnimationListener.onAnimationStart(controller.getAnimation());
            }
        }

        int clipSaveCount = 0;
        final boolean clipToPadding = (flags & CLIP_TO_PADDING_MASK) == CLIP_TO_PADDING_MASK;
        if (clipToPadding) {
            clipSaveCount = canvas.save(Canvas.CLIP_SAVE_FLAG);
            canvas.clipRect(mScrollX + mPaddingLeft, mScrollY + mPaddingTop,
                    mScrollX + mRight - mLeft - mPaddingRight,
                    mScrollY + mBottom - mTop - mPaddingBottom);
        }

        // We will draw our child's animation, let's reset the flag
        mPrivateFlags &= ~PFLAG_DRAW_ANIMATION;
        mGroupFlags &= ~FLAG_INVALIDATE_REQUIRED;

        boolean more = false;
        final long drawingTime = getDrawingTime();

        if (usingRenderNodeProperties) canvas.insertReorderBarrier();
        final int transientCount = mTransientIndices == null ? 0 : mTransientIndices.size();
        int transientIndex = transientCount != 0 ? 0 : -1;

        final ArrayList<View> preorderedList = usingRenderNodeProperties
                ? null : buildOrderedChildList();
        final boolean customOrder = preorderedList == null
                && isChildrenDrawingOrderEnabled();
        for (int i = 0; i < childrenCount; i++) {
            while (transientIndex >= 0 && mTransientIndices.get(transientIndex) == i) {
                final View transientChild = mTransientViews.get(transientIndex);
                if ((transientChild.mViewFlags & VISIBILITY_MASK) == VISIBLE ||
                        transientChild.getAnimation() != null) {
                    more |= drawChild(canvas, transientChild, drawingTime);
                }
                transientIndex++;
                if (transientIndex >= transientCount) {
                    transientIndex = -1;
                }
            }

            final int childIndex = getAndVerifyPreorderedIndex(childrenCount, i, customOrder);
            final View child = getAndVerifyPreorderedView(preorderedList, children, childIndex);
            if ((child.mViewFlags & VISIBILITY_MASK) == VISIBLE || child.getAnimation() != null) {
                more |= drawChild(canvas, child, drawingTime);
            }
        }
        while (transientIndex >= 0) {
            final View transientChild = mTransientViews.get(transientIndex);
            if ((transientChild.mViewFlags & VISIBILITY_MASK) == VISIBLE ||
                    transientChild.getAnimation() != null) {
                more |= drawChild(canvas, transientChild, drawingTime);
            }
            transientIndex++;
            if (transientIndex >= transientCount) {
                break;
            }
        }
        if (preorderedList != null) preorderedList.clear();

        // Draw any disappearing views that have animations
        if (mDisappearingChildren != null) {
            final ArrayList<View> disappearingChildren = mDisappearingChildren;
            final int disappearingCount = disappearingChildren.size() - 1;
            // Go backwards -- we may delete as animations finish
            for (int i = disappearingCount; i >= 0; i--) {
                final View child = disappearingChildren.get(i);
                more |= drawChild(canvas, child, drawingTime);
            }
        }
        if (usingRenderNodeProperties) canvas.insertInorderBarrier();

        if (clipToPadding) {
            canvas.restoreToCount(clipSaveCount);
        }

        flags = mGroupFlags;

        if ((flags & FLAG_INVALIDATE_REQUIRED) == FLAG_INVALIDATE_REQUIRED) {
            invalidate(true);
        }

        if ((flags & FLAG_ANIMATION_DONE) == 0 && (flags & FLAG_NOTIFY_ANIMATION_LISTENER) == 0 &&
                mLayoutAnimationController.isDone() && !more) {
            mGroupFlags |= FLAG_NOTIFY_ANIMATION_LISTENER;
            final Runnable end = new Runnable() {
               @Override
               public void run() {
                   notifyAnimationListener();
               }
            };
            post(end);
        }
    }
```
这个过程中做了如下几件事情：
- 1.判断是否打开了FLAG_RUN_ANIMATION标志位，且允许Layout动画。首先遍历该viewGroup中所有子View中所有的可见的子View，并且bindLayoutAnimation设置好每一个子View对应的Layout动画。
```java
    private void bindLayoutAnimation(View child) {
        Animation a = mLayoutAnimationController.getAnimationForView(child);
        child.setAnimation(a);
    }
```

- 2. LayoutAnimationController 控制Layout动画的控制者调用start启动动画，并且回调监听。

- 3.判断是否被padding裁剪内容区域，默认是开启的。这个情况下，则会滑动的区域，padding区域，以及viewgroup的区域，进行裁剪，而不是统统都画到Canvas中。
```java
            canvas.clipRect(mScrollX + mPaddingLeft, mScrollY + mPaddingTop,
                    mScrollX + mRight - mLeft - mPaddingRight,
                    mScrollY + mBottom - mTop - mPaddingBottom);
```

- 4.判断是否打开了硬件加速。如果没有，buildOrderedChildList对当前该ViewGroup下所有子View进行z轴上的插入排序，从而得知谁将绘制在更加更加上方。这个过程中z轴上的数值越小，越先调用drawChild方法绘制到canvas中，也就是层级越低，被其他子View覆盖在其上。在处理每一个孩子对应的drawChild方法之前，会先处理通过addTransientView添加进来的临时View。这种方式十分少见，你可以看成临时动画一样的效果，不参加view的onmeasure，onLayout，但是会绘制出来。需要手动的remove掉。

- 5.绘制通过addDisappearingView添加的消失临时View。

- 6.如果FLAG_NOTIFY_ANIMATION_LISTENER，FLAG_ANIMATION_DONE标志位都关闭了，同时Layout动画也完成了，所有的drawChild都返回了false，则在下一个Looper中开始时机调用notifyAnimationListener，通知监听者本次动画已经完成。


整个核心都是drawChild方法，我们来看看drawChild做了什么？

#### drawChild
```java
    protected boolean drawChild(Canvas canvas, View child, long drawingTime) {
        return child.draw(canvas, this, drawingTime);
    }
```
核心调用了view的draw方法。但是注意了，这个draw和上面那个draw方法不太一样。

```java
    boolean draw(Canvas canvas, ViewGroup parent, long drawingTime) {
        final boolean hardwareAcceleratedCanvas = canvas.isHardwareAccelerated();

        boolean drawingWithRenderNode = mAttachInfo != null
                && mAttachInfo.mHardwareAccelerated
                && hardwareAcceleratedCanvas;

        boolean more = false;
        final boolean childHasIdentityMatrix = hasIdentityMatrix();
        final int parentFlags = parent.mGroupFlags;

        if ((parentFlags & ViewGroup.FLAG_CLEAR_TRANSFORMATION) != 0) {
            parent.getChildTransformation().clear();
            parent.mGroupFlags &= ~ViewGroup.FLAG_CLEAR_TRANSFORMATION;
        }

        Transformation transformToApply = null;
        boolean concatMatrix = false;
        final boolean scalingRequired = mAttachInfo != null && mAttachInfo.mScalingRequired;
        final Animation a = getAnimation();
        if (a != null) {
            more = applyLegacyAnimation(parent, drawingTime, a, scalingRequired);
            concatMatrix = a.willChangeTransformationMatrix();
            if (concatMatrix) {
                mPrivateFlags3 |= PFLAG3_VIEW_IS_ANIMATING_TRANSFORM;
            }
            transformToApply = parent.getChildTransformation();
        } else {
            if ((mPrivateFlags3 & PFLAG3_VIEW_IS_ANIMATING_TRANSFORM) != 0) {
                // No longer animating: clear out old animation matrix
                mRenderNode.setAnimationMatrix(null);
                mPrivateFlags3 &= ~PFLAG3_VIEW_IS_ANIMATING_TRANSFORM;
            }
            if (!drawingWithRenderNode
                    && (parentFlags & ViewGroup.FLAG_SUPPORT_STATIC_TRANSFORMATIONS) != 0) {
                final Transformation t = parent.getChildTransformation();
                final boolean hasTransform = parent.getChildStaticTransformation(this, t);
                if (hasTransform) {
                    final int transformType = t.getTransformationType();
                    transformToApply = transformType != Transformation.TYPE_IDENTITY ? t : null;
                    concatMatrix = (transformType & Transformation.TYPE_MATRIX) != 0;
                }
            }
        }

        concatMatrix |= !childHasIdentityMatrix;

        // Sets the flag as early as possible to allow draw() implementations
        // to call invalidate() successfully when doing animations
        mPrivateFlags |= PFLAG_DRAWN;

        if (!concatMatrix &&
                (parentFlags & (ViewGroup.FLAG_SUPPORT_STATIC_TRANSFORMATIONS |
                        ViewGroup.FLAG_CLIP_CHILDREN)) == ViewGroup.FLAG_CLIP_CHILDREN &&
                canvas.quickReject(mLeft, mTop, mRight, mBottom, Canvas.EdgeType.BW) &&
                (mPrivateFlags & PFLAG_DRAW_ANIMATION) == 0) {
            mPrivateFlags2 |= PFLAG2_VIEW_QUICK_REJECTED;
            return more;
        }
        mPrivateFlags2 &= ~PFLAG2_VIEW_QUICK_REJECTED;

        if (hardwareAcceleratedCanvas) {
            // Clear INVALIDATED flag to allow invalidation to occur during rendering, but
            // retain the flag's value temporarily in the mRecreateDisplayList flag
            mRecreateDisplayList = (mPrivateFlags & PFLAG_INVALIDATED) != 0;
            mPrivateFlags &= ~PFLAG_INVALIDATED;
        }

        RenderNode renderNode = null;
        Bitmap cache = null;
        int layerType = getLayerType(); // TODO: signify cache state with just 'cache' local
        if (layerType == LAYER_TYPE_SOFTWARE || !drawingWithRenderNode) {
             if (layerType != LAYER_TYPE_NONE) {
                 // If not drawing with RenderNode, treat HW layers as SW
                 layerType = LAYER_TYPE_SOFTWARE;
                 buildDrawingCache(true);
            }
            cache = getDrawingCache(true);
        }

        if (drawingWithRenderNode) {
            renderNode = updateDisplayListIfDirty();
            if (!renderNode.isValid()) {
                renderNode = null;
                drawingWithRenderNode = false;
            }
        }

        int sx = 0;
        int sy = 0;
        if (!drawingWithRenderNode) {
            computeScroll();
            sx = mScrollX;
            sy = mScrollY;
        }

        final boolean drawingWithDrawingCache = cache != null && !drawingWithRenderNode;
        final boolean offsetForScroll = cache == null && !drawingWithRenderNode;

        int restoreTo = -1;
        if (!drawingWithRenderNode || transformToApply != null) {
            restoreTo = canvas.save();
        }
        if (offsetForScroll) {
            canvas.translate(mLeft - sx, mTop - sy);
        } else {
            if (!drawingWithRenderNode) {
                canvas.translate(mLeft, mTop);
            }
            if (scalingRequired) {
                if (drawingWithRenderNode) {
                    // TODO: Might not need this if we put everything inside the DL
                    restoreTo = canvas.save();
                }
                // mAttachInfo cannot be null, otherwise scalingRequired == false
                final float scale = 1.0f / mAttachInfo.mApplicationScale;
                canvas.scale(scale, scale);
            }
        }

        float alpha = drawingWithRenderNode ? 1 : (getAlpha() * getTransitionAlpha());
        if (transformToApply != null
                || alpha < 1
                || !hasIdentityMatrix()
                || (mPrivateFlags3 & PFLAG3_VIEW_IS_ANIMATING_ALPHA) != 0) {
            if (transformToApply != null || !childHasIdentityMatrix) {
                int transX = 0;
                int transY = 0;

                if (offsetForScroll) {
                    transX = -sx;
                    transY = -sy;
                }

                if (transformToApply != null) {
                    if (concatMatrix) {
                        if (drawingWithRenderNode) {
                            renderNode.setAnimationMatrix(transformToApply.getMatrix());
                        } else {

                            canvas.translate(-transX, -transY);
                            canvas.concat(transformToApply.getMatrix());
                            canvas.translate(transX, transY);
                        }
                        parent.mGroupFlags |= ViewGroup.FLAG_CLEAR_TRANSFORMATION;
                    }

                    float transformAlpha = transformToApply.getAlpha();
                    if (transformAlpha < 1) {
                        alpha *= transformAlpha;
                        parent.mGroupFlags |= ViewGroup.FLAG_CLEAR_TRANSFORMATION;
                    }
                }

                if (!childHasIdentityMatrix && !drawingWithRenderNode) {
                    canvas.translate(-transX, -transY);
                    canvas.concat(getMatrix());
                    canvas.translate(transX, transY);
                }
            }

            if (alpha < 1 || (mPrivateFlags3 & PFLAG3_VIEW_IS_ANIMATING_ALPHA) != 0) {
                if (alpha < 1) {
                    mPrivateFlags3 |= PFLAG3_VIEW_IS_ANIMATING_ALPHA;
                } else {
                    mPrivateFlags3 &= ~PFLAG3_VIEW_IS_ANIMATING_ALPHA;
                }
                parent.mGroupFlags |= ViewGroup.FLAG_CLEAR_TRANSFORMATION;
                if (!drawingWithDrawingCache) {
                    final int multipliedAlpha = (int) (255 * alpha);
                    if (!onSetAlpha(multipliedAlpha)) {
                        if (drawingWithRenderNode) {
                            renderNode.setAlpha(alpha * getAlpha() * getTransitionAlpha());
                        } else if (layerType == LAYER_TYPE_NONE) {
                            canvas.saveLayerAlpha(sx, sy, sx + getWidth(), sy + getHeight(),
                                    multipliedAlpha);
                        }
                    } else {
                        mPrivateFlags |= PFLAG_ALPHA_SET;
                    }
                }
            }
        } else if ((mPrivateFlags & PFLAG_ALPHA_SET) == PFLAG_ALPHA_SET) {
            onSetAlpha(255);
            mPrivateFlags &= ~PFLAG_ALPHA_SET;
        }

        if (!drawingWithRenderNode) {
            if ((parentFlags & ViewGroup.FLAG_CLIP_CHILDREN) != 0 && cache == null) {
                if (offsetForScroll) {
                    canvas.clipRect(sx, sy, sx + getWidth(), sy + getHeight());
                } else {
                    if (!scalingRequired || cache == null) {
                        canvas.clipRect(0, 0, getWidth(), getHeight());
                    } else {
                        canvas.clipRect(0, 0, cache.getWidth(), cache.getHeight());
                    }
                }
            }

            if (mClipBounds != null) {
                // clip bounds ignore scroll
                canvas.clipRect(mClipBounds);
            }
        }

        if (!drawingWithDrawingCache) {
            if (drawingWithRenderNode) {
                mPrivateFlags &= ~PFLAG_DIRTY_MASK;
                ((DisplayListCanvas) canvas).drawRenderNode(renderNode);
            } else {
                if ((mPrivateFlags & PFLAG_SKIP_DRAW) == PFLAG_SKIP_DRAW) {
                    mPrivateFlags &= ~PFLAG_DIRTY_MASK;
                    dispatchDraw(canvas);
                } else {
                    draw(canvas);
                }
            }
        } else if (cache != null) {
            mPrivateFlags &= ~PFLAG_DIRTY_MASK;
            if (layerType == LAYER_TYPE_NONE || mLayerPaint == null) {
                Paint cachePaint = parent.mCachePaint;
                if (cachePaint == null) {
                    cachePaint = new Paint();
                    cachePaint.setDither(false);
                    parent.mCachePaint = cachePaint;
                }
                cachePaint.setAlpha((int) (alpha * 255));
                canvas.drawBitmap(cache, 0.0f, 0.0f, cachePaint);
            } else {
                int layerPaintAlpha = mLayerPaint.getAlpha();
                if (alpha < 1) {
                    mLayerPaint.setAlpha((int) (alpha * layerPaintAlpha));
                }
                canvas.drawBitmap(cache, 0.0f, 0.0f, mLayerPaint);
                if (alpha < 1) {
                    mLayerPaint.setAlpha(layerPaintAlpha);
                }
            }
        }

        if (restoreTo >= 0) {
            canvas.restoreToCount(restoreTo);
        }

        if (a != null && !more) {
            if (!hardwareAcceleratedCanvas && !a.getFillAfter()) {
                onSetAlpha(255);
            }
            parent.finishAnimatingView(this, a);
        }

        if (more && hardwareAcceleratedCanvas) {
            if (a.hasAlpha() && (mPrivateFlags & PFLAG_ALPHA_SET) == PFLAG_ALPHA_SET) {
                invalidate(true);
            }
        }

        mRecreateDisplayList = false;

        return more;
    }
```
上面这个方法做了一个很重要的事情，那就是绘制每一个View的缓存。在这个过程中有两个比较重要的标志位：
```java
 boolean drawingWithRenderNode = mAttachInfo != null
                && mAttachInfo.mHardwareAccelerated
                && hardwareAcceleratedCanvas;
```
drawingWithRenderNode判断是否需要通过硬件绘制RenderNode。

```java
final boolean drawingWithDrawingCache = cache != null && !drawingWithRenderNode;
```
drawingWithDrawingCache是否绘制view中的缓存由2点决定，一个是关闭硬件渲染，另一个是缓存的bitmap不为空。

做到的事情如下：
- 1.首先判断View中是否通过setAnimation设置了一个变换矩阵Transformation动画到View中。如果有，则调用applyLegacyAnimation方法确定整个变化动画刷新的范围在这个View范围内；transformToApply设置为父容器的Transformation。如果没有设置Animation，则判断是否关闭了硬件渲染且打开了FLAG_SUPPORT_STATIC_TRANSFORMATIONS。也就是说当前的View的父容器是否存在一个静态的变换矩阵，存在则更新到transformToApply中。

- 2.如果mLayerType为LAYER_TYPE_SOFTWARE或者关闭了硬件渲染，说明是一个软件渲染，则调用buildDrawingCache构建一个绘制的缓存，通过getDrawingCache获取这个缓存bitmap到cache中。

- 3.如果drawingWithRenderNode为true，说明在使用硬件渲染。则调用updateDisplayListIfDirty更新DisplayList中的脏区。

- 4.drawingWithRenderNode为false，则调用computeScroll计算滑动区域，赋值给sx和sy。

- 5.如果存在一个变换矩阵或者关闭硬件渲染，则调用canvas的save方法保存当前的状态。如果offsetForScroll为true(说明此时是软件渲染同时没有缓存)，则调用canvas的translate方法参数第四步骤中计算出来平移距离。
> 横向平移：mLeft - sx
> 纵向平移： mTop - sy

这么做可以把绘制的原点移动到平移 平移后的位置，之后所有的绘制都是基于这个点进行的

- 6.offsetForScroll为false，说明此时可能需要绘制缓存或者是硬件渲染，只做了两件事情：平移当前的画布的绘制原点，如果需要则对整个画布进行伸缩。

- 7.如果transformToApply不为空，前提下。发现打开了硬件渲染，则调用RenderNode.setAnimationMatrix方法设置动画的矩阵。如果关闭，则先回退经过平移的Canvas原点，先对动画矩阵进行合并后在进行滑动的移动。

- 8.如果alpha小于1，且判断到drawingWithDrawingCache关闭的。则说明可以在当前的绘制结果中进行透明度处理。判断onSetAlpha为false，如果是硬件渲染则调用renderNode.setAlpha，如果是软件渲染则调用canvas.saveLayerAlpha。如果绘制缓存是打开。onSetAlpha如果为true说明整个透明是由子View决定的，因此先打开PFLAG_ALPHA_SET标志位，等待后续的处理。

- 9.如果父容器打开了FLAG_CLIP_CHILDREN标志位且当前的View没有缓存。说明当前的View绘制的结果需要被父容器裁剪了：
如果进行了滑动，则裁剪区域如下：
>  canvas.clipRect(sx, sy, sx + getWidth(), sy + getHeight());
如果没有缓存，则直接裁剪当前的View
> canvas.clipRect(0, 0, getWidth(), getHeight());
有缓存：
>  canvas.clipRect(0, 0, cache.getWidth(), cache.getHeight());
如果需要根据边缘进行裁剪：
> canvas.clipRect(mClipBounds);

- 10.drawingWithDrawingCache如果是关闭，且drawingWithRenderNode是打开的，则调用DisplayListCanvas.drawRenderNode(renderNode) 方法。参数中的renderNode是updateDisplayListIfDirty方法生成一个新的DisplayListCanvas。通过drawRenderNode把结果绘制到父容器的DisplayListCanvas。

- 11.drawingWithDrawingCache关闭，drawingWithRenderNode也是关闭的。说明此时是直接进行绘制。如果打开了PFLAG_SKIP_DRAW标志位说明需要直接掉过当前的View，直接调用dispatchDraw分发View的绘制命令。如果没有打开，则调用draw方法。就会继续调用onDraw后并且dispatchDraw分发View的绘制方法。

- 12.drawingWithDrawingCache是打开的，同时cache缓存不为空，则把cache中的结果绘制到Canvas中。


- 13.当所有子View都绘制结束之后，则调用canvas.restoreToCount方法一层层的恢复绘制状态。主要还是恢复绘制原点。调用父容器的finishAnimatingView清空所有的Animation以及disappearingAnimation，回调onAnimationEnd。

在这几点中，除去Canvas操作(关于Canvas操作，我会专门开一个Skia源码解析专题进行分析)有几个比较重要的方法：
- 1.buildDrawingCache 构建一个绘制缓存对象
- 2.updateDisplayListIfDirty 硬件渲染更新脏区

##### buildDrawingCache
```java
    public void buildDrawingCache(boolean autoScale) {
        if ((mPrivateFlags & PFLAG_DRAWING_CACHE_VALID) == 0 || (autoScale ?
                mDrawingCache == null : mUnscaledDrawingCache == null)) {
            try {
                buildDrawingCacheImpl(autoScale);
            } finally {
            }
        }
    }
```
能看到实际上就是调用buildDrawingCacheImpl.

###### buildDrawingCacheImpl
```java
    private void buildDrawingCacheImpl(boolean autoScale) {
        mCachingFailed = false;

        int width = mRight - mLeft;
        int height = mBottom - mTop;

        final AttachInfo attachInfo = mAttachInfo;
        final boolean scalingRequired = attachInfo != null && attachInfo.mScalingRequired;

        if (autoScale && scalingRequired) {
            width = (int) ((width * attachInfo.mApplicationScale) + 0.5f);
            height = (int) ((height * attachInfo.mApplicationScale) + 0.5f);
        }

        final int drawingCacheBackgroundColor = mDrawingCacheBackgroundColor;
        final boolean opaque = drawingCacheBackgroundColor != 0 || isOpaque();
        final boolean use32BitCache = attachInfo != null && attachInfo.mUse32BitDrawingCache;

        final long projectedBitmapSize = width * height * (opaque && !use32BitCache ? 2 : 4);
        final long drawingCacheSize =
                ViewConfiguration.get(mContext).getScaledMaximumDrawingCacheSize();
        if (width <= 0 || height <= 0 || projectedBitmapSize > drawingCacheSize) {
            if (width > 0 && height > 0) {
                Log.w(VIEW_LOG_TAG, getClass().getSimpleName() + " not displayed because it is"
                        + " too large to fit into a software layer (or drawing cache), needs "
                        + projectedBitmapSize + " bytes, only "
                        + drawingCacheSize + " available");
            }
            destroyDrawingCache();
            mCachingFailed = true;
            return;
        }

        boolean clear = true;
        Bitmap bitmap = autoScale ? mDrawingCache : mUnscaledDrawingCache;

        if (bitmap == null || bitmap.getWidth() != width || bitmap.getHeight() != height) {
            Bitmap.Config quality;
            if (!opaque) {
                // Never pick ARGB_4444 because it looks awful
                // Keep the DRAWING_CACHE_QUALITY_LOW flag just in case
                switch (mViewFlags & DRAWING_CACHE_QUALITY_MASK) {
                    case DRAWING_CACHE_QUALITY_AUTO:
                    case DRAWING_CACHE_QUALITY_LOW:
                    case DRAWING_CACHE_QUALITY_HIGH:
                    default:
                        quality = Bitmap.Config.ARGB_8888;
                        break;
                }
            } else {
                
                quality = use32BitCache ? Bitmap.Config.ARGB_8888 : Bitmap.Config.RGB_565;
            }

            if (bitmap != null) bitmap.recycle();

            try {
                bitmap = Bitmap.createBitmap(mResources.getDisplayMetrics(),
                        width, height, quality);
                bitmap.setDensity(getResources().getDisplayMetrics().densityDpi);
                if (autoScale) {
                    mDrawingCache = bitmap;
                } else {
                    mUnscaledDrawingCache = bitmap;
                }
                if (opaque && use32BitCache) bitmap.setHasAlpha(false);
            } catch (OutOfMemoryError e) {
                
                if (autoScale) {
                    mDrawingCache = null;
                } else {
                    mUnscaledDrawingCache = null;
                }
                mCachingFailed = true;
                return;
            }

            clear = drawingCacheBackgroundColor != 0;
        }

        Canvas canvas;
        if (attachInfo != null) {
            canvas = attachInfo.mCanvas;
            if (canvas == null) {
                canvas = new Canvas();
            }
            canvas.setBitmap(bitmap);
            attachInfo.mCanvas = null;
        } else {
            canvas = new Canvas(bitmap);
        }

        if (clear) {
            bitmap.eraseColor(drawingCacheBackgroundColor);
        }

        computeScroll();
        final int restoreCount = canvas.save();

        if (autoScale && scalingRequired) {
            final float scale = attachInfo.mApplicationScale;
            canvas.scale(scale, scale);
        }

        canvas.translate(-mScrollX, -mScrollY);

        mPrivateFlags |= PFLAG_DRAWN;
        if (mAttachInfo == null || !mAttachInfo.mHardwareAccelerated ||
                mLayerType != LAYER_TYPE_NONE) {
            mPrivateFlags |= PFLAG_DRAWING_CACHE_VALID;
        }

        if ((mPrivateFlags & PFLAG_SKIP_DRAW) == PFLAG_SKIP_DRAW) {
            mPrivateFlags &= ~PFLAG_DIRTY_MASK;
            dispatchDraw(canvas);
            drawAutofilledHighlight(canvas);
            if (mOverlay != null && !mOverlay.isEmpty()) {
                mOverlay.getOverlayView().draw(canvas);
            }
        } else {
            draw(canvas);
        }

        canvas.restoreToCount(restoreCount);
        canvas.setBitmap(null);

        if (attachInfo != null) {
            attachInfo.mCanvas = canvas;
        }
    }
```
- 1.在创建绘制的缓存bitmap之前，如果当前View的宽高其中之一小于等于0，或者当前View需要内存大于最大允许的缓存View大小。
这个过程中，View绘制后的缓存计算方法如下：
> projectedBitmapSize = width * height * (opaque && !use32BitCache ? 2 : 4);

能看到这个过程中判断是否需要透明且关闭32的缓存，一个像素就会2位，否则则是4位。

如果计算出来的结果比MAXIMUM_DRAWING_CACHE_SIZE大则销毁绘制缓存。
```java
private static final int MAXIMUM_DRAWING_CACHE_SIZE = 480 * 800 * 4; // ARGB8888
```
能看到每一个View最大只能是由宽480，高800且是ARGB8888模式内存大小。

- 2.如果View的大小发生了变化，则调用Bitmap.createBitmap的方法创建一个对应View大小的Bitmap。

- 3.如果attachInfo不为空，则判断是否存在一个全局的Canvas，如果不存在就创建一个新的Canvas，并把bitmap设置到Canvas中。

- 4.如果需要进行伸缩，则伸缩缓存bitmap。如果需要滑动，则移动整个Canvas的绘制原点。

- 5.如果PFLAG_SKIP_DRAW 打开了，则直接调用dispatchDraw，继续分发绘制流程。关闭了则调用draw方法，先调用onDraw后调用dispatchDraw。


能看到在上面draw方法中因为检测存在绘制缓存而跳过的流程，在这个方法中都进行处理了。


##### updateDisplayListIfDirty
```java
public RenderNode updateDisplayListIfDirty() {
        final RenderNode renderNode = mRenderNode;
        if (!canHaveDisplayList()) {
            return renderNode;
        }

        if ((mPrivateFlags & PFLAG_DRAWING_CACHE_VALID) == 0
                || !renderNode.isValid()
                || (mRecreateDisplayList)) {
            if (renderNode.isValid()
                    && !mRecreateDisplayList) {
                mPrivateFlags |= PFLAG_DRAWN | PFLAG_DRAWING_CACHE_VALID;
                mPrivateFlags &= ~PFLAG_DIRTY_MASK;
                dispatchGetDisplayList();

                return renderNode; // no work needed
            }

            mRecreateDisplayList = true;

            int width = mRight - mLeft;
            int height = mBottom - mTop;
            int layerType = getLayerType();

            final DisplayListCanvas canvas = renderNode.start(width, height);

            try {
                if (layerType == LAYER_TYPE_SOFTWARE) {
                    buildDrawingCache(true);
                    Bitmap cache = getDrawingCache(true);
                    if (cache != null) {
                        canvas.drawBitmap(cache, 0, 0, mLayerPaint);
                    }
                } else {
                    computeScroll();

                    canvas.translate(-mScrollX, -mScrollY);
                    mPrivateFlags |= PFLAG_DRAWN | PFLAG_DRAWING_CACHE_VALID;
                    mPrivateFlags &= ~PFLAG_DIRTY_MASK;

                    // Fast path for layouts with no backgrounds
                    if ((mPrivateFlags & PFLAG_SKIP_DRAW) == PFLAG_SKIP_DRAW) {
                        dispatchDraw(canvas);
                        drawAutofilledHighlight(canvas);
                        if (mOverlay != null && !mOverlay.isEmpty()) {
                            mOverlay.getOverlayView().draw(canvas);
                        }
                        if (debugDraw()) {
                            debugDrawFocus(canvas);
                        }
                    } else {
                        draw(canvas);
                    }
                }
            } finally {
                renderNode.end(canvas);
                setDisplayListProperties(renderNode);
            }
        } else {
            mPrivateFlags |= PFLAG_DRAWN | PFLAG_DRAWING_CACHE_VALID;
            mPrivateFlags &= ~PFLAG_DIRTY_MASK;
        }
        return renderNode;
    }
```
- 1.如果canHaveDisplayList为 false也就是mThreadedRenderer为null，则直接返回。


如果PFLAG_DRAWING_CACHE_VALID关闭，或者renderNode是无效的，或者mRecreateDisplayList是false。则进入到RenderNode的Canvas绘制中。

- 2.如果renderNode是有效的，且不需要进行重新构建整个硬件渲染的DisplayList(mRecreateDisplayList为false)，说明不是第一次绘制了已经有绘制结果了，则调用dispatchGetDisplayList。

- 3.接下来的情景说明是第一次绘制，renderNode还是属于无效状态。其初始化流程如下：
    - 1.renderNode.start(width, height) 调用start方法创建一个全新的DisplayListCanvas
    - 2.如果LayerType是LAYER_TYPE_SOFTWARE，就算是Layer的模式是软件渲染模式，如果打开了硬件渲染模式，还是会把当前View对应绘制缓存bitmap通过setBitmap的方式设置到DisplayListCanvas中。
    - 3.如果不是LAYER_TYPE_SOFTWARE，调用computeScroll进行滑动计算后。把整个RenderNode的绘制原点退回到滑动之前的状态，并且打上PFLAG_DRAWN和PFLAG_DRAWING_CACHE_VALID两个标志位。
    - 4.如果打开PFLAG_SKIP_DRAW，则直接调用dispatchDraw，分发绘制流程。
    - 5.没有打开PFLAG_SKIP_DRAW，则直接调用draw方法，先回调onDraw再调用dispatchDraw进行分发。

- 4.最后调用renderNode.end(canvas) 结束整个RenderNode的绘制。

我们来看看非第一次绘制时候dispatchGetDisplayList做了什么？

##### ViewGroup dispatchGetDisplayList
```java
    protected void dispatchGetDisplayList() {
        final int count = mChildrenCount;
        final View[] children = mChildren;
        for (int i = 0; i < count; i++) {
            final View child = children[i];
            if (((child.mViewFlags & VISIBILITY_MASK) == VISIBLE || child.getAnimation() != null)) {
                recreateChildDisplayList(child);
            }
        }
        final int transientCount = mTransientViews == null ? 0 : mTransientIndices.size();
        for (int i = 0; i < transientCount; ++i) {
            View child = mTransientViews.get(i);
            if (((child.mViewFlags & VISIBILITY_MASK) == VISIBLE || child.getAnimation() != null)) {
                recreateChildDisplayList(child);
            }
        }
        if (mOverlay != null) {
            View overlayView = mOverlay.getOverlayView();
            recreateChildDisplayList(overlayView);
        }
        if (mDisappearingChildren != null) {
            final ArrayList<View> disappearingChildren = mDisappearingChildren;
            final int disappearingCount = disappearingChildren.size();
            for (int i = 0; i < disappearingCount; ++i) {
                final View child = disappearingChildren.get(i);
                recreateChildDisplayList(child);
            }
        }
    }
```

能看到实际上很简单，对4种View进行recreateChildDisplayList处理。
- 1.所有的可见子View或者带着动画的子View
- 2.mTransientViews 通过addTransientView添加进来的临时View
- 3.overlayView 每一个View的浮层
- 4.mDisappearingChildren 通过addDisappearingView 添加进来的当View移除时候需要的动画View。

##### ViewGroup recreateChildDisplayList
```java
    private void recreateChildDisplayList(View child) {
        child.mRecreateDisplayList = (child.mPrivateFlags & PFLAG_INVALIDATED) != 0;
        child.mPrivateFlags &= ~PFLAG_INVALIDATED;
        child.updateDisplayListIfDirty();
        child.mRecreateDisplayList = false;
    }
```
能看到这个过程实际上就是调用了子View的updateDisplayListIfDirty方法。

### pendingDrawFinished
当一切都处理完毕之后，就会调用pendingDrawFinished。如果mDrawsNeededToReport计数为0，则说明所有需要绘制的命令全部完成了。最后调用reportDrawFinished。
```java
    void pendingDrawFinished() {
        if (mDrawsNeededToReport == 0) {
            throw new RuntimeException("Unbalanced drawPending/pendingDrawFinished calls");
        }
        mDrawsNeededToReport--;
        if (mDrawsNeededToReport == 0) {
            reportDrawFinished();
        }
    }
```

#### reportDrawFinished
```java
    private void reportDrawFinished() {
        try {
            mDrawsNeededToReport = 0;
            mWindowSession.finishDrawing(mWindow);
        } catch (RemoteException e) {
            // Have fun!
        }
    }
```
能看到最后会调用reportDrawFinished，通知WindowSession已经finishDrawing。


```java
    public void finishDrawing(IWindow window) {
        if (WindowManagerService.localLOGV) Slog.v(
            TAG_WM, "IWindow finishDrawing called for " + window);
        mService.finishDrawingWindow(this, window);
    }

```

#### WMS finishDrawingWindow
```java
    void finishDrawingWindow(Session session, IWindow client) {
        final long origId = Binder.clearCallingIdentity();
        try {
            synchronized (mWindowMap) {
                WindowState win = windowForClientLocked(session, client, false);
                if (win != null && win.mWinAnimator.finishDrawingLocked()) {
                    if ((win.mAttrs.flags & FLAG_SHOW_WALLPAPER) != 0) {
                        win.getDisplayContent().pendingLayoutChanges |=
                                WindowManagerPolicy.FINISH_LAYOUT_REDO_WALLPAPER;
                    }
                    win.setDisplayLayoutNeeded();
                    mWindowPlacerLocked.requestTraversal();
                }
            }
        } finally {
            Binder.restoreCallingIdentity(origId);
        }
    }
```
会调用WindowState的setDisplayLayoutNeeded。设置DisplayContent的mLayoutNeeded为true。

调用WindowSurfacePlacer的requestTraversal。而这个方法会在AnimationHandler 窗体动画的handler中调用performSurfacePlacement。而这里的逻辑可以阅读[WMS在Activity启动中的职责 计算窗体的大小](https://www.jianshu.com/p/e83496ca788c)



## 总结
到这列就完成了onDraw的解析。从onMeasure，onLayout，onDraw四个流程已经过了一遍。但是还没有仔细聊聊硬件渲染，但是没关系，从软件渲染也能一窥整个核心流程了。

老规矩，先来一副时序图：
![View的绘制流程.jpg](/images/View的绘制流程.jpg)

整个onDraw的入口依次执行了如下的方法：
- 1.执行该View的background 背景的绘制
- 2.执行该View重写的onDraw流程，进行绘制
- 3.dispatchDraw 把绘制行为分发到子View中
- 4.判断是否有overlay，有则绘制每一个View的浮层的dispatchDraw
- 5.onDrawForeground 绘制View的前景drawable
- 6.drawDefaultFocusHighlight 绘制默认的焦点高亮。


每一次进行一次onDraw之前对dirtyOpaque标志位进行判断，实际上就是判断是否是透明的，是透明的就不会调用该View的onDraw方法。

其中dispatchDraw进行绘制行为分发后，就会调用drawChild的方法会每一个子View的draw方法。

这个过程中，软件渲染过程中会伴随着绘制一个Bitmap的缓存。每一个View都能够申请到的缓存最大数值就是：
> (宽/高)480 * (宽/高)800 * 4(ARGB8889)

如果超出这个数值就不会出现缓存，或者直到OOM了也会销毁缓存。

当执行完毕之后，必定会调用WMS的finishDrawingWindow，告诉WMS ViewRootImpl已经完成了绘制工作。这个方法会设置DisplayContent的mLayoutNeeded为true。这样就能告诉WMS，当下一轮WMS的relayoutWindow对窗体进行重新测量的时候，允许遍历DisplayContent所有的内容窗体(详细的可以看看我写的[WMS在Activity启动中的职责 计算窗体的大小](https://www.jianshu.com/p/e83496ca788c))。

本文已经涉及到不少关于硬件渲染的逻辑，下一篇就来聊聊硬件绘制的原理。

