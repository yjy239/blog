---
title: Android 重学系列 Binder的总结
top: false
cover: false
date: 2020-09-06 19:51:51
img:
tag:
description:
categories: Binder
tags:
- Android
- Linux kernel
- Binder
- Android Framework
- 系统调用
---

# 前言
本文实际上是Android 重学系列 Binder驱动相关知识的总结。关于Binder驱动的源码分析我划分出了6部分：
- 1.[Binder驱动的初始化 syscall原理](https://www.jianshu.com/p/ba0a34826b27)
- 2.[Binder驱动的初始化 mmap映射原理](https://www.jianshu.com/p/4399aedb4d42)
- 3.[Binder驱动初始化 Binder的Looper初始化](https://www.jianshu.com/p/2ab3aaf2aeb6)
- 4.[Binder 服务的初始化以及交互原理(上)](https://www.jianshu.com/p/04e53fd86ca2)
- 5.[Binder 服务的初始化以及交互原理(下)](https://www.jianshu.com/p/84b18387992f)
- 6.[Binder 死亡代理](https://www.jianshu.com/p/e22005e5c411)

详细的源码分析最好还是阅读原文，本文只是总结之前欠下的总结文章。

接下来我就按照这6个部分进行总结。时隔一年回来，在看了极客时间的刘超大神的Linux内核专栏之后，我又多了几分感悟，本文将会结合刘超大神的思路一起来总结Binder驱动。

# 正文
先展示一副大家最常见的Binder设计图，也就是罗升阳大神的Binder示意图：
![Binder.png](/images/Binder.png)

包含了4个角色：
- 1.Binder 客户端(本地端)
- 2.Binder服务端(远程端)
- 3.service_manager
- 4.Binder 驱动

能看到在Android系统中，存在一个客户端和服务端。两者之间通过通过Binder驱动进行IPC通信。

Android系统会通过init.rc的解析，从而启动一个service_manager进程，这个进程就是整个Android系统的Binder服务启动核心中心，也是所有Binder服务注册缓存的地方。

整个IPC基础的模型如下图：
![binder IPC基本模型.png](/images/binder IPC基本模型.png)

然而这个过程可能会发生阻塞也可能不发生阻塞，这个就是要Binder进行传输的是否传输一个特殊的flag:FLAG_ONEWAY `0x00000001`，也就是aidl中在方法前设置的oneway标识就不会阻塞等待。我们这边讨论的是阻塞等待的情况，因此，我们隐藏好binder驱动和service_manager，只观察Client和Service之间的关系，则有：
![Binder中service 和 client.png](/images/Binder中service 和 client.png)

实际上在整个Binder驱动通信体系中存在着三种不同的Looper：
- 1.service_manager 的Looper监听来自其他Binder的查询服务。在Looper中主要是提供给其他App进程，那些SystemServer注册在Binder中的服务，如AMS，PMS等等

- 2.当调用Binder时候，构建的阻塞等待循环。

- 3.应用启动初期的Looper，这个Looper主要负责初始化当前应用进程在Binder驱动中的配置。用于接受从服务端返回来的异步消息，以及处理类似`BC_REPLY`等消息，以及死亡代理的回调



接下来，我们从第一个Looper service_manager的初始化查询服务，以及初始化第一个Binder服务的原来开始聊


## Binder的启动

Binder 身为内核模块的一份子，必须通过陷入内核空间才能进行访问，因此我们必须理解Linux的syscall 系统调用是调用的。

原理图如下：
![syscall 工作原理.png](/images/syscall 工作原理.png)

以kill为例子，首先每一个系统调用都有自己的`.S`实现的汇编代码，在这个文件中会通过软中断，查找对应的中断地址。而在内核中会维护一张系统调用的表，在图中为`call.S`.此时对应的中断偏移量就是这种系统调用对应的方法。而这些方法就声明在`syscall.h`中。

此时可以通过这张表所对应的方法指针，找到真正的系统调用的实现，更加具体的图，刘超大神总结的很好：
![系统调用.png](/images/系统调用.png)

可以结合这张图，和我写的[Binder驱动的初始化 syscall原理](https://www.jianshu.com/p/ba0a34826b27)效果更好。


Binder身为驱动，不可避免的需要在系统启动的时候进行初始化，注意这里只是初始化内核模块而不是启动内核模块。

我们在进程初始化之初或者service_manager，就会尝试的打开一个本地文件`/dev/binder`。其实这个文件并不是真的是文件，只是这个驱动程序表现形式是文件罢了。经常看我的文章就知道我经常提到一句话Linux中一切皆为文件，只是这个“文件”很特殊，重写了面向操作系统的`open`,`mmap`等操作。

我们操作Binder驱动本质上是操作一个内存中的一个特殊的file结构体，这个结构体的file_operation(文件操作结构体)重新写成Binder特殊的操作。

### 驱动加载流程

- 1.Linux刚开始通过module_init类似字符设备方式把当前作为dev_t注册到全局的cdev_map。

- 2.module_init是用户态启动时候调用insmod调用加载内核模块。

- 3.就会mknod系统调用，层层查找，找到/dev/xxx如果没有就会创建一个文件，此时这个内存文件inode的i_rdev指向dev_t,这样文件系统就和内核模块关联起来。

- 4.当我们调用这个路径下的open时候，就会找到该内存文件对应inode，也就找到我们binder驱动。驱动本质上是为了屏蔽设备控制器，而这里Binder借助驱动的机制，巧妙的实现了跨进程通信

> 注释：这里面冒出了不少的名词。你可以想象inode实际上是在磁盘中的一个单位节点，关于用户态的启动流程，inode之后在Linux内核专栏会专门解析。

刘超大神也有一副很好的图，展示了整个流程：
![驱动的加载流程.png](/images/驱动的加载流程.png)

### Binder 驱动的示意图

在聊Binder驱动之前，先上一副思维图，先要对Binder驱动中几个核心的对象有印象：
![binder核心成员.png](/images/binder核心成员.png)

- binder_proc 每一个进程都会在binder中映射一个binder_proc对象。并保存到当前进程对应file结构体的私有数据中

- binder_node 是指每一个同进程下的Binder对象，里面记载了binder_proc 和 cookie

- binder_thread 是每一个binder执行的环境，和binder_proc的定位类似。不过当一个进程在不同的线程进行binder通信的时候，binder_thread就是binder运行环境

- free_buffers 是binder 在mmap阶段进行映射的时候，一口气获得的绑定了同一套物理页的(用户空间，内核空间)虚拟内存

- binder_buffer Binder驱动的内核缓冲区，是用于承载和转移数据的

- binder_transaction 当进行传输数据时候，数据，命令的承载体。他持有binder_buffer.

- binder_ref 挂载在binder_proc的`refs_by_node`和`refs_by_desc`两棵树中.他是记录了远端进程对应的句柄，`binder_proc`,`binder_thread`.  前者可以通过binder_node找到binder_ref,后者可以通过句柄`desc`(对应用户空间的`handle`)找到binder_ref


### service_manager 初始化与启动Binder

Binder身为驱动的一份子不可避免也是走这一套流程，module_init 是用户态启动时候调用insmod把dev_t注册到cdev_map；mknod又创建了`/dev/binder`的文件，并且让dev_t和inode的i_rdev关联起来；那么service_manager只剩下一个open的流程，才能正式启动Binder驱动。

而ServiceManager的启动流程可以分为三个步骤：
- 1.open 打开`/dev/binder` 从而调用Binder驱动重写的file_op中的open方法
- 2.ioctl 对binder驱动进行通信，发送BINDER_VERSION命令
- 3.mmap 调用`/dev/binder`  从而调用Binder驱动重写的file_op中的mmap方法(注意参数是MAP_PRIVATE，而不是MAP_SHARE所以内容不会同步到磁盘)
- 4.进入到looper等待，等待其他进程通过Binder通信进来ServiceManager查询Android系统提供的Binder服务。

#### Binder open
在open中如下几件重要的事情：
- 1.通过`kzalloc `为当前调用open的进程分配一个binder_proc结构体
- 2.初始化`binder_proc`中`todo `链表
- 3.初始化binder_proc的`wait` 等待队列头
- 4.初始化`binder_proc`中的双向链表`proc_node ` 添加到静态变量(没初始化的放在BSS，初始化的放在.Data中)`binder_procs `中。
- 5.初始化delivered_death链表，保存那些正在监听目标进程是否死亡的进程队列，一旦死亡了就会执行这个列表中所有进程对应的死亡监听
- 6.把`binder_proc`对象设置到当前file结构体的私有数据中。之后每一次进程通过申请到的file结构体去访问binder驱动时候，就能通过file结构体的私有数据确定当前进程对应的`binder_proc`

关于这一块详细的解析可以阅读我写的https://www.jianshu.com/p/ba0a34826b27

#### Binder ioctl BINDER_VERSION
- 1.初始化`binder_proc`中的`binder_thread`结构体。从`binder_proc`的 `threads`红黑树中查找和当前pid一致的`binder_thread`。
  - 1.1.如果找不到，则生成一个全新的`binder_thread`结构体并初始化`binder_thread`的`todo `队列以及`wait `等待队列，并且绑定`binder_proc`对象和`pid`

注意`binder_proc`和`binder_thread`可以说是Binder驱动执行对应进程事务的环境

- 2.同ioctl BINDER_VERSION从Binder驱动中获取Binder的版本号。


### mmap 原理

在聊Binder的mmap之前，先来总结mmap系统调用做了什么？接下来这段解析，最好先看看我写的Linux内存基础篇章https://www.jianshu.com/p/82b4454697ce。

下面这一幅图：
![mmap映射原理.png](/images/mmap映射原理.png)

记住mmap不仅仅只是可以映射物理内存和虚拟内存之间的关系，还能映射虚拟内存和内存文件之间的关系。

关于Binder相关的mmap原理，具体的源码分析可以阅读https://www.jianshu.com/p/4399aedb4d42

mmap的映射的核心方法为`do_mmap_pgoff `,这里面可以分为如下几个流程：

- 1.get_unmapped_area 检索一个没有进行映射的用户空间虚拟内存区域(32为是0～3G中查找)，注意在Linux内核中分为两种虚拟内存结构体，一个代表用户空间的vm_area_struct，另一个则是代表内核空间的vm_struct.

  - 1.1.get_unmapped_area会判断当前是否是匿名映射，也就是是否把file的内容映射到虚拟内存中。是匿名映射，则从mm_struct的get_unmapped_area方法从的vm_area_struct 红黑树中查找空闲的vm_area_struct对应的区域

  - 1.2.如果是文件映射，则调用文件系统的get_unmapped_area。一般都是讨论ext4虚拟文件系统，在这里面还是调用当前进程的mm_struct的get_unmapped_area方法。

- 2.mmap_region 映射这个新的vm_area_struct虚拟内存区域。首先判断新的vm_area_struct能否和之前的虚拟内存合并起来。

如果不能则通过`kmem_cache_zalloc `生成一个新的`vm_area_struct`。并把`vm_area_struct`和刚才从`get_unmapped_area` 拿到的地址以及映射大小进行绑定。最后把这个`vm_area_struct`绑定到`mm_struct`的红黑树上。

   - 2.1.如果是文件映射，还会调用了文件操作`file_operation`的`mmap`。还记得在上面说过的吗？驱动也是一个特殊的文件，此时就会调用驱动文件的`file_operation`的`mmap`。也就是调用Binder 驱动的`mmap`方法。

  -  2.2.如果是文件映射，当调用了驱动的`mmap`方法后，还会把这个`vm_area_struct`挂载到`file`结构体的`address_space`结构体中的`i_mmap`的红黑树中。这样就`file`结构体记录映射的虚拟内存了。

- 3.如果不是Binder驱动的`mmap`方法，一般的匿名映射在第1和第2步把`vm_area_struct`和虚拟内存地址关联起来了，也就是说虚拟地址和`vm_area_struct`在逻辑上关联起来，并没有真正的申请物理内存。

  - 3.1.当进行访问的时候，就会爆出缺页异常,就进入到中断，调用`do_page_fault`方法中开始分配物理内存，就会调用`__handle_mm_fault` 先进行分配页目录。其中调用了`handle_pte_fault`物理页的绑定，这里分为三种情况：
  - 3.1.如果是匿名映射，`do_anonymous_page`从伙伴系统中分配出物理页面

  - 3.2.如果是文件映射,调用`filemap_fault`查找文件是否有对应的物理内存缓存，有就预读缓存的内存，没有就先分配一个缓存页，接着调用`kmap_atomic`将物理页面临时映射到内核虚拟地址，读取文件到这个缓存页虚拟地址中。

   - 3.3.物理内存如果长时间不用，就会把内容换出到磁盘中。此时就会调用`do_swap_page`方法。先查找swap文件是否存在缓存页，没有则调用`swapin_readahead`从文件中读取生成新的内存页，并通过`mk_pte`生成页表项，插入到页表，接着把文件清理了。整个读取文件的过程还是使用`kmap_atomic`进行映射读取内容。

当然为了加快映射可以使用硬件设备直接缓存虚拟内存和物理内存的映射关系，就不需要想链表一样层层寻找，一步到位。这种硬件成为TLB，快表。

#### Binder mmap
Binder 驱动重写了`mmap`的file_operation，此时mmap就会调用Binder的`mmap`。

按照步骤做了如下几件事：

- 1. 准备内核空间准备内核的虚拟内存 为结构体`vm_area`设置和在用户空间获取到的`vm_area_struct`相同`mmapsize`大小。注意在serviceManager中申请的大小为`128*1024`
  - 1.1.把`vm_area`绑定到`binder_proc`的`binder_buffer`中
  - 1.2.为了快速查找用户空间申请的虚拟内存和内核中申请的虚拟内存，计算出`vm_area`和`vm_area_struct`之间的地址差值，保存到`binder_proc`的`user_buffer_offset `

> 每个进程对应映射区的内核线性区 + user_buffer_offset = 每个进程映射区的用户态线性区

- 2.为`binder_proc`中`binder_buffer`binder内核缓冲区绑定物理页.

  - 2.1.通过kzalloc为`binder_proc-> pages `链表中每一个`page`元素申请大小。binder驱动为当前的用户空间虚拟内存`vm_area_struct`的操作结构体设置一个全新的`binder_vm_ops `.除了close之外，都没做什么事情。相当于屏蔽了一些系统对这段用户空间虚拟内存`vm_area_struct`的默认操作。

  - 2.2.`vm_area_struct-> vm_private_data `保存`binder_proc`结构体

  - 2.3.`binder_update_page_range`在上层函数为数组申请了页框数组的内存，这里就要通过循环，从vm的start开始到end，每隔`4kb`申请一次页框（因为Linux内核中是以`4kb`为一个页框，这样有利于Linux处理简单）。每一次通过`alloc_page`通过伙伴算法去申请物理页面，最后通过`map_vm_area`把`vm_area`（内核空间的线性区）和物理地址真正的绑定起来。根据计算上面总结，我们同时可以计算出每一页对应的用户空间的页面地址多少，并且最后插入到`pagetable`(页表)中管理。


- 3.把`binder_buffer` 插入到`binder_proc`的`free_buffers `红黑树中.来研究研究binder_buffer的构成
```c
struct binder_buffer {
    struct list_head entry; //binder_buffer的链表
    struct rb_node rb_node; //binder_node的红黑树
    unsigned free:1;
    unsigned allow_user_free:1;
    unsigned async_transaction:1;
    unsigned debug_id:29;

    struct binder_transaction *transaction;//binder通信时候的事务

    struct binder_node *target_node;//目标binder实体
    size_t data_size;//数据缓冲区大小
    size_t offsets_size;//元数据区的偏移量
    uint8_t data[0];//指向数据缓冲区的指针
};
```

简单的说，`binder_buffer`可以分为两个部分。一部分是`binder_buffer` 内核缓冲区持有的属性，一部分是`binder_buffer`持有的缓存数据.而数据只记录了指针，所以还需要记录缓冲的数据大小。

因此插入链表，需要计算`binder_buffer`的大小，主要还是计算`binder_buffer`的缓冲数据的大小，可以分为两种情况来讨论，如何查找`binder_buffer`的大小。之所以要查找大小，目的就是为了找到合适的位置插入到`binder_proc->free_buffers`中：

![buffer大小在中间时候的计算.png](/images/buffer大小在中间时候的计算.png)

![buffer大小在末尾时候的计算.png](/images/buffer大小在中间时候的计算.png)

`binder_buffer `的申请内存的核心原理:binder会尝试着从当前的大缓冲区切割一个小的buffer，当可以满足当前内核缓冲区的使用同时，并且能够满足一个binder_buffer的大小，就把当前的这个小的buffer切割下来，放进空闲内核缓冲区中

- 4.保存`vm_area`，以及free_async_space

整个 binder的`mmap`的原理流程可以看成如下：

![binder_mmap原理图.png](/images/binder_mmap原理图.png)

经过系统默认的`mmap`和binder的`mmap`比较。可以发现最大的不同是什么呢？

- 1.系统默认的`mmap`是按需获取物理页。而binder的`mmap`是一旦调用了`mmap`就会绑定物理内存。这么做最大的好处是，加速了binder在后续的通信，特别是Android的应用进程，时时刻刻都需要binder进行通信，一开始就申请好，比起需要使用时候，发生中断再去申请性能体验上更好

- 2.binder的`mmap`需要做到用户空间的虚拟内存和内核申请的内核缓冲区也就是内核的虚拟内存需要一一对应上,把一个物理页同时绑定在用户空间的虚拟内存以及内核空间的虚拟内存中；系统的`mmap`则不需要，系统的`mmap`会根据是`匿名映射`还是`文件映射`都不需要(我们忽略掉换入换出)，前者是通过伙伴系统绑定物理内存，后者则是把文件的缓存读到到文件绑定的`vm_area_struct`的`pages`链表中。

更加详细的解析在:[https://www.jianshu.com/p/4399aedb4d42](https://www.jianshu.com/p/4399aedb4d42) 一文中

#### service_manager 进入到Binder的Looper阻塞等待

service_manager进入到Binder的Looper阻塞可以分为如下几个步骤：

- 1. 调用ioctl系统调用，发送命令BINDER_SET_CONTEXT_MGR到Binder驱动中.
  - 1.1.把service_manager 进程在Binder中申请一个特殊的`binder_node`在全局静态变量`binder_context_mgr_node `中.并把这个`binder_node`插入到`binder_proc->nodes`红黑树中。
  - 1.2.设置`binder_context_mgr_node `的`cookie`和ptr都是0.设置`binder_work`的type为`BINDER_WORK_NODE`
  - 1.3.初始化`binder_node`的异步队列以及`binder_node`中的`binder_work`的`entry`队列
  - 1.4.`binder_node`持有当前为他申请的内存的进程`binder_proc`对象

为什么这么做？因为Android应用经常通过Binder驱动去service_manager中查找，Android提供服务的Binder 服务端对象。因此直接独立出来，当需要查找时候，直接拿到这个对象通信即可。


- 2.service_manager启动消息等待循环 分为如下两个大步骤

  - 2.1.调用ioctl系统调用发送BINDER_WRITE_READ命令，发送`BC_ENTER_LOOPER`数据，不过设置的`read_size`为0，`write_size`为32位。这样就能避免Binder驱动进行读取操作。

    - 2.1.1.通过`get_user `拷贝用户空间传递下来的数据；并在`binder_thread_write ` 方法的switch `BC_ENTER_LOOPER `分支，设置`binder->looper`为`BINDER_LOOPER_STATE_ENTERED ` ；最后通过`copy_to_user `把处理的结果返回给用户

  - 2.2.调用ioctl系统调用发送BINDER_WRITE_READ命令，发送`BC_ENTER_LOOPER`数据。这时候设置了`write_size`为0，`read_size`的为`BC_ENTER_LOOPER`的大小。

    - 2.2.1.此时在`binder_thread_read `会判断`binder_thread->transaction_stack`是否为空和`binder_thread->todo`todo队列中是否有任务消费。如果没有任何事务，binder调用`wait_event_freezable_exclusive `进入到schdule模块，把`binder_proc->wait`进程的等待队列添加到系统中，让出cpu进入休眠。直到有人唤醒，也就是有进程往service_manager进程写入数据，并唤醒。

原理图如下：
![binder驱动在Android service系统初始化.png](/images/binder驱动在Android service系统初始化.png)

更加详细的原理，阅读[https://www.jianshu.com/p/2ab3aaf2aeb6](https://www.jianshu.com/p/2ab3aaf2aeb6)一文

到这里就完成了Android系统的初始化Binder驱动，以及ServiceManager服务。
![binder驱动初始化.png](/images/binder驱动初始化.png)

也就是画红框的区域。解析来让我们来总结App进程初始化，以及App进程是如何和SystemServer进行Binder交互。


## App进程 Binder 服务的初始化第二种Looper


App想要通过Binder驱动和其他App应用或者系统服务，必须自己也要在binder驱动中申请属于自己的`binder_proc`对象，这样才能通过binder驱动中，类似消息队列的机制，把信息跨进程的通信。


### App进程 Binder 服务的初始化

所以进程启动期间调用`RuntimeInit.zygoteInit`的时候，在Binder驱动中通过`ProcessState `进行初始化。注意`ProcessState`是一个单例对象，进程内全局唯一。

#### ProcessState实例化流程
在这个对象的实例化过程中一次执行如下的事情：

- 1.调用open 去初始化Binder 驱动对应的内存文件路径。其行为和service_manager的open一致。主要是实例化一个`binder_proc`在内核中，并添加到`binder_procs `binder的静态属性中

- 2.调用`ioctl` 发送BINDER_VERSION 获得版本号

- 3.调用`ioctl` 发送BINDER_SET_MAX_THREADS 命令，设置`binder_proc->max_threads`属性为15.

- 4.调用`mmap `系统调用，在Binder驱动中映射一段内核虚拟内存和用户空间虚拟内存，并为这段用户空间的虚拟内存绑定物理页。`binder_buffer`直接绑定内核虚拟内存。注意这段映射的大小为`((1 * 1024 * 1024) - sysconf(_SC_PAGE_SIZE) * 2)` 也就是1M - 4kb * 2 = 1016kb。

换句话说，应用进程和service_manager进程映射的大小是完全不同的。其实原因页很简单，service_manager只是负责查询注册在Android系统中的Binder信息，不需要这么的空间。而App进程往往需要传输各种各样的数据，因此需要更大的内存。

注意因为`get_vm_area `申请内核虚拟内存的时候使用的flag是`VM_IOREMAP `,则通过通过ioremap分配的页,将一个IO地址空间映射到内核的虚拟地址空间上去。

#### IPCThreadState实例化流程
当实例化好了`ProcessState`之后，就说明了该进程拥有了通过Binder进行通信的能力，此时还差一个looper，类似service_manager一样的进行消息循环。

- 1.此时会调用`startThreadPool`方法，启动一个`IPCThreadState`对象

注意IPCThreadState 这个对象是线程唯一的，他会保存在线程的本地变量中。其实就是Java编程中ThreadLocal相似的概念。

由此可以得知，每一个线程想要对Binder进行通信，都会先创建一个`IPCThreadState`形成自己的阻塞。

- 2.接着调用`IPCThreadState`的`joinThreadPool`进入到阻塞监听

### IPCThreadState 启动阻塞原理

- 1.IPCThreadState `joinThreadPool`执行的时候就会设置如下命令：
```java
 mOut.writeInt32(isMain ? BC_ENTER_LOOPER : BC_REGISTER_LOOPER);
```
接下来`joinThreadPool`中进行一个无限遍历阻塞监听。
```java
  do {
        processPendingDerefs();
        result = getAndExecuteCommand();

        if(result == TIMED_OUT && !isMain) {
            break;
        }
    } while (result != -ECONNREFUSED && result != -EBADF);
```
在getAndExecuteCommand中会执行`talkWithDriver`方法，执行系统调用`ioctl`发送命令`BINDER_WRITE_READ`告诉Binder驱动，当前App进程的Looper也初始化好了，Binder中对应的`binder_proc`的`binder_thread`的`loop`也可以设置为`BINDER_LOOPER_STATE_ENTERED `

而这个过程和service_manager不同，因为service_manager是阻塞了整个进程,只需要等到有人向他查询是否在Binder中存在这么一个服务才会继续运行。这里当然不可能阻塞整个进程，不然我们的app该怎么继续初始化后运行。

到这里就完成了App进程接受Binder驱动信息的Looper的初始化，直到等到Binder驱动返回了`BC_ENTER_LOOPER`的消息的处理结果。

整个流程图可以如下：
![应用启动时启动的Binder初始化.jpg](/images/应用启动时启动的Binder初始化.jpg)

在这里构建好的Looper，做的事情实际上就是为了处理aidl模块。不过aidl的通信前提是必须要从`service_manager`进程查询到对应的IBinder服务，才能进行通信。因此先来IPCThreadState 通信到Binder驱动的流程。


#### IPCThreadState交互原理

整个流程如下图：
![binder数据交互时序图.png](/images/binder数据交互时序图.png)

我们就以ServiceManagerNative 注册一个AMS服务到service_manager中。

注意在Android系统中有三中ServiceManager，很多人容易搞混：
- service_manager是指 一个独立的进程，里面保存了SystemServer或者其他应用开放给Android系统的Binder 服务
- ServiceManager 是指在SystemServer中用于统一管理的服务
- 还有一个是位于App进程的Context中SystemServiceRegistry对象，这个对象保存了每一个Android的Binder服务的代理类。如AMS对应ActivityManager。

先获取当前的目标进程也就是Binder服务端的句柄,调用`getStrongProxyForHandle `方法，`lookupHandleLocked `从本地中查找是否存在对应的`IBinder`对象，找不到且句柄刚好是`0`说明是向service_manager通信，此时就会进行调用：
```java
IPCThreadState::self()->transact(
                        0, IBinder::PING_TRANSACTION, data, NULL, 0);
```


当Binder需要发送消息的时候，就会调用`IPCThreadState`的`self`方法获得当前线程中`IPCThreadState`实例，并调用`transact`方法，往Binder通信。其中的核心方法还是`waitForResponse `方法，
整个`transact`通信流程大致可以分为如下几个步骤：

- 1.`writeTransactionData` 在Parcel中构造第一段数据`BC_TRANSACTION `命令的`binder_transaction_data`数据，命令内容如下：
  - 1.1.cmd：BC_TRANSACTION
  - 1.2.tr ： binder_transaction_data
  - 1.3.code: IBinder::PING_TRANSACTION

- 2. `waitForResponse` 中会构造一个Looper 调用`talkWithDriver `方法，不断的等待Binder处理完事务后的结果：
```cpp
    while (1) {
        if ((err=talkWithDriver()) < NO_ERROR) break;
        err = mIn.errorCheck();
        if (err < NO_ERROR) break;
        if (mIn.dataAvail() == 0) continue;
```

- 3.`talkWithDriver ` 会继续往Parcel写入第二段数据，保存到`binder_write_read `的`buffer`属性中 ，并记录其写入的长度。最后通过`ioctl `发送命令`BINDER_WRITE_READ ` 把数据传入到底层。注意这个发送过程也是一个循环遍历，知道发送成功，或者Binder返回了非`-EINTR`的异常信号才会退出。
```cpp
    do {
#if defined(__ANDROID__)
        if (ioctl(mProcess->mDriverFD, BINDER_WRITE_READ, &bwr) >= 0)
            err = NO_ERROR;
        else
            err = -errno;
#else
        err = INVALID_OPERATION;
#endif
        if (mProcess->mDriverFD <= 0) {
            err = -EBADF;
        }

    } while (err == -EINTR);
```

所以此时发送到Binder驱动中的数据结构如下：
![用户空间传递到Binder驱动的数据封装.jpg](/images/用户空间传递到Binder驱动的数据封装.jpg)



- 4.由于此时需要同步接受数据：
```java
    if (doReceive && needRead) {
        bwr.read_size = mIn.dataCapacity();
        bwr.read_buffer = (uintptr_t)mIn.data();
    } else {
        bwr.read_size = 0;
        bwr.read_buffer = 0;
    }
```
`binder_write_read`中设置了读取的大小以及读取对应的Parcel数据块，因此当在binder驱动调用完`binder_thread_write`后就会调用`binder_thread_read`阻塞住整个流程。

到这里，就构建出了第三种Looper，这个Looper是为了处理`IPCThreadState`调用 `self`方法直接通信，并阻塞等待Binder‘服务端处理后的结果。


#### Binder通信流程

整个流程，我们可以分开两个部分来看，一个是Binder的客户端，一个是Binder的服务端。

我们就以1个例子来解释整个通信流程：
- 1.App进程通过`service_manager`查询AMS服务为例子。

此时Binder客户端就是App进程，Binder的服务端就是指service_manager进程。

#### App进程查询AMS服务
在这里我分为客户端和服务端两端来总结：

##### App进程 Binder客户端发送向Binder 服务管理者通信请求查询Binder 服务对应的IBinder

在这个过程就会把上面封装好的`binder_write_read `结构体通信到Binder驱动中，Binder驱动必定会进行解包处理。由于此时只有写入的内容，我们只需要关注写入的`binder_thread_write`的逻辑，这里一次做了如下的事情：

- 1.首先获取`binder_write_read`中的`write_buffer`内容，在这里也就是`binder_transaction_data` 事务数据结构体。

- 2.解析结构体中的cmd 为`BC_TRANSACTION `，则执行`binder_transaction `处理客户端传递过来的事务。

- 3.接着判断cmd是否是`BC_REPLY `，是则说明这个事务是从服务端传递过来，处理完事务的返回消息。由于是发送，则判断`binder_transaction_data`中需要通信的Binder服务端的`handle`句柄。此时是`0`，设置为默认的`binder_context_mgr_node ` 此时就直接找到存放在全局的静态变量，代表`service_manager`的`binder_node`对象。也就找到接下来需要通信的`Binder`服务端是什么了。

- 4.通过需要通信的Binder服务端对应的`binder_node`中获取到`binder_proc`对象。

- 5.遍历当前Binder客户端 也就是App的`binder_proc`的`binder_thread`中的`transaction_stack` 事务处理栈。准备构建`binder_transaction`结构体，通信到Binder服务端，在这里就是`service_manager`.

  - 5.1.如果发现这个堆栈有事务，说明当前进程的其他线程有正在执行的`binder`通信任务，并且查找通信的目标，和本次通信的目标是一致的。说明Binder服务端可能在处理Binder通信的事务正准备返回呢？

  - 5.2.当没有任务事务依赖，双方都是第一次通信，另一个第一次接受。此时会给`binder_transaction->from`设置为当前Binder 客户端的`binder_thread`.更加复杂的场景下，客户端和服务端可能正在通信，因此会为把目标的`target_thread` 设置为上一个正在通信到Binder客户端的`binder_thread`. 通过这种方式设置每一个事务的依赖。

- 6.为`binder_work `和`binder_transaction`结构体申请一段内核的内存.

- 7.`binder_transaction` 记录下目标通信的Binder服务端对应的`binder_proc`,`binder_thread`;从IPCThreadState传下来的`binder_transaction_data`的`code`,`flag`;

  - 7.1.通过`binder_alloc_buf `方法为`binder_transaction-> buffer `(也就是`binder_buffer`)申请一段内存。`binder_buffer`的`transaction`指向当前的`binder_transaction`以及保存了Binder服务端的`binder_node`.把`binder_transaction_data->data.ptr.buffer` 也就是IPCThreadState用于缓冲的数据段，拷贝到`binder_buffer->data`。

  - 7.2.获取`binder_transaction_data-> data.ptr.offsets`这个偏移量实际上指向的是`flat_binder_obj`.这个对象代表了Binder服务端或者客户端在用户空间的中压缩数据的表示,如果是本进程的binder对象在这个结构体里面就保存了指针，如果是另一个进程的Binder 服务端就是一个`handle`句柄。如果是本地对象`cookie`保存的是在内核中对应`binder_node`在`binder_proc->nodes`红黑树中的位置。
```cpp
struct flat_binder_object {
    /* 8 bytes for large_flat_header. */
    __u32       type;
    __u32       flags;

    /* 8 bytes of data. */
    union {
        binder_uintptr_t    binder; /* local object */
        __u32           handle; /* remote object */
    };

    /* extra data associated with local object */
    binder_uintptr_t    cookie;
};
```

- 8.通过`binder_transaction_data-> data.ptr.offsets` 获取到`flat_binder_object`。接下来就根据`flat_binder_object->type`的Binder类型进行相应的处理：



| BINDER_TYPE             | 意义                             | 处理方式                                                                                                                                                                                                                                                                                                                                          |
| ----------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BINDER_TYPE_BINDER      | 传输的是本地Binder对象           | 通过`cookie`和`binder_proc`寻找`binder_node`,找不到则根据`flat_binder_object->cookie`和`flat_binder_object->binder `生成新的`binder_node`,根据`binder_get_ref_for_node`寻找或者生成新的`binder_ref`，把`flat_binder_object->type`转化成`BINDER_TYPE_HANDLE `,并在`flat_binder_object->handle`保存`binder_ref->desc`                               |
| BINDER_TYPE_WEAK_BINDER | 传输的是本地Binder对象弱引用     | 通过`cookie`和`binder_proc`寻找`binder_node`,找不到则根据`flat_binder_object->cookie`和`flat_binder_object->binder `生成新的`binder_node`,根据`binder_get_ref_for_node`寻找或者生成新的`binder_ref`，把`flat_binder_object->type`转化成`BINDER_TYPE_WEAK_HANDLE `,并在`flat_binder_object->handle`保存`binder_ref->desc`                          |
| BINDER_TYPE_HANDLE      | 传输的是远程Binder对象句柄       | 通过`binder_get_ref `从`binder_proc->refs_by_desc`找到对应的`binder_ref `对象，如果`binder_ref`对应的`binder_node`刚好是Binder服务端的`binder_node`，则把`flat_binder_object->type`转化为 `BINDER_TYPE_BINDER`;否则则从`binder_get_ref_for_node `获取到另一个Binder服务端的`binder_node`,`flat_binder_object->handle`保存`binder_ref->desc`       |
| BINDER_TYPE_WEAK_HANDLE | 传输的是远程Binder对象句柄弱引用 | 通过`binder_get_ref `从`binder_proc->refs_by_desc`找到对应的`binder_ref `对象，如果`binder_ref`对应的`binder_node`刚好是Binder服务端的`binder_node`，则把`flat_binder_object->type`转化为 `BINDER_TYPE_WEAK_BINDER `;否则则从`binder_get_ref_for_node `获取到另一个Binder服务端的`binder_node`,`flat_binder_object->handle`保存`binder_ref->desc` |
| BINDER_TYPE_FD          | 传输的是文件                     | 暂时不做事情                                                                                                                                                                                                                                                                                                                                      |

在这里面出现了一个很重要的数据结构`binder_ref`。这是Binder从本地端往远程端转化的核心。

总结下来如图：
![binder对象传送过程.png](/images/binder对象传送过程.png)

根据是否和Binder 服务端管理端是同一个进程，是否和客户端进程是同一个进程,从而诞生了三种返回。

这一段的逻辑主要是进行Binder对象的返回。之所以我在原文里面不喜欢说Binder客户端和服务端，只说本地端和远程端也是基于这种考虑。他们之间其实并没有很明确的区分界限，Binder的客户端也可以当服务端，Binder的服务端可以当客户端。这里的Binder 服务端不仅仅只是指Android系统中的Binder服务，还可以是Service在onBind返回的Binder对象的服务，也可以是RePlugin中通过ContentProvider管理并返回的Binder的服务。


- 8.把`binder_transaction t`中的`binder_work`添加到目标`binder_proc`或者`binder_thread`的`todo`队列中.设置`binder_work- >type`为`BINDER_WORK_TRANSACTION `
当然这个过程中，如果没有事务依赖也不是Binder服务端处理完事务后返回，`binder_thread`则为null，会设置到`binder_proc->todo`

- 9.把当前`binder_thread`中`transaction_stack `设置为`binder_transaction`，并把当前的`binder_transaction`设置到`binder_transaction t`的`from_parent`这个`binder_transaction`链表

- 10.除了`binder_transaction`之中存在一个`binder_work`之外，这个过程也构造名字为`to_complete`的`binder_work`，这个`binder_work`的type设置为`BINDER_WORK_TRANSACTION_COMPLETE `，加入到当前进程对应的`binder_proc`的`binder_thread`的`todo`队列

- 11.通过`wake_up_interruptible `唤醒目标进程的等待队列


代入App发送一个命令，往service_manager查询服务的场景。这个时候，首先往`service_manager`中传入空的数据，但是命令为`BC_TRANSACTION`.由于`handle`默认是0，就直接拿到了`service_manager`对应的`binder_node`,也就拿到了`binder_node`中进程相关的信息`binder_proc`。并往`service_manager`的`binder_proc->todo`中添加一个` binder-work`工作事务。在这个` binder_work`中的内核缓冲区，保存好了数据，等待`service_manager`读取。


##### Binder 服务管理者到查询Binder 服务后返回给App进程

当唤醒了`service_manager`，就会解除`binder_thread_read`的阻塞。下面分为如下几步，处理完后到`service_manager`进程中处理

首先是一个while的循环，不断的从当前进程的`service_manager` `binder_thread`和`binder_proc`的`todo`队列中获取`binder_work` 事务进行消费。

- 1.检查出`binder_work- >type`为`BINDER_WORK_TRANSACTION `，则取出其中的`binder_transaction `。

- 2.把传递过来的`binder_transaction `中的`binder_node`中的`cookie`和`ptr`都拷贝到`binder_transaction `的`cookie`和`ptr`，并把命令转化为`binder_transaction `中的命令从`BC_TRANSACTION `转化为`BR_TRANSACTION `

- 3.把解析出来的`binder_transaction`的`to_parent`保存了当前Binder服务端的`transaction_stack`,以及`to_thread`设置为当前Binder服务端的`binder_thread`

- 4.把`binder_transaction `设置为Binder服务的`binder_thread->transaction_stack`.并数据拷贝回用户空间并返回。


##### Binder服务管理器 查询服务
此时管理Binder 众多服务的是`service_manager`进程，此时就会解开`binder_loop`的死循环，进入到binder_parse中解析从Binder 驱动回调的命令。

在`BR_TRANSACTION `的分支中，会再度解析存在`binder_transaction_data`的code。

还记得，当进程第一次Binder通信时候，就会发送code就是`PING_TRANSACTION`的binder通信。所以每一个进程必定在Binder驱动中有属于自己的`binder_node`,这么做的目的很简单，就是为了保证了Binder的客户端和service_manager进程都存活。

那么当App进程向service_manager查询AMS服务，和AMS诞生时候添加的服务又是如何的？实际上整个过程变化的只有`binder_transaction_data`的code：

- ADD_SERVICE_TRANSACTION 对应 SVC_MGR_ADD_SERVICE代表Binder服务初始化完成进行注册
- SVC_MGR_GET_SERVICE 代表App进程查询服务

注意在`service_manager`进程中，保存就是`binder_ref` 对应的desc 句柄。

当完成了这些之后，就会调用`binder_send_reply `方法，把`BC_FREE_BUFFER `,`BC_REPLY `两个命令压缩到一起发送到binder驱动中,通过`ioctl`的`BINDER_WRITE_READ`命令写回Binder驱动。

#### Binder服务管理器 根据句柄返回Binder驱动的Binder对象

- `BC_FREE_BUFFER` 释放了`binder_proc`中`binder_buffer`的内核缓冲区。注意这里的`binder_buffer`实际上是指写入时候的`binder_transaction_data->data.ptr.buffer`内核缓冲区

- `BC_REPLY ` 执行的流程和`BC_TRANSACTION `分支重合。不同点在于，如下：


- 1.在service_manager读取的最后一个步骤，把`binder_thread`的`transaction_stack`设置为从App进程获取到的`binder_transaction`,此时就能很简单的知道，需要返回的Binder客户端是什么
```cpp
if (reply) {
        in_reply_to = thread->transaction_stack;
...
        binder_set_nice(in_reply_to->saved_priority);
...
        thread->transaction_stack = in_reply_to->to_parent;
        target_thread = in_reply_to->from;
...
        target_proc = target_thread->proc;
    }
```
这里面包含了Binder客户端的`binder_thread`和`binder_proc`.

- 2.经过Binder 通过句柄`handle`转化后，就能获得了`flat_binder_obj`。这里面要么存在着远程端的句柄，要么就存在着对应在Binder客户端`cookie`

- 3.继续重复发送Binder消息一小节的的步骤，添加一个`binder_transaction`到`binder_proc`或者`binder_thread`的todo队列中，打开Binder客户端的也就是App进程的阻塞，执行`binder_thread_read`方法。

图解整个流程如下：
![发送数据.png](/images/发送数据.png)



第二部分是返回消息在清除binder_transaction_stack之前：
![返回消息在清除binder_transaction_stack.png](/images/返回消息在清除binder_transaction_stack.png)

第三部分：
![binder传输原理.png](/images/binder传输原理.png)


从这里面可以得知，为什么说Binder驱动只是进行了一次拷贝。这个拷贝不是我们常说的拷贝，而是特指两个进程之间需要同步物理内存所需要的拷贝次数。

检查整个过程就是，为`binder_work`中的`binder_buffer`申请缓存并缓存好需要传输的`binder_transaction`.每一次进行数据传输，实际上就是在共享`binder_transaction`对应的`binder_buffer`内存缓冲区。

而这个`binder_buffer`实际上就是在`binder_mmap`阶段一口气申请出来的大内存切割出来的。而这个大内存是通过`binder_page_update_range`把一个物理页同时绑定在用户空间的虚拟内存以及内核空间的虚拟内存中。

这种方式下，访问了用户空间的虚拟内存就是访问了用户空间的虚拟内存。那么相对的Binder客户端和Binder服务端，都有一个虚拟内存映射到内核中。

因此当从虚拟内存从内核空间往用户空间，或者用户空间往内核转移时候不会有任何的中转站。

真正发生物理页拷贝的是Binder客户端读取数据拷贝到`binder_transaction`，以及`binder_transaction`需要从内核拷贝到Binder服务端的用户空间中。

当然常说的一次拷贝是忽略了前者的拷贝，也就是忽略了内核中的拷贝次数，而只关注进程切换内核态和用户态的过程中需要获得数据的后者步骤。

在这个过程中，也不是一口气拷贝`binder_transaction`下来，而是分段拷贝。单次通信有6次小拷贝，但是一个Binder通信的完成需要一个来回，因此需要12次小来回。

最后再来看看整个Binder 在内核中的数据传输封包

![binder传输数据的封包.png](/images/binder传输数据的封包.png)

 关于这里的详情可以看[https://www.jianshu.com/p/04e53fd86ca2](https://www.jianshu.com/p/04e53fd86ca2)


### AIDL与Java层的交互
先来看看面向Java的UML图
![binder类依赖图.png](/images/binder类依赖图.png)

从图中可以看到，有几个很关键的类：
- 1.BBinder 是native层的Binder对象，他是一个真正持有对应binder驱动下`binder_node`的cookie对象
- 2.JavaBBinder 是BBinder的派生类，每当消息来了就会反射Binder的onTransact方法
- 3.Binder  java层代表本进程中对应的Binder类，他持有了JavaBBinder
- 4.BpBinder 是native层的代表远端进程的Binder对象类，持有了远端进程的句柄`handle`
- 2.BinderProxy java层代表远端进程的Binder类,持有了BpBinder

换句话说，整个流程实际上就是Binder客户端的Java层调用BinderProxy类调用transact 方法后，就会反射到aidl的Binder服务端的Binder类中的onTransact执行解析以及业务处理。

最后来看看状态转移：
![binder握手通信.png](/images/binder握手通信.png)

关于这一块的内容可以阅读[https://www.jianshu.com/p/84b18387992f](https://www.jianshu.com/p/84b18387992f)里面有更详细对aidl的解析。

Binder整个过程用一个示意图来表示如下：
![binder整体模型.png](/images/binder整体模型.png)


### binder 的死亡代理

下面是linkToDeath时序图：
![binder 注册死亡代理.png](/images/binder 注册死亡代理.png)


下面是当App进程时候的死亡回调时序图
![binder死亡唤起死亡注册的回调.png](/images/binder死亡唤起死亡注册的回调.png)
注意：红色线代表了跨进程


更多的请阅读[https://www.jianshu.com/p/e22005e5c411](https://www.jianshu.com/p/e22005e5c411)里面包含了关于死亡代理的详细内容。


## 后话
写这篇文章主要还是为了对之前Binder的回顾，希望有对这6篇文章对总结，加上这几年看了更多的Linux内核的源码有了更加深刻的认识。

























