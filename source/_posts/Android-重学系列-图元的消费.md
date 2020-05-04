---
title: Android 重学系列 图元的消费
top: false
cover: false
date: 2020-02-14 09:24:17
img:
tag:
description:
author: yjy239
summary:
categories: SurfaceFlinger
tags:
- Android
- Android Framework
---

# 前言
经过前两篇文章的解析，我们彻底的理解GraphicBuffer的生产端究竟做了什么。本文就来讨论GraphicBuffer是怎么消费。

整个图元的消费到合成，最后到通过hwc发送到fb。由于整个流程十分长，中间有许多细节，我将会挑出核心的思想来和大家聊聊其中的原理。

还记得，我在[GraphicBuffer的诞生](https://www.jianshu.com/p/3bfc0053d254)里面具体了聊了queuebuffer最后会通过IConsumerListener的回调通知消费者进行消费。

我们接着继续看看接下来的逻辑。

如果遇到问题，可以到本文讨论[https://www.jianshu.com/p/67c1e350fe0d](https://www.jianshu.com/p/67c1e350fe0d)


# 正文
让我们先来回忆一下，在[图元缓冲队列初始化](https://www.jianshu.com/p/a2b5f82cf75f)一文中曾经总结的UML图。

![Layer与缓冲队列的设计.png](/images/Layer与缓冲队列的设计.png)



文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[BufferQueueProducer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/BufferQueueProducer.cpp)

```cpp
           frameAvailableListener = mCore->mConsumerListener;
        }
        Mutex::Autolock lock(mCallbackMutex);
        while (callbackTicket != mCurrentCallbackTicket) {
            mCallbackCondition.wait(mCallbackMutex);
        }

        if (frameAvailableListener != NULL) {
            frameAvailableListener->onFrameAvailable(item);
        } else if (frameReplacedListener != NULL) {
            frameReplacedListener->onFrameReplaced(item);
        }
```

frameAvailableListener就是ProxyConsumerListener。这个对象持有ConsumeBase。当进行回调时候就会回调到ConsumeBase的mFrameAvailableListener。
```cpp
void ConsumerBase::onFrameAvailable(const BufferItem& item) {

    sp<FrameAvailableListener> listener;
    { // scope for the lock
        Mutex::Autolock lock(mFrameAvailableMutex);
        listener = mFrameAvailableListener.promote();
    }

    if (listener != NULL) {
        listener-> (item);
    }
}
```
而ConsumeBase的mFrameAvailableListener是BufferLayer注册进来的。到这里倒在缓冲队列的初始化聊过。

## BufferLayer onFrameAvailable
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayer.cpp)

```cpp
void BufferLayer::onFrameAvailable(const BufferItem& item) {
    // Add this buffer from our internal queue tracker
    { // Autolock scope
        Mutex::Autolock lock(mQueueItemLock);
        mFlinger->mInterceptor->saveBufferUpdate(this, item.mGraphicBuffer->getWidth(),
                                                 item.mGraphicBuffer->getHeight(),
                                                 item.mFrameNumber);

        if (item.mFrameNumber == 1) {
            mLastFrameNumberReceived = 0;
        }

        // Ensure that callbacks are handled in order
        while (item.mFrameNumber != mLastFrameNumberReceived + 1) {
            status_t result = mQueueItemCondition.waitRelative(mQueueItemLock,
                                                               ms2ns(500));
...
        }

        mQueueItems.push_back(item);
        android_atomic_inc(&mQueuedFrames);


        mLastFrameNumberReceived = item.mFrameNumber;
        mQueueItemCondition.broadcast();
    }

    mFlinger->signalLayerUpdate();
}
```

这里做的事情很简单，增加mQueuedFrames的计数，mQueueItems添加一个BufferItem，并唤醒其他线程入队的阻塞。接着调用SF的signalLayerUpdate。

## SurfaceFlinger signalLayerUpdate
文件：[rameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)
```cpp
void SurfaceFlinger::signalLayerUpdate() {
    mEventQueue->invalidate();
}
```
接着调用到MessageQueue的invalidate
```cpp
void MessageQueue::invalidate() {
    mEvents->requestNextVsync();
}
```
在MessageQueue中请求下一个同步信号

### EventThread::Connection::requestNextVsync
```cpp
void EventThread::Connection::requestNextVsync() {
    mEventThread->requestNextVsync(this);
}
```

```cpp
void EventThread::requestNextVsync(const sp<EventThread::Connection>& connection) {
    std::lock_guard<std::mutex> lock(mMutex);

    if (mResyncWithRateLimitCallback) {
        mResyncWithRateLimitCallback();
    }

    if (connection->count < 0) {
        connection->count = 0;
        mCondition.notify_all();
    }
}
```
EventThread::Connection的count的标志位实际上是指vysnc事件是每隔几个事件通知。此时是count在初始化的时候是-1.此时强制设置为0，说明只有调用requestNextVsync强制唤醒才会返回vysnc通知。


整体设计可以看我写第一篇[SurfaceFlinger 的初始化](https://www.jianshu.com/p/8e29c3d9b27a)。mResyncWithRateLimitCallback这个方法用于调整DispSync的时间戳。假如是第一次初始化，因此count还是-1.因此直接唤醒waitForEventLocked中的等待。
```cpp
        if (!timestamp && !eventPending) {
            // wait for something to happen
            if (waitForVSync) {
                bool softwareSync = mUseSoftwareVSync;
                auto timeout = softwareSync ? 16ms : 1000ms;
                if (mCondition.wait_for(*lock, timeout) == std::cv_status::timeout) {
                    if (!softwareSync) {
                        ALOGW("Timed out waiting for hw vsync; faking it");
                    }
                    // FIXME: how do we decide which display id the fake
                    // vsync came from ?
                    mVSyncEvent[0].header.type = DisplayEventReceiver::DISPLAY_EVENT_VSYNC;
                    mVSyncEvent[0].header.id = DisplayDevice::DISPLAY_PRIMARY;
                    mVSyncEvent[0].header.timestamp = systemTime(SYSTEM_TIME_MONOTONIC);
                    mVSyncEvent[0].vsync.count++;
                }
            } else {
                mCondition.wait(*lock);
            }
```
此时timestamp一开始是0，当设置了时间戳，将不会直接等待跳出死循环，为0则会。eventPending是由接进来的屏幕的mPendingEvents判断是否为空，不为空则是true。 如果EventThread有Connection接进来进行监听将会设置为waitForVSync为true。

当我们进行初始化的时候，由于没有屏幕接进来。因此第一个信号是DISPLAY_EVENT_VSYNC。进行刷新。


#### MessageQueue的回调 
```cpp
int MessageQueue::eventReceiver(int /*fd*/, int /*events*/) {
    ssize_t n;
    DisplayEventReceiver::Event buffer[8];
    while ((n = DisplayEventReceiver::getEvents(&mEventTube, buffer, 8)) > 0) {
        for (int i = 0; i < n; i++) {
            if (buffer[i].header.type == DisplayEventReceiver::DISPLAY_EVENT_VSYNC) {
                mHandler->dispatchInvalidate();
                break;
            }
        }
    }
    return 1;
}
```
能看到整个MessageQueue的回调只接受DISPLAY_EVENT_VSYNC，进行刷新。

```cpp
void MessageQueue::Handler::dispatchInvalidate() {
    if ((android_atomic_or(eventMaskInvalidate, &mEventMask) & eventMaskInvalidate) == 0) {
        mQueue.mLooper->sendMessage(this, Message(MessageQueue::INVALIDATE));
    }
}

void MessageQueue::Handler::handleMessage(const Message& message) {
    switch (message.what) {
        case INVALIDATE:
            android_atomic_and(~eventMaskInvalidate, &mEventMask);
            mQueue.mFlinger->onMessageReceived(message.what);
            break;
        case REFRESH:
            android_atomic_and(~eventMaskRefresh, &mEventMask);
            mQueue.mFlinger->onMessageReceived(message.what);
            break;
    }
}
```
发送了一个INVALIDATE消息交给SF的onMessageReceive处理。


## SF onMessageReceive 处理 INVALIDATE消息
```cpp
void SurfaceFlinger::onMessageReceived(int32_t what) {
    ATRACE_CALL();
    switch (what) {
        case MessageQueue::INVALIDATE: {
            bool frameMissed = !mHadClientComposition &&
                    mPreviousPresentFence != Fence::NO_FENCE &&
                    (mPreviousPresentFence->getSignalTime() ==
                            Fence::SIGNAL_TIME_PENDING);

            if (frameMissed) {
                mTimeStats.incrementMissedFrames();
                if (mPropagateBackpressure) {
                    signalLayerUpdate();
                    break;
                }
            }

            updateVrFlinger();

            bool refreshNeeded = handleMessageTransaction();
            refreshNeeded |= handleMessageInvalidate();
            refreshNeeded |= mRepaintEverything;
            if (refreshNeeded) {
                signalRefresh();
            }
            break;
        }
        case MessageQueue::REFRESH: {
            handleMessageRefresh();
            break;
        }
    }
}
```
MessageQueue的消息处理函数中SF处理了两种消息一种是INVALIDATE校验无效的区域。校验方式两个步骤：
- 1.handleMessageTransaction 处理事务，如交换绘制mDrawState和mCurrentState的焦点状态，记录每一个Layer当前需要绘制的各自的Layer，如果判断到已经添加了Layer进来，则需要打开判断可视区域标志位。发现Layer被移除了需要更新脏(已经变动)区域
- 2.handleMessageInvalidate 核心就是latch每一个Layer中的图元进行acquire的操作。一旦判断到每一Layer中有latch了图元，说有新的图元需要消费，或者还有图元没有消费的，则需要主动调用signalLayerUpdate()进行下一个循环的INVALIDATE发送。

最后是否需要调用signalRefresh，handleMessageTransaction需要处理事务或者handleMessageInvalidate判断到有新图元。则会通过signalRefresh进入下一个循环进行Refresh消息的发送。
```cpp
void SurfaceFlinger::signalRefresh() {
    mRefreshPending = true;
    mEventQueue->refresh();
}
```

知道核心思想，我们再来每一个步骤中做了什么。


### handleMessageTransaction
```cpp
uint32_t SurfaceFlinger::peekTransactionFlags() {
    return android_atomic_release_load(&mTransactionFlags);
}

bool SurfaceFlinger::handleMessageTransaction() {
    uint32_t transactionFlags = peekTransactionFlags();
    if (transactionFlags) {
        handleTransaction(transactionFlags);
        return true;
    }
    return false;
}
```
我们先讨论打开了mTransactionFlags事务的标志位。一旦Layer，Display等和显示相关的数据结构发生变化都需要打开这个标志位。
```cpp
void SurfaceFlinger::handleTransaction(uint32_t transactionFlags)
{

    State drawingState(mDrawingState);

    Mutex::Autolock _l(mStateLock);
    const nsecs_t now = systemTime();
...

    mVsyncModulator.onTransactionHandled();
    transactionFlags = getTransactionFlags(eTransactionMask);
    handleTransactionLocked(transactionFlags);

    mLastTransactionTime = systemTime() - now;

    invalidateHwcGeometry();
}

void SurfaceFlinger::invalidateHwcGeometry()
{
    mGeometryInvalid = true;
}
```
核心是handleTransactionLocked。
```cpp
void SurfaceFlinger::handleTransactionLocked(uint32_t transactionFlags)
{
    // 通知所有的Layer可以进行合成
    mCurrentState.traverseInZOrder([](Layer* layer) {
        layer->notifyAvailableFrames();
    });


    if (transactionFlags & eTraversalNeeded) {
        mCurrentState.traverseInZOrder([&](Layer* layer) {
            uint32_t trFlags = layer->getTransactionFlags(eTransactionNeeded);
            if (!trFlags) return;

            const uint32_t flags = layer->doTransaction(0);
            if (flags & Layer::eVisibleRegion)
                mVisibleRegionsDirty = true;
        });
    }

    /*
     * Perform display own transactions if needed
     */

    if (transactionFlags & eDisplayTransactionNeeded) {
        processDisplayChangesLocked();
        processDisplayHotplugEventsLocked();
    }

    if (transactionFlags & (eDisplayLayerStackChanged|eDisplayTransactionNeeded)) {

        sp<const DisplayDevice> disp;
        uint32_t currentlayerStack = 0;
        bool first = true;
        mCurrentState.traverseInZOrder([&](Layer* layer) {
            uint32_t layerStack = layer->getLayerStack();
            if (first || currentlayerStack != layerStack) {
                currentlayerStack = layerStack;
                disp.clear();
                for (size_t dpy=0 ; dpy<mDisplays.size() ; dpy++) {
                    sp<const DisplayDevice> hw(mDisplays[dpy]);
                    if (layer->belongsToDisplay(hw->getLayerStack(), hw->isPrimary())) {
                        if (disp == nullptr) {
                            disp = std::move(hw);
                        } else {
                            disp = nullptr;
                            break;
                        }
                    }
                }
            }

            if (disp == nullptr) {
                disp = getDefaultDisplayDeviceLocked();
            }

            if (disp != nullptr) {
                layer->updateTransformHint(disp);
            }

            first = false;
        });
    }


    if (mLayersAdded) {
        mLayersAdded = false;
        mVisibleRegionsDirty = true;
    }

    if (mLayersRemoved) {
        mLayersRemoved = false;
        mVisibleRegionsDirty = true;
        mDrawingState.traverseInZOrder([&](Layer* layer) {
            if (mLayersPendingRemoval.indexOf(layer) >= 0) {
                Region visibleReg;
                visibleReg.set(layer->computeScreenBounds());
                invalidateLayerStack(layer, visibleReg);
            }
        });
    }

    commitTransaction();

    updateCursorAsync();
}
```
- 1.第一个从底部向顶部循环遍历mCurrentState中的Layer，通知每一个被SyncPoint完成了doTransaction步骤而阻塞的Layer。让Layer可以进行合成的准备。
```cpp
void BufferLayer::notifyAvailableFrames() {
    auto headFrameNumber = getHeadFrameNumber();
    bool headFenceSignaled = headFenceHasSignaled();
    Mutex::Autolock lock(mLocalSyncPointMutex);
    for (auto& point : mLocalSyncPoints) {
        if (headFrameNumber >= point->getFrameNumber() && headFenceSignaled) {
            point->setFrameAvailable();
        }
    }
}
```

- 2.从底部遍历每一个Layer的doTransaction方法。处理可视区域。
- 3.检查每一个Layer中的所对应的显示屏id类型，同时更新里面的变换矩阵。
- 4.如果通过Client添加过Layer就会打上mLayersAdded，此时将会关闭这个标志位，同时打开mVisibleRegionsDirty，让后续的步骤检测变动的可视区域。
- 5.如果Layer有移除，则调用invalidateLayerStack更新DisplayDevice中原有的可视脏区。
```cpp
void SurfaceFlinger::invalidateLayerStack(const sp<const Layer>& layer, const Region& dirty) {
    for (size_t dpy=0 ; dpy<mDisplays.size() ; dpy++) {
        const sp<DisplayDevice>& hw(mDisplays[dpy]);
        if (layer->belongsToDisplay(hw->getLayerStack(), hw->isPrimary())) {
            hw->dirtyRegion.orSelf(dirty);
        }
    }
}
```

让我们看看doTransaction核心方法。

#### Layer  doTransaction
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[Layer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/Layer.cpp)

```cpp
uint32_t Layer::doTransaction(uint32_t flags) {

    pushPendingState();
    Layer::State c = getCurrentState();
    if (!applyPendingStates(&c)) {
        return 0;
    }

    const Layer::State& s(getDrawingState());

    const bool sizeChanged = (c.requested.w != s.requested.w) || (c.requested.h != s.requested.h);

    if (sizeChanged) {
...
        setDefaultBufferSize(c.requested.w, c.requested.h);
    }

    const bool resizePending = ((c.requested.w != c.active.w) || (c.requested.h != c.active.h)) &&
            (getBE().compositionInfo.mBuffer != nullptr);
    if (!isFixedSize()) {
        if (resizePending && getBE().compositionInfo.hwc.sidebandStream == nullptr) {
            flags |= eDontUpdateGeometryState;
        }
    }

    if (!(flags & eDontUpdateGeometryState)) {
        Layer::State& editCurrentState(getCurrentState());

        if (mFreezeGeometryUpdates) {
            float tx = c.active.transform.tx();
            float ty = c.active.transform.ty();
            c.active = c.requested;
            c.active.transform.set(tx, ty);
            editCurrentState.active = c.active;
        } else {
            editCurrentState.active = editCurrentState.requested;
            c.active = c.requested;
        }
    }

    if (s.active != c.active) {
        flags |= Layer::eVisibleRegion;
    }

    if (c.sequence != s.sequence) {
        // invalidate and recompute the visible regions if needed
        flags |= eVisibleRegion;
        this->contentDirty = true;

        const uint8_t type = c.active.transform.getType();
        mNeedsFiltering = (!c.active.transform.preserveRects() || (type >= Transform::SCALE));
    }

    if (c.flags & layer_state_t::eLayerHidden) {
        clearSyncPoints();
    }

    // Commit the transaction
    commitTransaction(c);
    return flags;
}

void Layer::commitTransaction(const State& stateToCommit) {
    mDrawingState = stateToCommit;
}

```
- 1.就是检测BufferLayer中的mCurrentState和上一帧已经绘制了的mDrawState的差距。如果发现两者的requested的区域发生了变动，则会调用setDefaultBufferSize，重新定义图元消费BufferLayerConsumer的默认宽高。
```cpp
void BufferLayer::setDefaultBufferSize(uint32_t w, uint32_t h) {
    mConsumer->setDefaultBufferSize(w, h);
}
```
- 2. 检测mCurrentState中requested和active之间的几何宽高。在每一个Layer::State中都会存在两个几何结构体requested和active。当我们设置了Surface了postion等在屏幕上显示的几何参数会先设置到mCurrentState.requested中。也就是说requested等待绘制的参数。active则是显示中的几何参数。一旦发生变化则设resizePending为true。
- 3. isFixedSize则是判断当前对应的Layer是否被冻结不允许变化大小，假设此时是关闭的，且sidebandStream是空的。此时不会立即更新requested和active的区域。回到后面acquire步骤时候进行处理。

- 4. 最后更新mCurrentState为mDrawState。

这里需要注意，和SF的State不一样。Layer::State将会记录Layer显示相关的参数。


#### SF commitTransaction
```cpp
void SurfaceFlinger::commitTransaction()
{
    if (!mLayersPendingRemoval.isEmpty()) {
        // Notify removed layers now that they can't be drawn from
        for (const auto& l : mLayersPendingRemoval) {
            recordBufferingStats(l->getName().string(),
                    l->getOccupancyHistory(true));
            l->onRemoved();
        }
        mLayersPendingRemoval.clear();
    }


    mAnimCompositionPending = mAnimTransactionPending;

    mDrawingState = mCurrentState;
    mCurrentState.colorMatrixChanged = false;

    mDrawingState.traverseInZOrder([](Layer* layer) {
        layer->commitChildList();
    });
    mTransactionPending = false;
    mAnimTransactionPending = false;
    mTransactionCV.broadcast();
}
```
此时也会更新SF中的mDrawingState，同时会更新每一个Layer中对应处理完的事务状态。

##### BufferLayer commitChildList
```cpp
void Layer::commitChildList() {
    for (size_t i = 0; i < mCurrentChildren.size(); i++) {
        const auto& child = mCurrentChildren[i];
        child->commitChildList();
    }
    mDrawingChildren = mCurrentChildren;
    mDrawingParent = mCurrentParent;
}
```
对应的每一个Layer同时会更新之后需要绘制的父Layer和子Layer。


### handleMessageInvalidate 检测变动区域
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)

```cpp
bool SurfaceFlinger::handleMessageInvalidate() {
    return handlePageFlip();
}
```
```cpp
bool SurfaceFlinger::handlePageFlip()
{

    nsecs_t latchTime = systemTime();

    bool visibleRegions = false;
    bool frameQueued = false;
    bool newDataLatched = false;

    mDrawingState.traverseInZOrder([&](Layer* layer) {
        if (layer->hasQueuedFrame()) {
            frameQueued = true;
            if (layer->shouldPresentNow(mPrimaryDispSync)) {
                mLayersWithQueuedFrames.push_back(layer);
            } else {
                layer->useEmptyDamage();
            }
        } else {
            layer->useEmptyDamage();
        }
    });

    for (auto& layer : mLayersWithQueuedFrames) {
        const Region dirty(layer->latchBuffer(visibleRegions, latchTime));
        layer->useSurfaceDamage();
        invalidateLayerStack(layer, dirty);
        if (layer->isBufferLatched()) {
            newDataLatched = true;
        }
    }

    mVisibleRegionsDirty |= visibleRegions;

    if (frameQueued && (mLayersWithQueuedFrames.empty() || !newDataLatched)) {
        signalLayerUpdate();
    }

    return !mLayersWithQueuedFrames.empty() && newDataLatched;
}
```
首先要注意，在这个方法开始SF需要正式消费图元。此时会有一个问题，比如有个Layer.此时线程1通知了Layer有了一个新的图元进来了，还没来的消费又进来了一个图元。此时我们需要再进行消费？假如出现了宽高变化怎么办？那不就浪费了doTransaction步骤的宽高变化记录吗。因此我们需要一个latch方法，锁住图元。

一旦检测到图元还有没有消费的或者还没有到了需要显示时候，就会调用signalLayerUpdate，让下一个循环回来消费。

这个方法判断是否需要refresh的依据，其实就是判断两个情况同时成立，第一个是mLayersWithQueuedFrames不为空，有需要显示的Layer。同时latch上锁图元成功了。

#### BufferLayer  shouldPresentNow
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayer.cpp)

```cpp

bool BufferLayer::shouldPresentNow(const DispSync& dispSync) const {
    if (mSidebandStreamChanged || mAutoRefresh) {
        return true;
    }

    Mutex::Autolock lock(mQueueItemLock);
    if (mQueueItems.empty()) {
        return false;
    }
    auto timestamp = mQueueItems[0].mTimestamp;
    nsecs_t expectedPresent = mConsumer->computeExpectedPresent(dispSync);

    // Ignore timestamps more than a second in the future
    bool isPlausible = timestamp < (expectedPresent + s2ns(1));

    bool isDue = timestamp < expectedPresent;
    return isDue || !isPlausible;
}
```
该方法会通过computeExpectedPresent通过DispSync计算这一帧应该是什么显示。是否显示由下面的公式决定：
> 预期显示 - 入队时间 < 1s && 入队时间<预期时间

一旦允许显示则往mLayersWithQueuedFrames添加Layer。这个Layer集合就是需要绘制的图层。


#### BufferLayer  latchBuffer
接着会遍历mLayersWithQueuedFrames每一层的Layer，并且调用latchBuffer进行图元锁定。

接下来这个方法很长。我把它拆开2部分来聊
```cpp
Region BufferLayer::latchBuffer(bool& recomputeVisibleRegions, nsecs_t latchTime) {

 ...
    Region outDirtyRegion;
    if (mQueuedFrames <= 0 && !mAutoRefresh) {
        return outDirtyRegion;
    }
//已经latch过了就不需要了
    if (mRefreshPending) {
        return outDirtyRegion;
    }
//fence已经唤醒了，也不需要了
    if (!headFenceHasSignaled()) {
        mFlinger->signalLayerUpdate();
        return outDirtyRegion;
    }

    const State& s(getDrawingState());
    const bool oldOpacity = isOpaque(s);
    sp<GraphicBuffer> oldBuffer = getBE().compositionInfo.mBuffer;

    if (!allTransactionsSignaled()) {
        mFlinger->signalLayerUpdate();
        return outDirtyRegion;
    }

    bool queuedBuffer = false;
    LayerRejecter r(mDrawingState, getCurrentState(), recomputeVisibleRegions,
                    getProducerStickyTransform() != 0, mName.string(),
                    mOverrideScalingMode, mFreezeGeometryUpdates);
//核心
    status_t updateResult =
            mConsumer->updateTexImage(&r, mFlinger->mPrimaryDispSync,
                                                    &mAutoRefresh, &queuedBuffer,
                                                    mLastFrameNumberReceived);
//根据消费返回的状态做处理
    if (updateResult == BufferQueue::PRESENT_LATER) {
        mFlinger->signalLayerUpdate();
        return outDirtyRegion;
    } else if (updateResult == BufferLayerConsumer::BUFFER_REJECTED) {
        if (queuedBuffer) {
            Mutex::Autolock lock(mQueueItemLock);
            mTimeStats.removeTimeRecord(getName().c_str(), mQueueItems[0].mFrameNumber);
            mQueueItems.removeAt(0);
            android_atomic_dec(&mQueuedFrames);
        }
        return outDirtyRegion;
    } else if (updateResult != NO_ERROR || mUpdateTexImageFailed) {
        if (queuedBuffer) {
            Mutex::Autolock lock(mQueueItemLock);
            mQueueItems.clear();
            android_atomic_and(0, &mQueuedFrames);
            mTimeStats.clearLayerRecord(getName().c_str());
        }

        mUpdateTexImageFailed = true;

        return outDirtyRegion;
    }
//从入队到这里的queuedBuffer 都为true
    if (queuedBuffer) {
        // Autolock scope
        auto currentFrameNumber = mConsumer->getFrameNumber();

        Mutex::Autolock lock(mQueueItemLock);

        while (mQueueItems[0].mFrameNumber != currentFrameNumber) {
            mTimeStats.removeTimeRecord(getName().c_str(), mQueueItems[0].mFrameNumber);
            mQueueItems.removeAt(0);
            android_atomic_dec(&mQueuedFrames);
        }

        const std::string layerName(getName().c_str());
        mTimeStats.setAcquireFence(layerName, currentFrameNumber, mQueueItems[0].mFenceTime);
        mTimeStats.setLatchTime(layerName, currentFrameNumber, latchTime);

        mQueueItems.removeAt(0);
    }

    if ((queuedBuffer && android_atomic_dec(&mQueuedFrames) > 1) ||
        mAutoRefresh) {
        mFlinger->signalLayerUpdate();
    }

//把已经消费的图元保存到SurfaceFlingerBE里面
    getBE().compositionInfo.mBuffer =
            mConsumer->getCurrentBuffer(&getBE().compositionInfo.mBufferSlot);

    mActiveBuffer = getBE().compositionInfo.mBuffer;
    if (getBE().compositionInfo.mBuffer == nullptr) {
        // this can only happen if the very first buffer was rejected.
        return outDirtyRegion;
    }

    mBufferLatched = true;
...
}
```
整个核心就是updateTexImage方法。在这里面经过判断，latch过的Layer就不会再进行latch。

经过updateTexImage处理后，会判断返回的状态码。如果需要延迟显示则直接返回空的脏区域。如果发现需要拒绝显示这个帧，将会丢弃mQueueItem中对应的图元参数和索引。如果消费失败了，则会处理清除mQueueItem中所有等待消费的图元。最后返回空脏区。

成功消费后，如果是从queueBuffer的步骤到这里的，将会移除mQueueItem第一项图元数据。剩下的图元还有剩下的，则需要进行下一轮invalidate消息。

最后会把消费后的图元，作为当前需要显示的图元保存在getBE().compositionInfo.mBuffer和mActiveBuffer，并且设置mBufferLatched。

核心的updateTexImage方法我们稍后注重考究。



```cpp
//记录上一帧序列
    mPreviousFrameNumber = mCurrentFrameNumber;
//记录当前这一帧的序列
    mCurrentFrameNumber = mConsumer->getFrameNumber();

    {
//记录上锁时间
        Mutex::Autolock lock(mFrameEventHistoryMutex);
        mFrameEventHistory.addLatch(mCurrentFrameNumber, latchTime);
    }

    mRefreshPending = true;
    mFrameLatencyNeeded = true;
    if (oldBuffer == nullptr) {
        recomputeVisibleRegions = true;
    }
//记录DataSpace
    ui::Dataspace dataSpace = mConsumer->getCurrentDataSpace();
    switch (dataSpace) {
        case ui::Dataspace::V0_SRGB:
            dataSpace = ui::Dataspace::SRGB;
            break;
        case ui::Dataspace::V0_SRGB_LINEAR:
            dataSpace = ui::Dataspace::SRGB_LINEAR;
            break;
        case ui::Dataspace::V0_JFIF:
            dataSpace = ui::Dataspace::JFIF;
            break;
        case ui::Dataspace::V0_BT601_625:
            dataSpace = ui::Dataspace::BT601_625;
            break;
        case ui::Dataspace::V0_BT601_525:
            dataSpace = ui::Dataspace::BT601_525;
            break;
        case ui::Dataspace::V0_BT709:
            dataSpace = ui::Dataspace::BT709;
            break;
        default:
            break;
    }
    mCurrentDataSpace = dataSpace;

    Rect crop(mConsumer->getCurrentCrop());
    const uint32_t transform(mConsumer->getCurrentTransform());
    const uint32_t scalingMode(mConsumer->getCurrentScalingMode());
    if ((crop != mCurrentCrop) ||
        (transform != mCurrentTransform) ||
        (scalingMode != mCurrentScalingMode)) {
        mCurrentCrop = crop;
        mCurrentTransform = transform;
        mCurrentScalingMode = scalingMode;
        recomputeVisibleRegions = true;
    }

    if (oldBuffer != nullptr) {
        uint32_t bufWidth = getBE().compositionInfo.mBuffer->getWidth();
        uint32_t bufHeight = getBE().compositionInfo.mBuffer->getHeight();
        if (bufWidth != uint32_t(oldBuffer->width) ||
            bufHeight != uint32_t(oldBuffer->height)) {
            recomputeVisibleRegions = true;
        }
    }
//记录透明参数
    mCurrentOpacity = getOpacityForFormat(getBE().compositionInfo.mBuffer->format);
    if (oldOpacity != isOpaque(s)) {
        recomputeVisibleRegions = true;
    }

//移除mLocalSyncPoints中的阻塞
    {
        Mutex::Autolock lock(mLocalSyncPointMutex);
        auto point = mLocalSyncPoints.begin();
        while (point != mLocalSyncPoints.end()) {
            if (!(*point)->frameIsAvailable() || !(*point)->transactionIsApplied()) {
                // This sync point must have been added since we started
                // latching. Don't drop it yet.
                ++point;
                continue;
            }

            if ((*point)->getFrameNumber() <= mCurrentFrameNumber) {
                point = mLocalSyncPoints.erase(point);
            } else {
                ++point;
            }
        }
    }

    // FIXME: postedRegion should be dirty & bounds
    Region dirtyRegion(Rect(s.active.w, s.active.h));

    // transform the dirty region to window-manager space
    outDirtyRegion = (getTransform().transform(dirtyRegion));

    return outDirtyRegion;
```
- 1.设置相关的参数，如帧数，裁剪参数，DataSpace，透明参数等。并且移除了代表当帧数之前mLocalSyncPoints。
- 2.计算脏区是由mDrawState对应的active参数确定(此时requested和active已经交换了)。最后调用transform转化转化为脏区
```cpp
Transform Layer::getTransform() const {
    Transform t;
    const auto& p = mDrawingParent.promote();
    if (p != nullptr) {
        t = p->getTransform();

        if (p->isFixedSize() && p->getBE().compositionInfo.mBuffer != nullptr) {
            int bufferWidth;
            int bufferHeight;
            if ((p->mCurrentTransform & NATIVE_WINDOW_TRANSFORM_ROT_90) == 0) {
                bufferWidth = p->getBE().compositionInfo.mBuffer->getWidth();
                bufferHeight = p->getBE().compositionInfo.mBuffer->getHeight();
            } else {
                bufferHeight = p->getBE().compositionInfo.mBuffer->getWidth();
                bufferWidth = p->getBE().compositionInfo.mBuffer->getHeight();
            }
            float sx = p->getDrawingState().active.w / static_cast<float>(bufferWidth);
            float sy = p->getDrawingState().active.h / static_cast<float>(bufferHeight);
            Transform extraParentScaling;
            extraParentScaling.set(sx, 0, 0, sy);
            t = t * extraParentScaling;
        }
    }
    return t * getDrawingState().active.transform;
}
```
其实这个转化是查找每一个Layer的父Layer，并且根据父Layer的宽高和当前Layer比进行一次等比例缩小。

换句话说，实际上脏区的计算，从App进程角度来看是以Surface为一个单位进行计算。



##### BufferLayerConsumer updateTexImage
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayerConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayerConsumer.cpp)

```cpp
status_t BufferLayerConsumer::updateTexImage(BufferRejecter* rejecter, const DispSync& dispSync,
                                             bool* autoRefresh, bool* queuedBuffer,
                                             uint64_t maxFrameNumber) {
    ATRACE_CALL();
    Mutex::Autolock lock(mMutex);

    if (mAbandoned) {
        return NO_INIT;
    }

    // Make sure RenderEngine is current
    if (!mRE.isCurrent()) {
        return INVALID_OPERATION;
    }

    BufferItem item;


    status_t err = acquireBufferLocked(&item, computeExpectedPresent(dispSync), maxFrameNumber);
    if (err != NO_ERROR) {
        if (err == BufferQueue::NO_BUFFER_AVAILABLE) {
            err = NO_ERROR;
        } else if (err == BufferQueue::PRESENT_LATER) {
            // return the error, without logging
        } else {
            BLC_LOGE("updateTexImage: acquire failed: %s (%d)", strerror(-err), err);
        }
        return err;
    }

    if (autoRefresh) {
        *autoRefresh = item.mAutoRefresh;
    }

    if (queuedBuffer) {
        *queuedBuffer = item.mQueuedBuffer;
    }

    int slot = item.mSlot;
    if (rejecter && rejecter->reject(mSlots[slot].mGraphicBuffer, item)) {
        releaseBufferLocked(slot, mSlots[slot].mGraphicBuffer);
        return BUFFER_REJECTED;
    }

    // Release the previous buffer.
    err = updateAndReleaseLocked(item, &mPendingRelease);
    if (err != NO_ERROR) {
        return err;
    }

    if (!SyncFeatures::getInstance().useNativeFenceSync()) {
        err = bindTextureImageLocked();
    }

    return err;
}
```
在这个方法中有两个核心：
- 1.acquireBufferLocked消费图元。
- 2.LayerReject 判断是否需要拒绝显示当前已经消费的图元。
- 3.updateAndReleaseLocked更新当前Layer中需要显示的图元，同时释放之前的图元为Free状态。
- 4.最后判断OpenGL es是否携带EGL_KHR_fence_sync标志位，代表OpenGL es的同步栅。如果是，则提前通过OpenGL es绘制Image。


### BufferLayerConsumer acquireBufferLocked
文件：[meworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayerConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayerConsumer.cpp)
```cpp
status_t BufferLayerConsumer::acquireBufferLocked(BufferItem* item, nsecs_t presentWhen,
                                                  uint64_t maxFrameNumber) {
    status_t err = ConsumerBase::acquireBufferLocked(item, presentWhen, maxFrameNumber);
    if (err != NO_ERROR) {
        return err;
    }


    if (item->mGraphicBuffer != nullptr) {
        mImages[item->mSlot] = new Image(item->mGraphicBuffer, mRE);
    }

    return NO_ERROR;
}
```
- 1.ConsumerBase::acquireBufferLocked 从基类还是处理图元消费。
- 2.通过GraphicBuffer生成Image对象保存在mImages数组中。

先来看看image对象对应的头文件：
```cpp
    class Image : public LightRefBase<Image> {
    public:
        Image(sp<GraphicBuffer> graphicBuffer, RE::RenderEngine& engine);

        Image(const Image& rhs) = delete;
        Image& operator=(const Image& rhs) = delete;

        status_t createIfNeeded(const Rect& imageCrop);

        const sp<GraphicBuffer>& graphicBuffer() { return mGraphicBuffer; }
        const native_handle* graphicBufferHandle() {
            return mGraphicBuffer == nullptr ? nullptr : mGraphicBuffer->handle;
        }

        const RE::Image& image() const { return *mImage; }

    private:
        friend class LightRefBase<Image>;
        virtual ~Image();

        // mGraphicBuffer is the buffer that was used to create this image.
        sp<GraphicBuffer> mGraphicBuffer;

        std::unique_ptr<RE::Image> mImage;
        bool mCreated;
        int32_t mCropWidth;
        int32_t mCropHeight;
    };
```
其实很简单，核心是持有了GraphicBuffer和RE::Image两个对象。GraphicBuffer图元，我们去看看RE::Image对象是怎么生成的。
```cpp
BufferLayerConsumer::Image::Image(sp<GraphicBuffer> graphicBuffer, RE::RenderEngine& engine)
      : mGraphicBuffer(graphicBuffer),
        mImage{engine.createImage()},
        mCreated(false),
        mCropWidth(0),
        mCropHeight(0) {}
```

```cpp
std::unique_ptr<RE::Image> RenderEngine::createImage() {
    return std::make_unique<Image>(*this);
}
```

```cpp
class Image {
public:
    virtual ~Image() = 0;
    virtual bool setNativeWindowBuffer(ANativeWindowBuffer* buffer, bool isProtected,
                                       int32_t cropWidth, int32_t cropHeight) = 0;
};

namespace impl {

class RenderEngine;

class Image : public RE::Image {
public:
    explicit Image(const RenderEngine& engine);
    ~Image() override;

    Image(const Image&) = delete;
    Image& operator=(const Image&) = delete;

    bool setNativeWindowBuffer(ANativeWindowBuffer* buffer, bool isProtected, int32_t cropWidth,
                               int32_t cropHeight) override;

private:
    friend class RenderEngine;
    EGLSurface getEGLImage() const { return mEGLImage; }

    EGLDisplay mEGLDisplay;
    EGLImageKHR mEGLImage = EGL_NO_IMAGE_KHR;
};

} // namespace impl
```
其实Image对象实际上就是控制NativeBuffer，EGLDisplay，EGLSurface对象。这些对象实际上都是OpenGL es绘制的核心对象。所有的操作都是透过这个Image绘制。


### ConsumerBase acquireBufferLocked
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[ConsumerBase.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/ConsumerBase.cpp)

```cpp
status_t ConsumerBase::acquireBufferLocked(BufferItem *item,
        nsecs_t presentWhen, uint64_t maxFrameNumber) {
...
    status_t err = mConsumer->acquireBuffer(item, presentWhen, maxFrameNumber);
...
    if (item->mGraphicBuffer != NULL) {
        if (mSlots[item->mSlot].mGraphicBuffer != NULL) {
            freeBufferLocked(item->mSlot);
        }
        mSlots[item->mSlot].mGraphicBuffer = item->mGraphicBuffer;
    }

    mSlots[item->mSlot].mFrameNumber = item->mFrameNumber;
    mSlots[item->mSlot].mFence = item->mFence;

    return OK;
}
```
这里调用了BufferQueueConsumer的acquireBuffer。并且把消费的值赋值到新的item对应的mSlots下标中。因为这个过程可能会选择一些丢帧或者跳帧处理。

##### BufferQueueConsumer acquireBuffer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[BufferQueueConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/BufferQueueConsumer.cpp)
```cpp
status_t BufferQueueConsumer::acquireBuffer(BufferItem* outBuffer,
        nsecs_t expectedPresent, uint64_t maxFrameNumber) {
    ATRACE_CALL();

    int numDroppedBuffers = 0;
    sp<IProducerListener> listener;
    {
        Mutex::Autolock lock(mCore->mMutex);

        int numAcquiredBuffers = 0;
        for (int s : mCore->mActiveBuffers) {
            if (mSlots[s].mBufferState.isAcquired()) {
                ++numAcquiredBuffers;
            }
        }
        if (numAcquiredBuffers >= mCore->mMaxAcquiredBufferCount + 1) {
            return INVALID_OPERATION;
        }

        bool sharedBufferAvailable = mCore->mSharedBufferMode &&
                mCore->mAutoRefresh && mCore->mSharedBufferSlot !=
                BufferQueueCore::INVALID_BUFFER_SLOT;


        if (mCore->mQueue.empty() && !sharedBufferAvailable) {
            return NO_BUFFER_AVAILABLE;
        }

        BufferQueueCore::Fifo::iterator front(mCore->mQueue.begin());

        if (expectedPresent != 0 && !mCore->mQueue.empty()) {
            const int MAX_REASONABLE_NSEC = 1000000000ULL; // 1 second

            while (mCore->mQueue.size() > 1 && !mCore->mQueue[0].mIsAutoTimestamp) {
                const BufferItem& bufferItem(mCore->mQueue[1]);

                if (maxFrameNumber && bufferItem.mFrameNumber > maxFrameNumber) {
                    break;
                }

                nsecs_t desiredPresent = bufferItem.mTimestamp;
                if (desiredPresent < expectedPresent - MAX_REASONABLE_NSEC ||
                        desiredPresent > expectedPresent) {
                    break;
                }


                if (!front->mIsStale) {
                    // Front buffer is still in mSlots, so mark the slot as free
                    mSlots[front->mSlot].mBufferState.freeQueued();

                    if (!mCore->mSharedBufferMode &&
                            mSlots[front->mSlot].mBufferState.isFree()) {
                        mSlots[front->mSlot].mBufferState.mShared = false;
                    }

                    // Don't put the shared buffer on the free list
                    if (!mSlots[front->mSlot].mBufferState.isShared()) {
                        mCore->mActiveBuffers.erase(front->mSlot);
                        mCore->mFreeBuffers.push_back(front->mSlot);
                    }

                    listener = mCore->mConnectedProducerListener;
                    ++numDroppedBuffers;
                }

                mCore->mQueue.erase(front);
                front = mCore->mQueue.begin();
            }

            nsecs_t desiredPresent = front->mTimestamp;
            bool bufferIsDue = desiredPresent <= expectedPresent ||
                    desiredPresent > expectedPresent + MAX_REASONABLE_NSEC;
            bool consumerIsReady = maxFrameNumber > 0 ?
                    front->mFrameNumber <= maxFrameNumber : true;
            if (!bufferIsDue || !consumerIsReady) {
                return PRESENT_LATER;
            }

        }

        int slot = BufferQueueCore::INVALID_BUFFER_SLOT;

        if (sharedBufferAvailable && mCore->mQueue.empty()) {
           ....
        } else {
            slot = front->mSlot;
            *outBuffer = *front;
        }



        if (!outBuffer->mIsStale) {
            mSlots[slot].mAcquireCalled = true;
            if (mCore->mQueue.empty()) {
                mSlots[slot].mBufferState.acquireNotInQueue();
            } else {
                mSlots[slot].mBufferState.acquire();
            }
            mSlots[slot].mFence = Fence::NO_FENCE;
        }


        if (outBuffer->mAcquireCalled) {
            outBuffer->mGraphicBuffer = NULL;
        }

        mCore->mQueue.erase(front);

        mCore->mDequeueCondition.broadcast();

        mCore->mOccupancyTracker.registerOccupancyChange(mCore->mQueue.size());

        VALIDATE_CONSISTENCY();
    }

    if (listener != NULL) {
        for (int i = 0; i < numDroppedBuffers; ++i) {
            listener->onBufferReleased();
        }
    }

    return NO_ERROR;
}
```
- 1. 处理图元之前，首先检测mActiveBuffers中活跃的图元究竟有多少个。如果超出mMaxAcquiredBufferCount限制，则不允许继续。
- 2. 获取之前入队到mQueue的第一项front进行循环处理。首先获取之前计算出来的期待显示时间和当前入队的时间比较，找出和当前时间最接近的入队图元。如果入队的时间比期待的小一秒，并且入队的时间比期待的时间小。这样就会直接跳出mQueue处理的处理循环。

如果front.mIsStale为false说明这个图元已经过期了。将把mSlot的索引从mActiveBuffers转移到mFreeBuffer。同时计算为一个numDroppedBuffers丢帧计数处理。获取mQueue的下一项图元。

最后把当前的front图元返回，并且释放那些已经丢帧的图元。


#### LayerRejecter 判断是否需要拒绝显示当前已经消费的图元
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[LayerRejecter.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/LayerRejecter.cpp)

```cpp
bool LayerRejecter::reject(const sp<GraphicBuffer>& buf, const BufferItem& item) {
    if (buf == nullptr) {
        return false;
    }

    uint32_t bufWidth = buf->getWidth();
    uint32_t bufHeight = buf->getHeight();

    if (item.mTransform & Transform::ROT_90) {
        swap(bufWidth, bufHeight);
    }

    int actualScalingMode = mOverrideScalingMode >= 0 ? mOverrideScalingMode : item.mScalingMode;
    bool isFixedSize = actualScalingMode != NATIVE_WINDOW_SCALING_MODE_FREEZE;
    if (mFront.active != mFront.requested) {
        if (isFixedSize || (bufWidth == mFront.requested.w && bufHeight == mFront.requested.h)) {
            mFront.active = mFront.requested;

            mCurrent.active = mFront.active;
            mCurrent.modified = true;

            mRecomputeVisibleRegions = true;

            mFreezeGeometryUpdates = false;

            if (mFront.crop != mFront.requestedCrop) {
                mFront.crop = mFront.requestedCrop;
                mCurrent.crop = mFront.requestedCrop;
                mRecomputeVisibleRegions = true;
            }
            if (mFront.finalCrop != mFront.requestedFinalCrop) {
                mFront.finalCrop = mFront.requestedFinalCrop;
                mCurrent.finalCrop = mFront.requestedFinalCrop;
                mRecomputeVisibleRegions = true;
            }
        }

       
    }

    if (!isFixedSize && !mStickyTransformSet) {
        if (mFront.active.w != bufWidth || mFront.active.h != bufHeight) {
            return true;
        }
    }

   
    if (!mFront.activeTransparentRegion.isTriviallyEqual(mFront.requestedTransparentRegion)) {
        mFront.activeTransparentRegion = mFront.requestedTransparentRegion;

        mCurrent.activeTransparentRegion = mFront.activeTransparentRegion;

        mRecomputeVisibleRegions = true;
    }

    return false;
}
```
拒绝检测图元显示。mFront其实就是上文通过doTransaction的mDrawState，此时已经进行交换，所以mDrawState是这一帧的内容。一旦发现requested和active的几何不一致。如果此时不是NATIVE_WINDOW_SCALING_MODE_FREEZE(冻结屏幕)。同时图元的宽高和requested相同，才会进行requested和active的交换。

如果是NATIVE_WINDOW_SCALING_MODE_FREEZE(冻结屏幕)，则但是发现requested的宽高和图元需要的宽高不一致就会拒绝绘制，丢掉当前帧。其实思想很简单，实际上就这种NATIVE_WINDOW_SCALING_MODE_FREEZE模式下就是只绘制和当前窗口一样大小的图元。其他都不设置。


#### updateAndReleaseLocked更新当前Layer中需要显示的图元，同时释放之前的图元为Free状态
```cpp
status_t BufferLayerConsumer::updateAndReleaseLocked(const BufferItem& item,
                                                     PendingRelease* pendingRelease) {
    status_t err = NO_ERROR;

    int slot = item.mSlot;

    if (slot != mCurrentTexture) {
        err = syncForReleaseLocked();
        if (err != NO_ERROR) {
            releaseBufferLocked(slot, mSlots[slot].mGraphicBuffer);
            return err;
        }
    }


    sp<Image> nextTextureImage = mImages[slot];

    if (mCurrentTexture != BufferQueue::INVALID_BUFFER_SLOT) {
        if (pendingRelease == nullptr) {
            status_t status =
                    releaseBufferLocked(mCurrentTexture, mCurrentTextureImage->graphicBuffer());
            if (status < NO_ERROR) {
                err = status;
            }
        } else {
            pendingRelease->currentTexture = mCurrentTexture;
            pendingRelease->graphicBuffer = mCurrentTextureImage->graphicBuffer();
            pendingRelease->isPending = true;
        }
    }

    // Update the BufferLayerConsumer state.
    mCurrentTexture = slot;
    mCurrentTextureImage = nextTextureImage;
    mCurrentCrop = item.mCrop;
    mCurrentTransform = item.mTransform;
    mCurrentScalingMode = item.mScalingMode;
    mCurrentTimestamp = item.mTimestamp;
    mCurrentDataSpace = static_cast<ui::Dataspace>(item.mDataSpace);
    mCurrentHdrMetadata = item.mHdrMetadata;
    mCurrentFence = item.mFence;
    mCurrentFenceTime = item.mFenceTime;
    mCurrentFrameNumber = item.mFrameNumber;
    mCurrentTransformToDisplayInverse = item.mTransformToDisplayInverse;
    mCurrentSurfaceDamage = item.mSurfaceDamage;
    mCurrentApi = item.mApi;

    computeCurrentTransformMatrixLocked();

    return err;
}
```
- 1.syncForReleaseLocked 实际上是一次Fence阻塞，等待所有的Fence的监听都达到了NO_ERROR,返回Signal状态。就进行下一步，同时进行释放上一帧的图元，进入到free状态。
- 2.记录上一帧的数据到pendingRelease，以及本次准备渲染的帧数中相关的参数，如DataSpace，mSlot插槽中对应的index，以及携带GraphicBuffer的Image。


### DataSpace小知识的记录
有了RGB，Ycbcr这些颜色format，为什么还需要DataSpace，色彩的数据空间呢？这里需要借助一篇[文章](https://zhuanlan.zhihu.com/p/66558476)
，这里稍作总结。

在现实世界中，当光强一倍，则亮度也会提升一倍，是一个线性关系。但是由于最早的显示器(阴极射线管)显示图像的时候，输出亮度和电压并不是成线性关系的，而是亮度等于电压的2.2次幂的非线性关系：$l = u^{2.2}$.

这个2.2也叫做Gama值。为了尽可能的达到现实世界的效果。因此需要一个Gama的纠正。也就是去除2.2次幂，因此会在处理之前先进行一次0.45次幂的处理，抵消这个2.2次幂的造成的异常。

而我们常用的sRGB的色彩空间也是这么一回事，就是指的是0.45次幂。而在上文中所有记录的DataSpace也是这个意思。


## 总结
```cpp
            bool refreshNeeded = handleMessageTransaction();
            refreshNeeded |= handleMessageInvalidate();
            refreshNeeded |= mRepaintEverything;
            if (refreshNeeded) {
                signalRefresh();
            }
```
此时我们已经分析接收到Invalidate消息之后判断是否需要刷新的判断处理。
- 1.handleMessageTransaction将会处理每一个Layer的事务，最核心的事情就是把每一个Layer中的上一帧的mDrawState被当前帧的mCurrentState替代。一旦有事务需要处理，说明有Surface发生了状态的变化，如宽高如位置。此时就必须重新刷新整个界面。
- 2.handleMessageInvalidate处理的核心：
1. 首先检测哪一些图元需要显示，需要的则会添加到mLayersWithQueuedFrames。条件是入队时间不能超过预期时间的一秒，也能不能超过预期时间（mQueueItems是onFrameAvailable回调添加）。
2. 遍历每一个需要显示的Layer，调用latchBuffer方法。这个方法核心是updateTexImage。这个方法分为3个步骤：
1) acquireBufferLocked 本质上是获取mQueue的第一个加进来的图元作为即将显示的图元。但是如果遇到显示的时间和预期时间差大于1秒，同时发现这个图元已经过期了(free状态),则会跳帧，直到找到最近时间的一帧。

2) LayerRejecter 判断是否有打开冻结窗口模式，打开了但是发现图元的大小不对则拒绝显示。相反，则会mDrawState的requested赋值给active。

3) updateAndReleaseLocked 释放前一帧的图元，同时准备设置当前消费的图元作为准备绘制的画面。


我们回头来看看handleMessageInvalidate，它其实也是判断是否需要全局刷新。如果发现图元锁定之后有Layer消费了图元，则会决定进行调用refresh页面。发送Refresh消息。最后dirty区域将会依赖父Layer 的宽高。mVisibleRegions标志位最后是依赖latchBuffer返回的脏区和Layer是否有添加过。

我们最后来看看Refresh做了什么？
```cpp
        case MessageQueue::REFRESH: {
            handleMessageRefresh();
            break;
        }
```

```cpp
void SurfaceFlinger::handleMessageRefresh() {

    mRefreshPending = false;

    nsecs_t refreshStartTime = systemTime(SYSTEM_TIME_MONOTONIC);

    preComposition(refreshStartTime);
    rebuildLayerStacks();
    setUpHWComposer();
    doDebugFlashRegions();
    doTracing("handleRefresh");
    logLayerStats();
    doComposition();
    postComposition(refreshStartTime);

...

    mLayersWithQueuedFrames.clear();
}
```
大致上，刷新屏幕分为7步骤：
- 1.preComposition 预处理合成
- 2.rebuildLayerStacks 重新构建Layer栈
- 3.setUpHWComposer HWC的渲染或者准备
- 4.doDebugFlashRegions 打开debug绘制模式
- 5.doTracing 跟踪打印
- 6.doComposition 合成图元
- 7.postComposition 图元合成后的vysnc等收尾工作。

下一篇文章将会和大家聊聊。




