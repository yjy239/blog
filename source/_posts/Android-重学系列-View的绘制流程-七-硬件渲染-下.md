---
title: Android 重学系列 View的绘制流程(七) 硬件渲染(下)
top: false
cover: false
date: 2020-07-11 11:35:20
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
上一篇文章，我们一直聊到了ThreadedRenderer的setFrameCallback方法，就停止下来了。本文继续沿着setFrameCallback的逻辑来看看ThreadedRenderer中做了什么。

我们继续考察下面这个代码段的逻辑：
```java
    void draw(View view, AttachInfo attachInfo, DrawCallbacks callbacks,
            FrameDrawingCallback frameDrawingCallback) {
        attachInfo.mIgnoreDirtyState = true;

        final Choreographer choreographer = attachInfo.mViewRootImpl.mChoreographer;
        choreographer.mFrameInfo.markDrawStart();

        updateRootDisplayList(view, callbacks);

        attachInfo.mIgnoreDirtyState = false;

        if (attachInfo.mPendingAnimatingRenderNodes != null) {
            final int count = attachInfo.mPendingAnimatingRenderNodes.size();
            for (int i = 0; i < count; i++) {
                registerAnimatingRenderNode(
                        attachInfo.mPendingAnimatingRenderNodes.get(i));
            }
            attachInfo.mPendingAnimatingRenderNodes.clear();
            attachInfo.mPendingAnimatingRenderNodes = null;
        }

        final long[] frameInfo = choreographer.mFrameInfo.mFrameInfo;
        if (frameDrawingCallback != null) {
            nSetFrameCallback(mNativeProxy, frameDrawingCallback);
        }
        int syncResult = nSyncAndDrawFrame(mNativeProxy, frameInfo, frameInfo.length);
        if ((syncResult & SYNC_LOST_SURFACE_REWARD_IF_FOUND) != 0) {
            setEnabled(false);
            attachInfo.mViewRootImpl.mSurface.release();
            attachInfo.mViewRootImpl.invalidate();
        }
        if ((syncResult & SYNC_INVALIDATE_REQUIRED) != 0) {
            attachInfo.mViewRootImpl.invalidate();
        }
    }
```

上一篇文章，我们聊到了nSetFrameCallback就戛然而止，本文将继续讨论下面的方法。

如果遇到疑问欢迎来到[https://www.jianshu.com/p/4854d9fcc55e](https://www.jianshu.com/p/4854d9fcc55e)下讨论。


# 正文

## ThreadedRenderer nSetFrameCallback
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)

接着在ThreadedRenderer的draw方法遍历完整个View树后会设置一个回调FrameCallback在底层。
```cpp
static void android_view_ThreadedRenderer_setFrameCallback(JNIEnv* env,
        jobject clazz, jlong proxyPtr, jobject frameCallback) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    if (!frameCallback) {
        ...
    } else {
        JavaVM* vm = nullptr;
        auto globalCallbackRef = std::make_shared<JGlobalRefHolder>(vm,
                env->NewGlobalRef(frameCallback));
        proxy->setFrameCallback([globalCallbackRef](int64_t frameNr) {
            JNIEnv* env = getenv(globalCallbackRef->vm());
            env->CallVoidMethod(globalCallbackRef->object(), gFrameDrawingCallback.onFrameDraw,
                    static_cast<jlong>(frameNr));
        });
    }
}
```
### RenderProxy setFrameCallback
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)
```cpp
void RenderProxy::setFrameCallback(std::function<void(int64_t)>&& callback) {
    mDrawFrameTask.setFrameCallback(std::move(callback));
}
```
很简单实际上就是把这个方法设置给DrawFrameTask的mFrameCallback方法指针中。


## ThreadedRenderer nSyncAndDrawFrame
前面的步骤都只是对绘制的准备，而在这个步骤开始才是真正开始绘制图层。
```cpp
static int android_view_ThreadedRenderer_syncAndDrawFrame(JNIEnv* env, jobject clazz,
        jlong proxyPtr, jlongArray frameInfo, jint frameInfoSize) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    env->GetLongArrayRegion(frameInfo, 0, frameInfoSize, proxy->frameInfo());
    return proxy->syncAndDrawFrame();
}
```
实际上还是调用了RenderProxy的syncAndDrawFrame方法。实际上很简单，就是调用了mDrawFrameTask的drawFrame方法。
```cpp
int RenderProxy::syncAndDrawFrame() {
    return mDrawFrameTask.drawFrame();
}
```

### DrawFrameTask drawFrame
```cpp
int DrawFrameTask::drawFrame() {
    mSyncResult = SyncResult::OK;
    mSyncQueued = systemTime(CLOCK_MONOTONIC);
    postAndWait();

    return mSyncResult;
}

void DrawFrameTask::postAndWait() {
    AutoMutex _lock(mLock);
    mRenderThread->queue().post([this]() { run(); });
    mSignal.wait(mLock);
}
```
在这个过程中能看到实际上把一个run方法丢到mRenderThread的任务队列中进行排队处理，同时通过mSignal阻塞当前线程。什么时候释放该线程呢？
```cpp
void DrawFrameTask::unblockUiThread() {
    AutoMutex _lock(mLock);
    mSignal.signal();
}
```
当处理完一次绘制操作后，就会调用unblockUiThread释放当前线程的阻塞。核心方法如下：

#### DrawFrameTask run
```cpp
void DrawFrameTask::run() {
    bool canUnblockUiThread;
    bool canDrawThisFrame;
    {
        TreeInfo info(TreeInfo::MODE_FULL, *mContext);
        canUnblockUiThread = syncFrameState(info);
        canDrawThisFrame = info.out.canDrawThisFrame;

        if (mFrameCompleteCallback) {
            mContext->addFrameCompleteListener(std::move(mFrameCompleteCallback));
            mFrameCompleteCallback = nullptr;
        }
    }

    CanvasContext* context = mContext;
    std::function<void(int64_t)> callback = std::move(mFrameCallback);
    mFrameCallback = nullptr;

    if (canUnblockUiThread) {
        unblockUiThread();
    }

    if (CC_UNLIKELY(callback)) {
        context->enqueueFrameWork([callback, frameNr = context->getFrameNumber()]() {
            callback(frameNr);
        });
    }

    if (CC_LIKELY(canDrawThisFrame)) {
        context->draw();
    } else {
        context->waitOnFences();
    }

    if (!canUnblockUiThread) {
        unblockUiThread();
    }
}
```
在这里面可以分为几个步骤：
- 1.为CanvasContext通过addFrameCompleteListener添加一个绘制完毕的回调
- 2.调用syncFrameState进行Layer的处理，判断是否需要阻塞ui线程。
- 2.如果不需要阻塞线程，则在绘制之前调用unblockUiThread，把ui线程的阻塞先关闭。
- 3.通过enqueueFrameWork回调，回调Java层添加的mFrameCallback监听。
- 4.如果可以绘制当前这一帧，则调用CanvasContext的draw绘制，否则说明硬件的绘制栏栅没有释放，需要对fence进行等待。
- 5.如果需要阻塞线程，说明之前没有释放过阻塞，此时需要进行释放一次。

可以看到核心方法有两个：
- 1.syncFrameState 准备渲染树
- 2.CanvasContext 的draw方法。

这两个方法才是真正的执行绘制的行为，只要弄懂了这两个行为就可以明白整个硬件渲染的流程了。

### DrawFrameTask syncFrameState
syncFrameState方法其实已经和大家聊过不少。

不过在这里面，如果没有TextureView这种自己先进行绘制图层的情况，更多是进行准备工作。
```cpp
bool DrawFrameTask::syncFrameState(TreeInfo& info) {
    int64_t vsync = mFrameInfo[static_cast<int>(FrameInfoIndex::Vsync)];
    mRenderThread->timeLord().vsyncReceived(vsync);
    bool canDraw = mContext->makeCurrent();
    mContext->unpinImages();

    for (size_t i = 0; i < mLayers.size(); i++) {
        mLayers[i]->apply();
    }
    mLayers.clear();
    mContext->setContentDrawBounds(mContentDrawBounds);
    mContext->prepareTree(info, mFrameInfo, mSyncQueued, mTargetNode);

...
    return info.prepareTextures;
}
```
大致上可以分为3步骤：
- 1.CanvasContext调用makeCurrent，为OpenGL创建运行上下文。
```cpp
bool CanvasContext::makeCurrent() {
    if (mStopped) return false;
    auto result = mRenderPipeline->makeCurrent();
...
    return true;
}
```
很简单实际上就是调用了渲染管道的makeCurrent，此时是指OpenGLPipeline的makeCurrent。而OpenGLPipeline的makeCurrent实际上还是调用EglManager的makeCurrent。
```cpp
bool EglManager::makeCurrent(EGLSurface surface, EGLint* errOut) {
    if (isCurrent(surface)) return false;

    if (surface == EGL_NO_SURFACE) {
        // Ensure we always have a valid surface & context
        surface = mPBufferSurface;
    }
    if (!eglMakeCurrent(mEglDisplay, surface, surface, mEglContext)) {
...
    }
    mCurrentSurface = surface;
    if (Properties::disableVsync) {
        eglSwapInterval(mEglDisplay, 0);
    }
    return true;
}
```
很简单就是调用了OpenGL的eglMakeCurrent方法。

- 2.CanvasContext调用unpinImages。而这个方法实际上调用的是渲染管道OpenGLPipeLine的unpinImages方法。而unpinImages方法是获取之前所有的纹理缓存并且重置。

- 3.处理保存在mDisplayList的Layer逻辑。在TextureView一文中，打开了Skia标志位，并且由于TextureView本身的特殊性，需要自己在App端进行OpenGL的渲染加工，因此需要压入DeferredLayerUpdater延迟刷新Layer对象对图像进行刷新。详细的内容可以阅读我写的[SurfaceView和TextureView 源码浅析(下)](https://www.jianshu.com/p/1dce98846dc7)

- 4.CanvasContext prepareTree 在绘制之前做最后的准备。而这个方法最后决定了是否要阻塞ui线程。

#### CanvasContext prepareTree
```cpp
void CanvasContext::prepareTree(TreeInfo& info, int64_t* uiFrameInfo, int64_t syncQueued,
                                RenderNode* target) {
    mRenderThread.removeFrameCallback(this);

...
    mCurrentFrameInfo->importUiThreadInfo(uiFrameInfo);
    mCurrentFrameInfo->set(FrameInfoIndex::SyncQueued) = syncQueued;
    mCurrentFrameInfo->markSyncStart();

    info.damageAccumulator = &mDamageAccumulator;
    info.layerUpdateQueue = &mLayerUpdateQueue;

    mAnimationContext->startFrame(info.mode);
    mRenderPipeline->onPrepareTree();
    for (const sp<RenderNode>& node : mRenderNodes) {
        info.mode = (node.get() == target ? TreeInfo::MODE_FULL : TreeInfo::MODE_RT_ONLY);
        node->prepareTree(info);
    }
    mAnimationContext->runRemainingAnimations(info);

    freePrefetchedLayers();

    mIsDirty = true;
...
}
```
- 1.mRenderPipeline的onPrepareTree回调
- 2.mAnimationContext 调用startFrame
- 3.调用保存在mRenderNodes集合中的RenderNode的prepareTree方法。
- 4.mAnimationContext runRemainingAnimations

关于动画这里的逻辑，我们先不管，先看看第三点。还记得在上文中和大家聊过的在CanvasContext的构造函数中，会先把根部的RenderNode保存到mrenderNodes中。

换句话说，此时是从RootRenderNode的prepareTree开始执行所有的RenderNode。

#### RootRenderNode prepareTree
```cpp
    virtual void prepareTree(TreeInfo& info) override {
        info.errorHandler = this;

        for (auto& anim : mRunningVDAnimators) {

            anim->getVectorDrawable()->markDirty();
        }
        if (info.mode == TreeInfo::MODE_FULL) {
            for (auto &anim : mPausedVDAnimators) {
                anim->getVectorDrawable()->setPropertyChangeWillBeConsumed(false);
                anim->getVectorDrawable()->markDirty();
            }
        }
        info.updateWindowPositions = true;
        RenderNode::prepareTree(info);
        info.updateWindowPositions = false;
        info.errorHandler = nullptr;
    }
```
- 1.首先处理添加到RootRenderNode的mRunningVDAnimators集合，这个集合实际上是在ViewRootImpl通过registerAnimatingRenderNode的添加向量动画。此时把这些集合设置为脏区，告诉之后需要渲染。这里不多进行讨论了。
- 2.调用父类RenderNode的prepareTree方法。

在prepareTree方法中，就会遍历View树中所有内容，转化为一帧帧的内容。

##### RenderNode prepareTree
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RenderNode.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RenderNode.cpp)
```cpp
void RenderNode::prepareTree(TreeInfo& info) {
    MarkAndSweepRemoved observer(&info);
    bool functorsNeedLayer = Properties::debugOverdraw && !Properties::isSkiaEnabled();
    prepareTreeImpl(observer, info, functorsNeedLayer);
}
```
核心调用了prepareTreeImpl。

##### RenderNode prepareTreeImpl
```cpp
void RenderNode::prepareTreeImpl(TreeObserver& observer, TreeInfo& info, bool functorsNeedLayer) {
    info.damageAccumulator->pushTransform(this);

    if (info.mode == TreeInfo::MODE_FULL) {
        pushStagingPropertiesChanges(info);
    }
    uint32_t animatorDirtyMask = 0;
...

    bool willHaveFunctor = false;
    if (info.mode == TreeInfo::MODE_FULL && mStagingDisplayList) {
        willHaveFunctor = mStagingDisplayList->hasFunctor();
    } else if (mDisplayList) {
        ....
    }
...

    if (CC_UNLIKELY(mPositionListener.get())) {
        mPositionListener->onPositionUpdated(*this, info);
    }

    prepareLayer(info, animatorDirtyMask);
    if (info.mode == TreeInfo::MODE_FULL) {
        pushStagingDisplayListChanges(observer, info);
    }

    if (mDisplayList) {
        info.out.hasFunctors |= mDisplayList->hasFunctor();
        bool isDirty = mDisplayList->prepareListAndChildren(
                observer, info, childFunctorsNeedLayer,
                [](RenderNode* child, TreeObserver& observer, TreeInfo& info,
                   bool functorsNeedLayer) {
                    child->prepareTreeImpl(observer, info, functorsNeedLayer);
                });
        if (isDirty) {
            damageSelf(info);
        }
    }
    pushLayerUpdate(info);

    info.damageAccumulator->popTransform();
}
```
记住此时的TreeInfo的mode是TreeInfo::MODE_FULL。
- 1.首先在TreeInfo的通过pushTransform把当前的renderNode对象保存在一个脏栈(DirtyStack)中
- 2.判断DisplayList中的hasFunctor是否为true，也就是DisplayList的functors集合是否为空。而functors实际上是通过Java层的DisplayListCanvas的下面方法添加的：
```java
    public void drawGLFunctor2(long drawGLFunctor, @Nullable Runnable releasedCallback) {
        nCallDrawGLFunction(mNativeCanvasWrapper, drawGLFunctor, releasedCallback);
    }
```

- 3.回调位置监听mPositionListener的onPositionUpdated

- 4.调用pushStagingDisplayListChanges方法，而这个方法就是DisplayList的functors的方法指针执行时机。
```cpp
void RenderNode::damageSelf(TreeInfo& info) {
    if (isRenderable()) {
        if (properties().getClipDamageToBounds()) {
            info.damageAccumulator->dirty(0, 0, properties().getWidth(), properties().getHeight());
        } else {
            info.damageAccumulator->dirty(DIRTY_MIN, DIRTY_MIN, DIRTY_MAX, DIRTY_MAX);
        }
    }
}
void RenderNode::pushStagingDisplayListChanges(TreeObserver& observer, TreeInfo& info) {
    if (mNeedsDisplayListSync) {
        mNeedsDisplayListSync = false;
        damageSelf(info);
        syncDisplayList(observer, &info);
        damageSelf(info);
    }
}
```
调用damageSelf方法，对info进行更新脏区。每一次更新都会获取RenderNode的properties对象中保存RenderNode的宽高作为脏区，更新TreeInfo中记录脏区的数据。

- 5.执行mDisplayList的prepareListAndChildren方法，最后在回调中调用所有保存在DisplayList中的子RenderNode的prepareTreeImpl。

#### RenderNode syncDisplayList
```cpp
void RenderNode::syncDisplayList(TreeObserver& observer, TreeInfo* info) {
    if (mStagingDisplayList) {
        mStagingDisplayList->updateChildren([](RenderNode* child) { child->incParentRefCount(); });
    }
    deleteDisplayList(observer, info);
    mDisplayList = mStagingDisplayList;
    mStagingDisplayList = nullptr;
    if (mDisplayList) {
        mDisplayList->syncContents();
    }
}
```
- 1.mStagingDisplayList的updateChildren，增加每一个孩子的引用计数
- 2.mStagingDisplayList赋值给mDisplayList，调用mDisplayList的syncContents。

```cpp
void DisplayList::syncContents() {
    for (auto& iter : functors) {
        (*iter.functor)(DrawGlInfo::kModeSync, nullptr);
    }
    for (auto& vectorDrawable : vectorDrawables) {
        vectorDrawable->syncProperties();
    }
}
```
执行每一个从Java层传递下来的GL方法指针，其次是处理每一个向量Drawable。


#### DisplayList prepareListAndChildren
```cpp
bool DisplayList::prepareListAndChildren(
        TreeObserver& observer, TreeInfo& info, bool functorsNeedLayer,
        std::function<void(RenderNode*, TreeObserver&, TreeInfo&, bool)> childFn) {
    info.prepareTextures = info.canvasContext.pinImages(bitmapResources);

    for (auto&& op : children) {
        RenderNode* childNode = op->renderNode;
        info.damageAccumulator->pushTransform(&op->localMatrix);
        bool childFunctorsNeedLayer =
                functorsNeedLayer;  
        childFn(childNode, observer, info, childFunctorsNeedLayer);
        info.damageAccumulator->popTransform();
    }

    bool isDirty = false;
    for (auto& vectorDrawable : vectorDrawables) {
        if (vectorDrawable->isDirty()) {
            isDirty = true;
        }
        vectorDrawable->setPropertyChangeWillBeConsumed(true);
    }
    return isDirty;
}
```
可以的出，实际上是取出了所有的子RenderNode，先通过pushTransform把当前的RenderNode加入到脏栈，接着调用每一个子View的prepareTreeImpl方法，最后再调用damageAccumulator的popTransform推出当前的RenderNode，因为已经把当前的子RenderNode以及其后代RenderNode的总脏区已经计算完毕了。

最后可以注意到 info.prepareTextures这个bool是决定于CanvasContext的pinImages方法的结果。而info.prepareTextures的结果决定了ThreadedRender在绘制时候ui线程是否需要阻塞。

##### OpenGLPipeline::pinImages
其核心实际上是调用了OpenGLPipeline::pinImages
```cpp
bool OpenGLPipeline::pinImages(LsaVector<sk_sp<Bitmap>>& images) {
    TextureCache& cache = Caches::getInstance().textureCache;
    bool prefetchSucceeded = true;
    for (auto& bitmapResource : images) {
        prefetchSucceeded &= cache.prefetchAndMarkInUse(this, bitmapResource.get());
    }
    return prefetchSucceeded;
}
```
而在native中会通过TextureCache保存所有之前使用过的Bitmap资源中的纹理id。除非缓存的Bitmap本身的纹理被移除了，或者申请纹理失败了(如申请的图片纹理实在太大)，才会出现prefetchSucceeded为false的情况。

总结来说是否可以进行同步操作，需要判断硬件渲染的Bitmap缓存是否还生效，如果缓存生效则说明可以不阻塞ui线程。如果原来的缓存失败了，为了绘制避免出现割裂感，必须保证ui线程和硬件渲染执行的统一性。

##### TreeInfo 中DamageAccumulator的职责
```cpp
    for (auto&& op : children) {
        RenderNode* childNode = op->renderNode;
        info.damageAccumulator->pushTransform(&op->localMatrix);
        bool childFunctorsNeedLayer =
                functorsNeedLayer;  
        childFn(childNode, observer, info, childFunctorsNeedLayer);
        info.damageAccumulator->popTransform();
    }
```
能看到在TreeInfo中大致可以分为如下3个步骤：
- 1.DamageAccumulator.pushTransform压入RenderNodeop的localMatrix变化矩阵。
- 2.childFn的方法指针实际上是指子RenderNode的prepareTree方法：
```cpp
child->prepareTreeImpl(observer, info, functorsNeedLayer);
```
- 3.DamageAccumulator.popTransform.

这三个步骤DamageAccumulator做了什么呢？
```cpp
void DamageAccumulator::pushTransform(const RenderNode* transform) {
    pushCommon();
    mHead->type = TransformRenderNode;
    mHead->renderNode = transform;
}

void DamageAccumulator::pushCommon() {
    if (!mHead->next) {
        DirtyStack* nextFrame = mAllocator.create_trivial<DirtyStack>();
        nextFrame->next = nullptr;
        nextFrame->prev = mHead;
        mHead->next = nextFrame;
    }
    mHead = mHead->next;
    mHead->pendingDirty.setEmpty();
}


void DamageAccumulator::popTransform() {
    LOG_ALWAYS_FATAL_IF(mHead->prev == mHead, "Cannot pop the root frame!");
    DirtyStack* dirtyFrame = mHead;
    mHead = mHead->prev;
    switch (dirtyFrame->type) {
        case TransformRenderNode:
            applyRenderNodeTransform(dirtyFrame);
            break;
        case TransformMatrix4:
....
            break;
        case TransformNone:
...
            break;
        default:
            LOG_ALWAYS_FATAL("Tried to pop an invalid type: %d", dirtyFrame->type);
    }
}
```
push的过程实际上是申请一个全新的DirtyStack，放在DirtyStack的链表的末尾，这个链表是一个双向指针。把mHead更新为尾部。并设置type为TransformRenderNode，transform为RenderNode。

每当pop操作调用一次就会通过mHead指向的前驱指针找到上一个DirtyStack，并且执行的applyRenderNodeTransform方法以当前RenderNode作为参数。

###### applyRenderNodeTransform
```cpp
static inline void mapRect(const Matrix4* matrix, const SkRect& in, SkRect* out) {
    if (in.isEmpty()) return;
    Rect temp(in);
    if (CC_LIKELY(!matrix->isPerspective())) {
        matrix->mapRect(temp);
    } else {
        temp.set(DIRTY_MIN, DIRTY_MIN, DIRTY_MAX, DIRTY_MAX);
    }
    out->join(RECT_ARGS(temp));
}


void DamageAccumulator::applyRenderNodeTransform(DirtyStack* frame) {
    if (frame->pendingDirty.isEmpty()) {
        return;
    }

    const RenderProperties& props = frame->renderNode->properties();
    if (props.getAlpha() <= 0) {
        return;
    }

    if (props.getClipDamageToBounds() && !frame->pendingDirty.isEmpty()) {
        if (!frame->pendingDirty.intersect(0, 0, props.getWidth(), props.getHeight())) {
            frame->pendingDirty.setEmpty();
        }
    }

    mapRect(props, frame->pendingDirty, &mHead->pendingDirty);

    if (props.getProjectBackwards() && !frame->pendingDirty.isEmpty()) {
...
    }
}
```
记住此时到applyRenderNodeTransform方法的时候，mHead已经指向前驱的DirtyStack，而参数是当前RenderNode对象的DirtyStack。那么做法实际上就很简单了：
- 1.首先获取当前RenderNode的属性，通过交集计算裁剪出当前的脏区。
- 2.通过mapRect方法把当前的RenderNode的DirtyStack中的pendingDirty（脏区）设置到前驱节点的pendingDirty中。

就通过这种递归方式不断用下层的RenderNode和上层的renderNode进行交集计算最终找到需要绘制的区域。


### RenderNode pushLayerUpdate
我们回到RenderNode的prepareTreeImpl方法中，当通过RenderNode的prepareTree步骤遍历完所有的View显示层级，就会调用pushLayerUpdate方法。
```cpp
void RenderNode::pushLayerUpdate(TreeInfo& info) {
    LayerType layerType = properties().effectiveLayerType();

    if (CC_LIKELY(layerType != LayerType::RenderLayer) || CC_UNLIKELY(!isRenderable()) ||
        CC_UNLIKELY(properties().getWidth() == 0) || CC_UNLIKELY(properties().getHeight() == 0) ||
        CC_UNLIKELY(!properties().fitsOnLayer())) {
        if (CC_UNLIKELY(hasLayer())) {
            renderthread::CanvasContext::destroyLayer(this);
        }
        return;
    }

    if (info.canvasContext.createOrUpdateLayer(this, *info.damageAccumulator, info.errorHandler)) {
        damageSelf(info);
    }

    if (!hasLayer()) {
        return;
    }

    SkRect dirty;
    info.damageAccumulator->peekAtDirty(&dirty);
    info.layerUpdateQueue->enqueueLayerWithDamage(this, dirty);

    info.canvasContext.markLayerInUse(this);
}
```
在这个过程TreeInfo已经通过prepareTree的方法计算完需要刷新的脏区。
- 1.CanvasContext的createOrUpdateLayer方法创建每一个RenderNode的绘制Layer。
- 2.首先获取通过peekAtDirty获取damageAccumulator中mHead的脏区，这个脏区就是之前通过prepareTree计算出来的顶层脏区，接着通过enqueueLayerWithDamage计算·当前的Layer需要刷新的区域大小以及需要刷新的RenderNode。

注意如果判断到RenderNode不是RenderLayer类型则直接返回。实际上RenderNode有在native层三种类型：
```cpp
enum class LayerType {
    None = 0,
    Software = 1,
    RenderLayer = 2,
};
```
只有RenderLayer才是代表硬件渲染，只有打开了RenderLayer的LayerType才会开始构建一个离屏渲染内存。

当然这三个也对应上Java层的三个标志位,在之前的文章已经出现了不少次：
```java
    @ViewDebug.ExportedProperty(category = "drawing", mapping = {
            @ViewDebug.IntToString(from = LAYER_TYPE_NONE, to = "NONE"),
            @ViewDebug.IntToString(from = LAYER_TYPE_SOFTWARE, to = "SOFTWARE"),
            @ViewDebug.IntToString(from = LAYER_TYPE_HARDWARE, to = "HARDWARE")
    })
    int mLayerType = LAYER_TYPE_NONE;
```
默认是LAYER_TYPE_NONE。


#### LayerUpdateQueue enqueueLayerWithDamage
```cpp
void LayerUpdateQueue::enqueueLayerWithDamage(RenderNode* renderNode, Rect damage) {
    damage.roundOut();
    damage.doIntersect(0, 0, renderNode->getWidth(), renderNode->getHeight());
    if (!damage.isEmpty()) {
        for (Entry& entry : mEntries) {
            if (CC_UNLIKELY(entry.renderNode == renderNode)) {
                entry.damage.unionWith(damage);
                return;
            }
        }
        mEntries.emplace_back(renderNode, damage);
    }
}
```
先计算当前的脏区和当前RenderNode区域之前的交集。如果计算出来的结果脏区不为空，并且在LayerUpdateQueue的Entry中记录的底层RenderNode和当前的一致则把刷新区域的大小增加并且返回。

如果是新的RenderNode则记录到mEntries中，作为一个全新需要刷新的RenderNode记录。

### CanvasContext中离屏渲染相关对象
再聊这个话题之前，我们先来看看下面几个重要的对象：
- 1.RenderState 渲染器的状态
- 2.OffscreenBufferPool 离屏渲染内存申请池
- 3.OffscreenBuffer 离屏渲染内存

#### RenderState
```cpp
class RenderState {
...

private:
...
    renderthread::RenderThread& mRenderThread;
    Caches* mCaches = nullptr;

    Blend* mBlend = nullptr;
    MeshState* mMeshState = nullptr;
    Scissor* mScissor = nullptr;
    Stencil* mStencil = nullptr;

    OffscreenBufferPool* mLayerPool = nullptr;

    std::set<Layer*> mActiveLayers;
    std::set<DeferredLayerUpdater*> mActiveLayerUpdaters;
    std::set<renderthread::CanvasContext*> mRegisteredContexts;

    GLsizei mViewportWidth;
    GLsizei mViewportHeight;
    GLuint mFramebuffer;

    pthread_t mThreadId;
};
```
能看到在RenderState，存在几个核心对象。
- 1.Caches 关于OpenGL相关的缓存
- 2.OffscreenBufferPool 离屏渲染缓存池子
- 3.Layer集合 是绘制像素内存的承载体Layer
- 4.DeferredLayerUpdater 延时绘制集合，一般是指TextureView中TextureLayer的集合
- 5.mViewportWidth和mViewportHeight 整个视窗的大小
- 6.mFramebuffer OpenGL中离屏渲染缓存的id


#### OffscreenBufferPool
```cpp
class OffscreenBufferPool {
...

private:
    struct Entry {
        Entry() {}

        Entry(const uint32_t layerWidth, const uint32_t layerHeight, bool wideColorGamut)
                : width(OffscreenBuffer::computeIdealDimension(layerWidth))
                , height(OffscreenBuffer::computeIdealDimension(layerHeight))
                , wideColorGamut(wideColorGamut) {}

        explicit Entry(OffscreenBuffer* layer)
                : layer(layer)
                , width(layer->texture.width())
                , height(layer->texture.height())
                , wideColorGamut(layer->wideColorGamut) {}

...

        OffscreenBuffer* layer = nullptr;
        uint32_t width = 0;
        uint32_t height = 0;
        bool wideColorGamut = false;
    };  // struct Entry

    std::multiset<Entry> mPool;

    uint32_t mSize = 0;
    uint32_t mMaxSize;
};  
```
能看到在OffscreenBufferPool中存在一个multiset(在c++中保证有序且重复的set集合)的Entry集合。这个Entry对象中保存了一个个OffscreenBuffer对象，让被调用者从mPool中申请出来。

每当我们需要获取一个全新的OffscreenBuffer对象的时候会调用如下方法：
```cpp
OffscreenBuffer* OffscreenBufferPool::get(RenderState& renderState, const uint32_t width,
                                          const uint32_t height, bool wideColorGamut) {
    OffscreenBuffer* layer = nullptr;

    Entry entry(width, height, wideColorGamut);
    auto iter = mPool.find(entry);

    if (iter != mPool.end()) {
        entry = *iter;
        mPool.erase(iter);

        layer = entry.layer;
        layer->viewportWidth = width;
        layer->viewportHeight = height;
        mSize -= layer->getSizeInBytes();
    } else {
        layer = new OffscreenBuffer(renderState, Caches::getInstance(), width, height,
                                    wideColorGamut);
    }

    return layer;
}
```
首先通过宽高和色彩模式为entry，通过entry尝试查找mPool中是否存在缓存，存在则从mPool总移除，并且把对应的OffscreenBuffer返回，不存在就直接new一个OffscreenBuffer对象返回给请求者。

每当使用完毕OffscreenBuffer,会调用如下方法对OffscreenBuffer进行回收：
```cpp
void OffscreenBufferPool::putOrDelete(OffscreenBuffer* layer) {
    const uint32_t size = layer->getSizeInBytes();
    if (size < mMaxSize) {
        // TODO: Use an LRU
        while (mSize + size > mMaxSize) {
            OffscreenBuffer* victim = mPool.begin()->layer;
            mSize -= victim->getSizeInBytes();
            delete victim;
            mPool.erase(mPool.begin());
        }

        // clear region, since it's no longer valid
        layer->region.clear();

        Entry entry(layer);

        mPool.insert(entry);
        mSize += size;
    } else {
        delete layer;
    }
}
```
实际上就是把OffscreenBuffer添加回mPool中，同时检查大小是否需要缩小整个mPool池中大小。

实际上这是一个十分经典的享元设计设计模式，我们开发中也经常使用到。这么做的好处可以对内存进行循环应用。


##### OffscreenBuffer
```cpp
class OffscreenBuffer : GpuMemoryTracker {
public:
    OffscreenBuffer(RenderState& renderState, Caches& caches, uint32_t viewportWidth,
                    uint32_t viewportHeight, bool wideColorGamut = false);
...
    RenderState& renderState;

    uint32_t viewportWidth;
    uint32_t viewportHeight;
    Texture texture;

    bool wideColorGamut = false;

    Region region;

    Matrix4 inverseTransformInWindow;

    GLsizei elementCount = 0;
    GLuint vbo = 0;

    bool hasRenderedSinceRepaint;
};
```
能看到这个OffscreenBuffer对象实际上保存如下几个核心对象：
- 1.viewportWidth和viewportHeight 当前离屏缓存对象的大小
- 2.Texture 纹理对象，实际上就是指OpenGL的纹理对象
- 3.inverseTransformInWindow 一个转化的纹理矩阵
- 4.vbo 顶点缓存对象

关于顶点缓存对象以及纹理对象可以阅读我写过的[绘制一个三角形](https://www.jianshu.com/p/4710b707e3ae)以及[纹理基础与索引](https://www.jianshu.com/p/9c58cd895fa5)


#### Layer 
```cpp
class Layer : public VirtualLightRefBase, GpuMemoryTracker {
public:
    enum class Api {
        OpenGL = 0,
        Vulkan = 1,
    };

    Api getApi() const { return mApi; }

...


protected:
...

private:
    void buildColorSpaceWithFilter();

    Api mApi;

    sk_sp<SkColorFilter> mColorFilter;

    android_dataspace mCurrentDataspace = HAL_DATASPACE_UNKNOWN;

    sk_sp<SkColorFilter> mColorSpaceWithFilter;

    bool forceFilter = false;

    int alpha;

    SkBlendMode mode;


    mat4 texTransform;

    mat4 transform;

};  // struct Layer
```
能看到Layer实际上这是一个简单的对象，Layer本质上只存在了透明度，是否打开混合模式，颜色过滤器，转化矩阵等等。
而实际上，我们一般是不会直接使用Layer这个结构体，而是会使用如GlLayer更加具体意义的Layer对象。



#### CanvasContext createOrUpdateLayer
而这个方法时机上调用的就是渲染管道的createOrUpdateLayer方法。
```cpp
bool OpenGLPipeline::createOrUpdateLayer(RenderNode* node,
                                         const DamageAccumulator& damageAccumulator,
                                         bool wideColorGamut,
                                         ErrorHandler* errorHandler) {
    RenderState& renderState = mRenderThread.renderState();
    OffscreenBufferPool& layerPool = renderState.layerPool();
    bool transformUpdateNeeded = false;
    if (node->getLayer() == nullptr) {
        node->setLayer(
                layerPool.get(renderState, node->getWidth(), node->getHeight(), wideColorGamut));
        transformUpdateNeeded = true;
    } else if (!layerMatchesWH(node->getLayer(), node->getWidth(), node->getHeight())) {
        if (node->properties().fitsOnLayer()) {
            node->setLayer(layerPool.resize(node->getLayer(), node->getWidth(), node->getHeight()));
        } else {
            destroyLayer(node);
        }
        transformUpdateNeeded = true;
    }

    if (transformUpdateNeeded && node->getLayer()) {

        Matrix4 windowTransform;
        damageAccumulator.computeCurrentTransform(&windowTransform);
        node->getLayer()->setWindowTransform(windowTransform);
    }

    if (!node->hasLayer()) {
...
    }

    return transformUpdateNeeded;
}
```
了解上面几个核心对象后，就能知道实际上这个步骤就是给每一个RenderNode设置一个OffscreenBuffer离屏渲染内存，这里主要起作用的是纹理对象。经过这个步骤之后RenderNode才能拥有绘制出图像的能力。

当这里就分析完了关于CanvasContext的syncFrameState方法了。

### CanvasContext draw
```cpp
void CanvasContext::draw() {
    SkRect dirty;
    mDamageAccumulator.finish(&dirty);
....

    Frame frame = mRenderPipeline->getFrame();

    SkRect windowDirty = computeDirtyRect(frame, &dirty);

    bool drew = mRenderPipeline->draw(frame, windowDirty, dirty, mLightGeometry, &mLayerUpdateQueue,
                                      mContentDrawBounds, mOpaque, mWideColorGamut, mLightInfo,
                                      mRenderNodes, &(profiler()));

    int64_t frameCompleteNr = mFrameCompleteCallbacks.size() ? getFrameNumber() : -1;

    waitOnFences();

    bool requireSwap = false;
    bool didSwap =
            mRenderPipeline->swapBuffers(frame, drew, windowDirty, mCurrentFrameInfo, &requireSwap);

    mIsDirty = false;

    if (requireSwap) {
        if (!didSwap) {  
            setSurface(nullptr);
        }
...
    } else {
...
    }

....

    if (didSwap) {
        for (auto& func : mFrameCompleteCallbacks) {
            std::invoke(func, frameCompleteNr);
        }
        mFrameCompleteCallbacks.clear();
    }

...
}
```
实际上CanvasContext的draw可以分为如下几个步骤：
- 1.DamageAccumulator.finish 获取需要渲染的脏区
- 2.通过getFrame获取到包含Surface的Frame对象，并通过computeDirtyRect把DamageAccumulator计算出来的脏区赋值到frame中。
- 3.渲染管道调用draw方法开始执行渲染
- 4.waitOnFences 等待OpenGL渲染的绘制栏栅fence解放
- 5.调用渲染管道的swapBuffers，把Surface中的GrapBuffer发送到SF进行开始渲染
- 6.如果发现渲染失败，则设置CanvasContext的Surface为null
- 7.回调之前设置渲染完成监听。

#### DamageAccumulator::finish

```cpp
void DamageAccumulator::finish(SkRect* totalDirty) {
    *totalDirty = mHead->pendingDirty;
    totalDirty->roundOut(totalDirty);
    mHead->pendingDirty.setEmpty();
}
```
很简单就是把mHead中的脏区的大小赋值给SkRect。

#### CanvasContext获取本次需要渲染区域
首先来看看一个比较关键的对象Frame的头文件：
```cpp
class Frame {
public:
....

private:
    Frame() {}
    friend class EglManager;

    int32_t mWidth;
    int32_t mHeight;
    int32_t mBufferAge;

    EGLSurface mSurface;
};
```
能看到实际上很简单，存在当前EGLSurface对应的宽高参数以及EGLSurface对象。

##### getFrame获取Frame对象
```cpp
Frame OpenGLPipeline::getFrame() {
    return mEglManager.beginFrame(mEglSurface);
}
```
```cpp
Frame EglManager::beginFrame(EGLSurface surface) {
    makeCurrent(surface);
    Frame frame;
    frame.mSurface = surface;
    eglQuerySurface(mEglDisplay, surface, EGL_WIDTH, &frame.mWidth);
    eglQuerySurface(mEglDisplay, surface, EGL_HEIGHT, &frame.mHeight);
    frame.mBufferAge = queryBufferAge(surface);
    eglBeginFrame(mEglDisplay, surface);
    return frame;
}
```
能看到很简单，首先makeCurrent 设置当前EGLSurface为渲染的上下为主体环境。把frame中的mSurface赋值为保存在mEglManager的EGLSurface，以及通过eglQuerySurface查询mEglDisplay(渲染屏幕对象)的宽高并且返回。

##### computeDirtyRect计算Frame的脏区
```cpp
SkRect CanvasContext::computeDirtyRect(const Frame& frame, SkRect* dirty) {
    if (frame.width() != mLastFrameWidth || frame.height() != mLastFrameHeight) {
        dirty->setEmpty();
        mLastFrameWidth = frame.width();
        mLastFrameHeight = frame.height();
    } else if (mHaveNewSurface || frame.bufferAge() == 0) {
        dirty->setEmpty();
    } else {
        if (!dirty->isEmpty() && !dirty->intersect(0, 0, frame.width(), frame.height())) {
                  frame.width(), frame.height());
            dirty->setEmpty();
        }
        profiler().unionDirty(dirty);
    }

    if (dirty->isEmpty()) {
        dirty->set(0, 0, frame.width(), frame.height());
    }

    SkRect windowDirty(*dirty);
    if (frame.bufferAge() > 1) {
        if (frame.bufferAge() > (int)mSwapHistory.size()) {
            dirty->set(0, 0, frame.width(), frame.height());
        } else {
            for (int i = mSwapHistory.size() - 1;
                 i > ((int)mSwapHistory.size()) - frame.bufferAge(); i--) {
                dirty->join(mSwapHistory[i].damage);
            }
        }
    }

    return windowDirty;
}
```
这个过程实际上很简单，如果发现从EGLSurface中获取到的宽高和上一次的不同则更新mLastFrameWidth和mLastFrameHeight。如果Frame的是第一次创建则脏区设置为null。

如果脏区为空，就需要把frame的宽高设置到脏区中进行全局刷新。

如果bufferAge大于1，则判断当前的bufferAge是否大于mSwapHistory。mSwapHistory这个对象实际上记录了当前已经交换成功的历史。如果bufferAge大于mSwapHistory说明是权限的刷新区域，则把脏区设置为全局，否则则查找对应的mSwapHistory子元素比较和当前的脏区获取交集。

最后返回脏区的区域。


#### 渲染管道的draw方法
在聊具体的逻辑之前，我们还需要弄清楚几个关键的对象。
##### FrameBuilder 帧构造者
```cpp
class FrameBuilder : public CanvasStateClient {
public:
    struct LightGeometry {
        Vector3 center;
        float radius;
    };

...
    LinearAllocator mAllocator;
    LinearStdAllocator<void*> mStdAllocator;

    // List of every deferred layer's render state. Replayed in reverse order to render a frame.
    LsaVector<LayerBuilder*> mLayerBuilders;

    LsaVector<size_t> mLayerStack;

    CanvasState mCanvasState;

    Caches& mCaches;

    float mLightRadius;

    const bool mDrawFbo0;
};
```
在这里我们只关注它的属性即可。
能看到FrameBuilder帧构造者中包含了如下几个核心对象：
- 1.LinearAllocator和LinearStdAllocator 这两个线性内存管理器在上一篇文章已经和大家聊过了
- 2.mLayerBuilders 是一个LayerBuilder Layer构造器的集合
- 3.mLayerStack 是指Layer的栈
- 4.mCaches 是指OpenGL的缓存

而这里面又存在另一个核心的对象LayerBuilder Layer构造器

##### LayerBuilder Layer构造器
```cpp
class LayerBuilder {viewportClip
    PREVENT_COPY_AND_ASSIGN(LayerBuilder);

public:
    LayerBuilder(uint32_t width, uint32_t height, const Rect& repaintRect)
            : LayerBuilder(width, height, repaintRect, nullptr, nullptr){};

    LayerBuilder(uint32_t width, uint32_t height, const Rect& repaintRect,
                 const BeginLayerOp* beginLayerOp, RenderNode* renderNode);

...

    const uint32_t width;
    const uint32_t height;
    const Rect repaintRect;
    const ClipRect repaintClip;
    OffscreenBuffer* offscreenBuffer;
    const BeginLayerOp* beginLayerOp;
    const RenderNode* renderNode;

    std::vector<BakedOpState*> activeUnclippedSaveLayers;

private:
...

    std::vector<BatchBase*> mBatches;

    std::unordered_map<mergeid_t, MergingOpBatch*> mMergingBatchLookup[OpBatchType::Count];

    OpBatch* mBatchLookup[OpBatchType::Count] = {nullptr};

    std::vector<Rect> mClearRects;
};
```

LayerBuilder中保存了对应宽高，renderNode，以及OffscreenBuffer几个核心的属性。

在这里出现几个比较重要的新对象，我称为绘制操作批次：
- 1.BatchBase
- 2.MergingOpBatch
- 3.mBatchLookup

实际上这些对象是都是通过RecordOp转化过来的全新的操作对象。但是他们并非直接操作RecordOp，而是操作一个名为BakedOpState的对象。

###### BakedOpState
```cpp
class BakedOpState {
public:
    static BakedOpState* tryConstruct(LinearAllocator& allocator, Snapshot& snapshot,
                                      const RecordedOp& recordedOp);

    static BakedOpState* tryConstructUnbounded(LinearAllocator& allocator, Snapshot& snapshot,
                                               const RecordedOp& recordedOp);

    enum class StrokeBehavior {
        StyleDefined,
    };

    static BakedOpState* tryStrokeableOpConstruct(LinearAllocator& allocator, Snapshot& snapshot,
                                                  const RecordedOp& recordedOp,
                                                  StrokeBehavior strokeBehavior,
                                                  bool expandForPathTexture);

    static BakedOpState* tryShadowOpConstruct(LinearAllocator& allocator, Snapshot& snapshot,
                                              const ShadowOp* shadowOpPtr);

    static BakedOpState* directConstruct(LinearAllocator& allocator, const ClipRect* clip,
                                         const Rect& dstRect, const RecordedOp& recordedOp);

...

    const float alpha;
    const RoundRectClipState* roundRectClipState;
    const RecordedOp* op;

private:
    friend class LinearAllocator;

    BakedOpState(LinearAllocator& allocator, Snapshot& snapshot, const RecordedOp& recordedOp,
                 bool expandForStroke, bool expandForPathTexture)
            : computedState(allocator, snapshot, recordedOp, expandForStroke, expandForPathTexture)
            , alpha(snapshot.alpha)
            , roundRectClipState(snapshot.roundRectClipState)
            , op(&recordedOp) {}

    BakedOpState(LinearAllocator& allocator, Snapshot& snapshot, const RecordedOp& recordedOp)
            : computedState(allocator, snapshot, recordedOp.localMatrix, recordedOp.localClip)
            , alpha(snapshot.alpha)
            , roundRectClipState(snapshot.roundRectClipState)
            , op(&recordedOp) {}

    BakedOpState(LinearAllocator& allocator, Snapshot& snapshot, const ShadowOp* shadowOpPtr)
            : computedState(allocator, snapshot)
            , alpha(snapshot.alpha)
            , roundRectClipState(snapshot.roundRectClipState)
            , op(shadowOpPtr) {}

    BakedOpState(const ClipRect* clipRect, const Rect& dstRect, const RecordedOp& recordedOp)
            : computedState(clipRect, dstRect)
            , alpha(1.0f)
            , roundRectClipState(nullptr)
            , op(&recordedOp) {}
};
```
从头文件可以看出，实际上BackStateOp是包含了RecordedOp，也就是我们在每一个View调用Canvas的操作方法生成的RecordedOp对象。同时包含透明度以及裁剪范围。

那么BackStateOp和RecordedOp有什么区别呢？实际上从名字就能明白，就是对RecordedOp进行一次拷贝存储后，同时保存裁剪区域，目标绘制区域以及透明度。

###### BatchBase
```cpp
class BatchBase {
public:
    BatchBase(batchid_t batchId, BakedOpState* op, bool merging)
            : mBatchId(batchId), mMerging(merging) {
        mBounds = op->computedState.clippedBounds;
        mOps.push_back(op);
    }

    bool intersects(const Rect& rect) const {
        if (!rect.intersects(mBounds)) return false;

        for (const BakedOpState* op : mOps) {
            if (rect.intersects(op->computedState.clippedBounds)) {
                return true;
            }
        }
        return false;
    }

    batchid_t getBatchId() const { return mBatchId; }
    bool isMerging() const { return mMerging; }

    const std::vector<BakedOpState*>& getOps() const { return mOps; }

....

protected:
    batchid_t mBatchId;
    Rect mBounds;
    std::vector<BakedOpState*> mOps;
    bool mMerging;
};
```
能看到实际上BatchBase 包含的了一个BakedOpState集合，以及渲染的区域。但是一般来说很少直接使用BatchBase而是使用它的派生类OpBatch以及MergingOpBatch。

###### OpBatch
```h
class OpBatch : public BatchBase {
public:
    OpBatch(batchid_t batchId, BakedOpState* op) : BatchBase(batchId, op, false) {}

    void batchOp(BakedOpState* op) {
        mBounds.unionWith(op->computedState.clippedBounds);
        mOps.push_back(op);
    }
};
```
很简单，OpBatch相比BatchBase来说，会并上所有添加到mOps集合中每一个绘制操作符的区域，以及保存每一个绘制操作BakedOpState。

###### MergingOpBatch
```h
class MergingOpBatch : public BatchBase {
public:
    MergingOpBatch(batchid_t batchId, BakedOpState* op)
            : BatchBase(batchId, op, true), mClipSideFlags(op->computedState.clipSideFlags) {}

    static inline bool checkSide(const int currentFlags, const int newFlags, const int side,
                                 float boundsDelta) {
        bool currentClipExists = currentFlags & side;
        bool newClipExists = newFlags & side;

        if (boundsDelta > 0 && currentClipExists) return false;

        if (boundsDelta < 0 && newClipExists) return false;

        return true;
    }

    static bool paintIsDefault(const SkPaint& paint) {
        return paint.getAlpha() == 255 && paint.getColorFilter() == nullptr &&
               paint.getShader() == nullptr;
    }

    static bool paintsAreEquivalent(const SkPaint& a, const SkPaint& b) {
        return a.getAlpha() == b.getAlpha() && a.getColorFilter() == b.getColorFilter() &&
               a.getShader() == b.getShader();
    }

    bool canMergeWith(BakedOpState* op) const {
        bool isTextBatch =
                getBatchId() == OpBatchType::Text || getBatchId() == OpBatchType::ColorText;

        if (!isTextBatch || PaintUtils::hasTextShadow(op->op->paint)) {
            if (intersects(op->computedState.clippedBounds)) return false;
        }

        const BakedOpState* lhs = op;
        const BakedOpState* rhs = mOps[0];

        if (!MathUtils::areEqual(lhs->alpha, rhs->alpha)) return false;

        if (lhs->roundRectClipState != rhs->roundRectClipState) return false;

        if (lhs->computedState.localProjectionPathMask ||
            rhs->computedState.localProjectionPathMask)
            return false;

        const int currentFlags = mClipSideFlags;
        const int newFlags = op->computedState.clipSideFlags;
        if (currentFlags != OpClipSideFlags::None || newFlags != OpClipSideFlags::None) {
            const Rect& opBounds = op->computedState.clippedBounds;
            float boundsDelta = mBounds.left - opBounds.left;
            if (!checkSide(currentFlags, newFlags, OpClipSideFlags::Left, boundsDelta))
                return false;
            boundsDelta = mBounds.top - opBounds.top;
            if (!checkSide(currentFlags, newFlags, OpClipSideFlags::Top, boundsDelta)) return false;

            boundsDelta = opBounds.right - mBounds.right;
            if (!checkSide(currentFlags, newFlags, OpClipSideFlags::Right, boundsDelta))
                return false;
            boundsDelta = opBounds.bottom - mBounds.bottom;
            if (!checkSide(currentFlags, newFlags, OpClipSideFlags::Bottom, boundsDelta))
                return false;
        }

        const SkPaint* newPaint = op->op->paint;
        const SkPaint* oldPaint = mOps[0]->op->paint;

        if (newPaint == oldPaint) {
            return true;
        } else if (newPaint && !oldPaint) {
            return paintIsDefault(*newPaint);
        } else if (!newPaint && oldPaint) {
            return paintIsDefault(*oldPaint);
        }
        return paintsAreEquivalent(*newPaint, *oldPaint);
    }

    void mergeOp(BakedOpState* op) {
        mBounds.unionWith(op->computedState.clippedBounds);
        mOps.push_back(op);
        mClipSideFlags |= op->computedState.clipSideFlags;
    }

    int getClipSideFlags() const { return mClipSideFlags; }
    const Rect& getClipRect() const { return mBounds; }

private:
    int mClipSideFlags;
};
```
实际上MergingOpBatch就如同名字一样，尝试着把多个BakedOpState合并成一个操作批次。如果可以合并到一个操作，就能对这些操作同步进行。

判断能够进行合并需要考量如下几点：
- 1.如果不是绘制文字，或者是绘制文字但是存在阴影。则需要判断是否存在交集，存在则返回false。
- 2.透明度不一致，返回false
- 3.裁剪区域不一致返回false
- 4.OpClipSideFlags 标志位不为空，则判断对应方向（top,left,right,bottom）的边缘是否是在当前MergingOpBatch的裁剪范围内，不在则返回false
- 5.判断绘制的画笔SKPaint是否是相同透明度，相同色值的，不是则返回false。

有了这些基础后，我们在回过头来看看OpenGLPipeline中的draw方法。


### OpenGLPipeline draw
在这里渲染管道是指OpenGL的渲染管道。因此我们考察一下OpenGLPipeline的draw方法。
```cpp
bool OpenGLPipeline::draw(const Frame& frame, const SkRect& screenDirty, const SkRect& dirty,
                          const FrameBuilder::LightGeometry& lightGeometry,
                          LayerUpdateQueue* layerUpdateQueue, const Rect& contentDrawBounds,
                          bool opaque, bool wideColorGamut,
                          const BakedOpRenderer::LightInfo& lightInfo,
                          const std::vector<sp<RenderNode>>& renderNodes,
                          FrameInfoVisualizer* profiler) {
    mEglManager.damageFrame(frame, dirty);

    bool drew = false;

    auto& caches = Caches::getInstance();
    FrameBuilder frameBuilder(dirty, frame.width(), frame.height(), lightGeometry, caches);

    frameBuilder.deferLayers(*layerUpdateQueue);
    layerUpdateQueue->clear();

    frameBuilder.deferRenderNodeScene(renderNodes, contentDrawBounds);

    BakedOpRenderer renderer(caches, mRenderThread.renderState(), opaque, wideColorGamut,
                             lightInfo);
    frameBuilder.replayBakedOps<BakedOpDispatcher>(renderer);
    ProfileRenderer profileRenderer(renderer);
    profiler->draw(profileRenderer);
    drew = renderer.didDraw();

    // post frame cleanup
    caches.clearGarbage();
    caches.pathCache.trim();
    caches.tessellationCache.trim();

...

    return drew;
}
```
- 1.构建FrameBuilder对象后调用deferLayers方法
- 2.构建BakedOpRenderer对象，调用FrameBuilder的replayBakedOps，通过BakedOpDispatcher分发具体操作
- 3.调用ProfileRenderer的draw方法

大致上就是这三步。

#### FrameBuilder deferLayers
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[FrameBuilder.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/FrameBuilder.cpp)
```cpp
void FrameBuilder::deferLayers(const LayerUpdateQueue& layers) {

    for (int i = layers.entries().size() - 1; i >= 0; i--) {
        RenderNode* layerNode = layers.entries()[i].renderNode.get();

        OffscreenBuffer* layer = layerNode->getLayer();
        if (CC_LIKELY(layer)) {

            Rect layerDamage = layers.entries()[i].damage;
            layerDamage.doIntersect(0, 0, layer->viewportWidth, layer->viewportHeight);
            layerNode->computeOrdering();

...

            saveForLayer(layerNode->getWidth(), layerNode->getHeight(), 0, 0, layerDamage,
                         lightCenter, nullptr, layerNode);

            if (layerNode->getDisplayList()) {
                deferNodeOps(*layerNode);
            }
            restoreForLayer();
        }
    }
}
```
注意这里的LayerUpdateQueue记录了需要更新的RenderNode，在prepareTree步骤中已经完成了对所有RenderNode的刷新范围以及个数进行记录。而LayerUpdateQueue的entries方法就是获取mEntries对象。

- 1.遍历每一个mEntries记录的RenderNode，首先把整个视窗大小和RenderNode的脏区去交集，避免RenderNode绘制在屏幕之外。
- 2.通过computeOrdering计算renderNode的投影顺序。
- 3.saveForLayer 通过RenderNode和BeginLayerOp生成LayerBuilder，记录在FrameBuilder的mLayerBuilders集合中。同时通过mLayerStack记录当前的绘制的个数。
- 4.判断RenderNode是否存在DisplayList，从上一篇文章知道DisplayList这个对象时机上控制了当前的RenderNode的所有子renderNode，因此如果存在DisplayList说明RenderNode还有子元素，调用deferNodeOps处理子renderNode。
- 5.restoreForLayer 把mLayerStack的绘制个数弹出。


#### FrameBuilder saveForLayer
```cpp
void FrameBuilder::saveForLayer(uint32_t layerWidth, uint32_t layerHeight, float contentTranslateX,
                                float contentTranslateY, const Rect& repaintRect,
                                const Vector3& lightCenter, const BeginLayerOp* beginLayerOp,
                                RenderNode* renderNode) {
    mCanvasState.save(SaveFlags::MatrixClip);
    mCanvasState.writableSnapshot()->initializeViewport(layerWidth, layerHeight);
    mCanvasState.writableSnapshot()->roundRectClipState = nullptr;
    mCanvasState.writableSnapshot()->setRelativeLightCenter(lightCenter);
    mCanvasState.writableSnapshot()->transform->loadTranslate(contentTranslateX, contentTranslateY,
                                                              0);
    mCanvasState.writableSnapshot()->setClip(repaintRect.left, repaintRect.top, repaintRect.right,
                                             repaintRect.bottom);

    mLayerStack.push_back(mLayerBuilders.size());
    auto newFbo = mAllocator.create<LayerBuilder>(layerWidth, layerHeight, repaintRect,
                                                  beginLayerOp, renderNode);
    mLayerBuilders.push_back(newFbo);
}
```
能看到每一个RenderNode都会生成一个LayerBuilder对象，并且保存到mLayerBuilders中。同时通过mCanvasState记录当前的绘制属性状态。mLayerStack还会记录当前mLayerBuilders中的大小。这样就能通过栈知道每一层的View显示层次有多少个子View。


##### FrameBuilder deferNodeOps
```cpp
#define OP_RECEIVER(Type)                                       \
    [](FrameBuilder& frameBuilder, const RecordedOp& op) {      \
        frameBuilder.defer##Type(static_cast<const Type&>(op)); \
    },
void FrameBuilder::deferNodeOps(const RenderNode& renderNode) {
    typedef void (*OpDispatcher)(FrameBuilder & frameBuilder, const RecordedOp& op);
    static OpDispatcher receivers[] = BUILD_DEFERRABLE_OP_LUT(OP_RECEIVER);


    const DisplayList& displayList = *(renderNode.getDisplayList());
    for (auto& chunk : displayList.getChunks()) {
        FatVector<ZRenderNodeOpPair, 16> zTranslatedNodes;
        buildZSortedChildList(&zTranslatedNodes, displayList, chunk);

        defer3dChildren(chunk.reorderClip, ChildrenSelectMode::Negative, zTranslatedNodes);
        for (size_t opIndex = chunk.beginOpIndex; opIndex < chunk.endOpIndex; opIndex++) {
            const RecordedOp* op = displayList.getOps()[opIndex];
            receivers[op->opId](*this, *op);

            if (CC_UNLIKELY(!renderNode.mProjectedNodes.empty() &&
                            displayList.projectionReceiveIndex >= 0 &&
                            static_cast<int>(opIndex) == displayList.projectionReceiveIndex)) {
                deferProjectedChildren(renderNode);
            }
        }
        defer3dChildren(chunk.reorderClip, ChildrenSelectMode::Positive, zTranslatedNodes);
    }
}
```
在这个方法中，遍历了DisplayList的chunk，这个对象实际上就是记录当前RenderNode的op操作层级从哪里还是到哪里结束 。在这里面还是分为三步骤：
- 1.buildZSortedChildList 根据chunk来重新对子RenderNode在Z轴上的排序，接着调用defer3dChildren(mode 为ChildrenSelectMode::Negative)处理已经拍好z轴顺序的zTranslatedNodes列表.

- 2.获取chunk记录当前op的起始位置和结束位置。以此为index获取当前DisplayList中记录的RecordedOp集合的位置。并且调用receivers这个OpDispatcher数组对应位置的方法指针执行对应RecordedOp操作。这个过程实际上是把RecordedOp转化为BakedOpState保存起来。

- 3.最后再调用defer3dChildren，mode为ChildrenSelectMode::Positive

我们依次看看buildZSortedChildList，defer3dChildren以及receivers数组转化RecordedOp为BakeOpState的过程。


###### FrameBuilder buildZSortedChildList
```cpp
template <typename V>
static void buildZSortedChildList(V* zTranslatedNodes, const DisplayList& displayList,
                                  const DisplayList::Chunk& chunk) {
    if (chunk.beginChildIndex == chunk.endChildIndex) return;

    for (size_t i = chunk.beginChildIndex; i < chunk.endChildIndex; i++) {
        RenderNodeOp* childOp = displayList.getChildren()[i];
        RenderNode* child = childOp->renderNode;
        float childZ = child->properties().getZ();

        if (!MathUtils::isZero(childZ) && chunk.reorderChildren) {
            zTranslatedNodes->push_back(ZRenderNodeOpPair(childZ, childOp));
            childOp->skipInOrderDraw = true;
        } else if (!child->properties().getProjectBackwards()) {
            childOp->skipInOrderDraw = false;
        }
    }
    std::stable_sort(zTranslatedNodes->begin(), zTranslatedNodes->end());
}
```
能看到是机上很简单，就是获取RenderNode每一个子RenderNode的Z轴的坐标，接着使用稳定排序，重排保存在zTranslatedNodes的所有的子RenderNode。


###### FrameBuilder::defer3dChildren
```cpp
template <typename V>
static size_t findNonNegativeIndex(const V& zTranslatedNodes) {
    for (size_t i = 0; i < zTranslatedNodes.size(); i++) {
        if (zTranslatedNodes[i].key >= 0.0f) return i;
    }
    return zTranslatedNodes.size();
}

template <typename V>
void FrameBuilder::defer3dChildren(const ClipBase* reorderClip, ChildrenSelectMode mode,
                                   const V& zTranslatedNodes) {
    const int size = zTranslatedNodes.size();
    if (size == 0 || (mode == ChildrenSelectMode::Negative && zTranslatedNodes[0].key > 0.0f) ||
        (mode == ChildrenSelectMode::Positive && zTranslatedNodes[size - 1].key < 0.0f)) {
        return;
    }

    const size_t nonNegativeIndex = findNonNegativeIndex(zTranslatedNodes);
    size_t drawIndex, shadowIndex, endIndex;
    if (mode == ChildrenSelectMode::Negative) {
        drawIndex = 0;
        endIndex = nonNegativeIndex;
        shadowIndex = endIndex;  // draw no shadows
    } else {
        drawIndex = nonNegativeIndex;
        endIndex = size;
        shadowIndex = drawIndex;  // potentially draw shadow for each pos Z child
    }

    float lastCasterZ = 0.0f;
    while (shadowIndex < endIndex || drawIndex < endIndex) {
        if (shadowIndex < endIndex) {
            const RenderNodeOp* casterNodeOp = zTranslatedNodes[shadowIndex].value;
            const float casterZ = zTranslatedNodes[shadowIndex].key;

            if (shadowIndex == drawIndex || casterZ - lastCasterZ < 0.1f) {
                deferShadow(reorderClip, *casterNodeOp);

                lastCasterZ = casterZ;  // must do this even if current caster not casting a shadow
                shadowIndex++;
                continue;
            }
        }

        const RenderNodeOp* childOp = zTranslatedNodes[drawIndex].value;
        deferRenderNodeOpImpl(*childOp);
        drawIndex++;
    }
}
```
通过findNonNegativeIndex找到第一个带有z轴的子RenderNode，否则是子RenderNode的总数大小，也就是统一z轴层次。
在这个方法根据ChildrenSelectMode两个流程：
- 1.为ChildrenSelectMode::Negative时候，drawIndex为0，endIndex为第一个z轴子RenderNode，shadowIndex为endIndex。因此在下面那个循环，就不会走到deferShadow进行阴影的绘制。

- 2.为ChildrenSelectMode::Positive时候，则是相反。尽可能的绘制z轴上每一个层级上的阴影。

最后调用deferRenderNodeOpImpl处理子renderNode。注意ChildrenSelectMode::Negative是获取第0个子RenderNode，而ChildrenSelectMode::Positive，则获取第一个带有z轴序列的renderNode。


###### deferRenderNodeOpImpl
```cpp
void FrameBuilder::deferRenderNodeOpImpl(const RenderNodeOp& op) {
    if (op.renderNode->nothingToDraw()) return;
    int count = mCanvasState.save(SaveFlags::MatrixClip);

    mCanvasState.writableSnapshot()->applyClip(op.localClip,
                                               *mCanvasState.currentSnapshot()->transform);
    mCanvasState.concatMatrix(op.localMatrix);

    deferNodePropsAndOps(*op.renderNode);

    mCanvasState.restoreToCount(count);
}

void FrameBuilder::deferNodePropsAndOps(RenderNode& node) {
....
    bool quickRejected = mCanvasState.currentSnapshot()->getRenderTargetClip().isEmpty() ||
                         (properties.getClipToBounds() &&
                          mCanvasState.quickRejectConservative(0, 0, width, height));
    if (!quickRejected) {
        if (node.getLayer()) {
            // HW layer
            LayerOp* drawLayerOp = mAllocator.create_trivial<LayerOp>(node);
            BakedOpState* bakedOpState = tryBakeOpState(*drawLayerOp);
            if (bakedOpState) {

                currentLayer().deferUnmergeableOp(mAllocator, bakedOpState, OpBatchType::Bitmap);
            }
        } else if (CC_UNLIKELY(!saveLayerBounds.isEmpty())) {
            SkPaint saveLayerPaint;
            saveLayerPaint.setAlpha(properties.getAlpha());
            deferBeginLayerOp(*mAllocator.create_trivial<BeginLayerOp>(
                    saveLayerBounds, Matrix4::identity(),
                    nullptr,  // no record-time clip - need only respect defer-time one
                    &saveLayerPaint));
            deferNodeOps(node);
            deferEndLayerOp(*mAllocator.create_trivial<EndLayerOp>());
        } else {
            deferNodeOps(node);
        }
    }
}
```
实际上这里可以分为2种子renderNode的情况：
- 1.RenderNode 是一个重写onDraw的有内容的View(如ImageView，textView)。此时getLayer获得的OffscreenBuffer离屏渲染内存就不为空，也就是设置了RenderLayer的LayerType。那么说明原来RenderNode就有内容，保存在BakeOpState中。

- 2.如果是ViewGroup对应的RenderNode，必定不存在OffscreenBuffer。则会走两个流程。如果之前ViewGroup对应的RenderNode，也就是当前RenderNode的父renderNode已经把范围记录在saveLayerBounds，先通过deferBeginLayerOp压入一个BeginLayerOp确定范围保存当前状态，再调用deferNodeOps继续遍历孙子RenderNode，最后通过deferEndLayerOp 返回之前保存的状态生成一个全新的LayerOp保存到BakedOpState。

###### OpDispatcher receivers执行RecordedOp的原理
可能有点糊涂，这里分析一下可以看到receivers数组是这么定义：
```cpp
    static OpDispatcher receivers[] = BUILD_DEFERRABLE_OP_LUT(OP_RECEIVER);
```
而OP_RECEIVER又是这么定义的：
```cpp
#define OP_RECEIVER(Type)                                       \
    [](FrameBuilder& frameBuilder, const RecordedOp& op) {      \
        frameBuilder.defer##Type(static_cast<const Type&>(op)); \
    },
```
可以看到这里是根据传进来的RecordedOp如XXX类型，找到对应的frameBuilder.deferXXX方法。比如说，此时我们使用的是ColorOp，颜色操作。那么这个数组对应的位置执行的是frameBuilder.deferColorOp。遍历chunk中记录的对应index的RecordedOp，就是执行如下方法：
```cpp
void FrameBuilder::deferColorOp(const ColorOp& op) {
    BakedOpState* bakedState = tryBakeUnboundedOpState(op);
    if (!bakedState) return;  // quick rejected
    currentLayer().deferUnmergeableOp(mAllocator, bakedState, OpBatchType::Vertices);
}
```

```cpp
 LayerBuilder& currentLayer() { return *(mLayerBuilders[mLayerStack.back()]); }

    BakedOpState* tryBakeUnboundedOpState(const RecordedOp& recordedOp) {
        return BakedOpState::tryConstructUnbounded(mAllocator, *mCanvasState.writableSnapshot(),
                                                   recordedOp);
    }
```
首先把通过LinearAllocation生成一个BakedOpState对象，它持有了当前对应的绘制操作RecordedOp以及快照区域。

接着调用刚刚设置到mLayerBuilders的LayerBuilder的deferUnmergeableOp方法。
```cpp
void LayerBuilder::deferUnmergeableOp(LinearAllocator& allocator, BakedOpState* op,
                                      batchid_t batchId) {
    onDeferOp(allocator, op);
    OpBatch* targetBatch = mBatchLookup[batchId];

    size_t insertBatchIndex = mBatches.size();
    if (targetBatch) {
        locateInsertIndex(batchId, op->computedState.clippedBounds, (BatchBase**)(&targetBatch),
                          &insertBatchIndex);
    }

    if (targetBatch) {
        targetBatch->batchOp(op);
    } else {
        targetBatch = allocator.create<OpBatch>(batchId, op);
        mBatchLookup[batchId] = targetBatch;
        mBatches.insert(mBatches.begin() + insertBatchIndex, targetBatch);
    }
}
```
一开始的mBatchLookup对应index的OpBatch都是null指针。因此会走到下面的targetBatch分支，创建一个OpBatch对象，插入对应类型id到mBatches中。如果能找到mBatches对应类型id，就调用batchOp方法保存新的BakedOpState到OpBatch。

当然让我们看看一共有多少种OpBatch的类型：
```cpp
namespace OpBatchType {
enum {
    Bitmap,
    MergedPatch,
    AlphaVertices,
    Vertices,
    AlphaMaskTexture,
    Text,
    ColorText,
    Shadow,
    TextureLayer,
    Functor,
    CopyToLayer,
    CopyFromLayer,

    Count  // must be last
};
}
```


#### FrameBuilder的replayBakedOps
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[FrameBuilder.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/FrameBuilder.h)

```cpp
    template <typename StaticDispatcher, typename Renderer>
    void replayBakedOps(Renderer& renderer) {
        std::vector<OffscreenBuffer*> temporaryLayers;
        finishDefer();

#define X(Type)                                                                   \
    [](void* renderer, const BakedOpState& state) {                               \
        StaticDispatcher::on##Type(*(static_cast<Renderer*>(renderer)),           \
                                   static_cast<const Type&>(*(state.op)), state); \
    },
        static BakedOpReceiver unmergedReceivers[] = BUILD_RENDERABLE_OP_LUT(X);
#undef X


#define X(Type)                                                                           \
    [](void* renderer, const MergedBakedOpList& opList) {                                 \
        StaticDispatcher::onMerged##Type##s(*(static_cast<Renderer*>(renderer)), opList); \
    },
        static MergedOpReceiver mergedReceivers[] = BUILD_MERGEABLE_OP_LUT(X);
#undef X

        for (int i = mLayerBuilders.size() - 1; i >= 1; i--) {
            GL_CHECKPOINT(MODERATE);
            LayerBuilder& layer = *(mLayerBuilders[i]);
            if (layer.renderNode) {
                renderer.startRepaintLayer(layer.offscreenBuffer, layer.repaintRect);
                layer.replayBakedOpsImpl((void*)&renderer, unmergedReceivers, mergedReceivers);
                renderer.endLayer();
            } else if (!layer.empty()) {
...
            }
        }

        if (CC_LIKELY(mDrawFbo0)) {
            const LayerBuilder& fbo0 = *(mLayerBuilders[0]);
            renderer.startFrame(fbo0.width, fbo0.height, fbo0.repaintRect);
            fbo0.replayBakedOpsImpl((void*)&renderer, unmergedReceivers, mergedReceivers);
            renderer.endFrame(fbo0.repaintRect);
        }

        for (auto& temporaryLayer : temporaryLayers) {
            renderer.recycleTemporaryLayer(temporaryLayer);
        }
    }
```
首先遍历mLayerBuilders中所有保存的LayerBuilder依次执行如下几个方法：
- 1.Renderer的startFrame方法
- 2.LayerBuilder的replayBakedOpsImpl
- 3.Renderer的endFrame方法

如果判断mDrawFbo0为true，再一次执行LayerBuilder第0个位置的LayerBuilder上面三个步骤。这个Render就是BakedOpRenderer。

注意replayBakedOpsImpl方法设置两个特殊的对象：
- 1.BakedOpReceiver
- 2.MergedOpReceiver

这两个参数作为方法指针传入到replayBakedOpsImpl中。这两个方法实际上分别对应2个宏。
```cpp
#define X(Type)                                                                   \
    [](void* renderer, const BakedOpState& state) {                               \
        StaticDispatcher::on##Type(*(static_cast<Renderer*>(renderer)),           \
                                   static_cast<const Type&>(*(state.op)), state); \
    },
        static BakedOpReceiver unmergedReceivers[] = BUILD_RENDERABLE_OP_LUT(X);
#undef X
```
注意StaticDispatcher这个实际上是一个范性对象，它实际上是指
```cpp
frameBuilder.replayBakedOps<BakedOpDispatcher>(renderer);
```
BakedOpDispatcher。

如果当前X传递进来的类型是BitmapOp，那么实际上保存的是：
```cpp
BakedOpDispatcher::onBitmapOp
```
这个方法。

同理，对于mergedReceivers，如果是BitmapOp则是：
```cpp
BakedOpDispatcher::onMergedBitmapOps
```
这样就能对应每一个Type，执行一种操作。而对应合并操作，必须是同一种绘制操作，同一个透明度才能完成合并。

让我们依次看看这三个方法都做了什么吧。

##### BakedOpRenderer startFrame
```cpp
void BakedOpRenderer::startFrame(uint32_t width, uint32_t height, const Rect& repaintRect) {
    mRenderState.bindFramebuffer(0);
    setViewport(width, height);

    if (!mOpaque) {
        clearColorBuffer(repaintRect);
    }

}
```
```cpp
void RenderState::bindFramebuffer(GLuint fbo) {
    if (mFramebuffer != fbo) {
        mFramebuffer = fbo;
        glBindFramebuffer(GL_FRAMEBUFFER, mFramebuffer);
    }
}
```
很简单实际上就是绑定index为0的Framebuffer。0号帧缓冲就是默认的屏幕帧缓冲区。接着设置试图宽高，如果不是透明的则清空当前绘制区域的色值。

##### LayerBuilder replayBakedOpsImpl
```cpp
void LayerBuilder::replayBakedOpsImpl(void* arg, BakedOpReceiver* unmergedReceivers,
                                      MergedOpReceiver* mergedReceivers) const {
    for (const BatchBase* batch : mBatches) {
        size_t size = batch->getOps().size();
        if (size > 1 && batch->isMerging()) {
            int opId = batch->getOps()[0]->op->opId;
            const MergingOpBatch* mergingBatch = static_cast<const MergingOpBatch*>(batch);
            MergedBakedOpList data = {batch->getOps().data(), size,
                                      mergingBatch->getClipSideFlags(),
                                      mergingBatch->getClipRect()};
            mergedReceivers[opId](arg, data);
        } else {
            for (const BakedOpState* op : batch->getOps()) {
                unmergedReceivers[op->op->opId](arg, *op);
            }
        }
    }
}
```
之前通过deferUnmergeableOp的操作把所有的OpBatch保存到mBatches。此时在replayBakedOpsImpl开始遍历所有的OpBatch。

- 1.如果OpBatch中保存的BakeOpState列表大小大于1，且允许合并。说明这是一个MergingOpBatch对象。先生成MergedBakedOpList对象后，在调用mergedReceivers对应index的BakedOpDispatcher::onMerged##Type##s的方法。

- 2.如果无法合并，只能遍历OpBatch中每一个BakedOpState进行一一绘制，此时调用的方法是mergedReceivers对应index的BakedOpDispatcher::on##Type。

我们举个例子Bitmap的操作。

##### 关于Bitmap的操作
```cpp
void BakedOpDispatcher::onBitmapOp(BakedOpRenderer& renderer, const BitmapOp& op,
                                   const BakedOpState& state) {
    Texture* texture = renderer.getTexture(op.bitmap);
    if (!texture) return;
    const AutoTexture autoCleanup(texture);

    const int textureFillFlags = (op.bitmap->colorType() == kAlpha_8_SkColorType)
                                         ? TextureFillFlags::IsAlphaMaskTexture
                                         : TextureFillFlags::None;
    Glop glop;
    GlopBuilder(renderer.renderState(), renderer.caches(), &glop)
            .setRoundRectClipState(state.roundRectClipState)
            .setMeshTexturedUnitQuad(texture->uvMapper)
            .setFillTexturePaint(*texture, textureFillFlags, op.paint, state.alpha)
            .setTransform(state.computedState.transform, TransformFlags::None)
            .setModelViewMapUnitToRectSnap(Rect(texture->width(), texture->height()))
            .build();
    renderer.renderGlop(state, glop);
}
```
能看到这个过程实际上就是获取Bitmap中的纹理为基础，以及其他的参数构成一个GlopBuilder生成glop对象。

最后调用renderer的renderGlop进行渲染

```cpp
void BakedOpDispatcher::onMergedBitmapOps(BakedOpRenderer& renderer,
                                          const MergedBakedOpList& opList) {
    const BakedOpState& firstState = *(opList.states[0]);
    Bitmap* bitmap = (static_cast<const BitmapOp*>(opList.states[0]->op))->bitmap;

    Texture* texture = renderer.caches().textureCache.get(bitmap);
    if (!texture) return;
    const AutoTexture autoCleanup(texture);

    TextureVertex vertices[opList.count * 4];
    for (size_t i = 0; i < opList.count; i++) {
        const BakedOpState& state = *(opList.states[i]);
        TextureVertex* rectVerts = &vertices[i * 4];

        Rect opBounds = state.op->unmappedBounds;
        state.computedState.transform.mapRect(opBounds);
        if (CC_LIKELY(state.computedState.transform.isPureTranslate())) {
            opBounds.snapToPixelBoundaries();
        }
        storeTexturedRect(rectVerts, opBounds);
        renderer.dirtyRenderTarget(opBounds);
    }

    const int textureFillFlags = (bitmap->colorType() == kAlpha_8_SkColorType)
                                         ? TextureFillFlags::IsAlphaMaskTexture
                                         : TextureFillFlags::None;
    Glop glop;
    GlopBuilder(renderer.renderState(), renderer.caches(), &glop)
            .setRoundRectClipState(firstState.roundRectClipState)
            .setMeshTexturedIndexedQuads(vertices, opList.count * 6)
            .setFillTexturePaint(*texture, textureFillFlags, firstState.op->paint, firstState.alpha)
            .setTransform(Matrix4::identity(), TransformFlags::None)
            .setModelViewIdentityEmptyBounds()
            .build();
    ClipRect renderTargetClip(opList.clip);
    const ClipBase* clip = opList.clipSideFlags ? &renderTargetClip : nullptr;
    renderer.renderGlop(nullptr, clip, glop);
}
```
对于merge来说，由于是希望把多个操作合并到一起，因此每一个绘制操作的区域可能不哦不同，因此需要计算最大的操作区域，以及不断的记录每一个操作对应脏区到mRenderTarget结构体中。

最后还是调用renderGlop进行渲染。不同的是，此时还传了裁剪区域ClipRect到BakedOpRenderer中。



##### BakedOpRenderer renderGlop
```cpp
    void renderGlop(const BakedOpState& state, const Glop& glop) {
        renderGlop(&state.computedState.clippedBounds, state.computedState.getClipIfNeeded(), glop);
    }

    void renderGlop(const Rect* dirtyBounds, const ClipBase* clip, const Glop& glop) {
        mGlopReceiver(*this, dirtyBounds, clip, glop);
    }
```
能看到最后是调用了mGlopReceiver这个函数 指针。这个mGlopReceiver实际上是什么呢？我们来看看BakedOpRenderer的构造函数：
```cpp
    BakedOpRenderer(Caches& caches, RenderState& renderState, bool opaque, bool wideColorGamut,
                    const LightInfo& lightInfo)
            : mGlopReceiver(DefaultGlopReceiver)
            , mRenderState(renderState)
            , mCaches(caches)
            , mOpaque(opaque)
            , mWideColorGamut(wideColorGamut)
            , mLightInfo(lightInfo) {}

    static void DefaultGlopReceiver(BakedOpRenderer& renderer, const Rect* dirtyBounds,
                                    const ClipBase* clip, const Glop& glop) {
        renderer.renderGlopImpl(dirtyBounds, clip, glop);
    }
```
实际上它调用就是BakedOpRenderer的renderGlopImpl方法。

```cpp
void BakedOpRenderer::renderGlopImpl(const Rect* dirtyBounds, const ClipBase* clip,
                                     const Glop& glop) {
    prepareRender(dirtyBounds, clip);

    bool overrideDisableBlending = !mHasDrawn && mOpaque && !mRenderTarget.frameBufferId &&
                                   glop.blend.src == GL_ONE &&
                                   glop.blend.dst == GL_ONE_MINUS_SRC_ALPHA;
    mRenderState.render(glop, mRenderTarget.orthoMatrix, overrideDisableBlending);
    if (!mRenderTarget.frameBufferId) mHasDrawn = true;
}
```

做了两件是将：
- 1.prepareRender 打开裁剪区域，模版测试，为帧缓冲区绑定颜色附件
- 2.调用了RenderState的render方法。

###### prepareRender
```cpp
void BakedOpRenderer::prepareRender(const Rect* dirtyBounds, const ClipBase* clip) {
    mRenderState.scissor().setEnabled(clip != nullptr);
    if (clip) {
        mRenderState.scissor().set(mRenderTarget.viewportHeight, clip->rect);
    }

    if (CC_LIKELY(!Properties::debugOverdraw)) {

        if (CC_UNLIKELY(clip && clip->mode != ClipMode::Rectangle)) {
            if (mRenderTarget.lastStencilClip != clip) {
                mRenderTarget.lastStencilClip = clip;

                if (mRenderTarget.frameBufferId != 0 && !mRenderTarget.stencil) {
                    OffscreenBuffer* layer = mRenderTarget.offscreenBuffer;
                    mRenderTarget.stencil = mCaches.renderBufferCache.get(
                            Stencil::getLayerStencilFormat(), layer->texture.width(),
                            layer->texture.height());
                    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                                              GL_RENDERBUFFER, mRenderTarget.stencil->getName());
                }

                if (clip->mode == ClipMode::RectangleList) {
                    setupStencilRectList(clip);
                } else {
                    setupStencilRegion(clip);
                }
            } else {
                int incrementThreshold = 0;
                if (CC_LIKELY(clip->mode == ClipMode::RectangleList)) {
                    auto&& rectList = reinterpret_cast<const ClipRectList*>(clip)->rectList;
                    incrementThreshold = rectList.getTransformedRectanglesCount();
                }
                mRenderState.stencil().enableTest(incrementThreshold);
            }
        } else {
            mRenderState.stencil().disable();
        }
    }

    if (dirtyBounds) {
        dirtyRenderTarget(*dirtyBounds);
    }
}
```
能看到实际上这里面的逻辑都是关于OpenGL 模版测试是否打开，如果有裁剪区域则打开裁剪功能。其中最重要的一点就是从Caches中获取一个宽高一致的渲染缓冲对象，通过glFramebufferRenderbuffer绑定到帧缓冲区。

###### RenderState的render方法
下面这段代码十分冗长，我只节选比较核心的，其实都是我之前和大家聊过的OpenGL es的套路操作
```cpp
void RenderState::render(const Glop& glop, const Matrix4& orthoMatrix,
                         bool overrideDisableBlending) {
    const Glop::Mesh& mesh = glop.mesh;
    const Glop::Mesh::Vertices& vertices = mesh.vertices;
    const Glop::Mesh::Indices& indices = mesh.indices;
    const Glop::Fill& fill = glop.fill;

    GL_CHECKPOINT(MODERATE);

    // ---------------------------------------------
    // ---------- Program + uniform setup ----------
    // ---------------------------------------------
    mCaches->setProgram(fill.program);

    if (fill.colorEnabled) {
        fill.program->setColor(fill.color);
    }

    fill.program->set(orthoMatrix, glop.transform.modelView, glop.transform.meshTransform(),
                      glop.transform.transformFlags & TransformFlags::OffsetByFudgeFactor);

....

    // --------------------------------
    // ---------- Mesh setup ----------
    // --------------------------------
    // vertices
    meshState().bindMeshBuffer(vertices.bufferObject);
    meshState().bindPositionVertexPointer(vertices.position, vertices.stride);

    // indices
    meshState().bindIndicesBuffer(indices.bufferObject);

    ....

    // ------------------------------------
    // ---------- GL state setup ----------
    // ------------------------------------
...


    // ------------------------------------
    // ---------- Actual drawing ----------
    // ------------------------------------
    if (indices.bufferObject == meshState().getQuadListIBO()) {
        GLsizei elementsCount = mesh.elementCount;
        const GLbyte* vertexData = static_cast<const GLbyte*>(vertices.position);
        while (elementsCount > 0) {
            GLsizei drawCount = std::min(elementsCount, (GLsizei)kMaxNumberOfQuads * 6);
            GLsizei vertexCount = (drawCount / 6) * 4;
            meshState().bindPositionVertexPointer(vertexData, vertices.stride);
            if (vertices.attribFlags & VertexAttribFlags::TextureCoord) {
                meshState().bindTexCoordsVertexPointer(vertexData + kMeshTextureOffset,
                                                       vertices.stride);
            }

            if (mCaches->extensions().getMajorGlVersion() >= 3) {
                glDrawRangeElements(mesh.primitiveMode, 0, vertexCount - 1, drawCount,
                                    GL_UNSIGNED_SHORT, nullptr);
            } else {
                glDrawElements(mesh.primitiveMode, drawCount, GL_UNSIGNED_SHORT, nullptr);
            }
            elementsCount -= drawCount;
            vertexData += vertexCount * vertices.stride;
        }
    } else if (indices.bufferObject || indices.indices) {
        if (mCaches->extensions().getMajorGlVersion() >= 3) {
            glDrawRangeElements(mesh.primitiveMode, 0, mesh.vertexCount - 1, mesh.elementCount,
                                GL_UNSIGNED_SHORT, indices.indices);
        } else {
            glDrawElements(mesh.primitiveMode, mesh.elementCount, GL_UNSIGNED_SHORT,
                           indices.indices);
        }
    } else {
        glDrawArrays(mesh.primitiveMode, 0, mesh.elementCount);
    }

...

    // -----------------------------------
    // ---------- Mesh teardown ----------
    // -----------------------------------
    if (vertices.attribFlags & VertexAttribFlags::Alpha) {
        glDisableVertexAttribArray(alphaLocation);
    }
    if (vertices.attribFlags & VertexAttribFlags::Color) {
        glDisableVertexAttribArray(colorLocation);
    }

    GL_CHECKPOINT(MODERATE);
}
```
都是套路操作，首先执行在Glop中初始化好的GLProgram对象，接着处理vbo和vao对象，并且bindPositionVertexPointer告诉OpenGL es应该如何进行操作解析vbo和vao。最后根据条件执行glElementDraw还是glDrawArrays方法，根据索引绘制还是默认的进行glDrawArrays绘制。

最后通过渲染管道的swapBuffers，把Surface中的内存发送到SF进程中处理。最后回调在ViewRootImpl设置的FrameCompleteCallback，也就是pendingDrawFinished方法。


### ViewRootImpl pendingDrawFinished
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
最后和之前[onDraw](https://www.jianshu.com/p/a4fb6a02ad53)总结一文一样，通知WMS已经执行完了draw流程，允许下一次performTraversals可以进行relayoutWindow对窗体进行测量。


到这里硬件渲染一次渲染就结束了。

### Vsync信号 的硬件刷新原理
硬件渲染但是还没有结束，硬件渲染的RenderThread还监听了Vsync信号。实际上为了更加快捷的进行渲染，RenderThread会自己在native进行监听，并且执行类似ViewRootImpl的循环流程。

我们来看看上一篇文章和大家聊过的，当Vsync信号到来最终会执行如下方法：
```cpp
void RenderThread::dispatchFrameCallbacks() {
    ATRACE_CALL();
    mFrameCallbackTaskPending = false;

    std::set<IFrameCallback*> callbacks;
    mFrameCallbacks.swap(callbacks);

    if (callbacks.size()) {
        requestVsync();
        for (std::set<IFrameCallback*>::iterator it = callbacks.begin(); it != callbacks.end();
             it++) {
            (*it)->doFrame();
        }
    }
}
```

那么这个IFrameCallback对象是何时注册进来的呢？我之前在聊ViewRootImpl的时候有一个方法我忽略了。
```java
    void scheduleTraversals() {
        if (!mTraversalScheduled) {
            mTraversalScheduled = true;
            mTraversalBarrier = mHandler.getLooper().getQueue().postSyncBarrier();
            mChoreographer.postCallback(
                    Choreographer.CALLBACK_TRAVERSAL, mTraversalRunnable, null);
...
            notifyRendererOfFramePending();
            pokeDrawLockIfNeeded();
        }
    }
```
每当mChoreographer发送一个CALLBACK_TRAVERSAL到Handler的Loop中进行下一轮的View绘制流程处理后，会执行notifyRendererOfFramePending方法：
```java
    void notifyRendererOfFramePending() {
        if (mAttachInfo.mThreadedRenderer != null) {
            mAttachInfo.mThreadedRenderer.notifyFramePending();
        }
    }
```
而这个方法实际上就是ThreadedRenderer通过RenderProxy，调用了CanvasContext的pushBackFrameCallback：
```cpp
void CanvasContext::notifyFramePending() {
    mRenderThread.pushBackFrameCallback(this);
}
```
到这里，才真正的注册了CanvasContext的回调。换句话说，每当RenderThread接收到了VSync信号就会走到CanvasContext的doFrame回调中。

```cpp
void CanvasContext::doFrame() {
    if (!mRenderPipeline->isSurfaceReady()) return;
    prepareAndDraw(nullptr);
}
```

```cpp
void CanvasContext::prepareAndDraw(RenderNode* node) {

    nsecs_t vsync = mRenderThread.timeLord().computeFrameTimeNanos();
    int64_t frameInfo[UI_THREAD_FRAME_INFO_SIZE];
    UiFrameInfoBuilder(frameInfo).addFlag(FrameInfoFlags::RTAnimation).setVsync(vsync, vsync);

    TreeInfo info(TreeInfo::MODE_RT_ONLY, *this);
    prepareTree(info, frameInfo, systemTime(CLOCK_MONOTONIC), node);
    if (info.out.canDrawThisFrame) {
        draw();
    } else {
        waitOnFences();
    }
}
```
能看到这个过程和之前的几乎一致：
- 1.prepareTree 处理整个View的显示层级,构建绘制操作recordedOp以及生成OffscreenBuffer
- 2.draw 进行渲染

如果此时已经在绘制了，canDrawThisFrame为false，则对fence进行等待。

## 总结
到这里硬件渲染的主要流程和原理和大家已经解析，关于Skia的渲染管道以及Vulkan相关渲染管道相关的操作，在这里就不多赘述了。不过关于Skia相关的专题会等到IMS，PMS，另外三个组建和大家聊完了，我们再回头看看。

老规矩，先让我们上时序图：
![硬件渲染流程.jpg](/images/硬件渲染流程.jpg)

关于总体流程的总结可以阅读我写的上一篇文章：[Android 重学系列 View的绘制流程(六) 硬件渲染(上)](https://www.jianshu.com/p/c84bfa909810)。

我们只需要关注ThreadedRenderer绘制流程的中做了什么？当ThreadedRenderer准备开始绘制，则会通知RenderProxy，把绘制事件压入RenderThread进行排队执行后，从DrawFrameTask的run方法开始绘制。

在DrawFrameTask中主要执行了两个步骤：

- 1.syncFrameState 从名字就能知道是同步每一帧的状态，而这个方法的核心就是调用prepareTree从RootRenderNode开始遍历整个View显示层级。
    - 第一步执行了drawGLFunctor2注入的OpenGL的回调方法；
    - 第二步尝试着读取当前RenderNode对应的纹理缓存，如果缓存生效可以不阻塞ui线程；
    - 第三步根据层级的脏区计算出整个视图的总脏区；
    - 第四步把需要刷新的RenderNode记录到LayerUpdateQueue中
    - 第五步为每一个需要绘制View的RenderNode，创建一个离屏渲染缓存

- 2.CanvasContext的draw方法，执行如下几个步骤：
    - 第一步通过computeDirtyRect把计算好的脏区拷贝到包含OpenGL es的EGLSurface对象Frame中
    - 第二步 构建FrameBuilder对象，并且调用deferLayers方法。在deferLayer方法中，先通过saveForLayer保存每一个LayerBuilder在FrameBuilder的LayerBuilders集合中；接着调用deferNodeOps，调用buildZSortedChildList处理每一个子RenderNode的z轴上的顺序，defer3dChildren处理每一个子RenderNode上是否需要对阴影进行处理。遍历保存在DisplayList对象中的chunk集合对象，以chunk记录的索引获取当前的RecordedOp绘制操作，并且调用每一个操作的defer(类型)Op,把RecordedOp转化为BakeStateOp对象

- 第三步 调用FrameBuilder的replayBakedOps方法，这个方法会通过一个BakedOpDispatcher对象为对应的绘制类型，找到对应on(类型)Op方法 构建一个Glop对象传递到BakedOpRenderer 中开始渲染。如果遇到绘制类型，画笔，透明度一致则变成找到onMerged(类型)Ops，合并绘制操作之后，最后才构成Glop对象传递到BakedOpRenderer 中开始渲染。

- 第四步 BakedOpRenderer最后会通过RenderState真正的开始渲染。同时会解开通过建造者模式构造的Glop对象内容，开始OpenGL es的绘制。

经历了2大步骤，9个小步骤才在RenderThread中完成了渲染的行为。

当然，在其中绘制操作对象RecordedOp经历了几个比较重大的转变。
![RecordedOp转化.png](/images/RecordedOp转化.png)



## 思考
我们来比较一下硬件渲染系列文章以及[软件渲染](https://www.jianshu.com/p/a4fb6a02ad53)文章，可以发现两者最大的不同。软件渲染所有的工作都在ui主线程中的Looper排队处理渲染事件；

而硬件渲染不同的地方就是一旦到达了performDraw开始绘制的步骤，所有的流程就会切换到渲染线程RenderThread的Looper中排队渲染。

下面是一个示意图：
![软硬件渲染逻辑比对.jpg](/images/软硬件渲染逻辑比对.jpg)

所以很多说ui渲染优化说打开硬件渲染进行优化，这是正确的。这是因为在这些流程中最消耗事件就是绘制。如果我们把绘制的步骤放在另外一个RenderThread线程中的Looper执行，就能降低ui线程的压力。

那么我们能不能再大胆一点，把performMeasure和performLayout，也就是测量和排版统统移动到另外一个测量线程中完成测量。让我们的主线程完全脱离ui线程的逻辑，成为名副其实的业务线程。

### 关于ui渲染优化和Litho的介绍
实际上确实有人这么做了，facebook开源了一个[Litho](https://github.com/facebook/litho)的异步测量的绘制库。Litho这个库最大的问题就是抛弃了Android原来流水线式开发，需要接受一种新的理念，更加接近React的理念，万物皆组件(Component)。在这一点的设计思路上flutter倒是学习了不少。litho和Android的布局比起来更为的简单。它只有一种布局那就是flexbox布局，由于在代码中编写，所以目前为止还没办法在AS中直观看到编写结果。
![litho线程设计.png](/images/litho线程设计.png)



它又是怎么工作的呢？这里不会有太多介绍，下面是一个示意图：
![litho工作原理.png](/images/litho工作原理.png)

为了能够在多线程中正常进行控件的测量，Litho为每一个控件添加几个状态：
- @OnPrepare，准备阶段，进行一些初始化操作。
- @OnMeasure，负责布局的计算。
- @OnBoundsDefined，在布局计算完成后挂载视图前做一些操作。
- @OnCreateMountContent，创建需要挂载的视图。
- @OnMount，挂载视图，完成布局相关的设置。
- @OnBind，绑定视图，完成数据和视图的绑定。
- @OnUnBind，解绑视图，主要用于重置视图的数据相关的属性，防止出现复用问题。
- @OnUnmount，卸载视图，主要用于重置视图的布局相关的属性，防止出现复用问题。

其原理是怎么样子的呢？Litho的源码也不难，有空和大家聊聊。他的设计和flutter有同工异曲之妙。Flutter实际上是在Activity中有且只有一个FlutterNativeView，之后所有的绘制操作都在这个View上通过Skia进行。而LItho也是一样，全局只有一个LithoView，所有的绘制都是从LithoView开始，在LithoView中通过yoga库不断的给LithoView添加绘制节点(YogaNode)。

那么对于Android系统来说，onMeasure和onLayout以及onDraw只会有一个层级那就是LithoView。
![Litho.jpg](/images/Litho.jpg)
能看到在Litho中已经把performMeasure，performLayout，performDraw接管过来了。

整个流程中，只要LithoView需要开始绘制了从onMeasure开始进行布局就会完全把遍历组件树的逻辑接管过来，执行上面几个注解对应的步骤。当执行完布局的测量和摆放后，就会执行Yoga节点的绘制。当然LithoView默认是同步布局测量，只有在RecyclerView类似的列表组件中，才会进行异步布局。当然它也如下核心方法：
```java
  private void setRootAndSizeSpecInternal(
      Component root,
      int widthSpec,
      int heightSpec,
      boolean isAsync,
      @Nullable Size output,
      @CalculateLayoutSource int source,
      int externalRootVersion,
      String extraAttribution,
      @Nullable TreeProps treeProps)
```
当需要更新的时候，也有对应的Async方法。
```java
void updateStateInternal(boolean isAsync, String attribution, boolean isCreateLayoutInProgress)
```

Android原生为什么不支持异步布局？虽然网上说的原因有二：
- 1.View的属性是可变的，只要属性发生变化就可能导致布局变化，因此需要重新计算布局，那么提前计算布局的意义就不大了。Litho的属性唯一，因此有了提前计算布局的可能。
- 2.提前异步布局就意味着要提前创建好接下来要用到的一个或者多个条目的视图，而Android原生的View作为视图单元，不仅包含一个视图的所有属性，而且还负责视图的绘制工作。如果要在绘制前提前去计算布局，就需要预先去持有大量未展示的View实例，大大增加内存占用。而Litho在底层有一个DefaultMountContentPool 挂载池子对组件对象进行循环利用，只有经过挂载之后的View才会显示到屏幕上。

第二点我是赞同的，但是第一点我对这个说法抱有意见。我们的确不能忽视异步线程预先测量变化程度大View中的所做无意义的工作。

但是别忘了在整个ui线程中我们不仅仅只有View的绘制工作。更多的还有我们的业务代码，往往一开始小小需求到没什么太大的问题。但是一旦到达了一定的量级对于16ms一帧数的会造成不少负担(理想情况下允许掉帧1-3帧)。一般我们开发为了处理这种情况会从一个线程池中生成一个线程处理繁重的业务，比如io操作。不过有的时候，不一定是io操作也会造成方法耗时超出理想阈值，可能是一片片碎小的业务代码组合造成(因此我们需要对方法插桩监控)。


因此，在线程上下文切换代价不大的情况下，为了尽可能降低绘制的压力，我们完全可以对performMeasure和performLayout进行异步处理。

当然除了有这种优化手段，当然可以从Litho中得到一些灵感，如提前构造View对象等。使用X2C手段从xml转化为code，减少view对象实例化时间;复杂的像素操作可以你用RenderScript进行GPU的优化操作;可以使用View.animate生成ViewPropertyAnimator的硬件渲染动画。

### 横向比较浏览器的渲染流程后思考
实际上在我看来RenderThread的硬件渲染绘制流程和浏览器的绘制流程设计十分相似。
虽然，我没有专门的阅读过webview的内核代码，但是一些基础原理还是明白的。这里我们简单来比较一下，这里就以Chrome浏览器原理为例子。
![浏览器工作原理.png](/images/浏览器工作原理.png)

能看到Android系统如果打开了硬件渲染后，其实整个流程就和浏览器的渲染流程十分接近了。

在浏览器中，网络请求后，获取到的DOM树后，进行style的计算，进行Layout排版生成对应的树。实际上和Android的performMeasure和performLayout两个流程做的事情几乎是一致的，都是对布局的大小和位置进行了测定。

当浏览器根据LayoutTree生成了LayerTree，跨越到合成线程分成更小的图块，再到栅格线程每个图层进行栅格化后，传递回合成线程生成每一帧。

这个步骤实际上和硬件渲染有点相似。但是硬件渲染做的更多。在RenderThread线程中对所有的绘制节点RenderNode(对应上DOM树中的节点)会分配离屏渲染内存生成一个个LayerBuilder保存到FrameBuilder中。也就相当于浏览器中的Layer Tree步骤。

对于硬件渲染来说最小单位的图块就是RenderNode，每一个RenderNode都有自己的缓存。也可以对应上tiles图块的步骤。但是后面的步骤就不相同了。

在ThreadedRenderer的遍历View 树的时候，虽然如ImageView会调用Drawable的绘制方法绘制到DisplayListCanvas中，由于DisplayListCanvas本质上是一个RecordedCanvas，不会立即绘制而是把所有的绘制操作保存起来，等到后续同一合成绘制。这么做就极大的优化了整个硬件渲染的流程，不需要时刻操作OpenGL es和GPU进行交互，通过合成绘制操作，延后统一执行减少GPU的计算次数，就能大大增加了整个系统的绘制性能。


最后，Android系统通过GPU栅格化，合成每一帧EGLSurface直接发送到SF进程中进一步处理。

还有一点启示，那就是为什么无论软硬件，每一个View或者RenderNode都需要自己的缓存呢？从chrome得到的启发是tiles的图块划分是在一个名为合成线程中完成的。

对比上Android系统，实际上也有合成的概念。每一个renderNode有自己的缓存纹理，每一个View有自己的缓存Bitmap。那么就有如下的设计图：

![View的合成思想.png](/images/View的合成思想.png)

由于所有的绘制操作都有延后性，只保存了绘制操作对象，因此每一个纹理或者View如果有自己的缓存，可以统一在LayerBuilder中进行合成，最终通过OpenGL es进行栅格化，传送到SF进程。通过这种方式把View/RenderNode一块块组合起来就能快速的组成一个全新的一帧。我称这种行为为横向帧合成。

当然，为什么推荐硬件渲染，另一个原因是它能申请更大的纹理缓存。而不是软件渲染中只有 480 * 800 * 4这么大。

当然也有纵向帧合成，这个就是SF的HWC，HardwareComposer的作用，一个个Client对应的Layer对象进行纵向(z轴)合成。

## 后记
写硬件渲染这两篇文章倒是重新写了一遍，发现对象有点多，需要重新理清思路，所以才这么久写完。

到这里View的渲染主要逻辑已经和大家理清楚了，暂时可以收尾了。下一次你再见到我写绘制流程，估计就是关于Skia源码解析了。但是别太得意这仅仅只是熟悉的程度，其实里面还有不少东西可以探究的，比如说动画等。

接下来我们来探索IMS与点击事件的传递原理。

最后关于Litho更多的基础知识可以阅读：[https://tech.meituan.com/2019/03/14/litho-use-and-principle-analysis.html](https://tech.meituan.com/2019/03/14/litho-use-and-principle-analysis.html)






