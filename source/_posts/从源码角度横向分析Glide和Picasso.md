---
title: 从源码角度横向分析Glide和Picasso
top: false
cover: false
date: 2018-01-30 15:22:14
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android 常用第三方库
---
Glide和Picasso这两个库，是现在Android里面是开发中比较常用的两个库。而且用法极其的相似，很多人也喜欢拿这两者比较。这一次我自己亲自看了一遍源码，对两者进行了比较。

本人才疏学浅，有错误的地方请指出，在原地址在下面:
https://www.jianshu.com/p/4de87ebf5104

# Glide

先看看Glide的用法：
```
Glide.with(this).load("url").into(imageview);
```
先从Glide 3.7.0开始说明。就从网络加载图片为例子：
先看看整个时序图：![Glide时序图.jpg](/images/Glide时序图.jpg)


由于调用链十分长，而且大量的使用接口编程。这么看或许还不够直观，在这里，我附上一个glide中每个角色负责的功能图。

![Glide主要角色.png](/images/Glide主要角色.png)


这里包含了在上述流程中所用到的主要功能模块。

### Glide各个职能

1.Engine 是整个Glide的引擎，无论是加载图片还是链接网络都是通过这个Engine的类进行启动,而且通过里面的MainHandler进行异步刷新图片。无论是glide-v3还是glide-v4，这一块的功能都没怎么变动过。发生变化的是，glide-v4感觉上学习了Picasso多了几种图片加载的状态，每一次完成一部分就切换当前资源的状态。

2.ResourceTranscoder 这个是Glide进行类型变换的类，换句话就是转化器。比如说当我们准备加载url的时候，我们获取到的是Resource<Bitmap> 的resource类型，但是我们获取之后需要对bitmap进行一些处理，我们需要进行对这个Resource进行转化，因此会在回调之前，会把无绘制加工的Resource类型转化为有绘制加工的GlideBitmapDrawableResource。注意，这个和我们常用用来转化圆角的transform()产生的transformtion不是一个东西。

3.DataLoadProvider Glide核心部分，因为这一部分是Glide用于解析bitmap，链接网络，读取本地文件等等，所用到的数据读取时候提供的decode，encode类。


4.ModelLoader是Glide另一处核心部分，这个是用于生成用于读取的数据，比如说String转化为InputStream等。而且妙的一点那是，每个生成工厂之间可以嵌套，最后会一层层解析获取到一些参数，进入到最为基础的数据模型。

4.bitmapPool顾名思义，就是指bitmap池子

5.Cache 是特指DiskCache和MemoryCache两种，前者是指磁盘上的缓存，后者是指内存上的缓存。

6.Target 这个是指每一次加载的目标资源，每个target都包含一次请求动作Request。

7.Request 这个是指每一次事件的请求。

8.还有其他的，在这里不多做讨论。毕竟glide做的事情很多，篇幅有限先不说了。

上述这些模块会在Glide调用with的时候，调用单例，进行初始化，并且在构造函数中进行初始化。其中我们要尤其注意一点，除了ModelLoader，ResourceTranscoder，DataLoadProvider是通过register方法到下面两个类，其他都是在构造器里面就是可以初始化好。而在glide-v4中，这些所有的东西都会注册到Registry里面，在通过getloadpath获取对应ModelLoader，获取到之后进行解析，而且没有这么多Request，通过RequestBuilder创建一个SingleRequest。这一点的重构使得glide-v4比起glide-v3轻量了很多。由于大家用的v3还是多一点，这里挑出v3和大家说一下。

###Glide的注册表
```
    private final GenericLoaderFactory loaderFactory;
    private final TranscoderRegistry transcoderRegistry 
    private final DataLoadProviderRegistry 
Glide(Engine engine, MemoryCache memoryCache, BitmapPool bitmapPool, Context context, DecodeFormat decodeFormat) {
...
//容器注册方法
    dataLoadProviderRegistry.register(InputStream.class, Bitmap.class, streamBitmapLoadProvider);

//ModelLoader注册调用
    register(String.class, InputStream.class, new StreamStringLoader.Factory());

....

//转换器注册方法
transcoderRegistry.register(GifBitmapWrapper.class, GlideDrawable.class,
                new GifBitmapWrapperDrawableTranscoder(
                        new GlideBitmapDrawableTranscoder(context.getResources(), bitmapPool)));

..

}


//ModelLoader在Glide类里面的方法
public <T, Y> void register(Class<T> modelClass, Class<Y> resourceClass, ModelLoaderFactory<T, Y> factory) {
        ModelLoaderFactory<T, Y> removed = loaderFactory.register(modelClass, resourceClass, factory);
        if (removed != null) {
            removed.teardown();
        }
    }


//根据你注册对应的两个类的参数，获取对应的ModelLoader
    public static <T, Y> ModelLoader<T, Y> buildModelLoader(Class<T> modelClass, Class<Y> resourceClass,
            Context context) {
         if (modelClass == null) {
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Unable to load null model, setting placeholder only");
            }
            return null;
        }
        return Glide.get(context).getLoaderFactory().buildModelLoader(modelClass, resourceClass);
    }

```
最后一个方法尤为的重要，但是我学习源码的时候，就是没有注意到这里根本找不到解析接口对应的实现类是哪个。

好了，铺垫都差不多了，虽然Darren大佬和郭霖大佬都写过了，再写一遍着实有点没意思，我这一次从他们没怎么说过的角度来解析，一起比较Picasso源码，好了闲话到这里，我们开始Glide的源码旅程。

### with

先从with的方法开始
```
    public static RequestManager with(FragmentActivity activity) {
        RequestManagerRetriever retriever = RequestManagerRetriever.get();
        return retriever.get(activity);
    }
```
从我上面那个流程图，可以知道最后会调用fragmentGet
```
    RequestManager fragmentGet(Context context, android.app.FragmentManager fm) {
        RequestManagerFragment current = getRequestManagerFragment(fm);
        RequestManager requestManager = current.getRequestManager();
        if (requestManager == null) {
            requestManager = new RequestManager(context, current.getLifecycle(), current.getRequestManagerTreeNode());
            current.setRequestManager(requestManager);
        }
        return requestManager;
    }

    RequestManagerFragment getRequestManagerFragment(final android.app.FragmentManager fm) {
        RequestManagerFragment current = (RequestManagerFragment) fm.findFragmentByTag(FRAGMENT_TAG);
        if (current == null) {
            current = pendingRequestManagerFragments.get(fm);
            if (current == null) {
                current = new RequestManagerFragment();
                pendingRequestManagerFragments.put(fm, current);
                fm.beginTransaction().add(current, FRAGMENT_TAG).commitAllowingStateLoss();
                handler.obtainMessage(ID_REMOVE_FRAGMENT_MANAGER, fm).sendToTarget();
            }
        }
        return current;
    }
```
这个方法在我们的activity上面创建一个隐藏的fragment，这fragment的作用可以和外面的activity,fragment的生命周期同步。这么做的好处，我们可以把加载图片等行为和生命周期同步，不需要把onresume,onstop等方法暴露在使用者眼里，很好是遵守了设计模式中的单一原则。

### Glide load
而返回的RequestManager，会帮助我们创建好，一个事件请求类GenericRequest，这个类就是整个事件请求的起点。
由于我们研究的是网络请求的流程
```
    public DrawableTypeRequest<String> load(String string) {
        return (DrawableTypeRequest<String>) fromString().load(string);
    }
```
根据我的时序图可以清楚到了loadGeneric：
```
private <T> DrawableTypeRequest<T> loadGeneric(Class<T> modelClass) {
        ModelLoader<T, InputStream> streamModelLoader = Glide.buildStreamModelLoader(modelClass, context);
        ModelLoader<T, ParcelFileDescriptor> fileDescriptorModelLoader =
                Glide.buildFileDescriptorModelLoader(modelClass, context);
        if (modelClass != null && streamModelLoader == null && fileDescriptorModelLoader == null) {
            throw new IllegalArgumentException("Unknown type " + modelClass + ". You must provide a Model of a type for"
                    + " which there is a registered ModelLoader, if you are using a custom model, you must first call"
                    + " Glide#register with a ModelLoaderFactory for your custom model class");
        }

        return optionsApplier.apply(
                new DrawableTypeRequest<T>(modelClass, streamModelLoader, fileDescriptorModelLoader, context,
                        glide, requestTracker, lifecycle, optionsApplier));
    }
```

### Glide into
而里面这个DrawableTypeRequest父类就是GenericRequestBuilder，这样就可以通过这个建造者创建一个请求，我们在看into方法，所有的核心逻辑都在这里。
```

    public Target<TranscodeType> into(ImageView view) {
        Util.assertMainThread();
        if (view == null) {
            throw new IllegalArgumentException("You must pass in a non null View");
        }

        if (!isTransformationSet && view.getScaleType() != null) {
            switch (view.getScaleType()) {
                case CENTER_CROP:
                    applyCenterCrop();
                    break;
                case FIT_CENTER:
                case FIT_START:
                case FIT_END:
                    applyFitCenter();
                    break;
                //$CASES-OMITTED$
                default:
                    // Do nothing.
            }
        }
        return into(glide.buildImageViewTarget(view, transcodeClass));
    }
```

注意在这里我们要通过网络下载一个bitmap，我们从buildImageViewTarget知道我们会生成BitmapImageViewTarget。记住它，最后我们会回调他的onResourceReady
```
    public <Z> Target<Z> buildTarget(ImageView view, Class<Z> clazz) {
        if (GlideDrawable.class.isAssignableFrom(clazz)) {
            return (Target<Z>) new GlideDrawableImageViewTarget(view);
        } else if (Bitmap.class.equals(clazz)) {
            return (Target<Z>) new BitmapImageViewTarget(view);
        } else if (Drawable.class.isAssignableFrom(clazz)) {
            return (Target<Z>) new DrawableImageViewTarget(view);
        } else {
            throw new IllegalArgumentException("Unhandled class: " + clazz
                    + ", try .as*(Class).transcode(ResourceTranscoder)");
        }
    }
```
在下面这个函数我们创建一个GenericRequest的请求类，在lifecycle监听这个请求事件，这将会同步整个生命周期，而requestTracker.runRequest(request);将会启动Engine的load的方法，并且声明了DecodeJob和EngineRunnable。
```
    public <Y extends Target<TranscodeType>> Y into(Y target) {
        Util.assertMainThread();
        if (target == null) {
            throw new IllegalArgumentException("You must pass in a non null Target");
        }
        if (!isModelSet) {
            throw new IllegalArgumentException("You must first set a model (try #load())");
        }

        Request previous = target.getRequest();

        if (previous != null) {
            previous.clear();
            requestTracker.removeRequest(previous);
            previous.recycle();
        }

        Request request = buildRequest(target);
        target.setRequest(request);
        lifecycle.addListener(target);
        requestTracker.runRequest(request);
        return target;
    }
```
这里我们需要看看GenericRequest,有2点值得注意学习一下
```
    @Override
    public void begin() {
        startTime = LogTime.getLogTime();
        if (model == null) {
            onException(null);
            return;
        }

        status = Status.WAITING_FOR_SIZE;
        if (Util.isValidDimensions(overrideWidth, overrideHeight)) {
            onSizeReady(overrideWidth, overrideHeight);
        } else {
            target.getSize(this);
        }

        if (!isComplete() && !isFailed() && canNotifyStatusChanged()) {
            target.onLoadStarted(getPlaceholderDrawable());
        }
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logV("finished run method in " + LogTime.getElapsedMillis(startTime));
        }
    }

    @Override
    public void onSizeReady(int width, int height) {
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logV("Got onSizeReady in " + LogTime.getElapsedMillis(startTime));
        }
        if (status != Status.WAITING_FOR_SIZE) {
            return;
        }
        status = Status.RUNNING;

        width = Math.round(sizeMultiplier * width);
        height = Math.round(sizeMultiplier * height);

        ModelLoader<A, T> modelLoader = loadProvider.getModelLoader();
        final DataFetcher<T> dataFetcher = modelLoader.getResourceFetcher(model, width, height);

        if (dataFetcher == null) {
            onException(new Exception("Failed to load model: \'" + model + "\'"));
            return;
        }
        ResourceTranscoder<Z, R> transcoder = loadProvider.getTranscoder();
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logV("finished setup for calling load in " + LogTime.getElapsedMillis(startTime));
        }
        loadedFromMemoryCache = true;
        loadStatus = engine.load(signature, width, height, dataFetcher, loadProvider, transformation, transcoder,
                priority, isMemoryCacheable, diskCacheStrategy, this);
        loadedFromMemoryCache = resource != null;
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logV("finished onSizeReady in " + LogTime.getElapsedMillis(startTime));
        }
    }
```
在这个begin的方法中，我们是在 onSizeReady启动Engine，启动里面的线程池子。这个过程是一个耗时的过程，所以不需要等待将会有设置了默认图就设置默认图
```
 if (!isComplete() && !isFailed() && canNotifyStatusChanged()) {
            target.onLoadStarted(getPlaceholderDrawable());
        }
```
第一点：这个简单的处理切合了多线程的设计模式，Thread-per-Message设计
模式。多线程编程的很多时候我们需要这种思想，在耗时的工作的时候，我们可以把耗时的工作交给另一个类，而我们可以立即拿到一个返回。

第二点：和Picasso不同，glide会生成一个enginekey来寻找是否存在相同的请求。而每一次key里面也会算上图片对应的width，height。也就是说不同的宽高会被视为不同的请求而去再一次请求一次。

根据我的时序图截下来会到DecoderJob里面：
```
private Resource<T> decodeSource() throws Exception {
        Resource<T> decoded = null;
        try {
            long startTime = LogTime.getLogTime();
            final A data = fetcher.loadData(priority);
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                logWithTimeAndKey("Fetched data", startTime);
            }
            if (isCancelled) {
                return null;
            }
            decoded = decodeFromSourceData(data);
        } finally {
            fetcher.cleanup();
        }
        return decoded;
    }
```

### Glide 联网和decode
在这里，第一次看glide的人一定会遇到瓶颈，这个loadData点进去是一个接口，根本找不到在哪里实现这个方法。这个时候就要回到我最早说的地方，获取到注册在GenericLoaderFactory里面去找转化方法。

其实是在创建GenericRequest的时候创建的的一个FixedLoadProvider，所有的东西都是从里面获取的。

这里我们讨论的时候网络连接图片，当然是从String转化为InputStream，所以对应的fetcher是new StreamStringLoader.Factory()。
```
register(String.class, InputStream.class, new StreamStringLoader.Factory());

```
之后你会发现这个factory里面不断的嵌套下面这个方法
```
 buildModelLoader(Class<T> modelClass, Class<Y> resourceClass);
```
不断的在注册表里面找，最终会到达此处HttpUrlGlideUrlLoader,而fetcher.loadData(priority);中的fetcher就是通过
```
@Override
    public DataFetcher<InputStream> getResourceFetcher(GlideUrl model, int width, int height) {
        // GlideUrls memoize parsed URLs so caching them saves a few object instantiations and time spent parsing urls.
        GlideUrl url = model;
        if (modelCache != null) {
            url = modelCache.get(model, 0, 0);
            if (url == null) {
                modelCache.put(model, 0, 0, model);
                url = model;
            }
        }
        return new HttpUrlFetcher(url);
    }
```
来获取HttpUrlFetche这个转化器里面，在这里面的loadData则是联网的步骤：
```
    @Override
    public InputStream loadData(Priority priority) throws Exception {
        return loadDataWithRedirects(glideUrl.toURL(), 0 /*redirects*/, null /*lastUrl*/, glideUrl.getHeaders());
    }

    private InputStream loadDataWithRedirects(URL url, int redirects, URL lastUrl, Map<String, String> headers)
            throws IOException {
        if (redirects >= MAXIMUM_REDIRECTS) {
            throw new IOException("Too many (> " + MAXIMUM_REDIRECTS + ") redirects!");
        } else {
            // Comparing the URLs using .equals performs additional network I/O and is generally broken.
            // See http://michaelscharf.blogspot.com/2006/11/javaneturlequals-and-hashcode-make.html.
            try {
                if (lastUrl != null && url.toURI().equals(lastUrl.toURI())) {
                    throw new IOException("In re-direct loop");
                }
            } catch (URISyntaxException e) {
                // Do nothing, this is best effort.
            }
        }
        urlConnection = connectionFactory.build(url);
        for (Map.Entry<String, String> headerEntry : headers.entrySet()) {
          urlConnection.addRequestProperty(headerEntry.getKey(), headerEntry.getValue());
        }
        urlConnection.setConnectTimeout(2500);
        urlConnection.setReadTimeout(2500);
        urlConnection.setUseCaches(false);
        urlConnection.setDoInput(true);

        // Connect explicitly to avoid errors in decoders if connection fails.
        urlConnection.connect();
        if (isCancelled) {
            return null;
        }
        final int statusCode = urlConnection.getResponseCode();
        if (statusCode / 100 == 2) {
            return getStreamForSuccessfulRequest(urlConnection);
        } else if (statusCode / 100 == 3) {
            String redirectUrlString = urlConnection.getHeaderField("Location");
            if (TextUtils.isEmpty(redirectUrlString)) {
                throw new IOException("Received empty or null redirect url");
            }
            URL redirectUrl = new URL(url, redirectUrlString);
            return loadDataWithRedirects(redirectUrl, redirects + 1, url, headers);
        } else {
            if (statusCode == -1) {
                throw new IOException("Unable to retrieve response code from HttpUrlConnection.");
            }
            throw new IOException("Request failed " + statusCode + ": " + urlConnection.getResponseMessage());
        }
    }


    private InputStream getStreamForSuccessfulRequest(HttpURLConnection urlConnection)
            throws IOException {
        if (TextUtils.isEmpty(urlConnection.getContentEncoding())) {
            int contentLength = urlConnection.getContentLength();
            stream = ContentLengthInputStream.obtain(urlConnection.getInputStream(), contentLength);
        } else {
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Got non empty content encoding: " + urlConnection.getContentEncoding());
            }
            stream = urlConnection.getInputStream();
        }
        return stream;
    }
```
这样就从String转化为InputStream。

拿到我们读的数据流，接下来就要做解析的事情的了，根据上面的时序图，接下来会走到下面：
```
    private Resource<T> decodeFromSourceData(A data) throws IOException {
        final Resource<T> decoded;
        if (diskCacheStrategy.cacheSource()) {
            decoded = cacheAndDecodeSourceData(data);
        } else {
            long startTime = LogTime.getLogTime();
            decoded = loadProvider.getSourceDecoder().decode(data, width, height);
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                logWithTimeAndKey("Decoded from source", startTime);
            }
        }
        return decoded;
    }
```
如果们没有设定缓存模式，默认是缓存了Result，而不缓存source,那一定会走到下面这个decode方法。
这个decode方法也是接口方法之一，也是通过上面的注册表去寻找对应的实现类。最初找到的是这个类，最后你会发现getDecode里面不断的嵌套这更加基础的类
```
 ImageVideoDataLoadProvider imageVideoDataLoadProvider =
                new ImageVideoDataLoadProvider(streamBitmapLoadProvider, fileDescriptorLoadProvider);
        dataLoadProviderRegistry.register(ImageVideoWrapper.class, Bitmap.class, imageVideoDataLoadProvider);
```
最后达到StreamBitmapDataLoadProvider，这个数据解析容器就提供了把Inputstream转化到bitmap里面。这里面的Decoder里面会调用Downsampler，真正的进行解析。
```
   public Bitmap decode(InputStream is, BitmapPool pool, int outWidth, int outHeight, DecodeFormat decodeFormat) {
        final ByteArrayPool byteArrayPool = ByteArrayPool.get();
        final byte[] bytesForOptions = byteArrayPool.getBytes();
        final byte[] bytesForStream = byteArrayPool.getBytes();
        final BitmapFactory.Options options = getDefaultOptions();

        // Use to fix the mark limit to avoid allocating buffers that fit entire images.
        RecyclableBufferedInputStream bufferedStream = new RecyclableBufferedInputStream(
                is, bytesForStream);
        // Use to retrieve exceptions thrown while reading.
        // TODO(#126): when the framework no longer returns partially decoded Bitmaps or provides a way to determine
        // if a Bitmap is partially decoded, consider removing.
        ExceptionCatchingInputStream exceptionStream =
                ExceptionCatchingInputStream.obtain(bufferedStream);
        // Use to read data.
        // Ensures that we can always reset after reading an image header so that we can still attempt to decode the
        // full image even when the header decode fails and/or overflows our read buffer. See #283.
        MarkEnforcingInputStream invalidatingStream = new MarkEnforcingInputStream(exceptionStream);
        try {
            exceptionStream.mark(MARK_POSITION);
            int orientation = 0;
            try {
                orientation = new ImageHeaderParser(exceptionStream).getOrientation();
            } catch (IOException e) {
                if (Log.isLoggable(TAG, Log.WARN)) {
                    Log.w(TAG, "Cannot determine the image orientation from header", e);
                }
            } finally {
                try {
                    exceptionStream.reset();
                } catch (IOException e) {
                    if (Log.isLoggable(TAG, Log.WARN)) {
                        Log.w(TAG, "Cannot reset the input stream", e);
                    }
                }
            }

            options.inTempStorage = bytesForOptions;

            final int[] inDimens = getDimensions(invalidatingStream, bufferedStream, options);
            final int inWidth = inDimens[0];
            final int inHeight = inDimens[1];

            final int degreesToRotate = TransformationUtils.getExifOrientationDegrees(orientation);
            final int sampleSize = getRoundedSampleSize(degreesToRotate, inWidth, inHeight, outWidth, outHeight);

            final Bitmap downsampled =
                    downsampleWithSize(invalidatingStream, bufferedStream, options, pool, inWidth, inHeight, sampleSize,
                            decodeFormat);

            // BitmapFactory swallows exceptions during decodes and in some cases when inBitmap is non null, may catch
            // and log a stack trace but still return a non null bitmap. To avoid displaying partially decoded bitmaps,
            // we catch exceptions reading from the stream in our ExceptionCatchingInputStream and throw them here.
            final Exception streamException = exceptionStream.getException();
            if (streamException != null) {
                throw new RuntimeException(streamException);
            }

            Bitmap rotated = null;
            if (downsampled != null) {
                rotated = TransformationUtils.rotateImageExif(downsampled, pool, orientation);

                if (!downsampled.equals(rotated) && !pool.put(downsampled)) {
                    downsampled.recycle();
                }
            }

            return rotated;
        } finally {
            byteArrayPool.releaseBytes(bytesForOptions);
            byteArrayPool.releaseBytes(bytesForStream);
            exceptionStream.release();
            releaseOptions(options);
        }
    }
```
至于里面做了什么请容我稍后和Picasso一起说明。现在只需要明白是通过获取到inputstream，在BitmapFactory.decodeStream解析成为Bitmap的。

### Glide 转化和回调
接着根据我的时序图，可以清楚的知道到了decodeJob里面转化为我们需要的Resource
```
private Resource<Z> transformEncodeAndTranscode(Resource<T> decoded) {
        long startTime = LogTime.getLogTime();
        Resource<T> transformed = transform(decoded);
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logWithTimeAndKey("Transformed resource from source", startTime);
        }

        writeTransformedToCache(transformed);

        startTime = LogTime.getLogTime();
        Resource<Z> result = transcode(transformed);
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logWithTimeAndKey("Transcoded transformed from source", startTime);
        }
        return result;
    }
```
最后在EngineRunnable方法的run里面进行回调，到了EngineJob里面通过MainHandler进行异步，刷新UI
```
   public void onResourceReady(final Resource<?> resource) {
        this.resource = resource;
        MAIN_THREAD_HANDLER.obtainMessage(MSG_COMPLETE, this).sendToTarget();
    }

    private void handleResultOnMainThread() {
        if (isCancelled) {
            resource.recycle();
            return;
        } else if (cbs.isEmpty()) {
            throw new IllegalStateException("Received a resource without any callbacks to notify");
        }
        engineResource = engineResourceFactory.build(resource, isCacheable);
        hasResource = true;

        // Hold on to resource for duration of request so we don't recycle it in the middle of notifying if it
        // synchronously released by one of the callbacks.
        engineResource.acquire();
        listener.onEngineJobComplete(key, engineResource);

        for (ResourceCallback cb : cbs) {
            if (!isInIgnoredCallbacks(cb)) {
                engineResource.acquire();
                cb.onResourceReady(engineResource);
            }
        }
        // Our request is complete, so we can release the resource.
        engineResource.release();
    }
```
这里画一张图来作为理解：

![Glide联网与解码.png](/images/Glide责任流程图.png)


到这里Glide的图片加载就完成了。就这点东西？不可能，只有这点东西还不值得我来写文章，毕竟很多人都写过了。先来看看Picasso。

# Picasso
我这边还是以网络加载图片为例子来学习Picasso的源码。先上时序图
![Picasso时序图.jpg](/images/Picasso时序图.jpg)

先看看Picasso的用法:
```
Picasso.with(this).load("url").into(imageview);
```
看起来和Glide一模一样，所以经常很多人拿出来和Glide做比对。
我先开始他的源码学习之旅，比起看起来头痛欲裂重量级别的Glide，Picasso看起来舒服很多。
在这里我先归纳出几个重要的角色，在整个Picasso网络加载图片的流程中。

###Picasso 各个职能

![Picasso主要职能角色.png](/images/Picasso主要职能角色.png)


1.Request 是一次请求，每一次动作开始之前，我们要声明一个请求，设置好对应的资源号，uri等参数。

2.Action 这个是指一次动作。比如说当我们加载图片到ImageView的时候，就会声明一个ImageViewAction，初始化一次动作，每一个动作都会包含一个请求。

3.Dispatcher 是一个分发器。这个分发器的作用如果看过okhttp的源码，你会发现两者之间的思路十分相近。这个分发器是处理各种不同状态的Action，如REQUEST_SUBMIT 网络请求状态，HUNTER_COMPLETE 图片解析完成状态等。

4.ResourceRequestHandler 资源请求处理器。这个和okhttp的拦截器实现起来有点相似都是加入到一个不变的list中，但是实际上不同，每一次判断都会从这个list中轮询其中的处理器，通过canHandleRequest来判断是符合当前请求的情况。

5.BitmapHunter 里面实现了Runnable方法，通过PicassoExecutorService线程池启动其中的run方法，无论是联网还是解析数据都在这里面，可以说这个是Picasso的核心方法。

### Picasso with
好了重要角色也差不多了，从with开始，一边分析分析Picasso的源码，一边比较Glide之间的异同。
```
  public static Picasso with(Context context) {
    if (singleton == null) {
      synchronized (Picasso.class) {
        if (singleton == null) {
          singleton = new Builder(context).build();
        }
      }
    }
    return singleton;
  }


```
这个with很简单，比起Glide来说，简单了很多了。Picasso在with的过程中，仅仅只是通过单例获取Picasso的对象以及获取分发器，缓存，线程等对象，而Glide则是绑定了一个隐形的fragment监听整个生命周期。值得注意的是，Picasso在构造器中注册好了各种类型的ResourceRequestHandler 资源请求处理器，这点和Glide十分相似。
```
public Picasso build() {
      Context context = this.context;

      if (downloader == null) {
        downloader = Utils.createDefaultDownloader(context);
      }
      if (cache == null) {
        cache = new LruCache(context);
      }
      if (service == null) {
        service = new PicassoExecutorService();
      }
      if (transformer == null) {
        transformer = RequestTransformer.IDENTITY;
      }

      Stats stats = new Stats(cache);

      Dispatcher dispatcher = new Dispatcher(context, service, HANDLER, downloader, cache, stats);

      return new Picasso(context, dispatcher, cache, listener, transformer, requestHandlers, stats,
          defaultBitmapConfig, indicatorsEnabled, loggingEnabled);
    }

Picasso(Context context, Dispatcher dispatcher, Cache cache, Listener listener,
      RequestTransformer requestTransformer, List<RequestHandler> extraRequestHandlers, Stats stats,
      Bitmap.Config defaultBitmapConfig, boolean indicatorsEnabled, boolean loggingEnabled) {
    this.context = context;
    this.dispatcher = dispatcher;
    this.cache = cache;
    this.listener = listener;
    this.requestTransformer = requestTransformer;
    this.defaultBitmapConfig = defaultBitmapConfig;

    int builtInHandlers = 7; // Adjust this as internal handlers are added or removed.
    int extraCount = (extraRequestHandlers != null ? extraRequestHandlers.size() : 0);
    List<RequestHandler> allRequestHandlers =
        new ArrayList<RequestHandler>(builtInHandlers + extraCount);

    // ResourceRequestHandler needs to be the first in the list to avoid
    // forcing other RequestHandlers to perform null checks on request.uri
    // to cover the (request.resourceId != 0) case.
    allRequestHandlers.add(new ResourceRequestHandler(context));
    if (extraRequestHandlers != null) {
      allRequestHandlers.addAll(extraRequestHandlers);
    }
    allRequestHandlers.add(new ContactsPhotoRequestHandler(context));
    allRequestHandlers.add(new MediaStoreRequestHandler(context));
    allRequestHandlers.add(new ContentStreamRequestHandler(context));
    allRequestHandlers.add(new AssetRequestHandler(context));
    allRequestHandlers.add(new FileRequestHandler(context));
    allRequestHandlers.add(new NetworkRequestHandler(dispatcher.downloader, stats));
    requestHandlers = Collections.unmodifiableList(allRequestHandlers);

   ...
  }
```

### Picasso load
再看看load的方法,这个方法创建一个Request.Builder，用于以后创建Request请求
```
  public RequestCreator load(String path) {
    if (path == null) {
      return new RequestCreator(this, null, 0);
    }
    if (path.trim().length() == 0) {
      throw new IllegalArgumentException("Path must not be empty.");
    }
    return load(Uri.parse(path));
  }
```
```
  RequestCreator(Picasso picasso, Uri uri, int resourceId) {
    if (picasso.shutdown) {
      throw new IllegalStateException(
          "Picasso instance already shut down. Cannot submit new requests.");
    }
    this.picasso = picasso;
    this.data = new Request.Builder(uri, resourceId, picasso.defaultBitmapConfig);
  }

  @TestOnly RequestCreator() {
    this.picasso = null;
    this.data = new Request.Builder(null, 0, null);
  }
```
picasso的load方法确实简单很多，看来很多逻辑都放在了into之后的步骤。而glide在load的步骤会声明一个GenericRequest，一个FixDataProvider。而这个FixDataProvider在声明的时候，就把需要的数据解析容器全部筛选出来。

### Picasso into
接下来再看看Picasso的into方法
```
 public void into(ImageView target, Callback callback) {
    long started = System.nanoTime();
    checkMain();

    if (target == null) {
      throw new IllegalArgumentException("Target must not be null.");
    }

    if (!data.hasImage()) {
      picasso.cancelRequest(target);
      if (setPlaceholder) {
        setPlaceholder(target, getPlaceholderDrawable());
      }
      return;
    }

    if (deferred) {
      if (data.hasSize()) {
        throw new IllegalStateException("Fit cannot be used with resize.");
      }
      int width = target.getWidth();
      int height = target.getHeight();
      if (width == 0 || height == 0) {
        if (setPlaceholder) {
          setPlaceholder(target, getPlaceholderDrawable());
        }
        picasso.defer(target, new DeferredRequestCreator(this, target, callback));
        return;
      }
      data.resize(width, height);
    }

    Request request = createRequest(started);
    String requestKey = createKey(request);

    if (shouldReadFromMemoryCache(memoryPolicy)) {
      Bitmap bitmap = picasso.quickMemoryCacheCheck(requestKey);
      if (bitmap != null) {
        picasso.cancelRequest(target);
        setBitmap(target, picasso.context, bitmap, MEMORY, noFade, picasso.indicatorsEnabled);
        if (picasso.loggingEnabled) {
          log(OWNER_MAIN, VERB_COMPLETED, request.plainId(), "from " + MEMORY);
        }
        if (callback != null) {
          callback.onSuccess();
        }
        return;
      }
    }

    if (setPlaceholder) {
      setPlaceholder(target, getPlaceholderDrawable());
    }

    Action action =
        new ImageViewAction(picasso, target, request, memoryPolicy, networkPolicy, errorResId,
            errorDrawable, requestKey, tag, callback, noFade);

    picasso.enqueueAndSubmit(action);
  }
```
在这个into的方法中，Picasso做了如下的处理，创建一个Request，以及一个key。如果设置了memoryPolicy，就用来比较LruCache中是否存在对应的key。

接着就设置一个占位图，创建一个action，以及把动作丢给Dispatcher分发器，让它通过调用handler启动线程池去处理这个动作。

###Picasso 联网和decode
根据时序图，很容易知道接下来会到达Dispatcher的performSubmit
```
  void performSubmit(Action action, boolean dismissFailed) {
...
    BitmapHunter hunter = hunterMap.get(action.getKey());
    if (hunter != null) {
      hunter.attach(action);
      return;
    }

    if (service.isShutdown()) {
      if (action.getPicasso().loggingEnabled) {
        log(OWNER_DISPATCHER, VERB_IGNORED, action.request.logId(), "because shut down");
      }
      return;
    }

    hunter = forRequest(action.getPicasso(), this, cache, stats, action);
    hunter.future = service.submit(hunter);
    hunterMap.put(action.getKey(), hunter);

...
```
在这里有俩个行为需要特别注意:
```
    hunter = forRequest(action.getPicasso(), this, cache, stats, action);
    hunter.future = service.submit(hunter);
```
1.通过动作创建一个BitmapHunter
2.启动线程池子

在第一个方法中
```
  static BitmapHunter forRequest(Picasso picasso, Dispatcher dispatcher, Cache cache, Stats stats,
      Action action) {
    Request request = action.getRequest();
    List<RequestHandler> requestHandlers = picasso.getRequestHandlers();

    // Index-based loop to avoid allocating an iterator.
    //noinspection ForLoopReplaceableByForEach
    for (int i = 0, count = requestHandlers.size(); i < count; i++) {
      RequestHandler requestHandler = requestHandlers.get(i);
      if (requestHandler.canHandleRequest(request)) {
        return new BitmapHunter(picasso, dispatcher, cache, stats, action, requestHandler);
      }
    }

    return new BitmapHunter(picasso, dispatcher, cache, stats, action, ERRORING_HANDLER);
  }
```
通过了canHandleRequest来筛选出对应的资源处理器。我们先挑出来NetworkRequestHandler看看该方法
```
  private static final String SCHEME_HTTP = "http";
  private static final String SCHEME_HTTPS = "https";

  @Override public boolean canHandleRequest(Request data) {
    String scheme = data.uri.getScheme();
    return (SCHEME_HTTP.equals(scheme) || SCHEME_HTTPS.equals(scheme));
  }
```

这个是对传进来的String进行uri的判断。来筛选出合适的资源处理器。

第二个方法，则是启动了线程池子
接下来我们看看在BitmapHunter中的run方法。而这个run方法又会调用hunt
```
Bitmap hunt() throws IOException {
    Bitmap bitmap = null;

...

    data.networkPolicy = retryCount == 0 ? NetworkPolicy.OFFLINE.index : networkPolicy;
//调用NetworkRequestHandler的load联网
    RequestHandler.Result result = requestHandler.load(data, networkPolicy);
    if (result != null) {
      loadedFrom = result.getLoadedFrom();
      exifRotation = result.getExifOrientation();

      bitmap = result.getBitmap();

      // If there was no Bitmap then we need to decode it from the stream.
      if (bitmap == null) {
        InputStream is = result.getStream();
        try {
//解析bitmap
          bitmap = decodeStream(is, data);
        } finally {
          Utils.closeQuietly(is);
        }
      }
    }

    if (bitmap != null) {
      if (picasso.loggingEnabled) {
        log(OWNER_HUNTER, VERB_DECODED, data.logId());
      }
      stats.dispatchBitmapDecoded(bitmap);
      if (data.needsTransformation() || exifRotation != 0) {
        synchronized (DECODE_LOCK) {
          if (data.needsMatrixTransform() || exifRotation != 0) {
            bitmap = transformResult(data, bitmap, exifRotation);
            if (picasso.loggingEnabled) {
              log(OWNER_HUNTER, VERB_TRANSFORMED, data.logId());
            }
          }
          if (data.hasCustomTransformations()) {
            bitmap = applyCustomTransformations(data.transformations, bitmap);
            if (picasso.loggingEnabled) {
              log(OWNER_HUNTER, VERB_TRANSFORMED, data.logId(), "from custom transformations");
            }
          }
        }
        if (bitmap != null) {
          stats.dispatchBitmapTransformed(bitmap);
        }
      }
    }

    return bitmap;
  }
```
关键的两句话已经标记出来了，一个是通过NetworkRequestHandler的load方法联网获取inputstream，一个是通过decodeStream解析成bitmap。
我们发现load方法最后会
```
downloader.load(request.uri, request.networkPolicy);
```
而这个Downloader是在构造器时候初始化的，会优先获取okhttp，没有则调用UrlConnectionDownloader。:
```
  static Downloader createDefaultDownloader(Context context) {
    try {
      Class.forName("com.squareup.okhttp.OkHttpClient");
      return OkHttpLoaderCreator.create(context);
    } catch (ClassNotFoundException ignored) {
    }
    return new UrlConnectionDownloader(context);
  }
```
当然，调用okhttp会更好，毕竟okhttp在网络连接上更加的完善，除了几乎一系列的200，304，307等行为。这里我们先看看UrlConnectionDownloader的load方法
```
  @Override public Response load(Uri uri, int networkPolicy) throws IOException {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.ICE_CREAM_SANDWICH) {
      installCacheIfNeeded(context);
    }

    HttpURLConnection connection = openConnection(uri);
    connection.setUseCaches(true);

    if (networkPolicy != 0) {
      String headerValue;

      if (NetworkPolicy.isOfflineOnly(networkPolicy)) {
        headerValue = FORCE_CACHE;
      } else {
        StringBuilder builder = CACHE_HEADER_BUILDER.get();
        builder.setLength(0);

        if (!NetworkPolicy.shouldReadFromDiskCache(networkPolicy)) {
          builder.append("no-cache");
        }
        if (!NetworkPolicy.shouldWriteToDiskCache(networkPolicy)) {
          if (builder.length() > 0) {
            builder.append(',');
          }
          builder.append("no-store");
        }

        headerValue = builder.toString();
      }

      connection.setRequestProperty("Cache-Control", headerValue);
    }

    int responseCode = connection.getResponseCode();
    if (responseCode >= 300) {
      connection.disconnect();
      throw new ResponseException(responseCode + " " + connection.getResponseMessage(),
          networkPolicy, responseCode);
    }

    long contentLength = connection.getHeaderFieldInt("Content-Length", -1);
    boolean fromCache = parseResponseSourceHeader(connection.getHeaderField(RESPONSE_SOURCE));

    return new Response(connection.getInputStream(), fromCache, contentLength);
  }
```

从这里我们看出这两者处理十分相似。Picasso和Glide一样都是对之前设置设置好的模式都加入到了头里面进行请求。但是接下来就出现了分歧，在Picasso中会获取返回的数据解析头，来判断下一步究竟是要从磁盘中读取还是从流中读取。而glide则是完完全全按照配置来获取流，比如在这一段中，Picasso并没有解析头，而是直接把流传给了下一步。


接下来再看看Picasso对图片的解析
```
  static Bitmap decodeStream(InputStream stream, Request request) throws IOException {
    MarkableInputStream markStream = new MarkableInputStream(stream);
    stream = markStream;

    long mark = markStream.savePosition(65536); // TODO fix this crap.

    final BitmapFactory.Options options = RequestHandler.createBitmapOptions(request);
    final boolean calculateSize = RequestHandler.requiresInSampleSize(options);

    boolean isWebPFile = Utils.isWebPFile(stream);
    markStream.reset(mark);
    // When decode WebP network stream, BitmapFactory throw JNI Exception and make app crash.
    // Decode byte array instead
    if (isWebPFile) {
      byte[] bytes = Utils.toByteArray(stream);
      if (calculateSize) {
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        RequestHandler.calculateInSampleSize(request.targetWidth, request.targetHeight, options,
            request);
      }
      return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
    } else {
      if (calculateSize) {
        BitmapFactory.decodeStream(stream, null, options);
        RequestHandler.calculateInSampleSize(request.targetWidth, request.targetHeight, options,
            request);

        markStream.reset(mark);
      }
      Bitmap bitmap = BitmapFactory.decodeStream(stream, null, options);
      if (bitmap == null) {
        // Treat null as an IO exception, we will eventually retry.
        throw new IOException("Failed to decode stream.");
      }
      return bitmap;
    }
  }
```
在这里我们可以清楚：
Picasso支持解析WebP格式的图片，这种图片比起常用的png，jpeg来说更小，更省流量，加载更快。而Glide虽然并没有支持WebP但是却支持jpeg，png，gif这几种格式。

### Picasso回调和异步刷新UI
根据我的时序图，可以清晰的明白接下来会通过performComplete调用
```
private void batch(BitmapHunter hunter) {
    if (hunter.isCancelled()) {
      return;
    }
    batch.add(hunter);
    if (!handler.hasMessages(HUNTER_DELAY_NEXT_BATCH)) {
      handler.sendEmptyMessageDelayed(HUNTER_DELAY_NEXT_BATCH, BATCH_DELAY);
    }
  }
```

这里由通过Dispatcher 的Handler调用声明在主线程的mainThreadHandler
```
 void performBatchComplete() {
    List<BitmapHunter> copy = new ArrayList<BitmapHunter>(batch);
    batch.clear();
    mainThreadHandler.sendMessage(mainThreadHandler.obtainMessage(HUNTER_BATCH_COMPLETE, copy));
    logBatch(copy);
  }
```
通过主线程调用deliverAction
```
  private void deliverAction(Bitmap result, LoadedFrom from, Action action) {
    if (action.isCancelled()) {
      return;
    }
    if (!action.willReplay()) {
      targetToAction.remove(action.getTarget());
    }
    if (result != null) {
      if (from == null) {
        throw new AssertionError("LoadedFrom cannot be null.");
      }
      action.complete(result, from);
      if (loggingEnabled) {
        log(OWNER_MAIN, VERB_COMPLETED, action.request.logId(), "from " + from);
      }
    } else {
      action.error();
      if (loggingEnabled) {
        log(OWNER_MAIN, VERB_ERRORED, action.request.logId());
      }
    }
  }
```
我们回去看看ImageViewAction的complete方法。
```
  @Override public void complete(Bitmap result, Picasso.LoadedFrom from) {
    if (result == null) {
      throw new AssertionError(
          String.format("Attempted to complete action with no result!\n%s", this));
    }

    ImageView target = this.target.get();
    if (target == null) {
      return;
    }

    Context context = picasso.context;
    boolean indicatorsEnabled = picasso.indicatorsEnabled;
    PicassoDrawable.setBitmap(target, context, result, from, noFade, indicatorsEnabled);

    if (callback != null) {
      callback.onSuccess();
    }
  }
```
这样就把图片刷到了ImageView。至此就把Glide和Picasso的网络加载流程全部解释结束。

这里同样给一张图，作为总结理解：
![Picasso联网与解码.png](/images/Picasso联网与解码.png)



###Picasso和Glide异同

在这里我针对网上指出的Picasso和Glide比较的博文里面做一下解析，他们经过测试上比较了双方的异同。请原谅我，直接借用他们的文章抛砖引玉。

https://www.jianshu.com/p/fc72001dc18d
http://blog.csdn.net/qq_35166847/article/details/51814409

抛开相同的问题，我们通过现象对这些现象做解答。

异同1:Glide加载图片后占用的内存比Picasso占用少。
异同2:Glide的加载速度比Picasso慢。
异同3:Glide加载的图片一般比Picasso的质量差点。
这就要自己看看之前Glide是如何decode整个bitmap的。
我们翻上去看看decode的方法。
```
public Bitmap decode(InputStream is, BitmapPool pool, int outWidth, int outHeight, DecodeFormat decodeFormat) {
        final ByteArrayPool byteArrayPool = ByteArrayPool.get();
        final byte[] bytesForOptions = byteArrayPool.getBytes();
        final byte[] bytesForStream = byteArrayPool.getBytes();
        final BitmapFactory.Options options = getDefaultOptions();

// Use to fix the mark limit to avoid allocating buffers that fit entire images.
        RecyclableBufferedInputStream bufferedStream = new RecyclableBufferedInputStream(
                is, bytesForStream);
        // Use to retrieve exceptions thrown while reading.
        // TODO(#126): when the framework no longer returns partially decoded Bitmaps or provides a way to determine
        // if a Bitmap is partially decoded, consider removing.
        ExceptionCatchingInputStream exceptionStream =
                ExceptionCatchingInputStream.obtain(bufferedStream);
        // Use to read data.
        // Ensures that we can always reset after reading an image header so that we can still attempt to decode the
        // full image even when the header decode fails and/or overflows our read buffer. See #283.
        MarkEnforcingInputStream invalidatingStream = new MarkEnforcingInputStream(exceptionStream);
try {

        options.inTempStorage = bytesForOptions;
        final int[] inDimens = getDimensions(invalidatingStream, bufferedStream, options);
            final int inWidth = inDimens[0];
            final int inHeight = inDimens[1];
...

final Bitmap downsampled =
                    downsampleWithSize(invalidatingStream, bufferedStream, options, pool, inWidth, inHeight, sampleSize,
                            decodeFormat);

...

 Bitmap rotated = null;
            if (downsampled != null) {
                rotated = TransformationUtils.rotateImageExif(downsampled, pool, orientation);

                if (!downsampled.equals(rotated) && !pool.put(downsampled)) {
                    downsampled.recycle();
                }
            }

            return rotated;
          
        } finally {
            byteArrayPool.releaseBytes(bytesForOptions);
            byteArrayPool.releaseBytes(bytesForStream);
            exceptionStream.release();
            releaseOptions(options);
        }
}
```
Picasso是如何解析的呢？先声明一个MarkableInputStream，这个MarkableInputStream限制了图片解析时候将会占用65536的内存，而超过的时候会报错，这个是2.5.2的bug，而在2.5.2.4b中（网上说不是官方版本），则是做了和Glide一样的处理。
Glide 也是自己实现了FliterInputStream：RecyclableBufferedInputStream。这个stream最高限制了5M的大小，初始的时候给了bytesForStream的大小。而这个byte数组是一个长度为1的双端队列。
```
// 64 KB.
    private static final int TEMP_BYTES_SIZE = 64 * 1024;
    /**
     * Returns a byte array by retrieving one from the pool if the pool is non empty or otherwise by creating a new
     * byte array.
     */
    public byte[] getBytes() {
        byte[] result;
        synchronized (tempQueue) {
            result = tempQueue.poll();
        }
        if (result == null) {
            result = new byte[TEMP_BYTES_SIZE];
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Created temp bytes");
            }
        }
        return result;
    }
```
从上面知道我们将会获得一个初始的64kb大小的缓冲区。而这个缓冲区很明显对于加载大图片时候不够用。但是别忘了Glide是读了5遍图片数据流。读取第一次的的时候这个inputstream，每一次读到了极限值的时候，发现没有读完，将会把整个读取极限扩容*2，最后一定足够读完整个流。就是下面这个方法。
```
    private int fillbuf(InputStream localIn, byte[] localBuf)
            throws IOException {
        if (markpos == -1 || pos - markpos >= marklimit) {
            // Mark position not set or exceeded readlimit
            int result = localIn.read(localBuf);
            if (result > 0) {
                markpos = -1;
                pos = 0;
                count = result;
            }
            return result;
        }
        // Added count == localBuf.length so that we do not immediately double the buffer size before reading any data
        // when marklimit > localBuf.length. Instead, we will double the buffer size only after reading the initial
        // localBuf worth of data without finding what we're looking for in the stream. This allows us to set a
        // relatively small initial buffer size and a large marklimit for safety without causing an allocation each time
        // read is called.
        if (markpos == 0 && marklimit > localBuf.length && count == localBuf.length) {
            // Increase buffer size to accommodate the readlimit
            int newLength = localBuf.length * 2;
            if (newLength > marklimit) {
                newLength = marklimit;
            }
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "allocate buffer of length: " + newLength);
            }
            byte[] newbuf = new byte[newLength];
            System.arraycopy(localBuf, 0, newbuf, 0, localBuf.length);
            // Reassign buf, which will invalidate any local references
            // FIXME: what if buf was null?
            localBuf = buf = newbuf;
        } else if (markpos > 0) {
            System.arraycopy(localBuf, markpos, localBuf, 0, localBuf.length
                    - markpos);
        }
        // Set the new position and mark position
        pos -= markpos;
        count = markpos = 0;
        int bytesread = localIn.read(localBuf, pos, localBuf.length - pos);
        count = bytesread <= 0 ? pos : pos + bytesread;
        return bytesread;
    }
```
而Picasso之后也做了相似的处理，也是重写了read方法，不断的扩容读取极限。
我刚才说的5遍读取数据流又是哪5次呢？这里指出来：

1.获取jpeg图片的信息头exif，这里设计很精妙，每一次读1个字节，一遍解析，一遍获取到自己想要信息。只是调用了数次的inputstream.read()方法。根本不需要读完整个流，加快了获取速度。
```
orientation = new ImageHeaderParser(exceptionStream).getOrientation();
```

2.获取图片的宽高，但是这个时候设置了options.inJustDecodeBounds = true;图片压根没有存到内存里面，仅仅只是获取了图片一些options。
```
final int[] inDimens = getDimensions(invalidatingStream, bufferedStream, options);
            final int inWidth = inDimens[0];
            final int inHeight = inDimens[1];
```

3.根据宽高创建出原始的Bitmap
```
final Bitmap downsampled =
                    downsampleWithSize(invalidatingStream, bufferedStream, options, pool, inWidth, inHeight, sampleSize,
                            decodeFormat);
```

4.是在第三点的时候，判断图片类型，再读了一次头信息


5.根据绘画出来的图片通过画布根据放置方向，方正再一次绘画一次。
```
 Bitmap rotated = null;
            if (downsampled != null) {
                rotated = TransformationUtils.rotateImageExif(downsampled, pool, orientation);

                if (!downsampled.equals(rotated) && !pool.put(downsampled)) {
                    downsampled.recycle();
                }
            }
```
这个即是我们最终所得的图片。

那上面的异同点也可以解释了为什么Glide显示的比Picasso慢，主要因为Glide读了5次流，绘画了2次bitmp，而Picasso只是读了一次流，绘画了一次bitmap。

为什么Glide占用的内存比Picasso小，为什么Glide一般情况下显示的比Picasso的图片质量差：
主要是由三点点；
1.上述代码可以知道，我们的缓冲区是循环使用的，而Picasso是每一次声明一个缓冲区进行读取流。
2.且看下面的代码
```
    private Bitmap downsampleWithSize(MarkEnforcingInputStream is, RecyclableBufferedInputStream  bufferedStream,
            BitmapFactory.Options options, BitmapPool pool, int inWidth, int inHeight, int sampleSize,
            DecodeFormat decodeFormat) {
        // Prior to KitKat, the inBitmap size must exactly match the size of the bitmap we're decoding.
        Bitmap.Config config = getConfig(is, decodeFormat);
        options.inSampleSize = sampleSize;
        options.inPreferredConfig = config;
        if ((options.inSampleSize == 1 || Build.VERSION_CODES.KITKAT <= Build.VERSION.SDK_INT) && shouldUsePool(is)) {
            int targetWidth = (int) Math.ceil(inWidth / (double) sampleSize);
            int targetHeight = (int) Math.ceil(inHeight / (double) sampleSize);
            // BitmapFactory will clear out the Bitmap before writing to it, so getDirty is safe.
            setInBitmap(options, pool.getDirty(targetWidth, targetHeight, config));
        }
        return decodeStream(is, bufferedStream, options);
    }
    @TargetApi(Build.VERSION_CODES.HONEYCOMB)
    private static void setInBitmap(BitmapFactory.Options options, Bitmap recycled) {
        if (Build.VERSION_CODES.HONEYCOMB <= Build.VERSION.SDK_INT) {
            options.inBitmap = recycled;
        }
    }
```
在这里做了options.inBitmap = recycled;的处理，在这里他在options设置了一个复用的Bitmap作为返回的结果bitmap，而这个bitmap复用了LruBitmapPool中规格相同的bitmap，比起Picasso又一次的节约了内存，而越是加载更多的图片，双方之间的内存差越大。

3.在计算SimpleSize采样率上双方采取的策略不一致：
先看看Glide：
```
private int getRoundedSampleSize(int degreesToRotate, int inWidth, int inHeight, int outWidth, int outHeight) {
        int targetHeight = outHeight == Target.SIZE_ORIGINAL ? inHeight : outHeight;
        int targetWidth = outWidth == Target.SIZE_ORIGINAL ? inWidth : outWidth;

        final int exactSampleSize;
        if (degreesToRotate == 90 || degreesToRotate == 270) {
            // If we're rotating the image +-90 degrees, we need to downsample accordingly so the image width is
            // decreased to near our target's height and the image height is decreased to near our target width.
            //noinspection SuspiciousNameCombination
            exactSampleSize = getSampleSize(inHeight, inWidth, targetWidth, targetHeight);
        } else {
            exactSampleSize = getSampleSize(inWidth, inHeight, targetWidth, targetHeight);
        }

/**
     * Load and scale the image uniformly (maintaining the image's aspect ratio) so that the smallest edge of the
     * image will be between 1x and 2x the requested size. The larger edge has no maximum size.
     */
    public static final Downsampler AT_LEAST = new Downsampler() {
        @Override
        protected int getSampleSize(int inWidth, int inHeight, int outWidth, int outHeight) {
            return Math.min(inHeight / outHeight, inWidth / outWidth);
        }

        @Override
        public String getId() {
            return "AT_LEAST.com.bumptech.glide.load.data.bitmap";
        }
    };

        // BitmapFactory only accepts powers of 2, so it will round down to the nearest power of two that is less than
        // or equal to the sample size we provide. Because we need to estimate the final image width and height to
        // re-use Bitmaps, we mirror BitmapFactory's calculation here. For bug, see issue #224. For algorithm see
        // http://stackoverflow.com/a/17379704/800716.
        final int powerOfTwoSampleSize = exactSampleSize == 0 ? 0 : Integer.highestOneBit(exactSampleSize);

        // Although functionally equivalent to 0 for BitmapFactory, 1 is a safer default for our code than 0.
        return Math.max(1, powerOfTwoSampleSize);
    }

public static final Downsampler AT_MOST = new Downsampler() {
        @Override
        protected int getSampleSize(int inWidth, int inHeight, int outWidth, int outHeight) {
            int maxIntegerFactor = (int) Math.ceil(Math.max(inHeight / (float) outHeight,
                inWidth / (float) outWidth));
            int lesserOrEqualSampleSize = Math.max(1, Integer.highestOneBit(maxIntegerFactor));
            return lesserOrEqualSampleSize << (lesserOrEqualSampleSize < maxIntegerFactor ? 1 : 0);
        }

        @Override
        public String getId() {
            return "AT_MOST.com.bumptech.glide.load.data.bitmap";
        }
    };
```
Glide有两种采样率计算模式，
默认是第一种AT_LEAST，加载的宽比上实际宽和要加载的高比两者之间去最小，这样能保证在1-2倍。
第二种就特殊一点，这里我们可以通过计算得知，Glide是通过要加载的宽比上实际宽和要加载的高比上实际高，去最大并且向上取整，并且去最高位后面极为全部置0.这样做的好处，你总会获取比起到比1倍小，比1/2倍大的数字，这样就限制采样率下限。而outHeight为0的情况不存在的，默认为Integer.MIN_VALUE在Target里面初始化好的默认值，而为0的时候，在onSizeReady就结束了。而为什么只取最高位呢？是因为系统也是这么做，SimpleSize不为2的次幂时候会取成最近的2次幂的采样率。

让我们看看Picasso
```
static void calculateInSampleSize(int reqWidth, int reqHeight, int width, int height,
      BitmapFactory.Options options, Request request) {
    int sampleSize = 1;
    if (height > reqHeight || width > reqWidth) {
      final int heightRatio;
      final int widthRatio;
      if (reqHeight == 0) {
        sampleSize = (int) Math.floor((float) width / (float) reqWidth);
      } else if (reqWidth == 0) {
        sampleSize = (int) Math.floor((float) height / (float) reqHeight);
      } else {
        heightRatio = (int) Math.floor((float) height / (float) reqHeight);
        widthRatio = (int) Math.floor((float) width / (float) reqWidth);
        sampleSize = request.centerInside
            ? Math.max(heightRatio, widthRatio)
            : Math.min(heightRatio, widthRatio);
      }
    }
    options.inSampleSize = sampleSize;
    options.inJustDecodeBounds = false;
  }
```
这个时候，如果我们没有设置宽高，则是默认的SimpleSize为1.而且比出来的结果是向下取整。
我们同时可以知道，Picasso的作者偏向还原图片的精致，而Glide的作者更加倾向内存的开销。
等一下，不清楚SimpleSize作用的朋友这里提一下，SimlpeSize简单的说就是图片像素的采样点，和视频的码率概念有点像，SimpleSize越高说明采样点越大，相当于几个点当成了一个点显示出来，越低图片越精致。
很简单的道理越是同一张图片越是精致占用的内存越高，越是粗糙的图片占用越低。

这里就能解释为什么Glide的图片即使都是在ARGB888下面往往没有Picasso清晰，而Glide占用内存比Picasso低是必然的。

### Glide和Picasso缓存策略
两者之间缓存策略都是内存-磁盘二级缓存机制，如果都没有则去网络下载数据。虽然大方向是相同的，但是细节上略有不同。上面在分析源码的时候已经提到了。
####Picasso缓存策略
先说说Picasso的缓存机制，在分析源码已经透露了：
into中，在请求每一个Action的时候，都会生成一个key来检测，能存缓存获取到图片，并且去除请求：
```
    if (shouldReadFromMemoryCache(memoryPolicy)) {
      Bitmap bitmap = picasso.quickMemoryCacheCheck(requestKey);
      if (bitmap != null) {
        picasso.cancelRequest(target);
        target.onBitmapLoaded(bitmap, MEMORY);
        return;
      }
    }
```

接着在hunter的run中检测再检测一次缓存是否存在bitmap，
```
if (shouldReadFromMemoryCache(memoryPolicy)) {
      bitmap = cache.get(key);
      if (bitmap != null) {
        stats.dispatchCacheHit();
        loadedFrom = MEMORY;
        if (picasso.loggingEnabled) {
          log(OWNER_HUNTER, VERB_DECODED, data.logId(), "from cache");
        }
        return bitmap;
      }
    }
```

接着在数据回调中，根据网络数据流返回的code，来判断是否从磁盘中获取。在这里，有两个UrlConnectionDownloader和OkHttpDownloader网络连接器。前面是通过HttpResponseCache默认的缓存磁盘缓存，而OkHttpDownloader通过okhttp网络请求的时候，下面的cache拦截器拦截下来，获取磁盘下缓存。

####Glide缓存策略
Glide我之前就说过，整个流程是由我们自己完全控制。之前我提到了在Glide中分为缓存分为两种内存和磁盘，这个是在Glide初始化时候完成的工作。
```
   if (memoryCache == null) {
            memoryCache = new LruResourceCache(calculator.getMemoryCacheSize());
        }

        if (diskCacheFactory == null) {
            diskCacheFactory = new InternalCacheDiskCacheFactory(context);
        }
```

前者是内存缓存，后者是磁盘缓存。
先看整个流程，和Picasso很相似，
1.在创建Request的时候会判断一次，是否已经存在这个Request了，有的话则撤销请求，重新创建一个请求。
```
Request previous = target.getRequest();

        if (previous != null) {
            previous.clear();
            requestTracker.removeRequest(previous);
            previous.recycle();
        }

```
2.在engine中的load方法，会先判断一次memoryCache是否存在对应request产生出来的key对应的资源文件，有就读出直接返回。
```
 EngineResource<?> cached = loadFromCache(key, isMemoryCacheable);
        if (cached != null) {
            cb.onResourceReady(cached);
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                logWithTimeAndKey("Loaded resource from cache", startTime, key);
            }
            return null;
        }
```
这里值得注意的是loadFromCache这个方法：
```
private final Map<Key, WeakReference<EngineResource<?>>> activeResources;
private EngineResource<?> loadFromCache(Key key, boolean isMemoryCacheable) {
        if (!isMemoryCacheable) {
            return null;
        }

        EngineResource<?> cached = getEngineResourceFromCache(key);
        if (cached != null) {
            cached.acquire();
            activeResources.put(key, new ResourceWeakReference(key, cached, getReferenceQueue()));
        }
        return cached;
    }
```
这里的处理策略是，先从LruResourceCache读取缓存中的资源，如果有就从LruResourceCache中移除，并且加入到activeResources中。

3.接下来再尝试从activeResources取出资源文件
```
 EngineResource<?> active = loadFromActiveResources(key, isMemoryCacheable);
        if (active != null) {
            cb.onResourceReady(active);
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                logWithTimeAndKey("Loaded resource from active resources", startTime, key);
            }
            return null;
        }
```
```
private EngineResource<?> loadFromActiveResources(Key key, boolean isMemoryCacheable) {
        if (!isMemoryCacheable) {
            return null;
        }

        EngineResource<?> active = null;
        WeakReference<EngineResource<?>> activeRef = activeResources.get(key);
        if (activeRef != null) {
            active = activeRef.get();
            if (active != null) {
                active.acquire();
            } else {
                activeResources.remove(key);
            }
        }

        return active;
    }
```
这么做的好处是什么，首先即使是使用了LruCache最近最少用算法，也无法避免OOM的结果，毕竟加载图片很消耗内存。但是如果把正在使用的资源放在弱引用里面结果就不同了。弱引用相当于打上一个标记，当gc来的时候就会回收掉。一来我正在使用这个资源，即使gc来了，经过分析对象可达性，如果没有使用者也会尝试把这个列表里面的资源全部回收掉。这样就尽量保证了不会出现OOM的情况。

4.如果都没有资源，则从网络尝试获取资源文件在联网之前会先去磁盘缓存里面查看是否还存在key对应的资源，有就从磁盘里面获取。之前那个时序图，是第一次加载图片，所以没有缓存的流程，不然需要一口气看的东西太多了。下面是EngineRunnable的decode方法：
```
 private boolean isDecodingFromCache() {
        return stage == Stage.CACHE;
    }
    private Resource<?> decode() throws Exception {
        if (isDecodingFromCache()) {
            return decodeFromCache();
        } else {
            return decodeFromSource();
        }
    }
```
假设已经存到一次图片了：
```
private Resource<?> decodeFromCache() throws Exception {
        Resource<?> result = null;
        try {
            result = decodeJob.decodeResultFromCache();
        } catch (Exception e) {
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Exception decoding result from cache: " + e);
            }
        }

        if (result == null) {
            result = decodeJob.decodeSourceFromCache();
        }
        return result;
    }
```
这里值得注意的一点，磁盘缓存分为四种下面四种策略:
```
public enum DiskCacheStrategy {
    /** Caches with both {@link #SOURCE} and {@link #RESULT}. */
    ALL(true, true),
    /** Saves no data to cache. */
    NONE(false, false),
    /** Saves just the original data to cache. */
    SOURCE(true, false),
    /** Saves the media item after all transformations to cache. */
    RESULT(false, true);

    private final boolean cacheSource;
    private final boolean cacheResult;

    DiskCacheStrategy(boolean cacheSource, boolean cacheResult) {
        this.cacheSource = cacheSource;
        this.cacheResult = cacheResult;
    }

    /**
     * Returns true if this request should cache the original unmodified data.
     */
    public boolean cacheSource() {
        return cacheSource;
    }

    /**
     * Returns true if this request should cache the final transformed result.
     */
    public boolean cacheResult() {
        return cacheResult;
    }
}
```
source和result两种缓存策略。默认 RESULT(false, true);是只存储经过glide导正和采样之后的图片，而source网上说是没有变形之前的图片，其实还不准确，实际上是没有解析图片之前的从网络获取下来的数据流。

可以看最早的时序图,在解析数据流之前，会判断一次你的缓存策略是什么:
```
private Resource<T> decodeFromSourceData(A data) throws IOException {
        final Resource<T> decoded;
        if (diskCacheStrategy.cacheSource()) {
            decoded = cacheAndDecodeSourceData(data);
        } else {
            long startTime = LogTime.getLogTime();
            decoded = loadProvider.getSourceDecoder().decode(data, width, height);
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                logWithTimeAndKey("Decoded from source", startTime);
            }
        }
        return decoded;
    }
```
比如：
```
Glide.with(this).load("").diskCacheStrategy(DiskCacheStrategy.ALL).into();
```
这个时候会把流和图片一起保存起来，如果第二次加载一样的图片，这个时候就会走到了cacheAndDecodeSourceData的分支里面。
```
private Resource<T> cacheAndDecodeSourceData(A data) throws IOException {
        long startTime = LogTime.getLogTime();
        SourceWriter<A> writer = new SourceWriter<A>(loadProvider.getSourceEncoder(), data);
        diskCacheProvider.getDiskCache().put(resultKey.getOriginalKey(), writer);
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logWithTimeAndKey("Wrote source to cache", startTime);
        }

        startTime = LogTime.getLogTime();
        Resource<T> result = loadFromCache(resultKey.getOriginalKey());
        if (Log.isLoggable(TAG, Log.VERBOSE) && result != null) {
            logWithTimeAndKey("Decoded source from cache", startTime);
        }
        return result;
    }
```
这个时候就会把之前产生的key作为键值存入到DiskLruCacheWrapper中，接着再进入到：
```
 private Resource<T> loadFromCache(Key key) throws IOException {
        File cacheFile = diskCacheProvider.getDiskCache().get(key);
        if (cacheFile == null) {
            return null;
        }

        Resource<T> result = null;
        try {
            result = loadProvider.getCacheDecoder().decode(cacheFile, width, height);
        } finally {
            if (result == null) {
                diskCacheProvider.getDiskCache().delete(key);
            }
        }
        return result;
    }
```
从磁盘拿出刚才的流，并且解析。这边不多做解释，这个diskCacheProvider最后还是会调用StreamBitmapDataLoadProvider。

当解析好了之后，如果发现磁盘存储策略需要存储result的话，将会在转化的那一步，存入磁盘:
```
 private void writeTransformedToCache(Resource<T> transformed) {
        if (transformed == null || !diskCacheStrategy.cacheResult()) {
            return;
        }
        long startTime = LogTime.getLogTime();
        SourceWriter<Resource<T>> writer = new SourceWriter<Resource<T>>(loadProvider.getEncoder(), transformed);
        diskCacheProvider.getDiskCache().put(resultKey, writer);
        if (Log.isLoggable(TAG, Log.VERBOSE)) {
            logWithTimeAndKey("Wrote transformed from source to cache", startTime);
        }
    }
``` 
别担心会覆盖，因为在每个Request里面都会生成流和资源对应的key。

当然如果获取不到图片会调用LoadFailed，就会修改Stage状态，尝试这区联网去读流：
```
private void onLoadFailed(Exception e) {
        if (isDecodingFromCache()) {
            stage = Stage.SOURCE;
            manager.submitForSource(this);
        } else {
            manager.onException(e);
        }
    }
```
这个时候就是时序图上面的流程了。

到这里Picasso和Glide双方的缓存策略已经全部解释完了。在这里我发现有人总结的图片比我的好，我就借用他的图片了。
Picasso缓存策略:
![Picasso缓存策略](/images/Picasso缓存策略.jpg)

Glide缓存策略：
![Glide缓存策略](/images/Glide缓存策略.jpg)


Glide的基础部分也分析的差不多了，虽然还有不少的模块还没有解析到，等以后有缘在写吧。

这里要感谢Darren大佬，郭霖大佬以及下面这些博文的作者:
缓存图片出处:http://blog.csdn.net/u011803341/article/details/62434085

Glide和Picasso性能测试出处:
https://www.jianshu.com/p/fc72001dc18d
http://blog.csdn.net/qq_35166847/article/details/51814409

下面是经过解析之后，结合glide和picasso优点，使用拦截器处理图片流的图片加载库:
https://github.com/yjy239/TNLoader













































































