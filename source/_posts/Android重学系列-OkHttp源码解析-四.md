---
title: Android重学系列 OkHttp源码解析(四)
top: false
cover: false
date: 2020-11-03 09:31:02
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

上一篇文章和大家探讨了，Okhttp的ConnectInterceptor 拦截器。接下来，我们就来聊聊Okhttp最后一个拦截器，CallServerInterceptor拦截器都做了什么？

# 正文

```kotlin
  @Throws(IOException::class)
  override fun intercept(chain: Interceptor.Chain): Response {
    val realChain = chain as RealInterceptorChain
    val exchange = realChain.exchange!!
    val request = realChain.request
    val requestBody = request.body
    val sentRequestMillis = System.currentTimeMillis()

    exchange.writeRequestHeaders(request)

    var invokeStartEvent = true
    var responseBuilder: Response.Builder? = null
    if (HttpMethod.permitsRequestBody(request.method) && requestBody != null) {
      // If there's a "Expect: 100-continue" header on the request, wait for a "HTTP/1.1 100
      // Continue" response before transmitting the request body. If we don't get that, return
      // what we did get (such as a 4xx response) without ever transmitting the request body.
      if ("100-continue".equals(request.header("Expect"), ignoreCase = true)) {
        exchange.flushRequest()
        responseBuilder = exchange.readResponseHeaders(expectContinue = true)
        exchange.responseHeadersStart()
        invokeStartEvent = false
      }
      if (responseBuilder == null) {
        if (requestBody.isDuplex()) {
          // Prepare a duplex body so that the application can send a request body later.
          exchange.flushRequest()
          val bufferedRequestBody = exchange.createRequestBody(request, true).buffer()
          requestBody.writeTo(bufferedRequestBody)
        } else {
          // Write the request body if the "Expect: 100-continue" expectation was met.
          val bufferedRequestBody = exchange.createRequestBody(request, false).buffer()
          requestBody.writeTo(bufferedRequestBody)
          bufferedRequestBody.close()
        }
      } else {
        exchange.noRequestBody()
        if (!exchange.connection.isMultiplexed) {
          // If the "Expect: 100-continue" expectation wasn't met, prevent the HTTP/1 connection
          // from being reused. Otherwise we're still obligated to transmit the request body to
          // leave the connection in a consistent state.
          exchange.noNewExchangesOnConnection()
        }
      }
    } else {
      exchange.noRequestBody()
    }

    if (requestBody == null || !requestBody.isDuplex()) {
      exchange.finishRequest()
    }
    if (responseBuilder == null) {
      responseBuilder = exchange.readResponseHeaders(expectContinue = false)!!
      if (invokeStartEvent) {
        exchange.responseHeadersStart()
        invokeStartEvent = false
      }
    }
    var response = responseBuilder
        .request(request)
        .handshake(exchange.connection.handshake())
        .sentRequestAtMillis(sentRequestMillis)
        .receivedResponseAtMillis(System.currentTimeMillis())
        .build()
    var code = response.code
    if (code == 100) {
      // Server sent a 100-continue even though we did not request one. Try again to read the actual
      // response status.
      responseBuilder = exchange.readResponseHeaders(expectContinue = false)!!
      if (invokeStartEvent) {
        exchange.responseHeadersStart()
      }
      response = responseBuilder
          .request(request)
          .handshake(exchange.connection.handshake())
          .sentRequestAtMillis(sentRequestMillis)
          .receivedResponseAtMillis(System.currentTimeMillis())
          .build()
      code = response.code
    }

    exchange.responseHeadersEnd(response)

    response = if (forWebSocket && code == 101) {
      // Connection is upgrading, but we need to ensure interceptors see a non-null response body.
      response.newBuilder()
          .body(EMPTY_RESPONSE)
          .build()
    } else {
      response.newBuilder()
          .body(exchange.openResponseBody(response))
          .build()
    }
    if ("close".equals(response.request.header("Connection"), ignoreCase = true) ||
        "close".equals(response.header("Connection"), ignoreCase = true)) {
      exchange.noNewExchangesOnConnection()
    }
    if ((code == 204 || code == 205) && response.body?.contentLength() ?: -1L > 0L) {
      throw ProtocolException(
          "HTTP $code had non-zero Content-Length: ${response.body?.contentLength()}")
    }
    return response
  }
```

做的事情如下：

- 1.exchange.writeRequestHeaders 把请求的头部往socket写入
- 2. 判断到请求方式是并非`GET`和`HEAD`,那么需要进行传输请求体。接下来会查看请求的头部是否存在一个`Expect `的key，内容为`HTTP/1.1 100 Continue` 说明 此时需要等待服务器专门对这个请求进行等待，继续读取。
  - 2.1.如果存在，就会执行`exchange.readResponseHeaders` 读取响应的头部
  - 2.2. 如果读取出来的响应的头部 为空，且判断到 请求体requestBody的`isDuplex`为false，那么通过`exchange.createRequestBody`创造新的`bufferedRequestBody `RequestBodySink 请求体写入流并记录当前的isDuplex为true,往请求Request的`requestBody `写入。其实就是准备了一个常驻的专门写入请求体的全双工的写入流。
  - 2.3.如果读取出来的响应的头部 不为空，和2.2一样，不过`bufferedRequestBody`记录的isDuplex为false。但是不同的是这个写入流只存在一次就关闭了。因此isDuplex实际上代表的就是是否可以常驻一个写入请求流的标志位。
  - 2.4.如果读取出来的响应头不存在将不会继续写入请求体。

- 3.如果是`GET`和`HEAD`模式，就没必要写入请求体了。

- 4.如果没有请求体或者请求体的isDuplex为false(只使用一次的请求体流),可以直接调用 `exchange.finishRequest` 结束请求，并发送所有缓冲在缓冲区的数据到socket对面。

- 5.如果响应体此时为空，说明此时头部并没有带上`HTTP/1.1 100 Continue`，需要对服务器对该请求流整体的响应进行读取。调用的方法是`readResponseHeaders `

- 6.当拿到了请求体之后之后，就判断请求体的code是否为100.
  - 6.1. 如果为100，说明服务器后面还有更多的流需要传输过来，那么还会再调用一次`readResponseHeaders`方法再次读取服务器传输过来的数据，组成新的Response响应对象
  - 6.2. 如果再读取一次后是101或者本身就是101的响应代码，并且此时是websocket的模式，那么就会设置一个空的响应体在其中返回。不是则通过`exchange.openResponseBody(response)` 读取response中的数据生成一个真正的从流中获取的响应数据。

- 6.3 如果是204或者205 ，且发现请求体内容是空，则爆异常。没问题则直接返回。



> 从RFC协议文档中可以得知，除了101之外的1xx都是代表了服务器发送了第一帧的响应数据，需要继续往后读取才能继续读取完毕。当头部中带了`END_STREAM `的标志位才代表该传输流结束了。在Okhttp中就是用了RFC协议中的code为100例子作为整个标准。


整个流程最为核心的方法依次为：
- 1.Exchange.writeRequestHeaders
- 2.Exchange.readResponseHeaders
- 3.Exchange.createRequestBody
- 4.requestBody.writeTo 往responseBody写入数据
- 5.Exchange.finishRequest
- 6.Exchange.openResponseBody

还记得上一篇文章中聊过的，在ConnectInterceptor拦截器中生成的Exchange对象，并传递到当前的CallServiceInterceptor拦截中。而Exchange包含了一个十分重要的对象ExchangeCodec 。

ExchangeCodec在上一篇文章中有解析，实际上是根据协议类型http 1.0/1.1 以及Http 2.0分别生成了`Http1ExchangeCodec`或者`Http2ExchangeCodec`两个对象。

接下来我将分为两个不同协议 对这几个方法进行解析进行解析。

## Http 1.0/1.1 

### Exchange.writeRequestHeaders 往服务端写入请求

```kotlin
  @Throws(IOException::class)
  fun writeRequestHeaders(request: Request) {
    try {
      eventListener.requestHeadersStart(call)
      codec.writeRequestHeaders(request)
      eventListener.requestHeadersEnd(call, request)
    } catch (e: IOException) {
      eventListener.requestFailed(call, e)
      trackFailure(e)
      throw e
    }
  }
```

核心就是调用了ExchangeCodec 的writeRequestHeaders方法。

此时是Http 1.0/1.1那么将会进入`Http1ExchangeCodec` 中进行处理。


#### Http1ExchangeCodec writeRequestHeaders

```kotlin
  override fun writeRequestHeaders(request: Request) {
    val requestLine = RequestLine.get(request, connection.route().proxy.type())
    writeRequest(request.headers, requestLine)
  }

  /** Returns bytes of a request header for sending on an HTTP transport. */
  fun writeRequest(headers: Headers, requestLine: String) {
    check(state == STATE_IDLE) { "state: $state" }
    sink.writeUtf8(requestLine).writeUtf8("\r\n")
    for (i in 0 until headers.size) {
      sink.writeUtf8(headers.name(i))
          .writeUtf8(": ")
          .writeUtf8(headers.value(i))
          .writeUtf8("\r\n")
    }
    sink.writeUtf8("\r\n")
    state = STATE_OPEN_REQUEST_BODY
  }
```

```kotlin
  fun get(request: Request, proxyType: Proxy.Type) = buildString {
    append(request.method)
    append(' ')
    if (includeAuthorityInRequestLine(request, proxyType)) {
      append(request.url)
    } else {
      append(requestPath(request.url))
    }
    append(" HTTP/1.1")
  }
```
`RequestLine.get` 方法实际上就是构造了一个Http请求的请求行。然后在请求行下拼接 头部内容信息

如下图：
![Http请求协议结构.png](/images/Http请求协议结构.png)

到这里一步还差一个请求体没有设置。如果是`GET`或者`HEAD`请求方式，这里已经完成了字符串的拼接可以进行下一步的发送了。


#### Exchange.readResponseHeaders

```kotlin
  @Throws(IOException::class)
  fun readResponseHeaders(expectContinue: Boolean): Response.Builder? {
    try {
      val result = codec.readResponseHeaders(expectContinue)
      result?.initExchange(this)
      return result
    } catch (e: IOException) {
      eventListener.responseFailed(call, e)
      trackFailure(e)
      throw e
    }
  }
```


```kotlin
  private val headersReader = HeadersReader(source)

  override fun readResponseHeaders(expectContinue: Boolean): Response.Builder? {
    check(state == STATE_OPEN_REQUEST_BODY || state == STATE_READ_RESPONSE_HEADERS) {
      "state: $state"
    }

    try {
      val statusLine = StatusLine.parse(headersReader.readLine())

      val responseBuilder = Response.Builder()
          .protocol(statusLine.protocol)
          .code(statusLine.code)
          .message(statusLine.message)
          .headers(headersReader.readHeaders())

      return when {
        expectContinue && statusLine.code == HTTP_CONTINUE -> {
          null
        }
        statusLine.code == HTTP_CONTINUE -> {
          state = STATE_READ_RESPONSE_HEADERS
          responseBuilder
        }
        else -> {
          state = STATE_OPEN_RESPONSE_BODY
          responseBuilder
        }
      }
    } catch (e: EOFException) {
      // Provide more context if the server ends the stream before sending a response.
      val address = connection.route().address.url.redact()
      throw IOException("unexpected end of stream on $address", e)
    }
  }
```

- 1.HeadersReader 包裹了从socket中获取的输出流。首先通过 `HeadersReader.readLine` 读取状态行。
- 2.保存状态行中的code，message等信息到Response对象中
- 3.`HeadersReader.readHeaders` 读取头部信息
- 4.如果code是101 则记录当前状态是STATE_READ_RESPONSE_HEADERS，否则就是STATE_OPEN_RESPONSE_BODY。并返回Response.Builder

### Exchange.createRequestBody

```kotlin
  @Throws(IOException::class)
  fun createRequestBody(request: Request, duplex: Boolean): Sink {
    this.isDuplex = duplex
    val contentLength = request.body!!.contentLength()
    eventListener.requestBodyStart(call)
    val rawRequestBody = codec.createRequestBody(request, contentLength)
    return RequestBodySink(rawRequestBody, contentLength)
  }

```

先获取request中请求体的长度。然后调用Http1ExchangeCodec.createRequestBody

#### Http1ExchangeCodec createRequestBody
```kotlin
  override fun createRequestBody(request: Request, contentLength: Long): Sink {
    return when {
      request.body != null && request.body.isDuplex() -> throw ProtocolException(
          "Duplex connections are not supported for HTTP/1")
      request.isChunked -> newChunkedSink() // Stream a request body of unknown length.
      contentLength != -1L -> newKnownLengthSink() // Stream a request body of a known length.
      else -> // Stream a request body of a known length.
        throw IllegalStateException(
            "Cannot stream a request body without chunked encoding or a known content length!")
    }
  }

  private fun newChunkedSink(): Sink {
    check(state == STATE_OPEN_REQUEST_BODY) { "state: $state" }
    state = STATE_WRITING_REQUEST_BODY
    return ChunkedSink()
  }
```

这个过程就返回了一个ChunkedSink 对象。简单的来看看这个内部类：

##### ChunkedSink

```kotlin
  private inner class ChunkedSink : Sink {
    private val timeout = ForwardingTimeout(sink.timeout())
    private var closed: Boolean = false

    override fun timeout(): Timeout = timeout

    override fun write(source: Buffer, byteCount: Long) {
      check(!closed) { "closed" }
      if (byteCount == 0L) return

      sink.writeHexadecimalUnsignedLong(byteCount)
      sink.writeUtf8("\r\n")
      sink.write(source, byteCount)
      sink.writeUtf8("\r\n")
    }

    @Synchronized
    override fun flush() {
      if (closed) return // Don't throw; this stream might have been closed on the caller's behalf.
      sink.flush()
    }

    @Synchronized
    override fun close() {
      if (closed) return
      closed = true
      sink.writeUtf8("0\r\n\r\n")
      detachTimeout(timeout)
      state = STATE_READ_RESPONSE_HEADERS
    }
  }
```
之后所有对流的操作实际上都会操作到这个对象中，能看到这个对象`ChunkedSink` 会把数据往内容内写入。写入的格式是`\r\n` + `内容` + `\r\n`。

获取到`ChunkedSink` 会被`RequestBodySink` 包裹。

##### RequestBodySink
```kotlin
  private inner class RequestBodySink(
    delegate: Sink,
    /** The exact number of bytes to be written, or -1L if that is unknown. */
    private val contentLength: Long
  ) : ForwardingSink(delegate) {
    private var completed = false
    private var bytesReceived = 0L
    private var closed = false

    @Throws(IOException::class)
    override fun write(source: Buffer, byteCount: Long) {
      check(!closed) { "closed" }
      if (contentLength != -1L && bytesReceived + byteCount > contentLength) {
        throw ProtocolException(
            "expected $contentLength bytes but received ${bytesReceived + byteCount}")
      }
      try {
        super.write(source, byteCount)
        this.bytesReceived += byteCount
      } catch (e: IOException) {
        throw complete(e)
      }
    }

    @Throws(IOException::class)
    override fun flush() {
      try {
        super.flush()
      } catch (e: IOException) {
        throw complete(e)
      }
    }

    @Throws(IOException::class)
    override fun close() {
      if (closed) return
      closed = true
      if (contentLength != -1L && bytesReceived != contentLength) {
        throw ProtocolException("unexpected end of stream")
      }
      try {
        super.close()
        complete(null)
      } catch (e: IOException) {
        throw complete(e)
      }
    }

    private fun <E : IOException?> complete(e: E): E {
      if (completed) return e
      completed = true
      return bodyComplete(bytesReceived, responseDone = false, requestDone = true, e = e)
    }
  }
```

这个过程简单，几乎把所有的事情代理交给ChunkedSink，而自己只是记录了一些关键信息，如接受的字节大小。

#### ResponseBody writeTo

ResponseBody 其实是一个抽象类，派生很多对象。举两个例子，最常用的表单对象FormBody 以及 混合使用的 MultipartBody，还支持自定义的`RequestBody`.如果手写过断点下载等功能，必定会对`RequestBody`进行复写。

![RequestBody.png](/images/RequestBody.png)


```kotlin
abstract class RequestBody {

  /** Returns the Content-Type header for this body. */
  abstract fun contentType(): MediaType?

  /**
   * Returns the number of bytes that will be written to sink in a call to [writeTo],
   * or -1 if that count is unknown.
   */
  @Throws(IOException::class)
  open fun contentLength(): Long = -1L

  /** Writes the content of this request to [sink]. */
  @Throws(IOException::class)
  abstract fun writeTo(sink: BufferedSink)

  open fun isDuplex(): Boolean = false


  open fun isOneShot(): Boolean = false
}
```

- 1.contentType 代表当前请求体` Content-Type` 的内容：

 常见的媒体格式类型如下：

- text/html ： HTML格式
- text/plain ：纯文本格式      
- text/xml ：  XML格式
- image/gif ：gif图片格式    
- image/jpeg ：jpg图片格式 
- image/png：png图片格式

以application开头的媒体格式类型：
- application/xhtml+xml ：XHTML格式
- application/xml     ： XML数据格式
- application/atom+xml  ：Atom XML聚合格式    
- application/json    ： JSON数据格式
- application/pdf       ：pdf格式  
- application/msword  ： Word文档格式
- application/octet-stream ： 二进制流数据（如常见的文件下载）
- application/x-www-form-urlencoded ： <form encType=””>中默认的encType，form表单数据被编码为key/value格式发送到服务器（表单默认的提交数据的格式）

另外一种常见的媒体格式是上传文件之时使用的：

- multipart/form-data ： 需要在表单中进行文件上传时，就需要使用该格式

- 2.`contentLength` 代表了当前请求体有多长。

- 3.writeTo 方法是把写入流往请求体中写入的操作。

- 4.isDuplex 代表当前的请求体中的写入读取全双工流是否可以常驻

- 5.isOneShot 代表当前请求体是否只能使用一次，如果是遇到408,401,407等情况可以重复请求。此时需要这个标志位判断。

核心还是writeTo方法。

#### MultipartBody writeTo

```kotlin
    private val COLONSPACE = byteArrayOf(':'.toByte(), ' '.toByte())
    private val CRLF = byteArrayOf('\r'.toByte(), '\n'.toByte())
    private val DASHDASH = byteArrayOf('-'.toByte(), '-'.toByte())

  @Throws(IOException::class)
  override fun writeTo(sink: BufferedSink) {
    writeOrCountBytes(sink, false)
  }

  @Throws(IOException::class)
  private fun writeOrCountBytes(
    sink: BufferedSink?,
    countBytes: Boolean
  ): Long {
    var sink = sink
    var byteCount = 0L

    var byteCountBuffer: Buffer? = null
    if (countBytes) {
      byteCountBuffer = Buffer()
      sink = byteCountBuffer
    }

    for (p in 0 until parts.size) {
      val part = parts[p]
      val headers = part.headers
      val body = part.body

      sink!!.write(DASHDASH)
      sink.write(boundaryByteString)
      sink.write(CRLF)

      if (headers != null) {
        for (h in 0 until headers.size) {
          sink.writeUtf8(headers.name(h))
              .write(COLONSPACE)
              .writeUtf8(headers.value(h))
              .write(CRLF)
        }
      }

      val contentType = body.contentType()
      if (contentType != null) {
        sink.writeUtf8("Content-Type: ")
            .writeUtf8(contentType.toString())
            .write(CRLF)
      }

      val contentLength = body.contentLength()
      if (contentLength != -1L) {
        sink.writeUtf8("Content-Length: ")
            .writeDecimalLong(contentLength)
            .write(CRLF)
      } else if (countBytes) {
        // We can't measure the body's size without the sizes of its components.
        byteCountBuffer!!.clear()
        return -1L
      }

      sink.write(CRLF)

      if (countBytes) {
        byteCount += contentLength
      } else {
        body.writeTo(sink)
      }

      sink.write(CRLF)
    }

    sink!!.write(DASHDASH)
    sink.write(boundaryByteString)
    sink.write(DASHDASH)
    sink.write(CRLF)

    if (countBytes) {
      byteCount += byteCountBuffer!!.size
      byteCountBuffer.clear()
    }

    return byteCount
  }
```

写入内容格式如下：

注意${}这里代表去大括号内的值
```
\r\n${UUID.randomUUID()}\r\n
${header[0].key}: ${headers[0].value}\r\n
${header[1].key}: ${headers[1].value}\r\n
Content-Type: multipart/form-data; boundary=${UUID.randomUUID()}\r\n
Content-Length: ${contentLength}\r\n
${文件内容}
\r\n
\r\n${UUID.randomUUID()}\r\n
```

一般的`multipart` 除了可以传输键值对之外，还能传输文件。

再来看看一般用于表单提交的FormBody都做了什么？


##### FormBody writeTo

```kotlin
  @Throws(IOException::class)
  override fun writeTo(sink: BufferedSink) {
    writeOrCountBytes(sink, false)
  }


  private fun writeOrCountBytes(sink: BufferedSink?, countBytes: Boolean): Long {
    var byteCount = 0L
    val buffer: Buffer = if (countBytes) Buffer() else sink!!.buffer

    for (i in 0 until encodedNames.size) {
      if (i > 0) buffer.writeByte('&'.toInt())
      buffer.writeUtf8(encodedNames[i])
      buffer.writeByte('='.toInt())
      buffer.writeUtf8(encodedValues[i])
    }

    if (countBytes) {
      byteCount = buffer.size
      buffer.clear()
    }

    return byteCount
  }
```

提交表单的请求体格式也很简单：

```
${encodedNames[0]}=${encodedValues[0]}&${encodedNames[1]}=${encodedValues[1]}
```

注意往往这种mediaType格式都是`application/x-www-form-urlencoded`,一般的，FormBody只能传输简单的键值对不能传输文件。


### Exchange.finishRequest

```kotlin
  @Throws(IOException::class)
  fun finishRequest() {
    try {
      codec.finishRequest()
    } catch (e: IOException) {
      eventListener.requestFailed(call, e)
      trackFailure(e)
      throw e
    }
  }
```


```kotlin
  override fun finishRequest() {
    sink.flush()
  }

```

实际上很简单，就是把写入大缓冲区的内容一口气推倒socket的对端中。


### Exchange.openResponseBody

```kotlin
  @Throws(IOException::class)
  fun openResponseBody(response: Response): ResponseBody {
    try {
      val contentType = response.header("Content-Type")
      val contentLength = codec.reportedContentLength(response)
      val rawSource = codec.openResponseBodySource(response)
      val source = ResponseBodySource(rawSource, contentLength)
      return RealResponseBody(contentType, contentLength, source.buffer())
    } catch (e: IOException) {
      eventListener.responseFailed(call, e)
      trackFailure(e)
      throw e
    }
  }
```

- 1.从Response 中读取应答头部的`Content-Type`
- 2.从Response 中读取应答头部的`Content-Length`
- 3.openResponseBodySource 生成一个ChunkedSource 对象，这个对象调用read方法读取时候，将会根据流读取socket输入流中的内容，知道长度为消费完毕。
- 4.生成一个ResponseBodySource 对象，持有ChunkedSource读取流以及contentLength。生成RealResponseBody 对象持有ResponseBodySource对象。返回RealResponseBody。

## Http 2.0

那么我们都知道了实际上所有的Exchange对象的操作都会转移到Http1ExchangeCodec中。那么这部分我们只探索Http2ExchangeCodec 中对应相同接口都做了什么？

### Http2ExchangeCodec writeRequestHeaders

```kotlin
  override fun writeRequestHeaders(request: Request) {
    if (stream != null) return

    val hasRequestBody = request.body != null
    val requestHeaders = http2HeadersList(request)
    stream = http2Connection.newStream(requestHeaders, hasRequestBody)

    if (canceled) {
      stream!!.closeLater(ErrorCode.CANCEL)
      throw IOException("Canceled")
    }
    stream!!.readTimeout().timeout(chain.readTimeoutMillis.toLong(), TimeUnit.MILLISECONDS)
    stream!!.writeTimeout().timeout(chain.writeTimeoutMillis.toLong(), TimeUnit.MILLISECONDS)
  }
```

从这里开始就和http 1.0的做法完全不一样。
- 1.http2HeadersList 从请求对象中获取头部列表
- 2.http2Connection.newStream 生成全新的Http2Stream

#### Http2ExchangeCodec http2HeadersList

```kotlin
    fun http2HeadersList(request: Request): List<Header> {
      val headers = request.headers
      val result = ArrayList<Header>(headers.size + 4)
      result.add(Header(TARGET_METHOD, request.method))
      result.add(Header(TARGET_PATH, RequestLine.requestPath(request.url)))
      val host = request.header("Host")
      if (host != null) {
        result.add(Header(TARGET_AUTHORITY, host)) // Optional.
      }
      result.add(Header(TARGET_SCHEME, request.url.scheme))

      for (i in 0 until headers.size) {
        // header names must be lowercase.
        val name = headers.name(i).toLowerCase(Locale.US)
        if (name !in HTTP_2_SKIPPED_REQUEST_HEADERS ||
            name == TE && headers.value(i) == "trailers") {
          result.add(Header(name, headers.value(i)))
        }
      }
      return result
    }
```
能看到除了头部的信息之外，还把请求行中所有的信息也保存到Header的集合中。

#### Http2Connection.newStream 

```kotlin
  @Throws(IOException::class)
  fun newStream(
    requestHeaders: List<Header>,
    out: Boolean
  ): Http2Stream {
    return newStream(0, requestHeaders, out)
  }

```

```kotlin
  private fun newStream(
    associatedStreamId: Int,
    requestHeaders: List<Header>,
    out: Boolean
  ): Http2Stream {
    val outFinished = !out
    val inFinished = false
    val flushHeaders: Boolean
    val stream: Http2Stream
    val streamId: Int

    synchronized(writer) {
      synchronized(this) {
        if (nextStreamId > Int.MAX_VALUE / 2) {
          shutdown(REFUSED_STREAM)
        }
        if (isShutdown) {
          throw ConnectionShutdownException()
        }
        streamId = nextStreamId
        nextStreamId += 2
        stream = Http2Stream(streamId, this, outFinished, inFinished, null)
        flushHeaders = !out ||
            writeBytesTotal >= writeBytesMaximum ||
            stream.writeBytesTotal >= stream.writeBytesMaximum
        if (stream.isOpen) {
          streams[streamId] = stream
        }
      }
      if (associatedStreamId == 0) {
        writer.headers(outFinished, streamId, requestHeaders)
      } else {

        writer.pushPromise(associatedStreamId, streamId, requestHeaders)
      }
    }

    if (flushHeaders) {
      writer.flush()
    }

    return stream
  }
```

- 1.如果累计控制的streamId 位数大于 Int.MAX_VALUE的一半，则调用shutdown 关闭上一次读取过头部信息的流
- 2. stream的id分配，其实是不断的加2为下一个新的stramID，并赋值给Http2Stream。Http2Stream保存到streams集合中
- 3.此时传入的`associatedStreamId`为0，那么就会调用Http2writer的headers方法写入头部。


##### Http2writer的headers
```kotlin

  private val hpackBuffer: Buffer = Buffer()

  val hpackWriter: Hpack.Writer = Hpack.Writer(out = hpackBuffer)

  @Synchronized @Throws(IOException::class)
  fun headers(
    outFinished: Boolean,
    streamId: Int,
    headerBlock: List<Header>
  ) {
    if (closed) throw IOException("closed")
    hpackWriter.writeHeaders(headerBlock)

    val byteCount = hpackBuffer.size
    val length = minOf(maxFrameSize.toLong(), byteCount)
    var flags = if (byteCount == length) FLAG_END_HEADERS else 0
    if (outFinished) flags = flags or FLAG_END_STREAM
    frameHeader(
        streamId = streamId,
        length = length.toInt(),
        type = TYPE_HEADERS,
        flags = flags
    )
    sink.write(hpackBuffer, length)

    if (byteCount > length) writeContinuationFrames(streamId, byteCount - length)
  }
```
- 1.hpackWriter把所有的头部信息写入到hpackBuffer 一个临时缓冲区中

- 2.frameHeader 构造头部信息写入socket的缓冲区只能够，接着把hpackBuffer中的数据接在后面写入。 这个过程中如果传输的大小刚好在最大数据帧大小内，flag设置为FLAG_END_HEADERS，否则就是0. 如果outFinished也就是从外部传递进来的标志位是true，说明客户端已经不需要往这个流传输了，那么flag就是FLAG_END_STREAM。

- 3.如果本次传输缓冲区的大小比最大帧数还大，那么说明还有没有传输完就调用了writeContinuationFrames方法。


##### Hpack.Writer writeHeaders
```kotlin
    @Throws(IOException::class)
    fun writeHeaders(headerBlock: List<Header>) {
...
      for (i in 0 until headerBlock.size) {
        val header = headerBlock[i]
        val name = header.name.toAsciiLowercase()
        val value = header.value
        var headerIndex = -1
        var headerNameIndex = -1

        val staticIndex = NAME_TO_FIRST_INDEX[name]
        if (staticIndex != null) {
          headerNameIndex = staticIndex + 1
          if (headerNameIndex in 2..7) {

            if (STATIC_HEADER_TABLE[headerNameIndex - 1].value == value) {
              headerIndex = headerNameIndex
            } else if (STATIC_HEADER_TABLE[headerNameIndex].value == value) {
              headerIndex = headerNameIndex + 1
            }
          }
        }

        if (headerIndex == -1) {
          for (j in nextHeaderIndex + 1 until dynamicTable.size) {
            if (dynamicTable[j]!!.name == name) {
              if (dynamicTable[j]!!.value == value) {
                headerIndex = j - nextHeaderIndex + STATIC_HEADER_TABLE.size
                break
              } else if (headerNameIndex == -1) {
                headerNameIndex = j - nextHeaderIndex + STATIC_HEADER_TABLE.size
              }
            }
          }
        }

        when {
          headerIndex != -1 -> {
            // Indexed Header Field.
            writeInt(headerIndex, PREFIX_7_BITS, 0x80)
          }
          headerNameIndex == -1 -> {
            // Literal Header Field with Incremental Indexing - New Name.
            out.writeByte(0x40)
            writeByteString(name)
            writeByteString(value)
            insertIntoDynamicTable(header)
          }
          name.startsWith(Header.PSEUDO_PREFIX) && TARGET_AUTHORITY != name -> {

            writeInt(headerNameIndex, PREFIX_4_BITS, 0)
            writeByteString(value)
          }
          else -> {
            // Literal Header Field with Incremental Indexing - Indexed Name.
            writeInt(headerNameIndex, PREFIX_6_BITS, 0x40)
            writeByteString(value)
            insertIntoDynamicTable(header)
          }
        }
      }
    }
```

这个过程，Hpack.Writer中会持有一个很长的写死的允许解析的列表集合。
```kotlin
 val STATIC_HEADER_TABLE = arrayOf(
      Header(TARGET_AUTHORITY, ""),
      Header(TARGET_METHOD, "GET"),
      Header(TARGET_METHOD, "POST"),
      Header(TARGET_PATH, "/"),
      Header(TARGET_PATH, "/index.html"),
      Header(TARGET_SCHEME, "http"),
      Header(TARGET_SCHEME, "https"),
      Header(RESPONSE_STATUS, "200"),
      Header(RESPONSE_STATUS, "204"),
      Header(RESPONSE_STATUS, "206"),
      Header(RESPONSE_STATUS, "304"),
      Header(RESPONSE_STATUS, "400"),
      Header(RESPONSE_STATUS, "404"),
      Header(RESPONSE_STATUS, "500"),
      Header("accept-charset", ""),
      Header("accept-encoding", "gzip, deflate"),
      Header("accept-language", ""),
      Header("accept-ranges", ""),
      Header("accept", ""),
      Header("access-control-allow-origin", ""),
      Header("age", ""),
      Header("allow", ""),
      Header("authorization", ""),
      Header("cache-control", ""),
      Header("content-disposition", ""),
      Header("content-encoding", ""),
      Header("content-language", ""),
      Header("content-length", ""),
      Header("content-location", ""),
      Header("content-range", ""),
      Header("content-type", ""),
      Header("cookie", ""),
      Header("date", ""),
      Header("etag", ""),
      Header("expect", ""),
      Header("expires", ""),
      Header("from", ""),
      Header("host", ""),
      Header("if-match", ""),
      Header("if-modified-since", ""),
      Header("if-none-match", ""),
      Header("if-range", ""),
      Header("if-unmodified-since", ""),
      Header("last-modified", ""),
      Header("link", ""),
      Header("location", ""),
      Header("max-forwards", ""),
      Header("proxy-authenticate", ""),
      Header("proxy-authorization", ""),
      Header("range", ""),
      Header("referer", ""),
      Header("refresh", ""),
      Header("retry-after", ""),
      Header("server", ""),
      Header("set-cookie", ""),
      Header("strict-transport-security", ""),
      Header("transfer-encoding", ""),
      Header("user-agent", ""),
      Header("vary", ""),
      Header("via", ""),
      Header("www-authenticate", "")
  )
```

 通过列表就能知道头部中是否有符合规格的头部信息。

- 1.如果不存在在这个STATIC_HEADER_TABLE全局列表中，且不再动态列表dynamicTable中，那么headerIndex为-1.此时会添加0x04,并写入对应的header的name和value。注意如果`writeByteString`使用了压缩模式，就会使用huffman算法进行压缩。最后把这个新的Header的key添加到STATIC_HEADER_TABLE

- 2.如果headerIndex 不为-1，那么说明从STATIC_HEADER_TABLE 或者dynamicTable 找到，那么则写入headerIndex 并且只获取8位.从协议看来服务端也有一套一样的表，可以根据index找到对应Header是什么。接下来只写入headerIndex

- 3.如果是`:`开头的key，但是不是`:authority`,写入对应新的解析index，以及value。

- 4.其他情况就是记录，依次写入headerNameIndex，value，最后添加到动态列表dynamicTable。


总结一句话，所有的Header的key都被哈夫曼算法进行压缩，并保存起来。除非出现第一次或者改变等情况，才会传递对应新的value数值。


总结到图中就是如下：

![Http2传送压缩头部.png](/images/Http2传送压缩头部.png)



##### writeContinuationFrames

```kotlin
  @Throws(IOException::class)
  private fun writeContinuationFrames(streamId: Int, byteCount: Long) {
    var byteCount = byteCount
    while (byteCount > 0L) {
      val length = minOf(maxFrameSize.toLong(), byteCount)
      byteCount -= length
      frameHeader(
          streamId = streamId,
          length = length.toInt(),
          type = TYPE_CONTINUATION,
          flags = if (byteCount == 0L) FLAG_END_HEADERS else 0
      )
      sink.write(hpackBuffer, length)
    }
  }
```

![Http2传输续传头部信息.png](/images/Http2传输续传头部信息.png)


### Http2ExchangeCodec.readResponseHeaders

```kotlin
  override fun readResponseHeaders(expectContinue: Boolean): Response.Builder? {
    val headers = stream!!.takeHeaders()
    val responseBuilder = readHttp2HeadersList(headers, protocol)
    return if (expectContinue && responseBuilder.code == HTTP_CONTINUE) {
      null
    } else {
      responseBuilder
    }
  }

```
核心是`stream!!.takeHeaders` 读取从流中读取的头部信息缓存队列中；readHttp2HeadersList 读取响应头的内容。


##### takeHeaders

```kotlin
  fun takeHeaders(): Headers {
    readTimeout.enter()
    try {
      while (headersQueue.isEmpty() && errorCode == null) {
        waitForIo()
      }
    } finally {
      readTimeout.exitAndThrowIfTimedOut()
    }
    if (headersQueue.isNotEmpty()) {
      return headersQueue.removeFirst()
    }
    throw errorException ?: StreamResetException(errorCode!!)
  }
```

这个过程实际上就是一个消费者生产者模式。如果`headersQueue` 为空，则会阻塞等待`headersQueue` 中存入从流中读取到的头部结果。

```kotlin
    fun readHttp2HeadersList(headerBlock: Headers, protocol: Protocol): Response.Builder {
      var statusLine: StatusLine? = null
      val headersBuilder = Headers.Builder()
      for (i in 0 until headerBlock.size) {
        val name = headerBlock.name(i)
        val value = headerBlock.value(i)
        if (name == RESPONSE_STATUS_UTF8) {
          statusLine = StatusLine.parse("HTTP/1.1 $value")
        } else if (name !in HTTP_2_SKIPPED_RESPONSE_HEADERS) {
          headersBuilder.addLenient(name, value)
        }
      }
      if (statusLine == null) throw ProtocolException("Expected ':status' header not present")

      return Response.Builder()
          .protocol(protocol)
          .code(statusLine.code)
          .message(statusLine.message)
          .headers(headersBuilder.build())
    }
  }
```

takeHeaders 读取从Headers 对象后，把状态行，头部，信息存储到Response。结构如下图：
![Http响应协议结构.png](/images/Http响应协议结构.png)


那么哪里进行读取呢？


##### 读取从服务端传递的数据

在[OkHttp源码解析(三)](https://www.jianshu.com/p/639eaac1b5eb)  中提到过，在执行到CallServerInterceptor 之前，在Http2.0协议中会通过Http2Reader 进行读取从服务端发送过来的数据。

```kotlin
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
...
      } finally {
        close(connectionErrorCode, streamErrorCode, errorException)
        reader.closeQuietly()
      }
    }

```

当通过readConnectionPreface 读取完序言之后，就会不断的循环通过`nextFrame`读取服务端的内容。


```kotlin
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
```

读取头部的核心就是readHeaders。


##### readHeaders 读取头部信息

```kotlin
  @Throws(IOException::class)
  private fun readHeaders(handler: Handler, length: Int, flags: Int, streamId: Int) {
    if (streamId == 0) throw IOException("PROTOCOL_ERROR: TYPE_HEADERS streamId == 0")

    val endStream = (flags and FLAG_END_STREAM) != 0
    val padding = if (flags and FLAG_PADDED != 0) source.readByte() and 0xff else 0

    var headerBlockLength = length
    if (flags and FLAG_PRIORITY != 0) {
      readPriority(handler, streamId)
      headerBlockLength -= 5 // account for above read.
    }
    headerBlockLength = lengthWithoutPadding(headerBlockLength, flags, padding)
    val headerBlock = readHeaderBlock(headerBlockLength, padding, flags, streamId)

    handler.headers(endStream, streamId, -1, headerBlock)
  }
```

- 1.lengthWithoutPadding 读取当前传递过来压缩的头部信息长度。
- 2.readHeaderBlock 解析数据帧的内容区域，根据前面的标志位，从而获取更新的头部信息，并且生成Header集合的
- 3.然后调用`handler.headers` 方法。这里handler 对象就是Http2Connection

##### Http2Connection headers

```kotlin
    override fun headers(
      inFinished: Boolean,
      streamId: Int,
      associatedStreamId: Int,
      headerBlock: List<Header>
    ) {
      if (pushedStream(streamId)) {
        pushHeadersLater(streamId, headerBlock, inFinished)
        return
      }
      val stream: Http2Stream?
      synchronized(this@Http2Connection) {
        stream = getStream(streamId)

        if (stream == null) {
          // If we're shutdown, don't bother with this stream.
          if (isShutdown) return

          // If the stream ID is less than the last created ID, assume it's already closed.
          if (streamId <= lastGoodStreamId) return

          // If the stream ID is in the client's namespace, assume it's already closed.
          if (streamId % 2 == nextStreamId % 2) return

          // Create a stream.
          val headers = headerBlock.toHeaders()
          val newStream = Http2Stream(streamId, this@Http2Connection, false, inFinished, headers)
          lastGoodStreamId = streamId
          streams[streamId] = newStream

          // Use a different task queue for each stream because they should be handled in parallel.
          taskRunner.newQueue().execute("$connectionName[$streamId] onStream") {
            try {
              listener.onStream(newStream)
            } catch (e: IOException) {
              Platform.get().log("Http2Connection.Listener failure for $connectionName", INFO, e)
              ignoreIoExceptions {
                newStream.close(ErrorCode.PROTOCOL_ERROR, e)
              }
            }
          }
          return
        }
      }

      // Update an existing stream.
      stream!!.receiveHeaders(headerBlock.toHeaders(), inFinished)
    }
```
- 1.如果不存在streamID 对应的 Http2Stream对象就会创造出来
- 2.调用Http2Stream的receiveHeaders

```kotlin
  fun receiveHeaders(headers: Headers, inFinished: Boolean) {
    this@Http2Stream.assertThreadDoesntHoldLock()

    val open: Boolean
    synchronized(this) {
      if (!hasResponseHeaders || !inFinished) {
        hasResponseHeaders = true
        headersQueue += headers
      } else {
        this.source.trailers = headers
      }
      if (inFinished) {
        this.source.finished = true
      }
      open = isOpen
      notifyAll()
    }
    if (!open) {
      connection.removeStream(id)
    }
```

能看到此时就是把Headers对象设置到headersQueue中，并且调用notifyAll 唤醒在CallServerInterceptor的阻塞。

时刻记住，这些过程很可能是出现多个线程共用同一个流，同一个Http2Connection同时进行读取写入。那么成消费者生产者模式就十分合理了。



### Http2ExchangeCodec createRequestBody

```kotlin
  override fun createRequestBody(request: Request, contentLength: Long): Sink {
    return stream!!.getSink()
  }
```

很简单就是拿到Http2Stream的Sink对象，这个对象是一个`FramingSink` 。

```kotlin
  internal val sink = FramingSink(
      finished = outFinished
  )
```
那么接下来所有的对这个写入流操作就是操作这个对象。最后会被RequestBodySink包裹起来。


### FramingSink writeTo

当我们需要写入一个新的请求体到服务端，就会调用这个类的write方法。

```kotlin
  companion object {
    internal const val EMIT_BUFFER_SIZE = 16384L （16kb）
  }

    override fun write(source: Buffer, byteCount: Long) {
      this@Http2Stream.assertThreadDoesntHoldLock()

      sendBuffer.write(source, byteCount)
      while (sendBuffer.size >= EMIT_BUFFER_SIZE) {
        emitFrame(false)
      }
    }
```

实际上就是往一个临时的缓冲区写入数据。如果当前的数据大于16kb大小，那么就会调用emitFrame。

```kotlin
    @Throws(IOException::class)
    private fun emitFrame(outFinishedOnLastFrame: Boolean) {
      val toWrite: Long
      val outFinished: Boolean
      synchronized(this@Http2Stream) {
        writeTimeout.enter()
        try {
          while (writeBytesTotal >= writeBytesMaximum &&
              !finished &&
              !closed &&
              errorCode == null) {
            waitForIo() // Wait until we receive a WINDOW_UPDATE for this stream.
          }
        } finally {
          writeTimeout.exitAndThrowIfTimedOut()
        }

        checkOutNotClosed() // Kick out if the stream was reset or closed while waiting.
        toWrite = minOf(writeBytesMaximum - writeBytesTotal, sendBuffer.size)
        writeBytesTotal += toWrite
        outFinished = outFinishedOnLastFrame && toWrite == sendBuffer.size && errorCode == null
      }

      writeTimeout.enter()
      try {
        connection.writeData(id, outFinished, sendBuffer, toWrite)
      } finally {
        writeTimeout.exitAndThrowIfTimedOut()
      }
    }
```

- 1.如果在这个临时写入缓冲区中，已经大于`writeBytesMaximum` 写入最大的数据荷载极限，那么就会阻塞该写入流程。直到小于`writeBytesMaximum`大小。这个`writeBytesMaximum`数值是决定与上一篇文章聊到过的`65535 `的初始化流窗体大小，通过`Http2Stream.addBytesToWriteWindow `在`65535 `基础上进行调整。

- 2.接着调用`connection.writeData` 还是往socket写入数据。

#### Http2Connection往socket中写入数据

```kotlin
  @Throws(IOException::class)
  fun writeData(
    streamId: Int,
    outFinished: Boolean,
    buffer: Buffer?,
    byteCount: Long
  ) {
    // Empty data frames are not flow-controlled.
    if (byteCount == 0L) {
      writer.data(outFinished, streamId, buffer, 0)
      return
    }

    var byteCount = byteCount
    while (byteCount > 0L) {
      var toWrite: Int
      synchronized(this@Http2Connection) {
        try {
          while (writeBytesTotal >= writeBytesMaximum) {

            if (!streams.containsKey(streamId)) {
              throw IOException("stream closed")
            }
            this@Http2Connection.wait() // Wait until we receive a WINDOW_UPDATE.
          }
        } catch (e: InterruptedException) {
          Thread.currentThread().interrupt() // Retain interrupted status.
          throw InterruptedIOException()
        }

        toWrite = minOf(byteCount, writeBytesMaximum - writeBytesTotal).toInt()
        toWrite = minOf(toWrite, writer.maxDataLength())
        writeBytesTotal += toWrite.toLong()
      }

      byteCount -= toWrite.toLong()
      writer.data(outFinished && byteCount == 0L, streamId, buffer, toWrite)
    }
  }
```

- 1.校验了Http2Connection写入的总数据。注意`writeBytesMaximum` 也是在`Http2Stream.addBytesToWriteWindow ` 调用时刻进行更新。如果大于这个书就会进行阻塞。
- 2.调用Http2Writer.data 写入数据。

###### Http2Writer.data

```kotlin
  @Synchronized @Throws(IOException::class)
  fun data(outFinished: Boolean, streamId: Int, source: Buffer?, byteCount: Int) {
    if (closed) throw IOException("closed")
    var flags = FLAG_NONE
    if (outFinished) flags = flags or FLAG_END_STREAM
    dataFrame(streamId, flags, source, byteCount)
  }

  @Throws(IOException::class)
  fun dataFrame(streamId: Int, flags: Int, buffer: Buffer?, byteCount: Int) {
    frameHeader(
        streamId = streamId,
        length = byteCount,
        type = TYPE_DATA,
        flags = flags
    )
    if (byteCount > 0) {
      sink.write(buffer!!, byteCount.toLong())
    }
  }
```

注意，这里会判断此时的流是否写入完毕，如果写入完毕则设置为FLAG_END_STREAM否则是FLAG_NONE。只有把流关闭的时候才是FLAG_END_STREAM。

此时就会写入如下数据格式:

![Http2数据类型数据帧.png](/images/Http2数据类型数据帧.png)



### Http2ExchangeCodec finishRequest

如果此时不需要传输请求体，就会调用finishRequest 关闭当前的Http2ExchangeCodec中对应的写入流。

```kotlin
  override fun finishRequest() {
    stream!!.getSink().close()
  }
```

这个写入流就是`FramingSink`

#### FramingSink close

```kotlin
    @Throws(IOException::class)
    override fun close() {
      this@Http2Stream.assertThreadDoesntHoldLock()

      val outFinished: Boolean
      synchronized(this@Http2Stream) {
        if (closed) return
        outFinished = errorCode == null
      }
      if (!sink.finished) {

        val hasData = sendBuffer.size > 0L
        val hasTrailers = trailers != null
        when {
          hasTrailers -> {
            while (sendBuffer.size > 0L) {
              emitFrame(false)
            }
            connection.writeHeaders(id, outFinished, trailers!!.toHeaderList())
          }

          hasData -> {
            while (sendBuffer.size > 0L) {
              emitFrame(true)
            }
          }

          outFinished -> {
            connection.writeData(id, true, null, 0L)
          }
        }
      }
      synchronized(this@Http2Stream) {
        closed = true
      }
      connection.flush()
      cancelStreamIfNecessary()
    }
```

做的事情很简单，如果当前的写入流已经关闭了，则直接返回。没有关闭，就会把存在该缓冲区的数据全部往对端写入，并带上结束的标志位。


### Http2ExchangeCodec openResponseBody

```kotlin
  internal val source = FramingSource(
      maxByteCount = connection.okHttpSettings.initialWindowSize.toLong(),
      finished = inFinished
  )

  override fun openResponseBodySource(response: Response): Source {
    return stream!!.source
  }
```

很简单，实际上就是返回了一个FramingSource 对象被ResponseBodySource持有到顶层。让用户对响应体进行读取。

一般的当我们想要读取响应体的内容，可以直接通过ResponseBody.toString来完成,来看看这个过程都做了什么？


### ResponseBody.toString

```kotlin
  @Throws(IOException::class)
  fun string(): String = source().use { source ->
    source.readString(charset = source.readBomAsCharset(charset()))
  }

```

这个source 对象就是上一节说的FramingSource对象。注意source调用readString方法，实际上中间会有一个buffer进行承载，把source中的数据写入到中间缓冲区，最后在拷贝返回。在写入过程中，就会调用source的read方法。

也就是ResponseBodySource.read

#### ResponseBodySource.read

```kotlin
    @Throws(IOException::class)
    override fun read(sink: Buffer, byteCount: Long): Long {
      check(!closed) { "closed" }
      try {
        val read = delegate.read(sink, byteCount)

        if (invokeStartEvent) {
          invokeStartEvent = false
          eventListener.responseBodyStart(call)
        }

        if (read == -1L) {
          complete(null)
          return -1L
        }

        val newBytesReceived = bytesReceived + read
        if (contentLength != -1L && newBytesReceived > contentLength) {
          throw ProtocolException("expected $contentLength bytes but received $newBytesReceived")
        }

        bytesReceived = newBytesReceived
        if (newBytesReceived == contentLength) {
          complete(null)
        }

        return read
      } catch (e: IOException) {
        throw complete(e)
      }
    }
```

- 1.调用FramingSource 的 read方法
- 2.一旦读取不到数据，或者刚好长度是解析出来的响应体长度，就会执行`complete`方法。


#### FramingSource 的 read

```kotlin
    @Throws(IOException::class)
    override fun read(sink: Buffer, byteCount: Long): Long {
      require(byteCount >= 0L) { "byteCount < 0: $byteCount" }

      while (true) {
        var tryAgain = false
        var readBytesDelivered = -1L
        var errorExceptionToDeliver: IOException? = null

        // 1. Decide what to do in a synchronized block.

        synchronized(this@Http2Stream) {
          readTimeout.enter()
          try {
            if (errorCode != null) {
              // Prepare to deliver an error.
              errorExceptionToDeliver = errorException ?: StreamResetException(errorCode!!)
            }

            if (closed) {
              throw IOException("stream closed")
            } else if (readBuffer.size > 0L) {
              // Prepare to read bytes. Start by moving them to the caller's buffer.
              readBytesDelivered = readBuffer.read(sink, minOf(byteCount, readBuffer.size))
              readBytesTotal += readBytesDelivered

              val unacknowledgedBytesRead = readBytesTotal - readBytesAcknowledged
              if (errorExceptionToDeliver == null &&
                  unacknowledgedBytesRead >= connection.okHttpSettings.initialWindowSize / 2) {
                // Flow control: notify the peer that we're ready for more data! Only send a
                // WINDOW_UPDATE if the stream isn't in error.
                connection.writeWindowUpdateLater(id, unacknowledgedBytesRead)
                readBytesAcknowledged = readBytesTotal
              }
            } else if (!finished && errorExceptionToDeliver == null) {
              // Nothing to do. Wait until that changes then try again.
              waitForIo()
              tryAgain = true
            }
          } finally {
            readTimeout.exitAndThrowIfTimedOut()
          }
        }

        // 2. Do it outside of the synchronized block and timeout.

        if (tryAgain) {
          continue
        }

        if (readBytesDelivered != -1L) {

          updateConnectionFlowControl(readBytesDelivered)
          return readBytesDelivered
        }

        if (errorExceptionToDeliver != null) {

          throw errorExceptionToDeliver!!
        }

        return -1L // This source is exhausted.
      }
    }

```

- 1.如果读取缓冲区readbuffer的大小为0，但是finished 标志位为false，说明此时还没有数据读取进来，就会调用`waitForIo` 进行阻塞，直到有数据才进入下一个循环。 如果FramingSource已经关闭了则之间报错。

- 2.readbuffer 大于0，则从readbuffer 读取数据。每次读取的大小都会累加到`readBytesTotal`中。`readBytesAcknowledged` 则是记录上一次读取后当前缓冲区的大小。那么就有：
> 本次客户端已经扩容大小(`readBytesTotal` 新的总大小 - `readBytesAcknowledged` 上次大小 ) > 初始窗体大小 / 2

则需要调用`writeWindowUpdateLater` 告诉服务端，此时客户端的流控制窗体大小已经扩大了，服务端需要对应扩大一个`本次客户端已经扩容大小`.


通过这个方法，就把数据读取到参数sink中，等待okio的拷贝。


那么哪里真正的把数据读取到Http2Stream的readbuffer数据读取缓冲区呢？

### Http2 读取服务端的数据

实际上还是在Http2Stream的nextFrame中进行处理的，核心就是Http2Reader.readData 方法。

```kotlin
  @Throws(IOException::class)
  private fun readData(handler: Handler, length: Int, flags: Int, streamId: Int) {

    val inFinished = flags and FLAG_END_STREAM != 0
    val gzipped = flags and FLAG_COMPRESSED != 0
    if (gzipped) {
      throw IOException("PROTOCOL_ERROR: FLAG_COMPRESSED without SETTINGS_COMPRESS_DATA")
    }

    val padding = if (flags and FLAG_PADDED != 0) source.readByte() and 0xff else 0
    val dataLength = lengthWithoutPadding(length, flags, padding)

    handler.data(inFinished, streamId, source, dataLength)
    source.skip(padding.toLong())
  }
```

能看到先获取响应体的数据长度后，调用`ReaderRunnable`的data方法。


#### ReaderRunnable data

```kotlin
    @Throws(IOException::class)
    override fun data(
      inFinished: Boolean,
      streamId: Int,
      source: BufferedSource,
      length: Int
    ) {
      if (pushedStream(streamId)) {
        pushDataLater(streamId, source, length, inFinished)
        return
      }
      val dataStream = getStream(streamId)
      if (dataStream == null) {
        writeSynResetLater(streamId, ErrorCode.PROTOCOL_ERROR)
        updateConnectionFlowControl(length.toLong())
        source.skip(length.toLong())
        return
      }
      dataStream.receiveData(source, length)
      if (inFinished) {
        dataStream.receiveHeaders(EMPTY_HEADERS, true)
      }
    }
```

- 1.先根据streamId 查找是否有对应的Http2Stream流对象，找不到则返回服务端异常，并告诉服务端对应流的窗体大小可以设置为0

- 2.找到则调用Http2Stream.receiveData.如果解析的flag为`FLAG_END_STREAM`说明关闭，还会调用receiveHeaders设置一个空的Headers集合。


##### Http2Stream.receiveData

```kotlin
  @Throws(IOException::class)
  fun receiveData(source: BufferedSource, length: Int) {
    this@Http2Stream.assertThreadDoesntHoldLock()

    this.source.receive(source, length.toLong())
  }

```
```kotlin
    @Throws(IOException::class)
    internal fun receive(source: BufferedSource, byteCount: Long) {
      this@Http2Stream.assertThreadDoesntHoldLock()

      var byteCount = byteCount

      while (byteCount > 0L) {
        val finished: Boolean
        val flowControlError: Boolean
        synchronized(this@Http2Stream) {
          finished = this.finished
          flowControlError = byteCount + readBuffer.size > maxByteCount
        }

...

        // Fill the receive buffer without holding any locks.
        val read = source.read(receiveBuffer, byteCount)
        if (read == -1L) throw EOFException()
        byteCount -= read

        var bytesDiscarded = 0L
        synchronized(this@Http2Stream) {
          if (closed) {
            bytesDiscarded = receiveBuffer.size
            receiveBuffer.clear()
          } else {
            val wasEmpty = readBuffer.size == 0L
            readBuffer.writeAll(receiveBuffer)
            if (wasEmpty) {
              this@Http2Stream.notifyAll()
            }
          }
        }

      }
    }
```

- 1.从socket读取流中读取数据到receiveBuffer 中，并拷贝到`readBuffer`中。
- 2.如果`readBuffer`之前为0，说明是从无到有的读取，就会唤醒从FrameSink中readbuffer拷贝出去操作的阻塞。


### ResponseBodySource  complete

```kotlin
    fun <E : IOException?> complete(e: E): E {
      if (completed) return e
      completed = true
      // If the body is closed without reading any bytes send a responseBodyStart() now.
      if (e == null && invokeStartEvent) {
        invokeStartEvent = false
        eventListener.responseBodyStart(call)
      }
      return bodyComplete(bytesReceived, responseDone = true, requestDone = false, e = e)
    }

  fun <E : IOException?> bodyComplete(
    bytesRead: Long,
    responseDone: Boolean,
    requestDone: Boolean,
    e: E
  ): E {
    if (e != null) {
      trackFailure(e)
    }
    if (requestDone) {
      if (e != null) {
        eventListener.requestFailed(call, e)
      } else {
        eventListener.requestBodyEnd(call, bytesRead)
      }
    }
    if (responseDone) {
      if (e != null) {
        eventListener.responseFailed(call, e)
      } else {
        eventListener.responseBodyEnd(call, bytesRead)
      }
    }
    return call.messageDone(this, requestDone, responseDone, e)
  }

```
这个过程根据是否传入了`IOException`异常，来决定最后是返回异常的回调还正常结束的回调。



## 总结

终于吧七层拦截器全部都过了一边，实际上整个Okhttp的设计中内置的核心拦截器一共也就5个。本文就从更加宏观的角度来看看ConnectInterceptor以及CallServerInterceptor两个拦截器都做了什么？

先来看看Okhttp的管理活跃链接
![Okhttp链接管理.png](/images/Okhttp链接管理.png)

实际上是由一个RealConnectionPool 缓存所有的RealConnection。实际上对应上层来说每一个RealConnection就是代表每一个网络链接的抽象门面。

而实际上真正工作的是其中的Socket对象。整个socket链接大致可以分为如下几个步骤：

- dns lookup 把资源地址转化为ip地址
- socket.connect 通过socket把客户端和服务端联系起来
- socket.starthandshake
- socket.handshake

这四个步骤都是在ConnectionInterceptor 拦截器中完成。

虽然都是RealConnection对象，但是分发到CallServerInterceptor之前会生成一个Exchange对象，其中这个对象就会根据Http1.0/1.1 或者Http2.0 协议 对应生成不同的Http1ExchangeCodec 以及 Http2ExchangeCodec. 这两个对象就是根据协议类型对数据流进行解析。



无论这两个协议做了什么，都可以抽象成如下几个方法：

- 1.Exchange.writeRequestHeaders http1中就是把请求行和头部写入了socket临时缓冲区；http2就是把代表Header的数据帧数写到okio临时缓冲区。

- 2.Exchange.readResponseHeaders http1情况下如果没有请求体，那么则是尝试的读取响应体中的状态行头部等数据；如果是http2则是等待读取从服务端传递过来的头部数据帧数据到缓存队列中。

- 3.Exchange.createRequestBody http1则是获取ChunkedSink一个写入流；http2则是获取一个FrameSink写入流。

- 4.requestBody.writeTo 往createRequestBody创建的写入流写入数据。

- 5.Exchange.finishRequest 把请求体等数据一口气上传到服务端

- 6.Exchange.openResponseBody 获取响应体的读取流保存到Response对象中。当需要获取时候，就调用toString就会读取读取流的数据转化为字符串。



到这里就完成了对okhttp七层拦截器的解析。当然这几篇文章主要还是对http协议进行了考察。如果需要考察其他协议，有了这个思想基础可以自行探索。当然如果之后有兴趣，可能会单独开几篇文章来聊聊内置的其他协议。

我们最后再来回顾一下，整个网络请求中链接到服务器几个核心步骤：
- dns lookup 把资源地址转化为ip地址
- socket.connect 通过socket把客户端和服务端联系起来
- socket.starthandshake
- socket.handshake


下面的篇章将会着重解析这几个步骤的核心原理。

