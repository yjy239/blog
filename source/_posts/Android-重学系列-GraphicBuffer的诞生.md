---
title: Android 重学系列 GraphicBuffer的诞生
top: false
cover: false
date: 2020-01-31 19:24:59
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
经过上一篇对OpenGL es的解析，我们引出了在eglSwapBuffer时候会调用会调用两个关键的方法：
- 1.Surface::dequeueBuffer
- 2.Surface::queueBuffer

从上一篇openGL es分析可以得出，每一次当我们绘制完一次图元之后，surface做为生产者一方会在一个循环中一般依次完成如下内容：
- 1.dequeueBuffer 获取一个图元的插槽位置，或者生产一个图元
- 2.lock 锁定图元
- 3.queueBuffer 把图元放入缓冲队列中
- 4.unlock 解锁图元

对于生产者来说关键的是这四个步骤。不过openGL es把整个过程颠倒，每一次绘制上一帧，对于更加好理解，我把整个过程设置回Android常用的方式。我们分别来研究这几个函数做了什么。

遇到什么问题，欢迎来本文进行讨论[https://www.jianshu.com/p/3bfc0053d254](https://www.jianshu.com/p/3bfc0053d254)


## 正文

首先我们先不去深究细节，先对整个流程的源码流程有一个大体印象。因为图元的诞生不清楚，也看不懂其他原理。

### egl lock 锁定图元
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)

```cpp
status_t egl_window_surface_v2_t::lock(
        ANativeWindowBuffer* buf, int usage, void** vaddr)
{
    auto& mapper = GraphicBufferMapper::get();
    return mapper.lock(buf->handle, usage,
            android::Rect(buf->width, buf->height), vaddr);
}
```
在lock函数实际上是把ANativeWindowBuffer的handle传进去进行锁定，同时传入了一个vaddr的地址，这个地址是做什么的呢？其实就是共享buffer中的图元存储的地址。

实际上上在lock的时候，并不是直接把buffer传下去，而是传递一个handle，一个ANativeWindowBuffer的句柄。


## dequeueBuffer 获取一个图元的插槽位置，或者生产一个图元
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[Surface.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/Surface.cpp)


先介绍Surface的核心对象之一mSlot，这个对象是数组BufferSlot：
```cpp
struct BufferSlot {

    BufferSlot()
    : mGraphicBuffer(nullptr),
      mEglDisplay(EGL_NO_DISPLAY),
      mBufferState(),
      mRequestBufferCalled(false),
      mFrameNumber(0),
      mEglFence(EGL_NO_SYNC_KHR),
      mFence(Fence::NO_FENCE),
      mAcquireCalled(false),
      mNeedsReallocation(false) {
    }

    sp<GraphicBuffer> mGraphicBuffer;

    EGLDisplay mEglDisplay;

    BufferState mBufferState;


    bool mRequestBufferCalled;


    uint64_t mFrameNumber;


    EGLSyncKHR mEglFence;

    sp<Fence> mFence;

    // Indicates whether this buffer has been seen by a consumer yet
    bool mAcquireCalled;


    bool mNeedsReallocation;
};
```
在这里面保存着几个很重要对象：
- 1.GraphicBuffer 图元缓冲对象
- 2.mEglDisplay opengl es的屏幕对象，实际上就是egl_display_t
- 3.BufferState 图元状态
- 4.EGLSyncKHR opengl es的同步栅
- 5.Fence 同步栅

在这里先介绍一个重要的概念，每一个GraphicBuffer图元在不同的流程会分为5个状态都会在BufferState记录状态：
- 1.free 图元是自由的等待dequeue使用
- 2.dequeue SF中缓冲队列的插槽对应index的图元要么找到一个free的图元，要么就申请一个出来。
- 3.queue 从dequeue出来的图元，经过queueBuffer进入到SF进行刷新界面时候读取出来进行渲染
- 4.acquire 当SF的图元消费者进行消费之后，将会把这个状态设置为Acquire
- 4.share 共享图元 这种模式比较特殊，这种模式下能够和其他三个模式并存，只是这种模式下只会整个Layer进行绘制使用同一个图元绘制。

根据这些状态，在SF中对应的计数个数不一样，这些计数影响着SF是否需要调整整个mSlot的使用策略。
图元状态|mShared|mDequeueCount|mQueueCount|mAcquireCount
-|-|-|-|-
FREE|false|0|0|0
DEQUEUED|false|1|0|0
QUEUED|false|0|1|0
ACQUIRED|false|0|0|1
SHARED|true|any|any|any
- 1.mShared 代表该图元是共享的
- 2.mDequeueCount 有多少图元是否出队，被应用程序正在处理
- 3.mQueueCount 有多少图元已经入队，正在等待被消费者消费
- 4.mAcquireCount 有多少图元正在被消费。

因此当我们需要进行调整，需要对mDequeueCount+mAcquireCount加入调整计算，这样才能知道一共有多少图元在缓冲队伍之外，才能正确的计算，是否应该调整BufferQueue.mSlot的策略。在图元缓冲队列初始化那一章中，能看到会计算mMaxAcquiredBufferCount和mMaxDequeuedBufferCount的数量，来控制每一个Layer的图元生产者的是否需要调整slot为新的GraphicBuffer腾出位置。



```cpp
int Surface::dequeueBuffer(android_native_buffer_t** buffer, int* fenceFd) {

    uint32_t reqWidth;
    uint32_t reqHeight;
    PixelFormat reqFormat;
    uint64_t reqUsage;
    bool enableFrameTimestamps;

    {
        Mutex::Autolock lock(mMutex);
        if (mReportRemovedBuffers) {
            mRemovedBuffers.clear();
        }

        reqWidth = mReqWidth ? mReqWidth : mUserWidth;
        reqHeight = mReqHeight ? mReqHeight : mUserHeight;

        reqFormat = mReqFormat;
        reqUsage = mReqUsage;

        enableFrameTimestamps = mEnableFrameTimestamps;

        if (mSharedBufferMode && mAutoRefresh && mSharedBufferSlot !=
                BufferItem::INVALID_BUFFER_SLOT) {
            sp<GraphicBuffer>& gbuf(mSlots[mSharedBufferSlot].buffer);
            if (gbuf != NULL) {
                *buffer = gbuf.get();
                *fenceFd = -1;
                return OK;
            }
        }
    } // Drop the lock so that we can still touch the Surface while blocking in IGBP::dequeueBuffer

    int buf = -1;
    sp<Fence> fence;
    nsecs_t startTime = systemTime();

    FrameEventHistoryDelta frameTimestamps;
    status_t result = mGraphicBufferProducer->dequeueBuffer(&buf, &fence, reqWidth, reqHeight,
                                                            reqFormat, reqUsage, &mBufferAge,
                                                            enableFrameTimestamps ? &frameTimestamps
                                                                                  : nullptr);
    mLastDequeueDuration = systemTime() - startTime;

    if (result < 0) {
      ...
        return result;
    }

    if (buf < 0 || buf >= NUM_BUFFER_SLOTS) {
      ...
        return FAILED_TRANSACTION;
    }

    Mutex::Autolock lock(mMutex);

    // Write this while holding the mutex
    mLastDequeueStartTime = startTime;

    sp<GraphicBuffer>& gbuf(mSlots[buf].buffer);

    // this should never happen
    ...
    if (result & IGraphicBufferProducer::RELEASE_ALL_BUFFERS) {
        freeAllBuffers();
    }

    if (enableFrameTimestamps) {
         mFrameEventHistory->applyDelta(frameTimestamps);
    }

    if ((result & IGraphicBufferProducer::BUFFER_NEEDS_REALLOCATION) || gbuf == nullptr) {
        if (mReportRemovedBuffers && (gbuf != nullptr)) {
            mRemovedBuffers.push_back(gbuf);
        }
        result = mGraphicBufferProducer->requestBuffer(buf, &gbuf);
        if (result != NO_ERROR) {
            ...
            mGraphicBufferProducer->cancelBuffer(buf, fence);
            return result;
        }
    }

    if (fence->isValid()) {
        *fenceFd = fence->dup();
        if (*fenceFd == -1) {
           ...
        }
    } else {
        *fenceFd = -1;
    }

    *buffer = gbuf.get();

    if (mSharedBufferMode && mAutoRefresh) {
        mSharedBufferSlot = buf;
        mSharedBufferHasBeenQueued = false;
    } else if (mSharedBufferSlot == buf) {
        mSharedBufferSlot = BufferItem::INVALID_BUFFER_SLOT;
        mSharedBufferHasBeenQueued = false;
    }

    return OK;
}
```
流程如下：
- 1.如果是共享图元模式，则只会获取mSharedBufferSlot记录的在共享图元在mShared的位置，直接返回对的index。
- 2.调用SF的dequeueBuffer方法，在SF尝试的获取图元对应的位置。
- 3.如果返回的result超出了NUM_BUFFER_SLOTS，则返回一场。判断返回的命令决定是否释放在客户端中的mSlot
- 4.如果判断到BUFFER_NEEDS_REALLOCATION需要重新申请图元，则调用requestBuffer，拿到新申请图元的保存到客户端进程。

让我们重点关注SF的dequeueBuffer。

### BufferQueueProducer dequeueBuffer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[BufferQueueProducer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/BufferQueueProducer.cpp)

```cpp
status_t BufferQueueProducer::dequeueBuffer(int* outSlot, sp<android::Fence>* outFence,
                                            uint32_t width, uint32_t height, PixelFormat format,
                                            uint64_t usage, uint64_t* outBufferAge,
                                            FrameEventHistoryDelta* outTimestamps) {
    ATRACE_CALL();
    { // Autolock scope
        Mutex::Autolock lock(mCore->mMutex);
        mConsumerName = mCore->mConsumerName;

        if (mCore->mIsAbandoned) {
            return NO_INIT;
        }

        if (mCore->mConnectedApi == BufferQueueCore::NO_CONNECTED_API) {
            return NO_INIT;
        }
    } // Autolock scope


    if ((width && !height) || (!width && height)) {
        return BAD_VALUE;
    }

    status_t returnFlags = NO_ERROR;
    EGLDisplay eglDisplay = EGL_NO_DISPLAY;
    EGLSyncKHR eglFence = EGL_NO_SYNC_KHR;
    bool attachedByConsumer = false;

    { // Autolock scope
        Mutex::Autolock lock(mCore->mMutex);
        mCore->waitWhileAllocatingLocked();

        if (format == 0) {
            format = mCore->mDefaultBufferFormat;
        }

        // Enable the usage bits the consumer requested
        usage |= mCore->mConsumerUsageBits;

        const bool useDefaultSize = !width && !height;
        if (useDefaultSize) {
            width = mCore->mDefaultWidth;
            height = mCore->mDefaultHeight;
        }

        int found = BufferItem::INVALID_BUFFER_SLOT;
        while (found == BufferItem::INVALID_BUFFER_SLOT) {
            status_t status = waitForFreeSlotThenRelock(FreeSlotCaller::Dequeue,
                    &found);
            if (status != NO_ERROR) {
                return status;
            }

            // This should not happen
            if (found == BufferQueueCore::INVALID_BUFFER_SLOT) {
                return -EBUSY;
            }

            const sp<GraphicBuffer>& buffer(mSlots[found].mGraphicBuffer);

            if (!mCore->mAllowAllocation) {
                if (buffer->needsReallocation(width, height, format, BQ_LAYER_COUNT, usage)) {
                    if (mCore->mSharedBufferSlot == found) {
                        return BAD_VALUE;
                    }
                    mCore->mFreeSlots.insert(found);
                    mCore->clearBufferSlotLocked(found);
                    found = BufferItem::INVALID_BUFFER_SLOT;
                    continue;
                }
            }
        }

        const sp<GraphicBuffer>& buffer(mSlots[found].mGraphicBuffer);
        if (mCore->mSharedBufferSlot == found &&
                buffer->needsReallocation(width, height, format, BQ_LAYER_COUNT, usage)) {

            return BAD_VALUE;
        }

        if (mCore->mSharedBufferSlot != found) {
            mCore->mActiveBuffers.insert(found);
        }
        *outSlot = found;
        ATRACE_BUFFER_INDEX(found);

        attachedByConsumer = mSlots[found].mNeedsReallocation;
        mSlots[found].mNeedsReallocation = false;

        mSlots[found].mBufferState.dequeue();

        if ((buffer == NULL) ||
                buffer->needsReallocation(width, height, format, BQ_LAYER_COUNT, usage))
        {
            mSlots[found].mAcquireCalled = false;
            mSlots[found].mGraphicBuffer = NULL;
            mSlots[found].mRequestBufferCalled = false;
            mSlots[found].mEglDisplay = EGL_NO_DISPLAY;
            mSlots[found].mEglFence = EGL_NO_SYNC_KHR;
            mSlots[found].mFence = Fence::NO_FENCE;
            mCore->mBufferAge = 0;
            mCore->mIsAllocating = true;

            returnFlags |= BUFFER_NEEDS_REALLOCATION;
        } else {
            // We add 1 because that will be the frame number when this buffer
            // is queued
            mCore->mBufferAge = mCore->mFrameCounter + 1 - mSlots[found].mFrameNumber;
        }


        if (CC_UNLIKELY(mSlots[found].mFence == NULL)) {
...
        }

        eglDisplay = mSlots[found].mEglDisplay;
        eglFence = mSlots[found].mEglFence;
        // Don't return a fence in shared buffer mode, except for the first
        // frame.
        *outFence = (mCore->mSharedBufferMode &&
                mCore->mSharedBufferSlot == found) ?
                Fence::NO_FENCE : mSlots[found].mFence;
        mSlots[found].mEglFence = EGL_NO_SYNC_KHR;
        mSlots[found].mFence = Fence::NO_FENCE;

        if (mCore->mSharedBufferMode && mCore->mSharedBufferSlot ==
                BufferQueueCore::INVALID_BUFFER_SLOT) {
            mCore->mSharedBufferSlot = found;
            mSlots[found].mBufferState.mShared = true;
        }
    } // Autolock scope

    if (returnFlags & BUFFER_NEEDS_REALLOCATION) {
        sp<GraphicBuffer> graphicBuffer = new GraphicBuffer(
                width, height, format, BQ_LAYER_COUNT, usage,
                {mConsumerName.string(), mConsumerName.size()});

        status_t error = graphicBuffer->initCheck();

        { // Autolock scope
            Mutex::Autolock lock(mCore->mMutex);

            if (error == NO_ERROR && !mCore->mIsAbandoned) {
                graphicBuffer->setGenerationNumber(mCore->mGenerationNumber);
                mSlots[*outSlot].mGraphicBuffer = graphicBuffer;
            }

            mCore->mIsAllocating = false;
            mCore->mIsAllocatingCondition.broadcast();

            if (error != NO_ERROR) {
                mCore->mFreeSlots.insert(*outSlot);
                mCore->clearBufferSlotLocked(*outSlot);
                return error;
            }

            if (mCore->mIsAbandoned) {
                mCore->mFreeSlots.insert(*outSlot);
                mCore->clearBufferSlotLocked(*outSlot);
                return NO_INIT;
            }

            VALIDATE_CONSISTENCY();
        } // Autolock scope
    }

    if (attachedByConsumer) {
        returnFlags |= BUFFER_NEEDS_REALLOCATION;
    }

    if (eglFence != EGL_NO_SYNC_KHR) {
        EGLint result = eglClientWaitSyncKHR(eglDisplay, eglFence, 0,
                1000000000);
        if (result == EGL_FALSE) {
            BQ_LOGE("dequeueBuffer: error %#x waiting for fence",
                    eglGetError());
        } else if (result == EGL_TIMEOUT_EXPIRED_KHR) {
            BQ_LOGE("dequeueBuffer: timeout waiting for fence");
        }
        eglDestroySyncKHR(eglDisplay, eglFence);
    }

...

    if (outBufferAge) {
        *outBufferAge = mCore->mBufferAge;
    }
    addAndGetFrameTimestamps(nullptr, outTimestamps);

    return returnFlags;
}
```
- 1. waitWhileAllocatingLocked 如果其他线程进入这个方法，会等待BufferQueueProducer帮其他应用进程申请完之后才能继续走下去。
- 2. waitForFreeSlotThenRelock 不断的查找BufferQueueCore的Slot中空闲的插槽位置，并且取出BufferSlot(在SF中也有一个BufferSlot对应记录)中的GraphicBuffer的index(found)，判断当前这个图元是否宽高，像素格式是否和请求一样，不一样则需要重新请求，则在返回码添加BUFFER_NEEDS_REALLOCATION。
- 3. 先把found的index添加到mActiveBuffer 区间，标示为活跃状态,并且设置为dequeue状态。接着如果找到的GraphicBuffer是空的，或者需要重新申请，则把设置到BufferSlot的参数全部初始化。
- 4. 发现打开了BUFFER_NEEDS_REALLOCATION标志位，就在SF中申请一个新的GraphicBuffer，接着调用GraphicBuffer的initCheck进行校验。拿到found的下标，把新的GraphicBuffer 加入到mSlot。调用clearBufferSlotLocked，初始化clearBufferSlotLocked和里面的参数。
- 5. addAndGetFrameTimestamps 这个方法在dequeuebuffer没有意义。


在这个过程中其实很简单，就是找到合适的空位，添加到活跃区间，设置标志位，最后发现为空则会新生成一个，最后返回的是mSlot对应位置的下标。而不会直接返回一个完整的GraphicBuffer，因为一个图元太大了，根本不可能通过Binder进行通信。


我们来看看waitForFreeSlotThenRelock是怎么从mSlot找到合适位置的图元插槽。

#### BufferQueueProducer waitForFreeSlotThenRelock
```cpp
status_t BufferQueueProducer::waitForFreeSlotThenRelock(FreeSlotCaller caller,
        int* found) const {
    auto callerString = (caller == FreeSlotCaller::Dequeue) ?
            "dequeueBuffer" : "attachBuffer";
    bool tryAgain = true;
    while (tryAgain) {
        if (mCore->mIsAbandoned) {
            return NO_INIT;
        }

        int dequeuedCount = 0;
        int acquiredCount = 0;
        for (int s : mCore->mActiveBuffers) {
            if (mSlots[s].mBufferState.isDequeued()) {
                ++dequeuedCount;
            }
            if (mSlots[s].mBufferState.isAcquired()) {
                ++acquiredCount;
            }
        }


        if (mCore->mBufferHasBeenQueued &&
                dequeuedCount >= mCore->mMaxDequeuedBufferCount) {
...
            return INVALID_OPERATION;
        }

        *found = BufferQueueCore::INVALID_BUFFER_SLOT;

...
        const int maxBufferCount = mCore->getMaxBufferCountLocked();
        bool tooManyBuffers = mCore->mQueue.size()
                            > static_cast<size_t>(maxBufferCount);
        if (tooManyBuffers) {
        ...
        } else {
            ...
            if (mCore->mSharedBufferMode && mCore->mSharedBufferSlot !=
                    BufferQueueCore::INVALID_BUFFER_SLOT) {
                *found = mCore->mSharedBufferSlot;
            } else {
                if (caller == FreeSlotCaller::Dequeue) {
                    // If we're calling this from dequeue, prefer free buffers
                    int slot = getFreeBufferLocked();
                    if (slot != BufferQueueCore::INVALID_BUFFER_SLOT) {
                        *found = slot;
                    } else if (mCore->mAllowAllocation) {
                        *found = getFreeSlotLocked();
                    }
                } else {
                    // If we're calling this from attach, prefer free slots
                    int slot = getFreeSlotLocked();
                    if (slot != BufferQueueCore::INVALID_BUFFER_SLOT) {
                        *found = slot;
                    } else {
                        *found = getFreeBufferLocked();
                    }
                }
            }
        }

        tryAgain = (*found == BufferQueueCore::INVALID_BUFFER_SLOT) ||
                   tooManyBuffers;
        if (tryAgain) {
            if ((mCore->mDequeueBufferCannotBlock || mCore->mAsyncMode) &&
                    (acquiredCount <= mCore->mMaxAcquiredBufferCount)) {
                return WOULD_BLOCK;
            }
            if (mDequeueTimeout >= 0) {
                status_t result = mCore->mDequeueCondition.waitRelative(
                        mCore->mMutex, mDequeueTimeout);
                if (result == TIMED_OUT) {
                    return result;
                }
            } else {
                mCore->mDequeueCondition.wait(mCore->mMutex);
            }
        }
    } // while (tryAgain)

    return NO_ERROR;
}
```
- 1.每一次进入这个方法，都会先循环检测mActiveBuffers中所有所有保存的GraphicBuffer对象的状态，计算已经出队dequeue和消费acquire的数目，并且做校验dequeue是否大于mMaxDequeuedBufferCount数目，超出了就不能计算。还要校验整个Queue大小是否已经比maxBufferCount的限制。
- 2.如果判断在dequeue执行状态，则会从先从mFreeBuffer找，找不到再从mFreeSlots中查找。
- 3.最后唤醒其他要出队到应用的线程。

#### BufferQueueProducer requestBuffer
```cpp
status_t BufferQueueProducer::requestBuffer(int slot, sp<GraphicBuffer>* buf) {
    ATRACE_CALL();
    BQ_LOGV("requestBuffer: slot %d", slot);
    Mutex::Autolock lock(mCore->mMutex);

...
    mSlots[slot].mRequestBufferCalled = true;
    *buf = mSlots[slot].mGraphicBuffer;
    return NO_ERROR;
}
```
在这个过程中，很简单，直接返回一个GraphicBuffer对象。不是说GraphicBuffer很大，Binder没有办法传输吗？为什么这里又能返回到app进程呢？稍后解析。这里就能Surface就记录了对应index的GraphicBuffer。

### Surface queueBuffer
```cpp
int Surface::queueBuffer(android_native_buffer_t* buffer, int fenceFd) {
    ATRACE_CALL();
    ALOGV("Surface::queueBuffer");
    Mutex::Autolock lock(mMutex);
    int64_t timestamp;
    bool isAutoTimestamp = false;

    if (mTimestamp == NATIVE_WINDOW_TIMESTAMP_AUTO) {
        timestamp = systemTime(SYSTEM_TIME_MONOTONIC);
        isAutoTimestamp = true;
    } else {
        timestamp = mTimestamp;
    }
    int i = getSlotFromBufferLocked(buffer);
    if (i < 0) {
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        return i;
    }
    if (mSharedBufferSlot == i && mSharedBufferHasBeenQueued) {
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        return OK;
    }


    // Make sure the crop rectangle is entirely inside the buffer.
    Rect crop(Rect::EMPTY_RECT);
    mCrop.intersect(Rect(buffer->width, buffer->height), &crop);

    sp<Fence> fence(fenceFd >= 0 ? new Fence(fenceFd) : Fence::NO_FENCE);
    IGraphicBufferProducer::QueueBufferOutput output;
    IGraphicBufferProducer::QueueBufferInput input(timestamp, isAutoTimestamp,
            static_cast<android_dataspace>(mDataSpace), crop, mScalingMode,
            mTransform ^ mStickyTransform, fence, mStickyTransform,
            mEnableFrameTimestamps);

    input.setHdrMetadata(mHdrMetadata);

    if (mConnectedToCpu || mDirtyRegion.bounds() == Rect::INVALID_RECT) {
        input.setSurfaceDamage(Region::INVALID_REGION);
    } else {
     
        int width = buffer->width;
        int height = buffer->height;
        bool rotated90 = (mTransform ^ mStickyTransform) &
                NATIVE_WINDOW_TRANSFORM_ROT_90;
        if (rotated90) {
            std::swap(width, height);
        }

        Region flippedRegion;
        for (auto rect : mDirtyRegion) {
            int left = rect.left;
            int right = rect.right;
            int top = height - rect.bottom; // Flip from OpenGL convention
            int bottom = height - rect.top; // Flip from OpenGL convention
            switch (mTransform ^ mStickyTransform) {
                case NATIVE_WINDOW_TRANSFORM_ROT_90: {
                    // Rotate 270 degrees
                    Rect flippedRect{top, width - right, bottom, width - left};
                    flippedRegion.orSelf(flippedRect);
                    break;
                }
                case NATIVE_WINDOW_TRANSFORM_ROT_180: {
                    // Rotate 180 degrees
                    Rect flippedRect{width - right, height - bottom,
                            width - left, height - top};
                    flippedRegion.orSelf(flippedRect);
                    break;
                }
                case NATIVE_WINDOW_TRANSFORM_ROT_270: {
                    // Rotate 90 degrees
                    Rect flippedRect{height - bottom, left,
                            height - top, right};
                    flippedRegion.orSelf(flippedRect);
                    break;
                }
                default: {
                    Rect flippedRect{left, top, right, bottom};
                    flippedRegion.orSelf(flippedRect);
                    break;
                }
            }
        }

        input.setSurfaceDamage(flippedRegion);
    }

    nsecs_t now = systemTime();
    status_t err = mGraphicBufferProducer->queueBuffer(i, input, &output);
    mLastQueueDuration = systemTime() - now;
 ...
    if (mEnableFrameTimestamps) {
        mFrameEventHistory->applyDelta(output.frameTimestamps);
        mFrameEventHistory->updateAcquireFence(mNextFrameNumber,
                std::make_shared<FenceTime>(std::move(fence)));
...
        mFrameEventHistory->updateSignalTimes();
    }

    mLastFrameNumber = mNextFrameNumber;

    mDefaultWidth = output.width;
    mDefaultHeight = output.height;
    mNextFrameNumber = output.nextFrameNumber;

    // Disable transform hint if sticky transform is set.
    if (mStickyTransform == 0) {
        mTransformHint = output.transformHint;
    }

    mConsumerRunningBehind = (output.numPendingBuffers >= 2);

    if (!mConnectedToCpu) {
        // Clear surface damage back to full-buffer
        mDirtyRegion = Region::INVALID_REGION;
    }

    if (mSharedBufferMode && mAutoRefresh && mSharedBufferSlot == i) {
        mSharedBufferHasBeenQueued = true;
    }

    mQueueBufferCondition.broadcast();

    return err;
}
```
流程如下：
- 1.获取当前的时间戳，等着作为参数传出去。通过getSlotFromBufferLocked检测GraphicBuffer有没有保存在Surface的mSlots中，没有就不能进行下一步。
- 2.设置所有的必须的参数给QueueBufferInput。如crop裁剪区域，fence同步栅。如果打开了硬件加速，则会设置Surface的Image。如果发现旋转角度，则会旋转像素区域，最后进行合并。最后设置到input。
- 3.调用BufferQueueProducer的queueBuffer，把图元对应的下标index设置进BufferQueueProducer中处理。
- 4.更新mFrameEventHistory数据。
- 5.设置framebuffer，记录前后两帧在对应index；记录入队消耗的时间等辅助参数。

### BufferQueueProducer queueBuffer
```cpp
status_t BufferQueueProducer::queueBuffer(int slot,
        const QueueBufferInput &input, QueueBufferOutput *output) {
...

    int64_t requestedPresentTimestamp;
    bool isAutoTimestamp;
    android_dataspace dataSpace;
    Rect crop(Rect::EMPTY_RECT);
    int scalingMode;
    uint32_t transform;
    uint32_t stickyTransform;
    sp<Fence> acquireFence;
    bool getFrameTimestamps = false;
    input.deflate(&requestedPresentTimestamp, &isAutoTimestamp, &dataSpace,
            &crop, &scalingMode, &transform, &acquireFence, &stickyTransform,
            &getFrameTimestamps);
    const Region& surfaceDamage = input.getSurfaceDamage();
    const HdrMetadata& hdrMetadata = input.getHdrMetadata();
...
    auto acquireFenceTime = std::make_shared<FenceTime>(acquireFence);

    switch (scalingMode) {
        case NATIVE_WINDOW_SCALING_MODE_FREEZE:
        case NATIVE_WINDOW_SCALING_MODE_SCALE_TO_WINDOW:
        case NATIVE_WINDOW_SCALING_MODE_SCALE_CROP:
        case NATIVE_WINDOW_SCALING_MODE_NO_SCALE_CROP:
            break;
        default:
           ...
            return BAD_VALUE;
    }

    sp<IConsumerListener> frameAvailableListener;
    sp<IConsumerListener> frameReplacedListener;
    int callbackTicket = 0;
    uint64_t currentFrameNumber = 0;
    BufferItem item;
    { // Autolock scope
        Mutex::Autolock lock(mCore->mMutex);

...

        if (mCore->mSharedBufferMode && mCore->mSharedBufferSlot ==
                BufferQueueCore::INVALID_BUFFER_SLOT) {
            mCore->mSharedBufferSlot = slot;
            mSlots[slot].mBufferState.mShared = true;
        }

        const sp<GraphicBuffer>& graphicBuffer(mSlots[slot].mGraphicBuffer);
        Rect bufferRect(graphicBuffer->getWidth(), graphicBuffer->getHeight());
        Rect croppedRect(Rect::EMPTY_RECT);
        crop.intersect(bufferRect, &croppedRect);


        if (dataSpace == HAL_DATASPACE_UNKNOWN) {
            dataSpace = mCore->mDefaultBufferDataSpace;
        }

        mSlots[slot].mFence = acquireFence;
        mSlots[slot].mBufferState.queue();

        ++mCore->mFrameCounter;
        currentFrameNumber = mCore->mFrameCounter;
        mSlots[slot].mFrameNumber = currentFrameNumber;

        item.mAcquireCalled = mSlots[slot].mAcquireCalled;
        item.mGraphicBuffer = mSlots[slot].mGraphicBuffer;
        item.mCrop = crop;
        item.mTransform = transform &
                ~static_cast<uint32_t>(NATIVE_WINDOW_TRANSFORM_INVERSE_DISPLAY);
        item.mTransformToDisplayInverse =
                (transform & NATIVE_WINDOW_TRANSFORM_INVERSE_DISPLAY) != 0;
        item.mScalingMode = static_cast<uint32_t>(scalingMode);
        item.mTimestamp = requestedPresentTimestamp;
        item.mIsAutoTimestamp = isAutoTimestamp;
        item.mDataSpace = dataSpace;
        item.mHdrMetadata = hdrMetadata;
        item.mFrameNumber = currentFrameNumber;
        item.mSlot = slot;
        item.mFence = acquireFence;
        item.mFenceTime = acquireFenceTime;
        item.mIsDroppable = mCore->mAsyncMode ||
                mCore->mDequeueBufferCannotBlock ||
                (mCore->mSharedBufferMode && mCore->mSharedBufferSlot == slot);
        item.mSurfaceDamage = surfaceDamage;
        item.mQueuedBuffer = true;
        item.mAutoRefresh = mCore->mSharedBufferMode && mCore->mAutoRefresh;
        item.mApi = mCore->mConnectedApi;

        mStickyTransform = stickyTransform;

        // Cache the shared buffer data so that the BufferItem can be recreated.
        if (mCore->mSharedBufferMode) {
            mCore->mSharedBufferCache.crop = crop;
            mCore->mSharedBufferCache.transform = transform;
            mCore->mSharedBufferCache.scalingMode = static_cast<uint32_t>(
                    scalingMode);
            mCore->mSharedBufferCache.dataspace = dataSpace;
        }

        output->bufferReplaced = false;
        if (mCore->mQueue.empty()) {
            mCore->mQueue.push_back(item);
            frameAvailableListener = mCore->mConsumerListener;
        } else {
            const BufferItem& last = mCore->mQueue.itemAt(
                    mCore->mQueue.size() - 1);
            if (last.mIsDroppable) {

                if (!last.mIsStale) {
                    mSlots[last.mSlot].mBufferState.freeQueued();


                    if (!mCore->mSharedBufferMode &&
                            mSlots[last.mSlot].mBufferState.isFree()) {
                        mSlots[last.mSlot].mBufferState.mShared = false;
                    }
                    // Don't put the shared buffer on the free list.
                    if (!mSlots[last.mSlot].mBufferState.isShared()) {
                        mCore->mActiveBuffers.erase(last.mSlot);
                        mCore->mFreeBuffers.push_back(last.mSlot);
                        output->bufferReplaced = true;
                    }
                }

                mCore->mQueue.editItemAt(mCore->mQueue.size() - 1) = item;
                frameReplacedListener = mCore->mConsumerListener;
            } else {
                mCore->mQueue.push_back(item);
                frameAvailableListener = mCore->mConsumerListener;
            }
        }

        mCore->mBufferHasBeenQueued = true;
        mCore->mDequeueCondition.broadcast();
        mCore->mLastQueuedSlot = slot;

        output->width = mCore->mDefaultWidth;
        output->height = mCore->mDefaultHeight;
        output->transformHint = mCore->mTransformHint;
        output->numPendingBuffers = static_cast<uint32_t>(mCore->mQueue.size());
        output->nextFrameNumber = mCore->mFrameCounter + 1;

        ATRACE_INT(mCore->mConsumerName.string(),
                static_cast<int32_t>(mCore->mQueue.size()));
        mCore->mOccupancyTracker.registerOccupancyChange(mCore->mQueue.size());

        // Take a ticket for the callback functions
        callbackTicket = mNextCallbackTicket++;

        VALIDATE_CONSISTENCY();
    } // Autolock scope

    if (!mConsumerIsSurfaceFlinger) {
        item.mGraphicBuffer.clear();
    }


    item.mSlot = BufferItem::INVALID_BUFFER_SLOT;


    int connectedApi;
    sp<Fence> lastQueuedFence;

    { // scope for the lock
        Mutex::Autolock lock(mCallbackMutex);
        while (callbackTicket != mCurrentCallbackTicket) {
            mCallbackCondition.wait(mCallbackMutex);
        }

        if (frameAvailableListener != NULL) {
            frameAvailableListener->onFrameAvailable(item);
        } else if (frameReplacedListener != NULL) {
            frameReplacedListener->onFrameReplaced(item);
        }

        connectedApi = mCore->mConnectedApi;
        lastQueuedFence = std::move(mLastQueueBufferFence);

        mLastQueueBufferFence = std::move(acquireFence);
        mLastQueuedCrop = item.mCrop;
        mLastQueuedTransform = item.mTransform;

        ++mCurrentCallbackTicket;
        mCallbackCondition.broadcast();
    }

    // Wait without lock held
    if (connectedApi == NATIVE_WINDOW_API_EGL) {
      
        lastQueuedFence->waitForever("Throttling EGL Production");
    }

    // Update and get FrameEventHistory.
    nsecs_t postedTime = systemTime(SYSTEM_TIME_MONOTONIC);
    NewFrameEventsEntry newFrameEventsEntry = {
        currentFrameNumber,
        postedTime,
        requestedPresentTimestamp,
        std::move(acquireFenceTime)
    };
    addAndGetFrameTimestamps(&newFrameEventsEntry,
            getFrameTimestamps ? &output->frameTimestamps : nullptr);

    return NO_ERROR;
}
```
核心有四个：
- 1.拿到当前需要入队的图元，并且把QueueBufferInput设置的参数全部取出，设置到BufferItem中，接着设置到BufferQueueCore的mQueue中，mQueue为如下类型：
```cpp
typedef Vector<BufferItem> Fifo;
```

其实在这个阶段判断mQueue如果为空，直接加到mQueue的末尾。不为空，需要判断最后一个图元是否已经不需要显示了，如果是共享模式的图元，则关闭。不是，则会从Active区域移除，放到Free区域中，并且代替mQueue最后一个图元。否则还是放到mQueue末尾。

- 2.设置QueueBufferOutput参数，能看到nextframebuffer，就是BufferQueueCore中包含者帧数+1。

- 3.调用frameAvailableListener回调。这个回调在缓冲队列初始化有专门介绍过。是通知消费者可以进行消费图元的回调。

- 4. addAndGetFrameTimestamps 更新当前帧时间戳。

### addAndGetFrameTimestamps
```cpp
 nsecs_t postedTime = systemTime(SYSTEM_TIME_MONOTONIC);
    NewFrameEventsEntry newFrameEventsEntry = {
        currentFrameNumber,
        postedTime,
        requestedPresentTimestamp,
        std::move(acquireFenceTime)
    };
    addAndGetFrameTimestamps(&newFrameEventsEntry,
            getFrameTimestamps ? &output->frameTimestamps : nullptr);
```
- 1.currentFrameNumber 每当进入queueBuffer，就会自动添加一次mFrameCounter，这个参数代表这是当前Surface诞生以来第几帧。
- 2.postedTime 完成queue时候的时间。
- 3.requestedPresentTimestamp 应用端调用Binder通信时候的时刻。
- 4.acquireFenceTime 一个同步栅

```cpp
void BufferQueueProducer::addAndGetFrameTimestamps(
        const NewFrameEventsEntry* newTimestamps,
        FrameEventHistoryDelta* outDelta) {
    if (newTimestamps == nullptr && outDelta == nullptr) {
        return;
    }

    sp<IConsumerListener> listener;
    {
        Mutex::Autolock lock(mCore->mMutex);
        listener = mCore->mConsumerListener;
    }
    if (listener != NULL) {
        listener->addAndGetFrameTimestamps(newTimestamps, outDelta);
    }
}
```
此时就是回调到消费者中的监听回调，具体做了什么之后再说。

### unlock 解锁图元
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)

```cpp
status_t egl_window_surface_v2_t::unlock(ANativeWindowBuffer* buf)
{
    if (!buf) return BAD_VALUE;
    auto& mapper = GraphicBufferMapper::get();
    return mapper.unlock(buf->handle);
}
```
能看到GraphicBufferMapper调用以ANativeWindowBuffer的handle为线索unlock解锁图元映射。

## 小结
在整个流程中，我们能够看到生产者生产涉及到的主要角色如下：
- 1.GraphicBufferMapper
- 2.BufferQueueProducer
- 3.Surface(ANativeWindow)
- 4.GraphicBuffer（ANativeWindowBuffer）

Surface是面向应用客户端的图元生产者，BufferQueueProducer是面向SF服务端的图元生产者。其核心涉及实际是查找mSlot中有没有空闲的位置，让图元占用。但是真正进行消费的时候，需要设置到BufferItem的Vector中。

但是思考过没有，一个图元代表一帧的数据。一个屏幕常见的占用的内存1080*1920*4 早就超过了应用传输Binder的极限1040k.那么系统是怎么规避这个问题呢？

我们从dequeue步骤中能看到，每一次dequeue之后先回返回一个mSlot的下标，即使在这个步骤已经new了一个GraphicBuffer，他也不会返回GraphicBuffer。但是到了requestBuffer就能GraphicBuffer对象。为什么这么设计？就算是返回了GraphicBuffer对象，Binder会因为这个对象占用太大而报错。

系统是怎么办到的？而且在OpenGL es中eglSwapBuffers中，把framebuffer_t和ANativeWindowBuffer的bit属性关联起来，ANativeWindowBuffer又是怎么在跨进程通信初始化bit字段的？

接下来让我们专门来解析GraphicBuffer类。

### GraphicBuffer 初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[include](http://androidxref.com/9.0.0_r3/xref/frameworks/native/include/)/[ui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/include/ui/)/[GraphicBuffer.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/include/ui/GraphicBuffer.h)
先来看看其继承关系：
```cpp

class GraphicBuffer
    : public ANativeObjectBase<ANativeWindowBuffer, GraphicBuffer, RefBase>,
      public Flattenable<GraphicBuffer>
```
GraphicBuffer继承于ANativeWindowBuffer和Flattenable，前者是在ANativeWindow中的图元缓冲，后者是Binder 传输时候的Parcel封装IBinder。但是这里里面的flattern和unflattern方法被重写了为自己的保存所有参数的方法。我们稍后再看。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[ui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/)/[GraphicBuffer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/GraphicBuffer.cpp)
```cpp
        sp<GraphicBuffer> graphicBuffer = new GraphicBuffer(
                width, height, format, BQ_LAYER_COUNT, usage,
                {mConsumerName.string(), mConsumerName.size()});
```

```cpp
GraphicBuffer::GraphicBuffer(uint32_t inWidth, uint32_t inHeight,
        PixelFormat inFormat, uint32_t inLayerCount, uint64_t usage, std::string requestorName)
    : GraphicBuffer()
{
    mInitCheck = initWithSize(inWidth, inHeight, inFormat, inLayerCount,
            usage, std::move(requestorName));
}
```

```cpp
status_t GraphicBuffer::initWithSize(uint32_t inWidth, uint32_t inHeight,
        PixelFormat inFormat, uint32_t inLayerCount, uint64_t inUsage,
        std::string requestorName)
{
    GraphicBufferAllocator& allocator = GraphicBufferAllocator::get();
    uint32_t outStride = 0;
    status_t err = allocator.allocate(inWidth, inHeight, inFormat, inLayerCount,
            inUsage, &handle, &outStride, mId,
            std::move(requestorName));
    if (err == NO_ERROR) {
        mBufferMapper.getTransportSize(handle, &mTransportNumFds, &mTransportNumInts);

        width = static_cast<int>(inWidth);
        height = static_cast<int>(inHeight);
        format = inFormat;
        layerCount = inLayerCount;
        usage = inUsage;
        usage_deprecated = int(usage);
        stride = static_cast<int>(outStride);
    }
    return err;
}
```
在初始化中有一个十分核心的类GraphicBufferAllocator，图元申请器。这个类真正在一个GraphicBuffer的壳内，通过allocate真正生成一个核心内存块。接着会调用GraphicBufferMapper. getTransportSize在Mapper中记录大小。请注意，allocate方法中有一个十分核心的参数handle。他是来自ANativeWindowBuffer：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[nativebase](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativebase/)/[include](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativebase/include/)/[nativebase](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativebase/include/nativebase/)/[nativebase.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativebase/include/nativebase/nativebase.h)
```cpp
const native_handle_t* handle;
```

```cpp
typedef struct native_handle
{
    int version;        /* sizeof(native_handle_t) */
    int numFds;         /* number of file-descriptors at &data[0] */
    int numInts;        /* number of ints at &data[numFds] */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wzero-length-array"
#endif
    int data[0];        /* numFds + numInts ints */
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
} native_handle_t;
```
native_handle_t实际上是的GraphicBuffer的句柄。

让我们依次看看GraphicBufferAllocator和GraphicBufferMapper都做了什么。


## GraphicBufferAllocator 初始化
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[ui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/)/[GraphicBufferAllocator.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/GraphicBufferAllocator.cpp)

```cpp
ANDROID_SINGLETON_STATIC_INSTANCE( GraphicBufferAllocator )

Mutex GraphicBufferAllocator::sLock;
KeyedVector<buffer_handle_t,
    GraphicBufferAllocator::alloc_rec_t> GraphicBufferAllocator::sAllocList;

GraphicBufferAllocator::GraphicBufferAllocator()
  : mMapper(GraphicBufferMapper::getInstance()),
    mAllocator(std::make_unique<Gralloc2::Allocator>(
                mMapper.getGrallocMapper()))
{
}
```

ANDROID_SINGLETON_STATIC_INSTANCE这个宏实际上就是一个单例：
```cpp
template <typename TYPE>
class ANDROID_API Singleton
{
public:
    static TYPE& getInstance() {
        Mutex::Autolock _l(sLock);
        TYPE* instance = sInstance;
        if (instance == 0) {
            instance = new TYPE();
            sInstance = instance;
        }
        return *instance;
    }

    static bool hasInstance() {
        Mutex::Autolock _l(sLock);
        return sInstance != 0;
    }
    
protected:
    ~Singleton() { }
    Singleton() { }

private:
    Singleton(const Singleton&);
    Singleton& operator = (const Singleton&);
    static Mutex sLock;
    static TYPE* sInstance;
};

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#define ANDROID_SINGLETON_STATIC_INSTANCE(TYPE)                 \
    template<> ::android::Mutex  \
        (::android::Singleton< TYPE >::sLock)(::android::Mutex::PRIVATE);  \
    template<> TYPE* ::android::Singleton< TYPE >::sInstance(0);  /* NOLINT */ \
    template class ::android::Singleton< TYPE >;
```
其实很简单有一个静态方法，上锁后获取一个静态实例。


在构造函数中实例化了两个十分核心对象：
- 1.GraphicBufferMapper
- 2.Gralloc2::Allocator 从GraphicBufferMapper获图元生成器

### GraphicBufferMapper 初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[ui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/)/[GraphicBufferMapper.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/GraphicBufferMapper.cpp)

```cpp
ANDROID_SINGLETON_STATIC_INSTANCE( GraphicBufferMapper )

GraphicBufferMapper::GraphicBufferMapper()
  : mMapper(std::make_unique<const Gralloc2::Mapper>())
{
}
```
初始化核心对象Gralloc2::Mapper。

其实Gralloc2::Mapper和Gralloc2::Allocator两者都是对应Hal层的对象。我们依次看看两者的初始化。

#### Gralloc2::Mapper 的初始化
```cpp
Mapper::Mapper()
{
    mMapper = hardware::graphics::mapper::V2_0::IMapper::getService();
...

    // IMapper 2.1 is optional
    mMapperV2_1 = IMapper::castFrom(mMapper);
}
```
能看到本质上是沟通了Hal层的hwServiceManager之后，获取IMapper的服务。

之前在SurfaceFlinger的HAL层初始化有详细的介绍，这里就不多赘述。这里就直接摆出关键几个数据结构。

### Gralloc2::Mapper HAL层的数据结构介绍

从我之前几篇文章能够知道，一般来说HAL需要hw_module_t的结构体作为核心。本文继续以msm8960为基准，Gralloc2对应的Hal层全部都是passthrough 直通模式，我们看看这个数据结构
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[gralloc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/gralloc.cpp)
```cpp
struct private_module_t HAL_MODULE_INFO_SYM = {
    .base = {
        .common = {
            .tag = HARDWARE_MODULE_TAG,
            .module_api_version = GRALLOC_MODULE_API_VERSION_0_2,
            .hal_api_version = 0,
            .id = GRALLOC_HARDWARE_MODULE_ID,
            .name = "Graphics Memory Allocator Module",
            .author = "The Android Open Source Project",
            .methods = &gralloc_module_methods,
            .dso = 0,
        },
        .registerBuffer = gralloc_register_buffer,
        .unregisterBuffer = gralloc_unregister_buffer,
        .lock = gralloc_lock,
        .unlock = gralloc_unlock,
        .perform = gralloc_perform,
        .lock_ycbcr = gralloc_lock_ycbcr,
    },
    .framebuffer = 0,
    .fbFormat = 0,
    .flags = 0,
    .numBuffers = 0,
    .bufferMask = 0,
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .currentBuffer = 0,
};
```
能看到这里面gralloc对应的结构体，module_api_version 代表gralloc hal结构体的版本。此时版本为0.2。以及注册了gralloc_register_buffer，gralloc_unregister_buffer，gralloc_lock，gralloc_unlock，gralloc_perform,gralloc_lock_ycbcr的方法指针.

对应hw_module_t的包装类是Gralloc0HalImpl 。gralloc有点特殊，没有包装成hw_device_t，而是直接操作hw_module_t。

位置如下：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[mapper](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/)/[mapper-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/2.0/)/[Gralloc0Hal.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/2.0/Gralloc0Hal.h)

最后我们关注IMapper.hal，看看这个hal层开放了什么方法给上层：
```
interface IMapper {
...

    @entry
    @callflow(next="*")
    createDescriptor(BufferDescriptorInfo descriptorInfo)
          generates (Error error,
                     BufferDescriptor descriptor);

    @entry
    @callflow(next="*")
    importBuffer(handle rawHandle) generates (Error error, pointer buffer);


    @exit
    @callflow(next="*")
    freeBuffer(pointer buffer) generates (Error error);

    @callflow(next="unlock")
    lock(pointer buffer,
         bitfield<BufferUsage> cpuUsage,
         Rect accessRegion,
         handle acquireFence)
        generates (Error error,
                   pointer data);

    @callflow(next="unlock")
    lockYCbCr(pointer buffer,
              bitfield<BufferUsage> cpuUsage,
              Rect accessRegion,
              handle acquireFence)
        generates (Error error,
                   YCbCrLayout layout);

    @callflow(next="*")
    unlock(pointer buffer)
        generates (Error error,
                   handle releaseFence);
};

```

一共四个方法：
- 1.importBuffer 生成可用的Buffer
- 2.freeBuffer 释放Buffer
- 3.lock 上锁buffer
- 4.lockYCbCr 上锁一个ycbcr的像素格式的buffer
- 4.unlock 解锁锁buffer

最后包装在这个HalImpl的类之上，在包装一层GrallocMapper给上层：
```cpp
template <typename T>
class GrallocMapper : public T {
   protected:
    void* addImportedBuffer(native_handle_t* bufferHandle) override {
        return GrallocImportedBufferPool::getInstance().add(bufferHandle);
    }

    native_handle_t* removeImportedBuffer(void* buffer) override {
        return GrallocImportedBufferPool::getInstance().remove(buffer);
    }

    const native_handle_t* getImportedBuffer(void* buffer) const override {
        return GrallocImportedBufferPool::getInstance().get(buffer);
    }
};
```

GrallocMapper是继承与MapperImpl，位置如下。

/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[mapper](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/)/[mapper-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/2.0/)/[Mapper.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/2.0/Mapper.h)




### Gralloc2::Allocator HAL层的数据结构介绍
其实对于Allocator来说,其实对应的hw_module_t和IMapper是一致的。只不过不同的hal对象开发的api不同。对于Allocator他只关注如何申请内存出来。
先来看看对应的hal文件：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[allocator](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/)/[IAllocator.hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/IAllocator.hal)

```
interface IAllocator {

    @entry
    @exit
    @callflow(next="*")
    dumpDebugInfo() generates (string debugInfo);

    @entry
    @exit
    @callflow(next="*")
    allocate(BufferDescriptor descriptor, uint32_t count)
        generates (Error error,
                   uint32_t stride,
                   vec<handle> buffers);
};
```

其实只有一个allocate的方法，进行内存申请。不过在IAllocator的包装类Gralloc0HalImpl在调用initMoudle初始化hw_module_t的时候，调用了如下方法：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[allocator](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/)/[allocator-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/2.0/)/[Gralloc0Hal.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/2.0/Gralloc0Hal.h)

```cpp
    bool initWithModule(const hw_module_t* module) {
        int result = gralloc_open(module, &mDevice);
        if (result) {
            mDevice = nullptr;
            return false;
        }

        return true;
    }
```

这里调用了gralloc_open，对hw_module_t进行初始化，生成一个hw_device_t.
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[gralloc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/gralloc.cpp)

```cpp
int gralloc_device_open(const hw_module_t* module, const char* name,
                        hw_device_t** device)
{
    int status = -EINVAL;
    if (!strcmp(name, GRALLOC_HARDWARE_GPU0)) {
        const private_module_t* m = reinterpret_cast<const private_module_t*>(
            module);
        gpu_context_t *dev;
        IAllocController* alloc_ctrl = IAllocController::getInstance();
        dev = new gpu_context_t(m, alloc_ctrl);
        *device = &dev->common;
        status = 0;
    } else {
        status = fb_device_open(module, name, device);
    }
    return status;
}
```

在gralloc初始化hw_device_t时候，会判断hw_module_t中的name字段。是否打开gralloc服务。打开就使用gpu_context_t包装gralloc申请服务返回给上层，不打开则使用老的方式framebuffer，通信fb驱动。

能看到上面hw_module_t.name字段就是GRALLOC_HARDWARE_GPU0。其实绝大部分都是在使用gralloc服务。framebuffer的服务将不会仔细聊，我们把重点放到gralloc服务。

再来看看gpu_context_t：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[gpu.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/gpu.cpp)
```
gpu_context_t::gpu_context_t(const private_module_t* module,
                             IAllocController* alloc_ctrl ) :
    mAllocCtrl(alloc_ctrl)
{
    // Zero out the alloc_device_t
    memset(static_cast<alloc_device_t*>(this), 0, sizeof(alloc_device_t));

    // Initialize the procs
    common.tag     = HARDWARE_DEVICE_TAG;
    common.version = 0;
    common.module  = const_cast<hw_module_t*>(&module->base.common);
    common.close   = gralloc_close;
    alloc          = gralloc_alloc;
#ifdef QCOM_BSP
    allocSize      = gralloc_alloc_size;
#endif
    free           = gralloc_free;

}
```

到了这一步，才真正的给整个hal的allocate方法赋予意义。

先来看看IAllocController 这个单例初始化。

#### IAllocController 初始化
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[alloc_controller.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/alloc_controller.cpp)
```cpp
IAllocController* IAllocController::sController = NULL;
IAllocController* IAllocController::getInstance(void)
{
    if(sController == NULL) {
        sController = new IonController();
    }
    return sController;
}


//-------------- IonController-----------------------//
IonController::IonController()
{
    mIonAlloc = new IonAlloc();
}
```
IAllocController中间包装了一个IonAlloc。IonController中包装一个ion驱动控制器IonAlloc。IonAlloc实际上继承IMemAlloc。

最后对应着HAL向外暴露的对象为AllocatorImpl

### 小结
涉及到的对象有点多，我们还是画一个UML图来梳理一遍整个GraphicAllactor的Hal层初始化。
![GraphicBuffer生成体系.png](/images/GraphicBuffer生成体系.png)

记住这幅图就能对整个GraphicBuffer的体系的设计了然于胸。


### GraphicBuffer Hal层的生成原理
在GraphicBuffer中其核心方法为：
- 1.GraphicBufferAllocator. allocate。
- 2.GraphicBufferMapper. getTransportSize

让我们依次解析这两个方法。
```cpp
status_t GraphicBufferAllocator::allocate(uint32_t width, uint32_t height,
        PixelFormat format, uint32_t layerCount, uint64_t usage,
        buffer_handle_t* handle, uint32_t* stride,
        uint64_t /*graphicBufferId*/, std::string requestorName)
{
    ATRACE_CALL();

    // make sure to not allocate a N x 0 or 0 x N buffer, since this is
    // allowed from an API stand-point allocate a 1x1 buffer instead.
    if (!width || !height)
        width = height = 1;

    // Ensure that layerCount is valid.
    if (layerCount < 1)
        layerCount = 1;

    Gralloc2::IMapper::BufferDescriptorInfo info = {};
    info.width = width;
    info.height = height;
    info.layerCount = layerCount;
    info.format = static_cast<Gralloc2::PixelFormat>(format);
    info.usage = usage;

    Gralloc2::Error error = mAllocator->allocate(info, stride, handle);
    if (error == Gralloc2::Error::NONE) {
        Mutex::Autolock _l(sLock);
        KeyedVector<buffer_handle_t, alloc_rec_t>& list(sAllocList);
        uint32_t bpp = bytesPerPixel(format);
        alloc_rec_t rec;
        rec.width = width;
        rec.height = height;
        rec.stride = *stride;
        rec.format = format;
        rec.layerCount = layerCount;
        rec.usage = usage;
        rec.size = static_cast<size_t>(height * (*stride) * bpp);
        rec.requestorName = std::move(requestorName);
        list.add(*handle, rec);

        return NO_ERROR;
    } else {
...
        return NO_MEMORY;
    }
}
```
核心方法就是把buffer_handle_t句柄作为参数调用mAllocator的allocate方法，接着获得真正申请出来的参数保存到sAllocList中。之后删除就能通过handle找到对应的参数销毁。

#### Gralloc2::Allocator allocate

```cpp
    Error allocate(const IMapper::BufferDescriptorInfo& descriptorInfo, uint32_t count,
            uint32_t* outStride, buffer_handle_t* outBufferHandles) const
    {
        BufferDescriptor descriptor;
        Error error = mMapper.createDescriptor(descriptorInfo, &descriptor);
        if (error == Error::NONE) {
            error = allocate(descriptor, count, outStride, outBufferHandles);
        }
        return error;
    }

    Error allocate(const IMapper::BufferDescriptorInfo& descriptorInfo,
            uint32_t* outStride, buffer_handle_t* outBufferHandle) const
    {
        return allocate(descriptorInfo, 1, outStride, outBufferHandle);
    }
```
先使用了Gralloc2::Mapper创建了BufferDescriptor对象。很简单就不去看，就是在Hal层初始化了BufferDescriptor对象。

```
Error Allocator::allocate(BufferDescriptor descriptor, uint32_t count,
        uint32_t* outStride, buffer_handle_t* outBufferHandles) const
{
    Error error;
    auto ret = mAllocator->allocate(descriptor, count,
            [&](const auto& tmpError, const auto& tmpStride,
                const auto& tmpBuffers) {
                error = tmpError;
                if (tmpError != Error::NONE) {
                    return;
                }

                // import buffers
                for (uint32_t i = 0; i < count; i++) {
                    error = mMapper.importBuffer(tmpBuffers[i],
                            &outBufferHandles[i]);
                    if (error != Error::NONE) {
                        for (uint32_t j = 0; j < i; j++) {
                            mMapper.freeBuffer(outBufferHandles[j]);
                            outBufferHandles[j] = nullptr;
                        }
                        return;
                    }
                }

                *outStride = tmpStride;
            });

    // make sure the kernel driver sees BC_FREE_BUFFER and closes the fds now
    hardware::IPCThreadState::self()->flushCommands();

    return (ret.isOk()) ? error : kTransactionError;
}
```
能看到这里就会调用了Hal层对应AllocatorImpl的申请多个图元方法。能看到在申请完内存之后，将会调用GraphicBufferMapper的importBuffer方法，让这段句柄对应的内存变得可用。

##### AllocatorImpl allocate
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[allocator](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/hal/include/)/[allocator-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/hal/include/allocator-hal/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/hal/include/allocator-hal/2.0/)/[Allocator.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/hal/include/allocator-hal/2.0/Allocator.h)

```cpp
    Return<void> allocate(const BufferDescriptor& descriptor, uint32_t count,
                          IAllocator::allocate_cb hidl_cb) override {
        uint32_t stride;
        std::vector<const native_handle_t*> buffers;
        Error error = mHal->allocateBuffers(descriptor, count, &stride, &buffers);
        if (error != Error::NONE) {
            hidl_cb(error, 0, hidl_vec<hidl_handle>());
            return Void();
        }

        hidl_vec<hidl_handle> hidlBuffers(buffers.cbegin(), buffers.cend());
        hidl_cb(Error::NONE, stride, hidlBuffers);

        // free the local handles
        mHal->freeBuffers(buffers);

        return Void();
    }
```
此时还是一样调用mHal的allocateBuffers的方法，并且使用hidl_handle包装native_handle_t。换句话说，实际上我们在上层GraphicBuffer拿到的handle是hidl_handle对象。

##### Gralloc0HalImpl::allocateBuffers
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[allocator](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/)/[allocator-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/2.0/)/[Gralloc0Hal.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/allocator/2.0/utils/passthrough/include/allocator-passthrough/2.0/Gralloc0Hal.h)

```cpp
    Error allocateBuffers(const BufferDescriptor& descriptor, uint32_t count, uint32_t* outStride,
                          std::vector<const native_handle_t*>* outBuffers) override {
        mapper::V2_0::IMapper::BufferDescriptorInfo descriptorInfo;
        if (!grallocDecodeBufferDescriptor(descriptor, &descriptorInfo)) {
            return Error::BAD_DESCRIPTOR;
        }

        Error error = Error::NONE;
        uint32_t stride = 0;
        std::vector<const native_handle_t*> buffers;
        buffers.reserve(count);

        // allocate the buffers
        for (uint32_t i = 0; i < count; i++) {
            const native_handle_t* tmpBuffer;
            uint32_t tmpStride;
            error = allocateOneBuffer(descriptorInfo, &tmpBuffer, &tmpStride);
            if (error != Error::NONE) {
                break;
            }

            buffers.push_back(tmpBuffer);

            if (stride == 0) {
                stride = tmpStride;
            } else if (stride != tmpStride) {
                // non-uniform strides
                error = Error::UNSUPPORTED;
                break;
            }
        }

...
        *outStride = stride;
        *outBuffers = std::move(buffers);

        return Error::NONE;
    }
```
核心的方法是allocateOneBuffer申请一个图元内存。我们直接看对应的gralloc的实现。

```cpp
    Error allocateOneBuffer(const mapper::V2_0::IMapper::BufferDescriptorInfo& info,
                            const native_handle_t** outBuffer, uint32_t* outStride) {
        if (info.layerCount > 1 || (info.usage >> 32) != 0) {
            return Error::BAD_VALUE;
        }

        const native_handle_t* buffer = nullptr;
        int stride = 0;
        int result = mDevice->alloc(mDevice, info.width, info.height, static_cast<int>(info.format),
                                    info.usage, &buffer, &stride);
        switch (result) {
            case 0:
                *outBuffer = buffer;
                *outStride = stride;
                return Error::NONE;
            case -EINVAL:
                return Error::BAD_VALUE;
            default:
                return Error::NO_RESOURCES;
        }
    }
```

#### gpu_context_t::gralloc_alloc
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[gpu.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/gpu.cpp)

```cpp
int gpu_context_t::gralloc_alloc(alloc_device_t* dev, int w, int h, int format,
                                 int usage, buffer_handle_t* pHandle,
                                 int* pStride)
{
    if (!dev) {
        return -EINVAL;
    }
    gpu_context_t* gpu = reinterpret_cast<gpu_context_t*>(dev);
    return gpu->alloc_impl(w, h, format, usage, pHandle, pStride, 0);
}
```

#### gpu_context_t::alloc_impl
```cpp
int gpu_context_t::alloc_impl(int w, int h, int format, int usage,
                              buffer_handle_t* pHandle, int* pStride,
                              size_t bufferSize) {
    if (!pHandle || !pStride)
        return -EINVAL;

    size_t size;
    int alignedw, alignedh;
    int grallocFormat = format;
    int bufferType;

    //If input format is HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED then based on
    //the usage bits, gralloc assigns a format.
...

    getGrallocInformationFromFormat(grallocFormat, &bufferType);
    size = getBufferSizeAndDimensions(w, h, grallocFormat, alignedw, alignedh);

    if ((ssize_t)size <= 0)
        return -EINVAL;
    size = (bufferSize >= size)? bufferSize : size;


    if ((usage & GRALLOC_USAGE_EXTERNAL_DISP) ||
        (usage & GRALLOC_USAGE_PROTECTED)) {
        bufferType = BUFFER_TYPE_VIDEO;
    }

    bool useFbMem = false;
    char property[PROPERTY_VALUE_MAX];
    if((usage & GRALLOC_USAGE_HW_FB) &&
       (property_get("debug.gralloc.map_fb_memory", property, NULL) > 0) &&
       (!strncmp(property, "1", PROPERTY_VALUE_MAX ) ||
        (!strncasecmp(property,"true", PROPERTY_VALUE_MAX )))) {
        useFbMem = true;
    }

    int err = 0;
    if(useFbMem) {
        err = gralloc_alloc_framebuffer(size, usage, pHandle);
    } else {
        err = gralloc_alloc_buffer(size, usage, pHandle, bufferType,
                                   grallocFormat, alignedw, alignedh);
    }

    if (err < 0) {
        return err;
    }

    *pStride = alignedw;
    return 0;
}
```
getBufferSizeAndDimensions计算不同规格像素需要占用的内存大小。接着检测debug.gralloc.map_fb_memory是否在全局变量中设置开，打开了gralloc服务也会强制使用fb驱动。

我们先不管fb驱动的逻辑，先看gralloc逻辑。调用gralloc_alloc_buffer。

##### gralloc_alloc_buffer
```cpp
int gpu_context_t::gralloc_alloc_buffer(size_t size, int usage,
                                        buffer_handle_t* pHandle, int bufferType,
                                        int format, int width, int height)
{
    int err = 0;
    int flags = 0;
    size = roundUpToPageSize(size);
    alloc_data data;
    data.offset = 0;
    data.fd = -1;
    data.base = 0;
    if(format == HAL_PIXEL_FORMAT_YCbCr_420_SP_TILED)
        data.align = 8192;
    else
        data.align = getpagesize();

    if ((qdutils::MDPVersion::getInstance().getMDPVersion() >= \
         qdutils::MDSS_V5) && (usage & GRALLOC_USAGE_PROTECTED)) {
        data.align = ALIGN(data.align, SZ_1M);
        size = ALIGN(size, data.align);
    }
    data.size = size;
    data.pHandle = (unsigned int) pHandle;
    err = mAllocCtrl->allocate(data, usage);

    if (!err) {
        /* allocate memory for enhancement data */
        alloc_data eData;
        eData.fd = -1;
        eData.base = 0;
        eData.offset = 0;
        eData.size = ROUND_UP_PAGESIZE(sizeof(MetaData_t));
        eData.pHandle = data.pHandle;
        eData.align = getpagesize();
        int eDataUsage = GRALLOC_USAGE_PRIVATE_SYSTEM_HEAP;
        int eDataErr = mAllocCtrl->allocate(eData, eDataUsage);

...

        flags |= data.allocType;
        int eBaseAddr = int(eData.base) + eData.offset;
        private_handle_t *hnd = new private_handle_t(data.fd, size, flags,
                bufferType, format, width, height, eData.fd, eData.offset,
                eBaseAddr);

        hnd->offset = data.offset;
        hnd->base = int(data.base) + data.offset;
        hnd->gpuaddr = 0;

        *pHandle = hnd;
    }


    return err;
}
```
alloc_data中保存handle句柄，让IonController处理。当IonController.allocate申请完内存后，alloc_data记录记录映射的共享内存的起点位置和长度，以及对应的fd。这个fd很重要，fd究竟是指什么驱动呢？我们往下看。

#### IonController allocate
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[alloc_controller.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/alloc_controller.cpp)
```cpp
int IonController::allocate(alloc_data& data, int usage)
{
    int ionFlags = 0;
    int ret;

    data.uncached = useUncached(usage);
    data.allocType = 0;

    if(usage & GRALLOC_USAGE_PRIVATE_UI_CONTIG_HEAP)
        ionFlags |= ION_HEAP(ION_SF_HEAP_ID);

    if(usage & GRALLOC_USAGE_PRIVATE_SYSTEM_HEAP)
        ionFlags |= ION_HEAP(ION_SYSTEM_HEAP_ID);

    if(usage & GRALLOC_USAGE_PRIVATE_IOMMU_HEAP)
        ionFlags |= ION_HEAP(ION_IOMMU_HEAP_ID);

    //MM Heap is exclusively a secure heap.
    if(usage & GRALLOC_USAGE_PRIVATE_MM_HEAP) {
        if(usage & GRALLOC_USAGE_PROTECTED) {
            ionFlags |= ION_HEAP(ION_CP_MM_HEAP_ID);
            ionFlags |= ION_SECURE;
        }
        else {
      
            ionFlags |= ION_HEAP(ION_IOMMU_HEAP_ID);
        }
    }

    if(usage & GRALLOC_USAGE_PRIVATE_CAMERA_HEAP)
        ionFlags |= ION_HEAP(ION_CAMERA_HEAP_ID);

    if(usage & GRALLOC_USAGE_PROTECTED)
         data.allocType |= private_handle_t::PRIV_FLAGS_SECURE_BUFFER;

    if(!ionFlags)
        ionFlags = ION_HEAP(ION_SF_HEAP_ID) | ION_HEAP(ION_IOMMU_HEAP_ID);

    data.flags = ionFlags;
    ret = mIonAlloc->alloc_buffer(data);

    // Fallback
    if(ret < 0 && canFallback(usage,
                              (ionFlags & ION_SYSTEM_HEAP_ID)))
    {
        ALOGW("Falling back to system heap");
        data.flags = ION_HEAP(ION_SYSTEM_HEAP_ID);
        ret = mIonAlloc->alloc_buffer(data);
    }

    if(ret >= 0 ) {
        data.allocType |= private_handle_t::PRIV_FLAGS_USES_ION;
    }

    return ret;
}
```


##### IonAlloc alloc_buffer
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[ionalloc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/ionalloc.cpp)


```cpp
#define ION_DEVICE "/dev/ion"

int IonAlloc::alloc_buffer(alloc_data& data)
{
    Locker::Autolock _l(mLock);
    int err = 0;
    struct ion_handle_data handle_data;
    struct ion_fd_data fd_data;
    struct ion_allocation_data ionAllocData;
    void *base = 0;

    ionAllocData.len = data.size;
    ionAllocData.align = data.align;
    ionAllocData.heap_id_mask = data.flags & ~ION_SECURE;
    ionAllocData.flags = data.uncached ? 0 : ION_FLAG_CACHED;

    if (data.flags & ION_SECURE)
        ionAllocData.flags |= ION_SECURE;

    err = open_device();
    if (err)
        return err;
    if(ioctl(mIonFd, ION_IOC_ALLOC, &ionAllocData)) {
        err = -errno;
        return err;
    }

    fd_data.handle = ionAllocData.handle;
    handle_data.handle = ionAllocData.handle;
    if(ioctl(mIonFd, ION_IOC_MAP, &fd_data)) {
        err = -errno;
        ioctl(mIonFd, ION_IOC_FREE, &handle_data);
        return err;
    }

    if(!(data.flags & ION_SECURE)) {
        base = mmap(0, ionAllocData.len, PROT_READ|PROT_WRITE,
                    MAP_SHARED, fd_data.fd, 0);
        if(base == MAP_FAILED) {
            err = -errno;
            ioctl(mIonFd, ION_IOC_FREE, &handle_data);
            return err;
        }
        memset(base, 0, ionAllocData.len);
        // Clean cache after memset
        clean_buffer(base, data.size, data.offset, fd_data.fd,
                     CACHE_CLEAN_AND_INVALIDATE);
    }

    data.base = base;
    data.fd = fd_data.fd;
    ioctl(mIonFd, ION_IOC_FREE, &handle_data);
    return 0;
}

```
IonController通过format预计完需要申请的图元内存大小，就调用IonAlloc的allocate。在这个方法中做的事情核心有三件：
- 1.打开/dev/ion 驱动，在驱动中创建一个ion_client对象
- 2.调用ioctl 传入ION_IOC_ALLOC ，在底层创建一个ion_buffer区域，并和ion_handle_data绑定。
- 3.ioctl 传入ION_IOC_MAP 进行ion_allocation_data的内存和里面fd文件句柄进行绑定，也即是有了一个匿名文件。
- 4.如果不是安全模式，mmap 映射一段共享的地址在base中，并且让虚拟内存和ion管理的page绑定。

### GraphicBufferMapper importBuffer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[ui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/)/[GraphicBufferMapper.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/ui/GraphicBufferMapper.cpp)

```cpp
status_t GraphicBufferMapper::importBuffer(buffer_handle_t rawHandle,
        uint32_t width, uint32_t height, uint32_t layerCount,
        PixelFormat format, uint64_t usage, uint32_t stride,
        buffer_handle_t* outHandle)
{
    ATRACE_CALL();

    buffer_handle_t bufferHandle;
    Gralloc2::Error error = mMapper->importBuffer(
            hardware::hidl_handle(rawHandle), &bufferHandle);
....
    Gralloc2::IMapper::BufferDescriptorInfo info = {};
    info.width = width;
    info.height = height;
    info.layerCount = layerCount;
    info.format = static_cast<Gralloc2::PixelFormat>(format);
    info.usage = usage;

    error = mMapper->validateBufferSize(bufferHandle, info, stride);
...
    *outHandle = bufferHandle;

    return NO_ERROR;
}
```

能上面的allocate方法只能此时的句柄是hidl_handle，而hidl_handle成为rawHandle，这个句柄还不能使用。需要经过importBuffer经过转化才能使用。最后需要校验buffer的大小

#### MapperImpl importBuffer
```cpp
  Return<void> importBuffer(const hidl_handle& rawHandle,
                              IMapper::importBuffer_cb hidl_cb) override {
...

        native_handle_t* bufferHandle = nullptr;
        Error error = mHal->importBuffer(rawHandle.getNativeHandle(), &bufferHandle);
        if (error != Error::NONE) {
            hidl_cb(error, nullptr);
            return Void();
        }

        void* buffer = addImportedBuffer(bufferHandle);
        if (!buffer) {
            mHal->freeBuffer(bufferHandle);
            hidl_cb(Error::NO_RESOURCES, nullptr);
            return Void();
        }

        hidl_cb(error, buffer);
        return Void();
    }
```
在MapperImpl中，把importBuffer分成2步骤。

- 1.Gralloc0HalImpl importBuffer
- 2.import 处理完Buffer后，addImportedBuffer把每一个Handle都添加到GrallocImportedBufferPool一个缓存池中，缓存起来。

#### Gralloc0HalImpl importBuffer
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[mapper](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/)/[mapper-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/2.0/)/[Gralloc0Hal.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/passthrough/include/mapper-passthrough/2.0/Gralloc0Hal.h)

```cpp
    Error importBuffer(const native_handle_t* rawHandle,
                       native_handle_t** outBufferHandle) override {
        native_handle_t* bufferHandle = native_handle_clone(rawHandle);
...
        if (mModule->registerBuffer(mModule, bufferHandle)) {
...
            return Error::BAD_BUFFER;
        }

        *outBufferHandle = bufferHandle;

        return Error::NONE;
    }
```
此时importBuffer对应的方法就是registerBuffer。在mMapper中，是直接操作hw_module_t。

##### hw_module_t 
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libgralloc](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/)/[mapper.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libgralloc/mapper.cpp)

```cpp
int gralloc_register_buffer(gralloc_module_t const* module,
                            buffer_handle_t handle)
{
...
    private_handle_t* hnd = (private_handle_t*)handle;
    hnd->base = 0;
    hnd->base_metadata = 0;
    int err = gralloc_map(module, handle);
    if (err) {
        return err;
    }

    return 0;
}
```

此时才会调用gralloc_map，真正进行mmap进行映射。

```cpp
static int gralloc_map(gralloc_module_t const* module,
                       buffer_handle_t handle)
{
    private_handle_t* hnd = (private_handle_t*)handle;
    void *mappedAddress;
    if (!(hnd->flags & private_handle_t::PRIV_FLAGS_FRAMEBUFFER) &&
        !(hnd->flags & private_handle_t::PRIV_FLAGS_SECURE_BUFFER)) {
        size_t size = hnd->size;
        IMemAlloc* memalloc = getAllocator(hnd->flags) ;
        int err = memalloc->map_buffer(&mappedAddress, size,
                                       hnd->offset, hnd->fd);
        if(err || mappedAddress == MAP_FAILED) {
            hnd->base = 0;
            return -errno;
        }

        hnd->base = intptr_t(mappedAddress) + hnd->offset;
        mappedAddress = MAP_FAILED;
        size = ROUND_UP_PAGESIZE(sizeof(MetaData_t));
        err = memalloc->map_buffer(&mappedAddress, size,
                                       hnd->offset_metadata, hnd->fd_metadata);
        if(err || mappedAddress == MAP_FAILED) {
            hnd->base_metadata = 0;
            return -errno;
        }
        hnd->base_metadata = intptr_t(mappedAddress) + hnd->offset_metadata;
    }
    return 0;
}
```
此时会调用ionalloc的map_buffer，为hnd的mappedAddress进行映射。映射了2段内存。一段是从mappedAddress到hnd->offset的，另一段是重新申请的mappedAddress到offset_metadata。记住这两个base。换句话说，只有此时才给handle中的base赋值共享内存的地址。


### GraphicBufferMapper lock
类似的流程，我们直接看核心方法：
```cpp
int gralloc_lock(gralloc_module_t const* module,
                 buffer_handle_t handle, int usage,
                 int l, int t, int w, int h,
                 void** vaddr)
{
    private_handle_t* hnd = (private_handle_t*)handle;
    int err = gralloc_map_and_invalidate(module, handle, usage, l, t, w, h);
    if(!err)
        *vaddr = (void*)hnd->base;
    return err;
}
```
```cpp
static int gralloc_map_and_invalidate (gralloc_module_t const* module,
                                       buffer_handle_t handle, int usage,
                                       int l, int t, int w, int h)
{
    if (private_handle_t::validate(handle) < 0)
        return -EINVAL;

    int err = 0;
    private_handle_t* hnd = (private_handle_t*)handle;
    if (usage & (GRALLOC_USAGE_SW_READ_MASK | GRALLOC_USAGE_SW_WRITE_MASK)) {
        if (hnd->base == 0) {
            // we need to map for real
            pthread_mutex_t* const lock = &sMapLock;
            pthread_mutex_lock(lock);
            err = gralloc_map(module, handle);
            pthread_mutex_unlock(lock);
        }
        IMemAlloc* memalloc = getAllocator(hnd->flags) ;
        err = memalloc->clean_buffer((void*)hnd->base,
                                     hnd->size, hnd->offset, hnd->fd,
                                     CACHE_INVALIDATE);
        if ((usage & GRALLOC_USAGE_SW_WRITE_MASK) &&
            !(hnd->flags & private_handle_t::PRIV_FLAGS_FRAMEBUFFER)) {
            hnd->flags |= private_handle_t::PRIV_FLAGS_NEEDS_FLUSH;
        }
    } else {
        hnd->flags |= private_handle_t::PRIV_FLAGS_DO_NOT_FLUSH;
    }
    return err;
}
```
能看到此时lock核心的思想，调用gralloc_map_and_invalidate，检测private_handle_t中的base的字段有没有进行映射过，没有就进行一次映射。接着就初始化这一段内存的资源，最后让句柄中hnd->base共享地址的资源赋值给addr，这个地址是什么？其实就是ANativeWindowBuffer中的bits字段。这样private_handle_t中的base就和ANativeWindowBuffer的bits关联起来。

此时才能正常的操作整个图元。

### GraphicBuffer 的跨进程通信

前文说过GraphicBuffer的数据太大了，没有办法进行Binder通信，那么他为什么可以办到binder返回呢？我们先去图元生产者的基类IGraphicBufferProducer 的远程端：
```cpp
class BpGraphicBufferProducer : public BpInterface<IGraphicBufferProducer>
{
public:
    explicit BpGraphicBufferProducer(const sp<IBinder>& impl)
        : BpInterface<IGraphicBufferProducer>(impl)
    {
    }

    ~BpGraphicBufferProducer() override;

    virtual status_t requestBuffer(int bufferIdx, sp<GraphicBuffer>* buf) {
        Parcel data, reply;
        data.writeInterfaceToken(IGraphicBufferProducer::getInterfaceDescriptor());
        data.writeInt32(bufferIdx);
        status_t result =remote()->transact(REQUEST_BUFFER, data, &reply);
        if (result != NO_ERROR) {
            return result;
        }
        bool nonNull = reply.readInt32();
        if (nonNull) {
            *buf = new GraphicBuffer();
            result = reply.read(**buf);
            if(result != NO_ERROR) {
                (*buf).clear();
                return result;
            }
        }
        result = reply.readInt32();
        return result;
    }
```
其实就在App进程中new了一个GraphicBuffer对象，但是这个对象展示不会去ion申请内存。而是调用了read的方法，继续解压缩reply返回的数据包。因为GraphicBuffer是一个Flatten对象，因此会走到GraphicBuffer的unflatten方法。
```cpp
status_t GraphicBuffer::unflatten(
        void const*& buffer, size_t& size, int const*& fds, size_t& count) {

    int const* buf = static_cast<int const*>(buffer);
...
        native_handle* h = native_handle_create(
                static_cast<int>(numFds), static_cast<int>(numInts));
...
        memcpy(h->data, fds, numFds * sizeof(int));
        memcpy(h->data + numFds, buf + flattenWordCount, numInts * sizeof(int));
        handle = h;
    } else {
...
    }

    mId = static_cast<uint64_t>(buf[7]) << 32;
    mId |= static_cast<uint32_t>(buf[8]);

    mGenerationNumber = static_cast<uint32_t>(buf[9]);

    mOwner = ownHandle;

    if (handle != 0) {
        buffer_handle_t importedHandle;
        status_t err = mBufferMapper.importBuffer(handle, uint32_t(width), uint32_t(height),
                uint32_t(layerCount), format, usage, uint32_t(stride), &importedHandle);
...

        native_handle_close(handle);
        native_handle_delete(const_cast<native_handle_t*>(handle));
        handle = importedHandle;
        mBufferMapper.getTransportSize(handle, &mTransportNumFds, &mTransportNumInts);
    }

    buffer = static_cast<void const*>(static_cast<uint8_t const*>(buffer) + sizeNeeded);
    size -= sizeNeeded;
    fds += numFds;
    count -= numFds;

    return NO_ERROR;
}
```
此时就把整个handle拷贝过来了，接着调用importBuffer，把handle转化从hidl_handle转化为可用的private_handle_t。记住此时一般是deqeue方法中调用，此时还没有lock，因此还没有和底层共享内存关联。

但是最重要的SF进程和App进程之间同一个handle的GraphicBuffer没有进行关联，我们来看看MapperImpl的lock方法：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[mapper](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/)/[mapper-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/)/[2.0](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/2.0/)/[Mapper.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/mapper/2.0/utils/hal/include/mapper-hal/2.0/Mapper.h)
```cpp
    Return<void> lock(void* buffer, uint64_t cpuUsage, const V2_0::IMapper::Rect& accessRegion,
                      const hidl_handle& acquireFence, IMapper::lock_cb hidl_cb) override {
        const native_handle_t* bufferHandle = getImportedBuffer(buffer);
        if (!bufferHandle) {
            hidl_cb(Error::BAD_BUFFER, nullptr);
            return Void();
        }

        base::unique_fd fenceFd;
        Error error = getFenceFd(acquireFence, &fenceFd);
        if (error != Error::NONE) {
            hidl_cb(error, nullptr);
            return Void();
        }

        void* data = nullptr;
        error = mHal->lock(bufferHandle, cpuUsage, accessRegion, std::move(fenceFd), &data);
        hidl_cb(error, data);
        return Void();
    }
```
在进行mmap共享内存绑定之前，会通过getImportedBuffer查找已经在GrallocImportedBufferPool缓存下来的图元数据的句柄native_handle_t，这样App进程就找到了对应SF进程中GraphicBuffer的共享内存。





## 总结
老规矩一幅图总结：
![GraphicBuffer诞生到可使用.png](/images/GraphicBuffer诞生到可使用.png)


一般来说：图元的绘制分为如下几个步骤：
- 1.dequeueBuffer 获取一个图元的插槽位置，或者生产一个图元。其实在IGrraphicBufferProducer通过flattern进行一次句柄GraphicBuffer拷贝，依次为依据找到底层的共享内存。
- 2.lock 绑定图元共享内存地址，最后通过句柄在GrallocImportedBufferPool中找到在SF进程申请好的内存地址
- 3.queueBuffer 把图元放入mActiveBuffer中，并且从新计算dequeue和acquire的数量，同时把GrapicBuffer放到mQueue进行消费，最后调用frameAvilable回调通知消费者。
- 4.unlock 解锁图元 揭开共享内存的映射。

到这里面涉及到了几个fd的转化，先不用太关注，知道是通过ion申请一段共享内存，通过fd的方式告诉App进程可以映射到同一段物理内存。


到这里，我们就能看到了整个gralloc的服务，在申请内存时候，会把主要的工作交给内核驱动ion。这个驱动究竟是怎么回事呢？在Android 4.4的时候还是在ashmem，申请共享内存，那么ion是怎么设计的，下一篇将会为你揭晓。



































