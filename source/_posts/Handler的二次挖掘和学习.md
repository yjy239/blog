---
title: Handler的二次挖掘和学习
top: false
cover: false
date: 2018-01-02 14:09:15
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---
时隔一年，我再一次回头看Handler的源码，发现又有一些东西是我之前没有弄透彻，没有完完全全理解Handler。2年后的今天，还是2年前的今天就都以Handler的解析作为起点开始我的学习之旅吧。
Handler的工作流程这里就不多叙述了，这是我大四的时候分析的源码：
http://blog.csdn.net/yujunyu12/article/details/52261436

为什么Handler来来去去被当成面试题目呢？只要对Android源码有过一点了解的人都知道，Handler生存在Android各个角落，无论是AsyncTask，四大组件的启动流程等等。

我在2016年的时候就提过来了，Handler分为四个主要的角色Handler,Looper,Message,MessageQueue，要分析他，我们必不可少一定要涉及者四个方面。

这边稍微提一下:
Message :顾名思义就是线程中传递消息。（IPC中Messenger中也用到Message）。

MessageQueue:是指消息队列，每个消息进入之后，就进入到该队列进行排队，等待Handler的处理。

Handler：处理发送过来的消息。，一般需要重写handleMessage()来达到目的。

Looper：可以说是核心的模块，作为每个线程MessageQueue的管理者。


我这一次要总结的东西是，Handler究竟是如何办到多线程之间的数据传递而且不会因为多线程导致数据错乱呢？

Looper作为核心的模块，控制着这一切。我在上一篇写过一个不太好的代码，但是确实告知了Looper如何在子线程的运用:
```
 new Thread(new Runnable() {
                    @Override
                    public void run() {
                        // TODO Auto-generated method stub
                        Looper.prepare();
                        MyHandler myHandler = new MyHandler(Looper.myLooper());
                        Message msg = new Message();
                        msg.what = 2;
                        myHandler.sendMessage(msg);
                        Looper.loop();
                    }
                }).start();
```

我们先看看这个prepare方法究竟做了什么事情
```
 public static final void prepare() {  
            if (sThreadLocal.get() != null) {  
                throw new RuntimeException("Only one Looper may be created per thread");  
            }  
            sThreadLocal.set(new Looper(true));  
    }  
```

这个sThreadLocal就是关键，下面是它的声明:
```
static final ThreadLocal<Looper> sThreadLocal = new ThreadLocal<Looper>()
```

这就是关键这个ThreadLocal其实就是一个每个线程里面的本地变量，我们可以从每个Thread中获取到存储在Thread对象里面的变量。它实际上是一种同步机制，不过不同于加锁，是从另一个方面解决多线程冲突的问题。

真的是这样吗？我们继续看看，整个Handler中最重要的函数loop()：
```
 public static void loop() {  
            //关键
            final Looper me = myLooper();  
            if (me == null) {  
                throw new RuntimeException("No Looper; Looper.prepare() wasn't called on this thread.");  
            }  
            final MessageQueue queue = me.mQueue;  

            // Make sure the identity of this thread is that of the local process,  
            // and keep track of what that identity token actually is.  
            Binder.clearCallingIdentity();  
            final long ident = Binder.clearCallingIdentity();  

            for (;;) {  
                Message msg = queue.next(); // might block  
                if (msg == null) {  
                    // No message indicates that the message queue is quitting.  
                    return;  
                }  

                // This must be in a local variable, in case a UI event sets the logger  
                Printer logging = me.mLogging;  
                if (logging != null) {  
                    logging.println(">>>>> Dispatching to " + msg.target + " " +  
                            msg.callback + ": " + msg.what);  
                }  

                msg.target.dispatchMessage(msg);  

                if (logging != null) {  
                    logging.println("<<<<< Finished to " + msg.target + " " + msg.callback);  
                }  

                // Make sure that during the course of dispatching the  
                // identity of the thread wasn't corrupted.  
                final long newIdent = Binder.clearCallingIdentity();  
                if (ident != newIdent) {  
                    Log.wtf(TAG, "Thread identity changed from 0x"  
                            + Long.toHexString(ident) + " to 0x"  
                            + Long.toHexString(newIdent) + " while dispatching to "  
                            + msg.target.getClass().getName() + " "  
                            + msg.callback + " what=" + msg.what);  
                }  

                msg.recycle();  
            }  
    }
```
上面的代码我们可以得知，Looper从myLooper的函数里面拿出来，再拿出里面的MessageQueue的对象，再进行分发:
```
msg.target.dispatchMessage(msg);  
```
之后的东西，一般都知道了。很明显，这个myLooper()就是就是关键。
我们看看myLooper:
```
    public static Looper myLooper() {
        return sThreadLocal.get();    
}
```

这里就可以很清楚的知道，我们在子线程的时候先把Looper作为Thread的本地变量存进去，之后再拿出来。这样就可以避免了多线程之间的干扰了。

但是ThreadLocal又是如何办到的呢？我们稍微的看一下源码,set和get的源码:
 ```
    public void set(T value) {
        Thread t = Thread.currentThread();
        ThreadLocalMap map = getMap(t);
        if (map != null)
            map.set(this, value);
        else
            createMap(t, value);
    }
```

```
    public T get() {
        Thread t = Thread.currentThread();
        ThreadLocalMap map = getMap(t);
        if (map != null) {
            ThreadLocalMap.Entry e = map.getEntry(this);
            if (e != null)
                return (T)e.value;
        }
        return setInitialValue();
    }
```

可以得知set和get的方法都是存储到线程Thread对象的ThreadLocalMap里面去。

这个ThreadLocalMap又是什么东西呢？只需要明白这是一个存放在Thread里面的map。
下面是Thread的部分源码:
```
    /* ThreadLocal values pertaining to this thread. This map is maintained
     * by the ThreadLocal class. */
     ThreadLocal.ThreadLocalMap threadLocals = null;
 
     /*
      * InheritableThreadLocal values pertaining to this thread. This map is
      * maintained by the InheritableThreadLocal class.
      */
     ThreadLocal.ThreadLocalMap inheritableThreadLocals = null;

```

或许有人问，但是源码里面ThreadLocalMap作为ThreadLocal的内部类并没有继承Map啊。我们稍微看一下就明白一般的,我们通过ThreadLocal进行操作的时候，ThreadLocalMap存入了ThreadLocal这个对象为键,ThreadLocal的内容为值。
一般来说是Thread和ThreadLocal一个对一进行对应的，不排除，有这么一个情况:
1.继承了父类的ThreadLocalMap。
2.绕开ThreadLocal，直接在Thread对象的里面ThreadLocalMap进行操作。
由于有这些特殊性，你会发现ThreadLocal自己实现了Map的机制。

到这里看起来就结束了吗？不不不，我还不甘心，我还担心native层如果做了处理怎么办？虽然已经有了一点猜测，为了放心。那就去看看Java native是怎么实现Thread的。

让我们转到
```
void Thread::CreateNativeThread(JNIEnv* env, jobject java_peer, size_t stack_size, bool is_daemon)
```
下面是c++的代码关键代码
```
 Thread* child_thread = new Thread(is_daemon);
  // Use global JNI ref to hold peer live while child thread starts.
  child_thread->tlsPtr_.jpeer = env->NewGlobalRef(java_peer);
  stack_size = FixStackSize(stack_size);

  // Thread.start is synchronized, so we know that nativePeer is 0, and know that we're not racing to
  // assign it.
  env->SetLongField(java_peer, WellKnownClasses::java_lang_Thread_nativePeer,
                    reinterpret_cast<jlong>(child_thread));

  // Try to allocate a JNIEnvExt for the thread. We do this here as we might be out of memory and
  // do not have a good way to report this on the child's side.
  std::unique_ptr<JNIEnvExt> child_jni_env_ext(
      JNIEnvExt::Create(child_thread, Runtime::Current()->GetJavaVM()));

  int pthread_create_result = 0;
  if (child_jni_env_ext.get() != nullptr) {
    pthread_t new_pthread;
    pthread_attr_t attr;
    child_thread->tlsPtr_.tmp_jni_env = child_jni_env_ext.get();
    CHECK_PTHREAD_CALL(pthread_attr_init, (&attr), "new thread");
    CHECK_PTHREAD_CALL(pthread_attr_setdetachstate, (&attr, PTHREAD_CREATE_DETACHED),
                       "PTHREAD_CREATE_DETACHED");
    CHECK_PTHREAD_CALL(pthread_attr_setstacksize, (&attr, stack_size), stack_size);
//关键，这个方法就是c创建线程的方法
    pthread_create_result = pthread_create(&new_pthread,
                                           &attr,
                                           Thread::CreateCallback,
                                           child_thread);
    CHECK_PTHREAD_CALL(pthread_attr_destroy, (&attr), "new thread");

    if (pthread_create_result == 0) {
      // pthread_create started the new thread. The child is now responsible for managing the
      // JNIEnvExt we created.
      // Note: we can't check for tmp_jni_env == nullptr, as that would require synchronization
      //       between the threads.
      child_jni_env_ext.release();
      return;
    }
```
果然是使用了pthread创建了一个新的线程，那么Thread::CreateCallback这个方法估计就是反射获取Java的Thread对象的run方法了，看看有没有什么处理。
下面是反射和运行的关键代码:
```
    // Invoke the 'run' method of our java.lang.Thread.
    mirror::Object* receiver = self->tlsPtr_.opeer;
    jmethodID mid = WellKnownClasses::java_lang_Thread_run;
    ScopedLocalRef<jobject> ref(soa.Env(), soa.AddLocalReference<jobject>(receiver));
    InvokeVirtualOrInterfaceWithJValues(soa, ref.get(), mid, nullptr);
```

看了一下整个start的方法也没有什么值得注意的地方，这样我可以做出如下示意图:
![threadlocal示意图](/images/threadlocal示意图.png)

换句话说,如上图：
thread的本体实际上是由底层pthread create出来的对象，而上面那些thread内部的的参数，实际上还不属于线程的内部数据而是属于哪里new数据就属于哪里，只有在run方法内部的创建的数据才是属于线程内部的数据。而我们的ThreadLocal起效用是因为我们之前在run方法里面Looper.prepare()存入了ThreadLocal。

写一个测试代码:
```
public class MakerThread extends Thread {
	
	private ThreadLocal<String> t = new ThreadLocal<>();
	public MakerThread(String name){
		super(name);
		t.set("aaa");
		
	}
	
	@Override
	public void run() {
		// TODO Auto-generated method stub
		//不断的生产
		try {
			while(true){
				Thread.sleep(1000);
				System.out.println(t.get());
			}
			
		} catch (InterruptedException e) {
			// TODO Auto-generated catch block
			e.printStackTrace();
		}
		
	}
	


}
```

![thread结果图.jpg](/images/thread结果图.jpg)


直接在主线程new一个上面一个thread，在进行start，就出现threadlocal找不到数据。而在run内设置threadlocal就能找到数据。



这样子我就弄明白了handler更加深层次的一些东西了。
