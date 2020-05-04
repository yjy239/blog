---
title: Android 重学系列 有趣的工具--智能指针与智能锁
top: false
cover: false
date: 2019-07-07 20:17:00
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android
- Linux
- Android Framework
---
# 背景
如果遇到什么问题在这个地址下留言：[https://www.jianshu.com/p/2f0ecf6ca08c](https://www.jianshu.com/p/2f0ecf6ca08c)


在Android 的底层中，编写大量的c/c++源码。但是却很少看到Android去调用delete去删除对象的申请的内存。而这其中，必定有一个东西去管理对象的生命周期。而这个担起这个责任就是智能指针。

于此同时，还能看到Android底层调用了锁之后，我们也没看到相应的解锁方法。实际上这里面起作用的就是智能锁，将锁自动解开。

接下来，将会从智能锁开始，聊聊这两个相似的设计思路。


# 正文
## 智能锁
让我们先看看源码,关于智能锁其中一个例子。
```cpp
void SurfaceFlinger::init() {
...
    Mutex::Autolock _l(mStateLock);
    // start the EventThread
    mEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync, SurfaceFlinger::vsyncPhaseOffsetNs,
                                             true, "app");
    mEventThread = std::make_unique<impl::EventThread>(mEventThreadSource.get(),
                                                       [this]() { resyncWithRateLimit(); },
                                                       impl::EventThread::InterceptVSyncsCallback(),
                                                       "appEventThread");
    mSfEventThreadSource =
            std::make_unique<DispSyncSource>(&mPrimaryDispSync,
                                             SurfaceFlinger::sfVsyncPhaseOffsetNs, true, "sf");

    mSFEventThread =
            std::make_unique<impl::EventThread>(mSfEventThreadSource.get(),
                                                [this]() { resyncWithRateLimit(); },
                                                [this](nsecs_t timestamp) {
                                                    mInterceptor->saveVSyncEvent(timestamp);
                                                },
                                                "sfEventThread");
    mEventQueue->setEventThread(mSFEventThread.get());
    mVsyncModulator.setEventThread(mSFEventThread.get());

    // Get a RenderEngine for the given display / config (can't fail)
    getBE().mRenderEngine =
            RE::impl::RenderEngine::create(HAL_PIXEL_FORMAT_RGBA_8888,
                                           hasWideColorDisplay
                                                   ? RE::RenderEngine::WIDE_COLOR_SUPPORT
                                                   : 0);
   ...
    getBE().mHwc.reset(
            new HWComposer(std::make_unique<Hwc2::impl::Composer>(getBE().mHwcServiceName)));
    getBE().mHwc->registerCallback(this, getBE().mComposerSequenceId);

    processDisplayHotplugEventsLocked();
...

    getDefaultDisplayDeviceLocked()->makeCurrent();
....
}
```
我们能看到作为Android显示系统的核心SurfaceFlinger在自己的进程初始化的时候，会初始化我们MessageQueue(设计思路和Android应用常用的Handler一致，一个消息队列)。作为消息队列，里面没有使用线程安全的数据结构，自然需要上锁，保护里面的数据结构。

虽然在整个Android系统中，一般只会初始化一次SurfaceFlinger。但是这就Google工程还是做了保护措施，可见其思想就是自己的模块要保证自己模块中数据正确性。

我们能看到一个很有趣东西
```cpp
Mutex::Autolock _l(mStateLock);
```
看到这个名字我们大致上能够明白实际上，这必定是个锁。但是我们却没看到哪里解锁，哪里上锁了。

### 智能锁的思路
在看源码之前，我们大致思考一下，如果我们尝试着简化，通过一个对象来管理整个上锁解锁流程应该怎么做。这就能顾让我们联想到，这个过程我们可以让锁跟着对象的创建和销毁的生命周期绑定起来。这样就能很简单做到锁的自动处理。本质上源码也是这么做的。

大致上，我们需要往这个方向努力：
```cpp
#include <strings.h>
#include <pthread.h>
#include "Define.h"
class Mutex {
private:
    pthread_mutex_t mMutex;

public:
    
    Mutex();


    ~Mutex();

};
```

```cpp
#include "Mutex.h"
Mutex::Mutex() {
    pthread_mutex_init(&mMutex,NULL);
    pthread_mutex_lock(&mMutex);

    LOGE("lock");
}

Mutex::~Mutex() {
    pthread_mutex_unlock(&mMutex);
    pthread_mutex_destroy(&mMutex);
    LOGE("unlock");
}
```

调用：
```cpp
    Mutex m;
    LOGE("do something");
```
![智能锁测试.png](/images/智能锁测试.png)

这样就能让锁和对象互相绑定。只要使用这种方式就能够让这个Mutex对象跟着方法内的作用域跑，当这个作用域跑完，就能自动解锁。也就是这种思路，才会在Android一些底层看到这么调用。

但是这样的思路，让我们看到一种可行性，就是通过作用域来决定对象的释放实际，从而决定锁的释放范围。

可以看到源码BufferQueueProducer(显示系统中生产GraphBuffer的生产队列)中
```cpp
status_t BufferQueueProducer::dequeueBuffer(int* outSlot, sp<android::Fence>* outFence,
                                            uint32_t width, uint32_t height, PixelFormat format,
                                            uint64_t usage, uint64_t* outBufferAge,
                                            FrameEventHistoryDelta* outTimestamps) {
    ATRACE_CALL();
    { // Autolock scope
        Mutex::Autolock lock(mCore->mMutex);
        mConsumerName = mCore->mConsumerName;

        if (mCore->mIsAbandoned) {
            BQ_LOGE("dequeueBuffer: BufferQueue has been abandoned");
            return NO_INIT;
        }

        if (mCore->mConnectedApi == BufferQueueCore::NO_CONNECTED_API) {
            BQ_LOGE("dequeueBuffer: BufferQueue has no connected producer");
            return NO_INIT;
        }
    } // Autolock scope
....
}
```

可以灵活运用着在方法创造一个作用域，让智能锁自动解锁。

当然这只是雏形，我们看看底层是做了什么。我们随意抽一个Mutex的实现看看。
```cpp
class Mutex {
public:
    Mutex() {
        pthread_mutex_init(&mMutex, NULL);
    }
    int lock() {
        return -pthread_mutex_lock(&mMutex);
    }
    void unlock() {
        pthread_mutex_unlock(&mMutex);
    }
    ~Mutex() {
        pthread_mutex_destroy(&mMutex);
    }

    // A simple class that locks a given mutex on construction
    // and unlocks it when it goes out of scope.
    class Autolock {
    public:
        Autolock(Mutex &mutex) : lock(&mutex) {
            lock->lock();
        }
        ~Autolock() {
            lock->unlock();
        }
    private:
        Mutex *lock;
    };

private:
    pthread_mutex_t mMutex;

    // Disallow copy and assign.
    Mutex(const Mutex&);
    Mutex& operator=(const Mutex&);
};
```

其思路和和我们的上面的思路很相似。但是能够看到这里面Mutex是对pthread_mutex_t对象的存在进行管理。Autolock则是让这个对象在作用域能进行上锁解锁管理。同时禁止了Mutex的拷贝构造函数，因为这样会造成意料之外的锁存在。

当然，在[/system/core/libutils/include/utils/](http://androidxref.com/9.0.0_r3/xref/system/core/libutils/include/utils/)下还有写的更好的智能锁。

能看到的是，让某种行为绑定着对象的生命周期这种设计也是很常见。比如说Glide的每一次请求都是绑定在当前Activity一个隐形的Fragment中。


接下来让我们看看更加重要的智能智能。
## 智能指针
智能指针诞生的初衷来源，c++每一次new一个新的对象，因为对象的内存放到了堆中，导致我们必须想办法清除掉堆中的内存。当我们忘记清除指针指向的内存时候，就会产生野指针问题。然而每一次想办法在合适的地方delete，将会让整个工程复杂度提升了一个等级，也给每个程序员素质的考验。

就以我之前写Binder来说，大部分对象的操作都在内核中，对binder_transaction这些事务来回拷贝，binder_ref在不断的使用，想要找到一个合适的时机delete需要判断的东西就十分多。

此时就诞生了智能指针。本质上智能指针的思路，实际上和我们所说的引用计数本质上是一个东西。

引用计数的思路就是，当每一次引用，就对这个对象引用加一，当超过作用域的之类调用一次析构函数函数，引用计数减一。知道引用计数一直减到1，说明再也没有任何对象引用这个对象，就能安心的销毁（初始引用次数为1）。

但是这种内存计数方式有一个致命缺点，就是当两个引用互相引用时候，会发生循环计数的问题。而智能指针的为了解决这个，诞生了强引用指针和弱引用指针。

了解这些之后，我们尝试的思考怎么编写智能指针才能解决上面那些问题。

### 智能指针设计思路
首先我们能够确定是这必定是一个模版类，同时能够为了能够管理指针，必定会传一个指针进来。

对于指针的计数，我们能不能模仿智能锁那样，通过某个类包装起来，让某个全权管理这个类的真正的析构时机以及计数呢？

就想我上面的说的，加入让智能指针这个对象去管理计数，就会出现一个致命的情况。当智能指针1和智能指针2都引用同一个对象的时候，当智能指针1的计数减为0，要去析构的时候，智能指针2还持用着计数，此时就会出现析构失败。

因此，我们不可能只用一个类去完成。这个过程中，至少需要两个类，一个是用于计数，另一个是用于管理指针。

接下来让我们尝试，编写一个智能指针。首先创建一个LightRefBase基类，让之后所有的类都去继承这个类，让类自己拥有计数的功能。接着再创建一个SmartPointer去管理指针。
#### LightRefBase
```cpp
#ifndef SMARTTOOLS_LIGHTREFBASE_H
#define SMARTTOOLS_LIGHTREFBASE_H

#include <stdio.h>
#include <atomic>
#include <Define.h>

using namespace std;

template <class T>
class LightRefBase {
public:
    LightRefBase():mCount(0){

    }

    void incStrong(){
        mCount.fetch_add(1,memory_order_relaxed);
        LOGE("inc");
    }

    void decStrong(){
        LOGE("dec");
        if(mCount.fetch_sub(1,memory_order_release) == 1){
            atomic_thread_fence(memory_order_acquire);
            delete static_cast<const T*>(this);
            LOGE("delete");
        }
    }


private:
    mutable atomic<int> mCount;

};


#endif //SMARTTOOLS_LIGHTREFBASE_H
```

能看到的是，这里我创建了一个模版类，一个轻量级别的引用计数。当调用incStrong，将会增加原子计数引用次数。当调用decStrong，则会减少原子计数的引用次数。

这里稍微记录一下atomic原子类操作。
- 1. fetch_add 是指原子数字的增加
- 2. fetch_sub 是指原子数字的减少

在这些原子模版类的操作中memory_order_release之类的内存顺序约束的操作。一共有如下操作：
```cpp
enum memory_order {

memory_order_relaxed,

memory_order_consume,

memory_order_acquire,

memory_order_release,

memory_order_acq_rel,

memory_order_seq_cst

};
```
这6种memory_order可以分为3类。第一类，relaxed内存松弛。第二类，sequential_consistency内存一致序，第三类acquire-release获取释放一致序。

- 对于内存松弛（memory_order_relaxed），对于多线程没有指令顺序一致性要求。只是保证了在一个线程内的原子操作保证了顺序上处理。对于不同线程之间的执行顺序是随意的。

- 对于内存一致序（memory_order_seq_cst），这是以牺牲优化效率，来保证指令顺序的一致性。相当于不打开编译器的优化指令。按照正常指令执行序执行，多线程之间原子操作也会Synchronized-with，比如atomic::load()需要等待atomic::store()写下元素才能读取，同步过程。

- 获取释放一致序，相当于对relaxed的加强。relax序由于无法限制多线程间的排序，所以引入synchronized-with，但并不一定意味着，统一的操作顺序。因为可能出现当出现读写操作时候，写入操作完成但是还是在缓存，并没有对应的内存，造成的异常。因此设计上诞生memory_order_release释放锁，memory_order_acquire上自旋锁。memory_order_consume的多线程消费者生产这些设计。

#### SmartPointer
在编写SmartPointer的时候，记住要重写几个操作符号，因为赋值，创造构造SmartPointer的构造函数，我们都需要为对象的引用计数加一。当超出了作用域，则把对象的引用减一。
```cpp
#ifndef SMARTTOOLS_SMARTPOINTER_H
#define SMARTTOOLS_SMARTPOINTER_H

#include <stdio.h>

template <class  T>
class SmartPointer {
private:
    T* m_ptr;

public:
    SmartPointer():m_ptr(0){

    }


    SmartPointer(T *ptr){
        if(m_ptr){
            m_ptr = ptr;
            m_ptr->incStrong();
        }


    }


    ~SmartPointer(){
        if(m_ptr){
            m_ptr->decStrong();
        }
    }

    SmartPointer& operator = (T* other){
        if(other){
            m_ptr = other;
            other->incStrong();
        }

        return *this;
    }
};

#endif //SMARTTOOLS_SMARTPOINTER_H
```

接下来我们测试一下，在随意一个方法，测试一下。
```cpp
class TestLight :public LightRefBase<TestLight>{
public:
    TestLight(){

    }
};

SmartPointer<TestLight> sp(new TestLight());
```

看到了吗，这个形式就和我们之前在Binder源码分析时候，出现的引用计数时候声明一个sp的方式一模一样。
测试一下：
![简单智能指针测试.png](/images/简单智能指针测试.png)

在一个方法内，确实完成了自动增加计数和销毁了。这样的设计和智能(自动锁)锁十分相似。都是灵活运用了作用域和析构函数之间的关系，对对象的引用计数做了内存管理，来判断是否继续需要这个对象。

### LightRefBase的缺点分析
正如上面所说的一样，这么做虽然能做到简单的计数统计，似乎没有什么问题。为什么Java虚拟机不采用引用计数，而去使用GC引用链对对象进行内存挂历。

我们来考虑这种情况。
当A和B互相引用的时候。就造成这么一个问题
![互相引用计数.png](/images/互相引用计数.png)

互相引用的时候，就造成一个特殊的情况。A中的B字段指向了B内存会让B本身无法析构，而B中的A字段指向了A的内存也会让A本身无法析构。

这样就出现，我们常说的循环引用。为了处理这种问题，诞生了强弱指针的概念。

先来聊聊强指针sp(StrongPointer)。强指针和我上面写的SmartPointer原理几乎一致。目的是为了操作继承了RefBase类中引用计数。

那么弱指针诞生就是为了处理循环引用的问题。如果换做是我们的话，我们该怎么处理这种异常呢。

我们回归问题的本质，这种情况类似于死锁，因为系统检查到双方都需要对方的资源，导致无法回收。那么就按照处理死锁的办法，打断死锁的资源的引用链就ok。这就是弱引用诞生的初衷。

强弱指针两种指针，将会分别为自己计数。那么我们一定需要一个删除引用的计数标准，当强引用了一个对象，当强引用的计数减到了1，将会删除里面的引用。

这样就打断了，引用计数的循环。但是，你们一定会想到，当我们删除A对象的引用，从B访问A，不就会出现了访问野指针/空指针的问题吗？

因此弱指针又有一个规定，弱指针不能直接访问对象，必须升级为强指针才能访问对象。

有这几个标准之后，我们尝试编写一下弱指针的源码。我们抛弃原来的LightRefBase，创建一个更加泛用的RefBase基类。
```cpp
#ifndef SMARTTOOLS_REFBASE_H
#define SMARTTOOLS_REFBASE_H

#include <stdio.h>
#include <StrongPointer.h>

#define COMPARE_WEAK(_op_)                                      \
inline bool operator _op_ (const sp<T>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}                                                               \
inline bool operator _op_ (const T* o) const {                  \
    return m_ptr _op_ o;                                        \
}                                                               \
template<typename U>                                            \
inline bool operator _op_ (const sp<U>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}                                                               \
template<typename U>                                            \
inline bool operator _op_ (const U* o) const {                  \
    return m_ptr _op_ o;                                        \
}

class RefBase {
public:
    void incStrong(const void* id) const;

    void decStrong(const void* id) const;

    int getStrongCount(const void* id) const;

    void forceStrong(const void* id) const;


    class weakref_type{
    public:
        RefBase* refBase() const;

        void incWeak(const void* id);

        void decWeak(const void* id);

        // acquires a strong reference if there is already one.
        bool attemptIncStrong(const void* id);

        bool attemptIncWeak(const void* id);

        int getWeakCount() const;

    };

    weakref_type* createWeak(const void* id) const;

    weakref_type* getWeakRef()const;

protected:
    RefBase();

    virtual ~RefBase();

    enum {
        OBJECT_LIFETIME_STRONG = 0x0000,
        OBJECT_LIFETIME_WEAK = 0x0001,
        OBJECT_LIFETIME_MASK = 0x0001
    };

    void extendObjectLifetime(int mode);

    enum {
        FIRST_INC_STRONG = 0x0001
    };

    virtual void onFirstRef();

    virtual void onLastStrongRef(const void* id);

    virtual bool onIncStrongAttempted(int flag, const void* id);

    virtual void onLastWeakRef(const void* id);

private:
    //为了让weakref_type去访问到refbase中的私有数据
    friend class weakref_type;
    //一个实现类
    class weakref_impl;
    RefBase(const RefBase& o);

    RefBase& operator =(const RefBase& o);

    weakref_impl *const mRefs;
};

//---------------------

template <typename T>
class wp{
public:
    typedef typename RefBase::weakref_type weakref_type;

    inline wp():m_ptr(0){}

    wp(T* other);
    //拷贝构造函数
    wp(const wp<T>& other);

    explicit wp(const sp<T>& other);


    template <typename U> wp(U* other);

    template <typename U> wp(const sp<U>& other);

    template <typename U> wp(const wp<U>& other);


    ~wp();


    wp& operator = (T* other);
    wp& operator = (const wp<T>& other);
    wp& operator = (const sp<T>& other);

    template<typename U> wp& operator = (U* other);
    template<typename U> wp& operator = (const wp<U>& other);
    template<typename U> wp& operator = (const sp<U>& other);

    void set_object_and_refs(T* other, weakref_type* refs);

    // promotion to sp

    sp<T> promote() const;

    
    // Reset

    void clear();

    // Accessors

    inline  weakref_type* get_refs() const { return m_refs; }

    inline  T* unsafe_get() const { return m_ptr; }

    // Operators
//
    COMPARE_WEAK(==)
    COMPARE_WEAK(!=)
    COMPARE_WEAK(>)
    COMPARE_WEAK(<)
    COMPARE_WEAK(<=)
    COMPARE_WEAK(>=)

    inline bool operator == (const wp<T>& o) const {
        return (m_ptr == o.m_ptr) && (m_refs == o.m_refs);
    }
    template<typename U>
    inline bool operator == (const wp<U>& o) const {
        return m_ptr == o.m_ptr;
    }

    inline bool operator > (const wp<T>& o) const {
        return (m_ptr == o.m_ptr) ? (m_refs > o.m_refs) : (m_ptr > o.m_ptr);
    }
    template<typename U>
    inline bool operator > (const wp<U>& o) const {
        return (m_ptr == o.m_ptr) ? (m_refs > o.m_refs) : (m_ptr > o.m_ptr);
    }

    inline bool operator < (const wp<T>& o) const {
        return (m_ptr == o.m_ptr) ? (m_refs < o.m_refs) : (m_ptr < o.m_ptr);
    }
    template<typename U>
    inline bool operator < (const wp<U>& o) const {
        return (m_ptr == o.m_ptr) ? (m_refs < o.m_refs) : (m_ptr < o.m_ptr);
    }
    inline bool operator != (const wp<T>& o) const { return m_refs != o.m_refs; }
    template<typename U> inline bool operator != (const wp<U>& o) const { return !operator == (o); }
    inline bool operator <= (const wp<T>& o) const { return !operator > (o); }
    template<typename U> inline bool operator <= (const wp<U>& o) const { return !operator > (o); }
    inline bool operator >= (const wp<T>& o) const { return !operator < (o); }
    template<typename U> inline bool operator >= (const wp<U>& o) const { return !operator < (o); }


private:
    template <typename Y> friend class wp;
    template <typename Y> friend class sp;
    T* m_ptr;
    weakref_type* m_refs;
};

#undef COMPARE_WEAK

#endif //SMARTTOOLS_REFBASE_H
```
我们能看到，所有的要使用智能指针的对象，都要继承RefBase对象。里面包含了关键的增加强引用计数以及减少强引用计数的方法，以及创建弱引用和获取强弱引用计数的方法。

并且为了方便弱引用能够访问到Refbase中的私有属性，作为一个友元类存在里面。

同时创建一个wp(WeakPointer)弱引用的类。里面包含了必要的构造函数，以及比对方法。为了避免用户使用操作符号，对弱引用中的东西进行操作，必须重写所有的操作符号。

更重要的是，声明一个promote方法，这个方法的作用就是把wp弱引用指针升级为强引用指针。

等一下，读者肯定会好奇了，为什么已经存在了wp的类，还要创造一个weakref_type的类呢？

从我们上面的设计上看来，我们需要统计sp和wp的引用计数，并且以sp的引用计数为标准进行删除。那么我们势必需要计算两者计数。那么我们为什么不抽离这一块计数逻辑出来呢？weakref_type的实现是weak_impl,因此其存在意义就是方便计算两种指针的引用次数。

那么我们继续实现sp，强引用的头文件StrongPointer。
```cpp
#ifndef SMARTTOOLS_STRONGPOINTER_H
#define SMARTTOOLS_STRONGPOINTER_H

template <typename T> class wp;

#define COMPARE(_op_)                                           \
inline bool operator _op_ (const sp<T>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}                                                               \
inline bool operator _op_ (const T* o) const {                  \
    return m_ptr _op_ o;                                        \
}                                                               \
template<typename U>                                            \
inline bool operator _op_ (const sp<U>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}                                                               \
template<typename U>                                            \
inline bool operator _op_ (const U* o) const {                  \
    return m_ptr _op_ o;                                        \
}                                                               \
inline bool operator _op_ (const wp<T>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}                                                               \
template<typename U>                                            \
inline bool operator _op_ (const wp<U>& o) const {              \
    return m_ptr _op_ o.m_ptr;                                  \
}

template <typename T>
class sp{
    inline sp():m_ptr(0){}

    sp(T* other);

    sp(const sp<T>& other);

    sp(sp<T>&& other);

    template <typename U> sp(U *other);

    template <typename U> sp(const sp<U>& other);

    template <typename U> sp(sp<U>&& other);


    ~sp();


    sp& operator = (T* other);

    sp& operator = (const sp<T>& other);

    sp&operator = (sp<T>&& other);


    template <typename U> sp&operator = (const sp<U>& other);

    template <typename U> sp&operator = (sp<U>&& other);

    template <typename U> sp&operator = (U* other);

    void force_set(T* other);

    void clear();

    inline T& operator*() const {
        return *m_ptr;
    };

    inline T* operator -> ()const{
        return m_ptr;
    }

    inline T* get() const {
        return m_ptr;
    }

    inline explicit operator bool () const {
        return m_ptr != nullptr;
    }


    // Operators

    COMPARE(==)
    COMPARE(!=)
    COMPARE(>)
    COMPARE(<)
    COMPARE(<=)
    COMPARE(>=)


private:
    template <typename Y> friend class wp;
    template <typename Y> friend class sp;
    void set_pointer(T* ptr);
    T* m_ptr;
};

#endif //SMARTTOOLS_STRONGPOINTER_H

```

sp的设计上相对简单点，和上面的SmartPointer十分相似。只是复写很多操作符号。

## 实现sp，wp，weakref_type
### wp的实现
```cpp
template <typename T>
wp<T>::wp(T *other):m_ptr(other){
    if(other){
        m_refs = other->createWeak(this);
    }
}


template <typename T>
wp<T>::wp(const wp<T>& other)
:m_ptr(other.m_ptr),m_refs(other.m_refs){
    //other的指针不为空，再增加弱引用计数
    if(m_ptr){
        m_refs->incWeak(this);
    }
}

template <typename T>
wp<T>::wp(const sp<T>& other):m_ptr(other.m_ptr){
    if(m_ptr){
        m_refs = m_ptr->createWeak(this);
    }
}

template <typename T> template <typename U>
wp<T>::wp(U *other)
:m_ptr(other){
    if(other){
        m_refs = other->createWeak(this);
    }
}


template <typename T> template <typename U>
wp<T>::wp(const wp<U>& other)
:m_ptr(other.m_ptr){
    if(m_ptr){
        m_refs = other.m_refs;
        m_refs->incWeak(this);
    }
}

template <typename T> template <typename U>
wp<T>::wp(const sp<U>& other)
:m_ptr(other.m_ptr){
    if(m_ptr){
        m_refs = m_ptr->createWeak(this);
    }
}


template <typename T>
wp<T>::~wp() {
    if(m_ptr){
        m_refs->decWeak(this);
    }
}


template <typename T>
wp<T>& wp<T>::operator=(T *other) {
    //赋值操作，把带着RefBase的对象复制给弱引用
    //为新的对象创建引用计数器
    weakref_type* newRefs = other ? other->createWeak(this) : 0;
    //如果原来的指针有数据，则需要把原来的弱引用减一。
    //因为此时相当于把当前已有的弱引用被新来的替换掉
    //那么，原来引用的弱引用计数要减一
    if(m_ptr){
        m_refs->decWeak(this);
    }


    m_ptr = other;
    m_refs = newRefs;
    return *this;
}


template <typename T>
wp& wp<T>::operator=(const wp<T> &other) {
    //弱引用赋值
    weakref_type* otherRef(other.m_refs);
    T* otherPtr(other.m_ptr);
    if(otherPtr){
        otherPtr->incWeak(this);
    }

    if(m_ptr){
        m_refs->decWeak(this);
    }

    m_ptr = otherPtr;
    m_refs = otherRef;
    return *this;
}

template <typename T>
wp& wp<T>::operator=(const sp<T> &other) {
    //强引用赋值给弱引用
    //和上面对象赋值同理
    weakref_type* newRefs = other ? other->createWeak(this) : 0;
    T* otherPtr(other.m_ptr);
    if(m_ptr){
        m_refs->decWeak(this);
    }

    m_ptr = otherPtr;
    m_refs = newRefs;
    return *this;
}

template <typename T> template <typename U>
wp& wp<T>::operator=(U *other) {
    //不是同类型赋值给弱引用
    weakref_type* newRefs = other ? other->createWeak(this) : 0;
    if(m_ptr){
        m_refs->decWeak(this);
    }

    m_ptr = other;
    m_refs = newRefs;
    return *this;
}

template<typename T> template<typename U>
wp<T>& wp<T>::operator = (const wp<U>& other)
{
    //不同类型的弱引用赋值
    weakref_type* otherRefs(other.m_refs);
    U* otherPtr(other.m_ptr);
    if (otherPtr){
        otherRefs->incWeak(this);
    }
    if (m_ptr){
        m_refs->decWeak(this);
    }
    m_ptr = otherPtr;
    m_refs = otherRefs;
    return *this;
}

template<typename T> template<typename U>
wp<T>& wp<T>::operator = (const sp<U>& other)
{
    //不同对象的强引用赋值给弱引用
    weakref_type* newRefs =
            other != NULL ? other->createWeak(this) : 0;
    U* otherPtr(other.m_ptr);
    if (m_ptr){
        m_refs->decWeak(this);
    }
    m_ptr = otherPtr;
    m_refs = newRefs;
    return *this;
}

template<typename T>
void wp<T>::set_object_and_refs(T* other, weakref_type* refs)
{
    //直接赋值对象和引用
    if (other){
        refs->incWeak(this);
    }
    if (m_ptr){
        m_refs->decWeak(this);
    }
    m_ptr = other;
    m_refs = refs;
}

template <typename T>
sp<T> wp<T>::promote() const {
    //核心
    sp<T> result;
    if(m_ptr && m_refs->attemptIncStrong(&result)){
        result.set_pointer(m_ptr);
    }

    return result;
}

template<typename T>
void wp<T>::clear()
{
    if (m_ptr) {
        m_refs->decWeak(this);
        m_ptr = 0;
    }
}
```

能看到这里面大部分的工作都是处理操作符和构造函数。当调用构造函数的时候，会为wp弱引用指针创建一个计数器。当调用赋值操作符时候，会判断原来是否包含引用对象，有则因为我们需要替换，相当于不需要这个对象，需要减少一次引用计数。

在这里面核心还是promote方法。还记得wp不能直接操作，需要promote升级，没错这里是约定俗称的。因此promote的时候会创建一个sp，并且会调用attemptIncStrong增加一次引用计数。attemptIncStrong为了避免多线程干扰而创建的方法，稍后会继续聊聊。

那么sp的思路实际上和wp思路几乎一致
```cpp
template<typename T>
sp<T>::sp(T* other)
        : m_ptr(other) {
    if (other)
        other->incStrong(this);
}

template<typename T>
sp<T>::sp(const sp<T>& other)
        : m_ptr(other.m_ptr) {
    if (m_ptr)
        m_ptr->incStrong(this);
}

template<typename T>
sp<T>::sp(sp<T>&& other)
        : m_ptr(other.m_ptr) {
    other.m_ptr = nullptr;
}

template<typename T> template<typename U>
sp<T>::sp(U* other)
        : m_ptr(other) {
    if (other)
        (static_cast<T*>(other))->incStrong(this);
}

template<typename T> template<typename U>
sp<T>::sp(const sp<U>& other)
        : m_ptr(other.m_ptr) {
    if (m_ptr)
        m_ptr->incStrong(this);
}

template<typename T> template<typename U>
sp<T>::sp(sp<U>&& other)
        : m_ptr(other.m_ptr) {
    other.m_ptr = nullptr;
}

template<typename T>
sp<T>::~sp() {
    if (m_ptr)
        m_ptr->decStrong(this);
}

template<typename T>
sp<T>& sp<T>::operator =(const sp<T>& other) {
    // Force m_ptr to be read twice, to heuristically check for data races.
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    T* otherPtr(other.m_ptr);
    if (otherPtr) otherPtr->incStrong(this);
    if (oldPtr) oldPtr->decStrong(this);
    m_ptr = otherPtr;
    return *this;
}

template<typename T>
sp<T>& sp<T>::operator =(sp<T>&& other) {
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    if (oldPtr) oldPtr->decStrong(this);
    m_ptr = other.m_ptr;
    other.m_ptr = nullptr;
    return *this;
}

template<typename T>
sp<T>& sp<T>::operator =(T* other) {
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    if (other) other->incStrong(this);
    if (oldPtr) oldPtr->decStrong(this);
    m_ptr = other;
    return *this;
}

template<typename T> template<typename U>
sp<T>& sp<T>::operator =(const sp<U>& other) {
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    T* otherPtr(other.m_ptr);
    if (otherPtr) otherPtr->incStrong(this);
    if (oldPtr) oldPtr->decStrong(this);
    m_ptr = otherPtr;
    return *this;
}

template<typename T> template<typename U>
sp<T>& sp<T>::operator =(sp<U>&& other) {
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    if (m_ptr) m_ptr->decStrong(this);
    m_ptr = other.m_ptr;
    other.m_ptr = nullptr;
    return *this;
}

template<typename T> template<typename U>
sp<T>& sp<T>::operator =(U* other) {
    T* oldPtr(*const_cast<T* volatile*>(&m_ptr));
    if (other) (static_cast<T*>(other))->incStrong(this);
    if (oldPtr) oldPtr->decStrong(this);
    m_ptr = other;
    return *this;
}

template<typename T>
void sp<T>::force_set(T* other) {
    other->forceIncStrong(this);
    m_ptr = other;
}

template<typename T>
void sp<T>::clear() {
    if (m_ptr) {
        m_ptr->decStrong(this);
        m_ptr = 0;
    }
}

template<typename T>
void sp<T>::set_pointer(T* ptr) {
    m_ptr = ptr;
}
```
### 小节
可以看见，在wp和sp的体系中，这两者只做两件事情，持有对象引用，并且调用计数方法进行计数。而核心方法还是在weakref_type以及RefBase中。

接下来，我们要实现核心的计数方法。

### weakref_type的实现
首先肯定有强弱引用的计数
```cpp
#define INITIAL_STRONG_VALUE (1<<28)

class RefBase::weakref_impl : public RefBase::weakref_type{
public:
    //强引用计数
    std::atomic<int32_t> mStrong;
    //弱引用计数
    std::atomic<int32_t> mWeak;

    //持有计数基础
    RefBase* const mBase;

    //声明周期的标志位
    std::atomic<int32_t> mFlags;


public:
    explicit weakref_impl(RefBase* base)
    :mStrong(INITIAL_STRONG_VALUE),mWeak(0),mBase(base){

    }

};
```

### RefBase的实现
#### 构造函数
```cpp
RefBase::RefBase():mRefs(new weakref_impl(this)) {

}
```

#### 首先看看，增加引用指针计数。

##### 增加强引用计数
```cpp
void RefBase::incStrong(const void *id) const {
    weakref_impl* const refs = mRefs;
    refs->incWeak(id);
    const int32_t c = refs->mStrong.fetch_add(1,std::memory_order_relaxed);
    //说明不是第一次声明
    if(c != INITIAL_STRONG_VALUE){
        return;
    }

    int32_t old __unused = refs->mStrong.fetch_sub(INITIAL_STRONG_VALUE,std::memory_order_relaxed);

    refs->mBase->onFirstRef();
}
```
能看到的是，为了同步强引用和弱引用的次数，只要每一次增加一次强引用计数，就会增加弱引用次数。但是弱引用就不是如此，因此强引用的次数一定大于弱引用。

在这里面，强引用的计数次数会初始化为（1<<28）就是1向左移动28位。在32位的int中属于十分大的数字。

这么做的好处就是能够通过简单的加减就能知道是否是第一次。

考虑到指针为因为指针是32位，所以这个大数字没有可能被引用这么多次可能。因此只要判断加一前发现不是这个数字INITIAL_STRONG_VALUE，就能确定是不是第一次。从而判断是否调用onFirstRef。这个只有第一次初始化sp才会调用的方法，相当于sp中绑定的生命周期。

从这里就能知道Google工程师的功力深厚。

##### 增加弱引用计数
```cpp
void RefBase::weakref_type::incWeak(const void *id) {
    weakref_impl* const impl = static_cast<weakref_impl*>(this);
    const int32_t c __unused = impl->mWeak.fetch_add(1,
            std::memory_order_relaxed);
}
```
很简单没什么好聊的。

#### 减少引用计数
减少引用计数，我们就必须要小心。因为这个控制着对象什么时候删除。以及存在的逻辑。

由于定义中sp能够使用对象，那么意味着，sp的强引用指针计数将会控制对象引用的声明周期。

注意到没有，在这个过程中，我们除了有对象的引用对象之外，还存在着一个用来统计强弱引用计数的weakref_type。这个对象也必须销毁。既然sp管理了愿对象，那么wp的引用计数就管理控制统计强弱引用计数的weakref_type声明周期。

因此，我们在减少的强引用计数的时候，要注意顺序。必须先减少强引用计数，再减少弱引用顺序。

##### 减少强引用指针的计数
```cpp
void RefBase::decStrong(const void *id) const {
    weakref_impl* const  refs = mRefs;
    const int32_t c = refs->mStrong.fetch_sub(1,std::memory_order_release);

    if(c == 1){
        std::atomic_thread_fence(std::memory_order_acquire);
        refs->mBase->onLastStrongRef(id);
        int32_t flags = refs->mFlags.load(std::memory_order_relaxed);
        if((flags&OBJECT_LIFETIME_WEAK) == OBJECT_LIFETIME_STRONG){
            delete this;
        }
    }

    refs->decWeak(id);
}
```
能看到的是，此时减少一次强引用次数，当达到1了之后，说明不会再使用，就delete掉。当然源码里面还有一个flags字段，这个字段使用扩展sp和wp的生命周期的行为。默认就是OBJECT_LIFETIME_STRONG。

##### 减少弱引用计数
```cpp
void RefBase::weakref_type::decWeak(const void *id) {
    weakref_impl* const impl = static_cast<weakref_impl*>(this);

    const int32_t c = impl->mWeak.fetch_sub(1,std::memory_order_release);


    if(c != 1){
        return;
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    int32_t flags = impl->mFlags.load(std::memory_order_release);

    if((flags&OBJECT_LIFETIME_MASK) == OBJECT_LIFETIME_STRONG){
        if(impl->mStrong.load(std::memory_order_release)
        == INITIAL_STRONG_VALUE){
            //说明强引用指针只是初始化
        } else{
            //删除引用计数对象
            delete impl;
        }
    } else{
        impl->mBase->onLastWeakRef(id);
        delete impl->mBase;
    }

}
```

### 智能指针其他细节
当我们第一次升级sp的时候调用了一个特殊的引用次数增加的方法。
```cpp
bool RefBase::weakref_type::attemptIncStrong(const void *id) {
    incWeak(id);

    weakref_impl*const impl = static_cast<weakref_impl*>(this);

    int32_t curCount = impl->mStrong.load(std::memory_order_relaxed);

    //这种情况是有本已经有数据引用
    while(curCount >0 &&curCount != INITIAL_STRONG_VALUE){
        //发现和原来相比大于1则退出循环
        if(impl->mStrong.compare_exchange_weak(curCount,curCount+1,
                std::memory_order_relaxed)){
            break;
        }
    }

    //这种情况是初始化，或者已经被释放了
    if(curCount<=0 || curCount == INITIAL_STRONG_VALUE){
        int32_t flags = impl->mFlags.
                load(std::memory_order_relaxed);

        if((flags&OBJECT_LIFETIME_MASK) == OBJECT_LIFETIME_STRONG){
            //原来的强引用被释放
            if(curCount <= 0){
                decWeak(id);
                return false;
            }

            //初始化
            while (curCount > 0){
                if(impl->mStrong.compare_exchange_weak(curCount,
                        curCount+1,std::memory_order_relaxed)){
                    break;
                }
            }


            //promote 升级失败
            //避免某些线程，又把当前的sp释放掉
            if(curCount <= 0){
                decWeak(id);
                return false;
            }

        } else{
            //会判断当前是否是需要FIRST_INC_STRONG
            if(!impl->mBase->onIncStrongAttempted(FIRST_INC_STRONG,id)){
                decWeak(id);
                return false;
            }

            curCount = impl->mStrong.load(std::memory_order_relaxed);

            //如果已经初始化过了引用计数，则调用onLastStrongRef
            if(curCount != 0&&curCount!=INITIAL_STRONG_VALUE){
                impl->mBase->onLastStrongRef(id);
            }
        }
    }

    //如果在添加之前是INITIAL_STRONG_VALUE，说明是初始化，
    // 需要减掉INITIAL_STRONG_VALUE，才是真正的计数
    if(curCount == INITIAL_STRONG_VALUE){
        impl->mStrong.fetch_sub(INITIAL_STRONG_VALUE,std::memory_order_relaxed);
    }

    return true;
}
```

而每一次调用createWeak的方法只会增加一次计数
```cpp
RefBase::weakref_type *RefBase::createWeak(const void *id) const {
    mRefs->incWeak(id);
    return mRefs;
}
```
测试一下：
```cpp
class Test:public RefBase{
private:
    void onFirstRef(){
        LOGE("first");
    }
public:
    void print(){
        LOGE("PRINT");
    }

    void incStrongPointer(){
        incStrong(this);
    }

    int printSCount(){
        return getStrongCount(this);
    }
};



void testPointer(){
    sp<Test> s(new Test());
  
}
```
![智能指针测试.png](/images/智能指针测试.png)
确实是正确的流程。



那么，我们试试，更加复杂的作用域操作。
```cpp
void testPointer(){
    sp<Test> s;
    {
        s = new Test();
        s->print();
        LOGE("1 times:%d",s->printSCount());
        s->incStrongPointer();
        LOGE("2 times:%d",s->printSCount());
    }


    LOGE("3 times:%d",s->printSCount());
}
```
当我们在一个作用域内声明了一个Test的对象。按照道理会在这个作用域结束的时候析构。我们看看其能不能通过增加引用计数，来延长生命周期。
```cpp
void testPointer(){
    sp<Test> s1;
    {
        sp<Test> s;
        s = new Test();
        s->print();
        LOGE("1 times:%d",s->printSCount());
        //s->incStrongPointer();
        s1 = s;
        if(s){
            LOGE("2 times:%d",s1->printSCount());
        }
    }

    if(s1){
        LOGE("3 times:%d",s1->printSCount());
    }

}
```
对于s1来说作用域是整个方法，而对于s来说作用域就是在方法的打括号内。理论上，=的操作符会增加一次新的强引用指针，减少一次旧的引用指针，也就如下图。
![智能指针计数测试.png](/images/智能指针计数测试.png)



### 总结

绘制一个UML图。
![智能指针UML.png](/images/智能指针UML.png)

我们能够从UML中清晰的看到各自的职责。
weakref_type控制弱引用的计数方法，同时通过弱引用计数控制weakref_type的生命周期。

所以这就是为什么在上述的代码中，并没有直接在weakref声明一个方法，而是通过参数来设置。

其次在继承了RefBase的Object本身具备了增加减少强引用的方法。因为此时想要操作Object的时候已经默认是强引用指针引用状态。同时持有这weakref_impl去访问引用计数。

wp和sp都是持有一个引用原有Object的引用。管理操作符，构造函数，拷贝构造函数，操作符，来对传进来的Object控制其引用计数。

实际上，看到这个UML图，就感觉很简单了。

特别提一句，看到上面的用法之后，sp和wp是怎么限制其他人使用内部的指针的。

可以关注到sp，重写下面这个操作符。
```cpp
inline T& operator*() const {
        return *m_ptr;
    };

    inline T* operator -> ()const{
        return m_ptr;
    }
```

而wp没有重写这个操作符。因此sp才能操作得了sp持有的对象。

附上完整的代码的地址：
[https://github.com/yjy239/SmartTool](https://github.com/yjy239/SmartTool)

