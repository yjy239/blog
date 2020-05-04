---
title: RxJava 源码浅析
top: false
cover: false
date: 2019-03-14 17:42:25
img:
tag:
description:
author: yjy239
summary:
categories: Android 常用第三方库
tags:
- Android
- Android 常用第三方库
---
https://www.jianshu.com/p/9e3a0bc5680a 如果遇到问题请到这里讨论
# 背景
本来想写底层Binder的原理，但是涉及的范围有点广，正在写binder底层涉及到的红黑树算法解析。与此同时，公司需要升级rxjava到rxjava2了。还记得，我在进入到这家公司的时候，使用了rxjava的设计漏洞，设计了一套可以重复响应的响应式，用来协助公司的网络请求自动重试处理，因此随着升级，我也要阅读源码，做一次升级（毕竟是两年前读过的）。最近有个哥们，问我能不能写一篇关于rxjava2的源码解析。于是想了想，既然工作开始同步展开了，那么就来写一篇Rxjava2的源码文章吧。

实际上rxjava的源码不难，只能说把链式调用和装饰设计模式使用到了极致。只要弄懂每个状态之间的来回切换，实际上阅读源码没什么难度。

这个文章将会探讨rxjava中每个状态流变化，以及线程切换原理。

# 正文

老规矩，我们来看看rxjava2是怎么使用的。
```
Observable.create(new ObservableOnSubscribe<Integer>() {
                    @Override
                    public void subscribe(ObservableEmitter<Integer> e) throws Exception {
                        int i = 0;
                        while (i < 10) {
                            i++;
                            e.onNext(i);
                        }
                    }
                })
                .observeOn(Schedulers.io())
                .subscribeOn(Schedulers.newThread())
                .subscribe(new Consumer<Integer>() {
                    @Override
                    public void accept(Integer integer) throws Exception {
                        Log.e("value",integer+"");
                    }
                });
```

这是rxjava2到rxjava1最为基础的用法。

实际上整个Rxjava的核心设计理念，就是一个可控制时机的观察者模式。而在上述代码中，是一个即时的观察者设计模式。

这里我先挑出在整个Rxjava中，抛弃操作符，需要完成整个响应式流程中属于极其重要的三个角色。

- 1. Observable
rxjava被观察对象。从上面的demo代码看，对于rxjava来说就是通过Observable.create的方式创建在内部的ObservableOnSubscribe方法，也就是我们俗称的上流。rxjava会对这个对象进行注册观察，一旦这个对象里面发生了变化，并且通过onnext等方法告诉观察者（Observer）。


- 2. Observer
rxjava观察对象。从上面的代码来讲，subscribe包装在内部的就是Observer。观察者。这个部分一般是用来观察上流中的变化，一旦Observable（被观察者）发生了变化，下面Observer（观察者）同时也会发生变化。

- 3. Schedulers
rxjava工作区 可以想像成上流在哪个区域中流动，下流又在哪里流动，一般是由observeOn() 和subscribeOn()两个方法，分别控制Observer（下流/观察者）的工作线程以及Observable（上流/被观察者）的工作线程。

这么说起来好像还是很抽象。说说我是怎么理解的。我每一次写rxjava的时候，我就当作是在地图上创造一条河流。
- 1. 先设定好Observable河流从哪里，流出来的。
- 2. 设定好各种操作符以及Schedulers，来决定这个河流究竟怎么流动，在哪里流动，是九曲十八弯，还是经过工厂污染加工呢（哈哈）。
- 3. 设定好Observer，决定河流流入哪个逻辑大海。这个大海中里面有我们需要的处理的最终逻辑。得到的水一定是从源头出来，经过操作符操作变化后得来的。

## 源码解析

### Rxjava的在链式调用中类型的转化

那么我们进入到源码解析环节。

首先我们先理清楚，这些类之间的包含关系，以及rxjava怎么流动的。只有弄清这些流程关系，rxjava几乎就解析完成。

我们来看看Rxjava创造河流源头的第一步，Observable.create究竟做了什么工作。

### Observable

#### Observable.create
```
public static <T> Observable<T> create(ObservableOnSubscribe<T> source) {
        ObjectHelper.requireNonNull(source, "source is null");
        return RxJavaPlugins.onAssembly(new ObservableCreate<T>(source));
    }
```
RxJavaPlugins这个类很简单，一般用来辅助检查这个传进来的接口是否非法，为空之类的辅助。onAssembly方法直接返回穿进去的对象。

记住此时从**Observable** 穿进去转化为 **ObservableCreate**类。通过链式调用返回。

明白此时的源头是什么，我们继续看看这个从源头的河流出来之后，后面经历了什么事情。

#### observeOn
我们继续看看下一步链式调用.observeOn(Schedulers.newThread())又转化为什么类。
```
 @CheckReturnValue
    @SchedulerSupport(SchedulerSupport.CUSTOM)
    public final Observable<T> observeOn(Scheduler scheduler) {
        return observeOn(scheduler, false, bufferSize());
    }

@CheckReturnValue
    @SchedulerSupport(SchedulerSupport.CUSTOM)
    public final Observable<T> observeOn(Scheduler scheduler, boolean delayError, int bufferSize) {
        ObjectHelper.requireNonNull(scheduler, "scheduler is null");
        ObjectHelper.verifyPositive(bufferSize, "bufferSize");
        return RxJavaPlugins.onAssembly(new ObservableObserveOn<T>(this, scheduler, delayError, bufferSize));
    }
```

请注意，此时 **ObservableCreate** 作为参数被包装起来，转化为**ObservableObserveOn**。

#### subscribeOn
```
    @CheckReturnValue
    @SchedulerSupport(SchedulerSupport.CUSTOM)
    public final Observable<T> subscribeOn(Scheduler scheduler) {
        ObjectHelper.requireNonNull(scheduler, "scheduler is null");
        return RxJavaPlugins.onAssembly(new ObservableSubscribeOn<T>(this, scheduler));
    }
```
注意，此时**ObservableObserveOn**作为参数包装进去，转化为**ObservableSubscribeOn**类。

#### subscribe
```
    @CheckReturnValue
    @SchedulerSupport(SchedulerSupport.NONE)
    public final Disposable subscribe(Consumer<? super T> onNext) {
        return subscribe(onNext, Functions.ON_ERROR_MISSING, Functions.EMPTY_ACTION, Functions.emptyConsumer());
    }
```

这个函数相当于观察者设计模式中的常用的notify唤起方法。我们继续向后看看

```
@CheckReturnValue
    @SchedulerSupport(SchedulerSupport.NONE)
    public final Disposable subscribe(Consumer<? super T> onNext, Consumer<? super Throwable> onError,
            Action onComplete, Consumer<? super Disposable> onSubscribe) {
        ObjectHelper.requireNonNull(onNext, "onNext is null");
        ObjectHelper.requireNonNull(onError, "onError is null");
        ObjectHelper.requireNonNull(onComplete, "onComplete is null");
        ObjectHelper.requireNonNull(onSubscribe, "onSubscribe is null");

        LambdaObserver<T> ls = new LambdaObserver<T>(onNext, onError, onComplete, onSubscribe);

        subscribe(ls);

        return ls;
    }
```

此时判断每个状态，onNext，onError，onComplete，onSubscribe这几个接口对应的函数是否为空之后。把上面**ObservableSubscribeOn**基础，把最下层的流**LambdaObserver**传进去，等待最后的调用。

只对着这几个函数，很简单不是吗？这里画一个思维导图。
![rxjava中链式调用流的变化.png](/images/rxjava中链式调用流的变化.png)

还不够，每个类之间都是一层层包装关系。

![rxjava类之间包含关系.png](/images/rxjava类之间包含关系.png)


仅仅这样还不够看透rxjava的设计。我们看看这几个类uml图

![Observable UML关系.png](/images/Observable UML关系.png)


![Observer.png](/images/Observer.png)

看到了这些这几个UML图是不是立即对Rxjava开始有点明白了。

那么让我们看看subscribe这个启动整个rxjava流动的方法。

#### Rxjava每个流程的解析。
让我们回到Observable
```
@SchedulerSupport(SchedulerSupport.NONE)
    @Override
    public final void subscribe(Observer<? super T> observer) {
        ObjectHelper.requireNonNull(observer, "observer is null");
        try {
            observer = RxJavaPlugins.onSubscribe(this, observer);

            ObjectHelper.requireNonNull(observer, "The RxJavaPlugins.onSubscribe hook returned a null Observer. Please change the handler provided to RxJavaPlugins.setOnObservableSubscribe for invalid null returns. Further reading: https://github.com/ReactiveX/RxJava/wiki/Plugins");

            subscribeActual(observer);
        } catch (NullPointerException e) { // NOPMD
            throw e;
        } catch (Throwable e) {
            Exceptions.throwIfFatal(e);
            // can't call onError because no way to know if a Disposable has been set or not
            // can't call onSubscribe because the call might have set a Subscription already
            RxJavaPlugins.onError(e);

            NullPointerException npe = new NullPointerException("Actually not, but can't throw other exceptions due to RS");
            npe.initCause(e);
            throw npe;
        }
    }
```

这里的流程，我们经过RxJavaPlugins校验之后，通过调用用subscribeActual这个抽象方法，把LambdaObserver作为参数穿进去。

根据上面的UML图，此时Observable是ObservableSubscribeOn，所以此时第一个调用的ObservableSubscribeOn的subscribeActual。

#### Rxjava线程切换原理

##### ObservableSubscribeOn
```
    @Override
    public void subscribeActual(final Observer<? super T> observer) {
        final SubscribeOnObserver<T> parent = new SubscribeOnObserver<T>(observer);

        observer.onSubscribe(parent);

        parent.setDisposable(scheduler.scheduleDirect(new SubscribeTask(parent)));
    }
```
首先，我们可以清楚，Rxjava中Observer第一个执行必定是onSubscribe回调，而且必定是当前线程。同时把最外层的Disposable（也是Observable）传进去做预备处理。

接着调用setDisposable，通过自旋锁，在多线程线程情况下，保证每一次回调之后只使用一次。

同时在scheduleDirect，通过Scheduler包裹Observer进SubscribeTask（实现了runnable），给工作线程。

##### Scheduler
```
    @NonNull
    public Disposable scheduleDirect(@NonNull Runnable run, long delay, @NonNull TimeUnit unit) {
        final Worker w = createWorker();

        final Runnable decoratedRun = RxJavaPlugins.onSchedule(run);

        DisposeTask task = new DisposeTask(decoratedRun, w);

        w.schedule(task, delay, unit);

        return task;
    }
```

根据上面的demo代码，还记得此时传进来的是Schedulers.newThread()吗。我们看看这个此时在Scheduler中声明的静态代码区域定义了5大基本的工作线程：
```
    static {
        SINGLE = RxJavaPlugins.initSingleScheduler(new SingleTask());

        COMPUTATION = RxJavaPlugins.initComputationScheduler(new ComputationTask());

        IO = RxJavaPlugins.initIoScheduler(new IOTask());

        TRAMPOLINE = TrampolineScheduler.instance();

        NEW_THREAD = RxJavaPlugins.initNewThreadScheduler(new NewThreadTask());
    }
```
所以此时Scheduler对应的是NewThreadScheduler。我们看看这个对应的createWorker方法。
```
@NonNull
    @Override
    public Worker createWorker() {
        return new NewThreadWorker(threadFactory);
    }
```
##### NewThreadWorker
```
 @NonNull
    @Override
    public Disposable schedule(@NonNull final Runnable action, long delayTime, @NonNull TimeUnit unit) {
        if (disposed) {
            return EmptyDisposable.INSTANCE;
        }
        return scheduleActual(action, delayTime, unit, null);
    }
```
根据上文此时ScheduledDirectTask这个runnable把DisposeTask这个runnable包裹起来，而DisposeTask又把上层的SubscribeTask这个runnable包裹起来，传进NewThreadWorker中，进入scheduleActual。
```
public Disposable scheduleDirect(final Runnable run, long delayTime, TimeUnit unit) {
        ScheduledDirectTask task = new ScheduledDirectTask(RxJavaPlugins.onSchedule(run));
        try {
            Future<?> f;
            if (delayTime <= 0L) {
                f = executor.submit(task);
            } else {
                f = executor.schedule(task, delayTime, unit);
            }
            task.setFuture(f);
            return task;
        } catch (RejectedExecutionException ex) {
            RxJavaPlugins.onError(ex);
            return EmptyDisposable.INSTANCE;
        }
    }
```

这里还记得我去年写过的线程解析的文章吗？这里使用就是future模式。判断延时事件通过ScheduledThreadPoolExecutor（核心线程数只有1）的线程池启动线程，并且异步的等待线程的触发获取结果。

既然执行了线程，我们看看包裹在最外层的ScheduledDirectTask runnable方法。

由于此时使用的是future模式，runnable必定回调用call方法。

##### ScheduledDirectTask
```
@Override
    public Void call() throws Exception {
        runner = Thread.currentThread();
        try {
            runnable.run();
        } finally {
            lazySet(FINISHED);
            runner = null;
        }
        return null;
    }
```

此时继续向上走DisposeTask的run方法
##### DisposeTask.run()
```
@Override
        public void run() {
            runner = Thread.currentThread();
            try {
                decoratedRun.run();
            } finally {
                dispose();
                runner = null;
            }
        }
```
##### SubscribeTask
```
    final class SubscribeTask implements Runnable {
        private final SubscribeOnObserver<T> parent;

        SubscribeTask(SubscribeOnObserver<T> parent) {
            this.parent = parent;
        }

        @Override
        public void run() {
            source.subscribe(parent);
        }
    }
```

此时source就是包裹在上层的Observable，那么根据上面的图，更上层的就是ObservableObserveOn.

#### ObservableObserveOn
此时这个方法还是会调用subscribeActual(observer);那么我们ObservableObserveOn的方法。
```
    @Override
    protected void subscribeActual(Observer<? super T> observer) {
        if (scheduler instanceof TrampolineScheduler) {
            source.subscribe(observer);
        } else {
            Scheduler.Worker w = scheduler.createWorker();

            source.subscribe(new ObserveOnObserver<T>(observer, w, delayError, bufferSize));
        }
    }
```
此时的情况和上面类似。此时传进来的Schedulers.io()。记住此时的线程是newThread。此时把observer相关的东西进行包裹进ObserveOnObserver。执行更加上层的Observable。

此时更加上层的Observable就是我们最初，最上流的ObservableCreate。

#### ObservableCreate
```
    @Override
    protected void subscribeActual(Observer<? super T> observer) {
        CreateEmitter<T> parent = new CreateEmitter<T>(observer);
        observer.onSubscribe(parent);

        try {
            source.subscribe(parent);
        } catch (Throwable ex) {
            Exceptions.throwIfFatal(ex);
            parent.onError(ex);
        }
    }
```

此时observer就是上层刚刚包裹的ObserveOnObserver。我们看看它的onSubscribe方法。

```
@Override
        public void onSubscribe(Disposable d) {
            if (DisposableHelper.validate(this.upstream, d)) {
                this.upstream = d;
                if (d instanceof QueueDisposable) {
                    @SuppressWarnings("unchecked")
                    QueueDisposable<T> qd = (QueueDisposable<T>) d;

                    int m = qd.requestFusion(QueueDisposable.ANY | QueueDisposable.BOUNDARY);

                    if (m == QueueDisposable.SYNC) {
                        sourceMode = m;
                        queue = qd;
                        done = true;
                        downstream.onSubscribe(this);
                        schedule();
                        return;
                    }
                    if (m == QueueDisposable.ASYNC) {
                        sourceMode = m;
                        queue = qd;
                        downstream.onSubscribe(this);
                        return;
                    }
                }

                queue = new SpscLinkedArrayQueue<T>(bufferSize);
                downstream.onSubscribe(this);
            }
        }
```

此时声明一个单对单的消费者-生产者的线程模式的链表。此时downstream就是我们最上层的LambdaObserver。

#### LambdaObserver
```
    @Override
    public void onSubscribe(Disposable d) {
        if (DisposableHelper.setOnce(this, d)) {
            try {
                onSubscribe.accept(this);
            } catch (Throwable ex) {
                Exceptions.throwIfFatal(ex);
                d.dispose();
                onError(ex);
            }
        }
    }
```

此时将会调用Consumer对应的onSubscribe的accept，在上面的demo没有表示。此时就来到了上流的执行者，而且所处于的线程还是NewThread工作区。这就是为什么我说subscribeOn，控制的是上流者的工作区间。

我们继续看ObservableCreate的source.subscribe(parent)方法。此时终于来到了Observer中的方法了，也就是对应ObservableOnSubscribe这一块。


嗯？那么一定有人问，那RxJava的切换线程特性去哪里了？

之前不是说了创建了一个SpscLinkedArrayQueue一个单对单的消费生产者的链表吗？如果看过我之前文章的哥们就能明白。这个线程设计模式就是用来协调当两个线程生产数据和接收数据。

#### CreateEmitter
```
@Override
        public void onNext(T t) {
            if (t == null) {
                onError(new NullPointerException("onNext called with null. Null values are generally not allowed in 2.x operators and sources."));
                return;
            }
            if (!isDisposed()) {
                observer.onNext(t);
            }
        }

```
此时我们在上流调用的onNext就是调用这个类对应的方法。

我们直接看看ObserveOnObserver.onNext方法。
#### ObserveOnObserver
```
        @Override
        public void onNext(T t) {
            if (done) {
                return;
            }

            if (sourceMode != QueueDisposable.ASYNC) {
                queue.offer(t);
            }
            schedule();
        }

        void schedule() {
            if (getAndIncrement() == 0) {
                worker.schedule(this);
            }
        }
```

rxjava每一次发送一个信号通知最底层的Observable都需要调用一次onNext,onError,onComplete方法。我们看到onNext的时候会从消费队列取出最顶上的数据。并且把这个类传入worker的schedule中。就是在这个方法，完成了线程的切换。

此时的worker是IO线程。是EventLoopWorker的worker。嗯？为什么不叫IOWorker呢？实际上，有人思考过Rxjava中IOThread和newThread的区别吗？大家都是开启新的线程，为什么这个IOThread能单独做出来？比起一般的Thread有什么优势呢？

实际上，如果看过我的线程设计模式那一片文章就能明白，实际上就是一个读写锁线程设计模式运用。除开被线程池控制外，为了避免多个线程往同一个文件做写操作，里面做了一个ConcurrentLinkedQueue等待队列。

因此，为了性能考虑，我们还真的在除了在写操作之外，尽量避免使用这个模式。

言归正传。

接下来的行为十分相似又是开启一个线程(此时线程是IO线程，终于切换过来了)，启动run方法。
```
@Override
        public void run() {
            if (outputFused) {
                drainFused();
            } else {
                drainNormal();
            }
        }
```

我们考虑当前情况下，走的是下面的分支drainNormal。

```
void drainNormal() {
            int missed = 1;

            final SimpleQueue<T> q = queue;
            final Observer<? super T> a = downstream;

            for (;;) {
                if (checkTerminated(done, q.isEmpty(), a)) {
                    return;
                }

                for (;;) {
//线程等待处理
...

                    a.onNext(v);
                }

                missed = addAndGet(-missed);
                if (missed == 0) {
                    break;
                }
            }
        }
```

这个时候ObserveOnObserver中的a就是我们最下流的onNext方法。

这样，rxJava就完成了线程切换的动作。以及rxJava的流程解析完毕。很简单吧，就是嵌套的类多了点，让人感到混乱。只要明白其中的核心设计，以及熟悉装饰设计模式，这一切都引刃而解。

## 总结
不清楚背压Flowable的哥们，可以看看下面这一篇：
https://www.jianshu.com/p/ff8167c1d191

写的挺好的。Flowable的解析我就不写了，Flowable也是跟着我解析思路就好。rxjava只要清楚思路，还是一个思路清晰，十分方便的库。对了，跟着我看了一遍源码，rxjava如果你想要复用下面Observable代码块，你会发现在rxjava2会报错，rxjava1没效果。你们思路是什么呢？实际上十分简单。这里就不详细说了。说穿了一句话，看源码只是为自己写代码的时候提供更好的思路，让自己成长起来。























