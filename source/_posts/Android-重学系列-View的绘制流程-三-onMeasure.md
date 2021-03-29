---
title: Android 重学系列 View的绘制流程(三) onMeasure
top: false
cover: false
date: 2020-05-25 00:13:59
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
经过上一篇文章的解析，我们熟知了Android在绘制流程之前需要完成的事情。本文将继续和大家聊聊onMeasure以及onLayout的流程。并且举几个常用的View的onMeasure和onLayout进行讲解。


# 正文
我们跟着上一篇文章的步伐，接着看看performTraversals后续代码

## 焦点处理与performMeasure 
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)

```java
            if (!mStopped || mReportNextDraw) {
                boolean focusChangedDueToTouchMode = ensureTouchModeLocally(
                        (relayoutResult&WindowManagerGlobal.RELAYOUT_RES_IN_TOUCH_MODE) != 0);
                if (focusChangedDueToTouchMode || mWidth != host.getMeasuredWidth()
                        || mHeight != host.getMeasuredHeight() || contentInsetsChanged ||
                        updatedConfiguration) {
                    int childWidthMeasureSpec = getRootMeasureSpec(mWidth, lp.width);
                    int childHeightMeasureSpec = getRootMeasureSpec(mHeight, lp.height);


                    performMeasure(childWidthMeasureSpec, childHeightMeasureSpec);

                    int width = host.getMeasuredWidth();
                    int height = host.getMeasuredHeight();
                    boolean measureAgain = false;

                    if (lp.horizontalWeight > 0.0f) {
                        width += (int) ((mWidth - width) * lp.horizontalWeight);
                        childWidthMeasureSpec = MeasureSpec.makeMeasureSpec(width,
                                MeasureSpec.EXACTLY);
                        measureAgain = true;
                    }
                    if (lp.verticalWeight > 0.0f) {
                        height += (int) ((mHeight - height) * lp.verticalWeight);
                        childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(height,
                                MeasureSpec.EXACTLY);
                        measureAgain = true;
                    }

                    if (measureAgain) {
                        performMeasure(childWidthMeasureSpec, childHeightMeasureSpec);
                    }

                    layoutRequested = true;
                }
            }

```

在这个方法中做了两件比较重要的事情：
- 1.调用ensureTouchModeLocally处理touchMode以及焦点
- 2.遍历整个View树，计算每一个View需要的大小。

### 焦点处理
#### ensureTouchModeLocally 焦点与触摸模式的处理
在聊这些逻辑之前，我们要明白下面这段逻辑实际上是帮忙处理focusableInTouchMode的触屏模式。这里就需要区分一下focusableInTouchMode和focusable之间的区别。

- 1.focusable 这个标志位实际上是针对键盘在View的焦点处理。如果为true，View是editText，则可以通过键盘上下左右的按键切换多个View的焦点。
- 2.focusableInTouchMode 这个标志位实际上是针对触屏手机的。如果为true，如果设置了这个标志位，第一次点击不会立即执行点击事件，而是会先焦点处理，而后点击才触发点击事件。

注意InTouchMode这个模式实际上就是WMS中默认设置的。一般来说是全局的资源中的defaultInTouchMode设置的bool数值。一般来说触屏手机都带上这个标志。

```java
    private boolean ensureTouchModeLocally(boolean inTouchMode) {

        if (mAttachInfo.mInTouchMode == inTouchMode) return false;

        mAttachInfo.mInTouchMode = inTouchMode;
        mAttachInfo.mTreeObserver.dispatchOnTouchModeChanged(inTouchMode);

        return (inTouchMode) ? enterTouchMode() : leaveTouchMode();
    }
```

如果WindowManager.LayoutParams打开了RELAYOUT_RES_IN_TOUCH_MODE这个标志位，则说明是inTouchMode的模式。如果发现这个模式发生了改变，就通过AttachInfo中TreeObserver中的dispatchOnTouchModeChanged分发模式变化的状态。

而这个标志位的打开时机，是在WMS.relayoutWindow方法中发现打开了inTouchMode，则给标志位增加一个RELAYOUT_RES_IN_TOUCH_MODE。

如果打开了模式则通过enterTouchMode进入触摸模式。

### enterTouchMode
```java
    private boolean enterTouchMode() {
        if (mView != null && mView.hasFocus()) {

            final View focused = mView.findFocus();
            if (focused != null && !focused.isFocusableInTouchMode()) {
                final ViewGroup ancestorToTakeFocus = findAncestorToTakeFocusInTouchMode(focused);
                if (ancestorToTakeFocus != null) {
                    return ancestorToTakeFocus.requestFocus();
                } else {
                    focused.clearFocusInternal(null, true, false);
                    return true;
                }
            }
        }
        return false;
    }
```
- 1.判断当前的根布局DecorView存在焦点。则尝试的从DecorView中查找焦点的View。
- 2.如果如果通过findFocus找到对应的焦点View，如果对应的焦点且isFocusableInTouchMode为false没有打开inTouchMode。则findAncestorToTakeFocusInTouchMode处理焦点ViewParent对象
- 3.调用ViewParent的requestFocus方法。


#### ViewGroup findFocus
```java
    public View findFocus() {
        if (isFocused()) {
            return this;
        }

        if (mFocused != null) {
            return mFocused.findFocus();
        }
        return null;
    }
```

```java
    public View findFocus() {
        return (mPrivateFlags & PFLAG_FOCUSED) != 0 ? this : null;
    }

    public boolean isFocused() {
        return (mPrivateFlags & PFLAG_FOCUSED) != 0;
    }
```
 能看到实际上就是校验View是否打上了PFLAG_FOCUSED标志位。这个标志位怎么来的呢？我们稍后聊聊。

#### findAncestorToTakeFocusInTouchMode
在聊这个方法之前，我们需要明白另外一个Xml布局标签,android:descendantFocusability的三个参数：
参数|效果
-|-
beforeDescendants|viewgroup会优先其子类控件而获取到焦点
afterDescendants|viewgroup只有当其子类控件不需要获取焦点时才获取焦点
blocksDescendants|viewgroup会覆盖子类控件而直接获得焦点


```java
    private static ViewGroup findAncestorToTakeFocusInTouchMode(View focused) {
        ViewParent parent = focused.getParent();
        while (parent instanceof ViewGroup) {
            final ViewGroup vgParent = (ViewGroup) parent;
            if (vgParent.getDescendantFocusability() == ViewGroup.FOCUS_AFTER_DESCENDANTS
                    && vgParent.isFocusableInTouchMode()) {
                return vgParent;
            }
            if (vgParent.isRootNamespace()) {
                return null;
            } else {
                parent = vgParent.getParent();
            }
        }
        return null;
    }
```
在这里能看到先从当前的焦点View不断的向上找父布局。知道找到打开了FOCUS_AFTER_DESCENDANTS(子控件不需要焦点才让父布局获取)且打开了FocusableInTouchMode的父布局。

通过这种处理，我们才能找到对应焦点抢占的父布局和子布局，这样才能完成上述的标志位表示的意思。

#### ViewGroup requestFocus
```java
    public boolean requestFocus(int direction, Rect previouslyFocusedRect) {
        int descendantFocusability = getDescendantFocusability();

        boolean result;
        switch (descendantFocusability) {
            case FOCUS_BLOCK_DESCENDANTS:
                result = super.requestFocus(direction, previouslyFocusedRect);
                break;
            case FOCUS_BEFORE_DESCENDANTS: {
                final boolean took = super.requestFocus(direction, previouslyFocusedRect);
                result = took ? took : onRequestFocusInDescendants(direction,
                        previouslyFocusedRect);
                break;
            }
            case FOCUS_AFTER_DESCENDANTS: {
                final boolean took = onRequestFocusInDescendants(direction, previouslyFocusedRect);
                result = took ? took : super.requestFocus(direction, previouslyFocusedRect);
                break;
            }
            default:
                throw new IllegalStateException("descendant focusability must be "
                        + "one of FOCUS_BEFORE_DESCENDANTS, FOCUS_AFTER_DESCENDANTS, FOCUS_BLOCK_DESCENDANTS "
                        + "but is " + descendantFocusability);
        }
        if (result && !isLayoutValid() && ((mPrivateFlags & PFLAG_WANTS_FOCUS) == 0)) {
            mPrivateFlags |= PFLAG_WANTS_FOCUS;
        }
        return result;
    }
```
```java
    protected boolean onRequestFocusInDescendants(int direction,
            Rect previouslyFocusedRect) {
        int index;
        int increment;
        int end;
        int count = mChildrenCount;
        if ((direction & FOCUS_FORWARD) != 0) {
            index = 0;
            increment = 1;
            end = count;
        } else {
            index = count - 1;
            increment = -1;
            end = -1;
        }
        final View[] children = mChildren;
        for (int i = index; i != end; i += increment) {
            View child = children[i];
            if ((child.mViewFlags & VISIBILITY_MASK) == VISIBLE) {
                if (child.requestFocus(direction, previouslyFocusedRect)) {
                    return true;
                }
            }
        }
        return false;
    }

```
在ViewGroup的requestFocus中就是处理了android:descendantFocusability几个参数。
- 1.FOCUS_BLOCK_DESCENDANTS 其实就是只执行了当前ViewGroup的View.requestFocus
- 2.FOCUS_BEFORE_DESCENDANTS 则是先执行的ViewGroup的requestFocus方法。如果requestFocus返回false，接着通过onRequestFocusInDescendants执行子View的requestFocus。
- 3.FOCUS_AFTER_DESCENDANTS 先执行子View的onRequestFocusInDescendants方法。如果返回了false，才执行父布局的requestFocus方法。

#### View requestFocus
```java
    public final boolean requestFocus() {
        return requestFocus(View.FOCUS_DOWN);
    }

    public final boolean requestFocus(int direction) {
        return requestFocus(direction, null);
    }

    public boolean requestFocus(int direction, Rect previouslyFocusedRect) {
        return requestFocusNoSearch(direction, previouslyFocusedRect);
    }

    private boolean requestFocusNoSearch(int direction, Rect previouslyFocusedRect) {

        if (!canTakeFocus()) {
            return false;
        }

        if (isInTouchMode() &&
            (FOCUSABLE_IN_TOUCH_MODE != (mViewFlags & FOCUSABLE_IN_TOUCH_MODE))) {
               return false;
        }

        if (hasAncestorThatBlocksDescendantFocus()) {
            return false;
        }

        if (!isLayoutValid()) {
            mPrivateFlags |= PFLAG_WANTS_FOCUS;
        } else {
            clearParentsWantFocus();
        }

        handleFocusGainInternal(direction, previouslyFocusedRect);
        return true;
    }
```
- 1.canTakeFocus 判断当前的View是否可见，可用，可聚焦。不可以直接返回false。

- 2.判断当前全局的mInTouchMode的模式，如果是true，且打开了FOCUSABLE_IN_TOUCH_MODE这个标志位，也就是设置在Xml布局中的focusableInTouchMode对象，这样就返回false。把事件交给其他人处理。就因为如此，才会出现focusableInTouchMode的父布局的影响下，子布局的View点击事件第一次无法生效的问题。

- 3.通过hasAncestorThatBlocksDescendantFocus 不断的回溯父布局，判断当前是不是有一个父布局中有FOCUS_BLOCK_DESCENDANTS标志位，则直接屏蔽当前的View的焦点处理。

- 4.如果layout还没绘制则打开PFLAG_WANTS_FOCUS标志位。不然就清空父布局的PFLAG_WANTS_FOCUS标志位。

- 5.handleFocusGainInternal处理焦点。

##### handleFocusGainInternal
```java
    void handleFocusGainInternal(@FocusRealDirection int direction, Rect previouslyFocusedRect) {
        if ((mPrivateFlags & PFLAG_FOCUSED) == 0) {
            mPrivateFlags |= PFLAG_FOCUSED;

            View oldFocus = (mAttachInfo != null) ? getRootView().findFocus() : null;

            if (mParent != null) {
                mParent.requestChildFocus(this, this);
                updateFocusedInCluster(oldFocus, direction);
            }

            if (mAttachInfo != null) {
                mAttachInfo.mTreeObserver.dispatchOnGlobalFocusChange(oldFocus, this);
            }

            onFocusChanged(true, direction, previouslyFocusedRect);
            refreshDrawableState();
        }
    }
```
最核心的方法：
- 1.onFocusChanged 更新View中的焦点状态
- 2.refreshDrawableState 刷新View中drawable的focus的状态。

关键让我们看看第一个方法：onFocusChanged

###### onFocusChanged
```java
    protected void onFocusChanged(boolean gainFocus, @FocusDirection int direction,
            @Nullable Rect previouslyFocusedRect) {
        if (gainFocus) {
            sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED);
        } else {
            notifyViewAccessibilityStateChangedIfNeeded(
                    AccessibilityEvent.CONTENT_CHANGE_TYPE_UNDEFINED);
        }

        switchDefaultFocusHighlight();

        InputMethodManager imm = InputMethodManager.peekInstance();
        if (!gainFocus) {
            if (isPressed()) {
                setPressed(false);
            }
            if (imm != null && mAttachInfo != null && mAttachInfo.mHasWindowFocus) {
                imm.focusOut(this);
            }
            onFocusLost();
        } else if (imm != null && mAttachInfo != null && mAttachInfo.mHasWindowFocus) {
            imm.focusIn(this);
        }

        invalidate(true);
        ListenerInfo li = mListenerInfo;
        if (li != null && li.mOnFocusChangeListener != null) {
            li.mOnFocusChangeListener.onFocusChange(this, gainFocus);
        }

        if (mAttachInfo != null) {
            mAttachInfo.mKeyDispatchState.reset(this);
        }

        notifyEnterOrExitForAutoFillIfNeeded(gainFocus);
    }
```
- 1.首先发送焦点事件给AccessibilityService中。
- 2.switchDefaultFocusHighlight 通过焦点设置高亮的drawable。
- 3.通过InputMethodManager键盘的弹出收回的焦点状态
- 4.notifyEnterOrExitForAutoFillIfNeeded 通知AutoFillManager状态。

### performMeasure原理
接下来看看performMeasure的逻辑：
```java
                if (focusChangedDueToTouchMode || mWidth != host.getMeasuredWidth()
                        || mHeight != host.getMeasuredHeight() || contentInsetsChanged ||
                        updatedConfiguration) {
                    int childWidthMeasureSpec = getRootMeasureSpec(mWidth, lp.width);
                    int childHeightMeasureSpec = getRootMeasureSpec(mHeight, lp.height);


                    performMeasure(childWidthMeasureSpec, childHeightMeasureSpec);

                    int width = host.getMeasuredWidth();
                    int height = host.getMeasuredHeight();
                    boolean measureAgain = false;

                    if (lp.horizontalWeight > 0.0f) {
                        width += (int) ((mWidth - width) * lp.horizontalWeight);
                        childWidthMeasureSpec = MeasureSpec.makeMeasureSpec(width,
                                MeasureSpec.EXACTLY);
                        measureAgain = true;
                    }
                    if (lp.verticalWeight > 0.0f) {
                        height += (int) ((mHeight - height) * lp.verticalWeight);
                        childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(height,
                                MeasureSpec.EXACTLY);
                        measureAgain = true;
                    }

                    if (measureAgain) {
                        performMeasure(childWidthMeasureSpec, childHeightMeasureSpec);
                    }

                    layoutRequested = true;
                }
            }
```
如果发现DecorView的MeasureWidth和MeasureHeight发生了变化，或者焦点也发生了变化。如果是第一次进行ViewRootImpl的渲染，必定会走到这个逻辑中。

performMeasure就是测量所有View树中View的大小。能看到这里面，如果我们还设置了WindowManager.LayoutParams横竖任意一个方向的weight通过会在执行一次performMeasure。

这里面的weight权重是指mWindowFrame 屏幕的宽高和当前DecorView通过performMeasure计算了一次准确的大小之后，进行一次按照比例的精确的宽高分配。


再继续聊performMeasure逻辑。我们先来聊聊MeasureSpec。

#### MeasureSpec
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)

MeasureSpec实际上是指代View在绘制过程中对View测量后所记录的View的大小以及对应的模式。而这个对象是通过MeasureSpec.makeMeasureSpec生成的。

```java
        private static final int MODE_SHIFT = 30;
        private static final int MODE_MASK  = 0x3 << MODE_SHIFT;

        /** @hide */
        @IntDef({UNSPECIFIED, EXACTLY, AT_MOST})
        @Retention(RetentionPolicy.SOURCE)
        public @interface MeasureSpecMode {}

        public static final int UNSPECIFIED = 0 << MODE_SHIFT;

        public static final int EXACTLY     = 1 << MODE_SHIFT;

        public static final int AT_MOST     = 2 << MODE_SHIFT;


        public static int makeMeasureSpec(@IntRange(from = 0, to = (1 << MeasureSpec.MODE_SHIFT) - 1) int size,
                                          @MeasureSpecMode int mode) {
            if (sUseBrokenMakeMeasureSpec) {
                return size + mode;
            } else {
                return (size & ~MODE_MASK) | (mode & MODE_MASK);
            }
        }
```
关于sUseBrokenMakeMeasureSpec这个标志位只有在低版本才是true。我们关注if下面的分支。

MeasureSpec有三种模式：
测量模式|解释
-|-
MeasureSpec.EXACTLY|精确模式，能够精确的指定View的大小
MeasureSpec.AT_MOST|最大模式，这个模式是不允许超过某一个设定的数值，一般是指子View不能超过父容器的大小。
MeasureSpec. UNSPECIFIED|无限制，这个模式下View的大小不受其他限制，仅仅由自己决定。

有了这个基础，一个View的宽高进行设定的时候，除了有一个View 的宽高参数之外，就会带上这些模式。

根据makeMeasureSpec方法分析，就能明白。
一个View的通过makeMeasureSpec生成的MeasureWidth或者MeasureHeight的是一个32位大小的MeasureSpec数据。

> MeasureSpec的构成 = 模式(头2位)+ 大小(后30位)
> MeasureSpec. UNSPECIFIED: 00
> MeasureSpec. AT_MOST: 01
> MeasureSpec. EXACTLY: 10

通过这种方法就能知道一个View大小的同时知道该View和父布局之间工作协调关系。

##### getRootMeasureSpec
接着来看看getRootMeasureSpec方法。
```java
    private static int getRootMeasureSpec(int windowSize, int rootDimension) {
        int measureSpec;
        switch (rootDimension) {

        case ViewGroup.LayoutParams.MATCH_PARENT:
            measureSpec = MeasureSpec.makeMeasureSpec(windowSize, MeasureSpec.EXACTLY);
            break;
        case ViewGroup.LayoutParams.WRAP_CONTENT:
            measureSpec = MeasureSpec.makeMeasureSpec(windowSize, MeasureSpec.AT_MOST);
            break;
        default:
            measureSpec = MeasureSpec.makeMeasureSpec(rootDimension, MeasureSpec.EXACTLY);
            break;
        }
        return measureSpec;
    }
```
能看到从根布局开始遍历会通过getRootMeasureSpec根据DecorView以及窗口的宽高设定一个默认的measureSpec。

- 1.如果是MATCH_PARENT，则measureSpec就是窗口mWindowState大小，并且是精确模式
- 2.WRAP_CONTENT，则measureSpec是窗口mWindowState大小，但是是AT_MOST模式。在尽可能保证自己View的大小前提下，设置DecorView的大小最大不能超过WindowManager.LayoutParams的大小。
- 3.默认就是WindowManager.LayoutParams的大小，并且是精确模式。

一句话总结，WindowManager.LayoutParams中的width和height，设置上了就会是设置的大小。如果没有设置精准大小，检查是不是MATCH_PARENT或者WRAP_CONTENT模式。是MATCH_PARENT就是窗体区域，否则就是最大不能超过窗体区域。


#### performMeasure
```java
    private void performMeasure(int childWidthMeasureSpec, int childHeightMeasureSpec) {
        if (mView == null) {
            return;
        }
        try {
            mView.measure(childWidthMeasureSpec, childHeightMeasureSpec);
        } finally {
            Trace.traceEnd(Trace.TRACE_TAG_VIEW);
        }
    }
```

你其实这个方法就是调用DecorView的measure方法。
文件；/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)

在聊这个方法之前先来了解一下android:layoutMode的模式：
LAYOUT_MODE_OPTICAL_BOUNDS标志位，该标志位也是xml中的android:layoutMode.这个标志位有3种模式：一个是LAYOUT_MODE_OPTICAL_BOUNDS(光学边缘)，一个是LAYOUT_MODE_CLIP_BOUNDS(裁剪边缘)，剩下一种是默认模式LAYOUT_MODE_UNDEFINED。
    
-1.LAYOUT_MODE_OPTICAL_BOUNDS 一个控件出现的位置，这个位置一般位于一个父容器的区域内。而这种模式往往允许这个控件覆盖更大的区域。一般这种模式是用来实现阴影等效果。

- 2.LAYOUT_MODE_CLIP_BOUNDS 这个模式就是根据getLeft，getTop，getBottom，getRight对当前的View进行裁剪。

下面这个模式我们很常见，那么上面那个模式又是怎么实现的呢？其实猜测就知道在测量的时候进行了宽高的扩张。

```java
    public final void measure(int widthMeasureSpec, int heightMeasureSpec) {
        boolean optical = isLayoutModeOptical(this);
        if (optical != isLayoutModeOptical(mParent)) {
            Insets insets = getOpticalInsets();
            int oWidth  = insets.left + insets.right;
            int oHeight = insets.top  + insets.bottom;
            widthMeasureSpec  = MeasureSpec.adjust(widthMeasureSpec,  optical ? -oWidth  : oWidth);
            heightMeasureSpec = MeasureSpec.adjust(heightMeasureSpec, optical ? -oHeight : oHeight);
        }

        long key = (long) widthMeasureSpec << 32 | (long) heightMeasureSpec & 0xffffffffL;
        if (mMeasureCache == null) mMeasureCache = new LongSparseLongArray(2);

        final boolean forceLayout = (mPrivateFlags & PFLAG_FORCE_LAYOUT) == PFLAG_FORCE_LAYOUT;


        final boolean specChanged = widthMeasureSpec != mOldWidthMeasureSpec
                || heightMeasureSpec != mOldHeightMeasureSpec;
        final boolean isSpecExactly = MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.EXACTLY
                && MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY;
        final boolean matchesSpecSize = getMeasuredWidth() == MeasureSpec.getSize(widthMeasureSpec)
                && getMeasuredHeight() == MeasureSpec.getSize(heightMeasureSpec);
        final boolean needsLayout = specChanged
                && (sAlwaysRemeasureExactly || !isSpecExactly || !matchesSpecSize);

        if (forceLayout || needsLayout) {
            mPrivateFlags &= ~PFLAG_MEASURED_DIMENSION_SET;

            resolveRtlPropertiesIfNeeded();

            int cacheIndex = forceLayout ? -1 : mMeasureCache.indexOfKey(key);
            if (cacheIndex < 0 || sIgnoreMeasureCache) {
           
                onMeasure(widthMeasureSpec, heightMeasureSpec);
                mPrivateFlags3 &= ~PFLAG3_MEASURE_NEEDED_BEFORE_LAYOUT;
            } else {
                long value = mMeasureCache.valueAt(cacheIndex);
                setMeasuredDimensionRaw((int) (value >> 32), (int) value);
                mPrivateFlags3 |= PFLAG3_MEASURE_NEEDED_BEFORE_LAYOUT;
            }

...

            mPrivateFlags |= PFLAG_LAYOUT_REQUIRED;
        }

        mOldWidthMeasureSpec = widthMeasureSpec;
        mOldHeightMeasureSpec = heightMeasureSpec;

        mMeasureCache.put(key, ((long) mMeasuredWidth) << 32 |
                (long) mMeasuredHeight & 0xffffffffL); // suppress sign extension
    }
```
measure方法完成如下几个事件

- 1.判断当前的View的父布局是否通过layoutMode打开了LAYOUT_MODE_OPTICAL_BOUNDS，以及当前的View是否打开了LAYOUT_MODE_OPTICAL_BOUNDS标志位。如果都打开了，则通过getOpticalInsets获取Drawable中的mOpticalInsets的间距区域，并且通过下面adjust方法把上下左右四个方向到新的MeasureSpec中。

```java
        static int adjust(int measureSpec, int delta) {
            final int mode = getMode(measureSpec);
            int size = getSize(measureSpec);
            if (mode == UNSPECIFIED) {
                // No need to adjust size for UNSPECIFIED mode.
                return makeMeasureSpec(size, UNSPECIFIED);
            }
            size += delta;
            if (size < 0) {
                size = 0;
            }
            return makeMeasureSpec(size, mode);
        }
```
从这里可以得知这里实际上就是即将测量的View的宽高提前扩张了。注意，如果没有任何的处理widthMeasureSpec以及heightMeasureSpec就是从父布局生成传递下来的。这种方式让父布局的控件变大，使得子布局能够展示的空间更多。

- 2.判断当前的View即将设定的宽高模式，大小尺寸和之前相比是否发生了变化只要其中一个发生了变化，或者api低于Android 6.0将会打开needsLayout标志位。如果当前的View调用了requestlayout通知ViewRootImpl进行全局刷新，则会打开PFLAG_FORCE_LAYOUT标志位，而这个标志位设置时机如下：
```java
    public void requestLayout() {
        if (mMeasureCache != null) mMeasureCache.clear();

        if (mAttachInfo != null && mAttachInfo.mViewRequestingLayout == null) {
            ViewRootImpl viewRoot = getViewRootImpl();
            if (viewRoot != null && viewRoot.isInLayout()) {
                if (!viewRoot.requestLayoutDuringLayout(this)) {
                    return;
                }
            }
            mAttachInfo.mViewRequestingLayout = this;
        }

        mPrivateFlags |= PFLAG_FORCE_LAYOUT;
        mPrivateFlags |= PFLAG_INVALIDATED;

        if (mParent != null && !mParent.isLayoutRequested()) {
            mParent.requestLayout();
        }
        if (mAttachInfo != null && mAttachInfo.mViewRequestingLayout == this) {
            mAttachInfo.mViewRequestingLayout = null;
        }
    }
```
能看到把当前的View的标志位打开了，最后打开View中的PFLAG_FORCE_LAYOUT标志位。并且不断的通过递归上上层直到ViewRootImpl的requestLayout方法中，进行下一轮的performTravel的方法。

- 3.如果needslayout和forceLayout两者其一打开了，就会走到准备测量阶段。然而这个过程会进行一次最后一次校验，在每一次调用measure的时候会把当前的32位的宽高，记录在缓存中。记录格式如下：

> 64位的key(高32位是widthMeasure  + 底32位是heighMeasure) -> 经过onMeasure测量后的value(高32位是测量后的mMeasuredWidth + 底32位测量后的mMeasuredHeight)

本质上就是让父布局测量后的宽高和当前布局测量后宽高做一次映射。这样做的好处是，如果发现父布局测量后宽高把这个参数分发给当前布局进行计算，因为测量逻辑是一致，因此可以把计算前和计算后的宽高缓存下来，就没必要进行重复的遍历。

这种思想可以打断冗长的View的遍历栈，可能运用到算法的动态规划。发现没有这个过程实际上就是一个动态规划的过程。

每一次都尝试从mMeasureCache找到对应的缓存，如果找不到或者打开PFLAG_FORCE_LAYOUT标志位，则调用onMeasure方法。如果找到则调用setMeasuredDimensionRaw，把缓存的宽高重新设置会View中。

核心还是onMeasure方法。请注意，这里是根布局DecorView，让我们跟下去看看它做了什么。


#### DecorView onMeasure
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/)/[policy](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/)/[DecorView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/DecorView.java)

```java
  protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        final DisplayMetrics metrics = getContext().getResources().getDisplayMetrics();
        final boolean isPortrait =
                getResources().getConfiguration().orientation == ORIENTATION_PORTRAIT;

        final int widthMode = getMode(widthMeasureSpec);
        final int heightMode = getMode(heightMeasureSpec);

        boolean fixedWidth = false;
        mApplyFloatingHorizontalInsets = false;
        if (widthMode == AT_MOST) {
            final TypedValue tvw = isPortrait ? mWindow.mFixedWidthMinor : mWindow.mFixedWidthMajor;
            if (tvw != null && tvw.type != TypedValue.TYPE_NULL) {
                final int w;
                if (tvw.type == TypedValue.TYPE_DIMENSION) {
                    w = (int) tvw.getDimension(metrics);
                } else if (tvw.type == TypedValue.TYPE_FRACTION) {
                    w = (int) tvw.getFraction(metrics.widthPixels, metrics.widthPixels);
                } else {
                    w = 0;
                }
                final int widthSize = MeasureSpec.getSize(widthMeasureSpec);
                if (w > 0) {
                    widthMeasureSpec = MeasureSpec.makeMeasureSpec(
                            Math.min(w, widthSize), EXACTLY);
                    fixedWidth = true;
                } else {
                    widthMeasureSpec = MeasureSpec.makeMeasureSpec(
                            widthSize - mFloatingInsets.left - mFloatingInsets.right,
                            AT_MOST);
                    mApplyFloatingHorizontalInsets = true;
                }
            }
        }

        mApplyFloatingVerticalInsets = false;
        if (heightMode == AT_MOST) {
...
        }

...
    }
```
 - 1.在这个过程中通过从上面传下来MeasureSpec获取Window的模式，从而决定DecorView在AT_MOST模式下的处理。在这个模式下，说明View最大的宽高被Window的宽高限制。通过记录在全局style资源的windowFixedWidthMinor，windowFixedWidthMajor数据。这两个资源记录的是在横屏和纵屏情况下的宽度。 widthMeasureSpec通过和资源style设置的宽高的大小进行比较，获取比较小的部分设置为宽度。

同理在高度也是如此处理。实际上这个过程中就能直到onMesaure实际上就是把父布局的宽高传递下来，当前布局根据当前的状态进行适配。

```java
        getOutsets(mOutsets);
        if (mOutsets.top > 0 || mOutsets.bottom > 0) {
            int mode = MeasureSpec.getMode(heightMeasureSpec);
            if (mode != MeasureSpec.UNSPECIFIED) {
                int height = MeasureSpec.getSize(heightMeasureSpec);
                heightMeasureSpec = MeasureSpec.makeMeasureSpec(
                        height + mOutsets.top + mOutsets.bottom, mode);
            }
        }
        if (mOutsets.left > 0 || mOutsets.right > 0) {
            int mode = MeasureSpec.getMode(widthMeasureSpec);
            if (mode != MeasureSpec.UNSPECIFIED) {
                int width = MeasureSpec.getSize(widthMeasureSpec);
                widthMeasureSpec = MeasureSpec.makeMeasureSpec(
                        width + mOutsets.left + mOutsets.right, mode);
            }
        }

        super.onMeasure(widthMeasureSpec, heightMeasureSpec);

        int width = getMeasuredWidth();
        boolean measure = false;

        widthMeasureSpec = MeasureSpec.makeMeasureSpec(width, EXACTLY);

        if (!fixedWidth && widthMode == AT_MOST) {
            final TypedValue tv = isPortrait ? mWindow.mMinWidthMinor : mWindow.mMinWidthMajor;
            if (tv.type != TypedValue.TYPE_NULL) {
                final int min;
                if (tv.type == TypedValue.TYPE_DIMENSION) {
                    min = (int)tv.getDimension(metrics);
                } else if (tv.type == TypedValue.TYPE_FRACTION) {
                    min = (int)tv.getFraction(mAvailableWidth, mAvailableWidth);
                } else {
                    min = 0;
                }

                if (width < min) {
                    widthMeasureSpec = MeasureSpec.makeMeasureSpec(min, EXACTLY);
                    measure = true;
                }
            }
        }


        if (measure) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec);
        }
```
- 2.在这个过程中，根据mAttachInfo.mOutSet外部间距区域新增到当前View的MeasureSpec中。最后调用父类的onMeasure，继续根据父类的测量规则进一步的测量DecorView的大小。

- 3.如果发现在style资源中设置了mMinWidthMinor也就是windowMinWidthMinor标签。说明宽高有最小的限制。如果之前测量出来的width比起最小的设置的宽度，则把最小宽度设置到MeasureSpec中，并且调用父类的onMeasure，重新进行一次测量。


#### FrameLayout onMeasure上半部分
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[FrameLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/FrameLayout.java)
```java
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int count = getChildCount();

        final boolean measureMatchParentChildren =
                MeasureSpec.getMode(widthMeasureSpec) != MeasureSpec.EXACTLY ||
                MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.EXACTLY;
        mMatchParentChildren.clear();

        int maxHeight = 0;
        int maxWidth = 0;
        int childState = 0;

        for (int i = 0; i < count; i++) {
            final View child = getChildAt(i);
            if (mMeasureAllChildren || child.getVisibility() != GONE) {
                measureChildWithMargins(child, widthMeasureSpec, 0, heightMeasureSpec, 0);
                final LayoutParams lp = (LayoutParams) child.getLayoutParams();
                maxWidth = Math.max(maxWidth,
                        child.getMeasuredWidth() + lp.leftMargin + lp.rightMargin);
                maxHeight = Math.max(maxHeight,
                        child.getMeasuredHeight() + lp.topMargin + lp.bottomMargin);
                childState = combineMeasuredStates(childState, child.getMeasuredState());
                if (measureMatchParentChildren) {
                    if (lp.width == LayoutParams.MATCH_PARENT ||
                            lp.height == LayoutParams.MATCH_PARENT) {
                        mMatchParentChildren.add(child);
                    }
                }
            }
        }

....
    }
```

- 1.遍历每一个FrameLayout的子View。如果发现每一个子View中mMeasureAllChildren标志位打开了，或者子View不为Gone。将会调用measureChildWithMargins进行一次带着Margin和Padding的测量的MeasureSpec传递到底层进行测量。

- 2.FrameLayout在遍历每一个子View的过程中，都需要考察最大的子View，为后续如LayoutParams.WRAP_CONTENT模式适配大小。并且通过combineMeasuredStates合并每一个子View的测量模式。因为第32位代表精确模式，第31位代表最大模式。这样就能直到FrameLayout中的子View一共有多少种模式。

- 3.如果当前FrameLayout的模式不是精准模式，而是AT_MOST或者UNSPECIFIED模式，则根据FrameLayout的子View层级不断的寻找打开了MATCH_PARENT模式的·View，最后添加到mMatchParentChildren中。准备第二次测量。说明子View需要依赖FrameLayout测量出来的大小，然而此时FrameLayout还没有真正确定大小，他需要度量完所有的子View后才能确定。因此此时需要确定好FrameLayout大小后再一次确定这些子View需要和FrameLayout一样大的宽高。

##### measureChildWithMargins
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewGroup.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewGroup.java)

```java
    protected void measureChildWithMargins(View child,
            int parentWidthMeasureSpec, int widthUsed,
            int parentHeightMeasureSpec, int heightUsed) {
        final MarginLayoutParams lp = (MarginLayoutParams) child.getLayoutParams();

        final int childWidthMeasureSpec = getChildMeasureSpec(parentWidthMeasureSpec,
                mPaddingLeft + mPaddingRight + lp.leftMargin + lp.rightMargin
                        + widthUsed, lp.width);
        final int childHeightMeasureSpec = getChildMeasureSpec(parentHeightMeasureSpec,
                mPaddingTop + mPaddingBottom + lp.topMargin + lp.bottomMargin
                        + heightUsed, lp.height);

        child.measure(childWidthMeasureSpec, childHeightMeasureSpec);
    }
```
能看到这个过程中，实际上就能看到实际上就是把FrameLayout的Padding和Margin的数值通过getChildMeasureSpec生成一个新的MeasureSpec，传递到底层子View的measure，进行上面类似的逻辑。

来看看getChildMeasureSpec中的逻辑。

###### getChildMeasureSpec
```java
public static int getChildMeasureSpec(int spec, int padding, int childDimension) {
        int specMode = MeasureSpec.getMode(spec);
        int specSize = MeasureSpec.getSize(spec);

        int size = Math.max(0, specSize - padding);

        int resultSize = 0;
        int resultMode = 0;

        switch (specMode) {
        case MeasureSpec.EXACTLY:
            if (childDimension >= 0) {
                resultSize = childDimension;
                resultMode = MeasureSpec.EXACTLY;
            } else if (childDimension == LayoutParams.MATCH_PARENT) {
                resultSize = size;
                resultMode = MeasureSpec.EXACTLY;
            } else if (childDimension == LayoutParams.WRAP_CONTENT) {
                // bigger than us.
                resultSize = size;
                resultMode = MeasureSpec.AT_MOST;
            }
            break;

        // Parent has imposed a maximum size on us
        case MeasureSpec.AT_MOST:
            if (childDimension >= 0) {
                resultSize = childDimension;
                resultMode = MeasureSpec.EXACTLY;
            } else if (childDimension == LayoutParams.MATCH_PARENT) {

                resultSize = size;
                resultMode = MeasureSpec.AT_MOST;
            } else if (childDimension == LayoutParams.WRAP_CONTENT) {

                resultSize = size;
                resultMode = MeasureSpec.AT_MOST;
            }
            break;

        case MeasureSpec.UNSPECIFIED:
            if (childDimension >= 0) {
                resultSize = childDimension;
                resultMode = MeasureSpec.EXACTLY;
            } else if (childDimension == LayoutParams.MATCH_PARENT) {

                resultSize = View.sUseZeroUnspecifiedMeasureSpec ? 0 : size;
                resultMode = MeasureSpec.UNSPECIFIED;
            } else if (childDimension == LayoutParams.WRAP_CONTENT) {

                resultSize = View.sUseZeroUnspecifiedMeasureSpec ? 0 : size;
                resultMode = MeasureSpec.UNSPECIFIED;
            }
            break;
        }
        //noinspection ResourceType
        return MeasureSpec.makeMeasureSpec(resultSize, resultMode);
    }
```
而这里面则是根据当前FrameLayout的测量Mode生成一个新的MeasureSpec交给子View处理：
- 1.MeasureSpec.EXACTLY 如果是精确模式分为三种情况：
    - 1.如果FrameLayout.LayoutParams也就是lp的宽或者高大于0，则给子View的MeasureSpec的模式为MeasureSpec.EXACTLY，大小为lp的宽或者高。
    - 2.如果FrameLayout.LayoutParams是MATCH_PARENT，大小则FrameLayout的MeasureWidth和MeasureHeight的大小减去padding和margin数值，模式为MeasureSpec.EXACTLY。
    - 3.如果FrameLayout.LayoutParams是WRAP_CONTENT，模式为AT_MOST，大小为FrameLayout的MeasureWidth和MeasureHeight的大小减去padding和margin数值。

- 2.MeasureSpec.AT_MOST分为如下三种情况：
    - 1.如果FrameLayout.LayoutParams也就是lp的宽或者高大于0，则模式为MeasureSpec.EXACTLY，大小为lp的大小。
    - 2.如果FrameLayout.LayoutParams是MATCH_PARENT，则模式为MeasureSpec.AT_MOST，大小为MeasureWidth和MeasureHeight的大小减去padding和margin数值。
    - 3.如果FrameLayout.LayoutParams是WRAP_CONTENT，则模式为MeasureSpec.AT_MOST，大小为MeasureWidth和MeasureHeight的大小减去padding和margin数值。

- 3.MeasureSpec.UNSPECIFIED分为如下三种情况：
    - 1.如果FrameLayout.LayoutParams也就是lp的宽或者高大于0，则模式为MeasureSpec.EXACTLY，大小为lp的大小。
  - 2.如果FrameLayout.LayoutParams是MATCH_PARENT，模式为MeasureSpec.UNSPECIFIED，如果小于Android 6.0中，大小为0。大于6.0则为MeasureWidth和MeasureHeight的大小减去padding和margin数值。
  - 3.如果FrameLayout.LayoutParams是WRAP_CONTENT，模式为MeasureSpec.AT_MOST，如果小于Android 6.0中，大小为0。大于6.0则为MeasureWidth和MeasureHeight的大小减去padding和margin数值。


实际上一句话总结就是，父容器LayoutParams有精确大小时候，传递给子View的是精确模式和精确数值。LayoutParams为MATCH_PARENT或者WRAP_CONTENT，大小为当前大小减去padding+margin数值。只是模式跟着父容器走。




#### FrameLayout onMeasure下半部分
```java
        // Account for padding too
        maxWidth += getPaddingLeftWithForeground() + getPaddingRightWithForeground();
        maxHeight += getPaddingTopWithForeground() + getPaddingBottomWithForeground();

        // Check against our minimum height and width
        maxHeight = Math.max(maxHeight, getSuggestedMinimumHeight());
        maxWidth = Math.max(maxWidth, getSuggestedMinimumWidth());

        // Check against our foreground's minimum height and width
        final Drawable drawable = getForeground();
        if (drawable != null) {
            maxHeight = Math.max(maxHeight, drawable.getMinimumHeight());
            maxWidth = Math.max(maxWidth, drawable.getMinimumWidth());
        }

        setMeasuredDimension(resolveSizeAndState(maxWidth, widthMeasureSpec, childState),
                resolveSizeAndState(maxHeight, heightMeasureSpec,
                        childState << MEASURED_HEIGHT_STATE_SHIFT));

        count = mMatchParentChildren.size();
        if (count > 1) {
            for (int i = 0; i < count; i++) {
                final View child = mMatchParentChildren.get(i);
                final MarginLayoutParams lp = (MarginLayoutParams) child.getLayoutParams();

                final int childWidthMeasureSpec;
                if (lp.width == LayoutParams.MATCH_PARENT) {
                    final int width = Math.max(0, getMeasuredWidth()
                            - getPaddingLeftWithForeground() - getPaddingRightWithForeground()
                            - lp.leftMargin - lp.rightMargin);
                    childWidthMeasureSpec = MeasureSpec.makeMeasureSpec(
                            width, MeasureSpec.EXACTLY);
                } else {
                    childWidthMeasureSpec = getChildMeasureSpec(widthMeasureSpec,
                            getPaddingLeftWithForeground() + getPaddingRightWithForeground() +
                            lp.leftMargin + lp.rightMargin,
                            lp.width);
                }

                final int childHeightMeasureSpec;
                if (lp.height == LayoutParams.MATCH_PARENT) {
                    final int height = Math.max(0, getMeasuredHeight()
                            - getPaddingTopWithForeground() - getPaddingBottomWithForeground()
                            - lp.topMargin - lp.bottomMargin);
                    childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(
                            height, MeasureSpec.EXACTLY);
                } else {
                    childHeightMeasureSpec = getChildMeasureSpec(heightMeasureSpec,
                            getPaddingTopWithForeground() + getPaddingBottomWithForeground() +
                            lp.topMargin + lp.bottomMargin,
                            lp.height);
                }

                child.measure(childWidthMeasureSpec, childHeightMeasureSpec);
            }
        }
```


- 1.考察ForegroundDrawable，BackgroundDrawable的大小，以及设置在View中的最大和最小的宽高，最后通过resolveSizeAndState确定大小，并把测量好的大小通过setMeasuredDimension设置在View中。

- 2.当确定好FrameLayout，回头把子View中MatchParent的取出来.如果FrameLayout为MATCH_PARENT状态，则把FrameLayout测量的大小减去padding和margin数值传递给子View;如果是WRAP_CONTENT模式，则设置为FrameLayout测量的大小减去padding和margin；FrameLayout的LayoutParams中带着width和height的具体参数,则为具体的大小。

来看看resolveSizeAndState方法做了什么事情。

##### resolveSizeAndState
```java
    public static int resolveSizeAndState(int size, int measureSpec, int childMeasuredState) {
        final int specMode = MeasureSpec.getMode(measureSpec);
        final int specSize = MeasureSpec.getSize(measureSpec);
        final int result;
        switch (specMode) {
            case MeasureSpec.AT_MOST:
                if (specSize < size) {
                    result = specSize | MEASURED_STATE_TOO_SMALL;
                } else {
                    result = size;
                }
                break;
            case MeasureSpec.EXACTLY:
                result = specSize;
                break;
            case MeasureSpec.UNSPECIFIED:
            default:
                result = size;
        }
        return result | (childMeasuredState & MEASURED_STATE_MASK);
    }
```
- 1.MeasureSpec.AT_MOST:模式下，则比较maxWidth和widthMeasureSpec。如果widthMeasureSpec大于等于maxWidth，则为maxWidth。如果小于则取widthMeasureSpec。

- 2.MeasureSpec.EXACTLY模式下，则返回widthMeasureSpec

- 3.MeasureSpec.UNSPECIFIED，则取maxWidth。

注意这里的maxWidth并非是在Android标签中设置的最大宽度。而是通过测量子View后，统计出来的最大宽度加上forgroundDrawable宽高等计算出来的结果。


### View onMeasure
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[View.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/View.java)
再来看看view中默认的onMeasure方法。
```java
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        setMeasuredDimension(getDefaultSize(getSuggestedMinimumWidth(), widthMeasureSpec),
                getDefaultSize(getSuggestedMinimumHeight(), heightMeasureSpec));
    }

    public static int getDefaultSize(int size, int measureSpec) {
        int result = size;
        int specMode = MeasureSpec.getMode(measureSpec);
        int specSize = MeasureSpec.getSize(measureSpec);

        switch (specMode) {
        case MeasureSpec.UNSPECIFIED:
            result = size;
            break;
        case MeasureSpec.AT_MOST:
        case MeasureSpec.EXACTLY:
            result = specSize;
            break;
        }
        return result;
    }

    protected int getSuggestedMinimumHeight() {
        return (mBackground == null) ? mMinHeight : max(mMinHeight, mBackground.getMinimumHeight());

    }

```
不重写onMesaure方法，能看到MeasureSpec.EXACTLY和MeasureSpec.AT_MOST就是父容器的MeasureSpec。MeasureSpec.UNSPECIFIED则是根据背景Drawable最小大小以及设定的最小大小确定的。

到这里就完成了DecorView的onMeasure的逻辑。让我们再看看常见的另外两个ViewGroup的原理。

## LinearLayout onMeasure 
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[LinearLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/LinearLayout.java)
```java
    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        if (mOrientation == VERTICAL) {
            measureVertical(widthMeasureSpec, heightMeasureSpec);
        } else {
            measureHorizontal(widthMeasureSpec, heightMeasureSpec);
        }
    }
```

LinearLayout会先根据mOrientation的横向排版还是竖直排版顺序，进行两个方向的测量。因为LinearLayout这个ViewGroup实际上就是把所有的子View按照横竖两个方向进行布局。

我们只需要看一个方向即可。

### LinearLayout measureVertical上半部分
```java
    void measureVertical(int widthMeasureSpec, int heightMeasureSpec) {
        mTotalLength = 0;
        int maxWidth = 0;
        int childState = 0;
        int alternativeMaxWidth = 0;
        int weightedMaxWidth = 0;
        boolean allFillParent = true;
        float totalWeight = 0;

        final int count = getVirtualChildCount();

        final int widthMode = MeasureSpec.getMode(widthMeasureSpec);
        final int heightMode = MeasureSpec.getMode(heightMeasureSpec);

        boolean matchWidth = false;
        boolean skippedMeasure = false;

        final int baselineChildIndex = mBaselineAlignedChildIndex;
        final boolean useLargestChild = mUseLargestChild;

        int largestChildHeight = Integer.MIN_VALUE;
        int consumedExcessSpace = 0;

        int nonSkippedChildCount = 0;

        for (int i = 0; i < count; ++i) {
            final View child = getVirtualChildAt(i);
            if (child == null) {
                mTotalLength += measureNullChild(i);
                continue;
            }

            if (child.getVisibility() == View.GONE) {
               i += getChildrenSkipCount(child, i);
               continue;
            }

            nonSkippedChildCount++;
            if (hasDividerBeforeChildAt(i)) {
                mTotalLength += mDividerHeight;
            }

            final LayoutParams lp = (LayoutParams) child.getLayoutParams();

            totalWeight += lp.weight;

            final boolean useExcessSpace = lp.height == 0 && lp.weight > 0;
            if (heightMode == MeasureSpec.EXACTLY && useExcessSpace) {
                final int totalLength = mTotalLength;
                mTotalLength = Math.max(totalLength, totalLength + lp.topMargin + lp.bottomMargin);
                skippedMeasure = true;
            } else {
                if (useExcessSpace) {
                    lp.height = LayoutParams.WRAP_CONTENT;
                }

                final int usedHeight = totalWeight == 0 ? mTotalLength : 0;
                measureChildBeforeLayout(child, i, widthMeasureSpec, 0,
                        heightMeasureSpec, usedHeight);

                final int childHeight = child.getMeasuredHeight();
                if (useExcessSpace) {

                    lp.height = 0;
                    consumedExcessSpace += childHeight;
                }

                final int totalLength = mTotalLength;
                mTotalLength = Math.max(totalLength, totalLength + childHeight + lp.topMargin +
                       lp.bottomMargin + getNextLocationOffset(child));

                if (useLargestChild) {
                    largestChildHeight = Math.max(childHeight, largestChildHeight);
                }
            }


            if ((baselineChildIndex >= 0) && (baselineChildIndex == i + 1)) {
               mBaselineChildTop = mTotalLength;
            }

...
            boolean matchWidthLocally = false;
            if (widthMode != MeasureSpec.EXACTLY && lp.width == LayoutParams.MATCH_PARENT) {
                matchWidth = true;
                matchWidthLocally = true;
            }

            final int margin = lp.leftMargin + lp.rightMargin;
            final int measuredWidth = child.getMeasuredWidth() + margin;
            maxWidth = Math.max(maxWidth, measuredWidth);
            childState = combineMeasuredStates(childState, child.getMeasuredState());

            allFillParent = allFillParent && lp.width == LayoutParams.MATCH_PARENT;
            if (lp.weight > 0) {

                weightedMaxWidth = Math.max(weightedMaxWidth,
                        matchWidthLocally ? margin : measuredWidth);
            } else {
                alternativeMaxWidth = Math.max(alternativeMaxWidth,
                        matchWidthLocally ? margin : measuredWidth);
            }

            i += getChildrenSkipCount(child, i);
        }
...
    }
```

在LinearLayout中首先有一个大的循环遍历，遍历所有在LinearLayout中的子View。这个循环中做了如下几个事情：
- 1.首先跳开那些null对象以及Gone的子View，并添加每一个分割线的高度。

- 2.获取每一个子View的LayoutParams，获取每一个子View的比重，并计算总比重，为后续进行高度分配作准备。

- 3.如果判断到从父布局传递下来的模式是精准模式，并且LayoutLayoutParams的高度为0，weight大于0.此时没有必要测量每个子View的大小，只需要确定好了父布局的大小，再分发即可。

- 4.不是第三点的模式，判断到总比重weight大于0，则把usedHeight设置为0.否则为上面把分割线等情况都累加的总高度传递下去，调用measureChildBeforeLayout对子View进行测量。
```java
    void measureChildBeforeLayout(View child, int childIndex,
            int widthMeasureSpec, int totalWidth, int heightMeasureSpec,
            int totalHeight) {
        measureChildWithMargins(child, widthMeasureSpec, totalWidth,
                heightMeasureSpec, totalHeight);
    }
```
能看到这个方法实际上也是调用measureChildWithMargins的方法对子View进行测量。根据上面讲解的逻辑，实际上是指根据当前的模式，计算出对应的大小，此时大小要么是(LinearLayout.height - (padding+margin)),要么就是上面计算的usedHeight高度。

经过该方法后，就能计算出每一个子View的高度，然后都累加到mTotalLength中，作为第一轮计算，也是没有使用weight情况下LinearLayout的总高度。

- 5.计算最后一项LinearLayout的baseline，这里的baseline实际上就是此时刚刚通过上面流程累加出来的高度。

- 6.如果LinearLayout的父容器宽度不是MeasureSpec.EXACTLY，但是LinearLayout的宽度是LayoutParams.MATCH_PARENT模式。每一次都开始不断的遍历找到最大的宽度。


### LinearLayout measureVertical下半部分
```java
        if (nonSkippedChildCount > 0 && hasDividerBeforeChildAt(count)) {
            mTotalLength += mDividerHeight;
        }
        if (useLargestChild &&
                (heightMode == MeasureSpec.AT_MOST || heightMode == MeasureSpec.UNSPECIFIED)) {
            mTotalLength = 0;

            for (int i = 0; i < count; ++i) {
                final View child = getVirtualChildAt(i);
                if (child == null) {
                    mTotalLength += measureNullChild(i);
                    continue;
                }

                if (child.getVisibility() == GONE) {
                    i += getChildrenSkipCount(child, i);
                    continue;
                }

                final LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams)
                        child.getLayoutParams();
                // Account for negative margins
                final int totalLength = mTotalLength;
                mTotalLength = Math.max(totalLength, totalLength + largestChildHeight +
                        lp.topMargin + lp.bottomMargin + getNextLocationOffset(child));
            }
        }

        mTotalLength += mPaddingTop + mPaddingBottom;

        int heightSize = mTotalLength;

        heightSize = Math.max(heightSize, getSuggestedMinimumHeight());

        int heightSizeAndState = resolveSizeAndState(heightSize, heightMeasureSpec, 0);
        heightSize = heightSizeAndState & MEASURED_SIZE_MASK;

        int remainingExcess = heightSize - mTotalLength
                + (mAllowInconsistentMeasurement ? 0 : consumedExcessSpace);
        if (skippedMeasure
                || ((sRemeasureWeightedChildren || remainingExcess != 0) && totalWeight > 0.0f)) {
            float remainingWeightSum = mWeightSum > 0.0f ? mWeightSum : totalWeight;

            mTotalLength = 0;

            for (int i = 0; i < count; ++i) {
                final View child = getVirtualChildAt(i);
                if (child == null || child.getVisibility() == View.GONE) {
                    continue;
                }

                final LayoutParams lp = (LayoutParams) child.getLayoutParams();
                final float childWeight = lp.weight;
                if (childWeight > 0) {
                    final int share = (int) (childWeight * remainingExcess / remainingWeightSum);
                    remainingExcess -= share;
                    remainingWeightSum -= childWeight;

                    final int childHeight;
                    if (mUseLargestChild && heightMode != MeasureSpec.EXACTLY) {
                        childHeight = largestChildHeight;
                    } else if (lp.height == 0 && (!mAllowInconsistentMeasurement
                            || heightMode == MeasureSpec.EXACTLY)) {

                        childHeight = share;
                    } else {
                        childHeight = child.getMeasuredHeight() + share;
                    }

                    final int childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(
                            Math.max(0, childHeight), MeasureSpec.EXACTLY);
                    final int childWidthMeasureSpec = getChildMeasureSpec(widthMeasureSpec,
                            mPaddingLeft + mPaddingRight + lp.leftMargin + lp.rightMargin,
                            lp.width);
                    child.measure(childWidthMeasureSpec, childHeightMeasureSpec);

                    childState = combineMeasuredStates(childState, child.getMeasuredState()
                            & (MEASURED_STATE_MASK>>MEASURED_HEIGHT_STATE_SHIFT));
                }

                final int margin =  lp.leftMargin + lp.rightMargin;
                final int measuredWidth = child.getMeasuredWidth() + margin;
                maxWidth = Math.max(maxWidth, measuredWidth);

                boolean matchWidthLocally = widthMode != MeasureSpec.EXACTLY &&
                        lp.width == LayoutParams.MATCH_PARENT;

                alternativeMaxWidth = Math.max(alternativeMaxWidth,
                        matchWidthLocally ? margin : measuredWidth);

                allFillParent = allFillParent && lp.width == LayoutParams.MATCH_PARENT;

                final int totalLength = mTotalLength;
                mTotalLength = Math.max(totalLength, totalLength + child.getMeasuredHeight() +
                        lp.topMargin + lp.bottomMargin + getNextLocationOffset(child));
            }

            mTotalLength += mPaddingTop + mPaddingBottom;
        } else {
            alternativeMaxWidth = Math.max(alternativeMaxWidth,
                                           weightedMaxWidth);


            if (useLargestChild && heightMode != MeasureSpec.EXACTLY) {
                for (int i = 0; i < count; i++) {
                    final View child = getVirtualChildAt(i);
                    if (child == null || child.getVisibility() == View.GONE) {
                        continue;
                    }

                    final LinearLayout.LayoutParams lp =
                            (LinearLayout.LayoutParams) child.getLayoutParams();

                    float childExtra = lp.weight;
                    if (childExtra > 0) {
                        child.measure(
                                MeasureSpec.makeMeasureSpec(child.getMeasuredWidth(),
                                        MeasureSpec.EXACTLY),
                                MeasureSpec.makeMeasureSpec(largestChildHeight,
                                        MeasureSpec.EXACTLY));
                    }
                }
            }
        }

        if (!allFillParent && widthMode != MeasureSpec.EXACTLY) {
            maxWidth = alternativeMaxWidth;
        }

        maxWidth += mPaddingLeft + mPaddingRight;

        maxWidth = Math.max(maxWidth, getSuggestedMinimumWidth());

        setMeasuredDimension(resolveSizeAndState(maxWidth, widthMeasureSpec, childState),
                heightSizeAndState);

        if (matchWidth) {
            forceUniformWidth(count, heightMeasureSpec);
        }
```
这里主要处理了两个情况，一个是处理带了weight且父容器是精确模式的情况，一个是不带weight测量的情况。

- 1.如果带上了weight，在上半部分会跳过totalHeight的计算，也就是说最多只有写padding，margin以及分割线的数值。此时就要开始测量从父容器留给LinearLayout还有多少空间:
> int remainingExcess = heightSize - mTotalLength

得到这个剩余可分配的空间大小，在不断的遍历子View，根据比重，按照比例分配给每一个子View对应的高度，最后调用子View的measure的方法，让子View进一步的消化这些空间。最后把这些数据记录加上每一个子View的margin和padding以及LinearLayout的padding和margin到mTotalLength中

- 2.如果通过setMeasureWithLargestChildEnabled设置了LinearLayout，就会让所有的View拥有最大子View的宽高。能看到下半部分开始的时候，如果是AT_MOST模式或者UNSPECIFIED且打开了这个标志位，会对mTotalLength进行一次清零，重新遍历所有的子View，并以之前计算出来最大的子View作为基础不断的向上叠加。

如果测定了最大的子View的高度，且高度模式不是EXACTLY。则调用一次所有子View的measure方法，不过高度都是最大子View的高度。

- 3.当一切测定好后，就调用setMeasuredDimension设置LinearLayout的宽高。

- 4.如果父容器宽度不是EXACTLY，且LinearLayout的宽度是MATCH_PARENT。最后还会通过forceUniformWidth进行处理一次宽度。因为之前的时候父容器不确定允许完全适配LinearLayout的宽度，但是LinearLayout此时还不确定，需要等到LinearLayout测量好之后，才能让正式的设置width。

```java
    private void forceUniformWidth(int count, int heightMeasureSpec) {
        int uniformMeasureSpec = MeasureSpec.makeMeasureSpec(getMeasuredWidth(),
                MeasureSpec.EXACTLY);
        for (int i = 0; i< count; ++i) {
           final View child = getVirtualChildAt(i);
           if (child != null && child.getVisibility() != GONE) {
               LinearLayout.LayoutParams lp = ((LinearLayout.LayoutParams)child.getLayoutParams());

               if (lp.width == LayoutParams.MATCH_PARENT) {
                   int oldHeight = lp.height;
                   lp.height = child.getMeasuredHeight();

                   measureChildWithMargins(child, uniformMeasureSpec, 0, heightMeasureSpec, 0);
                   lp.height = oldHeight;
               }
           }
        }
    }
```
能看到实际上这个方法只处理MATCH_PARENT模式，调用measureChildWithMargin重新设置宽度和高度。


### RelativeLayout onMeasure
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[widget](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/)/[RelativeLayout.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/widget/RelativeLayout.java)

```java
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        if (mDirtyHierarchy) {
            mDirtyHierarchy = false;
            sortChildren();
        }

        int myWidth = -1;
        int myHeight = -1;

        int width = 0;
        int height = 0;

        final int widthMode = MeasureSpec.getMode(widthMeasureSpec);
        final int heightMode = MeasureSpec.getMode(heightMeasureSpec);
        final int widthSize = MeasureSpec.getSize(widthMeasureSpec);
        final int heightSize = MeasureSpec.getSize(heightMeasureSpec);

        if (widthMode != MeasureSpec.UNSPECIFIED) {
            myWidth = widthSize;
        }

        if (heightMode != MeasureSpec.UNSPECIFIED) {
            myHeight = heightSize;
        }

        if (widthMode == MeasureSpec.EXACTLY) {
            width = myWidth;
        }

        if (heightMode == MeasureSpec.EXACTLY) {
            height = myHeight;
        }

        View ignore = null;
        int gravity = mGravity & Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK;
        final boolean horizontalGravity = gravity != Gravity.START && gravity != 0;
        gravity = mGravity & Gravity.VERTICAL_GRAVITY_MASK;
        final boolean verticalGravity = gravity != Gravity.TOP && gravity != 0;

        int left = Integer.MAX_VALUE;
        int top = Integer.MAX_VALUE;
        int right = Integer.MIN_VALUE;
        int bottom = Integer.MIN_VALUE;

        boolean offsetHorizontalAxis = false;
        boolean offsetVerticalAxis = false;

        if ((horizontalGravity || verticalGravity) && mIgnoreGravity != View.NO_ID) {
            ignore = findViewById(mIgnoreGravity);
        }

        final boolean isWrapContentWidth = widthMode != MeasureSpec.EXACTLY;
        final boolean isWrapContentHeight = heightMode != MeasureSpec.EXACTLY;


        final int layoutDirection = getLayoutDirection();
        if (isLayoutRtl() && myWidth == -1) {
            myWidth = DEFAULT_WIDTH;
        }

        View[] views = mSortedHorizontalChildren;
        int count = views.length;

        for (int i = 0; i < count; i++) {
            View child = views[i];
            if (child.getVisibility() != GONE) {
                LayoutParams params = (LayoutParams) child.getLayoutParams();
                int[] rules = params.getRules(layoutDirection);

                applyHorizontalSizeRules(params, myWidth, rules);
                measureChildHorizontal(child, params, myWidth, myHeight);

                if (positionChildHorizontal(child, params, myWidth, isWrapContentWidth)) {
                    offsetHorizontalAxis = true;
                }
            }
        }

        views = mSortedVerticalChildren;
        count = views.length;
        final int targetSdkVersion = getContext().getApplicationInfo().targetSdkVersion;

        for (int i = 0; i < count; i++) {
            final View child = views[i];
            if (child.getVisibility() != GONE) {
                final LayoutParams params = (LayoutParams) child.getLayoutParams();

                applyVerticalSizeRules(params, myHeight, child.getBaseline());
                measureChild(child, params, myWidth, myHeight);
                if (positionChildVertical(child, params, myHeight, isWrapContentHeight)) {
                    offsetVerticalAxis = true;
                }

                if (isWrapContentWidth) {
                    if (isLayoutRtl()) {
                        if (targetSdkVersion < Build.VERSION_CODES.KITKAT) {
                            width = Math.max(width, myWidth - params.mLeft);
                        } else {
                            width = Math.max(width, myWidth - params.mLeft + params.leftMargin);
                        }
                    } else {
                        if (targetSdkVersion < Build.VERSION_CODES.KITKAT) {
                            width = Math.max(width, params.mRight);
                        } else {
                            width = Math.max(width, params.mRight + params.rightMargin);
                        }
                    }
                }

                if (isWrapContentHeight) {
                    if (targetSdkVersion < Build.VERSION_CODES.KITKAT) {
                        height = Math.max(height, params.mBottom);
                    } else {
                        height = Math.max(height, params.mBottom + params.bottomMargin);
                    }
                }

                if (child != ignore || verticalGravity) {
                    left = Math.min(left, params.mLeft - params.leftMargin);
                    top = Math.min(top, params.mTop - params.topMargin);
                }

                if (child != ignore || horizontalGravity) {
                    right = Math.max(right, params.mRight + params.rightMargin);
                    bottom = Math.max(bottom, params.mBottom + params.bottomMargin);
                }
            }
        }


        View baselineView = null;
        LayoutParams baselineParams = null;
        for (int i = 0; i < count; i++) {
            final View child = views[i];
            if (child.getVisibility() != GONE) {
                final LayoutParams childParams = (LayoutParams) child.getLayoutParams();
                if (baselineView == null || baselineParams == null
                        || compareLayoutPosition(childParams, baselineParams) < 0) {
                    baselineView = child;
                    baselineParams = childParams;
                }
            }
        }
        mBaselineView = baselineView;

        if (isWrapContentWidth) {

            width += mPaddingRight;

            if (mLayoutParams != null && mLayoutParams.width >= 0) {
                width = Math.max(width, mLayoutParams.width);
            }

            width = Math.max(width, getSuggestedMinimumWidth());
            width = resolveSize(width, widthMeasureSpec);

            if (offsetHorizontalAxis) {
                for (int i = 0; i < count; i++) {
                    final View child = views[i];
                    if (child.getVisibility() != GONE) {
                        final LayoutParams params = (LayoutParams) child.getLayoutParams();
                        final int[] rules = params.getRules(layoutDirection);
                        if (rules[CENTER_IN_PARENT] != 0 || rules[CENTER_HORIZONTAL] != 0) {
                            centerHorizontal(child, params, width);
                        } else if (rules[ALIGN_PARENT_RIGHT] != 0) {
                            final int childWidth = child.getMeasuredWidth();
                            params.mLeft = width - mPaddingRight - childWidth;
                            params.mRight = params.mLeft + childWidth;
                        }
                    }
                }
            }
        }

        if (isWrapContentHeight) {

            height += mPaddingBottom;

            if (mLayoutParams != null && mLayoutParams.height >= 0) {
                height = Math.max(height, mLayoutParams.height);
            }

            height = Math.max(height, getSuggestedMinimumHeight());
            height = resolveSize(height, heightMeasureSpec);

            if (offsetVerticalAxis) {
                for (int i = 0; i < count; i++) {
                    final View child = views[i];
                    if (child.getVisibility() != GONE) {
                        final LayoutParams params = (LayoutParams) child.getLayoutParams();
                        final int[] rules = params.getRules(layoutDirection);
                        if (rules[CENTER_IN_PARENT] != 0 || rules[CENTER_VERTICAL] != 0) {
                            centerVertical(child, params, height);
                        } else if (rules[ALIGN_PARENT_BOTTOM] != 0) {
                            final int childHeight = child.getMeasuredHeight();
                            params.mTop = height - mPaddingBottom - childHeight;
                            params.mBottom = params.mTop + childHeight;
                        }
                    }
                }
            }
        }

        if (horizontalGravity || verticalGravity) {
            final Rect selfBounds = mSelfBounds;
            selfBounds.set(mPaddingLeft, mPaddingTop, width - mPaddingRight,
                    height - mPaddingBottom);

            final Rect contentBounds = mContentBounds;
            Gravity.apply(mGravity, right - left, bottom - top, selfBounds, contentBounds,
                    layoutDirection);

            final int horizontalOffset = contentBounds.left - left;
            final int verticalOffset = contentBounds.top - top;
            if (horizontalOffset != 0 || verticalOffset != 0) {
                for (int i = 0; i < count; i++) {
                    final View child = views[i];
                    if (child.getVisibility() != GONE && child != ignore) {
                        final LayoutParams params = (LayoutParams) child.getLayoutParams();
                        if (horizontalGravity) {
                            params.mLeft += horizontalOffset;
                            params.mRight += horizontalOffset;
                        }
                        if (verticalGravity) {
                            params.mTop += verticalOffset;
                            params.mBottom += verticalOffset;
                        }
                    }
                }
            }
        }

        if (isLayoutRtl()) {
            final int offsetWidth = myWidth - width;
            for (int i = 0; i < count; i++) {
                final View child = views[i];
                if (child.getVisibility() != GONE) {
                    final LayoutParams params = (LayoutParams) child.getLayoutParams();
                    params.mLeft -= offsetWidth;
                    params.mRight -= offsetWidth;
                }
            }
        }

        setMeasuredDimension(width, height);
    }
```
这里处理的事情可以分为如下几个步骤：
- 1.第一次遍历所有的子View，获取每一个View所携带的Relativelayout中特有的规则，如谁在谁的左边等。并根据这些规则测量每一个子View经过排列后，测定每一个View需要多少宽度，并且设置每一个子View的左右，2个方向的参数。
```java
    private void measureChildHorizontal(
            View child, LayoutParams params, int myWidth, int myHeight) {
        final int childWidthMeasureSpec = getChildMeasureSpec(params.mLeft, params.mRight,
                params.width, params.leftMargin, params.rightMargin, mPaddingLeft, mPaddingRight,
                myWidth);

        final int childHeightMeasureSpec;
        if (myHeight < 0 && !mAllowBrokenMeasureSpecs) {
            if (params.height >= 0) {
                childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(
                        params.height, MeasureSpec.EXACTLY);
            } else {
                childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED);
            }
        } else {
            final int maxHeight;
            if (mMeasureVerticalWithPaddingMargin) {
                maxHeight = Math.max(0, myHeight - mPaddingTop - mPaddingBottom
                        - params.topMargin - params.bottomMargin);
            } else {
                maxHeight = Math.max(0, myHeight);
            }

            final int heightMode;
            if (params.height == LayoutParams.MATCH_PARENT) {
                heightMode = MeasureSpec.EXACTLY;
            } else {
                heightMode = MeasureSpec.AT_MOST;
            }
            childHeightMeasureSpec = MeasureSpec.makeMeasureSpec(maxHeight, heightMode);
        }

        child.measure(childWidthMeasureSpec, childHeightMeasureSpec);
    }
```

```java
    private boolean positionChildHorizontal(View child, LayoutParams params, int myWidth,
            boolean wrapContent) {

        final int layoutDirection = getLayoutDirection();
        int[] rules = params.getRules(layoutDirection);

        if (params.mLeft == VALUE_NOT_SET && params.mRight != VALUE_NOT_SET) {
            params.mLeft = params.mRight - child.getMeasuredWidth();
        } else if (params.mLeft != VALUE_NOT_SET && params.mRight == VALUE_NOT_SET) {
            params.mRight = params.mLeft + child.getMeasuredWidth();
        } else if (params.mLeft == VALUE_NOT_SET && params.mRight == VALUE_NOT_SET) {
            if (rules[CENTER_IN_PARENT] != 0 || rules[CENTER_HORIZONTAL] != 0) {
                if (!wrapContent) {
                    centerHorizontal(child, params, myWidth);
                } else {
                    params.mLeft = mPaddingLeft + params.leftMargin;
                    params.mRight = params.mLeft + child.getMeasuredWidth();
                }
                return true;
            } else {
                if (isLayoutRtl()) {
                    params.mRight = myWidth - mPaddingRight- params.rightMargin;
                    params.mLeft = params.mRight - child.getMeasuredWidth();
                } else {
                    params.mLeft = mPaddingLeft + params.leftMargin;
                    params.mRight = params.mLeft + child.getMeasuredWidth();
                }
            }
        }
        return rules[ALIGN_PARENT_END] != 0;
    }
```

- 2.第二次遍历所遇的子View，获取每一个子View的规则，根据这个规则测量每一个子View在竖直方向经过排列后，每一个View需要多少高度，并且确定上下两个方向的参数。此时横向已经测量过了，就能在这个循环中，根据对应方向是否是WRAP_CONTENT或者UNSPECIFIED。如果是，则说明RelativeLayout的父布局是允许RelativeLayout根据自己的内容宽高进行调整，不要超RelativeLayout的父布局即可。此时RelativeLayout的上下左右的位置则是由最左,最右,最上，最下边的子View位置以及margin竖直决定的。


- 3.第三个循环遍历，则是查找RelativeLayout中设置的baseline对应上的子View

- 4.第四个循环遍历，则是专门处理Xml布局中的ALIGN_PARENT_LEFT,ALIGN_PARENT_RIGHT,CENTER_IN_PARENT,CENTER_HORIZONTAL属性。这个属性可以让内容布局靠在最左，最右,居中三个位置。

如果是能看ALIGN_PARENT_RIGHT，到这个过程中实际上是一个逆推过程。因为上面的情况已经算出来了宽高，每一次迭代：
> 每一个子View的左边缘 = 已经算好的宽度 - mPaddingRight - 孩子的宽度
>  每一个子View的右边缘 = 计算好的左边缘 + 孩子的宽度。

这样就能让整个子View都移动到了整个View的右边。

- 5.第五个循环，专门处理CENTER_IN_PARENT，CENTER_VERTICAL，ALIGN_PARENT_BOTTOM三个方向。其运算原理和第四个循环一致。

- 6.当RelativeLayout设置了Gravity，则说明布局内容也要发生变化。此时会根据Gravity.apply方法，找到合适的整个RelativeLayout中合适的位置。并且计算出横竖方向的偏移量，把偏移量设置到每一个子View上。

- 7.如果是isLayoutRtl，也就是设置的布局顺序是从右到左这种特殊情况，则根据之前的计算出来的宽度和从RelativeLayout传下来的父布局的宽度，进行一次差值计算。就能直到需要往左边移动多少，并且分发给子View，让子View进行移动。


## 总结
到这里onMeasure就先到这里。按照老规矩，进行总结。

### 焦点分发和TouchMode的总结
在进行onMeasure之前，ViewRootImpl会进行一次处理InTouchMode，焦点判断以及分发。InTouchMode通过ViewRootImpl的enterTouchMode进入的。

- 1.首先通过View的findFocus，从View树中找到首个添加了PFLAG_FOCUSED标志位的View，也就是焦点View。

- 2.如果焦点View没有打开isFocusableInTouchMode标志位，通过findAncestorToTakeFocusInTouchMode方法找到焦点View的父布局，不断的向上遍历，直到找到打开isFocusableInTouchMode的父布局。这样就有了isFocusableInTouchMode的父布局以及焦点布局。

- 3.ViewGroup. requestFocus的方法中，开始处理android:descendantFocusability的三个参数：
参数|效果
-|-
beforeDescendants|viewgroup会优先其子类控件而获取到焦点
afterDescendants|viewgroup只有当其子类控件不需要获取焦点时才获取焦点
blocksDescendants|viewgroup会覆盖子类控件而直接获得焦点

其原理就是很简单就是根据当前的标签，是先调用子View的requestFocus还是父类的requestFocus。

- 4.requestFocus如果发现不可见;是inTouchMode并设置了focusableInTouchMode则拦截焦点的触发行为。换句话说focusableInTouchMode这个属性最好不要和焦点View放在一起，这样会造成点击事件的聚焦失效。关于这个问题已经有好几个人向我询问过来了。一问发现他们都设置了这个模式。

- 5.handleFocusGainInternal 处理所有焦点的行为，如切换焦点的Drawable，进行焦点变化的回调。


### onMeasure的总结
我在这一篇文章和大家聊了DecorView，FrameLayout，LinearLayout，RelativeLayout三个布局的原理。在上文能看到onMeasure有一个核心的对象贯穿测量上下文：
测量模式|解释
-|-
MeasureSpec.EXACTLY|精确模式，能够精确的指定View的大小
MeasureSpec.AT_MOST|最大模式，这个模式是不允许超过某一个设定的数值，一般是指子View不能超过父容器的大小。
MeasureSpec. UNSPECIFIED|无限制，这个模式下View的大小不受其他限制，仅仅由自己决定。

一般都是通过onMeasure的两个参数进行接受。而接受的就是该View的父容器中已经测量的大小和模式。注意不一定是最终，如果是AT_MOST模式还会根据子View测量反馈的结果进行适应处理。

并且根据对FrameLayout，LinearLayout，RelativeLayout三个布局的onMeasure原理进行浅析。就能明白，一般在开发过程中，MeasureSpec的模式会和当前子View的LayoutParams进行联合处理，才能获取真正的宽高。

核心方法可以看getChildMeasureSpec，在这里面决定了交给View的两个参数，一个是模式一个是大小：
大小计算如下：
>      int specMode = MeasureSpec.getMode(spec);
>       int specSize = MeasureSpec.getSize(spec);
>       int size = Math.max(0, specSize - padding);

接下来就要使用size参数在表格下面，注意这个size就是从父容器-(padding+maring)的大小让子View进行消费。

 当前View的LayoutParams\父容器测量|MeasureSpec.EXACTLY|MeasureSpec.AT_MOST|MeasureSpec. UNSPECIFIED
-|-|-|-
LayoutParams.width/height>0|size(EXACTLY)|size(EXACTLY)|size(EXACTLY)
LayoutParams.WRAP_CONTENT|size(AT_MOST)|size(AT_MOST)|低于6.0为0，大于等于6.0为size(UNSPECIFIED)
LayoutParams.MATCH_PARENT|size(EXACTLY)|size(AT_MOST)|低于6.0为0，大于等于6.0为size(UNSPECIFIED)

一句话总结，就是LayoutParams的宽高确定好宽高，传递给子View的测量结果就是精确模式；LayoutParams的模式是WRAP_CONTENT，除了UNSPECIFIED之外都是AT_MOST模式；LayoutParams的模式是MATCH_PARENT则是跟着父布局的模式走。

特殊的，如果是MeasureSpec. UNSPECIFIED，只有LayoutParams的宽高确定好宽高才是EXACTLY，其他都是UNSPECIFIED，同时大小以6.0为分割，低于为0，高于为size大小。

通过这种处理就能让View测量后的或者测量过程的结果，告诉子View 你还有多少空间可以消耗。

#### DecorView onMeasure
能看到DecorView测量流程实际上是获取ViewRootImpl中的下传对应的WindowFrame的大小进行消费，以及windowFixedWidthMinor等全局style资源比较获取横向竖向的屏幕大小，传递到父类FrameLayout进行测量。

#### FrameLayout onMeasure
FrameLayout最多经历两个子View的遍历。主要的工作是第一次的子View遍历。

第一次的子View遍历，就会为每一个子View进行宽高的宽高，并且给FrameLayout设置的宽高为最大子View。如果发现子View是Match_parent模式，且FrameLayout对应的父容器不是MeasureSpec.EXACTLY 模式。说明需要先决定FrameLayout之后才能决定子View的大小，而此时FrameLayout的大小需要这些子View决定大小。就会添加到mMatchParentChildren中等到第二次遍历处理。

第二次子View的遍历，就是等到FrameLayout测量好宽高之后，遍历这些子View，如果子View是LayoutParams.MATCH_PARENT，则设置FrameLayout的大小。否则通过getChildMeasureSpec进行测量。


#### LinearLayout onMeasure
LinearLayout最多经历4次子View的遍历。

- 1.第一次的子View遍历，主要是遍历那些没有设置weight权重的子View，在这个过程中，如果设置了weight，但是对应的宽或者高为0.说明这个View最后再测量，则打开skippedMeasure标志位，让后续再一次测量。如果不是，则直接让子View的measure方法进行测量，测量的结果直接累加。

- 2.第二次遍历，如果通过setMeasureWithLargestChildEnabled设置了LinearLayout，就会让所有的View拥有最大子View的宽高。

- 3.第三次遍历，分为两种情况。第一种情况就是为了处理weight的情况。因为经过上面2次遍历，基本确定了LinearLayout的宽高，此时就会根据每一个子View的weight占总weight的比例分配宽高。

第二种情况是指，如果使用了setMeasureWithLargestChildEnabled，同时不是精确模式。此时说明整个View的宽高需要再一次调整，就需要重新遍历子View累加宽高。

- 4.如果父容器宽度不是EXACTLY，且LinearLayout的宽度是MATCH_PARENT。最后还会通过forceUniformWidth进行处理一次宽度。因为之前的时候父容器不确定允许完全适配LinearLayout的宽度，但是LinearLayout此时还不确定，需要等到LinearLayout测量好之后，才能让正式的设置width。


### RelativeLayout onMeasure
RelativeLayout大致经历了7次子View的遍历(同时带上了一点onLayout的逻辑)：
- 1.第一次遍历和第二次遍历所有的子View，获取每一个View所携带的Relativelayout中特有的规则，如谁在谁的左边等。并根据这些规则测量每一个子View经过排列后，测定每一个View需要多少宽度，需要多少高度。

- 2.第三次遍历，则是测定baseline的位置。

- 3.第四个和第五个循环遍历，则是专门处理Xml布局中的ALIGN_xxx属性。这个属性可以让内容布局靠在最左，最右,居中,最上，最下五个位置的布局移动。

- 4.第六次循环遍历，则是处理设置了Gravity之后，每一个子View的偏移量。

- 5.第七次遍历，则是检测是否开启了一些特殊地区从右到左阅读的习惯模式，从新计算每一个子View的位置。


为什么我要拿出这几个比较呢？因为也是有人问过我FrameLayout，LinearLayout，RelativeLayout三个基础布局之间的性能区别。我们从onMeasure上来看，就以遍历子View的规模来比较，虽然都是O(N)级别的规模。但是细究对应的规模，FrameLayout做的事情最少(2次遍历)，LinearLayout(4次遍历)其次，RelativeLayout最多(7次遍历)。

当然该用的时候还是使用，老实说，我们普通开发的布局，能上20层除了首页之外也很少见，就算是这个级别性能也不会表现的太拉垮。

当然如果是首页这种追求极致的渲染体验要求，这个层数的布局无疑是失败的。我们需要使用一个利器ConstraintLayout对布局的扁平化处理。我前几年的时候在开发iOS时候，就像过为什么Android没有一个布局逻辑和iOS里面的相似呢？可以根据View之间的边缘决定位置和大小呢？果然没多久就有ConstraintLayout的诞生了。这个利器可以让七八层甚至数十层的布局压缩层位一个级别的View中。这样就能减少onMeasure和onLayout的次数了。


那么onMeasure相关的知识就到这里了，之后来阅读onLayout方法。