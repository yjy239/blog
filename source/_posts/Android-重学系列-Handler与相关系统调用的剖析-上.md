---
title: Android 重学系列 Handler与相关系统调用的剖析(上)
top: false
cover: false
date: 2019-11-18 17:30:42
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
- Linux
---
# 前言
经过之前系列的文章，总结了View是如何实例化，又是怎么查找资源。接下来就是弄清楚整个Android是如何把View渲染到屏幕上。不过在这之前，需要剖析一遍Handler的源码。因为在整个Android系统中，Handler贯穿整个应用的生命周期，渲染流程。可以说是我们开发的核心。其实Handler我已经写过两篇了，一篇是基础设计，一篇是从线程设计角度看Handler，这一篇让我们全局性的阅读Handler的源码。

如果遇到问题欢迎来到这里讨论:[https://www.jianshu.com/p/416de2a3a1d6](https://www.jianshu.com/p/416de2a3a1d6)



在聊Handler之前，我先上一个Handler的设计图：
![Handler.png](/images/Handler.png)

刚开始学习Android的我一开始看到这个设计的时候觉得很奇怪，为什么在Looper中一个死循环为什么不会卡死？按照道理这个线程在不断的执行一个函数就没有退出来过，应该是没有机会继续执行其他函数，为什么在我们的开发中能够正常相应呢？之后随着学习，终于明白其中的核心原理，本文就以这个问题，来探讨一下Handler大多没有人熟知的设计。


# 正文
为了照顾不是很熟悉Handler的朋友，这里继续老生常谈的总结一下Handler中几个核心角色：
- 1.Message :顾名思义就是线程中传递消息。
- 2.MessageQueue:是指消息队列，每个消息进入之后，就进入到该队列进行排队，等待Handler的处理。
- 3.Handler：处理发送过来的消息。，一般需要重写handleMessage()来达到目的。
- 4.Looper：可以说是核心的模块，作为每个线程MessageQueue的管理者。

Handler如何使用，这里就不聊了，只要会Android的都明白。一般当我们使用Handler都会使用sendMessage的方式发送Message到MessageQueue中。最后会调用到MessageQueue的入队方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[Handler.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/Handler.java)

```java
    private boolean enqueueMessage(MessageQueue queue, Message msg, long uptimeMillis) {
        msg.target = this;
        if (mAsynchronous) {
            msg.setAsynchronous(true);
        }
        return queue.enqueueMessage(msg, uptimeMillis);
    }
```
就在这里把每一个Message的target设置为当前的Handler，之后就通过这个target反过来查找Handler。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[MessageQueue.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/MessageQueue.java)

```java
    boolean enqueueMessage(Message msg, long when) {
        if (msg.target == null) {
            throw new IllegalArgumentException("Message must have a target.");
        }
        if (msg.isInUse()) {
            throw new IllegalStateException(msg + " This message is already in use.");
        }

        synchronized (this) {
            if (mQuitting) {
                IllegalStateException e = new IllegalStateException(
                        msg.target + " sending message to a Handler on a dead thread");
                Log.w(TAG, e.getMessage(), e);
                msg.recycle();
                return false;
            }

            msg.markInUse();
            msg.when = when;
            Message p = mMessages;
            boolean needWake;
            if (p == null || when == 0 || when < p.when) {
                // New head, wake up the event queue if blocked.
                msg.next = p;
                mMessages = msg;
                needWake = mBlocked;
            } else {
                // Inserted within the middle of the queue.  Usually we don't have to wake
                // up the event queue unless there is a barrier at the head of the queue
                // and the message is the earliest asynchronous message in the queue.
                needWake = mBlocked && p.target == null && msg.isAsynchronous();
                Message prev;
                for (;;) {
                    prev = p;
                    p = p.next;
                    if (p == null || when < p.when) {
                        break;
                    }
                    if (needWake && p.isAsynchronous()) {
                        needWake = false;
                    }
                }
                msg.next = p; // invariant: p == prev.next
                prev.next = msg;
            }

            // We can assume mPtr != 0 because mQuitting is false.
            if (needWake) {
                nativeWake(mPtr);
            }
        }
        return true;
    }
```
这里的核心是，不断的通过Message链表找到比当前的当前时间大的Message，或者为空的时候跳出。并且添加到链表中。因此MessageQueue是以时间为顺序进行排列整个消息队列。

这里有一个十分重要的方法，nativeWake。当发现当前这个要加入的Message打开了isAsynchronous标志位，并且打开了mBlock标示位与Message对应的Handler为空，则不调用nativeWake。等下我们回头聊聊这个逻辑是怎么回事。


那么Looper呢？当我们一般调用Looper的prepare方法初始化后，会调用Looper的loop的方法启动当前线程的Looper从MessageQueue读取Message。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[Looper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/Looper.java)
```java
public static void loop() {
        final Looper me = myLooper();
...
        final MessageQueue queue = me.mQueue;
...

        boolean slowDeliveryDetected = false;

        for (;;) {
            Message msg = queue.next(); // might block
...
            final Printer logging = me.mLogging;
            if (logging != null) {
                logging.println(">>>>> Dispatching to " + msg.target + " " +
                        msg.callback + ": " + msg.what);
            }

...

            final long dispatchStart = needStartTime ? SystemClock.uptimeMillis() : 0;
            final long dispatchEnd;
            try {
                msg.target.dispatchMessage(msg);
                dispatchEnd = needEndTime ? SystemClock.uptimeMillis() : 0;
            } finally {
              ...
            }
...

            if (logging != null) {
                logging.println("<<<<< Finished to " + msg.target + " " + msg.callback);
            }

...
            msg.recycleUnchecked();
        }
    }
```
在这里看看loop方法中要点：
- 1.每一次Looper都会调用MessageQueue的next方法获取下一个信息
- 2.看到在这里面有有以个经常不被人注意到的功能，Handler的Logger日志，它能够记录每一次消息发送开始到结束的时间。因此我们可以通过这个方式检测所有在Handler中超时的运行方法，这也是性能检测一种方法。使用如下：
```java
Looper.getMainLooper().setMessageLogging(new Printer() {
            @Override
            public void println(String x) {
                
            }
        });
```

- 3.每一次使用完Message都会被回收到Message的缓存链表中，默认最大是50.


文件: /[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[MessageQueue.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/MessageQueue.java)

```java
    Message next() {
        final long ptr = mPtr;
        if (ptr == 0) {
            return null;
        }

        int pendingIdleHandlerCount = -1; // -1 only during first iteration
        int nextPollTimeoutMillis = 0;
        for (;;) {
            if (nextPollTimeoutMillis != 0) {
                Binder.flushPendingCommands();
            }

            nativePollOnce(ptr, nextPollTimeoutMillis);

            synchronized (this) {
                final long now = SystemClock.uptimeMillis();
                Message prevMsg = null;
                Message msg = mMessages;
                if (msg != null && msg.target == null) {
                    do {
                        prevMsg = msg;
                        msg = msg.next;
                    } while (msg != null && !msg.isAsynchronous());
                }
                if (msg != null) {
                    if (now < msg.when) {
                        nextPollTimeoutMillis = (int) Math.min(msg.when - now, Integer.MAX_VALUE);
                    } else {
                        mBlocked = false;
                        if (prevMsg != null) {
                            prevMsg.next = msg.next;
                        } else {
                            mMessages = msg.next;
                        }
                        msg.next = null;
                        msg.markInUse();
                        return msg;
                    }
                } else {
                    // No more messages.
                    nextPollTimeoutMillis = -1;
                }

                // Process the quit message now that all pending messages have been handled.
                if (mQuitting) {
                    dispose();
                    return null;
                }

                // If first time idle, then get the number of idlers to run.
                // Idle handles only run if the queue is empty or if the first message
                // in the queue (possibly a barrier) is due to be handled in the future.
                if (pendingIdleHandlerCount < 0
                        && (mMessages == null || now < mMessages.when)) {
                    pendingIdleHandlerCount = mIdleHandlers.size();
                }
                if (pendingIdleHandlerCount <= 0) {
                    // No idle handlers to run.  Loop and wait some more.
                    mBlocked = true;
                    continue;
                }

                if (mPendingIdleHandlers == null) {
                    mPendingIdleHandlers = new IdleHandler[Math.max(pendingIdleHandlerCount, 4)];
                }
                mPendingIdleHandlers = mIdleHandlers.toArray(mPendingIdleHandlers);
            }

            // Run the idle handlers.
            // We only ever reach this code block during the first iteration.
            for (int i = 0; i < pendingIdleHandlerCount; i++) {
                final IdleHandler idler = mPendingIdleHandlers[i];
                mPendingIdleHandlers[i] = null; // release the reference to the handler

                boolean keep = false;
                try {
                    keep = idler.queueIdle();
                } catch (Throwable t) {
                    Log.wtf(TAG, "IdleHandler threw exception", t);
                }

                if (!keep) {
                    synchronized (this) {
                        mIdleHandlers.remove(idler);
                    }
                }
            }

 
            pendingIdleHandlerCount = 0;
            nextPollTimeoutMillis = 0;
        }
    }
```
当next的方法进入到一个循环中，其作用就是为了不断的获取队列中的队列中的Message，一旦发现最近的Message的时间比当前的时间小，说明还需要等待一段时间才能执行，就会获取时间差赋值给nextPollTimeoutMillis。直到Message时间大于等于当前时间，就取出。

需要关注的核心如下：
- 1. nativePollOnce 是next方法中的核心，它的存在就是让这个死循环不再卡死的原因。
- 2.首先从MessageQueue取出所有打上了Asynchronous标志的Message，优先处理这种Message，这个方式一般又被叫做栏栅消息。但是我觉得用优先消息更为贴切。
- 3.接着根据时间取出符合的message，接着返回。
- 4.需要退出，此时将会退出。
- 5.如果message队列为空或者还没有到时间去处理最顶部的消息，则会检查idle数组中是否存放这需要空闲时处理的消息，有则处理。

这个方法用处挺大的，有时候有如下需求，当我们需要某个事件在Activity的某个行为如渲染，添加窗口，往往使用延时，但是这种做法并不优雅，因为你并不能准确预估到多少时间之后会处理,我们此时可以使用idleHandler，保证优先处理完系统的Handler事件之后，再调用不那么紧张的时间:
```
        mHandler.getLooper().getQueue().addIdleHandler(new MessageQueue.IdleHandler() {
            @Override
            public boolean queueIdle() {
                return false;
            }
        });
```

当返回值为false则只执行一次，返回true，等到空闲会不断的执行同一个方法。

到这里，Handler需要注意的地方就结束了。

### Handler所映射的native层

Handler并不是我们所看到的这么简单，呈现在开发者眼中的仅仅只是冰山一角。请注意一下Looper初始化中究竟有什么？
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[os](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/)/[Looper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/os/Looper.java)

```java
    private Looper(boolean quitAllowed) {
        mQueue = new MessageQueue(quitAllowed);
        mThread = Thread.currentThread();
    }
```
当Looper实例化会自带一个MessageQueue，而所有当猫腻都在MessageQueue中：
```java
    MessageQueue(boolean quitAllowed) {
        mQuitAllowed = quitAllowed;
        mPtr = nativeInit();
    }
```
在MessageQueue构造函数中，有一个nativeInit方法实例化一个native对象。
```cpp
static jlong android_os_MessageQueue_nativeInit(JNIEnv* env, jclass clazz) {
    NativeMessageQueue* nativeMessageQueue = new NativeMessageQueue();
    if (!nativeMessageQueue) {
        jniThrowRuntimeException(env, "Unable to allocate native queue");
        return 0;
    }

    nativeMessageQueue->incStrong(env);
    return reinterpret_cast<jlong>(nativeMessageQueue);
}
```

能看到实际上nativeInit，是实例化了一个NativeMessageQueue对象，并且返回地址。

### NativeMessageQueue的组成
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_os_MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_os_MessageQueue.cpp)

```cpp
class NativeMessageQueue : public MessageQueue, public LooperCallback {
public:
    NativeMessageQueue();
    virtual ~NativeMessageQueue();

    virtual void raiseException(JNIEnv* env, const char* msg, jthrowable exceptionObj);

    void pollOnce(JNIEnv* env, jobject obj, int timeoutMillis);
    void wake();
    void setFileDescriptorEvents(int fd, int events);

    virtual int handleEvent(int fd, int events, void* data);

private:
    JNIEnv* mPollEnv;
    jobject mPollObj;
    jthrowable mExceptionObj;
};
```
NativeMessageQueue继承了MessageQueue以及实现了LooperCallback。能看到在这个类有两个核心的方法，叫做pollOnce，以及wake。这就不由让我们联想到之前Message入队列时候的nativeWake，以及MessageQueue的next方法中的nativePollOnce是否是一一对应的呢？答案肯定是的。handleEvent的作用是什么呢？稍后解释，让我们先看看NativeMessageQueue的构造方法。

```cpp
NativeMessageQueue::NativeMessageQueue() :
        mPollEnv(NULL), mPollObj(NULL), mExceptionObj(NULL) {
    mLooper = Looper::getForThread();
    if (mLooper == NULL) {
        mLooper = new Looper(false);
        Looper::setForThread(mLooper);
    }
}
```
该方法同样在native中创建了一个Looper对象，并且调用了Looper的setForThread方法。能发现，在Java层中是Looper包含了MessageQueue的关系，而在native中则是MessageQueue包含了Looper对象。

### native的Looper对象
```cpp
class Looper : public RefBase {
protected:
    virtual ~Looper();

public:
   ...

    Looper(bool allowNonCallbacks);

    bool getAllowNonCallbacks() const;

    int pollOnce(int timeoutMillis, int* outFd, int* outEvents, void** outData);
    inline int pollOnce(int timeoutMillis) {
        return pollOnce(timeoutMillis, NULL, NULL, NULL);
    }

    int pollAll(int timeoutMillis, int* outFd, int* outEvents, void** outData);
    inline int pollAll(int timeoutMillis) {
        return pollAll(timeoutMillis, NULL, NULL, NULL);
    }

    void wake();

    int addFd(int fd, int ident, int events, Looper_callbackFunc callback, void* data);
    int addFd(int fd, int ident, int events, const sp<LooperCallback>& callback, void* data);

    int removeFd(int fd);

    void sendMessage(const sp<MessageHandler>& handler, const Message& message);

    void sendMessageDelayed(nsecs_t uptimeDelay, const sp<MessageHandler>& handler,
            const Message& message);

    void sendMessageAtTime(nsecs_t uptime, const sp<MessageHandler>& handler,
            const Message& message);

    void removeMessages(const sp<MessageHandler>& handler);

    void removeMessages(const sp<MessageHandler>& handler, int what);

    bool isPolling() const;

    static sp<Looper> prepare(int opts);

    static void setForThread(const sp<Looper>& looper);

    static sp<Looper> getForThread();

private:
   ...
};
```
我们注重看它的公开方法：能看到在native的Looper包含了和java层中naitve十分相似的方法，prepare生成一个Looper 对象。还包含了一部分类似于java的Handler的逻辑。如sendMessage等。当然还带有自己特有的addFd等逻辑。

根据经验论，可以猜测实际上native层的Looper的机制和用法应该和java层的十分相似。现在先让我们来看看Looper中的构造函数。


```cpp
Looper::Looper(bool allowNonCallbacks) :
        mAllowNonCallbacks(allowNonCallbacks), mSendingMessage(false),
        mPolling(false), mEpollFd(-1), mEpollRebuildRequired(false),
        mNextRequestSeq(0), mResponseIndex(0), mNextMessageUptime(LLONG_MAX) {
    mWakeEventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);


    AutoMutex _l(mLock);
    rebuildEpollLocked();
}
```
能看到在Looper在构造函数做了如下几件事情：
- 1.通过系统调用eventfd注册eventfd 对象，用于实现事件的等待和通知，并返回mWakeEventFd一个文件描述符。eventfd能够用作进程，线程，用户态和内核态之间通信，通过write，read，select，epoll等方法。

- 2.rebuildEpollLocked 构建epoll系统调用的初始化。

#### rebuildEpollLocked
```cpp
void Looper::rebuildEpollLocked() {
    // Close old epoll instance if we have one.
    if (mEpollFd >= 0) {
...
        close(mEpollFd);
    }

    // Allocate the new epoll instance and register the wake pipe.
    mEpollFd = epoll_create(EPOLL_SIZE_HINT);
...

    struct epoll_event eventItem;
    memset(& eventItem, 0, sizeof(epoll_event)); // zero out unused members of data field union
    eventItem.events = EPOLLIN;
    eventItem.data.fd = mWakeEventFd;
    int result = epoll_ctl(mEpollFd, EPOLL_CTL_ADD, mWakeEventFd, & eventItem);
...
    for (size_t i = 0; i < mRequests.size(); i++) {
        const Request& request = mRequests.valueAt(i);
        struct epoll_event eventItem;
        request.initEventItem(&eventItem);

        int epollResult = epoll_ctl(mEpollFd, EPOLL_CTL_ADD, request.fd, & eventItem);
...
    }
}
```
能看到，在这个过程中，能看到第二个系统调用epoll。这里做了如下的事情:
- 1.首先，通过epoll_create创建一个epoll句柄，最多可以监听9个消息
- 2.初始化epoll_event结构体，把这个事件定义为可以读取(EPOLLIN)，把mWakeEventFd设置到eventItem的数据中，并且通过epoll_ctl注册mWakeEventFd句柄的监听。
- 3.获取mRequests队列中通过addFd的方法添加进来需要监听的对象，全部注册到epoll_ctl中。其实这里的逻辑主要是为了处理，当同一个Looper监听句柄重新构建(一般是epoll监听出现了异常)，会把之前的Looper中Request队列继承下来。

那么epoll又是什么呢？这里稍微解释一下给一些不是很熟悉的读者。epoll是Linux提供的非阻塞的事件触发，一般是使用在网络，IO编程中。先不去解释怎么使用，我们看看handler是怎么使用的。

当我们准备好了native的Looper对象之后，接下来java层会调用loop方法中MessageQueue的next方法。之前我点出来两个值得注意的方法nativePollOnce，以及nativeWake

### nativePollOnce
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_os_MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_os_MessageQueue.cpp)
```cpp
static void android_os_MessageQueue_nativePollOnce(JNIEnv* env, jobject obj,
        jlong ptr, jint timeoutMillis) {
    NativeMessageQueue* nativeMessageQueue = reinterpret_cast<NativeMessageQueue*>(ptr);
    nativeMessageQueue->pollOnce(env, obj, timeoutMillis);
}
```

```cpp
void NativeMessageQueue::pollOnce(JNIEnv* env, jobject pollObj, int timeoutMillis) {
    mPollEnv = env;
    mPollObj = pollObj;
    mLooper->pollOnce(timeoutMillis);
    mPollObj = NULL;
    mPollEnv = NULL;

    if (mExceptionObj) {
        env->Throw(mExceptionObj);
        env->DeleteLocalRef(mExceptionObj);
        mExceptionObj = NULL;
    }
}
```
此时NativeMessageQueue回去调用native层Looper的pollOnce方法。

#### Looper pollOnce
文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libutils](http://androidxref.com/9.0.0_r3/xref/system/core/libutils/)/[Looper.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libutils/Looper.cpp)

```cpp
int Looper::pollOnce(int timeoutMillis, int* outFd, int* outEvents, void** outData) {
    int result = 0;
    for (;;) {
        while (mResponseIndex < mResponses.size()) {
            const Response& response = mResponses.itemAt(mResponseIndex++);
            int ident = response.request.ident;
            if (ident >= 0) {
                int fd = response.request.fd;
                int events = response.events;
                void* data = response.request.data;
...
                if (outFd != NULL) *outFd = fd;
                if (outEvents != NULL) *outEvents = events;
                if (outData != NULL) *outData = data;
                return ident;
            }
        }

        if (result != 0) {
...
            if (outFd != NULL) *outFd = 0;
            if (outEvents != NULL) *outEvents = 0;
            if (outData != NULL) *outData = NULL;
            return result;
        }

        result = pollInner(timeoutMillis);
    }
}
```

首先先检测通过addFd添加进来的监听事件，一旦发现内部有数据则理解返回，退出当前的死循环。否则则会进入到pollInner。为什么要这么做呢？因为addFd方法可能需要有回掉，那么就有两种模式，一种是没有回调的直接结果的方法，设置ident为POLL_BACK(-2),一种是存在回调的，ident必须是大于0的唯一标示。

没有回调的会在PollOnce中处理返回，有回调会在pollInner中处理。

#### pollInner
```cpp
int Looper::pollInner(int timeoutMillis) {

    // Adjust the timeout based on when the next message is due.
    if (timeoutMillis != 0 && mNextMessageUptime != LLONG_MAX) {
        nsecs_t now = systemTime(SYSTEM_TIME_MONOTONIC);
        int messageTimeoutMillis = toMillisecondTimeoutDelay(now, mNextMessageUptime);
        if (messageTimeoutMillis >= 0
                && (timeoutMillis < 0 || messageTimeoutMillis < timeoutMillis)) {
            timeoutMillis = messageTimeoutMillis;
        }

    }

    // Poll.
    int result = POLL_WAKE;
    mResponses.clear();
    mResponseIndex = 0;

    // We are about to idle.
    mPolling = true;

    struct epoll_event eventItems[EPOLL_MAX_EVENTS];
    int eventCount = epoll_wait(mEpollFd, eventItems, EPOLL_MAX_EVENTS, timeoutMillis);

    // No longer idling.
    mPolling = false;

    // Acquire lock.
    mLock.lock();

    // Rebuild epoll set if needed.
    if (mEpollRebuildRequired) {
        mEpollRebuildRequired = false;
        rebuildEpollLocked();
        goto Done;
    }

    // Check for poll error.
    if (eventCount < 0) {
        if (errno == EINTR) {
            goto Done;
        }
        ALOGW("Poll failed with an unexpected error: %s", strerror(errno));
        result = POLL_ERROR;
        goto Done;
    }

    // Check for poll timeout.
    if (eventCount == 0) {

        result = POLL_TIMEOUT;
        goto Done;
    }

    // Handle all events.

    for (int i = 0; i < eventCount; i++) {
        int fd = eventItems[i].data.fd;
        uint32_t epollEvents = eventItems[i].events;
        if (fd == mWakeEventFd) {
            if (epollEvents & EPOLLIN) {
                awoken();
            } else {
...
            }
        } else {
            ssize_t requestIndex = mRequests.indexOfKey(fd);
            if (requestIndex >= 0) {
                int events = 0;
                if (epollEvents & EPOLLIN) events |= EVENT_INPUT;
                if (epollEvents & EPOLLOUT) events |= EVENT_OUTPUT;
                if (epollEvents & EPOLLERR) events |= EVENT_ERROR;
                if (epollEvents & EPOLLHUP) events |= EVENT_HANGUP;
                pushResponse(events, mRequests.valueAt(requestIndex));
            } else {
...
            }
        }
    }
Done: ;

    // Invoke pending message callbacks.
    mNextMessageUptime = LLONG_MAX;
    while (mMessageEnvelopes.size() != 0) {
        nsecs_t now = systemTime(SYSTEM_TIME_MONOTONIC);
        const MessageEnvelope& messageEnvelope = mMessageEnvelopes.itemAt(0);
        if (messageEnvelope.uptime <= now) {
            // Remove the envelope from the list.
            // We keep a strong reference to the handler until the call to handleMessage
            // finishes.  Then we drop it so that the handler can be deleted *before*
            // we reacquire our lock.
            { // obtain handler
                sp<MessageHandler> handler = messageEnvelope.handler;
                Message message = messageEnvelope.message;
                mMessageEnvelopes.removeAt(0);
                mSendingMessage = true;
                mLock.unlock();

                handler->handleMessage(message);
            } // release handler

            mLock.lock();
            mSendingMessage = false;
            result = POLL_CALLBACK;
        } else {
            // The last message left at the head of the queue determines the next wakeup time.
            mNextMessageUptime = messageEnvelope.uptime;
            break;
        }
    }

    // Release lock.
    mLock.unlock();

    // Invoke all response callbacks.
    for (size_t i = 0; i < mResponses.size(); i++) {
        Response& response = mResponses.editItemAt(i);
        if (response.request.ident == POLL_CALLBACK) {
            int fd = response.request.fd;
            int events = response.events;
            void* data = response.request.data;

            int callbackResult = response.request.callback->handleEvent(fd, events, data);
            if (callbackResult == 0) {
                removeFd(fd, response.request.seq);
            }

            response.request.callback.clear();
            result = POLL_CALLBACK;
        }
    }
    return result;
}
```
这段方法做的事情有两件：
- 1.通过epoll_wait方法阻塞监听所有已经注册到mEpollFd句柄中的监听事件，如mWakeEventFd，以及在mRequests队列中需要监听的句柄。

- 2.一旦发现监听监控的文件描述符中出现了数据的变动，则立即响应。注意epoll有两种事件触发模式，LT以及ET两种模式。LT(水平)模式是指只要有数据写入到被监听的对象，就会立即触发事件返回。而ET(边缘)模式是指只有状态发生变化了才会触发事件返回，不过缓冲区里面有没有数据。默认是LT模式。

- 3.唤醒阻塞之后，开始循环检查每一个监听返回的eventItems中的标志位。如果检测到当前是mWakeEventFd的fd，则获取当前的events中的标志是否是EPOLLIN，是则调用awoken方法。否则则获取每一个通过addFd注入的Requests是否有相符合的fd句柄，有则调用pushResponse。

- 4.处理加入到Looper中的Native层中的Handler对象，循环回调每一个Handler对应的handleMessage方法

- 5.回调所有pushResponse压入的Response队列中的回调handleEvent。

全部做好监听准备之后，我们来看看对应的唤醒方法，也就是之前提到过的在equeue入队时候调用的nativeWake方法。


### nativeWake
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_os_MessageQueue.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_os_MessageQueue.cpp)
```cpp
static void android_os_MessageQueue_nativeWake(JNIEnv* env, jclass clazz, jlong ptr) {
    NativeMessageQueue* nativeMessageQueue = reinterpret_cast<NativeMessageQueue*>(ptr);
    nativeMessageQueue->wake();
}

void NativeMessageQueue::wake() {
    mLooper->wake();
}
```

能看到最后还是调用到了Looper对象中的wake方法。

```cpp
void Looper::wake() {
    uint64_t inc = 1;
    ssize_t nWrite = TEMP_FAILURE_RETRY(write(mWakeEventFd, &inc, sizeof(uint64_t)));
    if (nWrite != sizeof(uint64_t)) {
        if (errno != EAGAIN) {
            LOG_ALWAYS_FATAL("Could not write wake signal to fd %d: %s",
                    mWakeEventFd, strerror(errno));
        }
    }
}
```
这个方法的核心逻辑就是就是往mWakeEventFd文件句柄写入一个int 为1的数据。通过这种方法，改变了mWakeEventFd文件中的数据流，从而唤醒了epoll_wait的阻塞，继续走到awoken的方法。


#### awoken
```cpp
void Looper::awoken() {

    uint64_t counter;
    TEMP_FAILURE_RETRY(read(mWakeEventFd, &counter, sizeof(uint64_t)));
}
```
不断的读取里面所有数据，但是这个数据没有什么作用。


### 小结
因此我们能够总结出来，整个Handler其实是借助epoll和eventfd系统调用，从而做到高性能的回调事件触发机制。而epoll这个系统调用本身存在的意义就是为了监听极大量数据的变化，一般在网络编程中是用来处理百万级别的链接。与select不同，select首先是限制了可以链接的数量，而epoll则是可以自己设定最大数量。其次select方式做非阻塞socket需要不断的轮询每一个接口，而epoll通过回调的方式告诉你epoll监视下什么接口对应的句柄出现变化了。在Handler这里也是一样的，通过唤醒epoll-wait把所有改变数据的对象回调上来。

但是仅仅只是这样，根本就不是重学系列。让我们详细的思考一下，为什么在这个唤醒过程中使用eventfd，而不用普通的文件描述符呢？相比之下eventfd有什么优势呢？而epoll究竟又是怎么工作的呢？为什么可以做到百万级别的监听每个文件数据变化呢？

## eventfd
先来看看eventfd在Handler中的用法：
```cpp
 mWakeEventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
```
这个系统调用有两个参数，因此我们可以直接找到内核中对应的方法：
文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventfd.c](http://androidxref.com/kernel_3.18/xref/fs/eventfd.c)
```cpp
SYSCALL_DEFINE2(eventfd2, unsigned int, count, int, flags)
{
	int fd, error;
	struct file *file;

	error = get_unused_fd_flags(flags & EFD_SHARED_FCNTL_FLAGS);
	if (error < 0)
		return error;
	fd = error;

	file = eventfd_file_create(count, flags);
	if (IS_ERR(file)) {
		error = PTR_ERR(file);
		goto err_put_unused_fd;
	}
	fd_install(fd, file);

	return fd;

err_put_unused_fd:
	put_unused_fd(fd);

	return error;
}
```
这里的步骤和我之前open打开一个文件描述很相似，可以对照[syscall原理](https://www.jianshu.com/p/ba0a34826b27)阅读，比对一下，两种文件描述符的创建。
这里主要做了如下几个事情：
- 1.get_unused_fd_flags 获取一下当前fdt进程中空闲的fdt描述符，加入遇到容量不足则2倍扩容或者是（最小）PAGE_SIZE *8.
- 2.eventfd_file_create 创建一个文件描述符，并且把eventfd的文件操作结构体复写进去
- 3.fd_install 通过RCU机制把创建出来的文件描述符和fd关联起来。(RCU机制其实就和我之前聊过的读写锁很相似，读操作优先的多线程同步操作)

那么核心还是eventfd_file_create中创建了做了事情：
```cpp
static const struct file_operations eventfd_fops = {
#ifdef CONFIG_PROC_FS
	.show_fdinfo	= eventfd_show_fdinfo,
#endif
	.release	= eventfd_release,
	.poll		= eventfd_poll,
	.read		= eventfd_read,
	.write		= eventfd_write,
	.llseek		= noop_llseek,
};



struct file *eventfd_file_create(unsigned int count, int flags)
{
	struct file *file;
	struct eventfd_ctx *ctx;


	if (flags & ~EFD_FLAGS_SET)
		return ERR_PTR(-EINVAL);

	ctx = kmalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return ERR_PTR(-ENOMEM);

	kref_init(&ctx->kref);
	init_waitqueue_head(&ctx->wqh);
	ctx->count = count;
	ctx->flags = flags;

	file = anon_inode_getfile("[eventfd]", &eventfd_fops, ctx,
				  O_RDWR | (flags & EFD_SHARED_FCNTL_FLAGS));
	if (IS_ERR(file))
		eventfd_free_ctx(ctx);

	return file;
}
```
做了如下2件事情：
- 1.eventfd_ctx 首先会在内核中创建一个eventfd_ctx上下文,这个上下文记录eventfd的flag，一个等待队列的头部，一个计数器。这个计数器的作用是当写入数据到当前这个eventfd创建的文件描述符，计数增加，并且唤醒对应的等待队列。当读取数据时候，计数清0，并且返回计数。当然eventfd_signal也会增加计数和唤醒。

记住此时的count是从上方传进来的0，稍后会用到。

```cpp
struct eventfd_ctx {
	struct kref kref;
//等待头
	wait_queue_head_t wqh;
//计数
	__u64 count;
	unsigned int flags;
};
```

- 2.anon_inode_getfile 真正的创建文件描述符，并且把eventfd的文件操作结构体复写进去。
文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[anon_inodes.c](http://androidxref.com/kernel_3.18/xref/fs/anon_inodes.c)

```cpp
struct file *anon_inode_getfile(const char *name,
				const struct file_operations *fops,
				void *priv, int flags)
{
	struct qstr this;
	struct path path;
	struct file *file;

	if (IS_ERR(anon_inode_inode))
		return ERR_PTR(-ENODEV);

	if (fops->owner && !try_module_get(fops->owner))
		return ERR_PTR(-ENOENT);

	/*
	 * Link the inode to a directory entry by creating a unique name
	 * using the inode sequence number.
	 */
	file = ERR_PTR(-ENOMEM);
	this.name = name;
	this.len = strlen(name);
	this.hash = 0;
	path.dentry = d_alloc_pseudo(anon_inode_mnt->mnt_sb, &this);
	if (!path.dentry)
		goto err_module;

	path.mnt = mntget(anon_inode_mnt);

	ihold(anon_inode_inode);

	d_instantiate(path.dentry, anon_inode_inode);

	file = alloc_file(&path, OPEN_FMODE(flags), fops);
	if (IS_ERR(file))
		goto err_dput;
	file->f_mapping = anon_inode_inode->i_mapping;

	file->f_flags = flags & (O_ACCMODE | O_NONBLOCK);
	file->private_data = priv;

	return file;

err_dput:
	path_put(&path);
err_module:
	module_put(fops->owner);
	return file;
}
```
能看到核心方法就是alloc_file方法。创建一个文件描述符以及传递一个fops。而这个文件描述符的名字是"[eventfd]"，并且把eventfd_ctx上下作为当前file的私有数据。当然，每一个进程里面都有一个fs结构体，象征着这个进程所在的目录，而这个eventfd则是说明是在这个目录下的创建的一个虚拟文件。

详细的之后，有机会和大家聊聊基于虚拟文件系统相关的系统调用。

##### eventfd 创建的小结
因此总结一下，eventfd的创建，比起通常的file 创建，除了复写了文件描述对应的read,write，seek，poll，release五个文件操作之外，还有就是构建了一个该进程全局的eventfd的上下文。


## eventfd的读写操作

当我们理解了eventfd的创建，让我们看看整个读写又是怎么回事？handler在nativeWake以及naitvePollOnce中，特殊处理了一个特殊的文件描述符mWakeEventFd(从名字上可以知道这是一个唤醒事件，每次入队message都要往这个文件描述符中写数据)，只有mWakeEventFd是通过eventfd初始化mWakeEventFd。一般的我们在不用native层的addFd情况下，epoll也就监听了这个文件描述符。有想过吗，为什么唯独特殊这个事件？

要彻底理解这个问题，我们需要看看里面的读写的操作。

### eventfd的写操作
让我们先看看写操作。
文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventfd.c](http://androidxref.com/kernel_3.18/xref/fs/eventfd.c)
```cpp
static ssize_t eventfd_write(struct file *file, const char __user *buf, size_t count,
			     loff_t *ppos)
{
	struct eventfd_ctx *ctx = file->private_data;
	ssize_t res;
	__u64 ucnt;
	DECLARE_WAITQUEUE(wait, current);

	if (count < sizeof(ucnt))
		return -EINVAL;
	if (copy_from_user(&ucnt, buf, sizeof(ucnt)))
		return -EFAULT;
	if (ucnt == ULLONG_MAX)
		return -EINVAL;
	spin_lock_irq(&ctx->wqh.lock);
	res = -EAGAIN;
	if (ULLONG_MAX - ctx->count > ucnt)
		res = sizeof(ucnt);
	else if (!(file->f_flags & O_NONBLOCK)) {
		__add_wait_queue(&ctx->wqh, &wait);
		for (res = 0;;) {
			set_current_state(TASK_INTERRUPTIBLE);
			if (ULLONG_MAX - ctx->count > ucnt) {
				res = sizeof(ucnt);
				break;
			}
			if (signal_pending(current)) {
				res = -ERESTARTSYS;
				break;
			}
			spin_unlock_irq(&ctx->wqh.lock);
			schedule();
			spin_lock_irq(&ctx->wqh.lock);
		}
		__remove_wait_queue(&ctx->wqh, &wait);
		__set_current_state(TASK_RUNNING);
	}
	if (likely(res > 0)) {
		ctx->count += ucnt;
		if (waitqueue_active(&ctx->wqh))
			wake_up_locked_poll(&ctx->wqh, POLLIN);
	}
	spin_unlock_irq(&ctx->wqh.lock);

	return res;
}
```
- 1.通过DECLARE_WAITQUEUE声明一个wait等待项
- 2.通过copy_from_user把用户空间的传递下来的数据拷贝下来。
- 3.接下来分为两种情况：当（ULLONG_MAX - 上下文的count）的值 比拷贝下来的数据大，则直接测量当前数据的大小。

否则，当file没有打开O_NONBLOCK(非阻塞)开关的时候，先把当前的上下文对应的等待头添加到等待队列，而后进入到一个循环中。

该循环首先会切换当前进程进入到TASK_INTERRUPTIBLE（可被中断信号中断的等待状态），该循环不断的通过schedule方法切换到最需要切换处理的进程(vruntime最小的)。跳出的循环条件有两个，第一个当（ULLONG_MAX - 上下文的count）的值 比拷贝下来的数据大，则直接测量当前数据的大小后跳出。第二，就是被中断信号中断了。

最后把当前的等待队列头从等待队列移除出来，把进程设置为TASK_RUNNING(准备好运行状态)

- 4.当res大于0(传递下来有数据)，且没有超过最大无符号的long(64位全是1),则把当前的计数增加一个输入进来的数据大小，最后确认等待队列不为空，则唤醒当前进程。返回结果。

因此本质上eventfd并没有把数据写进磁盘，而是把所有的value记录在当前上下文eventfd_ctx 的count中，这么做有什么好处呢？等我们看完read之后再来套路。

### eventfd的读操作

先来看看Handler底层是怎么读取eventfd中的数据:
```cpp
void Looper::awoken() {
    uint64_t counter;
    TEMP_FAILURE_RETRY(read(mWakeEventFd, &counter, sizeof(uint64_t)));
}
```
此时是通过一个循环不断调用read方法，每一次读取都是64位。

```cpp
static void eventfd_ctx_do_read(struct eventfd_ctx *ctx, __u64 *cnt)
{
	*cnt = (ctx->flags & EFD_SEMAPHORE) ? 1 : ctx->count;
	ctx->count -= *cnt;
}

ssize_t eventfd_ctx_read(struct eventfd_ctx *ctx, int no_wait, __u64 *cnt)
{
	ssize_t res;
	DECLARE_WAITQUEUE(wait, current);

	spin_lock_irq(&ctx->wqh.lock);
	*cnt = 0;
	res = -EAGAIN;
	if (ctx->count > 0)
		res = 0;
	else if (!no_wait) {
		__add_wait_queue(&ctx->wqh, &wait);
		for (;;) {
			set_current_state(TASK_INTERRUPTIBLE);
			if (ctx->count > 0) {
				res = 0;
				break;
			}
			if (signal_pending(current)) {
				res = -ERESTARTSYS;
				break;
			}
			spin_unlock_irq(&ctx->wqh.lock);
			schedule();
			spin_lock_irq(&ctx->wqh.lock);
		}
		__remove_wait_queue(&ctx->wqh, &wait);
		__set_current_state(TASK_RUNNING);
	}
	if (likely(res == 0)) {
		eventfd_ctx_do_read(ctx, cnt);
		if (waitqueue_active(&ctx->wqh))
			wake_up_locked_poll(&ctx->wqh, POLLOUT);
	}
	spin_unlock_irq(&ctx->wqh.lock);

	return res;
}

static ssize_t eventfd_read(struct file *file, char __user *buf, size_t count,
			    loff_t *ppos)
{
	struct eventfd_ctx *ctx = file->private_data;
	ssize_t res;
	__u64 cnt;

	if (count < sizeof(cnt))
		return -EINVAL;
	res = eventfd_ctx_read(ctx, file->f_flags & O_NONBLOCK, &cnt);
	if (res < 0)
		return res;

	return put_user(cnt, (__u64 __user *) buf) ? -EFAULT : sizeof(cnt);
}
```
在整个read方法中，执行了如下几件事情和write很相似:
- 1.初始化一个等待队列的等待项。
- 2.如果eventfd_ctx 上下文中的count大小本身不为0，则会把res设置为0，并且赋值给上下文的count。否则，当数据为0且打开了等待标志位，则会进入进程调度切换循环，等待数据的到来或者中断，最后唤醒当前进程。


### eventfd的优势

阅读源码之后，我可以尝试总结这种系统调用比起常规的file的读写优势。
- 1.eventfd不会像file的读写一样尝试着构建一个文件在磁盘上，写入缓存后把脏数据写入磁盘。eventfd只会在内存中构建一个名为[eventfd]的虚拟文件，在这个文件中进行通信。

- 2.eventfd 不能像正常的file一样读写大量的数据。其读写是有限制的。所有的写数据都在一个无符号64位的count上，它会记录下所有写进来的数据。但是也正是整个原因累积写入的数据一旦超出这个这个值，将会失败。所以eventfd通常使用来做通知的。

- 3.在eventfd中，无论是读还是写都会先进入一个循环，读数据的时候，如果没有任何读取，将会不断的进行进程调度切换。而数据是写入当前file结构体私有数据中的eventfd_ctx。说明eventfd是支持极其高效率的进程间，进程中的通知通信。

- 4.当我么注意一下，写入数据时候的逻辑:
> ULLONG_MAX - ctx->count > ucnt

这个逻辑是跳出进程调度循环逻辑。换句话说，当写入的数据+累加的数据大于当前的无符号64位的最大值的时候，会进入阻塞等待其他进程的消耗在eventfd中累积的数据，直到小于这个最大值。才允许继续写入。而read则是如果可读的数据为0，一直等待读取数据。我们需要注意一个问题，每一次写入数据的量要足够小，而且必须想办法消耗，同时要保证先写后读，不然如果只有一个进程关注这个eventfd文件，就可能会出现死锁的情况。

eventfd总结一句话就是，和名字一样，基于文件系统的一个极其高效的进程间通知事件机制。这也就解释了为什么Handler的唤醒事件，使用eventfd系统调用了。

## 总结

eventfd是一个高性能的进程间通信机制，由于数据传输大小的限制，一般是作为进程间，进程内通知来使用。

因为听说很多人在聊Handler的native层的时候，都只注意到了eventfd或者epoll，但是并没有弄清楚这2个系统调用的原理，就没有办法正确的使用这些系统调用，以及Android为什么要这样设计。更加功利一点的说，很多人面试都遇到这些问题，就是死在这些原理的层面。

下一篇将会和大家聊聊epoll系统调用。