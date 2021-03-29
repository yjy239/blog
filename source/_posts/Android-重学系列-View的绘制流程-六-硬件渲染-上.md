---
title: Android 重学系列 View的绘制流程(六) 硬件渲染(上)
top: false
cover: false
date: 2020-06-30 23:13:09
img:
tag:
description:
author: yjy239
summary:
categories: View的绘制流程
tags: 
- Android
- Android Framework
---
# 前言
本文开始聊聊Android中的硬件渲染。如果跟着我的文章顺序，从SF进程到App进程的绘制流程一直阅读，我们到这里已经有了一定的基础，可以试着进行横向比对如Chrome浏览器渲染流程，看看软件渲染，硬件渲染，SF合成都做了什么程度的优化。

先让我们回顾一下负责硬件渲染的主体对象ThreadedRenderer在整个绘制流程中做了哪几个步骤。
- 1.enableHardwareAcceleration 实例化ThreadedRenderer
- 2.initialize 初始化
- 3.updateSurface 更新Surface
- 4.setup 启动ThreadedRenderer设置阴影等参数
- 5.如果需要 执行invalidateRoot 判断是否需要从根部开始遍历查找无效的元素
- 6.draw 开始硬件渲染进行View层级绘制
- 7.updateDisplayListIfDirty 更新硬件渲染中的脏区
- 8.destroy 销毁硬件渲染对象

在硬件渲染的过程中，有一个很核心的对象RenderNode，作为每一个View绘制的节点对象。

当每一次进行准备进行绘制的时候，都会雷打不动执行如下三个步骤：
- 1.RenderNode.start 生成一个新的DisplayListCanvas
- 2.DisplayListCanvas 上进行绘制 如调用Drawable的draw方法，把DisplayListCanvas作为参数
- 3.RenderNode.end 完成RenderNode的操作



# 正文
实际上整个硬件渲染的设计还是比较庞大。因此本文先聊聊ThreadedRender整个体系中主要对象的构造以及相关的原理。

首先来认识下面几个重要的对象有一个大体的印象。
- 1.ThreadedRenderer 管理所有的硬件渲染对象，也是ViewRootImpl进行硬件渲染的入口对象。
- 2.RenderNode 每一个View都会携带的对象，当打开了硬件渲染的时候，将会根据判断，把相关的渲染逻辑移动到RenderNode中。
- 3.DisplayListCanvas 每一个RenderNode真正开始绘制自己的内容之前，需要通过RenderNode生成一个DisplayListCanvas，所有的绘制的行为都会在DisplayListCanvas中绘制，最后DisplayListCanvas会保存会RenderNode中。

在Java层中面向Framework中，只有这么多，下面是一一映射的简图。
![硬件渲染.jpg](/images/TextureView硬件渲染.jpg)

能看到实际上RenderNode也会跟着View 树的构建同时一起构建整个显示层级。也是因此ThreadedRender也能以RenderNode为线索构建出一套和软件渲染一样的渲染流程。

仅仅这样？如果只是这么简单，知道我习惯的都知道，我喜欢把相关总结写在最后。如果把总揽写在正文开头是因为设计比较繁多。因为我们如果以流水线的形式进行剖析容易造成迷失细节的困境。

让我继续介绍一下，在硬件渲染中native层的核心对象。
- 1.RootRenderNode 所有RenderNode的根部RenderNode，一切的View层级结构遍历都从这个RenderNode开始。类似View中DecorView的职责。但是DecorView并非和RootRenderNode对应，而是拥有自己的RenderNode。

- 2.RenderNode 对应于Java层的native对象

- 3.RenderThread 硬件渲染线程，所有的渲染任务都会在该线程中使用硬件渲染线程的Looper进行。

- 4.CanvasContext 是所有的渲染的上下文，它将持用PipeLine渲染管道

- 5.PipeLine 如OpenGLPipeLine，SkiaOpenGLPipeLine，VulkanPipeLine渲染管道。而这个渲染管道将会根据Android系统的配置，执行真正的渲染行为

- 6.DrawFrameTask 是整个ThreadedRender中真正开始执行渲染的对象

- 7.RenderNodeProxy  ThreadedRender的对应native层的入口。它将全局的作为RootRenderNode，CanvasContext，以及RenderThread门面（门面设计模式）。

如下是一个思维导图：
![ThreadedRender对象.png](/images/ThreadedRender对象.png)

有这么一个大体印象后，就不容易迷失在源码中。我们先来把这些对象的实例化以及上面列举的ThreadedRenderer在ViewRootImpl中执行行为的顺序和大家来聊聊其原理，先来看看ThreadedRenderer的实例化。


## ThreadedRenderer 实例化
当发现mSurfaceHolder为空的时候会调用如下函数：
```java
                if (mSurfaceHolder == null) {
                    enableHardwareAcceleration(attrs);
....
                }
```
而这个方法则调用如下的方法对ThreadedRenderer进行创建：
```java
 mAttachInfo.mThreadedRenderer = ThreadedRenderer.create(mContext, translucent,
                        attrs.getTitle().toString());
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ThreadedRenderer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ThreadedRenderer.java)

```java
    public static boolean isAvailable() {
        if (sSupportsOpenGL != null) {
            return sSupportsOpenGL.booleanValue();
        }
        if (SystemProperties.getInt("ro.kernel.qemu", 0) == 0) {
            sSupportsOpenGL = true;
            return true;
        }
        int qemu_gles = SystemProperties.getInt("qemu.gles", -1);
        if (qemu_gles == -1) {
            return false;
        }
        sSupportsOpenGL = qemu_gles > 0;
        return sSupportsOpenGL.booleanValue();
    }


    public static ThreadedRenderer create(Context context, boolean translucent, String name) {
        ThreadedRenderer renderer = null;
        if (isAvailable()) {
            renderer = new ThreadedRenderer(context, translucent, name);
        }
        return renderer;
    }
```
能不能创建的了ThreadedRenderer则决定于全局配置。如果ro.kernel.qemu的配置为0，说明支持OpenGL 则可以直接返回true。如果qemu.gles为-1说明不支持OpenGL es返回false，只能使用软件渲染。如果设置了qemu.gles并大于0，才能打开硬件渲染。

### ThreadedRenderer构造函数
```java
    ThreadedRenderer(Context context, boolean translucent, String name) {
...

        long rootNodePtr = nCreateRootRenderNode();
        mRootNode = RenderNode.adopt(rootNodePtr);
        mRootNode.setClipToBounds(false);
        mIsOpaque = !translucent;
        mNativeProxy = nCreateProxy(translucent, rootNodePtr);
        nSetName(mNativeProxy, name);

        ProcessInitializer.sInstance.init(context, mNativeProxy);

        loadSystemProperties();
    }
```
我们能看到ThreadedRenderer在初始化，做了三件事情：
- 1.nCreateRootRenderNode 创建native层的RootRenderNode，也就是所有RenderNode的根。类似DecorView的角色，是所有View的父布局，我们把整个View层次看成一个树，那么这里是根节点。
- 2.RenderNode.adopt  根据native的 RootRenderNode创建Java层的根部RenderNode。
- 3.nCreateProxy 创建RenderNode的代理者，nSetName给该代理者赋予名字。
- 4.ProcessInitializer的初始化graphicsstats服务
- 5.loadSystemProperties 读取系统给硬件渲染器设置的属性。

关键是看1-3点中ThreadRenderer都做了什么。

#### nCreateRootRenderNode 
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)
```cpp
static jlong android_view_ThreadedRenderer_createRootRenderNode(JNIEnv* env, jobject clazz) {
    RootRenderNode* node = new RootRenderNode(env);
    node->incStrong(0);
    node->setName("RootRenderNode");
    return reinterpret_cast<jlong>(node);
}
```
能看到这里是直接实例化一个RootRenderNode对象，并把指针的地址直接返回。
```cpp
class RootRenderNode : public RenderNode, ErrorHandler {
public:
    explicit RootRenderNode(JNIEnv* env) : RenderNode() {
        mLooper = Looper::getForThread();
        env->GetJavaVM(&mVm);
    }
}
```
能看到RootRenderNode继承了RenderNode对象，并且保存一个JavaVM也就是我们所说的Java虚拟机对象，一个java进程全局只有一个。同时通过getForThread方法，获取ThreadLocal中的Looper对象。这里实际上拿的就是UI线程的Looper。

##### native层RenderNode 的实例化
```cpp
RenderNode::RenderNode()
        : mDirtyPropertyFields(0)
        , mNeedsDisplayListSync(false)
        , mDisplayList(nullptr)
        , mStagingDisplayList(nullptr)
        , mAnimatorManager(*this)
        , mParentCount(0) {}
```
在这个构造函数有一个mDisplayList十分重要，记住之后会频繁出现。接着来看看RenderNode的头文件：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RenderNode.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RenderNode.h)
```cpp
class RenderNode : public VirtualLightRefBase {
    friend class TestUtils;  // allow TestUtils to access syncDisplayList / syncProperties
    friend class FrameBuilder;

public:
....
    ANDROID_API void setStagingDisplayList(DisplayList* newData);

...
    bool isValid() { return mValid; }

    int getWidth() const { return properties().getWidth(); }

    int getHeight() const { return properties().getHeight(); }

...
    AnimatorManager& animators() { return mAnimatorManager; }

....

    const DisplayList* getDisplayList() const { return mDisplayList; }
    OffscreenBuffer* getLayer() const { return mLayer; }
    OffscreenBuffer** getLayerHandle() { return &mLayer; }  // ugh...
    void setLayer(OffscreenBuffer* layer) { mLayer = layer; }
....
private:
...
    String8 mName;
...
    uint32_t mDirtyPropertyFields;
    RenderProperties mProperties;
    RenderProperties mStagingProperties;

    bool mValid = false;

    DisplayList* mDisplayList;
    DisplayList* mStagingDisplayList;

    friend class AnimatorManager;
    AnimatorManager mAnimatorManager;

    OffscreenBuffer* mLayer = nullptr;

    std::vector<RenderNodeOp*> mProjectedNodes;

...

private:
...
} /* namespace uirenderer */
} /* namespace android */
```
实际上我把几个重要的对象留下来：
- 1.mDisplayList 实际上就是RenderNode中持有的所有的子RenderNode对象
- 2.mStagingDisplayList 这个一般是一个View遍历完后保存下来的DisplayList，之后会在绘制行为之前转化为mDisplayList
- 3.RenderProperties mProperties 是指RenderNode的宽高等信息的存储对象
- 4.OffscreenBuffer mProperties RenderNode真正的渲染内存对象。


#### RenderNode.adopt
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[RenderNode.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/RenderNode.java)
```java
    public static RenderNode adopt(long nativePtr) {
        return new RenderNode(nativePtr);
    }
```
能看到很简单，就是包裹一个native层的RenderNode返回一个Java层对应的对象开放Java层的操作API。

#### nCreateProxy
```cpp
static jlong android_view_ThreadedRenderer_createProxy(JNIEnv* env, jobject clazz,
        jboolean translucent, jlong rootRenderNodePtr) {
    RootRenderNode* rootRenderNode = reinterpret_cast<RootRenderNode*>(rootRenderNodePtr);
    ContextFactoryImpl factory(rootRenderNode);
    return (jlong) new RenderProxy(translucent, rootRenderNode, &factory);
}
```
能看到这个过程生成了两个对象：
- 1.ContextFactoryImpl 动画上下文工厂

```cpp
class ContextFactoryImpl : public IContextFactory {
public:
    explicit ContextFactoryImpl(RootRenderNode* rootNode) : mRootNode(rootNode) {}

    virtual AnimationContext* createAnimationContext(renderthread::TimeLord& clock) {
        return new AnimationContextBridge(clock, mRootNode);
    }

private:
    RootRenderNode* mRootNode;
};
```
这个对象实际上让RenderProxy持有一个创建动画上下文的工厂。RenderProxy可以通过ContextFactoryImpl为每一个RenderNode创建一个动画执行对象的上下文AnimationContextBridge。

- 2.RenderProxy 一个 根RenderNode的代理对象。这个代理对象将作为所有绘制开始遍历入口。


#### RenderProxy 根RenderNode的代理对象的创建
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)

```cpp
RenderProxy::RenderProxy(bool translucent, RenderNode* rootRenderNode,
                         IContextFactory* contextFactory)
        : mRenderThread(RenderThread::getInstance()), mContext(nullptr) {
    mContext = mRenderThread.queue().runSync([&]() -> CanvasContext* {
        return CanvasContext::create(mRenderThread, translucent, rootRenderNode, contextFactory);
    });
    mDrawFrameTask.setContext(&mRenderThread, mContext, rootRenderNode);
}
```

在这里有几个十分重要的对象被实例化，当然这几个对象在聊TextureView有聊过([SurfaceView和TextureView 源码浅析](https://www.jianshu.com/p/1dce98846dc7))：
- 1.RenderThread 硬件渲染线程，所有的硬件渲染命令都需要经过这个线程排队执行。初始化方法如下：
```cpp
RenderThread::getInstance()
```
- 2.CanvasContext 一个硬件Canvas的上下文，一般来说就在这个上下文决定了使用OpenGL es还是其他的渲染管道。初始化方法如下：
```cpp
CanvasContext::create(mRenderThread, translucent, rootRenderNode, contextFactory);
```
- 2.DrawFrameTask 每一帧绘制的任务对象。

我们依次看看他们初始化都做了什么。

###  RenderThread的初始化和运行机制
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderThread.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderThread.cpp)

```cpp
RenderThread& RenderThread::getInstance() {
    static RenderThread* sInstance = new RenderThread();
    gHasRenderThreadInstance = true;
    return *sInstance;
}
```
能看到其实就是简单的调用RenderThread的构造函数进行实例化，并且返回对象的指针。

RenderThread是一个线程对象。先来看看其头文件继承的对象：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderThread.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderThread.h)

```cpp
class RenderThread : private ThreadBase {
    PREVENT_COPY_AND_ASSIGN(RenderThread);

public:
    // Sets a callback that fires before any RenderThread setup has occured.
    ANDROID_API static void setOnStartHook(void (*onStartHook)());

    WorkQueue& queue() { return ThreadBase::queue(); }
...
}
```
其中RenderThread的中进行排队处理的任务队列实际上是来自ThreadBase的WorkQueue对象。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[thread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/)/[ThreadBase.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/ThreadBase.h)

```java
class ThreadBase : protected Thread {
    PREVENT_COPY_AND_ASSIGN(ThreadBase);

public:
    ThreadBase()
            : Thread(false)
            , mLooper(new Looper(false))
            , mQueue([this]() { mLooper->wake(); }, mLock) {}

    WorkQueue& queue() { return mQueue; }

    void requestExit() {
        Thread::requestExit();
        mLooper->wake();
    }

    void start(const char* name = "ThreadBase") { Thread::run(name); }
...
}
```
ThreadBase则是继承于Thread对象。当调用start方法时候其实就是调用Thread的run方法启动线程。

另一个更加关键的对象，就是实例化一个Looper对象到WorkQueue中。而直接实例化Looper实际上就是新建一个Looper。但是这个Looper并没有获取当先线程的Looper，这个Looper做什么的呢？下文就会揭晓。

WorkQueue把一个Looper的方法指针设置到其中，其作用可能是完成了某一件任务后唤醒Looper继续工作。


```cpp
RenderThread::RenderThread()
        : ThreadBase()
        , mVsyncSource(nullptr)
        , mVsyncRequested(false)
        , mFrameCallbackTaskPending(false)
        , mRenderState(nullptr)
        , mEglManager(nullptr)
        , mVkManager(nullptr) {
    Properties::load();
    start("RenderThread");
}
```
- 1.先从Properties读取一些全局配置，进行一些如debug的配置。
- 2.start启动当前的线程

而start方法会启动Thread的run方法。而run方法最终会走到threadLoop方法中，至于是怎么走进来的，之后有机会会解剖虚拟机的源码线程篇章进行讲解。

#### RenderThread::threadLoop
```cpp
bool RenderThread::threadLoop() {
    setpriority(PRIO_PROCESS, 0, PRIORITY_DISPLAY);
    if (gOnStartHook) {
        gOnStartHook();
    }
    initThreadLocals();

    while (true) {
        waitForWork();
        processQueue();

        if (mPendingRegistrationFrameCallbacks.size() && !mFrameCallbackTaskPending) {
            drainDisplayEventQueue();
            mFrameCallbacks.insert(mPendingRegistrationFrameCallbacks.begin(),
                                   mPendingRegistrationFrameCallbacks.end());
            mPendingRegistrationFrameCallbacks.clear();
            requestVsync();
        }

        if (!mFrameCallbackTaskPending && !mVsyncRequested && mFrameCallbacks.size()) {
            requestVsync();
        }
    }

    return false;
}
```
在threadloop中关键的步骤有如下四个：
- 1.initThreadLocals 初始化线程本地变量
- 2.waitForWork 等待RenderThread的渲染工作
- 3.processQueue 执行保存在WorkQueue的渲染工作
- 4.mPendingRegistrationFrameCallbacks大于0或者mFrameCallbacks大于0；并且mFrameCallbackTaskPending为false，则会调用requestVsync，打开SF进程的EventThread的阻塞让监听返回。mFrameCallbackTaskPending这个方法代表Vsync信号来了并且执行则mFrameCallbackTaskPending为true。

##### initThreadLocals
```cpp
void RenderThread::initThreadLocals() {
    mDisplayInfo = DeviceInfo::queryDisplayInfo();
    nsecs_t frameIntervalNanos = static_cast<nsecs_t>(1000000000 / mDisplayInfo.fps);
    mTimeLord.setFrameInterval(frameIntervalNanos);
    initializeDisplayEventReceiver();
    mEglManager = new EglManager(*this);
    mRenderState = new RenderState(*this);
    mVkManager = new VulkanManager(*this);
    mCacheManager = new CacheManager(mDisplayInfo);
}
```
在这个过程中创建了几个核心对象：
- 1.EglManager 当使用OpenGL 相关的管道的时候，将会通过EglManager对OpenGL进行上下文等操作。
- 2.VulkanManager 当使用Vulkan 的渲染管道，将会使用VulkanManager进行操作(Vulkan 是新一代的3d硬件显卡渲染api，比起OpenGL更加轻量化，性能更佳)
- 3.RenderState 渲染状态，内有OpenGL和Vulkan的管道，需要渲染的Layer等。

另一个核心的方法就是initializeDisplayEventReceiver，这个方法为WorkQueue的Looper注册了监听：
```cpp
void RenderThread::initializeDisplayEventReceiver() {
    LOG_ALWAYS_FATAL_IF(mVsyncSource, "Initializing a second DisplayEventReceiver?");

    if (!Properties::isolatedProcess) {
        auto receiver = std::make_unique<DisplayEventReceiver>();
        status_t status = receiver->initCheck();

        mLooper->addFd(receiver->getFd(), 0, Looper::EVENT_INPUT,
                RenderThread::displayEventReceiverCallback, this);
        mVsyncSource = new DisplayEventReceiverWrapper(std::move(receiver));
    } else {
        mVsyncSource = new DummyVsyncSource(this);
    }
}
```
能看到在这个Looper中注册了对DisplayEventReceiver的监听，也就是Vsync信号的监听，回调方法为displayEventReceiverCallback。

我们暂时先对RenderThread的initializeDisplayEventReceiver方法探索到这里，我们稍后继续看看回调后的逻辑。


##### waitForWork 对Looper监听的对象进行阻塞等待
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[thread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/)/[ThreadBase.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/ThreadBase.h)

```cpp
    void waitForWork() {
        nsecs_t nextWakeup;
        {
            std::unique_lock lock{mLock};
            nextWakeup = mQueue.nextWakeup(lock);
        }
        int timeout = -1;
        if (nextWakeup < std::numeric_limits<nsecs_t>::max()) {
            timeout = ns2ms(nextWakeup - WorkQueue::clock::now());
            if (timeout < 0) timeout = 0;
        }
        int result = mLooper->pollOnce(timeout);
    }
```
能看到这里的逻辑很简单实际上就是调用Looper的pollOnce方法，阻塞Looper中的循环，直到Vsync的信号到来才会继续往下执行。详细的可以阅读我写的[Handler与相关系统调用的剖析](https://www.jianshu.com/p/416de2a3a1d6)系列文章。

##### processQueue
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[thread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/)/[ThreadBase.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/ThreadBase.h)
```cpp
void processQueue() { mQueue.process(); }
```
实际上调用的是WorkQueue的process方法。

###### WorkQueue的process
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[thread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/)/[WorkQueue.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/WorkQueue.h)
```cpp
    void process() {
        auto now = clock::now();
        std::vector<WorkItem> toProcess;
        {
            std::unique_lock _lock{mLock};
            if (mWorkQueue.empty()) return;
            toProcess = std::move(mWorkQueue);
            auto moveBack = find_if(std::begin(toProcess), std::end(toProcess),
                                    [&now](WorkItem& item) { return item.runAt > now; });
            if (moveBack != std::end(toProcess)) {
                mWorkQueue.reserve(std::distance(moveBack, std::end(toProcess)) + 5);
                std::move(moveBack, std::end(toProcess), std::back_inserter(mWorkQueue));
                toProcess.erase(moveBack, std::end(toProcess));
            }
        }
        for (auto& item : toProcess) {
            item.work();
        }
    }
```
能看到这个过程中很简单，几乎和Message的loop的逻辑一致。如果Looper的阻塞打开了，则首先找到预计执行时间比当前时刻都大的WorkItem。并且从mWorkQueue移除，最后添加到toProcess中，并且执行每一个WorkItem的work方法。而每一个WorkItem其实就是通过从某一个压入方法添加到mWorkQueue中。

到这里，我们就明白了RenderThread中是如何消费渲染任务的。那么这些渲染任务又是哪里诞生呢？

#### RenderThread 相应Vsync信号的回调

上文聊到了在RenderThread中的Looper会监听Vsync信号，当信号回调后将会执行下面的回调。

#### displayEventReceiverCallback
```cpp
int RenderThread::displayEventReceiverCallback(int fd, int events, void* data) {
    if (events & (Looper::EVENT_ERROR | Looper::EVENT_HANGUP)) {
        return 0;  // remove the callback
    }

    if (!(events & Looper::EVENT_INPUT)) {
        return 1;  // keep the callback
    }

    reinterpret_cast<RenderThread*>(data)->drainDisplayEventQueue();

    return 1;  // keep the callback
}
```
能看到这个方法的核心实际上就是调用drainDisplayEventQueue方法，对ui渲染任务队列进行处理。

###### RenderThread::drainDisplayEventQueue
```cpp
void RenderThread::drainDisplayEventQueue() {
    ATRACE_CALL();
    nsecs_t vsyncEvent = mVsyncSource->latestVsyncEvent();
    if (vsyncEvent > 0) {
        mVsyncRequested = false;
        if (mTimeLord.vsyncReceived(vsyncEvent) && !mFrameCallbackTaskPending) {
            mFrameCallbackTaskPending = true;
            nsecs_t runAt = (vsyncEvent + DISPATCH_FRAME_CALLBACKS_DELAY);
            queue().postAt(runAt, [this]() { dispatchFrameCallbacks(); });
        }
    }
}
```
能到在这里mVsyncRequested设置为false，且mFrameCallbackTaskPending将会设置为true，并且调用queue的postAt的方法执行ui渲染方法。

还记得queue实际是是指WorkQueue，而WorkQueue的postAt方法实际实现如下：
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[thread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/)/[WorkQueue.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/thread/WorkQueue.h)

```cpp
    template <class F>
    void postAt(nsecs_t time, F&& func) {
        enqueue(WorkItem{time, std::function<void()>(std::forward<F>(func))});
    }

    void enqueue(WorkItem&& item) {
        bool needsWakeup;
        {
            std::unique_lock _lock{mLock};
            auto insertAt = std::find_if(
                    std::begin(mWorkQueue), std::end(mWorkQueue),
                    [time = item.runAt](WorkItem & item) { return item.runAt > time; });
            needsWakeup = std::begin(mWorkQueue) == insertAt;
            mWorkQueue.emplace(insertAt, std::move(item));
        }
        if (needsWakeup) {
            mWakeFunc();
        }
    }
```
情景带入，当一个Vsync信号达到Looper的监听者，此时就会通过WorkQueue的drainDisplayEventQueue 压入一个任务到队列中。

每一个默认的任务都是执行dispatchFrameCallback方法。这里的判断mWorkQueue中是否存在比当前时间更迟的时刻，并返回这个WorkItem。如果这个对象在头部needsWakeup为true，说明可以进行唤醒了。而mWakeFunc这个方法指针就是上面传下来：
```cpp
mLooper->wake(); 
```
把阻塞的Looper唤醒。当唤醒后就继续执行WorkQueue的process方法。也就是执行dispatchFrameCallbacks方法。

##### RenderThread dispatchFrameCallbacks
```cpp
void RenderThread::dispatchFrameCallbacks() {
    ATRACE_CALL();
    mFrameCallbackTaskPending = false;

    std::set<IFrameCallback*> callbacks;
    mFrameCallbacks.swap(callbacks);

    if (callbacks.size()) {
        requestVsync();
        for (std::set<IFrameCallback*>::iterator it = callbacks.begin(); it != callbacks.end();
             it++) {
            (*it)->doFrame();
        }
    }
}
```
在这里执行了两个事情：
- 1.requestVsync 打开EventThread的监听阻塞。
- 2.处理IFrameCallback的doFrame方法。而每一个IFrameCallback是通过如下方式添加进来的：
```cpp
void RenderThread::pushBackFrameCallback(IFrameCallback* callback) {
    if (mFrameCallbacks.erase(callback)) {
        mPendingRegistrationFrameCallbacks.insert(callback);
    }
}
```
先添加到mPendingRegistrationFrameCallbacks集合中，在上面提到过的threadLoop中，会执行如下逻辑：
```cpp
        if (mPendingRegistrationFrameCallbacks.size() && !mFrameCallbackTaskPending) {
            drainDisplayEventQueue();
            mFrameCallbacks.insert(mPendingRegistrationFrameCallbacks.begin(),
                                   mPendingRegistrationFrameCallbacks.end());
            mPendingRegistrationFrameCallbacks.clear();
            requestVsync();
        }
```
如果mPendingRegistrationFrameCallbacks大小不为0，则的把mPendingRegistrationFrameCallbacks中的IFrameCallback全部迁移到mFrameCallbacks中。

而这个方法什么时候调用呢？稍后就会介绍。其实这部分的逻辑在TextureView的解析中提到过。

#### CanvasContext的初始化
接下来将会初始化一个重要对象：
```cpp
CanvasContext::create(mRenderThread, translucent, rootRenderNode, contextFactory);
```
这个对象名字叫做画布的上下文，具体是什么上下文呢？我们现在就来看看其实例化方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[CanvasContext.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/CanvasContext.cpp)
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
            break;
    }
    return nullptr;
}
```
文件：/[device](http://androidxref.com/9.0.0_r3/xref/device/)/[generic](http://androidxref.com/9.0.0_r3/xref/device/generic/)/[goldfish](http://androidxref.com/9.0.0_r3/xref/device/generic/goldfish/)/[init.ranchu.rc](http://androidxref.com/9.0.0_r3/xref/device/generic/goldfish/init.ranchu.rc)
```
on boot
    setprop debug.hwui.renderer opengl
```
在init.rc中默认是opengl，那么我们就来看看下面的逻辑：
```cpp
        case RenderPipelineType::OpenGL:
            return new CanvasContext(thread, translucent, rootRenderNode, contextFactory,
                                     std::make_unique<OpenGLPipeline>(thread));
```
首先实例化一个OpenGLPipeline管道，接着OpenGLPipeline作为参数实例化CanvasContext。

#### OpenGLPipeline实例化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[OpenGLPipeline.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/OpenGLPipeline.cpp)
```cpp
OpenGLPipeline::OpenGLPipeline(RenderThread& thread)
        : mEglManager(thread.eglManager()), mRenderThread(thread) {}
```
能看到在OpenGLPipeline中，实际上就是存储了RenderThread对象，以及RenderThread中的mEglManager。透过OpenGLPipeline来控制mEglManager进而进一步操作OpenGL。

#### CanvasContext实例化
```
CanvasContext::CanvasContext(RenderThread& thread, bool translucent, RenderNode* rootRenderNode,
                             IContextFactory* contextFactory,
                             std::unique_ptr<IRenderPipeline> renderPipeline)
        : mRenderThread(thread)
        , mGenerationID(0)
        , mOpaque(!translucent)
        , mAnimationContext(contextFactory->createAnimationContext(mRenderThread.timeLord()))
        , mJankTracker(&thread.globalProfileData(), thread.mainDisplayInfo())
        , mProfiler(mJankTracker.frames())
        , mContentDrawBounds(0, 0, 0, 0)
        , mRenderPipeline(std::move(renderPipeline)) {
    rootRenderNode->makeRoot();
    mRenderNodes.emplace_back(rootRenderNode);
    mRenderThread.renderState().registerCanvasContext(this);
    mProfiler.setDensity(mRenderThread.mainDisplayInfo().density);
}
```
做了如下操作：
- 1.RenderNode的makeRoot方法，添加RenderNode的引用计数
- 2.mRenderNodes的集合收集rootRenderNode对象，注意在这里带了一个很核心的逻辑，把rootRenderNode根RenderNode添加到mRenderNodes集合中，之后就可以从mRenderNodes找到根部的RenderNode。
- 3.获取RenderThread的renderState对象调用registerCanvasContext方法保存CanvasContext到mRegisteredContexts中。

 文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderstate](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderstate/)/[RenderState.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderstate/RenderState.cpp)

```cpp
    void registerCanvasContext(renderthread::CanvasContext* context) {
        mRegisteredContexts.insert(context);
    }
```

#### mDrawFrameTask 初始化
```cpp
 mDrawFrameTask.setContext(&mRenderThread, mContext, rootRenderNode);
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[DrawFrameTask.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/DrawFrameTask.cpp)
```cpp
void DrawFrameTask::setContext(RenderThread* thread, CanvasContext* context,
                               RenderNode* targetNode) {
    mRenderThread = thread;
    mContext = context;
    mTargetNode = targetNode;
}
```
实际上就是保存这三对象RenderThread；CanvasContext；RenderNode。

### ThreadedRenderer nSetName
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)
```cpp
static void android_view_ThreadedRenderer_setName(JNIEnv* env, jobject clazz,
        jlong proxyPtr, jstring jname) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    const char* name = env->GetStringUTFChars(jname, NULL);
    proxy->setName(name);
    env->ReleaseStringUTFChars(jname, name);
}
```
能看到实际上就是调用RenderProxy的setName方法给当前硬件渲染对象设置名字。

 文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[RenderProxy.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/RenderProxy.cpp)

```cpp
void RenderProxy::setName(const char* name) {
    mRenderThread.queue().runSync([this, name]() { mContext->setName(std::string(name)); });
}
```
能看到在setName方法中，实际上就是调用RenderThread的WorkQueue，把一个任务队列设置进去，并且调用runSync执行。
```cpp
    template <class F>
    auto runSync(F&& func) -> decltype(func()) {
        std::packaged_task<decltype(func())()> task{std::forward<F>(func)};
        post([&task]() { std::invoke(task); });
        return task.get_future().get();
    };
```
能看到这个方法实际上也是调用post执行排队执行任务，不同的是，这里使用了线程的Future方式，阻塞了执行，等待CanvasContext的setName工作完毕。

## ThreadedRenderer 初始化
```java
    boolean initialize(Surface surface) throws OutOfResourcesException {
        boolean status = !mInitialized;
        mInitialized = true;
        updateEnabledState(surface);
        nInitialize(mNativeProxy, surface);
        return status;
    }
```
核心是调用nInitialize的方法，把Surface方法传递到threadedRenderer中。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_ThreadedRenderer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_ThreadedRenderer.cpp)
```cpp
static void android_view_ThreadedRenderer_initialize(JNIEnv* env, jobject clazz,
        jlong proxyPtr, jobject jsurface) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    sp<Surface> surface = android_view_Surface_getSurface(env, jsurface);
    proxy->initialize(surface);
}
```
这里里面的核心也很简单，拿到RenderProxy对象，把native层的Surface对象作为参数调用initialize方法。关于Surface对象详解可以阅读。[GraphicBuffer的诞生](https://www.jianshu.com/p/3bfc0053d254)。

### RenderProxy initialize
```cpp
void RenderProxy::initialize(const sp<Surface>& surface) {
    mRenderThread.queue().post(
            [ this, surf = surface ]() mutable { mContext->setSurface(std::move(surf)); });
}
```

#### CanvasContext setSurface
```cpp
void CanvasContext::setSurface(sp<Surface>&& surface) {
    mNativeSurface = std::move(surface);

    ColorMode colorMode = mWideColorGamut ? ColorMode::WideColorGamut : ColorMode::Srgb;
    bool hasSurface = mRenderPipeline->setSurface(mNativeSurface.get(), mSwapBehavior, colorMode);

    mFrameNumber = -1;

    if (hasSurface) {
        mHaveNewSurface = true;
        mSwapHistory.clear();
    } else {
        mRenderThread.removeFrameCallback(this);
        mGenerationID++;
    }
}
```
实际上这里的逻辑很简单，就是给渲染管道(当前OpenGLPipeline)方法调用setSurface。如果设置成功mSwapHistory则清空。如果失败说明mNativeSurface为空或者无效，则调用removeFrameCallback移除会调用，也就是上面说过的IFrameCallback。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[renderthread](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/)/[OpenGLPipeline.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/renderthread/OpenGLPipeline.cpp)
```cpp
bool OpenGLPipeline::setSurface(Surface* surface, SwapBehavior swapBehavior, ColorMode colorMode) {
    if (mEglSurface != EGL_NO_SURFACE) {
        mEglManager.destroySurface(mEglSurface);
        mEglSurface = EGL_NO_SURFACE;
    }

    if (surface) {
        const bool wideColorGamut = colorMode == ColorMode::WideColorGamut;
        mEglSurface = mEglManager.createSurface(surface, wideColorGamut);
    }

    if (mEglSurface != EGL_NO_SURFACE) {
        const bool preserveBuffer = (swapBehavior != SwapBehavior::kSwap_discardBuffer);
        mBufferPreserved = mEglManager.setPreserveBuffer(mEglSurface, preserveBuffer);
        return true;
    }

    return false;
}
```
这里面的逻辑很简单，走的就是OpenGL的初始化的流程，如果surface不为空，则调用mEglManager为Surface， 从Surface中创建一个opengl es的surface。详情可以阅读我写的[渲染图层-OpenGL es上的封装(上)](https://www.jianshu.com/p/03c40afab7a5)。


#### ThreadedRenderer updateSurface  更新Surface
当Surface在Java层发生了变化，则需要进行updateSurface方法，告诉硬件渲染线程更新Surface方法。
```java
    void updateSurface(Surface surface) throws OutOfResourcesException {
        updateEnabledState(surface);
        nUpdateSurface(mNativeProxy, surface);
    }
```
实际上还是调用RenderProxy的updateSurface方法。而这个方法还是调用CanvasContext的setSurface方法。
```cpp
void RenderProxy::updateSurface(const sp<Surface>& surface) {
    mRenderThread.queue().post(
            [ this, surf = surface ]() mutable { mContext->setSurface(std::move(surf)); });
}
```

### ThreadedRenderer setup启动硬件渲染，初始化参数
```java
    void setup(int width, int height, AttachInfo attachInfo, Rect surfaceInsets) {
        mWidth = width;
        mHeight = height;

        if (surfaceInsets != null && (surfaceInsets.left != 0 || surfaceInsets.right != 0
                || surfaceInsets.top != 0 || surfaceInsets.bottom != 0)) {
            mHasInsets = true;
            mInsetLeft = surfaceInsets.left;
            mInsetTop = surfaceInsets.top;
            mSurfaceWidth = width + mInsetLeft + surfaceInsets.right;
            mSurfaceHeight = height + mInsetTop + surfaceInsets.bottom;
            setOpaque(false);
        } else {
            mHasInsets = false;
            mInsetLeft = 0;
            mInsetTop = 0;
            mSurfaceWidth = width;
            mSurfaceHeight = height;
        }

        mRootNode.setLeftTopRightBottom(-mInsetLeft, -mInsetTop, mSurfaceWidth, mSurfaceHeight);
        nSetup(mNativeProxy, mLightRadius,
                mAmbientShadowAlpha, mSpotShadowAlpha);

        setLightCenter(attachInfo);
    }
```
- 1.调用RootNode的setLeftTopRightBottom更新根部节点的上下左右的参数。
- 2.nSetup 进行ThreadedRenderer进行装载。


#### RootNode setLeftTopRightBottom
RootNode.setLeftTopRightBottom方法实际上调用的是如下方法：
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_RenderNode.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_RenderNode.cpp)
```cpp
static jboolean android_view_RenderNode_setLeftTopRightBottom(jlong renderNodePtr,
        int left, int top, int right, int bottom) {
    RenderNode* renderNode = reinterpret_cast<RenderNode*>(renderNodePtr);
    if (renderNode->mutateStagingProperties().setLeftTopRightBottom(left, top, right, bottom)) {
        renderNode->setPropertyFieldsDirty(RenderNode::X | RenderNode::Y);
        return true;
    }
    return false;
}
```

- 1.setLeftTopRightBottom 是RenderNode的RenderNode参数对象RenderProperties设置上下左右的方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RenderProperties.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RenderProperties.cpp)
```cpp
    bool setLeftTopRightBottom(int left, int top, int right, int bottom) {
        if (left != mPrimitiveFields.mLeft || top != mPrimitiveFields.mTop ||
            right != mPrimitiveFields.mRight || bottom != mPrimitiveFields.mBottom) {
            mPrimitiveFields.mLeft = left;
            mPrimitiveFields.mTop = top;
            mPrimitiveFields.mRight = right;
            mPrimitiveFields.mBottom = bottom;
            mPrimitiveFields.mWidth = mPrimitiveFields.mRight - mPrimitiveFields.mLeft;
            mPrimitiveFields.mHeight = mPrimitiveFields.mBottom - mPrimitiveFields.mTop;
            if (!mPrimitiveFields.mPivotExplicitlySet) {
                mPrimitiveFields.mMatrixOrPivotDirty = true;
            }
            return true;
        }
        return false;
    }
```
能看到实际上就是给mPrimitiveFields中的参数给设置上。

- 2.setPropertyFieldsDirty 告诉当前的RenderNode已经改变了。
```cpp
void setPropertyFieldsDirty(uint32_t fields) { mDirtyPropertyFields |= fields; }
```

#### native中ThreadedRenderer setup
```cpp
static void android_view_ThreadedRenderer_setup(JNIEnv* env, jobject clazz, jlong proxyPtr,
        jfloat lightRadius, jint ambientShadowAlpha, jint spotShadowAlpha) {
    RenderProxy* proxy = reinterpret_cast<RenderProxy*>(proxyPtr);
    proxy->setup(lightRadius, ambientShadowAlpha, spotShadowAlpha);
}
```
本质上还是调用RenderProxy的setup方法。

##### RenderProxy setup
```cpp 
void RenderProxy::setup(float lightRadius, uint8_t ambientShadowAlpha, uint8_t spotShadowAlpha) {
    mRenderThread.queue().post(
            [=]() { mContext->setup(lightRadius, ambientShadowAlpha, spotShadowAlpha); });
}
```
能看到实际上调用CanvasContext的setup。
```cpp
void CanvasContext::setup(float lightRadius, uint8_t ambientShadowAlpha, uint8_t spotShadowAlpha) {
    mLightGeometry.radius = lightRadius;
    mLightInfo.ambientShadowAlpha = ambientShadowAlpha;
    mLightInfo.spotShadowAlpha = spotShadowAlpha;
}
```
能看到这个过程中就是设置好一些亮度，阴影的参数。

### ThreadedRenderer invalidateRoot打开标志位
首先ViewRootImpl的draw方法时候，会判断invalidateRoot是否需要调用：
```java
                if (invalidateRoot) {
                    mAttachInfo.mThreadedRenderer.invalidateRoot();
                }
```

```java
    void invalidateRoot() {
        mRootNodeNeedsUpdate = true;
    }
```
能看到实际上就是很简单的，mRootNodeNeedsUpdate标志位设置为true。而invalidateRoot判断的标准是整个View tree位移是否发生了变化。整个是指整个View树的整体位移。
每一个View的onMeasure，onLayout，onDraw三个流程中，判断是否是软件渲染还是硬件渲染，进而判断是否调用RenderNode中的操作，还是调用Skia中的Canvas操作。

## ThreadedRenderer draw 开始硬件渲染绘制
调用时机在ViewRootImpl的draw方法：
```java
 final FrameDrawingCallback callback = mNextRtFrameCallback;
                mNextRtFrameCallback = null;
                mAttachInfo.mThreadedRenderer.draw(mView, mAttachInfo, this, callback);
```
详细的解析可以阅读我写的[View的绘制流程(三) onDraw](https://www.jianshu.com/p/a4fb6a02ad53)。

```java
    void draw(View view, AttachInfo attachInfo, DrawCallbacks callbacks,
            FrameDrawingCallback frameDrawingCallback) {
        attachInfo.mIgnoreDirtyState = true;

        final Choreographer choreographer = attachInfo.mViewRootImpl.mChoreographer;
        choreographer.mFrameInfo.markDrawStart();

        updateRootDisplayList(view, callbacks);

        attachInfo.mIgnoreDirtyState = false;

        if (attachInfo.mPendingAnimatingRenderNodes != null) {
            final int count = attachInfo.mPendingAnimatingRenderNodes.size();
            for (int i = 0; i < count; i++) {
                registerAnimatingRenderNode(
                        attachInfo.mPendingAnimatingRenderNodes.get(i));
            }
            attachInfo.mPendingAnimatingRenderNodes.clear();
            attachInfo.mPendingAnimatingRenderNodes = null;
        }

        final long[] frameInfo = choreographer.mFrameInfo.mFrameInfo;
        if (frameDrawingCallback != null) {
            nSetFrameCallback(mNativeProxy, frameDrawingCallback);
        }
        int syncResult = nSyncAndDrawFrame(mNativeProxy, frameInfo, frameInfo.length);
        if ((syncResult & SYNC_LOST_SURFACE_REWARD_IF_FOUND) != 0) {
            setEnabled(false);
            attachInfo.mViewRootImpl.mSurface.release();
            attachInfo.mViewRootImpl.invalidate();
        }
        if ((syncResult & SYNC_INVALIDATE_REQUIRED) != 0) {
            attachInfo.mViewRootImpl.invalidate();
        }
    }
```

- 1.updateRootDisplayList 从根部开始遍历整个View tree。
- 2.registerAnimatingRenderNode 注册每一个需要执行动画的RenderNode
- 3.nSetFrameCallback 把FrameDrawingCallback注册到native层
- 4.nSyncAndDrawFrame 调用native的同步绘制
- 5.如果绘制结果返回SYNC_LOST_SURFACE_REWARD_IF_FOUND标志位，说明可能Surface无效或者出错，则关闭硬件渲染，释放VRI的mSurface等对象。如果SYNC_INVALIDATE_REQUIRED返回了，说明还需要下一轮的Loop通过performTravel进行局部刷新。

可以看到整个核心在updateRootDisplayList和nSyncAndDrawFrame两个方法。只要弄懂这两个核心流程就能明白整套硬件渲染的流程。

### ThreadedRenderer updateRootDisplayList 从根部更新绘制树
```java
    private void updateRootDisplayList(View view, DrawCallbacks callbacks) {
        updateViewTreeDisplayList(view);

        if (mRootNodeNeedsUpdate || !mRootNode.isValid()) {
            DisplayListCanvas canvas = mRootNode.start(mSurfaceWidth, mSurfaceHeight);
            try {
                final int saveCount = canvas.save();
                canvas.translate(mInsetLeft, mInsetTop);
                callbacks.onPreDraw(canvas);

                canvas.insertReorderBarrier();
                canvas.drawRenderNode(view.updateDisplayListIfDirty());
                canvas.insertInorderBarrier();

                callbacks.onPostDraw(canvas);
                canvas.restoreToCount(saveCount);
                mRootNodeNeedsUpdate = false;
            } finally {
                mRootNode.end(canvas);
            }
        }
        Trace.traceEnd(Trace.TRACE_TAG_VIEW);
    }
```
执行了如下几个事情：
- 1.updateViewTreeDisplayList 更新整个View tree
- 2.调用根绘制节点mRootNode的start方法，生成一个根DisplayListCanvas对象
- 3.调用ViewRootImpl的onPreDraw回调。
- 4.DisplayListCanvas insertReorderBarrier
- 5.DisplayListCanvas drawRenderNode绘制节点，并开始遍历子节点
- 6.DisplayListCanvas insertInorderBarrier
- 7.调用ViewRootImpl的onPostDraw
- 8.mRootNode的end方法，保存DisplayListCanvas到根节点中。

我们一个个进行解析。

#### updateViewTreeDisplayList
```java
    private void updateViewTreeDisplayList(View view) {
        view.mPrivateFlags |= View.PFLAG_DRAWN;
        view.mRecreateDisplayList = (view.mPrivateFlags & View.PFLAG_INVALIDATED)
                == View.PFLAG_INVALIDATED;
        view.mPrivateFlags &= ~View.PFLAG_INVALIDATED;
        view.updateDisplayListIfDirty();
        view.mRecreateDisplayList = false;
    }
```
注意此时的View是指DecorView，在这里面给DecorView设置了PFLAG_DRAWN标志位。

如果DecorView的PFLAG_INVALIDATED标志位打开了，说明整个View都被设置无效，需要重新构建整个硬件渲染的View树。接着关闭PFLAG_INVALIDATED标志位，调用updateDisplayListIfDirty进行子View的RenderNode遍历。

而关于updateDisplayListIfDirty的详细原理可以阅读[View的绘制流程(三) onDraw](https://www.jianshu.com/p/a4fb6a02ad53)中updateDisplayListIfDirty小结。这里我们只关注核心的部分：
```java
public RenderNode updateDisplayListIfDirty() {
        final RenderNode renderNode = mRenderNode;
        if (!canHaveDisplayList()) {
            return renderNode;
        }
...
            mRecreateDisplayList = true;

            int width = mRight - mLeft;
            int height = mBottom - mTop;
            int layerType = getLayerType();

            final DisplayListCanvas canvas = renderNode.start(width, height);

            try {
                if (layerType == LAYER_TYPE_SOFTWARE) {
...
                } else {
...
                    canvas.translate(-mScrollX, -mScrollY);
                    mPrivateFlags |= PFLAG_DRAWN | PFLAG_DRAWING_CACHE_VALID;
                    mPrivateFlags &= ~PFLAG_DIRTY_MASK;

                    if ((mPrivateFlags & PFLAG_SKIP_DRAW) == PFLAG_SKIP_DRAW) {
                        dispatchDraw(canvas);
                        drawAutofilledHighlight(canvas);
                        if (mOverlay != null && !mOverlay.isEmpty()) {
                            mOverlay.getOverlayView().draw(canvas);
                        }

                    } else {
                        draw(canvas);
                    }
                }
            } finally {
                renderNode.end(canvas);
                setDisplayListProperties(renderNode);
            }
        } else {
...
        }
        return renderNode;
    }
```
假如此时是DecorView，则会调用DecorView中的RenderNode对象执行如下：
- 1.RenderNode.start 给DecorView生成一个对应的DisplayListCanvas对象。
- 2.调用draw方法，开始对DisplayListCanvas进行绘制。在这个过程中，还会调用drawRenderNode方法。
- 3.RenderNode.end 保存了DisplayListCanvas对象。

能看到实际上来来去去都是调用每一个View层级中RenderNode的三个方法，
- 1.start生成View自己的RenderNode
- 2.当调用完DisplayListCanvas的绘制结果后，drawRenderNode DisplayListCanvas绘制RenderNode
- 3.end 保存DisplayListCanvas

关于这三个方法，我们接下来来看看DisplayListCanvas几个方法。

## DisplayListCanvas 原理
在聊DisplayListCanvas之前，我们需要了解它的在Java层中的继承关系。如下图：
![DisplayListCanvas继承关系.jpg](/images/DisplayListCanvas继承关系.jpg)

实际上在native层也是十分相似的结构。


### RenderNode DisplayListCanvas的生成
```java
    public DisplayListCanvas start(int width, int height) {
        return DisplayListCanvas.obtain(this, width, height);
    }
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[DisplayListCanvas.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/DisplayListCanvas.java)
```java
    private static final int POOL_LIMIT = 25;
    private static final SynchronizedPool<DisplayListCanvas> sPool =
            new SynchronizedPool<>(POOL_LIMIT);

    static DisplayListCanvas obtain(@NonNull RenderNode node, int width, int height) {
        if (node == null) throw new IllegalArgumentException("node cannot be null");
        DisplayListCanvas canvas = sPool.acquire();
        if (canvas == null) {
            canvas = new DisplayListCanvas(node, width, height);
        } else {
            nResetDisplayListCanvas(canvas.mNativeCanvasWrapper, node.mNativeRenderNode,
                    width, height);
        }
        canvas.mNode = node;
        canvas.mWidth = width;
        canvas.mHeight = height;
        return canvas;
    }
```
能看到这个过程中，所有的DisplayListCanvas都是从一个sPool中获取。其实这就是一个享元设计模式，sPool里面最大25个DisplayListCanvas，如果获取不到则直接new一个，否则则调用nResetDisplayListCanvas重置DisplayListCanvas中的内容。

我们再来看看DisplayListCanvas的构造函数。
```java
    private DisplayListCanvas(@NonNull RenderNode node, int width, int height) {
        super(nCreateDisplayListCanvas(node.mNativeRenderNode, width, height));
        mDensity = 0; 
    }

    @CriticalNative
    private static native long nCreateDisplayListCanvas(long node, int width, int height);
```
首先调用了native方法nCreateDisplayListCanvas生成一个native对象继续调用父类的构造函数。

这里有两个比较有意思的注解，是从Android 8.0开始支持的，@CriticalNative与@FastNative。

这两个注解是注解在native方法上，可以加速native的查找。

@FastNative：注解支持非静态方法(当然也支持静态方法)。如果某种方法将 jobject 作为参数或返回值进行访问，请使用此注解。其速度是普通的3倍。

@CriticalNative 比起普通的速度有5倍差距，但是使用场景有限制：
- 1.方法必须是静态的 - 没有参数、返回值或隐式 this 的对象
- 2.仅将基元类型传递给原生方法
- 3.native方法在其函数定义中不使用 JNIEnv 和 jclass 参数
- 4.该方法必须是使用 RegisterNatives 注册的，而不是依靠动态 JNI 链接

#### nCreateDisplayListCanvas
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_DisplayListCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_DisplayListCanvas.cpp)

```cpp
static jlong android_view_DisplayListCanvas_createDisplayListCanvas(jlong renderNodePtr,
        jint width, jint height) {
    RenderNode* renderNode = reinterpret_cast<RenderNode*>(renderNodePtr);
    return reinterpret_cast<jlong>(Canvas::create_recording_canvas(width, height, renderNode));
}
```
能看到实际上调用了静态方法create_recording_canvas创建了一个对象。
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/hwui/)/[Canvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/hwui/Canvas.cpp)
```cpp
Canvas* Canvas::create_recording_canvas(int width, int height, uirenderer::RenderNode* renderNode) {
    if (uirenderer::Properties::isSkiaEnabled()) {
        return new uirenderer::skiapipeline::SkiaRecordingCanvas(renderNode, width, height);
    }
    return new uirenderer::RecordingCanvas(width, height);
}
```
在这个过程中会进行判断，如果打开了Skia开关，也就是SKiaGL或者SkiaVulan两者其一的类型则会创建一个SkiaRecordingCanvas对象，否则会创建RecordingCanvas对象。

SkiaRecordingCanvas这个对象，我在TextureView一文和大家已经聊过一部分内容，我们现在来聊聊skia默认关闭的情景。

#### RecordingCanvas的创建
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RecordingCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RecordingCanvas.cpp)
```cpp
RecordingCanvas::RecordingCanvas(size_t width, size_t height)
        : mState(*this), mResourceCache(ResourceCache::getInstance()) {
    resetRecording(width, height);
}

void RecordingCanvas::resetRecording(int width, int height, RenderNode* node) {
    mDisplayList = new DisplayList();

    mState.initializeRecordingSaveStack(width, height);

    mDeferredBarrierType = DeferredBarrierType::InOrder;
}
```
RecordingCanvas顾名思义，就是记录了什么东西的Canvas。
- 1.首先构建一个记录绘制集合DisplayList对象。
- 2.调用当前对象的initializeRecordingSaveStack方法。也就是调用CanvasState的initializeRecordingSaveStack。
文件： /[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[CanvasState.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/CanvasState.cpp)

```cpp
void CanvasState::initializeRecordingSaveStack(int viewportWidth, int viewportHeight) {
    if (mWidth != viewportWidth || mHeight != viewportHeight) {
        mWidth = viewportWidth;
        mHeight = viewportHeight;
        mFirstSnapshot.initializeViewport(viewportWidth, viewportHeight);
        mCanvas.onViewportInitialized();
    }

    freeAllSnapshots();
    mSnapshot = allocSnapshot(&mFirstSnapshot, SaveFlags::MatrixClip);
    mSnapshot->setRelativeLightCenter(Vector3());
    mSaveCount = 1;
}
```
如果宽高和当前实例化的换高不一致，初始化mFirstSnapshot快照对象，以及回调RecordCanvas的onViewportInitialized的回调。

释放之前除了第一张之外所有的快照，并且重新申请一个新的快照对象。

#### DisplayList 实例化
能看到在RecordingCanvas中，有一个核心对象DisplayList。从名字可以看出是承载一个个显示图层的集合。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[DisplayList.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/DisplayList.h)
```cpp
class DisplayList {
    friend class RecordingCanvas;

public:
....

protected:
    // allocator into which all ops and LsaVector arrays allocated
    LinearAllocator allocator;
    LinearStdAllocator<void*> stdAllocator;

private:
    LsaVector<Chunk> chunks;
    LsaVector<BaseOpType*> ops;

    // list of Ops referring to RenderNode children for quick, non-drawing traversal
    LsaVector<NodeOpType*> children;

    // Resources - Skia objects + 9 patches referred to by this DisplayList
    LsaVector<sk_sp<Bitmap>> bitmapResources;
    LsaVector<const SkPath*> pathResources;
    LsaVector<const Res_png_9patch*> patchResources;
    LsaVector<std::unique_ptr<const SkPaint>> paints;
    LsaVector<std::unique_ptr<const SkRegion>> regions;
    LsaVector<sp<VirtualLightRefBase>> referenceHolders;

    // List of functors
    LsaVector<FunctorContainer> functors;

    LsaVector<VectorDrawableRoot*> vectorDrawables;

    void cleanupResources();
};
```
能看到DisplayList类中，有那么几个核心对象：
- 1.LinearAllocator与LinearStdAllocator，这两个对象是硬件渲染中用于控制申请管理操作对象BaseOpType内存的内存管理器。
- 2.BaseOpType集合  BaseOpType是RecordedOp 类的别名，RecordedOp类是指绘制操作。
- 3.NodeOpType集合 NodeOpType 是RenderNodeOp别名，一般是作为DisplayList用于保存子RenderNode的内容
- 4.剩下的如bitmap资源，.9图片资源，画笔字眼，区域，vector向量图资源。

能看到DisplayList中，有两个对象作为整个类的主导地位：
- 1.BaseOpType 绘制操作对象
- 2.LinearAllocator BaseOpType的内存管理器

让我们来看看这两者的核心原理。

#### LinearAllocator 线性内存管理器
先来看看头文件：
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[utils](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/utils/)/[LinearAllocator.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/utils/LinearAllocator.h)
```cpp
class LinearAllocator {
public:
    template <class T>
    void* alloc(size_t size) {
        return allocImpl(size);
    }

    template <class T, typename... Params>
    T* create(Params&&... params) {
        T* ret = new (allocImpl(sizeof(T))) T(std::forward<Params>(params)...);
        if (!std::is_trivially_destructible<T>::value) {
            auto dtor = [](void* ret) { ((T*)ret)->~T(); };
            addToDestructionList(dtor, ret);
        }
        return ret;
    }

    template <class T, typename... Params>
    T* create_trivial(Params&&... params) {
        static_assert(std::is_trivially_destructible<T>::value,
                      "Error, called create_trivial on a non-trivial type");
        return new (allocImpl(sizeof(T))) T(std::forward<Params>(params)...);
    }

    template <class T>
    T* create_trivial_array(int count) {
        static_assert(std::is_trivially_destructible<T>::value,
                      "Error, called create_trivial_array on a non-trivial type");
        return reinterpret_cast<T*>(allocImpl(sizeof(T) * count));
    }
private:
    LinearAllocator(const LinearAllocator& other);

    class Page;
...
    void* allocImpl(size_t size);

...
    size_t mPageSize;
    size_t mMaxAllocSize;
    void* mNext;
    Page* mCurrentPage;
    Page* mPages;
...
    size_t mTotalAllocated;
    size_t mWastedSpace;
    size_t mPageCount;
    size_t mDedicatedPageCount;
};
```
能看到在这个内存管理器中实际上是把每一个申请出去的内存以page(页为单位)管理
- 1.同时会不断的通过mTotalAllocated记录总共申请了多少
- 2.mWastedSpace记录有多少内存没有被使用
- 3.mPages指针实际上是一个page链表，当前LinearAllocator所有已经申请的内存页。
- 4.mCurrentPage 当前申请指向的页对象。

一般的当Android进行申请内存，将会调用如下顺序：
```cpp
create_trivial<TextureLayerOp>(
            Rect(layerHandle->getWidth(), layerHandle->getHeight()),
            *(mState.currentSnapshot()->transform), getRecordedClip(), layerHandle)
```
实际上调用create_trivial方法。
```cpp

    template <class T, typename... Params>
    T* create_trivial(Params&&... params) {
        return new (allocImpl(sizeof(T))) T(std::forward<Params>(params)...);
    }
```
实际上是根据范性T的大小调用allocImpl申请内存大小为T。

##### LinearAllocator的内存单元Page
其中还有一个核心的对象Page：

```cpp
class LinearAllocator::Page {
public:
    Page* next() { return mNextPage; }
    void setNext(Page* next) { mNextPage = next; }
    Page() : mNextPage(0) {}
    void* operator new(size_t /*size*/, void* buf) { return buf; }
    void* start() { return (void*)(((size_t)this) + sizeof(Page)); }
    void* end(int pageSize) { return (void*)(((size_t)start()) + pageSize); }
private:
    Page(const Page& /*other*/) {}
    Page* mNextPage;
};
```
 能看到实际上Page类实际上是一个链表中的一项，记录下一个Page的指针。page中有2个基本操作，用于计算Page的所申请的内存起点和末尾。
- start 是指Page内存单元的起点:
> 计算方式为 Page地址起点+page类的大小
- end 是指Page内存单元的终点:
> 计算方式为 Page地址起点+page类的大小+申请的内存大小PageSize

了解两个基本操作后，我们来看看LinearAllocator的内存操作create_trivial。


文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[utils](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/utils/)/[LinearAllocator.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/utils/LinearAllocator.cpp)
```cpp
#define INITIAL_PAGE_SIZE ((size_t)512)  // 512b
#define MAX_PAGE_SIZE ((size_t)131072)   // 128kb

#if ALIGN_DOUBLE
#define ALIGN_SZ (sizeof(double))
#else
#define ALIGN_SZ (sizeof(int))
#endif

#define ALIGN(x) (((x) + ALIGN_SZ - 1) & ~(ALIGN_SZ - 1))
#define ALIGN_PTR(p) ((void*)(ALIGN((size_t)(p))))
#define MAX_WASTE_RATIO (0.5f)


LinearAllocator::LinearAllocator()
        : mPageSize(INITIAL_PAGE_SIZE)
        , mMaxAllocSize(INITIAL_PAGE_SIZE * MAX_WASTE_RATIO)
        , mNext(0)
        , mCurrentPage(0)
        , mPages(0)
        , mTotalAllocated(0)
        , mWastedSpace(0)
        , mPageCount(0)
        , mDedicatedPageCount(0) {}

bool LinearAllocator::fitsInCurrentPage(size_t size) {
    return mNext && ((char*)mNext + size) <= end(mCurrentPage);
}

void* LinearAllocator::start(Page* p) {
    return ALIGN_PTR((size_t)p + sizeof(Page));
}

void* LinearAllocator::end(Page* p) {
    return ((char*)p) + mPageSize;
}

LinearAllocator::Page* LinearAllocator::newPage(size_t pageSize) {
    pageSize = ALIGN(pageSize + sizeof(LinearAllocator::Page));
    mTotalAllocated += pageSize;
    mPageCount++;
    void* buf = malloc(pageSize);
    return new (buf) Page();
}
```
先来看看两个重要的属性：
- 1.mPageSize 在初始化的时候定义好当前拥有页的大小，为INITIAL_PAGE_SIZE也就是宏512b。
- 2.mMaxAllocSize 也就是512* 0.5，也就是256.也是指最大能够申请的大小，超过这个大小就需要扩容了。
- 3.mNext 记录LinearAllocator本次申请后的终点。

我们先来看看几个重要查找内存位置方法：
- 1.start 方法实际上就是当前page的指针向后偏移Page的大小，并且ALIGN_PTR进行指针地址对齐。ALIGN_PTR的操作就是先把当前的指针地址先加3，接着与上3的非，这样能保证增加后的两位都为0，这样就能保证是4的倍数。

- 2.end 计算当前内存的末尾，指针大小+申请的页数大小

- 3.fitsInCurrentPage 判断当前的需要申请的大小是否能够被满足，计算方式最后一次申请的起点+即将申请的大小< 当前已经申请大小的末尾

- 4.newPage 当超过mMaxAllocSize的阈值的时候，将会调用newPage申请新的内存。能看到每一次申请对应对象的大小，将会在mTotalAllocated累计起来，mPageCount进行累加申请了多少页。
而申请的大小通过malloc方式申请：
> 新申请的大小 = 对齐内存（即将申请对象的大小 + Page大小）

##### allocImpl 申请实现
```cpp
void* LinearAllocator::allocImpl(size_t size) {
    size = ALIGN(size);
    if (size > mMaxAllocSize && !fitsInCurrentPage(size)) {
        Page* page = newPage(size);
        mDedicatedPageCount++;
        page->setNext(mPages);
        mPages = page;
        if (!mCurrentPage) mCurrentPage = mPages;
        return start(page);
    }
    ensureNext(size);
    void* ptr = mNext;
    mNext = ((char*)mNext) + size;
    mWastedSpace -= size;
    return ptr;
}
```
- 1.首先对需要申请的大小进行ALIGN 字节对齐处理
- 2.判断需要申请的大小是否大于mMaxAllocSize且当前的页所支持有的大小不能满足当前需要申请的大小，则先通过newPage申请一个size内存大小page对象，把page的mNextPage对象设置为mPage对象，并且更新mPage的指针为最新对象，最后调用start方法，找到page申请出来大小的指针，并且返回起始地址。
- 3.如果满足剩余的Page当前需要申请的大小且小于mMaxAllocSize大小，则通过ensureNext查找合适的大小，并以mNext指针为起始地址返回，同时记录新的mNext地址作为申请的末尾，等待下次申请，并且把mWastedSpace的大小缩减。

###### ensureNext
```cpp
void LinearAllocator::ensureNext(size_t size) {
    if (fitsInCurrentPage(size)) return;

    if (mCurrentPage && mPageSize < MAX_PAGE_SIZE) {
        mPageSize = min(MAX_PAGE_SIZE, mPageSize * 2);
        mMaxAllocSize = mPageSize * MAX_WASTE_RATIO;
        mPageSize = ALIGN(mPageSize);
    }
    mWastedSpace += mPageSize;
    Page* p = newPage(mPageSize);
    if (mCurrentPage) {
        mCurrentPage->setNext(p);
    }
    mCurrentPage = p;
    if (!mPages) {
        mPages = mCurrentPage;
    }
    mNext = start(mCurrentPage);
}
```
- 1.如果fitsInCurrentPage判断到大小已经合适当前需要申请的大小，则直接返回，把当前的mNext申请到Page的地址起点返回。
- 2.如果mCurrentPage存在，且mPageSize(已经申请的Page的大小)小于MAX_PAGE_SIZE，说明此时原来已有的空余Page已经无法满足需要申请的大小，需要进行一次扩容。

> 扩容的上限数值为：MAX_PAGE_SIZE为128kb

在128kb的限制夏，每一次对在上一次的PageSize的大小2倍基础上进行扩容。同时对mMaxAllocSize 最大可以申请到的阈值更新为新的PageSize的一半。

mPageSize最后需要进行一次，字节对齐。

- 3.mWastedSpace 新增一个mPageSize大小，同时根据需要扩容的mPageSize进行newPage的申请。mCurrentPage如果存在，则mCurrentPage的mNext设置为新申请的page对象。mPages为空，说明是第一次申请，则把mPages设置为mCurrentPage。mNext设置为当前当前新申请的Page的起点。

可能到这里，有的读者还是有点模糊，我这里再上几幅图就能明白LinearAllocator的内存管理思想。

每一个内存单元管理如下：
![LinearAlloc.jpg](/images/LinearAlloc.jpg)

有了这个内存管理支持后，当需要销毁的时候，会调用LinearAllocator的析构函数。
```cpp
LinearAllocator::~LinearAllocator(void) {
    while (mDtorList) {
        auto node = mDtorList;
        mDtorList = node->next;
        node->dtor(node->addr);
    }
    Page* p = mPages;
    while (p) {
        Page* next = p->next();
        p->~Page();
        free(p);
        RM_ALLOCATION();
        p = next;
    }
}
```

#### RecordedOp 绘制操作基础对象
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RecordedOp.h](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RecordedOp.h)
来看看它的声明：
```cpp
struct RecordedOp {
    /* ID from RecordedOpId - generally used for jumping into function tables */
    const int opId;

    /* bounds in *local* space, without accounting for DisplayList transformation, or stroke */
    const Rect unmappedBounds;

    /* transform in recording space (vs DisplayList origin) */
    const Matrix4 localMatrix;

    /* clip in recording space - nullptr if not clipped */
    const ClipBase* localClip;

    /* optional paint, stored in base object to simplify merging logic */
    const SkPaint* paint;

protected:
    RecordedOp(unsigned int opId, BASE_PARAMS)
            : opId(opId)
            , unmappedBounds(unmappedBounds)
            , localMatrix(localMatrix)
            , localClip(localClip)
            , paint(paint) {}
};
```
- 1.opId RecordedOp 绘制操作的类型id
- 2.unmappedBounds RecordedOp 绘制操作的区域(不考虑画笔宽度以及变换)
- 3.localMatrix 坐标的转化矩阵
- 4.localClip 裁剪区域
- 5.paint 画笔

我们可以看看几个经典的继承例子：
代表绘制线的操作对象LinesOp：
```cpp
struct LinesOp : RecordedOp {
    LinesOp(BASE_PARAMS, const float* points, const int floatCount)
            : SUPER(LinesOp), points(points), floatCount(floatCount) {}
    const float* points;
    const int floatCount;
};
```
线所有点集合points。

代表颜色操作的RecordedOp
```cpp
struct ColorOp : RecordedOp {
    // Note: unbounded op that will fillclip, so no bounds/matrix needed
    ColorOp(const ClipBase* localClip, int color, SkBlendMode mode)
            : RecordedOp(RecordedOpId::ColorOp, Rect(), Matrix4::identity(), localClip, nullptr)
            , color(color)
            , mode(mode) {}
    const int color;
    const SkBlendMode mode;
};
```
代表色值的color。

还有TextureView接触的对象TextureLayerOp：
```cpp
struct TextureLayerOp : RecordedOp {
    TextureLayerOp(BASE_PARAMS_PAINTLESS, DeferredLayerUpdater* layer)
            : SUPER_PAINTLESS(TextureLayerOp), layerHandle(layer) {}

    // Copy an existing TextureLayerOp, replacing the underlying matrix
    TextureLayerOp(const TextureLayerOp& op, const Matrix4& replacementMatrix)
            : RecordedOp(RecordedOpId::TextureLayerOp, op.unmappedBounds, replacementMatrix,
                         op.localClip, op.paint)
            , layerHandle(op.layerHandle) {}
    DeferredLayerUpdater* layerHandle;
};
```
内部包含了一个DeferredLayerUpdater，由于更新一块图层区域DeferredLayerUpdater对象。关于DeferredLayerUpdater的原理详细的可以阅读我写的[ SurfaceView和TextureView 源码浅析(下)](https://www.jianshu.com/p/1dce98846dc7)一文，注意TextView一文中实际上就是打开了Skia开关后的逻辑。


##### RenderNodeOp
除此之外，还有另一个比较重要的对象RenderNodeOp：
```cpp
struct RenderNodeOp : RecordedOp {
    RenderNodeOp(BASE_PARAMS_PAINTLESS, RenderNode* renderNode)
            : SUPER_PAINTLESS(RenderNodeOp), renderNode(renderNode) {}
    RenderNode* renderNode;  // not const, since drawing modifies it
    Matrix4 transformFromCompositingAncestor;
    bool skipInOrderDraw = false;
};
```
能看到RenderNodeOp这个操作实际上是包含了一个RenderNode对象。实际上mDisplayList对象将会通过RenderNodeOp控制所有的子renderNode。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[DisplayList.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/DisplayList.cpp)

```cpp
size_t DisplayList::addChild(NodeOpType* op) {
    referenceHolders.push_back(op->renderNode);
    size_t index = children.size();
    children.push_back(op);
    return index;
}
```
还记得这个children实际上就是NodeOpType的集合吗？那么就可以看到，实际上父容器的RenderNode是通过其生成的DisplayListCanvas中的DisplayList的NodeOpType集合控制所有的子RenderNode。

从而在硬件渲染线程中构造出和软件渲染一样的View树。


#### Canvas的构造函数
RecordingCanvas的构造函数还是直接调用基类的构造函数，我们来直接看看Canvas的对象：
```java
    public Canvas(long nativeCanvas) {
        if (nativeCanvas == 0) {
            throw new IllegalStateException();
        }
        mNativeCanvasWrapper = nativeCanvas;
        mFinalizer = NoImagePreloadHolder.sRegistry.registerNativeAllocation(
                this, mNativeCanvasWrapper);
        mDensity = Bitmap.getDefaultDensity();
    }
```
能看到很简单实际上就是监听了mNativeCanvasWrapper的回收方法。

#### DisplayListCanvas nResetDisplayListCanvas  重置整个DisplayListCanvas对象
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_DisplayListCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_DisplayListCanvas.cpp)
```cpp
static void android_view_DisplayListCanvas_resetDisplayListCanvas(jlong canvasPtr,
        jlong renderNodePtr, jint width, jint height) {
    Canvas* canvas = reinterpret_cast<Canvas*>(canvasPtr);
    RenderNode* renderNode = reinterpret_cast<RenderNode*>(renderNodePtr);
    canvas->resetRecording(width, height, renderNode);
}
```
实际上还是调用了RecordingCanvas的resetRecording，一个新的DisplayList以及重置快照。

#### DisplayListCanvas drawRenderNode
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[DisplayListCanvas.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/DisplayListCanvas.java)

```java
    public void drawRenderNode(RenderNode renderNode) {
        nDrawRenderNode(mNativeCanvasWrapper, renderNode.getNativeDisplayList());
    }
```

文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_view_DisplayListCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_view_DisplayListCanvas.cpp)
```cpp
static void android_view_DisplayListCanvas_drawRenderNode(jlong canvasPtr, jlong renderNodePtr) {
    Canvas* canvas = reinterpret_cast<Canvas*>(canvasPtr);
    RenderNode* renderNode = reinterpret_cast<RenderNode*>(renderNodePtr);
    canvas->drawRenderNode(renderNode);
}
```
实际上很简单，就是调用了RecordingCanvas的drawRenderNode方法。

##### RecordingCanvas drawRenderNode
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[hwui](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/)/[RecordingCanvas.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/hwui/RecordingCanvas.cpp)
```cpp
void RecordingCanvas::drawRenderNode(RenderNode* renderNode) {
    auto&& stagingProps = renderNode->stagingProperties();
    RenderNodeOp* op = alloc().create_trivial<RenderNodeOp>(
            Rect(stagingProps.getWidth(), stagingProps.getHeight()),
            *(mState.currentSnapshot()->transform), getRecordedClip(), renderNode);
    int opIndex = addOp(op);
    if (CC_LIKELY(opIndex >= 0)) {
        int childIndex = mDisplayList->addChild(op);

        // update the chunk's child indices
        DisplayList::Chunk& chunk = mDisplayList->chunks.back();
        chunk.endChildIndex = childIndex + 1;

        if (renderNode->stagingProperties().isProjectionReceiver()) {
            // use staging property, since recording on UI thread
            mDisplayList->projectionReceiveIndex = opIndex;
        }
    }
}
```
drawRenderNode方法首先先通过addOp，把RenderNodeOp操作添加到ops操作集合中，同时通过addChild把子的RenderNode交给当前的DisplayList进行管理。


##### RecordingCanvas addOp
```cpp
int RecordingCanvas::addOp(RecordedOp* op) {
    // skip op with empty clip
    if (op->localClip && op->localClip->rect.isEmpty()) {
        return -1;
    }

    int insertIndex = mDisplayList->ops.size();
    mDisplayList->ops.push_back(op);
    if (mDeferredBarrierType != DeferredBarrierType::None) {
        // op is first in new chunk
        mDisplayList->chunks.emplace_back();
        DisplayList::Chunk& newChunk = mDisplayList->chunks.back();
        newChunk.beginOpIndex = insertIndex;
        newChunk.endOpIndex = insertIndex + 1;
        newChunk.reorderChildren = (mDeferredBarrierType == DeferredBarrierType::OutOfOrder);
        newChunk.reorderClip = mDeferredBarrierClip;

        int nextChildIndex = mDisplayList->children.size();
        newChunk.beginChildIndex = newChunk.endChildIndex = nextChildIndex;
        mDeferredBarrierType = DeferredBarrierType::None;
    } else {
        // standard case - append to existing chunk
        mDisplayList->chunks.back().endOpIndex = insertIndex + 1;
    }
    return insertIndex;
}
```
实际上这里的操作有2个：
- 1.mDisplayList的ops保存当前的操作。
- 2.mDeferredBarrierType不为None，则获取末尾位置的chunk数据块对象，保存相关的参数。

### DisplayListCanvas end
当start和drawRenderNode后，RenderNode就会调用end方法收尾：
```java
    public void end(DisplayListCanvas canvas) {
        long displayList = canvas.finishRecording();
        nSetDisplayList(mNativeRenderNode, displayList);
        canvas.recycle();
    }
```
- 1.finishRecord 方法结束Canvas对绘制的记录。调用的方法如下：
```cpp
DisplayList* RecordingCanvas::finishRecording() {
    restoreToCount(1);
    mPaintMap.clear();
    mRegionMap.clear();
    mPathMap.clear();
    DisplayList* displayList = mDisplayList;
    mDisplayList = nullptr;
    mSkiaCanvasProxy.reset(nullptr);
    return displayList;
}
```
能看到实际上就是把RecordingCanvas中的DisplayList直接返回给上层对象。

- 2.nSetDisplayList RenderNode记录DisplayList。
```cpp
static void android_view_RenderNode_setDisplayList(JNIEnv* env,
        jobject clazz, jlong renderNodePtr, jlong displayListPtr) {
    RenderNode* renderNode = reinterpret_cast<RenderNode*>(renderNodePtr);
    DisplayList* newData = reinterpret_cast<DisplayList*>(displayListPtr);
    renderNode->setStagingDisplayList(newData);
}
```
```cpp
void RenderNode::setStagingDisplayList(DisplayList* displayList) {
    mValid = (displayList != nullptr);
    mNeedsDisplayListSync = true;
    delete mStagingDisplayList;
    mStagingDisplayList = displayList;
}
```
能看到实际上RenderNode的native对象，会先销毁上一次DisplayList对象，并把新的DisplayList保存到mStagingDisplayList中。


## 总结
本文先到这里，到这里我们就知道了整个ThreadRenderer在执行硬件渲染之前都做了什么准备。后续就会开始解析整个硬件渲染的原理。先做做总结。


现在再来看看之前的思维导图：
![ThreadedRender对象.png](/images/ThreadedRender对象.png)

我们先从RenderNode开始总结


### RenderNode的总结
RenderNode可以分为两种：
- 1.一种是保存在ThreadedRenderer中的RootRenderNode，是一个根部RenderNode，在初始化的时候，会添加到CanvasContext中，等待后续的绘制时候从RootRenderNode开始遍历。

- 2.另一种是跟在所有View的RenderNode的对象，这是所有View中都会只有的对象，当打开了硬件渲染，就会走到RenderNode的分支中，把绘制行为都放到RenderNode中。

对于所有的RenderNode都有如下图的职责：
![RenderNode.png](/images/RenderNode.png)

### DisplayListCanvas与DisplayList的总结
所有的DisplayListCanvas都是通过RenderNode的start方法生成的，DisplayListCanvas对应native对象就是RecordingCanvas，下面是一个更加全面的UML图：
![DisplayListCanvas.jpg](/images/DisplayListCanvas.jpg)
从图中可以看到如下关系：
- 1.DisplayListCanvas在底层和RecordingCanvas/SkiaRecordingCanvas 一一对应。所有在硬件渲染画布上的内容实际上保存在RecordingCanvas。

- 2.RecordingCanvas 之所以名字为Recording 记录，原因很简单，因为通过draw，onDraw，drawdispatch三个流程时候，并不会立即绘制到内存中，而是把绘制操作变成一个个BaseOpType保存在DisplayList中。当一次绘制结束后就会通过RenderNode.end把DisplayList保存到RenderNode中。

- 3.在RecordingCanvas中有一个十分关键的类DisplayList。DisplayList中有两个比较核心的集合，这两个集合贯通了硬件渲染的全局，一个是ops，一个是children。

ops是BaseOpType的集合，实际上是一个个RecordedOp集合。这个集合一般不记录RecordedOp基础结构体，而是收集那些通过继承扩展成Text，Color等有实际操作的意义的操作。

children是RenderNodeOp。虽然也是继承RecordedOp，但是RenderNodeOp中包含了子RenderNode，因此硬件渲染执行的时候，并不会把RenderNodeOp保存到ops集合中，而是在draw方法的时候收集到children集合中。


### RenderThread的总结
RenderThread本质上是活跃在背后的硬件渲染线程：
```java

                final FrameDrawingCallback callback = mNextRtFrameCallback;
                mNextRtFrameCallback = null;
                mAttachInfo.mThreadedRenderer.draw(mView, mAttachInfo, this, callback);
```
在ViewRootImpl的draw方法中会调用判断到mThreadedRenderer可用，则会通过mThreadedRenderer.draw通过RenderProxy进入到RenderThread中。注意RenderThread是一个单例的渲染线程，其中包含着一个Looper和一个WorkQueue。其核心原理几乎和MessageQueue和Looper一致。

所有的任务都是通过RenderThread进入到WorkQueue中，Looper会通过epoll唤醒获取WorkQueue中保存好的WorkItem进行执行。而这些WorkItem包含我们需要执行的渲染的方法指针。

RenderThread的Looper除了执行WorkQueue中保存的渲染方法之外，还做了另一件事情，那就是监听Vsync信号的到来。当每一次Vsync信号到了，将会调用dispatchFrameCallbacks方法开始回调到CanvasContext中执行渲染动作，关于这部分内容，我将放到下一篇文章和大家聊聊。

### CanvasContext与PipeLine的总结
CanvasContext是指绘制上下文，CanvasContext持有一个很关键的对象PipeLine。PipeLine会根据当前配置，选择OpenGL，Skia适配的OpenGL，Skia适配的vulkan进行硬件渲染

总结来说，所有的绘制行为都会集中到CanvasContext中，最后由CanvasContext决定使用哪一个管道进行渲染行为。

每当RenderThread监听到一个Vsync信号到来之后，将会回调到DrawFrameTask中执行真正的像素合成。

### ThreadedRenderer 在ViewRootImpl中扮演的角色与执行时机
总结2个在核心类后，我们全局观看一下ThreadedRenderer在ViewRootImpl中三大绘制流程所扮演的角色。实际上在前面几篇文章中，我有意无意的跳过了硬件渲染的流程。

不熟悉的，可以阅读我之前写的5篇文章：
- 1.[Android 重学系列 View的绘制流程 (一)View的初始化](https://www.jianshu.com/p/003dc36af9db)
- 2.[Android 重学系列 View的绘制流程(二) 绘制的准备](https://www.jianshu.com/p/2f4e7e9e5cc0)
- 3.[Android 重学系列 View的绘制流程(三) onMeasure](https://www.jianshu.com/p/4f8b5c559311)
- 4.[Android 重学系列 View的绘制流程(四) onLayout](https://www.jianshu.com/p/577afa53ce97)
- 5.[Android 重学系列 View的绘制流程(五) onDraw](https://www.jianshu.com/p/a4fb6a02ad53)

实际上真正参与工作是从步骤2 绘制的准备开始的。
在ViewRootImpl的performTraversals方法中执行如下步骤：
- 1.enableHardwareAcceleration 实例化ThreadedRenderer，同时构建RootRenderNode，RenderProxy，CanvasContext，DrawFrameTask等。并通过Looper开始监听Vsync信号.

- 2.initialize 在调用onMeasure遍历全局的View树之前，处理WindowInset之后。让渲染管道PipeLine能够持有Surface对象，从而可以通过Surface通信到SF进程中.

- 3.updateSurface 在调用onMeasure遍历全局的View树之前，处理WindowInset之后发现Surface参数发生了变化，更新硬件渲染PipeLine中的Surface。

- 4.setup 当初始化好PipeLine中的Surface，后启动ThreadedRenderer设置阴影等参数，处理RootRenderNode的左和上偏移量，也就是整个View树的左和上的偏移量。

下面几个步骤是调用draw方法的时候，会判断是否能进行硬件渲染：
- 5.如果需要 执行invalidateRoot 判断是否需要从根部开始遍历查找无效的元素，而判断的依据是整体硬件渲染树是否发生偏移

- 6.draw 开始硬件渲染进行View层级绘制，它包含如下几个步骤：-         
  - 1.updateRootDisplayList 从根部开始遍历整个View树
  - 2.registerAnimatingRenderNode 注册每一个需要执行动画的RenderNode
  - 3.nSetFrameCallback 把FrameDrawingCallback注册到native层
  - 4.nSyncAndDrawFrame 调用native的开始把绘制操作进行合成像素存档到内存。
  - 5.如果绘制结果返回SYNC_LOST_SURFACE_REWARD_IF_FOUND标志位，说明可能Surface无效或者出错，则关闭硬件渲染，释放VRI的mSurface等对象。如果SYNC_INVALIDATE_REQUIRED返回了，说明还需要下一轮的Loop通过performTravel进行局部刷新。


- 7.updateDisplayListIfDirty 在updateRootDisplayList从根部开始遍历View树的过程中，每一个View都会调用该方法更新硬件渲染中的脏区。当PFLAG_DRAWING_CACHE_VALID 绘制缓存过期标志位关闭说明没有过期，则不需要通过执行一次draw，onDraw，dispatchDraw的流程，把绘制操作保存到RenderNode的DisplayList中等待合成。

- 8.destroy 销毁硬件渲染对象

分析到了nSyncAndDrawFrame就暂时停止，下一篇文章将会接着本文继续聊聊硬件渲染是怎么合成这个操作，从Layer转化为Frame的。













