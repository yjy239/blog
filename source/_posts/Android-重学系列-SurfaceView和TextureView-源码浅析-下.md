---
title: Android 重学系列 SurfaceView和TextureView 源码浅析(下)
top: false
cover: false
date: 2020-04-19 23:14:35
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---
# 前言
上一篇文章和大家论述了SurfaceView的核心原理，本文和大家聊聊TextureView的核心原理。

如果发现什么地方写的有问题，欢迎来本文[https://www.jianshu.com/p/1dce98846dc7](https://www.jianshu.com/p/1dce98846dc7)指出。

# 正文
TextureView的用法这里稍微解释一下。用一个官方的demo看看。
```java
public class LiveCameraActivity extends Activity implements TextureView.SurfaceTextureListener {
      private Camera mCamera;
      private TextureView mTextureView;
      SurfaceTexture.OnFrameAvailableListener mFrameAvailableListener;

      protected void onCreate(Bundle savedInstanceState) {
          super.onCreate(savedInstanceState);

          mTextureView = new TextureView(this);
          mTextureView.setSurfaceTextureListener(this);

          setContentView(mTextureView);
      }

      public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
          mCamera = Camera.open();
          try {
              surface.setOnFrameAvailableListener(mFrameAvailableListener);
              mCamera.setPreviewTexture(surface);
              mCamera.startPreview();
          } catch (IOException ioe) {
              // Something bad happened
          }
      }

      public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {
          // Ignored, Camera does all the work for us
      }

      public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
          mCamera.stopPreview();
          mCamera.release();
          return true;
      }

      public void onSurfaceTextureUpdated(SurfaceTexture surface) {
          // Invoked every time there's a new Camera preview frame
      }
  }
```
这是一个最简单的相机预览功能模型。首先通过setSurfaceTextureListener监听TextureView的生命周期:
- 1.onSurfaceTextureAvailable(TextureView可用).
- 2.onSurfaceTextureSizeChanged TextureView大小发生了变化
- 3.onSurfaceTextureUpdated TextureView有视图数据进行了更新。
- 4.onSurfaceTextureDestroyed TextureView销毁了。
- 5.setOnFrameAvailableListener 监听TextureView绘制每一帧结束后的回调。

在每一个生命周期中，分别处理了Camera的对应的行为。详细的就不铺开说了。我们主要来关注TextureView，在整个View的绘制流程中做了什么？

## TextureView 源码解析
老规矩，我们根据上一篇文章总结的，如何阅读View源码方式进行解析。本文将着重的解析TextureView中lockCanvas，unlockCanvasAndPost，以及draw的方法。

### TextureView onMeasure,onLayout,onDraw
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureView.java)

TextureView 在 onMeasure,onLayout两个流程并没有什么可说的。我们来看看draw方法。
```java
 @Override
    public final void draw(Canvas canvas) {
        // NOTE: Maintain this carefully (see View#draw)
        mPrivateFlags = (mPrivateFlags & ~PFLAG_DIRTY_MASK) | PFLAG_DRAWN;


        if (canvas.isHardwareAccelerated()) {
            DisplayListCanvas displayListCanvas = (DisplayListCanvas) canvas;

            TextureLayer layer = getTextureLayer();
            if (layer != null) {
                applyUpdate();
                applyTransformMatrix();

                mLayer.setLayerPaint(mLayerPaint); // ensure layer paint is up to date
                displayListCanvas.drawTextureLayer(layer);
            }
        }
    }
```
和SurfaceView不同，TextureView确实是跟着ViewRootImpl 绘制View 树时候的三大流程走。不过有一点不同的是，ViewRootImpl的draw流程时候，都是绘制在从ViewRootImpl中生成的Canvas中。但是TextureView并直接没有使用从上层传递下来的Canvas，而是通过TextureLayer绘制的。

第二点不同的是，TextureView想要可以正常绘制，当前Activity必须要打开硬件渲染。因为这里面必须使用硬件渲染独有的Canvas DisplayListCanvas进行绘制。否则标志位没进来，TextureView跳过draw的方法就是背景色。

让我们来看看TextureLayer是什么吧。

#### TextureLayer TextureView的画笔的初始化

```java
    TextureLayer getTextureLayer() {
        if (mLayer == null) {
            if (mAttachInfo == null || mAttachInfo.mThreadedRenderer == null) {
                return null;
            }

            mLayer = mAttachInfo.mThreadedRenderer.createTextureLayer();
            boolean createNewSurface = (mSurface == null);
            if (createNewSurface) {
                // Create a new SurfaceTexture for the layer.
                mSurface = new SurfaceTexture(false);
                nCreateNativeWindow(mSurface);
            }
            mLayer.setSurfaceTexture(mSurface);
            mSurface.setDefaultBufferSize(getWidth(), getHeight());
            mSurface.setOnFrameAvailableListener(mUpdateListener, mAttachInfo.mHandler);

            if (mListener != null && createNewSurface) {
                mListener.onSurfaceTextureAvailable(mSurface, getWidth(), getHeight());
            }
            mLayer.setLayerPaint(mLayerPaint);
        }

        if (mUpdateSurface) {
            // Someone has requested that we use a specific SurfaceTexture, so
            // tell mLayer about it and set the SurfaceTexture to use the
            // current view size.
            mUpdateSurface = false;

            // Since we are updating the layer, force an update to ensure its
            // parameters are correct (width, height, transform, etc.)
            updateLayer();
            mMatrixChanged = true;

            mLayer.setSurfaceTexture(mSurface);
            mSurface.setDefaultBufferSize(getWidth(), getHeight());
        }

        return mLayer;
    }
```
一旦发现mLayer没有初始化，这里做的事情分为如下几个步骤：
- 1.通过从ViewRootImpl传下来的AttchInfo中的ThreadedRenderer调用createTextureLayer()进行生成一个TextureLayer。ThreadedRenderer这个类是硬件渲染的核心类，所有的硬件渲染都是从这个类开始触发。
- 2.检查是否创建了SurfaceTexture，没有创建则先创建后调用native方法nCreateNativeWindow 保存起来。并保存到TextureLayer。
- 3.设置SurfaceTexture的宽高，setOnFrameAvailableListener监听SurfaceTexture的回调，并且回调第一个生命周期onSurfaceTextureAvailable。
- 4.如果需要更新SurfaceTexture，调用updateLayer更新标志位后，更新TextureLayer中的SurfaceTexture以及重新设置宽高。

这里面涉及了两个比较关键的函数ThreadedRenderer.createTextureLayer以及nCreateNativeWindow，以及一个对象SurfaceTexture。从名字上来看叫做Surface纹理，感觉绘制内容都在里面。我们先来看看SurfaceTexture究竟是什么东西？

### SurfaceTexture的初始化
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[graphics](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/)/[graphics](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/graphics/)/[SurfaceTexture.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/graphics/java/android/graphics/SurfaceTexture.java)
```java
    public SurfaceTexture(boolean singleBufferMode) {
        mCreatorLooper = Looper.myLooper();
        mIsSingleBuffered = singleBufferMode;
        nativeInit(true, 0, singleBufferMode, new WeakReference<SurfaceTexture>(this));
    }

```
关键是调用nativeInit在native层进行初始化。默认是设置的mIsSingleBuffered为false，mCreatorLooper则为当前线程对应的Looper。所以我们想要创建一个SurfaceTexture，可以不是当前的ui主线程，但是当前线程必须存在初始化好的Looper。

### SurfaceTexture native层的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android/)/[graphics](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android/graphics/)/[SurfaceTexture.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android/graphics/SurfaceTexture.cpp)
```cpp
static void SurfaceTexture_init(JNIEnv* env, jobject thiz, jboolean isDetached,
        jint texName, jboolean singleBufferMode, jobject weakThiz)
{
    sp<IGraphicBufferProducer> producer;
    sp<IGraphicBufferConsumer> consumer;
    BufferQueue::createBufferQueue(&producer, &consumer);

    if (singleBufferMode) {
        consumer->setMaxBufferCount(1);
    }

    sp<GLConsumer> surfaceTexture;
    if (isDetached) {
        surfaceTexture = new GLConsumer(consumer, GL_TEXTURE_EXTERNAL_OES,
                true, !singleBufferMode);
    } else {
        surfaceTexture = new GLConsumer(consumer, texName,
                GL_TEXTURE_EXTERNAL_OES, true, !singleBufferMode);
    }

    if (surfaceTexture == 0) {
        jniThrowException(env, OutOfResourcesException,
                "Unable to create native SurfaceTexture");
        return;
    }
    surfaceTexture->setName(String8::format("SurfaceTexture-%d-%d-%d",
            (isDetached ? 0 : texName),
            getpid(),
            createProcessUniqueId()));

    // If the current context is protected, inform the producer.
    consumer->setConsumerIsProtected(isProtectedContext());

    SurfaceTexture_setSurfaceTexture(env, thiz, surfaceTexture);
    SurfaceTexture_setProducer(env, thiz, producer);

    jclass clazz = env->GetObjectClass(thiz);
    if (clazz == NULL) {
        jniThrowRuntimeException(env,
                "Can't find android/graphics/SurfaceTexture");
        return;
    }

    sp<JNISurfaceTextureContext> ctx(new JNISurfaceTextureContext(env, weakThiz,
            clazz));
    surfaceTexture->setFrameAvailableListener(ctx);
    SurfaceTexture_setFrameAvailableListener(env, thiz, ctx);
}
```
首先通过createBufferQueue初始化了两个极其重要的角色：
- 1.IGraphicBufferProducer 图元生产者
- 2.IGraphicBufferConsumer 图元消费者


接着，使用初始化好的图元消费者，在SurfaceTexture在native层中初始化了一个极其重要的角色GLConsumer。当然在SurfaceTexture这里面图元生产者和图元消费者要区别于SF进程的图元生产者和图元消费者。具体有什么区别稍后再来聊聊。

最后把IGraphicBufferProducer和GLConsumer以及FrameAvailableListener的地址设置在SurfaceTexture的long类型中。
```java
    private long mSurfaceTexture;
    private long mProducer;
    private long mFrameAvailableListener;
```


#### GLConsumer的初始化
```cpp
GLConsumer::GLConsumer(const sp<IGraphicBufferConsumer>& bq, uint32_t tex,
        uint32_t texTarget, bool useFenceSync, bool isControlledByApp) :
    ConsumerBase(bq, isControlledByApp),
    mCurrentCrop(Rect::EMPTY_RECT),
    mCurrentTransform(0),
    mCurrentScalingMode(NATIVE_WINDOW_SCALING_MODE_FREEZE),
    mCurrentFence(Fence::NO_FENCE),
    mCurrentTimestamp(0),
    mCurrentDataSpace(HAL_DATASPACE_UNKNOWN),
    mCurrentFrameNumber(0),
    mDefaultWidth(1),
    mDefaultHeight(1),
    mFilteringEnabled(true),
    mTexName(tex),
    mUseFenceSync(useFenceSync),
    mTexTarget(texTarget),
    mEglDisplay(EGL_NO_DISPLAY),
    mEglContext(EGL_NO_CONTEXT),
    mCurrentTexture(BufferQueue::INVALID_BUFFER_SLOT),
    mAttached(true)
{
    GLC_LOGV("GLConsumer");

    memcpy(mCurrentTransformMatrix, mtxIdentity.asArray(),
            sizeof(mCurrentTransformMatrix));

    mConsumer->setConsumerUsageBits(DEFAULT_USAGE_FLAGS);
}
```

GLConsumer的构造函数，我们能看到有这么几个参数：
- 1.consumer IGraphicBufferConsumer图元消费者
- 2.texName 一个int型，实际上设置一个纹理id。
- 3.GL_TEXTURE_EXTERNAL_OES 这是指渲染在屏幕上的纹理类型，就像OpenGL es的GL_TEXTURE_2D这种类型一样。这也是为什么，我们自定义TextureView的渲染纹理时候，往往需要GL_TEXTURE_EXTERNAL_OES这种类型进行承载。
- 4.useFenceSync 一个boolean型，他的作用是是否使用fence同步栅，一般都为true。
- 5.isControlledByApp 在这里面被singleBufferMode所控制。singleBufferMode为true的时候，也就是isControlledByApp为false：代表这个GLConsumer最大只能分配一个图元给SurfaceTexture。不过这里一般为false，代表isControlledByApp为true，可以根据需求获取更多的图元。

当然在初始化GLConsumer过程中，分为2种方式一种是detach一种是非detach。这两个有什么区别呢？最主要的区别就是可以设置texName纹理id。因为OpenGL es的纹理是跟着线程的OpenGL的上下文走的。因此，在TextureView在不同线程渲染同一个SurfaceTexture，需要进行一次detach，重新绑定一次当前线程新的纹理。

了解了SurfaceTexture内部其实控制着自己内部的图元生产者和消费者，我们继续看看TextureLayer是什么东西。


#### ThreadedRenderer.createTextureLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ThreadedRenderer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ThreadedRenderer.java)
```java
    TextureLayer createTextureLayer() {
        long layer = nCreateTextureLayer(mNativeProxy);
        return TextureLayer.adoptTextureLayer(this, layer);
    }
```

在native层创建了一个对应的TextureLayer之后，保存在java层中返回。

### native层创建TextureLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)
```cpp
static jlong android_view_ThreadedRenderer_createTextureLayer(JNIEnv* env, jobject clazz,
        jlong proxyPtr) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    DeferredLayerUpdater* layer = proxy->createTextureLayer();
    return reinterpret_cast<jlong>(layer);
}
```
RenderProxy这个对象是ThreadedRenderer在初始化的时候，根据RootNode(可以看成硬件绘制的根节点，硬件绘制将会绘制每一个View中的RenderNode)创建出来的。

#### RenderProxy createTextureLayer
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)
```cpp
DeferredLayerUpdater* RenderProxy::createTextureLayer() {
    return mRenderThread.queue().runSync([this]() -> auto {
        return mContext->createTextureLayer();
    });
}
```
这里面把事件放到RenderThread中排队处理。通过CanvasContext.createTextureLayer成功创建DeferredLayerUpdater后返回。

#### CanvasContext createTextureLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[CanvasContext.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/CanvasContext.cpp)

```cpp
DeferredLayerUpdater* CanvasContext::createTextureLayer() {
    return mRenderPipeline->createTextureLayer();
}
```
这里使用了一个pipeline进行TextureLayer的创建。这个pipeline一般是在硬件模式开启下使用的。Android在硬件渲染上为了更好的兼容Skia，OpenGL，vulkan，在初始化ThreadRenderer的时候，会根据你在系统中设置的标志，从而打开对应的硬件渲染，如下：
```cpp
CanvasContext* CanvasContext::create(RenderThread& thread, bool translucent,
                                     RenderNode* rootRenderNode, IContextFactory* contextFactory) {
    auto renderType = Properties::getRenderPipelineType();

    switch (renderType) {
        case RenderPipelineType::OpenGL:
            return new CanvasContext(thread, translucent, rootRenderNode, contextFactory,
                                     std::make_unique<OpenGLPipeline>(thread));
        case RenderPipelineType::SkiaGL:
            return new CanvasContext(thread, translucent, rootRenderNode, contextFactory,
                                     std::make_unique<skiapipeline::SkiaOpenGLPipeline>(thread));
        case RenderPipelineType::SkiaVulkan:
            return new CanvasContext(thread, translucent, rootRenderNode, contextFactory,
                                     std::make_unique<skiapipeline::SkiaVulkanPipeline>(thread));
        default:
            LOG_ALWAYS_FATAL("canvas context type %d not supported", (int32_t)renderType);
            break;
    }
    return nullptr;
}
```
能看到在RenderThread硬件渲染模式中，每一种诞生的CanvasContext都会伴随对应类型的管道Pipeline。这种设计十分常见，就是一个工厂模式。SkiaGL和vulkan是比较新鲜的语言。特别是SkiaGL，如果你去下载Skia源码阅读后，还会发现一种名为SLGL的语言同步开发中,当然这里面是指Skia兼容的OpenGL模式。vulkan是当前性能更优，框架比起OpenGL es更加小巧的方案。当然Android P默认是使用SkiaOpenGLPipeline，而Android O是OpenGLPipeline。我们来讨论这一种。现在我们在讨论Android 9.0，理应解析SkiaOpenGLPipeline。当然从源码的角度来看Android P和O两者创建TextureLayer的逻辑上是一致的。


##### SkiaOpenGLPipeline createTextureLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[pipeline](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/)/[skia](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/)/[SkiaOpenGLPipeline.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/SkiaOpenGLPipeline.cpp)

```cpp
static Layer* createLayer(RenderState& renderState, uint32_t layerWidth, uint32_t layerHeight,
                          sk_sp<SkColorFilter> colorFilter, int alpha, SkBlendMode mode, bool blend) {
    GlLayer* layer =
            new GlLayer(renderState, layerWidth, layerHeight, colorFilter, alpha, mode, blend);
    layer->generateTexture();
    return layer;
}

DeferredLayerUpdater* SkiaOpenGLPipeline::createTextureLayer() {
    mEglManager.initialize();
    return new DeferredLayerUpdater(mRenderThread.renderState(), createLayer, Layer::Api::OpenGL);
}
```
在这里，我们就能看到诞生的TextureLayer为什么名字是DeferredLayerUpdater(延时Layer的更新者)。因为真正工作的对象其实是上面的GlLayer。

我们把方法指针传入到DeferredLayerUpdater后，什么时候才开始调用且初始化呢？我们继续回头看看TexureView中的nCreateNativeWindow方法。

#### TextureView nCreateNativeWindow
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_TextureView.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_TextureView.cpp)

```cpp
static void android_view_TextureView_createNativeWindow(JNIEnv* env, jobject textureView,
        jobject surface) {

    sp<IGraphicBufferProducer> producer(SurfaceTexture_getProducer(env, surface));
    sp<ANativeWindow> window = new Surface(producer, true);

    window->incStrong((void*)android_view_TextureView_createNativeWindow);
    SET_LONG(textureView, gTextureViewClassInfo.nativeWindow, jlong(window.get()));
}
```
通过jni注册的方法，我们能够清晰知道nCreateWindow指向的是上面的方法。如果还记得我写的SF系列文章，就能明白Surface中包含着一般都会保存SF进程通过Binder传递过来的Binder对象作为跨进程通信的图元生产者。此时是吧SurfaceTexture的图元生产者设置到Surface中，之后这个Surface需要进行图元出队和入队的操作，就会从GLConsumer中获取。

最后把这个Surface的地址保存在TextureView中：
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureView.java)
```java
    private long mNativeWindow;
```

到这里为止TextureView通过初始化TextureLayer，让TextureView持用了一个Surface，SurfaceTexture持有了图元消费者GLConsumer。并且让TextureLayer持有SurfaceTexture对象。




### 小结
到这里，TextureView的初始化才算是完成了。我们先中断解析的流程，还是按照正常思维来看看正常的View的绘制流程所经历的lockCanvas，draw，unlockCanvasAndPost的顺序。

当然，我们需要稍微提一下，整个TextureView的流程和传统的流程有什么不同。一般的View的draw流程走的顺序如我上一篇文章聊过的，先从ViewRootImpl诞生一个Canvas，把这个Canvas不断的向下传递，每一个View在自己的draw方法绘制对应的内容在Canvas上，当遍历好整个View tree，ViewRootImpl将会调用unlockCanvasAndPost发送到SF进程。

那么TextureView一般是怎么绘制的呢？TextureView本身内置了lockCanvas以及unlockCanvasAndPost的方法直接通信到SF中。只要我们在SurfaceTexture.OnFrameAvailableListener回调中进行调用。

回过头来思考一下，为什么说TextureView比起SurfaceView从性能上总是慢上几帧呢？

首先在第一次draw的时候TextureView才真正的初始化完毕。接着我们来看看SurfaceTexture_setFrameAvailableListener这个从SurfaceTexture默认设置的FrameAvailableListener监听做了什么。
```cpp
    sp<JNISurfaceTextureContext> ctx(new JNISurfaceTextureContext(env, weakThiz,
            clazz));
    surfaceTexture->setFrameAvailableListener(ctx);
    SurfaceTexture_setFrameAvailableListener(env, thiz, ctx);
```
注意这里面surfaceTexture对象是孩子GLConsumer，GLConsumer本质上也是一个图元消费者。从SF系列可以得知，当Surface调用了queueBuffer之后，将会调用setFrameAvailableListener注册的监听。

```cpp
static void SurfaceTexture_setFrameAvailableListener(JNIEnv* env,
        jobject thiz, sp<GLConsumer::FrameAvailableListener> listener)
{
    GLConsumer::FrameAvailableListener* const p =
        (GLConsumer::FrameAvailableListener*)
            env->GetLongField(thiz, fields.frameAvailableListener);
    if (listener.get()) {
        listener->incStrong((void*)SurfaceTexture_setSurfaceTexture);
    }
    if (p) {
        p->decStrong((void*)SurfaceTexture_setSurfaceTexture);
    }
    env->SetLongField(thiz, fields.frameAvailableListener, (jlong)listener.get());
}
```
接下来这个方法则是把native层对应JNISurfaceTextureContext 监听设置到Java层中的对象。每当有图元通过queueBuffer把图元传递进来则会调用如下方法：
```cpp
void JNISurfaceTextureContext::onFrameAvailable(const BufferItem& /* item */)
{
    bool needsDetach = false;
    JNIEnv* env = getJNIEnv(&needsDetach);
    if (env != NULL) {
        env->CallStaticVoidMethod(mClazz, fields.postEvent, mWeakThiz);
    } else {
        ALOGW("onFrameAvailable event will not posted");
    }
    if (needsDetach) {
        detachJNI();
    }
}
```
这个方法本质上是反射调用SurfaceTexture中的postEventFromNative方法：
```java
    private static void postEventFromNative(WeakReference<SurfaceTexture> weakSelf) {
        SurfaceTexture st = weakSelf.get();
        if (st != null) {
            Handler handler = st.mOnFrameAvailableHandler;
            if (handler != null) {
                handler.sendEmptyMessage(0);
            }
        }
    }
```
通过注册在SurfaceTexture中的handler发送消息，进行FrameAvailable的回调。

我们来算一下，究竟延时了多少loop，第一个Looper，是来自Handler的消息Looper，第二个Looper是来自RenderThread的入队处理，下文会提到。因此延时2次，比起外部的ViewRootImpl和SurfaceView延时1-3帧的结果也是靠谱的。

那么现在的研究的中心。就转移到TextureView是怎么和DisplayListCanvas协调工作的；以及TextureLayer这个作为TextureView的画笔究竟什么时候转化为真正的绘制层级GlLayer。

先来看看lockCanvas方法做了什么。

### TextureView lockCanvas
从设计上lockCanvas还是和原来设计基本上是相通的。
文件：[rameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureView.java)
```java
    public Canvas lockCanvas() {
        return lockCanvas(null);
    }

    public Canvas lockCanvas(Rect dirty) {
        if (!isAvailable()) return null;

        if (mCanvas == null) {
            mCanvas = new Canvas();
        }

        synchronized (mNativeWindowLock) {
            if (!nLockCanvas(mNativeWindow, mCanvas, dirty)) {
                return null;
            }
        }
        mSaveCount = mCanvas.save();

        return mCanvas;
    }
```
请注意这了的mNativeWindow在上文有提到过。就是android_view_TextureView_createNativeWindow方法初始化Window的时候生成的一个临时的Surface，不过只是保存在native层而已。

这里也要注意一下，lockCanvas的时候，发现mCanvas为空就会生成一个新的Canvas对象。换句话说，TextureView在调用lockCanvas的时候，实际上是使用自己的Canvas，自己的Surface。从设计上和SurfaceView几乎一致。

接下来的native层逻辑就和SurfaceView中的一致。


#### TextureView unlockCanvasAndPost
```java
    public void unlockCanvasAndPost(Canvas canvas) {
        if (mCanvas != null && canvas == mCanvas) {
            canvas.restoreToCount(mSaveCount);
            mSaveCount = 0;

            synchronized (mNativeWindowLock) {
                nUnlockCanvasAndPost(mNativeWindow, mCanvas);
            }
        }
    }
```
同理这里面就要把textureView自己的Surface中NativeWindow承载的内容发送到SF进程，并且刷新mCanvas中的SkBitmap内容。

接下来，我们来看看TextureView 在draw方法中的后续。


### TextureView的绘制
通过draw方法的getTextureLayer方法初始化好TextureView的绘制环境。接着就会执行下面的方法。
```java
if (layer != null) {
                applyUpdate();
                applyTransformMatrix();

                mLayer.setLayerPaint(mLayerPaint); // ensure layer paint is up to date
                displayListCanvas.drawTextureLayer(layer);
            }
```
绘制流程分为4个步骤：
- 1.applyUpdate TextureLayer更新准备
- 2.applyTransformMatrix TextureLayer保存变换矩阵
- 3.TextureLayer 设置LayerPaint
- 4.displayListCanvas 绘制TextureLayer。
##### applyUpdate TextureLayer更新准备
```cpp
    private void applyUpdate() {
        if (mLayer == null) {
            return;
        }

        synchronized (mLock) {
            if (mUpdateLayer) {
                mUpdateLayer = false;
            } else {
                return;
            }
        }

        mLayer.prepare(getWidth(), getHeight(), mOpaque);
        mLayer.updateSurfaceTexture();

        if (mListener != null) {
            mListener.onSurfaceTextureUpdated(mSurface);
        }
    }
```
这里面调用了TextureLayer的prepare以及updateSurfaceTexture，并且调用onSurfaceTextureUpdated触发第二个生命周期，onSurfaceTextureUpdated SurfaceTexture更新了。


##### TextureLayer prepare
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureLayer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureLayer.java)
```java
    public boolean prepare(int width, int height, boolean isOpaque) {
        return nPrepare(mFinalizer.get(), width, height, isOpaque);
    }
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_TextureLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_TextureLayer.cpp)
```cpp
static jboolean TextureLayer_prepare(JNIEnv* env, jobject clazz,
        jlong layerUpdaterPtr, jint width, jint height, jboolean isOpaque) {
    DeferredLayerUpdater* layer = reinterpret_cast<DeferredLayerUpdater*>(layerUpdaterPtr);
    bool changed = false;
    changed |= layer->setSize(width, height);
    changed |= layer->setBlend(!isOpaque);
    return changed;
}
```

可以看到prepare其实就是给DeferredLayerUpdater设置是否开启透明以及DeferredLayerUpdater的绘制范围。换句话说，就是TextureView绘制的宽高。保存到DeferredLayerUpdater中。

#### TextureLayer updateSurfaceTexture
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_TextureLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_TextureLayer.cpp)
```cpp
static void TextureLayer_updateSurfaceTexture(JNIEnv* env, jobject clazz,
        jlong layerUpdaterPtr) {
    DeferredLayerUpdater* layer = reinterpret_cast<DeferredLayerUpdater*>(layerUpdaterPtr);
    layer->updateTexImage();
}
```
此时将会调用DeferredLayerUpdater的updateTexImage。打开了刷新的标志位。

#### TextureLayer 设置变换矩阵
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureView.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureView.java)

```java
private void applyTransformMatrix() {
        if (mMatrixChanged && mLayer != null) {
            mLayer.setTransform(mMatrix);
            mMatrixChanged = false;
        }
    }
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[TextureLayer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/TextureLayer.java)

```java
    public void setTransform(Matrix matrix) {
        nSetTransform(mFinalizer.get(), matrix.native_instance);
        mRenderer.pushLayerUpdate(this);
    }
```
nSetTransform把Matrix保存在DeferredLayerUpdater。下一个方法是核心，调用ThreadRenderer的pushLayerUpdate，把TextureLayer压入栈中。

#### ThreadRenderer 保存当前的Layer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)
```cpp
static void android_view_ThreadedRenderer_pushLayerUpdate(JNIEnv* env, jobject clazz,
        jlong proxyPtr, jlong layerPtr) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    DeferredLayerUpdater* layer = reinterpret_cast<DeferredLayerUpdater*>(layerPtr);
    proxy->pushLayerUpdate(layer);
}
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)
```cpp
void RenderProxy::pushLayerUpdate(DeferredLayerUpdater* layer) {
    mDrawFrameTask.pushLayerUpdate(layer);
}
```
在这里就把DeferredLayerUpdater保存到DrawFrameTask中，等待ViewRootImpl后续流程统一把DrawFrameTask中保存的内容进行绘制。

文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[DrawFrameTask.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/DrawFrameTask.cpp)

```cpp
void DrawFrameTask::pushLayerUpdate(DeferredLayerUpdater* layer) {
    LOG_ALWAYS_FATAL_IF(!mContext,
                        "Lifecycle violation, there's no context to pushLayerUpdate with!");

    for (size_t i = 0; i < mLayers.size(); i++) {
        if (mLayers[i].get() == layer) {
            return;
        }
    }
    mLayers.push_back(layer);
}
```
DeferredLayerUpdater将会把没有保存过的layer保存到mLayers这个集合当中。


#### TextureLayer setLayerPaint 设置画笔
```cpp
static void TextureLayer_setLayerPaint(JNIEnv* env, jobject clazz,
        jlong layerUpdaterPtr, jlong paintPtr) {
    DeferredLayerUpdater* layer = reinterpret_cast<DeferredLayerUpdater*>(layerUpdaterPtr);
    if (layer) {
        Paint* paint = reinterpret_cast<Paint*>(paintPtr);
        layer->setPaint(paint);
    }
}
```
此时也给TextureLayer设置了Paint的画笔。

#### DisplayListCanvas drawTextureLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[DisplayListCanvas.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/DisplayListCanvas.java)
```java
    void drawTextureLayer(TextureLayer layer) {
        nDrawTextureLayer(mNativeCanvasWrapper, layer.getLayerHandle());
    }
```
DisplayListCanvas是硬件渲染的用的Canvas。通过这个Canvas调用native层进行渲染。但是本文不会和大家聊硬件渲染的核心原理，大致上可以想象和SkiaCanvas一样的原理，只是画像素的时候从CPU合成转移到GPU等硬件合成。



文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_DisplayListCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_DisplayListCanvas.cpp)
```cpp
static void android_view_DisplayListCanvas_drawTextureLayer(jlong canvasPtr, jlong layerPtr) {
    Canvas* canvas = reinterpret_cast<Canvas*>(canvasPtr);
    DeferredLayerUpdater* layer = reinterpret_cast<DeferredLayerUpdater*>(layerPtr);
    canvas->drawLayer(layer);
}
```
DisplayListCanvas对应在native层，也是根据pipe的类型生成对应不同的硬件渲染Canvas，在这里我们挑选默认的SkiaRecordingCanvas来聊聊。接下来就会调用SkiaRecordingCanvas的drawLayer方法。

##### SkiaRecordingCanvas drawLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[pipeline](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/)/[skia](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/)/[SkiaRecordingCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/SkiaRecordingCanvas.cpp)

```cpp
void SkiaRecordingCanvas::drawLayer(uirenderer::DeferredLayerUpdater* layerUpdater) {
    if (layerUpdater != nullptr) {
        // Create a ref-counted drawable, which is kept alive by sk_sp in SkLiteDL.
        sk_sp<SkDrawable> drawable(new LayerDrawable(layerUpdater));
        drawDrawable(drawable.get());
    }
}
```
此时会使用一个智能指针包裹LayerDrawable。LayerDrawable则会持有DeferredLayerUpdater。drawDrawable绘制LayerDrawable中的内容。由于SkiaRecordingCanvas继承于SkiaCanvas。从上一篇文章可知，SkiaCanvas中真正在工作的是SkCanvas。我们直接看看SkCanvas的drawDrawable方法。

#### SkCanvas drawDrawable
文件：/[external](http://androidxref.com/9.0.0_r3/xref/external/)/[skia](http://androidxref.com/9.0.0_r3/xref/external/skia/)/[src](http://androidxref.com/9.0.0_r3/xref/external/skia/src/)/[core](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/)/[SkCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/SkCanvas.cpp)
```cpp
void drawDrawable(SkDrawable* drawable, const SkMatrix* matrix = nullptr);
```
```cpp
void SkCanvas::drawDrawable(SkDrawable* dr, const SkMatrix* matrix) {
#ifndef SK_BUILD_FOR_ANDROID_FRAMEWORK
    TRACE_EVENT0("skia", TRACE_FUNC);
#endif
    RETURN_ON_NULL(dr);
    if (matrix && matrix->isIdentity()) {
        matrix = nullptr;
    }
    this->onDrawDrawable(dr, matrix);
}
void SkCanvas::onDrawDrawable(SkDrawable* dr, const SkMatrix* matrix) {
    // drawable bounds are no longer reliable (e.g. android displaylist)
    // so don't use them for quick-reject
    dr->draw(this, matrix);
}
```
能看到实际上是获取SkDrawable的draw方法。

###### SkDrawable draw
文件：/[external](http://androidxref.com/9.0.0_r3/xref/external/)/[skia](http://androidxref.com/9.0.0_r3/xref/external/skia/)/[src](http://androidxref.com/9.0.0_r3/xref/external/skia/src/)/[core](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/)/[SkDrawable.cpp](http://androidxref.com/9.0.0_r3/xref/external/skia/src/core/SkDrawable.cpp)
```cpp
void SkDrawable::draw(SkCanvas* canvas, const SkMatrix* matrix) {
    SkAutoCanvasRestore acr(canvas, true);
    if (matrix) {
        canvas->concat(*matrix);
    }
    this->onDraw(canvas);
....
}
```
在SkDrawable则会调用onDraw方法。onDraw是一个虚函数，在LayerDrawable中实现了。

##### LayerDrawable onDraw
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[pipeline](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/)/[skia](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/)/[LayerDrawable.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/LayerDrawable.cpp)

```cpp
void LayerDrawable::onDraw(SkCanvas* canvas) {
    Layer* layer = mLayerUpdater->backingLayer();
    if (layer) {
        DrawLayer(canvas->getGrContext(), canvas, layer);
    }
}
```
会从DeferredLayerUpdater 获取Layer对象，而这个Layer对象就是通过DeferredLayerUpdater保存的函数指针生成的GLLayer。但是第一次刷新界面的时候，并没有诞生出一个GLLayer进行绘制。所以不会继续走。

那么到这里，我们似乎遇到了瓶颈了，究竟是在什么时候才会真正的生成GLLayer。

## 硬件绘制的真正入口
我们不得不提一下硬件渲染从根部渲染节点RootNode遍历好整个DisplayList的View Tree之后。就会调用如下方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ThreadedRenderer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ThreadedRenderer.java)
```java
void draw(View view, AttachInfo attachInfo, DrawCallbacks callbacks,
            FrameDrawingCallback frameDrawingCallback) {
        attachInfo.mIgnoreDirtyState = true;

//从根部节点遍历整个DisplayList
        updateRootDisplayList(view, callbacks);

        ...
        int syncResult = nSyncAndDrawFrame(mNativeProxy, frameInfo, frameInfo.length);
....
    }
```
而这个方法会调用RenderProxy下的方法。我们直截选相关的逻辑，具体的流程可以等到我之后专门写一个专题。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)
```cpp
int RenderProxy::syncAndDrawFrame() {
    return mDrawFrameTask.drawFrame();
}
```

文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[DrawFrameTask.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/DrawFrameTask.cpp)
```cpp
int DrawFrameTask::drawFrame() {
    LOG_ALWAYS_FATAL_IF(!mContext, "Cannot drawFrame with no CanvasContext!");

    mSyncResult = SyncResult::OK;
    mSyncQueued = systemTime(CLOCK_MONOTONIC);
    postAndWait();

    return mSyncResult;
}

void DrawFrameTask::postAndWait() {
    AutoMutex _lock(mLock);
    mRenderThread->queue().post([this]() { run(); });
    mSignal.wait(mLock);
}

void DrawFrameTask::run() {
    ATRACE_NAME("DrawFrame");

    bool canUnblockUiThread;
    bool canDrawThisFrame;
    {
...
        canUnblockUiThread = syncFrameState(info);
...
    }

....
}

```
能看到在这个过程中调用了mRenderThread的queue方法，把绘制的run事件加入了渲染线程的事件队列中。其中syncFrameState方法就是把DeferredLayerUpdater转化为GlLayer。

#### DrawFrameTask syncFrameState
```cpp
bool DrawFrameTask::syncFrameState(TreeInfo& info) {
    ATRACE_CALL();
    int64_t vsync = mFrameInfo[static_cast<int>(FrameInfoIndex::Vsync)];
    mRenderThread->timeLord().vsyncReceived(vsync);
    bool canDraw = mContext->makeCurrent();
    mContext->unpinImages();

    for (size_t i = 0; i < mLayers.size(); i++) {
        mLayers[i]->apply();
    }
    mLayers.clear();
....
    return info.prepareTextures;
}
```
能看到，把OpenGL es的上下文切换为当前线程之后，调用每一个Layer的apply进行处理，并且清空mLayers集合。

此时我们看看DeferredLayerUpdater的apply。

#### DeferredLayerUpdater apply
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[DeferredLayerUpdater.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/DeferredLayerUpdater.cpp)

```cpp
void DeferredLayerUpdater::apply() {
    if (!mLayer) {
        mLayer = mCreateLayerFn(mRenderState, mWidth, mHeight, mColorFilter, mAlpha, mMode, mBlend);
    }

    mLayer->setColorFilter(mColorFilter);
    mLayer->setAlpha(mAlpha, mMode);

    if (mSurfaceTexture.get()) {
        if (mLayer->getApi() == Layer::Api::Vulkan) {
            ...
        } else {
            if (!mGLContextAttached) {
                mGLContextAttached = true;
                mUpdateTexImage = true;
                mSurfaceTexture->attachToContext(static_cast<GlLayer*>(mLayer)->getTextureId());
            }
            if (mUpdateTexImage) {
                mUpdateTexImage = false;
                doUpdateTexImage();
            }
            GLenum renderTarget = mSurfaceTexture->getCurrentTextureTarget();
            static_cast<GlLayer*>(mLayer)->setRenderTarget(renderTarget);
        }
        if (mTransform) {
            mLayer->getTransform().load(*mTransform);
            setTransform(nullptr);
        }
    }
}
```
能看到如果判断到mLayer为空，则调用之前保存下来的方法指针生成一个GlLayer。mSurfaceTexture在这里就是上面保存下来的GLConsumer。
- 1.调用GlLayer的attachToContext进行上下文切换和GlLayer中的纹理id进行绑定。
- 2.调用 doUpdateTexImage 更新纹理数据
- 3.设置GlLayer渲染的纹理为GLConsumer当前渲染的纹理。
- 4.GlLayer保存变换矩阵。

我们先来看看GlLayer的初始化。
```cpp
static Layer* createLayer(RenderState& renderState, uint32_t layerWidth, uint32_t layerHeight,
                          sk_sp<SkColorFilter> colorFilter, int alpha, SkBlendMode mode, bool blend) {
    GlLayer* layer =
            new GlLayer(renderState, layerWidth, layerHeight, colorFilter, alpha, mode, blend);
    layer->generateTexture();
    return layer;
}
```

#### GlLayer的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[GlLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/GlLayer.cpp)
```cpp
GlLayer::GlLayer(RenderState& renderState, uint32_t layerWidth, uint32_t layerHeight,
                 sk_sp<SkColorFilter> colorFilter, int alpha, SkBlendMode mode, bool blend)
        : Layer(renderState, Api::OpenGL, colorFilter, alpha, mode)
        , caches(Caches::getInstance())
        , texture(caches) {
    texture.mWidth = layerWidth;
    texture.mHeight = layerHeight;
    texture.blend = blend;
}
```
在这个过程中，创建了一个Cache的单例。Cache实际上是当前RenderThread硬件渲染线程唯一一个运行OpenGL的着色器程序。并让Texture纹理对象进行包裹，让Texture拥有了着色器上运行的能力。

```cpp
void GlLayer::generateTexture() {
    if (!texture.mId) {
        glGenTextures(1, &texture.mId);
    }
}
```
发现Texture对象没有分配纹理id，则调用glGenTextures进行分配。


#### GLConsumer attachToContext
文件： /[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[GLConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/GLConsumer.cpp)

```cpp
status_t GLConsumer::attachToContext(uint32_t tex) {
    ATRACE_CALL();
    GLC_LOGV("attachToContext");
    Mutex::Autolock lock(mMutex);

    if (mAbandoned) {
        GLC_LOGE("attachToContext: abandoned GLConsumer");
        return NO_INIT;
    }

    if (mAttached) {
        GLC_LOGE("attachToContext: GLConsumer is already attached to a "
                "context");
        return INVALID_OPERATION;
    }

    EGLDisplay dpy = eglGetCurrentDisplay();
    EGLContext ctx = eglGetCurrentContext();

    if (dpy == EGL_NO_DISPLAY) {
        GLC_LOGE("attachToContext: invalid current EGLDisplay");
        return INVALID_OPERATION;
    }

    if (ctx == EGL_NO_CONTEXT) {
        GLC_LOGE("attachToContext: invalid current EGLContext");
        return INVALID_OPERATION;
    }

    // We need to bind the texture regardless of whether there's a current
    // buffer.
    glBindTexture(mTexTarget, GLuint(tex));

    mEglDisplay = dpy;
    mEglContext = ctx;
    mTexName = tex;
    mAttached = true;

    if (mCurrentTextureImage != NULL) {
        status_t err =  bindTextureImageLocked();
        if (err != NO_ERROR) {
            return err;
        }
    }

    return OK;
}
```
关键的核心还是在于glBindTexture，把从Java层SurfaceTexture构造函数传下来的mTexTarget和GlLayer的textureId互相绑定起来。

如果发现之前绘制过TextureImage，则使用这个TextureImage。但是此时还是第一次初始化，并不会走到这个分支。

#### DeferredLayerUpdater doUpdateTexImage
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[DeferredLayerUpdater.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/DeferredLayerUpdater.cpp)

```cpp
void DeferredLayerUpdater::doUpdateTexImage() {

    if (mSurfaceTexture->updateTexImage() == NO_ERROR) {
        float transform[16];

        int64_t frameNumber = mSurfaceTexture->getFrameNumber();
        int dropCounter = 0;
        while (mSurfaceTexture->updateTexImage() == NO_ERROR) {
            int64_t newFrameNumber = mSurfaceTexture->getFrameNumber();
            if (newFrameNumber == frameNumber) break;
            frameNumber = newFrameNumber;
            dropCounter++;
        }

        bool forceFilter = false;
        sp<GraphicBuffer> buffer = mSurfaceTexture->getCurrentBuffer();
        if (buffer != nullptr) {
            // force filtration if buffer size != layer size
            forceFilter = mWidth != static_cast<int>(buffer->getWidth()) ||
                          mHeight != static_cast<int>(buffer->getHeight());
        }

        mSurfaceTexture->getTransformMatrix(transform);

        updateLayer(forceFilter, transform, mSurfaceTexture->getCurrentDataSpace());
    }
}

void DeferredLayerUpdater::updateLayer(bool forceFilter, const float* textureTransform,
                                       android_dataspace dataspace) {
    mLayer->setBlend(mBlend);
    mLayer->setForceFilter(forceFilter);
    mLayer->setSize(mWidth, mHeight);
    mLayer->getTexTransform().load(textureTransform);
    mLayer->setDataSpace(dataspace);
}

```
其实在整个doUpdateTexImage流程中，核心是调用了GLConsumer的updateTexImage更新里面需要消费的纹理以及图元。最后设置透明混合，大小，变换矩阵，颜色空间等。

#### GLConsumer updateTexImage
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[GLConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/GLConsumer.cpp)

```cpp
status_t GLConsumer::updateTexImage() {
    ATRACE_CALL();
    Mutex::Autolock lock(mMutex);

    if (mAbandoned) {
        GLC_LOGE("updateTexImage: GLConsumer is abandoned!");
        return NO_INIT;
    }

    status_t err = checkAndUpdateEglStateLocked();
    if (err != NO_ERROR) {
        return err;
    }

    BufferItem item;

    err = acquireBufferLocked(&item, 0);
...

    // Release the previous buffer.
    err = updateAndReleaseLocked(item);
    if (err != NO_ERROR) {
        // We always bind the texture.
        glBindTexture(mTexTarget, mTexName);
        return err;
    }

    // Bind the new buffer to the GL texture, and wait until it's ready.
    return bindTextureImageLocked();
}
```
这里面的流程其实和SF系列那一篇的流程几乎一致，[Android 重学系列 图元的消费](https://www.jianshu.com/p/67c1e350fe0d)。首先通过acquireBufferLocked获取需要消费的Buffer，其次通过updateAndReleaseLocked更新当前需要消费的图元，并且释放，最后调用bindTextureImageLocked进行mCurrentTextureImage的创建，并且进行同步栅的等待。

让我们看看每一个步骤究竟和SF进程中图元消费有什么区别。

#### GLConsumer acquireBufferLocked
```cpp
status_t GLConsumer::acquireBufferLocked(BufferItem *item,
        nsecs_t presentWhen, uint64_t maxFrameNumber) {
    status_t err = ConsumerBase::acquireBufferLocked(item, presentWhen,
            maxFrameNumber);
    if (err != NO_ERROR) {
        return err;
    }

    if (item->mGraphicBuffer != NULL) {
        int slot = item->mSlot;
        mEglSlots[slot].mEglImage = new EglImage(item->mGraphicBuffer);
    }

    return NO_ERROR;
}
```

```cpp
status_t ConsumerBase::acquireBufferLocked(BufferItem *item,
        nsecs_t presentWhen, uint64_t maxFrameNumber) {
...
    status_t err = mConsumer->acquireBuffer(item, presentWhen, maxFrameNumber);
...
    if (item->mGraphicBuffer != NULL) {
        if (mSlots[item->mSlot].mGraphicBuffer != NULL) {
            freeBufferLocked(item->mSlot);
        }
        mSlots[item->mSlot].mGraphicBuffer = item->mGraphicBuffer;
    }

    mSlots[item->mSlot].mFrameNumber = item->mFrameNumber;
    mSlots[item->mSlot].mFence = item->mFence;

    return OK;
}
```
mConsumer此时就是上文BufferQueue::createBufferQueue生成的一个本地的BufferQueueConsumer。并且设置mSlots当前的mGraphicBuffer，在GLConsumer中同时在对应的位置也保存了一个EglImage。并且释放当前到GraphicBuffer对应槽的状态。

换句话说，GLConsumer的职责在这里和BufferLayerConsumer几乎一致。

#### GLConsumer updateAndReleaseLocked
```cpp
status_t GLConsumer::updateAndReleaseLocked(const BufferItem& item,
        PendingRelease* pendingRelease)
{
    status_t err = NO_ERROR;

    int slot = item.mSlot;

    if (!mAttached) {
        return INVALID_OPERATION;
    }

    // Confirm state.
    err = checkAndUpdateEglStateLocked();
    if (err != NO_ERROR) {
        releaseBufferLocked(slot, mSlots[slot].mGraphicBuffer,
                mEglDisplay, EGL_NO_SYNC_KHR);
        return err;
    }

    // Ensure we have a valid EglImageKHR for the slot, creating an EglImage
    // if nessessary, for the gralloc buffer currently in the slot in
    // ConsumerBase.
    // We may have to do this even when item.mGraphicBuffer == NULL (which
    // means the buffer was previously acquired).
    err = mEglSlots[slot].mEglImage->createIfNeeded(mEglDisplay, item.mCrop);
    if (err != NO_ERROR) {
        return UNKNOWN_ERROR;
    }

    // Do whatever sync ops we need to do before releasing the old slot.
    if (slot != mCurrentTexture) {
        err = syncForReleaseLocked(mEglDisplay);
        if (err != NO_ERROR) {
            // Release the buffer we just acquired.  It's not safe to
            releaseBufferLocked(slot, mSlots[slot].mGraphicBuffer,
                    mEglDisplay, EGL_NO_SYNC_KHR);
            return err;
        }
    }


    // Hang onto the pointer so that it isn't freed in the call to
    // releaseBufferLocked() if we're in shared buffer mode and both buffers are
    // the same.
    sp<EglImage> nextTextureImage = mEglSlots[slot].mEglImage;

    // release old buffer
    if (mCurrentTexture != BufferQueue::INVALID_BUFFER_SLOT) {
        if (pendingRelease == nullptr) {
            status_t status = releaseBufferLocked(
                    mCurrentTexture, mCurrentTextureImage->graphicBuffer(),
                    mEglDisplay, mEglSlots[mCurrentTexture].mEglFence);
            if (status < NO_ERROR) {
                err = status;
                // keep going, with error raised [?]
            }
        } else {
            pendingRelease->currentTexture = mCurrentTexture;
            pendingRelease->graphicBuffer =
                    mCurrentTextureImage->graphicBuffer();
            pendingRelease->display = mEglDisplay;
            pendingRelease->fence = mEglSlots[mCurrentTexture].mEglFence;
            pendingRelease->isPending = true;
        }
    }

    // Update the GLConsumer state.
    mCurrentTexture = slot;
    mCurrentTextureImage = nextTextureImage;
    mCurrentCrop = item.mCrop;
    mCurrentTransform = item.mTransform;
    mCurrentScalingMode = item.mScalingMode;
    mCurrentTimestamp = item.mTimestamp;
    mCurrentDataSpace = item.mDataSpace;
    mCurrentFence = item.mFence;
    mCurrentFenceTime = item.mFenceTime;
    mCurrentFrameNumber = item.mFrameNumber;

    computeCurrentTransformMatrixLocked();

    return err;
}
```
这里的逻辑也几乎和BufferQueueConsumer一致，也是释放上一次的GraphicBuffer以及EglImage对象。接着保存当前需要渲染的GraphicBuffer和EglImage。

#### GLConsumer bindTextureImageLocked
```cpp
status_t GLConsumer::bindTextureImageLocked() {
    if (mEglDisplay == EGL_NO_DISPLAY) {
        ALOGE("bindTextureImage: invalid display");
        return INVALID_OPERATION;
    }

...
    glBindTexture(mTexTarget, mTexName);
...
    status_t err = mCurrentTextureImage->createIfNeeded(mEglDisplay,
                                                        mCurrentCrop);
    if (err != NO_ERROR) {
        return UNKNOWN_ERROR;
    }
    mCurrentTextureImage->bindToTextureTarget(mTexTarget);

....

    // Wait for the new buffer to be ready.
    return doGLFenceWaitLocked();
}
```
- 1.mCurrentTextureImage EglImage这个对象的createIfNeeded尝试创建需要绘制的纹理对应的内存。
- 2.EglImage bindToTextureTarget 绑定绘制的纹理
- 3.doGLFenceWaitLocked 等待OpenGL es绘制成功

#### EglImage createIfNeeded
```cpp
status_t GLConsumer::EglImage::createIfNeeded(EGLDisplay eglDisplay,
                                              const Rect& cropRect,
                                              bool forceCreation) {
    // If there's an image and it's no longer valid, destroy it.
    bool haveImage = mEglImage != EGL_NO_IMAGE_KHR;
    bool displayInvalid = mEglDisplay != eglDisplay;
    bool cropInvalid = hasEglAndroidImageCrop() && mCropRect != cropRect;
    if (haveImage && (displayInvalid || cropInvalid || forceCreation)) {
        if (!eglDestroyImageKHR(mEglDisplay, mEglImage)) {
           ALOGE("createIfNeeded: eglDestroyImageKHR failed");
        }
        eglTerminate(mEglDisplay);
        mEglImage = EGL_NO_IMAGE_KHR;
        mEglDisplay = EGL_NO_DISPLAY;
    }

    // If there's no image, create one.
    if (mEglImage == EGL_NO_IMAGE_KHR) {
        mEglDisplay = eglDisplay;
        mCropRect = cropRect;
        mEglImage = createImage(mEglDisplay, mGraphicBuffer, mCropRect);
    }

    // Fail if we can't create a valid image.
    if (mEglImage == EGL_NO_IMAGE_KHR) {
        mEglDisplay = EGL_NO_DISPLAY;
        mCropRect.makeInvalid();
        const sp<GraphicBuffer>& buffer = mGraphicBuffer;
        ALOGE("Failed to create image. size=%ux%u st=%u usage=%#" PRIx64 " fmt=%d",
            buffer->getWidth(), buffer->getHeight(), buffer->getStride(),
            buffer->getUsage(), buffer->getPixelFormat());
        return UNKNOWN_ERROR;
    }

    return OK;
}

EGLImageKHR GLConsumer::EglImage::createImage(EGLDisplay dpy,
        const sp<GraphicBuffer>& graphicBuffer, const Rect& crop) {
    EGLClientBuffer cbuf =
            static_cast<EGLClientBuffer>(graphicBuffer->getNativeBuffer());
    const bool createProtectedImage =
            (graphicBuffer->getUsage() & GRALLOC_USAGE_PROTECTED) &&
            hasEglProtectedContent();
    EGLint attrs[] = {
        EGL_IMAGE_PRESERVED_KHR,        EGL_TRUE,
        EGL_IMAGE_CROP_LEFT_ANDROID,    crop.left,
        EGL_IMAGE_CROP_TOP_ANDROID,     crop.top,
        EGL_IMAGE_CROP_RIGHT_ANDROID,   crop.right,
        EGL_IMAGE_CROP_BOTTOM_ANDROID,  crop.bottom,
        createProtectedImage ? EGL_PROTECTED_CONTENT_EXT : EGL_NONE,
        createProtectedImage ? EGL_TRUE : EGL_NONE,
        EGL_NONE,
    };
    if (!crop.isValid()) {
        // No crop rect to set, so leave the crop out of the attrib array. Make
        // sure to propagate the protected content attrs if they are set.
        attrs[2] = attrs[10];
        attrs[3] = attrs[11];
        attrs[4] = EGL_NONE;
    } else if (!isEglImageCroppable(crop)) {
        // The crop rect is not at the origin, so we can't set the crop on the
        // EGLImage because that's not allowed by the EGL_ANDROID_image_crop
        // extension.  In the future we can add a layered extension that
        // removes this restriction if there is hardware that can support it.
        attrs[2] = attrs[10];
        attrs[3] = attrs[11];
        attrs[4] = EGL_NONE;
    }
    eglInitialize(dpy, 0, 0);
    EGLImageKHR image = eglCreateImageKHR(dpy, EGL_NO_CONTEXT,
            EGL_NATIVE_BUFFER_ANDROID, cbuf, attrs);
    if (image == EGL_NO_IMAGE_KHR) {
        EGLint error = eglGetError();
        ALOGE("error creating EGLImage: %#x", error);
        eglTerminate(dpy);
    }
    return image;
}
```
这里面做的事情本质上和SF进程上几乎一致，也是在EglImage中的EGLImageKHR判断是否初始化，没有初始化则调用createImage创建一个OpenGL es的直接纹理。关于这种纹理，我在[OpenGL es上的封装(下)](https://www.jianshu.com/p/29ab1b15cd2a)已经和大家聊过了。是一种基于Android平台的纹理优化方案。之后OpenGL es渲染这个纹理的时候，就会直接渲染到对应的GraphicBuffer的内存中。


#### EglImage bindToTextureTarget
```cpp
void GLConsumer::EglImage::bindToTextureTarget(uint32_t texTarget) {
    glEGLImageTargetTexture2DOES(texTarget,
            static_cast<GLeglImageOES>(mEglImage));
}
```
很简单，就是绑定一个OES的纹理。记住此时的texTarget就是GL_TEXTURE_EXTERNAL_OES，这样就把EGLImageKHR和一个YUV格式的纹理绑定起来了。经过这个步骤之后，GraphicBuffer的像素内存就和EglImage的像素内存绑定起来了。

#### GLConsumer doGLFenceWaitLocked
```cpp
status_t GLConsumer::doGLFenceWaitLocked() const {

    EGLDisplay dpy = eglGetCurrentDisplay();
    EGLContext ctx = eglGetCurrentContext();

    if (mEglDisplay != dpy || mEglDisplay == EGL_NO_DISPLAY) {
        GLC_LOGE("doGLFenceWait: invalid current EGLDisplay");
        return INVALID_OPERATION;
    }

    if (mEglContext != ctx || mEglContext == EGL_NO_CONTEXT) {
        GLC_LOGE("doGLFenceWait: invalid current EGLContext");
        return INVALID_OPERATION;
    }

    if (mCurrentFence->isValid()) {
        if (SyncFeatures::getInstance().useWaitSync() &&
            SyncFeatures::getInstance().useNativeFenceSync()) {
            // Create an EGLSyncKHR from the current fence.
            int fenceFd = mCurrentFence->dup();
            if (fenceFd == -1) {
                GLC_LOGE("doGLFenceWait: error dup'ing fence fd: %d", errno);
                return -errno;
            }
            EGLint attribs[] = {
                EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fenceFd,
                EGL_NONE
            };
            EGLSyncKHR sync = eglCreateSyncKHR(dpy,
                    EGL_SYNC_NATIVE_FENCE_ANDROID, attribs);
...
            // XXX: The spec draft is inconsistent as to whether this should
            // return an EGLint or void.  Ignore the return value for now, as
            // it's not strictly needed.
            eglWaitSyncKHR(dpy, sync, 0);
            EGLint eglErr = eglGetError();
            eglDestroySyncKHR(dpy, sync);
...
        } else {
            status_t err = mCurrentFence->waitForever(
                    "GLConsumer::doGLFenceWaitLocked");
            if (err != NO_ERROR) {
                GLC_LOGE("doGLFenceWait: error waiting for fence: %d", err);
                return err;
            }
        }
    }

    return NO_ERROR;
}
```
在这里面，也是和SF进行一样进行OpenGL es的同步栅阻塞，直到OpenGL es的唤醒。

### 绘制的小结
我们再整理一次思路。每一次硬件绘制总是从ThreadRenderer开始进行绘制，在这个过程中传递一个DisplayListCanvas下去(目的是为了共享根部的DisplayList变相的在native层总构建View tree)。在这个过程中硬件渲染会遍历每一个RenderNode对应的View中的draw方法，这个过程中会draw在每一个View自己的DisplayListCanvas中。TextureView的draw方法中，会初始化SurfaceTexture以及TextureLayer。

而在这里面SurfaceTexture包含了GLConsumer，而GLConsumer扮演的是TextureView的图元消费者。他决定了此刻需要消费的图元是对应哪一个图元槽。

接着会调用DrawLayer的方法尝试的绘制Layer中的内容。然而第一次调用draw方法并没有初始化DeferredLayerUpdater中的GlLayer对象。因此绘制时机会推后到下一个draw方法调用，等到ThreadRenderer遍历完DisplayList后调用syncFrameState方法，使得DeferredLayerUpdater生成GlLayer。之后才能正常绘制纹理中的像素。

### LayerDrawable DrawLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[pipeline](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/)/[skia](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/)/[LayerDrawable.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/pipeline/skia/LayerDrawable.cpp)
```cpp
bool LayerDrawable::DrawLayer(GrContext* context, SkCanvas* canvas, Layer* layer,
                              const SkRect* dstRect) {
...
    // transform the matrix based on the layer
    SkMatrix layerTransform;
    layer->getTransform().copyTo(layerTransform);
    sk_sp<SkImage> layerImage;
    const int layerWidth = layer->getWidth();
    const int layerHeight = layer->getHeight();
    if (layer->getApi() == Layer::Api::OpenGL) {
        GlLayer* glLayer = static_cast<GlLayer*>(layer);
        GrGLTextureInfo externalTexture;
        externalTexture.fTarget = glLayer->getRenderTarget();
        externalTexture.fID = glLayer->getTextureId();

        externalTexture.fFormat = GL_RGBA8;
        GrBackendTexture backendTexture(layerWidth, layerHeight, GrMipMapped::kNo, externalTexture);
        layerImage = SkImage::MakeFromTexture(context, backendTexture, kTopLeft_GrSurfaceOrigin,
                                              kPremul_SkAlphaType, nullptr);
    } else {
...
    }

    if (layerImage) {
        SkMatrix textureMatrixInv;
        layer->getTexTransform().copyTo(textureMatrixInv);
        // TODO: after skia bug https://bugs.chromium.org/p/skia/issues/detail?id=7075 is fixed
        // use bottom left origin and remove flipV and invert transformations.
        SkMatrix flipV;
        flipV.setAll(1, 0, 0, 0, -1, 1, 0, 0, 1);
        textureMatrixInv.preConcat(flipV);
        textureMatrixInv.preScale(1.0f / layerWidth, 1.0f / layerHeight);
        textureMatrixInv.postScale(layerWidth, layerHeight);
        SkMatrix textureMatrix;
        if (!textureMatrixInv.invert(&textureMatrix)) {
            textureMatrix = textureMatrixInv;
        }

        SkMatrix matrix = SkMatrix::Concat(layerTransform, textureMatrix);

        SkPaint paint;
        paint.setAlpha(layer->getAlpha());
        paint.setBlendMode(layer->getMode());
        paint.setColorFilter(layer->getColorSpaceWithFilter());

        const bool nonIdentityMatrix = !matrix.isIdentity();
        if (nonIdentityMatrix) {
            canvas->save();
            canvas->concat(matrix);
        }
        if (dstRect) {
            SkMatrix matrixInv;
            if (!matrix.invert(&matrixInv)) {
                matrixInv = matrix;
            }
            SkRect srcRect = SkRect::MakeIWH(layerWidth, layerHeight);
            matrixInv.mapRect(&srcRect);
            SkRect skiaDestRect = *dstRect;
            matrixInv.mapRect(&skiaDestRect);
            canvas->drawImageRect(layerImage.get(), srcRect, skiaDestRect, &paint,
                                  SkCanvas::kFast_SrcRectConstraint);
        } else {
            canvas->drawImage(layerImage.get(), 0, 0, &paint);
        }
        // restore the original matrix
        if (nonIdentityMatrix) {
            canvas->restore();
        }
    }

    return layerImage;
}
```
请注意此时的Canvas就是从ThreadRenderer中传递下来的DisplayListCanvas(不准确，暂时这么认为)。

接下来将执行如下步骤：
- 1.判断到是OpenGL类型的pipeline。接着通过GlLayer保存的纹理对象生成GrBackendTexture里面保存着当前TextureLayer的宽高(也就是TextureView在draw中applyUpdate的保存下来的TextureView的宽高)。最后通过GrBackendTexture生成一个SkImage对象。
- 2.根据变换矩阵处理SkImage
- 3.canvas 在一个区域内绘制SkImage中的像素。

到这里面就完成了TextureView的解析。

## 总结
这两篇文章并没有太过详细的分析软件渲染和硬件渲染。但是还是从SurfaceView和TextureView两者看到两者之间的区别。先来用一幅图总结TextureView的硬件绘制流程。

![TextureView硬件渲染.jpg](https://upload-images.jianshu.io/upload_images/9880421-f74e1722d383126b.jpg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

请注意这里面从RootRenderNode中分发DisplayListCanvas下去，是为了共享来自同一个DisplayListCanvas中的DisplayList树。但是每一个RenderNode都会在自己的DisplaylistCanvas中进行绘制。

官方也有对Android的Graphic体系，进行一次简单的原理示意图:
![TextureView大致示意图.png](https://upload-images.jianshu.io/upload_images/9880421-1d4efc9602b05e48.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

其实官方这一副图已经很好的解释了TextureView和系统之间的合作关系。但是实际上还是不够仔细，也不够准确。在我看来OpenGL es不应该只是一个图元的消费者，同时也可以当作一个图元的生产者。由于OpenGL es和Skia的特殊性，我一般不会把这两者都成为消费者和生产者，我喜欢称它们是像素的加工者，或者说是画笔。

可能到这里还是不够详细，这里根据本文画了一个更为详细的核心原理图:
![TextureView的核心原理.jpg](https://upload-images.jianshu.io/upload_images/9880421-05463804931ea298.jpg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

总结一下，里面有几个十分关键的角色：
- 1.ThreadedRenderer 是硬件渲染的入口点，里面包含了所有硬件渲染的根RenderNode，以及一个根DisplayListCanvas。虽然每一个View一般都会包含自己的DisplayListCanvas。之所以存在一个根是为了公用一个DisplayListCanvas中的DisplayList。
- 2.CanvasContext 硬件渲染的上下文，根据当前模式选择合适的硬件渲染管道。而管道就是真正执行具体模式的绘制行为。
- 3.DrawFrameTask 保存所有的App中硬件渲染的Layer。当然这个Layer要和SF进程的Layer要区分，不是一个东西。在TextureView中是指DeferredLayerUpdater，真正执行具体行为的是GlLayer。
- 4.TextureLayer 在TextureView中承担一个TextureView 图层角色。其中包含了TextureView图元消费端SurfaceTexture，图层更新者DeferredLayerUpdater，以及ThreadedRenderer。
- 5.DeferredLayerUpdater 图层更新者。这相当于一个Holder，不会一开始就从内存中申请一个纹理对象。纹理对象可是很消耗内存的。因此会等到第一次draw调用之后，才会通过syncFrame的方法从CanvasContext生成GlLayer。GlLayer则是真正的控制图层，而这个图层实际上就是一个OpenGL es的纹理对象。
- 6.RenderNode 每一个View在硬件渲染对应的每一个节点。
- 7.DisplayListCanvas 通过RenderNode生成的一个画板。所有的像素都会画上去，并且可以和来自父View中DisplayListCanvas的DisplayList进行合并。

关键对象已经总结了这么多了。从上图就能明白实际上TextureView之所以称为textureView是因为他控制的是一个纹理对象。

那么，他的执行流程也是如何呢？在上面那个例子TextureView之所以可以正常的运作，是因为把SurfaceTexture设置到Camera中了。让Camera在背后操作图元消费者SurfaceTexture。

重新梳理一次流程。
- 1.当我们把Camera都设置了TextureView之后，经过第一次的draw之后，将会创建一个TextureLayer，GLConsumer。此时draw的遍历结束，就会执行ThreadedRenderer的syncFrameState方法，生成真正的GlLayer，并且调用invalid进行下一轮的绘制。

- 2.进入到下一轮的绘制之后，将会继续调用DisplayListCanvas的drawTextureLayer，进行DrawLayer的方法调用，把像素绘制到DisplayListCanvas中，最后调用CanvasContext的draw的方法，并且通过其中的swapBuffers把图元发送的SF进程。

换句话说，我们在TextureView中不断的更新纹理的内容，而纹理的绘制和发送却依赖ViewRootImpl发送的draw信号。因此我们没有办法看到像软件渲染那样有lockCanvas和unlockCanvasAndPost的方法那样在绘制前后有一个明显的dequeueBuffer和queueBuffer的操作。如果阅读过我写的OpenGL es软件渲染一文，就能明白其实swapBuffer方法里面本身就带着dequeueBuffer和queueBuffer的方法。


回到开始的问题。TextureView和SurfaceView两者之间最本质的区别是什么？在这里我们就能回答TextureView本质上是控制一个硬件的纹理对象，刷新频率依赖ViewRootImpl，除非你是用lockCanvas的api才会通过临时的Surface直接沟通SF进程。其宽高是在draw方法的时候每一次进行prepare的时候重新设置上去，所以他的宽高本质上是跟着View的三大绘制流程走的。因此TextureView才能做到如共享动画等需要同步宽高的操作。TextureView为了执行的同步性，在Handler的Looper中一个，渲染线程RenderThread分别做了事件入队操作，这就是TextureView为什么慢的原因。

SurfaceView本质上就是控制一个Surface对象，操作的单位不是纹理而是一个GraphicBuffer对象。其宽高本质上不会和View的绘制进行同步的，而是跟着Surface每一次刷新之后回调设置的。


## 后话
到这里textureview和surefaceview两个比较常用的View解析，稍微打开了一扇软硬件View的绘制流程大门。下一篇，我们就复习一下View的绘制流程。这个是经常考的考点，虽然老生常谈，我们还是需要慎重对待。





