---
title: Android 重学系列 WMS在Activity启动中的职责 计算窗体的大小(四)
top: false
cover: false
date: 2019-09-26 08:31:16
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
通过启动窗口为例子，大致上明白了WMS是如何添加，更新，移除窗口的工作原理。本文将会重点聊一聊窗口的大小计算逻辑。

下面的源码都是来自Android 9.0

# 正文

## 窗口大小计算
计算窗口的大小和Android 4.4相比变化很大。花了一点心思去重新学习了。在Android 4.4中,窗体的计算在onResume中调用了ViewRootImpl调用relayoutWindow对整个Window重新测量窗口大小以及边距。

relayoutWindow这个方法是做什么的呢？当我们在Activity的生命周期到达了onResume的阶段，此时ViewRootImpl的setView，开始走渲染的View的流程，并且调用requestLayout开始测量渲染。其中有一个核心的逻辑就是调用WMS的relayoutWindow，重新测量Window。

在Android 9.0中把这个流程和DisplayContent绑定起来。让我们稍微解剖一下这个方法。

### relayout
```java
  public int relayoutWindow(Session session, IWindow client, int seq, LayoutParams attrs,
            int requestedWidth, int requestedHeight, int viewVisibility, int flags,
            long frameNumber, Rect outFrame, Rect outOverscanInsets, Rect outContentInsets,
            Rect outVisibleInsets, Rect outStableInsets, Rect outOutsets, Rect outBackdropFrame,
            DisplayCutout.ParcelableWrapper outCutout, MergedConfiguration mergedConfiguration,
            Surface outSurface) {
        int result = 0;
        boolean configChanged;
        final boolean hasStatusBarPermission =
                mContext.checkCallingOrSelfPermission(permission.STATUS_BAR)
                        == PackageManager.PERMISSION_GRANTED;
        final boolean hasStatusBarServicePermission =
                mContext.checkCallingOrSelfPermission(permission.STATUS_BAR_SERVICE)
                        == PackageManager.PERMISSION_GRANTED;

        long origId = Binder.clearCallingIdentity();
        final int displayId;
        synchronized(mWindowMap) {
            WindowState win = windowForClientLocked(session, client, false);
            if (win == null) {
                return 0;
            }
            displayId = win.getDisplayId();

      ....
       
            mWindowPlacerLocked.performSurfacePlacement(true /* force */);

            if (shouldRelayout) {
                result = win.relayoutVisibleWindow(result, attrChanges, oldVisibility);

                try {
                    result = createSurfaceControl(outSurface, result, win, winAnimator);
                } catch (Exception e) {
                    mInputMonitor.updateInputWindowsLw(true /*force*/);
                    Binder.restoreCallingIdentity(origId);
                    return 0;
                }
                if ((result & WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME) != 0) {
                    focusMayChange = isDefaultDisplay;
                }
                if (win.mAttrs.type == TYPE_INPUT_METHOD && mInputMethodWindow == null) {
                    setInputMethodWindowLocked(win);
                    imMayMove = true;
                }
                win.adjustStartingWindowFlags();
                Trace.traceEnd(TRACE_TAG_WINDOW_MANAGER);
            } else {
...
            }

            if (focusMayChange) {
                if (updateFocusedWindowLocked(UPDATE_FOCUS_WILL_PLACE_SURFACES,
                        false /*updateInputWindows*/)) {
                    imMayMove = false;
                }
            }

            boolean toBeDisplayed = (result & WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME) != 0;
            final DisplayContent dc = win.getDisplayContent();
            if (imMayMove) {
                dc.computeImeTarget(true /* updateImeTarget */);
                if (toBeDisplayed) {
                    dc.assignWindowLayers(false /* setLayoutNeeded */);
                }
            }

...

            outFrame.set(win.mCompatFrame);
            outOverscanInsets.set(win.mOverscanInsets);
            outContentInsets.set(win.mContentInsets);
            win.mLastRelayoutContentInsets.set(win.mContentInsets);
            outVisibleInsets.set(win.mVisibleInsets);
            outStableInsets.set(win.mStableInsets);
            outCutout.set(win.mDisplayCutout.getDisplayCutout());
            outOutsets.set(win.mOutsets);
            outBackdropFrame.set(win.getBackdropFrame(win.mFrame));

            result |= mInTouchMode ? WindowManagerGlobal.RELAYOUT_RES_IN_TOUCH_MODE : 0;

            mInputMonitor.updateInputWindowsLw(true /*force*/);

            win.mInRelayout = false;
        }
...
        Binder.restoreCallingIdentity(origId);
        return result;
    }
```
relayout大致上要做了以下的事情:
- 1.通过IWindow找到对应的WindowState，并且获取各种参数。
- 2.WindowPlacerLocked.performSurfacePlacement为Surface交互做准备。
- 3.创建Surface对象，开始和SurfaceFlinger做交互。
- 4.updateFocusedWindowLocked Window发生变化则会尝试着重新计算窗体大小的区域
- 5.计算层级，设置窗体的各种边距。

relayout的方法有点长，本次我们将关注这一部分核心的逻辑。分别是两个方法：
- 1.mWindowPlacerLocked.performSurfacePlacement 当窗体出现了变更，需要重新设置DisplayContent的各种参数,销毁不用的Surface，重新计算层级，计算触点区域等等

- 2.updateFocusedWindowLocked 当发现Window可能发生变化，则重新计算窗口大小。


#### WindowPlacerLocked.performSurfacePlacement
```java
    final void performSurfacePlacement(boolean force) {
        if (mDeferDepth > 0 && !force) {
            return;
        }
        int loopCount = 6;
        do {
            mTraversalScheduled = false;
            performSurfacePlacementLoop();
            mService.mAnimationHandler.removeCallbacks(mPerformSurfacePlacement);
            loopCount--;
        } while (mTraversalScheduled && loopCount > 0);
        mService.mRoot.mWallpaperActionPending = false;
    }
```
能看到在这里面对performSurfacePlacementLoop做最多为6次的循环,这六次循环做什么呢？

```
private void performSurfacePlacementLoop() {
        ...
        mInLayout = true;

        boolean recoveringMemory = false;
        if (!mService.mForceRemoves.isEmpty()) {
            recoveringMemory = true;
            while (!mService.mForceRemoves.isEmpty()) {
                final WindowState ws = mService.mForceRemoves.remove(0);
                ws.removeImmediately();
            }
            Object tmp = new Object();
            synchronized (tmp) {
                try {
                    tmp.wait(250);
                } catch (InterruptedException e) {
                }
            }
        }

        try {
            mService.mRoot.performSurfacePlacement(recoveringMemory);

            mInLayout = false;

            if (mService.mRoot.isLayoutNeeded()) {
                if (++mLayoutRepeatCount < 6) {
                    requestTraversal();
                } else {
                    Slog.e(TAG, "Performed 6 layouts in a row. Skipping");
                    mLayoutRepeatCount = 0;
                }
            } else {
                mLayoutRepeatCount = 0;
            }

            if (mService.mWindowsChanged && !mService.mWindowChangeListeners.isEmpty()) {
                mService.mH.removeMessages(REPORT_WINDOWS_CHANGE);
                mService.mH.sendEmptyMessage(REPORT_WINDOWS_CHANGE);
            }
        } catch (RuntimeException e) {
            mInLayout = false;
        }
    }
```
能看到这里面的核心逻辑，首先会检查WMS下mForceRemoves集合中是否还有对象。有则调用removeImmediately清空WindowState的中SurfaceControl和WindowContainer之间的绑定和Surface对象，以及销毁WindowAnimator中的Surface。

做这个得到目的很简单，因为下一个步骤将会申请一个Surface对象，而此时如果Android系统内存过大了(OOM)，mForceRemoves就存在对象，就可以销毁不需要的Surface。这一点的设计和Davlik虚拟机申请对象时候的思路倒是一致的。

销毁需要一点时间，因此就需要做一个250毫秒的的等待。接着会调用RootWindowContainer的performSurfacePlacement做真正的执行。最后会通过handler通过ViewServer通知事件给DebugBridge调试类中。

每一次loop的最后，如果发现RootWindowContainer需要重新测量，就会把当前这个方法，放入Handler中，等待下次的调用，也是调用6次。这样就能最大限度的保证在这段时间内Window能够测量每一次的窗体参数。

### RootWindowContainer.performSurfacePlacement
下面这个方法十分长，我们只看核心;
```java
   void performSurfacePlacement(boolean recoveringMemory) {


        int i;
        boolean updateInputWindowsNeeded = false;
//核心事件1
        if (mService.mFocusMayChange) {
            mService.mFocusMayChange = false;
            updateInputWindowsNeeded = mService.updateFocusedWindowLocked(
                    UPDATE_FOCUS_WILL_PLACE_SURFACES, false /*updateInputWindows*/);
        }

        // 核心事件2
        final int numDisplays = mChildren.size();
        for (int displayNdx = 0; displayNdx < numDisplays; ++displayNdx) {
            final DisplayContent displayContent = mChildren.get(displayNdx);
            displayContent.setExitingTokensHasVisible(false);
        }

        mHoldScreen = null;
...
        final DisplayInfo defaultInfo = defaultDisplay.getDisplayInfo();
        final int defaultDw = defaultInfo.logicalWidth;
        final int defaultDh = defaultInfo.logicalHeight;

...

        final WindowSurfacePlacer surfacePlacer = mService.mWindowPlacerLocked;

        // 核心事件3
        if (mService.mAppTransition.isReady()) {
            final int layoutChanges = surfacePlacer.handleAppTransitionReadyLocked();
            defaultDisplay.pendingLayoutChanges |= layoutChanges;
            if (DEBUG_LAYOUT_REPEATS)
                surfacePlacer.debugLayoutRepeats("after handleAppTransitionReadyLocked",
                        defaultDisplay.pendingLayoutChanges);
        }

        if (!isAppAnimating() && mService.mAppTransition.isRunning()) {
            defaultDisplay.pendingLayoutChanges |=
                    mService.handleAnimatingStoppedAndTransitionLocked();
        }

        // 核心事件4
        final RecentsAnimationController recentsAnimationController =
            mService.getRecentsAnimationController();
        if (recentsAnimationController != null) {
            recentsAnimationController.checkAnimationReady(mWallpaperController);
        }

        if (mWallpaperForceHidingChanged && defaultDisplay.pendingLayoutChanges == 0
                && !mService.mAppTransition.isReady()) {
            defaultDisplay.pendingLayoutChanges |= FINISH_LAYOUT_REDO_LAYOUT;
        }
        mWallpaperForceHidingChanged = false;

...
        if (mService.mFocusMayChange) {
            mService.mFocusMayChange = false;
            if (mService.updateFocusedWindowLocked(UPDATE_FOCUS_PLACING_SURFACES,
                    false /*updateInputWindows*/)) {
                updateInputWindowsNeeded = true;
                defaultDisplay.pendingLayoutChanges |= FINISH_LAYOUT_REDO_ANIM;
            }
        }

...
        final ArraySet<DisplayContent> touchExcludeRegionUpdateDisplays = handleResizingWindows();

....
        // 核心事件5
        boolean wallpaperDestroyed = false;
        i = mService.mDestroySurface.size();
        if (i > 0) {
            do {
                i--;
                WindowState win = mService.mDestroySurface.get(i);
                win.mDestroying = false;
                if (mService.mInputMethodWindow == win) {
                    mService.setInputMethodWindowLocked(null);
                }
                if (win.getDisplayContent().mWallpaperController.isWallpaperTarget(win)) {
                    wallpaperDestroyed = true;
                }
                win.destroySurfaceUnchecked();
                win.mWinAnimator.destroyPreservedSurfaceLocked();
            } while (i > 0);
            mService.mDestroySurface.clear();
        }

...

        // 核心事件6
        mService.mInputMonitor.updateInputWindowsLw(true /*force*/);

        mService.setHoldScreenLocked(mHoldScreen);
...

        if (mSustainedPerformanceModeCurrent != mSustainedPerformanceModeEnabled) {
            mSustainedPerformanceModeEnabled = mSustainedPerformanceModeCurrent;
            mService.mPowerManagerInternal.powerHint(
                    PowerHint.SUSTAINED_PERFORMANCE,
                    (mSustainedPerformanceModeEnabled ? 1 : 0));
        }

....

//事件7
        final int N = mService.mPendingRemove.size();
        if (N > 0) {
            if (mService.mPendingRemoveTmp.length < N) {
                mService.mPendingRemoveTmp = new WindowState[N+10];
            }
            mService.mPendingRemove.toArray(mService.mPendingRemoveTmp);
            mService.mPendingRemove.clear();
            ArrayList<DisplayContent> displayList = new ArrayList();
            for (i = 0; i < N; i++) {
                final WindowState w = mService.mPendingRemoveTmp[i];
                w.removeImmediately();
                final DisplayContent displayContent = w.getDisplayContent();
                if (displayContent != null && !displayList.contains(displayContent)) {
                    displayList.add(displayContent);
                }
            }

            for (int j = displayList.size() - 1; j >= 0; --j) {
                final DisplayContent dc = displayList.get(j);
                dc.assignWindowLayers(true /*setLayoutNeeded*/);
            }
        }

        // 事件8
        for (int displayNdx = mChildren.size() - 1; displayNdx >= 0; --displayNdx) {
            mChildren.get(displayNdx).checkCompleteDeferredRemoval();
        }

        if (updateInputWindowsNeeded) {
            mService.mInputMonitor.updateInputWindowsLw(false /*force*/);
        }
        mService.setFocusTaskRegionLocked(null);
        if (touchExcludeRegionUpdateDisplays != null) {
            final DisplayContent focusedDc = mService.mFocusedApp != null
                    ? mService.mFocusedApp.getDisplayContent() : null;
            for (DisplayContent dc : touchExcludeRegionUpdateDisplays) {
                if (focusedDc != dc) {
                    dc.setTouchExcludeRegion(null /* focusedTask */);
                }
            }
        }

        // 核心事件9
        mService.enableScreenIfNeededLocked();

        mService.scheduleAnimationLocked();

    }
```
我在上面划分了9个部分：
- 1.如果WMS发现当前的焦点Window发生了改变，则会调用updateFocusedWindowLocked重新测量窗口大小。
- 2.设置所有即将推出的WindowToken为不可见的标志位。
- 3.执行App transition(窗体动画)的时候，检测所有的窗体都可见。接着我们需要自然的完成我们的窗体动画，此时还没有真正的把视图绘制到屏幕上，因此为了实现这个事情，就需要推迟很多操作。如显示隐藏程序，按照z轴摆列窗体等等，因此需要重新建立Window的层级。
- 4.推迟壁纸的绘制。
- 5.清除需要销毁的Surface
- 6.更新触点事件的范围
- 7.清除掉那些当动画结束之后，需要推迟清除的Surface，接着重新对层级进行排序
- 8.更新触点事件策略，并且更新触点事件范围(这个会有专门的输入系统专栏和大家聊聊)
- 9.执行窗体动画

这里只给总览，之后有机会再进去里面抓细节。

### WMS.updateFocusedWindowLocked

我们能够看到无论是在哪里，如果窗口发生了变化，都会调用updateFocusedWindowLocked方法。实际上这个方法才是真正的核心测量窗口大小逻辑。
```java
boolean updateFocusedWindowLocked(int mode, boolean updateInputWindows) {
        WindowState newFocus = mRoot.computeFocusedWindow();
        if (mCurrentFocus != newFocus) {
...
            final DisplayContent displayContent = getDefaultDisplayContentLocked();
            boolean imWindowChanged = false;
            if (mInputMethodWindow != null) {
                final WindowState prevTarget = mInputMethodTarget;
                final WindowState newTarget =
                        displayContent.computeImeTarget(true /* updateImeTarget*/);

                imWindowChanged = prevTarget != newTarget;

                if (mode != UPDATE_FOCUS_WILL_ASSIGN_LAYERS
                        && mode != UPDATE_FOCUS_WILL_PLACE_SURFACES) {
                    final int prevImeAnimLayer = mInputMethodWindow.mWinAnimator.mAnimLayer;
                    displayContent.assignWindowLayers(false /* setLayoutNeeded */);
                    imWindowChanged |=
                            prevImeAnimLayer != mInputMethodWindow.mWinAnimator.mAnimLayer;
                }
            }

            if (imWindowChanged) {
                mWindowsChanged = true;
                displayContent.setLayoutNeeded();
                newFocus = mRoot.computeFocusedWindow();
            }

...
            int focusChanged = mPolicy.focusChangedLw(oldFocus, newFocus);

            if (imWindowChanged && oldFocus != mInputMethodWindow) {

                if (mode == UPDATE_FOCUS_PLACING_SURFACES) {
                    displayContent.performLayout(true /*initial*/,  updateInputWindows);
                    focusChanged &= ~FINISH_LAYOUT_REDO_LAYOUT;
                } else if (mode == UPDATE_FOCUS_WILL_PLACE_SURFACES) {
                    displayContent.assignWindowLayers(false /* setLayoutNeeded */);
                }
            }

            if ((focusChanged & FINISH_LAYOUT_REDO_LAYOUT) != 0) {
                displayContent.setLayoutNeeded();
                if (mode == UPDATE_FOCUS_PLACING_SURFACES) {
                    displayContent.performLayout(true /*initial*/, updateInputWindows);
                }
            }

            if (mode != UPDATE_FOCUS_WILL_ASSIGN_LAYERS) {
                mInputMonitor.setInputFocusLw(mCurrentFocus, updateInputWindows);
            }
...
            return true;
        }
        return false;
    }

```
这里注意一下isWindowChange是判断输入法焦点是否一致，而窗体焦点则是通过不同的WindowState来判断。

- 1.首先如果发现有输入法弹窗则重新计算层级，或者说如果输入法焦点窗口发生变化，也要从RootWindowContainer找到当前的焦点窗口。
- 2.如果输入法焦点出现了变化，且当前的模式是UPDATE_FOCUS_PLACING_SURFACES(需要强制重绘）则要重新计算窗体大小，否则则直接做一次层级变化即可。
- 3. 一般的情况下，如果UPDATE_FOCUS_PLACING_SURFACES这个模式，则需要performLayout重新测量窗体各个边距大小
- 4.不是UPDATE_FOCUS_WILL_ASSIGN_LAYERS模式，则则需要处理触点焦点边距。


实际上核心测量的真正动作是DisplayContent.performLayout。我们仔细一想也就知道，在Android 9.0的时候，DisplayContent象征着逻辑屏幕，我们讨论无分屏的情况，实际上就是指我们当前窗体铺满逻辑显示屏各个边距的大小。

### 窗体边距的类型
在正式开始聊窗体大小的测量之前，实际上，在Android系统中，为了把Window各个边界标记出来，实际上随着时代和审美潮流的演进，诞生越来越多的边距类型，我们往往可以通过这些边距来测定窗体的大小。

在DisplayFrame中有了大致的分区，如下：
type|描述
-|-
mOverScan|带有这个前后缀的边距名字代表着过扫描。过扫描是什么东西？实际上在我们在自己看自己的手机屏幕，会发现手机屏幕显示范围并未铺满全屏，而是留有一点黑色的边框。而这个黑色的部分就是就是过扫描区域。原因是如果把显示范围铺面全屏，如电视机之类的屏幕会导致失真。![过扫描区域.png](https://upload-images.jianshu.io/upload_images/9880421-f65560e20ea010f9.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
mOverScanScreen|代表着显示屏真实宽高，是带上了过扫描的边距范围 ![image.png](https://upload-images.jianshu.io/upload_images/9880421-0bcceffbcad4259f.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
mRestrictedOverscan|类似OverScanScreen，适当的时候允许移动到OverScanScreen中
mUnrestricted| 真实屏幕大小，但是不包含OverScan区域
mRestricted | 当前屏幕大小;如果状态栏无法隐藏，则这些值可能不同于(0,0)-(dw,dh);在这种情况下，它有效地将显示区域从所有其他窗口分割出来。
mSystem | 在布局期间，所有可见的SysytemUI元素区域
mStable | 稳定不变的应用内容区域
mStableFullscreen | 对于稳定不变的应用区域，但是这个Window是添加了FullScreen标志，这是除了StatusBar以外的区域
mCurrent | 在布局期间，当前屏幕且带上键盘，状态栏的区域(虽然不好理解，但是如果是分屏和自由窗口模式就好理解了）
mContent | 布局期间，向用户展示内容的所有区域，包括所有的外部装饰如状态来和键盘，一般和mCurrent一样，除非使用了嵌套模式，则会比mCurrent更大。
mVoiceContent | 布局期间，我们声量变化时候的系统区域
mDock | 输入法窗体区域
mDisplayCutout | 刘海屏上面那一块的区域
mDisplayCutoutSafe | 刘海屏不允许使用交叉部分![image.png](https://upload-images.jianshu.io/upload_images/9880421-3ff87b8dc4df7127.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


可以看到，这些窗体的边距实际上是跟着这些年潮流走的。如Android 7.0的自由窗体模式，嵌套窗体模式，刘海屏等等，这些边距的共同作用，才会诞生一个真正的Window大小。有了这些基础知识之后，我们去看看测量大小的逻辑。


### DisplayContent.performLayout
```java
    void performLayout(boolean initial, boolean updateInputWindows) {
        if (!isLayoutNeeded()) {
            return;
        }
        clearLayoutNeeded();

        final int dw = mDisplayInfo.logicalWidth;
        final int dh = mDisplayInfo.logicalHeight;

        mDisplayFrames.onDisplayInfoUpdated(mDisplayInfo,
                calculateDisplayCutoutForRotation(mDisplayInfo.rotation));
        mDisplayFrames.mRotation = mRotation;
        mService.mPolicy.beginLayoutLw(mDisplayFrames, getConfiguration().uiMode);
        if (isDefaultDisplay) {
            mService.mSystemDecorLayer = mService.mPolicy.getSystemDecorLayerLw();
            mService.mScreenRect.set(0, 0, dw, dh);
        }

        int seq = mLayoutSeq + 1;
        if (seq < 0) seq = 0;
        mLayoutSeq = seq;

        mTmpWindow = null;
        mTmpInitial = initial;

        // 首先测量那些没有绑定父窗口的窗口
        forAllWindows(mPerformLayout, true /* traverseTopToBottom */);
...
       //测量那些绑定了父窗口的窗口
        forAllWindows(mPerformLayoutAttached, true /* traverseTopToBottom */);
...
    }
```
我们这里把这个方法拆成如下几个部分：
- 设置DisplayFrame
- beginLayoutLw开始测量
- 测量那些没有绑定父窗口的窗口
- 测量那些绑定了父窗口的窗口

### 设置DisplayFrame
```java
    public void onDisplayInfoUpdated(DisplayInfo info, WmDisplayCutout displayCutout) {
        mDisplayWidth = info.logicalWidth;
        mDisplayHeight = info.logicalHeight;
        mRotation = info.rotation;
        mDisplayInfoOverscan.set(
                info.overscanLeft, info.overscanTop, info.overscanRight, info.overscanBottom);
        mDisplayInfoCutout = displayCutout != null ? displayCutout : WmDisplayCutout.NO_CUTOUT;
    }
```
能看到，此时会设置当前显示屏幕的大小，以及获取过扫描区域，还会判断当前手机屏幕是否支持刘海屏。这一切实际上都是由硬件回馈到DisplayService，我们再从中获取的信息。

#### PhoneWindowManager.beginLayoutLw开始测量大小与边距
实际上如果有读者注意到我写的WMS第一篇就会看到实际上WMS初始化的时候，我们能够看到WMS会初始化一个WindowManagerPolicy的策略，而这个策略就是PhoneWindowManager。实际上这也支持了系统开发自定义策略，从而办到自己想要的窗体计算结果。

```java
public void beginLayoutLw(DisplayFrames displayFrames, int uiMode) {
        displayFrames.onBeginLayout();
        mSystemGestures.screenWidth = displayFrames.mUnrestricted.width();
        mSystemGestures.screenHeight = displayFrames.mUnrestricted.height();
        mDockLayer = 0x10000000;
        mStatusBarLayer = -1;

        // start with the current dock rect, which will be (0,0,displayWidth,displayHeight)
        final Rect pf = mTmpParentFrame; //父窗口大小
        final Rect df = mTmpDisplayFrame; //显示屏大小
        final Rect of = mTmpOverscanFrame;//过扫描大小
        final Rect vf = mTmpVisibleFrame;//可见区域大小
        final Rect dcf = mTmpDecorFrame;//输入法大小
        vf.set(displayFrames.mDock);
        of.set(displayFrames.mDock);
        df.set(displayFrames.mDock);
        pf.set(displayFrames.mDock);
        dcf.setEmpty();  // Decor frame N/A for system bars.

        if (displayFrames.mDisplayId == DEFAULT_DISPLAY) {
            final int sysui = mLastSystemUiFlags;
            boolean navVisible = (sysui & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0;
            boolean navTranslucent = (sysui
                    & (View.NAVIGATION_BAR_TRANSLUCENT | View.NAVIGATION_BAR_TRANSPARENT)) != 0;
            boolean immersive = (sysui & View.SYSTEM_UI_FLAG_IMMERSIVE) != 0;
            boolean immersiveSticky = (sysui & View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY) != 0;
            boolean navAllowedHidden = immersive || immersiveSticky;
            navTranslucent &= !immersiveSticky;  // transient trumps translucent
            boolean isKeyguardShowing = isStatusBarKeyguard() && !mKeyguardOccluded;
            if (!isKeyguardShowing) {
                navTranslucent &= areTranslucentBarsAllowed();
            }
            boolean statusBarExpandedNotKeyguard = !isKeyguardShowing && mStatusBar != null
                    && mStatusBar.getAttrs().height == MATCH_PARENT
                    && mStatusBar.getAttrs().width == MATCH_PARENT;
...
            navVisible |= !canHideNavigationBar();

            boolean updateSysUiVisibility = layoutNavigationBar(displayFrames, uiMode, dcf,
                    navVisible, navTranslucent, navAllowedHidden, statusBarExpandedNotKeyguard);
            updateSysUiVisibility |= layoutStatusBar(
                    displayFrames, pf, df, of, vf, dcf, sysui, isKeyguardShowing);
            if (updateSysUiVisibility) {
                updateSystemUiVisibilityLw();
            }
        }
        layoutScreenDecorWindows(displayFrames, pf, df, dcf);

        if (displayFrames.mDisplayCutoutSafe.top > displayFrames.mUnrestricted.top) {
            displayFrames.mDisplayCutoutSafe.top = Math.max(displayFrames.mDisplayCutoutSafe.top,
                    displayFrames.mStable.top);
        }
    }
```
首先初始化几个参数，父窗体，屏幕，过扫描，可见区域，输入法区域为当前逻辑显示屏的大小，等到后面做裁剪。

能看到所有的事情实际上是关注的是系统UI上的判断，检测NavBar，StatusBar大小。最后再判断当前刘海屏的不允许交叉的区域顶部和显示屏顶部哪个大。如果mDisplayCutoutSafe的top大于mUnrestricted的top，说明mDisplayCutoutSafe在mUnrestricted下面，也就是我上面那个包含一段黑色的区域。此时会拿稳定的应用区域和刘海区域顶部的最大值，作为刘海屏幕的区域。这样就能保证刘海屏的顶部就是状态栏。

提一句如果NavigationBar隐藏，则会创建一个虚假的区域把输入事件都捕捉起来。

里面有四个关键函数：
- 函数onBeginLayout，初始化了所有边距值
- layoutNavigationBar ,测量NavigationBar
- layoutStatusBar 测量layoutStatusBar
- layoutScreenDecorWindows 测量所有装饰窗口

#### DisplayFrame.onBeginLayout
```java
    public void onBeginLayout() {
        switch (mRotation) {
            case ROTATION_90:
...
                break;
            case ROTATION_180:
...
                break;
            case ROTATION_270:
...
                break;
            default:
                mRotatedDisplayInfoOverscan.set(mDisplayInfoOverscan);
                break;
        }

        mRestrictedOverscan.set(0, 0, mDisplayWidth, mDisplayHeight);
        mOverscan.set(mRestrictedOverscan);
        mSystem.set(mRestrictedOverscan);
        mUnrestricted.set(mRotatedDisplayInfoOverscan);
        mUnrestricted.right = mDisplayWidth - mUnrestricted.right;
        mUnrestricted.bottom = mDisplayHeight - mUnrestricted.bottom;
        mRestricted.set(mUnrestricted);
        mDock.set(mUnrestricted);
        mContent.set(mUnrestricted);
        mVoiceContent.set(mUnrestricted);
        mStable.set(mUnrestricted);
        mStableFullscreen.set(mUnrestricted);
        mCurrent.set(mUnrestricted);

        mDisplayCutout = mDisplayInfoCutout;
        mDisplayCutoutSafe.set(Integer.MIN_VALUE, Integer.MIN_VALUE,
                Integer.MAX_VALUE, Integer.MAX_VALUE);
        if (!mDisplayCutout.getDisplayCutout().isEmpty()) {
            final DisplayCutout c = mDisplayCutout.getDisplayCutout();
            if (c.getSafeInsetLeft() > 0) {
                mDisplayCutoutSafe.left = mRestrictedOverscan.left + c.getSafeInsetLeft();
            }
            if (c.getSafeInsetTop() > 0) {
                mDisplayCutoutSafe.top = mRestrictedOverscan.top + c.getSafeInsetTop();
            }
            if (c.getSafeInsetRight() > 0) {
                mDisplayCutoutSafe.right = mRestrictedOverscan.right - c.getSafeInsetRight();
            }
            if (c.getSafeInsetBottom() > 0) {
                mDisplayCutoutSafe.bottom = mRestrictedOverscan.bottom - c.getSafeInsetBottom();
            }
        }
    }
```
可以看到所有的所有的间距将会设置为mUnrestricted的初始宽高，也就是不包含OverScan区域。如果是遇到刘海屏，则会根据设置的SafeInset区域来设置mDisplayCutoutSafe的安全区域。也就是我上面那种情况。比如设置了LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT这种情况，显示区域将不会超过刘海屏的底部。


#### layoutNavigationBar测量NavigationBar
```java
    private boolean layoutNavigationBar(DisplayFrames displayFrames, int uiMode, Rect dcf,
            boolean navVisible, boolean navTranslucent, boolean navAllowedHidden,
            boolean statusBarExpandedNotKeyguard) {
        if (mNavigationBar == null) {
            return false;
        }
        boolean transientNavBarShowing = mNavigationBarController.isTransientShowing();

        final int rotation = displayFrames.mRotation;
        final int displayHeight = displayFrames.mDisplayHeight;
        final int displayWidth = displayFrames.mDisplayWidth;
        final Rect dockFrame = displayFrames.mDock;
        mNavigationBarPosition = navigationBarPosition(displayWidth, displayHeight, rotation);

        final Rect cutoutSafeUnrestricted = mTmpRect;
        cutoutSafeUnrestricted.set(displayFrames.mUnrestricted);
        cutoutSafeUnrestricted.intersectUnchecked(displayFrames.mDisplayCutoutSafe);

        if (mNavigationBarPosition == NAV_BAR_BOTTOM) {
            final int top = cutoutSafeUnrestricted.bottom
                    - getNavigationBarHeight(rotation, uiMode);
            mTmpNavigationFrame.set(0, top, displayWidth, displayFrames.mUnrestricted.bottom);
            displayFrames.mStable.bottom = displayFrames.mStableFullscreen.bottom = top;
....
            if (navVisible && !navTranslucent && !navAllowedHidden
                    && !mNavigationBar.isAnimatingLw()
                    && !mNavigationBarController.wasRecentlyTranslucent()) {

                displayFrames.mSystem.bottom = top;
            }
        }
//不关注旋转后的测量
....

        displayFrames.mCurrent.set(dockFrame);
        displayFrames.mVoiceContent.set(dockFrame);
        displayFrames.mContent.set(dockFrame);
        mStatusBarLayer = mNavigationBar.getSurfaceLayer();

        mNavigationBar.computeFrameLw(mTmpNavigationFrame, mTmpNavigationFrame,
                mTmpNavigationFrame, displayFrames.mDisplayCutoutSafe, mTmpNavigationFrame, dcf,
                mTmpNavigationFrame, displayFrames.mDisplayCutoutSafe,
                displayFrames.mDisplayCutout, false /* parentFrameWasClippedByDisplayCutout */);
        mNavigationBarController.setContentFrame(mNavigationBar.getContentFrameLw());

        return mNavigationBarController.checkHiddenLw();
    }
```
我们关注到mTmpNavigationFrame这个对象的赋值，在正常的情况下的范围是如下：
> left: 0
top:刘海屏的安全区 - Navigation高度(也就是刘海屏幕的安全区向上移动Navigation高度)
right：displayWidth(屏幕宽度)
bottom: mUnrestricted(不包含过扫描区域的底部)

此时mStable和mStableFullscreen区域的底部都是对应着top，也就是对应着Navigation顶部。System系统元素的底部也是Navigation顶部。

最后经过computeFrameLw重新计算这个区域的值。这个方法稍后会聊到，但是在正常手机开发中，其实是没有变化的。也就说，实际上对于mNavigationBar来说:
> 可见区域，过扫描区域，内容区域，Dock区域：mTmpNavigationFrame
过扫描区域，稳定区域，刘海裁剪安全区:displayFrames.mDisplayCutoutSafe

#### layoutStatusBar 测量layoutStatusBar
```java
    private boolean layoutStatusBar(DisplayFrames displayFrames, Rect pf, Rect df, Rect of, Rect vf,
            Rect dcf, int sysui, boolean isKeyguardShowing) {
        // decide where the status bar goes ahead of time
        if (mStatusBar == null) {
            return false;
        }
        of.set(displayFrames.mUnrestricted);
        df.set(displayFrames.mUnrestricted);
        pf.set(displayFrames.mUnrestricted);
        vf.set(displayFrames.mStable);

        mStatusBarLayer = mStatusBar.getSurfaceLayer();
size.
        mStatusBar.computeFrameLw(pf /* parentFrame */, df /* displayFrame */,
                vf /* overlayFrame */, vf /* contentFrame */, vf /* visibleFrame */,
                dcf /* decorFrame */, vf /* stableFrame */, vf /* outsetFrame */,
                displayFrames.mDisplayCutout, false /* parentFrameWasClippedByDisplayCutout */);

        displayFrames.mStable.top = displayFrames.mUnrestricted.top
                + mStatusBarHeightForRotation[displayFrames.mRotation];
        displayFrames.mStable.top = Math.max(displayFrames.mStable.top,
                displayFrames.mDisplayCutoutSafe.top);

...
        mStatusBarController.setContentFrame(mTmpRect);

...
        if (mStatusBar.isVisibleLw() && !statusBarTransient) {
            final Rect dockFrame = displayFrames.mDock;
            dockFrame.top = displayFrames.mStable.top;
            displayFrames.mContent.set(dockFrame);
            displayFrames.mVoiceContent.set(dockFrame);
            displayFrames.mCurrent.set(dockFrame);


            if (!mStatusBar.isAnimatingLw() && !statusBarTranslucent
                    && !mStatusBarController.wasRecentlyTranslucent()) {
                displayFrames.mSystem.top = displayFrames.mStable.top;
            }
        }
        return mStatusBarController.checkHiddenLw();
    }
```
同理对于statusBar来说：
> 父亲区域，显示屏区域，过扫描区域，内容区域，可见区域，稳定区域，外部区域全部都是mUnrestricted
Dock区域为0

注意，此时如果statusBar可见，则做如下计算：
> displayFrames.mStable的顶部向下移动StatusBar的高度位置，接着判断安全裁剪去和当前哪个更接近底部一点，则获取哪个。这样就能保证我们的应用一定能在StatusBar之下，且能够被刘海安全裁剪。

> 如果Statusbar可见，当然dockFrame，整体也要从屏幕去除过扫描区域的顶部向下移动StatusBar高度的位置。mSystem代表的系统元素也是同理。这样就能保证没人挡住系统状态栏。

*这种情况挺常见的，我们从一个隐藏状态栏的页面跳转到有状态栏的页面，国有有个PopupWindow，你能看到这个popwindow会明显向下移动。*

#### layoutScreenDecorWindows
```java
private void layoutScreenDecorWindows(DisplayFrames displayFrames, Rect pf, Rect df, Rect dcf) {
        if (mScreenDecorWindows.isEmpty()) {
            return;
        }

        final int displayId = displayFrames.mDisplayId;
        final Rect dockFrame = displayFrames.mDock;
        final int displayHeight = displayFrames.mDisplayHeight;
        final int displayWidth = displayFrames.mDisplayWidth;

        for (int i = mScreenDecorWindows.size() - 1; i >= 0; --i) {
            final WindowState w = mScreenDecorWindows.valueAt(i);
            if (w.getDisplayId() != displayId || !w.isVisibleLw()) {
                // Skip if not on the same display or not visible.
                continue;
            }

            w.computeFrameLw(pf /* parentFrame */, df /* displayFrame */, df /* overlayFrame */,
                    df /* contentFrame */, df /* visibleFrame */, dcf /* decorFrame */,
                    df /* stableFrame */, df /* outsetFrame */, displayFrames.mDisplayCutout,
                    false /* parentFrameWasClippedByDisplayCutout */);
            final Rect frame = w.getFrameLw();

            if (frame.left <= 0 && frame.top <= 0) {
                // Docked at left or top.
                if (frame.bottom >= displayHeight) {
                    // Docked left.
                    dockFrame.left = Math.max(frame.right, dockFrame.left);
                } else if (frame.right >= displayWidth ) {
                    // Docked top.
                    dockFrame.top = Math.max(frame.bottom, dockFrame.top);
                } else {

                }
            } else if (frame.right >= displayWidth && frame.bottom >= displayHeight) {
                // Docked at right or bottom.
                if (frame.top <= 0) {
                    // Docked right.
                    dockFrame.right = Math.min(frame.left, dockFrame.right);
                } else if (frame.left <= 0) {
                    // Docked bottom.
                    dockFrame.bottom = Math.min(frame.top, dockFrame.bottom);
                } else {

                }
            } else {

            }
        }

        displayFrames.mRestricted.set(dockFrame);
        displayFrames.mCurrent.set(dockFrame);
        displayFrames.mVoiceContent.set(dockFrame);
        displayFrames.mSystem.set(dockFrame);
        displayFrames.mContent.set(dockFrame);
        displayFrames.mRestrictedOverscan.set(dockFrame);
    }
```
在这个方法中mScreenDecorWindows这个集合实际上是在adjustWindowParamsLw以及prepareAddWindowLw这两个方法中加入。加入的条件是，每当有新的Window加入(WMS的addView)或者Window需要重新调整(WMS的relayoutWindow)，当前新增得到Window或者需要重新relayout的Window有StatusBar有权限，且显示则会添加到mScreenDecorWindows集合。

mScreenDecorWindows从上面的描述，能得知实际上这个步骤还没有根据层级作区分。但是没关系，此时仅仅只是初步的测量。

明白了mScreenDecorWindows之后，我们阅读上面这个方法就很简单了。

layoutScreenDecorWindows做的事情就如名字一样，要测量Window上装饰部分，如StatusBar，如输入法。此时经过循环，自尾部往头部调用所有的WindowState的computeFrameLw计算每一个WindowState的对应Window的窗体大小。

当计算出每一个窗体大小之后，将会把事件分成两个情况，当计算出来的当前的Window的left和top都小于等于0，也就是说，当前的Window的顶部边缘并且左边缘超过了当前的屏幕。

说明了有什么东西在右下侧把整个Window定上去了。因此dockFrame的计算就很简单了:
- 当当前的Frame的底部大于等于屏幕高度，说明底部可能没东西，dockFrame在右边。计算最左侧的的位置(dockFrame.left)就是当前窗体和之前WindowState相比谁在右侧就取谁。
- 当当前的Frame的右侧大于等于屏幕宽度，说明右边可能没东西，dockFrame在底部。只需要计算dockFrame的顶部(dockFrame.top)和frame的底部谁大(谁更靠近底部)就获谁。

如果计算出来的bottom大于等于屏幕高度且right大于等于屏幕宽度。说明有什么东西在左上方把整个Window顶下去了。
- 当当前的Frame的顶部小于等于0，说明没有东西顶住上方，dock在左边。只要需要计算dockFrame右侧即可，计算原来的dockFrame的右侧(dockFrame.right)和当前的Frame的左侧更加靠左获取谁。
- 当当前的Frame左侧小于等于0，则说明没有东西在左侧，dock在顶部。只需要计算dockFrame的底部(dockFrame.bottom)和当前的frame的顶部谁更加小(靠近顶部)则获取谁。

**最后再设置这个把displayFrames的可见等区域都设置为dockFrame。联合上下文，实际上这里就是把整个区域的顶部移动到了statusBar之下。**

#### WindowState.computeFrameLw 
```java
    public void computeFrameLw(Rect parentFrame, Rect displayFrame, Rect overscanFrame,
            Rect contentFrame, Rect visibleFrame, Rect decorFrame, Rect stableFrame,
            Rect outsetFrame, WmDisplayCutout displayCutout,
            boolean parentFrameWasClippedByDisplayCutout) {
...

        final Rect layoutContainingFrame;
        final Rect layoutDisplayFrame;

        final int layoutXDiff;
        final int layoutYDiff;
//核心事件1
        if (inFullscreenContainer || layoutInParentFrame()) {
            // 当全屏的时候，设置内容区域就是父亲区域，显示屏区域就是传进来的显示屏区域，并且窗体没有位移
            mContainingFrame.set(parentFrame);
            mDisplayFrame.set(displayFrame);
            layoutDisplayFrame = displayFrame;
            layoutContainingFrame = parentFrame;
            layoutXDiff = 0;
            layoutYDiff = 0;
        } else {
//当不是的全屏或者在父亲窗体内部的模式
            getBounds(mContainingFrame);
            if (mAppToken != null && !mAppToken.mFrozenBounds.isEmpty()) {

                Rect frozen = mAppToken.mFrozenBounds.peek();
                mContainingFrame.right = mContainingFrame.left + frozen.width();
                mContainingFrame.bottom = mContainingFrame.top + frozen.height();
            }
            if (imeWin != null && imeWin.isVisibleNow() && isInputMethodTarget()) {
                if (inFreeformWindowingMode()
                        && mContainingFrame.bottom > contentFrame.bottom) {
                    mContainingFrame.top -= mContainingFrame.bottom - contentFrame.bottom;
                } else if (!inPinnedWindowingMode()
                        && mContainingFrame.bottom > parentFrame.bottom) {
                    mContainingFrame.bottom = parentFrame.bottom;
                }
            }

...
//显示屏区域就是内容区域
            mDisplayFrame.set(mContainingFrame);
//计算偏移量，这个偏移量的计算是根据动画的临时区域来变化
            layoutXDiff = !mInsetFrame.isEmpty() ? mInsetFrame.left - mContainingFrame.left : 0;
            layoutYDiff = !mInsetFrame.isEmpty() ? mInsetFrame.top - mContainingFrame.top : 0;
            layoutContainingFrame = !mInsetFrame.isEmpty() ? mInsetFrame : mContainingFrame;
            mTmpRect.set(0, 0, dc.getDisplayInfo().logicalWidth, dc.getDisplayInfo().logicalHeight);
//合并所有的区域到显示屏区域中
            subtractInsets(mDisplayFrame, layoutContainingFrame, displayFrame, mTmpRect);
            if (!layoutInParentFrame()) {
                subtractInsets(mContainingFrame, layoutContainingFrame, parentFrame, mTmpRect);
                subtractInsets(mInsetFrame, layoutContainingFrame, parentFrame, mTmpRect);
            }
            layoutDisplayFrame = displayFrame;
            layoutDisplayFrame.intersect(layoutContainingFrame);
        }

        final int pw = mContainingFrame.width();
        final int ph = mContainingFrame.height();

        if (!mParentFrame.equals(parentFrame)) {
            mParentFrame.set(parentFrame);
            mContentChanged = true;
        }
        if (mRequestedWidth != mLastRequestedWidth || mRequestedHeight != mLastRequestedHeight) {
            mLastRequestedWidth = mRequestedWidth;
            mLastRequestedHeight = mRequestedHeight;
            mContentChanged = true;
        }
//核心事件2
//设置各个区域的参数
        mOverscanFrame.set(overscanFrame);
        mContentFrame.set(contentFrame);
        mVisibleFrame.set(visibleFrame);
        mDecorFrame.set(decorFrame);
        mStableFrame.set(stableFrame);
        final boolean hasOutsets = outsetFrame != null;
        if (hasOutsets) {
            mOutsetFrame.set(outsetFrame);
        }

        final int fw = mFrame.width();
        final int fh = mFrame.height();
//设置Window的Gravity
        applyGravityAndUpdateFrame(layoutContainingFrame, layoutDisplayFrame);
//设置Window外部填充区域如果存在则是mOutsetFrame - mContentFrame
        if (hasOutsets) {
            mOutsets.set(Math.max(mContentFrame.left - mOutsetFrame.left, 0),
                    Math.max(mContentFrame.top - mOutsetFrame.top, 0),
                    Math.max(mOutsetFrame.right - mContentFrame.right, 0),
                    Math.max(mOutsetFrame.bottom - mContentFrame.bottom, 0));
        } else {
            mOutsets.set(0, 0, 0, 0);
        }
//核心事件3
        if (windowsAreFloating && !mFrame.isEmpty()) {
...
        } else if (mAttrs.type == TYPE_DOCK_DIVIDER) {
....
        } else {
//计算显示区域mContentFrame  mFrame 两者之间更大的区域
            mContentFrame.set(Math.max(mContentFrame.left, mFrame.left),
                    Math.max(mContentFrame.top, mFrame.top),
                    Math.min(mContentFrame.right, mFrame.right),
                    Math.min(mContentFrame.bottom, mFrame.bottom));

            mVisibleFrame.set(Math.max(mVisibleFrame.left, mFrame.left),
                    Math.max(mVisibleFrame.top, mFrame.top),
                    Math.min(mVisibleFrame.right, mFrame.right),
                    Math.min(mVisibleFrame.bottom, mFrame.bottom));

            mStableFrame.set(Math.max(mStableFrame.left, mFrame.left),
                    Math.max(mStableFrame.top, mFrame.top),
                    Math.min(mStableFrame.right, mFrame.right),
                    Math.min(mStableFrame.bottom, mFrame.bottom));
        }
//设置过扫描区间(边距)
        if (inFullscreenContainer && !windowsAreFloating) {
            mOverscanInsets.set(Math.max(mOverscanFrame.left - layoutContainingFrame.left, 0),
                    Math.max(mOverscanFrame.top - layoutContainingFrame.top, 0),
                    Math.max(layoutContainingFrame.right - mOverscanFrame.right, 0),
                    Math.max(layoutContainingFrame.bottom - mOverscanFrame.bottom, 0));
        }

        if (mAttrs.type == TYPE_DOCK_DIVIDER) {
...
        } else {
            getDisplayContent().getBounds(mTmpRect);
            boolean overrideRightInset = !windowsAreFloating && !inFullscreenContainer
                    && mFrame.right > mTmpRect.right;
            boolean overrideBottomInset = !windowsAreFloating && !inFullscreenContainer
                    && mFrame.bottom > mTmpRect.bottom;
            mContentInsets.set(mContentFrame.left - mFrame.left,
                    mContentFrame.top - mFrame.top,
                    overrideRightInset ? mTmpRect.right - mContentFrame.right
                            : mFrame.right - mContentFrame.right,
                    overrideBottomInset ? mTmpRect.bottom - mContentFrame.bottom
                            : mFrame.bottom - mContentFrame.bottom);

            mVisibleInsets.set(mVisibleFrame.left - mFrame.left,
                    mVisibleFrame.top - mFrame.top,
                    overrideRightInset ? mTmpRect.right - mVisibleFrame.right
                            : mFrame.right - mVisibleFrame.right,
                    overrideBottomInset ? mTmpRect.bottom - mVisibleFrame.bottom
                            : mFrame.bottom - mVisibleFrame.bottom);

            mStableInsets.set(Math.max(mStableFrame.left - mFrame.left, 0),
                    Math.max(mStableFrame.top - mFrame.top, 0),
                    overrideRightInset ? Math.max(mTmpRect.right - mStableFrame.right, 0)
                            : Math.max(mFrame.right - mStableFrame.right, 0),
                    overrideBottomInset ? Math.max(mTmpRect.bottom - mStableFrame.bottom, 0)
                            :  Math.max(mFrame.bottom - mStableFrame.bottom, 0));
        }

        mDisplayCutout = displayCutout.calculateRelativeTo(mFrame);

        // 设置位移区域
        mFrame.offset(-layoutXDiff, -layoutYDiff);
        mCompatFrame.offset(-layoutXDiff, -layoutYDiff);
        mContentFrame.offset(-layoutXDiff, -layoutYDiff);
        mVisibleFrame.offset(-layoutXDiff, -layoutYDiff);
        mStableFrame.offset(-layoutXDiff, -layoutYDiff);

        mCompatFrame.set(mFrame);
//设置屏幕内容的缩放
        if (mEnforceSizeCompat) {
            mOverscanInsets.scale(mInvGlobalScale);
            mContentInsets.scale(mInvGlobalScale);
            mVisibleInsets.scale(mInvGlobalScale);
            mStableInsets.scale(mInvGlobalScale);
            mOutsets.scale(mInvGlobalScale);

            mCompatFrame.scale(mInvGlobalScale);
        }
//更新壁纸的位移
        if (mIsWallpaper && (fw != mFrame.width() || fh != mFrame.height())) {
            final DisplayContent displayContent = getDisplayContent();
            if (displayContent != null) {
                final DisplayInfo displayInfo = displayContent.getDisplayInfo();
                getDisplayContent().mWallpaperController.updateWallpaperOffset(
                        this, displayInfo.logicalWidth, displayInfo.logicalHeight, false);
            }
        }
    }
```
方法很长，我这里只截取了需要注意的地方，并且添加了注释。这里稍微总结一下:
> mFrame只有在自由窗体模式和固定模式才有值。否则都是(0,0,0,0)
这个mFrame让我困惑一下子，就明白了。实际上mFrame的诞生就是为了保证在自由窗体模式下有最小的内容值，因为自由窗体模式类似PC上的窗体一样，可以变化。如果是一般情况下，实际上是没有必要设置这个值，因为有mContentFrame等区域就能确定窗体大小。

接下来就有如下的计算窗口Frame公式
> mOverscanFrame = OverscanFrame
mContentFrame = Min(mContentFrame, mFrame)
mVisibleFrame = Min(mVisibleFrame,mFrame)
mDecorFrame = mTmpDecorFrame
mStableFrame = Min(mStableFrame,mFrame)

当是全屏时候:
> layoutContainingFrame = parentFrame

不是全屏:
>layoutContainingFrame = !mInsetFrame.isEmpty() ? mInsetFrame : mContainingFrame;

mInsetFrame这个是临时的Frame，为做动画准备的Frame。不看动画实际上就是mContainingFrame

计算窗体的Insets
> mOverscanInsets = Max(mOverscanFrame-layoutContainingFrame,0)
mContentInsets = mContentFrame - mFrame
mVisibleInsets = mVisibleFrame - mFrame
mStableInsets = mStableFrame - mFrame

我们关注到这个之后就能明白在Window中的Frame实际上是连同内部的总区域，Inset是指真正的区域。但是这里只是简单的处理了。都是根据显示屏宽高来做简单的差值计算。

#### 测量那些没有绑定父窗口的窗口(所有的根部窗口）
核心逻辑:
```java
 forAllWindows(mPerformLayout, true /* traverseTopToBottom */);
```

实际上forAllWindow就是循环DisplayContent中所有的窗体，我们只需要看看这个实现的接口:
```java
 private final Consumer<WindowState> mPerformLayout = w -> {
        final boolean gone = (mTmpWindow != null && mService.mPolicy.canBeHiddenByKeyguardLw(w))
                || w.isGoneForLayoutLw();
...
        if (!gone || !w.mHaveFrame || w.mLayoutNeeded
                || ((w.isConfigChanged() || w.setReportResizeHints())
                && !w.isGoneForLayoutLw() &&
                ((w.mAttrs.privateFlags & PRIVATE_FLAG_KEYGUARD) != 0 ||
                        (w.mHasSurface && w.mAppToken != null &&
                                w.mAppToken.layoutConfigChanges)))) {
            if (!w.mLayoutAttached) {
                w.mLayoutNeeded = false;
                w.prelayout();
                final boolean firstLayout = !w.isLaidOut();
                mService.mPolicy.layoutWindowLw(w, null, mDisplayFrames);
...
            }
        }
    };
```
一旦确定其可见且，则会调用PhoneWindowManager的layoutWindowLw。

#### PhoneWindowManager.layoutWindowLw
这个方法更加的冗长，下面是拆成两个部分聊聊:
- 1.根据type设置区域的上下左右的边缘
- 2.根据其他标志，最后设置区域
##### 根据type设置区域的上下左右的边缘
这里不关注旋转之后以及状态栏下拉窗口等其他窗口，指关注我们常用的Activity窗口。
```java
    public void layoutWindowLw(WindowState win, WindowState attached, DisplayFrames displayFrames) {
//不处理状态栏，NavigationBar，以及mScreenDecorWindows包含的装饰WindowState，因为在begin中已经处理了
        if ((win == mStatusBar && !canReceiveInput(win)) || win == mNavigationBar
                || mScreenDecorWindows.contains(win)) {
            return;
        }
...
//获取type
        final int type = attrs.type;
        final int fl = PolicyControl.getWindowFlags(win, attrs);
        final int pfl = attrs.privateFlags;
        final int sim = attrs.softInputMode;
        final int requestedSysUiFl = PolicyControl.getSystemUiVisibility(null, attrs);
        final int sysUiFl = requestedSysUiFl | getImpliedSysUiFlagsForLayout(attrs);
//初始化当前的区域
        final Rect pf = mTmpParentFrame;
        final Rect df = mTmpDisplayFrame;
        final Rect of = mTmpOverscanFrame;
        final Rect cf = mTmpContentFrame;
        final Rect vf = mTmpVisibleFrame;
        final Rect dcf = mTmpDecorFrame;
        final Rect sf = mTmpStableFrame;
        Rect osf = null;
        dcf.setEmpty();

        final boolean hasNavBar = (isDefaultDisplay && mHasNavigationBar
                && mNavigationBar != null && mNavigationBar.isVisibleLw());

        final int adjust = sim & SOFT_INPUT_MASK_ADJUST;

        final boolean requestedFullscreen = (fl & FLAG_FULLSCREEN) != 0
                || (requestedSysUiFl & View.SYSTEM_UI_FLAG_FULLSCREEN) != 0;

        final boolean layoutInScreen = (fl & FLAG_LAYOUT_IN_SCREEN) == FLAG_LAYOUT_IN_SCREEN;
        final boolean layoutInsetDecor = (fl & FLAG_LAYOUT_INSET_DECOR) == FLAG_LAYOUT_INSET_DECOR;

        sf.set(displayFrames.mStable);

        if (type == TYPE_INPUT_METHOD) {
//如果当前是输入法区域，所有区域先设置为输入对应的mDock区域
            vf.set(displayFrames.mDock);
            cf.set(displayFrames.mDock);
            of.set(displayFrames.mDock);
            df.set(displayFrames.mDock);
            pf.set(displayFrames.mDock);

            pf.bottom = df.bottom = of.bottom = displayFrames.mUnrestricted.bottom;

            cf.bottom = vf.bottom = displayFrames.mStable.bottom;
...
            attrs.gravity = Gravity.BOTTOM;
            mDockLayer = win.getSurfaceLayer();
        } else if (type == TYPE_VOICE_INTERACTION) {
//测量声音窗口
...
        } else if (type == TYPE_WALLPAPER) {
//测量壁纸
...
        } else if (win == mStatusBar) {
//测量状态栏
            of.set(displayFrames.mUnrestricted);
            df.set(displayFrames.mUnrestricted);
            pf.set(displayFrames.mUnrestricted);
            cf.set(displayFrames.mStable);
            vf.set(displayFrames.mStable);

            if (adjust == SOFT_INPUT_ADJUST_RESIZE) {
                cf.bottom = displayFrames.mContent.bottom;
            } else {
                cf.bottom = displayFrames.mDock.bottom;
                vf.bottom = displayFrames.mContent.bottom;
            }
        } else {
//测量内容型弹窗
            dcf.set(displayFrames.mSystem);
            final boolean inheritTranslucentDecor =
                    (attrs.privateFlags & PRIVATE_FLAG_INHERIT_TRANSLUCENT_DECOR) != 0;
            final boolean isAppWindow =
                    type >= FIRST_APPLICATION_WINDOW && type <= LAST_APPLICATION_WINDOW;
            final boolean topAtRest =
                    win == mTopFullscreenOpaqueWindowState && !win.isAnimatingLw();
            if (isAppWindow && !inheritTranslucentDecor && !topAtRest) {
                if ((sysUiFl & View.SYSTEM_UI_FLAG_FULLSCREEN) == 0
                        && (fl & FLAG_FULLSCREEN) == 0
                        && (fl & FLAG_TRANSLUCENT_STATUS) == 0
                        && (fl & FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS) == 0
                        && (pfl & PRIVATE_FLAG_FORCE_DRAW_STATUS_BAR_BACKGROUND) == 0) {
                    dcf.top = displayFrames.mStable.top;
                }
                if ((fl & FLAG_TRANSLUCENT_NAVIGATION) == 0
                        && (sysUiFl & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0
                        && (fl & FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS) == 0) {
                    dcf.bottom = displayFrames.mStable.bottom;
                    dcf.right = displayFrames.mStable.right;
                }
            }

            if (layoutInScreen && layoutInsetDecor) {
                if (attached != null) {
                    setAttachedWindowFrames(win, fl, adjust, attached, true, pf, df, of, cf, vf,
                            displayFrames);
                } else {
                    if (type == TYPE_STATUS_BAR_PANEL || type == TYPE_STATUS_BAR_SUB_PANEL) {
...
                    } else if ((fl & FLAG_LAYOUT_IN_OVERSCAN) != 0
                            && type >= FIRST_APPLICATION_WINDOW && type <= LAST_SUB_WINDOW) {
                        of.set(displayFrames.mOverscan);
                        df.set(displayFrames.mOverscan);
                        pf.set(displayFrames.mOverscan);
                    } else if (canHideNavigationBar()
                            && (sysUiFl & View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION) != 0
                            && (type >= FIRST_APPLICATION_WINDOW && type <= LAST_SUB_WINDOW
                            || type == TYPE_VOLUME_OVERLAY)) {
                        df.set(displayFrames.mOverscan);
                        pf.set(displayFrames.mOverscan);
                        of.set(displayFrames.mUnrestricted);
                    } else {
                        df.set(displayFrames.mRestrictedOverscan);
                        pf.set(displayFrames.mRestrictedOverscan);
                        of.set(displayFrames.mUnrestricted);
                    }

                    if ((fl & FLAG_FULLSCREEN) == 0) {
                        if (win.isVoiceInteraction()) {
                            cf.set(displayFrames.mVoiceContent);
                        } else {
                            if (adjust != SOFT_INPUT_ADJUST_RESIZE) {
                                cf.set(displayFrames.mDock);
                            } else {
                                cf.set(displayFrames.mContent);
                            }
                        }
                    } else {
                        cf.set(displayFrames.mRestricted);
                    }
                    applyStableConstraints(sysUiFl, fl, cf, displayFrames);
                    if (adjust != SOFT_INPUT_ADJUST_NOTHING) {
                        vf.set(displayFrames.mCurrent);
                    } else {
                        vf.set(cf);
                    }
                }
            } else if (layoutInScreen || (sysUiFl
                    & (View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)) != 0) {
                if (type == TYPE_STATUS_BAR_PANEL || type == TYPE_STATUS_BAR_SUB_PANEL) {
...
                    }
                } else if (type == TYPE_NAVIGATION_BAR || type == TYPE_NAVIGATION_BAR_PANEL) {
                    // The navigation bar has Real Ultimate Power.
                    of.set(displayFrames.mUnrestricted);
                    df.set(displayFrames.mUnrestricted);
                    pf.set(displayFrames.mUnrestricted);
                } else if ((type == TYPE_SECURE_SYSTEM_OVERLAY || type == TYPE_SCREENSHOT)
                        && ((fl & FLAG_FULLSCREEN) != 0)) {
                    cf.set(displayFrames.mOverscan);
                    of.set(displayFrames.mOverscan);
                    df.set(displayFrames.mOverscan);
                    pf.set(displayFrames.mOverscan);
                } else if (type == TYPE_BOOT_PROGRESS) {
...
                } else if ((fl & FLAG_LAYOUT_IN_OVERSCAN) != 0
                        && type >= FIRST_APPLICATION_WINDOW && type <= LAST_SUB_WINDOW) {

                    cf.set(displayFrames.mOverscan);
                    of.set(displayFrames.mOverscan);
                    df.set(displayFrames.mOverscan);
                    pf.set(displayFrames.mOverscan);
                } else if (canHideNavigationBar()
                        && (sysUiFl & View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION) != 0
                        && (type == TYPE_STATUS_BAR
                            || type == TYPE_TOAST
                            || type == TYPE_DOCK_DIVIDER
                            || type == TYPE_VOICE_INTERACTION_STARTING
                            || (type >= FIRST_APPLICATION_WINDOW && type <= LAST_SUB_WINDOW))) {
                    cf.set(displayFrames.mUnrestricted);
                    of.set(displayFrames.mUnrestricted);
                    df.set(displayFrames.mUnrestricted);
                    pf.set(displayFrames.mUnrestricted);
                } else if ((sysUiFl & View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN) != 0) {
                    of.set(displayFrames.mRestricted);
                    df.set(displayFrames.mRestricted);
                    pf.set(displayFrames.mRestricted);
                    if (adjust != SOFT_INPUT_ADJUST_RESIZE) {
                        cf.set(displayFrames.mDock);
                    } else {
                        cf.set(displayFrames.mContent);
                    }
                } else {
                    cf.set(displayFrames.mRestricted);
                    of.set(displayFrames.mRestricted);
                    df.set(displayFrames.mRestricted);
                    pf.set(displayFrames.mRestricted);
                }

                applyStableConstraints(sysUiFl, fl, cf,displayFrames);

                if (adjust != SOFT_INPUT_ADJUST_NOTHING) {
                    vf.set(displayFrames.mCurrent);
                } else {
                    vf.set(cf);
                }
            } else if (attached != null) {

                setAttachedWindowFrames(win, fl, adjust, attached, false, pf, df, of, cf, vf,
                        displayFrames);
            } else {

                if (type == TYPE_STATUS_BAR_PANEL) {
...
                } else if (type == TYPE_TOAST || type == TYPE_SYSTEM_ALERT) {
                    // These dialogs are stable to interim decor changes.
                    cf.set(displayFrames.mStable);
                    of.set(displayFrames.mStable);
                    df.set(displayFrames.mStable);
                    pf.set(displayFrames.mStable);
                } else {
                    pf.set(displayFrames.mContent);
                    if (win.isVoiceInteraction()) {
...
                    } else if (adjust != SOFT_INPUT_ADJUST_RESIZE) {
                        cf.set(displayFrames.mDock);
                        of.set(displayFrames.mDock);
                        df.set(displayFrames.mDock);
                    } else {
                        cf.set(displayFrames.mContent);
                        of.set(displayFrames.mContent);
                        df.set(displayFrames.mContent);
                    }
                    if (adjust != SOFT_INPUT_ADJUST_NOTHING) {
                        vf.set(displayFrames.mCurrent);
                    } else {
                        vf.set(cf);
                    }
                }
            }
        }


```
我们大致上可以分以下几种情况进行测量：
- 输入法
- 状态栏
- 壁纸
- 声音窗口
- 状态栏下拉窗口
- 其他(如Activity,Dialog对应的窗口(PhoneWindow),或者启动窗口等等。内容型窗口。


本文只关注，输入法，状态栏，内容型窗口。

##### 输入法
> 输入法区域 = mDock
底部需要调整：
输入法的过扫描区域底部，显示屏区域底部，父区域底部 = mUnrestricted.bottom
内容区域，可见区域 = mStable.bottom
整个输入法的中心都在整个窗体的底部

##### 状态栏
> 状态栏父区域，显示屏区域，过扫描区域 = mUnrestricted
可见区域，内容区域 = mStable

需要判断Window的标志位是否是SOFT_INPUT_ADJUST_RESIZE：
打开SOFT_INPUT_ADJUST_RESIZE：
> 内容区域的底部 = mContent.bottom

关闭SOFT_INPUT_ADJUST_RESIZE：
> 内容区域的底部 = mDock.bottom
可见区域的底部 = mContent.bottom

关闭了SOFT_INPUT_ADJUST_RESIZE，比如说打开了adjustPan，整个屏幕向上移动了。此时的内容区域就是键盘的底部，可见区域当然是就是原来的内容区域的底部。

虽然状态栏一致位于顶部，实际上显示出来的样子只是冰山一角，只是其余部分被内容型弹窗遮住了。为了严谨，状态栏的底部也需要一起改变，才是适应window的高度的变化。

打开了SOFT_INPUT_ADJUST_RESIZE，就会通过调整Activity内容来腾出键盘的空间，所以底部还是内容区域的底部。


##### 内容型窗口
- 首先调整DecorFrame，装饰区域(外部window挂载区域如statusBar)
> DecorFrame = mSystem

如果此时是App应用的窗口：
当打开了fitSystemWindows，没有打开如下标志位：
- SYSTEM_UI_FLAG_FULLSCREEN
- FLAG_FULLSCREEN
- FLAG_TRANSLUCENT_STATUS
- FLAG_DRAWS_SYSTEM_BAR_BACKGROUND
- PRIVATE_FLAG_FORCE_DRAW_STATUS_BAR_BACKGROUND
实际上就是我们常见的Activity，Dialog。
> DecorFrame.top = mStable.top

如果隐藏了Nav Bar：
> DecorFrame.left  = mStable.bottom;
DecorFrame.right  = mStable.right;


###### 接下来调整过扫描区域(OverScanFrame),显示屏区域(displayFrame),父区域(parentFrame),最后调整内容区域(ContentFrame)和可视区域(VisiblityFrame)
*如果同时打开标志位layoutInScreen 和 layoutInsetDecor且没有绑定窗口*：
如果打开了FLAG_LAYOUT_IN_OVERSCAN：
> 过扫描，显示屏区域，父区域 = mOverScan

如果隐藏NavBar：
> 显示屏，父区域 = mOverscan；过扫描区域=mUnrestricted
确保没有任何窗口超过导航栏，确保没有内容插入到过扫描区


其他情况：
> 显示屏区域，父区域 = mRestrictedOverscan；过扫描区域 = mUnrestricted
确保没有内容插入到过扫描区

如果关闭全屏:
> 没有打开SOFT_INPUT_ADJUST_RESIZE：
> 内容区域 = mDock
> 打开SOFT_INPUT_ADJUST_RESIZE：
> 内容区域 = mContent

如果打开全屏：
> 内容区域 = mRestricted

和mStable和mStableFullScreen，获取大的一方。

adjustNothing关闭：
> 可见区域 = mCurrent

adjustNothing打开：
> 可见区域 = 刚刚测量好的内容区域

因此这个状态能够处理PopWindow因为状态栏等原因出现了移动的问题。

*如果只打开标志位layoutInScreen，隐藏Nav Bar且没有绑定窗口*：
其实和上面十分相似，实际上就是每一次根据标志为多同步设置了内容区域。但是可见区域还是由adjustNothing做处理。

也就是说这个状态将不会对全屏做更多的处理。

*普通情况*：
这里我们不管Toast等情况：
当关闭SOFT_INPUT_ADJUST_RESIZE：
> 显示屏区域，父区域，内容区域 = mDock

当打开SOFT_INPUT_ADJUST_RESIZE:
> 显示屏区域，父区域，内容区域 = mContent

关闭SOFT_INPUT_ADJUST_NOTHING：
> 可见区域 = mCurrent

adjustNothing打开：
> 可见区域 = 刚刚测量好的内容区域


#### 根据其他标志，最后设置区域
```java
        boolean parentFrameWasClippedByDisplayCutout = false;
        final int cutoutMode = attrs.layoutInDisplayCutoutMode;
        final boolean attachedInParent = attached != null && !layoutInScreen;
        final boolean requestedHideNavigation =
                (requestedSysUiFl & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) != 0;

        final boolean floatingInScreenWindow = !attrs.isFullscreen() && layoutInScreen
                && type != TYPE_BASE_APPLICATION;

        if (cutoutMode != LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS) {
            final Rect displayCutoutSafeExceptMaybeBars = mTmpDisplayCutoutSafeExceptMaybeBarsRect;
            displayCutoutSafeExceptMaybeBars.set(displayFrames.mDisplayCutoutSafe);
            if (layoutInScreen && layoutInsetDecor && !requestedFullscreen
                    && cutoutMode == LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT) {
                displayCutoutSafeExceptMaybeBars.top = Integer.MIN_VALUE;
            }
            if (layoutInScreen && layoutInsetDecor && !requestedHideNavigation
                    && cutoutMode == LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT) {
                switch (mNavigationBarPosition) {
                    case NAV_BAR_BOTTOM:
                        displayCutoutSafeExceptMaybeBars.bottom = Integer.MAX_VALUE;
                        break;
                    case NAV_BAR_RIGHT:
...
                        break;
                    case NAV_BAR_LEFT:
...
                        break;
                }
            }
            if (type == TYPE_INPUT_METHOD && mNavigationBarPosition == NAV_BAR_BOTTOM) {
                displayCutoutSafeExceptMaybeBars.bottom = Integer.MAX_VALUE;
            }

            if (!attachedInParent && !floatingInScreenWindow) {
                mTmpRect.set(pf);
                pf.intersectUnchecked(displayCutoutSafeExceptMaybeBars);
                parentFrameWasClippedByDisplayCutout |= !mTmpRect.equals(pf);
            }

            df.intersectUnchecked(displayCutoutSafeExceptMaybeBars);
        }

        cf.intersectUnchecked(displayFrames.mDisplayCutoutSafe);

....
        win.computeFrameLw(pf, df, of, cf, vf, dcf, sf, osf, displayFrames.mDisplayCutout,
                parentFrameWasClippedByDisplayCutout);
        if (type == TYPE_INPUT_METHOD && win.isVisibleLw()
                && !win.getGivenInsetsPendingLw()) {
            setLastInputMethodWindowLw(null, null);
            offsetInputMethodWindowLw(win, displayFrames);
        }
        if (type == TYPE_VOICE_INTERACTION && win.isVisibleLw()
                && !win.getGivenInsetsPendingLw()) {
            offsetVoiceInputWindowLw(win, displayFrames);
        }
    }
```
实际上这一段就是根据刘海屏幕的处理区间，最后调用computeFrameLw设置区域。接下来的逻辑在上面已经聊过了。

#### 测量那些绑定了父窗口的窗口
实际上这里的逻辑和上面很相似，不过走的是attach的逻辑：
```java
    private void setAttachedWindowFrames(WindowState win, int fl, int adjust, WindowState attached,
            boolean insetDecors, Rect pf, Rect df, Rect of, Rect cf, Rect vf,
            DisplayFrames displayFrames) {
        if (!win.isInputMethodTarget() && attached.isInputMethodTarget()) {
            vf.set(displayFrames.mDock);
            cf.set(displayFrames.mDock);
            of.set(displayFrames.mDock);
            df.set(displayFrames.mDock);
        } else {
            if (adjust != SOFT_INPUT_ADJUST_RESIZE) {
                cf.set((fl & FLAG_LAYOUT_ATTACHED_IN_DECOR) != 0
                        ? attached.getContentFrameLw() : attached.getOverscanFrameLw());
            } else {
                cf.set(attached.getContentFrameLw());
                if (attached.isVoiceInteraction()) {
                    cf.intersectUnchecked(displayFrames.mVoiceContent);
                } else if (win.isInputMethodTarget() || attached.isInputMethodTarget()) {
                    cf.intersectUnchecked(displayFrames.mContent);
                }
            }
            df.set(insetDecors ? attached.getDisplayFrameLw() : cf);
            of.set(insetDecors ? attached.getOverscanFrameLw() : cf);
            vf.set(attached.getVisibleFrameLw());
        }
        pf.set((fl & FLAG_LAYOUT_IN_SCREEN) == 0 ? attached.getFrameLw() : df);
    }
```
如果附着的窗体是输入法，一切都被输入法限制住。
关闭SOFT_INPUT_ADJUST_RESIZE:
> FLAG_LAYOUT_ATTACHED_IN_DECOR 是否打开？
关闭则内容区域 = 父窗体内容区域
打开则内容区域 = 父窗体的扫描区域

打开SOFT_INPUT_ADJUST_RESIZE:
> 则获取比较子内容区域和mContent更大取哪个

> 显示，过扫描，可见区域 = 父（被父窗体限制）

## 总结
beginLayoutLw，layoutWindowLw通过对整个Window的边距的确定，从而确定Window的大小。
beginLayoutLw，做了如下的事情：
- 测量Nav Bar
- 测量status Bar
- 测量layoutDecorScreen

对整个屏幕做了初步的测量，把剩下的Window都限定到了statusBar 之下。不允许任何窗体遮挡它。

layoutWindowLw，做了如下的事情：
**测量所有窗体的显示屏区域，过扫描区域，父区域，内容区域，可见区域。**
能够注意到的是，有两个标志为layoutInScreen，layoutInDecor。
这两个标志位确定了窗口能够移动的最大范围。

内容区域，是被adjustResize标志位确定。如果是打开则是内容区域的范围。因为这个标志是处理了Activity调整空间给键盘腾出空间。如果是关闭，打开layoutInScreen则内容区域为mDock，否则内容区域为mContent，或者根据标志为走。

可视区域，是由adjustNothing确定，如果打开了可视区域就等于内容区域，关闭了则内容区域为mCurrent(内容带上键盘)，任由系统自己默认适配。

# 后话
这就是WMS的最后一篇，实际上还有窗体动画以及Surface如何管理没有讲解。但是还没有涉及到SurfaceFlinger是如何工作的，View的绘制流程又是如何。接下来，将会以这个为突破口，和大家聊聊SurfaceFlinger的核心原理。不过，还需要点其他知识，除了OpenGL之外，还需要Skia相关的知识。

跟着我看OpenGL的朋友应该没有多少问题，如果对OpenGL感兴趣的可以看看我的OpenGL的学习日记。之后我还会放出几篇关于Skia的学习笔记。










