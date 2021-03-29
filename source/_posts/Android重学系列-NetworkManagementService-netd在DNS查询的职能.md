---
title: 'Android重学系列 NetworkManagementService,netd在DNS查询的职能'
top: false
cover: false
date: 2020-11-29 21:00:31
img:
tag:
description:
author: yjy239
summary:
categories: 网络编程
tags:
- Android
- 网络编程
---



# 前言

前四篇文章讲述了Okhttp的核心原理，得知Okhttp是基于Socket开发的，而不是基于HttpUrlConnection开发的。

其中对于客户端来说，核心有如下四个步骤：

- 1.dns lookup 把资源地址转化为ip地址
- 2.socket.connect 通过socket把客户端和服务端联系起来
- 3.socket.starthandshake
- 4.socket.handshake

本文着重来看看DNS做了什么事情。在Okhttp默认的DNS 对象就是如下这个DnsSystem对象。

```kotlin
    private class DnsSystem : Dns {
      override fun lookup(hostname: String): List<InetAddress> {
        try {
          return InetAddress.getAllByName(hostname).toList()
        } catch (e: NullPointerException) {
          throw UnknownHostException("Broken system behaviour for dns lookup of $hostname").apply {
            initCause(e)
          }
        }
      }
    }
```

然而本文并不会立即和大家聊DNS的解析过程。因为在Android的网络模块中，存在着2个十分重要的对象：
- 1.用于监控网络状态的 NetworkManagementService
- 2.Android/Linux 网络监控核心netd进程。

而DNS的查询恰好是通过2个模块的互相运作才能执行。

# 正文

## netd进程启动

文件:/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[netd](http://androidxref.com/9.0.0_r3/xref/system/netd/)/[server](http://androidxref.com/9.0.0_r3/xref/system/netd/server/)/[netd.rc](http://androidxref.com/9.0.0_r3/xref/system/netd/server/netd.rc)

```
service netd /system/bin/netd
    class main
    socket netd stream 0660 root system
    socket dnsproxyd stream 0660 root inet
    socket mdns stream 0660 root system
    socket fwmarkd stream 0660 root inet
    onrestart restart zygote
    onrestart restart zygote_secondary
```

关于rc文件如何解析，本文就不多赘述了。详情可以阅读我写的 [系统启动到Activity(上)](https://www.jianshu.com/p/68758696b2ab) 一文。

能看到在这个过程中，会启动一个`netd` 进程，接着会启动`netd`,`dnsproxyd`,`mdns`,`fwmarkd` 四个socket。

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[netd](http://androidxref.com/9.0.0_r3/xref/system/netd/)/[server](http://androidxref.com/9.0.0_r3/xref/system/netd/server/)/[main.cpp](http://androidxref.com/9.0.0_r3/xref/system/netd/server/main.cpp)

```cpp
int main() {
    using android::net::gCtls;
    Stopwatch s;

    remove_pid_file();

    blockSigpipe();


    for (const auto& sock : { CommandListener::SOCKET_NAME,
                              DnsProxyListener::SOCKET_NAME,
                              FwmarkServer::SOCKET_NAME,
                              MDnsSdListener::SOCKET_NAME }) {
        setCloseOnExec(sock);
    }

    NetlinkManager *nm = NetlinkManager::Instance();
    if (nm == nullptr) {

        exit(1);
    };

    gCtls = new android::net::Controllers();
    gCtls->init();

    CommandListener cl;
    nm->setBroadcaster((SocketListener *) &cl);

    if (nm->start()) {
...
        exit(1);
    }

    std::unique_ptr<NFLogListener> logListener;
    {
        auto result = makeNFLogListener();
        if (!isOk(result)) {
...
            exit(1);
        }
        logListener = std::move(result.value());
        auto status = gCtls->wakeupCtrl.init(logListener.get());
...
    }


    setenv("ANDROID_DNS_MODE", "local", 1);
    DnsProxyListener dpl(&gCtls->netCtrl, &gCtls->eventReporter);
    if (dpl.startListener()) {

        exit(1);
    }

    MDnsSdListener mdnsl;
    if (mdnsl.startListener()) {

        exit(1);
    }

    FwmarkServer fwmarkServer(&gCtls->netCtrl, &gCtls->eventReporter, &gCtls->trafficCtrl);
    if (fwmarkServer.startListener()) {

        exit(1);
    }

    Stopwatch subTime;
    status_t ret;
    if ((ret = NetdNativeService::start()) != android::OK) {

        exit(1);
    }



    if (cl.startListener()) {

        exit(1);
    }


    write_pid_file();

    NetdHwService mHwSvc;
    if ((ret = mHwSvc.start()) != android::OK) {
        exit(1);
    }

    IPCThreadState::self()->joinThreadPool();

    remove_pid_file();

    exit(0);
}
```

- 1.屏蔽SIGPIPE信号，构建一个`NetlinkManager`单例对象
- 2.实例化`android::net::Controllers`，并调用`init`初始化
- 3.实例化`CommandListener`,这个监听者将会监听名为`netd`的socket
- 4.`NetlinkManager`的`setBroadcaster `把广播消息的发送设置为`CommandListener`，并调用`NetlinkManager`的start方法。
- 5.初始化`NFLogListener ` 日志对象到`Controllers` 中。之后下面所有的组件都会设置该`Controllers` 到其中从而获得日志。
- 5.设置当前`netd`进程的环境变量`ANDROID_DNS_MODE ` 为`local`
- 6.生成`DnsProxyListener `对象并启动线程监听，是DNS发送请求和返回的本地代理对象，监听了`dnsproxyd ` socket
- 7. 生成`MDnsSdListener`对象并启动线程监听`mdns ` socket。这个socket实际上全名为`Multicast DNS Service Service Discovery` 会自动给局域网内没有分配地址的ip给自动分配ip。是基于组播域名服务实现的
- 8.生成一个FwmarkServer对象，并监听`fwmarkd ` socket,这个socket实际上是用来监听标记从防火墙来的数据包。
- 9. 启动Binder服务NetdNativeService，可以跨进程操作中`android::net::Controllers`的行为
- 10.启动CommandListener 对所有socket接口命令监听
- 11.启动`NetdHwService `服务
- 12.通过joinThreadPool 阻塞当前的进程


这里我们分别看看都做了什么。



### NetlinkManager 初始化

```cpp
NetlinkManager *NetlinkManager::Instance() {
    if (!sInstance)
        sInstance = new NetlinkManager();
    return sInstance;
}
```

实例化NetlinkManager对象后，设置一个CommandListener 到NetlinkManager 中。

```cpp
    void setBroadcaster(SocketListener *sl) { mBroadcaster = sl; }
    SocketListener *getBroadcaster() { return mBroadcaster; }
```

接着调用start方法启动`NetlinkManager`.


#### NetlinkManager start

```cpp
int NetlinkManager::start() {
    if ((mUeventHandler = setupSocket(&mUeventSock, NETLINK_KOBJECT_UEVENT,
         0xffffffff, NetlinkListener::NETLINK_FORMAT_ASCII, false)) == NULL) {
        return -1;
    }

    if ((mRouteHandler = setupSocket(&mRouteSock, NETLINK_ROUTE,
                                     RTMGRP_LINK |
                                     RTMGRP_IPV4_IFADDR |
                                     RTMGRP_IPV6_IFADDR |
                                     RTMGRP_IPV6_ROUTE |
                                     (1 << (RTNLGRP_ND_USEROPT - 1)),
         NetlinkListener::NETLINK_FORMAT_BINARY, false)) == NULL) {
        return -1;
    }

    if ((mQuotaHandler = setupSocket(&mQuotaSock, NETLINK_NFLOG,
            NFLOG_QUOTA_GROUP, NetlinkListener::NETLINK_FORMAT_BINARY, false)) == NULL) {
...
    }

    if ((mStrictHandler = setupSocket(&mStrictSock, NETLINK_NETFILTER,
            0, NetlinkListener::NETLINK_FORMAT_BINARY_UNICAST, true)) == NULL) {
...
    }

    return 0;
}
```

这三个步骤都是生成一个socket对象，并设置domain为`PF_NETLINK`,然后设置不同的Type用于监听socket从内核模块释放的信息。

- 1.监听`NETLINK_KOBJECT_UEVENT` 代表的socket端口，代表kobject事件。kobject一般是指内核通知外部某个内核模块卸载和加载的。这里主要监听的是`/sys/class/net`。把获取的数据转化为`ASCII`字符串到NetworkLinker

- 2.监听一个`NETLINK_ROUTE ` 所代表的socket。这个socket就是指内核中routing或link改变时候返回的UEvent消息。监听如`RTMGRP_LINK ` 事件，这样就能从内核模块中获取到当前Android 网络断开还是链接状态。

- 3.监听一个`NETLINK_NETFILTER`所代表的接口。用于控制带宽，带宽可以设置一个预警数值，超过就会发送一个警告。该功能是iptable的功能之一。


### CommandListener 初始化

```
static constexpr const char* SOCKET_NAME = "netd";
```

```cpp
CommandListener::CommandListener() : FrameworkListener(SOCKET_NAME, true) {
    registerLockingCmd(new InterfaceCmd());
    registerLockingCmd(new IpFwdCmd(), gCtls->tetherCtrl.lock);
    registerLockingCmd(new TetherCmd(), gCtls->tetherCtrl.lock);
    registerLockingCmd(new NatCmd(), gCtls->tetherCtrl.lock);
    registerLockingCmd(new ListTtysCmd());
    registerLockingCmd(new PppdCmd());
    registerLockingCmd(new BandwidthControlCmd(), gCtls->bandwidthCtrl.lock);
    registerLockingCmd(new IdletimerControlCmd());
    registerLockingCmd(new ResolverCmd());
    registerLockingCmd(new FirewallCmd(), gCtls->firewallCtrl.lock);
    registerLockingCmd(new ClatdCmd());
    registerLockingCmd(new NetworkCommand());
    registerLockingCmd(new StrictCmd());
}
```

在这里面设置了一个socket名字为`netd `,并在父类`FrameworkListener `进行初始化。

在这一层构造函数中，会注册不同命令的监听。当从`netd`socket中接受到信息的到来就会检测获取第一个参数，是否是对应类型的CMD。

比如说，这里注册了InterfaceCmd对象：
```
CommandListener::InterfaceCmd::InterfaceCmd() :
                 NetdCommand("interface") {
}
```

为这个NetdCommand 设置了一个对应的字符串`interface`.当`netd `socket中监听到第一个参数字符串是`interface`,找到注册到`FrameworkListener`集合中的命令数据，并且调用对应`NetdCommand`的`runCommand`方法,从而执行对应的逻辑。



### DnsProxyListener 初始化
文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[netd](http://androidxref.com/9.0.0_r3/xref/system/netd/)/[server](http://androidxref.com/9.0.0_r3/xref/system/netd/server/)/[DnsProxyListener.cpp](http://androidxref.com/9.0.0_r3/xref/system/netd/server/DnsProxyListener.cpp)

```cpp
static constexpr const char* SOCKET_NAME = "dnsproxyd";
```

```cpp
DnsProxyListener::DnsProxyListener(const NetworkController* netCtrl, EventReporter* eventReporter) :
        FrameworkListener(SOCKET_NAME), mNetCtrl(netCtrl), mEventReporter(eventReporter) {
    registerCmd(new GetAddrInfoCmd(this));
    registerCmd(new GetHostByAddrCmd(this));
    registerCmd(new GetHostByNameCmd(this));
}
```

`DnsProxyListener` 也是`FrameworkListener`派生类。注册了`GetAddrInfoCmd`命令域名查找ip地址对象，`GetHostByAddrCmd`通过返回给定ip地址服务器信息命令对象,`GetHostByNameCmd`通过域名查找服务器信息命令对象.

简单来看看这几个对象注册命令是什么：

##### GetAddrInfoCmd

```cpp
DnsProxyListener::GetAddrInfoCmd::GetAddrInfoCmd(DnsProxyListener* dnsProxyListener) :
    NetdCommand("getaddrinfo"),
    mDnsProxyListener(dnsProxyListener) {
}
```

对应的命令识别字符串是`getaddrinfo`

##### GetHostByAddrCmd

```cpp
DnsProxyListener::GetHostByAddrCmd::GetHostByAddrCmd(const DnsProxyListener* dnsProxyListener) :
        NetdCommand("gethostbyaddr"),
        mDnsProxyListener(dnsProxyListener) {
}
```
对应的命令识别字符串是`gethostbyaddr`


##### GetHostByNameCmd
```cpp
DnsProxyListener::GetHostByNameCmd::GetHostByNameCmd(DnsProxyListener* dnsProxyListener) :
      NetdCommand("gethostbyname"),
      mDnsProxyListener(dnsProxyListener) {
}

```

对应的命令识别字符串是`gethostbyname`


#### DnsProxyListener startListener

```cpp
int SocketListener::startListener(int backlog) {

    if (!mSocketName && mSock == -1) {

        errno = EINVAL;
        return -1;
    } else if (mSocketName) {
        if ((mSock = android_get_control_socket(mSocketName)) < 0) {

            return -1;
        }

        fcntl(mSock, F_SETFD, FD_CLOEXEC);
    }

    if (mListen && listen(mSock, backlog) < 0) {

        return -1;
    } else if (!mListen)
        mClients->push_back(new SocketClient(mSock, false, mUseCmdNum));

    if (pipe(mCtrlPipe)) {

        return -1;
    }

    if (pthread_create(&mThread, NULL, SocketListener::threadStart, this)) {

        return -1;
    }

    return 0;
}
```

能看到这个过程中
- 1.如果遇到需要监听的sokcet的listen的监听方法。但是这里是是生成一个新的SocketClient对象保存当前的需要监听scoket缓存到mClients

- 2.启动新的线程执行`threadStart ` 方法

- 3.线程中会持续监听socket的数据，如果有数据返回就会调用`onDataAvailable`方法到FrameworkListener。



### MDnsSdListener  初始化

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[netd](http://androidxref.com/9.0.0_r3/xref/system/netd/)/[server](http://androidxref.com/9.0.0_r3/xref/system/netd/server/)/[MDnsSdListener.cpp](http://androidxref.com/9.0.0_r3/xref/system/netd/server/MDnsSdListener.cpp)

```cpp
static constexpr const char* SOCKET_NAME = "mdns";
```

```cpp
MDnsSdListener::MDnsSdListener() : FrameworkListener(SOCKET_NAME, true) {
    Monitor *m = new Monitor();
    registerCmd(new Handler(m, this));
}

MDnsSdListener::Handler::Handler(Monitor *m, MDnsSdListener *listener) :
   NetdCommand("mdnssd") {
   mMonitor = m;
   mListener = listener;
}
```

注册了一个`mdnssd` 命令监听。当调用了startListener方法后就会构建一个`mdns`socket 监听`mdnssd`命令的到来。


### FwmarkServer 初始化

```cpp
static constexpr const char* SOCKET_NAME = "fwmarkd";
```

```cpp
FwmarkServer::FwmarkServer(NetworkController* networkController, EventReporter* eventReporter,
                           TrafficController* trafficCtrl)
    : SocketListener(SOCKET_NAME, true),
      mNetworkController(networkController),
      mEventReporter(eventReporter),
      mTrafficCtrl(trafficCtrl) {}
```

首先实例化一个`fwmarkd`socket，并监听这个socket传递过来的内容。

- 1.NetworkController 核心处理的是关于iptables的路由规则的
- 2.EventReporter 则是把调用socket的connect方法后，回调上来的状态数据
- 3.TrafficController 则是进行流量监控。所有流量相关的开销都会记录在`/sys/fs/bpf` 下的文件。比如说当`FwmarkServer`收到回调则会判断命令中是否带有`TAG_SOCKET` 这个枚举也就是数字(8)那么就往`traffic_cookie_tag_map `记录当前的uid以及信息用于标记socket。 

注意`TrafficController`隶属于` eBPF 网络流浪监控模块` 。除了标记和取消标记socket外还承担了删除流量数据的职责。可以同时从`/sys/fs/bpf` 下其他文件中实时的读取不同uid，appid的流量数据。


### NetworkManagementService 初始化

初始化位置在为文件SystemServer中：
```java
            try {
                networkManagement = NetworkManagementService.create(context);
                ServiceManager.addService(Context.NETWORKMANAGEMENT_SERVICE, networkManagement);
            } catch (Throwable e) {
                reportWtf("starting NetworkManagement Service", e);
            }
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[NetworkManagementService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/NetworkManagementService.java)


```java

    static final String NETD_SERVICE_NAME = "netd";

    static NetworkManagementService create(Context context, String socket, SystemServices services)
            throws InterruptedException {
        final NetworkManagementService service =
                new NetworkManagementService(context, socket, services);
        final CountDownLatch connectedSignal = service.mConnectedSignal;
        service.mThread.start();
        connectedSignal.await();
        service.connectNativeNetdService();
        return service;
    }

    public static NetworkManagementService create(Context context) throws InterruptedException {
        return create(context, NETD_SERVICE_NAME, new SystemServices());
    }
```

- 1.传入的是SystemServer的Context对象
- 2.设置一个名为`netd`的socket名到NetworkManagementService中。
- 3.生成一个SystemServices到NetworkManagementService中。
- 4.通过connectedSignal等待`SystemServices`完成后，通过`SystemServices`的`connectNativeNetdService`链接到`netd`进程

```java
    private NetworkManagementService(
            Context context, String socket, SystemServices services) {
        mContext = context;
        mServices = services;

        // make sure this is on the same looper as our NativeDaemonConnector for sync purposes
        mFgHandler = new Handler(FgThread.get().getLooper());


        //PowerManager pm = (PowerManager)context.getSystemService(Context.POWER_SERVICE);
        PowerManager.WakeLock wl = null; //pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, NETD_TAG);

        mConnector = new NativeDaemonConnector(
                new NetdCallbackReceiver(), socket, 10, NETD_TAG, 160, wl,
                FgThread.get().getLooper());
        mThread = new Thread(mConnector, NETD_TAG);

        mDaemonHandler = new Handler(FgThread.get().getLooper());

        // Add ourself to the Watchdog monitors.
        Watchdog.getInstance().addMonitor(this);

        mServices.registerLocalService(new LocalService());

        synchronized (mTetheringStatsProviders) {
            mTetheringStatsProviders.put(new NetdTetheringStatsProvider(), "netd");
        }
    }
```
 

- 1.在其中生成一个持有FgThread线程Looper的Handler，注意FgThread 是一个HandlerThread
- 2.生成一个NativeDaemonConnector 后台常驻链接，链接到`netd`进程中，并通过`NetdCallbackReceiver`监听`netd`进程的回调。
- 3.mDaemonHandler 也是属于`FgThread` 线程的Looper
- 4.`Watchdog`监听当前的`NetworkManagementService ` 的是否卡死的状态。



#### NativeDaemonConnector 实例化

注意 `NativeDaemonConnector`是一个Runnable对象，在上面一节中进行Thread的实例化和start后会启动run方法。

```java
    NativeDaemonConnector(INativeDaemonConnectorCallbacks callbacks, String socket,
            int responseQueueSize, String logTag, int maxLogSize, PowerManager.WakeLock wl) {
        this(callbacks, socket, responseQueueSize, logTag, maxLogSize, wl,
                FgThread.get().getLooper());
    }

    NativeDaemonConnector(INativeDaemonConnectorCallbacks callbacks, String socket,
            int responseQueueSize, String logTag, int maxLogSize, PowerManager.WakeLock wl,
            Looper looper) {
        mCallbacks = callbacks;
        mSocket = socket;
        mResponseQueue = new ResponseQueue(responseQueueSize);
        mWakeLock = wl;
        if (mWakeLock != null) {
            mWakeLock.setReferenceCounted(true);
        }
        mLooper = looper;
        mSequenceNumber = new AtomicInteger(0);
        TAG = logTag != null ? logTag : "NativeDaemonConnector";
        mLocalLog = new LocalLog(maxLogSize);
    }



    @Override
    public void run() {
        mCallbackHandler = new Handler(mLooper, this);

        while (true) {
            if (isShuttingDown()) break;
            try {
                listenToSocket();
            } catch (Exception e) {
                loge("Error in NativeDaemonConnector: " + e);
                if (isShuttingDown()) break;
                SystemClock.sleep(5000);
            }
        }
    }
```

- 1.在构造函数中`mResponseQueue`就是`netd`发送的过来的消息的消息队列
- 2.在run方法中有一个死循环，调用`listenToSocket`不断的监听socket的到来。

##### listenToSocket

```java

    private LocalSocketAddress determineSocketAddress() {

        if (mSocket.startsWith("__test__") && Build.IS_DEBUGGABLE) {
            return new LocalSocketAddress(mSocket);
        } else {
            return new LocalSocketAddress(mSocket, LocalSocketAddress.Namespace.RESERVED);
        }
    }

    private void listenToSocket() throws IOException {
        LocalSocket socket = null;

        try {
            socket = new LocalSocket();
            LocalSocketAddress address = determineSocketAddress();

            socket.connect(address);

            InputStream inputStream = socket.getInputStream();
            synchronized (mDaemonLock) {
                mOutputStream = socket.getOutputStream();
            }

            mCallbacks.onDaemonConnected();

            FileDescriptor[] fdList = null;
            byte[] buffer = new byte[BUFFER_SIZE];
            int start = 0;

            while (true) {
                int count = inputStream.read(buffer, start, BUFFER_SIZE - start);
                if (count < 0) {
                    loge("got " + count + " reading with start = " + start);
                    break;
                }
                fdList = socket.getAncillaryFileDescriptors();

                // Add our starting point to the count and reset the start.
                count += start;
                start = 0;

                for (int i = 0; i < count; i++) {
                    if (buffer[i] == 0) {
                        final String rawEvent = new String(
                                buffer, start, i - start, StandardCharsets.UTF_8);

                        boolean releaseWl = false;
                        try {
                            final NativeDaemonEvent event =
                                    NativeDaemonEvent.parseRawEvent(rawEvent, fdList);

                            log("RCV <- {" + event + "}");

                            if (event.isClassUnsolicited()) {
                                // TODO: migrate to sending NativeDaemonEvent instances
                                if (mCallbacks.onCheckHoldWakeLock(event.getCode())
                                        && mWakeLock != null) {
                                    mWakeLock.acquire();
                                    releaseWl = true;
                                }
                                Message msg = mCallbackHandler.obtainMessage(
                                        event.getCode(), uptimeMillisInt(), 0, event.getRawEvent());
                                if (mCallbackHandler.sendMessage(msg)) {
                                    releaseWl = false;
                                }
                            } else {
                                mResponseQueue.add(event.getCmdNumber(), event);
                            }
                        } catch (IllegalArgumentException e) {
                            log("Problem parsing message " + e);
                        } finally {
                            if (releaseWl) {
                                mWakeLock.release();
                            }
                        }

                        start = i + 1;
                    }
                }


                if (start != count) {
                    final int remaining = BUFFER_SIZE - start;
                    System.arraycopy(buffer, start, buffer, 0, remaining);
                    start = remaining;
                } else {
                    start = 0;
                }
            }
        } catch (IOException ex) {
            loge("Communications error: " + ex);
            throw ex;
        } finally {
  ...
        }
    }
```

这个过程实际上做的事情就是一件：
- 1.不断的监听从`netd`socket返回回来的信息，并一一添加到ResponseQueue中，进行消费回调外部监听。

这里的`netd`socket实际上就是指`netd`进程创建的时候，通过app_main 解析init.rc创建出来的socket。而在`netd`进程也构造了这个socket，随时进行发送或者监听信息。



值得注意的是，这里面有一个有趣的对象`PowerManager.WakeLock`.每当从`netd`监听到消息的时候，发现从`netd`进程传送过来的事件是从`netd`主动来的请求，那么就会调用`PowerManager.WakeLock` 立即唤醒设备发送通过Handler发送数据。

这也是为什么耗电量会被Android系统监听到的原因的，这个WakeLock 唤醒锁是一个重要的依据。


## InetAddress.getAllByName DNS 查询过程

对NetworkManagementService以及netd 两个服务都有了大致的了解后，我们才好开展本次重点话题，Android是怎么进行通过域名进行DNS查询到ip地址的。

```java
static final InetAddressImpl impl = new Inet6AddressImpl();

     */
    public static InetAddress[] getAllByName(String host)
        throws UnknownHostException {

        return impl.lookupAllHostAddr(host, NETID_UNSET).clone();
    }
```


这个过程实际上是交给了`Inet6AddressImpl`的lookupAllHostAddr处理。


#### Inet6AddressImpl lookupAllHostAddr

```java
    @Override
    public InetAddress[] lookupAllHostAddr(String host, int netId) throws UnknownHostException {
        if (host == null || host.isEmpty()) {

            return loopbackAddresses();
        }

        // Is it a numeric address?
        InetAddress result = InetAddress.parseNumericAddressNoThrow(host);
        if (result != null) {
            result = InetAddress.disallowDeprecatedFormats(host, result);
            if (result == null) {
                throw new UnknownHostException("Deprecated IPv4 address format: " + host);
            }
            return new InetAddress[] { result };
        }

        return lookupHostByName(host, netId);
    }
```


- 1.如果传入的host 为空则通过loopbackAddresses返回，ipv6的默认虚拟回环地址以及ipv4的默认虚拟回环地址。就是我们常说的localhost，ipv4默认为`127.0.0.0/8` 以及 ipv6为`:: 1/128`。虚拟回环地址是一个特殊的网络接口，所有的网络数据都会在这个虚拟的网卡中处理。

- 2.InetAddress的parseNumericAddressNoThrow 处理带有`[:]`格式的ip地址，并通过`Libcore.os.android_getaddrinfo`进行查询，查到了则返回。

- 3.如果不符合上面的格式则调用`lookupHostByName`通过域名查找ip地址。


##### Inet6AddressImpl lookupHostByName

```java
    private static InetAddress[] lookupHostByName(String host, int netId)
            throws UnknownHostException {
        BlockGuard.getThreadPolicy().onNetwork();
        // Do we have a result cached?
        Object cachedResult = addressCache.get(host, netId);
        if (cachedResult != null) {
            if (cachedResult instanceof InetAddress[]) {
                // A cached positive result.
                return (InetAddress[]) cachedResult;
            } else {
                // A cached negative result.
                throw new UnknownHostException((String) cachedResult);
            }
        }
        try {
            StructAddrinfo hints = new StructAddrinfo();
            hints.ai_flags = AI_ADDRCONFIG;
            hints.ai_family = AF_UNSPEC;

            hints.ai_socktype = SOCK_STREAM;
            InetAddress[] addresses = Libcore.os.android_getaddrinfo(host, hints, netId);

            for (InetAddress address : addresses) {
                address.holder().hostName = host;
                address.holder().originalHostName = host;
            }
            addressCache.put(host, netId, addresses);
            return addresses;
        } catch (GaiException gaiException) {
...
        }
    }
```

构建了一个`StructAddrinfo`对象，保存了三个十分重要的标志：
- ai_flags 为AI_ADDRCONFIG
- ai_family 为AF_UNSPEC
- ai_socktype 为SOCK_STREAM

并把StructAddrinfo作为参数传入方法Libcore.os.android_getaddrinfo中处理。


#### Libcore.os.android_getaddrinfo

这个方法实际上就是一个native方法，对应如下文件：
/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[luni](http://androidxref.com/9.0.0_r3/xref/libcore/luni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/)/[native](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/)/[libcore_io_Linux.cpp](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/libcore_io_Linux.cpp)

```cpp
static jobjectArray Linux_android_getaddrinfo(JNIEnv* env, jobject, jstring javaNode,
        jobject javaHints, jint netId) {
    ScopedUtfChars node(env, javaNode);
    if (node.c_str() == NULL) {
        return NULL;
    }

    static jfieldID flagsFid = env->GetFieldID(JniConstants::structAddrinfoClass, "ai_flags", "I");
    static jfieldID familyFid = env->GetFieldID(JniConstants::structAddrinfoClass, "ai_family", "I");
    static jfieldID socktypeFid = env->GetFieldID(JniConstants::structAddrinfoClass, "ai_socktype", "I");
    static jfieldID protocolFid = env->GetFieldID(JniConstants::structAddrinfoClass, "ai_protocol", "I");

    addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_flags = env->GetIntField(javaHints, flagsFid);
    hints.ai_family = env->GetIntField(javaHints, familyFid);
    hints.ai_socktype = env->GetIntField(javaHints, socktypeFid);
    hints.ai_protocol = env->GetIntField(javaHints, protocolFid);

    addrinfo* addressList = NULL;
    errno = 0;
    int rc = android_getaddrinfofornet(node.c_str(), NULL, &hints, netId, 0, &addressList);
    std::unique_ptr<addrinfo, addrinfo_deleter> addressListDeleter(addressList);
    if (rc != 0) {
        throwGaiException(env, "android_getaddrinfo", rc);
        return NULL;
    }

    // Count results so we know how to size the output array.
    int addressCount = 0;
    for (addrinfo* ai = addressList; ai != NULL; ai = ai->ai_next) {
        if (ai->ai_family == AF_INET || ai->ai_family == AF_INET6) {
            ++addressCount;
        } else {
            ALOGE("android_getaddrinfo unexpected ai_family %i", ai->ai_family);
        }
    }
    if (addressCount == 0) {
        return NULL;
    }

    // Prepare output array.
    jobjectArray result = env->NewObjectArray(addressCount, JniConstants::inetAddressClass, NULL);
    if (result == NULL) {
        return NULL;
    }

    // Examine returned addresses one by one, save them in the output array.
    int index = 0;
    for (addrinfo* ai = addressList; ai != NULL; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) {
            // Unknown address family. Skip this address.
            ALOGE("android_getaddrinfo unexpected ai_family %i", ai->ai_family);
            continue;
        }

        // Convert each IP address into a Java byte array.
        sockaddr_storage& address = *reinterpret_cast<sockaddr_storage*>(ai->ai_addr);
        ScopedLocalRef<jobject> inetAddress(env, sockaddrToInetAddress(env, address, NULL));
        if (inetAddress.get() == NULL) {
            return NULL;
        }
        env->SetObjectArrayElement(result, index, inetAddress.get());
        ++index;
    }
    return result;
}
```

这个过程实际上就是从`StructAddrinfo `中拿到`ai_flags `,`ai_family `,`ai_socktype `作为参数传递到`android_getaddrinfofornet`方法中。并把取到的数据保存到Java数组中并返回。

##### android_getaddrinfofornet 从netd进程中查找dns
```cpp
#if defined(__BIONIC__)
extern "C" int android_getaddrinfofornet(const char*, const char*, const struct addrinfo*, unsigned, unsigned, struct addrinfo**);
#else
static inline int android_getaddrinfofornet(const char* hostname, const char* servname,
    const struct addrinfo* hints, unsigned /*netid*/, unsigned /*mark*/, struct addrinfo** res) {
  return getaddrinfo(hostname, servname, hints, res);
}
#endif

```

注意接下来分为2个分之，是调用libc中内置的`getaddrinfo`方法还是调用bionic的`android_getaddrinfofornet`.

一半的jdk都是使用libc内置的方法，而android中都是使用bionic库进行处理。

文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[dns](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/)/[net](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/net/)/[getaddrinfo.c](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/net/getaddrinfo.c)

```java
__BIONIC_WEAK_FOR_NATIVE_BRIDGE
int
getaddrinfo(const char *hostname, const char *servname,
    const struct addrinfo *hints, struct addrinfo **res)
{
	return android_getaddrinfofornet(hostname, servname, hints, NETID_UNSET, MARK_UNSET, res);
}

__BIONIC_WEAK_FOR_NATIVE_BRIDGE
int
android_getaddrinfofornet(const char *hostname, const char *servname,
    const struct addrinfo *hints, unsigned netid, unsigned mark, struct addrinfo **res)
{
	struct android_net_context netcontext = {
		.app_netid = netid,
		.app_mark = mark,
		.dns_netid = netid,
		.dns_mark = mark,
		.uid = NET_CONTEXT_INVALID_UID,
        };
	return android_getaddrinfofornetcontext(hostname, servname, hints, &netcontext, res);
}
```
生成一个`android_net_context` 结构体后，调用 `android_getaddrinfofornetcontext`.

##### android_getaddrinfofornetcontext

```cpp
__BIONIC_WEAK_FOR_NATIVE_BRIDGE
int
android_getaddrinfofornetcontext(const char *hostname, const char *servname,
    const struct addrinfo *hints, const struct android_net_context *netcontext,
    struct addrinfo **res)
{
	struct addrinfo sentinel;
	struct addrinfo *cur;
	int error = 0;
	struct addrinfo ai;
	struct addrinfo ai0;
	struct addrinfo *pai;
	const struct explore *ex;

	/* hostname is allowed to be NULL */
	/* servname is allowed to be NULL */
	/* hints is allowed to be NULL */
	assert(res != NULL);
	assert(netcontext != NULL);
	memset(&sentinel, 0, sizeof(sentinel));
	cur = &sentinel;
	pai = &ai;
	pai->ai_flags = 0;
	pai->ai_family = PF_UNSPEC;
	pai->ai_socktype = ANY;
	pai->ai_protocol = ANY;
	pai->ai_addrlen = 0;
	pai->ai_canonname = NULL;
	pai->ai_addr = NULL;
	pai->ai_next = NULL;

....
	if (hints) {
		/* error check for hints */
		if (hints->ai_addrlen || hints->ai_canonname ||
		    hints->ai_addr || hints->ai_next)
			ERR(EAI_BADHINTS); /* xxx */
		if (hints->ai_flags & ~AI_MASK)
			ERR(EAI_BADFLAGS);
		switch (hints->ai_family) {
		case PF_UNSPEC:
		case PF_INET:
#ifdef INET6
		case PF_INET6:
#endif
			break;
		default:
			ERR(EAI_FAMILY);
		}
		memcpy(pai, hints, sizeof(*pai));

		/*
		 * if both socktype/protocol are specified, check if they
		 * are meaningful combination.
		 */
		if (pai->ai_socktype != ANY && pai->ai_protocol != ANY) {
			for (ex = explore; ex->e_af >= 0; ex++) {
				if (pai->ai_family != ex->e_af)
					continue;
				if (ex->e_socktype == ANY)
					continue;
				if (ex->e_protocol == ANY)
					continue;
				if (pai->ai_socktype == ex->e_socktype
				 && pai->ai_protocol != ex->e_protocol) {
					ERR(EAI_BADHINTS);
				}
			}
		}
	}

	/*
	 * check for special cases.  (1) numeric servname is disallowed if
	 * socktype/protocol are left unspecified. (2) servname is disallowed
	 * for raw and other inet{,6} sockets.
	 */
	if (MATCH_FAMILY(pai->ai_family, PF_INET, 1)
#ifdef PF_INET6
	 || MATCH_FAMILY(pai->ai_family, PF_INET6, 1)
#endif
	    ) {
		ai0 = *pai;	/* backup *pai */

		if (pai->ai_family == PF_UNSPEC) {
#ifdef PF_INET6
			pai->ai_family = PF_INET6;
#else
			pai->ai_family = PF_INET;
#endif
		}
		error = get_portmatch(pai, servname);
		if (error)
			ERR(error);

		*pai = ai0;
	}

	ai0 = *pai;

	/* NULL hostname, or numeric hostname */
...
#if defined(__ANDROID__)
	int gai_error = android_getaddrinfo_proxy(
		hostname, servname, hints, res, netcontext->app_netid);
	if (gai_error != EAI_SYSTEM) {
		return gai_error;
	}
#endif

	/*
	 * hostname as alphabetical name.
	 * we would like to prefer AF_INET6 than AF_INET, so we'll make a
	 * outer loop by AFs.
	 */
	for (ex = explore; ex->e_af >= 0; ex++) {
		*pai = ai0;

		/* require exact match for family field */
		if (pai->ai_family != ex->e_af)
			continue;

		if (!MATCH(pai->ai_socktype, ex->e_socktype,
				WILD_SOCKTYPE(ex))) {
			continue;
		}
		if (!MATCH(pai->ai_protocol, ex->e_protocol,
				WILD_PROTOCOL(ex))) {
			continue;
		}

		if (pai->ai_socktype == ANY && ex->e_socktype != ANY)
			pai->ai_socktype = ex->e_socktype;
		if (pai->ai_protocol == ANY && ex->e_protocol != ANY)
			pai->ai_protocol = ex->e_protocol;

		error = explore_fqdn(
			pai, hostname, servname, &cur->ai_next, netcontext);

		while (cur && cur->ai_next)
			cur = cur->ai_next;
	}

	/* XXX */
	if (sentinel.ai_next)
		error = 0;

	if (error)
		goto free;
	if (error == 0) {
		if (sentinel.ai_next) {
 good:
			*res = sentinel.ai_next;
			return SUCCESS;
		} else
			error = EAI_FAIL;
	}
 free:
 bad:
	if (sentinel.ai_next)
		freeaddrinfo(sentinel.ai_next);
	*res = NULL;
	return error;
}
```

- 1.首先是把从Java对象传递进来的参数，组装到`addrinfo `结构体中
- 2.此时一半编译器的预定义宏一半来说就是`__ANDROID__`，对应Android系统。此时就会调用`android_getaddrinfo_proxy ` 把查询动作交给代理进程`netd`。

- 3.`explore_fqdn ` 方法将会真正进行查询和解析，从文件缓存以及互联网中查询结果，最后返回。




##### android_getaddrinfo_proxy

```cpp
static int
android_getaddrinfo_proxy(
    const char *hostname, const char *servname,
    const struct addrinfo *hints, struct addrinfo **res, unsigned netid)
{
	int success = 0;

...

	FILE* proxy = android_open_proxy();
	if (proxy == NULL) {
		return EAI_SYSTEM;
	}

	netid = __netdClientDispatch.netIdForResolv(netid);

	// Send the request.
	if (fprintf(proxy, "getaddrinfo %s %s %d %d %d %d %u",
		    hostname == NULL ? "^" : hostname,
		    servname == NULL ? "^" : servname,
		    hints == NULL ? -1 : hints->ai_flags,
		    hints == NULL ? -1 : hints->ai_family,
		    hints == NULL ? -1 : hints->ai_socktype,
		    hints == NULL ? -1 : hints->ai_protocol,
		    netid) < 0) {
		goto exit;
	}
	// literal NULL byte at end, required by FrameworkListener
	if (fputc(0, proxy) == EOF ||
	    fflush(proxy) != 0) {
		goto exit;
	}

	char buf[4];
	// read result code for gethostbyaddr
	if (fread(buf, 1, sizeof(buf), proxy) != sizeof(buf)) {
		goto exit;
	}

	int result_code = (int)strtol(buf, NULL, 10);
	// verify the code itself
	if (result_code != DnsProxyQueryResult) {
		fread(buf, 1, sizeof(buf), proxy);
		goto exit;
	}

	struct addrinfo* ai = NULL;
	struct addrinfo** nextres = res;
	while (1) {
		int32_t have_more;
		if (!readBE32(proxy, &have_more)) {
			break;
		}
		if (have_more == 0) {
			success = 1;
			break;
		}

		struct addrinfo* ai = calloc(1, sizeof(struct addrinfo) + sizeof(struct sockaddr_storage));
		if (ai == NULL) {
			break;
		}
		ai->ai_addr = (struct sockaddr*)(ai + 1);

		// struct addrinfo {
		//	int	ai_flags;	/* AI_PASSIVE, AI_CANONNAME, AI_NUMERICHOST */
		//	int	ai_family;	/* PF_xxx */
		//	int	ai_socktype;	/* SOCK_xxx */
		//	int	ai_protocol;	/* 0 or IPPROTO_xxx for IPv4 and IPv6 */
		//	socklen_t ai_addrlen;	/* length of ai_addr */
		//	char	*ai_canonname;	/* canonical name for hostname */
		//	struct	sockaddr *ai_addr;	/* binary address */
		//	struct	addrinfo *ai_next;	/* next structure in linked list */
		// };

		// Read the struct piece by piece because we might be a 32-bit process
		// talking to a 64-bit netd.
		int32_t addr_len;
		bool success =
				readBE32(proxy, &ai->ai_flags) &&
				readBE32(proxy, &ai->ai_family) &&
				readBE32(proxy, &ai->ai_socktype) &&
				readBE32(proxy, &ai->ai_protocol) &&
				readBE32(proxy, &addr_len);
		if (!success) {
			break;
		}

		// Set ai_addrlen and read the ai_addr data.
		ai->ai_addrlen = addr_len;
		if (addr_len != 0) {
			if ((size_t) addr_len > sizeof(struct sockaddr_storage)) {
				// Bogus; too big.
				break;
			}
			if (fread(ai->ai_addr, addr_len, 1, proxy) != 1) {
				break;
			}
		}

		// The string for ai_cannonname.
		int32_t name_len;
		if (!readBE32(proxy, &name_len)) {
			break;
		}
		if (name_len != 0) {
			ai->ai_canonname = (char*) malloc(name_len);
			if (fread(ai->ai_canonname, name_len, 1, proxy) != 1) {
				break;
			}
			if (ai->ai_canonname[name_len - 1] != '\0') {
				// The proxy should be returning this
				// NULL-terminated.
				break;
			}
		}

		*nextres = ai;
		nextres = &ai->ai_next;
		ai = NULL;
	}

	if (ai != NULL) {
		// Clean up partially-built addrinfo that we never ended up
		// attaching to the response.
		freeaddrinfo(ai);
	}
exit:
	if (proxy != NULL) {
		fclose(proxy);
	}

	if (success) {
		return 0;
	}

	// Proxy failed;
	// clean up memory we might've allocated.
	if (*res) {
		freeaddrinfo(*res);
		*res = NULL;
	}
	return EAI_NODATA;
}
```

- 1.`android_open_proxy ` 校验当前的环境变量是`ANDROID_DNS_MODE`是否是`local`还记得这个环境变量只有在`netd`设置了，而App进程并没有设置。 

此时App进程`ANDROID_DNS_MODE`不是`local`模式那么说明需要走代理，就会联通`netd`进程的`/dev/socket/dnsproxyd` 的socket接口，并返回。
```cpp

__LIBC_HIDDEN__ FILE* android_open_proxy() {
	const char* cache_mode = getenv("ANDROID_DNS_MODE");
	bool use_proxy = (cache_mode == NULL || strcmp(cache_mode, "local") != 0);
	if (!use_proxy) {
		return NULL;
	}

	int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
...
	const int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	struct sockaddr_un proxy_addr;
	memset(&proxy_addr, 0, sizeof(proxy_addr));
	proxy_addr.sun_family = AF_UNIX;
	strlcpy(proxy_addr.sun_path, "/dev/socket/dnsproxyd", sizeof(proxy_addr.sun_path));

	if (TEMP_FAILURE_RETRY(connect(s, (const struct sockaddr*) &proxy_addr, sizeof(proxy_addr))) != 0) {
		close(s);
		return NULL;
	}

	return fdopen(s, "r+");
}
```

- 2.拿到socket的文件描述符后，往`dnsproxyd`写入`"getaddrinfo %s %s %d %d %d %d %u"`命令。
- 3.进入一个循环知道有消息传入，从`dnsproxyd`返回的查询结果数据必定是 `addrinfo `结构体的数据结构返回，解析后直接返回。


### netd进程接受`getaddrinfo`命令

前面聊到了DnsProxyListener在内部中生成了`dnsproxyd `的socket。在DnsProxyListener构造函数中，就调用了`registerCmd `方法注册了不同命令的监听.

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libsysutils](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/)/[src](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/src/)/[FrameworkListener.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/src/FrameworkListener.cpp)


```cpp
void FrameworkListener::registerCmd(FrameworkCommand *cmd) {
    mCommands->push_back(cmd);
}
```

把FrameworkCommand添加到mCommands集合中。

FrameworkListener的父类就是SocketListener，而SocketListener在调用startListener方法后，就会启动一个线程执行`threadStart `方法。

```cpp
void *SocketListener::threadStart(void *obj) {
    SocketListener *me = reinterpret_cast<SocketListener *>(obj);

    me->runListener();
    pthread_exit(NULL);
    return NULL;
}

void SocketListener::runListener() {

    SocketClientCollection pendingList;

    while(1) {
        SocketClientCollection::iterator it;
        fd_set read_fds;
        int rc = 0;
        int max = -1;

        FD_ZERO(&read_fds);

        if (mListen) {
            max = mSock;
            FD_SET(mSock, &read_fds);
        }

        FD_SET(mCtrlPipe[0], &read_fds);
        if (mCtrlPipe[0] > max)
            max = mCtrlPipe[0];

        pthread_mutex_lock(&mClientsLock);
        for (it = mClients->begin(); it != mClients->end(); ++it) {
            // NB: calling out to an other object with mClientsLock held (safe)
            int fd = (*it)->getSocket();
            FD_SET(fd, &read_fds);
            if (fd > max) {
                max = fd;
            }
        }
        pthread_mutex_unlock(&mClientsLock);

        if ((rc = select(max + 1, &read_fds, NULL, NULL, NULL)) < 0) {
            if (errno == EINTR)
                continue;
...
            sleep(1);
            continue;
        } else if (!rc)
            continue;

...
        if (mListen && FD_ISSET(mSock, &read_fds)) {
            int c = TEMP_FAILURE_RETRY(accept4(mSock, nullptr, nullptr, SOCK_CLOEXEC));
            if (c < 0) {

                sleep(1);
                continue;
            }
            pthread_mutex_lock(&mClientsLock);
            mClients->push_back(new SocketClient(c, true, mUseCmdNum));
            pthread_mutex_unlock(&mClientsLock);
        }

        /* Add all active clients to the pending list first */
        pendingList.clear();
        pthread_mutex_lock(&mClientsLock);
        for (it = mClients->begin(); it != mClients->end(); ++it) {
            SocketClient* c = *it;
            // NB: calling out to an other object with mClientsLock held (safe)
            int fd = c->getSocket();
            if (FD_ISSET(fd, &read_fds)) {
                pendingList.push_back(c);
                c->incRef();
            }
        }
        pthread_mutex_unlock(&mClientsLock);

        /* Process the pending list, since it is owned by the thread,
         * there is no need to lock it */
        while (!pendingList.empty()) {
            /* Pop the first item from the list */
            it = pendingList.begin();
            SocketClient* c = *it;
            pendingList.erase(it);
            /* Process it, if false is returned, remove from list */
            if (!onDataAvailable(c)) {
                release(c, false);
            }
            c->decRef();
        }
    }
}
```

- 1.把pipeline对应的文件描述符以及`fd_set`(内含有外部设置进来的socket文件描述符)中，也就是系统帮你实现的一个fd缓存集合。在这里，我们设置了一个`/dev/socket/dnsproxyd`的socket文件描述符缓存到`SocketClient`.



- 2.通过select方法把监听`fd_set`中所有socket的数据到来的操作交给select系统调用。在这里实际上就是监听了`/dev/socket/dnsproxyd`.


- 3.注意在startListener方法中已经对改socket进行了listen监听操作，接下来在这个循环中就会调用`accept4 ` 接受网络数据。一旦有数据到来，把数据包装成一个个`SocketClient`保存`pendingList `集合中，调用`onDataAvailable`方法。

onDataAvailable 这个方法在FrameworkListener有实现。


#### FrameworkListener onDataAvailable

文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libsysutils](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/)/[src](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/src/)/[FrameworkListener.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libsysutils/src/FrameworkListener.cpp)

```java
bool FrameworkListener::onDataAvailable(SocketClient *c) {
    char buffer[CMD_BUF_SIZE];
    int len;

    len = TEMP_FAILURE_RETRY(read(c->getSocket(), buffer, sizeof(buffer)));
...

    int offset = 0;
    int i;

    for (i = 0; i < len; i++) {
        if (buffer[i] == '\0') {
            /* IMPORTANT: dispatchCommand() expects a zero-terminated string */
            if (mSkipToNextNullByte) {
                mSkipToNextNullByte = false;
            } else {
                dispatchCommand(c, buffer + offset);
            }
            offset = i + 1;
        }
    }

    mSkipToNextNullByte = false;
    return true;
}
```

在onDataAvailable 中，调用了`read`方法读socket传送来的数据，并调用`dispatchCommand`把保存在`pendingList `的数据分发出去。


### FrameworkListener dispatchCommand


```cpp
void FrameworkListener::dispatchCommand(SocketClient *cli, char *data) {
    FrameworkCommandCollection::iterator i;
    int argc = 0;
    char *argv[FrameworkListener::CMD_ARGS_MAX];
    char tmp[CMD_BUF_SIZE];
    char *p = data;
    char *q = tmp;
    char *qlimit = tmp + sizeof(tmp) - 1;
    bool esc = false;
    bool quote = false;
    bool haveCmdNum = !mWithSeq;

    memset(argv, 0, sizeof(argv));
    memset(tmp, 0, sizeof(tmp));
    while(*p) {
...
    for (i = mCommands->begin(); i != mCommands->end(); ++i) {
        FrameworkCommand *c = *i;

        if (!strcmp(argv[0], c->getCommand())) {
            if (c->runCommand(cli, argc, argv)) {
                SLOGW("Handler '%s' error (%s)", c->getCommand(), strerror(errno));
            }
            goto out;
        }
    }
    cli->sendMsg(500, "Command not recognized", false);
out:
    int j;
    for (j = 0; j < argc; j++)
        free(argv[j]);
    return;

overflow:
    cli->sendMsg(500, "Command too long", false);
    goto out;
}
```

还记得`FrameworkListener`中的`mCommands`集合实际上是通过上面registerCmd设置进来的。

在这个过程中，会遍历所有设置进来的命令对象。校验每一个`FrameworkCommand`设置好的字符串，当命令第一个字符串和`FrameworkCommand`匹配上了才会执行对应`FrameworkCommand`的`runCommand`


#### netd进程监听到App进程发送的DNS查询命令

注意，此时App进程调用了如下命令：
```
getaddrinfo %s %s %d %d %d %d %u
```

换句话说，此时`netd`进程需要匹配`getaddrinfo`命令

```cpp
DnsProxyListener::GetAddrInfoCmd::GetAddrInfoCmd(DnsProxyListener* dnsProxyListener) :
    NetdCommand("getaddrinfo"),
    mDnsProxyListener(dnsProxyListener) {
}
```

此时会匹配上`GetAddrInfoCmd`中的`getaddrinfo`的字符串。此时就会调用`GetAddrInfoCmd`的`runCommand`.


##### GetAddrInfoCmd runCommand

```cpp

// Limits the number of outstanding DNS queries by client UID.
constexpr int MAX_QUERIES_PER_UID = 256;
android::netdutils::OperationLimiter<uid_t> queryLimiter(MAX_QUERIES_PER_UID);


int DnsProxyListener::GetAddrInfoCmd::runCommand(SocketClient *cli,
                                            int argc, char **argv) {
...

    char* name = argv[1];
...
    char* service = argv[2];
...

    struct addrinfo* hints = NULL;
    int ai_flags = atoi(argv[3]);
    int ai_family = atoi(argv[4]);
    int ai_socktype = atoi(argv[5]);
    int ai_protocol = atoi(argv[6]);
    unsigned netId = strtoul(argv[7], NULL, 10);
    const bool useLocalNameservers = checkAndClearUseLocalNameserversFlag(&netId);
    const uid_t uid = cli->getUid();

    android_net_context netcontext;
    mDnsProxyListener->mNetCtrl->getNetworkContext(netId, uid, &netcontext);
    if (useLocalNameservers) {
        netcontext.flags |= NET_CONTEXT_FLAG_USE_LOCAL_NAMESERVERS;
    }

    if (ai_flags != -1 || ai_family != -1 ||
        ai_socktype != -1 || ai_protocol != -1) {
        hints = (struct addrinfo*) calloc(1, sizeof(struct addrinfo));
        hints->ai_flags = ai_flags;
        hints->ai_family = ai_family;
        hints->ai_socktype = ai_socktype;
        hints->ai_protocol = ai_protocol;
    }


    const int metricsLevel = mDnsProxyListener->mEventReporter->getMetricsReportingLevel();

    DnsProxyListener::GetAddrInfoHandler* handler =
            new DnsProxyListener::GetAddrInfoHandler(cli, name, service, hints, netcontext,
                    metricsLevel, mDnsProxyListener->mEventReporter->getNetdEventListener());
    tryThreadOrError(cli, handler);
    return 0;
}
```

- 1.从传递过来的字符串中读取了传递过来的`ai_flags`,`ai_family`,`ai_socktype`,`ai_protocol`几个数据，并在netd进程同样构造了`addrinfo`结构体传入`GetAddrInfoHandler`中，并调用`tryThreadOrError`启动`GetAddrInfoHandler`处理。


```cpp
template<typename T>
void tryThreadOrError(SocketClient* cli, T* handler) {
    cli->incRef();

    const int rval = threadLaunch(handler);
    if (rval == 0) {
        // SocketClient decRef() happens in the handler's run() method.
        return;
    }

...
}
```

注意`threadLaunch`这个方式实际上就是创建了一个线程，并执行了`handler`的run方法。

##### GetAddrInfoHandler run

```cpp
void DnsProxyListener::GetAddrInfoHandler::run() {
...

    struct addrinfo* result = NULL;
    Stopwatch s;
    maybeFixupNetContext(&mNetContext);
    const uid_t uid = mClient->getUid();
    uint32_t rv = 0;
    if (queryLimiter.start(uid)) {
        rv = android_getaddrinfofornetcontext(mHost, mService, mHints, &mNetContext, &result);
        queryLimiter.finish(uid);
    } else {
...
    }
    const int latencyMs = lround(s.timeTaken());

    if (rv) {
        // getaddrinfo failed
        mClient->sendBinaryMsg(ResponseCode::DnsProxyOperationFailed, &rv, sizeof(rv));
    } else {
        bool success = !mClient->sendCode(ResponseCode::DnsProxyQueryResult);
        struct addrinfo* ai = result;
        while (ai && success) {
            success = sendBE32(mClient, 1) && sendaddrinfo(mClient, ai);
            ai = ai->ai_next;
        }
        success = success && sendBE32(mClient, 0);
       ....
    }
    std::vector<String16> ip_addrs;
    int total_ip_addr_count = 0;
...
    mClient->decRef();
...
}

```

- 1.调用`android_getaddrinfofornetcontext`方法进行进行联网和文件缓存查询DNS

- 2.如果失败则返回`ResponseCode::DnsProxyOperationFailed`

- 3.如果成功，则发送`addrinfo`指针数组，不断的通过`sendBE32`发送到App进程。


到这里又返回了android_getaddrinfofornetcontext。

#### explore_fqdn 查询DNS服务


文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[dns](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/)/[net](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/net/)/[getaddrinfo.c](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/net/getaddrinfo.c)

值得注意的是，这里又调用了之前App进程调用的`bionic`库中的`android_getaddrinfofornetcontext `方法。由于`netd`进程在初始化时候设置了`ANDROID_DNS_MODE` 为`local`,此时就不会再一次走到`android_getaddrinfo_proxy `中，而是直接走到下半部分的 `explore_fqdn `方法。

```cpp
/*
 * FQDN hostname, DNS lookup
 */
static int
explore_fqdn(const struct addrinfo *pai, const char *hostname,
    const char *servname, struct addrinfo **res,
    const struct android_net_context *netcontext)
{
	struct addrinfo *result;
	struct addrinfo *cur;
	int error = 0;
	static const ns_dtab dtab[] = {
		NS_FILES_CB(_files_getaddrinfo, NULL)
		{ NSSRC_DNS, _dns_getaddrinfo, NULL },	/* force -DHESIOD */
		NS_NIS_CB(_yp_getaddrinfo, NULL)
		{ 0, 0, 0 }
	};

	assert(pai != NULL);
	/* hostname may be NULL */
	/* servname may be NULL */
	assert(res != NULL);

	result = NULL;

	/*
	 * if the servname does not match socktype/protocol, ignore it.
	 */
	if (get_portmatch(pai, servname) != 0)
		return 0;

	switch (nsdispatch(&result, dtab, NSDB_HOSTS, "getaddrinfo",
			default_dns_files, hostname, pai, netcontext)) {
	case NS_TRYAGAIN:
		error = EAI_AGAIN;
		goto free;
	case NS_UNAVAIL:
		error = EAI_FAIL;
		goto free;
	case NS_NOTFOUND:
		error = EAI_NODATA;
		goto free;
	case NS_SUCCESS:
		error = 0;
		for (cur = result; cur; cur = cur->ai_next) {
			GET_PORT(cur, servname);
			/* canonname should be filled already */
		}
		break;
	}

	*res = result;

	return 0;

free:
	if (result)
		freeaddrinfo(result);
	return error;
}
```

构建一个ns_dtab 数组，内含有三个结构体，这三个结构体实际上会被`nsdispatch`接受。这个过程会以传递到`nsdispatch `中最后三个为参数，并循环调用`_files_getaddrinfo`，`_dns_getaddrinfo`,`_yp_getaddrinfo`方法,直到找到该域名对应的ip地址。


我们分别来考量一下这三个方法都做了什么？


##### _files_getaddrinfo  从文件缓存中查询ip地址

```cpp
static int
_files_getaddrinfo(void *rv, void *cb_data, va_list ap)
{
	const char *name;
	const struct addrinfo *pai;
	struct addrinfo sentinel, *cur;
	struct addrinfo *p;
	FILE *hostf = NULL;

	name = va_arg(ap, char *);
	pai = va_arg(ap, struct addrinfo *);

//	fprintf(stderr, "_files_getaddrinfo() name = '%s'\n", name);
	memset(&sentinel, 0, sizeof(sentinel));
	cur = &sentinel;

	_sethtent(&hostf);
	while ((p = _gethtent(&hostf, name, pai)) != NULL) {
		cur->ai_next = p;
		while (cur && cur->ai_next)
			cur = cur->ai_next;
	}
	_endhtent(&hostf);

	*((struct addrinfo **)rv) = sentinel.ai_next;
	if (sentinel.ai_next == NULL)
		return NS_NOTFOUND;
	return NS_SUCCESS;
}


static void
_sethtent(FILE **hostf)
{

	if (!*hostf)
		*hostf = fopen(_PATH_HOSTS, "re");
	else
		rewind(*hostf);
}
```

注意`_PATH_HOSTS`是指：

```cpp
#define	_PATH_HOSTS	"/system/etc/hosts"
```

这个过程实际上就是打开`/system/etc/hosts` 系统环境文件，然后读取去该文件中的内容，转化`addrinfo`结构体。并和当前的域名进行匹配。

如果熟悉Linux的读者肯定知道`/system/etc/hosts`这个文件实际上就是缓存了每一次从网络中通过DNS服务器查询到的结果。


##### _dns_getaddrinfo

如果缓存查不到，那么调用 `_dns_getaddrinfo`查询DNS服务器，看看域名对应的ip地址是什么？

```cpp
static int
_dns_getaddrinfo(void *rv, void	*cb_data, va_list ap)
{
	struct addrinfo *ai;
	querybuf *buf, *buf2;
	const char *name;
	const struct addrinfo *pai;
	struct addrinfo sentinel, *cur;
	struct res_target q, q2;
	res_state res;
	const struct android_net_context *netcontext;

	name = va_arg(ap, char *);
	pai = va_arg(ap, const struct addrinfo *);
	netcontext = va_arg(ap, const struct android_net_context *);
	//fprintf(stderr, "_dns_getaddrinfo() name = '%s'\n", name);

	memset(&q, 0, sizeof(q));
	memset(&q2, 0, sizeof(q2));
	memset(&sentinel, 0, sizeof(sentinel));
	cur = &sentinel;

	buf = malloc(sizeof(*buf));
	if (buf == NULL) {
		h_errno = NETDB_INTERNAL;
		return NS_NOTFOUND;
	}
	buf2 = malloc(sizeof(*buf2));
	if (buf2 == NULL) {
		free(buf);
		h_errno = NETDB_INTERNAL;
		return NS_NOTFOUND;
	}

	switch (pai->ai_family) {
	case AF_UNSPEC:
		/* prefer IPv6 */
		q.name = name;
		q.qclass = C_IN;
		q.answer = buf->buf;
		q.anslen = sizeof(buf->buf);
		int query_ipv6 = 1, query_ipv4 = 1;
		if (pai->ai_flags & AI_ADDRCONFIG) {
			query_ipv6 = _have_ipv6(netcontext->app_mark, netcontext->uid);
			query_ipv4 = _have_ipv4(netcontext->app_mark, netcontext->uid);
		}
		if (query_ipv6) {
			q.qtype = T_AAAA;
			if (query_ipv4) {
				q.next = &q2;
				q2.name = name;
				q2.qclass = C_IN;
				q2.qtype = T_A;
				q2.answer = buf2->buf;
				q2.anslen = sizeof(buf2->buf);
			}
		} else if (query_ipv4) {
			q.qtype = T_A;
		} else {
			free(buf);
			free(buf2);
			return NS_NOTFOUND;
		}
		break;
	case AF_INET:
...
		break;
	case AF_INET6:
...
		break;
	default:
		free(buf);
		free(buf2);
		return NS_UNAVAIL;
	}

	res = __res_get_state();
	if (res == NULL) {
		free(buf);
		free(buf2);
		return NS_NOTFOUND;
	}


	res_setnetcontext(res, netcontext);
	if (res_searchN(name, &q, res) < 0) {
		__res_put_state(res);
		free(buf);
		free(buf2);
		return NS_NOTFOUND;
	}
	ai = getanswer(buf, q.n, q.name, q.qtype, pai);
	if (ai) {
		cur->ai_next = ai;
		while (cur && cur->ai_next)
			cur = cur->ai_next;
	}
	if (q.next) {
		ai = getanswer(buf2, q2.n, q2.name, q2.qtype, pai);
		if (ai)
			cur->ai_next = ai;
	}
	free(buf);
	free(buf2);
	if (sentinel.ai_next == NULL) {
		__res_put_state(res);
		switch (h_errno) {
		case HOST_NOT_FOUND:
			return NS_NOTFOUND;
		case TRY_AGAIN:
			return NS_TRYAGAIN;
		default:
			return NS_UNAVAIL;
		}
	}

	_rfc6724_sort(&sentinel, netcontext->app_mark, netcontext->uid);

	__res_put_state(res);

	*((struct addrinfo **)rv) = sentinel.ai_next;
	return NS_SUCCESS;
}
```

注意在Java层的StructInfo的`ai_family`中设置了`AF_UNSPEC `标志位，`ai_flags` 为` AI_ADDRCONFIG`

那么就会从`_have_ipv6`以及`_have_ipv4`查询。

```cpp
static int
_have_ipv6(unsigned mark, uid_t uid) {
	static const struct sockaddr_in6 sin6_test = {
		.sin6_family = AF_INET6,
		.sin6_addr.s6_addr = {  // 2000::
			0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
		};
	sockaddr_union addr = { .in6 = sin6_test };
	return _find_src_addr(&addr.generic, NULL, mark, uid) == 1;
}


static int
_have_ipv4(unsigned mark, uid_t uid) {
	static const struct sockaddr_in sin_test = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = __constant_htonl(0x08080808L)  // 8.8.8.8
	};
	sockaddr_union addr = { .in = sin_test };
	return _find_src_addr(&addr.generic, NULL, mark, uid) == 1;
}
```

这两个参数主要是用来确定是ipv6还是ipv4的。`AI_ADDRCONFIG `标志位不是用来检测链接是否可用，而是应该检测在本地中是否进行了配置。然而bionic不支持`getifaddrs `.因此需要先链接一下网络，确定DNS服务器是否正常。

`8.8.8.8`是google面向全球的查询的DNS服务器，`2000::`是ipv6全球单播地址。


- 2. `__res_get_state `获取系统设置好的默认DNS配置，以及承载结构体`res_target`，并调用`res_searchN `开始查询。查询到的结果通过`getanswer `解析，并设置到到第一个参数中返回。


核心来看看`res_searchN`都做了什么？

##### res_searchN

```cpp
static int
res_searchN(const char *name, struct res_target *target, res_state res)
{
	const char *cp, * const *domain;
	HEADER *hp;
	u_int dots;
	int trailing_dot, ret, saved_herrno;
	int got_nodata = 0, got_servfail = 0, tried_as_is = 0;


	hp = (HEADER *)(void *)target->answer;	/*XXX*/

	for (cp = name; *cp; cp++)
		dots += (*cp == '.');
	trailing_dot = 0;
	if (cp > name && *--cp == '.')
		trailing_dot++;

...


	saved_herrno = -1;
	if (dots >= res->ndots) {
		ret = res_querydomainN(name, NULL, target, res);
		if (ret > 0)
			return (ret);
		saved_herrno = h_errno;
		tried_as_is++;
	}

	if ((!dots && (res->options & RES_DEFNAMES)) ||
	    (dots && !trailing_dot && (res->options & RES_DNSRCH))) {
		int done = 0;

		_resolv_populate_res_for_net(res);

		for (domain = (const char * const *)res->dnsrch;
		   *domain && !done;
		   domain++) {

			ret = res_querydomainN(name, *domain, target, res);
			if (ret > 0)
				return ret;

			if (errno == ECONNREFUSED) {
				h_errno = TRY_AGAIN;
				return -1;
			}

			switch (h_errno) {
			case NO_DATA:
				got_nodata++;
				/* FALLTHROUGH */
			case HOST_NOT_FOUND:
				/* keep trying */
				break;
			case TRY_AGAIN:
				if (hp->rcode == SERVFAIL) {
					/* try next search element, if any */
					got_servfail++;
					break;
				}
				/* FALLTHROUGH */
			default:
				/* anything else implies that we're done */
				done++;
			}

			if (!(res->options & RES_DNSRCH))
			        done++;
		}
	}

	if (!tried_as_is) {
		ret = res_querydomainN(name, NULL, target, res);
		if (ret > 0)
			return ret;
	}

...
}
```

能看到此时会把整个域名如`www.baidu.com` 通过`.`的符号计算有多少个。如果阅读过我之前写的序言，就知道其实DNS就是根据`.`划分的层级开始逐层遍历查找不同层级的DNS服务器。


这里前后进行了两次`res_querydomainN`查询。 第一次是判断当前域名是否有超过阈值，超出了阈值后会进行一次查询。剩下的部分会在下面的循环中根据`res->dnsrch`的分割好的域名层层一次进行查询。


##### res_querydomainN

```cpp
static int
res_querydomainN(const char *name, const char *domain,
    struct res_target *target, res_state res)
{
	char nbuf[MAXDNAME];
	const char *longname = nbuf;
	size_t n, d;
...

	if (domain == NULL) {
		/*
		 * Check for trailing '.';
		 * copy without '.' if present.
		 */
		n = strlen(name);
		if (n + 1 > sizeof(nbuf)) {
			h_errno = NO_RECOVERY;
			return -1;
		}
		if (n > 0 && name[--n] == '.') {
			strncpy(nbuf, name, n);
			nbuf[n] = '\0';
		} else
			longname = name;
	} else {
		n = strlen(name);
		d = strlen(domain);
		if (n + 1 + d + 1 > sizeof(nbuf)) {
			h_errno = NO_RECOVERY;
			return -1;
		}
		snprintf(nbuf, sizeof(nbuf), "%s.%s", name, domain);
	}
	return res_queryN(longname, target, res);
}
```
能看到这个过程会根据域名如`www.baidu.com`从尾部开始把每一个层级划分出来设置到`longname`中。



#### res_queryN

```cpp
static int
res_queryN(const char *name, /* domain name */ struct res_target *target,
    res_state res)
{
	u_char buf[MAXPACKET];
	HEADER *hp;
	int n;
	struct res_target *t;
	int rcode;
	int ancount;

	assert(name != NULL);
	/* XXX: target may be NULL??? */

	rcode = NOERROR;
	ancount = 0;

	for (t = target; t; t = t->next) {
		int class, type;
		u_char *answer;
		int anslen;
		u_int oflags;

		hp = (HEADER *)(void *)t->answer;
		oflags = res->_flags;

again:
		hp->rcode = NOERROR;	/* default */

		/* make it easier... */
		class = t->qclass;
		type = t->qtype;
		answer = t->answer;
		anslen = t->anslen;


		n = res_nmkquery(res, QUERY, name, class, type, NULL, 0, NULL,
		    buf, sizeof(buf));
#ifdef RES_USE_EDNS0
...
#endif
		if (n <= 0) {

			h_errno = NO_RECOVERY;
			return n;
		}
		n = res_nsend(res, buf, n, answer, anslen);
...

		if (n < 0 || hp->rcode != NOERROR || ntohs(hp->ancount) == 0) {
			rcode = hp->rcode;	/* record most recent error */
#ifdef RES_USE_EDNS0
...
#endif
...
			continue;
		}

		ancount += ntohs(hp->ancount);

		t->n = n;
	}

	if (ancount == 0) {
		switch (rcode) {
		case NXDOMAIN:
			h_errno = HOST_NOT_FOUND;
			break;
		case SERVFAIL:
			h_errno = TRY_AGAIN;
			break;
		case NOERROR:
			h_errno = NO_DATA;
			break;
		case FORMERR:
		case NOTIMP:
		case REFUSED:
		default:
			h_errno = NO_RECOVERY;
			break;
		}
		return -1;
	}
	return ancount;
}
```

关于DNS的扩展字段这里就不多聊，我们直接看又关键如下几个关键步骤：

- 1.res_nmkquery 为buf缓冲区 设置当前查询的头部数据（实际上就是一个HEADER结构体）
- 2.res_nsend 发送buf缓冲区（HEADER结构体）中的数据.


##### res_nsend
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[dns](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/)/[resolv](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/)/[res_send.c](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/res_send.c)


```cpp
int
res_nsend(res_state statp,
	  const u_char *buf, int buflen, u_char *ans, int anssiz)
{
	int gotsomewhere, terrno, try, v_circuit, resplen, ns, n;
	char abuf[NI_MAXHOST];
	ResolvCacheStatus     cache_status = RESOLV_CACHE_UNSUPPORTED;
...
	v_circuit = (statp->options & RES_USEVC) || buflen > PACKETSZ;
	gotsomewhere = 0;
	terrno = ETIMEDOUT;

	int  anslen = 0;
	cache_status = _resolv_cache_lookup(
			statp->netid, buf, buflen,
			ans, anssiz, &anslen);

	if (cache_status == RESOLV_CACHE_FOUND) {
		return anslen;
	} else if (cache_status != RESOLV_CACHE_UNSUPPORTED) {
		// had a cache miss for a known network, so populate the thread private
		// data so the normal resolve path can do its thing
		_resolv_populate_res_for_net(statp);
	}
	if (statp->nscount == 0) {
		// We have no nameservers configured, so there's no point trying.
		// Tell the cache the query failed, or any retries and anyone else asking the same
		// question will block for PENDING_REQUEST_TIMEOUT seconds instead of failing fast.
		_resolv_cache_query_failed(statp->netid, buf, buflen);
		errno = ESRCH;
		return (-1);
	}

	/*
	 * If the ns_addr_list in the resolver context has changed, then
	 * invalidate our cached copy and the associated timing data.
	 */
	if (EXT(statp).nscount != 0) {
		int needclose = 0;
		struct sockaddr_storage peer;
		socklen_t peerlen;

		if (EXT(statp).nscount != statp->nscount) {
			needclose++;
		} else {
			for (ns = 0; ns < statp->nscount; ns++) {
				if (statp->nsaddr_list[ns].sin_family &&
				    !sock_eq((struct sockaddr *)(void *)&statp->nsaddr_list[ns],
					     (struct sockaddr *)(void *)&EXT(statp).ext->nsaddrs[ns])) {
					needclose++;
					break;
				}

				if (EXT(statp).nssocks[ns] == -1)
					continue;
				peerlen = sizeof(peer);
				if (getpeername(EXT(statp).nssocks[ns],
				    (struct sockaddr *)(void *)&peer, &peerlen) < 0) {
					needclose++;
					break;
				}
				if (!sock_eq((struct sockaddr *)(void *)&peer,
				    get_nsaddr(statp, (size_t)ns))) {
					needclose++;
					break;
				}
			}
		}
		if (needclose) {
			res_nclose(statp);
			EXT(statp).nscount = 0;
		}
	}

...


	/*
	 * Send request, RETRY times, or until successful.
	 */
	for (try = 0; try < statp->retry; try++) {
	    struct __res_stats stats[MAXNS];
	    struct __res_params params;
	    int revision_id = _resolv_cache_get_resolver_stats(statp->netid, &params, stats);
	    bool usable_servers[MAXNS];
	    android_net_res_stats_get_usable_servers(&params, stats, statp->nscount,
		    usable_servers);

	    for (ns = 0; ns < statp->nscount; ns++) {
		if (!usable_servers[ns]) continue;
		struct sockaddr *nsap;
		int nsaplen;
		time_t now = 0;
		int rcode = RCODE_INTERNAL_ERROR;
		int delay = 0;
		nsap = get_nsaddr(statp, (size_t)ns);
		nsaplen = get_salen(nsap);
		statp->_flags &= ~RES_F_LASTMASK;
		statp->_flags |= (ns << RES_F_LASTSHIFT);

....


		if (v_circuit) {
...
		} else {
			/* Use datagrams. */
...
			n = send_dg(statp, buf, buflen, ans, anssiz, &terrno,
				    ns, &v_circuit, &gotsomewhere, &now, &rcode, &delay);

			/* Only record stats the first time we try a query. See above. */
			if (try == 0) {
				struct __res_sample sample;
				_res_stats_set_sample(&sample, now, rcode, delay);
				_resolv_cache_add_resolver_stats_sample(statp->netid, revision_id,
					ns, &sample, params.max_samples);
			}
...
			if (n < 0)
				goto fail;
			if (n == 0)
				goto next_ns;
...
			if (v_circuit)
				goto same_ns;
			resplen = n;
		}


		if (cache_status == RESOLV_CACHE_NOTFOUND) {
		    _resolv_cache_add(statp->netid, buf, buflen,
				      ans, resplen);
		}
		/*
		 * If we have temporarily opened a virtual circuit,
		 * or if we haven't been asked to keep a socket open,
		 * close the socket.
		 */
		if ((v_circuit && (statp->options & RES_USEVC) == 0U) ||
		    (statp->options & RES_STAYOPEN) == 0U) {
			res_nclose(statp);
		}
...
		return (resplen);
 next_ns: ;
	   } /*foreach ns*/
	} /*foreach retry*/
	res_nclose(statp);
	if (!v_circuit) {
		if (!gotsomewhere)
			errno = ECONNREFUSED;	/* no nameservers found */
		else
			errno = ETIMEDOUT;	/* no answer obtained */
	} else
		errno = terrno;

	_resolv_cache_query_failed(statp->netid, buf, buflen);

	return (-1);
 fail:

...
	return (-1);
}

```

- 1.首先通过`_resolv_cache_lookup ` 查询缓存中的已经通过DNS解析好的数据。不过一旦发现res_state中缓存的nsaddr_list发生了改变那么就会废弃当前的缓存继续下面步骤进行查找。

- 2.在DNS查询中，分为2中模式查询，一种是通过TCP请求，一种是通过UDP请求。我们常用的一般是DNS请求。TCP请求的诞生是因为日益增加的数据量获取，而UDP无法保证数据的连贯性，因此需要使用TCP进行获取。

这里我们就以经典的UDP请求为例子。

send_dg 发送之前设置好的HEADER数据,如果`send_dg`返回的结果是0，说明还有域名没有解析到，需要进一步的迭代查询。



###### send_dg

```cpp
static int
send_dg(res_state statp,
	const u_char *buf, int buflen, u_char *ans, int anssiz,
	int *terrno, int ns, int *v_circuit, int *gotsomewhere,
	time_t *at, int *rcode, int* delay)
{
	*at = time(NULL);
	*rcode = RCODE_INTERNAL_ERROR;
	*delay = 0;
	const HEADER *hp = (const HEADER *)(const void *)buf;
	HEADER *anhp = (HEADER *)(void *)ans;
	const struct sockaddr *nsap;
	int nsaplen;
	struct timespec now, timeout, finish, done;
	fd_set dsmask;
	struct sockaddr_storage from;
	socklen_t fromlen;
	int resplen, seconds, n, s;

	nsap = get_nsaddr(statp, (size_t)ns);
	nsaplen = get_salen(nsap);
	if (EXT(statp).nssocks[ns] == -1) {
		EXT(statp).nssocks[ns] = socket(nsap->sa_family, SOCK_DGRAM | SOCK_CLOEXEC, 0);
		if (EXT(statp).nssocks[ns] > highestFD) {
			res_nclose(statp);
			errno = ENOTSOCK;
		}
		if (EXT(statp).nssocks[ns] < 0) {
			switch (errno) {
			case EPROTONOSUPPORT:
#ifdef EPFNOSUPPORT
...
#endif
			case EAFNOSUPPORT:
				Perror(statp, stderr, "socket(dg)", errno);
				return (0);
			default:
				*terrno = errno;
				Perror(statp, stderr, "socket(dg)", errno);
				return (-1);
			}
		}

		fchown(EXT(statp).nssocks[ns], AID_DNS, -1);
		if (statp->_mark != MARK_UNSET) {
			if (setsockopt(EXT(statp).nssocks[ns], SOL_SOCKET,
					SO_MARK, &(statp->_mark), sizeof(statp->_mark)) < 0) {
				res_nclose(statp);
				return -1;
			}
		}

	if (sendto(s, (const char*)buf, buflen, 0, nsap, nsaplen) != buflen)
	{
		Aerror(statp, stderr, "sendto", errno, nsap, nsaplen);
		res_nclose(statp);
		return (0);
	}
#endif /* !CANNOT_CONNECT_DGRAM */


	seconds = get_timeout(statp, ns);
	now = evNowTime();
	timeout = evConsTime((long)seconds, 0L);
	finish = evAddTime(now, timeout);
retry:
	n = retrying_select(s, &dsmask, NULL, &finish);

	if (n == 0) {
		*rcode = RCODE_TIMEOUT;
		*gotsomewhere = 1;
		return (0);
	}
	if (n < 0) {
		Perror(statp, stderr, "select", errno);
		res_nclose(statp);
		return (0);
	}
	errno = 0;
	fromlen = sizeof(from);
	resplen = recvfrom(s, (char*)ans, (size_t)anssiz,0,
			   (struct sockaddr *)(void *)&from, &fromlen);
...
	return (resplen);
}
```
- 1.调用`socket `系统调用.注意这里面的第一个代表`domain`参数`nsap->sa_family` 并没有进行设置此时就是数值为0的`AF_UNSPEC `，第二个参数为发送类型为`SOCK_DGRAM `. `AF_UNSPEC`是指不指定协议根据内容进行对应的解析；`SOCK_DGRAM`的意是指`UDP`传输方式。

- 2. sendto 把缓冲区的数据发送出去


- 3.retrying_select 使用`select`系统调用把socket的监听交给select系统调用

- 4. recvfrom 读取从socket传递进来的数据。


#### DNS 服务器的设置

看了半天好像没说到是怎么设置DNS查询的服务器的。可以看到send_dg方法中通过`nsap = get_nsaddr(statp, (size_t)ns);`方法获取需要请求的DNS地址。

其实这个数据是在netd第一次获取res_state的时候初始化好的，方法是来自`__res_get_state `.这个方法会一个线程唯一调用一次res_ninit方法读取系统中设置好的配置。

文件： /[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[dns](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/)/[resolv](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/)/[res_init.c](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/res_init.c)

下面是核心的阶段
```cpp
	if ((fp = fopen(_PATH_RESCONF, "re")) != NULL) {
	    /* read the config file */
	    while (fgets(buf, sizeof(buf), fp) != NULL) {
		if (*buf == ';' || *buf == '#')
			continue;
		if (MATCH(buf, "domain")) {
		    if (haveenv)	/* skip if have from environ */
			    continue;
		    cp = buf + sizeof("domain") - 1;
		    while (*cp == ' ' || *cp == '\t')
			    cp++;
		    if ((*cp == '\0') || (*cp == '\n'))
			    continue;
		    strncpy(statp->defdname, cp, sizeof(statp->defdname) - 1);
		    statp->defdname[sizeof(statp->defdname) - 1] = '\0';
		    if ((cp = strpbrk(statp->defdname, " \t\n")) != NULL)
			    *cp = '\0';
		    havesearch = 0;
		    continue;
		}
		if (MATCH(buf, "search")) {
		    if (haveenv)	/* skip if have from environ */
			    continue;
		    cp = buf + sizeof("search") - 1;
		    while (*cp == ' ' || *cp == '\t')
			    cp++;
		    if ((*cp == '\0') || (*cp == '\n'))
			    continue;
		    strncpy(statp->defdname, cp, sizeof(statp->defdname) - 1);
		    statp->defdname[sizeof(statp->defdname) - 1] = '\0';
		    if ((cp = strchr(statp->defdname, '\n')) != NULL)
			    *cp = '\0';
		    cp = statp->defdname;
		    pp = statp->dnsrch;
		    *pp++ = cp;
		    for (n = 0; *cp && pp < statp->dnsrch + MAXDNSRCH; cp++) {
			    if (*cp == ' ' || *cp == '\t') {
				    *cp = 0;
				    n = 1;
			    } else if (n) {
				    *pp++ = cp;
				    n = 0;
			    }
		    }

		    while (*cp != '\0' && *cp != ' ' && *cp != '\t')
			    cp++;
		    *cp = '\0';
		    *pp++ = 0;
		    havesearch = 1;
		    continue;
		}

		if (MATCH(buf, "nameserver") && nserv < MAXNS) {
		    struct addrinfo hints, *ai;
		    char sbuf[NI_MAXSERV];
		    const size_t minsiz =
		        sizeof(statp->_u._ext.ext->nsaddrs[0]);

		    cp = buf + sizeof("nameserver") - 1;
		    while (*cp == ' ' || *cp == '\t')
			cp++;
		    cp[strcspn(cp, ";# \t\n")] = '\0';
		    if ((*cp != '\0') && (*cp != '\n')) {
			memset(&hints, 0, sizeof(hints));
			hints.ai_family = PF_UNSPEC;
			hints.ai_socktype = SOCK_DGRAM;	/*dummy*/
			hints.ai_flags = AI_NUMERICHOST;
			sprintf(sbuf, "%u", NAMESERVER_PORT);
			if (getaddrinfo(cp, sbuf, &hints, &ai) == 0 &&
			    ai->ai_addrlen <= minsiz) {
			    if (statp->_u._ext.ext != NULL) {
				memcpy(&statp->_u._ext.ext->nsaddrs[nserv],
				    ai->ai_addr, ai->ai_addrlen);
			    }
			    if (ai->ai_addrlen <=
			        sizeof(statp->nsaddr_list[nserv])) {
				memcpy(&statp->nsaddr_list[nserv],
				    ai->ai_addr, ai->ai_addrlen);
			    } else
				statp->nsaddr_list[nserv].sin_family = 0;
			    freeaddrinfo(ai);
			    nserv++;
			}
		    }
		    continue;
		}
		if (MATCH(buf, "sortlist")) {
		    struct in_addr a;

		    cp = buf + sizeof("sortlist") - 1;
		    while (nsort < MAXRESOLVSORT) {
			while (*cp == ' ' || *cp == '\t')
			    cp++;
			if (*cp == '\0' || *cp == '\n' || *cp == ';')
			    break;
			net = cp;
			while (*cp && !ISSORTMASK(*cp) && *cp != ';' &&
			       isascii(*cp) && !isspace((unsigned char)*cp))
				cp++;
			n = *cp;
			*cp = 0;
			if (inet_aton(net, &a)) {
			    statp->sort_list[nsort].addr = a;
			    if (ISSORTMASK(n)) {
				*cp++ = n;
				net = cp;
				while (*cp && *cp != ';' &&
					isascii(*cp) &&
					!isspace((unsigned char)*cp))
				    cp++;
				n = *cp;
				*cp = 0;
				if (inet_aton(net, &a)) {
				    statp->sort_list[nsort].mask = a.s_addr;
				} else {
				    statp->sort_list[nsort].mask =
					net_mask(statp->sort_list[nsort].addr);
				}
			    } else {
				statp->sort_list[nsort].mask =
				    net_mask(statp->sort_list[nsort].addr);
			    }
			    nsort++;
			}
			*cp = n;
		    }
		    continue;
		}
		if (MATCH(buf, "options")) {
		    res_setoptions(statp, buf + sizeof("options") - 1, "conf");
		    continue;
		}
	    }
	    if (nserv > 0)
		statp->nscount = nserv;
	    statp->nsort = nsort;
	    (void) fclose(fp);
	}
```

在Android中对应的文件名为`resolv.conf`
```
_PATH_RESCONF        "/etc/ppp/resolv.conf"
```

下面是一个例子：
```
domain  51osos.com

search  [www.51osos.com](http://www.51osos.com/)  51osos.com

nameserver 202.102.192.68

nameserver 202.102.192.69

```

这段代码就是对这个字符串进行解析：
- nameserver 对应DNS服务器
- domain 自定义的本地域名
- search 代表定义域名的搜索列表
- sortlist 对返回的域名进行排序

对于我们来说，值得注意的是`nameserver `对应的数据，会注入到`statp->nsaddr_list`列表中,在后续发送时候就会根据这些DNS服务器进行解析。其中必定存在`8.8.8.8`google面向全球提供的DNS服务器。


这一段的知识来源是来自我对Linux系统的理解和结合Android源码的流程进行理解，然而我没在Android虚拟机中没找到对应的文件，如果知道的朋友请告诉一下我学习一下。



### UDP 传输的DNS查询数据格式


既然知道这是怎么传送的，来看看传送的数据是什么。


一说起DNS查询报文，我们上一张大家十分熟悉的图

![DNS查询报文.gif](/images/DNS查询报文.gif)



DNS报文可以分为两种类型：

- 1.DNS 请求查询
- 2.DNS 查询相应

但是整个数据协议格式都是一致的。

DNS报文可以分为如下三个区域的：

- 1.基础部分 

- 2.问题部分

- 3.资源记录部分

DNS请求查询阶段中，会设置基础和问题部分。而资源记录部分则通过0进行占位。

#### 基础部分 

下面是一个查询的例子(数据来源于 http://c.biancheng.net/view/6457.html)：
```
Domain Name System (query)
    Transaction ID: 0x9ad0                              #事务ID
    Flags: 0x0000 Standard query                        #报文中的标志字段
        0... .... .... .... = Response: Message is a query
                                                        #QR字段, 值为0, 因为是一个请求包
        .000 0... .... .... = Opcode: Standard query (0)
                                                        #Opcode字段, 值为0, 因为是标准查询
        .... ..0. .... .... = Truncated: Message is not truncated
                                                        #TC字段
        .... ...0 .... .... = Recursion desired: Don't do query recursively 
                                                        #RD字段
        .... .... .0.. .... = Z: reserved (0)           #保留字段, 值为0
        .... .... ...0 .... = Non-authenticated data: Unacceptable   
                                                        #保留字段, 值为0
    Questions: 1                                        #问题计数, 这里有1个问题
    Answer RRs: 0                                       #回答资源记录数
    Authority RRs: 0                                    #权威名称服务器计数
    Additional RRs: 0                                   #附加资源记录数
```

在这个部分里面为基础部分，基础部分又称为报文首部，在bionic中用Header结构体进行表示。

![DNS基础部分.gif](/images/DNS基础部分.gif)


- 事务 ID：DNS 报文的 ID 标识。对于请求报文和其对应的应答报文，该字段的值是相同的。通过它可以区分 DNS 应答报文是对哪个请求进行响应的。
- 标志：DNS 报文中的标志字段。
- 问题计数：DNS 查询请求的数目。
- 回答资源记录数：DNS 响应的数目。
- 权威名称服务器计数：权威名称服务器的数目。
- 附加资源记录数：额外的记录数目（权威名称服务器对应 IP 地址的数目）。


当DNS相应查询后，就会在资源查询部分添加查询的结果。

下面是一个查询响应的例子：
```
Domain Name System (response)
    Transaction ID: 0x9ad0                                    #事务ID
    Flags: 0x8180 Standard query response, No error           #报文中的标志字段
        1... .... .... .... = Response: Message is a response
                                                              #QR字段, 值为1, 因为是一个响应包
        .000 0... .... .... = Opcode: Standard query (0)      # Opcode字段
        .... .0.. .... .... = Authoritative: Server is not an authority for
        domain                                                #AA字段
        .... ..0. .... .... = Truncated: Message is not truncated
                                                              #TC字段
        .... ...1 .... .... = Recursion desired: Do query recursively 
                                                              #RD字段
        .... .... 1... .... = Recursion available: Server can do recursive
        queries                                               #RA字段
        .... .... .0.. .... = Z: reserved (0)
        .... .... ..0. .... = Answer authenticated: Answer/authority portion
        was not authenticated by the server
        .... .... ...0 .... = Non-authenticated data: Unacceptable
        .... .... .... 0000 = Reply code: No error (0)        #返回码字段
    Questions: 1
    Answer RRs: 2
    Authority RRs: 5
    Additional RRs: 5
```


整个首部是通过如下结构体进行表示：

```cpp

typedef struct {
	unsigned	id :16;		/* query identification number */
			/* fields in third byte */
	unsigned	rd :1;		/* recursion desired */
	unsigned	tc :1;		/* truncated message */
	unsigned	aa :1;		/* authoritive answer */
	unsigned	opcode :4;	/* purpose of message */
	unsigned	qr :1;		/* response flag */
			/* fields in fourth byte */
	unsigned	rcode :4;	/* response code */
	unsigned	cd: 1;		/* checking disabled by resolver */
	unsigned	ad: 1;		/* authentic data from named */
	unsigned	unused :1;	/* unused bits (MBZ as of 4.9.3a3) */
	unsigned	ra :1;		/* recursion available */
			/* remaining bytes */
	unsigned	qdcount :16;	/* number of question entries */
	unsigned	ancount :16;	/* number of answer entries */
	unsigned	nscount :16;	/* number of authority entries */
	unsigned	arcount :16;	/* number of resource entries */
} HEADER;
```

- qr（Response）：查询请求/响应的标志信息。查询请求时，值为 0；响应时，值为 1。
- opcode：操作码。其中，0 表示标准查询；1 表示反向查询；2 表示服务器状态请求。
- aa（Authoritative）：授权应答，该字段在响应报文中有效。值为 1 时，表示名称服务器是权威服务器；值为 0 时，表示不是权威服务器。
- tc（Truncated）：表示是否被截断。值为 1 时，表示响应已超过 512 字节并已被截断，只返回前 512 个字节。
- rd（Recursion Desired）：期望递归。该字段能在一个查询中设置，并在响应中返回。该标志告诉名称服务器必须处理这个查询，这种方式被称为一个递归查询。如果该位为 0，且被请求的名称服务器没有一个授权回答，它将返回一个能解答该查询的其他名称服务器列表。这种方式被称为迭代查询。
- ra（Recursion Available）：可用递归。该字段只出现在响应报文中。当值为 1 时，表示服务器支持递归查询。
- Z：保留字段，在所有的请求和应答报文中，它的值必须为 0。
- rcode（Reply code）：返回码字段，表示响应的差错状态。当值为 0 时，表示没有错误；当值为 1 时，表示报文格式错误（Format error），服务器不能理解请求的报文；当值为 2 时，表示域名服务器失败（Server failure），因为服务器的原因导致没办法处理这个请求；当值为 3 时，表示名字错误（Name Error），只有对授权域名解析服务器有意义，指出解析的域名不存在；当值为 4 时，表示查询类型不支持（Not Implemented），即域名服务器不支持查询类型；当值为 5 时，表示拒绝（Refused），一般是服务器由于设置的策略拒绝给出应答，如服务器不希望对某些请求者给出应答。


#### 问题部分

![DNS问题查询部分.gif](/images/DNS问题查询部分.gif)

整个问题部分十分简单，分为如下几个部分：
- 查询名： 要查询的地址。可能是ip地址，用于反向查询
- 查询类型： DNS查询请求的资源类型，如A类代表是获取域名对应的ip地址，在源码中用TA表示
- 查询类：地址类型。

举一个例子：
```
Domain Name System (query)                        #查询请求
    Queries                                       #问题部分
        baidu.com: type A, class IN
            Name: baidu.com                       #查询名字段, 这里请求域名baidu.com
            [Name Length: 9]
            [Label Count: 2]
            Type: A (Host Address) (1)            #查询类型字段, 这里为A类型
            Class: IN (0x0001)                    #查询类字段, 这里为互联网地址
```


那么基础部分和问题部分表现在源码中是什么形式呢？其实这部分工作是交给`res_mkquery `完成的。

#### res_mkquery 构建DNS查询的基础部分和问题部分

文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[dns](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/)/[resolv](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/)/[res_mkquery.c](http://androidxref.com/9.0.0_r3/xref/bionic/libc/dns/resolv/res_mkquery.c)

```cpp
        n = res_nmkquery(res, QUERY, name, class, type, NULL, 0, NULL,
            buf, sizeof(buf));
```

```cpp
int
res_nmkquery(res_state statp,
	     int op,			/* opcode of query */
	     const char *dname,		/* domain name */
	     int class, int type,	/* class and type of query */
	     const u_char *data,	/* resource record data */
	     int datalen,		/* length of data */
	     const u_char *newrr_in,	/* new rr for modify or append */
	     u_char *buf,		/* buffer to put query */
	     int buflen)		/* size of buffer */
{
	register HEADER *hp;
	register u_char *cp, *ep;
	register int n;
	u_char *dnptrs[20], **dpp, **lastdnptr;

	UNUSED(newrr_in);

	if ((buf == NULL) || (buflen < HFIXEDSZ))
		return (-1);
	memset(buf, 0, HFIXEDSZ);
	hp = (HEADER *)(void *)buf;
	hp->id = htons(res_randomid());
	hp->opcode = op;
	hp->rd = (statp->options & RES_RECURSE) != 0U;
	hp->ad = (statp->options & RES_USE_DNSSEC) != 0U;
	hp->rcode = NOERROR;
	cp = buf + HFIXEDSZ;
	ep = buf + buflen;
	dpp = dnptrs;
	*dpp++ = buf;
	*dpp++ = NULL;
	lastdnptr = dnptrs + sizeof dnptrs / sizeof dnptrs[0];
	/*
	 * perform opcode specific processing
	 */
	switch (op) {
	case QUERY:	/*FALLTHROUGH*/
	case NS_NOTIFY_OP:
		if (ep - cp < QFIXEDSZ)
			return (-1);
		if ((n = dn_comp(dname, cp, ep - cp - QFIXEDSZ, dnptrs,
		    lastdnptr)) < 0)
			return (-1);
		cp += n;
		ns_put16(type, cp);
		cp += INT16SZ;
		ns_put16(class, cp);
		cp += INT16SZ;
		hp->qdcount = htons(1);
		if (op == QUERY || data == NULL)
			break;

		if ((ep - cp) < RRFIXEDSZ)
			return (-1);
		n = dn_comp((const char *)data, cp, ep - cp - RRFIXEDSZ,
			    dnptrs, lastdnptr);
		if (n < 0)
			return (-1);
		cp += n;
		ns_put16(T_NULL, cp);
		cp += INT16SZ;
		ns_put16(class, cp);
		cp += INT16SZ;
		ns_put32(0, cp);
		cp += INT32SZ;
		ns_put16(0, cp);
		cp += INT16SZ;
		hp->arcount = htons(1);
		break;

	case IQUERY:
	...
	default:
		return (-1);
	}
	return (cp - buf);
}
```

此时调用的标志位为`QUERY`，此时会依次往HEADER中设置了如下的数据：
- id 事务id 通过一个`res_randomid`随机数方法设置
- opcode 操作码 为`QUERY`
- rd 和 ad。这两个递归标志位分别由`RES_RECURSE` 以及`RES_USE_DNSSEC`决定。
- rcode 为NOERROR

其他默认为0.接着`cp` 是缓冲区的地址指针。因为这个Header最后会记录到缓冲区buf中，此时向后移动一个HEADER的大小，就是设置问题区域的位置了。

因此下面不断的向后移动16位，依次设置了dname（查询名,dn_com通过name_compress进行编码压缩）,type(查询类型)以及class(查询类)。


#### 获取DNS服务器返回的查询结果

先来看看整个格式：
![DNS资源记录部分.gif](/images/DNS资源记录部分.gif)

这里分为如下6个部分：

- 1.域名： DNS请求的域名
- 2.类型 ：资源记录类型和问题部分一致
- 3.类：地址类型
- 4.生存时间：秒为单位的，生命周期内可以通过之前提过的缓存方法从中获取到缓存并返回
- 5.资源长度
- 6.资源数据：表示按照查询的资源返回的数据。

下面是一个例子：
```
Answers                                                      #“回答问题区域”字段
    baidu.com: type A, class IN, addr 220.181.57.216         #资源记录部分
        Name: baidu.com                                      #域名字段, 这里请求的域名为baidu.com
        Type: A (Host Address) (1)                           #类型字段, 这里为A类型
        Class: IN (0x0001)                                   #类字段
        Time to live: 5                                      #生存时间
        Data length: 4                                       #数据长度
        Address: 220.181.57.216                              #资源数据, 这里为IP地址
    baidu.com: type A, class IN, addr 123.125.115.110        #资源记录部分
        Name: baidu.com
        Type: A (Host Address) (1)
        Class: IN (0x0001)
        Time to live: 5
        Data length: 4
        Address: 123.125.115.110
```

表现在代码的形式，就是在核心方法在`_dns_getaddrinfo `：
```cpp
ai = getanswer(buf, q.n, q.name, q.qtype, pai);
```

```cpp
typedef union {
	HEADER hdr;
	u_char buf[MAXPACKET];
} querybuf;
```

注意此时的用于回应的结果是一个联合体。


```cpp
struct res_target {
	struct res_target *next;
	const char *name;	/* domain name */
	int qclass, qtype;	/* class and type of query */
	u_char *answer;		/* buffer to put answer */
	int anslen;		/* size of answer buffer */
	int n;			/* result length */
};
```

res_target 是一个链表项，记录了返回数据模块中的信息，用于辅助解析querybuf

```
static struct addrinfo *
getanswer(const querybuf *answer, int anslen, const char *qname, int qtype,
    const struct addrinfo *pai)
{
	struct addrinfo sentinel, *cur;
	struct addrinfo ai;
	const struct afd *afd;
	char *canonname;
	const HEADER *hp;
	const u_char *cp;
	int n;
	const u_char *eom;
	char *bp, *ep;
	int type, class, ancount, qdcount;
	int haveanswer, had_error;
	char tbuf[MAXDNAME];
	int (*name_ok) (const char *);
	char hostbuf[8*1024];


	memset(&sentinel, 0, sizeof(sentinel));
	cur = &sentinel;

	canonname = NULL;
	eom = answer->buf + anslen;
	switch (qtype) {
	case T_A:
	case T_AAAA:
	case T_ANY:	/*use T_ANY only for T_A/T_AAAA lookup*/
		name_ok = res_hnok;
		break;
	default:
		return NULL;	/* XXX should be abort(); */
	}

	hp = &answer->hdr;
	ancount = ntohs(hp->ancount);
	qdcount = ntohs(hp->qdcount);
	bp = hostbuf;
	ep = hostbuf + sizeof hostbuf;
	cp = answer->buf;
	BOUNDED_INCR(HFIXEDSZ);
	if (qdcount != 1) {
		h_errno = NO_RECOVERY;
		return (NULL);
	}
	n = dn_expand(answer->buf, eom, cp, bp, ep - bp);
	if ((n < 0) || !(*name_ok)(bp)) {
		h_errno = NO_RECOVERY;
		return (NULL);
	}
	BOUNDED_INCR(n + QFIXEDSZ);
	if (qtype == T_A || qtype == T_AAAA || qtype == T_ANY) {

		n = strlen(bp) + 1;		/* for the \0 */
		if (n >= MAXHOSTNAMELEN) {
			h_errno = NO_RECOVERY;
			return (NULL);
		}
		canonname = bp;
		bp += n;
		/* The qname can be abbreviated, but h_name is now absolute. */
		qname = canonname;
	}
	haveanswer = 0;
	had_error = 0;
	while (ancount-- > 0 && cp < eom && !had_error) {
		n = dn_expand(answer->buf, eom, cp, bp, ep - bp);
		if ((n < 0) || !(*name_ok)(bp)) {
			had_error++;
			continue;
		}
		cp += n;			/* name */
		BOUNDS_CHECK(cp, 3 * INT16SZ + INT32SZ);
		type = _getshort(cp);
 		cp += INT16SZ;			/* type */
		class = _getshort(cp);
 		cp += INT16SZ + INT32SZ;	/* class, TTL */
		n = _getshort(cp);
		cp += INT16SZ;			/* len */
		BOUNDS_CHECK(cp, n);
		if (class != C_IN) {
			cp += n;
			continue;		
		}
		if ((qtype == T_A || qtype == T_AAAA || qtype == T_ANY) &&
		    type == T_CNAME) {
			n = dn_expand(answer->buf, eom, cp, tbuf, sizeof tbuf);
			if ((n < 0) || !(*name_ok)(tbuf)) {
				had_error++;
				continue;
			}
			cp += n;
			/* Get canonical name. */
			n = strlen(tbuf) + 1;	/* for the \0 */
			if (n > ep - bp || n >= MAXHOSTNAMELEN) {
				had_error++;
				continue;
			}
			strlcpy(bp, tbuf, (size_t)(ep - bp));
			canonname = bp;
			bp += n;
			continue;
		}
		if (qtype == T_ANY) {
			if (!(type == T_A || type == T_AAAA)) {
				cp += n;
				continue;
			}
		} else if (type != qtype) {
			if (type != T_KEY && type != T_SIG)

			cp += n;
			continue;		/* XXX - had_error++ ? */
		}
		switch (type) {
		case T_A:
		case T_AAAA:
			if (strcasecmp(canonname, bp) != 0) {
				cp += n;
				continue;	/* XXX - had_error++ ? */
			}
			if (type == T_A && n != INADDRSZ) {
				cp += n;
				continue;
			}
			if (type == T_AAAA && n != IN6ADDRSZ) {
				cp += n;
				continue;
			}
			if (type == T_AAAA) {
				struct in6_addr in6;
				memcpy(&in6, cp, IN6ADDRSZ);
				if (IN6_IS_ADDR_V4MAPPED(&in6)) {
					cp += n;
					continue;
				}
			}
			if (!haveanswer) {
				int nn;

				canonname = bp;
				nn = strlen(bp) + 1;	/* for the \0 */
				bp += nn;
			}

			/* don't overwrite pai */
			ai = *pai;
			ai.ai_family = (type == T_A) ? AF_INET : AF_INET6;
			afd = find_afd(ai.ai_family);
			if (afd == NULL) {
				cp += n;
				continue;
			}
			cur->ai_next = get_ai(&ai, afd, (const char *)cp);
			if (cur->ai_next == NULL)
				had_error++;
			while (cur && cur->ai_next)
				cur = cur->ai_next;
			cp += n;
			break;
		default:
			abort();
		}
		if (!had_error)
			haveanswer++;
	}
	if (haveanswer) {
		if (!canonname)
			(void)get_canonname(pai, sentinel.ai_next, qname);
		else
			(void)get_canonname(pai, sentinel.ai_next, canonname);
		h_errno = NETDB_SUCCESS;
		return sentinel.ai_next;
	}

	h_errno = NO_RECOVERY;
	return NULL;
}
```

这里有三个重要的指针：
- bp 用于承载解析出来的头部数据 hostbuf
- ep hostbuf后用于承载后续的资源记录部分
- cp 指向了querybuf结构体的起始地址
- eom 是指向了querybuf 后面的资源记录部分


流程如下：

- 1. dn_expand 方法把`answer->buf`中的数据解码解析(每一次解析一个hostbuf的大小 8kb)，保存到bp指针指向的内存地址
- 2. 如果此时是`T_A`类型，则把`bp`解析到的头几位作为域名`canonname `，并把指针向后移动长度+1(处理‘\0’)
- 3.接下来就是一个循环，因为可能返回了多个地址内容。这里的前提是ancont也就是回答数目大于0，同时第一次递增cp的指针发现小于eom，说明还有没有解析的数据。
- 4.再调用一次`dn_expand `方法，把压缩的数据解码出来放到cp指针后续的地址，接着依次取出其中的class(类)和type(类型)。当判断到type是`T_A`，则继续往后展开内容到`tbuf`中。
- 5.然后把cp解码的数据通过`get_ai`直接拷贝到`addrinfo`

```cpp
struct addrinfo {
	int	ai_flags;	/* AI_PASSIVE, AI_CANONNAME, AI_NUMERICHOST */
	int	ai_family;	/* PF_xxx */
	int	ai_socktype;	/* SOCK_xxx */
	int	ai_protocol;	/* 0 or IPPROTO_xxx for IPv4 and IPv6 */
	socklen_t ai_addrlen;	/* length of ai_addr */
	char	*ai_canonname;	/* canonical name for hostname */
	struct	sockaddr *ai_addr;	/* binary address */
	struct	addrinfo *ai_next;	/* next structure in linked list */
};
```

```cpp
static struct addrinfo *
get_ai(const struct addrinfo *pai, const struct afd *afd, const char *addr)
{
	char *p;
	struct addrinfo *ai;

	ai = (struct addrinfo *)malloc(sizeof(struct addrinfo)
		+ (afd->a_socklen));
	if (ai == NULL)
		return NULL;

	memcpy(ai, pai, sizeof(struct addrinfo));
	ai->ai_addr = (struct sockaddr *)(void *)(ai + 1);
	memset(ai->ai_addr, 0, (size_t)afd->a_socklen);

	ai->ai_addrlen = afd->a_socklen;

	ai->ai_addr->sa_family = ai->ai_family = afd->a_af;
	p = (char *)(void *)(ai->ai_addr);
	memcpy(p + afd->a_off, addr, (size_t)afd->a_addrlen);
	return ai;
}
```

说明后面的cp数据接就是`addrinfo`结构体的内容。当生成了`addrinfo`后就会返回到底层，并从netd通过socket传送到App进程中，最后返回到Java层的api中。


## 总结

![DNS发送过程.png](/images/DNS发送过程.png)

整个流程用图来表示就比较简单了。

在netd进程首先会从线程内存中查询是否有符合的目标，不存在则从文件`/system/etc/hosts`中读取缓存好的域名对应的ip地址，如果找不到就从配置文件`/etc/ppp/resolv.conf` 中每一个DNS服务器找到对应的服务器进行迭代查询，最终返回addrinfo结构体的结果，转化成Java对象返回。

也是一个经典的3层缓存模式.








