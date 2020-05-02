---
title: Android 重学系列 Binder驱动初始化 Binder的Looper初始化(三)
top: false
cover: false
date: 2019-05-03 16:14:54
img:
description:
author: yjy239
summary:
tags:
- Linux kernel
- Android
- Binder
- Android Framework
---
如果遇到问题请到：[https://www.jianshu.com/p/2ab3aaf2aeb6](https://www.jianshu.com/p/2ab3aaf2aeb6)

## ServiceMananger 的初始化第二步 把进程对象注册到Binder驱动中
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/)/[servicemanager](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/)/[service_manager.c](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/service_manager.c)

```c
    if (binder_become_context_manager(bs)) {
        ALOGE("cannot become context manager (%s)\n", strerror(errno));
        return -1;
    }
```
我们看看这个方法具体做了什么。
文件：/[drivers](http://androidxref.com/kernel_3.18/xref/drivers/)/[staging](http://androidxref.com/kernel_3.18/xref/drivers/staging/)/[android](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/)/[binder.c](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/binder.c)

```c
int binder_become_context_manager(struct binder_state *bs)
{
    return ioctl(bs->fd, BINDER_SET_CONTEXT_MGR, 0);
}
```

这里又是我们熟悉的ioctl系统调用。这是初始化之后第一次使用bs对象，binder_state在binder_open中初始化的结构体。此时这个结构体包含着该binder的共享地址。

我们直接看看binder_ioctl中的switch片段

```c
case BINDER_SET_CONTEXT_MGR:
		ret = binder_ioctl_set_ctx_mgr(filp);
		if (ret)
			goto err;
...
		break;
```

```c
static int binder_ioctl_set_ctx_mgr(struct file *filp)
{
	int ret = 0;
	struct binder_proc *proc = filp->private_data;
...
	binder_context_mgr_node = binder_new_node(proc, 0, 0);
	if (binder_context_mgr_node == NULL) {
		ret = -ENOMEM;
		goto out;
	}
	binder_context_mgr_node->local_weak_refs++;
	binder_context_mgr_node->local_strong_refs++;
	binder_context_mgr_node->has_strong_ref = 1;
	binder_context_mgr_node->has_weak_ref = 1;
out:
	return ret;
}
```

实际上，我们需要关注的只有这么一小段。我们再一次从文件中获取私密对象，当前的进程对应的binder_proc对象。此时应用刚刚启动，因此整个binder驱动下都是空。因此此时我们需要新生成一个binder_node结构体加入到binder的红黑树中管理。而这个binder_node代表着在binder驱动中，一个进程，工作项，引用列表等关键数据的集合。

当我们添加并且生成binder一个新的binder _node对象之后，把它赋值给binder_context_mgr_node这个对象。这个对象是为了快速的寻找service_manager而创建的全局对象。这也因为考虑到Android系统处处使用这个对象。

我们来看看binder_new_node方法。

```c
static struct binder_node *binder_new_node(struct binder_proc *proc,
					   binder_uintptr_t ptr,
					   binder_uintptr_t cookie)
{
	struct rb_node **p = &proc->nodes.rb_node;
	struct rb_node *parent = NULL;
	struct binder_node *node;

	while (*p) {
		parent = *p;
		node = rb_entry(parent, struct binder_node, rb_node);

		if (ptr < node->ptr)
			p = &(*p)->rb_left;
		else if (ptr > node->ptr)
			p = &(*p)->rb_right;
		else
			return NULL;
	}

	node = kzalloc(sizeof(*node), GFP_KERNEL);
	if (node == NULL)
		return NULL;
	binder_stats_created(BINDER_STAT_NODE);
	rb_link_node(&node->rb_node, parent, p);
	rb_insert_color(&node->rb_node, &proc->nodes);
	node->debug_id = ++binder_last_id;
	node->proc = proc;
	node->ptr = ptr;
	node->cookie = cookie;
	node->work.type = BINDER_WORK_NODE;
	INIT_LIST_HEAD(&node->work.entry);
	INIT_LIST_HEAD(&node->async_todo);
	binder_debug(BINDER_DEBUG_INTERNAL_REFS,
		     "%d:%d node %d u%016llx c%016llx created\n",
		     proc->pid, current->pid, node->debug_id,
		     (u64)node->ptr, (u64)node->cookie);
	return node;
}
```


此时，Binder创建一个新的Binder 实体如果看过我的红黑树文章这里也就轻而易举了。

此时Binder将会从红黑树中根据node的弱引用的地址作为key寻找node。此时肯定是不会找到的，因此会通过kzmalloc生成一个新的node，并且添加到rb_node这个红黑树中管理。并且把binder的本地对象设置到cookie中。此时node的work模式是BINDER_WORK_NODE。

这样Binder驱动中第一个代表着service manager的binder实体就创建完成了。

此时的生成模式并没有有顶层的JavaBBinder，BpBinder，IPCThreadState等核心初始化Binder类参与进来。是一个极其特殊的服务的初始化。所以很多地方没有把service manager这个作为一个binder 服务，而是说是binder驱动的守护进程。然而归根结底，也不过只是注册在Binder驱动中的binder对象。

## ServiceMananger 的初始化第三步 service_manager启动消息等待循环
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/)/[servicemanager](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/)/[service_manager.c](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/service_manager.c)

```c
binder_loop(bs, svcmgr_handler);
```

实际上这里就是启动Android Service体系中的消息等待初始化。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/)/[servicemanager](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/)/[binder.c](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/binder.c)

```c
void binder_loop(struct binder_state *bs, binder_handler func)
{
    int res;
    struct binder_write_read bwr;
    uint32_t readbuf[32];

    bwr.write_size = 0;
    bwr.write_consumed = 0;
    bwr.write_buffer = 0;

    readbuf[0] = BC_ENTER_LOOPER;
    binder_write(bs, readbuf, sizeof(uint32_t));

    for (;;) {
        bwr.read_size = sizeof(readbuf);
        bwr.read_consumed = 0;
        bwr.read_buffer = (uintptr_t) readbuf;

        res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);

        if (res < 0) {
...
            break;
        }

        res = binder_parse(bs, 0, (uintptr_t) readbuf, bwr.read_consumed, func);
        if (res == 0) {
...
            break;
        }
        if (res < 0) {
...
            break;
        }
    }
}
```

依据之前学习到的东西，我们大致上可以知道，这个looper做了以下几个事情。

- 1.service_manager先往binder驱动中往binder_write_read写入BC_ENTER_LOOPER ，告诉binder驱动进入service的循环命令。

- 2.service_manager 进入阻塞，等待binder驱动往binder_write_read写入数据。

- 3.解析从binder驱动中传送上来的数据。

接下来，我将分为三点慢慢来聊聊。

### 1.binder looper 发送BC_ENTER_LOOPER 命令
这里有一个很关键的结构体 binder_write_read
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[kernel](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/)/[uapi](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/)/[linux](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/linux/)/[android](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/linux/android/)/[binder.h](http://androidxref.com/9.0.0_r3/xref/bionic/libc/kernel/uapi/linux/android/binder.h)

```c
struct binder_write_read {
  binder_size_t write_size;//写入数据的大小
  binder_size_t write_consumed;//写入的数据，已经写过了多少位置
  binder_uintptr_t write_buffer;// 写入数据的数据缓冲区

  binder_size_t read_size;//读取数据的大小
  binder_size_t read_consumed;//读取的数据，已经读取多少数据
  binder_uintptr_t read_buffer;//读取数据的数据缓冲区
};
```
结构体binder_write_read可以分为两部分，上部分描述了要写进去的数据，下部分描述要读取的数据。binder_write_read结构体一般是用来承载framework层数据的载体，用于传递数据给binder驱动。

```c
    bwr.write_size = 0;
    bwr.write_consumed = 0;
    bwr.write_buffer = 0;

    readbuf[0] = BC_ENTER_LOOPER;
    binder_write(bs, readbuf, sizeof(uint32_t));
```

binder一开始对写入数据进行初始化。接着BC_ENTER_LOOPER放到readbuf属性中，通过binder_write往binder驱动写入。
```c
int binder_write(struct binder_state *bs, void *data, size_t len)
{
    struct binder_write_read bwr;
    int res;

    bwr.write_size = len;
    bwr.write_consumed = 0;
    bwr.write_buffer = (uintptr_t) data;
    bwr.read_size = 0;
    bwr.read_consumed = 0;
    bwr.read_buffer = 0;
    res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);
    if (res < 0) {
        fprintf(stderr,"binder_write: ioctl failed (%s)\n",
                strerror(errno));
    }
    return res;
}
```

此时我们看到binder_write_read 把读取相关的数据都初始化为0，而写入数据相关的属性，write_buffer写入数据，write_size写入数据长度，write_consumed 为0.这样就告诉了binder驱动知道数据在哪里，应该从哪里开始读取。
文件：/[drivers](http://androidxref.com/kernel_3.18/xref/drivers/)/[staging](http://androidxref.com/kernel_3.18/xref/drivers/staging/)/[android](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/)/[binder.c](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/binder.c)

```c
static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	int ret;
	struct binder_proc *proc = filp->private_data;
	struct binder_thread *thread;
	unsigned int size = _IOC_SIZE(cmd);
	void __user *ubuf = (void __user *)arg;

...
	switch (cmd) {
	case BINDER_WRITE_READ:
		ret = binder_ioctl_write_read(filp, cmd, arg, thread);
		if (ret)
			goto err;
		break;
```
此时根据上面传下来的数据，将会走binder_ioctl_write_read分支。从这里开始就是binder的核心分支之一，binder驱动在进程间读写数据的核心就是这个方法。

```c
static int binder_ioctl_write_read(struct file *filp,
				unsigned int cmd, unsigned long arg,
				struct binder_thread *thread)
{
	int ret = 0;
	struct binder_proc *proc = filp->private_data;
	unsigned int size = _IOC_SIZE(cmd);
	void __user *ubuf = (void __user *)arg;
	struct binder_write_read bwr;

	if (size != sizeof(struct binder_write_read)) {
		ret = -EINVAL;
		goto out;
	}
	if (copy_from_user(&bwr, ubuf, sizeof(bwr))) {
		ret = -EFAULT;
		goto out;
	}
...
	if (bwr.write_size > 0) {
		ret = binder_thread_write(proc, thread,
					  bwr.write_buffer,
					  bwr.write_size,
					  &bwr.write_consumed);
		trace_binder_write_done(ret);
		if (ret < 0) {
			bwr.read_consumed = 0;
			if (copy_to_user(ubuf, &bwr, sizeof(bwr)))
				ret = -EFAULT;
			goto out;
		}
	}
	if (bwr.read_size > 0) {
		ret = binder_thread_read(proc, thread, bwr.read_buffer,
					 bwr.read_size,
					 &bwr.read_consumed,
					 filp->f_flags & O_NONBLOCK);
...
		if (!list_empty(&proc->todo))
			wake_up_interruptible(&proc->wait);
		if (ret < 0) {
			if (copy_to_user(ubuf, &bwr, sizeof(bwr)))
				ret = -EFAULT;
			goto out;
		}
	}
...
	if (copy_to_user(ubuf, &bwr, sizeof(bwr))) {
		ret = -EFAULT;
		goto out;
	}
out:
	return ret;
}
```
binder分为三个步骤进行解析从ioctl传送下来的数据。
- 1.把传递下来的数据转型为内核对应的binder_write_read结构体。
- 2.当判断到binder_write_read中write_size大于0，说明有数据写入，则执行binder_thread_write。
- 3.当判断到binder_write_read中read_size大于0，说明有数据需要读取，则执行binder_thread_read。

结束完之后，则从内核态的binder_write_read拷贝到用户态的binder_write_read数据中。因为此时传递下来的ubuf恰好就是用户空间对应的binder_write_read。因此能够直接通过copy_to_user把数据从内核空间拷贝一份到用户空间。

因此我们可以得出，binder在处理每个协议下来的数据时候，都是先处理写的数据，再处理读的数据。为什么这么做分别看看下面两个方法就知道了。

### binder处理从framework传下来的写数据
 ```c
static int binder_thread_write(struct binder_proc *proc,
			struct binder_thread *thread,
			binder_uintptr_t binder_buffer, size_t size,
			binder_size_t *consumed)
{
	uint32_t cmd;
	void __user *buffer = (void __user *)(uintptr_t)binder_buffer;
	void __user *ptr = buffer + *consumed;
	void __user *end = buffer + size;

	while (ptr < end && thread->return_error == BR_OK) {
		if (get_user(cmd, (uint32_t __user *)ptr))
			return -EFAULT;
		ptr += sizeof(uint32_t);
		trace_binder_command(cmd);
		if (_IOC_NR(cmd) < ARRAY_SIZE(binder_stats.bc)) {
			binder_stats.bc[_IOC_NR(cmd)]++;
			proc->stats.bc[_IOC_NR(cmd)]++;
			thread->stats.bc[_IOC_NR(cmd)]++;
		}
		switch (cmd) {
		...
		case BC_ENTER_LOOPER:
			binder_debug(BINDER_DEBUG_THREADS,
				     "%d:%d BC_ENTER_LOOPER\n",
				     proc->pid, thread->pid);
			if (thread->looper & BINDER_LOOPER_STATE_REGISTERED) {
				thread->looper |= BINDER_LOOPER_STATE_INVALID;
				binder_user_error("%d:%d ERROR: BC_ENTER_LOOPER called after BC_REGISTER_LOOPER\n",
					proc->pid, thread->pid);
			}
			thread->looper |= BINDER_LOOPER_STATE_ENTERED;
			break;
		case BC_EXIT_LOOPER:
			binder_debug(BINDER_DEBUG_THREADS,
				     "%d:%d BC_EXIT_LOOPER\n",
				     proc->pid, thread->pid);
			thread->looper |= BINDER_LOOPER_STATE_EXITED;
			break;

...

		default:
			pr_err("%d:%d unknown command %d\n",
			       proc->pid, thread->pid, cmd);
			return -EINVAL;
		}
		*consumed = ptr - buffer;
	}
	return 0;
}
```
 
这里我只挑选出需要关注的分支。
首先binder在处理写入数据的时候，由于没办法直接通过sizeof直接找到数据结构的边界，因此通过思路上和Parcel相似，通过下面几种参数来控制整个读写过程。

```c
   uint32_t cmd;
   void __user *buffer = (void __user *)(uintptr_t)binder_buffer;
   void __user *ptr = buffer + *consumed;
   void __user *end = buffer + size;
```
 - 1.cmd 这个缩写英文我们可以直接望文生义，就是从framework中写进来的write_buffer中第一个int型，这个决定了驱动怎么解析这次命令数据。
 
- 2.buffer 对应这用户空间的write_buffer 这里面存储着需要处理的数据。
- 3.ptr 对应着此时binder驱动已经处理了多少数据。
- 4.end 确定这一次buffer边界。

##### 数据解析循环

```c
   while (ptr < end && thread->return_error == BR_OK) {
       if (get_user(cmd, (uint32_t __user *)ptr))
           return -EFAULT;
       ptr += sizeof(uint32_t);
```

根据上面的数据解析，因此可以知道此时数据解析的循环结束条件有两个，第一 buffer的数据区域循环到了结束地址，第二，binder_thread 返回BR_OK。

从第一个get_user从用户空间拷贝方法出来得知，每一次循环第一个参数必定是符合条件的cmd，对应着下面binder分支命令。接着消费指针向前移动一个int的大小，而后面就是我们需要处理的数据。

此时我们从用户空间下传下来的命令正是BC_ENTER_LOOPER。

```c
  case BC_ENTER_LOOPER:
           binder_debug(BINDER_DEBUG_THREADS,
                    "%d:%d BC_ENTER_LOOPER\n",
                    proc->pid, thread->pid);
           if (thread->looper & BINDER_LOOPER_STATE_REGISTERED) {
               thread->looper |= BINDER_LOOPER_STATE_INVALID;
               binder_user_error("%d:%d ERROR: BC_ENTER_LOOPER called after BC_REGISTER_LOOPER\n",
                   proc->pid, thread->pid);
           }
           thread->looper |= BINDER_LOOPER_STATE_ENTERED;
           break;

```

此时命令需要的操作很简单，就是修改当前binder_proc对应的binder_thread的状态。

这样就完成了service_manager 从用户空间的写入操作。还记得上面的对binder_write_read的结构体处理吗？此时因为read_size被设置为0.因此走不到binder_thread_read。接着把内核空间对应的binder_write_read拷贝回到用户空间即可。

### service_manager 正式进入到binder looper循环等待消息。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[cmds](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/)/[servicemanager](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/)/[binder.c](http://androidxref.com/9.0.0_r3/xref/frameworks/native/cmds/servicemanager/binder.c)

```c
  for (;;) {
        bwr.read_size = sizeof(readbuf);
        bwr.read_consumed = 0;
        bwr.read_buffer = (uintptr_t) readbuf;

        res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);

        if (res < 0) {
...
            break;
        }
```

可以看到这是一个无限的循环，等待着binder驱动信息返回信息。但是做一个google开发者怎么可能真的让循环不断进行下去呢？看过我启动的zygote一章节的读者，肯定知道一直在跑无限循环只会不断的开销cpu，因此在这个循环必定会通过阻塞之类的手段来规避这种looper的开销。

我们看看循环的第一段。此时，把读取的数据长度设置为readbuf 一个长度为32的int数组。接着通过ioctl，通信到binder驱动。

文件：/[drivers](http://androidxref.com/kernel_3.18/xref/drivers/)/[staging](http://androidxref.com/kernel_3.18/xref/drivers/staging/)/[android](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/)/[binder.c](http://androidxref.com/kernel_3.18/xref/drivers/staging/android/binder.c)
此时我们根据service_manager可以得知，此时write_size为0，read_size不为0,将会走binder_ioctl_write_read 读取数据的代码:

```c
    if (bwr.read_size > 0) {
        ret = binder_thread_read(proc, thread, bwr.read_buffer,
                     bwr.read_size,
                     &bwr.read_consumed,
                     filp->f_flags & O_NONBLOCK);
...
        if (!list_empty(&proc->todo))
            wake_up_interruptible(&proc->wait);
        if (ret < 0) {
            if (copy_to_user(ubuf, &bwr, sizeof(bwr)))
                ret = -EFAULT;
            goto out;
        }
    }
...
    if (copy_to_user(ubuf, &bwr, sizeof(bwr))) {
        ret = -EFAULT;
        goto out;
    }
out:
    return ret;
```

我们看看binder_thread_read内部逻辑。

```c
static int binder_thread_read(struct binder_proc *proc,
			      struct binder_thread *thread,
			      binder_uintptr_t binder_buffer, size_t size,
			      binder_size_t *consumed, int non_block)
{
	void __user *buffer = (void __user *)(uintptr_t)binder_buffer;
	void __user *ptr = buffer + *consumed;
	void __user *end = buffer + size;

	int ret = 0;
	int wait_for_proc_work;

	if (*consumed == 0) {
		if (put_user(BR_NOOP, (uint32_t __user *)ptr))
			return -EFAULT;
		ptr += sizeof(uint32_t);
	}

retry:
	wait_for_proc_work = thread->transaction_stack == NULL &&
				list_empty(&thread->todo);

	if (thread->return_error != BR_OK && ptr < end) {
		if (thread->return_error2 != BR_OK) {
			if (put_user(thread->return_error2, (uint32_t __user *)ptr))
				return -EFAULT;
			ptr += sizeof(uint32_t);
			binder_stat_br(proc, thread, thread->return_error2);
			if (ptr == end)
				goto done;
			thread->return_error2 = BR_OK;
		}
		if (put_user(thread->return_error, (uint32_t __user *)ptr))
			return -EFAULT;
		ptr += sizeof(uint32_t);
		binder_stat_br(proc, thread, thread->return_error);
		thread->return_error = BR_OK;
		goto done;
	}


	thread->looper |= BINDER_LOOPER_STATE_WAITING;
	if (wait_for_proc_work)
		proc->ready_threads++;

	binder_unlock(__func__);

	trace_binder_wait_for_work(wait_for_proc_work,
				   !!thread->transaction_stack,
				   !list_empty(&thread->todo));
	if (wait_for_proc_work) {
		if (!(thread->looper & (BINDER_LOOPER_STATE_REGISTERED |
					BINDER_LOOPER_STATE_ENTERED))) {
			binder_user_error("%d:%d ERROR: Thread waiting for process work before calling BC_REGISTER_LOOPER or BC_ENTER_LOOPER (state %x)\n",
				proc->pid, thread->pid, thread->looper);
			wait_event_interruptible(binder_user_error_wait,
						 binder_stop_on_user_error < 2);
		}
		binder_set_nice(proc->default_priority);
		if (non_block) {
			if (!binder_has_proc_work(proc, thread))
				ret = -EAGAIN;
		} else
			ret = wait_event_freezable_exclusive(proc->wait, binder_has_proc_work(proc, thread));
	} else {
		if (non_block) {
			if (!binder_has_thread_work(thread))
				ret = -EAGAIN;
		} else
			ret = wait_event_freezable(thread->wait, binder_has_thread_work(thread));
	}

	binder_lock(__func__);

	if (wait_for_proc_work)
		proc->ready_threads--;
	thread->looper &= ~BINDER_LOOPER_STATE_WAITING;

	if (ret)
		return ret;

	while (1) {
...
	}

done:

	*consumed = ptr - buffer;
...
	return 0;
}
```

原理和binder_thread_write相似。binder_thread_read 做了以下几件事情。
- 1.首先判断到此时binder 驱动没有读取任何数据时候，则会为用户空间返回的数据中，第一段数据加上BR_NOOP。
- 2.wait_for_proc_work 判断当前进程是否需要等待工作。这个标志位的判断条件为binder _thread的事务处理栈为空同时binder_thread 的todo list没有任何需要todo的项。
- 3.设置binder_thread->looper状态进入到了BINDER_LOOPER_STATE_WAITING状态
- 4.假如需要等待，则判断当前binder初始化的时候是可阻塞工作还是不可阻塞工作。如果是可阻塞，则会取出binder _thread->wait 等待队列，让本进程进入到等待当中。还记得我之前写的等待队列的本质吧。实际上就是把这个时候进程会通过进程调度，把当前进程的需要的cpu资源让渡出去。如果是非阻塞，则判断当前binder_thread中是否还有需要的工作，没有则直接返回。
- 5.当当前进程的等待队列被唤醒，则会把 thread->looper 的BINDER_LOOPER_STATE_WAITING关闭。
- 6.进入到while循环解析数据。

而此时的场景，我们并有任何的需要工作的队列，因此通过wait_event_freezable把service_manager阻塞起来。

## service_manager binder_parse获取binder驱动回复的消息消息。

```c
int binder_parse(struct binder_state *bs, struct binder_io *bio,
                 uintptr_t ptr, size_t size, binder_handler func)
{
    int r = 1;
    uintptr_t end = ptr + (uintptr_t) size;

    while (ptr < end) {
        uint32_t cmd = *(uint32_t *) ptr;
        ptr += sizeof(uint32_t);
#if TRACE
        fprintf(stderr,"%s:\n", cmd_name(cmd));
#endif
        switch(cmd) {
        case BR_NOOP:
            break;
....
        default:
            ALOGE("parse: OOPS %d\n", cmd);
            return -1;
        }
    }

    return r;
}
```

这里场景模拟，假如有某个线程唤醒了service_manager,此时ptr实际上就是readbuf这个缓冲区。我们不管这个数据如何，第一个返回的参数必定是BR_NOOP，告诉着service_manager开始读取数据的开头标志位。接着不断的移动指针，读取处理每一段信息。

因此我们可以模拟tcp封包一样模拟出binder驱动在通信时候，数据是如何封包的。

![binder通信封包.png](/images/binder通信封包.png)

特殊的当读取通信信息的时候，封包格式将如下：
![binder驱动读取之后返回的通信数据.png](/images/binder驱动读取之后返回的通信数据.png)


这里就是binder驱动在Android 系统中service_manager 体系的初始化。当然还有一种aidl的binder初始化，我将会在后面和大家揭晓。


### 总结
这里总结一副时序图，为了便于理解，我省略掉通过软中断到内核空间的过程。
![binder驱动在service系统初始化.png](/images/binder驱动在service系统初始化.png)

从上图我们大致上可以总结出Binder驱动在系统初始化的时候大致上分为以下三步：
- 1.binder_open 打开binder驱动文件，确认版本号，并把该进程以及相关信息映射到内核中
- 2.mmap 确认能够打开binder驱动之后，再把当前进程的地址和内核映射到一起。
- 3.把当前的service_manager作为一个binder实体注册到binder驱动中，作为第一个binder服务。
- 4.进入binder_loop。先通过ioctl 通知binder驱动此时service_manager进入到了循环模式。接着调用读取数据函数，进入阻塞状态。当service_manager被唤醒，则开始解析从binder传上来的数据。

到目前位置，我如下图已经将描红的部分在Android 服务系统中初始化的阐述完毕。
![binder驱动初始化.png](/images/binder驱动初始化.png)


能够注意到的是，此时我们还没有添加任何的binder 的服务进来。但是基础的dns(service_manager)和路由分发器(Binder驱动)已经准备好了，接下来，让我们聊聊client 和 server的初始化。



