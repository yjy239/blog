---
title: 重学系列--系统启动到Activity(下)
top: false
cover: false
date: 2019-02-05 16:40:15
img:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android
- Linux
- Android Framework
---

### Zygote 进程间通信原理
不熟悉Linux编程的同学看到死循环最后这一段，可能就有点懵。这里我解释一遍，在构造一下整个流程以及模型估计就能明白了。

虽然是socket通信，但是实际上和我们常说Java的socket编程稍微有一点点不一样。实际上更加像驱动中的文件描述的监听。这里和Android4.4的有点不一样，但是思路是一样。

### Zygote监听服务端
从上面的代码，根据我的理论，peers这个ZygoteConnection是一个Zygote的链接对象，用来处理从远端的socket过来的消息。这个是一个关键类。我们看看这个ZygoteConnection究竟是怎么构造的。

```java
    private static ZygoteConnection acceptCommandPeer(String abiList) {
        try {
            return new ZygoteConnection(sServerSocket.accept(), abiList);
        } catch (IOException ex) {
            throw new RuntimeException(
                    "IOException during accept()", ex);
        }
    }
```
实际上此处会new一个ZygoteConnection，会把LocalServerSocket的accpet传进去。此时就和普通的socket一样进入阻塞。

让我先把LocalSocket这一系列的UML图放出来就能明白，这几个类之间关系。
![LocalSocket uml.png](/images/LocalSocket设计图.png)
实际上，所有的LocalSocket，无论是服务端LocalServerSocket还是客户端LocalSocket都是通过LocalServerImpl实现的。

```java
protected void accept(LocalSocketImpl s) throws IOException {
        if (fd == null) {
            throw new IOException("socket not created");
        }

        try {
            s.fd = Os.accept(fd, null /* address */);
            s.mFdCreatedInternally = true;
        } catch (ErrnoException e) {
            throw e.rethrowAsIOException();
        }
    }
```

这个Os对象通过Libcore.os.accept(fd, peerAddress);调用native层。
文件：/[libcore](http://androidxref.com/7.0.0_r1/xref/libcore/)/[luni](http://androidxref.com/7.0.0_r1/xref/libcore/luni/)/[src](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/)/[main](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/)/[native](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/native/)/[libcore_io_Posix.cpp](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/native/libcore_io_Posix.cpp)

```cpp
static jobject Posix_accept(JNIEnv* env, jobject, jobject javaFd, jobject javaSocketAddress) {
    sockaddr_storage ss;
    socklen_t sl = sizeof(ss);
    memset(&ss, 0, sizeof(ss));
//判断java层的socket对象是否为NULL
    sockaddr* peer = (javaSocketAddress != NULL) ? reinterpret_cast<sockaddr*>(&ss) : NULL;
    socklen_t* peerLength = (javaSocketAddress != NULL) ? &sl : 0;

//核心，此处等待阻塞线程
    jint clientFd = NET_FAILURE_RETRY(env, int, accept, javaFd, peer, peerLength);
    if (clientFd == -1 || !fillSocketAddress(env, javaSocketAddress, ss, *peerLength)) {
        close(clientFd);
        return NULL;
    }
//一旦socket回调之后，将会通过底层的fd对象转化为java对象
    return (clientFd != -1) ? jniCreateFileDescriptor(env, clientFd) : NULL;
}
```
此处分为三步：
- 第一步，通过解析address是否为空，来决定阻塞的等待时长，此时传下来为null，为无限期的等待。
- 第二步，核心方法，通过define声明的NET_FAILURE_RETRY代码段，阻塞线程
- 第三步，一旦等待的socket链接有数据回调进来，则转化为java层的fd返回。

此处是阻塞的核心代码
```cpp
#define NET_FAILURE_RETRY(jni_env, return_type, syscall_name, java_fd, ...) ({ \
    return_type _rc = -1; \
    int _syscallErrno; \
    do { \
        bool _wasSignaled; \
        { \
//转化java的fd，对Java进行监听
            int _fd = jniGetFDFromFileDescriptor(jni_env, java_fd); \
            AsynchronousCloseMonitor _monitor(_fd); \
            _rc = syscall_name(_fd, __VA_ARGS__); \
            _syscallErrno = errno; \
            _wasSignaled = _monitor.wasSignaled(); \
        } \
        if (_wasSignaled) { \
            jniThrowException(jni_env, "java/net/SocketException", "Socket closed"); \
            _rc = -1; \
            break; \
        } \
        if (_rc == -1 && _syscallErrno != EINTR) { \
            /* TODO: with a format string we could show the arguments too, like strace(1). */ \
            throwErrnoException(jni_env, # syscall_name); \
            break; \
        } \
    } while (_rc == -1); /* _syscallErrno == EINTR && !_wasSignaled */ \
    if (_rc == -1) { \
        /* If the syscall failed, re-set errno: throwing an exception might have modified it. */ \
        errno = _syscallErrno; \
    } \
    _rc; })
```

这里稍微解释一下，这段阻塞的核心方法的意思。
这循环代码的跳出条件有三个：
- _wasSignaled 为true 也就是说此时AsynchronousCloseMonitor通过线程锁ScopeThreadMutex上锁的线程被唤醒，说明了该socket断开，也就断开了阻塞。

- _rc 为-1 以及 _syscallErrno 错误标示位不为EINTER。rc为syscall_name（此时传进来的是socket的accept方法）。也就是说当accept链接出现异常的时候（返回-1）会一直在循环里面等待，除非为全局错误_syscallErrno 不是系统抛出的中断，则抛出异常。

- 当_rc不为-1，也就是说socket链接成功。则继续向下走。


因此从这里可以知道，Zygote在初始化runSelectLoop的时候，一开始会加入一个ZygoteConnection用于阻塞监听。一旦有链接进来，则唤醒则加入到peers队列中。在死循环下一个轮回的时候，通过执行runOnce执行fork新的进程。

虽然到这里似乎就完成整个流程了。但是实际上，google工程师写代码才不会这么简单就完成，而是做了一定的优化。

如果用Linux c写过服务器的哥们，就会明白这样不断的阻塞只会不断的消耗的cpu的资源，并不是很好的选择。

因此，runSelectLoop才有这一段代码
```java
            StructPollfd[] pollFds = new StructPollfd[fds.size()];
            for (int i = 0; i < pollFds.length; ++i) {
                pollFds[i] = new StructPollfd();
                pollFds[i].fd = fds.get(i);
                pollFds[i].events = (short) POLLIN;
            }
            try {
                Os.poll(pollFds, -1);
            } catch (ErrnoException ex) {
                throw new RuntimeException("poll failed", ex);
            }
```
根据这段代码，从表面上可以清楚的知道，一开始把描述符都设置进去StructPollfd等长数组中。把这个数组交给Os.poll中。

我们先看看StructPollfd这个类是个什么存在。
文件/[libcore](http://androidxref.com/7.0.0_r1/xref/libcore/)/[luni](http://androidxref.com/7.0.0_r1/xref/libcore/luni/)/[src](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/)/[main](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/)/[java](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/java/)/[android](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/java/android/)/[system](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/java/android/system/)/[StructPollfd.java](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/java/android/system/StructPollfd.java)

```
public final class StructPollfd {
  /** The file descriptor to poll. */
  public FileDescriptor fd;

  /**
   * The events we're interested in. POLLIN corresponds to being in select(2)'s read fd set,
   * POLLOUT to the write fd set.
   */
  public short events;

  /** The events that actually happened. */
  public short revents;

  /**
   * A non-standard extension that lets callers conveniently map back to the object
   * their fd belongs to. This is used by Selector, for example, to associate each
   * FileDescriptor with the corresponding SelectionKey.
   */
  public Object userData;

  @Override public String toString() {
    return Objects.toString(this);
  }
}
```

这个类十分简单。里面只有那么3个参数，events，revents，fd.分别是做什么的呢？

我们直接看看Os.poll方法底层的实现
文件：/[libcore](http://androidxref.com/7.0.0_r1/xref/libcore/)/[luni](http://androidxref.com/7.0.0_r1/xref/libcore/luni/)/[src](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/)/[main](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/)/[native](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/native/)/[libcore_io_Posix.cpp](http://androidxref.com/7.0.0_r1/xref/libcore/luni/src/main/native/libcore_io_Posix.cpp)
```cpp
static jint Posix_poll(JNIEnv* env, jobject, jobjectArray javaStructs, jint timeoutMs) {

//反射获取structPollfd.java属性的属性id
    static jfieldID fdFid = env->GetFieldID(JniConstants::structPollfdClass, "fd", "Ljava/io/FileDescriptor;");
    static jfieldID eventsFid = env->GetFieldID(JniConstants::structPollfdClass, "events", "S");
    static jfieldID reventsFid = env->GetFieldID(JniConstants::structPollfdClass, "revents", "S");
//转化为ndk底层的文件描述符
    // Turn the Java android.system.StructPollfd[] into a C++ struct pollfd[].
    size_t arrayLength = env->GetArrayLength(javaStructs);
    std::unique_ptr<struct pollfd[]> fds(new struct pollfd[arrayLength]);
    memset(fds.get(), 0, sizeof(struct pollfd) * arrayLength);
    size_t count = 0; // Some trailing array elements may be irrelevant. (See below.)
    for (size_t i = 0; i < arrayLength; ++i) {
        ScopedLocalRef<jobject> javaStruct(env, env->GetObjectArrayElement(javaStructs, i));
        if (javaStruct.get() == NULL) {
            break; // We allow trailing nulls in the array for caller convenience.
        }
        ScopedLocalRef<jobject> javaFd(env, env->GetObjectField(javaStruct.get(), fdFid));
        if (javaFd.get() == NULL) {
            break; // We also allow callers to just clear the fd field (this is what Selector does).
        }
        fds[count].fd = jniGetFDFromFileDescriptor(env, javaFd.get());
        fds[count].events = env->GetShortField(javaStruct.get(), eventsFid);
        ++count;
    }

    std::vector<AsynchronousCloseMonitor*> monitors;
    for (size_t i = 0; i < count; ++i) {
        monitors.push_back(new AsynchronousCloseMonitor(fds[i].fd));
    }
//循环监听
    int rc;
    while (true) {
        timespec before;
        clock_gettime(CLOCK_MONOTONIC, &before);
//poll 阻塞进程
        rc = poll(fds.get(), count, timeoutMs);
        if (rc >= 0 || errno != EINTR) {
            break;
        }

        // We got EINTR. Work out how much of the original timeout is still left.
        if (timeoutMs > 0) {
            timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);

            timespec diff;
            diff.tv_sec = now.tv_sec - before.tv_sec;
            diff.tv_nsec = now.tv_nsec - before.tv_nsec;
            if (diff.tv_nsec < 0) {
                --diff.tv_sec;
                diff.tv_nsec += 1000000000;
            }

            jint diffMs = diff.tv_sec * 1000 + diff.tv_nsec / 1000000;
            if (diffMs >= timeoutMs) {
                rc = 0; // We have less than 1ms left anyway, so just time out.
                break;
            }

            timeoutMs -= diffMs;
        }
    }

    for (size_t i = 0; i < monitors.size(); ++i) {
        delete monitors[i];
    }
    if (rc == -1) {
        throwErrnoException(env, "poll");
        return -1;
    }
//唤醒之后更新runSelectLooper中的revents标识位，revents
    // Update the revents fields in the Java android.system.StructPollfd[].
    for (size_t i = 0; i < count; ++i) {
        ScopedLocalRef<jobject> javaStruct(env, env->GetObjectArrayElement(javaStructs, i));
        if (javaStruct.get() == NULL) {
            return -1;
        }
        env->SetShortField(javaStruct.get(), reventsFid, fds[i].revents);
    }
    return rc;
}
```

这个代码做了三件事情：
- 1.通过反射获取structPollfd.java中fd属性，revents，events属性。把这些参数设置到pollfd[] fds队列中。
- 2. 把fds设置到poll进行监听
- 3. 更新java层的structPollfd队列。

核心是第二步骤，linux的poll的函数。
而poll函数的作用就是如果没有检测到文件描述符的变化，则进程进入到睡眠状态，等到有人唤醒。由于此时传入的timeout为0，则不设置超时等待时间。

那么我们可以清楚的知道了，structPollfd做三个属性是什么。

- 第一个文件描述符，用来poll监听该文件描述符是否出现了变化。在这里还记得，传入的是zygote的socket文件吗？也就是说此时poll在监听socket是否出现了变化。

- 第二个event，作为pollfd中事件掩码的参数

- 第三个revent，代表了该文件描述符是否产生了变化。

因此,在每一次调用完Os.poll之后，如果socket有唤醒之后，会更新StructPollfd中的数据，也就有了下面这段判断逻辑
```java
            for (int i = pollFds.length - 1; i >= 0; --i) {
                if ((pollFds[i].revents & POLLIN) == 0) {
                    continue;
                }
...
             }
```
唤醒之后直接循环pollFds中，判断revents是否有变化，和POLLIN（实际上是0）相于不为0则表示socket文件变化了，才有下面的加入peers列表以及通过runOnce启动进程。

通过这样的优化，就能做到，当没有socket接入的时候，进程休眠，腾出了cpu资源。当socket接入，则唤醒进程，进入到accept，等待数据的接入。这样就能大大的提升了其中的资源利用率。（一些普通的web服务器也是如此的设计的）


这里只是解释了LocalSocket的服务端。

###Zygote 客户端
实际上一般的ZygoteSocket的客户端，一般为SystemServer中的ActivitymanagerService.

我们看看在Android 7.0中当不存在对应的应用进程时候，会调用startProcessLocked方法中Process的start方法。
最终会调用
```java
 public static final String ZYGOTE_SOCKET = "zygote";


    private static ZygoteState openZygoteSocketIfNeeded(String abi) throws ZygoteStartFailedEx {
        if (primaryZygoteState == null || primaryZygoteState.isClosed()) {
            try {
                primaryZygoteState = ZygoteState.connect(ZYGOTE_SOCKET);
            } catch (IOException ioe) {
                throw new ZygoteStartFailedEx("Error connecting to primary zygote", ioe);
            }
        }

        if (primaryZygoteState.matches(abi)) {
            return primaryZygoteState;
        }

        // The primary zygote didn't match. Try the secondary.
        if (secondaryZygoteState == null || secondaryZygoteState.isClosed()) {
            try {
            secondaryZygoteState = ZygoteState.connect(SECONDARY_ZYGOTE_SOCKET);
            } catch (IOException ioe) {
                throw new ZygoteStartFailedEx("Error connecting to secondary zygote", ioe);
            }
        }

        if (secondaryZygoteState.matches(abi)) {
            return secondaryZygoteState;
        }

        throw new ZygoteStartFailedEx("Unsupported zygote ABI: " + abi);
    }
```

这里的核心会调用一次ZygoteState的connect方法。

```java
        public static ZygoteState connect(String socketAddress) throws IOException {
            DataInputStream zygoteInputStream = null;
            BufferedWriter zygoteWriter = null;
            final LocalSocket zygoteSocket = new LocalSocket();

            try {
                zygoteSocket.connect(new LocalSocketAddress(socketAddress,
                        LocalSocketAddress.Namespace.RESERVED));

                zygoteInputStream = new DataInputStream(zygoteSocket.getInputStream());

                zygoteWriter = new BufferedWriter(new OutputStreamWriter(
                        zygoteSocket.getOutputStream()), 256);
            } catch (IOException ex) {
                try {
                    zygoteSocket.close();
                } catch (IOException ignore) {
                }

                throw ex;
            }

            String abiListString = getAbiList(zygoteWriter, zygoteInputStream);
            Log.i("Zygote", "Process: zygote socket opened, supported ABIS: " + abiListString);

            return new ZygoteState(zygoteSocket, zygoteInputStream, zygoteWriter,
                    Arrays.asList(abiListString.split(",")));
        }
```

此时会尝试的通过zygoteSocket也就是LocalSocket 去连接名为zygote的socket。也就是我们最开始初始化的在ZygoteInit中registerZygoteSocket的socket名字。

调用connect方法，唤醒Os.poll方法之后，再唤醒LocalServerSocket.accept方法，在循环的下一个，调用runOnce。

那么zygote又是怎么启动ActivityThread，这个应用第一个启动的类呢？

第一次看runOnce代码的老哥可能会被这一行蒙蔽了：
```java
ZygoteConnection newPeer = acceptCommandPeer(abiList);
```
实际上在ZygoteConnection中，这个abiList不起任何作用。真正起作用的是ZygoteConnection.runOnce中readArgumentList
方法。
文件/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[core](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/)/[java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/)/[com](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/)/[os](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/)/[ZygoteConnection.java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/ZygoteConnection.java)

```
private String[] readArgumentList()
            throws IOException {

        /**
         * See android.os.Process.zygoteSendArgsAndGetPid()
         * Presently the wire format to the zygote process is:
         * a) a count of arguments (argc, in essence)
         * b) a number of newline-separated argument strings equal to count
         *
         * After the zygote process reads these it will write the pid of
         * the child or -1 on failure.
         */

        int argc;

        try {
            String s = mSocketReader.readLine();

            if (s == null) {
                // EOF reached.
                return null;
            }
            argc = Integer.parseInt(s);
        } catch (NumberFormatException ex) {
            Log.e(TAG, "invalid Zygote wire format: non-int at argc");
            throw new IOException("invalid wire format");
        }

        // See bug 1092107: large argc can be used for a DOS attack
        if (argc > MAX_ZYGOTE_ARGC) {
            throw new IOException("max arg count exceeded");
        }

        String[] result = new String[argc];
        for (int i = 0; i < argc; i++) {
            result[i] = mSocketReader.readLine();
            if (result[i] == null) {
                // We got an unexpected EOF.
                throw new IOException("truncated request");
            }
        }

        return result;
    }
```

看吧实际上所有的字符串都是通过zygote的SocketReader读取出来，再赋值给上层。进行fork出新的进程。
在ActivityManagerService的startProcessLocked
```java
if (entryPoint == null) entryPoint = "android.app.ActivityThread";

    Process.ProcessStartResult startResult = Process.start(entryPoint,
                    app.processName, uid, uid, gids, debugFlags, mountExternal,
                    app.info.targetSdkVersion, app.info.seinfo, requiredAbi, instructionSet,
                    app.info.dataDir, entryPointArgs);
```
第一个参数就是ActivityThread，通过start方法，来打runOnce之后，进去handleChildProc，把ActivityThread的main反射出来，开始了Activity的初始化。而实际上Process.start方法就是一个socket往Zygote中写数据。


#### handleChildProc
文件:/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[core](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/)/[java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/)/[com](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/)/[os](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/)/[ZygoteInit.java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/ZygoteInit.java)

因此，当fork之后，我们继续回到ZygoteInit的handleChildProc子进程处理。
```java
private void handleChildProc(Arguments parsedArgs,
            FileDescriptor[] descriptors, FileDescriptor pipeFd, PrintStream newStderr)
            throws ZygoteInit.MethodAndArgsCaller {
        closeSocket();
        ZygoteInit.closeServerSocket();

        if (descriptors != null) {
            try {
                Os.dup2(descriptors[0], STDIN_FILENO);
                Os.dup2(descriptors[1], STDOUT_FILENO);
                Os.dup2(descriptors[2], STDERR_FILENO);

                for (FileDescriptor fd: descriptors) {
                    IoUtils.closeQuietly(fd);
                }
                newStderr = System.err;
            } catch (ErrnoException ex) {
                Log.e(TAG, "Error reopening stdio", ex);
            }
        }

        if (parsedArgs.niceName != null) {
            Process.setArgV0(parsedArgs.niceName);
        }

        // End of the postFork event.
        Trace.traceEnd(Trace.TRACE_TAG_ACTIVITY_MANAGER);
        if (parsedArgs.invokeWith != null) {
            WrapperInit.execApplication(parsedArgs.invokeWith,
                    parsedArgs.niceName, parsedArgs.targetSdkVersion,
                    VMRuntime.getCurrentInstructionSet(),
                    pipeFd, parsedArgs.remainingArgs);
        } else {
            RuntimeInit.zygoteInit(parsedArgs.targetSdkVersion,
                    parsedArgs.remainingArgs, null /* classLoader */);
        }
    }
```
子进程将关闭socket，关闭socket的观测的文件描述符。这里就能完好的让进程的fdtable(文件描述符表)腾出更多的控件。接着走RuntimeInit.zygoteInit.接下来的逻辑就和SystemServer一样。同样是反射了main方法，nativeZygoteInit 同样会为新的App绑定继承新的Binder底层loop,commonInit 为App的进程初始化异常处理事件。我们可以来看看ActivityThread中的main方法。


文件：/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[core](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/)/[java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/)/[android](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/android/app/ActivityThread.java)

```java
public static void main(String[] args) {
...

        Looper.prepareMainLooper();

        ActivityThread thread = new ActivityThread();
        thread.attach(false);

        if (sMainThreadHandler == null) {
            sMainThreadHandler = thread.getHandler();
        }

        if (false) {
            Looper.myLooper().setMessageLogging(new
                    LogPrinter(Log.DEBUG, "ActivityThread"));
        }

        Looper.loop();

        throw new RuntimeException("Main thread loop unexpectedly exited");
    }
```

在这里面初始化了ActivityThread对象，并且传入attach方法。

 #### ActivityThread的绑定
```java
private void attach(boolean system) {
        sCurrentActivityThread = this;
        mSystemThread = system;
        if (!system) {
            ViewRootImpl.addFirstDrawHandler(new Runnable() {
                @Override
                public void run() {
                    ensureJitEnabled();
                }
            });
            android.ddm.DdmHandleAppName.setAppName("<pre-initialized>",
                                                    UserHandle.myUserId());
            RuntimeInit.setApplicationObject(mAppThread.asBinder());
            final IActivityManager mgr = ActivityManagerNative.getDefault();
            try {
                mgr.attachApplication(mAppThread);
            } catch (RemoteException ex) {
                // Ignore
            }
            // Watch for getting close to heap limit.
            BinderInternal.addGcWatcher(new Runnable() {
                @Override public void run() {
                    if (!mSomeActivitiesChanged) {
                        return;
                    }
                    Runtime runtime = Runtime.getRuntime();
                    long dalvikMax = runtime.maxMemory();
                    long dalvikUsed = runtime.totalMemory() - runtime.freeMemory();
                    if (dalvikUsed > ((3*dalvikMax)/4)) {
                        if (DEBUG_MEMORY_TRIM) Slog.d(TAG, "Dalvik max=" + (dalvikMax/1024)
                                + " total=" + (runtime.totalMemory()/1024)
                                + " used=" + (dalvikUsed/1024));
                        mSomeActivitiesChanged = false;
                        try {
                            mgr.releaseSomeActivities(mAppThread);
                        } catch (RemoteException e) {
                        }
                    }
                }
            });
        } else {
...
        }

        // add dropbox logging to libcore
        DropBox.setReporter(new DropBoxReporter());

        ViewRootImpl.addConfigCallback(new ComponentCallbacks2() {
            @Override
            public void onConfigurationChanged(Configuration newConfig) {
                synchronized (mResourcesManager) {
                    // We need to apply this change to the resources
                    // immediately, because upon returning the view
                    // hierarchy will be informed about it.
                    if (mResourcesManager.applyConfigurationToResourcesLocked(newConfig, null)) {
                        // This actually changed the resources!  Tell
                        // everyone about it.
                        if (mPendingConfiguration == null ||
                                mPendingConfiguration.isOtherSeqNewer(newConfig)) {
                            mPendingConfiguration = newConfig;
                            
                            sendMessage(H.CONFIGURATION_CHANGED, newConfig);
                        }
                    }
                }
            }
            @Override
            public void onLowMemory() {
            }
            @Override
            public void onTrimMemory(int level) {
            }
        });
    }
```
实际上这里做的事情核心有两个:
- 第一个把ApplictionThread绑定到AMS，让之后我们startActivity能够通过这个Binder对象找到对应的方法，从而正确的执行Activity中的正确的生命周期。同时为Binder添加gc的监听者。Binder的详细情况会在Binder解析中了解到
- 第二个就是为ViewRootImpl设置内存管理。这个类将会在后的view的绘制了解到。


至此，从Linux内核启动到应用的AcivityThread的大体流程就完成了。


# 优化与思考
Android系统这么写Zygote孵化流程真的最佳的吗？辉哥曾经提问过一个问题，framework的启动流程该怎么优化。

我们去翻翻4.4的整个流程和android 7.0做对比。发现除了加载虚拟机是从art变成dvm之外，其他逻辑大体上一致。

唯一不同的就是runSelectLoop方法出现了变化。
android 4.4.4 
/[frameworks](http://androidxref.com/4.4.4_r1/xref/frameworks/)/[base](http://androidxref.com/4.4.4_r1/xref/frameworks/base/)/[core](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/)/[java](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/)/[com](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/com/android/internal/)/[os](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/com/android/internal/os/)/[ZygoteInit.java](http://androidxref.com/4.4.4_r1/xref/frameworks/base/core/java/com/android/internal/os/ZygoteInit.java)

```java
static final int GC_LOOP_COUNT = 10;

private static void runSelectLoop() throws MethodAndArgsCaller {
        ArrayList<FileDescriptor> fds = new ArrayList<FileDescriptor>();
        ArrayList<ZygoteConnection> peers = new ArrayList<ZygoteConnection>();
        FileDescriptor[] fdArray = new FileDescriptor[4];

        fds.add(sServerSocket.getFileDescriptor());
        peers.add(null);

        int loopCount = GC_LOOP_COUNT;
        while (true) {
            int index;

            /*
             * Call gc() before we block in select().
             * It's work that has to be done anyway, and it's better
             * to avoid making every child do it.  It will also
             * madvise() any free memory as a side-effect.
             *
             * Don't call it every time, because walking the entire
             * heap is a lot of overhead to free a few hundred bytes.
             */
//做一次gc为了给每个子进程腾出内存空间
            if (loopCount <= 0) {
                gc();
                loopCount = GC_LOOP_COUNT;
            } else {
                loopCount--;
            }

//每一次通过select检测array中的fd有什么变化。
            try {
                fdArray = fds.toArray(fdArray);
                index = selectReadable(fdArray);
            } catch (IOException ex) {
                throw new RuntimeException("Error in select()", ex);
            }

//下面的逻辑一样和之前的一样
            if (index < 0) {
                throw new RuntimeException("Error in select()");
            } else if (index == 0) {
                ZygoteConnection newPeer = acceptCommandPeer();
                peers.add(newPeer);
                fds.add(newPeer.getFileDesciptor());
            } else {
                boolean done;
                done = peers.get(index).runOnce();

                if (done) {
                    peers.remove(index);
                    fds.remove(index);
                }
            }
        }
    }
```

这里稍微解释一下，在低版本fds和peers的意义还是没有多少变动，多了一个限制一次性最多也就4个ZygoteConnection监听。主要去看看下面的死循环之前的操作。

```java
            try {
                fdArray = fds.toArray(fdArray);
                index = selectReadable(fdArray);
            } catch (IOException ex) {
                throw new RuntimeException("Error in select()", ex);
            }
```
这里面的代码实际上和上面的Os.poll那一段的类似。是为了监听socket中哪些出现了变化，而后唤醒进程。
这个方法直接调用的是native方法。
```cpp
static jint com_android_internal_os_ZygoteInit_selectReadable (
        JNIEnv *env, jobject clazz, jobjectArray fds)
{
...
    FD_ZERO(&fdset);
//获取ndk层的fd
    int nfds = 0;
    for (jsize i = 0; i < length; i++) {
        jobject fdObj = env->GetObjectArrayElement(fds, i);
        if  (env->ExceptionOccurred() != NULL) {
            return -1;
        }
        if (fdObj == NULL) {
            continue;
        }
        int fd = jniGetFDFromFileDescriptor(env, fdObj);
        if  (env->ExceptionOccurred() != NULL) {
            return -1;
        }

        FD_SET(fd, &fdset);

        if (fd >= nfds) {
            nfds = fd + 1;
        }
    }
//select死循环阻塞
    int err;
    do {
        err = select (nfds, &fdset, NULL, NULL, NULL);
    } while (err < 0 && errno == EINTR);

    if (err < 0) {
        jniThrowIOException(env, errno);
        return -1;
    }
//查看哪些fd出现了变化，把index回调上去
    for (jsize i = 0; i < length; i++) {
        jobject fdObj = env->GetObjectArrayElement(fds, i);
        if  (env->ExceptionOccurred() != NULL) {
            return -1;
        }
        if (fdObj == NULL) {
            continue;
        }
        int fd = jniGetFDFromFileDescriptor(env, fdObj);
        if  (env->ExceptionOccurred() != NULL) {
            return -1;
        }
        if (FD_ISSET(fd, &fdset)) {
            return (jint)i;
        }
    }
    return -1;
}
```
这个函数分为三个部分：
- 1. 从java层获取fd的对象，通过jniGetFDFromFileDescriptor转化为具体的fd。每一次都加一个一,为select函数做准备。
- 2.调用select，监听所有的文件描述符中的变化
- 3.寻找变化的文件描述符（socket）对应的index，唤醒并且接受socket。


如果不太懂Linux api select函数，这里放出一个写select的比较好的博文：
https://www.cnblogs.com/skyfsm/p/7079458.html

这里简单的解释一下，select的参数。第一个参数，代表了有多少文件描述符加入了，此时只有一个，第二个参数，把fd每个参数对应的标志位，一旦这个标志位出现了变动，则代表这个文件描述符出现变化，socket接入了。其他先可以不管。

因此在最下面的那一段函数中，通过FD_ISSET的方法，判断变动的标志位，找到对应的fd，把对应的index返回。

这样就能正确找到哪个socket。并且处理对应的ZygoteConnection。

上个图总结：
![zygote通信原理.png](/images/Zygote通信原理.png)



## 思考
经过两者的比较，为什么在4.4.4版本使用select()去做，而到了7.0版本使用了poll。为什么这么做？先说说两个函数之间的区别。

简单的说，select和poll本质上都是对文件描述符的集合进行轮询查找，哪些socket出现了变化并且告诉Zygote。然而api的不同导致两者之间的策略不一样。

在4.4时代，大部分的手机内存吃紧（这一点从runLoop每隔10次就要gc一次就知道了），而select的好处就是每一次轮询都是直接修正每一个fd对应的标志位，速度较快。缺点是，一段标志位使用过每一个位上的0或者1来判断，也就限制了最大连接数量。

而7.0时代，大部分手机的性能变得比较好了。资源不再吃紧了，此时更换为poll函数。该函数的作用和select很相似。不过每一次轮询fd，都要修改pollfd结构体内部的标志位。这样就脱离标志位的限制了。

所以说，对于不同的api的，没有最好，只有最适用。

#### 愚见
难道没办法，更好的办法吗？有！这只是个人看法，还记得前几年流行的ngnx吗？这个的底层是用epoll来实现的。

这种实现和单一的阻塞不一样。而是异步的IO。这方法只有Linux 2.6才开始支持。这个方法相比于select和poll。不是简单的轮询，因为当量级到了一定的时候，轮询的速度必定慢下来。而是通过回调的机制去处理。每一次通过内存映射的方式查找对应的fd，并且回调。这样就省去了内存在调用fd时候造成的拷贝（从内核空间到用户空间）。

其次，epoll这个函数没有数量的限制，而是由一个文件描述符去控制所有的文件描述符。

基于这两个理由，很明显epoll才是最佳的选择。

但是，最佳就必须选择吗？不，我们只选择了最合适的。我刚才看了下android 9.0的源码。发现还是继续使用poll机制。对于android来说zygote诞生出新的进程的情况不多见，量级远没有达到服务器的地步，加上使用epoll，下面的fork的机制可能变动大，没有选择也是情理之中。

当然，如果有哥们看过Handler的源码，就知道Handler有一层ndk层，下层也是用epoll做等待死循环处理。有机会再源码解析解析。



# 总结

实际上最后这一段Zygote孵化原理，我发现老罗的书，还有网上的资料都说不详细，但是这却是最重要的一环，是Zygote沟通应用程序的核心代码。特此在此记录一下。

那么Zygote诞生做了什么？在Activity启动前的角色是什么？现在就明白了。

- 1.Zygote是init进程之后第一个诞生出来的孵化进程。就以Android系统的framework来说，Zygote是Android系统一切进程的母亲。

- 2.Zygote第一个孵化的进程是SystemServer进程。

- 3.初始化虚拟机是通过jniInvoaction，加载对应的so库

- 4.SystemServer进程初始化，AMS，WMS，PMS，DisplayManager（显示），InputManager（键盘）,PowerManager（电源）...

- 5.Zygote 诞生新的进程都是通过fork诞生的。

- 6.Zygote 开启socket监听死循环，在低版本使用select来阻塞，高版本使用poll来阻塞。

参考资料：
https://segmentfault.com/a/1190000003063859?utm_source=tag-newest

https://www.cnblogs.com/amanlikethis/p/6915485.html

#### 题外话
无语了，没办法发长一点的文章，只能拆开来放出来了。
写的比较粗浅，也不是很专业。看到错误可以找我纠正。估计很多人都懂这些了，更多的只是把这两年学习的复习和整理。
