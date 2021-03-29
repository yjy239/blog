---
title: Android重学系列 IMS与事件分发(上)
top: false
cover: false
date: 2020-07-22 09:37:17
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
当了解的View是如何渲染之后，我们再聊聊点击事件是如何分发。所有的点击事件实际上都是来源于SystemServer进程中的InputManagerService(之后我将简称为IMS)。

就让我们来看看IMS的初始化。

# 正文

## IMS的初始化
在SystemServer进程中，对IMS的初始化实际上很简单：
```java
            inputManager = new InputManagerService(context);
            wm = WindowManagerService.main(context, inputManager,
                    mFactoryTestMode != FactoryTest.FACTORY_TEST_LOW_LEVEL,
                    !mFirstBoot, mOnlyCore, new PhoneWindowManager());
            ServiceManager.addService(Context.WINDOW_SERVICE, wm, /* allowIsolated= */ false,
                    DUMP_FLAG_PRIORITY_CRITICAL | DUMP_FLAG_PROTO);
            ServiceManager.addService(Context.INPUT_SERVICE, inputManager,
                    /* allowIsolated= */ false, DUMP_FLAG_PRIORITY_CRITICAL);
            inputManager.setWindowManagerCallbacks(wm.getInputMonitor());
            inputManager.start();
```
大致分为如下几个步骤：
- 1.初始化IMS构造函数
- 2.IMS传入WMS一起初始化
- 3.在ServiceManager中添加Context.INPUT_SERVICE对应的IMS服务
- 4.IMS添加WindowManager的回调InputMonitor
- 5.IMS调用start方法


### IMS构造函数
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[input](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/input/)/[InputManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/input/InputManagerService.java)

```java
    public InputManagerService(Context context) {
        this.mContext = context;
        this.mHandler = new InputManagerHandler(DisplayThread.get().getLooper());

...
        mPtr = nativeInit(this, mContext, mHandler.getLooper().getQueue());
....

        LocalServices.addService(InputManagerInternal.class, new LocalService());
    }
```
- 构建可一个Hander对象，这个Handler对象的Looper来自DisplayThread的Looper。它将接受来自native中触点事件的回调
- nativeInit 在native层通过nativeInit初始化一个对应与IMS的native对象NativeInputManager。
- 新增一个本地服务LocalService 到LocalServices中


#### nativeInit
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/jni/)/[com_android_server_input_InputManagerService.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/jni/com_android_server_input_InputManagerService.cpp)
```cpp
static jlong nativeInit(JNIEnv* env, jclass /* clazz */,
        jobject serviceObj, jobject contextObj, jobject messageQueueObj) {
    sp<MessageQueue> messageQueue = android_os_MessageQueue_getMessageQueue(env, messageQueueObj);
...
    NativeInputManager* im = new NativeInputManager(contextObj, serviceObj,
            messageQueue->getLooper());
    im->incStrong(0);
    return reinterpret_cast<jlong>(im);
}
```
```cpp
NativeInputManager::NativeInputManager(jobject contextObj,
        jobject serviceObj, const sp<Looper>& looper) :
        mLooper(looper), mInteractive(true) {
    JNIEnv* env = jniEnv();

    mContextObj = env->NewGlobalRef(contextObj);
    mServiceObj = env->NewGlobalRef(serviceObj);

    {
        AutoMutex _l(mLock);
        mLocked.systemUiVisibility = ASYSTEM_UI_VISIBILITY_STATUS_BAR_VISIBLE;
        mLocked.pointerSpeed = 0;
        mLocked.pointerGesturesEnabled = true;
        mLocked.showTouches = false;
        mLocked.pointerCapture = false;
    }
    mInteractive = true;

    sp<EventHub> eventHub = new EventHub();
    mInputManager = new InputManager(eventHub, this, this);
}
```
在这里面构造了两个十分关键的对象EventHub与InputManager。

##### EventHub初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[EventHub.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/EventHub.cpp)

```cpp
EventHub::EventHub(void) :
        mBuiltInKeyboardId(NO_BUILT_IN_KEYBOARD), mNextDeviceId(1), mControllerNumbers(),
        mOpeningDevices(0), mClosingDevices(0),
        mNeedToSendFinishedDeviceScan(false),
        mNeedToReopenDevices(false), mNeedToScanDevices(true),
        mPendingEventCount(0), mPendingEventIndex(0), mPendingINotify(false) {
    acquire_wake_lock(PARTIAL_WAKE_LOCK, WAKE_LOCK_ID);

    mEpollFd = epoll_create(EPOLL_SIZE_HINT);

...
    struct epoll_event eventItem;
    memset(&eventItem, 0, sizeof(eventItem));
    eventItem.events = EPOLLIN;
    eventItem.data.u32 = EPOLL_ID_INOTIFY;
    result = epoll_ctl(mEpollFd, EPOLL_CTL_ADD, mINotifyFd, &eventItem);

    int wakeFds[2];
    result = pipe(wakeFds);

    mWakeReadPipeFd = wakeFds[0];
    mWakeWritePipeFd = wakeFds[1];

    result = fcntl(mWakeReadPipeFd, F_SETFL, O_NONBLOCK);

    result = fcntl(mWakeWritePipeFd, F_SETFL, O_NONBLOCK);

    eventItem.data.u32 = EPOLL_ID_WAKE;
    result = epoll_ctl(mEpollFd, EPOLL_CTL_ADD, mWakeReadPipeFd, &eventItem);
    int major, minor;
    getLinuxRelease(&major, &minor);
    mUsingEpollWakeup = major > 3 || (major == 3 && minor >= 5);
}
```
这里面执行如下2件事情:
- 1.先通过pipe系统调用，为wakeFds数组获取了socket文件描述符。注意第0个位置的socket描述符是读取，第一个是写入通道。
- 2.初始化epoll的文件描述符mEpollFd后，为pipe两个读写通道设置O_NONBLOCK标志位（不阻塞），并且通过epoll_ctl添加对读通道mWakeReadPipeFd的epoll监听。

##### InputManager初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[InputManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/InputManager.cpp)

```cpp
InputManager::InputManager(
        const sp<EventHubInterface>& eventHub,
        const sp<InputReaderPolicyInterface>& readerPolicy,
        const sp<InputDispatcherPolicyInterface>& dispatcherPolicy) {
    mDispatcher = new InputDispatcher(dispatcherPolicy);
    mReader = new InputReader(eventHub, readerPolicy, mDispatcher);
    initialize();
}

void InputManager::initialize() {
    mReaderThread = new InputReaderThread(mReader);
    mDispatcherThread = new InputDispatcherThread(mDispatcher);
}
```
在这里面创建了四个重要的对象：
- 1.InputDispatcher 事件分发者
- 2.InputReader 事件读取者
- 3.InputReaderThread 事件读取线程
- 4.InputDispatcherThread 事件分发线程

分别看看这4个对象初始化做了什么。

###### InputDispatcher
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[InputDispatcher.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/InputDispatcher.cpp)

```cpp
InputDispatcher::InputDispatcher(const sp<InputDispatcherPolicyInterface>& policy) :
    mPolicy(policy),
    mPendingEvent(NULL), mLastDropReason(DROP_REASON_NOT_DROPPED),
    mAppSwitchSawKeyDown(false), mAppSwitchDueTime(LONG_LONG_MAX),
    mNextUnblockedEvent(NULL),
    mDispatchEnabled(false), mDispatchFrozen(false), mInputFilterEnabled(false),
    mInputTargetWaitCause(INPUT_TARGET_WAIT_CAUSE_NONE) {
    mLooper = new Looper(false);

    mKeyRepeatState.lastKeyEntry = NULL;

    policy->getDispatcherConfiguration(&mConfig);
}
```
在这个过程中实例化了一个Looper对象,从NativeInputManager 的getDispatcherConfiguration方法中获取getKeyRepeatTimeout和getKeyRepeatDelay的配置。


###### InputReader
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[InputReader.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/InputReader.cpp)

```cpp
InputReader::InputReader(const sp<EventHubInterface>& eventHub,
        const sp<InputReaderPolicyInterface>& policy,
        const sp<InputListenerInterface>& listener) :
        mContext(this), mEventHub(eventHub), mPolicy(policy),
        mGlobalMetaState(0), mGeneration(1),
        mDisableVirtualKeysTimeout(LLONG_MIN), mNextTimeout(LLONG_MAX),
        mConfigurationChangesToRefresh(0) {
    mQueuedListener = new QueuedInputListener(listener);

    { 
        AutoMutex _l(mLock);

        refreshConfigurationLocked(0);
        updateGlobalMetaStateLocked();
    } 
}
```
保存EventHub对象和一个InputDispatcher对象。创建一个QueuedInputListener监听者。接着刷新配置。

###### InputReaderThread
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[InputReader.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/InputReader.cpp)

```cpp
InputReaderThread::InputReaderThread(const sp<InputReaderInterface>& reader) :
        Thread(/*canCallJava*/ true), mReader(reader) {
}

InputReaderThread::~InputReaderThread() {
}

bool InputReaderThread::threadLoop() {
    mReader->loopOnce();
    return true;
}

```
很简单，实际上就是一个线程对象。一旦启动了线程，则执行InputReader的loopOnce方法。

###### InputDispatcherThread
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[inputflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/)/[InputDispatcher.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/inputflinger/InputDispatcher.cpp)
```cpp
InputDispatcherThread::InputDispatcherThread(const sp<InputDispatcherInterface>& dispatcher) :
        Thread(/*canCallJava*/ true), mDispatcher(dispatcher) {
}

InputDispatcherThread::~InputDispatcherThread() {
}

bool InputDispatcherThread::threadLoop() {
    mDispatcher->dispatchOnce();
    return true;
}
```
同上，这里也是一个线程对象，一旦线程启动了，则会调用InputDispatcher的dispatchOnce方法。

从这几个构造函数我们大致上可以猜测输入事件的设计是怎么样的。InputReader持有了InputDispatcher，并且被InputReaderThread线程持有。那么可以推断出，InputReader运行在InputReaderThread线程中，并且会读取输入事件分发到InputDispatcher中。

### IMS传入WMS一起初始化

关于WMS相关的内容可以阅读[Android 重学系列 WMS在Activity启动中的职责(一)](https://www.jianshu.com/p/1fd180ea5d0e)相关文章。WMS的main方法到初始化构造函数的原理已经聊过了，我们来重点关注IMS相关的逻辑。

文件： /[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[WindowManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/WindowManagerService.java)

```java
private WindowManagerService(Context context, InputManagerService inputManager,
            boolean haveInputMethods, boolean showBootMsgs, boolean onlyCore,
            WindowManagerPolicy policy) {
...
        if(mInputManager != null) {
            final InputChannel inputChannel = mInputManager.monitorInput(TAG_WM);
            mPointerEventDispatcher = inputChannel != null
                    ? new PointerEventDispatcher(inputChannel) : null;
        } else {
            mPointerEventDispatcher = null;
        }
...
}
```
能看到在这个过程中IMS通过monitorInput创建了一个InputChannel，并且保存到了PointerEventDispatcher对象中。

该monitorInput方法实际上是创建了一个输入事件的名为WindowManager通道。

#### IMS monitorInput
```java
    public InputChannel monitorInput(String inputChannelName) {
        if (inputChannelName == null) {
            throw new IllegalArgumentException("inputChannelName must not be null.");
        }

        InputChannel[] inputChannels = InputChannel.openInputChannelPair(inputChannelName);
        nativeRegisterInputChannel(mPtr, inputChannels[0], null, true);
        inputChannels[0].dispose(); 
        return inputChannels[1];
    }
```
monitorInput这个方法实际上是通过openInputChannelPair创建一个接受通道，一个写入通道。释放掉原来的写入通道，返回一个接受通道，用于监听所有从底层传递过来的事件。

那么核心就是如下三个方法：
- InputChannel.openInputChannelPair 创建一对输入事件通道
- nativeRegisterInputChannel 注册输入事件通道到native的Looper中
- dispose 删除第0个位置的inputChannel通道，只留下第一个位置的通道，返回。因为在nativeRegisterInputChannel步骤中

### InputChannel.openInputChannelPair
openInputChannelPair该方法会直接调用对应的native方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_InputChannel.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_InputChannel.cpp)
```cpp
static const size_t SOCKET_BUFFER_SIZE = 32 * 1024;

static jobjectArray android_view_InputChannel_nativeOpenInputChannelPair(JNIEnv* env,
        jclass clazz, jstring nameObj) {
    const char* nameChars = env->GetStringUTFChars(nameObj, NULL);
    std::string name = nameChars;
    env->ReleaseStringUTFChars(nameObj, nameChars);

    sp<InputChannel> serverChannel;
    sp<InputChannel> clientChannel;
    status_t result = InputChannel::openInputChannelPair(name, serverChannel, clientChannel);

    jobjectArray channelPair = env->NewObjectArray(2, gInputChannelClassInfo.clazz, NULL);

    jobject serverChannelObj = android_view_InputChannel_createInputChannel(env,
            std::make_unique<NativeInputChannel>(serverChannel));

    jobject clientChannelObj = android_view_InputChannel_createInputChannel(env,
            std::make_unique<NativeInputChannel>(clientChannel));

    env->SetObjectArrayElement(channelPair, 0, serverChannelObj);
    env->SetObjectArrayElement(channelPair, 1, clientChannelObj);
    return channelPair;
}

static jobject android_view_InputChannel_createInputChannel(JNIEnv* env,
        std::unique_ptr<NativeInputChannel> nativeInputChannel) {
    jobject inputChannelObj = env->NewObject(gInputChannelClassInfo.clazz,
            gInputChannelClassInfo.ctor);
    if (inputChannelObj) {
        android_view_InputChannel_setNativeInputChannel(env, inputChannelObj,
                 nativeInputChannel.release());
    }
    return inputChannelObj;
}

```
- 调用 InputChannel::openInputChannelPair创建一对NativeInputChannel事件输入通道
- 通过android_view_InputChannel_createInputChannel 为服务端和客户端的通道用NativeInputChannel包裹一层后创建一个Java的InputChannel对象。最后返回InputChannel对。

#### InputChannel::openInputChannelPair
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[input](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/input/)/[InputTransport.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/input/InputTransport.cpp)

```cpp
status_t InputChannel::openInputChannelPair(const std::string& name,
        sp<InputChannel>& outServerChannel, sp<InputChannel>& outClientChannel) {
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets)) {
        status_t result = -errno;
        outServerChannel.clear();
        outClientChannel.clear();
        return result;
    }

    int bufferSize = SOCKET_BUFFER_SIZE;
    setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize));
    setsockopt(sockets[0], SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(bufferSize));
    setsockopt(sockets[1], SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize));
    setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(bufferSize));

    std::string serverChannelName = name;
    serverChannelName += " (server)";
    outServerChannel = new InputChannel(serverChannelName, sockets[0]);

    std::string clientChannelName = name;
    clientChannelName += " (client)";
    outClientChannel = new InputChannel(clientChannelName, sockets[1]);
    return OK;
}
```
能看到InputChannel实际上和SF进程中BitTube的原理十分相似，也可以阅读[Android 重学系列 SurfaceFlinger 的初始化](https://www.jianshu.com/p/9dac91bbb9c9)中的BitTube小结进行联动。

能看到BitTube以及InputChannel都是通过socketpair为传递进来的数组赋值一对socket文件描述符。设置这对socket文件描述符的接受发送缓冲区为32kb。并且分别创建socket文件描述符对应的InputChannel。

##### InputChannel 构造函数
```cpp
InputChannel::InputChannel(const std::string& name, int fd) :
        mName(name), mFd(fd) {

    int result = fcntl(mFd, F_SETFL, O_NONBLOCK);
}
```
很简单实际上就给当前的socket文件描述符设置非阻塞的标志位

### nativeRegisterInputChannel
注意nativeRegisterInputChannel这个方法是注册了socket对的第0个socket文件描述符
```java
nativeRegisterInputChannel(mPtr, inputChannels[0], null, true);
```

```cpp
static void nativeRegisterInputChannel(JNIEnv* env, jclass /* clazz */,
        jlong ptr, jobject inputChannelObj, jobject inputWindowHandleObj, jboolean monitor) {
    NativeInputManager* im = reinterpret_cast<NativeInputManager*>(ptr);

    sp<InputChannel> inputChannel = android_view_InputChannel_getInputChannel(env,
            inputChannelObj);
...
    sp<InputWindowHandle> inputWindowHandle =
            android_server_InputWindowHandle_getHandle(env, inputWindowHandleObj);

    status_t status = im->registerInputChannel(
            env, inputChannel, inputWindowHandle, monitor);
...

    if (! monitor) {
        android_view_InputChannel_setDisposeCallback(env, inputChannelObj,
                handleInputChannelDisposed, im);
    }
}
```
能看到这个过程中首先获取native中的InputChannel对象，并且获取IMS对应的native对象。由于此时InputWindowHandle传入的是null，我们暂时不考究。

此时调用的是NativeInputManager的registerInputChannel注册第0个socket文件描述符。

##### NativeInputManager registerInputChannel
```cpp
status_t NativeInputManager::registerInputChannel(JNIEnv* /* env */,
        const sp<InputChannel>& inputChannel,
        const sp<InputWindowHandle>& inputWindowHandle, bool monitor) {
    return mInputManager->getDispatcher()->registerInputChannel(
            inputChannel, inputWindowHandle, monitor);
}
```
实际上正在起作用的是InputManager中InputDispatcher对象。它执行了registerInputChannel

###### InputDispatcher registerInputChannel
```cpp
status_t InputDispatcher::registerInputChannel(const sp<InputChannel>& inputChannel,
        const sp<InputWindowHandle>& inputWindowHandle, bool monitor) {
...

    { // acquire lock
        AutoMutex _l(mLock);
...
        sp<Connection> connection = new Connection(inputChannel, inputWindowHandle, monitor);

        int fd = inputChannel->getFd();
        mConnectionsByFd.add(fd, connection);

        if (monitor) {
            mMonitoringChannels.push(inputChannel);
        }

        mLooper->addFd(fd, 0, ALOOPER_EVENT_INPUT, handleReceiveCallback, this);
    } 
    mLooper->wake();
    return OK;
}
```
在这个过程中，为inputChannel创建一个InputDispatcher::Connect 对象，并且以fd为key保存到mConnectionsByFd中。

如果monitor为true，inputChannel则保存到mMonitoringChannels中。此时是true因此会保存。

最后Looper将会对对当前InputChannel中的socket文件描述符进行监听ALOOPER_EVENT_INPUT事件类型，一旦出现了回调则调用handleReceiveCallback方法。
关于Looper的addFd的原理可以阅读我写的[Android 重学系列 Handler与相关系统调用的剖析(上)](https://www.jianshu.com/p/416de2a3a1d6)

接着先唤醒Looper中的阻塞。关于唤醒后的回调，对触点事件的分发，我们放到后面再来聊聊，先重点关注整个IMS的初始化。

### IMS添加WindowManager的回调InputMonitor
```java
inputManager.setWindowManagerCallbacks(wm.getInputMonitor());
```
```java
    public InputMonitor getInputMonitor() {
        return mInputMonitor;
    }
```

```java
    public void setWindowManagerCallbacks(WindowManagerCallbacks callbacks) {
        mWindowManagerCallbacks = callbacks;
    }
```
从这个三个片段的代码，实际上IMS获取了WMS内的InputMonitor为回调监听。
```java
final InputMonitor mInputMonitor = new InputMonitor(this);
```
保存到了IMS的mWindowManagerCallbacks。

### IMS调用start方法
```java
    public void start() {
        nativeStart(mPtr);

        Watchdog.getInstance().addMonitor(this);
        registerPointerSpeedSettingObserver();
        registerShowTouchesSettingObserver();
        registerAccessibilityLargePointerSettingObserver();

        mContext.registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                updatePointerSpeedFromSettings();
                updateShowTouchesFromSettings();
                updateAccessibilityLargePointerFromSettings();
            }
        }, new IntentFilter(Intent.ACTION_USER_SWITCHED), null, mHandler);

        updatePointerSpeedFromSettings();
        updateShowTouchesFromSettings();
        updateAccessibilityLargePointerFromSettings();
    }
```
依次做了如下的处理：
- 1.通过native 的方法启动IMS对应Native的对象
- 2.在WatchDog中注册监听卡死监听。WatchDog实际上很简单，就是校验每一个实现了Monitor接口的对象，在一个WatchDog线程中不断的监听每一个Monitor的monitor方法，这个方法一般的实现都是一个线程的Condition的等待阻塞。如果超过30秒没有释放锁则通过dropbox输入异常堆栈当日志中，并且根据情况是结束进程还是进行重启。有机会和大家聊聊。
- 3.更新触点显示速度和触点速度等配置。

核心还是第一个步骤nativeStart方法。

#### nativeStart
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/jni/)/[com_android_server_input_InputManagerService.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/jni/com_android_server_input_InputManagerService.cpp)
```cpp
static void nativeStart(JNIEnv* env, jclass /* clazz */, jlong ptr) {
    NativeInputManager* im = reinterpret_cast<NativeInputManager*>(ptr);

    status_t result = im->getInputManager()->start();
...
}
```
这个过程实际上就是调用了InputManager的start方法。

##### InputManager::start
```cpp
status_t InputManager::start() {
    status_t result = mDispatcherThread->run("InputDispatcher", PRIORITY_URGENT_DISPLAY);
    if (result) {
        return result;
    }

    result = mReaderThread->run("InputReader", PRIORITY_URGENT_DISPLAY);
    if (result) {
        mDispatcherThread->requestExit();
        return result;
    }

    return OK;
}
```
上文已经和大家聊过了，实际上就是分别执行InputDispatcherThread 事件分发线程的loopOnce和InputReaderThread 事件读取线程的threadLoop的方法。

先来看看事件读取的线程运行做了什么。

### InputReaderThread threadLoop 事件读取原理
```cpp
bool InputReaderThread::threadLoop() {
    mReader->loopOnce();
    return true;
}
```
```cpp
void InputReader::loopOnce() {
    int32_t oldGeneration;
    int32_t timeoutMillis;
    bool inputDevicesChanged = false;
    Vector<InputDeviceInfo> inputDevices;
    { // acquire lock
        AutoMutex _l(mLock);
...
    }

    size_t count = mEventHub->getEvents(timeoutMillis, mEventBuffer, EVENT_BUFFER_SIZE);

    { // acquire lock
        AutoMutex _l(mLock);
        mReaderIsAliveCondition.broadcast();

        if (count) {
            processEventsLocked(mEventBuffer, count);
        }

...
    } 

...
    mQueuedListener->flush();
}
```
核心代码代码本质上只有两个：
- 从EventHub中获取有多少个输入事件，保存到mEventBuffer中。
- 如果数量大于0，则processEventsLocked 把事件内容发送到事件分发线程中。

注意mReaderIsAliveCondition这个Condition实际上是Watchdog用于校验是否出现卡死的线程Condition条件。

##### EventHub getEvents
读取硬件中的输入事件比较长，让我们只关注核心的代码。
```cpp
size_t EventHub::getEvents(int timeoutMillis, RawEvent* buffer, size_t bufferSize) {
    ALOG_ASSERT(bufferSize >= 1);

    AutoMutex _l(mLock);

    struct input_event readBuffer[bufferSize];

    RawEvent* event = buffer;
    size_t capacity = bufferSize;
    bool awoken = false;
    for (;;) {
        nsecs_t now = systemTime(SYSTEM_TIME_MONOTONIC);
...

        if (mPendingINotify && mPendingEventIndex >= mPendingEventCount) {
            mPendingINotify = false;
            readNotifyLocked();
            deviceChanged = true;
        }

...
    
        mPendingEventIndex = 0;

        mLock.unlock(); // release lock before poll, must be before release_wake_lock
        release_wake_lock(WAKE_LOCK_ID);

        int pollResult = epoll_wait(mEpollFd, mPendingEventItems, EPOLL_MAX_EVENTS, timeoutMillis);

        acquire_wake_lock(PARTIAL_WAKE_LOCK, WAKE_LOCK_ID);
        mLock.lock();

        if (pollResult == 0) {
            mPendingEventCount = 0;
            break;
        }

        if (pollResult < 0) {
            // An error occurred.
            mPendingEventCount = 0;

            if (errno != EINTR) {
                usleep(100000);
            }
        } else {
            // Some events occurred.
            mPendingEventCount = size_t(pollResult);
        }
    }

    // All done, return the number of events we read.
    return event - buffer;
}
```
实际上做了两件事情：
- 1.如果是第一次加载或者输入的设备发生了变动，则会readNotifyLocked读取变化的设备信息，并且注册输入设备到epoll中进行监听。
- 2.接着会进行epoll等待，直到有输入事件到来，唤醒阻塞。

##### readNotifyLocked
```cpp

static const char *WAKE_LOCK_ID = "KeyEvents";
static const char *DEVICE_PATH = "/dev/input";

status_t EventHub::readNotifyLocked() {
    int res;
    char devname[PATH_MAX];
    char *filename;
    char event_buf[512];
    int event_size;
    int event_pos = 0;
    struct inotify_event *event;

  ...
    strcpy(devname, DEVICE_PATH);
    filename = devname + strlen(devname);
    *filename++ = '/';

    while(res >= (int)sizeof(*event)) {
        event = (struct inotify_event *)(event_buf + event_pos);
        if(event->len) {
            strcpy(filename, event->name);
            if(event->mask & IN_CREATE) {
                openDeviceLocked(devname);
            } else {
...
            }
        }
        event_size = sizeof(*event) + event->len;
        res -= event_size;
        event_pos += event_size;
    }
    return 0;
}
```
能看到这个过程实际上就是获取内存文件/dev/input，通过openDeviceLocked进行进一步的监听处理。监听/dev/input这个内存文件本质上就是监听输入设备的内核模块(驱动)。

###### openDeviceLocked
```cpp
status_t EventHub::openDeviceLocked(const char *devicePath) {
    char buffer[80];

    int fd = open(devicePath, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if(fd < 0) {
        return -1;
    }

    InputDeviceIdentifier identifier;

...

    assignDescriptorLocked(identifier);

    int32_t deviceId = mNextDeviceId++;
    Device* device = new Device(fd, deviceId, String8(devicePath), identifier);

...
    if (registerDeviceForEpollLocked(device) != OK) {
        delete device;
        return -1;
    }

    configureFd(device);

    addDeviceLocked(device);
    return OK;
}
```
能看到这个过程中做了如下四件事情：
- 1.open系统调用，打开输入驱动，并且获取对应的操作的fd文件描述符。
- 2.assignDescriptorLocked生成唯一id后，并且根据这个唯一id生成一个Device 输入设备对象。
- 3.registerDeviceForEpollLocked epoll将会开始监听输入驱动对应的文件描述符
- 4.addDeviceLocked 把当前的输入设备对象保存到mDevices集合中。

关键来看看registerDeviceForEpollLocked方法。

###### registerDeviceForEpollLocked
```cpp
status_t EventHub::registerDeviceForEpollLocked(Device* device) {
    struct epoll_event eventItem;
    memset(&eventItem, 0, sizeof(eventItem));
    eventItem.events = EPOLLIN;
    if (mUsingEpollWakeup) {
        eventItem.events |= EPOLLWAKEUP;
    }
    eventItem.data.u32 = device->id;
    if (epoll_ctl(mEpollFd, EPOLL_CTL_ADD, device->fd, &eventItem)) {
        return -errno;
    }
    return OK;
}
```
很简单就是通过epoll_ctl系统调用注册设备驱动对应的文件描述符的监听到epoll中。直到接收到了输入事件的驱动的信号唤醒，离开循环返回获取到的输入事件个数。

#### InputReader processEventsLocked
当一切都注册到了epoll的监听后，一旦出现了回调，则会调用解开epoll_wait的阻塞，进行processEventsLocked分发。
```cpp
void InputReader::processEventsLocked(const RawEvent* rawEvents, size_t count) {
    for (const RawEvent* rawEvent = rawEvents; count;) {
        int32_t type = rawEvent->type;
        size_t batchSize = 1;
        if (type < EventHubInterface::FIRST_SYNTHETIC_EVENT) {
            int32_t deviceId = rawEvent->deviceId;
            while (batchSize < count) {
                if (rawEvent[batchSize].type >= EventHubInterface::FIRST_SYNTHETIC_EVENT
                        || rawEvent[batchSize].deviceId != deviceId) {
                    break;
                }
                batchSize += 1;
            }
            processEventsForDeviceLocked(deviceId, rawEvent, batchSize);
        } else {
            switch (rawEvent->type) {
            case EventHubInterface::DEVICE_ADDED:
                addDeviceLocked(rawEvent->when, rawEvent->deviceId);
                break;
            case EventHubInterface::DEVICE_REMOVED:
                removeDeviceLocked(rawEvent->when, rawEvent->deviceId);
                break;
            case EventHubInterface::FINISHED_DEVICE_SCAN:
                handleConfigurationChangedLocked(rawEvent->when);
                break;
            default:
                ALOG_ASSERT(false); // can't happen
                break;
            }
        }
        count -= batchSize;
        rawEvent += batchSize;
    }
}
```
在输入事件中分为两种类型：
- 输入设备的的增加，变化，和删除
- 输入设备返回的是如键盘，屏幕触摸的输入信号

我们挑选设备增加的输入事件以及输入了触摸事件两个逻辑来看看InputReader的分发逻辑。

#### addDeviceLocked 驱动设备添加原理
```cpp
void InputReader::addDeviceLocked(nsecs_t when, int32_t deviceId) {
    ssize_t deviceIndex = mDevices.indexOfKey(deviceId);
    if (deviceIndex >= 0) {
        return;
    }

    InputDeviceIdentifier identifier = mEventHub->getDeviceIdentifier(deviceId);
    uint32_t classes = mEventHub->getDeviceClasses(deviceId);
    int32_t controllerNumber = mEventHub->getDeviceControllerNumber(deviceId);

    InputDevice* device = createDeviceLocked(deviceId, controllerNumber, identifier, classes);
    device->configure(when, &mConfig, 0);
    device->reset(when);

    mDevices.add(deviceId, device);
    bumpGenerationLocked();

    if (device->getClasses() & INPUT_DEVICE_CLASS_EXTERNAL_STYLUS) {
        notifyExternalStylusPresenceChanged();
    }
}
```
核心逻辑就是通过createDeviceLocked根据EventHub::Device 中的唯一id创建一个InputDevice对象；初始化好后添加到mDevices集合中。注意每一种输入设备的id对应的InputDevice，会在mDevices对应index下。

其中createDeviceLocked 这个方法就是整个InputReader对不同输入事件的处理控制者注册的逻辑。

###### createDeviceLocked
```cpp
InputDevice* InputReader::createDeviceLocked(int32_t deviceId, int32_t controllerNumber,
        const InputDeviceIdentifier& identifier, uint32_t classes) {
    InputDevice* device = new InputDevice(&mContext, deviceId, bumpGenerationLocked(),
            controllerNumber, identifier, classes);

...


    // Keyboard-like devices.
    uint32_t keyboardSource = 0;
    int32_t keyboardType = AINPUT_KEYBOARD_TYPE_NON_ALPHABETIC;
    if (classes & INPUT_DEVICE_CLASS_KEYBOARD) {
        keyboardSource |= AINPUT_SOURCE_KEYBOARD;
    }
    if (classes & INPUT_DEVICE_CLASS_ALPHAKEY) {
        keyboardType = AINPUT_KEYBOARD_TYPE_ALPHABETIC;
    }
    if (classes & INPUT_DEVICE_CLASS_DPAD) {
        keyboardSource |= AINPUT_SOURCE_DPAD;
    }
    if (classes & INPUT_DEVICE_CLASS_GAMEPAD) {
        keyboardSource |= AINPUT_SOURCE_GAMEPAD;
    }

    if (keyboardSource != 0) {
        device->addMapper(new KeyboardInputMapper(device, keyboardSource, keyboardType));
    }

    // Cursor-like devices.
...
    // Touchscreens and touchpad devices.
    if (classes & INPUT_DEVICE_CLASS_TOUCH_MT) {
        device->addMapper(new MultiTouchInputMapper(device));
    } else if (classes & INPUT_DEVICE_CLASS_TOUCH) {
        device->addMapper(new SingleTouchInputMapper(device));
    }

...
    return device;
}
```

这里我们只关注两个比较重要的InputMapper对象：
- KeyboardInputMapper 键盘输入事件处理对象
- SingleTouchInputMapper 单点触屏驶入事件处理对象

这两个对象也是开发中经常遇到的，能明白这两个逻辑，那么整个IMS 90%的场景已经够用了。

当输入设备在InputReader设置好之后，我们来看看InputReader遇到对应的输入事件是如何分发的。

核心方法为processEventsForDeviceLocked

##### processEventsForDeviceLocked
```cpp
void InputReader::processEventsForDeviceLocked(int32_t deviceId,
        const RawEvent* rawEvents, size_t count) {
    ssize_t deviceIndex = mDevices.indexOfKey(deviceId);
...
    InputDevice* device = mDevices.valueAt(deviceIndex);
    if (device->isIgnored()) {
        return;
    }

    device->process(rawEvents, count);
}
```
能看到此时根据输入设备的id从mDevices找到对应的InputDevice对象，从而进一步的处理输入事件。

```cpp
void InputDevice::process(const RawEvent* rawEvents, size_t count) {
    size_t numMappers = mMappers.size();
    for (const RawEvent* rawEvent = rawEvents; count != 0; rawEvent++) {

        if (mDropUntilNextSync) {
           ...
        } else if (rawEvent->type == EV_SYN && rawEvent->code == SYN_DROPPED) {

...
        } else {
            for (size_t i = 0; i < numMappers; i++) {
                InputMapper* mapper = mMappers[i];
                mapper->process(rawEvent);
            }
        }
        --count;
    }
}
```
能看到此时会遍历注册到InputDevice的InputMapper的处理对象。那么就来看看上文刚刚注册的KeyboardInputMapper和SingleTouchInputMapper对应的process方法。

### KeyboardInputMapper
首先来看看构造函数
```cpp
KeyboardInputMapper::KeyboardInputMapper(InputDevice* device,
        uint32_t source, int32_t keyboardType) :
        InputMapper(device), mSource(source),
        mKeyboardType(keyboardType) {
}
```
```cpp
bool KeyboardInputMapper::isKeyboardOrGamepadKey(int32_t scanCode) {
    return scanCode < BTN_MOUSE
        || scanCode >= KEY_OK
        || (scanCode >= BTN_MISC && scanCode < BTN_MOUSE)
        || (scanCode >= BTN_JOYSTICK && scanCode < BTN_DIGI);
}

void KeyboardInputMapper::process(const RawEvent* rawEvent) {
    switch (rawEvent->type) {
    case EV_KEY: {
        int32_t scanCode = rawEvent->code;
        int32_t usageCode = mCurrentHidUsage;
        mCurrentHidUsage = 0;

        if (isKeyboardOrGamepadKey(scanCode)) {
            processKey(rawEvent->when, rawEvent->value != 0, scanCode, usageCode);
        }
        break;
    }
    case EV_MSC: {
  ...
        break;
    }
    case EV_SYN: {
...
    }
    }
}
```
能判断到是EV_KEY这种类型，如果符合键盘输入的类型则执行processKey

##### processKey
```cpp
void KeyboardInputMapper::processKey(nsecs_t when, bool down, int32_t scanCode,
        int32_t usageCode) {
    int32_t keyCode;
    int32_t keyMetaState;
    uint32_t policyFlags;

....

    NotifyKeyArgs args(when, getDeviceId(), mSource, policyFlags,
            down ? AKEY_EVENT_ACTION_DOWN : AKEY_EVENT_ACTION_UP,
            AKEY_EVENT_FLAG_FROM_SYSTEM, keyCode, scanCode, keyMetaState, downTime);
    getListener()->notifyKey(&args);
}
```
此时就会获取Listener的对象的notifyKey方法。注意一下getListener其实就是上文初始化好的QueuedInputListener对象，而这个对象实际上就是InputDispatcher对象。



### SingleTouchInputMapper
```cpp
TouchInputMapper::TouchInputMapper(InputDevice* device) :
        InputMapper(device),
        mSource(0), mDeviceMode(DEVICE_MODE_DISABLED),
        mSurfaceWidth(-1), mSurfaceHeight(-1), mSurfaceLeft(0), mSurfaceTop(0),
        mSurfaceOrientation(DISPLAY_ORIENTATION_0) {
}

SingleTouchInputMapper::SingleTouchInputMapper(InputDevice* device) :
        TouchInputMapper(device) {
}
```
整个构造函数很简单，保存了当前Surface的宽高等信息。


#### SingleTouchInputMapper process
```cpp
void SingleTouchInputMapper::process(const RawEvent* rawEvent) {
    TouchInputMapper::process(rawEvent);

    mSingleTouchMotionAccumulator.process(rawEvent);
}
```
依次执行了TouchInputMapper的process方法以及SingleTouchMotionAccumulator的process。

重点来看看TouchInputMapper的process方法。

##### TouchInputMapper process
```cpp
void TouchInputMapper::process(const RawEvent* rawEvent) {
    mCursorButtonAccumulator.process(rawEvent);
    mCursorScrollAccumulator.process(rawEvent);
    mTouchButtonAccumulator.process(rawEvent);

    if (rawEvent->type == EV_SYN && rawEvent->code == SYN_REPORT) {
        sync(rawEvent->when);
    }
}
```
核心是这个sync方法。

##### TouchInputMapper sync
```cpp
void TouchInputMapper::sync(nsecs_t when) {
    const RawState* last = mRawStatesPending.isEmpty() ?
            &mCurrentRawState : &mRawStatesPending.top();

    // Push a new state.
    mRawStatesPending.push();
    RawState* next = &mRawStatesPending.editTop();
    next->clear();
    next->when = when;

...
    syncTouch(when, next);
    // Assign pointer ids.
    if (!mHavePointerIds) {
        assignPointerIds(last, next);
    }
    processRawTouches(false /*timeout*/);
}

```
这个过程中可以看到首先为mRawStatesPending集合中添加一个RawState对象记录当前输入事件触发的时间。

接下来分发可以分为两个步骤：
- syncTouch 为当前的RawState对象进行初始化赋值。如果是单点触碰则调用SingleTouchInputMapper的syncTouch，如果是多点触控则是调用MultiTouchInputMapper的syncTouch。最关键的地方是为RawState记录了当前有多少个点击事件被触发了。
- assignPointerIds 为需要分发的事件类型添加标志位
- processRawTouches 分发根据assignPointerIds打上输入事件类型以及对应次数进行分发。

要弄懂整个读取触控事件的读取，我们需要来了解几个比较重要的对象，他们是作为触点传输数据的承载体。
```cpp
    struct RawState {
        nsecs_t when;
        uint32_t deviceTimestamp;

        // Raw pointer sample data.
        RawPointerData rawPointerData;

        int32_t buttonState;

        // Scroll state.
        int32_t rawVScroll;
        int32_t rawHScroll;

...
    };
```
首先看看RawState代表需要被消费的触点事件状态，里面保存了：
- when 当前触发的时机
- RawPointerData 代表当前触点的类型，距离，次数等
- buttonState button的状态
- 横竖滑动的状态

其中最为关键的是RawPointerData对象，只要弄懂这个对象就知道InputReader是和管理从驱动来的触点数据了：
```cpp
struct RawPointerData {
    struct Pointer {
        uint32_t id;
        int32_t x;
        int32_t y;
        int32_t pressure;
        int32_t touchMajor;
        int32_t touchMinor;
        int32_t toolMajor;
        int32_t toolMinor;
        int32_t orientation;
        int32_t distance;
        int32_t tiltX;
        int32_t tiltY;
        int32_t toolType; // a fully decoded AMOTION_EVENT_TOOL_TYPE constant
        bool isHovering;
    };

    uint32_t pointerCount;
    Pointer pointers[MAX_POINTERS];
    BitSet32 hoveringIdBits, touchingIdBits;
    uint32_t idToIndex[MAX_POINTER_ID + 1];

    RawPointerData();
    void clear();
    void copyFrom(const RawPointerData& other);
    void getCentroidOfTouchingPointers(float* outX, float* outY) const;

    inline void markIdBit(uint32_t id, bool isHovering) {
        if (isHovering) {
            hoveringIdBits.markBit(id);
        } else {
            touchingIdBits.markBit(id);
        }
    }

    inline void clearIdBits() {
        hoveringIdBits.clear();
        touchingIdBits.clear();
    }

    inline const Pointer& pointerForId(uint32_t id) const {
        return pointers[idToIndex[id]];
    }

    inline bool isHovering(uint32_t pointerIndex) {
        return pointers[pointerIndex].isHovering;
    }
};
```
在RawPointerData结构体中：
- 1.Pointer结构体记录了所有触点在x，y轴上对应的位置，与上一次触点之间距离等关键信息。
- 2.pointerCount 记录了当前有多少个触点同时被驱动抛出需要处理
- 3.pointers数组记录了从驱动返回所有需要处理Pointer
- 4.hoveringIdBits 是指当前的Pointer是Hover状态对应的状态位
- 5.touchingIdBits 是指当前的Pointer是触碰分发对应的状态位。
- 6.idToIndex 数组

最后三个对象做的是什么事情呢？需要结合下面这段代码才能彻底明白。hoveringIdBits和touchingIdBits都是BitSet32对象。BitSet32这个对象实际上一个对32位int类型的操作。可以快速的知道32位中哪些位数已经设置为1和0，一般用于快速记录状态的辅助工具。

方法markIdBit实际上就是根据当前的触点类型进行判断，是否是hover类型，是则把hoveringIdBits32位的记录表中对应位置设置位1.不是则touchingIdBits对应位置设置为1.

idToIndex这个对象实际上是用来链接touchingIdBits/touchingIdBits只每一位与pointers数组下标的一个中间键。

换句话说可以通过touchingIdBits中的位数找到pointers数组中的Pointer。

来看看assignPointerIds都做了什么。

###### assignPointerIds
```cpp
void TouchInputMapper::assignPointerIds(const RawState* last, RawState* current) {
    uint32_t currentPointerCount = current->rawPointerData.pointerCount;
    uint32_t lastPointerCount = last->rawPointerData.pointerCount;

    current->rawPointerData.clearIdBits();

    if (currentPointerCount == 0) {
        return;
    }

    if (lastPointerCount == 0) {
// 关键事件1
        for (uint32_t i = 0; i < currentPointerCount; i++) {
            uint32_t id = i;
            current->rawPointerData.pointers[i].id = id;
            current->rawPointerData.idToIndex[id] = i;
            current->rawPointerData.markIdBit(id, current->rawPointerData.isHovering(i));
        }
        return;
    }
// 关键事件2
    if (currentPointerCount == 1 && lastPointerCount == 1
            && current->rawPointerData.pointers[0].toolType
                    == last->rawPointerData.pointers[0].toolType) {
        uint32_t id = last->rawPointerData.pointers[0].id;
        current->rawPointerData.pointers[0].id = id;
        current->rawPointerData.idToIndex[id] = 0;
        current->rawPointerData.markIdBit(id, current->rawPointerData.isHovering(0));
        return;
    }


    PointerDistanceHeapElement heap[MAX_POINTERS * MAX_POINTERS];
// 关键事件3
    uint32_t heapSize = 0;
    for (uint32_t currentPointerIndex = 0; currentPointerIndex < currentPointerCount;
            currentPointerIndex++) {
        for (uint32_t lastPointerIndex = 0; lastPointerIndex < lastPointerCount;
                lastPointerIndex++) {
            const RawPointerData::Pointer& currentPointer =
                    current->rawPointerData.pointers[currentPointerIndex];
            const RawPointerData::Pointer& lastPointer =
                    last->rawPointerData.pointers[lastPointerIndex];
            if (currentPointer.toolType == lastPointer.toolType) {
                int64_t deltaX = currentPointer.x - lastPointer.x;
                int64_t deltaY = currentPointer.y - lastPointer.y;

                uint64_t distance = uint64_t(deltaX * deltaX + deltaY * deltaY);
                heap[heapSize].currentPointerIndex = currentPointerIndex;
                heap[heapSize].lastPointerIndex = lastPointerIndex;
                heap[heapSize].distance = distance;
                heapSize += 1;
            }
        }
    }
// 关键事件4
    for (uint32_t startIndex = heapSize / 2; startIndex != 0; ) {
        startIndex -= 1;
        for (uint32_t parentIndex = startIndex; ;) {
            uint32_t childIndex = parentIndex * 2 + 1;
            if (childIndex >= heapSize) {
                break;
            }

            if (childIndex + 1 < heapSize
                    && heap[childIndex + 1].distance < heap[childIndex].distance) {
                childIndex += 1;
            }

            if (heap[parentIndex].distance <= heap[childIndex].distance) {
                break;
            }

            swap(heap[parentIndex], heap[childIndex]);
            parentIndex = childIndex;
        }
    }
// 关键事件5
    BitSet32 matchedLastBits(0);
    BitSet32 matchedCurrentBits(0);
    BitSet32 usedIdBits(0);
    bool first = true;
    for (uint32_t i = min(currentPointerCount, lastPointerCount); heapSize > 0 && i > 0; i--) {
        while (heapSize > 0) {
            if (first) {

                first = false;
            } else {

                heap[0] = heap[heapSize];
                for (uint32_t parentIndex = 0; ;) {
                    uint32_t childIndex = parentIndex * 2 + 1;
                    if (childIndex >= heapSize) {
                        break;
                    }

                    if (childIndex + 1 < heapSize
                            && heap[childIndex + 1].distance < heap[childIndex].distance) {
                        childIndex += 1;
                    }

                    if (heap[parentIndex].distance <= heap[childIndex].distance) {
                        break;
                    }

                    swap(heap[parentIndex], heap[childIndex]);
                    parentIndex = childIndex;
                }

            }

            heapSize -= 1;

            uint32_t currentPointerIndex = heap[0].currentPointerIndex;
            if (matchedCurrentBits.hasBit(currentPointerIndex)) continue; // already matched

            uint32_t lastPointerIndex = heap[0].lastPointerIndex;
            if (matchedLastBits.hasBit(lastPointerIndex)) continue; // already matched

            matchedCurrentBits.markBit(currentPointerIndex);
            matchedLastBits.markBit(lastPointerIndex);

            uint32_t id = last->rawPointerData.pointers[lastPointerIndex].id;
            current->rawPointerData.pointers[currentPointerIndex].id = id;
            current->rawPointerData.idToIndex[id] = currentPointerIndex;
            current->rawPointerData.markIdBit(id,
                    current->rawPointerData.isHovering(currentPointerIndex));
            usedIdBits.markBit(id);

            break;
        }
    }

// 关键事件6
    for (uint32_t i = currentPointerCount - matchedCurrentBits.count(); i != 0; i--) {
        uint32_t currentPointerIndex = matchedCurrentBits.markFirstUnmarkedBit();
        uint32_t id = usedIdBits.markFirstUnmarkedBit();

        current->rawPointerData.pointers[currentPointerIndex].id = id;
        current->rawPointerData.idToIndex[id] = currentPointerIndex;
        current->rawPointerData.markIdBit(id,
                current->rawPointerData.isHovering(currentPointerIndex));
    }
}
```
首先获取上一次触点状态和本次准备下发的触点对象。本次准备下发的触点对象将会以上次的为基准进行处理。

之后这段代码逻辑可以切分为6个部分：
- 1.如果上一次触点次数为0，说明这是第一次发生了触点分发。那么还会循环所有的触点个数，pointers数组中Pointer的id的就是对应当前遍历的下标，并且通过markIdBit在对应下标的位置在touch。

- 2.如果当前只有一个触点事件，且上一次的的触点事件为0.那么pointers第0号位置的Pointer对象中id为0，idToIndex第0个位置的也为0.

- 3.遍历当前每一个从驱动返回的Pointer结构体，和上一次触点分发的对应Pointer，计算每一个Pointer之间的欧式距离(euclidean distances)也就是两点之间的距离，保存到一个heap的数组中。这个heap数组最大为16*16 = 256个。

- 4.通过类似小顶堆排序，从heap中选取欧式距离最小的Pointer对象到heap数组的0号位置上

- 5.下面的大循环实际上就是每一次选取一个最小的欧式距离到heap的0号位置中，每一次准备添加到rawPointerData之前都会判断这样个id对应的Pointer是否添加了，如果添加了则跳出当前的触点。

- 6.在第五步骤中已经保存好了需要进行分发的触点，剩下的触点对应在IdBits中的位置都设置为0.

![需要分发输入事件模型.png](/images/需要分发输入事件模型.png)

为什么要做欧式距离的计算呢？我们还记得Android有一种多点触控的手势处理，里面可以根据不同的触点id来跟踪不同手指的触碰轨迹和行为。

那是怎么区分的每一个手指的呢？实际上Android中的驱动根本不会记录当前的手指对应的轨迹，只是简单的把每一个触碰的坐标抛出来处理。由于这个过程很快，所以Android可以把每一个坐标和上次最近的坐标看成同一个手指的轨迹。

如下图：
![触点轨迹计算.png](/images/触点轨迹计算.png)


##### processRawTouches
```cpp
void TouchInputMapper::processRawTouches(bool timeout) {
...
    const size_t N = mRawStatesPending.size();
    size_t count;
    for(count = 0; count < N; count++) {
        const RawState& next = mRawStatesPending[count];

        if (assignExternalStylusId(next, timeout)) {
            break;
        }
        clearStylusDataPendingFlags();
        mCurrentRawState.copyFrom(next);
        if (mCurrentRawState.when < mLastRawState.when) {
            mCurrentRawState.when = mLastRawState.when;
        }
        cookAndDispatch(mCurrentRawState.when);
    }
    if (count != 0) {
        mRawStatesPending.removeItemsAt(0, count);
    }

....
}
```

接着调用processRawTouches，在这个方法中会遍历mRawStatesPending这个集合中RawState对象。判断上一次最晚的触点触发事件，让待处理的输入事件时间比这个时间点都更新成这个时间。cookAndDispatch开始分发事件。

###### cookAndDispatch
首先介绍一下每一个InputMapper在初始化阶段，都会进行一次配置设置，并且把对应设备的模式保存到mDeviceMode中，定义的类型如下：
```cpp
    enum DeviceMode {
        DEVICE_MODE_DISABLED, // 输入禁止
        DEVICE_MODE_DIRECT, // 直接映射 (触屏模式)
        DEVICE_MODE_UNSCALED, // 无缩放映射 (touchpad)
        DEVICE_MODE_NAVIGATION, // 辅助的手势的无缩放触屏 (导航)
        DEVICE_MODE_POINTER, // pointer mapping (pointer)
    };
```
- DEVICE_MODE_DISABLED 输入禁止
- DEVICE_MODE_DIRECT 直接映射 (触屏模式)
-  DEVICE_MODE_UNSCALED 无缩放映射触摸(触摸板)
- DEVICE_MODE_NAVIGATION 辅助的手势的无缩放触屏 (导航)
- DEVICE_MODE_POINTER 非主要手指多点触摸

实际上在这个过程中DEVICE_MODE_DIRECT容易和DEVICE_MODE_POINTER弄混淆。DEVICE_MODE_DIRECT这个可以看成MotionEvent中的ACTION_DOWN和ACTION_POINTER_DOWN之间的区别。

前者是单点触摸的模式，后者是运用于多点触摸的模式。

这里我们只讨论单点触碰的逻辑，有兴趣的读者可以自行阅读多点触碰的逻辑。
```cpp
void TouchInputMapper::cookAndDispatch(nsecs_t when) {
....
    if (mDeviceMode == DEVICE_MODE_POINTER) {
      ...
    } else {
        if (mDeviceMode == DEVICE_MODE_DIRECT
                && mConfig.showTouches && mPointerController != NULL) {
            mPointerController->setPresentation(PointerControllerInterface::PRESENTATION_SPOT);
            mPointerController->fade(PointerControllerInterface::TRANSITION_GRADUAL);

            mPointerController->setButtonState(mCurrentRawState.buttonState);
            mPointerController->setSpots(mCurrentCookedState.cookedPointerData.pointerCoords,
                    mCurrentCookedState.cookedPointerData.idToIndex,
                    mCurrentCookedState.cookedPointerData.touchingIdBits);
        }

        if (!mCurrentMotionAborted) {
            dispatchButtonRelease(when, policyFlags);
            dispatchHoverExit(when, policyFlags);
            dispatchTouches(when, policyFlags);
            dispatchHoverEnterAndMove(when, policyFlags);
            dispatchButtonPress(when, policyFlags);
        }

        if (mCurrentCookedState.cookedPointerData.pointerCount == 0) {
            mCurrentMotionAborted = false;
        }
    }

    synthesizeButtonKeys(getContext(), AKEY_EVENT_ACTION_UP, when, getDeviceId(), mSource,
            policyFlags, mLastCookedState.buttonState, mCurrentCookedState.buttonState);

    mCurrentRawState.rawVScroll = 0;
    mCurrentRawState.rawHScroll = 0;

    mLastRawState.copyFrom(mCurrentRawState);
    mLastCookedState.copyFrom(mCurrentCookedState);
}
```
在这个过程中核心的步骤就判断mDeviceMode是DEVICE_MODE_DIRECT中：
- 1.首先设置好mPointerController中的状态,如果有关于button或者手势的hover相关状态(也就是鼠标移动某一个字体上变色的情况)也会保存。
- 2.dispatchButtonRelease尝试释放button状态，分发ACTION_BUTTON_RELEASE触点模式的输入事件
- 3.dispatchHoverExit 尝试释放hover状态，分发ACTION_HOVER_EXIT触点模式的输入事件
- 4.dispatchTouches 根据情况分发单点触碰输入事件
- 5.dispatchHoverEnterAndMove 根据情况是分发ACTION_HOVER_ENTER还是ACTION_HOVER_MOVE的触点
- 6.dispatchButtonPress 尝试分发ACTION_BUTTON_PRESS。

接下来只讨论dispatchTouches单个触点的ACTION_DOWN事件。

###### dispatchTouches
```cpp
void TouchInputMapper::dispatchTouches(nsecs_t when, uint32_t policyFlags) {
    BitSet32 currentIdBits = mCurrentCookedState.cookedPointerData.touchingIdBits;
    BitSet32 lastIdBits = mLastCookedState.cookedPointerData.touchingIdBits;
    int32_t metaState = getContext()->getGlobalMetaState();
    int32_t buttonState = mCurrentCookedState.buttonState;

    if (currentIdBits == lastIdBits) {
        if (!currentIdBits.isEmpty()) {

            dispatchMotion(when, policyFlags, mSource,
                    AMOTION_EVENT_ACTION_MOVE, 0, 0, metaState, buttonState,
                    AMOTION_EVENT_EDGE_FLAG_NONE,
                    mCurrentCookedState.deviceTimestamp,
                    mCurrentCookedState.cookedPointerData.pointerProperties,
                    mCurrentCookedState.cookedPointerData.pointerCoords,
                    mCurrentCookedState.cookedPointerData.idToIndex,
                    currentIdBits, -1,
                    mOrientedXPrecision, mOrientedYPrecision, mDownTime);
        }
    } else {

        BitSet32 upIdBits(lastIdBits.value & ~currentIdBits.value);
        BitSet32 downIdBits(currentIdBits.value & ~lastIdBits.value);
        BitSet32 moveIdBits(lastIdBits.value & currentIdBits.value);
        BitSet32 dispatchedIdBits(lastIdBits.value);

        bool moveNeeded = updateMovedPointers(
                mCurrentCookedState.cookedPointerData.pointerProperties,
                mCurrentCookedState.cookedPointerData.pointerCoords,
                mCurrentCookedState.cookedPointerData.idToIndex,
                mLastCookedState.cookedPointerData.pointerProperties,
                mLastCookedState.cookedPointerData.pointerCoords,
                mLastCookedState.cookedPointerData.idToIndex,
                moveIdBits);
        if (buttonState != mLastCookedState.buttonState) {
            moveNeeded = true;
        }


        while (!upIdBits.isEmpty()) {
            uint32_t upId = upIdBits.clearFirstMarkedBit();

            dispatchMotion(when, policyFlags, mSource,
                    AMOTION_EVENT_ACTION_POINTER_UP, 0, 0, metaState, buttonState, 0,
                    mCurrentCookedState.deviceTimestamp,
                    mLastCookedState.cookedPointerData.pointerProperties,
                    mLastCookedState.cookedPointerData.pointerCoords,
                    mLastCookedState.cookedPointerData.idToIndex,
                    dispatchedIdBits, upId, mOrientedXPrecision, mOrientedYPrecision, mDownTime);
            dispatchedIdBits.clearBit(upId);
        }

        if (moveNeeded && !moveIdBits.isEmpty()) {
            ALOG_ASSERT(moveIdBits.value == dispatchedIdBits.value);
            dispatchMotion(when, policyFlags, mSource,
                    AMOTION_EVENT_ACTION_MOVE, 0, 0, metaState, buttonState, 0,
                    mCurrentCookedState.deviceTimestamp,
                    mCurrentCookedState.cookedPointerData.pointerProperties,
                    mCurrentCookedState.cookedPointerData.pointerCoords,
                    mCurrentCookedState.cookedPointerData.idToIndex,
                    dispatchedIdBits, -1, mOrientedXPrecision, mOrientedYPrecision, mDownTime);
        }


        while (!downIdBits.isEmpty()) {
            uint32_t downId = downIdBits.clearFirstMarkedBit();
            dispatchedIdBits.markBit(downId);

            if (dispatchedIdBits.count() == 1) {
                mDownTime = when;
            }

            dispatchMotion(when, policyFlags, mSource,
                    AMOTION_EVENT_ACTION_POINTER_DOWN, 0, 0, metaState, buttonState, 0,
                    mCurrentCookedState.deviceTimestamp,
                    mCurrentCookedState.cookedPointerData.pointerProperties,
                    mCurrentCookedState.cookedPointerData.pointerCoords,
                    mCurrentCookedState.cookedPointerData.idToIndex,
                    dispatchedIdBits, downId, mOrientedXPrecision, mOrientedYPrecision, mDownTime);
        }
    }
}
```
currentIdBits是指当前通过assignPointerId分配好需要分发触点事件的index集合。lastIdBits则是指上一次保存下来已经分发的触点事件
核心分发逻辑如下：
- 1.如果发现lastIdBits和currentIdBits大小一致，说明触点没有变动直接通过dispatchMotion分发输入事件。
- 2.如果发现不同，则会根据lastIdBits和currentIdBits之间的差异生成如下几个对象：upIdBits(手势抬起)，downIdBits(手势下按)，moveIdBits（移动手势）。

这三个手势是怎么计算的呢？抬起的手势说明本次对应的分发触点位置比起上一次触点位置发生了消失，说明该id对应的手势抬起了。如果上一次的位置不存在但是本次对应位置的触点位置下出现了新的Pointer则说明已经按下了新的手势。如果上次和本次还是一致的说明很可能是移动的。

如下图：
![输入事件检查模型.png](/images/输入事件检查模型.png)

- 3.downIdBits计算出来不是0，说明有下按的事件触发了，就调用dispatchMotion。同理抬起手势和移动就是检查upIdBits和moveIdBits。当下按需要处理则更新dispatchedIdBits，而dispatchedIdBits的内容实际上就是lastIdBits对象。



###### dispatchMotion
```cpp
void TouchInputMapper::dispatchMotion(nsecs_t when, uint32_t policyFlags, uint32_t source,
        int32_t action, int32_t actionButton, int32_t flags,
        int32_t metaState, int32_t buttonState, int32_t edgeFlags, uint32_t deviceTimestamp,
        const PointerProperties* properties, const PointerCoords* coords,
        const uint32_t* idToIndex, BitSet32 idBits, int32_t changedId,
        float xPrecision, float yPrecision, nsecs_t downTime) {
    PointerCoords pointerCoords[MAX_POINTERS];
    PointerProperties pointerProperties[MAX_POINTERS];
    uint32_t pointerCount = 0;
    while (!idBits.isEmpty()) {
        uint32_t id = idBits.clearFirstMarkedBit();
        uint32_t index = idToIndex[id];
        pointerProperties[pointerCount].copyFrom(properties[index]);
        pointerCoords[pointerCount].copyFrom(coords[index]);

        if (changedId >= 0 && id == uint32_t(changedId)) {
            action |= pointerCount << AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
        }

        pointerCount += 1;
    }

    ALOG_ASSERT(pointerCount != 0);

    if (changedId >= 0 && pointerCount == 1) {
        if (action == AMOTION_EVENT_ACTION_POINTER_DOWN) {
            action = AMOTION_EVENT_ACTION_DOWN;
        } else if (action == AMOTION_EVENT_ACTION_POINTER_UP) {
            action = AMOTION_EVENT_ACTION_UP;
        } else {
            // Can't happen.
            ALOG_ASSERT(false);
        }
    }

    NotifyMotionArgs args(when, getDeviceId(), source, policyFlags,
            action, actionButton, flags, metaState, buttonState, edgeFlags,
            mViewport.displayId, deviceTimestamp, pointerCount, pointerProperties, pointerCoords,
            xPrecision, yPrecision, downTime);
    getListener()->notifyMotion(&args);
}
```
在这个过程中会通过idToIndex数组反向查找Pointer中对应的坐标并且保存起来。如果判断到当前的触点只有一个，并且发生了变化。就算是进行了多点触控的事件AMOTION_EVENT_ACTION_POINTER_DOWN也会强制转化为单点触控的事件AMOTION_EVENT_ACTION_DOWN。

接着调用InputDispatcher的notifyMotion，把触控事件分发出去。


InputReader的初始化已经了解，我们去看看InputDispatcherThread的初始化。


### InputDispatcherThread threadLoop
```cpp
bool InputDispatcherThread::threadLoop() {
    mDispatcher->dispatchOnce();
    return true;
}
```

```cpp
void InputDispatcher::dispatchOnce() {
    nsecs_t nextWakeupTime = LONG_LONG_MAX;
    { 
        AutoMutex _l(mLock);
        mDispatcherIsAliveCondition.broadcast();

        if (!haveCommandsLocked()) {
            dispatchOnceInnerLocked(&nextWakeupTime);
        }

        if (runCommandsLockedInterruptible()) {
            nextWakeupTime = LONG_LONG_MIN;
        }
    } 

    nsecs_t currentTime = now();
    int timeoutMillis = toMillisecondTimeoutDelay(currentTime, nextWakeupTime);
    mLooper->pollOnce(timeoutMillis);
}
```
执行如下的逻辑：
- 1.haveCommandsLocked会判断mCommandQueue命令队列是否可以被消费命令，可以则调用dispatchOnceInnerLocked消费命令队列中需要分发输入事件。

- 2.runCommandsLockedInterruptible 删除所有mCommandQueue 中的命令。这些命令队列中的命令已经在dispatchOnceInnerLocked中被消费完毕了。

- 3.mLooper调用pollOnce等待下一次的Looper的唤醒。

那么命令队列中的命令是从哪里来的呢？实际上就是从InputReader调用notifyMotion和notifyKey而来的。

先让我们看看这两个方法中的核心逻辑。

### InputDispatcher分发原理
```cpp
void InputDispatcher::notifyKey(const NotifyKeyArgs* args) {
....
    KeyEvent event;
    event.initialize(args->deviceId, args->source, args->action,
            flags, keyCode, args->scanCode, metaState, 0,
            args->downTime, args->eventTime);

    android::base::Timer t;
    mPolicy->interceptKeyBeforeQueueing(&event, /*byref*/ policyFlags);
...
    bool needWake;
    { // acquire lock
        mLock.lock();

        if (shouldSendKeyToInputFilterLocked(args)) {
            mLock.unlock();

            policyFlags |= POLICY_FLAG_FILTERED;
            if (!mPolicy->filterInputEvent(&event, policyFlags)) {
                return; // event was consumed by the filter
            }

            mLock.lock();
        }

        int32_t repeatCount = 0;
        KeyEntry* newEntry = new KeyEntry(args->eventTime,
                args->deviceId, args->source, policyFlags,
                args->action, flags, keyCode, args->scanCode,
                metaState, repeatCount, args->downTime);

        needWake = enqueueInboundEventLocked(newEntry);
        mLock.unlock();
    } // release lock

    if (needWake) {
        mLooper->wake();
    }
}
```
再来看看notifyMotion中做了什么？

#### notifyMotion
```cpp
void InputDispatcher::notifyMotion(const NotifyMotionArgs* args) {
...
    android::base::Timer t;
    mPolicy->interceptMotionBeforeQueueing(args->eventTime, /*byref*/ policyFlags);
    if (t.duration() > SLOW_INTERCEPTION_THRESHOLD) {
...
    }
    bool needWake;
    { // acquire lock
        mLock.lock();

        if (shouldSendMotionToInputFilterLocked(args)) {
            mLock.unlock();

            MotionEvent event;
            event.initialize(args->deviceId, args->source, args->action, args->actionButton,
                    args->flags, args->edgeFlags, args->metaState, args->buttonState,
                    0, 0, args->xPrecision, args->yPrecision,
                    args->downTime, args->eventTime,
                    args->pointerCount, args->pointerProperties, args->pointerCoords);

            policyFlags |= POLICY_FLAG_FILTERED;
            if (!mPolicy->filterInputEvent(&event, policyFlags)) {
                return; // event was consumed by the filter
            }

            mLock.lock();
        }

        // Just enqueue a new motion event.
        MotionEntry* newEntry = new MotionEntry(args->eventTime,
                args->deviceId, args->source, policyFlags,
                args->action, args->actionButton, args->flags,
                args->metaState, args->buttonState,
                args->edgeFlags, args->xPrecision, args->yPrecision, args->downTime,
                args->displayId,
                args->pointerCount, args->pointerProperties, args->pointerCoords, 0, 0);

        needWake = enqueueInboundEventLocked(newEntry);
        mLock.unlock();
    } // release lock

    if (needWake) {
        mLooper->wake();
    }
}
```

能看到这两个方法中实际上很简单：
- 1.初始化需要分发的对象MotionEntry或者KeyEntry
- 2.interceptMotionBeforeQueueing/interceptKeyBeforeQueueing 进行发送前的处理。
- 2.enqueueInboundEventLocked 把这两种Entry通过enqueueInboundEventLocked放到命令队列中准备被消费
- 3.mLooper 调用wake方法，解开pollOnce的阻塞方法对命令队列进行消费。

让我们看看enqueueInboundEventLocked中做了什么。

#### enqueueInboundEventLocked
```cpp
bool InputDispatcher::enqueueInboundEventLocked(EventEntry* entry) {
    bool needWake = mInboundQueue.isEmpty();
    mInboundQueue.enqueueAtTail(entry);
...
    }

    return needWake;
}
```
能看到实际上把entry都添加到mInboundQueue 队列的末尾，等待消费。

那么我们来看看InputDispatcher是怎么消费的。


##### dispatchOnceInnerLocked 消费输入事件
```cpp
void InputDispatcher::dispatchOnceInnerLocked(nsecs_t* nextWakeupTime) {
    nsecs_t currentTime = now();

....

    bool isAppSwitchDue = mAppSwitchDueTime <= currentTime;
    if (mAppSwitchDueTime < *nextWakeupTime) {
        *nextWakeupTime = mAppSwitchDueTime;
    }


    if (! mPendingEvent) {
        if (mInboundQueue.isEmpty()) {
...
        } else {
            mPendingEvent = mInboundQueue.dequeueAtHead();
        }


        if (mPendingEvent->policyFlags & POLICY_FLAG_PASS_TO_USER) {
            pokeUserActivityLocked(mPendingEvent);
        }

        resetANRTimeoutsLocked();
    }


    bool done = false;
...
    switch (mPendingEvent->type) {
    case EventEntry::TYPE_CONFIGURATION_CHANGED: {
...
        break;
    }

    case EventEntry::TYPE_DEVICE_RESET: {
...
        break;
    }

    case EventEntry::TYPE_KEY: {
        KeyEntry* typedEntry = static_cast<KeyEntry*>(mPendingEvent);
...
        done = dispatchKeyLocked(currentTime, typedEntry, &dropReason, nextWakeupTime);
        break;
    }

    case EventEntry::TYPE_MOTION: {
        MotionEntry* typedEntry = static_cast<MotionEntry*>(mPendingEvent);
...
        done = dispatchMotionLocked(currentTime, typedEntry,
                &dropReason, nextWakeupTime);
        break;
    }

    default:
        break;
    }

    if (done) {
...
        releasePendingEventLocked();
        *nextWakeupTime = LONG_LONG_MIN;  // force next poll to wake up immediately
    }
}
```
过程如下：
- 1.mInboundQueue 队列获取队列头进行处理，并且调用resetANRTimeoutsLocked重新刷新ANR的触点超时计数，超时事件就是如下定义：
```cpp
constexpr nsecs_t DEFAULT_INPUT_DISPATCHING_TIMEOUT = 5000 * 1000000LL; // 5 sec
```
- 2.如果当前的key类型事件则调用dispatchKeyLocked进行分发
- 3.如果当前是motion类型事件则调用dispatchMotionLocked进行分发。

我们先来看看dispatchKeyLocked中的核心逻辑。

###### dispatchKeyLocked
```cpp
bool InputDispatcher::dispatchKeyLocked(nsecs_t currentTime, KeyEntry* entry,
        DropReason* dropReason, nsecs_t* nextWakeupTime) {
....
    Vector<InputTarget> inputTargets;
    int32_t injectionResult = findFocusedWindowTargetsLocked(currentTime,
            entry, inputTargets, nextWakeupTime);
...

    dispatchEventLocked(currentTime, entry, inputTargets);
    return true;
}
```

核心步骤有两个：
- 1.findFocusedWindowTargetsLocked 校验当前聚焦的窗口，并且把句柄保存到inputTargets中，保证触点事件分发到聚焦的窗口上
- 2.dispatchEventLocked 开始分发事件到目标窗体中。

同理在分发Motion也是相似的过程。我们来看看如何找到聚焦的窗体呢？

###### findFocusedWindowTargetsLocked 查找聚集窗体
```cpp
int32_t InputDispatcher::findFocusedWindowTargetsLocked(nsecs_t currentTime,
        const EventEntry* entry, Vector<InputTarget>& inputTargets, nsecs_t* nextWakeupTime) {
    int32_t injectionResult;
    std::string reason;
...

...

    // Success!  Output targets.
    injectionResult = INPUT_EVENT_INJECTION_SUCCEEDED;
    addWindowTargetLocked(mFocusedWindowHandle,
            InputTarget::FLAG_FOREGROUND | InputTarget::FLAG_DISPATCH_AS_IS, BitSet32(0),
            inputTargets);

    // Done.
Failed:
Unresponsive:
...
    return injectionResult;
}
```
核心方法只有一个，那就是获取mFocusedWindowHandle 保存在InputDispatcher的全局焦点对象，并且调用addWindowTargetLocked 把当前的聚焦对象保存到inputTargets集合中。

这样下发的时候，inputTargets就保存了当前聚焦的窗体。那么mFocusedWindowHandle是什么时候设置的呢？实际上就是通过InputDispatcher的setInputWindow。

setInputWindow是由InputMonitor进行控制的，这个对象关闭了发送的通信，只能意味的接受事件。在这个过程中是作为IMS全局状态的监听器。而每当窗体大小，层级结构等属性发生变化，则会通过InputMonitor.updateInputWindowsLw对焦点窗口进行刷新。

###### dispatchEventLocked
```cpp
void InputDispatcher::dispatchEventLocked(nsecs_t currentTime,
        EventEntry* eventEntry, const Vector<InputTarget>& inputTargets) {
//PowerManagerService 记录耗电的节点
    pokeUserActivityLocked(eventEntry);

    for (size_t i = 0; i < inputTargets.size(); i++) {
        const InputTarget& inputTarget = inputTargets.itemAt(i);

        ssize_t connectionIndex = getConnectionIndexLocked(inputTarget.inputChannel);
        if (connectionIndex >= 0) {
            sp<Connection> connection = mConnectionsByFd.valueAt(connectionIndex);
            prepareDispatchCycleLocked(currentTime, connection, eventEntry, &inputTarget);
        } else {
...
        }
    }
}

ssize_t InputDispatcher::getConnectionIndexLocked(const sp<InputChannel>& inputChannel) {
    ssize_t connectionIndex = mConnectionsByFd.indexOfKey(inputChannel->getFd());
    if (connectionIndex >= 0) {
        sp<Connection> connection = mConnectionsByFd.valueAt(connectionIndex);
        if (connection->inputChannel.get() == inputChannel.get()) {
            return connectionIndex;
        }
    }

    return -1;
}
```
通过InputChannel的fd反向寻找在mConnectionsByFd的中Connection的下标。还记得mConnectionsByFd这个集合，里面保存了以fd为下标，Connection为内容。就是是由上文的registerInputChannel进行注册的。


接着调用Connection的prepareDispatchCycleLocked对每一个注册进IMS的窗体进行分发。关于如何注册IMS的，后文会和大家聊聊。


###### prepareDispatchCycleLocked
```cpp
void InputDispatcher::prepareDispatchCycleLocked(nsecs_t currentTime,
        const sp<Connection>& connection, EventEntry* eventEntry, const InputTarget* inputTarget) {
...

    // Not splitting.  Enqueue dispatch entries for the event as is.
    enqueueDispatchEntriesLocked(currentTime, connection, eventEntry, inputTarget);
}
```

```cpp
void InputDispatcher::enqueueDispatchEntriesLocked(nsecs_t currentTime,
        const sp<Connection>& connection, EventEntry* eventEntry, const InputTarget* inputTarget) {
...
    if (wasEmpty && !connection->outboundQueue.isEmpty()) {
        startDispatchCycleLocked(currentTime, connection);
    }
}
```
这个方法最后通过startDispatchCycleLocked区分输入事件类型分发。

###### startDispatchCycleLocked
```cpp
void InputDispatcher::startDispatchCycleLocked(nsecs_t currentTime,
        const sp<Connection>& connection) {

    while (connection->status == Connection::STATUS_NORMAL
            && !connection->outboundQueue.isEmpty()) {
        DispatchEntry* dispatchEntry = connection->outboundQueue.head;
        dispatchEntry->deliveryTime = currentTime;

        // Publish the event.
        status_t status;
        EventEntry* eventEntry = dispatchEntry->eventEntry;
        switch (eventEntry->type) {
        case EventEntry::TYPE_KEY: {
            KeyEntry* keyEntry = static_cast<KeyEntry*>(eventEntry);

            status = connection->inputPublisher.publishKeyEvent(dispatchEntry->seq,
                    keyEntry->deviceId, keyEntry->source,
                    dispatchEntry->resolvedAction, dispatchEntry->resolvedFlags,
                    keyEntry->keyCode, keyEntry->scanCode,
                    keyEntry->metaState, keyEntry->repeatCount, keyEntry->downTime,
                    keyEntry->eventTime);
            break;
        }

        case EventEntry::TYPE_MOTION: {
            MotionEntry* motionEntry = static_cast<MotionEntry*>(eventEntry);
...

            status = connection->inputPublisher.publishMotionEvent(dispatchEntry->seq,
                    motionEntry->deviceId, motionEntry->source, motionEntry->displayId,
                    dispatchEntry->resolvedAction, motionEntry->actionButton,
                    dispatchEntry->resolvedFlags, motionEntry->edgeFlags,
                    motionEntry->metaState, motionEntry->buttonState,
                    xOffset, yOffset, motionEntry->xPrecision, motionEntry->yPrecision,
                    motionEntry->downTime, motionEntry->eventTime,
                    motionEntry->pointerCount, motionEntry->pointerProperties,
                    usingCoords);
            break;
        }

        default:
            return;
        }


        if (status) {
            if (status == WOULD_BLOCK) {
                if (connection->waitQueue.isEmpty()) {
...
                    abortBrokenDispatchCycleLocked(currentTime, connection, true /*notify*/);
                } else {
...
                    connection->inputPublisherBlocked = true;
                }
            } else {
...
            }
            return;
        }

        // Re-enqueue the event on the wait queue.
        connection->outboundQueue.dequeue(dispatchEntry);
        traceOutboundQueueLengthLocked(connection);
        connection->waitQueue.enqueueAtTail(dispatchEntry);
        traceWaitQueueLengthLocked(connection);
    }
}
```
- 1.根据当前的类型，如果是key，则调用InputPublisher的publishKeyEvent进行分发。如果是motion，则调用InputPublisher的publishMotionEvent进行分发。

InputPublisher实际上就是Connection初始化时候，实例化并且包含InputChannel对象。

- 2.从Connection的outboundQueue移除顶部的分发事件，放到Connection的waitQueue中。


###### InputPublisher 通过InputChannel的socket接口发送输入事件
```cpp
status_t InputPublisher::publishKeyEvent(
        uint32_t seq,
        int32_t deviceId,
        int32_t source,
        int32_t action,
        int32_t flags,
        int32_t keyCode,
        int32_t scanCode,
        int32_t metaState,
        int32_t repeatCount,
        nsecs_t downTime,
        nsecs_t eventTime) {
...
    return mChannel->sendMessage(&msg);
}

status_t InputPublisher::publishMotionEvent(
        uint32_t seq,
        int32_t deviceId,
        int32_t source,
        int32_t displayId,
        int32_t action,
        int32_t actionButton,
        int32_t flags,
        int32_t edgeFlags,
        int32_t metaState,
        int32_t buttonState,
        float xOffset,
        float yOffset,
        float xPrecision,
        float yPrecision,
        nsecs_t downTime,
        nsecs_t eventTime,
        uint32_t pointerCount,
        const PointerProperties* pointerProperties,
        const PointerCoords* pointerCoords) {
....
    return mChannel->sendMessage(&msg);
}
```
这两个方法很简单，就是调用native层中InputChannel的sendMessage开始发送消息。

###### InputChannel sendMessage发送消息的核心逻辑
```cpp
status_t InputChannel::sendMessage(const InputMessage* msg) {
    size_t msgLength = msg->size();
    ssize_t nWrite;
    do {
        nWrite = ::send(mFd, msg, msgLength, MSG_DONTWAIT | MSG_NOSIGNAL);
    } while (nWrite == -1 && errno == EINTR);
...
    return OK;
}
```
很简单，就是调用了socket操作中的send方法，从InputChannel的发送端，发送到接收端。还记得上文提过的InputChannel的接收端实际上已经被主线程Looper监听了。

此时就会回调到主线程Looper调用对应的回调方法handleReceiveCallback中。

#### handleReceiveCallback
```cpp
InputDispatcher::handleReceiveCallback(int fd, int events, void* data) {
    InputDispatcher* d = static_cast<InputDispatcher*>(data);

    { // acquire lock
        AutoMutex _l(d->mLock);

        ssize_t connectionIndex = d->mConnectionsByFd.indexOfKey(fd);
        if (connectionIndex < 0) {
            return 0; // remove the callback
        }

        bool notify;
        sp<Connection> connection = d->mConnectionsByFd.valueAt(connectionIndex);
        if (!(events & (ALOOPER_EVENT_ERROR | ALOOPER_EVENT_HANGUP))) {
            if (!(events & ALOOPER_EVENT_INPUT)) {
                return 1;
            }

            nsecs_t currentTime = now();
            bool gotOne = false;
            status_t status;
            for (;;) {
                uint32_t seq;
                bool handled;
                status = connection->inputPublisher.receiveFinishedSignal(&seq, &handled);
                if (status) {
                    break;
                }
                d->finishDispatchCycleLocked(currentTime, connection, seq, handled);
                gotOne = true;
            }
            if (gotOne) {
                d->runCommandsLockedInterruptible();
                if (status == WOULD_BLOCK) {
                    return 1;
                }
            }

...
        } else {
...
        }
        d->unregisterInputChannelLocked(connection->inputChannel, notify);
        return 0; 
    } 
}
```
这个过程首先校验了当前的事件类型是否为ALOOPER_EVENT_INPUT，只有ALOOPER_EVENT_INPUT才能进入下面的逻辑。

在这个过程中，会根据fd获取到对应的Connection对象。并钱在一个循环中，依次执行下面的逻辑：
- 获取Connection的inputPublisher对象也就是InputPublisher对象(这个对象包含了InputChannel)。执行receiveFinishedSignal方法。
- 如果status大于1说明处理成功了，直接断开循环，执行unregisterInputChannelLocked方法。
- 如果status小于0，执行InputChannel的InputDispatcher::finishDispatchCycleLocked，以及InputDispatcher::runCommandsLockedInterruptible.如果receiveFinishedSignal返回status是WOULD_BLOCK(需要阻塞)，则返回1.否则执行unregisterInputChannelLocked。


##### InputPublisher::receiveFinishedSignal
```cpp
status_t InputPublisher::receiveFinishedSignal(uint32_t* outSeq, bool* outHandled) {
    InputMessage msg;
    status_t result = mChannel->receiveMessage(&msg);
    if (result) {
        *outSeq = 0;
        *outHandled = false;
        return result;
    }
    if (msg.header.type != InputMessage::TYPE_FINISHED) {
        return UNKNOWN_ERROR;
    }
    *outSeq = msg.body.finished.seq;
    *outHandled = msg.body.finished.handled;
    return OK;
}
```
核心其实就是InputChannel的receiveMessage方法。

##### InputChannel receiveMessage
```cpp
status_t InputChannel::receiveMessage(InputMessage* msg) {
    ssize_t nRead;
    do {
        nRead = ::recv(mFd, msg, sizeof(InputMessage), MSG_DONTWAIT);
    } while (nRead == -1 && errno == EINTR);

    if (nRead < 0) {
        int error = errno;
        if (error == EAGAIN || error == EWOULDBLOCK) {
            return WOULD_BLOCK;
        }
        if (error == EPIPE || error == ENOTCONN || error == ECONNREFUSED) {
            return DEAD_OBJECT;
        }
        return -error;
    }

    if (nRead == 0) { // check for EOF
        return DEAD_OBJECT;
    }

    if (!msg->isValid(nRead)) {
        return BAD_VALUE;
    }

    return OK;
}
```
能看到这里就是调用recv系统调用，读取从socket中传递过来的数据，数据结构就是InputMessage
```cpp
struct InputMessage {
    enum {
        TYPE_KEY = 1,
        TYPE_MOTION = 2,
        TYPE_FINISHED = 3,
    };

    struct Header {
        uint32_t type;
        uint32_t padding;
    } header;

    union Body {
        struct Key {
            uint32_t seq;
            nsecs_t eventTime __attribute__((aligned(8)));
            int32_t deviceId;
            int32_t source;
            int32_t displayId;
            int32_t action;
            int32_t flags;
            int32_t keyCode;
            int32_t scanCode;
            int32_t metaState;
            int32_t repeatCount;
            nsecs_t downTime __attribute__((aligned(8)));

            inline size_t size() const {
                return sizeof(Key);
            }
        } key;

        struct Motion {
            uint32_t seq;
            nsecs_t eventTime __attribute__((aligned(8)));
            int32_t deviceId;
            int32_t source;
            int32_t displayId;
            int32_t action;
            int32_t actionButton;
            int32_t flags;
            int32_t metaState;
            int32_t buttonState;
            int32_t edgeFlags;
            nsecs_t downTime __attribute__((aligned(8)));
            float xOffset;
            float yOffset;
            float xPrecision;
            float yPrecision;
            uint32_t pointerCount;

            struct Pointer {
                PointerProperties properties;
                PointerCoords coords;
            } pointers[MAX_POINTERS];

            int32_t getActionId() const {
                uint32_t index = (action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK)
                        >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
                return pointers[index].properties.id;
            }

            inline size_t size() const {
                return sizeof(Motion) - sizeof(Pointer) * MAX_POINTERS
                        + sizeof(Pointer) * pointerCount;
            }
        } motion;

        struct Finished {
            uint32_t seq;
            bool handled;

            inline size_t size() const {
                return sizeof(Finished);
            }
        } finished;
    } __attribute__((aligned(8))) body;

    bool isValid(size_t actualSize) const;
    size_t size() const;
};
```
该结构体包含如下4个部分：
- 1.Header 头部 持有了当前的Input消息的类型
- 2.Body 部 持有了当前Input消息的key类型，里面持有了设备id，显示屏id，设备code等重要参数
- 3.Motion 部 在Android开发中进行触点处理十分常见，里面包含了触点的偏移量，id，设备id等信息。
- 4.Finished部 触点消息结束的信息

#### InputDispatcher::finishDispatchCycleLocked
```cpp
void InputDispatcher::finishDispatchCycleLocked(nsecs_t currentTime,
        const sp<Connection>& connection, uint32_t seq, bool handled) {

    connection->inputPublisherBlocked = false;

    if (connection->status == Connection::STATUS_BROKEN
            || connection->status == Connection::STATUS_ZOMBIE) {
        return;
    }

    onDispatchCycleFinishedLocked(currentTime, connection, seq, handled);
}

void InputDispatcher::onDispatchCycleFinishedLocked(
        nsecs_t currentTime, const sp<Connection>& connection, uint32_t seq, bool handled) {
    CommandEntry* commandEntry = postCommandLocked(
            & InputDispatcher::doDispatchCycleFinishedLockedInterruptible);
    commandEntry->connection = connection;
    commandEntry->eventTime = currentTime;
    commandEntry->seq = seq;
    commandEntry->handled = handled;
}

InputDispatcher::CommandEntry* InputDispatcher::postCommandLocked(Command command) {
    CommandEntry* commandEntry = new CommandEntry(command);
    mCommandQueue.enqueueAtTail(commandEntry);
    return commandEntry;
}
```
实际上很简单，就是构建一个全新的CommandEntry 命令对象对象保存到mCommandQueue 命令队列中等待后续的消费，执行的是doDispatchCycleFinishedLockedInterruptible这个方法指针。

#### InputDispatcher::runCommandsLockedInterruptible
```cpp
bool InputDispatcher::runCommandsLockedInterruptible() {
    if (mCommandQueue.isEmpty()) {
        return false;
    }

    do {
        CommandEntry* commandEntry = mCommandQueue.dequeueAtHead();

        Command command = commandEntry->command;
        (this->*command)(commandEntry); // commands are implicitly 'LockedInterruptible'

        commandEntry->connection.clear();
        delete commandEntry;
    } while (! mCommandQueue.isEmpty());
    return true;
}
```
当执行完finishDispatchCycleLocked方法后，就会执行runCommandsLockedInterruptible消费刚才进入到命令队列中的命令。此时消费的方法是doDispatchCycleFinishedLockedInterruptible

##### InputDispatcher::doDispatchCycleFinishedLockedInterruptible
```cpp
void InputDispatcher::doDispatchCycleFinishedLockedInterruptible(
        CommandEntry* commandEntry) {
    sp<Connection> connection = commandEntry->connection;
    nsecs_t finishTime = commandEntry->eventTime;
    uint32_t seq = commandEntry->seq;
    bool handled = commandEntry->handled;

    // Handle post-event policy actions.
    DispatchEntry* dispatchEntry = connection->findWaitQueueEntry(seq);
    if (dispatchEntry) {
        nsecs_t eventDuration = finishTime - dispatchEntry->deliveryTime;


        bool restartEvent;
        if (dispatchEntry->eventEntry->type == EventEntry::TYPE_KEY) {
            KeyEntry* keyEntry = static_cast<KeyEntry*>(dispatchEntry->eventEntry);
            restartEvent = afterKeyEventLockedInterruptible(connection,
                    dispatchEntry, keyEntry, handled);
        } else if (dispatchEntry->eventEntry->type == EventEntry::TYPE_MOTION) {
            MotionEntry* motionEntry = static_cast<MotionEntry*>(dispatchEntry->eventEntry);
            restartEvent = afterMotionEventLockedInterruptible(connection,
                    dispatchEntry, motionEntry, handled);
        } else {
            restartEvent = false;
        }

        if (dispatchEntry == connection->findWaitQueueEntry(seq)) {
            connection->waitQueue.dequeue(dispatchEntry);
            traceWaitQueueLengthLocked(connection);
            if (restartEvent && connection->status == Connection::STATUS_NORMAL) {
                connection->outboundQueue.enqueueAtHead(dispatchEntry);
                traceOutboundQueueLengthLocked(connection);
            } else {
                releaseDispatchEntryLocked(dispatchEntry);
            }
        }

        startDispatchCycleLocked(now(), connection);
    }
}
```
能看到此时就是获取Connection的waitQueue中的dispatchEntry并且释放这个对象的内存。

## 总结
到这里就完成了一次IMS在native层从发送到接受的全部流程。到这里我们来绘制一个原理图。但是还没有完成整个IMS的流程，只是在native层下走了一圈，都不清楚是怎么把事件分发到App应用中。

这一篇文章中对象还是有点多，这里先给个思维导图，来看看每个对象之间的关系。
![InputManager.png](/images/InputManager.png)


知道这些对象的之间的关系后，我们再来看看IMS整个执行的模型。
![IMS输入事件传输模型.png](/images/IMS输入事件传输模型.png)

从这两张图，我们再进一步的总结.

在整个IMS中，存在两个线程环境：
- InputReaderThread 事件读取线程
  - 通过EventHub从驱动中读取输入事件后，通过InputDevice的Mapper对象RawEvent包裹为NotifyKeyArgs开始分发事件。这一段逻辑全是InputReader在工作。
  - InputReader也持有InputDispatcher，不过是通过QueueInputListener间接持有，在InputReader线程中，InputDispatcher会把NotifyKeyArgs中的RawEvent转化为EventEntry，最后添加到InputDispatcher的mInboundQueue中。最后通过Looper唤醒InputDispatcherThread

- InputDispatcherThread 事件分发线程
  - Looper被唤醒后，将会从mInBoundQueue中获取头部的EventEntry对象，放到Connection的outboundQueue中。
  - 查找当前焦点窗口或者触碰窗口句柄，并通过该句柄获取对应的输入通道InputChannel。
  - InputPublisher会持有InputChannel，并调用InputChannel的sendMessage方法发送socket内容。内容结构体为InputMessage。接着会添加到Connection的waitQueue中。
  - 除了App应用会对InputChannel的接收端监听外，WMS还注册了一个InputMonitor进行监听，每当App监听到发送过来的事件消息，InputMonitor也会监听到，从而把waitQueue中的EventEntry销毁了，并且执行还没有被消费完的事件。

值得一提的是Moition的原理，Moition类型的事件是指手指触摸屏幕。Android是支持多点触屏的 ，并做了如下优化：
- Android把多点触屏以32位的bit（也就是一个Int类型），进行存储最多32个触屏点，每一位代表当前触屏的状态。
  - 这样当进行32个触屏点的状态判断只需要判断0和1之间的变换就能知道，什么时候按下和抬起。需要简单的与和非运算就知道什么地方发生了变化。就从O(n)级别的时间复杂度下降到O(1)。
- Android 触屏驱动不会跟踪每个点的轨迹，在InputReader中就会遍历查找当前点距离最近的那个点就是该点的下一个轨迹。






