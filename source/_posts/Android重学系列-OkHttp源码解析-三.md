---
title: Android重学系列 OkHttp源码解析(三)
top: false
cover: false
date: 2020-10-24 23:02:05
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

上一篇文章和大家聊了聊Okhttp前三个拦截器，本文来聊聊ConnectInterceptor 链接拦截器都负责什么职责。

本文将不会了聊自定义的网络拦截器以及自定义的用户拦截器。

阅读本文之前，最好对SSL/TLS有一定的了解,具体的协议细节可看[https://tools.ietf.org/html/rfc7540](https://tools.ietf.org/html/rfc7540)，快速入门可看[阮一峰的SSL/TLS介绍](http://www.ruanyifeng.com/blog/2014/02/ssl_tls.html)。不过不懂没关系，阅读完okhttp如何处理SSL/TLS的，就能明白整个流程是如何运作的了。

总的一句话就是，SSL/TLS 就是我们常说的Https的加密手段。SSL是专门指代安全套字节(SSL Socket),而后SSL的基础上发展出了TLS。

> TLS 1.0通常被标示为SSL 3.1，TLS 1.1为SSL 3.2，TLS 1.2为SSL 3.3

可以说是一个东西。

# 正文

## ConnectInterceptor 链接拦截器 查找可靠链接

```kotlin
object ConnectInterceptor : Interceptor {
  @Throws(IOException::class)
  override fun intercept(chain: Interceptor.Chain): Response {
    val realChain = chain as RealInterceptorChain
    val exchange = realChain.call.initExchange(chain)
    val connectedChain = realChain.copy(exchange = exchange)
    return connectedChain.proceed(realChain.request)
  }
}
```

- 1.RealCall.initExchange 初始化可交换链接对象
- 2.copy拷贝一个全新的RealInterceptorChain对象，并调用这个对象的proceed方法。

核心还是RealCall.initExchange

### RealCall.initExchange

```kotlin
  internal fun initExchange(chain: RealInterceptorChain): Exchange {
    synchronized(this) {
      check(expectMoreExchanges) { "released" }
      check(!responseBodyOpen)
      check(!requestBodyOpen)
    }

    val exchangeFinder = this.exchangeFinder!!
    val codec = exchangeFinder.find(client, chain)
    val result = Exchange(this, eventListener, exchangeFinder, codec)
    this.interceptorScopedExchange = result
    this.exchange = result
    synchronized(this) {
      this.requestBodyOpen = true
      this.responseBodyOpen = true
    }

    if (canceled) throw IOException("Canceled")
    return result
  }
```
整个核心是使用exchangeFinder.find 找到ExchangeCodec后生成Exchange对象，并返回该对象。

#### ExchangeFinder find

```kotlin
  fun find(
    client: OkHttpClient,
    chain: RealInterceptorChain
  ): ExchangeCodec {
    try {
      val resultConnection = findHealthyConnection(
          connectTimeout = chain.connectTimeoutMillis,
          readTimeout = chain.readTimeoutMillis,
          writeTimeout = chain.writeTimeoutMillis,
          pingIntervalMillis = client.pingIntervalMillis,
          connectionRetryEnabled = client.retryOnConnectionFailure,
          doExtensiveHealthChecks = chain.request.method != "GET"
      )
      return resultConnection.newCodec(client, chain)
    } catch (e: RouteException) {
      trackFailure(e.lastConnectException)
      throw e
    } catch (e: IOException) {
      trackFailure(e)
      throw RouteException(e)
    }
  }
```

- 1.通过findHealthyConnection，获取一个“健康”的链接，也就是保持存活的链接。

- 2.调用RealConnection 的 newCodec并返回。


#### findHealthyConnection  查找活跃的链接

```kotlin
  @Throws(IOException::class)
  private fun findHealthyConnection(
    connectTimeout: Int,
    readTimeout: Int,
    writeTimeout: Int,
    pingIntervalMillis: Int,
    connectionRetryEnabled: Boolean,
    doExtensiveHealthChecks: Boolean
  ): RealConnection {
    while (true) {
      val candidate = findConnection(
          connectTimeout = connectTimeout,
          readTimeout = readTimeout,
          writeTimeout = writeTimeout,
          pingIntervalMillis = pingIntervalMillis,
          connectionRetryEnabled = connectionRetryEnabled
      )


      if (candidate.isHealthy(doExtensiveHealthChecks)) {
        return candidate
      }

      candidate.noNewExchanges()

      if (nextRouteToTry != null) continue

      val routesLeft = routeSelection?.hasNext() ?: true
      if (routesLeft) continue

      val routesSelectionLeft = routeSelector?.hasNext() ?: true
      if (routesSelectionLeft) continue

      throw IOException("exhausted all routes")
    }
  }
```
- 1.findConnection 从Okhttp的链接池中查找对应的RealConnection
- 2.isHealthy 校验筛选出链接是否活跃
- 3.如果判断到当前的链接是不活跃的，且可以匹配当前新的请求路径的，那么就通过noNewExchanges方法设置RealConnection的noNewExchanges为true，表示当前的链接可能有问题，被阻止进一步链接了。
- 4.此时虽然找到了链接，但是是不健康的，那么从RouteSelector 找到新的routesLeft，如果存在可以匹配多个route的情况则进入下一个轮回。

其实这些标志位最终都会作用到findConnection 方法中.


#### findConnection 查找匹配当前资源路径的链接

```kotlin
  @Throws(IOException::class)
  private fun findConnection(
    connectTimeout: Int,
    readTimeout: Int,
    writeTimeout: Int,
    pingIntervalMillis: Int,
    connectionRetryEnabled: Boolean
  ): RealConnection {
    if (call.isCanceled()) throw IOException("Canceled")

    val callConnection = call.connection // This may be mutated by releaseConnectionNoEvents()!
    if (callConnection != null) {
      var toClose: Socket? = null
      synchronized(callConnection) {
        if (callConnection.noNewExchanges || !sameHostAndPort(callConnection.route().address.url)) {
          toClose = call.releaseConnectionNoEvents()
        }
      }

      if (call.connection != null) {
        check(toClose == null)
        return callConnection
      }

      // The call's connection was released.
      toClose?.closeQuietly()
      eventListener.connectionReleased(call, callConnection)
    }

    // We need a new connection. Give it fresh stats.
    refusedStreamCount = 0
    connectionShutdownCount = 0
    otherFailureCount = 0

    // Attempt to get a connection from the pool.
    if (connectionPool.callAcquirePooledConnection(address, call, null, false)) {
      val result = call.connection!!
      eventListener.connectionAcquired(call, result)
      return result
    }

    // Nothing in the pool. Figure out what route we'll try next.
    val routes: List<Route>?
    val route: Route
    if (nextRouteToTry != null) {
      // Use a route from a preceding coalesced connection.
      routes = null
      route = nextRouteToTry!!
      nextRouteToTry = null
    } else if (routeSelection != null && routeSelection!!.hasNext()) {
      // Use a route from an existing route selection.
      routes = null
      route = routeSelection!!.next()
    } else {
      // Compute a new route selection. This is a blocking operation!
      var localRouteSelector = routeSelector
      if (localRouteSelector == null) {
        localRouteSelector = RouteSelector(address, call.client.routeDatabase, call, eventListener)
        this.routeSelector = localRouteSelector
      }
      val localRouteSelection = localRouteSelector.next()
      routeSelection = localRouteSelection
      routes = localRouteSelection.routes

      if (call.isCanceled()) throw IOException("Canceled")

      if (connectionPool.callAcquirePooledConnection(address, call, routes, false)) {
        val result = call.connection!!
        eventListener.connectionAcquired(call, result)
        return result
      }

      route = localRouteSelection.next()
    }

    // Connect. Tell the call about the connecting call so async cancels work.
    val newConnection = RealConnection(connectionPool, route)
    call.connectionToCancel = newConnection
    try {
      newConnection.connect(
          connectTimeout,
          readTimeout,
          writeTimeout,
          pingIntervalMillis,
          connectionRetryEnabled,
          call,
          eventListener
      )
    } finally {
      call.connectionToCancel = null
    }
    call.client.routeDatabase.connected(newConnection.route())

    if (connectionPool.callAcquirePooledConnection(address, call, routes, true)) {
      val result = call.connection!!
      nextRouteToTry = route
      newConnection.socket().closeQuietly()
      eventListener.connectionAcquired(call, result)
      return result
    }

    synchronized(newConnection) {
      connectionPool.put(newConnection)
      call.acquireConnectionNoEvents(newConnection)
    }

    eventListener.connectionAcquired(call, newConnection)
    return newConnection
  }

```
因为RealCall可以从之前的缓存队列获取，因此里面可能RealCall本身就存在RealConnection。

因此可以分为3种情况：
- 1.RealCall缓存了RealConnection 但是不匹配的情况
- 2.RealCall缓存了RealConnection 匹配的情况
- 3.RealCall没有缓存RealConnection

- 1.此时会校验如果发现RealCall中存在缓存的RealConnection，那么就校验noNewExchanges为true 或者校验 到url中的host和port不一致，则调用releaseConnectionNoEvents 方法，把RealConnection绑定的RealCall队列中对应的RealCall移除，并从ConnectionPool中移除该RealConnection，当前RealCall中绑定的RealConnection设置为空

```kotlin
  fun sameHostAndPort(url: HttpUrl): Boolean {
    val routeUrl = address.url
    return url.port == routeUrl.port && url.host == routeUrl.host
  }

  internal fun releaseConnectionNoEvents(): Socket? {
    val connection = this.connection!!
    connection.assertThreadHoldsLock()

    val calls = connection.calls
    val index = calls.indexOfFirst { it.get() == this@RealCall }
    check(index != -1)

    calls.removeAt(index)
    this.connection = null

    if (calls.isEmpty()) {
      connection.idleAtNs = System.nanoTime()
      if (connectionPool.connectionBecameIdle(connection)) {
        return connection.socket()
      }
    }

    return null
  }；
```

并获取当前缓存RealConnection的socket对象，并关闭该socket。

当然，如果出现了noNewExchanges 为false 且 host和port都匹配则返回，不会关闭RealConnection的socket。



- 2.处理RealCall没有缓存RealConnection 或者 RealConnection不匹配情况下，清除缓存重新申请RealCall。

  - 2.1. 首先从ConnectionPool的callAcquirePooledConnection方法中获取一个可用的RealConnection，找到匹配且可用的链接则直接返回。
  - 2.2. 如果ConnectionPool找不到匹配的RealConnection ，生成或者获取RouteSelector，从中获取routes对象并callAcquirePooledConnection 试着从路由中获取可复用的RealConnection
- 2.3. 什么都找不到，则会通过RealConnectionPool 生成RealConnection。 
    - 2.3.1 调用RealConnection.connect 进行链接RouteDatabase.connected 从失败的路由缓存中移除
    - 2.3.2 生成一个新的RealConnection后，继续从RealConnectionPool查找是否可以和另一个链接合并起来(http 2.0),可以则复用之前的RealConnection
    - 2.3.3 如果不能复用，则吧当前的RealConnection 添加到RealConnectionPool 中，并返回

在这个过程中有几个比较核心的方法：
- 1.connectionPool.callAcquirePooledConnection 
- 2. RouteSelector 生成
- 3. RealConnection.connect


##### connectionPool.callAcquirePooledConnection 

使用这个方法的时候分为3种情况：
- 1.直接从connectionPool 中查找RealConnection 传入的routes为null和 requireMultiplexed 为false
- 2.传入的routes为 Route集合和 requireMultiplexed 为false
- 3.传入的routes为 Route集合和 requireMultiplexed 为true

```kotlin
  fun callAcquirePooledConnection(
    address: Address,
    call: RealCall,
    routes: List<Route>?,
    requireMultiplexed: Boolean
  ): Boolean {
    for (connection in connections) {
      synchronized(connection) {
        if (requireMultiplexed && !connection.isMultiplexed) return@synchronized
        if (!connection.isEligible(address, routes)) return@synchronized
        call.acquireConnectionNoEvents(connection)
        return true
      }
    }
    return false
  }
```

- 1. 如果requireMultiplexed为true且RealConnection的isMultiplexed（可复用，只有在http 2.0协议中，才会打开这个协议）表为false 则进入下一个connections index的循环
- 2. 判断到connection的isEligible 校验到当前的RealConnection不合格则进入下一个循环
- 3. 通过上述两个判断火都通过就返回true，否则就是false。

###### RealConnection isEligible 判断是否复用合法

```kotlin
  private var allocationLimit = 1

  internal fun isEligible(address: Address, routes: List<Route>?): Boolean {
    assertThreadHoldsLock()

    if (calls.size >= allocationLimit || noNewExchanges) return false

    if (!this.route.address.equalsNonHost(address)) return false

    if (address.url.host == this.route().address.url.host) {
      return true // This connection is a perfect match.
    }

    if (http2Connection == null) return false

    // 2. The routes must share an IP address.
    if (routes == null || !routeMatchesAny(routes)) return false

    // 3. This connection's server certificate's must cover the new host.
    if (address.hostnameVerifier !== OkHostnameVerifier) return false
    if (!supportsUrl(address.url)) return false

    // 4. Certificate pinning must match the host.
    try {
      address.certificatePinner!!.check(address.url.host, handshake()!!.peerCertificates)
    } catch (_: SSLPeerUnverifiedException) {
      return false
    }

    return true // The caller's address can be carried by this connection.
  }
```

- 1.如果当前RealConnection复用的RealCall队列的大小大于allocationLimit 限制大小，或者noNewExchanges 为true ；则返回false。allocationLimit 代表了Okhttp在http 2.0协议中允许一个最大能够复用的链接，超出则说明不能继续复用了。noNewExchanges 链接链接后发现是不活跃的。

- 2.如果RealConnection 中的route和当前传递进来的地址的address不一致，直接返回false即可

- 3.如果RealConnection 中的route 和传递进来的host一致了，那么说明address和host都一致就是一个资源路径可以返回true。

- 4. 如果host 不一致，且http2Connection 为空，也就不是http 2.0协议，那么就不可能做到不同的资源路径进行复用的情况直接返回

- 5.此时就是必须要符合http 2.0的协议才能进行链接的复用，也就是路由可以共享。如果传进来的routes是空 或者通过routeMatchesAny 查找只要出现socket的地址一致且是直接链接的地址，则返回true，返回false一半就是代理的服务。此时就会直接返回。

- 6.想要进一步匹配，那么整个网络请求的HostnameVerifier 校验服务器主机名的必须为OkHostnameVerifier

- 7.其次匹配HttpUrl和RealConnection的route 能否匹配。如果port 端口不匹配则直接返回false，如果host 匹配则直接返回true。否则就必须要保证`noCoalescedConnections ` 为true （`noCoalescedConnections` 这个标志位为true，则说明该链接可以共享链接，但是不共享主机.），handshake不为空（说明已经经过了三次握手），且本次校验可以通过主机服务器名的校验。

```kotlin
  private fun supportsUrl(url: HttpUrl): Boolean {
    assertThreadHoldsLock()

    val routeUrl = route.address.url

    if (url.port != routeUrl.port) {
      return false // Port mismatch.
    }

    if (url.host == routeUrl.host) {
      return true // Host match. The URL is supported.
    }

    // We have a host mismatch. But if the certificate matches, we're still good.
    return !noCoalescedConnections && handshake != null && certificateSupportHost(url, handshake!!)
  }

  private fun certificateSupportHost(url: HttpUrl, handshake: Handshake): Boolean {
    val peerCertificates = handshake.peerCertificates

    return peerCertificates.isNotEmpty() && OkHostnameVerifier.verify(url.host,
        peerCertificates[0] as X509Certificate)
  }

```

- 8. address.certificatePinner!!.check 则是校验每一个Certificate 是否都是X509Certificate类型,且加密的方式是否是`sha256` 或者 `sha1`
```kotlin
  fun check(hostname: String, peerCertificates: List<Certificate>) {
    return check(hostname) {
      (certificateChainCleaner?.clean(peerCertificates, hostname) ?: peerCertificates)
          .map { it as X509Certificate }
    }
  }
```

##### RouteSelector 生成

```kotlin
      var localRouteSelector = routeSelector
      if (localRouteSelector == null) {
        localRouteSelector = RouteSelector(address, call.client.routeDatabase, call, eventListener)
        this.routeSelector = localRouteSelector
      }
```

还记得routeDatabase 是用于记录黑名单的路由。

```kotlin
on
class RouteSelector(
  private val address: Address,
  private val routeDatabase: RouteDatabase,
  private val call: Call,
  private val eventListener: EventListener
) {
  init {
    resetNextProxy(address.url, address.proxy)
  }
...
}
```

###### resetNextProxy 初始化代理代理队列

```kotlin
  private fun resetNextProxy(url: HttpUrl, proxy: Proxy?) {
    fun selectProxies(): List<Proxy> {
      if (proxy != null) return listOf(proxy)

      val uri = url.toUri()
      if (uri.host == null) return immutableListOf(Proxy.NO_PROXY)

      val proxiesOrNull = address.proxySelector.select(uri)
      if (proxiesOrNull.isNullOrEmpty()) return immutableListOf(Proxy.NO_PROXY)

      return proxiesOrNull.toImmutableList()
    }

    eventListener.proxySelectStart(call, url)
    proxies = selectProxies()
    nextProxyIndex = 0
    eventListener.proxySelectEnd(call, url, proxies)
  }
```

- 1.如果Address的Proxy不为空，则缓存到队列返回
- 2.如果host为为空，则直接返回一个`Proxy.NO_PROXY`无代理到缓存队列中
- 3.调用Address的ProxySelector的select获取代理队列。
一个例子,下面是默认的ProxySelector：
```kotlin
object NullProxySelector : ProxySelector() {
  override fun select(uri: URI?): List<Proxy> {
    requireNotNull(uri) { "uri must not be null" }
    return listOf(Proxy.NO_PROXY)
  }

  override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {
  }
}
```

能看到实际上如果没有设定，ProxySelector默认就是Proxy.NO_PROXY（无代理状态）。而如果有需要进行代理可以在OkhttpClientBuilder的addProxy中为不同的uri设置自己的代理规则。





直接来看看这个对象的next 迭代方法是什么：
```kotlin
 @Throws(IOException::class)
  operator fun next(): Selection {
    if (!hasNext()) throw NoSuchElementException()

    // Compute the next set of routes to attempt.
    val routes = mutableListOf<Route>()
    while (hasNextProxy()) {

      val proxy = nextProxy()
      for (inetSocketAddress in inetSocketAddresses) {
        val route = Route(address, proxy, inetSocketAddress)
        if (routeDatabase.shouldPostpone(route)) {
          postponedRoutes += route
        } else {
          routes += route
        }
      }

      if (routes.isNotEmpty()) {
        break
      }
    }

    if (routes.isEmpty()) {
      routes += postponedRoutes
      postponedRoutes.clear()
    }

    return Selection(routes)
  }

  private fun nextProxy(): Proxy {
    if (!hasNextProxy()) {
      throw SocketException(
          "No route to ${address.url.host}; exhausted proxy configurations: $proxies")
    }
    val result = proxies[nextProxyIndex++]
    resetNextInetSocketAddress(result)
    return result
  }
```

- 1. nextProxy 不断的迭代遍历初始化时候获取的所有的proxies 代理对象(从Address的ProxySelector)调用resetNextInetSocketAddress

```kotlin

  @Throws(IOException::class)
  private fun resetNextInetSocketAddress(proxy: Proxy) {
    // Clear the addresses. Necessary if getAllByName() below throws!
    val mutableInetSocketAddresses = mutableListOf<InetSocketAddress>()
    inetSocketAddresses = mutableInetSocketAddresses

    val socketHost: String
    val socketPort: Int
    if (proxy.type() == Proxy.Type.DIRECT || proxy.type() == Proxy.Type.SOCKS) {
      socketHost = address.url.host
      socketPort = address.url.port
    } else {
      val proxyAddress = proxy.address()
      require(proxyAddress is InetSocketAddress) {
        "Proxy.address() is not an InetSocketAddress: ${proxyAddress.javaClass}"
      }
      socketHost = proxyAddress.socketHost
      socketPort = proxyAddress.port
    }

    if (socketPort !in 1..65535) {
      throw SocketException("No route to $socketHost:$socketPort; port is out of range")
    }

    if (proxy.type() == Proxy.Type.SOCKS) {
      mutableInetSocketAddresses += InetSocketAddress.createUnresolved(socketHost, socketPort)
    } else {
      eventListener.dnsStart(call, socketHost)

      // Try each address for best behavior in mixed IPv4/IPv6 environments.
      val addresses = address.dns.lookup(socketHost)
      if (addresses.isEmpty()) {
        throw UnknownHostException("${address.dns} returned no addresses for $socketHost")
      }

      eventListener.dnsEnd(call, socketHost, addresses)

      for (inetAddress in addresses) {
        mutableInetSocketAddresses += InetSocketAddress(inetAddress, socketPort)
      }
    }
  }
```
- 1.1.如果代理类型是 `Proxy.Type.SOCKS` socket代理，那么先获得Address的host以及port，并调用`InetSocketAddress.createUnresolved` 解析套字节地址并保存到mutableInetSocketAddresses集合中

- 1.2.如果代理类型是`Proxy.Type.DIRECT` 则先获取Address的host和port，并调用Address的DNS方法调用lookup 查询 host，并生成InetSocketAddress保存到mutableInetSocketAddresses集合中。

- 1.3. 如果代理类型是其他，如`Proxy.Type.HTTP`，则获取传递进来的Proxy中的host和port，在DNS的lookup 查询转化的地址，并生成一个InetSocketAddress保存到mutableInetSocketAddresses。

注意默认的DNS是DnsSystem对象

```kotlin
    @JvmField
    val SYSTEM: Dns = DnsSystem()
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

能看到这个过程实际上是InetAddress.getAllByName 会查询DNS服务器解析主机地址返回InetAddress。InetAddress实际上就是在java中代表IP地址的对象。

这样就能拿到该地址对应所有的服务器主机的ip地址。



- 2. 当所有的代理和非代理，解析出来的主机ip都保存到inetSocketAddresses集合后，就会遍历这个集合生成一个个对应的Route对象，这个对象会缓存ip地址对象以及代理对象，并保存到Selection的routes中，返回。


#### RealConnection.connect

```kotlin
  fun connect(
    connectTimeout: Int,
    readTimeout: Int,
    writeTimeout: Int,
    pingIntervalMillis: Int,
    connectionRetryEnabled: Boolean,
    call: Call,
    eventListener: EventListener
  ) {
    check(protocol == null) { "already connected" }

    var routeException: RouteException? = null
    val connectionSpecs = route.address.connectionSpecs
    val connectionSpecSelector = ConnectionSpecSelector(connectionSpecs)

...
    while (true) {
      try {
        if (route.requiresTunnel()) {
          connectTunnel(connectTimeout, readTimeout, writeTimeout, call, eventListener)
          if (rawSocket == null) {
            break
          }
        } else {
          connectSocket(connectTimeout, readTimeout, call, eventListener)
        }
        establishProtocol(connectionSpecSelector, pingIntervalMillis, call, eventListener)
        eventListener.connectEnd(call, route.socketAddress, route.proxy, protocol)
        break
      } catch (e: IOException) {
        socket?.closeQuietly()
        rawSocket?.closeQuietly()
        socket = null
        rawSocket = null
        source = null
        sink = null
        handshake = null
        protocol = null
        http2Connection = null
        allocationLimit = 1

        eventListener.connectFailed(call, route.socketAddress, route.proxy, null, e)

        if (routeException == null) {
          routeException = RouteException(e)
        } else {
          routeException.addConnectException(e)
        }

        if (!connectionRetryEnabled || !connectionSpecSelector.connectionFailed(e)) {
          throw routeException
        }
      }
    }

    if (route.requiresTunnel() && rawSocket == null) {
      throw RouteException(ProtocolException(
          "Too many tunnel connections attempted: $MAX_TUNNEL_ATTEMPTS"))
    }

    idleAtNs = System.nanoTime()
  }
```

在这里可以分为2种情况：

- 1.requiresTunnel 判断当前的代理是http代理，那么就会调用`connectTunnel`方法链接socket
- 2. 如果是其他代理方式，那么就是调用connectSocket 方式链接socket

当上面2个步骤都完成之后，就会统一调用establishProtocol 进行协议的处理。


先来看看connectSocket 都做了什么。


##### connectSocket

```kotlin
  @Throws(IOException::class)
  private fun connectSocket(
    connectTimeout: Int,
    readTimeout: Int,
    call: Call,
    eventListener: EventListener
  ) {
    val proxy = route.proxy
    val address = route.address

    val rawSocket = when (proxy.type()) {
      Proxy.Type.DIRECT, Proxy.Type.HTTP -> address.socketFactory.createSocket()!!
      else -> Socket(proxy)
    }
    this.rawSocket = rawSocket

    eventListener.connectStart(call, route.socketAddress, proxy)
    rawSocket.soTimeout = readTimeout
    try {
      Platform.get().connectSocket(rawSocket, route.socketAddress, connectTimeout)
    } catch (e: ConnectException) {
      throw ConnectException("Failed to connect to ${route.socketAddress}").apply {
        initCause(e)
      }
    }

    // The following try/catch block is a pseudo hacky way to get around a crash on Android 7.0
    // More details:
    // https://github.com/square/okhttp/issues/3245
    // https://android-review.googlesource.com/#/c/271775/
    try {
      source = rawSocket.source().buffer()
      sink = rawSocket.sink().buffer()
    } catch (npe: NullPointerException) {
      if (npe.message == NPE_THROW_WITH_NULL) {
        throw IOException(npe)
      }
    }
  }
```


- 1.如果是直连或者是Http代理，则通过默认的SocketFactory创建socket对象。默认是DefaultSocketFactory 对象，但是通过SocketFactory 就进行了结偶，允许我们自己定义Socket
```java
public Socket createSocket() {
        return new Socket();
    }
```
- 2.如果是Socket代理，直接生成一个Socket对象
- 3.回调connectStart 监听
- 4.调用Socket的connect 链接上InetSocketAddress 对应的ip地址
```kotlin
  @Throws(IOException::class)
  open fun connectSocket(socket: Socket, address: InetSocketAddress, connectTimeout: Int) {
    socket.connect(address, connectTimeout)
  }
```
- 5.通过Okio分别获取source  写入流和sink 输出流缓存在RealConnection中。

##### connectTunnel 

```kotlin
    private const val MAX_TUNNEL_ATTEMPTS = 21

  @Throws(IOException::class)
  private fun connectTunnel(
    connectTimeout: Int,
    readTimeout: Int,
    writeTimeout: Int,
    call: Call,
    eventListener: EventListener
  ) {
    var tunnelRequest: Request = createTunnelRequest()
    val url = tunnelRequest.url
    for (i in 0 until MAX_TUNNEL_ATTEMPTS) {
      connectSocket(connectTimeout, readTimeout, call, eventListener)
      tunnelRequest = createTunnel(readTimeout, writeTimeout, tunnelRequest, url)
          ?: break // Tunnel successfully created.

      rawSocket?.closeQuietly()
      rawSocket = null
      sink = null
      source = null
      eventListener.connectEnd(call, route.socketAddress, route.proxy, null)
    }
  }
```
- 1.createTunnelRequest 创建一个通道确认的请求
- 2.首先调用connectSocket 尝试着链接服务器地址
- 3.createTunnel 回去http协议下的返回的结果数据生成新的Request。如果返回Request 不是空空则重新尝试，直到21次为止。

##### createTunnelRequest 创建一个通道确认的请求

```kotlin
  private fun createTunnelRequest(): Request {
    val proxyConnectRequest = Request.Builder()
        .url(route.address.url)
        .method("CONNECT", null)
        .header("Host", route.address.url.toHostHeader(includeDefaultPort = true))
        .header("Proxy-Connection", "Keep-Alive") // For HTTP/1.0 proxies like Squid.
        .header("User-Agent", userAgent)
        .build()

    val fakeAuthChallengeResponse = Response.Builder()
        .request(proxyConnectRequest)
        .protocol(Protocol.HTTP_1_1)
        .code(HTTP_PROXY_AUTH)
        .message("Preemptive Authenticate")
        .body(EMPTY_RESPONSE)
        .sentRequestAtMillis(-1L)
        .receivedResponseAtMillis(-1L)
        .header("Proxy-Authenticate", "OkHttp-Preemptive")
        .build()

    val authenticatedRequest = route.address.proxyAuthenticator
        .authenticate(route, fakeAuthChallengeResponse)

    return authenticatedRequest ?: proxyConnectRequest
  }
```
这个过程构建了构建了一个代理用的proxyConnectRequest 链接请求对象，以及一个虚假的响应，这个响应会包含proxyConnectRequest。然后通过设置的proxyAuthenticator 进行权限校验。

可以阅读源码JavaNetAuthenticator 中的实现：

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

  @Throws(IOException::class)
  private fun Proxy.connectToInetAddress(url: HttpUrl, dns: Dns): InetAddress {
    return when (type()) {
      Proxy.Type.DIRECT -> dns.lookup(url.host).first()
      else -> (address() as InetSocketAddress).address
    }
  }
```

校验方式实际上就是获取Response中的Header的challenges

```kotlin
  fun challenges(): List<Challenge> {
    return headers.parseChallenges(
        when (code) {
          HTTP_UNAUTHORIZED -> "WWW-Authenticate"
          HTTP_PROXY_AUTH -> "Proxy-Authenticate"
          else -> return emptyList()
        }
    )
  }
```
也就是拿到当前的状态码:
- 1.如果是401 则设置为`WWW-Authenticate`
- 2.如果是407 ，则设置`Proxy-Authenticate`

然后以这两个字符串为key 寻找设置Header的数值到Challenge对象中。

在这个过程构建了一个虚假的应答，答应的状态码为407.所以会生成一个对应的Challenge对象。然而此时在头部中设置了`OkHttp-Preemptive` 对应的value，那么在调用`Authenticator.requestPasswordAuthentication`方法就会把如`WWW-Authenticate: Basic realm="请求域"` 取出`realm`中的请求域，提交给Authenticator(通过`Authenticator.setDefault` 在本地设置的)认证。

注意在这个过程中还是会调用一次DNS的lookup方法，把url解析成对应主机的ip地址。

并返回校验权限的authenticatedRequest Request请求对象，注意观察这个对象，如果在本地的验证器认证通过后，会在新的请求头部中设置好`Basic:账号:密码`。



##### createTunnel 根据socket链接返回的结构构建新的Request

```kotlin
  @Throws(IOException::class)
  private fun createTunnel(
    readTimeout: Int,
    writeTimeout: Int,
    tunnelRequest: Request,
    url: HttpUrl
  ): Request? {
    var nextRequest = tunnelRequest
    // Make an SSL Tunnel on the first message pair of each SSL + proxy connection.
    val requestLine = "CONNECT ${url.toHostHeader(includeDefaultPort = true)} HTTP/1.1"
    while (true) {
      val source = this.source!!
      val sink = this.sink!!
      val tunnelCodec = Http1ExchangeCodec(null, this, source, sink)
      source.timeout().timeout(readTimeout.toLong(), MILLISECONDS)
      sink.timeout().timeout(writeTimeout.toLong(), MILLISECONDS)
      tunnelCodec.writeRequest(nextRequest.headers, requestLine)
      tunnelCodec.finishRequest()
      val response = tunnelCodec.readResponseHeaders(false)!!
          .request(nextRequest)
          .build()
      tunnelCodec.skipConnectBody(response)

      when (response.code) {
        HTTP_OK -> {
          if (!source.buffer.exhausted() || !sink.buffer.exhausted()) {
            throw IOException("TLS tunnel buffered too many bytes!")
          }
          return null
        }

        HTTP_PROXY_AUTH -> {
          nextRequest = route.address.proxyAuthenticator.authenticate(route, response)
              ?: throw IOException("Failed to authenticate with proxy")

          if ("close".equals(response.header("Connection"), ignoreCase = true)) {
            return nextRequest
          }
        }

        else -> throw IOException("Unexpected response code for CONNECT: ${response.code}")
      }
    }
  }
```
核心是构建了一个Http1ExchangeCodec对象，把之前通过Socket.connect获取到的输入输出流保存在其中，接着依次执行如下步骤：

- 1.设置输入输出流的超时时间
- 2.往Http1ExchangeCodec 中先往socket写入缓冲区写入 `"CONNECT ${host:port} HTTP/1.1"` (也就是把host和port写入到头部),接着往socket 的写入缓冲区写入 之前带上 校验的账号密码的头部。
- 3.调用Http1ExchangeCodec的finishRequest，把缓冲区的数据推到socket链接的服务器。
- 4.Http1ExchangeCodec 将会读取socket返回的头部信息以及响应状态码，如果为`200`则说明且有数据，则返回空。如果为`407` 则为权限校验出问题了，这一次再通过服务器那边返回的响应体，在本地中获取账号密码后再重新请求依次，直到`200`成功为止。


##### establishProtocol 处理协议链接

```kotlin
  @Throws(IOException::class)
  private fun establishProtocol(
    connectionSpecSelector: ConnectionSpecSelector,
    pingIntervalMillis: Int,
    call: Call,
    eventListener: EventListener
  ) {
    if (route.address.sslSocketFactory == null) {
      if (Protocol.H2_PRIOR_KNOWLEDGE in route.address.protocols) {
        socket = rawSocket
        protocol = Protocol.H2_PRIOR_KNOWLEDGE
        startHttp2(pingIntervalMillis)
        return
      }

      socket = rawSocket
      protocol = Protocol.HTTP_1_1
      return
    }

    eventListener.secureConnectStart(call)
    connectTls(connectionSpecSelector)
    eventListener.secureConnectEnd(call, handshake)

    if (protocol === Protocol.HTTP_2) {
      startHttp2(pingIntervalMillis)
    }
  }
```
整个过程分为3个情况：

- 1.如果没有设置sslSocketFactory (也就是安全套接字协议层的socket生成池)为空，说明可以进行明文传输。
  - 1.1.如果在Route.Address中的协议包含了`H2_PRIOR_KNOWLEDGE`也就是`h2_prior_knowledge` 调用startHttp2 启动Http 2.0协议

  - 1.2.如果不包含`H2_PRIOR_KNOWLEDGE` 又不存在sslSocketFactory。那么协议就会退化到http 1.1中

- 2.如果sslSocketFactory 存在，那么就会调用connectTls 进行链接，如果发现是http2.0协议，就调用startHttp2。


`h2_prior_knowledge` 这个协议，在RFC 第 3.4节中有介绍，实际上就是指可以对服务器发送一个序言(preface)，用于识别当前服务器是否支持http2.0的协议。如果支持可以直接进行发送数据帧，当然这个协议只建立在http2.0明文传输中。如果服务端实现的是TLS的Http 2.0，必须使用TLS方式进行传输。


整个核心有两个，都是关于Http 2.0的：
- startHttp2
- connectTls

我们从假设此时sslSocketFactory 存在，先调用connectTls 方法处理TLS协议

###### connectTls

```kotlin
  @Throws(IOException::class)
  private fun connectTls(connectionSpecSelector: ConnectionSpecSelector) {
    val address = route.address
    val sslSocketFactory = address.sslSocketFactory
    var success = false
    var sslSocket: SSLSocket? = null
    try {
      // Create the wrapper over the connected socket.
      sslSocket = sslSocketFactory!!.createSocket(
          rawSocket, address.url.host, address.url.port, true /* autoClose */) as SSLSocket

      // Configure the socket's ciphers, TLS versions, and extensions.
      val connectionSpec = connectionSpecSelector.configureSecureSocket(sslSocket)
      if (connectionSpec.supportsTlsExtensions) {
        Platform.get().configureTlsExtensions(sslSocket, address.url.host, address.protocols)
      }

      // Force handshake. This can throw!
      sslSocket.startHandshake()
      // block for session establishment
      val sslSocketSession = sslSocket.session
      val unverifiedHandshake = sslSocketSession.handshake()

      // Verify that the socket's certificates are acceptable for the target host.
...

      val certificatePinner = address.certificatePinner!!

      handshake = Handshake(unverifiedHandshake.tlsVersion, unverifiedHandshake.cipherSuite,
          unverifiedHandshake.localCertificates) {
        certificatePinner.certificateChainCleaner!!.clean(unverifiedHandshake.peerCertificates,
            address.url.host)
      }

      // Check that the certificate pinner is satisfied by the certificates presented.
      certificatePinner.check(address.url.host) {
        handshake!!.peerCertificates.map { it as X509Certificate }
      }

      // Success! Save the handshake and the ALPN protocol.
      val maybeProtocol = if (connectionSpec.supportsTlsExtensions) {
        Platform.get().getSelectedProtocol(sslSocket)
      } else {
        null
      }
      socket = sslSocket
      source = sslSocket.source().buffer()
      sink = sslSocket.sink().buffer()
      protocol = if (maybeProtocol != null) Protocol.get(maybeProtocol) else Protocol.HTTP_1_1
      success = true
    } finally {
      if (sslSocket != null) {
        Platform.get().afterHandshake(sslSocket)
      }
      if (!success) {
        sslSocket?.closeQuietly()
      }
    }
  }
```

- 1.sslSocketFactory!!.createSocket 通过工厂创建一个SSL 的socket
- 2. 获取Okhttp的Platform，调用configureTlsExtensions 配置SSLSocket
- 3. sslSocket. startHandshake 开始进行握手
- 4. 获取sslSocket的session，调用session的handshake方法
- 5.构建一个HandShake对象，CertificatePinner 对 Session的Certificate集合通过X509TrustManagerExtensions 校验，从这些证书集合中晒选出信任的证书。
- 6.从这些Certificate集合中，进一步的筛选出类型为X509Certificate的证书。
- 7.如果当前的请求支持tls的扩展，那么就从Platform中获取当前匹配的协议，进行协议切换。
- 8.最后，获取sslSocket的写入写出流缓存到RealConnection中。

![OkhttpPlatform.png](/images/OkhttpPlatform.png)

在Okhttp中内部设置如上几中platform，当然我们Android开发只需要关注AndroidPlatform以及Android10Platform。其实就是一个适配器模式。至于如何检测出Android还是Java其实很简单：

```kotlin
    val isAndroid: Boolean
        get() = "Dalvik" == System.getProperty("java.vm.name")
```

通过获取java的虚拟机名字，如果是`Dalvik`则是Android环境。说明不管是ART虚拟机还是Dalvik虚拟机，一般情况下，虚拟机名字都是Dalvik。

###### startHttp2

```kotlin
  @Throws(IOException::class)
  private fun startHttp2(pingIntervalMillis: Int) {
    val socket = this.socket!!
    val source = this.source!!
    val sink = this.sink!!
    socket.soTimeout = 0 // HTTP/2 connection timeouts are set per-stream.
    val http2Connection = Http2Connection.Builder(client = true, taskRunner = TaskRunner.INSTANCE)
        .socket(socket, route.address.url.host, source, sink)
        .listener(this)
        .pingIntervalMillis(pingIntervalMillis)
        .build()
    this.http2Connection = http2Connection
    this.allocationLimit = Http2Connection.DEFAULT_SETTINGS.getMaxConcurrentStreams()
    http2Connection.start()
  }

```

首先构建了一个Http2Connection对象，并把任务调度工具TaskRunner 和socket设置在其中，最后调用http2Connection的start方法。

注意如果是经过了TLS/SSL 此时的socket 是在connecttls中设置的SSL Socket。否则就是在establishProtocol 中设置的普通socket。

##### Http2Connection 的初始化

```kotlin
  init {
    if (builder.pingIntervalMillis != 0) {
      val pingIntervalNanos = TimeUnit.MILLISECONDS.toNanos(builder.pingIntervalMillis.toLong())
      writerQueue.schedule("$connectionName ping", pingIntervalNanos) {
        val failDueToMissingPong = synchronized(this@Http2Connection) {
          if (intervalPongsReceived < intervalPingsSent) {
            return@synchronized true
          } else {
            intervalPingsSent++
            return@synchronized false
          }
        }
        if (failDueToMissingPong) {
          failConnection(null)
          return@schedule -1L
        } else {
          writePing(false, INTERVAL_PING, 0)
          return@schedule pingIntervalNanos
        }
      }
    }
  }
``` 

关于TaskRunner的实现这里不多说，writerQueue实际上通过TaskRunner生成一个`TaskQueue`对象。TaskRunner内置了Backend对象，他里面就是一个线程池，阻塞队列为一对一的`SynchronousQueue `.

每当进行调度发送到任务处理，就会把这个Runnable封装成Task对象，添加到`TaskQueue`的`futureTasks`队列末尾，然后调用TaskRunner的Backend对象，在线程池中执行Task。当然如果正在工作了，调用Backend的执行而是把`TaskQueue`添加到`TaskRunner`的`readyQueues`中. 在Backend的线程池子中有一个写好的Runnable，消费这些队列：

```kotlin
  private val runnable: Runnable = object : Runnable {
    override fun run() {
      while (true) {
        val task = synchronized(this@TaskRunner) {
          awaitTaskToRun()
        } ?: return

        logElapsed(task, task.queue!!) {
          var completedNormally = false
          try {
            runTask(task)
            completedNormally = true
          } finally {
            // If the task is crashing start another thread to service the queues.
            if (!completedNormally) {
              backend.execute(this)
            }
          }
        }
      }
    }
  }
```

可以看到实际上线程执行的是一个looper，循环处理,核心是awaitTaskToRun 下面一段

```kotlin
      eachQueue@ for (queue in readyQueues) {
        val candidate = queue.futureTasks[0]
        val candidateDelay = maxOf(0L, candidate.nextExecuteNanoTime - now)

        when {
          // Compute the delay of the soonest-executable task.
          candidateDelay > 0L -> {
            minDelayNanos = minOf(candidateDelay, minDelayNanos)
            continue@eachQueue
          }

          // If we already have more than one task, that's enough work for now. Stop searching.
          readyTask != null -> {
            multipleReadyTasks = true
            break@eachQueue
          }

          // We have a task to execute when we complete the loop.
          else -> {
            readyTask = candidate
          }
        }
      }
```
这个过程实际上是不断的消费距离当前时间最近的Task。

这个Task实际上做的事情就是一个执行writePing 发送心跳包给服务器。

###### writePing

```kotlin
  val writer = Http2Writer(builder.sink, client)

  fun writePing(
    reply: Boolean,
    payload1: Int,
    payload2: Int
  ) {
    try {
      writer.ping(reply, payload1, payload2)
    } catch (e: IOException) {
      failConnection(e)
    }
  }
```
这个过程实际上就是通过Http2Writer 往服务器写数据帧数。

```kotlin
  fun ping(ack: Boolean, payload1: Int, payload2: Int) {
    if (closed) throw IOException("closed")
    frameHeader(
        streamId = 0,
        length = 8,
        type = TYPE_PING,
        flags = if (ack) FLAG_ACK else FLAG_NONE
    )
    sink.writeInt(payload1)
    sink.writeInt(payload2)
    sink.flush()
  }
```

注意几个参数：
- ack 为false
- payload1是指
```kotlin
const val INTERVAL_PING = 1
```
- payload2是指0

先通过frameHeader 生成一个数据帧，然后依次写入1和0

```kotlin
  const val FLAG_NONE = 0x0
  const val FLAG_ACK = 0x1 // Used for settings and ping.
  const val TYPE_PING = 0x6

  @Throws(IOException::class)
  fun frameHeader(streamId: Int, length: Int, type: Int, flags: Int) {
...
    sink.writeMedium(length) // 
    sink.writeByte(type and 0xff)
    sink.writeByte(flags and 0xff)
    sink.writeInt(streamId and 0x7fffffff)
  }

fun BufferedSink.writeMedium(medium: Int) {
  writeByte(medium.ushr(16) and 0xff) //向右移动高16位，获取低16位，也就是拿到最高的16位(31~16)
  writeByte(medium.ushr(8) and 0xff) //向右移动8位，也就是(24~8)
  writeByte(medium and 0xff) // 直接获取低16位
}
```

从这里，我们可以得到如下的数据结构
![http2ping第一帧.png](/images/http2ping第一帧.png)


##### http2Connection.start
```kotlin
  @Throws(IOException::class) @JvmOverloads
  fun start(sendConnectionPreface: Boolean = true, taskRunner: TaskRunner = TaskRunner.INSTANCE) {
    if (sendConnectionPreface) {
      writer.connectionPreface()
      writer.settings(okHttpSettings)
      val windowSize = okHttpSettings.initialWindowSize
      if (windowSize != DEFAULT_INITIAL_WINDOW_SIZE) {
        writer.windowUpdate(0, (windowSize - DEFAULT_INITIAL_WINDOW_SIZE).toLong())
      }
    }

    taskRunner.newQueue().execute(name = connectionName, block = readerRunnable)
  }
```

- 1.首先调用connectionPreface 往socket里写入序言，说明客户端要开始发送数据了。

```kotlin
  @JvmField
  val CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".encodeUtf8()

  @Synchronized @Throws(IOException::class)
  fun connectionPreface() {
    if (closed) throw IOException("closed")
    if (!client) return // Nothing to write; servers don't send connection headers!
    if (logger.isLoggable(FINE)) {
      logger.fine(format(">> CONNECTION ${CONNECTION_PREFACE.hex()}"))
    }
    sink.write(CONNECTION_PREFACE)
    sink.flush()
  }
```

这个过程往socket中写入字符串`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`

- 2.Http2Writer.settings 往socket中写入的配置

```kotlin

  /** Settings we communicate to the peer. */
  val okHttpSettings = Settings().apply {
    if (builder.client) {
      set(Settings.INITIAL_WINDOW_SIZE, OKHTTP_CLIENT_WINDOW_SIZE)
    }
  }
```

实际上在Settings中持有一个数组，数组每一位代表一种设置。设置这个初始数据输出窗口大小为16M。这个窗口和tcp的滑动窗口需要区分开。这个是为了避免出现Http2.0上传太多数据流而做的限制。

下面是配置http2.0的列表
```kotlin
  companion object {
    /**
     * From the HTTP/2 specs, the default initial window size for all streams is 64 KiB. (Chrome 25
     * uses 10 MiB).
     */
    const val DEFAULT_INITIAL_WINDOW_SIZE = 65535

    /** HTTP/2: Size in bytes of the table used to decode the sender's header blocks. */
    const val HEADER_TABLE_SIZE = 1
    /** HTTP/2: The peer must not send a PUSH_PROMISE frame when this is 0. */
    const val ENABLE_PUSH = 2
    /** Sender's maximum number of concurrent streams. */
    const val MAX_CONCURRENT_STREAMS = 4
    /** HTTP/2: Size in bytes of the largest frame payload the sender will accept. */
    const val MAX_FRAME_SIZE = 5
    /** HTTP/2: Advisory only. Size in bytes of the largest header list the sender will accept. */
    const val MAX_HEADER_LIST_SIZE = 6
    /** Window size in bytes. */
    const val INITIAL_WINDOW_SIZE = 7

    /** Total number of settings. */
    const val COUNT = 10
  }
```
- 1.HEADER_TABLE_SIZE 用于解码发送方头部的字节大小，这个大小由服务器发送回来的应答进行调整
- 2.ENABLE_PUSH 对端是否可以进行数据传输。默认是允许的。
- 3.MAX_CONCURRENT_STREAMS 发送端最大的并发流数目 
- 4.MAX_FRAME_SIZE 发送端一帧数据最大能接受多大，初始大小为16384(16kb).
- 5.MAX_HEADER_LIST_SIZE 发送端最大能接受的一帧数据
- 6.INITIAL_WINDOW_SIZE 所有并发流控制窗口初始大小，初始大小为65535.但是当时调用http2Connection的时候，就修改为16M。

```kotlin

  @Synchronized @Throws(IOException::class)
  fun settings(settings: Settings) {
    if (closed) throw IOException("closed")
    frameHeader(
        streamId = 0,
        length = settings.size() * 6,
        type = TYPE_SETTINGS,
        flags = FLAG_NONE
    )
    for (i in 0 until Settings.COUNT) {
      if (!settings.isSet(i)) continue
      val id = when (i) {
        4 -> 3 // SETTINGS_MAX_CONCURRENT_STREAMS renumbered.
        7 -> 4 // SETTINGS_INITIAL_WINDOW_SIZE renumbered.
        else -> i
      }
      sink.writeShort(id)
      sink.writeInt(settings[i])
    }
    sink.flush()
  }
```

![传送settings.png](/images/传送settings.png)

- 3.调用windowUpdate 往socket里面写入并发流控制窗体变化情况。

```kotlin
  @Synchronized @Throws(IOException::class)
  fun windowUpdate(streamId: Int, windowSizeIncrement: Long) {
    if (closed) throw IOException("closed")
    require(windowSizeIncrement != 0L && windowSizeIncrement <= 0x7fffffffL) {
      "windowSizeIncrement == 0 || windowSizeIncrement > 0x7fffffffL: $windowSizeIncrement"
    }
    frameHeader(
        streamId = streamId,
        length = 4,
        type = TYPE_WINDOW_UPDATE,
        flags = FLAG_NONE
    )
    sink.writeInt(windowSizeIncrement.toInt())
    sink.flush()
  }
```
![窗体变化数据.png](/images/窗体变化数据.png)


- 4.异步线程执行readerRunnable ，发送完配置数据后等待服务器的响应数据
```kotlin
  val readerRunnable = ReaderRunnable(Http2Reader(builder.source, client))
```

#### ReaderRunnable与Http2Reader 读取服务端发送的数据

```kotlin
  inner class ReaderRunnable internal constructor(
    internal val reader: Http2Reader
  ) : Http2Reader.Handler, () -> Unit {
    override fun invoke() {
      var connectionErrorCode = ErrorCode.INTERNAL_ERROR
      var streamErrorCode = ErrorCode.INTERNAL_ERROR
      var errorException: IOException? = null
      try {
        reader.readConnectionPreface(this)
        while (reader.nextFrame(false, this)) {
        }
        connectionErrorCode = ErrorCode.NO_ERROR
        streamErrorCode = ErrorCode.CANCEL
      } catch (e: IOException) {
        errorException = e
        connectionErrorCode = ErrorCode.PROTOCOL_ERROR
        streamErrorCode = ErrorCode.PROTOCOL_ERROR
      } finally {
        close(connectionErrorCode, streamErrorCode, errorException)
        reader.closeQuietly()
      }
    }
```
能看到实际上做了如下的事情：
- 1.从Http2Reader的readConnectionPreface 读取标示头
- 2.调用reader.nextFrame 不断的读取下一帧的响应数据，直到结束为止。

##### Http2Reader readConnectionPreface

```kotlin
  @Throws(IOException::class)
  fun readConnectionPreface(handler: Handler) {
    if (client) {
      if (!nextFrame(true, handler)) {
        throw IOException("Required SETTINGS preface not received")
      }
    } else {
...
    }
  }
```

能看到readConnectionPreface 方法核心也是nextFrame的方法。

##### Http2Reader nextFrame

```kotlin
  @Throws(IOException::class)
  fun nextFrame(requireSettings: Boolean, handler: Handler): Boolean {
    try {
      source.require(9) // Frame header size.
    } catch (e: EOFException) {
      return false // This might be a normal socket close.
    }

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                 Length (24)                   |
    // +---------------+---------------+---------------+
    // |   Type (8)    |   Flags (8)   |
    // +-+-+-----------+---------------+-------------------------------+
    // |R|                 Stream Identifier (31)                      |
    // +=+=============================================================+
    // |                   Frame Payload (0...)                      ...
    // +---------------------------------------------------------------+
    val length = source.readMedium()
    if (length > INITIAL_MAX_FRAME_SIZE) {
      throw IOException("FRAME_SIZE_ERROR: $length")
    }
    val type = source.readByte() and 0xff
    val flags = source.readByte() and 0xff
    val streamId = source.readInt() and 0x7fffffff // Ignore reserved bit.
...
    when (type) {
      TYPE_DATA -> readData(handler, length, flags, streamId)
      TYPE_HEADERS -> readHeaders(handler, length, flags, streamId)
      TYPE_PRIORITY -> readPriority(handler, length, flags, streamId)
      TYPE_RST_STREAM -> readRstStream(handler, length, flags, streamId)
      TYPE_SETTINGS -> readSettings(handler, length, flags, streamId)
      TYPE_PUSH_PROMISE -> readPushPromise(handler, length, flags, streamId)
      TYPE_PING -> readPing(handler, length, flags, streamId)
      TYPE_GOAWAY -> readGoAway(handler, length, flags, streamId)
      TYPE_WINDOW_UPDATE -> readWindowUpdate(handler, length, flags, streamId)
      else -> source.skip(length.toLong()) // Implementations MUST discard frames of unknown types.
    }

    return true
  }
```

服务端传递过来的结构和客户端传递过去的一致：
- 1.首先解析当前数据帧有多长
- 2.然后获取当前数据帧的类型type
- 3.接着获取数据帧的flag
- 4.获取当前数据帧所属的数据流id
- 5.根据类型从而解析不同的数据。

![Http2 数据帧.png](/images/Http2数据帧.png)



上面我们依次发送了如下的类型的数据：
- 1.TYPE_PING
- 2.TYPE_SETTINGS
- 3.TYPE_WINDOW_UPDATE

#### 处理TYPE_PING

TYPE_PING 在RFC协议中，用于确定双方的链接是否还有效。

```kotlin
  @Throws(IOException::class)
  private fun readPing(handler: Handler, length: Int, flags: Int, streamId: Int) {
    if (length != 8) throw IOException("TYPE_PING length != 8: $length")
    if (streamId != 0) throw IOException("TYPE_PING streamId != 0")
    val payload1 = source.readInt()
    val payload2 = source.readInt()
    val ack = flags and FLAG_ACK != 0
    handler.ping(ack, payload1, payload2)
  }
```
那么就会拿到flag，如果是FLAG_ACK 不为0，说明此时是从服务器那边的应答。并取出payload1和payload2，传递到Handler中处理。此时的Handler是指ReaderRunnable。

```kotlin
    override fun ping(
      ack: Boolean,
      payload1: Int,
      payload2: Int
    ) {
      if (ack) {
        synchronized(this@Http2Connection) {
          when (payload1) {
            INTERVAL_PING -> {
              intervalPongsReceived++
            }
            DEGRADED_PING -> {
              degradedPongsReceived++
            }
            AWAIT_PING -> {
              awaitPongsReceived++
              this@Http2Connection.notifyAll()
            }
            else -> {
              // Ignore an unexpected pong.
            }
          }
        }
      } else {
...
      }
    }

```

这个过程中，就是不断的进行ping的计数。


##### TYPE_SETTINGS

```kotlin
  private fun readSettings(handler: Handler, length: Int, flags: Int, streamId: Int) {
    if (streamId != 0) throw IOException("TYPE_SETTINGS streamId != 0")
    if (flags and FLAG_ACK != 0) {
      if (length != 0) throw IOException("FRAME_SIZE_ERROR ack frame should be empty!")
      handler.ackSettings()
      return
    }

    if (length % 6 != 0) throw IOException("TYPE_SETTINGS length % 6 != 0: $length")
    val settings = Settings()
    for (i in 0 until length step 6) {
      var id = source.readShort() and 0xffff
      val value = source.readInt()

      when (id) {
        // SETTINGS_HEADER_TABLE_SIZE
        1 -> {
        }

        // SETTINGS_ENABLE_PUSH
        2 -> {
          if (value != 0 && value != 1) {
            throw IOException("PROTOCOL_ERROR SETTINGS_ENABLE_PUSH != 0 or 1")
          }
        }

        // SETTINGS_MAX_CONCURRENT_STREAMS
        3 -> id = 4 // Renumbered in draft 10.

        // SETTINGS_INITIAL_WINDOW_SIZE
        4 -> {
          id = 7 // Renumbered in draft 10.
          if (value < 0) {
            throw IOException("PROTOCOL_ERROR SETTINGS_INITIAL_WINDOW_SIZE > 2^31 - 1")
          }
        }

        // SETTINGS_MAX_FRAME_SIZE
        5 -> {
          if (value < INITIAL_MAX_FRAME_SIZE || value > 16777215) {
            throw IOException("PROTOCOL_ERROR SETTINGS_MAX_FRAME_SIZE: $value")
          }
        }

        // SETTINGS_MAX_HEADER_LIST_SIZE
        6 -> { // Advisory only, so ignored.
        }

        // Must ignore setting with unknown id.
        else -> {
        }
      }
      settings[id] = value
    }
    handler.settings(false, settings)
  }
```
- 1.如果不是打开了FLAG_ACK，那么说明是从客户端发送到服务器的数据，此时会调用ackSettings。

- 2.如果打开了FLAG_ACK，说明是客户端发送到服务端的应答数据，这个过程就是读取从客户端传递过来的数据帧，读取其中每一项配置合并当前服务器每一个配置。能看到实际上客户端此时只能影响服务端除了限制并发流窗口大小之外所有的配置。


Handler中的ackSettings，其实什么实现都没有。


##### 处理TYPE_WINDOW_UPDATE

```kotlin
  @Throws(IOException::class)
  private fun readWindowUpdate(handler: Handler, length: Int, flags: Int, streamId: Int) {
...
    val increment = source.readInt() and 0x7fffffffL
...
    handler.windowUpdate(streamId, increment)
  }

```

核心只有一行windowUpdate：

```kotlin
    override fun windowUpdate(streamId: Int, windowSizeIncrement: Long) {
      if (streamId == 0) {
        synchronized(this@Http2Connection) {
          writeBytesMaximum += windowSizeIncrement
          this@Http2Connection.notifyAll()
        }
      } else {
        val stream = getStream(streamId)
        if (stream != null) {
          synchronized(stream) {
            stream.addBytesToWriteWindow(windowSizeIncrement)
          }
        }
      }
    }
```

如果streamId 为0，那么就更改writeBytesMaximum 中的大小，从而动态的修改okhttp 中对所有并发流的窗口控制。


### RealConnection newCodec

```kotlin
  @Throws(SocketException::class)
  internal fun newCodec(client: OkHttpClient, chain: RealInterceptorChain): ExchangeCodec {
    val socket = this.socket!!
    val source = this.source!!
    val sink = this.sink!!
    val http2Connection = this.http2Connection

    return if (http2Connection != null) {
      Http2ExchangeCodec(client, this, chain, http2Connection)
    } else {
      socket.soTimeout = chain.readTimeoutMillis()
      source.timeout().timeout(chain.readTimeoutMillis.toLong(), MILLISECONDS)
      sink.timeout().timeout(chain.writeTimeoutMillis.toLong(), MILLISECONDS)
      Http1ExchangeCodec(client, this, source, sink)
    }
  }
```


如果执行了startHttp2 那么此时的http2Connection 就不为空，并且为Http2Connection对象，就返回Http2ExchangeCodec对象。

除此之外都是Http 1.1或者是Http1.0 那么就返回Http1ExchangeCodec。


这两个对象最后都会保存在ExChange对象中并赋值给RealChainInterceptor中，执行到下一个拦截器中。

## 总结

ConnectInterceptor 链接拦截器在okhttp中做了如下几件事情：

- 1.尝试从ConnectionPool 中获取可以进行多路复用的socket链接(当然需要http 2.0协议的请求)
- 2.从ProxySelector 中获取直连或者代理的资源路径，在这个过程中，会处理三种情况：
  - 2.1 如果是`Proxy.Type.SOCKET` 则通过`InetSocketAddress.createUnresolved`解析获取到`InetSocketAddress `对象
  - 2.2 如果是`Proxy.Type.DIRECT`或者`Proxy.Type.HTTP` 则通过Address的DNS方法调用lookup 查询 host对应对应的ip地址，生成`InetSocketAddress `对象

- 3.当拿到了该资源路径对应所有的ip地址，(不是一对一，是因为可能是408等情况存在了负载均衡实际关联不同的服务器)，并开始尝试链接。

  - 3.1 如果是简单的知道了当前的代理模式是非Http代理模式，那么就会直接调用socket.connect 进行链接
  - 3.2. 如果当前的代理模式是Http代理模式，那么会先先构造一个虚假的请求和应答，交给本地的proxyAuthenticator 尝试获取该代理服务器的需要的账号和密码，这样就不会出现407/408等权限异常再重新进行一次请求。当获取好后就添加到头部，并且调用socket.connect. 
  - 3.3 获取socket的输入输出流，保存在全局。

- 4. establishProtocol 尝试这处理具体的协议，这个方法主要处理了Http 1.0和Http 2.0。

  - 4.1. Http 1.0 存入了SSLSocketFactory对象，说明允许进行TLS/SSL 的加密传输（一般都存在一个默认的对象）。就会依次执行握手过程，依次为：
    - 4.1.1. 根据原来的socket对象，通过SSLSocketFactory 包裹生成一个新的sslSocket对象
    - 4.1.2. sslSocket.startHandshake sslsocket对象开始进行握手
    - 4.1.3. 获取sslSocket.session 对象，调用他的handshake方法，开始握手
    - 4.1.4. 从Address的certificatePinner 中检索握手成功的证书，保证合法信任并且是X509Certificate

  - 4.2. 如果是Http 2.0 除了进行connectTls的操作之外，还会开始依次传输如下三种类型的http 数据帧：
    - 4.2.1. TYPE_PING 代表当前链接还活跃着，在RFC说明协议中，说明这个协议优先级是最高，必须先发送。
    - 4.2.2 往服务端发送序言，说明客户端的流开始传递的了，会发送如下的数据：`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`
    - 4.2.3. TYPE_SETTINGS 把当前的okhttp设置的客户端的设置，如一个数据帧最大的负载容量是多少（默认为16kb），当前的允许控制的最大(默认是Int的最大值相当于不限制)交给服务器，服务器会把客户端的配置合并起来，进行对客户端的适配
    - 4.2.4  TYPE_WINDOW_UPDATE  严格来说这个也是保存在settings中的，然而服务器只会读取前6个数组，刚好就没有读取这个所有复用并发流窗口大小。而是专门通过TYPE_WINDOW_UPDATE 和初始的65535大小的并发流窗口大小进行调节


到这里就完成了整个ConnectInterceptor 的工作。比起http 2.0的协议初始化，我们更需要关注的是，这个过程中由如下两个核心的方法：

- dns lookup 把资源地址转化为ip地址
- socket.connect 通过socket把客户端和服务端联系起来
- socket.starthandshake
- socket.handshake

这四个方法才是整个网络请求最为核心的四步骤。这里我们先把okhttp弄懂了整个流程，我们之后再回头看看这几个步骤，在底层中都做了什么？