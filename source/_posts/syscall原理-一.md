---
title: Android 重学系列 Binder驱动的初始化 syscall原理
top: false
cover: false
date: 2019-05-02 15:49:06
img:
description:
author: yjy239
summary:
categories: Binder
tags:
- Android
- Linux kernel
- Binder
- Android Framework
- 系统调用
---

# 背景
聊完前面的红黑树算法，让我复习，学习Binder驱动的内容。Binder可以说是整个Android系统中最为常用的进程间通讯。无论是AMS，WMS，PMS，几乎所有的Android核心服务都通过Binder向四面八方的应用通信。可以说是理解Android系统最为重要的一环。Binder涉及的面虽然十分的广，我也不能完全百分百读透，但是对于我来说这是必须经历，必须明白的知识点。因此，我也尝试来写写Binder的理解。

如果遇到问题请到本人：[https://www.jianshu.com/p/ba0a34826b27](https://www.jianshu.com/p/ba0a34826b27)

从本篇开始，binder的源码出自andoroid 9.0。本系列将分为6个章节，从Binder驱动的初始化，Binder的本地端注册，Binder交互原理，Binder注册死亡代理来分析这四个方面来分析


# 正文
在说明Binder之前。我们来想想Binder作为一个进程间通信的通道之前。我们常用的进程间通信有几种。

Linux中，我们常见有一下几种进程间通信：
- 1.pipe 管道
- 2.FIFO named pipe 有名管道
- 3.signal 信号
- 4.消息队列
- 5. socket 套子节
- 6. SharedMemory 共享内存

这其中都分别做了什么事情呢？为此我分别翻阅这些源码，过了一遍这些思路以及用法。

#### 用户空间(用户态)和内核空间(内核态)
在这之前先来理解一下，linux中用户空间(用户态)和内核空间(内核态)的区别。

> 一些操作系统允许所有用户与硬件做交互。但是，类unix操作系统在用户应用程序钱把计算机物理组织相关的底层细节都隐藏起来。当程序想试用硬件资源时候，必须向操作系统发出请求。内核会对这个请求做评估，允许使用，那么内核将会代表应用与硬件交互。
为了实现这个机制，现代操作系统依赖特殊硬件特性来禁止用户程序直接与底层打交道，或者直接访问任意的物理地址。硬件为cpu引入了至少两种执行模式：用户的非特权模式和内核的特权模式。也就是我们常说的用户态和内核态。

这是来自深入理解Linux一书中的定义。举个简单的例子，当我们需要运行文件操作的时候，使用open等操作方法，就会从用户程序就会从用户态进入到内核态，当open结束之后，用户程序进入回到用户态。

为什么Linux系统要这么设计。最大的原因就是为了让内核底层透明化，同时如果用户程序出现了问题，将不会影响内核。


换我们思考一下，如果是我们，怎么在两个隔离的进程任务块中联系彼此。很常见的一个思路，我们一般能想到的是，让一个进程把需要交互的信息存到一个文件里面，另一个进程从文件中读取数据。

### 管道pipe
这种思路，被广泛运用到Linux系统中。比如pipe实际上是创建了两个文件（文件描述符实际上是内核缓存区），一个专门用来读，一个专门用来写。而pipe是一个半双工的通道，换句话说就是在一个时间内只能在一个单方向的进程通信。这样就可能的减少因为多个进程来回竞争文件内容，导致传输过程中出错。

而此时pipe必定是先通过内核调用copy_from_user方法把初始化数据拷贝一份内核空间中，此时通过alloc_file通过kmalloc在调用slab在内核空间创建2个文件描述符。

大致上示意图如下：
![pipe的工作流程.png](/images/pipe的工作流程.png)

记住fd[0]是读通道，fd[1] 是写通道

### FIFO named pipe
有名管道，这中管道在原来的基础上做了处理，依赖了Linux的文件系统。从名字上就能得出这种管道是先入先出的原则，能够让数据通信按照顺序来。然而有名管道更大的意义是让管道命名。原来的管道是无名管道，所以只能在自己控制下的子进程做沟通。而多了名字之后，就不需要想法子把地址交给第二个进程，而是通过名字去找文件，就能建立通道。


### signal 信号
信号这个东西，我们其实早就有所耳闻。比如说我们常说的中断信号就是指的是信号的一种。而在linux内核中内置一些通知事件。每一次发出这个事件内核将会通知进程接收这些事件，并且做处理。

内核实现：
- 1.为了做到对应的信号能够发送到正确需要进程。内核需要记住当前进程被哪些信号阻塞。
- 2.当从内核态切换到用户态，检查进程是否产生信号。这种检测每个时钟都会触发一次，一般在几个毫秒内触发一次。
- 3.还要检测哪些信号被忽略。以下条件都满足时表示信号被忽略
    - 进程没有被追踪，task_struct（用来描述进程的结构体）PT_PTRACED标示为0.
    - 进程没有阻塞这种信号
    - 进程忽略这种信号
- 4.处理信号

此时我们需要注意的是，在内核态我们是不会处理信号的，往往都会抛到用户空间，通过copy_to_user拷贝交给用户空间去处理。
信号的实现比较上面几个还是比较复杂，有机会要详细看看看源码。


### 消息队列
这个听起来有点像Android里面的消息队列。两者相比，设计上确实相似。消息队列的使用，先通过ftok生成一个key，再通过key用msgget创建一个消息队列(文件)。之后用msgsnd或者msgrcv发送或者接收东西。

此时在内核上实际上可以看出创建了一个文件。把对应的消息传进去消息队列中。此时读取方和写入方由于有ftok生成一个key，就能在内核空间找到对应的消息队，就能借助这个队列完成消息的传递。其中为了让数据能够来回在用户态和内核态来回切换，还是使用到了copy _from_user,copy_to_user.其数据结构是一个链表。

### socket 套子节
这个我们所有人都十分的熟悉。我们做网络编程离不开它。实际上从原理上它也是一种特殊的文件，我们也是不断的监听socket的状态来回应。既然是文件操作，那么一定会经历一次用户态到内核态，内核态到用户态的转化。这种本地监听的运用，在zyogte孵化进程的时候经常用。这里不多介绍，之后会专门抽出来分析其中的原理以及源码。


### 共享内存
共享内存的设计，是最接近binder的设计。其核心也是用过mmap内存映射技术。其设计上也和消息队列相似。也是通过ftok生成一个key，再通过这个key申请内存shmget之后，就能对这段地址做操作。之后Binder的思路和这个相似，就先不说了。

对了肯定有人说信号量呢？实际上信号量最主要的作用是对进程进行加锁，如果有进程访问这个正在使用的资源会进入睡眠状态。我看来并没有更多的内容通信，所以这里不列入讨论。

这一次我不会分析其中的源码，只是稍微过了一次，现在的重点是Binder，等之后专门分析Linux内核再来细说。

# Binder 的概述
介绍了Linux的几种基础IPC(进程间通信),我们发现一个很有趣的现象。大部分的IPC通信都通过文件作为中转站来回通讯。这样势必会造成用户态，内核态在来回切换，那么必定造成这种数据拷贝两次的情况。那么我们有没有办法处理优化这种通信方法呢？Binder就诞生了。

![常见的IPC设计思路.png](/images/常见的IPC设计思路.png)

那么我们要设计Binder的话，又能怎么设计呢？首先为了让整个透明并且可靠化，我们能采用TCP/IP这一套思路来保证信息的可靠性。其次为了减少来回的在用户往内核中拷贝空间能够创造模仿共享内存的方式。

这样思路来了，实际上Binder也是遵从这套规则来创造出来的。

Binder涉及十分广。这里我就厚着脸皮使用罗生阳大神那张Binder在系统中示意图。
![Binder.png](/images/Binder.png)


我们可以关注到Binder中四种角色：
- 1.Binder 驱动
- 2.ServiceManager 
- 3.Binder Client
- 4.Binder Service

实际上单单一个的Binder，仅仅只是一个简单的用来进行跨进程通信的一个驱动。为了赋予其真实的场景下讨论意义，我解析来会专门讨论Android系统中各大服务和应用之间的沟通。而罗升阳的图正是这个意思，并非Binder驱动模型中必须包含着ServiceMananger这个角色。

从这里我们明白，在内核空间中，存在这一个Binder的驱动，而这个驱动正是作为整个IPC通信的中转站。也就是类似TCP通信中的路由地位，我不在乎你究竟要是干啥，我只需要找到你，并且把消息交给你就好。

- 此时service manager充当的是Binder驱动的守护进程，类似于TCP通信中的DNS地位。我们会把相关的Binder注册到里面，最后会通过service manager这个服务去查找binder的远程端。而实际上这个service manager在Andrioid 
 Binder体系中，承当了Android系统中第一个注册进入Binder的服务。

- Binder Client binder的客户端，相当于C/S架构中的客户端的概念。

- Binder Service binder的服务端，相当于C/S架构中中服务端的概念。

- Binder驱动，本身充当一个一个类似路由表，路由分发器。每当一个client想去寻找service的时候，都会经过binder驱动，binder并不关心传输的内容是什么，只需要帮助你分发到服务。

这里值得注意的是，无论是Binder的Client以及Service端和tcp中的client/service还是有少许区别的。以前很多人看过我三年前的博客反而没有弄清楚binder的原理。毕竟只从java层上观察，看到的十分有限。

在这里我重新申明一次，所谓的服务端和客户端的概念只是为了更加好理解，实际上在Binder驱动看来并没有所谓的服务和客户端概念，仅仅只有远程端（或者代理端）和本地端的概念。因此Binder在整个IPC进程通信中，谁发出了请求此时就是作为本地端也就是客户端，而远程响应这个请求的则是代理端/远程端，也就是上面说的服务端。

大致知道这些角色之后，也就能清楚上方这个图的意义了。很简单，在Android系统启动的时候，会去启动一个Service Manager的进程。而这个进程会初始化好内核的Binder驱动。此时DNS和路由都准备好了。只要等到服务端注册进来，客户端取链接交互即可。

下面是根据binder的设计的示意图。
![binder IPC基本模型.png](/images/binder IPC基本模型.png)


为什么我说Binder和TCP十分相似。首先在我们开发中从来不会注意到binder的存在，更加不会注意到Android开发中我们居然会有信息做了跨进程通信。这也侧面说明了binder的设计优秀以及binder已经对上层来说几乎透明化。

那么让我们略去service manager 和binder 驱动看看service和client之间的关系。

![Binder中service 和 client.png](/images/Binder中service 和 client.png)

这个通信方式和TCP的通信及其相似。那么初始化呢？是不是和TCP的模型相似呢？让我们阅读源码看看究竟。

实际上Binder有两种looper形式进行IPC模式。一种是AIDL，一种是添加到service manager中。

我们直接来看看service manager 服务托管的模式。接下来，我们稍微看看源码吧。

接下来我们按照顺序来聊聊，binder的启动流程时间顺序来。首先我们需要通过内核动态加载驱动，这就得益于linux的静态模块化，可以把编写一个驱动文件，在内核加载完之后，装载内核。这就涉及到了linux的驱动编程，本人也只是略懂一二。让我们看看内核中，binder.c的源码吧。

## Binder 驱动初始化
这里简单介绍一下驱动编程。驱动编程实际上和我们的Android，iOS开发还是有点相似，也是依据定义的接口来编程。

为了简单理解，我们可以把驱动看作成一种在内核加载完之后，就会加载的特殊文件。那么既然是文件，那么就一定有打开，关闭，写入等操作。

所以binder驱动下面有这么一个结构体：
 ```c
static const struct file_operations binder_fops = {
	.owner = THIS_MODULE,
	.poll = binder_poll,
	.unlocked_ioctl = binder_ioctl,
	.compat_ioctl = binder_ioctl,
	.mmap = binder_mmap,
	.open = binder_open,
	.flush = binder_flush,
	.release = binder_release,
};
 ```

这为结构体file_operations定义下面几个方法指针，poll,ioctl,mmap,open,flush,release等。举个简单的例子，当我们调用文件描述符打开文件(调用open方法)的时候，就会通过内核空间调用用binder_open的方法。稍后我会解析这一块的源码。

当然，在模块加载的守护，还有一个初始化的函数。
```c
device_initcall(binder_init);
```

在驱动的时候，需要调用这个函数，而这个函数传入的binder_init这个就是对应我们的驱动初始化方法。

我们看看里面究竟有点什么东西。

```c
static int __init binder_init(void)
{
	int ret;

	binder_deferred_workqueue = create_singlethread_workqueue("binder");
	if (!binder_deferred_workqueue)
		return -ENOMEM;

	binder_debugfs_dir_entry_root = debugfs_create_dir("binder", NULL);
	if (binder_debugfs_dir_entry_root)
		binder_debugfs_dir_entry_proc = debugfs_create_dir("proc",
						 binder_debugfs_dir_entry_root);
	ret = misc_register(&binder_miscdev);
	if (binder_debugfs_dir_entry_root) {
		debugfs_create_file("state",
				    S_IRUGO,
				    binder_debugfs_dir_entry_root,
				    NULL,
				    &binder_state_fops);
		debugfs_create_file("stats",
				    S_IRUGO,
				    binder_debugfs_dir_entry_root,
				    NULL,
				    &binder_stats_fops);
		debugfs_create_file("transactions",
				    S_IRUGO,
				    binder_debugfs_dir_entry_root,
				    NULL,
				    &binder_transactions_fops);
		debugfs_create_file("transaction_log",
				    S_IRUGO,
				    binder_debugfs_dir_entry_root,
				    &binder_transaction_log,
				    &binder_transaction_log_fops);
		debugfs_create_file("failed_transaction_log",
				    S_IRUGO,
				    binder_debugfs_dir_entry_root,
				    &binder_transaction_log_failed,
				    &binder_transaction_log_fops);
	}
	return ret;
}
```

这里做了什么呢？这里比起罗生阳当初研究的2.3有点出入。
- 1.首先会为binder创建一个延时的工作队列。接着就和2.3的一致了。
- 2.接着通过misc_register把binder注册到misc_list系统列表中
- 3.会为binder创建调试一个/proc/binder/proc文件夹，接着在/proc/binder目录下创建下面五个文件state,stats, transactions, transaction_log, failed_transaction_log.

这样我们就完成了binder驱动加载到了Android系统设备中。
本期重点不在驱动编程，我们要关注binder核心。了解了这些就足够了。

“路由”binder驱动已经准备好了，我们再看看“DNS” service_manager.

## Service Manager
首先看看init.rc中有这么一段：
```
start servicemanager
start hwservicemanager
start vndservicemanager
```
我们再看看servicemanager.rc
```
service servicemanager /system/bin/servicemanager
    class core animation
    user system
    group system readproc
    critical
    onrestart restart healthd
    onrestart restart zygote
    onrestart restart audioserver
    onrestart restart media
    onrestart restart surfaceflinger
    onrestart restart inputflinger
    onrestart restart drm
    onrestart restart cameraserver
    onrestart restart keystore
    onrestart restart gatekeeperd
    writepid /dev/cpuset/system-background/tasks
    shutdown critical
```

我们直接看看启动之后main方法。
```c
int main(int argc, char** argv)
{
    struct binder_state *bs;
    union selinux_callback cb;
    char *driver;
//没有参数，则默认打开目录下的binder
    if (argc > 1) {
        driver = argv[1];
    } else {
        driver = "/dev/binder";
    }
//调用open方法
    bs = binder_open(driver, 128*1024);
...
//把service_mananger设置为第一个binder服务
    if (binder_become_context_manager(bs)) {
        ALOGE("cannot become context manager (%s)\n", strerror(errno));
        return -1;
    }
...
//进入事件等待
    binder_loop(bs, svcmgr_handler);

    return 0;
}
```

总的来说，这里涉及到了3步操作。
- 1.打开binder驱动
- 2.设置service_manager为第一个进入Binder的服务，也就是网上常说的是binder的守护进程
- 3.进入binder循环等待命令。

接下来，我会按照这三部解析binder。
首先我们看看binder_open这个方法。你以为这是我上面介绍的驱动open的方法吗？不还早着呢。

### ServiceManager初始化第一步 打开binder驱动
```c
struct binder_state *binder_open(const char* driver, size_t mapsize)
{
    struct binder_state *bs;
    struct binder_version vers;

    bs = malloc(sizeof(*bs));
    if (!bs) {
        errno = ENOMEM;
        return NULL;
    }

    bs->fd = open(driver, O_RDWR | O_CLOEXEC);
    if (bs->fd < 0) {
        fprintf(stderr,"binder: cannot open %s (%s)\n",
                driver, strerror(errno));
        goto fail_open;
    }

    if ((ioctl(bs->fd, BINDER_VERSION, &vers) == -1) ||
        (vers.protocol_version != BINDER_CURRENT_PROTOCOL_VERSION)) {
        fprintf(stderr,
                "binder: kernel driver version (%d) differs from user space version (%d)\n",
                vers.protocol_version, BINDER_CURRENT_PROTOCOL_VERSION);
        goto fail_open;
    }

    bs->mapsize = mapsize;
    bs->mapped = mmap(NULL, mapsize, PROT_READ, MAP_PRIVATE, bs->fd, 0);
    if (bs->mapped == MAP_FAILED) {
        fprintf(stderr,"binder: cannot map device (%s)\n",
                strerror(errno));
        goto fail_map;
    }

    return bs;

fail_map:
    close(bs->fd);
fail_open:
    free(bs);
    return NULL;
}
```

这里面我一步步剖开来解说。首先为binder_status创建在用户空间申请一个内存，并且打开上面传下来的binder驱动文件，返回到binder_state的fd属性中。
核心在这里
```c
bs->fd = open(driver, O_RDWR | O_CLOEXEC);
```
我们可以看到这里实际上以读写模式。这里我们稍微看看其open的源码如何的。

### syscall 工作原理
用户态是怎么进入到内核态呢？这着实让人头疼。实际上open方法将会进入到内核态，而沟通内核态的方法就是sys_call方法。

这里先给出，一般来说，系统是怎么通过找到去找到内核对应的方法的。这里就涉及到了syscall的原理了。如果对c/c++编程了解的人就会明白如下当我们想要使用系统调用的时候，我们都需要这个头文件<unistd.h>。而这个头文件就是重点。

文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[kernel](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/)/[uapi](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/)/[asm-arm](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/asm-arm/)/[asm](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/asm-arm/asm/)/[unistd-common.h](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/asm-arm/asm/unistd-common.h)
```c
#ifndef _UAPI_ASM_ARM_UNISTD_COMMON_H
#define _UAPI_ASM_ARM_UNISTD_COMMON_H 1
#define __NR_restart_syscall (__NR_SYSCALL_BASE + 0)
#define __NR_exit (__NR_SYSCALL_BASE + 1)
#define __NR_fork (__NR_SYSCALL_BASE + 2)
#define __NR_read (__NR_SYSCALL_BASE + 3)
#define __NR_write (__NR_SYSCALL_BASE + 4)
#define __NR_open (__NR_SYSCALL_BASE + 5)
#define __NR_close (__NR_SYSCALL_BASE + 6)
#define __NR_creat (__NR_SYSCALL_BASE + 8)
#define __NR_link (__NR_SYSCALL_BASE + 9)
...
#endif
```
这里面为用户空间中声明了每一个对应到内核的方法。每一次调用都会发出一个中断信号。用户空间会通过调用汇编调用，而这个汇编调用从这个头文件作为去尝试的找到来到内核中对应的方法。

因此，我们可以规划出一个syscall的流程图。就以网上最常见kill分析为例子。
![syscall 工作原理.png](/images/syscall 工作原理.png)


从上面的图，我们可以得知，整个流程氛围以下几个步骤：
- 1.调用 kill()方法。
- 2. 调用kill.S汇编方法。
- 3.通过汇编方法正式进入到内核态
- 4.从sys_call_table 查找sys_kill
- 5. 执行真实的内核执行动作ret_fast_syscall 
- 6.回到用户空间的kill()代码。

从这里我们可以知道整个用户空间和内核空间都有一一对应unistd.h头文件用来查找和用户空间上面一一对应的方法。而使用这个实现这个用户态往内核态转化的核心机制就是swi软中断。

所以这里有个小诀窍，每一个内核对应着用户空间调用的方法一定是xxx对应着xxx.S的汇编文件。而这个汇编文件里面有着异常常量表地址(地址名一般__NR_xxx)，而这个地址会通过调用CALL汇编指令调转到内核实际方法(实际方法名sys_xxx)。

### open 源码跟踪
接下来我们跟着open来看看open对应的方法。在arm框架下面的内核执行。但是问题来了，我们看看上面用户空间中unistd.h头文件中确实存在__NR_open.接着在bionic找找有没有open.S或者__open.S。
 
问题来了！我居然没找到，太打脸了。但是有的博客说是存在__open.S 的汇编文件。我现在是基于Linux内核3.1.8版本的，或许情况有变，我们追踪以下源码。

### open在用户空间的处理
经过查找发现open的方法声明在此处。
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[include](http://androidxref.com/9.0.0_r3/xref/bionic/libc/include/)/[fcntl.h](http://androidxref.com/9.0.0_r3/xref/bionic/libc/include/fcntl.h)

```c
#ifndef _FCNTL_H
#define _FCNTL_H

...
int openat(int __dir_fd, const char* __path, int __flags, ...);
int openat64(int __dir_fd, const char* __path, int __flags, ...) __INTRODUCED_IN(21);
int open(const char* __path, int __flags, ...);
...

#endif
```

此时我们发现在open.cpp实现了这个方法
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/)/[open.cpp](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/open.cpp)
```c
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>

#include "private/bionic_fortify.h"
//通过此处调用汇编方法
extern "C" int __openat(int, const char*, int, int);

int open(const char* pathname, int flags, ...) {
  mode_t mode = 0;

  if (needs_mode(flags)) {
    va_list args;
    va_start(args, flags);
    mode = static_cast<mode_t>(va_arg(args, int));
    va_end(args);
  }

  return __openat(AT_FDCWD, pathname, force_O_LARGEFILE(flags), mode);
}
```
原来如此，在这个内核版本用__openat的异常地址来代替__open的异常地址。这种内核就减少了异常常量表的数量。我们来看看__openat.S下面的汇编。

文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[arch-arm](http://androidxref.com/9.0.0_r3/xref/bionic/libc/arch-arm/)/[syscalls](http://androidxref.com/9.0.0_r3/xref/bionic/libc/arch-arm/syscalls/)/[__openat.S](http://androidxref.com/9.0.0_r3/xref/bionic/libc/arch-arm/syscalls/__openat.S)

```c
#include <private/bionic_asm.h>

ENTRY(__openat)
    mov     ip, r7
    .cfi_register r7, ip
//设置中断地址
    ldr     r7, =__NR_openat
//进入内核
    swi     #0
//把之前的状态从ip拿回来，进入回用户态
    mov     r7, ip
    .cfi_restore r7
    cmn     r0, #(MAX_ERRNO + 1)
    bxls    lr
    neg     r0, r0
    b       __set_errno_internal
END(__openat)
```
这里可以把汇编看成两截首先我们会把系统调用常量表中的地址给到r7寄存器，接着通过swi中断进入内核态，等到处理完成又进入到用户态。

### open在内核空间的处理
那么我们直接奔向sys_openat。实际上我们根本找不到sys_openat的方法，但是实际上我们能够找到如下方法
文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[open.c](http://androidxref.com/kernel_3.18/xref/fs/open.c)

```c
SYSCALL_DEFINE4(openat, int, dfd, const char __user *, filename, int, flags,
		umode_t, mode)
{
	if (force_o_largefile())
		flags |= O_LARGEFILE;

	return do_sys_open(dfd, filename, flags, mode);
}
```
而这个SYSCALL_DEFINE4是一个define实际上就是把第一个参数转化为sys_openat作为方法名。

终于来到了open了核心处理方法do_sys_open。

### do_sys_open
接下来就稍微涉及到了vfs linux的虚拟文件系统。那就一边复习，一边研究吧。
```c
long do_sys_open(int dfd, const char __user *filename, int flags, umode_t mode)
{
	struct open_flags op;
	int fd = build_open_flags(flags, mode, &op);
	struct filename *tmp;

	if (fd)
		return fd;
//从进程地址读取文件路径名字
	tmp = getname(filename);
	if (IS_ERR(tmp))
		return PTR_ERR(tmp);
//从current（进程描述符task_struct）查找对应的空闲的位置,遇到fdt不足时候扩容
	fd = get_unused_fd_flags(flags);
	if (fd >= 0) {
		struct file *f = do_filp_open(dfd, tmp, &op);
		if (IS_ERR(f)) {
			put_unused_fd(fd);
			fd = PTR_ERR(f);
		} else {
			fsnotify_open(f);
			fd_install(fd, f);
		}
	}
	putname(tmp);
	return fd;
}
```

- 1.getname 从进程地址获取路径名字
- 2.get_unused_fd_flags 获取一下当前fdt进程中空闲的fdt描述符，加入遇到容量不足则2倍扩容或者是（最小）PAGE_SIZE *8 。
- 3.当fd>= 0的时候，说明找到了空闲的位置，先通过do_filp_open获取file结构体。
- 4.设置fd文件描述符到file结构体中

我们主要看看do_filp_open的方法。

### path_openat
而这里do_filp_open 的核心逻辑在path_openat

文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[namei.c](http://androidxref.com/kernel_3.18/xref/fs/namei.c)

```c
static struct file *path_openat(int dfd, struct filename *pathname,
		struct nameidata *nd, const struct open_flags *op, int flags)
{
	struct file *base = NULL;
	struct file *file;
	struct path path;
	int opened = 0;
	int error;
//从filecached获取 一个空的file
	file = get_empty_filp();
	if (IS_ERR(file))
		return file;

	file->f_flags = op->open_flag;

	if (unlikely(file->f_flags & __O_TMPFILE)) {
		error = do_tmpfile(dfd, pathname, nd, flags, op, file, &opened);
		goto out;
	}

	error = path_init(dfd, pathname->name, flags | LOOKUP_PARENT, nd, &base);
	if (unlikely(error))
		goto out;

	current->total_link_count = 0;
	error = link_path_walk(pathname->name, nd);
	if (unlikely(error))
		goto out;

	error = do_last(nd, &path, file, op, &opened, pathname);
	while (unlikely(error > 0)) { /* trailing symlink */
		struct path link = path;
		void *cookie;
		if (!(nd->flags & LOOKUP_FOLLOW)) {
			path_put_conditional(&path, nd);
			path_put(&nd->path);
			error = -ELOOP;
			break;
		}
		error = may_follow_link(&link, nd);
		if (unlikely(error))
			break;
		nd->flags |= LOOKUP_PARENT;
		nd->flags &= ~(LOOKUP_OPEN|LOOKUP_CREATE|LOOKUP_EXCL);
		error = follow_link(&link, nd, &cookie);
		if (unlikely(error))
			break;
		error = do_last(nd, &path, file, op, &opened, pathname);
		put_link(nd, &link, cookie);
	}
out:
	if (nd->root.mnt && !(nd->flags & LOOKUP_ROOT))
		path_put(&nd->root);
	if (base)
		fput(base);
	if (!(opened & FILE_OPENED)) {
		BUG_ON(!error);
		put_filp(file);
	}
	if (unlikely(error)) {
		if (error == -EOPENSTALE) {
			if (flags & LOOKUP_RCU)
				error = -ECHILD;
			else
				error = -ESTALE;
		}
		file = ERR_PTR(error);
	}
	return file;
}
```
我们不需要过度关注细节，只需要明白binder驱动怎么贯通整个linux用户控件到内核空间的。
这里为核心，大致上分为三个步骤：
- 1.get_empty_filp 从 filpcache中获取一个空的file

- 2. path_init 设置nameidata ，这个结构体很重要一般就是代表在内核中文件路径。一般在解析和查找路径名会使用到。

- 3.link_path_walk 逐步解析路径，初始化dentry 结构体，这个结构体就是虚拟文件系统中的目录结构体。同时设置inode结构体。这个inode结构体在虚拟文件系统十分重要，是指索引节点。文件系统需要处理的信息都是存放到inode中，索引节点是唯一的，是随着文件的存在而存在。

- 4.最后交由do_last来实现虚拟文件系统启动文件.

我们重点看看do_last究竟做了什么事情，我们只关注核心逻辑
```c
static int do_last(struct nameidata *nd, struct path *path,
		   struct file *file, const struct open_flags *op,
		   int *opened, struct filename *name)
{
	...

	if (!(open_flag & O_CREAT)) {
		if (nd->last.name[nd->last.len])
			nd->flags |= LOOKUP_FOLLOW | LOOKUP_DIRECTORY;
		if (open_flag & O_PATH && !(nd->flags & LOOKUP_FOLLOW))
			symlink_ok = true;
		/* we _can_ be in RCU mode here */
		error = lookup_fast(nd, path, &inode);
		if (likely(!error))
			goto finish_lookup;

		if (error < 0)
			goto out;

		BUG_ON(nd->inode != dir->d_inode);
	} else {
...
	}

retry_lookup:
	...
finish_lookup:
/* we _can_ be in RCU mode here */
	error = -ENOENT;
	if (!inode || d_is_negative(path->dentry)) {
		path_to_nameidata(path, nd);
		goto out;
	}

	if (should_follow_link(path->dentry, !symlink_ok)) {
		if (nd->flags & LOOKUP_RCU) {
			if (unlikely(unlazy_walk(nd, path->dentry))) {
				error = -ECHILD;
				goto out;
			}
		}
		BUG_ON(inode != path->dentry->d_inode);
		return 1;
	}

	if ((nd->flags & LOOKUP_RCU) || nd->path.mnt != path->mnt) {
		path_to_nameidata(path, nd);
	} else {
		save_parent.dentry = nd->path.dentry;
		save_parent.mnt = mntget(path->mnt);
		nd->path.dentry = path->dentry;

	}
	nd->inode = inode;
	/* Why this, you ask?  _Now_ we might have grown LOOKUP_JUMPED... */
finish_open:
	...
finish_open_created:
	error = may_open(&nd->path, acc_mode, open_flag);
	if (error)
		goto out;

	BUG_ON(*opened & FILE_OPENED); /* once it's opened, it's opened */
	error = vfs_open(&nd->path, file, current_cred());
	if (!error) {
		*opened |= FILE_OPENED;
	} else {
		if (error == -EOPENSTALE)
			goto stale_open;
		goto out;
	}
opened:
...
out:
	if (got_write)
		mnt_drop_write(nd->path.mnt);
	path_put(&save_parent);
	terminate_walk(nd);
	return error;

exit_dput:
...
exit_fput:
...

stale_open:
	...
}
```
经过精简之后，假如我们想要打开一个存在的文件，将会走以下这个顺序。线调用lookup_fast来用过rcu方式(rcu是一种读写锁，允许多读入，一个线程写入)检测对应的inode是不是挂载点，是则挂在系统文件，不是继续查找知道找到为止。一旦找到了，则调到finish_lookup标签处，粗俗判断找到的文件是否是一个连接，不是则设置数据到nameidata中。接着调用mayopen检测权限，最后来到vfs_open真正的调用虚拟文件系统的启动方法。

### vfs_open
文件:/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[open.c](http://androidxref.com/kernel_3.18/xref/fs/open.c)

vfs_open会调用do_dentry_open
```c
static int do_dentry_open(struct file *f,
			  int (*open)(struct inode *, struct file *),
			  const struct cred *cred)
{
	static const struct file_operations empty_fops = {};
	struct inode *inode;
	int error;

	f->f_mode = OPEN_FMODE(f->f_flags) | FMODE_LSEEK |
				FMODE_PREAD | FMODE_PWRITE;

	path_get(&f->f_path);
	inode = f->f_inode = f->f_path.dentry->d_inode;
	f->f_mapping = inode->i_mapping;

....

	f->f_op = fops_get(inode->i_fop);
...
	if (!open)
		open = f->f_op->open;
	if (open) {
		error = open(inode, f);
		if (error)
			goto cleanup_all;
	}
...
```

经过精简之后我们可以知道，首先先从file中获取对应的inode，而inode就是文件系统对应的索引节点，这个节点里面我们能获取file里面的操作符号。一旦判断没有打开则调用文件操作符中的open方法。

##回到Binder
经过漫长的用户空间到内核空间的切换，不要忘记了，此时我们binder驱动文件。
```c
static const struct file_operations binder_fops = {
...
   .open = binder_open,
...
};
```
f->f_op->open 对应的就是 binder 中binder_open 的方法指针。

### binder_open
```c
static int binder_open(struct inode *nodp, struct file *filp)
{
	struct binder_proc *proc;

	binder_debug(BINDER_DEBUG_OPEN_CLOSE, "binder_open: %d:%d\n",
		     current->group_leader->pid, current->pid);
//内核中申请binder_proc 内存
	proc = kzalloc(sizeof(*proc), GFP_KERNEL);
	if (proc == NULL)
		return -ENOMEM;
	get_task_struct(current);
	proc->tsk = current;
	INIT_LIST_HEAD(&proc->todo);
	init_waitqueue_head(&proc->wait);
	proc->default_priority = task_nice(current);

	binder_lock(__func__);

	binder_stats_created(BINDER_STAT_PROC);
	hlist_add_head(&proc->proc_node, &binder_procs);
	proc->pid = current->group_leader->pid;
	INIT_LIST_HEAD(&proc->delivered_death);
	filp->private_data = proc;

	binder_unlock(__func__);

	if (binder_debugfs_dir_entry_proc) {
		char strbuf[11];

		snprintf(strbuf, sizeof(strbuf), "%u", proc->pid);
		proc->debugfs_entry = debugfs_create_file(strbuf, S_IRUGO,
			binder_debugfs_dir_entry_proc, proc, &binder_proc_fops);
	}

	return 0;
}
```
这里尝试的抓点细节。首先我们会遇到Binder中第一个重要的结构体binder_proc 这个结构体代表的是当前调用的binder驱动的进程对象。

```c
    struct binder_proc *proc;

    binder_debug(BINDER_DEBUG_OPEN_CLOSE, "binder_open: %d:%d\n",
             current->group_leader->pid, current->pid);
//内核中申请binder_proc 内存
    proc = kzalloc(sizeof(*proc), GFP_KERNEL);
    if (proc == NULL)
        return -ENOMEM;
    get_task_struct(current);
    proc->tsk = current;
```
kzalloc这个方法，一般是用来在内核空间申请并初始化一段内存。因此为binder_proc 是在内核中申请了内存。对linux熟悉一点的都知道，task_struct代表着进程，也就是我们常说的进程描述符。因此此时binder_proc首先记录了当前使用binder的进程节点是什么。

```
 INIT_LIST_HEAD(&proc->todo);
    init_waitqueue_head(&proc->wait);
    proc->default_priority = task_nice(current);

    binder_lock(__func__);

    binder_stats_created(BINDER_STAT_PROC);
    hlist_add_head(&proc->proc_node, &binder_procs);
    proc->pid = current->group_leader->pid;
    INIT_LIST_HEAD(&proc->delivered_death);
```
其次我们将初始化几个binder需要的队列：
- 1.proc->todo binder的todo队列
- 2. 根据进程设置优先级
- 3. 接着把当前binder_proc中的proc_node这个双向链表， 设置为binder_procs。这个binder_procs对象是存活在binder驱动中用来管理所有接进binder的双向链表。
- 4. binder_proc设置死亡分发列表，会在binder 发送死亡的通知中使用到。

```c
filp->private_data = proc;
```
记住此时我们把binder_proc这个对象设置为当前文件的私密数据，为后面初始化做准备。



### 中场休息
这次先到这里，接下来会继续探讨mmap binder是怎么做内存映射。重新学习binder驱动去抓细节，发现自己确实能力不足，很多东西不懂，花了不少时间去复习和研究linux内核源码，才能保证自己说的正确。但是这样也仅仅只是管中窥豹，不管是我和读者都需要多多努力。
