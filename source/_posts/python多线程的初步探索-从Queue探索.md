---
title: python多线程的初步探索(从Queue探索)
top: false
cover: false
date: 2018-06-24 12:02:33
img:
tag:
description:
author: yjy239
summary:
tags:
- python
---
### 前言
自学了快4天的python。有些东西还是需要自己记录一下，故此写下该随笔。

在学习python的时候，编写多线程的时候，顺手写一个经典的消费者和生产者模式时候。发现一个有趣的东西。在Java中我往往需要wait或者调用lock的方法去等待生产者生产一个数据，消费者再去消费。

### 目标
目标是通过学习python3的queue的线程机制来加深对python多线程编程的理解

### 序
如果学习过java的老兄弟可以看看，java的多线程的消费者生产者模式。不熟悉Java就跳过不看也行。
生产者：
```
/*
生产者
*/
public class MakerThread extends Thread {
	
	private final Table table;
	private int id = 0;
	private volatile boolean shutdown = false;
	public MakerThread(Table table,String name){
		super(name);
		this.table = table;
	
		
	}
	
	@Override
	public void run() {
		// TODO Auto-generated method stub
		//临界区
		try {
			while(!shutdown){
//				Thread.sleep(1000);
				String cake = "["+"No."+nextid()+"by"+Thread.currentThread().getName()+"]";
				table.put(cake);
			}
			
		} catch (Exception e) {
			// TODO Auto-generated catch block
			e.printStackTrace();
		}finally {
			doShutDown();
		}
		
	}
	
	private int nextid(){
		return id++;
	}
	
	
	public boolean isInterrupted(){
		return shutdown;
	}
	
	//终止
	public void doShutDown(){
		System.out.println("doShutDown:"+Thread.currentThread().getName());
	}	
	
	public void shutdown(){
		shutdown = true;
		interrupt();
	}

}
```

消费者：
```
//消费者
public class EatThread extends Thread {
	
	private final Table table;
	private int id = 0;
	private volatile boolean shutdown = false;
	
	public EatThread(Table table,String name){
		super(name);
		this.table = table;
	}
	
	@Override
	public void run() {
		// TODO Auto-generated method stub
		
		try {
			while(!shutdown){
				String take = table.get();
				System.out.println("eating"+take);
				Thread.sleep(1000);
				
			}
		} catch (InterruptedException e) {
			// TODO: handle exception
		}finally {
			doShutDown();
		}
	}
	
	public boolean isInterrupted(){
		return shutdown;
	}
	
	//终止
	public void doShutDown(){
		System.out.println("doShutDown:"+Thread.currentThread().getName());
	}	
	
	public void shutdown(){
		shutdown = true;
		interrupt();
	}

}
```

Table：
```
public class Table {
	private String[] buffers;
	private int tail; //队列的尾部
	private int head; //队列的头部
	private int count; //当前的队列的数量
	
	public Table(int count){
		buffers = new String[count];
		this.head = 0;
		tail = 0;
		count = 0;
	}
	
	public synchronized void put(String cake){
		System.out.println(Thread.currentThread().getName()+" put "+cake);
		while(count >= buffers.length){
			try {
				wait();
			} catch (InterruptedException e) {
				// TODO Auto-generated catch block
				e.printStackTrace();
			}
		}
		buffers[tail] = cake;
		tail = (tail+1)%buffers.length;
		count++;
		notifyAll();
	}
	
	
	public synchronized String get(){
		while(count <= 0){
			try {
				wait();
			} catch (InterruptedException e) {
				// TODO Auto-generated catch block
				e.printStackTrace();
			}
		}
		String cake = buffers[head];
		head = (head+1)%buffers.length;
		count--;
//		System.out.println(Thread.currentThread().getName()+" get "+cake);
		notifyAll();
		return cake;
		
		
	}
}
```

熟悉java的兄弟大致上也明白了，我的思路是什么。生产者不断通过put方法，把生产的数据放入数组中，如果大于最大的数组上限，生产者等待消费者消耗。消费者不断的检测数组中的数据数量是否大于0，小于等于则线程等待知道大于0，大于则取出。

OK，不要喧宾夺主了。这一次的主题还是Python。

### 正文
让我来写一个Python的消费者-生产吧。由于python是一种脚本语言，故此这一次为了方便阅读，我全部写到了文件里面。
```
from threading import Thread,current_thread
import time
import random
from queue import Queue

queue = Queue(5)

class ProducerThread(Thread):
    def run(self):
        name = current_thread().getName()
        nums = range(100)
        global queue
        while True:
            num = random.choice(nums)
            queue.put(num)
            print('生产 %s 生产了数据 %s' % (name, num))
            t = random.randint(1, 3)
            time.sleep(t)
            print('生产者%s 睡眠了 %s 秒' % (name, t))


class ConsumerThread(Thread):
    def run(self):
        name = current_thread().getName()
        global queue
        while True:
            num = queue.get()
            queue.task_done()
            print('消费者 %s 消耗了数据 %s' % (name, num))
            t = random.randint(1,5)
            time.sleep(t)
            print('消费者 %s 睡眠了 %d' % (name, t))


p1 = ProducerThread(name='p1')
c1 = ConsumerThread(name='c1')
c2 = ConsumerThread(name='c2')

p1.start()
c1.start()
c2.start()
```

这就是python 的消费者生产者模式的写法。确实简便了很多，当然这也是和语言设计者本身对语言本身的定位有关，这里就不多做评述了。

如果学过java的朋友一定会发现java和python除了语法不同之外。实际上思路上大体一致的。

让我稍微比较一下两者之间的关联。在变化中找不变：
同样的java和python都是需要有一个while的循环，一个是不断取出，一个是不断的生产。
java的生产者：
```
@Override
    public void run() {
        // TODO Auto-generated method stub
        //临界区
        try {
            while(!shutdown){
//              Thread.sleep(1000);
                String cake = "["+"No."+nextid()+"by"+Thread.currentThread().getName()+"]";
                table.put(cake);
            }
            
        } catch (Exception e) {
            // TODO Auto-generated catch block
            e.printStackTrace();
        }finally {
            doShutDown();
        }
        
    }
```

python的生产者：
```
 while True:
            num = random.choice(nums)
            queue.put(num)
            print('生产 %s 生产了数据 %s' % (name, num))
            t = random.randint(1, 3)
            time.sleep(t)
            print('生产者%s 睡眠了 %s 秒' % (name, t))
```
发现两者都是put进到队列里面。奇怪的是为什么python为什么不需要对临界区进行判断。毕竟在queue初始化的时候，我设定Queue的容量为5，如果不做临界区的判断处理，可能会造成queue出现更多的情况而报错。那么按照归纳推理法，queue一定做了线程同步的处理。

再看看消费者的呢？
Java:
```
    @Override
    public void run() {
        // TODO Auto-generated method stub
        
        try {
            while(!shutdown){
                String take = table.get();
                System.out.println("eating"+take);
                Thread.sleep(1000);
                
            }
        } catch (InterruptedException e) {
            // TODO: handle exception
        }finally {
            doShutDown();
        }
    }
```

Python:
```
while True:
            num = queue.get()
            queue.task_done()
            print('消费者 %s 消耗了数据 %s' % (name, num))
            t = random.randint(1,5)
            time.sleep(t)
            print('消费者 %s 睡眠了 %d' % (name, t))
```
python，同理取出似乎没有看见什么同步的内容。那么一定是queue在底层做了处理。那么就让我一探究竟吧。

老规矩，我这一次的源码是python3.6，Queue的源码。先看看Queue的类的初始方法：
```
    def __init__(self, maxsize=0):
        self.maxsize = maxsize
        self._init(maxsize)

        # mutex must be held whenever the queue is mutating.  All methods
        # that acquire mutex must release it before returning.  mutex
        # is shared between the three conditions, so acquiring and
        # releasing the conditions also acquires and releases mutex.
        self.mutex = threading.Lock()

        # Notify not_empty whenever an item is added to the queue; a
        # thread waiting to get is notified then.
        self.not_empty = threading.Condition(self.mutex)

        # Notify not_full whenever an item is removed from the queue;
        # a thread waiting to put is notified then.
        self.not_full = threading.Condition(self.mutex)

        # Notify all_tasks_done whenever the number of unfinished tasks
        # drops to zero; thread waiting to join() is notified to resume
        self.all_tasks_done = threading.Condition(self.mutex)
        self.unfinished_tasks = 0
```
看到这里我想起了c中的条件变量。几乎和C的条件变量用法一致。C这一块的这个之后有机会再聊。不过用法和pthread的用法如此接近。我大概可以推理出python的条件变量的用法。

如果我只关注数据取入取出这一块的线程同步，我可以把Queue的整个代码思路简化下来就是这个模样

```
class Queue:
    def __init__(self, length):
        self.length = length
        self.mutex = Lock()
        self.condition = Condition(self.mutex)

    def put(self, name):
        # 给整个想要上锁的代码块上锁
        self.condition.acquire()

        # 临界区，设定该queue 大小不能超过5，超过则线程等待
        while self.length >= 5:
            self.condition.wait()

        self.length += 1
        print('%s 放入了数据 长度：%s' % (name, self.length))
        # 一旦放入了数据，则唤醒其他线程
        self.condition.notify()
        # 解锁
        self.condition.release()

    def get(self, name):
        # 给整个想要上锁的代码块上锁
        self.condition.acquire()

        # 临界区，设定该queue 大小不能小于0，超过则线程等待
        while self.length <= 0:
            self.condition.wait()

        self.length -= 1
        print('%s 取出了数据 长度：%s' % (name, self.length))
        # 一旦放入了数据，则唤醒其他线程
        self.condition.notify()
        # 解锁
        self.condition.release()
```

结果很明显：
![简化Queue的结果](/images/简化Queue的结果.png)

当然Queue的做的事情更多，我这边只是为了把逻辑理清楚，才把代码简化到这种程度。

这里就联动一下C语言中的条件变量，稍微解释一下上面这些函数所代表的含义。

threading.Lock() 是创建一个加锁对象。在这个Queue里面只有唯一一个加锁对象，目的就是为了每一次一个线程访问这个Queue对象的时候唯一获取一个对象，当其他线程想要访问的时候，发现获取不到这个对象将会站在线程之外尝试获取这个对象。

当然单单创建一个锁是不够的。我们要需要给这个锁做上锁，解锁的动作。
这个时候我们可以直接调用self.mutex这个对自己想要上锁的代码块上锁和解锁的动作。

而threading.Condition顾名思义就是条件变量，是主要是为了控制外部引入的锁，作为条件变量来控制什么时候解锁，加锁。

都明白了，那么 self.condition.wait() 意思就是当不满足这个条件的时候，将会让该线程进行等待。

具体为什么这么设计，这里就稍微涉及到前两篇的多线程设计模式了。这就不多赘述了。

那么Java有Condition,Lock吗？有加锁对象吗？当然有。只是我们经常使用synchronized，而很少使用Lock和Condition的应用。

就算常见的synchronized加锁代码块的时候：
```
synchronized (MainActivity.class){
            
}
```
这个括号里面的内容，就是加锁的对象。加锁的对象是这个程序里面唯一的MainActivity.class class对象。我记得一个印象很深的可笑场景，就在去年，某个同时写后端，突然说为什么我加锁没有成功，其他线程老是能访问到对象呢？我一看，发现这个括号里面加锁的对象，是程序每一次进来都new一次。

这造成了什么结果，这就导致，每一次加锁的对象都是新的对象。换个形象的说法来说，就是每一次都在这个资源上，新开了一道门，自己加上锁访问之后把锁解开。

有点意思，看来大部分的语言对锁的理解和操作都是大多相似的。同理OC中也有这种类似的操作。这里就不多赘述了。

### 结束语
其实我们可以思考一下，为什么绝大多数的语言对多线程的操作如此相似呢？我们大学学过了计算机组成原理和计算机导论，我记得里面大概的意思，多线程的实现其实是依赖于机器底层对多时间并发的处理，要么是抢占式的线程，要么是协作式的线程。这就要看我们的系统，我们的机器选择的策略了。











