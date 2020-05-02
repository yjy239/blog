---
title: Android 重学系列 Handler与相关系统调用的剖析(下)
top: false
cover: false
date: 2019-11-18 17:31:32
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
- Linux
---
# 前言
上一篇文章，和大家讲述了Handler的中使用到的eventfd系统调用原理。而本文将会着重剖析epoll系统调用，而整个handler核心的系统就是epoll。

如果遇到问题欢迎来到这里讨论:[https://www.jianshu.com/p/d38b2970ff3f](https://www.jianshu.com/p/d38b2970ff3f)


# 正文
在聊epoll的原理之前，我们来看看epoll在Handler中的使用。
epoll的使用一般分为三个步骤:
- 1.调用epoll_create构建一个epoll的句柄
```cpp
EpollFd = epoll_create(EPOLL_SIZE_HINT);
```
- 2.调用epoll_ctl 注册一个事件的监听，这个事件一般是文件描述符的数据是否发生变化
```cpp
epoll_ctl(mEpollFd, EPOLL_CTL_ADD, mWakeEventFd, & eventItem);
```
该方法的意思是，往mEpollFd句柄中注册一个新的事件监听mWakeEventFd，把eventItem作为相关的数据传入

- 3.调用epoll_wait 阻塞当前的循环，直到监听到数据流发生变化，就释放阻塞进行下一步
```cpp
epoll_wait(mEpollFd, eventItems, EPOLL_MAX_EVENTS, timeoutMillis);
```
该方法的意思就是指，当前将会监听mEpollFd句柄，设定了最大的监听量以及超时事件。如果发生了某些监听对象发生了变化，则把相关变化的数据输出到eventItems中。

知道了如何使用，我们就尝试着剖析一下依照这个调用顺序，解剖整个epoll的源码原理。

首先我们需要有一个意识，那就是epoll本质上和binder很相似， 但不是一个驱动，而是通过通过fs_initcall的方式，为内核添加新的功能。


## epoll的初始化
```cpp
static int __init eventpoll_init(void)
{
	struct sysinfo si;

	si_meminfo(&si);
	/*
	 * Allows top 4% of lomem to be allocated for epoll watches (per user).
	 */
	max_user_watches = (((si.totalram - si.totalhigh) / 25) << PAGE_SHIFT) /
		EP_ITEM_COST;
	BUG_ON(max_user_watches < 0);

	/*
	 * Initialize the structure used to perform epoll file descriptor
	 * inclusion loops checks.
	 */
	ep_nested_calls_init(&poll_loop_ncalls);

	/* Initialize the structure used to perform safe poll wait head wake ups */
	ep_nested_calls_init(&poll_safewake_ncalls);

	/* Initialize the structure used to perform file's f_op->poll() calls */
	ep_nested_calls_init(&poll_readywalk_ncalls);


	/* Allocates slab cache used to allocate "struct epitem" items */
	epi_cache = kmem_cache_create("eventpoll_epi", sizeof(struct epitem),
			0, SLAB_HWCACHE_ALIGN | SLAB_PANIC, NULL);

	/* Allocates slab cache used to allocate "struct eppoll_entry" */
	pwq_cache = kmem_cache_create("eventpoll_pwq",
			sizeof(struct eppoll_entry), 0, SLAB_PANIC, NULL);

	return 0;
}
fs_initcall(eventpoll_init);
```
能看到在epoll在内核启动时候，会初始化如下几个数据结构：
- 1.poll_loop_ncalls 用于缓存循环查找epoll文件描述符时候的缓存路径结构
- 2.poll_safewake_ncalls 保存着那些已经加入到等待队列那些可以安全唤醒的项。
- 3.poll_readywalk_ncalls 已经执行了file的poll操作的文件描述符
- 4.epi_cache 一个缓存的epitem队列
- 5.pwq_cache 一个缓存的eppoll_entry队列

这些对象是做什么的什么的，稍后的解析就能明白了。


## epoll_create源码解析
文件：/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/)/[libc](http://androidxref.com/9.0.0_r3/xref/bionic/libc/)/[bionic](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/)/[sys_epoll.cpp](http://androidxref.com/9.0.0_r3/xref/bionic/libc/bionic/sys_epoll.cpp)

```cpp
int epoll_create(int size) {
  if (size <= 0) {
    errno = EINVAL;
    return -1;
  }
  return epoll_create1(0);
}
```
能看到在Android的epoll_create其实这个size设置的毫无意义，直接会调用epoll_create1这个系统调用，并且flag为0.接下来看看内核中的方法。

文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventpoll.c](http://androidxref.com/kernel_3.18/xref/fs/eventpoll.c)

```cpp
SYSCALL_DEFINE1(epoll_create1, int, flags)
{
	int error, fd;
	struct eventpoll *ep = NULL;
	struct file *file;


	if (flags & ~EPOLL_CLOEXEC)
		return -EINVAL;

	error = ep_alloc(&ep);
	if (error < 0)
		return error;
	/*
	 * Creates all the items needed to setup an eventpoll file. That is,
	 * a file structure and a free file descriptor.
	 */
	fd = get_unused_fd_flags(O_RDWR | (flags & O_CLOEXEC));
	if (fd < 0) {
		error = fd;
		goto out_free_ep;
	}
	file = anon_inode_getfile("[eventpoll]", &eventpoll_fops, ep,
				 O_RDWR | (flags & O_CLOEXEC));
...
	ep->file = file;
	fd_install(fd, file);
	return fd;

...
}
```
我们一样可以和eventfd系统调用进行比较，做的是事情如下：
- 1.ep_alloc 初始化epoll需要的句柄以及所有的数据
- 2. get_unused_fd_flags 获取fdtable空闲的fd
- 3. anon_inode_getfile 构建一个名字为[eventpoll]的文件，并且把epoll对应的文件操作设置到file结构体中，把ep作为全局变量设置到file的私有数据中 
- 4. fd_install 把fd和file结构体关联起来。

### ep_alloc
```cpp
static int ep_alloc(struct eventpoll **pep)
{
	int error;
	struct user_struct *user;
	struct eventpoll *ep;

	user = get_current_user();
	error = -ENOMEM;
	ep = kzalloc(sizeof(*ep), GFP_KERNEL);
	if (unlikely(!ep))
		goto free_uid;

	spin_lock_init(&ep->lock);
	mutex_init(&ep->mtx);
	init_waitqueue_head(&ep->wq);
	init_waitqueue_head(&ep->poll_wait);
	INIT_LIST_HEAD(&ep->rdllist);
	ep->rbr = RB_ROOT;
	ep->ovflist = EP_UNACTIVE_PTR;
	ep->user = user;

	*pep = ep;

	return 0;

free_uid:
	free_uid(user);
	return error;
}
```
能看到这个过程实际上就是赋值eventpoll的过程。在这个过程为eventpoll初始化了如下的数据：
- 1.eventpoll 相关的线程的lock，mutex
- 2.eventpoll 中的等待队列头poll_wait
- 3.eventpoll 中文件描述符已经处理过poll方法，其实就是准备好的文件描述队列
- 4.eventpoll 中的红黑树根部
- 5.ovflist 输出到外界已经发生变化的文件描述符
- 6. user_struct 用于跟踪进程用户的信息

最后epollevent将会持有file结构体。

最后这些epollevent会被设置为file中的中的私有数据。

到这里epoll需要注意初始化数据结构就完成了，接下来看看epoll_ctl是怎么把需要监听的文件描述符设置到epoll中。

## epoll_ctl 的系统调用
```cpp
SYSCALL_DEFINE4(epoll_ctl, int, epfd, int, op, int, fd,
		struct epoll_event __user *, event)
{
	int error;
	int full_check = 0;
	struct fd f, tf;
	struct eventpoll *ep;
	struct epitem *epi;
	struct epoll_event epds;
	struct eventpoll *tep = NULL;

	error = -EFAULT;
	if (ep_op_has_event(op) &&
	    copy_from_user(&epds, event, sizeof(struct epoll_event)))
		goto error_return;

	error = -EBADF;
	f = fdget(epfd);
...

	/* Get the "struct file *" for the target file */
	tf = fdget(fd);

	/* The target file descriptor must support poll */
	error = -EPERM;
	if (!tf.file->f_op->poll)
		goto error_tgt_fput;

	/* Check if EPOLLWAKEUP is allowed */
	if (ep_op_has_event(op))
		ep_take_care_of_epollwakeup(&epds);

....

	ep = f.file->private_data;

	mutex_lock_nested(&ep->mtx, 0);
	if (op == EPOLL_CTL_ADD) {
		if (!list_empty(&f.file->f_ep_links) ||
						is_file_epoll(tf.file)) {
			full_check = 1;
			mutex_unlock(&ep->mtx);
			mutex_lock(&epmutex);
			if (is_file_epoll(tf.file)) {
				error = -ELOOP;
				if (ep_loop_check(ep, tf.file) != 0) {
					clear_tfile_check_list();
					goto error_tgt_fput;
				}
			} else
				list_add(&tf.file->f_tfile_llink,
							&tfile_check_list);
			mutex_lock_nested(&ep->mtx, 0);
			if (is_file_epoll(tf.file)) {
				tep = tf.file->private_data;
				mutex_lock_nested(&tep->mtx, 1);
			}
		}
	}


	epi = ep_find(ep, tf.file, fd);

	error = -EINVAL;
	switch (op) {
	case EPOLL_CTL_ADD:
		if (!epi) {
			epds.events |= POLLERR | POLLHUP;
			error = ep_insert(ep, &epds, tf.file, fd, full_check);
		} else
			error = -EEXIST;
		if (full_check)
			clear_tfile_check_list();
		break;
	case EPOLL_CTL_DEL:
		if (epi)
			error = ep_remove(ep, epi);
		else
			error = -ENOENT;
		break;
	case EPOLL_CTL_MOD:
		if (epi) {
			epds.events |= POLLERR | POLLHUP;
			error = ep_modify(ep, epi, &epds);
		} else
			error = -ENOENT;
		break;
	}
	if (tep != NULL)
		mutex_unlock(&tep->mtx);
	mutex_unlock(&ep->mtx);

...
}
```
epoll_ctl把文件描述符添加到监听中大致分为以下3个步骤：
- 1.首先从用户空间拷贝相关的信息。设置f为epoll_ctl传下来epoll句柄对应的fd，tfd则是需要监听对象对应的句柄。
- 2.循环检测监听对象的文件描述符是否出现嵌套深度过深
- 3.处理epoll_ctl的操作标志，如果是添加，调用ep_insert会把当前文件描述添加到缓存中，并且调用文件描述符的poll方法。通过ep_find找到有相同的epoll则会报错

值得注意的是后面两点，我们着重剖析看看。

### 循环检测每一个添加进来的监听对象的合法性
```cpp
static LIST_HEAD(tfile_check_list);
```
```cpp
    ep = f.file->private_data;

    mutex_lock_nested(&ep->mtx, 0);
    if (op == EPOLL_CTL_ADD) {
        if (!list_empty(&f.file->f_ep_links) ||
                        is_file_epoll(tf.file)) {
            full_check = 1;
            mutex_unlock(&ep->mtx);
            mutex_lock(&epmutex);
            if (is_file_epoll(tf.file)) {
                error = -ELOOP;
                if (ep_loop_check(ep, tf.file) != 0) {
                    clear_tfile_check_list();
                    goto error_tgt_fput;
                }
            } else
                list_add(&tf.file->f_tfile_llink,
                            &tfile_check_list);
            mutex_lock_nested(&ep->mtx, 0);
            if (is_file_epoll(tf.file)) {
                tep = tf.file->private_data;
                mutex_lock_nested(&tep->mtx, 1);
            }
        }
    }
```
当前判断是添加对象的操作则会处理一个额外的判断。
- epoll句柄对应的file结构体中f_ep_links队列不为空，或者目标监听的file结构体中含有poll方法。

说明这种情况比较特殊一个可能是类似socket文件描述符一样自身带有着poll方法，一种可能是本身就是epoll对象，这样就会出现一个环，当通知一个epoll有回唤醒另一个epoll对象，这个对象有可能继续唤醒回来，出现一个死循环。

- 都没有，说明此时是一个普通的文件描述符，直接添加到tfile_check_list。

如果目标文件有poll函数则把file中的私有数据赋值给tep。

我们先来注重看看第一种情况，其核心函数是ep_loop_check，一般常用是第一种情况。

#### ep_loop_check 检测嵌套循环
```cpp
/* Visited nodes during ep_loop_check(), so we can unset them when we finish */
static LIST_HEAD(visited_list);

#define EP_MAX_NESTS 4
```
```cpp
static int ep_loop_check(struct eventpoll *ep, struct file *file)
{
	int ret;
	struct eventpoll *ep_cur, *ep_next;

	ret = ep_call_nested(&poll_loop_ncalls, EP_MAX_NESTS,
			      ep_loop_check_proc, file, ep, current);
	/* clear visited list */
	list_for_each_entry_safe(ep_cur, ep_next, &visited_list,
							visited_list_link) {
		ep_cur->visited = 0;
		list_del(&ep_cur->visited_list_link);
	}
	return ret;
}
```
这段代码就是为了处理下面这个问题，那就是如果epoll自己监听自己怎么办？自己唤醒自己，接着继续通知自己数据来了又要唤醒自己。而且如果一个epoll注册多个相同的监听对象，岂不是会出现唤醒返回的结果出现重复的对象。

##### ep_call_nested
```cpp
static int ep_call_nested(struct nested_calls *ncalls, int max_nests,
			  int (*nproc)(void *, void *, int), void *priv,
			  void *cookie, void *ctx)
{
	int error, call_nests = 0;
	unsigned long flags;
	struct list_head *lsthead = &ncalls->tasks_call_list;
	struct nested_call_node *tncur;
	struct nested_call_node tnode;

	spin_lock_irqsave(&ncalls->lock, flags);


	list_for_each_entry(tncur, lsthead, llink) {
		if (tncur->ctx == ctx &&
		    (tncur->cookie == cookie || ++call_nests > max_nests)) {
			/*
			 * Ops ... loop detected or maximum nest level reached.
			 * We abort this wake by breaking the cycle itself.
			 */
			error = -1;
			goto out_unlock;
		}
	}

	/* Add the current task and cookie to the list */
	tnode.ctx = ctx;
	tnode.cookie = cookie;
	list_add(&tnode.llink, lsthead);

	spin_unlock_irqrestore(&ncalls->lock, flags);

	/* Call the nested function */
	error = (*nproc)(priv, cookie, call_nests);

	/* Remove the current task from the list */
	spin_lock_irqsave(&ncalls->lock, flags);
	list_del(&tnode.llink);
out_unlock:
	spin_unlock_irqrestore(&ncalls->lock, flags);

	return error;
}
```
为了弄懂整个方法，先标记以下几个关键的对象意味着什么：
- priv 其实是被监听文件的file结构体
- cookie 是目前要把被监听对象添加到epoll句柄的那个epoll监听主体
- nested_call_node 是nested_calls链表的子节点
- ctx 上下文是指当前执行当前系统调用对应的task_struct进程是哪一个

分清楚这些对象之后，链表lsthead(nested_calls的tasks_call_list)的循环实际上是就是查找全局变量poll_loop_ncalls中每一个子节点中的是否存在一模一样的进程，第二条件是判断当前的需要添加到的ep对象是否是同一个或者已经添加了超过4次。

如果不满足则会为当前这个目标file结构体设置ctx以及cookie,并且添加到lsthead(nested_calls的tasks_call_list)保存起来，接着执行上面传下来的方法指针，当执行完之后就把刚加入的nested_call_node从poll_loop_ncalls删除。为了更好的明白这段代码的逻辑，我们再来看看这个方法指针ep_loop_check_proc


##### ep_loop_check_proc
```cpp
static int ep_loop_check_proc(void *priv, void *cookie, int call_nests)
{
	int error = 0;
	struct file *file = priv;
	struct eventpoll *ep = file->private_data;
	struct eventpoll *ep_tovisit;
	struct rb_node *rbp;
	struct epitem *epi;

	mutex_lock_nested(&ep->mtx, call_nests + 1);
	ep->visited = 1;
	list_add(&ep->visited_list_link, &visited_list);
	for (rbp = rb_first(&ep->rbr); rbp; rbp = rb_next(rbp)) {
		epi = rb_entry(rbp, struct epitem, rbn);
		if (unlikely(is_file_epoll(epi->ffd.file))) {
			ep_tovisit = epi->ffd.file->private_data;
			if (ep_tovisit->visited)
				continue;
			error = ep_call_nested(&poll_loop_ncalls, EP_MAX_NESTS,
					ep_loop_check_proc, epi->ffd.file,
					ep_tovisit, current);
			if (error != 0)
				break;
		} else {

			if (list_empty(&epi->ffd.file->f_tfile_llink))
				list_add(&epi->ffd.file->f_tfile_llink,
					 &tfile_check_list);
		}
	}
	mutex_unlock(&ep->mtx);

	return error;
}
```
这一段代码其实就是不断的遍历挂在epoll监听主体的红黑树中每一子节点epitem结构体，检查每一个判断到有poll方法的file结构体，获取里面的私有数据epitem，判断是否已经遍历过了这个file结构体。一般遍历过的epitem，其visited就会为1.没遍历过的一般为0.

什么时候会出现1和0的差异呢？一般情况下，如果是一个没有连接到任何一个epoll主体对象的epoll对象都为0，链接过则为1.这样就能很好的区分出所有的epoll是否会出现链接监听重复了。

如果当前的对应epitem已经访问过了则查找下一个子节点，没有访问过，说明就要考虑一个特殊情况这个epoll或者说带有这poll方法的file结构体。这个情况就可能出现循环监听，因此需要不断向着子节点查询校验。

当找到一个没有重写poll的file结构体。此时是把对应节点下的f_tfile_llink拷贝到tfile_check_list。

为了减少递归次数，使用了visit_list记录已经访问过的文件，用visit标志位避免重复判断。

这个过程做了什么呢？其实这个过程就是为了解决循环嵌套监听做的努力？实际上没有做什么，太过深入细节反而容易忘记初衷：
```cpp
if (ep_loop_check(ep, tf.file) != 0) {
                    clear_tfile_check_list();
                    goto error_tgt_fput;
                }
```
其实就是在判断当前目标file中到error不为0的时候会报错，错误是什么时候返回的，就是在ep_call_nested的遍历循环中，通过检验当前进程属否出现loop深度过深(超过4层)，一旦超过则返回-1.也就是说不允许你嵌套监听过多层次。当然如果遇到了自己监听自己就会称为一个有向图数据结构一定会超出4层，一定会报错。

因此我们可以得到一个epoll_ctl使用细节，请不要自己监听自己，也不要epoll监听epoll的层数超过4层。


#### ep_insert 把当前被监听对象插入到epoll对象中
```cpp
static int ep_insert(struct eventpoll *ep, struct epoll_event *event,
		     struct file *tfile, int fd, int full_check)
{
	int error, revents, pwake = 0;
	unsigned long flags;
	long user_watches;
	struct epitem *epi;
	struct ep_pqueue epq;

	user_watches = atomic_long_read(&ep->user->epoll_watches);
	if (unlikely(user_watches >= max_user_watches))
		return -ENOSPC;
	if (!(epi = kmem_cache_alloc(epi_cache, GFP_KERNEL)))
		return -ENOMEM;

	/* Item initialization follow here ... */
	INIT_LIST_HEAD(&epi->rdllink);
	INIT_LIST_HEAD(&epi->fllink);
	INIT_LIST_HEAD(&epi->pwqlist);
	epi->ep = ep;
	ep_set_ffd(&epi->ffd, tfile, fd);
	epi->event = *event;
	epi->nwait = 0;
	epi->next = EP_UNACTIVE_PTR;
	if (epi->event.events & EPOLLWAKEUP) {
		error = ep_create_wakeup_source(epi);
		if (error)
			goto error_create_wakeup_source;
	} else {
		RCU_INIT_POINTER(epi->ws, NULL);
	}

	/* Initialize the poll table using the queue callback */
	epq.epi = epi;
	init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);


	revents = ep_item_poll(epi, &epq.pt);


	error = -ENOMEM;
	if (epi->nwait < 0)
		goto error_unregister;

	/*把file结构体的 f_ep_links指针指给epoll的flink方便epoll查找*/
	spin_lock(&tfile->f_lock);
	list_add_tail_rcu(&epi->fllink, &tfile->f_ep_links);
	spin_unlock(&tfile->f_lock);


	ep_rbtree_insert(ep, epi);

	/* now check if we've created too many backpaths */
	error = -EINVAL;
	if (full_check && reverse_path_check())
		goto error_remove_epi;

	/* We have to drop the new item inside our item list to keep track of it */
	spin_lock_irqsave(&ep->lock, flags);

	/* If the file is already "ready" we drop it inside the ready list */
	if ((revents & event->events) && !ep_is_linked(&epi->rdllink)) {
		list_add_tail(&epi->rdllink, &ep->rdllist);
		ep_pm_stay_awake(epi);

		/* Notify waiting tasks that events are available */
		if (waitqueue_active(&ep->wq))
			wake_up_locked(&ep->wq);
		if (waitqueue_active(&ep->poll_wait))
			pwake++;
	}

	spin_unlock_irqrestore(&ep->lock, flags);

	atomic_long_inc(&ep->user->epoll_watches);

	/* We have to call this outside the lock */
	if (pwake)
		ep_poll_safewake(&ep->poll_wait);

	return 0;

... 
}

```
epitem的插入大致分为如下几个步骤：
- 1.初始化epitem中所有的数据，rdllink，fllink，pwqlist这几个队列，设置epi中的event数据就是从系统调用传下来的数据(eventItem)，如果打开了EPOLLWAKEUP则创建一个wakeup_source注册监听，用于避免系统沉睡(电量消耗检测的关键之一，一般在AlarmManager和InputManager中使用)。
- 2.调用被监听对象的poll方法
- 3.把epi对象添加到ep的红黑树中
- 4.如果file结构体已经准备好了，就添加到准备列表中。接着保持cpu避免沉睡，尝试着唤醒对应进程，判断当前的事件是可以走得通的。

其实重点是从第二点开始，我们先从第二点开始阅读。

#### 调用被监听对象的poll方法
```cpp
struct ep_pqueue {
	poll_table pt;
	struct epitem *epi;
};
```
```c
    /* Initialize the poll table using the queue callback */
    epq.epi = epi;
    init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
    revents = ep_item_poll(epi, &epq.pt);
```
init_poll_funcptr 将方法ep_ptable_queue_proc赋值到poll_table中。接着调用ep_item_poll。
```cpp
static inline unsigned int ep_item_poll(struct epitem *epi, poll_table *pt)
{
	pt->_key = epi->event.events;

	return epi->ffd.file->f_op->poll(epi->ffd.file, pt) & epi->event.events;
}
```
此时会调用目标文件的poll方法。而这个目标文件在此时是eventfd，换句话说调用的是eventfd的poll的方法。

文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventfd.c](http://androidxref.com/kernel_3.18/xref/fs/eventfd.c)
```cpp
static unsigned int eventfd_poll(struct file *file, poll_table *wait)
{
	struct eventfd_ctx *ctx = file->private_data;
	unsigned int events = 0;
	unsigned long flags;

	poll_wait(file, &ctx->wqh, wait);

	spin_lock_irqsave(&ctx->wqh.lock, flags);
	if (ctx->count > 0)
		events |= POLLIN;
	if (ctx->count == ULLONG_MAX)
		events |= POLLERR;
	if (ULLONG_MAX - 1 > ctx->count)
		events |= POLLOUT;
	spin_unlock_irqrestore(&ctx->wqh.lock, flags);

	return events;
}
```
在这个方法中有一个核心方法poll_wait。这个方法取出了file的私有数据拿到eventfd的上下文中的等待队列头,并且调用poll_table中的proc方法
```cpp
static inline void poll_wait(struct file * filp, wait_queue_head_t * wait_address, poll_table *p)
{
	if (p && p->_qproc && wait_address)
		p->_qproc(filp, wait_address, p);
}

```
而这个方法刚好就是上面init_poll_funcptr初始化进来的ep_ptable_queue_proc。

##### ep_ptable_queue_proc
文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventpoll.c](http://androidxref.com/kernel_3.18/xref/fs/eventpoll.c)
```cpp
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead,
				 poll_table *pt)
{
	struct epitem *epi = ep_item_from_epqueue(pt);
	struct eppoll_entry *pwq;

	if (epi->nwait >= 0 && (pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL))) {
		init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
		pwq->whead = whead;
		pwq->base = epi;
		add_wait_queue(whead, &pwq->wait);
		list_add_tail(&pwq->llink, &epi->pwqlist);
		epi->nwait++;
	} else {
		/* We have to signal that an error occurred */
		epi->nwait = -1;
	}
}
```
这里出现了几个等待队列的头部：
- whead 是从eventfd传下来的等待队列
- pwq 是eppoll_entry ，在这个结构体中有包含着两个等待队列头部，whead指代原来目标被监听对象的等待队列头，这里指的是eventfd的等待队列。把whead添加到pwq->wait队列中。
```cpp
struct eppoll_entry {
	/* List header used to link this structure to the "struct epitem" */
	struct list_head llink;

	/* The "base" pointer is set to the container "struct epitem" */
	struct epitem *base;

	/*
	 * Wait queue item that will be linked to the target file wait
	 * queue head.
	 */
	wait_queue_t wait;

	/* The wait queue head that linked the "wait" wait queue item */
	wait_queue_head_t *whead;
};

```

如果nwait标志位大于等于0(此时设置的是0),并且申请了pwq_cache一段内存是成功的。此时将会初始化pwq中的等待头，并且设置一个poll_wait的回调函数；接着把eventfd中的等待队列头部添加到pwq的wait队列，这样就相当于把epoll中的pwqlist和eventfd的等待队列关联起来；最后把当前的pwq->llink添加到epi的pwqlist中。为后面回调作准备。

这种设计十分常见，几乎所有关于poll和epoll方法的重写都是这样设计的。需要重写一个poll_wait的方法，把自己的等待队列和上层调度者的等待队列关联起来，这样一旦唤醒了该文件的等待队列同时也会唤起上层调度者对应的等待队列。

在这个过程中做了一个很重要的事情，那就是设定了ep_poll_callback方法作为自定义唤醒方法。每当想要唤醒挂起的进程将会执行这个方法，我们稍后再聊。



#### 把epi对象添加到ep的红黑树中
```cpp
/*把file结构体的 f_ep_links指针指给epoll的flink方便epoll查找*/
	spin_lock(&tfile->f_lock);
	list_add_tail_rcu(&epi->fllink, &tfile->f_ep_links);
	spin_unlock(&tfile->f_lock);

	ep_rbtree_insert(ep, epi);
```
```cpp
static void ep_rbtree_insert(struct eventpoll *ep, struct epitem *epi)
{
	int kcmp;
	struct rb_node **p = &ep->rbr.rb_node, *parent = NULL;
	struct epitem *epic;

	while (*p) {
		parent = *p;
		epic = rb_entry(parent, struct epitem, rbn);
		kcmp = ep_cmp_ffd(&epi->ffd, &epic->ffd);
		if (kcmp > 0)
			p = &parent->rb_right;
		else
			p = &parent->rb_left;
	}
	rb_link_node(&epi->rbn, parent, p);
	rb_insert_color(&epi->rbn, &ep->rbr);
}
```
能看到这里仅仅只是一个很常规的红黑树添加的方法，找到合适的地方插入到eventpoll结构体中的rbr最后进行左右旋转平衡，对红黑树算法感兴趣的可以阅读我之前写的红黑树一文。


#### 校验新增的epitem并添加到准备队列
```cpp
 if (full_check && reverse_path_check())
        goto error_remove_epi;

    /* We have to drop the new item inside our item list to keep track of it */
    spin_lock_irqsave(&ep->lock, flags);

    /* If the file is already "ready" we drop it inside the ready list */
    if ((revents & event->events) && !ep_is_linked(&epi->rdllink)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);
        ep_pm_stay_awake(epi);

        /* Notify waiting tasks that events are available */
        if (waitqueue_active(&ep->wq))
            wake_up_locked(&ep->wq);
        if (waitqueue_active(&ep->poll_wait))
            pwake++;
    }

    spin_unlock_irqrestore(&ep->lock, flags);

    atomic_long_inc(&ep->user->epoll_watches);

    /* We have to call this outside the lock */
    if (pwake)
        ep_poll_safewake(&ep->poll_wait);
```
在这个过程中主要做了两件事情：
- 1.reverse_path_check校验是否会出现唤醒风暴
- 2.检查是否出现遗漏的event监听时间，并添加到准备队列

##### reverse_path_check校验是否会出现唤醒风暴
```cpp
static const int path_limits[PATH_ARR_SIZE] = { 1000, 500, 100, 50, 10 };
static int path_count[PATH_ARR_SIZE];


static int path_count_inc(int nests)
{
	/* Allow an arbitrary number of depth 1 paths */
	if (nests == 0)
		return 0;

	if (++path_count[nests] > path_limits[nests])
		return -1;
	return 0;
}

static void path_count_init(void)
{
	int i;

	for (i = 0; i < PATH_ARR_SIZE; i++)
		path_count[i] = 0;
}

static int reverse_path_check_proc(void *priv, void *cookie, int call_nests)
{
	int error = 0;
	struct file *file = priv;
	struct file *child_file;
	struct epitem *epi;

	/* CTL_DEL can remove links here, but that can't increase our count */
	rcu_read_lock();
	list_for_each_entry_rcu(epi, &file->f_ep_links, fllink) {
		child_file = epi->ep->file;
		if (is_file_epoll(child_file)) {
			if (list_empty(&child_file->f_ep_links)) {
				if (path_count_inc(call_nests)) {
					error = -1;
					break;
				}
			} else {
				error = ep_call_nested(&poll_loop_ncalls,
							EP_MAX_NESTS,
							reverse_path_check_proc,
							child_file, child_file,
							current);
			}
			if (error != 0)
				break;
		} else {
			printk(KERN_ERR "reverse_path_check_proc: "
				"file is not an ep!\n");
		}
	}
	rcu_read_unlock();
	return error;
}

static int reverse_path_check(void)
{
	int error = 0;
	struct file *current_file;

	/* let's call this for all tfiles */
	list_for_each_entry(current_file, &tfile_check_list, f_tfile_llink) {
		path_count_init();
		error = ep_call_nested(&poll_loop_ncalls, EP_MAX_NESTS,
					reverse_path_check_proc, current_file,
					current_file, current);
		if (error)
			break;
	}
	return error;
}
```
在上面的ep_loop_check是为了避免监听嵌套层级过深，这里则会判断每一个层级是否过于庞大。对于epoll来说，为了避免每一层链接的带有epoll监听对象过大，对每一层epoll都做了大小的限制。因为一旦一个层级放置监听数量过大的另一个epoll会导致一旦唤醒就会唤醒一场风暴一样，卷席整个系统，导致性能急速下降。

为了处理这个问题，epoll对每一层做了如下的数量限制：
> 第0层1000，第1层500，第2层100，第3层50，第4层10

那么我们求一下总数，一个epoll对象一共能够监听能够监听2.5*10^10 这么多。其实也足够使用了。不过面向服务器开发的朋友，倒是有可能使用这么多，到底怎么把socket链接均匀的分布在不同epoll也是不错的优化点。

##### 添加到准备队列中
```cpp
 if ((revents & event->events) && !ep_is_linked(&epi->rdllink)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);
        ep_pm_stay_awake(epi);

        /* Notify waiting tasks that events are available */
        if (waitqueue_active(&ep->wq))
            wake_up_locked(&ep->wq);
        if (waitqueue_active(&ep->poll_wait))
            pwake++;
    }
```
能看到当epi的rdllink没有添加到ep->rdllist)，则去添加；接着调用ep_pm_stay_awake，如果初始化了epitem中的ws对象，则会避免cpu沉睡，接着判断ep所在的等待队列是否存在，此时虽然初始化了，但是没有加入到等待队列中。同理poll_wait等待队列，这个队列一般是处理poll文件操作的。

从这里面可以得知，如果我们已经在监听了，同时在注册新的监听文件描述符同时，发生了事件事件变化，此时也会把相应的监听对象添加到eventpoll的rdllist准备队列。其实准备队列就是指已经监听到发生变化的文件描述符，准备通过epoll_wait返回上层的核心数据结构。


### epoll_wait 系统调用等待触发epoll监听回调
```cpp
epoll_wait(mEpollFd, eventItems, EPOLL_MAX_EVENTS, timeoutMillis);
```
把对应的文件描述符注册到epoll之后，接着就开始尝试着阻塞监听epoll中所有注册到epoll的文件描述符的数据变化。一旦发生变化则会调上来，而所有发生变化的对应的事件就是eventItems中的数据。


文件：/[fs](http://androidxref.com/kernel_3.18/xref/fs/)/[eventpoll.c](http://androidxref.com/kernel_3.18/xref/fs/eventpoll.c)
```cpp
SYSCALL_DEFINE4(epoll_wait, int, epfd, struct epoll_event __user *, events,
		int, maxevents, int, timeout)
{
	int error;
	struct fd f;
	struct eventpoll *ep;

	/* The maximum number of event must be greater than zero */
	if (maxevents <= 0 || maxevents > EP_MAX_EVENTS)
		return -EINVAL;

	/* Verify that the area passed by the user is writeable */
	if (!access_ok(VERIFY_WRITE, events, maxevents * sizeof(struct epoll_event)))
		return -EFAULT;

	/* Get the "struct file *" for the eventpoll file */
	f = fdget(epfd);
...
	if (!is_file_epoll(f.file))
		goto error_fput;

	ep = f.file->private_data;

	/* Time to fish for events ... */
	error = ep_poll(ep, events, maxevents, timeout);

...
	return error;
}
```

在这个系统调用中核心方法是ep_poll。


### ep_poll
```cpp
static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,
		   int maxevents, long timeout)
{
	int res = 0, eavail, timed_out = 0;
	unsigned long flags;
	long slack = 0;
	wait_queue_t wait;
	ktime_t expires, *to = NULL;

	if (timeout > 0) {
		struct timespec end_time = ep_set_mstimeout(timeout);

		slack = select_estimate_accuracy(&end_time);
		to = &expires;
		*to = timespec_to_ktime(end_time);
	} else if (timeout == 0) {
		/*
		 * Avoid the unnecessary trip to the wait queue loop, if the
		 * caller specified a non blocking operation.
		 */
		timed_out = 1;
		spin_lock_irqsave(&ep->lock, flags);
		goto check_events;
	}

fetch_events:
	spin_lock_irqsave(&ep->lock, flags);

	if (!ep_events_available(ep)) {
		/*
		 * We don't have any available event to return to the caller.
		 * We need to sleep here, and we will be wake up by
		 * ep_poll_callback() when events will become available.
		 */
		init_waitqueue_entry(&wait, current);
		__add_wait_queue_exclusive(&ep->wq, &wait);

		for (;;) {
			/*
			 * We don't want to sleep if the ep_poll_callback() sends us
			 * a wakeup in between. That's why we set the task state
			 * to TASK_INTERRUPTIBLE before doing the checks.
			 */
			set_current_state(TASK_INTERRUPTIBLE);
			if (ep_events_available(ep) || timed_out)
				break;
			if (signal_pending(current)) {
				res = -EINTR;
				break;
			}

			spin_unlock_irqrestore(&ep->lock, flags);
			if (!freezable_schedule_hrtimeout_range(to, slack,
								HRTIMER_MODE_ABS))
				timed_out = 1;

			spin_lock_irqsave(&ep->lock, flags);
		}
		__remove_wait_queue(&ep->wq, &wait);

		set_current_state(TASK_RUNNING);
	}
check_events:
	/* Is it worth to try to dig for events ? */
	eavail = ep_events_available(ep);

	spin_unlock_irqrestore(&ep->lock, flags);

	/*
	 * Try to transfer events to user space. In case we get 0 events and
	 * there's still timeout left over, we go trying again in search of
	 * more luck.
	 */
	if (!res && eavail &&
	    !(res = ep_send_events(ep, events, maxevents)) && !timed_out)
		goto fetch_events;

	return res;
}
```

首先这里先获取timeout，如果是0则会理解进入到check_events标签对应的代码段，否则则会先进入fetch_events代码段。先来弄清楚一般情况，设置了timeout的epoll_wait。

在fetch_events代码段中做了如下的事情，先把之前在ep_alloc初始化好的ep->wq将会加入到当前的进程的等待队列中，进行超时等待。这个过程允许中断打断。等待被监听对象唤起当前的进程。

接下来将会执行check_events代码段，这个代码段会判断当前的准备队列是否为空，为空则没有必要执行，直接返回。不为空则调用ep_send_events。

在这里需要注意一点，此时epoll_wait使用eventpoll中的wq作为等待队列进行进程的挂起处理。而这个对象实际上是可以被被监听对象打断的，这个时候就来看看在epoll_ctl设置监听时候设置到epi->pwqlist中的自定义唤醒进程方法。

#### ep_poll_callback自定义唤醒方法
下面这个方法就是整个回调机制的核心
```cpp
static int ep_poll_callback(wait_queue_t *wait, unsigned mode, int sync, void *key)
{
	int pwake = 0;
	unsigned long flags;
	struct epitem *epi = ep_item_from_wait(wait);
	struct eventpoll *ep = epi->ep;

....
	spin_lock_irqsave(&ep->lock, flags);

...

	if (unlikely(ep->ovflist != EP_UNACTIVE_PTR)) {
		if (epi->next == EP_UNACTIVE_PTR) {
			epi->next = ep->ovflist;
			ep->ovflist = epi;
			if (epi->ws) {
				__pm_stay_awake(ep->ws);
			}

		}
		goto out_unlock;
	}

	/* If this file is already in the ready list we exit soon */
	if (!ep_is_linked(&epi->rdllink)) {
		list_add_tail(&epi->rdllink, &ep->rdllist);
		ep_pm_stay_awake_rcu(epi);
	}


	if (waitqueue_active(&ep->wq))
		wake_up_locked(&ep->wq);
	if (waitqueue_active(&ep->poll_wait))
		pwake++;

out_unlock:
	spin_unlock_irqrestore(&ep->lock, flags);

	/* We have to call this outside the lock */
	if (pwake)
		ep_poll_safewake(&ep->poll_wait);

	return 1;
}
```
通过wait等待队列反过来找epitem；接着把当前的epitem添加到对应eventpoll的ovflist链表中；把epi->rdllink添加到ep的ep->rdllist的尾部，因为是一个链表环所以也是头部，解析来要查找什么发生了变化的file只需要读取头部即可。接着调用wake_up_locked打断epoll_wait的循环。如果需要则调用ep_poll_safewake处理调用poll方法而在挂起的进程。

明白这点之后继续看ep_send_events方法。



#### ep_send_events
```cpp
static int ep_send_events(struct eventpoll *ep,
			  struct epoll_event __user *events, int maxevents)
{
	struct ep_send_events_data esed;

	esed.maxevents = maxevents;
	esed.events = events;

	return ep_scan_ready_list(ep, ep_send_events_proc, &esed, 0, false);
}
```
调用ep_scan_ready_list，并把ep_send_events_proc方法指针传入。
```cpp
static int ep_scan_ready_list(struct eventpoll *ep,
			      int (*sproc)(struct eventpoll *,
					   struct list_head *, void *),
			      void *priv, int depth, bool ep_locked)
{
	int error, pwake = 0;
	unsigned long flags;
	struct epitem *epi, *nepi;
	LIST_HEAD(txlist);

	...
	spin_lock_irqsave(&ep->lock, flags);
	list_splice_init(&ep->rdllist, &txlist);
	ep->ovflist = NULL;
	spin_unlock_irqrestore(&ep->lock, flags);

	/*
	 * Now call the callback function.
	 */
	error = (*sproc)(ep, &txlist, priv);

	spin_lock_irqsave(&ep->lock, flags);
	/*
	 * During the time we spent inside the "sproc" callback, some
	 * other events might have been queued by the poll callback.
	 * We re-insert them inside the main ready-list here.
	 */
	for (nepi = ep->ovflist; (epi = nepi) != NULL;
	     nepi = epi->next, epi->next = EP_UNACTIVE_PTR) {

		if (!ep_is_linked(&epi->rdllink)) {
			list_add_tail(&epi->rdllink, &ep->rdllist);
			ep_pm_stay_awake(epi);
		}
	}

	ep->ovflist = EP_UNACTIVE_PTR;


	list_splice(&txlist, &ep->rdllist);
	__pm_relax(ep->ws);

	if (!list_empty(&ep->rdllist)) {

		if (waitqueue_active(&ep->wq))
			wake_up_locked(&ep->wq);
		if (waitqueue_active(&ep->poll_wait))
			pwake++;
	}
	spin_unlock_irqrestore(&ep->lock, flags);

	if (!ep_locked)
		mutex_unlock(&ep->mtx);

	/* We have to call this outside the lock */
	if (pwake)
		ep_poll_safewake(&ep->poll_wait);

	return error;
}
```
在这个过程中会把ovflist设置为NULL，这个只是一个标志位告诉epoll它监听的文件出现了状态的变化；接着把rdllist拷贝到txlist；然后会调用ep_send_events_proc方法拷贝变化的数据到用户空间对应的eventpoll对象中。最后再检测一次是否还有ovflist中是否有遗漏的数据。

因为在从内核拷贝到用户空间这个行为并不是一个原子操作，可能出现异步的情况，这个时候可能还在ep_send_events_proc中进行数据的拷贝，此时又进行了回调，因此需要最后再一次的校验和添加到rdllist中并且再来一次wake_up_locked步骤重新执行一次该行为。

##### ep_read_events_proc
最后再看看这个拷贝数据的核心方法
```cpp
static int ep_send_events_proc(struct eventpoll *ep, struct list_head *head,
			       void *priv)
{
	struct ep_send_events_data *esed = priv;
	int eventcnt;
	unsigned int revents;
	struct epitem *epi;
	struct epoll_event __user *uevent;
	struct wakeup_source *ws;
	poll_table pt;

	init_poll_funcptr(&pt, NULL);

	/*
	 * We can loop without lock because we are passed a task private list.
	 * Items cannot vanish during the loop because ep_scan_ready_list() is
	 * holding "mtx" during this call.
	 */
	for (eventcnt = 0, uevent = esed->events;
	     !list_empty(head) && eventcnt < esed->maxevents;) {
		epi = list_first_entry(head, struct epitem, rdllink);

		/*
		 * Activate ep->ws before deactivating epi->ws to prevent
		 * triggering auto-suspend here (in case we reactive epi->ws
		 * below).
		 *
		 * This could be rearranged to delay the deactivation of epi->ws
		 * instead, but then epi->ws would temporarily be out of sync
		 * with ep_is_linked().
		 */
		ws = ep_wakeup_source(epi);
		if (ws) {
			if (ws->active)
				__pm_stay_awake(ep->ws);
			__pm_relax(ws);
		}

		list_del_init(&epi->rdllink);

		revents = ep_item_poll(epi, &pt);

		/*
		 * If the event mask intersect the caller-requested one,
		 * deliver the event to userspace. Again, ep_scan_ready_list()
		 * is holding "mtx", so no operations coming from userspace
		 * can change the item.
		 */
		if (revents) {
			if (__put_user(revents, &uevent->events) ||
			    __put_user(epi->event.data, &uevent->data)) {
				list_add(&epi->rdllink, head);
				ep_pm_stay_awake(epi);
				return eventcnt ? eventcnt : -EFAULT;
			}
			eventcnt++;
			uevent++;
			if (epi->event.events & EPOLLONESHOT)
				epi->event.events &= EP_PRIVATE_BITS;
			else if (!(epi->event.events & EPOLLET)) {

				list_add_tail(&epi->rdllink, &ep->rdllist);
				ep_pm_stay_awake(epi);
			}
		}
	}

	return eventcnt;
}
```
做了如下几点事情：
- 1.首先清除上一次残留下来的准备队列。
- 2.进入用户空间对应的epoll_event指针数组不断向后循环。在循环中获取从ep_poll_callback回调回来的eventpoll中的全局准备队列的头部，不断的通过__put_user从内核空间拷贝到用户空间中（__put_user 比起copy_to_user拷贝的数量要更小更快）.能走到这个拷贝函数是因为再一次的调用poll方法，确认对应的文件描述符中的缓冲区是否返回正常的返回码(大于0，一般的实现是指缓冲区中是否还有数据)，又因为此时polltable中的方法是null，不会循环添加等待队列。
- 3.处理EPOLLET边缘触发和EPOLLLT水平触发的区别。能看到在循环的末尾如果没有打开EPOLLET(边缘触发)，则会继续把当前的epi添加到eventpoll中的准备队列中。

这就是边缘触发和水平触发实现核心，如果返回了正常的数据，同时发现关闭了边缘触发的标志位，则会继续把当前的epitem添加到全局的eventpoll中的准备队列，继续下次读取，知道对应文件描述符中poll操作返回0为止。


这就是在内核中怎么实现边缘触发（状态变化不管数据缓冲区是否有数据就返回一次）和水平触发(只要缓冲区还有数据则会不断的触发返回)。


## 总结

epoll之所以叫做eventpoll，其实核心是执行每一个注册到epoll中文件描述符的poll方法。每当调用每一个文件描述符的poll的方法时候，就会把自己的等待行为和被监听事件链接到一起，同时被打断回调。

epoll第一次阅读源码必定会头大(作者就是这样)，因为里面有数个等待队列，每个等待队列做的事情都不一样，如果没注意到这些等待队列做的事情，逻辑将会混乱。

里面主要包含三个等待队列:
- eventpoll.wq 这个是主要的等待队列，当调用epoll_wait的时候，就是用这个等待队列进行进程的调度挂起。于此同时在ep_poll_callback中，将会获取到ep对象并且打断这个等待队列的挂起

- eventpoll.pwqlist 主要就是为了和被监听的文件描述符poll中的等待队列关联起来。一旦进行被监听事件发生了需要打断poll方法的等待队列挂起操作时候将会，通知到epoll的回调

- eventpoll.poll_wait 这个等待队列一般是用在epoll本身的poll方法中。

在这个过程中，每监听一个事件，就会在当前进程的eventpoll的文件描述符中的eventpoll的红黑树中增加一个epitem对象。

每当被监听事件被唤起时候，将会带着自定义唤起事件一起唤起整个epoll。在回调中，会把自己添加到eventpoll的准备队列中，后面的扫描拷贝。

下面是epoll的设计图:
![epoll设计模型.png](https://upload-images.jianshu.io/upload_images/9880421-b01329ea36c5336a.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)



## 思考

最后再来解决一下开篇的疑问，为什么在Handler的Looper是一个死循环不会卡死?因为Handler的核心是epoll，epoll是一个异步回调监听事件变化状态的系统调用，当没有事件的时候将会进入到进程挂起。

为什么Handler不会引起ANR？ANR的管理是在AMS中进行一个Handler的延时事件，当到达时间后还没有拆出掉这个handler事件将会爆出ANR异常。而Hander整个过程并没有涉及到这些流程？返回来说，ANR是依赖于Handler的机制？只有会专门开一篇聊anr。

当我们彻底理解epoll的源码实现之后，让我们反过来想想Handler为什么这么设计？Handler为了在整个Android系统来说可说是一个命脉。除去从Zygote到四大组件的启动的流程，几乎其他所有的操作都是在mainhandler中完成的，无论是点击触摸事件，还是View的绘制。


只要写过OpenGL就知道，一个显示系统也好，操作系统也好，所有的操作都不可避免的需要在一个循环中处理，只有在一个循环中才能保证系统源源不断的运行。但是并不是所有的事件都必须在所有的循环中都检测一遍执行一遍，这样就太消耗性能。相反，如果有一个系统调用可以做到只需要更新需要更新的系统事件，其他时候就把资源让渡给更加需要的地方，才是一个系统的合理设计。

也是基于这个思路，在poll,select之上就诞生了epoll系统调用。这个系统调用通过回调很灵活的解决了资源调度的合理分配。

而Handler作为整个系统的运行命脉使用epoll能够监听大量的事件，且能对所有事件的变化快速的反应过来，这是一个极好的设计。于此同时，因为epoll在内核中会拷贝数据，为了加速epoll的唤醒速度，Android特定设计了一个唤醒文件描述符eventfd作为Handler的唤醒标志。在上一篇文章阅读eventfd的源码，可以知道这是一个用户态内核态进程线程之间快速的通知，而且数据量永远超不过一个long型，对于put_user来说这简直就是天大的喜事，因为它设计出来就是为了拷贝基础类型。

基于这种回调的方式，Handler才会被称为异步工具。没工作的时候就通过nativePollOnce挂起进程，让渡资源。


我们抛开Android系统，把眼光放在整个领域上。如网络编程，所有百万级别的服务器全部都是用了epoll系统调用进行设计。为什么？很直观的一个数据，我们使用select或者poll把socket放在一个池子中每一次有数据变化了就进行循环检测每一个socket中数据流的变化，这样就会出现O(n)的时间消耗，虽然O(n)在算法中属于比较好的时间复杂度，但是量一大就会变成一百万一次循环，这是不可能接受的。因此如果有办法快速得知哪些socket出现了变化并且快速处理，这是一个从O(n)下降到O(1)级别的优化，让服务器承载更大网络连接成为了可能。

而在Android中，也有类似的优化。如腾讯开源的mars就是通过epoll进一步优化整个网络链接。


所以为什么说无论是前端也好，后端也好。我喜欢说一句话，殊途同归。只要开发是基于某个平台核心进行的，那么必须要对该平台的核心有一定的理解，才能做得更好。



## 后话
接下来再补充一篇之前写遗漏的Application的初始化与绑定，接下来就让我们开启Android渲染系统。对了，在这里我稍微宣扬一下我的[个人博客](https://yjy239.github.io/)，有兴趣可以来这里看看，会同步更新移植文章，可能有其他更多杂谈。








