---
title: Android重学系列 IMS与事件分发(下)
top: false
cover: false
date: 2020-07-26 17:51:08
img:
tag:
description:
author: yjy239
summary:
categories: IMS
tags:
- Android
- Android Framework
---

# 前言
上一篇文章和大家聊到了IMS在SystemServer进程native层中的原理，本文来聊聊App进程是怎么监听IMS分发出来的输入信号的.

# 正文
还记得我写过WMS系列文章[WMS在Activity启动中的职责 添加窗体(三)](https://www.jianshu.com/p/157e8bbfa45a)中，提到了App第一次渲染的时候会通过ViewRootImpl的addWindow方法，在WMS中为当前的Activity中的PhoneWindow添加一个对应的WindowState进行管理。

让我们先看看ViewRootImpl中做了什么。

## ViewRootImpl setView
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ViewRootImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ViewRootImpl.java)

```cpp
    public void setView(View view, WindowManager.LayoutParams attrs, View panelParentView) {
        synchronized (this) {
            if (mView == null) {
                mView = view;

....

                requestLayout();
                if ((mWindowAttributes.inputFeatures
                        & WindowManager.LayoutParams.INPUT_FEATURE_NO_INPUT_CHANNEL) == 0) {
//核心事件一
                    mInputChannel = new InputChannel();
                }
                mForceDecorViewVisibility = (mWindowAttributes.privateFlags
                        & PRIVATE_FLAG_FORCE_DECOR_VIEW_VISIBILITY) != 0;
                try {
//核心事件二
                    res = mWindowSession.addToDisplay(mWindow, mSeq, mWindowAttributes,
                            getHostVisibility(), mDisplay.getDisplayId(), mWinFrame,
                            mAttachInfo.mContentInsets, mAttachInfo.mStableInsets,
                            mAttachInfo.mOutsets, mAttachInfo.mDisplayCutout, mInputChannel);
                } catch (RemoteException e) {
...
                } finally {
...
                }

...
//核心事件三
                if (mInputChannel != null) {
                    if (mInputQueueCallback != null) {
                        mInputQueue = new InputQueue();
                        mInputQueueCallback.onInputQueueCreated(mInputQueue);
                    }
                    mInputEventReceiver = new WindowInputEventReceiver(mInputChannel,
                            Looper.myLooper());
                }

...
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
            }
        }
    }
```
在这个过程中，我们可以把它视作三大部分的逻辑
- 1.没有为当前的ViewRootImpl初始化InputChannel，则会先创建一个InputChannel。

- 2.接着把InputChannel对象通过Session的addToDisplay，也就是addWindow发送到WMS中进行处理。详细的逻辑请看[WMS在Activity启动中的职责 添加窗体(三)](https://www.jianshu.com/p/157e8bbfa45a)。

- 3.最后为ViewRootImpl构建接受从InputChannel发送回来的输入事件环境。

核心就是第二和第三点。先来看看第二点，Session的addToDisplay最后是调用到了WMS的addWindow中。

### WMS addWindow
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[WindowManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/WindowManagerService.java)

```cpp
    public int addWindow(Session session, IWindow client, int seq,
            LayoutParams attrs, int viewVisibility, int displayId, Rect outFrame,
            Rect outContentInsets, Rect outStableInsets, Rect outOutsets,
            DisplayCutout.ParcelableWrapper outDisplayCutout, InputChannel outInputChannel) {
...
        synchronized(mWindowMap) {

...

            final WindowState win = new WindowState(this, session, client, token, parentWindow,
                    appOp[0], seq, attrs, viewVisibility, session.mUid,
                    session.mCanAddInternalSystemWindow);

...

            final boolean openInputChannels = (outInputChannel != null
                    && (attrs.inputFeatures & INPUT_FEATURE_NO_INPUT_CHANNEL) == 0);
            if  (openInputChannels) {
                win.openInputChannel(outInputChannel);
            }

...
            mInputMonitor.setUpdateInputWindowsNeededLw();

            boolean focusChanged = false;
            if (win.canReceiveKeys()) {
                focusChanged = updateFocusedWindowLocked(UPDATE_FOCUS_WILL_ASSIGN_LAYERS,
                        false /*updateInputWindows*/);
                if (focusChanged) {
                    imMayMove = false;
                }
            }


            if (focusChanged) {
                mInputMonitor.setInputFocusLw(mCurrentFocus, false /*updateInputWindows*/);
            }
            mInputMonitor.updateInputWindowsLw(false /*force*/);


        }
...

        return res;
    }

```
我们把InputChannel相关的逻辑抽离出来：
- 1.首先如果当前的Window对应IWindow没有对应在WMS的mWindowMap，则会创建一个全新的WindowState对应上。并且调用WindowState的openInputChannel初始化从ViewRootImpl传过来的InputChannel

- 2.使用InputMonitor更新当前的焦点窗口。

我们来看看WindowState的openInputChannel方法。

#### WindowState
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[WindowState.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/WindowState.java)
```cpp
    WindowState(WindowManagerService service, Session s, IWindow c, WindowToken token,
            WindowState parentWindow, int appOp, int seq, WindowManager.LayoutParams a,
            int viewVisibility, int ownerId, boolean ownerCanAddInternalSystemWindow,
            PowerManagerWrapper powerManagerWrapper) {
        super(service);
....
        mInputWindowHandle = new InputWindowHandle(
                mAppToken != null ? mAppToken.mInputApplicationHandle : null, this, c,
                    getDisplayId());
    }
```
能看到实际上这个过程诞生了一个很重要的对象InputWindowHandle，输入窗口的句柄。这个句柄最核心的对象就是通过WindowToken获取AppToken的InputApplicationHandle。


#### WindowState openInputChannel

```cpp

    void openInputChannel(InputChannel outInputChannel) {

        String name = getName();
        InputChannel[] inputChannels = InputChannel.openInputChannelPair(name);
        mInputChannel = inputChannels[0];
        mClientChannel = inputChannels[1];
        mInputWindowHandle.inputChannel = inputChannels[0];
        if (outInputChannel != null) {
            mClientChannel.transferTo(outInputChannel);
            mClientChannel.dispose();
            mClientChannel = null;
        } else {
            mDeadWindowEventReceiver = new DeadWindowEventReceiver(mClientChannel);
        }
        mService.mInputManager.registerInputChannel(mInputChannel, mInputWindowHandle);
    }
```
能看到这个过程，实际上和上一篇文章十分相似的monitorInput一节中的内容十分相似。

依次执行了如下的逻辑：
- 1.openInputChannelPair 为Java层的InputChannel在native创建一对InputChannel。
- 2.mInputWindowHandle 持有InputChannel对的0号对应的InputChannel
- 3.把1号位置中的NativeInputChannel赋值给ViewRootImpl传递过来的InputChannel。并关闭InputChannel对的1号位置对应的InputChannel。
- 4.把0号位置的InputChannel注册到IMS底层中，监听输入时间的到来。

这样通过socketpair创建的一对socket对象，注册了一个新的发送端到IMS的native层中，就能被App端的InputChannel监听到。

从这里就可以知道，0号位置的InputChannel对应的socket就是服务端(发送端)。关于如何创建InputChannel，以及如何注册到IMS。这里就不多赘述，请阅读[IMS与事件分发(上)](https://www.jianshu.com/p/c53e313cd4a9)。


### ViewRootImpl 构建输入事件的监听环境
```java
                if (mInputChannel != null) {
...
                    mInputEventReceiver = new WindowInputEventReceiver(mInputChannel,
                            Looper.myLooper());
                }

...
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
```
- 1.在ViewRootImpl中构建一个WindowInputEventReceiver对象，这个对象将会监听从IMS传送过来的输入事件。
- 2.构建InputStage对象，该系列对象实际上就是当IMS从native传递上来后，进行处理的输入事件"舞台".

### WindowInputEventReceiver ViewRootImpl对输入事件的监听原理
```cpp
    final class WindowInputEventReceiver extends InputEventReceiver {
        public WindowInputEventReceiver(InputChannel inputChannel, Looper looper) {
            super(inputChannel, looper);
        }

        @Override
        public void onInputEvent(InputEvent event, int displayId) {
            enqueueInputEvent(event, this, 0, true);
        }

        @Override
        public void onBatchedInputEventPending() {
            if (mUnbufferedInputDispatch) {
                super.onBatchedInputEventPending();
            } else {
                scheduleConsumeBatchedInput();
            }
        }

        @Override
        public void dispose() {
            unscheduleConsumeBatchedInput();
            super.dispose();
        }
    }
```
这个对象很简单，他继承于InputEventReceiver。InputEventReceiver对象就是专门监听IMS输入事件的基类。每当IMS发送信号来了就会调用子类的onInputEvent方法，onBatchedInputEventPending。

我们先来看看InputEventReceiver的初始化。

#### InputEventReceiver
```cpp
    public InputEventReceiver(InputChannel inputChannel, Looper looper) {
...
        mInputChannel = inputChannel;
        mMessageQueue = looper.getQueue();
        mReceiverPtr = nativeInit(new WeakReference<InputEventReceiver>(this),
                inputChannel, mMessageQueue);

        mCloseGuard.open("dispose");
    }
```
核心实际上就是调用native方法在native层初始化了IMS事件监听器。


#### InputEventReceiver native层初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_InputEventReceiver.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_InputEventReceiver.cpp)
```cpp
static jlong nativeInit(JNIEnv* env, jclass clazz, jobject receiverWeak,
        jobject inputChannelObj, jobject messageQueueObj) {
    sp<InputChannel> inputChannel = android_view_InputChannel_getInputChannel(env,
            inputChannelObj);
...
    sp<MessageQueue> messageQueue = android_os_MessageQueue_getMessageQueue(env, messageQueueObj);
...
    sp<NativeInputEventReceiver> receiver = new NativeInputEventReceiver(env,
            receiverWeak, inputChannel, messageQueue);
    status_t status = receiver->initialize();
...
    receiver->incStrong(gInputEventReceiverClassInfo.clazz); // retain a reference for the object
    return reinterpret_cast<jlong>(receiver.get());
}
```
这里只是简单的生成一个NativeInputEventReceiver对象，并调用了NativeInputEventReceiver的initialize方法。为全局的clazz对象新增一个强引用计数。


#### NativeInputEventReceiver
```cpp
class NativeInputEventReceiver : public LooperCallback {
public:
    NativeInputEventReceiver(JNIEnv* env,
            jobject receiverWeak, const sp<InputChannel>& inputChannel,
            const sp<MessageQueue>& messageQueue);

    status_t initialize();
    void dispose();
    status_t finishInputEvent(uint32_t seq, bool handled);
    status_t consumeEvents(JNIEnv* env, bool consumeBatches, nsecs_t frameTime,
            bool* outConsumedBatch);

protected:
    virtual ~NativeInputEventReceiver();

private:
    struct Finish {
        uint32_t seq;
        bool handled;
    };

    jobject mReceiverWeakGlobal;
    InputConsumer mInputConsumer;
    sp<MessageQueue> mMessageQueue;
    PreallocatedInputEventFactory mInputEventFactory;
    bool mBatchedInputEventPending;
    int mFdEvents;
    Vector<Finish> mFinishQueue;
    void setFdEvents(int events);

    const std::string getInputChannelName() {
        return mInputConsumer.getChannel()->getName();
    }

    virtual int handleEvent(int receiveFd, int events, void* data);
};
```
从NativeInputEventReceiver的申明能看到实际上他是实现了LooperCallback。LooperCallback这个对象，可以阅读[Handler与相关系统调用的剖析(上)](https://www.jianshu.com/p/416de2a3a1d6)，里面有讲解到LooperCallback实际上就是native层Looper回调后的监听对象，回调的方法就是虚函数handleEvent。

在NativeInputEventReceiver有一个十分重要的对象InputConsumer。当IMS回调了输入事件后，NativeInputEventReceiver使用InputConsumer在native层中进行处理。

构造函数没什么好看的，直接看看initialize初始化的方法。

#### NativeInputEventReceiver initialize
```cpp
status_t NativeInputEventReceiver::initialize() {
    setFdEvents(ALOOPER_EVENT_INPUT);
    return OK;
}

void NativeInputEventReceiver::setFdEvents(int events) {
    if (mFdEvents != events) {
        mFdEvents = events;
        int fd = mInputConsumer.getChannel()->getFd();
        if (events) {
            mMessageQueue->getLooper()->addFd(fd, 0, events, this, NULL);
        } else {
            mMessageQueue->getLooper()->removeFd(fd);
        }
    }
}
```
能看到这里面实际上很简单，就是获取InputConsumer中的InputChannel中的fd，这里fd就是上面初始化好的接收端的InputChannel。因此就是获取主线程的Looper并使用Looper监听客户端的InputChannel。

一旦IMS有信号发送过来则立即回调LooperCallback中的handleEvent。


当输入信号从native层传送过来了，则会开始回调handleEvent方法。关于IMS如果读取输入事件，处理后传输过来，可以阅读我写的[IMS与事件分发(上)](https://www.jianshu.com/p/c53e313cd4a9)。

#### handleEvent App进程处理输入事件
```cpp
int NativeInputEventReceiver::handleEvent(int receiveFd, int events, void* data) {
    if (events & (ALOOPER_EVENT_ERROR | ALOOPER_EVENT_HANGUP)) {
        return 0; // remove the callback
    }

    if (events & ALOOPER_EVENT_INPUT) {
        JNIEnv* env = AndroidRuntime::getJNIEnv();
        status_t status = consumeEvents(env, false /*consumeBatches*/, -1, NULL);
        mMessageQueue->raiseAndClearException(env, "handleReceiveCallback");
        return status == OK || status == NO_MEMORY ? 1 : 0;
    }

    if (events & ALOOPER_EVENT_OUTPUT) {
        for (size_t i = 0; i < mFinishQueue.size(); i++) {
            const Finish& finish = mFinishQueue.itemAt(i);
            status_t status = mInputConsumer.sendFinishedSignal(finish.seq, finish.handled);
            if (status) {
                mFinishQueue.removeItemsAt(0, i);

                if (status == WOULD_BLOCK) {
                    return 1; // keep the callback, try again later
                }

...
                return 0; // remove the callback
            }
        }

        mFinishQueue.clear();
        setFdEvents(ALOOPER_EVENT_INPUT);
        return 1;
    }

    return 1;
}
``` 
大致上可以分为两种情况，分别对象Looper注册的事件类型ALOOPER_EVENT_INPUT和ALOOPER_EVENT_OUTPUT。

很多地方没解析清楚：
- ALOOPER_EVENT_INPUT 是指那些可读的文件描述符传递过来的事件
- ALOOPER_EVENT_OUTPUT 是指那些可写的文件描述符，需要传递过去的事件。

在NativeInputEventReceiver中，ALOOPER_EVENT_INPUT代表从驱动读取到的输入事件传递过来；ALOOPER_EVENT_OUTPUT代表此时需要关闭输入事件的监听，而传递过去的后返回的事件处理。

我们先来看看ALOOPER_EVENT_INPUT对应的事件处理。
```cpp
    if (events & ALOOPER_EVENT_INPUT) {
        JNIEnv* env = AndroidRuntime::getJNIEnv();
        status_t status = consumeEvents(env, false /*consumeBatches*/, -1, NULL);
        mMessageQueue->raiseAndClearException(env, "handleReceiveCallback");
        return status == OK || status == NO_MEMORY ? 1 : 0;
    }
```

核心处理方法是consumeEvents。

#### consumeEvents
```cpp

status_t NativeInputEventReceiver::consumeEvents(JNIEnv* env,
        bool consumeBatches, nsecs_t frameTime, bool* outConsumedBatch) {

    if (consumeBatches) {
        mBatchedInputEventPending = false;
    }
    if (outConsumedBatch) {
        *outConsumedBatch = false;
    }

    ScopedLocalRef<jobject> receiverObj(env, NULL);
    bool skipCallbacks = false;
    for (;;) {
        uint32_t seq;
        InputEvent* inputEvent;
        int32_t displayId;
        status_t status = mInputConsumer.consume(&mInputEventFactory,
                consumeBatches, frameTime, &seq, &inputEvent, &displayId);
        if (status) {
            if (status == WOULD_BLOCK) {
                if (!skipCallbacks && !mBatchedInputEventPending
                        && mInputConsumer.hasPendingBatch()) {

                    mBatchedInputEventPending = true;

                    env->CallVoidMethod(receiverObj.get(),
                            gInputEventReceiverClassInfo.dispatchBatchedInputEventPending);

                }
                return OK;
            }

            return status;
        }
...
        if (!skipCallbacks) {
....
            jobject inputEventObj;
            switch (inputEvent->getType()) {
            case AINPUT_EVENT_TYPE_KEY:

                inputEventObj = android_view_KeyEvent_fromNative(env,
                        static_cast<KeyEvent*>(inputEvent));
                break;

            case AINPUT_EVENT_TYPE_MOTION: {

                MotionEvent* motionEvent = static_cast<MotionEvent*>(inputEvent);
                if ((motionEvent->getAction() & AMOTION_EVENT_ACTION_MOVE) && outConsumedBatch) {
                    *outConsumedBatch = true;
                }
                inputEventObj = android_view_MotionEvent_obtainAsCopy(env, motionEvent);
                break;
            }

            default:
                inputEventObj = NULL;
            }

            if (inputEventObj) {
//发送核心
                env->CallVoidMethod(receiverObj.get(),
                        gInputEventReceiverClassInfo.dispatchInputEvent, seq, inputEventObj,
                        displayId);
                if (env->ExceptionCheck()) {
                    
                    skipCallbacks = true;
                }
                env->DeleteLocalRef(inputEventObj);
            } else {
                skipCallbacks = true;
            }
        }

        if (skipCallbacks) {
            mInputConsumer.sendFinishedSignal(seq, false);
        }
    }
}
```
- 1.通过InputConsumer的consume方法消费它持有的InputChannel的输入事件。

- 3.如果是Monition类型事件且是多点触控需要批量处理的，则会通过CallVoidMethod反射调用InputEventReceiver的dispatchBatchedInputEventPending方法。

- 2.根据Key 还是Monition生成对应的Java对象，通过CallVoidMethod反射调用Java方法，InputEventReceiver的dispatchInputEvent方法。


##### InputConsumer consume
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[input](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/input/)/[InputTransport.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/input/InputTransport.cpp)
```cpp
status_t InputConsumer::consume(InputEventFactoryInterface* factory,
        bool consumeBatches, nsecs_t frameTime, uint32_t* outSeq, InputEvent** outEvent,
        int32_t* displayId) {

    *outSeq = 0;
    *outEvent = NULL;
    *displayId = -1;  // Invalid display.


    while (!*outEvent) {
        if (mMsgDeferred) {

            mMsgDeferred = false;
        } else {

            status_t result = mChannel->receiveMessage(&mMsg);
            if (result) {

                if (consumeBatches || result != WOULD_BLOCK) {
                    result = consumeBatch(factory, frameTime, outSeq, outEvent, displayId);
                    if (*outEvent) {

                        break;
                    }
                }
                return result;
            }
        }

        switch (mMsg.header.type) {
        case InputMessage::TYPE_KEY: {
            KeyEvent* keyEvent = factory->createKeyEvent();
            if (!keyEvent) return NO_MEMORY;

            initializeKeyEvent(keyEvent, &mMsg);
            *outSeq = mMsg.body.key.seq;
            *outEvent = keyEvent;

            break;
        }

        case InputMessage::TYPE_MOTION: {
            ssize_t batchIndex = findBatch(mMsg.body.motion.deviceId, mMsg.body.motion.source);
            if (batchIndex >= 0) {
                Batch& batch = mBatches.editItemAt(batchIndex);
                if (canAddSample(batch, &mMsg)) {
                    batch.samples.push(mMsg);

                    break;
                } else {

                    mMsgDeferred = true;
                    status_t result = consumeSamples(factory,
                            batch, batch.samples.size(), outSeq, outEvent, displayId);
                    mBatches.removeAt(batchIndex);
                    if (result) {
                        return result;
                    }

                    break;
                }
            }

            // Start a new batch if needed.
            if (mMsg.body.motion.action == AMOTION_EVENT_ACTION_MOVE
                    || mMsg.body.motion.action == AMOTION_EVENT_ACTION_HOVER_MOVE) {
                mBatches.push();
                Batch& batch = mBatches.editTop();
                batch.samples.push(mMsg);

                break;
            }

            MotionEvent* motionEvent = factory->createMotionEvent();
            if (! motionEvent) return NO_MEMORY;

            updateTouchState(mMsg);
            initializeMotionEvent(motionEvent, &mMsg);
            *outSeq = mMsg.body.motion.seq;
            *outEvent = motionEvent;
            *displayId = mMsg.body.motion.displayId;
            break;
        }

        default:
            return UNKNOWN_ERROR;
        }
    }
    return OK;
}
```
先从InputChannel的recv系统调用获取socket里面的InputMessage数据。

虽然此时consumeBatches为false，但是result正常情况下不会是WOULD_BLOCK,会先执行consumeBatch批量处理触点事件。

在这个方法中分为两个类型处理：
- 1.InputMessage::TYPE_KEY 是key按键类型，则通过上面传下来的factory构建一个KeyEvent对象，初始化后并且返回。

- 2.InputMessage::TYPE_MOTION 是触点类型。由于触点类型可以是多点触碰，对于移动的触点，需要进行触点的跟踪，因此这里引入了Batch概念，按照批次处理触点事件。

```cpp
    struct Batch {
        Vector<InputMessage> samples;
    };
```
能看到实际上Batch就是一个InputMessage的集合。每当检测到AMOTION_EVENT_ACTION_MOVE或者AMOTION_EVENT_ACTION_HOVER_MOVE的触点类型，则会添加到mBatches集合中，等待下一次的更新。


当下一次触点触发了回调，在这个outEvent链表不为空的循环前提下，canAddSample判断到当前PointerCount和之前的一致，会把InputMessage不断的添加到Batch的samples集合中。如果出现了不一致则需要consumeSamples进行更新Batch中记录的InputMessage。

这样就能跟踪到了这一批次的触点的轨迹，以及新增的触点。

如果只有单个触点则生成MotionEvent对象赋值给指针返回。


我们来看看InputEventReceiver是通过InputConsumer消费后是怎么触发接下来的逻辑。我们只看单点触发的逻辑。

#### InputReceiver 分发输入事件
```cpp
                env->CallVoidMethod(receiverObj.get(),
                        gInputEventReceiverClassInfo.dispatchInputEvent, seq, inputEventObj,
                        displayId);
```

实际上对应的是：
```cpp
    private void dispatchInputEvent(int seq, InputEvent event, int displayId) {
        mSeqMap.put(event.getSequenceNumber(), seq);
        onInputEvent(event, displayId);
    }
```
而onInputEvent这个方法实际上就是对应WindowInputEventReceiver。
```java
    final class WindowInputEventReceiver extends InputEventReceiver {
        public WindowInputEventReceiver(InputChannel inputChannel, Looper looper) {
            super(inputChannel, looper);
        }

        @Override
        public void onInputEvent(InputEvent event, int displayId) {
            enqueueInputEvent(event, this, 0, true);
        }
```
可以看到最后回调到了enqueueInputEvent方法中。


##### enqueueInputEvent
```java
    void enqueueInputEvent(InputEvent event) {
        enqueueInputEvent(event, null, 0, false);
    }

    void enqueueInputEvent(InputEvent event,
            InputEventReceiver receiver, int flags, boolean processImmediately) {
        adjustInputEventForCompatibility(event);
        QueuedInputEvent q = obtainQueuedInputEvent(event, receiver, flags);

        QueuedInputEvent last = mPendingInputEventTail;
        if (last == null) {
            mPendingInputEventHead = q;
            mPendingInputEventTail = q;
        } else {
            last.mNext = q;
            mPendingInputEventTail = q;
        }
        mPendingInputEventCount += 1;

        if (processImmediately) {
            doProcessInputEvents();
        } else {
            scheduleProcessInputEvents();
        }
    }
```
 能看到整个很久爱都难，就是生成一个obtainQueuedInputEvent对象，添加到mPendingInputEventTail链表的末端，调用scheduleProcessInputEvents方法分发。如果是需要立即响应则调用doProcessInputEvents方法。

##### scheduleProcessInputEvents
```java
    private void scheduleProcessInputEvents() {
        if (!mProcessInputEventsScheduled) {
            mProcessInputEventsScheduled = true;
            Message msg = mHandler.obtainMessage(MSG_PROCESS_INPUT_EVENTS);
            msg.setAsynchronous(true);
            mHandler.sendMessage(msg);
        }
    }
```
能看到此时发送了一个MSG_PROCESS_INPUT_EVENTS一个Asynchronous异步消息。其实就是一个能在同步屏障内优先执行的消息。
```cpp
                case MSG_PROCESS_INPUT_EVENTS:
                    mProcessInputEventsScheduled = false;
                    doProcessInputEvents();
                    break;
```
核心还是调用了doProcessInputEvents。


###### doProcessInputEvents
```java
    void doProcessInputEvents() {
        while (mPendingInputEventHead != null) {
            QueuedInputEvent q = mPendingInputEventHead;
            mPendingInputEventHead = q.mNext;
            if (mPendingInputEventHead == null) {
                mPendingInputEventTail = null;
            }
            q.mNext = null;

            mPendingInputEventCount -= 1;

            long eventTime = q.mEvent.getEventTimeNano();
            long oldestEventTime = eventTime;
            if (q.mEvent instanceof MotionEvent) {
                MotionEvent me = (MotionEvent)q.mEvent;
                if (me.getHistorySize() > 0) {
                    oldestEventTime = me.getHistoricalEventTimeNano(0);
                }
            }
            mChoreographer.mFrameInfo.updateInputEventTime(eventTime, oldestEventTime);

            deliverInputEvent(q);
        }

        if (mProcessInputEventsScheduled) {
            mProcessInputEventsScheduled = false;
            mHandler.removeMessages(MSG_PROCESS_INPUT_EVENTS);
        }
    }
```
Choreographer.mFrameInfo 更新了分发时间后，整个过程最核心的逻辑就是循环遍历mPendingInputEventHead调用deliverInputEvent进行事件的分发QueuedInputEvent。

###### deliverInputEvent
```java
    private void deliverInputEvent(QueuedInputEvent q) {
        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onInputEvent(q.mEvent, 0);
        }

        InputStage stage;
        if (q.shouldSendToSynthesizer()) {
            stage = mSyntheticInputStage;
        } else {
            stage = q.shouldSkipIme() ? mFirstPostImeInputStage : mFirstInputStage;
        }

        if (q.mEvent instanceof KeyEvent) {
            mUnhandledKeyManager.preDispatch((KeyEvent) q.mEvent);
        }

        if (stage != null) {
            handleWindowFocusChanged();
            stage.deliver(q);
        } else {
            finishInputEvent(q);
        }
    }
```
逻辑分为如下几个步骤：
- 1.QueuedInputEvent的shouldSendToSynthesizer判断默认是false，shouldSkipIme也是false。此时InputStage就是mFirstInputStage。这个对象就是NativePreImeInputStage。

- 2.如果获取到的stage不为空，则调用NativePreImeInputStage的deliver方法分发事件。

## ViewRootImpl 构建输入事件的接收环境
```java
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
```
能看到这里面构建很多InputStage对象。这些对象都是通过责任链设计全部嵌套到一起。

我们简单的看看它的UML图，来区分他们的直接的关系：
![InputStage.png](/images/InputStage.png)


#### InputStage 的分发入口
先来看看InputStage的deliver
```java
        public final void deliver(QueuedInputEvent q) {
            if ((q.mFlags & QueuedInputEvent.FLAG_FINISHED) != 0) {
                forward(q);
            } else if (shouldDropInputEvent(q)) {
                finish(q, false);
            } else {
                apply(q, onProcess(q));
            }
        }

        protected void finish(QueuedInputEvent q, boolean handled) {
            q.mFlags |= QueuedInputEvent.FLAG_FINISHED;
            if (handled) {
                q.mFlags |= QueuedInputEvent.FLAG_FINISHED_HANDLED;
            }
            forward(q);
        }


        protected void forward(QueuedInputEvent q) {
            onDeliverToNext(q);
        }

        protected int onProcess(QueuedInputEvent q) {
            return FORWARD;
        }

        protected void onDeliverToNext(QueuedInputEvent q) {
            if (mNext != null) {
                mNext.deliver(q);
            } else {
                finishInputEvent(q);
            }
        }


        protected void apply(QueuedInputEvent q, int result) {
            if (result == FORWARD) {
                forward(q);
            } else if (result == FINISH_HANDLED) {
                finish(q, true);
            } else if (result == FINISH_NOT_HANDLED) {
                finish(q, false);
            } else {
                throw new IllegalArgumentException("Invalid result: " + result);
            }
        }
```
deliver的入口会判断当前QueuedInputEvent的状态。
- 如果判断QueuedInputEvent打开FLAG_FINISHED标志位，换句话说就是不是通过finish方法进来的，就会执行forward的方法。

- 如果判断到当前Window失去焦点，或者还没有进行刷新ui，QueuedInputEvent则执行finish

- 剩下的情况执行apply的默认方法，而执行的方法由每一个InputStage的子类复写onProcess标志位决定的。


我们来看看对整个链路从NativePreImeInputStage开始逆推回去，关键还是看apply中的方法。

在所有的InputStage中分为两类，一类是直接继承InputStage，一类是继承AsyncInputStage，我们优先看看AsyncInputStage。

#### AsyncInputStage
```java
abstract class AsyncInputStage extends InputStage {
        private final String mTraceCounter;

        private QueuedInputEvent mQueueHead;
        private QueuedInputEvent mQueueTail;
        private int mQueueLength;

        protected static final int DEFER = 3;

    ....

        protected void defer(QueuedInputEvent q) {
            q.mFlags |= QueuedInputEvent.FLAG_DEFERRED;
            enqueue(q);
        }

        @Override
        protected void forward(QueuedInputEvent q) {
            q.mFlags &= ~QueuedInputEvent.FLAG_DEFERRED;

            QueuedInputEvent curr = mQueueHead;
            if (curr == null) {
                super.forward(q);
                return;
            }

            final int deviceId = q.mEvent.getDeviceId();
            QueuedInputEvent prev = null;
            boolean blocked = false;
            while (curr != null && curr != q) {
                if (!blocked && deviceId == curr.mEvent.getDeviceId()) {
                    blocked = true;
                }
                prev = curr;
                curr = curr.mNext;
            }

            if (blocked) {
                if (curr == null) {
                    enqueue(q);
                }
                return;
            }

            if (curr != null) {
                curr = curr.mNext;
                dequeue(q, prev);
            }
            super.forward(q);

            while (curr != null) {
                if (deviceId == curr.mEvent.getDeviceId()) {
                    if ((curr.mFlags & QueuedInputEvent.FLAG_DEFERRED) != 0) {
                        break;
                    }
                    QueuedInputEvent next = curr.mNext;
                    dequeue(curr, prev);
                    super.forward(curr);
                    curr = next;
                } else {
                    prev = curr;
                    curr = curr.mNext;
                }
            }
        }

        private void enqueue(QueuedInputEvent q) {
            if (mQueueTail == null) {
                mQueueHead = q;
                mQueueTail = q;
            } else {
                mQueueTail.mNext = q;
                mQueueTail = q;
            }

            mQueueLength += 1;
        }

        private void dequeue(QueuedInputEvent q, QueuedInputEvent prev) {
            if (prev == null) {
                mQueueHead = q.mNext;
            } else {
                prev.mNext = q.mNext;
            }
            if (mQueueTail == q) {
                mQueueTail = prev;
            }
            q.mNext = null;

            mQueueLength -= 1;

        }
}
```
在AsyncInputStage存储了一个QueuedInputEvent链表。当判断到事件打开了FLAG_FINISHED，其在核心方法forward做了如下的事情：
- 当链表中没有任何待分发的事件，直接调用父类的forward方法，也就调用onDeliverNext方法，在onDeliverNext如果当前InputStage不存在下一个InputStage则会调用finishInputEvent。

- 当存在待分发的事件链表，则会尝试判断是否已经存在相同的输入设备(也就是相同的输入类型)相同事件对象。
  - 如果找到了相同的输入设备id则block为true，找到相同事件对象或者末尾则跳出循环。
    - 如果遍历刚好在末尾，说明没有相同的事件则通过enqueue添加到事件链表末尾。
    - 如果curr不为空，说明此时有相同的事件则dequeue 出队当前的输入事件，调用父类forward。
    - 如果经过forward的处理，事件队列还存在输入事件关闭FLAG_DEFERRED标志位的QueuedInputEvent，则继续遍历链表进行消费。


##### finishInputEvent
```cpp
    private void finishInputEvent(QueuedInputEvent q) {

        if (q.mReceiver != null) {
            boolean handled = (q.mFlags & QueuedInputEvent.FLAG_FINISHED_HANDLED) != 0;
            q.mReceiver.finishInputEvent(q.mEvent, handled);
        } else {
            ...
        }

        recycleQueuedInputEvent(q);
    }
```
能看到这个过程中很简单，如果QueuedInputEvent持有了InputEventReceiver对象则会InputEventReceiver.finishInputEvent进行native方法的调用，告诉native层销毁了当前的事件。

```cpp
    public final void finishInputEvent(InputEvent event, boolean handled) {
        if (event == null) {
            throw new IllegalArgumentException("event must not be null");
        }
        if (mReceiverPtr == 0) {
....
        } else {
            int index = mSeqMap.indexOfKey(event.getSequenceNumber());
            if (index < 0) {
...
            } else {
                int seq = mSeqMap.valueAt(index);
                mSeqMap.removeAt(index);
                nativeFinishInputEvent(mReceiverPtr, seq, handled);
            }
        }
        event.recycleIfNeededAfterDispatch();
    }
```

###### NativeInputEventReceiver finishInputEvent
```cpp
status_t NativeInputEventReceiver::finishInputEvent(uint32_t seq, bool handled) {

    status_t status = mInputConsumer.sendFinishedSignal(seq, handled);
    if (status) {
        if (status == WOULD_BLOCK) {
            Finish finish;
            finish.seq = seq;
            finish.handled = handled;
            mFinishQueue.add(finish);
            if (mFinishQueue.size() == 1) {
                setFdEvents(ALOOPER_EVENT_INPUT | ALOOPER_EVENT_OUTPUT);
            }
            return OK;
        }
    }
    return status;
}
```
能看到很简单就是调用InputConsumer的sendFinishedSignal方法发送该输入事件的序列号处理对应在InputDispatcher中事件。


#### InputStage分类

当InputStage需要开始分发事件，就会调用apply方法，而apply中就会调用onProcess方法。每一个子类InputStage的onProcess其实就是意味着这个InputStage做了什么事情。

接下来我们就按照责任链的嵌套顺序来看看InputStage，每一个输入阶段都做了什么。


##### NativePreImeInputStage
```java
    final class NativePreImeInputStage extends AsyncInputStage
            implements InputQueue.FinishedInputEventCallback {
        public NativePreImeInputStage(InputStage next, String traceCounter) {
            super(next, traceCounter);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (mInputQueue != null && q.mEvent instanceof KeyEvent) {
                mInputQueue.sendInputEvent(q.mEvent, q, true, this);
                return DEFER;
            }
            return FORWARD;
        }
...
    }
```
NativePreImeInputStage实际上就是就是处理InputQueue。

##### ViewPreImeInputStage
```java
    final class ViewPreImeInputStage extends InputStage {
        public ViewPreImeInputStage(InputStage next) {
            super(next);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (q.mEvent instanceof KeyEvent) {
                return processKeyEvent(q);
            }
            return FORWARD;
        }

        private int processKeyEvent(QueuedInputEvent q) {
            final KeyEvent event = (KeyEvent)q.mEvent;
            if (mView.dispatchKeyEventPreIme(event)) {
                return FINISH_HANDLED;
            }
            return FORWARD;
        }
    }
```


ViewPreImeInputStage 这个InputStage是预处理KeyEvent，把键盘等事件通过DecorView的dispatchKeyEventPreIme进行预处理分发。

##### ImeInputStage
```java
    final class ImeInputStage extends AsyncInputStage
            implements InputMethodManager.FinishedInputEventCallback {
        public ImeInputStage(InputStage next, String traceCounter) {
            super(next, traceCounter);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (mLastWasImTarget && !isInLocalFocusMode()) {
                InputMethodManager imm = InputMethodManager.peekInstance();
                if (imm != null) {
                    final InputEvent event = q.mEvent;
                    int result = imm.dispatchInputEvent(event, q, this, mHandler);
                    if (result == InputMethodManager.DISPATCH_HANDLED) {
                        return FINISH_HANDLED;
                    } else if (result == InputMethodManager.DISPATCH_NOT_HANDLED) {
                        return FORWARD;
                    } else {
                        return DEFER; // callback will be invoked later
                    }
                }
            }
            return FORWARD;
        }

...
    }
```
ImeInputStage专门处理软键盘的事件分发。


##### EarlyPostImeInputStage
```java
 final class EarlyPostImeInputStage extends InputStage {
        public EarlyPostImeInputStage(InputStage next) {
            super(next);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (q.mEvent instanceof KeyEvent) {
                return processKeyEvent(q);
            } else {
                final int source = q.mEvent.getSource();
                if ((source & InputDevice.SOURCE_CLASS_POINTER) != 0) {
                    return processPointerEvent(q);
                }
            }
            return FORWARD;
        }

        private int processKeyEvent(QueuedInputEvent q) {
            final KeyEvent event = (KeyEvent)q.mEvent;

            if (mAttachInfo.mTooltipHost != null) {
                mAttachInfo.mTooltipHost.handleTooltipKey(event);
            }

            if (checkForLeavingTouchModeAndConsume(event)) {
                return FINISH_HANDLED;
            }

            mFallbackEventHandler.preDispatchKeyEvent(event);
            return FORWARD;
        }

        private int processPointerEvent(QueuedInputEvent q) {
            final MotionEvent event = (MotionEvent)q.mEvent;

            if (mTranslator != null) {
                mTranslator.translateEventInScreenToAppWindow(event);
            }

            final int action = event.getAction();
            if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_SCROLL) {
                ensureTouchMode(event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN));
            }

            if (action == MotionEvent.ACTION_DOWN) {
                // Upon motion event within app window, close autofill ui.
                AutofillManager afm = getAutofillManager();
                if (afm != null) {
                    afm.requestHideFillUi();
                }
            }

            if (action == MotionEvent.ACTION_DOWN && mAttachInfo.mTooltipHost != null) {
                mAttachInfo.mTooltipHost.hideTooltip();
            }

            if (mCurScrollY != 0) {
                event.offsetLocation(0, mCurScrollY);
            }

            if (event.isTouchEvent()) {
                mLastTouchPoint.x = event.getRawX();
                mLastTouchPoint.y = event.getRawY();
                mLastTouchSource = event.getSource();
            }
            return FORWARD;
        }
    }
```
该方法实际上是处理mFallbackEventHandler的Key事件。这个对象是PhoneFallbackEventHandler，里面处理了手机屏幕外按键的事件处理，如多媒体音量，通话音量等等。还处理了Touch模式以及AutofillManager。


##### NativePostImeInputStage
```java
    final class NativePostImeInputStage extends AsyncInputStage
            implements InputQueue.FinishedInputEventCallback {
        public NativePostImeInputStage(InputStage next, String traceCounter) {
            super(next, traceCounter);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (mInputQueue != null) {
                mInputQueue.sendInputEvent(q.mEvent, q, false, this);
                return DEFER;
            }
            return FORWARD;
        }

...
    }
```

NativePostImeInputStage继续处理了之前还需要继续处理InputQueue中的事件。

##### ViewPostImeInputStage

```java
    final class ViewPostImeInputStage extends InputStage {
        public ViewPostImeInputStage(InputStage next) {
            super(next);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            if (q.mEvent instanceof KeyEvent) {
                return processKeyEvent(q);
            } else {
                final int source = q.mEvent.getSource();
                if ((source & InputDevice.SOURCE_CLASS_POINTER) != 0) {
                    return processPointerEvent(q);
                } else if ((source & InputDevice.SOURCE_CLASS_TRACKBALL) != 0) {
                    return processTrackballEvent(q);
                } else {
                    return processGenericMotionEvent(q);
                }
            }
        }
....
}
```
- 判断是KeyEvent类型则processKeyEvent开始分发KeyEntry
- 如果不是KeyEvent，但是是手指输入设备，则调用processPointerEvent。最终会调用View 的dispatchPointerEvent
  - 如果来自SOURCE_CLASS_TRACKBALL输入设备，则调用processTrackballEvent。最终会调用View 的dispatchTrackballEvent
  - 剩下的则会通过processGenericMotionEvent分发Monition。会调用View的dispatchGenericMotionEvent方法。

###### SyntheticInputStage
```java
    final class SyntheticInputStage extends InputStage {
        private final SyntheticTrackballHandler mTrackball = new SyntheticTrackballHandler();
        private final SyntheticJoystickHandler mJoystick = new SyntheticJoystickHandler();
        private final SyntheticTouchNavigationHandler mTouchNavigation =
                new SyntheticTouchNavigationHandler();
        private final SyntheticKeyboardHandler mKeyboard = new SyntheticKeyboardHandler();

        public SyntheticInputStage() {
            super(null);
        }

        @Override
        protected int onProcess(QueuedInputEvent q) {
            q.mFlags |= QueuedInputEvent.FLAG_RESYNTHESIZED;
            if (q.mEvent instanceof MotionEvent) {
                final MotionEvent event = (MotionEvent)q.mEvent;
                final int source = event.getSource();
                if ((source & InputDevice.SOURCE_CLASS_TRACKBALL) != 0) {
                    mTrackball.process(event);
                    return FINISH_HANDLED;
                } else if ((source & InputDevice.SOURCE_CLASS_JOYSTICK) != 0) {
                    mJoystick.process(event);
                    return FINISH_HANDLED;
                } else if ((source & InputDevice.SOURCE_TOUCH_NAVIGATION)
                        == InputDevice.SOURCE_TOUCH_NAVIGATION) {
                    mTouchNavigation.process(event);
                    return FINISH_HANDLED;
                }
            } else if ((q.mFlags & QueuedInputEvent.FLAG_UNHANDLED) != 0) {
                mKeyboard.process((KeyEvent)q.mEvent);
                return FINISH_HANDLED;
            }

            return FORWARD;
        }
        @Override
        protected void onDeliverToNext(QueuedInputEvent q) {
            if ((q.mFlags & QueuedInputEvent.FLAG_RESYNTHESIZED) == 0) {
                if (q.mEvent instanceof MotionEvent) {
                    final MotionEvent event = (MotionEvent)q.mEvent;
                    final int source = event.getSource();
                    if ((source & InputDevice.SOURCE_CLASS_TRACKBALL) != 0) {
                        mTrackball.cancel();
                    } else if ((source & InputDevice.SOURCE_CLASS_JOYSTICK) != 0) {
                        mJoystick.cancel();
                    } else if ((source & InputDevice.SOURCE_TOUCH_NAVIGATION)
                            == InputDevice.SOURCE_TOUCH_NAVIGATION) {
                        mTouchNavigation.cancel(event);
                    }
                }
            }
            super.onDeliverToNext(q);
        }
...
}
```
在对剩下不同的设备输入事件进行通过对应的处理对象进行enqueue处理。


## View触点事件的分发
在这么多的InputStage 输入处理阶段对象中，需要我们进行重点关注的是ViewPostImeInputStage。在这个阶段中对Key和Motion对象进行处理。

### Key事件分发
```java
        private int processKeyEvent(QueuedInputEvent q) {
            final KeyEvent event = (KeyEvent)q.mEvent;

....
            // Deliver the key to the view hierarchy.
            if (mView.dispatchKeyEvent(event)) {
                return FINISH_HANDLED;
            }
...
            return FORWARD;
        }
```
实际上此时的mView是DecorView。通过根布局的dispatchKeyEvent向整个View视图层级分发。

#### DecorView dispatchKeyEvent
```java
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        final int keyCode = event.getKeyCode();
        final int action = event.getAction();
        final boolean isDown = action == KeyEvent.ACTION_DOWN;

...
        if (!mWindow.isDestroyed()) {
            final Window.Callback cb = mWindow.getCallback();
            final boolean handled = cb != null && mFeatureId < 0 ? cb.dispatchKeyEvent(event)
                    : super.dispatchKeyEvent(event);
            if (handled) {
                return true;
            }
        }

        return isDown ? mWindow.onKeyDown(mFeatureId, event.getKeyCode(), event)
                : mWindow.onKeyUp(mFeatureId, event.getKeyCode(), event);
    }
```
DecorView会校验它持有的PhoneWindow是否被销毁。没有销毁则获取PhoneWindow的Window.Callback监听对象，调用它的dispatchKeyEvent方法。


如果判断dispatchKeyEvent处理的事件返回false，说明需要继续处理Key事件。因此此时发现当前的KeyEvent是ACTION_DOWN，则会调用PhoneWindow的onKeyDown方法，否则则调用onKeyUp。

我们主要来考察Key的事件分发.注意此时正在监听Window.Callback的回调是Activity。

#### Activity dispatchKeyEvent
```java
    public boolean dispatchKeyEvent(KeyEvent event) {
        onUserInteraction();

        final int keyCode = event.getKeyCode();
        if (keyCode == KeyEvent.KEYCODE_MENU &&
                mActionBar != null && mActionBar.onMenuKeyEvent(event)) {
            return true;
        }

        Window win = getWindow();
        if (win.superDispatchKeyEvent(event)) {
            return true;
        }
        View decor = mDecor;
        if (decor == null) decor = win.getDecorView();
        return event.dispatch(this, decor != null
                ? decor.getKeyDispatcherState() : null, this);
    }
```
Activity获取PhoneWindow对象，调用PhoneWindow的superDispatchKeyEvent。

##### PhoneWindow superDispatchKeyEvent
```java
    public boolean superDispatchKeyEvent(KeyEvent event) {
        return mDecor.superDispatchKeyEvent(event);
    }
```
##### DecorView superDispatchKeyEvent
```java
    public boolean superDispatchKeyEvent(KeyEvent event) {
...

        if (super.dispatchKeyEvent(event)) {
            return true;
        }

        return (getViewRootImpl() != null) && getViewRootImpl().dispatchUnhandledKeyEvent(event);
    }
```
调用了核心的了ViewGroup的dispatchKeyEvent方法。


###### ViewGroup dispatchKeyEvent
```java
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onKeyEvent(event, 1);
        }

        if ((mPrivateFlags & (PFLAG_FOCUSED | PFLAG_HAS_BOUNDS))
                == (PFLAG_FOCUSED | PFLAG_HAS_BOUNDS)) {
            if (super.dispatchKeyEvent(event)) {
                return true;
            }
        } else if (mFocused != null && (mFocused.mPrivateFlags & PFLAG_HAS_BOUNDS)
                == PFLAG_HAS_BOUNDS) {
            if (mFocused.dispatchKeyEvent(event)) {
                return true;
            }
        }

        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onUnhandledEvent(event, 1);
        }
        return false;
    }
```
在ViewGroup中会记录当前的焦点View。如果是当前的ViewGroup带上了焦点，则会调用父类的dispatchKeyEvent方法。否则则尝试的查找当前的ViewGroup中焦点View的dispatchKeyEvent继续分发Key事件。


##### View dispatchKeyEvent
```java
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onKeyEvent(event, 0);
        }


        ListenerInfo li = mListenerInfo;
        if (li != null && li.mOnKeyListener != null && (mViewFlags & ENABLED_MASK) == ENABLED
                && li.mOnKeyListener.onKey(this, event.getKeyCode(), event)) {
            return true;
        }

        if (event.dispatch(this, mAttachInfo != null
                ? mAttachInfo.mKeyDispatchState : null, this)) {
            return true;
        }

        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onUnhandledEvent(event, 0);
        }
        return false;
    }
```
能够在这里看到了此时会回调我们给当前View设置的mOnKeyListener回调onKey方法。

这样就完成了对Key事件的监听。

### ViewRootImpl Motion触点事件分发
我们回到ViewPostImeInputStage中对Motion的触点事件处理processPointerEvent的考察。

```java

        private int processPointerEvent(QueuedInputEvent q) {
            final MotionEvent event = (MotionEvent)q.mEvent;

            mAttachInfo.mUnbufferedDispatchRequested = false;
            mAttachInfo.mHandlingPointerEvent = true;
            boolean handled = mView.dispatchPointerEvent(event);
...
            return handled ? FINISH_HANDLED : FORWARD;
        }
```

很简单就是调用了DecorView的dispatchPointerEvent方法。而DecorView的dispatchPointerEvent就是调用了View的dispatchPointerEvent

#### View dispatchPointerEvent
```java
    public final boolean dispatchPointerEvent(MotionEvent event) {
        if (event.isTouchEvent()) {
            return dispatchTouchEvent(event);
        } else {
            return dispatchGenericMotionEvent(event);
        }
    }

```
这里就会判断是否是触点事件，如果是则调用dispatchTouchEvent方法，否则则dispatchGenericMotionEvent处理。我们考察dispatchTouchEvent触点事件的分发。

#### ViewGroup dispatchTouchEvent
从这个方法开始，就是我们熟悉的事件分发处理：

```java
    public boolean dispatchTouchEvent(MotionEvent ev) {
...
        boolean handled = false;
        if (onFilterTouchEventForSecurity(ev)) {
            final int action = ev.getAction();
            final int actionMasked = action & MotionEvent.ACTION_MASK;

            if (actionMasked == MotionEvent.ACTION_DOWN) {
                cancelAndClearTouchTargets(ev);
                resetTouchState();
            }

            final boolean intercepted;
            if (actionMasked == MotionEvent.ACTION_DOWN
                    || mFirstTouchTarget != null) {
                final boolean disallowIntercept = (mGroupFlags & FLAG_DISALLOW_INTERCEPT) != 0;
                if (!disallowIntercept) {
//核心事件1
                    intercepted = onInterceptTouchEvent(ev);
                    ev.setAction(action); // restore action in case it was changed
                } else {
                    intercepted = false;
                }
            } else {
                intercepted = true;
            }


...
            final boolean canceled = resetCancelNextUpFlag(this)
                    || actionMasked == MotionEvent.ACTION_CANCEL;

            final boolean split = (mGroupFlags & FLAG_SPLIT_MOTION_EVENTS) != 0;
            TouchTarget newTouchTarget = null;
            boolean alreadyDispatchedToNewTouchTarget = false;
            if (!canceled && !intercepted) {

                View childWithAccessibilityFocus = ev.isTargetAccessibilityFocus()
                        ? findChildWithAccessibilityFocus() : null;

                if (actionMasked == MotionEvent.ACTION_DOWN
                        || (split && actionMasked == MotionEvent.ACTION_POINTER_DOWN)
                        || actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
                    final int actionIndex = ev.getActionIndex(); // always 0 for down
                    final int idBitsToAssign = split ? 1 << ev.getPointerId(actionIndex)
                            : TouchTarget.ALL_POINTER_IDS;

                    removePointersFromTouchTargets(idBitsToAssign);

                    final int childrenCount = mChildrenCount;
                    if (newTouchTarget == null && childrenCount != 0) {
                        final float x = ev.getX(actionIndex);
                        final float y = ev.getY(actionIndex);
                        final ArrayList<View> preorderedList = buildTouchDispatchChildList();
                        final boolean customOrder = preorderedList == null
                                && isChildrenDrawingOrderEnabled();
                        final View[] children = mChildren;
                        for (int i = childrenCount - 1; i >= 0; i--) {
                            final int childIndex = getAndVerifyPreorderedIndex(
                                    childrenCount, i, customOrder);
                            final View child = getAndVerifyPreorderedView(
                                    preorderedList, children, childIndex);

                            if (!canViewReceivePointerEvents(child)
                                    || !isTransformedTouchPointInView(x, y, child, null)) {
                                ev.setTargetAccessibilityFocus(false);
                                continue;
                            }

                            newTouchTarget = getTouchTarget(child);
                            if (newTouchTarget != null) {
                                newTouchTarget.pointerIdBits |= idBitsToAssign;
                                break;
                            }

                            if (dispatchTransformedTouchEvent(ev, false, child, idBitsToAssign)) {
                                mLastTouchDownTime = ev.getDownTime();
                                if (preorderedList != null) {
                                    // childIndex points into presorted list, find original index
                                    for (int j = 0; j < childrenCount; j++) {
                                        if (children[childIndex] == mChildren[j]) {
                                            mLastTouchDownIndex = j;
                                            break;
                                        }
                                    }
                                } else {
                                    mLastTouchDownIndex = childIndex;
                                }
                                mLastTouchDownX = ev.getX();
                                mLastTouchDownY = ev.getY();
                                newTouchTarget = addTouchTarget(child, idBitsToAssign);
                                alreadyDispatchedToNewTouchTarget = true;
                                break;
                            }

...
                        }
                        if (preorderedList != null) preorderedList.clear();
                    }

                    if (newTouchTarget == null && mFirstTouchTarget != null) {
                        newTouchTarget = mFirstTouchTarget;
                        while (newTouchTarget.next != null) {
                            newTouchTarget = newTouchTarget.next;
                        }
                        newTouchTarget.pointerIdBits |= idBitsToAssign;
                    }
                }
            }

            // Dispatch to touch targets.
            if (mFirstTouchTarget == null) {
                handled = dispatchTransformedTouchEvent(ev, canceled, null,
                        TouchTarget.ALL_POINTER_IDS);
            } else {

                TouchTarget predecessor = null;
                TouchTarget target = mFirstTouchTarget;
                while (target != null) {
                    final TouchTarget next = target.next;
                    if (alreadyDispatchedToNewTouchTarget && target == newTouchTarget) {
                        handled = true;
                    } else {
                        final boolean cancelChild = resetCancelNextUpFlag(target.child)
                                || intercepted;
                        if (dispatchTransformedTouchEvent(ev, cancelChild,
                                target.child, target.pointerIdBits)) {
                            handled = true;
                        }
                        if (cancelChild) {
                            if (predecessor == null) {
                                mFirstTouchTarget = next;
                            } else {
                                predecessor.next = next;
                            }
                            target.recycle();
                            target = next;
                            continue;
                        }
                    }
                    predecessor = target;
                    target = next;
                }
            }

            if (canceled
                    || actionMasked == MotionEvent.ACTION_UP
                    || actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
                resetTouchState();
            } else if (split && actionMasked == MotionEvent.ACTION_POINTER_UP) {
                final int actionIndex = ev.getActionIndex();
                final int idBitsToRemove = 1 << ev.getPointerId(actionIndex);
                removePointersFromTouchTargets(idBitsToRemove);
            }
        }

...
        return handled;
    }
```
在这个过程中如下执行了几个核心逻辑：
- 1.onInterceptTouchEvent 校验当前的ViewGroup是否需要拦截当前事件分发到子View。
- 2.如果不进行拦截事件分发，则代表可以继续分发触点事件。首先会对当前ViewGroup中所有的子View先按照z轴的顺序排序。然后按照这个顺序遍历每一个子View.
  - 1.为了进行优化，ViewGroup会记录TouchTarget对象链表。TouchTarget这个链表实际上就是记录每一次可以进行焦点处理的子View。通过isTransformedTouchPointInView方法校验当前的触点是否在子View范围中，如果当前能够获取到TouchTarget对象，则跳出当前遍历z轴顺序的循环。并在下面一个新循环中处理dispatchTransformedTouchEvent。
  - 2.如果TouchTarget中获取不到有效的触点对象，说明该View已经清空了一次TouchTarget链表或者第一次。则会dispatchTransformedTouchEvent处理每一个子View成功后，为对应的子View添加一个对应的TouchTarget。

来看看isTransformedTouchPointInView是怎么判断触点事件在View的范围：
```java
    protected boolean isTransformedTouchPointInView(float x, float y, View child,
            PointF outLocalPoint) {
        final float[] point = getTempPoint();
        point[0] = x;
        point[1] = y;
        transformPointToViewLocal(point, child);
        final boolean isInView = child.pointInView(point[0], point[1]);
        if (isInView && outLocalPoint != null) {
            outLocalPoint.set(point[0], point[1]);
        }
        return isInView;
    }

    public boolean pointInView(float localX, float localY, float slop) {
        return localX >= -slop && localY >= -slop && localX < ((mRight - mLeft) + slop) &&
                localY < ((mBottom - mTop) + slop);
    }
```
很简单知道子View的四个边缘和滑动的距离，只要在这四个区域内即可。

核心分发给子View的核心是dispatchTransformedTouchEvent。

##### ViewGroup dispatchTransformedTouchEvent

```java
    private boolean dispatchTransformedTouchEvent(MotionEvent event, boolean cancel,
            View child, int desiredPointerIdBits) {
        final boolean handled;

        final int oldAction = event.getAction();
...
        final int oldPointerIdBits = event.getPointerIdBits();
        final int newPointerIdBits = oldPointerIdBits & desiredPointerIdBits;

        if (newPointerIdBits == 0) {
            return false;
        }

        final MotionEvent transformedEvent;
...

        if (child == null) {
            handled = super.dispatchTouchEvent(transformedEvent);
        } else {
            final float offsetX = mScrollX - child.mLeft;
            final float offsetY = mScrollY - child.mTop;
            transformedEvent.offsetLocation(offsetX, offsetY);
            if (! child.hasIdentityMatrix()) {
                transformedEvent.transform(child.getInverseMatrix());
            }

            handled = child.dispatchTouchEvent(transformedEvent);
        }

        // Done.
        transformedEvent.recycle();
        return handled;
    }
```
- 如果child为null，说明可能在这个ViewGroup中没找到需要触点处理的子View。则调用了父类View的dispatchTouchEvent。

- 如果child不为null，则调用该子View的dispatchTouchEvent方法。


###### View dispatchTouchEvent
```java
    public boolean dispatchTouchEvent(MotionEvent event) {
...

        boolean result = false;

        if (mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onTouchEvent(event, 0);
        }

        final int actionMasked = event.getActionMasked();
        if (actionMasked == MotionEvent.ACTION_DOWN) {
            stopNestedScroll();
        }

        if (onFilterTouchEventForSecurity(event)) {
            if ((mViewFlags & ENABLED_MASK) == ENABLED && handleScrollBarDragging(event)) {
                result = true;
            }

            ListenerInfo li = mListenerInfo;
            if (li != null && li.mOnTouchListener != null
                    && (mViewFlags & ENABLED_MASK) == ENABLED
                    && li.mOnTouchListener.onTouch(this, event)) {
                result = true;
            }

            if (!result && onTouchEvent(event)) {
                result = true;
            }
        }

        if (!result && mInputEventConsistencyVerifier != null) {
            mInputEventConsistencyVerifier.onUnhandledEvent(event, 0);
        }

        if (actionMasked == MotionEvent.ACTION_UP ||
                actionMasked == MotionEvent.ACTION_CANCEL ||
                (actionMasked == MotionEvent.ACTION_DOWN && !result)) {
            stopNestedScroll();
        }

        return result;
    }
```
在这个过程中按照顺序执行如下的步骤：
- 1.判断当前是ACTION_DOWN 则暂停滑动
- 2.判断mOnTouchListener不为空，先执行mOnTouchListener的onTouch方法。
- 3.回调onTouchEvent方法
- 4.判断到是ACTION_UP或者ACTION_CANCEL或者ACTION_DOWN，且不是拽动则暂停滑动。

###### View onTouchEvent
```java
    public boolean onTouchEvent(MotionEvent event) {
        final float x = event.getX();
        final float y = event.getY();
        final int viewFlags = mViewFlags;
        final int action = event.getAction();

        final boolean clickable = ((viewFlags & CLICKABLE) == CLICKABLE
                || (viewFlags & LONG_CLICKABLE) == LONG_CLICKABLE)
                || (viewFlags & CONTEXT_CLICKABLE) == CONTEXT_CLICKABLE;

        if ((viewFlags & ENABLED_MASK) == DISABLED) {
            if (action == MotionEvent.ACTION_UP && (mPrivateFlags & PFLAG_PRESSED) != 0) {
                setPressed(false);
            }
            mPrivateFlags3 &= ~PFLAG3_FINGER_DOWN;
            return clickable;
        }
        if (mTouchDelegate != null) {
            if (mTouchDelegate.onTouchEvent(event)) {
                return true;
            }
        }

        if (clickable || (viewFlags & TOOLTIP) == TOOLTIP) {
            switch (action) {
                case MotionEvent.ACTION_UP:
                    mPrivateFlags3 &= ~PFLAG3_FINGER_DOWN;
...
                    boolean prepressed = (mPrivateFlags & PFLAG_PREPRESSED) != 0;
                    if ((mPrivateFlags & PFLAG_PRESSED) != 0 || prepressed) {
                        boolean focusTaken = false;
                        if (isFocusable() && isFocusableInTouchMode() && !isFocused()) {
                            focusTaken = requestFocus();
                        }

                        if (prepressed) {
                            setPressed(true, x, y);
                        }

                        if (!mHasPerformedLongPress && !mIgnoreNextUpEvent) {
                            removeLongPressCallback();
                            if (!focusTaken) {
                                if (mPerformClick == null) {
                                    mPerformClick = new PerformClick();
                                }
                                if (!post(mPerformClick)) {
                                    performClickInternal();
                                }
                            }
                        }

                        if (mUnsetPressedState == null) {
                            mUnsetPressedState = new UnsetPressedState();
                        }

                        if (prepressed) {
                            postDelayed(mUnsetPressedState,
                                    ViewConfiguration.getPressedStateDuration());
                        } else if (!post(mUnsetPressedState)) {
                            mUnsetPressedState.run();
                        }

                        removeTapCallback();
                    }
                    mIgnoreNextUpEvent = false;
                    break;

                case MotionEvent.ACTION_DOWN:
...
                    break;

                case MotionEvent.ACTION_CANCEL:
...
                    break;

                case MotionEvent.ACTION_MOVE:
....
                    break;
            }

            return true;
        }

        return false;
    }
```
我们只需要关注Up手势中做了比较重要的逻辑：
- 如果可以进行聚焦，但是没有焦点则先requestFocus进行焦点的请求
- 如果prepressed为true，则调用setPressed把下按状态设置为true
- 调用post发送PerformClick的runnable，如果发送失败则调用performClickInternal直接发送onClick方法。

```java
    public boolean performClick() {
        notifyAutofillManagerOnClick();

        final boolean result;
        final ListenerInfo li = mListenerInfo;
        if (li != null && li.mOnClickListener != null) {
            playSoundEffect(SoundEffectConstants.CLICK);
            li.mOnClickListener.onClick(this);
            result = true;
        } else {
            result = false;
        }

        sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_CLICKED);

        notifyEnterOrExitForAutoFillIfNeeded(true);

        return result;
    }
```

## 总结
到这里就结束了对IMS相关的逻辑分析。

根据上一次的设计图，来展示更加完整的结构图
![IMS_App设计.png](/images/IMS_App设计.png)

App进程初始化IMS的监听：
- 当Activity初始化后，在resume生命周期，会调用ViewRootImpl的setView方法。
 - 在这个方法中，会调用addWindow，把初始化好的InputChannel传送到WMS的WindowState中。WindowState会为InputChannel初始化一对socket文件描述符，一端在监听IMS的事件发送，另一段是监听发送的到来。
  - App主线程的WindowInputEventReceiver 对象会通过Looper会监听InputChannel的接收端。一旦接收端有事件发送到来，就会唤醒Looper在InputConsumer中进行消费。
    - InputConsumer消费触点对象后，会回调到WindowInputEventReceiver中，调用Looper发送一个IMS发送对象，准备在InputStage中进行处理。

InputStage是输入事件的处理阶段，是一种很典型的责任链设计模式，每一个处理阶段都会知道下一个处理阶段是什么，这种设计在App开发中十分常见，对于冗长的业务，我们可以通过这种设计灵活的进行解藕。

- NativePreImeInputStage 预处理InputQueue
- ViewPreImeInputStage 这个InputStage是预处理KeyEvent，把键盘等事件通过DecorView的dispatchKeyEventPreIme进行预处理分发。
- ImeInputStage专门处理软键盘的事件分发
- EarlyPostImeInputStage 处理mFallbackEventHandler的Key事件。这个对象是PhoneFallbackEventHandler，里面处理了手机屏幕外按键的事件处理，如多媒体音量，通话音量等等。还处理了Touch模式以及AutofillManager
- NativePostImeInputStage继续处理了之前还需要继续处理InputQueue中的事件
- ViewPostImeInputStage 对Key和Motion进行View层级的事件分发
- SyntheticInputStage 根据设备进行不同的输入事件入队处理(如触屏球等)。

关于InputQueue和SyntheticInputStage我们不需要过多的关注。我们App开发还是主要关注ViewPostImeInputStage是如何分发的。

事件分发的流程顺序：
- ViewGroup的dispatchTouchEvent 分发事件
- ViewGroup的onInterceptTouchEvent 拦截事件
- View的dispatchTouchEvent
- onTouchListener.onTouch 的监听回调
- onTouchEvent 方法回调
- onClickListener.onClick 当是手势抬起时，点击事件回调

这个流程是面试最常见的问题之一，记住即可。


## 后记
原计划是准备聊聊PMS的安装Apk原理。不过，我个人觉得还是先把另外三大组件都聊一边，我们再回来聊聊PMS的安装原理。

然后以PMS安装的dex文件的介绍，来开始Android art虚拟机的原理介绍。