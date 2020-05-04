---
title: kotlin 协程源码浅析
top: false
cover: false
date: 2018-04-22 22:17:58
img:
tag:
description:
author: yjy239
summary:
categories: kotlin
tags:
- Android
- kotlin
---
### 前言

kotlin 现在都比较新鲜的一个语言。问过了身边的朋友，有的似乎开始用其开始写后台，有的开始用kotlin重构Android工程代码。甚至有朋友说，kotlin的协程在腾讯面试Android的时候被面了。如今深深的感觉到了，kotlin已经悄然声息的走进了我们的开发生活中。相信不久的将来一定有不少基于kotlin的优秀的第三方库。本人也只是刚刚学习kotlin，学习到了协程决定尝试着分析它的源码。兑现我之前写的多线程设计模式那一篇所说的，把kotlin的源码翻出来，让我们来聊聊kotlin的协程吧。但是事先声明，这个源码是基于kotlin1.1，官方都说了是实验作品，说明以后可能会大变。

### 正文

老规矩，我们先学会如何使用kotlin的协程序。
```
val result = async(CommonPool) {
            work()
        }

        launch {
            log("result is ${result.await()}")
        }

```

```
//这是log方法
fun log(msg:String):Unit{
        Log.e(TAG,"[${Thread.currentThread().name}] $msg")
    }

//这是work方法
   suspend fun work():String{
        delay(3000L)   //模拟一个耗时任务
        return "job"
    }
```
这就是kotlin中，协程最基础的用法。很简单，比起我们在java中编写多线程的时候简单多了。

具体是什么意思呢？为了以后的阅读这边稍微说一下，async括号里面是是一个单例模式的线程池，说明的是括号里面的程序将要在这个线程里面运行。而async这个扩展函数将会启动线程，并且返回一个Deferred对象。

在launch中也会启动一个线程池子，在这个线程里面我们就会等待async返回出job并且打印出来。

究竟对不对，我们看看源码就知道了。顺道一体，这一篇文章要解决async中究竟是不是我之前说那样运用了Future模式。以及launch和async区别。


前提提要，这里我就不多讨论lamda表达式，并不是今天的重点。我们要了解其中的思想。

#### async 参数和构建器解析

老规矩上源码：
```
public fun <T> async(
    context: CoroutineContext = DefaultDispatcher,
    start: CoroutineStart = CoroutineStart.DEFAULT,
    block: suspend CoroutineScope.() -> T
): Deferred<T> {
    val newContext = newCoroutineContext(context)
    val coroutine = if (start.isLazy)
        LazyDeferredCoroutine(newContext, block) else
        DeferredCoroutine<T>(newContext, active = true)
    coroutine.initParentJob(context[Job])
    start(block, coroutine, coroutine)
    return coroutine
}
```

方法里面设定了默认的几个参数context  类型是CoroutineContext，start 
 类型是CoroutineStart，以及用过类型安全的构建器把block中的内容往下穿。

我们先看看这个DefaultDispatcher究竟是什么。

```
public val DefaultDispatcher: CoroutineDispatcher = CommonPool
```

我们一直这是一个CommonPool也就是说就算我们不声明CommonPool，也会默认为CommonPool。我们再看看CommonPool是啥东西

```
object CommonPool : CoroutineDispatcher() {
    private var usePrivatePool = false

    @Volatile
    private var _pool: Executor? = null

    private inline fun <T> Try(block: () -> T) = try { block() } catch (e: Throwable) { null }

    private fun createPool(): ExecutorService {
        val fjpClass = Try { Class.forName("java.util.concurrent.ForkJoinPool") }
            ?: return createPlainPool()
        if (!usePrivatePool) {
            Try { fjpClass.getMethod("commonPool")?.invoke(null) as? ExecutorService }
                ?.let { return it }
        }
        Try { fjpClass.getConstructor(Int::class.java).newInstance(defaultParallelism()) as? ExecutorService }
            ?. let { return it }
        return createPlainPool()
    }

    private fun createPlainPool(): ExecutorService {
        val threadId = AtomicInteger()
        return Executors.newFixedThreadPool(defaultParallelism()) {
            Thread(it, "CommonPool-worker-${threadId.incrementAndGet()}").apply { isDaemon = true }
        }
    }

    private fun defaultParallelism() = (Runtime.getRuntime().availableProcessors() - 1).coerceAtLeast(1)

    @Synchronized
    private fun getOrCreatePoolSync(): Executor =
        _pool ?: createPool().also { _pool = it }

    override fun dispatch(context: CoroutineContext, block: Runnable) =
        try { (_pool ?: getOrCreatePoolSync()).execute(timeSource.trackTask(block)) }
        catch (e: RejectedExecutionException) {
            timeSource.unTrackTask()
            DefaultExecutor.execute(block)
        }

    // used for tests
    @Synchronized
    internal fun usePrivatePool() {
        shutdown(0)
        usePrivatePool = true
        _pool = null
    }

    // used for tests
    @Synchronized
    internal fun shutdown(timeout: Long) {
        (_pool as? ExecutorService)?.apply {
            shutdown()
            if (timeout > 0)
                awaitTermination(timeout, TimeUnit.MILLISECONDS)
            shutdownNow().forEach { DefaultExecutor.execute(it) }
        }
        _pool = Executor { throw RejectedExecutionException("CommonPool was shutdown") }
    }

    // used for tests
    @Synchronized
    internal fun restore() {
        shutdown(0)
        usePrivatePool = false
        _pool = null
    }

    override fun toString(): String = "CommonPool"
}
```
提一下，CommonPool是一个标志了object的类，这个在kotlin的意思是编译的时候只会产生唯一一个对象，也就是我们java所说的单例模式。

从这里我们可以看到很关键的东西，createPool的方法返回了一个ExecutorService这个类，我们在java中多线程编程也有一个ExecutorService这个类。我们点击去看看
```
package java.util.concurrent;
```
确实是我们的java中的ExecutorService。我们接下来可以做出以下合理的推测，kotlin中的协程是不是也是调用了我们java中thread来完成的。

```
    private fun createPlainPool(): ExecutorService {
        val threadId = AtomicInteger()
        return Executors.newFixedThreadPool(defaultParallelism()) {
            Thread(it, "CommonPool-worker-${threadId.incrementAndGet()}").apply { isDaemon = true }
        }
    }
```
我们的这个创建池子调用createPlainPool的方法。也是和我们Java中使用Executors线程池一样的用法。

那么我们的推测是对的，可以下这么一个结论，kotlin的协程实际上就是我们的java的线程，更加准确的说是线程池。


我们再看看第二个参数start，类型是CoroutineStart

```
public enum class CoroutineStart {
    /**
     * Default -- immediately schedules coroutine for execution according to its context.
     *
     * If the [CoroutineDispatcher] of the coroutine context returns `true` from [CoroutineDispatcher.isDispatchNeeded]
     * function as most dispatchers do, then the coroutine code is dispatched for execution later, while the code that
     * invoked the coroutine builder continues execution.
     *
     * Note, that [Unconfined] dispatcher always returns `false` from its [CoroutineDispatcher.isDispatchNeeded]
     * function, so starting coroutine with [Unconfined] dispatcher by [DEFAULT] is the same as using [UNDISPATCHED].
     *
     * If coroutine [Job] is cancelled before it even had a chance to start executing, then it will not start its
     * execution at all, but complete with an exception.
     *
     * Cancellability of coroutine at suspension points depends on the particular implementation details of
     * suspending functions. Use [suspendCancellableCoroutine] to implement cancellable suspending functions.
     */
    DEFAULT,

    /**
     * Starts coroutine lazily, only when it is needed.
     *
     * See the documentation for the corresponding coroutine builders for details:
     * [launch], [async], and [actor][kotlinx.coroutines.experimental.channels.actor].
     *
     * If coroutine [Job] is cancelled before it even had a chance to start executing, then it will not start its
     * execution at all, but complete with an exception.
     */
    LAZY,

    /**
     * Atomically (non-cancellably) schedules coroutine for execution according to its context.
     * This is similar to [DEFAULT], but the coroutine cannot be cancelled before it starts executing.
     *
     * Cancellability of coroutine at suspension points depends on the particular implementation details of
     * suspending functions as in [DEFAULT].
     */
    ATOMIC,

    /**
     * Immediately executes coroutine until its first suspension point _in the current thread_ as if it the
     * coroutine was started using [Unconfined] dispatcher. However, when coroutine is resumed from suspension
     * it is dispatched according to the [CoroutineDispatcher] in its context.
     *
     * This is similar to [ATOMIC] in the sense that coroutine starts executing even if it was already cancelled,
     * but the difference is that it start executing in the same thread.
     *
     * Cancellability of coroutine at suspension points depends on the particular implementation details of
     * suspending functions as in [DEFAULT].
     */
    UNDISPATCHED;

    /**
     * Starts the corresponding block as a coroutine with this coroutine start strategy.
     *
     * * [DEFAULT] uses [startCoroutineCancellable].
     * * [ATOMIC] uses [startCoroutine].
     * * [UNDISPATCHED] uses [startCoroutineUndispatched].
     * * [LAZY] does nothing.
     */
    public operator fun <T> invoke(block: suspend () -> T, completion: Continuation<T>) =
        when (this) {
            CoroutineStart.DEFAULT -> block.startCoroutineCancellable(completion)
            CoroutineStart.ATOMIC -> block.startCoroutine(completion)
            CoroutineStart.UNDISPATCHED -> block.startCoroutineUndispatched(completion)
            CoroutineStart.LAZY -> Unit // will start lazily
        }

    /**
     * Starts the corresponding block with receiver as a coroutine with this coroutine start strategy.
     *
     * * [DEFAULT] uses [startCoroutineCancellable].
     * * [ATOMIC] uses [startCoroutine].
     * * [UNDISPATCHED] uses [startCoroutineUndispatched].
     * * [LAZY] does nothing.
     */
    public operator fun <R, T> invoke(block: suspend R.() -> T, receiver: R, completion: Continuation<T>) =
        when (this) {
            CoroutineStart.DEFAULT -> block.startCoroutineCancellable(receiver, completion)
            CoroutineStart.ATOMIC -> block.startCoroutine(receiver, completion)
            CoroutineStart.UNDISPATCHED -> block.startCoroutineUndispatched(receiver, completion)
            CoroutineStart.LAZY -> Unit // will start lazily
        }

    /**
     * Returns `true` when [LAZY].
     */
    public val isLazy: Boolean get() = this === LAZY
}
```
我们可以得知，这个类是一个枚举类。默认是DEFAULT，也就是说，返回的isLazy一般情况是false。

#### async 方法流程
有了这个基础，我们继续分析构建器里面的代码。
```
    val newContext = newCoroutineContext(context)
    val coroutine = if (start.isLazy)
        LazyDeferredCoroutine(newContext, block) else
        DeferredCoroutine<T>(newContext, active = true)
    coroutine.initParentJob(context[Job])
    start(block, coroutine, coroutine)
    return coroutine
```
我们查阅newCoroutineContext下面的方法，实际上是为了debug做处理，我们不多讨论，只需要知道在我们默认情况下继续返回了CommonPool。

按照我们刚才分析coroutine 由于判断isLazy是false，这个形参实际上是DeferredCoroutine。

##### initParentJob 线程初始化
接着我们看看initParentJob 初始化了什么东西。由于知道DeferredCoroutine这个类
```
@Suppress("UNCHECKED_CAST")
private open class DeferredCoroutine<T>(
    parentContext: CoroutineContext,
    active: Boolean
) : AbstractCoroutine<T>(parentContext, active), Deferred<T> {
    override fun getCompleted(): T = getCompletedInternal() as T
    suspend override fun await(): T = awaitInternal() as T
    override val onAwait: SelectClause1<T>
        get() = this as SelectClause1<T>
}
```
由于我们可以知道这个类继承了AbstractCoroutine。而这个类也是继承了JobSupport这个类，这个类实际上是扩展了Job这个接口。注意这个地方就是重点，是用来标记这个线程任务的状态。

我们看看initParent是怎么回事
```
    public fun initParentJob(parent: Job?) {
        check(parentHandle == null)
        if (parent == null) {
            parentHandle = NonDisposableHandle
            return
        }
        parent.start() // make sure the parent is started
        val handle = parent.attachChild(this)
        parentHandle = handle
        // now check our state _after_ registering (see updateState order of actions)
        if (isCompleted) handle.dispose()
    }
```
由于传进来的parent实际上是DeferredCoroutine，我们其实也是调用JobSupport中start，attachChild方法。我们一一看看
```
    public final override fun start(): Boolean {
        loopOnState { state ->
            when (startInternal(state)) {
                FALSE -> return false
                TRUE -> return true
            }
        }
    }
```
在这个loopOnState是一个循环体
```
    protected inline fun loopOnState(block: (Any?) -> Unit): Nothing {
        while (true) {
            block(state)
        }
    }
```
不断的调用startInternal判断状态
```
    // returns: RETRY/FALSE/TRUE:
    //   FALSE when not new,
    //   TRUE  when started
    //   RETRY when need to retry
    private fun startInternal(state: Any?): Int {
        when (state) {
            is Empty -> { // EMPTY_X state -- no completion handlers
                if (state.isActive) return FALSE // already active
                if (!_state.compareAndSet(state, EmptyActive)) return RETRY
                onStart()
                return TRUE
            }
            is NodeList -> { // LIST -- a list of completion handlers (either new or active)
                return state.tryMakeActive().also { result ->
                    if (result == TRUE) onStart()
                }
            }
            else -> return FALSE // not a new state
        }
    }
```

我们现在有两种状态，Empty 和NodeList。
```
@Suppress("PrivatePropertyName")
private val EmptyNew = Empty(false)
@Suppress("PrivatePropertyName")
private val EmptyActive = Empty(true)
...
private val _state = atomic<Any?>(if (active) EmptyActive else EmptyNew)

private class Empty(override val isActive: Boolean) : JobSupport.Incomplete {
    override val list: JobSupport.NodeList? get() = null
    override fun toString(): String = "Empty{${if (isActive) "Active" else "New" }}"
}
```

这就是证据。我们一般的情况active是false，那么协程的第一个初始是EmptyNew状态。接下来发现是EmptyNew的状态通过CAS转化为EmptyActive状态。

我们继续看看，attachChild绑定方法
```
override fun attachChild(child: Job): DisposableHandle =
        invokeOnCompletion(onCancelling = true, handler = Child(this, child))
```
```
    public final override fun invokeOnCompletion(onCancelling: Boolean, handler: CompletionHandler): DisposableHandle =
        installHandler(handler, onCancelling = onCancelling && hasCancellingState)
```

我们再看看installhandler的方法
```
private fun installHandler(handler: CompletionHandler, onCancelling: Boolean): DisposableHandle {
        var nodeCache: JobNode<*>? = null
        loopOnState { state ->
            when (state) {
                is Empty -> { // EMPTY_X state -- no completion handlers
                    if (state.isActive) {
                        // try move to SINGLE state
                        val node = nodeCache ?: makeNode(handler, onCancelling).also { nodeCache = it }
                        if (_state.compareAndSet(state, node)) return node
                    } else
                        promoteEmptyToNodeList(state) // that way we can add listener for non-active coroutine
                }
                is Incomplete -> {
                    val list = state.list
                    if (list == null) { // SINGLE/SINGLE+
                        promoteSingleToNodeList(state as JobNode<*>)
                    } else {
                        if (state is Finishing && state.cancelled != null && onCancelling) {
                            // installing cancellation handler on job that is being cancelled
                            handler((state as? CompletedExceptionally)?.exception)
                            return NonDisposableHandle
                        }
                        val node = nodeCache ?: makeNode(handler, onCancelling).also { nodeCache = it }
                        if (addLastAtomic(state, list, node)) return node
                    }
                }
                else -> { // is complete
                    handler((state as? CompletedExceptionally)?.exception)
                    return NonDisposableHandle
                }
            }
        }
    }
```
这个方法就是处理整个Job状态的关键函数在这里面处理了一下协程几种状态，一个是Empty，InComplete，complete状态。我们当前是Empty状态，非活跃状态。所以将会调用promoteEmptyToNodeList方法
```
    private fun promoteEmptyToNodeList(state: Empty) {
        // try to promote it to list in new state
        _state.compareAndSet(state, NodeList(state.isActive))
    }
```
又看到了这个方法，是不是很熟悉。就是我上一篇聊过的CAS乐观锁。这个方法是在Empty状态尝试把线程中活跃状态颠倒一下，也就是说，我们现在就是处于通过CAS尝试着把Empty状态的协程状态从非活跃状态转换为活跃状态。同时把state转换为NodeList。

接下来就会在Looper这个循环体走到handler的分支
```
val node = nodeCache ?: makeNode(handler, onCancelling).also { nodeCache = it }
                        if (_state.compareAndSet(state, node)) return node
```
通过可以知道我们将会创建一个新的任务节点并且通过CAS修改state中的node，让里面的node不为空
```
    private fun makeNode(handler: CompletionHandler, onCancelling: Boolean): JobNode<*> =
        if (onCancelling)
            (handler as? JobCancellationNode<*>)?.also { require(it.job === this) }
                ?: InvokeOnCancellation(this, handler)
        else
            (handler as? JobNode<*>)?.also { require(it.job === this && (!hasCancellingState || it !is JobCancellationNode)) }
                ?: InvokeOnCompletion(this, handler)
```
看到这个不要觉得奇怪，also是返回了当前对象，把它当作我们常见的链式调用就好了，最后会返回了InvokeOnCompletion。这个对象是一个JobNode。
```
internal abstract class JobNode<out J : Job>(
    @JvmField val job: J
) : LockFreeLinkedListNode(), DisposableHandle, CompletionHandler, JobSupport.Incomplete {
    final override val isActive: Boolean get() = true
    final override val list: JobSupport.NodeList? get() = null
    final override fun dispose() = (job as JobSupport).removeNode(this)
    override abstract fun invoke(reason: Throwable?)
}
```
这里我们可以发现它刚好扩展了DisposableHandle这个取消任务的接口。所以我们在最后发现
```
if (isCompleted) handle.dispose()
```
这一旦判断这个任务已经完成了，则会移除掉当前的节点。这里稍微提一下LockFreeLinkedListNode这个类。它实际上是一个线程安全的链表，主要是通过CAS完成线程安全的。





#### async 启动线程

接着就走start这个枚举类的构造函数。我们抽出看一下：
```
    public operator fun <T> invoke(block: suspend () -> T, completion: Continuation<T>) =
        when (this) {
            CoroutineStart.DEFAULT -> block.startCoroutineCancellable(completion)
            CoroutineStart.ATOMIC -> block.startCoroutine(completion)
            CoroutineStart.UNDISPATCHED -> block.startCoroutineUndispatched(completion)
            CoroutineStart.LAZY -> Unit // will start lazily
        }
```
这段代码实际上kotlin的特性，这个operator的方法标志，是告诉你，我要重写某种操作符了。而invoke一般是指构造函数。

那么就是说接下来start的方法接下来会走invoke的CoroutineStart.DEFAULT分支。为了提一下可能有0基础的，这个when我们可以看成switch类似的东西。

我们再进去看看。
```
internal fun <T> (suspend () -> T).startCoroutineCancellable(completion: Continuation<T>) =
    createCoroutineUnchecked(completion).resumeCancellable(Unit)
```
这里开始的方法名字开始像我们java中的futuretask了。我们详细看看里面是怎么回事。


我们先看看createCoroutineUnchecked这个方法究竟创建了一个什么对象，由于我们显示的设置了接受者是CommonPool，那么走进将会这个函数
```
@SinceKotlin("1.1")
@kotlin.jvm.JvmVersion
public fun <R, T> (suspend R.() -> T).createCoroutineUnchecked(
        receiver: R,
        completion: Continuation<T>
): Continuation<Unit> =
        if (this !is kotlin.coroutines.experimental.jvm.internal.CoroutineImpl)
            buildContinuationByInvokeCall(completion) {
                @Suppress("UNCHECKED_CAST")
                (this as Function2<R, Continuation<T>, Any?>).invoke(receiver, completion)
            }
        else
            (this.create(receiver, completion) as kotlin.coroutines.experimental.jvm.internal.CoroutineImpl).facade
```
走到这里我们开始很疑惑了，这个this按照道理来说是block的对象，然而我查遍整个apk编译出来的类都没有实现这个CoroutineImpl这个抽象类的类。着实让我费解了很久。接着我反编译我的apk之后，发现这个是kotlin的一个特性，它会根据写的代码会适当的在MainActivity扩展一些内部类。jdk-gui上看不到的，我的AS点击decompiler也没有效果，最后还是这个工具
https://github.com/skylot/jadx
解了我的燃眉之急。
```
final class MainActivity$onCreate$result$1 extends CoroutineImpl implements Function2<CoroutineScope, Continuation<? super String>, Object> {
    private CoroutineScope p$;
    final /* synthetic */ MainActivity this$0;

    MainActivity$onCreate$result$1(MainActivity mainActivity, Continuation continuation) {
        this.this$0 = mainActivity;
        super(2, continuation);
    }

    @NotNull
    public final Continuation<Unit> create(@NotNull CoroutineScope $receiver, @NotNull Continuation<? super String> $continuation) {
        Intrinsics.checkParameterIsNotNull($receiver, "$receiver");
        Intrinsics.checkParameterIsNotNull($continuation, "$continuation");
        Continuation mainActivity$onCreate$result$1 = new MainActivity$onCreate$result$1(this.this$0, $continuation);
        mainActivity$onCreate$result$1.p$ = $receiver;
        return mainActivity$onCreate$result$1;
    }

    @Nullable
    public final Object invoke(@NotNull CoroutineScope $receiver, @NotNull Continuation<? super String> $continuation) {
        Intrinsics.checkParameterIsNotNull($receiver, "$receiver");
        Intrinsics.checkParameterIsNotNull($continuation, "$continuation");
        return ((MainActivity$onCreate$result$1) create($receiver, (Continuation) $continuation)).doResume(Unit.INSTANCE, null);
    }

    @Nullable
    public final Object doResume(@Nullable Object obj, @Nullable Throwable th) {
        Object coroutine_suspended = IntrinsicsKt.getCOROUTINE_SUSPENDED();
        switch (this.label) {
            case 0:
                if (th != null) {
                    throw th;
                }
                CoroutineScope coroutineScope = this.p$;
                MainActivity mainActivity = this.this$0;
                this.label = 1;
                obj = mainActivity.work(this);
                return obj == coroutine_suspended ? coroutine_suspended : obj;
            case 1:
                if (th == null) {
                    return obj;
                }
                throw th;
            default:
                throw new IllegalStateException("call to 'resume' before 'invoke' with coroutine");
        }
    }
}
```
我们可以看见这个地方kotlin编译器编译出了新的内部类。上面那个create的方法实际上就是走的这个create方法，返回了一个实现了CoroutineImpl的MainActivity$onCreate$result$1的对象。

接着我们继续接着上面调用了facade对象
```
private val _context: CoroutineContext? = completion?.context

val facade: Continuation<Any?> get() {
        if (_facade == null) _facade = interceptContinuationIfNeeded(_context!!, this)
        return _facade!!
    }

```
接着调用下面的
```
internal fun <T> interceptContinuationIfNeeded(
        context: CoroutineContext,
        continuation: Continuation<T>
) = context[ContinuationInterceptor]?.interceptContinuation(continuation) ?: continuation
```
那么这些参数对应了哪几个呢？
1.completion 对应了DeferredCoroutine  
2.那么context对应了newCoroutineContext。而我们前面就说了newCoroutineContext实际上是指的是CommonPool。

还记得CommonPool继承了CoroutineDispatcher这个抽象类，而这个类实际上就是扩展了
```
public abstract class CoroutineDispatcher :
        AbstractCoroutineContextElement(ContinuationInterceptor), ContinuationInterceptor
```


换句话说，我们实际上调用的是CoroutineDispatcher的interceptContinuation，这个方法将会返回一个DispatchedContinuation对象
```
public override fun <T> interceptContinuation(continuation: Continuation<T>): Continuation<T> =
            DispatchedContinuation(this, continuation)
```
DispatchedContinuation而这个类就是重点开始分发
```
internal class DispatchedContinuation<in T>(
    @JvmField val dispatcher: CoroutineDispatcher,
    @JvmField val continuation: Continuation<T>
): Continuation<T> by continuation {
    override fun resume(value: T) {
        val context = continuation.context
        if (dispatcher.isDispatchNeeded(context))
            dispatcher.dispatch(context, DispatchTask(continuation, value, exception = false, cancellable = false))
        else
            resumeUndispatched(value)
    }

    override fun resumeWithException(exception: Throwable) {
        val context = continuation.context
        if (dispatcher.isDispatchNeeded(context))
            dispatcher.dispatch(context, DispatchTask(continuation, exception, exception = true, cancellable = false))
        else
            resumeUndispatchedWithException(exception)
    }

    @Suppress("NOTHING_TO_INLINE") // we need it inline to save us an entry on the stack
    inline fun resumeCancellable(value: T) {
        val context = continuation.context
        if (dispatcher.isDispatchNeeded(context))
            dispatcher.dispatch(context, DispatchTask(continuation, value, exception = false, cancellable = true))
        else
            resumeUndispatched(value)
    }

    @Suppress("NOTHING_TO_INLINE") // we need it inline to save us an entry on the stack
    inline fun resumeCancellableWithException(exception: Throwable) {
        val context = continuation.context
        if (dispatcher.isDispatchNeeded(context))
            dispatcher.dispatch(context, DispatchTask(continuation, exception, exception = true, cancellable = true))
        else
            resumeUndispatchedWithException(exception)
    }

    @Suppress("NOTHING_TO_INLINE") // we need it inline to save us an entry on the stack
    inline fun resumeUndispatched(value: T) {
        withCoroutineContext(context) {
            continuation.resume(value)
        }
    }

    @Suppress("NOTHING_TO_INLINE") // we need it inline to save us an entry on the stack
    inline fun resumeUndispatchedWithException(exception: Throwable) {
        withCoroutineContext(context) {
            continuation.resumeWithException(exception)
        }
    }

    // used by "yield" implementation
    internal fun dispatchYield(value: T) {
        val context = continuation.context
        dispatcher.dispatch(context, DispatchTask(continuation, value,false, true))
    }

    override fun toString(): String =
        "DispatchedContinuation[$dispatcher, ${continuation.toDebugString()}]"
}
```
看到这里，如果看过okhttp源码的朋友一定会惊呼，这不就是okhttp的拦截器模式吗？这里面同理，CoroutineDispatcher扩展了一个协同拦截器的接口，一个类似链表一样的接口。也就是在最上面context[job]的时候，把这个新的任务丢进到链表里面，最后再通过DispatchedContinuation分发任务。

是不是这样我们再看看，我们几乎走完了createCoroutineUnchecked这个函数接下来我们看看它调用的resumeCancellable。

```
internal fun <T> Continuation<T>.resumeCancellable(value: T) = when (this) {
    is DispatchedContinuation -> resumeCancellable(value)
    else -> resume(value)
}
```
和我们分析的一致会判断一次DispatchedContinuation的类型，接着走resumeCancellable方法。
```
    inline fun resumeCancellable(value: T) {
        val context = continuation.context
        if (dispatcher.isDispatchNeeded(context))
            dispatcher.dispatch(context, DispatchTask(continuation, value, exception = false, cancellable = true))
        else
            resumeUndispatched(value)
    }
```
这个方法实际上是DispatchedContinuation内部的分发动作。

```
    override fun dispatch(context: CoroutineContext, block: Runnable) =
        try { (_pool ?: getOrCreatePoolSync()).execute(timeSource.trackTask(block)) }
        catch (e: RejectedExecutionException) {
            timeSource.unTrackTask()
            DefaultExecutor.execute(block)
        }
```
接着最后走到CommonPool里面的dispatch方法。看到没有，这里就走到了execute这个线程执行器启动线程并且把block，也就是安全构建器这个async大括号内的内容统统放到了线程中执行。如果出现了拒绝的一场就添加到队列里面。

这就是协程启动线程的流程。

这就完了吗，还有几点要注意的：
```
internal class DispatchTask<in T>(
    private val continuation: Continuation<T>,
    private val value: Any?, // T | Throwable
    private val exception: Boolean,
    private val cancellable: Boolean
) : Runnable {
    @Suppress("UNCHECKED_CAST")
    override fun run() {
        try {
            val context = continuation.context
            val job = if (cancellable) context[Job] else null
            withCoroutineContext(context) {
                when {
                    job != null && !job.isActive -> continuation.resumeWithException(job.getCancellationException())
                    exception -> continuation.resumeWithException(value as Throwable)
                    else -> continuation.resume(value as T)
                }
            }
        } catch (e: Throwable) {
            throw RuntimeException("Unexpected exception running $this", e)
        }
    }

    override fun toString(): String =
        "DispatchTask[${continuation.toDebugString()}, cancellable=$cancellable, value=${value.toSafeString()}]"
}
```

这个dispatchTask实际上扩展了java中的runnable方法。这里面重写了run的方法。这里就是为了切换Job。

我们看看，这里有几种状态我们逐一分析一下，顺便总结一下，
Job是线程初始化的时候绑定
如果是job != null && !job.isActive这个状态说明是一个异常状态以及抛出了异常。

正常情况下会走resume的方法。
如果分发器发现还有下一个任务就会继续封装一个runnable对象启动线程。不然就执行下面resumeUndispatched。

```
    final override fun resume(value: T) {
        makeCompleting(value, defaultResumeMode)
    }
```

```
internal fun makeCompleting(proposedUpdate: Any?, mode: Int): Boolean {
        loopOnState { state ->
            if (state !is Incomplete)
                throw IllegalStateException("Job $this is already complete, but is being completed with $proposedUpdate", proposedUpdate.exceptionOrNull)
            if (state is Finishing && state.completing)
                throw IllegalStateException("Job $this is already completing, but is being completed with $proposedUpdate", proposedUpdate.exceptionOrNull)
            val child: Child = firstChild(state) ?: // or else complete immediately w/o children
                if (updateState(state, proposedUpdate, mode)) return true else return@loopOnState
            // must promote to list to correct operate on child lists
            if (state is JobNode<*>) {
                promoteSingleToNodeList(state)
                return@loopOnState // retry
            }
            // cancel all children in list on exceptional completion
            if (proposedUpdate is CompletedExceptionally)
                child.cancelChildrenInternal(proposedUpdate.exception)
            // switch to completing state
            val completing = Finishing(state.list!!, (state as? Finishing)?.cancelled, true)
            if (_state.compareAndSet(state, completing)) {
                waitForChild(child, proposedUpdate)
                return false
            }
        }
    }
```
这个方法就是切换Job状态的，如果state是JobNode的类型则获取下一个新的的节点，再返回。一旦后面的任务队列已经没有任何东西了，就会走到了completing，尝试着修改为completing的状态，最后再去调用下一个aysnc的方法。

只有这点东西吗？不对这一次我们是来看看async是怎么做到future。别忘了，DeferredCoroutine这个类还扩展了第二个接口，Deferred。

我们看看await的方法：
```
    protected suspend fun awaitInternal(): Any? {
        // fast-path -- check state (avoid extra object creation)
        while(true) { // lock-free loop on state
            val state = this.state
            if (state !is Incomplete) {
                // already complete -- just return result
                if (state is CompletedExceptionally) throw state.exception
                return state

            }
            if (startInternal(state) >= 0) break // break unless needs to retry
        }
        return awaitSuspend() // slow-path
    }
```

这个方法，实际上就是不断的检测state这个状态是否是完成状态，是的话，就把结果返回去。

也就印证了我之前说的，我们的future模式。在kotlin中我们先拿到了一个DeferredCoroutine作为一个句柄，我们调用await的时候实际上是在自己想要获取的地方等待线程完成获取自己想要的数据。

那么launch呢？
```
public fun launch(
    context: CoroutineContext = DefaultDispatcher,
    start: CoroutineStart = CoroutineStart.DEFAULT,
    block: suspend CoroutineScope.() -> Unit
): Job {
    val newContext = newCoroutineContext(context)
    val coroutine = if (start.isLazy)
        LazyStandaloneCoroutine(newContext, block) else
        StandaloneCoroutine(newContext, active = true)
    coroutine.initParentJob(context[Job])
    start(block, coroutine, coroutine)
    return coroutine
}
```
很明显，这里面只是扩展了Job这个控制线程的接口，并没有获取方法的函数。

可以很轻易的发现Deferred和Java中的Callable很相似，但是更加的灵活了。

### 结束语
kotlin作为一门新的语言，我学习的时间不长，但是不断看源码的路上，从源码上学习到了不少kotlin的一些用法。虽然可能将的可能会漏。我感觉这确实是一种成长。估计之后的1-2个月暂时不会去写文章了，公司给了一个挺有意思的课题，接下来我会全力去做。这篇文章我本来也是写了一半，了却之前没有完成的事情。

如果有疑问请在本文找我：https://www.jianshu.com/p/56b7650642c0

对了未来的一段日子里面我会陆陆续续添加类的时序图和类的结构图。


