---
title: 从onRestoreInstanceState报错到源码浅析
top: false
cover: false
date: 2018-12-13 17:03:41
img:
tag:
description:
author: yjy239
summary:
categories: Android
tags:
- Android
---
今天遇到了一个比较有意思的问题，也比较简单，就顺手记录下来。

下面是报错内容:


>java.lang.IllegalArgumentException: Wrong state class, expecting View State but received class com.airbnb.lottie.LottieAnimationView$SavedState instead. This usually happens when two views of different type have the same id in the same hierarchy. This view's id is xxx. Make sure other views do not use the same id.

从报错可以了解到，这种错误发生的原因通常是从根布局开始，重现了相同的id，因此在onRestoreInstanceState的时候出现了异常。

由于我们的项目对一个页面的状态做了几种抽象抽象处理，所以这种情况出现也是可能的。但是实际上，我在我的android 7.0的手机上尝试了几种触发onRestoreInstanceState回调的方法的时候，却没有出现任何问题。这是为什么呢？我确实找到了相同的id。我们从源码开始吧。

了解过android的绘制流程，就会明白实际上android最顶层的view
众所周知，当当前页面出现了变化的时候，会调用Activity的onSaveInstance的回调，保存view当前的状态。当状态变更完将会调用onRestoreInstanceState恢复view中的状态。


进行源码解析之前，简单的补充一下Activity的最外层view的结构。
我们看看ActivityThread实例化后Activity，调用attach方法绑定数据做的第一件事情：
```
 final void attach(Context context, ActivityThread aThread,
            Instrumentation instr, IBinder token, int ident,
            Application application, Intent intent, ActivityInfo info,
            CharSequence title, Activity parent, String id,
            NonConfigurationInstances lastNonConfigurationInstances,
            Configuration config, String referrer, IVoiceInteractor voiceInteractor,
            Window window, ActivityConfigCallback activityConfigCallback) {
        attachBaseContext(context);

        mFragments.attachHost(null /*parent*/);

        mWindow = new PhoneWindow(this, window, activityConfigCallback);
        mWindow.setWindowControllerCallback(this);
        mWindow.setCallback(this);
        mWindow.setOnWindowDismissedCallback(this);
        mWindow.getLayoutInflater().setPrivateFactory(this);
```

可以清楚第一件事情就是实例化一个PhoneWindow,也就是最外层的window。接着就是DecorView，也就是我们Android页面开始绘制的FrameLayout.换句话说，这个就是Activity最外层的结构。当我们页面重载的时候就会从这个最上层不断向下传递每个view保存好的状态，不断的绘制。

## 正文

###onSaveInstanceState
实际上，在Activity的onPause的生命周期就会第一次调用这个方法。当然Stop也可能会调用:
```
 final Bundle performPauseActivity(ActivityClientRecord r, boolean finished,
            boolean saveState, String reason) {
        if (r.paused) {
            if (r.activity.mFinished) {
                // If we are finishing, we won't call onResume() in certain cases.
                // So here we likewise don't want to call onPause() if the activity
                // isn't resumed.
                return null;
            }
            RuntimeException e = new RuntimeException(
                    "Performing pause of activity that is not resumed: "
                    + r.intent.getComponent().toShortString());
            Slog.e(TAG, e.getMessage(), e);
        }
        if (finished) {
            r.activity.mFinished = true;
        }

        // Next have the activity save its current state and managed dialogs...
        if (!r.activity.mFinished && saveState) {
            callCallActivityOnSaveInstanceState(r);
        }
...
}

...

    private void callCallActivityOnSaveInstanceState(ActivityClientRecord r) {
        r.state = new Bundle();
        r.state.setAllowFds(false);
        if (r.isPersistable()) {
            r.persistentState = new PersistableBundle();
            mInstrumentation.callActivityOnSaveInstanceState(r.activity, r.state,
                    r.persistentState);
        } else {
            mInstrumentation.callActivityOnSaveInstanceState(r.activity, r.state);
        }
    }
```
该方法就是判断这个Activity不是finish状态，而是启动另一个Activity的时候，就会调用callCallActivityOnSaveInstanceState，就回调到Activity中的OnSaveInstanceState。

```
    protected void onSaveInstanceState(Bundle outState) {
        outState.putBundle(WINDOW_HIERARCHY_TAG, mWindow.saveHierarchyState());

        outState.putInt(LAST_AUTOFILL_ID, mLastAutofillId);
        Parcelable p = mFragments.saveAllState();
        if (p != null) {
            outState.putParcelable(FRAGMENTS_TAG, p);
        }
        if (mAutoFillResetNeeded) {
            outState.putBoolean(AUTOFILL_RESET_NEEDED, true);
            getAutofillManager().onSaveInstanceState(outState);
        }
        getApplication().dispatchActivitySaveInstanceState(this, outState);
    }
```
关键就是下面，这段方法实际上是调用了PhoneWindow的saveHierarchyState方法。通过这个方法不断的获取每个View的saveInstance的方法，把状态保存下来。
```
outState.putBundle(WINDOW_HIERARCHY_TAG, mWindow.saveHierarchyState());
```

#### PhoneWindow
```
  /** {@inheritDoc} */
    @Override
    public Bundle saveHierarchyState() {
        Bundle outState = new Bundle();
        if (mContentParent == null) {
            return outState;
        }

        SparseArray<Parcelable> states = new SparseArray<Parcelable>();
        mContentParent.saveHierarchyState(states);
        outState.putSparseParcelableArray(VIEWS_TAG, states);

        // Save the focused view ID.
        final View focusedView = mContentParent.findFocus();
        if (focusedView != null && focusedView.getId() != View.NO_ID) {
            outState.putInt(FOCUSED_ID_TAG, focusedView.getId());
        }
        ....
    }
```

此时将会调用mContentParent（ViewGroup）的saveHierarchyState。而这个mContentParent实际上就是DecorView.而实际上，这ViewGroup继承于View。所有的View 都会在saveHierarchyState处理保存状态。

我们接下来看看7.0的代码。
```
    public void saveHierarchyState(SparseArray<Parcelable> container) {
        dispatchSaveInstanceState(container);
    }
```

###View以及ViewGroup
而ViewGroup继承了View并且重写了dispatchSaveInstanceState方法。
```
    @Override
    protected void dispatchSaveInstanceState(SparseArray<Parcelable> container) {
        super.dispatchSaveInstanceState(container);
        final int count = mChildrenCount;
        final View[] children = mChildren;
        for (int i = 0; i < count; i++) {
            View c = children[i];
            if ((c.mViewFlags & PARENT_SAVE_DISABLED_MASK) != PARENT_SAVE_DISABLED) {
                c.dispatchSaveInstanceState(container);
            }
        }
    }
```

而View的dispatchSaveInstanceState
```
    protected void dispatchSaveInstanceState(SparseArray<Parcelable> container) {
        if (mID != NO_ID && (mViewFlags & SAVE_DISABLED_MASK) == 0) {
            mPrivateFlags &= ~PFLAG_SAVE_STATE_CALLED;
            Parcelable state = onSaveInstanceState();
            if ((mPrivateFlags & PFLAG_SAVE_STATE_CALLED) == 0) {
                throw new IllegalStateException(
                        "Derived class did not call super.onSaveInstanceState()");
            }
            if (state != null) {
                // Log.i("View", "Freezing #" + Integer.toHexString(mID)
                // + ": " + state);
                container.put(mID, state);
            }
        }
    }

```

可以得知，在dispatch的时候，如果是ViewGroup则不断的轮训获取子view的SaveState。而子View将会把每一个设置进来的id作为key把state保存下来。

做这一切就保存到ActivityClientRecord的state中。

###onRestoreInstanceState

此时我们在看看onRestoreInstanceState的时候，是在什么时候触发。回到ActivityThread中.

#### performLaunchActivity方法中
```

             if (!r.activity.mFinished) {
                    if (r.isPersistable()) {
                        if (r.state != null || r.persistentState != null) {
                            mInstrumentation.callActivityOnRestoreInstanceState(activity, r.state,
                                    r.persistentState);
                        }
                    } else if (r.state != null) {
                        mInstrumentation.callActivityOnRestoreInstanceState(activity, r.state);
                    }
                }
```
如果判断到Activity没有finish，但是却走了onCreate方法这个Activity实例化流程。也就是我们常见的旋转导致重构Activity之类状况。此时，判断到里面存在数据，则调用Activity的onRestore的方法。
```
    protected void onRestoreInstanceState(Bundle savedInstanceState) {
        if (mWindow != null) {
            Bundle windowState = savedInstanceState.getBundle(WINDOW_HIERARCHY_TAG);
            if (windowState != null) {
                mWindow.restoreHierarchyState(windowState);
            }
        }
    }
```

此时，存在ActivityClientRecord的State将会传下，通过onSaveInstance类似的流程下传，从DecorView开始下传到每个View。

看看PhoneWindow的方法:
```
/** {@inheritDoc} */
    @Override
    public void restoreHierarchyState(Bundle savedInstanceState) {
        if (mContentParent == null) {
            return;
        }

        SparseArray<Parcelable> savedStates
                = savedInstanceState.getSparseParcelableArray(VIEWS_TAG);
        if (savedStates != null) {
            mContentParent.restoreHierarchyState(savedStates);
        }
```

这个时候再一次的分ViewGroup和View调用
ViewGroup:
```
@Override
    protected void dispatchRestoreInstanceState(SparseArray<Parcelable> container) {
        super.dispatchRestoreInstanceState(container);
        final int count = mChildrenCount;
        final View[] children = mChildren;
        for (int i = 0; i < count; i++) {
            View c = children[i];
            if ((c.mViewFlags & PARENT_SAVE_DISABLED_MASK) != PARENT_SAVE_DISABLED) {
                c.dispatchRestoreInstanceState(container);
            }
        }
    }
```
View:
```
protected void dispatchRestoreInstanceState(SparseArray<Parcelable> container) {
        if (mID != NO_ID) {
            Parcelable state = container.get(mID);
            if (state != null) {
                // Log.i("View", "Restoreing #" + Integer.toHexString(mID)
                // + ": " + state);
                mPrivateFlags &= ~PFLAG_SAVE_STATE_CALLED;
                onRestoreInstanceState(state);
                if ((mPrivateFlags & PFLAG_SAVE_STATE_CALLED) == 0) {
                    throw new IllegalStateException(
                            "Derived class did not call super.onRestoreInstanceState()");
                }
            }
        }
    }
```
### 问题分析
源码流程十分简单，但是为什么出现上述问题呢？

我们看看View中
```
    /**
     * Called by {@link #restoreHierarchyState(android.util.SparseArray)} to retrieve the
     * state for this view and its children. May be overridden to modify how restoring
     * happens to a view's children; for example, some views may want to not store state
     * for their children.
     *
     * @param container The SparseArray which holds previously saved state.
     *
     * @see #dispatchSaveInstanceState(android.util.SparseArray)
     * @see #restoreHierarchyState(android.util.SparseArray)
     * @see #onRestoreInstanceState(android.os.Parcelable)
     */
    protected void dispatchRestoreInstanceState(SparseArray<Parcelable> container) {
        if (mID != NO_ID) {
            Parcelable state = container.get(mID);
            if (state != null) {
                // Log.i("View", "Restoreing #" + Integer.toHexString(mID)
                // + ": " + state);
                mPrivateFlags &= ~PFLAG_SAVE_STATE_CALLED;
                onRestoreInstanceState(state);
                if ((mPrivateFlags & PFLAG_SAVE_STATE_CALLED) == 0) {
                    throw new IllegalStateException(
                            "Derived class did not call super.onRestoreInstanceState()");
                }
            }
        }
    }

    /**
     * Hook allowing a view to re-apply a representation of its internal state that had previously
     * been generated by {@link #onSaveInstanceState}. This function will never be called with a
     * null state.
     *
     * @param state The frozen state that had previously been returned by
     *        {@link #onSaveInstanceState}.
     *
     * @see #onSaveInstanceState()
     * @see #restoreHierarchyState(android.util.SparseArray)
     * @see #dispatchRestoreInstanceState(android.util.SparseArray)
     */
    @CallSuper
    protected void onRestoreInstanceState(Parcelable state) {
        mPrivateFlags |= PFLAG_SAVE_STATE_CALLED;
        if (state != null && !(state instanceof AbsSavedState)) {
            throw new IllegalArgumentException("Wrong state class, expecting View State but "
                    + "received " + state.getClass().toString() + " instead. This usually happens "
                    + "when two views of different type have the same id in the same hierarchy. "
                    + "This view's id is " + ViewDebug.resolveId(mContext, getId()) + ". Make sure "
                    + "other views do not use the same id.");
        }
        if (state != null && state instanceof BaseSavedState) {
            mStartActivityRequestWho = ((BaseSavedState) state).mStartActivityRequestWhoSaved;
        }
    }

```

实际上核心思想十分简单。就是取通过保存在内部的id，来查找View对应的状态。
```
        if (state != null && !(state instanceof AbsSavedState)) {
            throw new IllegalArgumentException("Wrong state class, expecting View State but "
                    + "received " + state.getClass().toString() + " instead. This usually happens "
                    + "when two views of different type have the same id in the same hierarchy. "
                    + "This view's id is " + ViewDebug.resolveId(mContext, getId()) + ". Make sure "
                    + "other views do not use the same id.");
        }
```

此时会做一次判断，如果state状态内容不为空，但是state状态内容不是集成于AbsSavedState这个类则报错。AbsSavedState实际上是开放给自定义View用来保存自定义的State，而BaseSavedState继承于AbsSavedState。我们看看保存状态时候的步骤，当view需要保存状态的时候究竟保存了什么进来：
```
    @CallSuper
    protected Parcelable onSaveInstanceState() {
        mPrivateFlags |= PFLAG_SAVE_STATE_CALLED;
        if (mStartActivityRequestWho != null) {
            BaseSavedState state = new BaseSavedState(AbsSavedState.EMPTY_STATE);
            state.mStartActivityRequestWhoSaved = mStartActivityRequestWho;
            return state;
        }
        return BaseSavedState.EMPTY_STATE;
    }

```

此时，会根据情况返回BaseSavedState还是BaseSavedState.EMPTY_STATE。一般情况下都是返回BaseSavedState。

根据具体问题我们查看具体的分析，看看LottieAnimationView中的保存State:
```
@Override protected Parcelable onSaveInstanceState() {
    Parcelable superState = super.onSaveInstanceState();
    SavedState ss = new SavedState(superState);
    ss.animationName = animationName;
    ss.animationResId = animationResId;
    ss.progress = lottieDrawable.getProgress();
    ss.isAnimating = lottieDrawable.isAnimating();
    ss.imageAssetsFolder = lottieDrawable.getImageAssetsFolder();
    ss.repeatMode = lottieDrawable.getRepeatMode();
    ss.repeatCount = lottieDrawable.getRepeatCount();
    return ss;
  }
```

这里面保存了LottieAnimationView中关键的信息，如重复模式，次数，进度，json内容等。而SaveState继承于BaseState:
```
 private static class SavedState extends BaseSavedState
```

再看看onRestoreInstanceState
```
@Override protected void onRestoreInstanceState(Parcelable state) {
    if (!(state instanceof SavedState)) {
      super.onRestoreInstanceState(state);
      return;
    }

    SavedState ss = (SavedState) state;
    super.onRestoreInstanceState(ss.getSuperState());
    animationName = ss.animationName;
    if (!TextUtils.isEmpty(animationName)) {
      setAnimation(animationName);
    }
    animationResId = ss.animationResId;
    if (animationResId != 0) {
      setAnimation(animationResId);
    }
    setProgress(ss.progress);
    if (ss.isAnimating) {
      playAnimation();
    }
    lottieDrawable.setImagesAssetsFolder(ss.imageAssetsFolder);
    setRepeatMode(ss.repeatMode);
    setRepeatCount(ss.repeatCount);
  }

```

逻辑上完全正确。经过bugly的调查，发现都是低版本爆出这个问题。我就挑一个低版本的看看这一块究竟是怎么回事。

经过阅读，我发现实际上整个流程大同小异，唯一不同处事判断这个State是否异常不一样:
下面是低版本5.1.0保存状态逻辑:
```
protected Parcelable onSaveInstanceState() {
        mPrivateFlags |= PFLAG_SAVE_STATE_CALLED;
        return BaseSavedState.EMPTY_STATE;
    }
```

下面是5.1.0版本获取状态判断逻辑
```
    /**
     * Hook allowing a view to re-apply a representation of its internal state that had previously
     * been generated by {@link #onSaveInstanceState}. This function will never be called with a
     * null state.
     *
     * @param state The frozen state that had previously been returned by
     *        {@link #onSaveInstanceState}.
     *
     * @see #onSaveInstanceState()
     * @see #restoreHierarchyState(android.util.SparseArray)
     * @see #dispatchRestoreInstanceState(android.util.SparseArray)
     */
    protected void onRestoreInstanceState(Parcelable state) {
        mPrivateFlags |= PFLAG_SAVE_STATE_CALLED;
        if (state != BaseSavedState.EMPTY_STATE && state != null) {
            throw new IllegalArgumentException("Wrong state class, expecting View State but "
                    + "received " + state.getClass().toString() + " instead. This usually happens "
                    + "when two views of different type have the same id in the same hierarchy. "
                    + "This view's id is " + ViewDebug.resolveId(mContext, getId()) + ". Make sure "
                    + "other views do not use the same id.");
        }
    }
```
这样就明白了究竟怎么回事了吧。在高版本中是判断state是否继承于AbsSavedState。由于LottieAnimationView继承了这个类自定义了SavedState，所以没问题。

而低版本是直接返回了BaseSavedState.EMPTY_STATE并且保存下来。而此时onRestoreInstanceState的判断条件是，这个从id获取的BaseState是否BaseSavedState.EMPTY_STATE。因此这点差异导致了在低版本的表现形式和高版本的不一致。

来到LottieAmiationView中，当出现变化的时候存下了SavedState，恢复的时候取出SavedState。然后再取存进去的父类BaseSavedState。如果是低版本则是BaseSavedState.EMPTY_STATE，高版本则是BaseSavedState一个实例。因此判断上出现了问题。

不得不说，这是个bug。但是也不能怪LottieAnimationView，毕竟我翻了下TextView的源码，也是这么写的。


那么解决这个问题的根本解决方法就是检查一遍从根布局开始的所有的id是否存在相同吧。不要侥幸高版本的机型没有出现问题。



