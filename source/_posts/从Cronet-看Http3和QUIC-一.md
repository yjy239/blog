---
title: 从Cronet 看Http3和QUIC(一)
top: false
cover: false
date: 2022-05-03 15:02:54
img:
tag: quic
description:
author: yjy239
summary:
---

# 前言

前一段时间，在公司内部进行了一次QUIC协议的演讲。当时因为时间有限，没有仔细的讨论Cronet 的源码细节，仅仅只是介绍了QUIC的协议细节。本文就从`Cronet`源码出发，聊聊QUIC的一些实现，进而看看QUIC对比Http2的优势，解决了什么问题？


网上搜了不少QUIC解析文章，不是太老就是粗略聊聊原理，没有几个真的深入源码层面来证明说法是否正确，本文将主要根据QUIC最新的源码来聊聊整个协议的设计，以及这样做的优势

# 正文

## Http 发展史

在聊QUIC之前，我们需要对QUIC有一个初步的了解。QUIC本质上是在Http之上进一步的发展，而不是凭空出现的，而是为了解决Http之前的痛点诞生的。为此我们需要先了解http的发展，以及每一代比起上一代都解决了什么问题。

下图是一个Http的发展进程：


![Http发展.png](/images/Http发展.png)

在这个发展史中可以看到在Http2.0正式推出之前，Google就开始实验QUIC协议。并在2018年在QUIC基础上进一步的发展出Http3协议。在2021年正式发布出QUIC协议。

能看到Http 1到SPDY协议中间间隔10年时间，究竟是为什么在Http 2.0正式发布之前，就开始了Http3前身QUIC进行实验了？那必然是很早就被Google发现了Http 2.0协议的有根本性的缺陷，无法被弥补，需要立即实验下一代协议。

再来看看如今Http 2.0的全网使用情况：


![Http2 全网占比.png](/images/Http2 全网占比.png)

能看到目前Http 2.0全网使用率从发展到2022年2月份还是50%的使用率，而在5月份就是骤降了5%。实际上都转去了QUIC协议，如今已尽占比接近25%了。那究竟有什么魅力，导致这么多开发者青睐QUIC协议呢？

带着疑问，我们来简单回顾一下每一代Http协议实现的功能，以及缺点。

### Http 1

在Http 1中奠定了Http协议的基本语义：

- 由请求行/状态行，body和header 构成 Http请求


![Http请求协议结构.png](/images/Http请求协议结构.png)


![Http响应协议结构.png](/images/Http响应协议结构.png)

Http的缺点分为如下几点：

- 1.header 编码效率低：特别是Rest 架构，往往无状态容易，没有对Header进行编码压缩

- 2.多路复用成本过高
  - 慢启动
  - 一旦网络发生异动就需要重建连接，无论如何都需要3次握手，缓慢

- 3.一旦长连接建立了就无法中断
- 4.Http 应用层不支持流控

为了解决这些问题，就诞生出了Http 2.0协议。

### Http 2.0

Http 2.0在Http 1.0基础上实现了如下的功能：

- 1.多路复用
  - 连接，Stream级别流控
  - 带权重，依赖优先级
  - Stream Reset
  - 应用层数据交换单位细化到Frame(帧)

- 2.HPack 头部编码
- 3.服务器消息推送

关于Http 2.0详细的设计，可以阅读我之前写的[Okhttp源码解析](https://www.jianshu.com/p/639eaac1b5eb)中的`Http2Connection `相关的源码解析。里面有详细剖析Okhttp是如何进行Frame江湖，以及HPack是如何压缩的，还有流是如何控制的。

Http 2.0的缺点如下：

- 1.队头阻塞


![网络协议-Http2队头阻塞.png](/images/网络协议-Http2队头阻塞.png)

因为Http 2.0中使用的是多路复用的流模型，一个tcp链接的发送数据过程中可能会把一个个请求分割成多个流发送到服务器。，因为Tcp的tls加密是一个Record的加密，也就是接近10stream大小进行加密。如果其中在某一个流丢失了，整一串都会解密失败。

这就是Http 2.0最为严重的队头阻塞问题。

- 2.建立连接速度缓慢，能看到整个过程都需要一个十分冗长的过程，三次握手，tls密钥交换等等。可以简单看看https的建立链接过程：


![Https通信模型.png](/images/Https通信模型.png)


- 3.基于TCP四元组确定一个链接，在移动互联网中表现不佳。因为移动设备经常移动，可能在公交地铁等地方，出现了基站变换，Wi-Fi变化等状态。导致四元组发声变化，而需要重新建立链接。

## QUIC

Http 2.0的问题很大情况是因为TCP本身在传输层本身就需要保证包的有序性导致的，因此QUIC干脆抛弃TCP协议，使用UDP协议，可以看看下面QUIC的协议构成：


![网络协议-QUIC_Http3.png](/images/网络协议-QUIC_Http3.png)

Http2是基于TCP协议，并在可以独立出tls加密协议出来。可以选择是否使用tls加密。

能看到QUIC协议本质上是基于UDP传输层协议。在这个之上的应用层是QUIC协议，其中包含了tls加密协议。而未来的Http3则是在QUIC协议上进一步发展的。

QUIC的源码十分之多和复杂？为什么如此呢？能看到QUIC实际上是在UDP上发展，那么需要保证网络数据包的有序性以及正确性，就需要把类似TCP可靠协议逻辑放在QUIC中实现。

也正因如此，QUIC是在应用层实现的协议，可以很灵活的切换各种协议状态，而不需要在内核中增加socket中netFamily的族群，在传输层增加逻辑。

为什么QUIC协议中内置tls协议呢？往后看就知道优势在哪里了。

### QUIC 使用

在聊QUIC之前，我们需要熟悉这个协议`cronet`是如何使用的QUIC协议的。

估计熟悉的人不多，因为`cronet`网络库官方告诉你的依赖方式，需要的引擎需要通过GooglePlay获取到`cronet`的引擎才能完整的使用所有的功能。国内环境一般是没有GooglePlay因此如果想要使用cronet，最好把源码弄下来，自己生成so库或者使用生成好的so库。

这里就不多说依赖，来看看如何使用的：

- 1.先生成一个`CronetEngine`引擎

```java
    CronetEngine.Builder myBuilder = new CronetEngine.Builder(context);
    CronetEngine cronetEngine = myBuilder.build();
```

- 2.构造一个网络请求过程中，不同状态的回调函数：

```java
 class MyUrlRequestCallback extends UrlRequest.Callback {
      private static final String TAG = "MyUrlRequestCallback";

      @Override
      public void onRedirectReceived(UrlRequest request, UrlResponseInfo info, String newLocationUrl) {
        Log.i(TAG, "onRedirectReceived method called.");
        // You should call the request.followRedirect() method to continue
        // processing the request.
        request.followRedirect();
      }

      @Override
      public void onResponseStarted(UrlRequest request, UrlResponseInfo info) {
        Log.i(TAG, "onResponseStarted method called.");
        // You should call the request.read() method before the request can be
        // further processed. The following instruction provides a ByteBuffer object
        // with a capacity of 102400 bytes to the read() method.
        request.read(ByteBuffer.allocateDirect(102400));
      }

      @Override
      public void onReadCompleted(UrlRequest request, UrlResponseInfo info, ByteBuffer byteBuffer) {
        Log.i(TAG, "onReadCompleted method called.");
        // You should keep reading the request until there's no more data.
        request.read(ByteBuffer.allocateDirect(102400));
      }

      @Override
      public void onSucceeded(UrlRequest request, UrlResponseInfo info) {
        Log.i(TAG, "onSucceeded method called.");
      }
    }
```

- 3. 生成`UrlRequest`对象，并启动请求：

```java
    Executor executor = Executors.newSingleThreadExecutor();
    UrlRequest.Builder requestBuilder = cronetEngine.newUrlRequestBuilder(
            "https://www.example.com", new MyUrlRequestCallback(), executor);

    UrlRequest request = requestBuilder.build();
    request.start();
```

其实就是这么简单。

下面是对Cronet中UrlRequest请求的生命周期：


![cronet-lifecycle.png](/images/cronet-lifecycle.png)

### QUIC 源码架构

在聊QUIC源码之前，我们需要初步的对`Cronet`的源码架构有一个了解。这部分的源码实在太多，接下来的源码使用的分支是最新的`chromium` 浏览器内核中`Cronet`模块。

下面是一个Cronet的核心类在整个Cronet的组成：

![cronet.png](/images/cronet.png)


根据上面的示意图，可以看到Cronet，将整个模块分为如下几个部分：

- 面向应用的api层，如Android，iOS。
  - iOS 则是由一个Cronet的中类方法通过`cronet_environment `控制`cronet`引擎。
  - Android 则复杂很多。首先面向开发者的java-api接口，在这个api接口中有4种不同的实现，分别是`GmsCoreCronetProvider`,`PlayServicesCronetProvider`，`NativeCronetProvider`,`JavaCronetProvider`.为什么会这样呢？其实前两者是在Google环境和存在Google商店下内置了Cronet的组件库，那么就可以直接复用Google为你提供的Cronet 网络请求服务，从而减小包大小。当然如果上述`Cronet`引擎都找不到，就会装载默认的`JavaCronetProvider`对象，通过`JavaUrlRequest`使用`URLConnection`进行网络请求。当然我们可以把`GmsCoreCronetProvider`,`PlayServicesCronetProvider`看成`NativeCronetProvider`也未尝不可，之后我们也只看这个引擎加载器的源码。最终`NativeCronetProvider 最终会生成`CronetUrlRequest`对象交给开发者进行请求

- 对于Android jni层来说，几乎java每一个步骤下生成的Java对象都会在jni的中有一个native对象。这里只说核心的几个。而在jni中，名字带有Adapter的对象一般都是适配器，连接java层对应在native的对象。

  - `CronetURLRequest`对应在jni中也有一个`CronetURLRequest`负责请求的总启动.
  -   `CronetURLRequestAdapter` 负责监听`CronetURLRequest`回调到java层对应的生命周期回调。
  - `CronetUploadDataStream` 控制post时候需要发送的消息体数据流

- `Cronet Core` 也就是`cronet`的核心引擎层。在这个层级里面，无论是iOS还是Android最终都会调用到他们的api。其中在这个引擎层中包含了3部分，`UrlRequest 控制请求事务流转曾层`，`缓存与请求流控制层`，`QUIC实现层`。当然这`cronet`并不只是包含了qui协议c，同级别的具体协议实现还包含了如http1.0，http2.0，webscoket等，可以在UrlRequest组建的时候决定当前请求的协议应该是什么。

  - `URLRequest` 所有的请求都会存在一个`URLRequestJobFactory` 请求工作工厂，当 `URLRequest` 需要执行的请求的时候，就会通过这个工厂生成一个`Job`对象进行生命周期的流转，当真正执行的时候就会把事情委托给`HttpCache`,进行流级别的控制管理

  - `HttpCache` 本质上是一个面向流的缓存。可以缓存多个请求事务(Transaction)，同时每个事务会控制不同的流。而每一个新的流都会生成一个全新的`HttpStreamRequest`，通过`JobController` 创建一个`HttpStreamFactory::Job`将请求委托给事务`HttpTransaction`，`HttpTransaction`进行生命周期的流转。而在这个全新的Job，就会根据之前在 `URLRequest` 配置好的协议头，执行不同的协议请求处理器，并调用`HttpTransaction`开始请求。

   - `QUIC`协议层部分则是对应`quic`的具体实现。其中会生成一个`QuicStreamRequest`控制每一个`quic`请求流，而这个请求流会把事务委托给`QuicStreamFactory`生成`QuicStreamFactory::Job`工作对象。在Job中事务流转整个请求的状态。并在这个Job中控制UDP传输quic协议格式的数据。


有一个大致的认识后，让我们进一步的了解整个QUIC的运行机制，再来看看QUIC协议中原理以及其优越性。


## QUIC 源码解析

先根据使用来看看最初几个api的设计,来看看`CronetEngine.Builder`的构造函数：

```java
        public Builder(Context context) {
            this(createBuilderDelegate(context));
        }
```

```java
        private static ICronetEngineBuilder createBuilderDelegate(Context context) {
            List<CronetProvider> providers =
                    new ArrayList<>(CronetProvider.getAllProviders(context));
            CronetProvider provider = getEnabledCronetProviders(context, providers).get(0);
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG,
                        String.format("Using '%s' provider for creating CronetEngine.Builder.",
                                provider));
            }
            return provider.createBuilder().mBuilderDelegate;
        }
```

能看到实际上是通过`CronetProvider.getAllProviders`获取所有的Cronet引擎提供容器，通过`getEnabledCronetProviders`筛选出第一个可用的Cronet引擎。

#### CronetProvider getAllProviders

```java
    private static final String JAVA_CRONET_PROVIDER_CLASS =
            "org.chromium.net.impl.JavaCronetProvider";

    private static final String NATIVE_CRONET_PROVIDER_CLASS =
            "org.chromium.net.impl.NativeCronetProvider";

    private static final String PLAY_SERVICES_CRONET_PROVIDER_CLASS =
            "com.google.android.gms.net.PlayServicesCronetProvider";

    private static final String GMS_CORE_CRONET_PROVIDER_CLASS =
            "com.google.android.gms.net.GmsCoreCronetProvider";
...
    private static final String RES_KEY_CRONET_IMPL_CLASS = "CronetProviderClassName";

    public static List<CronetProvider> getAllProviders(Context context) {
        // Use LinkedHashSet to preserve the order and eliminate duplicate providers.
        Set<CronetProvider> providers = new LinkedHashSet<>();
        addCronetProviderFromResourceFile(context, providers);
        addCronetProviderImplByClassName(
                context, PLAY_SERVICES_CRONET_PROVIDER_CLASS, providers, false);
        addCronetProviderImplByClassName(context, GMS_CORE_CRONET_PROVIDER_CLASS, providers, false);
        addCronetProviderImplByClassName(context, NATIVE_CRONET_PROVIDER_CLASS, providers, false);
        addCronetProviderImplByClassName(context, JAVA_CRONET_PROVIDER_CLASS, providers, false);
        return Collections.unmodifiableList(new ArrayList<>(providers));
    }

    private static boolean addCronetProviderImplByClassName(
            Context context, String className, Set<CronetProvider> providers, boolean logError) {
        ClassLoader loader = context.getClassLoader();
        try {
            Class<? extends CronetProvider> providerClass =
                    loader.loadClass(className).asSubclass(CronetProvider.class);
            Constructor<? extends CronetProvider> ctor =
                    providerClass.getConstructor(Context.class);
            providers.add(ctor.newInstance(context));
            return true;
        } catch (InstantiationException e) {
            logReflectiveOperationException(className, logError, e);
        } catch (InvocationTargetException e) {
            logReflectiveOperationException(className, logError, e);
        } catch (NoSuchMethodException e) {
            logReflectiveOperationException(className, logError, e);
        } catch (IllegalAccessException e) {
            logReflectiveOperationException(className, logError, e);
        } catch (ClassNotFoundException e) {
            logReflectiveOperationException(className, logError, e);
        }
        return false;
    }

    private static boolean addCronetProviderFromResourceFile(
            Context context, Set<CronetProvider> providers) {
        int resId = context.getResources().getIdentifier(
                RES_KEY_CRONET_IMPL_CLASS, "string", context.getPackageName());
        // Resource not found
        if (resId == 0) {
            // The resource wasn't included in the app; therefore, there is nothing to add.
            return false;
        }
        String className = context.getResources().getString(resId);

        if (className == null || className.equals(PLAY_SERVICES_CRONET_PROVIDER_CLASS)
                || className.equals(GMS_CORE_CRONET_PROVIDER_CLASS)
                || className.equals(JAVA_CRONET_PROVIDER_CLASS)
                || className.equals(NATIVE_CRONET_PROVIDER_CLASS)) {
            return false;
        }

        if (!addCronetProviderImplByClassName(context, className, providers, true)) {
...
        }
        return true;
    }
```

能看到整个核心就是
- 1.获取资源ID为`CronetProviderClassName ` 所对应的Cronet引擎类名。
- 2.反射内置好的`GmsCoreCronetProvider`,`PlayServicesCronetProvider`，`NativeCronetProvider`,`JavaCronetProvider`四种类名为默认引擎提供器

在这里我们只需要阅读`NativeCronetProvider#createBuilder().mBuilderDelegate`相关的源码即可。

### NativeCronetProvider createBuilder

```java
public class NativeCronetProvider extends CronetProvider {

    @UsedByReflection("CronetProvider.java")
    public NativeCronetProvider(Context context) {
        super(context);
    }

    @Override
    public CronetEngine.Builder createBuilder() {
        ICronetEngineBuilder impl = new NativeCronetEngineBuilderWithLibraryLoaderImpl(mContext);
        return new ExperimentalCronetEngine.Builder(impl);
    }
```
从名字能很侵袭的看到整个过程是一个委托者设计模式，构建一个`ExperimentalCronetEngine`对象，而这个对象将真正的执行者委托给`NativeCronetEngineBuilderWithLibraryLoaderImpl`.而之前的`mBuilderDelegate `就是指`NativeCronetEngineBuilderWithLibraryLoaderImpl`对象。

### NativeCronetEngineBuilderWithLibraryLoaderImpl build

```java
public class NativeCronetEngineBuilderImpl extends CronetEngineBuilderImpl {

    public NativeCronetEngineBuilderImpl(Context context) {
        super(context);
    }

    @Override
    public ExperimentalCronetEngine build() {
        if (getUserAgent() == null) {
            setUserAgent(getDefaultUserAgent());
        }

        ExperimentalCronetEngine builder = new CronetUrlRequestContext(this);

        // Clear MOCK_CERT_VERIFIER reference if there is any, since
        // the ownership has been transferred to the engine.
        mMockCertVerifier = 0;

        return builder;
    }
}
```

能看到直接返回`CronetUrlRequestContext`对象作为`CronetEngine`返回给应用层。之后会通过`CronetUrlRequestContext`调用`newUrlRequestBuilder `获取UrlRequestBuilder。

```java
    public CronetEngineBuilderImpl(Context context) {
        mApplicationContext = context.getApplicationContext();
        enableQuic(true);
        enableHttp2(true);
        enableBrotli(false);
        enableHttpCache(CronetEngine.Builder.HTTP_CACHE_DISABLED, 0);
        enableNetworkQualityEstimator(false);
        enablePublicKeyPinningBypassForLocalTrustAnchors(true);
    }
```

而`CronetEngineBuilderImpl`将默认支持quic的选项，http2选项，关闭httpCache。

### CronetUrlRequestContext 构造函数

```java
    public CronetUrlRequestContext(final CronetEngineBuilderImpl builder) {
        mRttListenerList.disableThreadAsserts();
        mThroughputListenerList.disableThreadAsserts();
        mNetworkQualityEstimatorEnabled = builder.networkQualityEstimatorEnabled();
        CronetLibraryLoader.ensureInitialized(builder.getContext(), builder);
        if (!IntegratedModeState.INTEGRATED_MODE_ENABLED) {
            CronetUrlRequestContextJni.get().setMinLogLevel(getLoggingLevel());
        }
        if (builder.httpCacheMode() == HttpCacheType.DISK) {
            mInUseStoragePath = builder.storagePath();
            synchronized (sInUseStoragePaths) {
                if (!sInUseStoragePaths.add(mInUseStoragePath)) {
                    throw new IllegalStateException("Disk cache storage path already in use");
                }
            }
        } else {
            mInUseStoragePath = null;
        }
        synchronized (mLock) {
            mUrlRequestContextAdapter =
                    CronetUrlRequestContextJni.get().createRequestContextAdapter(
                            createNativeUrlRequestContextConfig(builder));
            if (mUrlRequestContextAdapter == 0) {
                throw new NullPointerException("Context Adapter creation failed.");
            }
        }

        // Init native Chromium URLRequestContext on init thread.
        CronetLibraryLoader.postToInitThread(new Runnable() {
            @Override
            public void run() {
                CronetLibraryLoader.ensureInitializedOnInitThread();
                synchronized (mLock) {
                    // mUrlRequestContextAdapter is guaranteed to exist until
                    // initialization on init and network threads completes and
                    // initNetworkThread is called back on network thread.
                    CronetUrlRequestContextJni.get().initRequestContextOnInitThread(
                            mUrlRequestContextAdapter, CronetUrlRequestContext.this);
                }
            }
        });
    }
```

这里核心就是围绕3个native方法:

- 1.`CronetUrlRequestContextJni.get().setMinLogLevel(getLoggingLevel()) ` 设置日志等级
- 2.`CronetUrlRequestContextJni.get().createRequestContextAdapter ` 通过`createNativeUrlRequestContextConfig `获取当前`Cronet`的配置在native下层创建一个`UrlRequestContextAdapter `
- 3.`CronetUrlRequestContextJni.get().initRequestContextOnInitThread `在异步线程中初始化。

核心是`CronetUrlRequestContextJni.get().createRequestContextAdapter ` 以及`CronetUrlRequestContextJni.get().initRequestContextOnInitThread `。要弄懂Cronet在jni层调用之前需要了解Cronet的jni初始化的JNI_OnLoad 做了什么。

不过在这之前先来简单看看`createNativeUrlRequestContextConfig`看看UrlRequestContextConfig(UrlRequest上下文的配置)都有些什么选项？

#### createNativeUrlRequestContextConfig 创建Context配置对象

```java
    public static long createNativeUrlRequestContextConfig(CronetEngineBuilderImpl builder) {
        final long urlRequestContextConfig =
                CronetUrlRequestContextJni.get().createRequestContextConfig(builder.getUserAgent(),
                        builder.storagePath(), builder.quicEnabled(),
                        builder.getDefaultQuicUserAgentId(), builder.http2Enabled(),
                        builder.brotliEnabled(), builder.cacheDisabled(), builder.httpCacheMode(),
                        builder.httpCacheMaxSize(), builder.experimentalOptions(),
                        builder.mockCertVerifier(), builder.networkQualityEstimatorEnabled(),
                        builder.publicKeyPinningBypassForLocalTrustAnchorsEnabled(),
                        builder.threadPriority(Process.THREAD_PRIORITY_BACKGROUND));
        if (urlRequestContextConfig == 0) {
            throw new IllegalArgumentException("Experimental options parsing failed.");
        }
        for (CronetEngineBuilderImpl.QuicHint quicHint : builder.quicHints()) {
            CronetUrlRequestContextJni.get().addQuicHint(urlRequestContextConfig, quicHint.mHost,
                    quicHint.mPort, quicHint.mAlternatePort);
        }
        for (CronetEngineBuilderImpl.Pkp pkp : builder.publicKeyPins()) {
            CronetUrlRequestContextJni.get().addPkp(urlRequestContextConfig, pkp.mHost, pkp.mHashes,
                    pkp.mIncludeSubdomains, pkp.mExpirationDate.getTime());
        }
        return urlRequestContextConfig;
    }
```

能看到配置除了上面说过的quic模式和，http2模式。还有httpCache的开关以及Cache的大小。

注意如果想要使用`QUIC`需要设置`QuicHint`，告诉QUIC协议哪些`url`和`host`支持`quic`协议。

另外，还能通过设置`CronetEngineBuilderImpl.Pkp` 设置默认的加密公钥。


### cronet_jni JNI_OnLoad

```c
extern "C" jint JNI_OnLoad(JavaVM* vm, void* reserved) {
  return cronet::CronetOnLoad(vm, reserved);
}

extern "C" void JNI_OnUnLoad(JavaVM* vm, void* reserved) {
  cronet::CronetOnUnLoad(vm, reserved);
}
```

```c
jint CronetOnLoad(JavaVM* vm, void* reserved) {
  base::android::InitVM(vm);
  JNIEnv* env = base::android::AttachCurrentThread();
  if (!RegisterMainDexNatives(env) || !RegisterNonMainDexNatives(env)) {
    return -1;
  }
  if (!base::android::OnJNIOnLoadInit())
    return -1;
  NativeInit();
  return JNI_VERSION_1_6;
}

void CronetOnUnLoad(JavaVM* jvm, void* reserved) {
  if (base::ThreadPoolInstance::Get())
    base::ThreadPoolInstance::Get()->Shutdown();

  base::android::LibraryLoaderExitHook();
}
```

- 1.`RegisterMainDexNatives` 和 `RegisterNonMainDexNatives` 实际上是加载通过`jni_registration_generator.py`生成的cpp文件。这种文件生成出来就是为了减少`dlsym()`耗时。

了解`jni`的小伙伴都会清楚`jni`有两种注册方式一种是简单的直接声明native方法，然后通过AS可以自动生成`包名_类名_方法名`的cpp方法。而后虚拟机加载native的方法时候，就会通过`dlsym()`调用查找`so`动态库中的对应的方法。另一种则是通过`JNIEnv->RegisterNatives`手动在`JNI_OnLoad`注册当前的native方法关联的java方法(注意要有指向包和类名)。

而`jni_registration_generator.py`就是会遍历所有java文件中的native方法并`JNIEnv->RegisterNatives`手动注册的代码cpp代码。同时会遍历Java文件中带上了`@CalledByNative`方法，说明这是`native`想要调用`java`方法，也会生成相关的反射jmethod的方法的文件。

在这里`RegisterMainDexNatives` 和 `RegisterNonMainDexNatives` 本质上就是装在生成好的动态注册的jni方法。

这个不是重点之后有机会再仔细聊聊。

- 2.  `OnJNIOnLoadInit` 这个方法就是获取`JNIUtils`类中的`ClassLoader`,并获取`ClassLoader#loadClass`的jmethodID保存到全局变量`g_class_loader_load_class_method_id`

- 3.`NativeInit` 在全局生成一个名为`Cronet`的线程池。




### CreateRequestContextAdapter 初始化 

``` cpp
// Creates RequestContextAdater if config is valid URLRequestContextConfig,
// returns 0 otherwise.
static jlong JNI_CronetUrlRequestContext_CreateRequestContextAdapter(
    JNIEnv* env,
    jlong jconfig) {
  std::unique_ptr<URLRequestContextConfig> context_config(
      reinterpret_cast<URLRequestContextConfig*>(jconfig));

  CronetURLRequestContextAdapter* context_adapter =
      new CronetURLRequestContextAdapter(std::move(context_config));
  return reinterpret_cast<jlong>(context_adapter);
}
```

很简答就是初始化了`CronetURLRequestContextAdapter`一个cpp对象对应java对象，并返回当前对象的地址到java中。


#### CreateRequestContextAdapter 头文件

要了解一个c++的类，首先看看头文件，然后再看看构造函数。

```h
namespace net {
class NetLog;
class URLRequestContext;
}  // namespace net

namespace cronet {
class TestUtil;

struct URLRequestContextConfig;

// Adapter between Java CronetUrlRequestContext and CronetURLRequestContext.
class CronetURLRequestContextAdapter
    : public CronetURLRequestContext::Callback {
 public:
  explicit CronetURLRequestContextAdapter(
      std::unique_ptr<URLRequestContextConfig> context_config);

  CronetURLRequestContextAdapter(const CronetURLRequestContextAdapter&) =
      delete;
  CronetURLRequestContextAdapter& operator=(
      const CronetURLRequestContextAdapter&) = delete;

  ~CronetURLRequestContextAdapter() override;

...
 private:
  friend class TestUtil;

  // Native Cronet URL Request Context.
  raw_ptr<CronetURLRequestContext> context_;

  // Java object that owns this CronetURLRequestContextAdapter.
  base::android::ScopedJavaGlobalRef<jobject> jcronet_url_request_context_;
};

}  // namespace cronet

#endif  // COMPONENTS_CRONET_ANDROID_CRONET_URL_REQUEST_CONTEXT_ADAPTER_H_
};

}  // namespace cronet

```

在这里其实持有了一个`CronetURLRequestContext `native对象，这个对象顾名思义就是Cronet请求时候的上下文。同时持有将会持有一个`UrlRequestContext`的java对象。

之后当`Cronet`的状态发生变化都会通过这里的回调java层的`CronetUrlRequestContext`中的监听。



#### CronetURLRequestContextAdapter 构造函数

```cpp
CronetURLRequestContextAdapter::CronetURLRequestContextAdapter(
    std::unique_ptr<URLRequestContextConfig> context_config) {
  // Create context and pass ownership of |this| (self) to the context.
  std::unique_ptr<CronetURLRequestContextAdapter> self(this);
#if BUILDFLAG(INTEGRATED_MODE)
  // Create CronetURLRequestContext running in integrated network task runner.
  ...
#else
  context_ =
      new CronetURLRequestContext(std::move(context_config), std::move(self));
#endif
}
```

CronetURLRequestContextAdapter 则会创建一个`CronetURLRequestContext`对象


#### CronetURLRequestContext 头文件

```h
class CronetURLRequestContext {
 public:
  // Callback implemented by CronetURLRequestContext() caller and owned by
  // CronetURLRequestContext::NetworkTasks.
  class Callback {
   public:
    virtual ~Callback() = default;

    // Invoked on network thread when initialized.
    virtual void OnInitNetworkThread() = 0;

    // Invoked on network thread immediately prior to destruction.
    virtual void OnDestroyNetworkThread() = 0;

...
  };


  CronetURLRequestContext(
      std::unique_ptr<URLRequestContextConfig> context_config,
      std::unique_ptr<Callback> callback,
      scoped_refptr<base::SingleThreadTaskRunner> network_task_runner =
          nullptr);

  CronetURLRequestContext(const CronetURLRequestContext&) = delete;
  CronetURLRequestContext& operator=(const CronetURLRequestContext&) = delete;

  // Releases all resources for the request context and deletes the object.
  // Blocks until network thread is destroyed after running all pending tasks.
  virtual ~CronetURLRequestContext();

  // Called on init thread to initialize URLRequestContext.
  void InitRequestContextOnInitThread();
...

 private:
  friend class TestUtil;
  class ContextGetter;

  class NetworkTasks : public net::EffectiveConnectionTypeObserver,
                       public net::RTTAndThroughputEstimatesObserver,
                       public net::NetworkQualityEstimator::RTTObserver,
                       public net::NetworkQualityEstimator::ThroughputObserver {
   public:
    // Invoked off the network thread.
    NetworkTasks(std::unique_ptr<URLRequestContextConfig> config,
                 std::unique_ptr<CronetURLRequestContext::Callback> callback);

    NetworkTasks(const NetworkTasks&) = delete;
    NetworkTasks& operator=(const NetworkTasks&) = delete;

    // Invoked on the network thread.
    ~NetworkTasks() override;
...

   private:
...
  };

...
};

}  // namespace cronet

#endif  // COMPONENTS_CRONET_CRONET_URL_REQUEST_CONTEXT_H_

```

能看到这个头文件分为3部分：

- `CronetURLRequestContext` 承载所有`URLRequest`请求的上下文，主要用于构建网络任务的环境，回调网络质量相关的回调（如rtt耗时等）
- `Callback ` 用于回调来自`NetworkQualityEstimator `对象对网络质量的监控
- `NetworkTasks ` 实现了`Callback `的回调，承载网络请求的起始



#### CronetURLRequestContext 构造函数

```cpp

CronetURLRequestContext::CronetURLRequestContext(
    std::unique_ptr<URLRequestContextConfig> context_config,
    std::unique_ptr<Callback> callback,
    scoped_refptr<base::SingleThreadTaskRunner> network_task_runner)
    : bidi_stream_detect_broken_connection_(
          context_config->bidi_stream_detect_broken_connection),
      heartbeat_interval_(context_config->heartbeat_interval),
      default_load_flags_(
          net::LOAD_NORMAL |
          (context_config->load_disable_cache ? net::LOAD_DISABLE_CACHE : 0)),
      network_tasks_(
          new NetworkTasks(std::move(context_config), std::move(callback))),
      network_task_runner_(network_task_runner) {
  if (!network_task_runner_) {
    network_thread_ = std::make_unique<base::Thread>("network");
    base::Thread::Options options;
    options.message_pump_type = base::MessagePumpType::IO;
    network_thread_->StartWithOptions(std::move(options));
    network_task_runner_ = network_thread_->task_runner();
  }
}
```

初始化一个`NetworkTasks`作为一个网络请求任务承载者。并初始化一个名为`network`的线程，并以这个线程创建一个`looper`赋值给`network_task_runner_`，之后所有的请求任务都会在这个loop中开始。

#### initRequestContextOnInitThread

```cpp
void CronetURLRequestContext::InitRequestContextOnInitThread() {
  DCHECK(OnInitThread());
  auto proxy_config_service =
      cronet::CreateProxyConfigService(GetNetworkTaskRunner());
  g_net_log.Get().EnsureInitializedOnInitThread();
  GetNetworkTaskRunner()->PostTask(
      FROM_HERE,
      base::BindOnce(&CronetURLRequestContext::NetworkTasks::Initialize,
                     base::Unretained(network_tasks_), GetNetworkTaskRunner(),
                     GetFileThread()->task_runner(),
                     std::move(proxy_config_service)));
}
```
`GetNetworkTaskRunner`获取`network_task_runner_`调用`PostTask `进入切换到`network`线程的loop，执行`CronetURLRequestContext::NetworkTasks::Initialize`方法

```cpp
void CronetURLRequestContext::NetworkTasks::Initialize(
    scoped_refptr<base::SingleThreadTaskRunner> network_task_runner,
    scoped_refptr<base::SequencedTaskRunner> file_task_runner,
    std::unique_ptr<net::ProxyConfigService> proxy_config_service) {

  std::unique_ptr<URLRequestContextConfig> config(std::move(context_config_));
  network_task_runner_ = network_task_runner;
  if (config->network_thread_priority)
    SetNetworkThreadPriorityOnNetworkThread(
        config->network_thread_priority.value());
  base::DisallowBlocking();
  net::URLRequestContextBuilder context_builder;
  context_builder.set_network_delegate(
      std::make_unique<BasicNetworkDelegate>());
  context_builder.set_net_log(g_net_log.Get().net_log());

  context_builder.set_proxy_resolution_service(
      cronet::CreateProxyResolutionService(std::move(proxy_config_service),
                                           g_net_log.Get().net_log()));

  config->ConfigureURLRequestContextBuilder(&context_builder);
  effective_experimental_options_ =
      base::Value(config->effective_experimental_options);

  if (config->enable_network_quality_estimator) {
    std::unique_ptr<net::NetworkQualityEstimatorParams> nqe_params =
        std::make_unique<net::NetworkQualityEstimatorParams>(
            std::map<std::string, std::string>());
    if (config->nqe_forced_effective_connection_type) {
      nqe_params->SetForcedEffectiveConnectionType(
          config->nqe_forced_effective_connection_type.value());
    }

    network_quality_estimator_ = std::make_unique<net::NetworkQualityEstimator>(
        std::move(nqe_params), g_net_log.Get().net_log());
    network_quality_estimator_->AddEffectiveConnectionTypeObserver(this);
    network_quality_estimator_->AddRTTAndThroughputEstimatesObserver(this);

    context_builder.set_network_quality_estimator(
        network_quality_estimator_.get());
  }

...

  // Disable net::CookieStore.
  context_builder.SetCookieStore(nullptr);

  context_ = context_builder.Build();

..

  if (config->enable_quic) {
    for (const auto& quic_hint : config->quic_hints) {
      if (quic_hint->host.empty()) {
        LOG(ERROR) << "Empty QUIC hint host: " << quic_hint->host;
        continue;
      }

      url::CanonHostInfo host_info;
      std::string canon_host(
          net::CanonicalizeHost(quic_hint->host, &host_info));
      if (!host_info.IsIPAddress() &&
          !net::IsCanonicalizedHostCompliant(canon_host)) {
...
        continue;
      }

      if (quic_hint->port <= std::numeric_limits<uint16_t>::min() ||
          quic_hint->port > std::numeric_limits<uint16_t>::max()) {
...
        continue;
      }

      if (quic_hint->alternate_port <= std::numeric_limits<uint16_t>::min() ||
          quic_hint->alternate_port > std::numeric_limits<uint16_t>::max()) {
...
        continue;
      }

      url::SchemeHostPort quic_server("https", canon_host, quic_hint->port);
      net::AlternativeService alternative_service(
          net::kProtoQUIC, "",
          static_cast<uint16_t>(quic_hint->alternate_port));
      context_->http_server_properties()->SetQuicAlternativeService(
          quic_server, net::NetworkIsolationKey(), alternative_service,
          base::Time::Max(), quic::ParsedQuicVersionVector());
    }
  }

  for (const auto& pkp : config->pkp_list) {
    // Add the host pinning.
    context_->transport_security_state()->AddHPKP(
        pkp->host, pkp->expiration_date, pkp->include_subdomains,
        pkp->pin_hashes, GURL::EmptyGURL());
  }

  context_->transport_security_state()
      ->SetEnablePublicKeyPinningBypassForLocalTrustAnchors(
          config->bypass_public_key_pinning_for_local_trust_anchors);

  callback_->OnInitNetworkThread();
  is_context_initialized_ = true;

  if (config->enable_network_quality_estimator && cronet_prefs_manager_) {
    network_task_runner_->PostTask(
        FROM_HERE,
        base::BindOnce(
            &CronetURLRequestContext::NetworkTasks::InitializeNQEPrefs,
            base::Unretained(this)));
  }

#if BUILDFLAG(ENABLE_REPORTING)
  if (context_->reporting_service()) {
    for (const auto& preloaded_header : config->preloaded_report_to_headers) {
      context_->reporting_service()->ProcessReportToHeader(
          preloaded_header.origin, net::NetworkIsolationKey(),
          preloaded_header.value);
    }
  }

  if (context_->network_error_logging_service()) {
    for (const auto& preloaded_header : config->preloaded_nel_headers) {
      context_->network_error_logging_service()->OnHeader(
          net::NetworkIsolationKey(), preloaded_header.origin, net::IPAddress(),
          preloaded_header.value);
    }
  }
#endif  // BUILDFLAG(ENABLE_REPORTING)

  while (!tasks_waiting_for_context_.empty()) {
    std::move(tasks_waiting_for_context_.front()).Run();
    tasks_waiting_for_context_.pop();
  }
}
```

别看这段代码很长实际上做的事情也就如下几件：

- 1.根据`URLRequestContextConfig `装载出`NetworkQualityEstimator `网络质量监控器
- 2.创建`URLRequestContext ` 对象，为之后的`UrlRequest`做准备
- 3.如果`URLRequestContextConfig `允许了quic协议那么会加载所有的`QuicHint`中的资源路径，端口号作为识别。之后遇到这些请求就会使用quic协议，最后生成的`SchemeHostPort `通过`SetQuicAlternativeService`保存到`URLRequestContext `

到目前为止java层的`CronetUrlRequestContext `通过native层的`CronetUrlRequestContextAdapter`创建了一个对应在native层的`CronetUrlRequestContext `对象进行一一对应。

当准备好了`CronetUrlRequestContext `,就可以使用`CronetUrlRequestContext`创建`newUrlRequestBuilder`请求

#### CronetEngineBase newUrlRequestBuilder 创建请求对象

```java
    @Override
    public ExperimentalUrlRequest.Builder newUrlRequestBuilder(
            String url, UrlRequest.Callback callback, Executor executor) {
        return new UrlRequestBuilderImpl(url, callback, executor, this);
    }
```

##### UrlRequestBuilderImpl createRequest 创建请求对象

```java
    @Override
    public UrlRequestBase createRequest(String url, UrlRequest.Callback callback, Executor executor,
            int priority, Collection<Object> requestAnnotations, boolean disableCache,
            boolean disableConnectionMigration, boolean allowDirectExecutor,
            boolean trafficStatsTagSet, int trafficStatsTag, boolean trafficStatsUidSet,
            int trafficStatsUid, RequestFinishedInfo.Listener requestFinishedListener,
            int idempotency) {
        synchronized (mLock) {
            checkHaveAdapter();
            return new CronetUrlRequest(this, url, priority, callback, executor, requestAnnotations,
                    disableCache, disableConnectionMigration, allowDirectExecutor,
                    trafficStatsTagSet, trafficStatsTag, trafficStatsUidSet, trafficStatsUid,
                    requestFinishedListener, idempotency);
        }
    }
```

很简单，这里把之前在`UrlRequestBuilderImpl`组合的参数都保存到`CronetUrlRequest`返回给应用层。

##### CronetUrlRequest.start 启动请求

```java
    @Override
    public void start() {
        synchronized (mUrlRequestAdapterLock) {
            checkNotStarted();

            try {
                mUrlRequestAdapter = CronetUrlRequestJni.get().createRequestAdapter(
                        CronetUrlRequest.this, mRequestContext.getUrlRequestContextAdapter(),
                        mInitialUrl, mPriority, mDisableCache, mDisableConnectionMigration,
                        mRequestContext.hasRequestFinishedListener()
                                || mRequestFinishedListener != null,
                        mTrafficStatsTagSet, mTrafficStatsTag, mTrafficStatsUidSet,
                        mTrafficStatsUid, mIdempotency);
                mRequestContext.onRequestStarted();
                if (mInitialMethod != null) {
                    if (!CronetUrlRequestJni.get().setHttpMethod(
                                mUrlRequestAdapter, CronetUrlRequest.this, mInitialMethod)) {
                        throw new IllegalArgumentException("Invalid http method " + mInitialMethod);
                    }
                }

                boolean hasContentType = false;
                for (Map.Entry<String, String> header : mRequestHeaders) {
                    if (header.getKey().equalsIgnoreCase("Content-Type")
                            && !header.getValue().isEmpty()) {
                        hasContentType = true;
                    }
                    if (!CronetUrlRequestJni.get().addRequestHeader(mUrlRequestAdapter,
                                CronetUrlRequest.this, header.getKey(), header.getValue())) {
                        throw new IllegalArgumentException(
                                "Invalid header " + header.getKey() + "=" + header.getValue());
                    }
                }
                if (mUploadDataStream != null) {
                    if (!hasContentType) {
                        throw new IllegalArgumentException(
                                "Requests with upload data must have a Content-Type.");
                    }
                    mStarted = true;
                    mUploadDataStream.postTaskToExecutor(new Runnable() {
                        @Override
                        public void run() {
                            mUploadDataStream.initializeWithRequest();
                            synchronized (mUrlRequestAdapterLock) {
                                if (isDoneLocked()) {
                                    return;
                                }
                                mUploadDataStream.attachNativeAdapterToRequest(mUrlRequestAdapter);
                                startInternalLocked();
                            }
                        }
                    });
                    return;
                }
            } catch (RuntimeException e) {
                // If there's an exception, cleanup and then throw the exception to the caller.
                // start() is synchronized so we do not acquire mUrlRequestAdapterLock here.
                destroyRequestAdapterLocked(RequestFinishedInfo.FAILED);
                throw e;
            }
            mStarted = true;
            startInternalLocked();
        }
    }

    @GuardedBy("mUrlRequestAdapterLock")
    private void startInternalLocked() {
        CronetUrlRequestJni.get().start(mUrlRequestAdapter, CronetUrlRequest.this);
    }

```

这里围绕着4个核心的jni方法：

- 1.`createRequestAdapter` 生成一个jni的`UrlRequestAdapter`对象
- 2.回调`onRequestStarted`生命周期
- 3.`setHttpMethod` 为jni的`UrlRequestAdapter` 设置 http请求类型
- 4.`addRequestHeader`为请求装载header
- 5.`mUploadDataStream`读取并把body的数据缓存到jni的`UploadDataStream`中.
- 6.调用`startInternalLocked`也就是`CronetUrlRequest`的start

#### CronetURLRequestAdapter 创建

```java
static jlong JNI_CronetUrlRequest_CreateRequestAdapter(
    JNIEnv* env,
    const JavaParamRef<jobject>& jurl_request,
    jlong jurl_request_context_adapter,
    const JavaParamRef<jstring>& jurl_string,
    jint jpriority,
    jboolean jdisable_cache,
    jboolean jdisable_connection_migration,
    jboolean jenable_metrics,
    jboolean jtraffic_stats_tag_set,
    jint jtraffic_stats_tag,
    jboolean jtraffic_stats_uid_set,
    jint jtraffic_stats_uid,
    jint jidempotency) {
  CronetURLRequestContextAdapter* context_adapter =
      reinterpret_cast<CronetURLRequestContextAdapter*>(
          jurl_request_context_adapter);


  CronetURLRequestAdapter* adapter = new CronetURLRequestAdapter(
      context_adapter, env, jurl_request, url,
      static_cast<net::RequestPriority>(jpriority), jdisable_cache,
      jdisable_connection_migration, jenable_metrics, jtraffic_stats_tag_set,
      jtraffic_stats_tag, jtraffic_stats_uid_set, jtraffic_stats_uid,
      static_cast<net::Idempotency>(jidempotency));

  return reinterpret_cast<jlong>(adapter);
}
```

```java
CronetURLRequestAdapter::CronetURLRequestAdapter(
    CronetURLRequestContextAdapter* context,
    JNIEnv* env,
    jobject jurl_request,
    const GURL& url,
    net::RequestPriority priority,
    jboolean jdisable_cache,
    jboolean jdisable_connection_migration,
    jboolean jenable_metrics,
    jboolean jtraffic_stats_tag_set,
    jint jtraffic_stats_tag,
    jboolean jtraffic_stats_uid_set,
    jint jtraffic_stats_uid,
    net::Idempotency idempotency)
    : request_(
          new CronetURLRequest(context->cronet_url_request_context(),
                               std::unique_ptr<CronetURLRequestAdapter>(this),
                               url,
                               priority,
                               jdisable_cache == JNI_TRUE,
                               jdisable_connection_migration == JNI_TRUE,
                               jenable_metrics == JNI_TRUE,
                               jtraffic_stats_tag_set == JNI_TRUE,
                               jtraffic_stats_tag,
                               jtraffic_stats_uid_set == JNI_TRUE,
                               jtraffic_stats_uid,
                               idempotency)) {
  owner_.Reset(env, jurl_request);
}

```

`CronetURLRequestContextAdapter` 持有一个 `CronetURLRequest`对象。刚刚好对应java层中的`CronetURLRequest`。整个请求的发起就是从`CronetURLRequest`开始。

##### CronetURLRequest 构造函数

```cpp
CronetURLRequest::CronetURLRequest(CronetURLRequestContext* context,
                                   std::unique_ptr<Callback> callback,
                                   const GURL& url,
                                   net::RequestPriority priority,
                                   bool disable_cache,
                                   bool disable_connection_migration,
                                   bool enable_metrics,
                                   bool traffic_stats_tag_set,
                                   int32_t traffic_stats_tag,
                                   bool traffic_stats_uid_set,
                                   int32_t traffic_stats_uid,
                                   net::Idempotency idempotency)
    : context_(context),
      network_tasks_(std::move(callback),
                     url,
                     priority,
                     CalculateLoadFlags(context->default_load_flags(),
                                        disable_cache,
                                        disable_connection_migration),
                     enable_metrics,
                     traffic_stats_tag_set,
                     traffic_stats_tag,
                     traffic_stats_uid_set,
                     traffic_stats_uid,
                     idempotency),
      initial_method_("GET"),
      initial_request_headers_(std::make_unique<net::HttpRequestHeaders>()) {
  DCHECK(!context_->IsOnNetworkThread());
}
```

能看到`CronetURLRequest`默认设置`GET` http的方法，同时创建`HttpRequestHeaders`接受Http协议的头部信息。


#### CronetURLRequest start

java方法`CronetUrlRequestJni.get().start`所对应的jni方法如下，也就是`CronetURLRequest`的start方法。

```cpp
void CronetURLRequestAdapter::Start(JNIEnv* env,
                                    const JavaParamRef<jobject>& jcaller) {
  request_->Start();
}
```

```cpp
void CronetURLRequest::Start() {
  DCHECK(!context_->IsOnNetworkThread());
  context_->PostTaskToNetworkThread(
      FROM_HERE,
      base::BindOnce(&CronetURLRequest::NetworkTasks::Start,
                     base::Unretained(&network_tasks_),
                     base::Unretained(context_), initial_method_,
                     std::move(initial_request_headers_), std::move(upload_)));
}
```

start方法其实就是切换到network线程。调用`NetworkTasks`名为start类方法。

##### NetworkTasks Start

```cpp
void CronetURLRequest::NetworkTasks::Start(
    CronetURLRequestContext* context,
    const std::string& method,
    std::unique_ptr<net::HttpRequestHeaders> request_headers,
    std::unique_ptr<net::UploadDataStream> upload) {

  url_request_ = context->GetURLRequestContext()->CreateRequest(
      initial_url_, net::DEFAULT_PRIORITY, this, MISSING_TRAFFIC_ANNOTATION);
  url_request_->SetLoadFlags(initial_load_flags_);
  url_request_->set_method(method);
  url_request_->SetExtraRequestHeaders(*request_headers);
  url_request_->SetPriority(initial_priority_);
  url_request_->SetIdempotency(idempotency_);
  std::string referer;
  if (request_headers->GetHeader(net::HttpRequestHeaders::kReferer, &referer)) {
    url_request_->SetReferrer(referer);
  }
  if (upload)
    url_request_->set_upload(std::move(upload));
  if (traffic_stats_tag_set_ || traffic_stats_uid_set_) {
#if BUILDFLAG(IS_ANDROID)
    url_request_->set_socket_tag(net::SocketTag(
        traffic_stats_uid_set_ ? traffic_stats_uid_ : net::SocketTag::UNSET_UID,
        traffic_stats_tag_set_ ? traffic_stats_tag_
                               : net::SocketTag::UNSET_TAG));
#else
...
#endif
  }
  url_request_->Start();
}
```

`GetURLRequestContext()->CreateRequest`创造一个`URLRequest`对象。将保存在`CronetURLRequest`填充到`URLRequest`中，并调用这个对象的start方法。

而这个`URLRequest` 你可以看成Cronet的内核对外的最重要的接口。因为iOS的模块最终也是对接到`URLRequest`对象中。

### URLRequest 的头文件

```cpp
class NET_EXPORT URLRequest : public base::SupportsUserData {
 public:
 
  typedef URLRequestJob*(ProtocolFactory)(URLRequest* request,
                                          const std::string& scheme);

  static constexpr int kMaxRedirects = 20;

...

  URLRequest(const URLRequest&) = delete;
  URLRequest& operator=(const URLRequest&) = delete;
...
  ~URLRequest() override;

...

 protected:
 ...

 private:
  friend class URLRequestJob;
  friend class URLRequestContext;

  // For testing purposes.
  // TODO(maksims): Remove this.
  friend class TestNetworkDelegate;

  // URLRequests are always created by calling URLRequestContext::CreateRequest.
  URLRequest(const GURL& url,
             RequestPriority priority,
             Delegate* delegate,
             const URLRequestContext* context,
             NetworkTrafficAnnotationTag traffic_annotation,
             bool is_for_websockets,
             absl::optional<net::NetLogSource> net_log_source);

...
  raw_ptr<const URLRequestContext> context_;

...

  std::unique_ptr<URLRequestJob> job_;
  std::unique_ptr<UploadDataStream> upload_data_stream_;

  std::vector<GURL> url_chain_;
  SiteForCookies site_for_cookies_;

...
};
```

在这里面有3个核心的对象：

- 1.`context_`类型是`URLRequestContext`，该类负责了`URLRequest`请求过程中需要的上下文，其中有一个核心的核心上下文`QuicContext`用于quic协议请求的过程
- 2.`job_` 这个对象是`URLRequestJob` 这是`URLRequest`真正用于执行请求的任务对象，内置请求任务生命周期
- 3.`upload_data_stream_` 是`UploadDataStream`，这个数据流是用于保存post时候的，消息体。



### URLRequest Start  

```cpp
void URLRequest::Start() {
  if (status_ != OK)
    return;
...

...

  StartJob(context_->job_factory()->CreateJob(this));
}
```

很见到在这里获取`job_factory`通过`CreateJob` 创建一个`URLRequestJob`工作项，并调用`UrlRequest`的`StartJob`启动URLRequestJob。
简单看看`CreateJob`返回的是什么类型的`URLRequestJob`.

```cpp
std::unique_ptr<URLRequestJob> URLRequestJobFactory::CreateJob(
    URLRequest* request) const {

  if (!request->url().is_valid())
    return std::make_unique<URLRequestErrorJob>(request, ERR_INVALID_URL);

  if (g_interceptor_for_testing) {
    std::unique_ptr<URLRequestJob> job(
        g_interceptor_for_testing->MaybeInterceptRequest(request));
    if (job)
      return job;
  }

  auto it = protocol_handler_map_.find(request->url().scheme());
  if (it == protocol_handler_map_.end()) {
    return std::make_unique<URLRequestErrorJob>(request,
                                                ERR_UNKNOWN_URL_SCHEME);
  }

  return it->second->CreateJob(request);
}
```

实际上在不同的协议都会对应上不同的`URLRequestJob`工厂，而这些网络协议创建工厂为`ProtocolHandler`.这些`ProtocolHandler`都可以通过设置到`protocol_handler_map_`中，根据协议头scheme进行自定义协议实现。

而在这个内核层中，默认自带了`HttpProtocolHandler`实现,如下：

```cpp
class HttpProtocolHandler : public URLRequestJobFactory::ProtocolHandler {
 public:

  explicit HttpProtocolHandler(bool is_for_websockets)
      : is_for_websockets_(is_for_websockets) {}

  HttpProtocolHandler(const HttpProtocolHandler&) = delete;
  HttpProtocolHandler& operator=(const HttpProtocolHandler&) = delete;
  ~HttpProtocolHandler() override = default;

  std::unique_ptr<URLRequestJob> CreateJob(URLRequest* request) const override {
    if (request->is_for_websockets() != is_for_websockets_) {
      return std::make_unique<URLRequestErrorJob>(request,
                                                  ERR_UNKNOWN_URL_SCHEME);
    }
    return URLRequestHttpJob::Create(request);
  }

  const bool is_for_websockets_;
};
```

能看到默认的 Http对应的协议处理器`HttpProtocolHandler`,并通过`CreateJob`创建请求任务对应`URLRequestHttpJob`。而这个的设置时机：

```cpp
URLRequestJobFactory::URLRequestJobFactory() {
  SetProtocolHandler(url::kHttpScheme, std::make_unique<HttpProtocolHandler>(
                                           /*is_for_websockets=*/false));
  SetProtocolHandler(url::kHttpsScheme, std::make_unique<HttpProtocolHandler>(
                                            /*is_for_websockets=*/false));
#if BUILDFLAG(ENABLE_WEBSOCKETS)
  SetProtocolHandler(url::kWsScheme, std::make_unique<HttpProtocolHandler>(
                                         /*is_for_websockets=*/true));
  SetProtocolHandler(url::kWssScheme, std::make_unique<HttpProtocolHandler>(
                                          /*is_for_websockets=*/true));
#endif  // BUILDFLAG(ENABLE_WEBSOCKETS)
}
```
`job_factory`也就是`URLRequestJobFactory`类型，能看到构造函数中默认的设置了http和https，ws,wss的协议处理器。

```cpp
void URLRequest::StartJob(std::unique_ptr<URLRequestJob> job) {
...
  job_ = std::move(job);
  job_->SetExtraRequestHeaders(extra_request_headers_);
  job_->SetPriority(priority_);
  job_->SetRequestHeadersCallback(request_headers_callback_);
  job_->SetEarlyResponseHeadersCallback(early_response_headers_callback_);
  job_->SetResponseHeadersCallback(response_headers_callback_);

  if (upload_data_stream_.get())
    job_->SetUpload(upload_data_stream_.get());

...
  job_->Start();
}
```

很简单就是把URLRequest 中的头部，优先级，回调，消息体的数据流引用数据保存到`URLRequestJob`，并调用`URLRequestJob`的Start。此时`URLRequestJob`一般是指`URLRequestHttpJob`.


#### URLRequestHttpJob Start

```cpp
void URLRequestHttpJob::Start() {

  request_info_.url = request_->url();
  request_info_.method = request_->method();

  request_info_.network_isolation_key =
      request_->isolation_info().network_isolation_key();
  request_info_.possibly_top_frame_origin =
      request_->isolation_info().top_frame_origin();
  request_info_.is_subframe_document_resource =
      request_->isolation_info().request_type() ==
      net::IsolationInfo::RequestType::kSubFrame;
  request_info_.load_flags = request_->load_flags();
  request_info_.secure_dns_policy = request_->secure_dns_policy();
  request_info_.traffic_annotation =
      net::MutableNetworkTrafficAnnotationTag(request_->traffic_annotation());
  request_info_.socket_tag = request_->socket_tag();
  request_info_.idempotency = request_->GetIdempotency();
#if BUILDFLAG(ENABLE_REPORTING)
  request_info_.reporting_upload_depth = request_->reporting_upload_depth();
#endif

  bool should_add_cookie_header = ShouldAddCookieHeader();


  if (!should_add_cookie_header) {
    OnGotFirstPartySetMetadata(FirstPartySetMetadata());
    return;
  }
  absl::optional<FirstPartySetMetadata> metadata =
      cookie_util::ComputeFirstPartySetMetadataMaybeAsync(
          SchemefulSite(request()->url()), request()->isolation_info(),
          request()->context()->cookie_store()->cookie_access_delegate(),
          request()->force_ignore_top_frame_party_for_cookies(),
          base::BindOnce(&URLRequestHttpJob::OnGotFirstPartySetMetadata,
                         weak_factory_.GetWeakPtr()));

  if (metadata.has_value())
    OnGotFirstPartySetMetadata(std::move(metadata.value()));
}
```

将`UrlRequest`的请求参数保存到`request_info_`。如果没有任何的cookie则直接调用`OnGotFirstPartySetMetadata`,如果存在全局通用cookie,则把数据保存到`FirstPartySetMetadata`。并调用`OnGotFirstPartySetMetadata`.

#### OnGotFirstPartySetMetadata

```cpp
void URLRequestHttpJob::OnGotFirstPartySetMetadata(
    FirstPartySetMetadata first_party_set_metadata) {
  first_party_set_metadata_ = std::move(first_party_set_metadata);
 
  request_info_.privacy_mode = DeterminePrivacyMode();
...

  GURL referrer(request_->referrer());

  if (referrer.is_valid()) {
    std::string referer_value = referrer.spec();
    request_info_.extra_headers.SetHeader(HttpRequestHeaders::kReferer,
                                          referer_value);
  }

  request_info_.extra_headers.SetHeaderIfMissing(
      HttpRequestHeaders::kUserAgent,
      http_user_agent_settings_ ?
          http_user_agent_settings_->GetUserAgent() : std::string());

  AddExtraHeaders();

  if (ShouldAddCookieHeader()) {

    cookie_partition_key_ =
        absl::make_optional(CookiePartitionKey::FromNetworkIsolationKey(
            request_->isolation_info().network_isolation_key(),
            base::OptionalOrNullptr(
                first_party_set_metadata_.top_frame_owner())));
    AddCookieHeaderAndStart();
  } else {
    StartTransaction();
  }
}
```

- 1.先通过`SetHeader`以及`AddExtraHeaders`设置`Referer`,`GZIP`等常用的Header
- 2.如果存在cookie则通过`AddCookieHeaderAndStart`添加到Header中`Cookie`为key的数据集合中。不过
- 3.`StartTransaction`启动事务。

#### URLRequestHttpJob StartTransaction

```cpp
void URLRequestHttpJob::StartTransaction() {
...
  StartTransactionInternal();
}

void URLRequestHttpJob::StartTransactionInternal() {
 

  int rv;

  ...

  if (transaction_.get()) {
    rv = transaction_->RestartWithAuth(
        auth_credentials_, base::BindOnce(&URLRequestHttpJob::OnStartCompleted,
                                          base::Unretained(this)));
    auth_credentials_ = AuthCredentials();
  } else {

    rv = request_->context()->http_transaction_factory()->CreateTransaction(
        priority_, &transaction_);
...

    if (rv == OK) {
      transaction_->SetConnectedCallback(base::BindRepeating(
          &URLRequestHttpJob::NotifyConnectedCallback, base::Unretained(this)));
      transaction_->SetRequestHeadersCallback(request_headers_callback_);
      transaction_->SetEarlyResponseHeadersCallback(
          early_response_headers_callback_);
      transaction_->SetResponseHeadersCallback(response_headers_callback_);

      if (!throttling_entry_.get() ||
          !throttling_entry_->ShouldRejectRequest(*request_)) {
        rv = transaction_->Start(
            &request_info_,
            base::BindOnce(&URLRequestHttpJob::OnStartCompleted,
                           base::Unretained(this)),
            request_->net_log());
        start_time_ = base::TimeTicks::Now();
      } else {
        // Special error code for the exponential back-off module.
        rv = ERR_TEMPORARILY_THROTTLED;
      }
    }
  }

  if (rv == ERR_IO_PENDING)
    return;

  // The transaction started synchronously, but we need to notify the
  // URLRequest delegate via the message loop.
  base::ThreadTaskRunnerHandle::Get()->PostTask(
      FROM_HERE, base::BindOnce(&URLRequestHttpJob::OnStartCompleted,
                                weak_factory_.GetWeakPtr(), rv));
}
```

能看到这个过程中存在一个核心的对象`transaction_`也就是`HttpTransaction`。之后请求Job工作项，就将请求委托给`HttpTransaction`.

如果发现`URLRequestHttpJob`已经存在了`HttpTransaction`，那么就会调用`HttpTransaction`的`RestartWithAuth`重新启动并且校验权限。

如果发现没有创建，则调用事务工厂`CreateTransaction`创建`HttpTransaction`，然后调用Start方法正式启动事务，开始请求。

### 总结

首先进行一个初步的总结，到了`HttpTransaction`之后，就会开始流转请求的生命周期，然后进行quic协议的初始化，执行quic的请求。

不过限于篇幅，以及Cronet设计上的确实比较冗长，这里先做一个简单的总结先：

可以将Cronet的设计组合看成3层：

- 1.java的api层
- 2.用于连通java和native的jni的adapter层
- 3.通用于所有平台的内核层

java层会通过反射尝试获取不同环境依赖下的cronetProvider，也就是Cornet的内核提供器。有的是依赖Google环境，有的可以自己自己直接依赖native的包，都没有则使用默认的 android自带的网络请求。

jni层，实际上就是末尾带上了Adapter的类以及和java层中相同类名的类，这些类一般不做任何事情，一般会包裹一个对应相同名字的cpp对象在native中，并且把相同的行为赋予给Adpater以及对应的native对象。

- java层CronetUrlRequestContext 会对应上 jni中的`CronetURLRequestContextAdapter`作为枢纽，间接控制native中的`CronetURLRequestContext`。而`CronetURLRequestContext`则是控制了整个请求的上下文

- java层`CronetUrlRequest` 会对应上jni中的`CronetURLRequestAdapter`,并间接控制native层的`CronetUrlRequest`对象。

而这个对象最终会控制native层的`UrlRequest`，而这个对象最终会通向Cronet的内核层。并且会从thridParty文件夹中找到quic协议相关的处理。

后续的文章将会继续揭晓`HttpTransaction`如何进行事务流转，并且quic是如何执行。

