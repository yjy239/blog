---
title: 从源码角度看AsyncTask与LoaderManager多线程设计
top: false
cover: false
date: 2018-04-05 16:32:29
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android
- Android Framework
---
## 题外话
哈，搁置了一段时间没有写博客。主要是去研究Android虚拟机和ffmpeg中ffplay的源码了。计划上是时候把AsyncTask和其中蕴含的多线程编程思想和大家所得分享一下，自己也需要记录一下。
之后可能将计划把handler最后一部分:native层中looper使用管道挂起handler线程，从而让步cpu资源的原理分析一下。当然如果觉得自己写的没有其他人好，我也就不放出来了。

## 开篇以及题外话
AsyncTask是Android官方开放出来的多线程控制器。源码我在16年的时候已经分析过了附上地址:
http://blog.csdn.net/yujunyu12/article/details/52279927

题外话:我这才发现我这篇博文被csdn推荐过首页，感觉是时候可以让简书和csdn的文章同步一下了。

这一篇文章我当时比较年轻只是把大体的流程解析了一遍。也没有把其中的关节讲透。而LoadManager 被称为可以用来代替AsyncTask的更好方案。这一次我将结合LoadManager和asynctask一起分析一下，Android官方对多线程的编程思想以及为什么网上的人老是说AsyncTask内存泄露。

## 多线程编程的一些设计模式
在这里我稍微借用java多线程设计模式一书中，所设定的多线程程设计的模式概念:

1.Single Threaded Excution 单线程执行模式(能通过这座桥的只有一个人)

2.Immutable 不变原则(想破坏它也没办法)

3.Guarded Suspension 临界区保护原则 要等我准备好

4.Balking  阻行原则 不需要的话，就算了吧

5.Produce-Consumer 生产者和消费者模型 

6.Read-Write Lock 读写锁

7.Thread - per - Message 工作交于第三者实现

8.Worker-Thread 工作线程，有工作就完成

9.Future 先获取对象再获取到线程结果

10.Two-Phase Termiation 线程结束模式

11.Thread-Special Storage Thread-local每个线程自身的存储map

以上就是这本书对多线程设计模式的定义。

我们结合上面的思想分析一下AsyncTask，LoadManager其中的源码。

关于AsyncTask的源码我很早就分析过了，这边稍微提一下。下面分析的源码老规矩还是5.1.0版本的。
先让我们看看关键的几处：
```
 public AsyncTask() {
        mWorker = new WorkerRunnable<Params, Result>() {
            public Result call() throws Exception {
                mTaskInvoked.set(true);

                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND);
                //noinspection unchecked
                return postResult(doInBackground(mParams));
            }
        };

        mFuture = new FutureTask<Result>(mWorker) {
            @Override
            protected void done() {
                try {
                    postResultIfNotInvoked(get());
                } catch (InterruptedException e) {
                    android.util.Log.w(LOG_TAG, e);
                } catch (ExecutionException e) {
                    throw new RuntimeException("An error occured while executing doInBackground()",
                            e.getCause());
                } catch (CancellationException e) {
                    postResultIfNotInvoked(null);
                }
            }
        };
    }
```
实际上在我看来这个构造函数在整个AsyncTask来说也是及其重要的地位。我很久之前是着重对AysncTask的线程池执行器进行了解析。如今在看一遍AysncTask源码，却又有了新的理解。我再一次看到这个构造函数的时候，发现AsyncTask为什么说做的精妙，为什么说做是一个经典的异步工具。看到了这个构造函数之后，就会明白，AsyncTask实际上是对Java的异步调用FutureTask做了第二次封装。

我们先来看看一个FutureTask的常见用法：

创建一个Call对象
```
public class Call implements Callable<Integer> {

    private int sum;
    @Override
    public Integer call() throws Exception {

        for(int i=0 ;i<5000;i++){
            sum=sum+i;
        }
        return sum;
    }
}
```

在主函数：
```
public class FutureTest {

    public static void main(String[] args){

        ExecutorService service = Executors.newFixedThreadPool(1);

        Call call = new Call();

        Future<Integer> future = service.submit(call);

        service.shutdown();

        try {
            Thread.sleep(2000);
            System.out.println("主线程在执行其他任务");

            if(future.get()!=null){
                //输出获取到的结果
                System.out.println("future.get()-->"+future.get());
            }else{
                //输出获取到的结果
                System.out.println("future.get()未获取到结果");
            }

        } catch (Exception e) {
            e.printStackTrace();
        }
        System.out.println("主线程在执行完成");
    }
}
```

这段代码的思想其实和上述我所说的多线程编程模式中的Future模式一致。这个模式的核心思想是当我们需要从多线程里面获取某个结果的时候，我们并不需要一致等待线程完成，而是只需要拿到一个线程对象的句柄或者说“拿到这个结果的兑换票”,之后在想获取的地方获取。

这么说还是太过于抽象了，让我们稍微看看java下面是怎么实现的。由于Call我们先来看看关键的运行方法run。
```
    public void run() {
        if (state != NEW ||
            !UNSAFE.compareAndSwapObject(this, runnerOffset,
                                         null, Thread.currentThread()))
            return;
        try {
            Callable<V> c = callable;
            if (c != null && state == NEW) {
                V result;
                boolean ran;
                try {
                    //此处获取结果，调用了call方法
                    result = c.call();
                    ran = true;
                } catch (Throwable ex) {
                    result = null;
                    ran = false;
                    setException(ex);
                }
                if (ran)
                    set(result);
            }
        } finally {
            // runner must be non-null until state is settled to
            // prevent concurrent calls to run()
            runner = null;
            // state must be re-read after nulling runner to prevent
            // leaked interrupts
            int s = state;
            if (s >= INTERRUPTING)
                handlePossibleCancellationInterrupt(s);
        }
    }
```
这一段代码的大致思路是当线程池启动时候，调用run方法。在run方法里面执行call的的方法获取计算结果。

这里有一点值得注意的是UNSAFE.compareAndSwapObject这个方法。这个方法是一个UNSAFE类的静态native方法，对应的是java虚拟机每个平台下面的一个指令是一个原子操作故不需要担心多线程多次访问问题。结合一下下面贴的代码稍微说一下

```
 // Unsafe mechanics
    private static final sun.misc.Unsafe UNSAFE;
    private static final long stateOffset;
    private static final long runnerOffset;
    private static final long waitersOffset;
    static {
        try {
            UNSAFE = sun.misc.Unsafe.getUnsafe();
            Class<?> k = FutureTask.class;
            stateOffset = UNSAFE.objectFieldOffset
                (k.getDeclaredField("state"));
            runnerOffset = UNSAFE.objectFieldOffset
                (k.getDeclaredField("runner"));
            waitersOffset = UNSAFE.objectFieldOffset
                (k.getDeclaredField("waiters"));
        } catch (Exception e) {
            throw new Error(e);
        }
    }
```
结合两个代码，就可以知道
```
UNSAFE.compareAndSwapObject(this, runnerOffset,
                                         null, Thread.currentThread())
```

这个方法顾名思义，不断的扫描类中的某个对象并且进行比较。那么这个方法调用意思是从这个类映射的内存找到找到runner这个属性对象偏移量也就是runner这个对象在内存的位置，不断的尝试的修改为Thread.currentThread()，如果成功则返回true否则返回false。

其实这个操作和我们用wait定义临界区一个意思，不过就是这个方法是原子操作保证同一资源在同一时间只有一个线程访问（不准确，因为在linux内核中是抢占式调度的，这么说好理解），而wait是保证只有一个线程访问资源，手段是通过挂起其他线程。

这个不就是我们经常所说的CAS乐观锁，或者说是自旋锁吗。很乐观的认为这个属性一定发生变化，不断的在循环检测该地址的值是否改变。我们可以如此写可以等价上面的操作。
```
private Thread t;
    public synchronized void waitforObject(){
        while (t==null){
            try {
                wait();
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        }
    }
```
我也曾经想去操作这个UNSAFE类，既然java隐藏了，那就算了。发现没，这里面也是符合了多线程编程的单一线程执行原则，这个原则是指在访问同一个资源的时候，最好是保证一次只有一个线程在对这个资源进行操作。

这个关键的函数理解了。接下来理解FutureTask就好办了。继续回到run方法里面看看究竟做了什么事情：
1.我们在run里面也就是线程本体里面通过call方法获取结果
2.接着把结果通过set方法设置进去，很明显outcome就是我们想要的结果。
```
protected void set(V v) {
        if (UNSAFE.compareAndSwapInt(this, stateOffset, NEW, COMPLETING)) {
            outcome = v;
            UNSAFE.putOrderedInt(this, stateOffset, NORMAL); // final state
            finishCompletion();
        }
    }
```

这样我们再看看get和其中调用的report方法:
```
public V get(long timeout, TimeUnit unit)
        throws InterruptedException, ExecutionException, TimeoutException {
        if (unit == null)
            throw new NullPointerException();
        int s = state;
        if (s <= COMPLETING &&
            (s = awaitDone(true, unit.toNanos(timeout))) <= COMPLETING)
            throw new TimeoutException();
        return report(s);
    }

 private V report(int s) throws ExecutionException {
        Object x = outcome;
        if (s == NORMAL)
            return (V)x;
        if (s >= CANCELLED)
            throw new CancellationException();
        throw new ExecutionException((Throwable)x);
    }
```
每一次获取度判断一次其等待的时间是否超时，超时抛出异常，没有超时则获取在outcome的数据返回。接着通过waitNode设置为下个线程运作run的方法。当然里面还有该线程执行的状态
```
    private static final int NEW          = 0;
    private static final int COMPLETING   = 1;
    private static final int NORMAL       = 2;
    private static final int EXCEPTIONAL  = 3;
    private static final int CANCELLED    = 4;
    private static final int INTERRUPTING = 5;
    private static final int INTERRUPTED  = 6;
```
这里暂时不做任何讨论。

FutureTask暂时分析到这里。说到这里我们大概知道所谓的future模式就是拿到包裹结果的对象，再通过对象从里面获取真正的结果。从这里我们可以模仿FutureTask，写一个简单版本的：
Data.java
```
public interface Data {
	
	public abstract String getContent();

}
```
FutureData.java
```
public class FutureData implements Data {
	
	private RealData data = null;
	private boolean ready = false;
	
	public synchronized void setRealData(RealData data){
		if(ready){
			return;//balk模式，临界值不正确则不执行
		}
		this.data = data;
		this.ready = true;
		notifyAll();
	}
	
	
	@Override
	public synchronized String getContent() {
		// TODO Auto-generated method stub
                //临界区中等待数据加载成功
		while (!ready) {
			try {
				wait();
			} catch (InterruptedException e) {
				// TODO Auto-generated catch block
				
			}
		}
		return data.getContent();
	}

}
```
RealData.java
```
public class RealData implements Data {
	//为了显示出效果把加载过程用sleep加长了写入时间
	private final String content;
	
	public RealData(int count ,char c) {
		// TODO Auto-generated constructor stub
		System.out.println(" making RealData("+count+","+c+") BEGIN");
		char[] buffer = new char[count];
		for(int i=0;i<count;i++){
			buffer[i] = c;
			try{
				Thread.sleep(100);
			}catch(InterruptedException e){
				
			}
		}
		System.out.println(" making RealData("+count+","+c+") END");
		this.content = new String(buffer);
		
	}
	
	@Override
	public String getContent() {
		// TODO Auto-generated method stub
		return content;
	}
}
```
Host.java
```
public class Host {
	
	public Data request(final int count,final char c){
		System.out.println(" request("+count+","+c+") BEGIN");
		final FutureData futureData = new FutureData();
		//这个是Thread-pre 好处在于可以迅速拿到FutureData的对象，但是要获取里面的RealData的内容，需要等待线程解锁
		new Thread(){
			public void run() {
				RealData data = new RealData(count, c);
				futureData.setRealData(data);
			};
		}.start();
		
		System.out.println(" request("+count+","+c+") END");
		
		return futureData;
		
	}

}
```

```
public class Main {
	
	public static void main(String[] args) {
		System.out.println("main BEGIN");
		Host host = new Host();
		Data data1 = host.request(10, 'A');
		
		Data data2 = host.request(20, 'B');
		Data data3 = host.request(30, 'C');
		
		System.out.println("DO other");
		
		try {
			Thread.sleep(2000);
		} catch (InterruptedException e) {
			// TODO Auto-generated catch block
			e.printStackTrace();
		}
		System.out.println("DO other END");
		
		System.out.println("data1: "+data1.getContent());
		System.out.println("data2: "+data2.getContent());
		System.out.println("data3: "+data3.getContent());
		
		
		System.out.println("main END");
		
	}

}
```
似乎之前说的很简单，自己着手写一个类似futuretask还是涉及到了不少的多线程模式，如balk模式，一旦检测到返回值不正确则立即返回。Thread-pre模式是把线程实际的动作交给其他人来处理，Guarded Suspension模式，通过只允许单线程访问资源，来保护资源。这些组合起来才是完整future模式。可以说futuretask看似简单，实际里面的内容多多。在AsyncTask中涉及到了线程池，而线程池实际上也是属于Work-Thread的模式，意思就是线程池在待机，有任务就开始工作。

当然最近比较流行的kotlin的线程协程模型实际上也是这么一个思路。等我有时间找找kotlin有没有放出源码，再给你验证一下。我所写的tnloader图片加载器的okhttpsupport也是通过这种方式进行了okhttp和tnloader图片加载两个线程进行通信。

回到开头，我们再回头看看AsyncTask又是怎么回事。我们现在也能即使0基础明白了AsyncTask的源码。

构造函数mWorker扩展了接口WorkerRunnable，也就是一个callable
```
    private static abstract class WorkerRunnable<Params, Result> implements Callable<Result> {
        Params[] mParams;
    }
```

那么也懂了mFuture，为什么要设置这个mWork，因为执行器最后一定通过callable调用里面的run的方法。这里就不分析AsyncTask的异步执行为什么是串行，又怎么并行了。我前年已经分析过了。

这也是为什么我们说doInBackground(mParams)是在线程中工作,因为这个doInBackground是在call里面的，call实际上就是线程执行的本体。
```
postResult(doInBackground(mParams));
```

而onPreExecute();又因为此时还没有执行线程所以也是线程之外
```
public final AsyncTask<Params, Progress, Result> executeOnExecutor(Executor exec,
            Params... params) {
        if (mStatus != Status.PENDING) {
            switch (mStatus) {
                case RUNNING:
                    throw new IllegalStateException("Cannot execute task:"
                            + " the task is already running.");
                case FINISHED:
                    throw new IllegalStateException("Cannot execute task:"
                            + " the task has already been executed "
                            + "(a task can be executed only once)");
            }
        }

        mStatus = Status.RUNNING;

        onPreExecute();

        mWorker.mParams = params;
        exec.execute(mFuture);

        return this;
    }
```

而我之前也说过了里面有一个handler，当执行完成之后将会通过这个切换主线程。详细的就看我16年写的文章。总结一句话，AsyncTask实际上是对FutureTask的封装。在通过模板模式，将对应的操作暴露出来。

我们切换一下，看一下LoadManager为什么很多人说这个用来替代AsyncTask。我们挑最相似AsyncTaskLoader。这个类是继承Loader的抽象类。老规矩，让我们看看AsyncTaskLoader怎么用，再来分析源码吧。

```
public class AsyncLoader extends AsyncTaskLoader<Integer> {


    public AsyncLoader(Context context) {
        super(context);
    }

    @Override
    protected void onStartLoading() {
        super.onStartLoading();
        Log.e("TAG","start "+Thread.currentThread());
        forceLoad();
    }

    @Override
    public Integer loadInBackground() {
        Log.e("TAG","load "+Thread.currentThread());
        return 100;
    }

    @Override
    public void forceLoad() {
        super.forceLoad();
        Log.e("TAG","forceLoad "+Thread.currentThread());
    }

    @Override
    public void deliverResult(Integer data) {
        super.deliverResult(data);
        Log.e("TAG","deliverResult"+Thread.currentThread());
    }

    @Override
    protected void onStopLoading() {
        super.onStopLoading();
        Log.e("TAG","onStopLoading "+Thread.currentThread());
        cancelLoad();
    }

    @Override
    protected void onReset() {
        super.onReset();
        Log.e("TAG","onReset "+Thread.currentThread());
    }

    @Override
    protected boolean onCancelLoad() {
        Log.e("TAG","onCancelLoad "+Thread.currentThread());
        return super.onCancelLoad();

    }
}
```

```
public class MainActivity extends AppCompatActivity implements LoaderManager.LoaderCallbacks<Integer> {

    private static final int ID = 0;
    private String TAG = "TAG";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        if(getLoaderManager().getLoader(ID) == null){
            Log.e(TAG,"no loader");
        }else {
            Log.e(TAG,"has loader");
        }
        getLoaderManager().initLoader(ID,null,this);
    }


    @Override
    public Loader<Integer> onCreateLoader(int id, Bundle args) {
        Log.e(TAG,"onCreateLoader");
        return new AsyncLoader(this);
    }

    @Override
    public void onLoadFinished(Loader<Integer> loader, Integer data) {
        Log.e(TAG,"onLoadFinished "+data);
    }

    @Override
    public void onLoaderReset(Loader<Integer> loader) {
        Log.e(TAG,"onCreateLoader");

    }
}
```

![LoadManager生命周期.png](/images/LoadManager生命周期.png)

这个显示的流程，我顺便把线程也打印下来，顺便我们可以清晰的看出也就是在loadInBackground的位置在另一个线程。其他的都处于主线程中。看到打印了吧，生成一个名字为AsyncTask的线程名，其实官方就是在告诉我们，AsyncLoader是封装了AsyncTask一次。我们稍稍看看getLoaderManager中的init初始化做了什么吧。

我们会发现这个getLoaderManager是Activity 中FragmentController的getLoaderManager方法。但是实际上是一个桥接模式，把真正的工作交给mHost工作，
```
private final FragmentHostCallback<?> mHost;

public LoaderManager getLoaderManager() {
        return mHost.getLoaderManagerImpl();
    }
```
去FragmentHostCallback下面找实际对象
```

LoaderManagerImpl getLoaderManagerImpl() {
        if (mLoaderManager != null) {
            return mLoaderManager;
        }
        mCheckedForLoaderManager = true;
        mLoaderManager = getLoaderManager("(root)", mLoadersStarted, true /*create*/);
        return mLoaderManager;
    }

LoaderManagerImpl getLoaderManager(String who, boolean started, boolean create) {
        if (mAllLoaderManagers == null) {
            mAllLoaderManagers = new ArrayMap<String, LoaderManager>();
        }
        LoaderManagerImpl lm = (LoaderManagerImpl) mAllLoaderManagers.get(who);
        if (lm == null && create) {
            lm = new LoaderManagerImpl(who, this, started);
            mAllLoaderManagers.put(who, lm);
        } else if (started && lm != null && !lm.mStarted){
            lm.doStart();
        }
        return lm;
    }
```
实际上会在每个FragmentController里面创建一个新的LoaderManagerImpl并且加入到一个ArrayMap进行管理。当然如果已经创建了那么则会从这个map中找到对应的loadermanager。一般的，我们那只有名字为（root）的loadermanager，也就说至始至终只有一个。

那么就要从LoaderManagerImpl里面去找到我们想要的初始化方法。
```
final SparseArray<LoaderInfo> mLoaders = new SparseArray<LoaderInfo>(0);

public <D> Loader<D> initLoader(int id, Bundle args, LoaderManager.LoaderCallbacks<D> callback) {
        if (mCreatingLoader) {
            throw new IllegalStateException("Called while creating a loader");
        }
        
        LoaderInfo info = mLoaders.get(id);
        
        if (DEBUG) Log.v(TAG, "initLoader in " + this + ": args=" + args);

        if (info == null) {
            // Loader doesn't already exist; create.
            info = createAndInstallLoader(id, args,  (LoaderManager.LoaderCallbacks<Object>)callback);
            if (DEBUG) Log.v(TAG, "  Created new loader " + info);
        } else {
            if (DEBUG) Log.v(TAG, "  Re-using existing loader " + info);
            info.mCallbacks = (LoaderManager.LoaderCallbacks<Object>)callback;
        }
        
        if (info.mHaveData && mStarted) {
            // If the loader has already generated its data, report it now.
            info.callOnLoadFinished(info.mLoader, info.mData);
        }
        
        return (Loader<D>)info.mLoader;
    }
```

我们先从mLoaders这个SparseArray获取到对应id的LoaderInfo。实际上我们初始化也是这个LoaderInfo。在这里稍微提一下ArrayMap和SparseArray。ArrayMap是android特有的一种Map，拓展了Map的接口，没有entry这种对象反之用两个数组维护，是能够插入任何的数据，而且在内存上做了一些优化。SparseArray有人经常把他和map相比较，但是实际上并没有实现map的接口。只是用法和思想相似，说不是map的成员也对，是也对。它有一点好处的是key值默认是int，减少了Integer的封装类型，大大的减少了内存的消耗。有时间再分析吧。

### 现在开始真正的走起Loader的生命周期：
我们这边按照第一次进来，创建loaderinfo，也就是说走了createAndInstallLoader的方法。
```
private LoaderInfo createAndInstallLoader(int id, Bundle args,
            LoaderManager.LoaderCallbacks<Object> callback) {
        try {
            mCreatingLoader = true;
            LoaderInfo info = createLoader(id, args, callback);
            installLoader(info);
            return info;
        } finally {
            mCreatingLoader = false;
        }
    }
```
```
private LoaderInfo createLoader(int id, Bundle args,
            LoaderManager.LoaderCallbacks<Object> callback) {
        LoaderInfo info = new LoaderInfo(id, args,  (LoaderManager.LoaderCallbacks<Object>)callback);
        Loader<Object> loader = callback.onCreateLoader(id, args);
        info.mLoader = (Loader<Object>)loader;
        return info;
    }
```

##### 从这里就得知会通过回调走onCreatLoader拿到loader对象。也就是上面打印的第一个步骤。

接着再走installLoader方法。
```
void installLoader(LoaderInfo info) {
        mLoaders.put(info.mId, info);
        if (mStarted) {
            // The activity will start all existing loaders in it's onStart(),
            // so only start them here if we're past that point of the activitiy's
            // life cycle
            info.start();
        }
    }
```

再来看看installLoader，由于传进来默认是true，那么一定会走info.start，接着就走到Loader的onStartLoading的回调。
```
void start() {
            if (mRetaining && mRetainingStarted) {
                // Our owner is started, but we were being retained from a
                // previous instance in the started state...  so there is really
                // nothing to do here, since the loaders are still started.
                mStarted = true;
                return;
            }

            if (mStarted) {
                // If loader already started, don't restart.
                return;
            }

            mStarted = true;
            
            if (DEBUG) Log.v(TAG, "  Starting: " + this);
            if (mLoader == null && mCallbacks != null) {
               mLoader = mCallbacks.onCreateLoader(mId, mArgs);
            }
            if (mLoader != null) {
                if (mLoader.getClass().isMemberClass()
                        && !Modifier.isStatic(mLoader.getClass().getModifiers())) {
                    throw new IllegalArgumentException(
                            "Object returned from onCreateLoader must not be a non-static inner member class: "
                            + mLoader);
                }
                if (!mListenerRegistered) {
                    mLoader.registerListener(mId, this);
                    mLoader.registerOnLoadCanceledListener(this);
                    mListenerRegistered = true;
                }
                mLoader.startLoading();
            }
        }
```

到这里Loader以及LoaderManager初始化就完成了。

接着如果我们只是简单的复写了里面的方法，你会发现这个异步根本没有执行。我们还需要在onStartLoading里面调用forceLoad();去刷新数据。才会真正的启动线程去执行。

###### 由于我们初始化的是AsyncTaskLoader，我们这个时候应该去AsyncTaskLoader里面查看forceLoad();方法。这个方法又调用了onForceLoad，而执行之前会调用cancelLoad回调取消上次正在加载的方法，我们适合把一些需要回收的数据在这里回收一次。
```
@Override
    protected void onForceLoad() {
        super.onForceLoad();
        cancelLoad();
        mTask = new LoadTask();
        if (DEBUG) Log.v(TAG, "Preparing load: mTask=" + mTask);
        executePendingTask();
    }
```
从这里我们一的得知我们自己也能复写onForceLoad，参与进forceLoad方法的调用。

关键的方法是executePendingTask
```
void executePendingTask() {
        if (mCancellingTask == null && mTask != null) {
            if (mTask.waiting) {
                mTask.waiting = false;
                mHandler.removeCallbacks(mTask);
            }
            if (mUpdateThrottle > 0) {
                long now = SystemClock.uptimeMillis();
                if (now < (mLastLoadCompleteTime+mUpdateThrottle)) {
                    // Not yet time to do another load.
                    if (DEBUG) Log.v(TAG, "Waiting until "
                            + (mLastLoadCompleteTime+mUpdateThrottle)
                            + " to execute: " + mTask);
                    mTask.waiting = true;
                    mHandler.postAtTime(mTask, mLastLoadCompleteTime+mUpdateThrottle);
                    return;
                }
            }
            if (DEBUG) Log.v(TAG, "Executing: " + mTask);
            mTask.executeOnExecutor(mExecutor, (Void[]) null);
        }
    }
```
这个mTask实际上是一个LoadTask，扩展了runnable接口，继承了AsyncTask。这个就是关键。而Handler的唯一的目的就是延时执行这个runnnable对象以及在删除Loader的时候，删除掉在handler中的runnable回调。

也就是说，每一次都会生成一个AsyncTask对象，Handler延时调用run的方法。

看到了executeOnExecutor这个串行执行AsyncTask的方法，大致也就明了接下来的步骤了。这边把复写的方法都列出来：
```
final class LoadTask extends AsyncTask<Void, Void, D> implements Runnable {
        private final CountDownLatch mDone = new CountDownLatch(1);

        // Set to true to indicate that the task has been posted to a handler for
        // execution at a later time.  Used to throttle updates.
        boolean waiting;

        /* Runs on a worker thread */
        @Override
        protected D doInBackground(Void... params) {
            if (DEBUG) Log.v(TAG, this + " >>> doInBackground");
            try {
                D data = AsyncTaskLoader.this.onLoadInBackground();
                if (DEBUG) Log.v(TAG, this + "  <<< doInBackground");
                return data;
            } catch (OperationCanceledException ex) {
                if (!isCancelled()) {
                    // onLoadInBackground threw a canceled exception spuriously.
                    // This is problematic because it means that the LoaderManager did not
                    // cancel the Loader itself and still expects to receive a result.
                    // Additionally, the Loader's own state will not have been updated to
                    // reflect the fact that the task was being canceled.
                    // So we treat this case as an unhandled exception.
                    throw ex;
                }
                if (DEBUG) Log.v(TAG, this + "  <<< doInBackground (was canceled)", ex);
                return null;
            }
        }

        /* Runs on the UI thread */
        @Override
        protected void onPostExecute(D data) {
            if (DEBUG) Log.v(TAG, this + " onPostExecute");
            try {
                AsyncTaskLoader.this.dispatchOnLoadComplete(this, data);
            } finally {
                mDone.countDown();
            }
        }

        /* Runs on the UI thread */
        @Override
        protected void onCancelled(D data) {
            if (DEBUG) Log.v(TAG, this + " onCancelled");
            try {
                AsyncTaskLoader.this.dispatchOnCancelled(this, data);
            } finally {
                mDone.countDown();
            }
        }

        /* Runs on the UI thread, when the waiting task is posted to a handler.
         * This method is only executed when task execution was deferred (waiting was true). */
        @Override
        public void run() {
            waiting = false;
            AsyncTaskLoader.this.executePendingTask();
        }

        /* Used for testing purposes to wait for the task to complete. */
        public void waitForLoader() {
            try {
                mDone.await();
            } catch (InterruptedException e) {
                // Ignore
            }
        }
    }
```

我们可以指知道，每一次Handler执行都会调用一次run里面的方法，run又调用了上面的方法，达成一个链式的调用。这个思路和AysncTask里面重写了excutor的excute的方法思路很像，区别在于一个AsyncTask中不断向下一个任务调用，到了Loader里面是通过Loader不断的的向下一个AsyncTask调用。

继续关注Loader的生命周期。由于它复写了doInBackground，onPostExecute，onCancelled三个方法。

###### 由于我们分析了doInBackGround方法，就会懂了异步线程就会调用一次抽象方法loadInBackground里面。

###### 一旦结束了通过onPostExecute调用dispatchOnLoadComplete方法，该方法最终也会通过deliverResult(data);回调到onLoadComplete中。

###### deliverResult走完父类的的方法才走到我们重写的方法中。

大致上我们AsyncTaskLoader的生命周期的完成了。

这个在java编程中就是一个很明显的模板设计模式，而在多线程设计模式又是结合了Thread - per - Message和Work-Thread设计出来，将真正的做事的对象交给线程。

当然也有一些其他没有说到，比如调用onContentChanged告诉容器变化了，刷新一次数据，不过最后还是调用forceload这里不做讨论。我们甚至可以在OnStartThread直接调用deliverResult直接获取缓存的数据，不需要每次都重新调用线程来获取数据等。

由于这个源码十分的简单，这一次就不上源码类的流程图了。



#### 源码都分析清楚，我们是时候说一下网上一些关于asynctask缺陷。

##### 1.很明显，AsyncTask的生命周期比activity要长。
就用网络加载图片为例子，由于是开了线程在工作，如果图片没有加载好，就算是activity走了onDestroy，它也会继续运行。

##### 2.AsyncTask容易内存泄漏。
就以上面的例子来说，加载图片图片如果是一个超长的时间，activity就算走了onDestroy也没有办法通过gc去回收。只要我们了解gc在android虚拟机原理就明白了，android虚拟机是每一次申请内存的时候才会试着做一次gc。这个时候会通过遍历Active堆（4.4以下，2.2以上）/Allcation或者LargeObjectMap（4.4以上）里面所认为的根对象集合。通过调用链不断的遍历，最后如果发现AsyncTask还引用Activity的对象，那么Activity对象也会打上标记不允许清除。
这个详细就在这里不做讨论了，有时间再结合源码分析，不过估计写的不可能有罗升阳好。

##### 3.并发数目有限。
因为AsyncTask是一个线程池并发的。我们可以清晰的看到有128并发数量的上限。

主要是以上几点，网上还说了结果丢失和串并行问题，在我的眼里根本还算不上主要矛盾。

#### 那么AsyncTaskLoader又处理的如何呢？

##### 1.针对生命周期和内存泄漏的问题：
```
final void performDestroy() {
        mDestroyed = true;
        mWindow.destroy();
        mFragments.dispatchDestroy();
        onDestroy();
        mFragments.doLoaderDestroy();
        if (mVoiceInteractor != null) {
            mVoiceInteractor.detachActivity();
        }
    }
```
我们可以清楚的发现整个LoaderManager的生命周期将会依赖这个Activity。一旦销毁的activity，则立即调用LoaderManager的doLoaderDestroy方法。我们直接看看实现类怎么回收数据的。我们看看LoaderInfo是怎么运作的。

```
void destroy() {
            if (DEBUG) Log.v(TAG, "  Destroying: " + this);
            mDestroyed = true;
            boolean needReset = mDeliveredData;
            mDeliveredData = false;
            if (mCallbacks != null && mLoader != null && mHaveData && needReset) {
                if (DEBUG) Log.v(TAG, "  Reseting: " + this);
                String lastBecause = null;
                if (mHost != null) {
                    lastBecause = mHost.mFragmentManager.mNoTransactionsBecause;
                    mHost.mFragmentManager.mNoTransactionsBecause = "onLoaderReset";
                }
                try {
                    mCallbacks.onLoaderReset(mLoader);
                } finally {
                    if (mHost != null) {
                        mHost.mFragmentManager.mNoTransactionsBecause = lastBecause;
                    }
                }
            }
            mCallbacks = null;
            mData = null;
            mHaveData = false;
            if (mLoader != null) {
                if (mListenerRegistered) {
                    mListenerRegistered = false;
                    mLoader.unregisterListener(this);
                    mLoader.unregisterOnLoadCanceledListener(this);
                }
                mLoader.reset();
            }
            if (mPendingLoader != null) {
                mPendingLoader.destroy();
            }
        }
```

主要做的工作注销了注册的监听接口，这个是主要用来监听Loader里面的加载是否成功，加载是否取消，第二个先后调用了一个在重写LoaderManager抽象方法的onLoaderReset，接着再回调Loader的reset方法。

这样就完成了生命周期是怎么绑定的。那么相对的我们也要在AsyncLoader的onReset回调中回收一些由Loader引用到其他位置的资源，在onLoaderonReset回收一些Activity引用其他位置的一些资源，保证自己在这个回调中把所有的引用链断开。

做好了上述这几点，我们就能在AsyncTaskLoader完美的避免内存泄漏。


##### 2.并发数量的问题。
如果仔细的读者，应该知道是怎么解决的。就和okhttp一样，不依赖下面的线程池最大并发数，而是保证每个线程任务保存在队列里面，每执行完一个，从队列中获取下一个任务。

这个也是一样，只允许AsyncTask执行一个线程，但是每一次都是一个AsyncTask作为任务通过Handler不断的轮询下一个AsyncTask的任务。这样就避免了并发数目的问题。

##### 关于AsyncTask和AsyncTaskLoader都有的一些小遗憾

不知道读者注意到没有，除了用于读写这种特殊操作的读写锁多线程模式之外，还有一种模式Two-Phase Termiation并没有涉及到，其他8种多线程主要的设计模式都涉及到了。

这个模式是用来终结线程工作的。换言之，两者都没有对线程的终结做处理。这导致一个什么问题呢？比如说我们在AsyncTask中执行一个时间十分长的行为，我们就算调用了reset的方法，就算是Handler把AsyncTask看作runnable Remove掉，也没有办法回收掉这个线程。

看来java和Android官方本来就是希望把如何结束线程这个行为交给我们开发者来判断。

对于结束线程一个概念，要结束线程的手段有两种，一个是触发Interceptor的异常，一个是让线程自发的运行到run的最后一行，自主结束这个线程行为。第一种线程触发了中断虽然行为中断了，实际上线程并不会立即回收。那么最好处理方式是第二种，第二种才会使得线程自己死亡，被回收。当然还有一种stop的方法，这个不能使用，万一你写数据的时候突然断了，这就不得了了。

案例代码：
```
		try {
			while (!shutdownRequest) {
				doWork();
			}
		} catch (InterruptedException e) {
			// TODO: handle exception
		}finally {
			doShutDown();
		}
```
我们可以通过一个标志位作为判断，灵活使用try...finally的妙用回收线程内的一些数据。

转换到AsyncTaskLoader的思路，我们完全可以设置一个标志位在loadInBackground里面，在onReset回调中把标志位设置掉，告诉线程是时候结束，让线程自己走完回收处理。

这就是推荐的线程回收方式。

结语：我本来只是想要稍微复习一下AsyncTask里面的代码的，分析一下我毕业的时候没有注意到的问题，毕竟虽然简单，但是还是十分经典的。这个时候，发现AsyncTaskLoader是AsyncTask的升级版本，而且里面还是有不少门道，就发出来一起分析。原本以为官方对线程结束有什么很好的见解，冲着这个问题去学习，发现就是上面我说的结论。通过两者之间的比较，现在比起AsyncTask我们当然优先使用AsyncTaskLoader。







































