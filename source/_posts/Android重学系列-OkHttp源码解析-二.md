---
title: Android重学系列 OkHttp源码解析(二)
top: false
cover: false
date: 2020-10-16 23:25:01
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
阅读过上一篇对网络编程的概述一文后，应该对网络编程有一个大体的概念了。从本文开始，将会开始对OkHttp的源码开始进行解析。

OkHttp是由square开发的网络请求哭，它是当前Android开发中使用率高达近100%的网络请求库。而且在Android源码中也内置了这个库作为官方的网络请求。甚至在一小部分后端也开始使用了。

关于前置知识，可以阅读我写的上篇[OKHttp系列解析(一) Okio源码解析](https://www.jianshu.com/p/5061860545ef) 以及[Android重学系列 Android网络编程 总览](https://www.jianshu.com/p/ba60ff3c56e6)


# 正文
老规矩，先来看看OkHttp是如何使用的。
```kotlin
public class GetExample {
  OkHttpClient client = new OkHttpClient();

  String run(String url) throws IOException {
    Request request = new Request.Builder()
        .url(url)
        .build();

    try (Response response = client.newCall(request).execute()) {
      return response.body().string();
    }
  }

  public static void main(String[] args) throws IOException {
    GetExample example = new GetExample();
    String response = example.run("https://raw.github.com/square/okhttp/master/README.md");
    System.out.println(response);
  }
}
```
就用官方的例子来看看，实际上就是通过Get请求github中README文本。

这个过程涉及了如下几个重要角色：
- `OkHttpClient` Okhttp用于请求的执行客户端
- `Request` 通过构造者设计模式，构建的一个请求对象
- `Call` 是通过 `client.newCall` 生成的请求执行对象，当执行了execute之后才会真正的开始执行网络请求
- `Response`  是通过网络请求后，从服务器返回的信息都在里面。内含返回的状态码，以及代表响应消息正文的ResponseBody。

再来看看POST是怎么请求的：
```kotlin
public static final MediaType JSON
    = MediaType.get("application/json; charset=utf-8");

OkHttpClient client = new OkHttpClient();

String post(String url, String json) throws IOException {
  RequestBody body = RequestBody.create(json, JSON);
  Request request = new Request.Builder()
      .url(url)
      .post(body)
      .build();
  try (Response response = client.newCall(request).execute()) {
    return response.body().string();
  }
}
```
和Get很相似，只是这个过程在Request中添加了`RequestBody`对象。这个RequestBody对象保存一个json字符串，并且设置MediaType为`"application/json; charset=utf-8"`也就是指正文格式，可以让客户端识别到应该怎么解析这串字符串。

当然还有put，delete等，和post流程十分相似就没有必要再展示了。

我们就以此为铺垫来看看整个OkHttp是怎么处理网络请求的。下面的原来来自最新的okHttp 4.1版本解析

## OkHttp的概况
整个OkHttp设计的很有层次性，OKHttp把整个网络请求逻辑拆成7个拦截器，设计成责任链模式的处理。我们可以把Okhttp的网络请求大致分为如下几层，如下图：
![OkHttp设计基础框架.png](/images/OkHttp设计基础框架.png)

- 1.retryAndFollowUpInterceptor 重试拦截器
- 2.BridgeInterceptor 建立网络桥梁的拦截器，主要是为了给网络请求时候，添加各种各种必要参数。如Cookie，Content-type
- 3.CacheInterceptor 缓存拦截器，主要是为了在网络请求时候，根据返回码处理缓存。
- 4.ConnectInterceptor 链接拦截器，主要是为了从链接池子中查找可以复用的socket链接。
- 5.CallServerInterceptor 真正执行网络请求的逻辑。
- 6.Interceptor 用户定义的拦截器，在重试拦截器之前执行
- 7.networkInterceptors 用户定义的网络拦截器，在CallServerInterceptor(执行网络请求拦截器)之前运行。

每个拦截器的处理逻辑可以拆分为两个部分，请求部分(处理Request)可应答部分(处理Response )。

其中最后两点是允许用户进行自定义的。本文将会专门讲述前三点的设计和思想。

### OkHttp 执行流程
我们来看看整个流程都做了什么？

实际上OkHttp 执行客户端可以通过建造者模式构建出来的，每一个成员变量代表了Okhttp中的一种能力,先来看看okhttp.Builder中的成员变量中都有写什么。
```kotlin
 class Builder constructor() {
    internal var dispatcher: Dispatcher = Dispatcher()
    internal var connectionPool: ConnectionPool = ConnectionPool()
    internal val interceptors: MutableList<Interceptor> = mutableListOf()
    internal val networkInterceptors: MutableList<Interceptor> = mutableListOf()
    internal var eventListenerFactory: EventListener.Factory = EventListener.NONE.asFactory()
    internal var retryOnConnectionFailure = true
    internal var authenticator: Authenticator = Authenticator.NONE
    internal var followRedirects = true
    internal var followSslRedirects = true
    internal var cookieJar: CookieJar = CookieJar.NO_COOKIES
    internal var cache: Cache? = null
    internal var dns: Dns = Dns.SYSTEM
    internal var proxy: Proxy? = null
    internal var proxySelector: ProxySelector? = null
    internal var proxyAuthenticator: Authenticator = Authenticator.NONE
    internal var socketFactory: SocketFactory = SocketFactory.getDefault()
    internal var sslSocketFactoryOrNull: SSLSocketFactory? = null
    internal var x509TrustManagerOrNull: X509TrustManager? = null
    internal var connectionSpecs: List<ConnectionSpec> = DEFAULT_CONNECTION_SPECS
    internal var protocols: List<Protocol> = DEFAULT_PROTOCOLS
    internal var hostnameVerifier: HostnameVerifier = OkHostnameVerifier
    internal var certificatePinner: CertificatePinner = CertificatePinner.DEFAULT
    internal var certificateChainCleaner: CertificateChainCleaner? = null
    internal var callTimeout = 0
    internal var connectTimeout = 10_000
    internal var readTimeout = 10_000
    internal var writeTimeout = 10_000
    internal var pingInterval = 0
    internal var minWebSocketMessageToCompress = RealWebSocket.DEFAULT_MINIMUM_DEFLATE_SIZE
    internal var routeDatabase: RouteDatabase? = null
...
}
```

- `Dispatcher ` Okhttp 请求分发器，是整个OkhttpClient的执行核心
- `ConnectionPool` Okhttp链接池，不过会把任务委托给`RealConnectionPool`处理
- `interceptors: MutableList<Interceptor>` 这是代表了okhttp所有的网络拦截器
- `networkInterceptors: MutableList<Interceptor>` 这种特殊的拦截器，会生效在`CallServerInterceptor`真正执行网络请求的拦截器之前执行。
- `eventListenerFactory: EventListener.Factory` 这是一个Event的监听器，可以监听到如`callStart`开始执行,`proxySelectStart` 代理选择开始,`proxySelectEnd`代理选择结束，`dnsStart`dns开始查找ip映射，`dnsEnd`查找ip完毕，`connectStart`开始链接服务器，`secureConnectStart`开始安全链接服务器,`secureConnectEnd`安全链接服务器结束，`connectEnd`链接结束等周期

- `authenticator: Authenticator` 当出现401时候，就会使用这个对象进行身份校验。如果配置过登录信息，则会根据信息生成新的Request重新请求

- `followRedirects` 是否允许重定向

- `cookieJar: CookieJar` 这是okhttp 对cookie持久化的接口

- `cache: Cache` 这部分实际上是okhttp持久化缓存的接口

- `dns: Dns` 这部分也就是前文说过的，用于通过URL地址反过来查找ip地址的对象，默认为DnsSystem.在这里面ip地址是使用java对象`InetAddress`来表示。

- `proxy: Proxy`和 `ProxySelector` Okhttp中请求的代理对象以及自动代理选择器。`proxyAuthenticator: Authenticator` 代理服务的401权限校验处理中心.

- `socketFactory: SocketFactory` 默认的socket链接池

- `sslSocketFactoryOrNull: SSLSocketFactory` 用于https的socket链接工厂

- `X509TrustManager` 用于信任https证书的对象，编码格式为`X.509`。换句话说，就是在TLS握手期间进行校验，如果校验失败则链接失败

- `connectionSpecs: List<ConnectionSpec>` ConnectionSpec实际上是用于指定http请求时候的socket链接，如果是Https则是构建TLS链接时候向服务端说明的TLS版本，密码套件的类。

- `protocols: List<Protocol>` Okhttp支持的自定义请求协议集合，内含http1.1，http2.0

- `hostnameVerifier: HostnameVerifier `。也是https中的校验，只是是在握手之后，对host进行校验。

- `CertificatePinner ` 在SSL过程锁定证书，只允许设置在这个类中的证书才能正常的链接。

- `CertificateChainCleaner` 这是一个证书链清理器。证书链是指使用一组收到信任的证书构成的根证书链，在TLS握手过程中，会清理链路中的证书。

- `connectTimeout` 链接超时时间

- `readTimeout` 读取超时时间，`writeTimeout`写入超时时间

-  `RealWebSocket`管理Okhttp内部所有的websocket对象

- `RouteDatabase` 这是okhttp学习那些链接不上去的黑名单地址，如果出现请求这些黑名单就会想办法。如果出现了链接过程出现异常，之后会想办法找到可以替代的路由。

大致上我们需要聊的内容都在这里面了。有了对okhttp的大体的功能之后，我们先来看看Okhttp的运行远离。


### Okhttp 分发请求入口 newCall
先来看看Okhttp如果需要构造一个可以请求的对象需要调用如下方法
```kotlin
  override fun newCall(request: Request): Call = RealCall(this, request, forWebSocket = false)
```

生成一个`RealCall`对象。其中第三个参数说迷宫这个请求是否是websocket。

得到`RealCall`对象之后，一般有两种选择进行网络请求：
- 1.如官方给出的方法，调用excute方法，把执行设置在RealCall的Request对象。很少使用excute的方式，开发中更多的下面这种方式。

- 2.使用方法`enqueue` 把请求分发按照队列方式顺序消费执行。


#### RealCall excute
```kotlin
  override fun execute(): Response {
    check(executed.compareAndSet(false, true)) { "Already Executed" }

    timeout.enter()
    callStart()
    try {
      client.dispatcher.executed(this)
      return getResponseWithInterceptorChain()
    } finally {
      client.dispatcher.finished(this)
    }
  }

  private fun callStart() {
    this.callStackTrace = Platform.get().getStackTraceForCloseable("response.body().close()")
    eventListener.callStart(this)
  }
```

首先回调上面设置的EventListenter的callStart方法，接着调用`Dispatcher`的`execute`方法，把当前的RealCall传入，最后调用getResponseWithInterceptorChain 阻塞获取从网络请求响应后的结果，最后调用`Dispatcher` 的`finished` 方法

#### RealCall enqueue
```java
  override fun enqueue(responseCallback: Callback) {
    check(executed.compareAndSet(false, true)) { "Already Executed" }

    callStart()
    client.dispatcher.enqueue(AsyncCall(responseCallback))
  }
```
整个流程就很简单了，先给当前的RealCall的executed原子类设置为true后，回调callStart方法，最后调用把外面监听响应数据的接口`responseCallback`封装成`AsyncCall`后作为参数传入 `Dispatcher`的`enqueue`方法。

我们主要来看`enqueue`方法的设计，`execute`的使用场景确实不多。

#### AsyncCall
先来看看`AysncCall`都做了什么？
```java
  internal inner class AsyncCall(
    private val responseCallback: Callback
  ) : Runnable {
    @Volatile var callsPerHost = AtomicInteger(0)
      private set

    fun reuseCallsPerHostFrom(other: AsyncCall) {
      this.callsPerHost = other.callsPerHost
    }

    val host: String
      get() = originalRequest.url.host

    val request: Request
        get() = originalRequest

    val call: RealCall
        get() = this@RealCall

    /**
     * Attempt to enqueue this async call on [executorService]. This will attempt to clean up
     * if the executor has been shut down by reporting the call as failed.
     */
    fun executeOn(executorService: ExecutorService) {
      client.dispatcher.assertThreadDoesntHoldLock()

      var success = false
      try {
        executorService.execute(this)
        success = true
      } catch (e: RejectedExecutionException) {
        val ioException = InterruptedIOException("executor rejected")
        ioException.initCause(e)
        noMoreExchanges(ioException)
        responseCallback.onFailure(this@RealCall, ioException)
      } finally {
        if (!success) {
          client.dispatcher.finished(this) // This call is no longer running!
        }
      }
    }

    override fun run() {
      threadName("OkHttp ${redactedUrl()}") {
        var signalledCallback = false
        timeout.enter()
        try {
          val response = getResponseWithInterceptorChain()
          signalledCallback = true
          responseCallback.onResponse(this@RealCall, response)
        } catch (e: IOException) {
          if (signalledCallback) {
            // Do not signal the callback twice!
            Platform.get().log("Callback failure for ${toLoggableString()}", Platform.INFO, e)
          } else {
            responseCallback.onFailure(this@RealCall, e)
          }
        } catch (t: Throwable) {
          cancel()
          if (!signalledCallback) {
            val canceledException = IOException("canceled due to $t")
            canceledException.addSuppressed(t)
            responseCallback.onFailure(this@RealCall, canceledException)
          }
          throw t
        } finally {
          client.dispatcher.finished(this)
        }
      }
    }
  }
```

`AysncCall`是一个Runnable对象。一旦线程开始执行的时候就会运行其中的run方法。而executeOn 方法这是允许任何的线程池执行该AsyncCall对象，接着调用其中的`run`方法。

在run方法中依次执行了如下步骤：
- 1. getResponseWithInterceptorChain 执行Okhttp中所有的拦截器，并获得对象response。
- 2.调用responseCallback的onResponse 方法把response对象回调出去。
- 3.如果遇到IOException异常则返回responseCallback.onFailure
- 4.其他异常则调用cancel 方法取消请求后，回调responseCallback.onFailure
- 5.调用Dispatcher的finished 方法结束执行。



### Dispatcher enqueue
```kotlin
  private val readyAsyncCalls = ArrayDeque<AsyncCall>()
  private val runningAsyncCalls = ArrayDeque<AsyncCall>()
  private val runningSyncCalls = ArrayDeque<RealCall>()

  internal fun enqueue(call: AsyncCall) {
    synchronized(this) {
      readyAsyncCalls.add(call)

      if (!call.call.forWebSocket) {
        val existingCall = findExistingCallWithHost(call.host)
        if (existingCall != null) call.reuseCallsPerHostFrom(existingCall)
      }
    }
    promoteAndExecute()
  }

  private fun findExistingCallWithHost(host: String): AsyncCall? {
    for (existingCall in runningAsyncCalls) {
      if (existingCall.host == host) return existingCall
    }
    for (existingCall in readyAsyncCalls) {
      if (existingCall.host == host) return existingCall
    }
    return null
  }
```
这里有三个队列十分重要：
- 1.readyAsyncCalls 异步执行的准备队列
- 2.runningAsyncCalls 正在异步执行队列
- 3.runningSyncCalls 正在同步执行队列

清楚这三个队列的功能后，下面就很好理解了：

- 1.首先把当前的`AsyncCall` 添加到readyAsyncCalls 预备执行队列中。这是一个 `ArrayDeque`对象，这是一个双端队列，可以作为栈使用。这个队列看起来像一个链表，实质上内部是一个数组(每一次扩容为原来的2倍，并且初始值为8，内用head和tail标示整个队列的范围，只允许操作头部和尾部).

- 2.其次通过findExistingCallWithHost 查找是否有host相同的AsyncCall 在`runningAsyncCalls` 和 `readyAsyncCalls`,存在则调用`reuseCallsPerHostFrom`复用这个AsyncCall，也就是复用这个请求配置，没必要重新构建全新的对象。

- 3.promoteAndExecute 开始通过线程池执行保存在队列中的AsyncCall


#### promoteAndExecute
```java
  @get:Synchronized
  @get:JvmName("executorService") val executorService: ExecutorService
    get() {
      if (executorServiceOrNull == null) {
        executorServiceOrNull = ThreadPoolExecutor(0, Int.MAX_VALUE, 60, TimeUnit.SECONDS,
            SynchronousQueue(), threadFactory("$okHttpName Dispatcher", false))
      }
      return executorServiceOrNull!!
    }

@get:Synchronized var maxRequests = 64
    set(maxRequests) {
      require(maxRequests >= 1) { "max < 1: $maxRequests" }
      synchronized(this) {
        field = maxRequests
      }
      promoteAndExecute()
    }

  @get:Synchronized var maxRequestsPerHost = 5
    set(maxRequestsPerHost) {
      require(maxRequestsPerHost >= 1) { "max < 1: $maxRequestsPerHost" }
      synchronized(this) {
        field = maxRequestsPerHost
      }
      promoteAndExecute()
    }


  private fun promoteAndExecute(): Boolean {
    this.assertThreadDoesntHoldLock()

    val executableCalls = mutableListOf<AsyncCall>()
    val isRunning: Boolean
    synchronized(this) {
      val i = readyAsyncCalls.iterator()
      while (i.hasNext()) {
        val asyncCall = i.next()

        if (runningAsyncCalls.size >= this.maxRequests) break // Max capacity.
        if (asyncCall.callsPerHost.get() >= this.maxRequestsPerHost) continue // Host max capacity.

        i.remove()
        asyncCall.callsPerHost.incrementAndGet()
        executableCalls.add(asyncCall)
        runningAsyncCalls.add(asyncCall)
      }
      isRunning = runningCallsCount() > 0
    }

    for (i in 0 until executableCalls.size) {
      val asyncCall = executableCalls[i]
      asyncCall.executeOn(executorService)
    }

    return isRunning
  }

```

`SynchronousQueue`是一个单对单的消费者生产者模式数据结构，必须要要有一个Request对应一个Data模式的数据结构。更多的Request会进入阻塞等待，知道有Data来匹配。

这里面设置一个默认的线程池，其中线程的调度队列就是通过`SynchronousQueue`处理成一对一的消费者生产者模式。

而在一次请求中一次性消费AsyncCall最大的数量默认为64，且这个AysncCall复用Host的次数要小于5次。

最后就会添加到executableCalls和runningAsyncCalls 加入到执行队列中。最后遍历一次executableCalls中AsyncCall的executeOn，执行其中的run方法。

那么我们需要看看整个Okhttp执行的核心方法`getResponseWithInterceptorChain `.


#### getResponseWithInterceptorChain
```kotlin
  @Throws(IOException::class)
  internal fun getResponseWithInterceptorChain(): Response {
    // Build a full stack of interceptors.
    val interceptors = mutableListOf<Interceptor>()
    interceptors += client.interceptors
    interceptors += RetryAndFollowUpInterceptor(client)
    interceptors += BridgeInterceptor(client.cookieJar)
    interceptors += CacheInterceptor(client.cache)
    interceptors += ConnectInterceptor
    if (!forWebSocket) {
      interceptors += client.networkInterceptors
    }
    interceptors += CallServerInterceptor(forWebSocket)

    val chain = RealInterceptorChain(
        call = this,
        interceptors = interceptors,
        index = 0,
        exchange = null,
        request = originalRequest,
        connectTimeoutMillis = client.connectTimeoutMillis,
        readTimeoutMillis = client.readTimeoutMillis,
        writeTimeoutMillis = client.writeTimeoutMillis
    )

    var calledNoMoreExchanges = false
    try {
      val response = chain.proceed(originalRequest)
      if (isCanceled()) {
        response.closeQuietly()
        throw IOException("Canceled")
      }
      return response
    } catch (e: IOException) {
      calledNoMoreExchanges = true
      throw noMoreExchanges(e) as Throwable
    } finally {
      if (!calledNoMoreExchanges) {
        noMoreExchanges(null)
      }
    }
  }
```

首先构造一个可变的 Interceptor集合。这个集合的顺序其实就是指代了整个okhttp拦截器的执行顺序。

整个流程如图：
![OkHttp设计基础框架.png](/images/OkHttp设计基础框架.png)

注意如果是websocket的话，就不会执行用户自定定义的NetworkInterceptor。

然后使用`RealInterceptorChain `包裹所有的拦截器后，执行`RealInterceptorChain.proceed `方法执行Request。

#### RealInterceptorChain 拦截器管理器
```kotlin
  internal fun copy(
    index: Int = this.index,
    exchange: Exchange? = this.exchange,
    request: Request = this.request,
    connectTimeoutMillis: Int = this.connectTimeoutMillis,
    readTimeoutMillis: Int = this.readTimeoutMillis,
    writeTimeoutMillis: Int = this.writeTimeoutMillis
  ) = RealInterceptorChain(call, interceptors, index, exchange, request, connectTimeoutMillis,
      readTimeoutMillis, writeTimeoutMillis)

  override fun proceed(request: Request): Response {
    check(index < interceptors.size)

    calls++

...

    // Call the next interceptor in the chain.
    val next = copy(index = index + 1, request = request)
    val interceptor = interceptors[index]

    @Suppress("USELESS_ELVIS")
    val response = interceptor.intercept(next) ?: throw NullPointerException(
        "interceptor $interceptor returned null")
...
    return response
  }

```
这个过程可以看到实际上又copy可一个RealInterceptorChain 对象，不过index 下标增加了1，此时就会继续执行对应下标的Interceptor。

换句话说，每当一个拦截器走完一个Request的处理流程就会生成一个新的RealInterceptorChain并且下标+1，时候下一个拦截器的intercept方法。不断的迭代下去。

这种思路，在我写的OkRxCache的库中有使用，很实用。能够把复杂且层级结构分明的逻辑拆分出来，做到可组装的效果。


那么就来看看第一个拦截器retryAndFollowUpInterceptor 做了什么？


### retryAndFollowUpInterceptor 重试拦截器

整个拦截器可以划分为2个部分进行理解，以方法`realChain.proceed`作为分割线，上部分为请求逻辑，下部分为应答处理逻辑

#### retryAndFollowUpInterceptor 处理请求
```kotlin
  override fun intercept(chain: Interceptor.Chain): Response {
    val realChain = chain as RealInterceptorChain
    var request = chain.request
    val call = realChain.call
    var followUpCount = 0
    var priorResponse: Response? = null
    var newExchangeFinder = true
    var recoveredFailures = listOf<IOException>()
    while (true) {
      call.enterNetworkInterceptorExchange(request, newExchangeFinder)

      var response: Response
      var closeActiveExchange = true
      try {
        if (call.isCanceled()) {
          throw IOException("Canceled")
        }

        try {
          response = realChain.proceed(request)
          newExchangeFinder = true
        } catch (e: RouteException) {

          if (!recover(e.lastConnectException, call, request, requestSendStarted = false)) {
            throw e.firstConnectException.withSuppressed(recoveredFailures)
          } else {
            recoveredFailures += e.firstConnectException
          }
          newExchangeFinder = false
          continue
        } catch (e: IOException) {

          if (!recover(e, call, request, requestSendStarted = e !is ConnectionShutdownException)) {
            throw e.withSuppressed(recoveredFailures)
          } else {
            recoveredFailures += e
          }
          newExchangeFinder = false
          continue
        }

    ...
    }
  }
```

- 1.调用RealCall的enterNetworkInterceptorExchange方法实例化一个`ExchangeFinder`在RealCall对象中。
- 2.执行RealCall的proceed 方法，进入下一个拦截器，进行下一步的请求处理。
- 3.如果出现路由异常，则通过recover方法校验，当前的链接是否可以重试，不能重试则抛出异常，离开当前的循环。

##### recover 校验链接是否可以重试
```kotlin
  private fun recover(
    e: IOException,
    call: RealCall,
    userRequest: Request,
    requestSendStarted: Boolean
  ): Boolean {
    // The application layer has forbidden retries.
    if (!client.retryOnConnectionFailure) return false

    // We can't send the request body again.
    if (requestSendStarted && requestIsOneShot(e, userRequest)) return false

    // This exception is fatal.
    if (!isRecoverable(e, requestSendStarted)) return false

    // No more routes to attempt.
    if (!call.retryAfterFailure()) return false

    // For failure recovery, use the same route selector with a new connection.
    return true
  }
```
- 1.如果Okhttp 的retryOnConnectionFailure为false，禁止重试则返回false

- 2.requestIsOneShot 如果requestIsOneShot校验的是RequestBody的isOneShot是否是true, isOneShot默认是false。说明一个请求正文可以多次请求（多次请求的情况如`408 客户端超时`;`401和407 权限异常可以通过头部进行满足`;`503 服务端异常，但是头部的retry-After为0可以进行重试`）。

- 3.isRecoverable 校验当前的异常是否是可恢复的异常。`ProtocolException` 协议异常返回false；`InterruptedIOException` io读写异常同时是socket链接超时异常可以重试；`SSLHandshakeException` https握手时候的异常同时是校验异常`CertificateException`会返回false； `SSLPeerUnverifiedException`证书校验异常则返回false。



#### retryAndFollowUpInterceptor 处理应答
```kotlin
   if (priorResponse != null) {
          response = response.newBuilder()
              .priorResponse(priorResponse.newBuilder()
                  .body(null)
                  .build())
              .build()
        }

        val exchange = call.interceptorScopedExchange
        val followUp = followUpRequest(response, exchange)

        if (followUp == null) {
          if (exchange != null && exchange.isDuplex) {
            call.timeoutEarlyExit()
          }
          closeActiveExchange = false
          return response
        }

        val followUpBody = followUp.body
        if (followUpBody != null && followUpBody.isOneShot()) {
          closeActiveExchange = false
          return response
        }

        response.body?.closeQuietly()

        if (++followUpCount > MAX_FOLLOW_UPS) {
          throw ProtocolException("Too many follow-up requests: $followUpCount")
        }

        request = followUp
        priorResponse = response
      } finally {
        call.exitNetworkInterceptorExchange(closeActiveExchange)
      }
```
- 1.每一次循环都会获取上次应答数据作为本次重定向或者权限询问的参数。
- 2.followUpRequest 根据当前的响应体，更新请求体中的内容。
- 3.如果当前的仇视次数超过了20次，就会抛出异常，跳出循环。
```kotlin
private const val MAX_FOLLOW_UPS = 20
```
其实整个重试拦截器最为核心的内容就是`followUpRequest`方法。


#### followUpRequest 根据应答重试请求处理
```kotlin
  private fun followUpRequest(userResponse: Response, exchange: Exchange?): Request? {
    val route = exchange?.connection?.route()
    val responseCode = userResponse.code

    val method = userResponse.request.method
    when (responseCode) {
      HTTP_PROXY_AUTH -> {
        val selectedProxy = route!!.proxy
        if (selectedProxy.type() != Proxy.Type.HTTP) {
          throw ProtocolException("Received HTTP_PROXY_AUTH (407) code while not using proxy")
        }
        return client.proxyAuthenticator.authenticate(route, userResponse)
      }

      HTTP_UNAUTHORIZED -> return client.authenticator.authenticate(route, userResponse)

      HTTP_PERM_REDIRECT, HTTP_TEMP_REDIRECT, HTTP_MULT_CHOICE, HTTP_MOVED_PERM, HTTP_MOVED_TEMP, HTTP_SEE_OTHER -> {
        return buildRedirectRequest(userResponse, method)
      }

      HTTP_CLIENT_TIMEOUT -> {
        // 408's are rare in practice, but some servers like HAProxy use this response code. The
        // spec says that we may repeat the request without modifications. Modern browsers also
        // repeat the request (even non-idempotent ones.)
        if (!client.retryOnConnectionFailure) {
          // The application layer has directed us not to retry the request.
          return null
        }

        val requestBody = userResponse.request.body
        if (requestBody != null && requestBody.isOneShot()) {
          return null
        }
        val priorResponse = userResponse.priorResponse
        if (priorResponse != null && priorResponse.code == HTTP_CLIENT_TIMEOUT) {
          // We attempted to retry and got another timeout. Give up.
          return null
        }

        if (retryAfter(userResponse, 0) > 0) {
          return null
        }

        return userResponse.request
      }

      HTTP_UNAVAILABLE -> {
        val priorResponse = userResponse.priorResponse
        if (priorResponse != null && priorResponse.code == HTTP_UNAVAILABLE) {
          // We attempted to retry and got another timeout. Give up.
          return null
        }

        if (retryAfter(userResponse, Integer.MAX_VALUE) == 0) {
          // specifically received an instruction to retry without delay
          return userResponse.request
        }

        return null
      }

      HTTP_MISDIRECTED_REQUEST -> {
        // OkHttp can coalesce HTTP/2 connections even if the domain names are different. See
        // RealConnection.isEligible(). If we attempted this and the server returned HTTP 421, then
        // we can retry on a different connection.
        val requestBody = userResponse.request.body
        if (requestBody != null && requestBody.isOneShot()) {
          return null
        }

        if (exchange == null || !exchange.isCoalescedConnection) {
          return null
        }

        exchange.connection.noCoalescedConnections()
        return userResponse.request
      }

      else -> return null
    }
  }
```
这个过程处理了几个HttpCode状态码:
```java
    public static final int HTTP_PROXY_AUTH = 407;
    public static final int HTTP_UNAUTHORIZED = 401;
    public static final int HTTP_CLIENT_TIMEOUT = 408;
    public static final int HTTP_UNAVAILABLE = 503;
```
```kotlin
    const val HTTP_TEMP_REDIRECT = 307
    const val HTTP_PERM_REDIRECT = 308
    const val HTTP_MISDIRECTED_REQUEST = 421
```
下面我们一个个的解析：

##### 状态码407 代理需要校验身份
```kotlin
        val selectedProxy = route!!.proxy
        if (selectedProxy.type() != Proxy.Type.HTTP) {
          throw ProtocolException("Received HTTP_PROXY_AUTH (407) code while not using proxy")
        }
        return client.proxyAuthenticator.authenticate(route, userResponse)
```
如果状态代码是407，此时会校验当前路由的代理模式是不是Http协议，不是则抛出异常，没有使用代理时候接受到了407。如果是，则通过`Authenticator`对响应体进行校验。

此时默认是设置没有任何行为的代理权限校验器。如果设置了就会调用Authenticator进行校验，这里面可以设置根据路由和响应体获取到对应的校验处理。可以来看看OkHttp内置的一个`JavaNetAuthenticator` 做了什么？
```kotlin
  @Throws(IOException::class)
  override fun authenticate(route: Route?, response: Response): Request? {
    val challenges = response.challenges()
    val request = response.request
    val url = request.url
    val proxyAuthorization = response.code == 407
    val proxy = route?.proxy ?: Proxy.NO_PROXY

    for (challenge in challenges) {
      if (!"Basic".equals(challenge.scheme, ignoreCase = true)) {
        continue
      }

      val dns = route?.address?.dns ?: defaultDns
      val auth = if (proxyAuthorization) {
        val proxyAddress = proxy.address() as InetSocketAddress
        Authenticator.requestPasswordAuthentication(
            proxyAddress.hostName,
            proxy.connectToInetAddress(url, dns),
            proxyAddress.port,
            url.scheme,
            challenge.realm,
            challenge.scheme,
            url.toUrl(),
            Authenticator.RequestorType.PROXY
        )
      } else {
        Authenticator.requestPasswordAuthentication(
            url.host,
            proxy.connectToInetAddress(url, dns),
            url.port,
            url.scheme,
            challenge.realm,
            challenge.scheme,
            url.toUrl(),
            Authenticator.RequestorType.SERVER
        )
      }

      if (auth != null) {
        val credentialHeader = if (proxyAuthorization) "Proxy-Authorization" else "Authorization"
        val credential = Credentials.basic(
            auth.userName, String(auth.password), challenge.charset)
        return request.newBuilder()
            .header(credentialHeader, credential)
            .build()
      }
    }

    return null // No challenges were satisfied!
  }
```
核心其实很简单，就是通过` Authenticator.requestPasswordAuthentication`获得一个`PasswordAuthentication`对象。从这个对象中获取对应代理设置的权限账号密码，并且设置到`Authorization`或者`Proxy-Authorization`头部key中，重试时候会带上这个头部放到新的请求中。

##### 状态码 401 	请求要求用户的身份认证
```kotlin
return client.authenticator.authenticate(route, userResponse)
```
说明此时需要通过Authenticator校验身份，可以发送自己的用户名和密码过去进行校验。


##### 状态码300，301，302，303，307，308
```kotlin
return buildRedirectRequest(userResponse, method)
```
状态码30X 系列一般是发生了资源变动处理的行为。如重定向跳转等。

- 300 是指有多种选择。请求的资源包含多个位置
- 301 请求的资源已经永久移动了 会自动重定向
- 302 临时移动，资源是临时转移了，客户端可以沿用原来的url
- 303 查看其他地址，可301类似
- 307 临时重定向，GET请求的重定向
- 308 和307类似也是临时重定向

```kotlin
  private fun buildRedirectRequest(userResponse: Response, method: String): Request? {
    if (!client.followRedirects) return null

    val location = userResponse.header("Location") ?: return null
    val url = userResponse.request.url.resolve(location) ?: return null

    val sameScheme = url.scheme == userResponse.request.url.scheme
    if (!sameScheme && !client.followSslRedirects) return null

    val requestBuilder = userResponse.request.newBuilder()
    if (HttpMethod.permitsRequestBody(method)) {
      val responseCode = userResponse.code
      val maintainBody = HttpMethod.redirectsWithBody(method) ||
          responseCode == HTTP_PERM_REDIRECT ||
          responseCode == HTTP_TEMP_REDIRECT
      if (HttpMethod.redirectsToGet(method) && responseCode != HTTP_PERM_REDIRECT && responseCode != HTTP_TEMP_REDIRECT) {
        requestBuilder.method("GET", null)
      } else {
        val requestBody = if (maintainBody) userResponse.request.body else null
        requestBuilder.method(method, requestBody)
      }
      if (!maintainBody) {
        requestBuilder.removeHeader("Transfer-Encoding")
        requestBuilder.removeHeader("Content-Length")
        requestBuilder.removeHeader("Content-Type")
      }
    }

    if (!userResponse.request.url.canReuseConnectionFor(url)) {
      requestBuilder.removeHeader("Authorization")
    }

    return requestBuilder.url(url).build()
  }
```
- 1.先从响应头，取出`Location`key对应的值，而这个值就是重定向之后的url路径。
- 2.并且校验这个请求是否是`GET`或者`HEAD`. 
  - 2.1.如果不是，则请求方式不是`PROPFIND` 且状态码不是`307`或者`308`状态码，则强制设置请求方式为`GET`
  - 2.2.否则则判断请求状态码是`307`或者`308`,或者请求方式是`PROPFIND`,那么继承之前设置的请求体。

- 3.不是`307`或者`308`且不是`PROPFIND`，则清掉Header中的`Content-Length`,`Transfer-Encoding`,`Content-Type`。

- 4.如果之前的请求和本次请求的host(主机)和port(端口)一致,则不需要`Authorization`校验身份。


##### 状态码408 服务器等待客户端发送请求超时处理
```kotlin
        if (!client.retryOnConnectionFailure) {
          return null
        }

        val requestBody = userResponse.request.body
        if (requestBody != null && requestBody.isOneShot()) {
          return null
        }
        val priorResponse = userResponse.priorResponse
        if (priorResponse != null && priorResponse.code == HTTP_CLIENT_TIMEOUT) {
          return null
        }

        if (retryAfter(userResponse, 0) > 0) {
          return null
        }

        return userResponse.request
```
状态码408不常见，但是在HAProxy中会比较常见。这种情况说明我们可以重复的进行没有修改过的请求(甚至是非幂等请求)。

> HAProxy 是一种高可用，负载均衡的，基于TCP和HTTP的应用程序代理。十分合适负载十分大的服务器。如github，stackflow等都集成了。它实现了事件驱动，单一进程模型支持十分大的(超越一个进程因内存模型而限制的线程数目)。

实际上还是那老一套的，基于系统调用epoll，select,poll等实现。


这一段代码的逻辑校验了如下逻辑：
- 1.当前okhttp是否允许重试
- 2.请求体是否允许重复发送
- 3.是否已经重试了，且重试的状态是否还是408
- 4.通过retryAfter获取响应头部信息`Retry-After`(头部存在该key，则设置为key的内容否则设置为0.不存在该key设置为INT的最大数值)。拿到重试时间后判断是否大于0，大于0说明此时返回一个空的请求对象，Okhttp将不会处理抛给业务层自己处理。

##### 状态码 503 由于服务器的异常导致无法完成客户端的请求
```kotlin
        val priorResponse = userResponse.priorResponse
        if (priorResponse != null && priorResponse.code == HTTP_UNAVAILABLE) {
          return null
        }

        if (retryAfter(userResponse, Integer.MAX_VALUE) == 0) {
          return userResponse.request
        }
        return null
```
如果上一次的请求已经是503了，就没必要重复请求了。且如果`Retry-After` 设置为0，说明需要立即重复请求，才会重新请求，其他情况下只会放弃请求。

##### 状态码421 超出了服务器最大连接数，需要重新请求
```kotlin
        val requestBody = userResponse.request.body
        if (requestBody != null && requestBody.isOneShot()) {
          return null
        }

        if (exchange == null || !exchange.isCoalescedConnection) {
          return null
        }

        exchange.connection.noCoalescedConnections()
        return userResponse.request
      }
``` 
这种情况下，只要requestBody允许重复发送，且host发生了变化，则重新返回请求体重新请求。这种情况下，一般是指Http 2.0协议。这种情况下，只要链接链接的得失同一个服务器，且RealConntection是合法的，如果服务器返回了421状态码，可以复用这个流。

### BridgeInterceptor 桥接拦截器

#### BridgeInterceptor 处理请求体头部
```kotlin
  @Throws(IOException::class)
  override fun intercept(chain: Interceptor.Chain): Response {
    val userRequest = chain.request()
    val requestBuilder = userRequest.newBuilder()

    val body = userRequest.body
    if (body != null) {
      val contentType = body.contentType()
      if (contentType != null) {
        requestBuilder.header("Content-Type", contentType.toString())
      }

      val contentLength = body.contentLength()
      if (contentLength != -1L) {
        requestBuilder.header("Content-Length", contentLength.toString())
        requestBuilder.removeHeader("Transfer-Encoding")
      } else {
        requestBuilder.header("Transfer-Encoding", "chunked")
        requestBuilder.removeHeader("Content-Length")
      }
    }

    if (userRequest.header("Host") == null) {
      requestBuilder.header("Host", userRequest.url.toHostHeader())
    }

    if (userRequest.header("Connection") == null) {
      requestBuilder.header("Connection", "Keep-Alive")
    }

    var transparentGzip = false
    if (userRequest.header("Accept-Encoding") == null && userRequest.header("Range") == null) {
      transparentGzip = true
      requestBuilder.header("Accept-Encoding", "gzip")
    }

    val cookies = cookieJar.loadForRequest(userRequest.url)
    if (cookies.isNotEmpty()) {
      requestBuilder.header("Cookie", cookieHeader(cookies))
    }

    if (userRequest.header("User-Agent") == null) {
      requestBuilder.header("User-Agent", userAgent)
    }

    val networkResponse = chain.proceed(requestBuilder.build())
...
  }
``` 
在请求到下一个拦截器之前，做了如下的事情：
- 1.设置头部的`Content-Type`.说明内容类型是什么
- 2.如果contentLength大于等于0，则设置头部的`Content-Length`(说明内容大小是多少)；否则设置头部的`Transfer-Encoding`为`chunked`(说明传输编码为分块传输)
- 3.如果`Host`不存在，设置头部的`Host`(在Http 1.1之后出现，可以通过同一个URL访问到不同主机，从而实现服务器虚拟服务器的负载均衡。如果1.1之后不设置就会返回404)。
- 4.如果`Connection`不存在，设置头部的`Connection`为`Keep-Alive`(代表链接状态需要保持活跃)
- 5.如果`Accept-Encoding`且`Range`为空，则强制设置`Accept-Encoding`为`gzip`(说明请求将会以gzip方式压缩)
- 6.从`CookieJar`的缓存中取出cookie设置到头部的`Cookie`
- 7.如果`User-Agent`为空，则设置`User-Agent`到头部

> Cookie是什么？Cookie是http协议中用于追踪用户会话的机制。注意Http协议是无状态的(但是底层构成http协议的tcp协议是有状态用于控制数据的正确性)。一个用户所有的请求都是同属一个会话。在http协议中，服务器为了得知客户端的身份会给每一个客户端分配一个cookie，同时在服务器有一个sessionID进行对应。都会保存在服务器的Map中。正是有这个上下文才会正确的知道该用户的的请求状态。




#### BridgeInterceptor 处理响应体
```kotlin

    cookieJar.receiveHeaders(userRequest.url, networkResponse.headers)

    val responseBuilder = networkResponse.newBuilder()
        .request(userRequest)

    if (transparentGzip &&
        "gzip".equals(networkResponse.header("Content-Encoding"), ignoreCase = true) &&
        networkResponse.promisesBody()) {
      val responseBody = networkResponse.body
      if (responseBody != null) {
        val gzipSource = GzipSource(responseBody.source())
        val strippedHeaders = networkResponse.headers.newBuilder()
            .removeAll("Content-Encoding")
            .removeAll("Content-Length")
            .build()
        responseBuilder.headers(strippedHeaders)
        val contentType = networkResponse.header("Content-Type")
        responseBuilder.body(RealResponseBody(contentType, -1L, gzipSource.buffer()))
      }
    }

    return responseBuilder.build()
```
- 1.读取响应头上的信息，把cookie'保存到CookieJar中
- 2.如果此时是`Content-Encoding`是gzip的内容压缩格式，则获取当前的响应体的内容，并根据 `Content-Type`把压缩格式还原，重新设置到响应体中。

#### CacheInterceptor 缓存拦截器

#### CacheInterceptor 缓存拦截器处理请求
```java
  override fun intercept(chain: Interceptor.Chain): Response {
    val call = chain.call()
    val cacheCandidate = cache?.get(chain.request())

    val now = System.currentTimeMillis()

    val strategy = CacheStrategy.Factory(now, chain.request(), cacheCandidate).compute()
    val networkRequest = strategy.networkRequest
    val cacheResponse = strategy.cacheResponse

    cache?.trackResponse(strategy)
    val listener = (call as? RealCall)?.eventListener ?: EventListener.NONE

    if (cacheCandidate != null && cacheResponse == null) {
      // The cache candidate wasn't applicable. Close it.
      cacheCandidate.body?.closeQuietly()
    }

    // If we're forbidden from using the network and the cache is insufficient, fail.
    if (networkRequest == null && cacheResponse == null) {
      return Response.Builder()
          .request(chain.request())
          .protocol(Protocol.HTTP_1_1)
          .code(HTTP_GATEWAY_TIMEOUT)
          .message("Unsatisfiable Request (only-if-cached)")
          .body(EMPTY_RESPONSE)
          .sentRequestAtMillis(-1L)
          .receivedResponseAtMillis(System.currentTimeMillis())
          .build().also {
            listener.satisfactionFailure(call, it)
          }
    }

    // If we don't need the network, we're done.
    if (networkRequest == null) {
      return cacheResponse!!.newBuilder()
          .cacheResponse(stripBody(cacheResponse))
          .build().also {
            listener.cacheHit(call, it)
          }
    }

    if (cacheResponse != null) {
      listener.cacheConditionalHit(call, cacheResponse)
    } else if (cache != null) {
      listener.cacheMiss(call)
    }

    var networkResponse: Response? = null
    try {
      networkResponse = chain.proceed(networkRequest)
    } finally {
      // If we're crashing on I/O or otherwise, don't leak the cache body.
      if (networkResponse == null && cacheCandidate != null) {
        cacheCandidate.body?.closeQuietly()
      }
    }

...
  }
```
- 1.先根据请求体的状态通过CacheStrategy获取到是否需要缓存，从而获得本次网络请求的请求体以及缓存的响应体，关键就是
```kotlin
val cacheCandidate = cache?.get(chain.request())
 CacheStrategy.Factory(now, chain.request(), cacheCandidate).compute()
```

- 2.如果两者都获取不到，此时会返回协议http 1.1，错误代码为`504`，消息是禁止了网络请求但是缓存响应不存在的应答消息体。

- 3.如果只是网络请求不存在，而缓存的响应体存在，则根据缓存的响应构造出响应体对象，返回cacheHit会爱到并返回。

- 4.如果网络请求存在，则正常的进入下一个拦截器中。


##### Cache get 从LRUCache中获取缓存

```kotlin
@JvmStatic
    fun key(url: HttpUrl): String = url.toString().encodeUtf8().md5().hex()

  internal fun get(request: Request): Response? {
    val key = key(request.url)
    val snapshot: DiskLruCache.Snapshot = try {
      cache[key] ?: return null
    } catch (_: IOException) {
      return null // Give up because the cache cannot be read.
    }

    val entry: Entry = try {
      Entry(snapshot.getSource(ENTRY_METADATA))
    } catch (_: IOException) {
      snapshot.closeQuietly()
      return null
    }

    val response = entry.response(snapshot)
    if (!entry.matches(request, response)) {
      response.body?.closeQuietly()
      return null
    }

    return response
  }
```
 - 1.首先把url路径转化成utf-8，并且md5一下拿到摘要，并调用hex获取摘要的16进制的字符串，这个字符串就是LRUCache的key

- 2.通过key拿到Cache中DiskLruCache.Snapshot对象，每一个Snapshot就是LRUCache的缓存单位。每一个缓存单位中都缓存一个文件，在cache的get操作方法重写中，会读取数据为Okio的Source

```kotlin
  operator fun get(key: String): Snapshot? {
    initialize()

    checkNotClosed()
    validateKey(key)
    val entry = lruEntries[key] ?: return null
    val snapshot = entry.snapshot() ?: return null

    redundantOpCount++
    journalWriter!!.writeUtf8(READ)
        .writeByte(' '.toInt())
        .writeUtf8(key)
        .writeByte('\n'.toInt())
    if (journalRebuildRequired()) {
      cleanupQueue.schedule(cleanupTask)
    }

    return snapshot
  }
```

- 3.把数据转化为Respone 响应体


##### CacheStrategy compute 计算获取请求对应的缓存

```kotlin
    fun compute(): CacheStrategy {
      val candidate = computeCandidate()

      // We're forbidden from using the network and the cache is insufficient.
      if (candidate.networkRequest != null && request.cacheControl.onlyIfCached) {
        return CacheStrategy(null, null)
      }

      return candidate
    }

    /** Returns a strategy to use assuming the request can use the network. */
    private fun computeCandidate(): CacheStrategy {
      // No cached response.
      if (cacheResponse == null) {
        return CacheStrategy(request, null)
      }

      // Drop the cached response if it's missing a required handshake.
      if (request.isHttps && cacheResponse.handshake == null) {
        return CacheStrategy(request, null)
      }

      if (!isCacheable(cacheResponse, request)) {
        return CacheStrategy(request, null)
      }

      val requestCaching = request.cacheControl
      if (requestCaching.noCache || hasConditions(request)) {
        return CacheStrategy(request, null)
      }

      val responseCaching = cacheResponse.cacheControl

      val ageMillis = cacheResponseAge()
      var freshMillis = computeFreshnessLifetime()

      if (requestCaching.maxAgeSeconds != -1) {
        freshMillis = minOf(freshMillis, SECONDS.toMillis(requestCaching.maxAgeSeconds.toLong()))
      }

      var minFreshMillis: Long = 0
      if (requestCaching.minFreshSeconds != -1) {
        minFreshMillis = SECONDS.toMillis(requestCaching.minFreshSeconds.toLong())
      }

      var maxStaleMillis: Long = 0
      if (!responseCaching.mustRevalidate && requestCaching.maxStaleSeconds != -1) {
        maxStaleMillis = SECONDS.toMillis(requestCaching.maxStaleSeconds.toLong())
      }

      if (!responseCaching.noCache && ageMillis + minFreshMillis < freshMillis + maxStaleMillis) {
        val builder = cacheResponse.newBuilder()
        if (ageMillis + minFreshMillis >= freshMillis) {
          builder.addHeader("Warning", "110 HttpURLConnection \"Response is stale\"")
        }
        val oneDayMillis = 24 * 60 * 60 * 1000L
        if (ageMillis > oneDayMillis && isFreshnessLifetimeHeuristic()) {
          builder.addHeader("Warning", "113 HttpURLConnection \"Heuristic expiration\"")
        }
        return CacheStrategy(null, builder.build())
      }

      // Find a condition to add to the request. If the condition is satisfied, the response body
      // will not be transmitted.
      val conditionName: String
      val conditionValue: String?
      when {
        etag != null -> {
          conditionName = "If-None-Match"
          conditionValue = etag
        }

        lastModified != null -> {
          conditionName = "If-Modified-Since"
          conditionValue = lastModifiedString
        }

        servedDate != null -> {
          conditionName = "If-Modified-Since"
          conditionValue = servedDateString
        }

        else -> return CacheStrategy(request, null) // No condition! Make a regular request.
      }

      val conditionalRequestHeaders = request.headers.newBuilder()
      conditionalRequestHeaders.addLenient(conditionName, conditionValue!!)

      val conditionalRequest = request.newBuilder()
          .headers(conditionalRequestHeaders.build())
          .build()
      return CacheStrategy(conditionalRequest, cacheResponse)
    }

```
从LRUCache中获取到缓存的应答数据，将会做如下的Header的校验。

先来看看CacheStagty的初始化：

```kotlin
    init {
      if (cacheResponse != null) {
        this.sentRequestMillis = cacheResponse.sentRequestAtMillis
        this.receivedResponseMillis = cacheResponse.receivedResponseAtMillis
        val headers = cacheResponse.headers
        for (i in 0 until headers.size) {
          val fieldName = headers.name(i)
          val value = headers.value(i)
          when {
            fieldName.equals("Date", ignoreCase = true) -> {
              servedDate = value.toHttpDateOrNull()
              servedDateString = value
            }
            fieldName.equals("Expires", ignoreCase = true) -> {
              expires = value.toHttpDateOrNull()
            }
            fieldName.equals("Last-Modified", ignoreCase = true) -> {
              lastModified = value.toHttpDateOrNull()
              lastModifiedString = value
            }
            fieldName.equals("ETag", ignoreCase = true) -> {
              etag = value
            }
            fieldName.equals("Age", ignoreCase = true) -> {
              ageSeconds = value.toNonNegativeInt(-1)
            }
          }
        }
      }
    }
```

分别取出了缓存头部中的：
- 1.Date  缓存应答的发送到客户端的时间
- 2.Expires 代表应答可以存活时间
- 3.Last-Modified 代表服务器用来校验客户端的请求是否是最新的时间，不是则返回304
- 4.ETag 用于记录当前请求页面状态时效的token
- 5.Age 代理服务器用自己去缓存应答的时候，该头部代表从诞生到现在多长时间

获得这些基础数据后，上面的compute就是根据这5个标志位进行计算。

- 1.cacheResponseAge 计算这个缓存真正缓存时间方式：

> 接受消耗的时间 = max(Response抵达客户端的时间 - Response从服务端发出的时间(Date字段),Age字段,0)
> Response来回时间 = Response抵达客户端的时间 - 客户端发送的时间
> 缓存时间 = 当前时间 - Response抵达客户端的时间
> 当前应答真实缓存时间 = 接受消耗的时间 + Response来回时间 + 缓存时间

- 2.computeFreshnessLifetime 遵循如下的逻辑计算缓存有效性时间段
> 优先取出CacheControl的maxAge 字段，存在则返回
> 其次取出expires 字段，expires - (Date字段 或者 Response抵达客户端时间)
> 最后取出lastModified字段， (Date字段 或者 Response抵达客户端时间) - lastModified(上次修改)

这样计算差值就能大致获得这个缓存比较精确的有效时间。

- 3.cacheResponseAge 获取到的缓存的时间和 computeFreshnessLifetime计算出来的缓存时效性，以及在okhttp设置的最小缓存minFreshSeconds时效，通过下面简单的计算：
> cacheResponseAge + minFreshSeconds > computeFreshnessLifetime

就能知道当前缓存是否有效，从而决定是否返回一个CacheResponse上去。


#### CacheInterceptor 缓存拦截器进行网络请求后的处理
```kotlin
    // If we have a cache response too, then we're doing a conditional get.
    if (cacheResponse != null) {
      if (networkResponse?.code == HTTP_NOT_MODIFIED) {
        val response = cacheResponse.newBuilder()
            .headers(combine(cacheResponse.headers, networkResponse.headers))
            .sentRequestAtMillis(networkResponse.sentRequestAtMillis)
            .receivedResponseAtMillis(networkResponse.receivedResponseAtMillis)
            .cacheResponse(stripBody(cacheResponse))
            .networkResponse(stripBody(networkResponse))
            .build()

        networkResponse.body!!.close()

        // Update the cache after combining headers but before stripping the
        // Content-Encoding header (as performed by initContentStream()).
        cache!!.trackConditionalCacheHit()
        cache.update(cacheResponse, response)
        return response.also {
          listener.cacheHit(call, it)
        }
      } else {
        cacheResponse.body?.closeQuietly()
      }
    }

    val response = networkResponse!!.newBuilder()
        .cacheResponse(stripBody(cacheResponse))
        .networkResponse(stripBody(networkResponse))
        .build()

    if (cache != null) {
      if (response.promisesBody() && CacheStrategy.isCacheable(response, networkRequest)) {
        // Offer this request to the cache.
        val cacheRequest = cache.put(response)
        return cacheWritingResponse(cacheRequest, response).also {
          if (cacheResponse != null) {
            // This will log a conditional cache miss only.
            listener.cacheMiss(call)
          }
        }
      }

      if (HttpMethod.invalidatesCache(networkRequest.method)) {
        try {
          cache.remove(networkRequest)
        } catch (_: IOException) {
          // The cache cannot be written.
        }
      }
    }

    return response
```
- 1.如果当前缓存响应体存在，且当前网络请求返回的状态代码为`304`。在http协议中说明此时请求没有发生变化，那么就会根据缓存响应体构造一个全新的响应体，并更新当前的是时间戳，最后更新了到缓存中，并返回到上层。

- 2.不为`304`情况，且缓存策略是允许刷新的，还是会把当前成功的响应体保存到Cache中最后返回。

来看看如何判断那些响应体可以进行缓存：

```kotlin
    fun isCacheable(response: Response, request: Request): Boolean {
      // Always go to network for uncacheable response codes (RFC 7231 section 6.1), This
      // implementation doesn't support caching partial content.
      when (response.code) {
        HTTP_OK,
        HTTP_NOT_AUTHORITATIVE,
        HTTP_NO_CONTENT,
        HTTP_MULT_CHOICE,
        HTTP_MOVED_PERM,
        HTTP_NOT_FOUND,
        HTTP_BAD_METHOD,
        HTTP_GONE,
        HTTP_REQ_TOO_LONG,
        HTTP_NOT_IMPLEMENTED,
        StatusLine.HTTP_PERM_REDIRECT -> {
          // These codes can be cached unless headers forbid it.
        }

        HTTP_MOVED_TEMP,
        StatusLine.HTTP_TEMP_REDIRECT -> {
          // These codes can only be cached with the right response headers.
          // http://tools.ietf.org/html/rfc7234#section-3
          // s-maxage is not checked because OkHttp is a private cache that should ignore s-maxage.
          if (response.header("Expires") == null &&
              response.cacheControl.maxAgeSeconds == -1 &&
              !response.cacheControl.isPublic &&
              !response.cacheControl.isPrivate) {
            return false
          }
        }

        else -> {
          // All other codes cannot be cached.
          return false
        }
      }

      // A 'no-store' directive on request or response prevents the response from being cached.
      return !response.cacheControl.noStore && !request.cacheControl.noStore
    }
  }
```
- 1.302,307状态码状态下，需要判断获取头部中的`Expires`数值，获取不存在。并且`Cache-Control`头部中`max-age`为-1，且`public`和`private`都存在的时候。

Expires和max-age 说明了有效期为无限长，public说明http通信的过程中，包括请求的发起方、代理缓存服务器都可以进行缓存。private说明http通信过程中只有请求方可以缓存。

- 2.如果状态码为200，203，204，300，301，404，405，410，414，501，308都可以缓存。

- 2.其他情况都返回false，不允许缓存


## 总结

到这里就完成了对Okhttp头三层协议的解析，能看到实际上头三层主要处理的是Http协议中状态码所对应的行为。

Http响应状态码大致上可以分为如下几种情况：

### 2XX 代表请求成功

200，203，204 代表请求成功，可以对响应数据进行缓存

### 30X 代表资源发生变动或者没有变动

- 300 是指有多种选择。请求的资源包含多个位置，此时请求也可以看作成功，此时也会进行缓存起来。此时也会记录下需要跳转Header中的Location，并重新设置为全新的跳转url。记住这个过程是先执行了缓存拦截器后，再执行跳转拦截器。

- 301 请求的资源已经永久移动了 会自动重定向。此时还是一样会缓存当前的结果后，尝试获取Location的url 进行重定向（Http 1.0内容），不允许重定向时候改变请求方式(如get转化成post)

- 302 代表临时移动的资源，所以没有特殊处理并不会缓存结果，因为这个响应数据很可能时效性很短；但是如果设置了`Cache-Control`，`Expires`这些缓存时效头部就会进行缓存，接着会获取Location的url 进行重定向（Http 1.0内容），不允许重定向时候改变请求方式(如get转化成post)

- 303 代表查看其他资源，而这个过程可以不视作一个正常的响应结果，也因为允许改变请求方式；因此也不会进行缓存，接着会获取Location的url 进行重定向.

- 304 代表资源没有发生变动，且缓存策略是允许刷新的。那么就说明服务器这段时间内对这个请求的应答没有变化，客户端直接从缓存获取即可。此时客户端就会从缓存拦截器中的缓存对象获取缓存好的响应信息。

- 307 同302 也是一个临时移动资源的标志位，不同的是这是来自Http 1.1协议。为什么出现一个一样的呢？因为302在很多浏览器的实现是允许改变请求方式，因此307强制规定不允许改变

- 308 同301 是一个永久移动的资源路径，来自Http 1.1.原因也是因为强制规范不允许改变请求方式，但是允许进行缓存。


### 4XX 客户端异常或者客户端需要特殊处理

- 401 请求要求用户的身份认证。这个过程就会获取设置在Authenticator 中的账号密码，添加到头部中重试这个请求。

- 403 代表拒绝访问，okhttp不会做任何处理直接返回

- 404 代表客户端请求异常，说明这个url的请求状态有问题，okhttp也会进行缓存学习，下一次再一次访问的时候就会直接返回异常。

- 405 代表当前请求的方式出错了，这个请求不支持这种请求方式

- 407 和401类似 不过在这里面代表的是使用代理的Authenticator. authenticate 进行账号密码的校验

- 408 服务器等待客户端发送请求超时处理  状态码408不常见，但是在HAProxy中会比较常见。这种情况说明我们可以重复的进行没有修改过的请求(甚至是非幂等请求),从头部中获取对应的key，从而决定是否立即重试

- 410 代表资源已经不可用了，此时okhttp也会学习，缓存这个结果直到超过缓存时效。

- 414 代表请求的URL长度超出了服务器可以处理的长度。很少见这种情况，这种也是数据一种异常，所以okhttp也会获取摘要学习

- 421 代表客户端所在的ip地址到服务器的连接数超过了服务器最大的连接数。此时还是有机会进行重新请求，因为在Http 2.0协议中允许流的复用。

### 5XX 服务端异常

- 500 服务端出现了无法处理的错误，直接报错了。 这种情况不会做处理，直接抛出错误即可

- 501 服务端此时不支持请求所需要的功能，服务器无法识别请求的方法，并且无法支持对任何资源的请求。 这种错误okhhtp可以缓存学习，因为是服务器的web系统需要升级了。

- 503 服务器过载，暂时不处理。一般会带上`Retry-After` 告诉客户端延时多少时间之后再次请求。然而okhttp不会做延时处理，而是交给开发者处理，他只会处理`Retry-After` 为0的情况，也就是立即处理

- 504 一般是指网关超时，注意如果okhttp禁止了网络请求和缓存也会返回504

### retryAndFollowUpInterceptor

主要处理了如下几个方向的问题：
- 1.异常，或者协议重试(408客户端超时，权限问题，503服务暂时不处理，retry-after为0)
- 2.重定向
- 3.重试的次数不能超过20次。


### BridgeInterceptor

主要是把Cookie，Content-type设置到头部中。很多时候，初学者会疑惑为什么自己加的头部会失效，就是因为在Application拦截器中处理后，又被BridgeInterceptor 覆盖了。需要使用networkInterceptor


### CacheInterceptor

主要是处理304等响应体的缓存。通过DiskLruCache缓存起来。


到这里前三层属于对Http协议处理的拦截器就完成了，接下来几层就是okhttp如何管理链接的。