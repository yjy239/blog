---
title: Android 重学系列 View的绘制流程(三) onLayout
top: false
cover: false
date: 2020-06-05 23:20:19
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
上一篇文章和大家聊了onMeasure的原理，本文继续和大家聊聊onLayout的核心原理。


# 正文

## onLayout的原理
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)
```java
        final boolean didLayout = layoutRequested && (!mStopped || mReportNextDraw);
        boolean triggerGlobalLayoutListener = didLayout
                || mAttachInfo.mRecomputeGlobalAttributes;
        if (didLayout) {
            performLayout(lp, mWidth, mHeight);

            if ((host.mPrivateFlags & View.PFLAG_REQUEST_TRANSPARENT_REGIONS) != 0) {
                host.getLocationInWindow(mTmpLocation);
                mTransparentRegion.set(mTmpLocation[0], mTmpLocation[1],
                        mTmpLocation[0] + host.mRight - host.mLeft,
                        mTmpLocation[1] + host.mBottom - host.mTop);

                host.gatherTransparentRegion(mTransparentRegion);
                if (mTranslator != null) {
                    mTranslator.translateRegionInWindowToScreen(mTransparentRegion);
                }

                if (!mTransparentRegion.equals(mPreviousTransparentRegion)) {
                    mPreviousTransparentRegion.set(mTransparentRegion);
                    mFullRedrawNeeded = true;
                    try {
                        mWindowSession.setTransparentRegion(mWindow, mTransparentRegion);
                    } catch (RemoteException e) {
                    }
                }
            }

        }

        if (triggerGlobalLayoutListener) {
            mAttachInfo.mRecomputeGlobalAttributes = false;
            mAttachInfo.mTreeObserver.dispatchOnGlobalLayout();
        }
//分发内部的insets，这里我们暂时不去关心省略的逻辑
...
        }

```
接下来performTraversals后续事情分为如下几个方面：
- 1.就是判断当前的View是否需要重新摆放位置。如果通过requestLayout执行performTraversals方法，则layoutRequested为true；此时需要调用performLayout进行重新的摆放。

- 2.判断到调用了requestTransparentRegion方法，需要重新计算透明区域，则会调用gatherTransparentRegion方法重新计算透明区域。如果发现当前的和之前的透明区域发生了变化，则通过WindowSession更新WMS那边的区域。

这种情况通常是指存在SurfaceView的情况。因为SurfaceView本身就拥有自己的一套体系沟通到SF体系中进行渲染。Android没有必要把SurfaceView纳入到层级中处理，需要把这部分当作透明，当作不必要的层级进行优化。


整个核心我还是回头关注performLayout究竟做了什么？

### ViewRootImpl performLayout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)

```java
    private void performLayout(WindowManager.LayoutParams lp, int desiredWindowWidth,
            int desiredWindowHeight) {
        mLayoutRequested = false;
        mScrollMayChange = true;
        mInLayout = true;

        final View host = mView;
        if (host == null) {
            return;
        }


        try {
            host.layout(0, 0, host.getMeasuredWidth(), host.getMeasuredHeight());

            mInLayout = false;
            int numViewsRequestingLayout = mLayoutRequesters.size();
            if (numViewsRequestingLayout > 0) {

                ArrayList<View> validLayoutRequesters = getValidLayoutRequesters(mLayoutRequesters,
                        false);
                if (validLayoutRequesters != null) {

                    mHandlingLayoutInLayoutRequest = true;

                    int numValidRequests = validLayoutRequesters.size();
                    for (int i = 0; i < numValidRequests; ++i) {
                        final View view = validLayoutRequesters.get(i);
                        view.requestLayout();
                    }
                    measureHierarchy(host, lp, mView.getContext().getResources(),
                            desiredWindowWidth, desiredWindowHeight);
                    mInLayout = true;
                    host.layout(0, 0, host.getMeasuredWidth(), host.getMeasuredHeight());

                    mHandlingLayoutInLayoutRequest = false;


                    validLayoutRequesters = getValidLayoutRequesters(mLayoutRequesters, true);
                    if (validLayoutRequesters != null) {
                        final ArrayList<View> finalRequesters = validLayoutRequesters;

                        getRunQueue().post(new Runnable() {
                            @Override
                            public void run() {
                                int numValidRequests = finalRequesters.size();
                                for (int i = 0; i < numValidRequests; ++i) {
                                    final View view = finalRequesters.get(i);

                                    view.requestLayout();
                                }
                            }
                        });
                    }
                }

            }
        } finally {
            Trace.traceEnd(Trace.TRACE_TAG_VIEW);
        }
        mInLayout = false;
    }
```
其实整个核心还是这一段代码：
```
            host.layout(0, 0, host.getMeasuredWidth(), host.getMeasuredHeight());
```

这一段代码将会开启遍历View树的layout的流程，也就是View的摆放的流程。

当处理完layout流程之后，就会继续检查是否有View在测量，摆放的流程请求
中是否有别的View请求进行刷新，如果请求则把这个View保存在mLayoutRequesters对象中。此时取出重新进行测量和摆放。

记住此时的根布局是DecorView是layout方法.由于DecorView和FrameLayout都有重写layout，我们来看看ViewGroup的layout.

### ViewGroup layout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewGroup.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewGroup.java)

```java
    public final void layout(int l, int t, int r, int b) {
        if (!mSuppressLayout && (mTransition == null || !mTransition.isChangingLayout())) {
            if (mTransition != null) {
                mTransition.layoutChange(this);
            }
            super.layout(l, t, r, b);
        } else {
            // record the fact that we noop'd it; request layout when transition finishes
            mLayoutCalledWhileSuppressed = true;
        }
    }
```
能看到，layout走到View的layout方法的条件有2:
- 1.mSuppressLayout为false，也就是不设置抑制Layout方法
- 2.mTransition LayoutTransition 布局动画为空或者没有改变才可以。

在Android中动画api中提供了LayoutTransition，用于对子View的加入和移除添加自定义的属性动画。有一篇文章写的挺好的可以看看：[LayoutTransition的使用介绍](https://juejin.im/entry/57de086f816dfa0067f539ac)

记住此时从DecorView传进来的layout四个参数，分别代表该View可以摆放的左部，顶部，右部，底部四个位置。但是不代表该View就是摆放到这个位置

### View layout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)

```java
    public void layout(int l, int t, int r, int b) {
        if ((mPrivateFlags3 & PFLAG3_MEASURE_NEEDED_BEFORE_LAYOUT) != 0) {
            onMeasure(mOldWidthMeasureSpec, mOldHeightMeasureSpec);
            mPrivateFlags3 &= ~PFLAG3_MEASURE_NEEDED_BEFORE_LAYOUT;
        }

        int oldL = mLeft;
        int oldT = mTop;
        int oldB = mBottom;
        int oldR = mRight;

        boolean changed = isLayoutModeOptical(mParent) ?
                setOpticalFrame(l, t, r, b) : setFrame(l, t, r, b);

        if (changed || (mPrivateFlags & PFLAG_LAYOUT_REQUIRED) == PFLAG_LAYOUT_REQUIRED) {
            onLayout(changed, l, t, r, b);

            if (shouldDrawRoundScrollbar()) {
                if(mRoundScrollbarRenderer == null) {
                    mRoundScrollbarRenderer = new RoundScrollbarRenderer(this);
                }
            } else {
                mRoundScrollbarRenderer = null;
            }

            mPrivateFlags &= ~PFLAG_LAYOUT_REQUIRED;

            ListenerInfo li = mListenerInfo;
            if (li != null && li.mOnLayoutChangeListeners != null) {
                ArrayList<OnLayoutChangeListener> listenersCopy =
                        (ArrayList<OnLayoutChangeListener>)li.mOnLayoutChangeListeners.clone();
                int numListeners = listenersCopy.size();
                for (int i = 0; i < numListeners; ++i) {
                    listenersCopy.get(i).onLayoutChange(this, l, t, r, b, oldL, oldT, oldR, oldB);
                }
            }
        }

        final boolean wasLayoutValid = isLayoutValid();

        mPrivateFlags &= ~PFLAG_FORCE_LAYOUT;
        mPrivateFlags3 |= PFLAG3_IS_LAID_OUT;

        if (!wasLayoutValid && isFocused()) {
            mPrivateFlags &= ~PFLAG_WANTS_FOCUS;
            if (canTakeFocus()) {
                clearParentsWantFocus();
            } else if (getViewRootImpl() == null || !getViewRootImpl().isInLayout()) {

                clearFocusInternal(null, /* propagate */ true, /* refocus */ false);
                clearParentsWantFocus();
            } else if (!hasParentWantsFocus()) {

                clearFocusInternal(null, /* propagate */ true, /* refocus */ false);
            }

        } else if ((mPrivateFlags & PFLAG_WANTS_FOCUS) != 0) {
            mPrivateFlags &= ~PFLAG_WANTS_FOCUS;
            View focused = findFocus();
            if (focused != null) {
                // Try to restore focus as close as possible to our starting focus.
                if (!restoreDefaultFocus() && !hasParentWantsFocus()) {
                    focused.clearFocusInternal(null, /* propagate */ true, /* refocus */ false);
                }
            }
        }

        if ((mPrivateFlags3 & PFLAG3_NOTIFY_AUTOFILL_ENTER_ON_LAYOUT) != 0) {
            mPrivateFlags3 &= ~PFLAG3_NOTIFY_AUTOFILL_ENTER_ON_LAYOUT;
            notifyEnterOrExitForAutoFillIfNeeded(true);
        }
    }
```
在这里可以分为如下几个步骤：
- 1.判断PFLAG3_MEASURE_NEEDED_BEFORE_LAYOUT是否开启了。这个标志位打开的时机是在onMeasure步骤发现原来父容器传递下来的大小不变，就会设置老的测量结果在View中。在layout的步骤会先调用一次onMeasure继续遍历测量底层的子View的大小。

- 2.判断isLayoutModeOptical是否开启了光学边缘模式。打开了则setOpticalFrame进行四个方向的边缘设置，否则则setFrame处理。用于判断是否需要更新四个方向的数值。

- 3.如果发生了大小或者摆放的位置变化，则进行onLayout的回调。一般子类都会重写这个方法，进行进一步的摆放设置。

- 4.如果需要显示滑动块，则初始化RoundScrollbarRenderer对象。这个对象实际上就一个封装好如何绘制绘制一个滑动块的自定义View。

- 5.回调已经进行了Layout变化监听的OnLayoutChangeListener回调。

- 6.当前View的layout的行为进行的同时没有另一个layout进行，说明当前的Layout行为是有效的。如果layout的行为是无效的，此时的View又获取了焦点则清除。如果此时是想要请求焦点，则清空焦点。

- 7.通知AllFillManager进行相关的处理。

这里我们着重看看setFrame方法做了什么。

#### setFrame
```java
    protected boolean setFrame(int left, int top, int right, int bottom) {
        boolean changed = false;

        if (mLeft != left || mRight != right || mTop != top || mBottom != bottom) {
            changed = true;
            int drawn = mPrivateFlags & PFLAG_DRAWN;

            int oldWidth = mRight - mLeft;
            int oldHeight = mBottom - mTop;
            int newWidth = right - left;
            int newHeight = bottom - top;
            boolean sizeChanged = (newWidth != oldWidth) || (newHeight != oldHeight);

            invalidate(sizeChanged);

            mLeft = left;
            mTop = top;
            mRight = right;
            mBottom = bottom;
            mRenderNode.setLeftTopRightBottom(mLeft, mTop, mRight, mBottom);

            mPrivateFlags |= PFLAG_HAS_BOUNDS;


            if (sizeChanged) {
                sizeChange(newWidth, newHeight, oldWidth, oldHeight);
            }

            if ((mViewFlags & VISIBILITY_MASK) == VISIBLE || mGhostView != null) {

                mPrivateFlags |= PFLAG_DRAWN;
                invalidate(sizeChanged);

                invalidateParentCaches();
            }

            mPrivateFlags |= drawn;

            mBackgroundSizeChanged = true;
            mDefaultFocusHighlightSizeChanged = true;
            if (mForegroundInfo != null) {
                mForegroundInfo.mBoundsChanged = true;
            }

            notifySubtreeAccessibilityStateChangedIfNeeded();
        }
        return changed;
    }
```
就以setFrame为例子来看看其核心思想。实际上很简单：

- 1.比较左上右下四个方向的数值是否发生了变化。如果发生了变化，则更新四个方向的大小,并判断整个需要绘制的区域是否发生了变化，把sizechange作为参数调用invalidate进行onDraw的刷新。

- 2.获取mRenderNode这个硬件渲染的对象，并且设置这个渲染点的位置。

- 3.调用sizeChange方法进行onSizeChange的回调：
```java
    private void sizeChange(int newWidth, int newHeight, int oldWidth, int oldHeight) {
        onSizeChanged(newWidth, newHeight, oldWidth, oldHeight);
        if (mOverlay != null) {
            mOverlay.getOverlayView().setRight(newWidth);
            mOverlay.getOverlayView().setBottom(newHeight);
        }

        if (!sCanFocusZeroSized && isLayoutValid()
                // Don't touch focus if animating
                && !(mParent instanceof ViewGroup && ((ViewGroup) mParent).isLayoutSuppressed())) {
            if (newWidth <= 0 || newHeight <= 0) {
                if (hasFocus()) {
                    clearFocus();
                    if (mParent instanceof ViewGroup) {
                        ((ViewGroup) mParent).clearFocusedInCluster();
                    }
                }
                clearAccessibilityFocus();
            } else if (oldWidth <= 0 || oldHeight <= 0) {
                if (mParent != null && canTakeFocus()) {
                    mParent.focusableViewAvailable(this);
                }
            }
        }
        rebuildOutline();
    }
```
如果当前不是ViewGroup且新的宽高小于0焦点则清除焦点，并且通知AccessibilityService。如果新的宽高大于0，则通知父容器焦点可集中。最后重新构建外框。

- 4.如果判断到mGhostView不为空，且当前的View可见。则对mGhostView发出draw的刷新命令。并通知父容器也刷新。这里mGhostView实际上是一层覆盖层，作用和ViewOverLay相似。

到这里View和ViewGroup的onLayout似乎就看完了。但是还没有完。记得我们现在分析的是DecorView。因此我们看看DecorView在onLayout中做了什么。

### DecorView onLayout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/)/[policy](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/)/[DecorView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/DecorView.java)

```java
    protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
        super.onLayout(changed, left, top, right, bottom);
        getOutsets(mOutsets);
        if (mOutsets.left > 0) {
            offsetLeftAndRight(-mOutsets.left);
        }
        if (mOutsets.top > 0) {
            offsetTopAndBottom(-mOutsets.top);
        }
        if (mApplyFloatingVerticalInsets) {
            offsetTopAndBottom(mFloatingInsets.top);
        }
        if (mApplyFloatingHorizontalInsets) {
            offsetLeftAndRight(mFloatingInsets.left);
        }

        updateElevation();
        mAllowUpdateElevation = true;

        if (changed && mResizeMode == RESIZE_MODE_DOCKED_DIVIDER) {
            getViewRootImpl().requestInvalidateRootRenderNode();
        }
    }
```
- 1.先调用了FrameLayout的onLayout的方法后，确定每一个子View的摆放位置。

- 2.getOutsets方法获取mAttachInfo中的mOutSet区域。从上一篇文章的打印看来，mOutsets的区域实际上就是指当前屏幕最外层的四个padding大小。如果左右都大于0，则调用offsetLeftAndRight和offsetTopAndBottom进行设置。

- 3.如果mApplyFloatingVerticalInsets或者mApplyFloatingHorizontalInsets为true，说明DecorView自己需要处理一次onApplyWindowInsets的回调。如果关闭FLAG_LAYOUT_IN_SCREEN标志位也就是非全屏模式，且宽或高是WRAP_CONTENT模式，则给横轴或者纵轴两端增加systemwindowInset的padding数值。
```java
    public WindowInsets onApplyWindowInsets(WindowInsets insets) {
        final WindowManager.LayoutParams attrs = mWindow.getAttributes();
        mFloatingInsets.setEmpty();
        if ((attrs.flags & FLAG_LAYOUT_IN_SCREEN) == 0) {

            if (attrs.height == WindowManager.LayoutParams.WRAP_CONTENT) {
                mFloatingInsets.top = insets.getSystemWindowInsetTop();
                mFloatingInsets.bottom = insets.getSystemWindowInsetBottom();
                insets = insets.inset(0, insets.getSystemWindowInsetTop(),
                        0, insets.getSystemWindowInsetBottom());
            }
            if (mWindow.getAttributes().width == WindowManager.LayoutParams.WRAP_CONTENT) {
                mFloatingInsets.left = insets.getSystemWindowInsetTop();
                mFloatingInsets.right = insets.getSystemWindowInsetBottom();
                insets = insets.inset(insets.getSystemWindowInsetLeft(), 0,
                        insets.getSystemWindowInsetRight(), 0);
            }
        }
        mFrameOffsets.set(insets.getSystemWindowInsets());
        insets = updateColorViews(insets, true /* animate */);
        insets = updateStatusGuard(insets);
        if (getForeground() != null) {
            drawableChanged();
        }
        return insets;
    }
```

- 4.当所有都Layout好之后，则调用updateElevation更新窗体的阴影面积。
```java
    // The height of a window which has focus in DIP.
    private final static int DECOR_SHADOW_FOCUSED_HEIGHT_IN_DIP = 20;
    // The height of a window which has not in DIP.
    private final static int DECOR_SHADOW_UNFOCUSED_HEIGHT_IN_DIP = 5;

     private void updateElevation() {
        float elevation = 0;
        final boolean wasAdjustedForStack = mElevationAdjustedForStack;
        final int windowingMode =
                getResources().getConfiguration().windowConfiguration.getWindowingMode();
        if ((windowingMode == WINDOWING_MODE_FREEFORM) && !isResizing()) {
            elevation = hasWindowFocus() ?
                    DECOR_SHADOW_FOCUSED_HEIGHT_IN_DIP : DECOR_SHADOW_UNFOCUSED_HEIGHT_IN_DIP;

            if (!mAllowUpdateElevation) {
                elevation = DECOR_SHADOW_FOCUSED_HEIGHT_IN_DIP;
            }
            elevation = dipToPx(elevation);
            mElevationAdjustedForStack = true;
        } else if (windowingMode == WINDOWING_MODE_PINNED) {
            elevation = dipToPx(PINNED_WINDOWING_MODE_ELEVATION_IN_DIP);
            mElevationAdjustedForStack = true;
        } else {
            mElevationAdjustedForStack = false;
        }

        if ((wasAdjustedForStack || mElevationAdjustedForStack)
                && getElevation() != elevation) {
            mWindow.setElevation(elevation);
        }
    }
```
能看到这个过程中，如果窗体模式是freedom模式（也就是更像电脑中可以拖动的窗体一样）且不是正在拖拽变化大小，则会根据是否窗体聚焦了来决定阴影的的四个方向的大小。注意如果是没有焦点则为5，有焦点则为20.这里面的距离并非是measure的时候增加当前测量的大小，而是在测量好的大小中继续占用内容空间，也就是相当于设置了padding数值。

如果窗体是WINDOWING_MODE_PINNED模式或者WINDOWING_MODE_FREEFORM模式，且elevation发生了变化则通过PhoneWindow.setElevation设置Surface的Insets数值。

- 5.最后调用requestInvalidateRootRenderNode，通知ViweRootImpl中的硬件渲染对象ThreadRenderer进行刷新绘制。

整个过程中，有一系列函数用于更新摆放的偏移量，就以offsetLeftAndRight比较重要，看看是如何计算的。

#### offsetLeftAndRight
```java
    public void offsetLeftAndRight(int offset) {
        if (offset != 0) {
            final boolean matrixIsIdentity = hasIdentityMatrix();
            if (matrixIsIdentity) {
                if (isHardwareAccelerated()) {
                    invalidateViewProperty(false, false);
                } else {
                    final ViewParent p = mParent;
                    if (p != null && mAttachInfo != null) {
                        final Rect r = mAttachInfo.mTmpInvalRect;
                        int minLeft;
                        int maxRight;
                        if (offset < 0) {
                            minLeft = mLeft + offset;
                            maxRight = mRight;
                        } else {
                            minLeft = mLeft;
                            maxRight = mRight + offset;
                        }
                        r.set(0, 0, maxRight - minLeft, mBottom - mTop);
                        p.invalidateChild(this, r);
                    }
                }
            } else {
                invalidateViewProperty(false, false);
            }

            mLeft += offset;
            mRight += offset;
            mRenderNode.offsetLeftAndRight(offset);
            if (isHardwareAccelerated()) {
                invalidateViewProperty(false, false);
                invalidateParentIfNeededAndWasQuickRejected();
            } else {
                if (!matrixIsIdentity) {
                    invalidateViewProperty(false, true);
                }
                invalidateParentIfNeeded();
            }
            notifySubtreeAccessibilityStateChangedIfNeeded();
        }
    }
```
这个过程会判断offset如果不等于0才会进行计算。如果从RenderNode判断到存在单位变化矩阵(关于这个矩阵我们暂时不去聊，涉及到了硬件渲染的机制)。
- 1.判断到如果有硬件加速，则直接调用invalidateViewProperty方法刷新。
- 2.没有硬件加速，软件渲染的逻辑本质上也是一样的。

在这里能看到如果offset小于0，则把minLeft的大小增加。如果offset大于0，则增加maxRight的数值。计算出刷新的区域：
>offset>0 maxRight = maxRight + mRight
> offset<0 minLeft = minLeft + mLeft
> 刷新横向范围：maxRight - minLeft

计算出需要刷新的区域通过获取父布局的invalidateChild发送刷新命令。换算成图就是如下原理：
![Layout刷新区域.jpg](/images/Layout刷新区域.jpg)


- 3.如果没有单位变换矩阵，则调用invalidateViewProperty发送刷新命令

- 4.最后mLeft和mRight增加offset。并把left和right同步数据到mRenderNode中。

- 5.如果打开了硬件加速，又一次调用了invalidateViewProperty，并且调用invalidateParentIfNeededAndWasQuickRejected拒绝遍历刷新。

- 6.关闭硬件加速，如果没有单位变换矩阵，则调用invalidateViewProperty。接着调用invalidateParentIfNeeded。

能看到这个过程中有几个方法被频繁的调用：
- 1.invalidate
- 2.invalidateChild
- 3.invalidateViewProperty
- 4.invalidateParentIfNeededAndWasQuickRejected
- 5.invalidateParentIfNeeded

这几个方法决定了绘制需要更新的区域。这里我们先不管，我们放到后面来聊聊。我们来继续看看DecorView的父类FrameLayout中做了什么

### FrameLayout onLayout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[FrameLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/FrameLayout.java)

```java
 protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
        layoutChildren(left, top, right, bottom, false /* no force left gravity */);
    }

    void layoutChildren(int left, int top, int right, int bottom, boolean forceLeftGravity) {
        final int count = getChildCount();

        final int parentLeft = getPaddingLeftWithForeground();
        final int parentRight = right - left - getPaddingRightWithForeground();

        final int parentTop = getPaddingTopWithForeground();
        final int parentBottom = bottom - top - getPaddingBottomWithForeground();

        for (int i = 0; i < count; i++) {
            final View child = getChildAt(i);
            if (child.getVisibility() != GONE) {
                final LayoutParams lp = (LayoutParams) child.getLayoutParams();

                final int width = child.getMeasuredWidth();
                final int height = child.getMeasuredHeight();

                int childLeft;
                int childTop;

                int gravity = lp.gravity;
                if (gravity == -1) {
                    gravity = DEFAULT_CHILD_GRAVITY;
                }

                final int layoutDirection = getLayoutDirection();
                final int absoluteGravity = Gravity.getAbsoluteGravity(gravity, layoutDirection);
                final int verticalGravity = gravity & Gravity.VERTICAL_GRAVITY_MASK;

                switch (absoluteGravity & Gravity.HORIZONTAL_GRAVITY_MASK) {
                    case Gravity.CENTER_HORIZONTAL:
                        childLeft = parentLeft + (parentRight - parentLeft - width) / 2 +
                        lp.leftMargin - lp.rightMargin;
                        break;
                    case Gravity.RIGHT:
                        if (!forceLeftGravity) {
                            childLeft = parentRight - width - lp.rightMargin;
                            break;
                        }
                    case Gravity.LEFT:
                    default:
                        childLeft = parentLeft + lp.leftMargin;
                }

                switch (verticalGravity) {
                    case Gravity.TOP:
                        childTop = parentTop + lp.topMargin;
                        break;
                    case Gravity.CENTER_VERTICAL:
                        childTop = parentTop + (parentBottom - parentTop - height) / 2 +
                        lp.topMargin - lp.bottomMargin;
                        break;
                    case Gravity.BOTTOM:
                        childTop = parentBottom - height - lp.bottomMargin;
                        break;
                    default:
                        childTop = parentTop + lp.topMargin;
                }

                child.layout(childLeft, childTop, childLeft + width, childTop + height);
            }
        }
    }
```
FrameLayout的onLayout方法很简单。实际上就是遍历每一个可见的子View处理其gravity。
可以分为横轴和竖轴两个方向进行处理：
**横轴的处理方向：**
- 1.是判断到gravity是CENTER_HORIZONTAL，说明要横向居中：
> 每一个孩子左侧 = 父View的左侧位置 - （父亲的宽度 - 孩子的宽度）/ 2 + 孩子的marginLeft - 孩子的marginRight

保证孩子位置的居中。

- 2.Gravity.RIGHT：
> 孩子的左侧= 父View的右侧 - 孩子宽度 - 孩子的marginRight

保证了孩子是从右边还是摆放位置。

- 3.Gravity.LEFT
> 孩子的左侧= 父View的左侧 + 孩子的marginLeft

 竖直方向上同理。

最后把每一个摆放好的孩子位置通过child.layout进行迭代执行子View的layout流程。

### LinearLayout onLayout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[LinearLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/LinearLayout.java)

 我们来看看LinearLayout中做了什么。
```java
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        if (mOrientation == VERTICAL) {
            layoutVertical(l, t, r, b);
        } else {
            layoutHorizontal(l, t, r, b);
        }
    }
```
我们只看竖直方向上的逻辑。

```java
    void layoutVertical(int left, int top, int right, int bottom) {
        final int paddingLeft = mPaddingLeft;

        int childTop;
        int childLeft;

        // Where right end of child should go
        final int width = right - left;
        int childRight = width - mPaddingRight;

        // Space available for child
        int childSpace = width - paddingLeft - mPaddingRight;

        final int count = getVirtualChildCount();

        final int majorGravity = mGravity & Gravity.VERTICAL_GRAVITY_MASK;
        final int minorGravity = mGravity & Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK;

        switch (majorGravity) {
           case Gravity.BOTTOM:
               childTop = mPaddingTop + bottom - top - mTotalLength;
               break;

           case Gravity.CENTER_VERTICAL:
               childTop = mPaddingTop + (bottom - top - mTotalLength) / 2;
               break;

           case Gravity.TOP:
           default:
               childTop = mPaddingTop;
               break;
        }

        for (int i = 0; i < count; i++) {
            final View child = getVirtualChildAt(i);
            if (child == null) {
               ...
            } else if (child.getVisibility() != GONE) {
                final int childWidth = child.getMeasuredWidth();
                final int childHeight = child.getMeasuredHeight();

                final LinearLayout.LayoutParams lp =
                        (LinearLayout.LayoutParams) child.getLayoutParams();

                int gravity = lp.gravity;
                if (gravity < 0) {
                    gravity = minorGravity;
                }
                final int layoutDirection = getLayoutDirection();
                final int absoluteGravity = Gravity.getAbsoluteGravity(gravity, layoutDirection);
                switch (absoluteGravity & Gravity.HORIZONTAL_GRAVITY_MASK) {
                    case Gravity.CENTER_HORIZONTAL:
                        childLeft = paddingLeft + ((childSpace - childWidth) / 2)
                                + lp.leftMargin - lp.rightMargin;
                        break;

                    case Gravity.RIGHT:
                        childLeft = childRight - childWidth - lp.rightMargin;
                        break;

                    case Gravity.LEFT:
                    default:
                        childLeft = paddingLeft + lp.leftMargin;
                        break;
                }

                if (hasDividerBeforeChildAt(i)) {
                    childTop += mDividerHeight;
                }

                childTop += lp.topMargin;
                setChildFrame(child, childLeft, childTop + getLocationOffset(child),
                        childWidth, childHeight);
                childTop += childHeight + lp.bottomMargin + getNextLocationOffset(child);

                i += getChildrenSkipCount(child, i);
            }
        }
    }

    private void setChildFrame(View child, int left, int top, int width, int height) {
        child.layout(left, top, left + width, top + height);
    }
```
能看到这里的逻辑和FrameLayout十分相似，也是处理gravity。在这个方法之前已经通过在父容器的layout方法测量好LinearLayout的四个位置的基础上进一步摆放LinearLayout中的子View。

在竖直摆放的逻辑中，分别处理两个方向的Gravity。
首先看在竖直方向摆放中进行竖直方向上的gravity的处理：
- 1.Gravity.BOTTOM
> 每一个孩子的顶部 = paddingTop + LinearLayout的bottom - LinearLayout的top - LinearLayout的总高度

通过从LinearLayout的底部开始向上摆放子View。

- 2.Gravity.CENTER_VERTICAL
> 每一个孩子的顶部 = mPaddingTop + (LinearLayout的bottom - LinearLayout的top - mTotalLength) / 2

通过计算LinearLayout居中的位置设置好LinearLayout的子View。

- 3.Gravity.TOP
> 每一个孩子的顶部 = mPaddingTop

能看到在竖直方向摆放，处理竖直方向的Gravity只会统一处理所有的子View。而不会进行累加处理。

竖直方向摆放中进行横向方向上的gravity的处理：
> 每一个孩子的宽度childSpace = LinearLayout的宽度 - paddingLeft - mPaddingRight
- 1.Gravity.CENTER_HORIZONTAL:
> 每一个孩子的左侧 = paddingLeft + ((childSpace - childWidth) / 2)
                                + lp.leftMargin - lp.rightMargin;

- 2.Gravity.RIGHT:
> 每一个孩子的左侧 = childRight - childWidth - lp.rightMargin

- 3.Gravity.LEFT:
>  每一个孩子的左侧 = paddingLeft + lp.leftMargin;

在处理横向的过程中，不断的累加每一个子View的topMargin，并且调用子View的layout方法进行子View的摆放流程，当测定好子View后则累加子View的高度，bottomMargin以及偏移量。



### RelativeLayout onLayout
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[RelativeLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/RelativeLayout.java)

```java
    protected void onLayout(boolean changed, int l, int t, int r, int b) {

        final int count = getChildCount();

        for (int i = 0; i < count; i++) {
            View child = getChildAt(i);
            if (child.getVisibility() != GONE) {
                RelativeLayout.LayoutParams st =
                        (RelativeLayout.LayoutParams) child.getLayoutParams();
                child.layout(st.mLeft, st.mTop, st.mRight, st.mBottom);
            }
        }
    }
```

至于RelativeLayout这里面，由于在onMeasure的7次遍历中已经处理好了对应的摆放逻辑了。因此这里指简单的遍历一次每一个子View的layout方法即可。


### invalidate方法的家族
能看到在onLayout的过程中使用了很多次带有invalidate含义的方法。
- 1.invalidate
- 2.invalidateChild
- 3.invalidateViewProperty
- 4.invalidateParentIfNeededAndWasQuickRejected
- 5.invalidateParentIfNeeded

实际上这是一个告诉Android渲染系统，某一段区域是设置为无效区也就是发生了变化的脏区，需要进行重新绘制的意思。我们先来看看invalidate方法。


#### View invalidate
```java
    public void invalidate() {
        invalidate(true);
    }

    public void invalidate(boolean invalidateCache) {
        invalidateInternal(0, 0, mRight - mLeft, mBottom - mTop, invalidateCache, true);
    }

    private boolean skipInvalidate() {
        return (mViewFlags & VISIBILITY_MASK) != VISIBLE && mCurrentAnimation == null &&
                (!(mParent instanceof ViewGroup) ||
                        !((ViewGroup) mParent).isViewTransitioning(this));
    }

    void invalidateInternal(int l, int t, int r, int b, boolean invalidateCache,
            boolean fullInvalidate) {
        if (mGhostView != null) {
            mGhostView.invalidate(true);
            return;
        }

        if (skipInvalidate()) {
            return;
        }

        if ((mPrivateFlags & (PFLAG_DRAWN | PFLAG_HAS_BOUNDS)) == (PFLAG_DRAWN | PFLAG_HAS_BOUNDS)
                || (invalidateCache && (mPrivateFlags & PFLAG_DRAWING_CACHE_VALID) == PFLAG_DRAWING_CACHE_VALID)
                || (mPrivateFlags & PFLAG_INVALIDATED) != PFLAG_INVALIDATED
                || (fullInvalidate && isOpaque() != mLastIsOpaque)) {
            if (fullInvalidate) {
                mLastIsOpaque = isOpaque();
                mPrivateFlags &= ~PFLAG_DRAWN;
            }

            mPrivateFlags |= PFLAG_DIRTY;

            if (invalidateCache) {
                mPrivateFlags |= PFLAG_INVALIDATED;
                mPrivateFlags &= ~PFLAG_DRAWING_CACHE_VALID;
            }

            final AttachInfo ai = mAttachInfo;
            final ViewParent p = mParent;
            if (p != null && ai != null && l < r && t < b) {
                final Rect damage = ai.mTmpInvalRect;
                damage.set(l, t, r, b);
                p.invalidateChild(this, damage);
            }

            if (mBackground != null && mBackground.isProjected()) {
                final View receiver = getProjectionReceiver();
                if (receiver != null) {
                    receiver.damageInParent();
                }
            }
        }
    }

    private boolean isProjectionReceiver() {
        return mBackground != null;
    }

    private View getProjectionReceiver() {
        ViewParent p = getParent();
        while (p != null && p instanceof View) {
            final View v = (View) p;
            if (v.isProjectionReceiver()) {
                return v;
            }
            p = p.getParent();
        }

        return null;
    }
```
- 1.判断到mGhostView不为空，则调用mGhostView的invalidate。
- 2.如果当前的View不可见，且无动画，且父容器不是ViewGroup(可能是ViewRootImpl)则跳过该方法的执行。
- 3.如果打开了PFLAG_DRAWN 和 PFLAG_HAS_BOUNDS；或者PFLAG_DRAWING_CACHE_VALID；或者PFLAG_INVALIDATED；或者fullInvalidate为true(此时为true)且透明发生了变化，则执行下面的逻辑：

- 4.关闭PFLAG_DRAWN标志位，给当前的View打上PFLAG_DIRTY标志位需要重新绘制，如果invalidateCache为true，说明要基于缓存绘制，打开PFLAG_INVALIDATED，关闭PFLAG_DRAWING_CACHE_VALID。

- 5.给当前的rect设置为当前View的四个边缘的位置，说明这个位置下所有的View必须重新绘制，通过invalidateChild传递给子View进行进一步的处理。

- 6.如果mBackground背景drawable设置了，则不断的向顶部容器遍历找到另一个包含背景drawable的父容器，调用父容器的damageInParent方法进行两者的刷新。
```java
    protected void damageInParent() {
        if (mParent != null && mAttachInfo != null) {
            mParent.onDescendantInvalidated(this, this);
        }
    }
```

#### ViewGroup invalidateChild 刷新子布局内容
传递下来的参数child是当前的View，dirty区域是上面计算出来的Layout发生变化脏区。
```java
    public final void invalidateChild(View child, final Rect dirty) {
        final AttachInfo attachInfo = mAttachInfo;
        if (attachInfo != null && attachInfo.mHardwareAccelerated) {
            onDescendantInvalidated(child, child);
            return;
        }

        ViewParent parent = this;
        if (attachInfo != null) {

            final boolean drawAnimation = (child.mPrivateFlags & PFLAG_DRAW_ANIMATION) != 0;

            Matrix childMatrix = child.getMatrix();
            final boolean isOpaque = child.isOpaque() && !drawAnimation &&
                    child.getAnimation() == null && childMatrix.isIdentity();
            int opaqueFlag = isOpaque ? PFLAG_DIRTY_OPAQUE : PFLAG_DIRTY;

            if (child.mLayerType != LAYER_TYPE_NONE) {
                mPrivateFlags |= PFLAG_INVALIDATED;
                mPrivateFlags &= ~PFLAG_DRAWING_CACHE_VALID;
            }

            final int[] location = attachInfo.mInvalidateChildLocation;
            location[CHILD_LEFT_INDEX] = child.mLeft;
            location[CHILD_TOP_INDEX] = child.mTop;
            if (!childMatrix.isIdentity() ||
                    (mGroupFlags & ViewGroup.FLAG_SUPPORT_STATIC_TRANSFORMATIONS) != 0) {
                RectF boundingRect = attachInfo.mTmpTransformRect;
                boundingRect.set(dirty);
                Matrix transformMatrix;
                if ((mGroupFlags & ViewGroup.FLAG_SUPPORT_STATIC_TRANSFORMATIONS) != 0) {
                    Transformation t = attachInfo.mTmpTransformation;
                    boolean transformed = getChildStaticTransformation(child, t);
                    if (transformed) {
                        transformMatrix = attachInfo.mTmpMatrix;
                        transformMatrix.set(t.getMatrix());
                        if (!childMatrix.isIdentity()) {
                            transformMatrix.preConcat(childMatrix);
                        }
                    } else {
                        transformMatrix = childMatrix;
                    }
                } else {
                    transformMatrix = childMatrix;
                }
                transformMatrix.mapRect(boundingRect);
                dirty.set((int) Math.floor(boundingRect.left),
                        (int) Math.floor(boundingRect.top),
                        (int) Math.ceil(boundingRect.right),
                        (int) Math.ceil(boundingRect.bottom));
            }

            do {
                View view = null;
                if (parent instanceof View) {
                    view = (View) parent;
                }

                if (drawAnimation) {
                    if (view != null) {
                        view.mPrivateFlags |= PFLAG_DRAW_ANIMATION;
                    } else if (parent instanceof ViewRootImpl) {
                        ((ViewRootImpl) parent).mIsAnimating = true;
                    }
                }

                if (view != null) {
                    if ((view.mViewFlags & FADING_EDGE_MASK) != 0 &&
                            view.getSolidColor() == 0) {
                        opaqueFlag = PFLAG_DIRTY;
                    }
                    if ((view.mPrivateFlags & PFLAG_DIRTY_MASK) != PFLAG_DIRTY) {
                        view.mPrivateFlags = (view.mPrivateFlags & ~PFLAG_DIRTY_MASK) | opaqueFlag;
                    }
                }

                parent = parent.invalidateChildInParent(location, dirty);
                if (view != null) {
                    // Account for transform on current parent
                    Matrix m = view.getMatrix();
                    if (!m.isIdentity()) {
                        RectF boundingRect = attachInfo.mTmpTransformRect;
                        boundingRect.set(dirty);
                        m.mapRect(boundingRect);
                        dirty.set((int) Math.floor(boundingRect.left),
                                (int) Math.floor(boundingRect.top),
                                (int) Math.ceil(boundingRect.right),
                                (int) Math.ceil(boundingRect.bottom));
                    }
                }
            } while (parent != null);
        }
    }
```
- 1.会判断当前的是否打开了硬件加速，如果打开了则把事件委托给onDescendantInvalidated完成。

- 2.如果没有打开则是软件渲染。如果发现是当前的布局的子View不存在单位变换矩阵或者打开了FLAG_SUPPORT_STATIC_TRANSFORMATIONS。则把之前计算出来的脏区设置到boundingRect，并且遍历孙子View中的变换矩阵一起通过矩阵计算合并起来。最后通过这个变换矩阵对boundingRect区域进行一个变换，或变大或缩小。最后把经过变换的boundingRect脏区设置会dirty。

- 3.判断当前的ViewParent是否是View(一般是View，也有可能是ViewRootImpl)。判断当前的View是否正在执行动画，如果执行动画那就要不断的向父布局遍历打开PFLAG_DRAW_ANIMATION标志位。如果遍历到顶层的ViewRootImpl则mIsAnimating为true。

- 4.如果当前的View对应的父容器的节点是不透明的或者透明部分发生了变化，则向顶层父容器遍历打上PFLAG_DIRTY标志位。

- 5.调用invalidateChildInParent根据当前的脏区在父容器进行处理和变化。

在这里出现了invalidateChildInParent方法。我们来看看这个方法做了什么。


####  ViewGroup invalidateChildInParent
```java
    public ViewParent invalidateChildInParent(final int[] location, final Rect dirty) {
        if ((mPrivateFlags & (PFLAG_DRAWN | PFLAG_DRAWING_CACHE_VALID)) != 0) {
            // either DRAWN, or DRAWING_CACHE_VALID
            if ((mGroupFlags & (FLAG_OPTIMIZE_INVALIDATE | FLAG_ANIMATION_DONE))
                    != FLAG_OPTIMIZE_INVALIDATE) {
                dirty.offset(location[CHILD_LEFT_INDEX] - mScrollX,
                        location[CHILD_TOP_INDEX] - mScrollY);
                if ((mGroupFlags & FLAG_CLIP_CHILDREN) == 0) {
                    dirty.union(0, 0, mRight - mLeft, mBottom - mTop);
                }

                final int left = mLeft;
                final int top = mTop;

                if ((mGroupFlags & FLAG_CLIP_CHILDREN) == FLAG_CLIP_CHILDREN) {
                    if (!dirty.intersect(0, 0, mRight - left, mBottom - top)) {
                        dirty.setEmpty();
                    }
                }

                location[CHILD_LEFT_INDEX] = left;
                location[CHILD_TOP_INDEX] = top;
            } else {

....
            return mParent;
        }

        return null;
    }
```
首先判断，是否打开了PFLAG_DRAWN标志位且PFLAG_DRAWING_CACHE_VALID。PFLAG_DRAWING_CACHE_VALID标志位是等到在绘制流程draw中updateDisplayListIfDirty更新脏区调用的，说明此时是基于上次一次绘制结果进行绘制。PFLAG_DRAWN标志位是draw方法的时候打开的。


Android在绘制的时候，会默认走基于上一次绘制的结果，进行绘制区域的设置。

*绘制缓存原理如下：*
其中FLAG_OPTIMIZE_INVALIDATE的标志位打开时机是在dispatchDraw分发绘制行为给子View流程中，发现设置了LayoutAnimation(也就是摆放动画)，并且延时比例mDelay小于1。

这个过程必定出现绘制重叠的区域，因此需要进行一次优化。但是需要注意，校验FLAG_OPTIMIZE_INVALIDATE标志位的同时需要校验FLAG_ANIMATION_DONE标志位。这个标志位是动画执行完毕之后，调用notifyAnimationListener打开了，当然ViewGroup默认初始化也会打开。这样的校验就能比较精准的计算出需要更新的绘制区域。

分为下面三步：
- 1.加入滑动x轴和y轴的偏移量：
> 脏区x轴偏移量：location[CHILD_LEFT_INDEX] - mScrollX
> 脏区y轴的偏移量：location[CHILD_TOP_INDEX] - mScrollY

- 2.如果打开了FLAG_CLIP_CHILDREN，也就是设置clipChild标志位，用来确定子元素是否可以超出父元素的边界。一般都是true，不允许子元素超过父元素。如果打开了，只需要更新父元素和子元素之间的交集。如果失败说明无交集，脏区设置为空。

- 3.更新location数组的最左和最顶部的数值。

记住在invalidateChild执行过程中调用invalidateChildInParent是不断的向顶部进行遍历的，因此会遍历到DecorView以及ViewRootImpl。


#### ViewRootImpl invalidateChild
```java
    public ViewParent invalidateChildInParent(int[] location, Rect dirty) {
        checkThread();

        if (dirty == null) {
            invalidate();
            return null;
        } else if (dirty.isEmpty() && !mIsAnimating) {
            return null;
        }
...

        invalidateRectOnScreen(dirty);

        return null;
    }
```
实际上核心调用的是invalidateRectOnScreen。

##### invalidateRectOnScreen
```java
    private void invalidateRectOnScreen(Rect dirty) {
        final Rect localDirty = mDirty;
        if (!localDirty.isEmpty() && !localDirty.contains(dirty)) {
            mAttachInfo.mSetIgnoreDirtyState = true;
            mAttachInfo.mIgnoreDirtyState = true;
        }

        localDirty.union(dirty.left, dirty.top, dirty.right, dirty.bottom);

        final float appScale = mAttachInfo.mApplicationScale;
        final boolean intersected = localDirty.intersect(0, 0,
                (int) (mWidth * appScale + 0.5f), (int) (mHeight * appScale + 0.5f));
        if (!intersected) {
            localDirty.setEmpty();
        }
        if (!mWillDrawSoon && (intersected || mIsAnimating)) {
            scheduleTraversals();
        }
    }
```
能看到这里记录当前传递过来的脏区记录到了全局变量mDirty中，直接调用scheduleTraversals，进行View的绘制流程。那么和requestLayout有什么区别？我们来看看：
```java
    public void requestLayout() {
        if (!mHandlingLayoutInLayoutRequest) {
            checkThread();
            mLayoutRequested = true;
            scheduleTraversals();
        }
    }
```
能看到requestLayout会打上mLayoutRequested标志位之后才执行scheduleTraversals方法。

我们抽取performTraversals中核心方法看一下：
```java
        final boolean windowRelayoutWasForced = mForceNextWindowRelayout;
        if (mFirst || windowShouldResize || insetsChanged ||
                viewVisibilityChanged || params != null || mForceNextWindowRelayout) {
            mForceNextWindowRelayout = false;
...
        } else {
            maybeHandleWindowMove(frame);
        }

        final boolean didLayout = layoutRequested && (!mStopped || mReportNextDraw);
        boolean triggerGlobalLayoutListener = didLayout
                || mAttachInfo.mRecomputeGlobalAttributes;
        if (didLayout){
....
```
能看到实际上onMeasure是第一个if中进行处理的，onLayout是在didLayou为true处理的。这几个流程中，如果不是第一次渲染，且窗体，insets，可见度等因素没有变化是不会走measure的流程，而layout依赖与requestLayout设置的标志位。

invalidate的方法在正常情况下都不会直接触发这两个流程，只会直接进行这个区域的重新绘制流程。这也是为什么invalidate更新新添加的View在Android屏幕无法渲染的原因了。

这种方式比较适合如LottieView这种在一个区域内不断执行的动画的情景。


#### View invalidateViewProperty
```java
    void invalidateViewProperty(boolean invalidateParent, boolean forceRedraw) {
        if (!isHardwareAccelerated()
                || !mRenderNode.isValid()
                || (mPrivateFlags & PFLAG_DRAW_ANIMATION) != 0) {
            if (invalidateParent) {
                invalidateParentCaches();
            }
            if (forceRedraw) {
                mPrivateFlags |= PFLAG_DRAWN; // force another invalidation with the new orientation
            }
            invalidate(false);
        } else {
            damageInParent();
        }
    }
```
这个方法本质上比起invalidate更加关注View刷新的性能。注意这个方法从offsetLeftAndRight方法中调用的。invalidateViewProperty两个参数都是false，只有非硬件加速且不是单位矩阵的变换矩阵，第二个才是true。

没有硬件加速，或者mRenderNode是无效的，就会走invalidate流程。否则则走damageInParent，把事件委托给父容器的onDescendantInvalidated方法中。

先来看看软件渲染的逻辑：
- 1.如果参数invalidateParent是true，则调用invalidateParentCaches方法渲染父容器的缓存
- 2.forceRedraw 参数是true，则PFLAG_DRAWN标志位。这个标志位判断了draw的行为是否已经完成了，然后调用invalidate方法。不过参数是false，也就是不基于上一次渲染的结果进行运算，找出前后两次绘制的交集区域。

如果是硬件渲染，则交给onDescendantInvalidated方法处理。这个方法出现了多次了，在invalidateChild中也出现了。

那么我们来看看invalidateParentCaches和onDescendantInvalidated都做了什么？


#### View invalidateParentCaches
```java
    protected void invalidateParentCaches() {
        if (mParent instanceof View) {
            ((View) mParent).mPrivateFlags |= PFLAG_INVALIDATED;
        }
    }
```
实际上这个方法就是给父容器打上PFLAG_INVALIDATED标志位。

#### ViewGroup onDescendantInvalidated
```java
    public void onDescendantInvalidated(@NonNull View child, @NonNull View target) {
        mPrivateFlags |= (target.mPrivateFlags & PFLAG_DRAW_ANIMATION);

        if ((target.mPrivateFlags & ~PFLAG_DIRTY_MASK) != 0) {

            mPrivateFlags = (mPrivateFlags & ~PFLAG_DIRTY_MASK) | PFLAG_DIRTY;

            mPrivateFlags &= ~PFLAG_DRAWING_CACHE_VALID;
        }

        if (mLayerType == LAYER_TYPE_SOFTWARE) {
            mPrivateFlags |= PFLAG_INVALIDATED | PFLAG_DIRTY;
            target = this;
        }

        if (mParent != null) {
            mParent.onDescendantInvalidated(this, target);
        }
    }
```
能看到实际上在是一个不断向顶层View递归的过程，如果PFLAG_DIRTY_MASK打开了，先关闭PFLAG_DIRTY_MASK，再给顶层的View打上PFLAG_DIRTY。最后关闭PFLAG_DRAWING_CACHE_VALID。

这是什么意思呢？
```java
    static final int PFLAG_DIRTY_MASK                  = 0x00600000;
    static final int PFLAG_DIRTY                       = 0x00200000;
    static final int PFLAG_DIRTY_OPAQUE                = 0x00400000;
```
能看到PFLAG_DIRTY_MASK控制的两位高一位是透明，低一位是是否无效。

所以这里的意思是关闭dirty和opaque两个标志位之后再打开dirty标志位。说明该View区域发生了变化，但是不是透明的，可以回调onDraw方法。

如果mLayerType是LAYER_TYPE_SOFTWARE模式，还需要多打开一个PFLAG_INVALIDATED标志位。

其实这里面的逻辑和invalidateParentCaches有点相似。

##### ViewRootImpl onDescendantInvalidated
```java
    public void onDescendantInvalidated(@NonNull View child, @NonNull View descendant) {
        if ((descendant.mPrivateFlags & PFLAG_DRAW_ANIMATION) != 0) {
            mIsAnimating = true;
        }
        invalidate();
    }

    void invalidate() {
        mDirty.set(0, 0, mWidth, mHeight);
        if (!mWillDrawSoon) {
            scheduleTraversals();
        }
    }

```
能看到这里实际上做的事情很简单，就是把脏区设置为全局，进行全屏幕的刷新。虽然是全局的刷新脏区，实际上已经从底层的View到上层的View都标记了脏区。

这么做有什么好处呢？这样就能知道onDraw的绘制需要从顶层开始一直到底层的哪个层级的子View。当然这种模式是专门提供给硬件加速，因为在硬件加速中是一个个RenderNode才是绘制的核心，每一个RenderNode是来自父容器的RenderNode中的DisplayLIst这个View tree中。因此需要从父容器开始向下遍历找到真正需要重新渲染的对象。


PFLAG_INVALIDATED 又是做什么的呢？下一篇就会和大家揭露，实际上就是告诉硬件渲染对象，从哪个层级开始重新构造View tree。


#### View invalidateParentIfNeededAndWasQuickRejected
```java
    protected void invalidateParentIfNeededAndWasQuickRejected() {
        if ((mPrivateFlags2 & PFLAG2_VIEW_QUICK_REJECTED) != 0) {
            invalidateParentIfNeeded();
        }
    }
```
实际上就是判断PFLAG2_VIEW_QUICK_REJECTED是否开启，开启了则走invalidateParentIfNeeded方法。而这个标志位的开启实际上，几乎是由Canvas的quickReject方法进行判断，是否拒绝当前的绘制。如果是则打上PFLAG2_VIEW_QUICK_REJECTED标志，不回调onDraw直接返回。

而这个方法的调用时机就是offsetLeftAndTop方法中，完成了offset偏移量的变化后最后调用的。

再来看看invalidateParentIfNeeded。

#### View invalidateParentIfNeeded
```java
    protected void invalidateParentIfNeeded() {
        if (isHardwareAccelerated() && mParent instanceof View) {
            ((View) mParent).invalidate(true);
        }
    }
```
很简单，实际上就是判断到是硬件加速之后，调用invalidate方法进行View的draw刷新。


## 总结
到这里就完成了onLayout的解析了。 

惯例总结，onLayout实质上就是在onMeasure的测量结果的基础上对每一个子View进行摆放。

### onMeasure的执行条件
我们从头开始回顾以下，onMeasure是否进行测量是由如下几个因素组成的。
- 1.第一次渲染
- 2.窗口发生了变更
- 3.如果Inset的区域发生了变化
- 4.如果窗体的顶层ViewDecorView可见情况发生了变化
- 5.如果mWindowAttributes不为空
- 6.每一次更新了整个ViewRootImpl的Configuration，如横竖屏切换，资源主题的切换等。

只要6个前置因素完成之后，才会进行下一步的判断。
- 1.原来DecorView的宽高和WindowFrame的宽高发生了变化
- 2.触点模式发生了变化
- 3. contentInsetsChanged 也就是内容区域的inset发生了变化
- 4.更新了Configuration

只有这样才会执行onMeasure。

###  onLayout的执行条件
有如下3个条件决定：
- 1.requestLayout 调用的。
- 2.onMeasure 经过测量后，说明有View的大小发生变化因此需要重新进行onLayout的摆放。

前两点满足其中一点后，同时满足View没有Stop或者调用需要强制调用Draw方法，必定会执行performLayout。

- 3.performLayout中如果ViewGroup判断到关闭摆放抑制,且没有Layout动画或者Layout的动画没有变化才会传递给子View进行执行摆放流程。

达到这些情况后才会调用onLayout方法。

### onLayout的优化
为了优化整个onMeasure和onLayout遍历的逻辑。onMeasure做了缓存处理，如果判断到父容器的大小不变，则不会遍历到底层的子View中进行测量。

然而在这个过程中如果子View发生了变化呢？所以在onLayout的过程中会提前进行一次onMeasure保证在摆放onLayout之前，每一个子View测量的大小都是正常的。


通过这种类似与状态转移表的方式记录哪一个层级可以断开遍历，极大的降低了整个View的onMeasure和onLayout的遍历层级。

### onLayout执行流程

ViewRootImpl将performLayout作为View的摆放流程onLayout的全局入口。这个过程中：
- 1.首先会通过DecorView的layout方法进行全局的View树，进行所有的View的摆放处理。
- 2.检测是否有在onMeasure和onLayout的过程中进行了需要重新绘制，摆放的请求。如果有就把这些请求对象重新进行measure和layout进行处理。

整个核心流程在View的layout方法中。layout每一次在执行onLayout进行每一个子View真正的摆放动作之前：
- 1.会调用setFrame或者setOpticalFrame方法确定当前的容器在摆放位置是否因为父容器发生了变化，一旦发生了变化则需要调用子View的onLayout遍历。

- 2.或者判断是否是从调用requestLayout进来，如果是则会强制进行一次子View的onLayout遍历。

在这个过程中，setFrame方法还做了另一件十分重要的事情，记录了该View左边，右边，顶部，底部的坐标。同时刷新到View的renderNode中，并且回到用sizeChange方法。如果发现该View可是则调用invalidate发送局部刷新绘制命令，以及调用invalidateParentCaches更新View的父布局的脏区的标志位。

### DecorView onLayout
DecorView作为根布局当处理完父类的onLayout放啊后，会调用offsetLeftAndRight等方法进行窗体层级上的摆放偏移处理。其根据就是在每一个窗体设置的Inset四个方位的大小。


### FrameLayout onLayout
FrameLayout在onLayout中只进行了一次所有子View的遍历循环，处理gravity。以及子View的layout方法

### LinearLayout onLayout
LinearLayout在onLayout中只进行了一次所有子View的遍历循环，处理gravity。以及子View的layout方法


### RelativeLayout onLayout
只进行一次遍历，遍历每一个子View的layout方法。


### invalidate的作用
在View的绘制流程中不需要时时刻刻都进行整个View树的遍历onDraw方法进行绘制。实际上onDraw这个过程中才是最为消耗的性能，因此Android就通过invalidate这个命令进行优化,以做到局部刷新的能力。

invalidate工作流程如下图：
![invalidate流程.jpg](/images/invalidate流程.jpg)

当上dirty标志位有什么好处呢？好处就是知道需要遍历到哪一个层级就终止onDraw的调用，缩减Android绘制时间。

在这个过程中会根据clipChild的标志位设置父容器和子View之间的刷新区域关系。如下：
![invalidate刷新区域.jpg](/images/invalidate刷新区域.jpg)

当执行完整个整个View tree的onLayout方法之后，将会到DecorView判断是否执行offsetTopAndLeft方法。实际上这个方法也很常用，当我们需要改变一个View的为止的时候，可以调用这个方法快速改变该View中摆放位置，其原理很除了修改了该View四个边缘的偏移量，还通过invalidateChild进行局部刷新偏移整个偏移的区域，这样就能极大的避免了大量的遍历循环处理，原理图如下：
![Layout刷新区域.jpg](/images/Layout刷新区域.jpg)


## 后话
接下来就来看看onDraw中做了什么工作了。

原本打算一周一更的，但是因为有林林种种不可抗力的因素，导致这短时间闲暇的时候无法在电脑边。估计这段时间更新的速度都会下降。

这段时间经历了一些事情，我直到今时今日才体验到以前学的那个古诗中令人动容的精神是多么难能可贵。
> 咬定青山不放松，立根原在破岩中。
> 千磨万击还坚劲，任尔东西南北风。

希望我能保住初心，不管遇到什么困难都能像古诗中说的竹子一样，咬定青山不放松，还能千磨万击还坚劲。





