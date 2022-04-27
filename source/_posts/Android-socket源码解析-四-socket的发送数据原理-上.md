---
title: Android socket源码解析(四)socket的发送数据原理(上)
top: false
cover: false
date: 2022-04-24 23:24:04
img:
tag: socket
description:
author: yjy239
summary:
---

# 前言

上一篇文章仔细的聊了下socket的connect的原理。本文来自仔细聊聊socket发送的原理。

首先看看socket在调用connect之后，是如何调用api发送数据包的：

```java
    InputStream inputStream = socket.getInputStream();
    byte[] bytes = new byte[1024];
    int len;
    StringBuilder sb = new StringBuilder();

    while ((len = inputStream.read(bytes)) != -1) {
      sb.append(new String(bytes, 0, len, "UTF-8"));
    }

    OutputStream outputStream = socket.getOutputStream();
    outputStream.write("...".getBytes("UTF-8"));
```

可以看到本质上使用了write的系统调用，间接调用socket的句柄发送数据。关于write的jni调用逻辑可以阅读这一篇文章：[Okio源码解析](https://www.jianshu.com/p/5061860545ef).

在这里`socket.getOutputStream` 则是获取一个SocketOutputStream 输出流对象。

```java
private void socketWrite(byte b[], int off, int len) throws IOException {


        if (len <= 0 || off < 0 || len > b.length - off) {
            if (len == 0) {
                return;
            }
            throw new ArrayIndexOutOfBoundsException("len == " + len
                    + " off == " + off + " buffer length == " + b.length);
        }

        FileDescriptor fd = impl.acquireFD();
        try {
            // Android-added: Check BlockGuard policy in socketWrite.
            BlockGuard.getThreadPolicy().onNetwork();
            socketWrite0(fd, b, off, len);
        } catch (SocketException se) {
            if (se instanceof sun.net.ConnectionResetException) {
                impl.setConnectionResetPending();
                se = new SocketException("Connection reset");
            }
            if (impl.isClosedOrPending()) {
                throw new SocketException("Socket closed");
            } else {
                throw se;
            }
        } finally {
            impl.releaseFD();
        }
    }

    public void write(byte b[], int off, int len) throws IOException {
        socketWrite(b, off, len);
    }
```

核心就是这个`socketWrite0` native方法。

# 正文

文件：/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[ojluni](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/)/[native](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/native/)/[SocketOutputStream.c](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/native/SocketOutputStream.c)


```c
JNIEXPORT void JNICALL
SocketOutputStream_socketWrite0(JNIEnv *env, jobject this,
                                              jobject fdObj,
                                              jbyteArray data,
                                              jint off, jint len) {
    char *bufP;
    char BUF[MAX_BUFFER_LEN];
    int buflen;
    int fd;

    if (IS_NULL(fdObj)) {
       ...
        return;
    } else {
        fd = (*env)->GetIntField(env, fdObj, IO_fd_fdID);

        if (fd == -1) {
            ...
            return;
        }

    }

    if (len <= MAX_BUFFER_LEN) {
        bufP = BUF;
        buflen = MAX_BUFFER_LEN;
    } else {
        buflen = min(MAX_HEAP_BUFFER_LEN, len);
        bufP = (char *)malloc((size_t)buflen);

        /* if heap exhausted resort to stack buffer */
        if (bufP == NULL) {
            bufP = BUF;
            buflen = MAX_BUFFER_LEN;
        }
    }

    while(len > 0) {
        int loff = 0;
        int chunkLen = min(buflen, len);
        int llen = chunkLen;
        (*env)->GetByteArrayRegion(env, data, off, chunkLen, (jbyte *)bufP);

        while(llen > 0) {
            int n = NET_Send(fd, bufP + loff, llen, 0);
            if (n > 0) {
                llen -= n;
                loff += n;
                continue;
            }
            if (n == JVM_IO_INTR) {
                ...
            } else {
                ...
            }
            if (bufP != BUF) {
                free(bufP);
            }
            return;
        }
        len -= chunkLen;
        off += chunkLen;
    }

    if (bufP != BUF) {
        free(bufP);
    }
}
```

这个过程很简单，就是取出内存块的数据，通过偏移量和数据长度从java内存拷贝到native的指针中。并通过`NET_Send `发送。而这个方法实际上调用的是send系统调用.

虽然java层看来是write，但是实际上在jni中调用的是核心调用的是send系统调用发送网络数据包。send和write最终都会调用到同一处方法`sock_sendmsg`。

而两者最大的区别是，send/recv系统调用可以通过flag控制socket的行为，而write/read不行。write/read从设计上是面向更为通用的文件描述符的读写。

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[socket.c](http://androidxref.com/kernel_3.18/xref/net/socket.c)


```c
SYSCALL_DEFINE4(send, int, fd, void __user *, buff, size_t, len,
		unsigned int, flags)
{
	return sys_sendto(fd, buff, len, flags, NULL, 0);
}


SYSCALL_DEFINE6(sendto, int, fd, void __user *, buff, size_t, len,
		unsigned int, flags, struct sockaddr __user *, addr,
		int, addr_len)
{
	struct socket *sock;
	struct sockaddr_storage address;
	int err;
	struct msghdr msg;
	struct iovec iov;
	int fput_needed;

	if (len > INT_MAX)
		len = INT_MAX;
	sock = sockfd_lookup_light(fd, &err, &fput_needed);
	if (!sock)
		goto out;

	iov.iov_base = buff;
	iov.iov_len = len;
	msg.msg_name = NULL;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = NULL;
	msg.msg_controllen = 0;
	msg.msg_namelen = 0;
	if (addr) {
		err = move_addr_to_kernel(addr, addr_len, &address);
		if (err < 0)
			goto out_put;
		msg.msg_name = (struct sockaddr *)&address;
		msg.msg_namelen = addr_len;
	}
	if (sock->file->f_flags & O_NONBLOCK)
		flags |= MSG_DONTWAIT;
	msg.msg_flags = flags;
	err = sock_sendmsg(sock, &msg, len);

out_put:
	fput_light(sock->file, fput_needed);
out:
	return err;
}
```

- sockfd_lookup_light 从文件描述符中找到私有数据的`sock`结构体
- 创建`msghdr `，如果有发送的地址，则将地址拷贝到`msghdr`，但是这里是空对象。除此之外，还把从用户空间需要发送的数据缓冲区的数据指针赋值给`iov_base`字段，`iov_len `保存了缓冲区的数据长度。
- `sock_sendmsg `进一步执行发送数据包。 而这个方法是通过在第一节中所说的，在内核网络模块初始化装载tcp协议，为tcp协议结构体中sendmsg的方法设置方法指针，也就是到了tcp_sendmsg.


### 2. 传输层几个核心的数据结构

严格意义上来说从下面这部分就涉及到了传输层相关的数据结构，因此需要了解如下3个数据结构的定义，才能更好的理解本文。

- `sk_buff` 网络数据包的缓冲区，它是整个socket传输过程中数据的载体
- `tcp_skb_cb` 保存在`sk_buff` 中，是tcp协议中的用于控制当前包数据的结构体
- `tcphdr` 保存在`sk_buff `中，是代表了整个TCP的协议头部信息
- `tcp_sock` 本质上是sock结构体的扩展，当决定使用了TCP协议后，其实底层的sock结构体就是`tcp_sock`,里面保存了当前套子节在TCP协议中核心的字段。

#### 2.1.sk_buff 网络数据缓冲区

接下来这段代码会涉及到一个核心的结构体：`sk_buff`.这个结构体是承载了网络数据包的数据缓冲区。在不同的网络协议层都有不同的含义。在tcp层中成为segment，ip层称为packet，在数据链路层称为frame。

文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[linux](http://androidxref.com/kernel_3.18/xref/include/linux/)/[skbuff.h](http://androidxref.com/kernel_3.18/xref/include/linux/skbuff.h)


```c 
struct sk_buff {
	/* These two members must be first. */
	struct sk_buff		*next;
	struct sk_buff		*prev;

	union {
		ktime_t		tstamp;
		struct skb_mstamp skb_mstamp;
	};

	struct sock		*sk;
	struct net_device	*dev;
...
	/*
	 * This is the control buffer. It is free to use for every
	 * layer. Please put your private variables there. If you
	 * want to keep them across layers you have to do a skb_clone()
	 * first. This is owned by whoever has the skb queued ATM.
	 */
	char			cb[48] __aligned(8);
...
	unsigned int		len,
				data_len;
	__u16			mac_len,
				hdr_len;
...

	/* fields enclosed in headers_start/headers_end are copied
	 * using a single memcpy() in __copy_skb_header()
	 */
	/* private: */
	__u32			headers_start[0];
	/* public: */

...

	__u32			priority;
	int			skb_iif;
...

	__u16			inner_transport_header;
	__u16			inner_network_header;
	__u16			inner_mac_header;

	__be16			protocol;
	__u16			transport_header;
	__u16			network_header;
	__u16			mac_header;

	/* private: */
	__u32			headers_end[0];
	/* public: */

	/* These elements must be at the end, see alloc_skb() for details.  */
	sk_buff_data_t		tail;
	sk_buff_data_t		end;
	unsigned char		*head,
				*data;
	unsigned int		truesize;
	atomic_t		users;
};
```

这里介绍几个比较核心的变量：

-  `next `,`prev` 记录当前sk_buff在链表中前后继
- `cb` 为一个44字节大小的数组，存储着`tcp_skb_cb`，记录着TCP网络包传输时候的控制信息

```c
#define TCP_SKB_CB(__skb)	((struct tcp_skb_cb *)&((__skb)->cb[0]))
```

- `len` sk_buff的数据缓冲区中数据区域长度
- `data_len` sk_buff  中的片段大小
- `mac_len` 网络数据包中，代表mac层封装数据长度
- `hdr_len`  整个网络数据包中封装头长度
- `headers_start` 指向了网络数据包header 指针
- `mac_header` 最外层的mac封装header 距离缓冲区起点的偏移量
- `network_header`  网络层协议封装的header 距离缓冲区起点的偏移量
- `transport_header` 传输层封装的header距离缓冲区起点的偏移量
- `headers_end` 指向header的尾部
-  `tail` 代表了连续分配的data数据的末尾位置
- `end` 代表了整个skbuff 中数据包大小，指向了整个网络数据包的末尾。
- `head` 指向sk_buff中的header的起点
- `data` 指向连续申请内存的数据内容的指针
- `truesize`整个`sk_buff`大小


#### 2.2.sk_buff 的申请

这里看看sk_buff是如何申请出来的：

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[core](http://androidxref.com/kernel_3.18/xref/net/core/)/[skbuff.c](http://androidxref.com/kernel_3.18/xref/net/core/skbuff.c)


```c
struct sk_buff *__alloc_skb(unsigned int size, gfp_t gfp_mask,
			    int flags, int node)
{
	struct kmem_cache *cache;
	struct skb_shared_info *shinfo;
	struct sk_buff *skb;
	u8 *data;
	bool pfmemalloc;

	cache = (flags & SKB_ALLOC_FCLONE)
		? skbuff_fclone_cache : skbuff_head_cache;

	if (sk_memalloc_socks() && (flags & SKB_ALLOC_RX))
		gfp_mask |= __GFP_MEMALLOC;

	/* Get the HEAD */
	skb = kmem_cache_alloc_node(cache, gfp_mask & ~__GFP_DMA, node);
	if (!skb)
		goto out;
	prefetchw(skb);

	/* We do our best to align skb_shared_info on a separate cache
	 * line. It usually works because kmalloc(X > SMP_CACHE_BYTES) gives
	 * aligned memory blocks, unless SLUB/SLAB debug is enabled.
	 * Both skb->head and skb_shared_info are cache line aligned.
	 */
	size = SKB_DATA_ALIGN(size);
	size += SKB_DATA_ALIGN(sizeof(struct skb_shared_info));
	data = kmalloc_reserve(size, gfp_mask, node, &pfmemalloc);
	if (!data)
		goto nodata;
	/* kmalloc(size) might give us more room than requested.
	 * Put skb_shared_info exactly at the end of allocated zone,
	 * to allow max possible filling before reallocation.
	 */
	size = SKB_WITH_OVERHEAD(ksize(data));
	prefetchw(data + size);

	/*
	 * Only clear those fields we need to clear, not those that we will
	 * actually initialise below. Hence, don't put any more fields after
	 * the tail pointer in struct sk_buff!
	 */
	memset(skb, 0, offsetof(struct sk_buff, tail));
	/* Account for allocated memory : skb + skb->head */
	skb->truesize = SKB_TRUESIZE(size);
	skb->pfmemalloc = pfmemalloc;
	atomic_set(&skb->users, 1);
	skb->head = data;
	skb->data = data;
	skb_reset_tail_pointer(skb);
	skb->end = skb->tail + size;
	skb->mac_header = (typeof(skb->mac_header))~0U;
	skb->transport_header = (typeof(skb->transport_header))~0U;

	/* make sure we initialize shinfo sequentially */
	shinfo = skb_shinfo(skb);
	memset(shinfo, 0, offsetof(struct skb_shared_info, dataref));
	atomic_set(&shinfo->dataref, 1);
	kmemcheck_annotate_variable(shinfo->destructor_arg);

...
out:
	return skb;
nodata:
	kmem_cache_free(cache, skb);
	skb = NULL;
	goto out;
}
EXPORT_SYMBOL(__alloc_skb);
```

其中，`tail`字段初始的位置通过`skb_reset_tail_pointer`设置。这个方法是指向了data的位置。换句话说tail是跟着连续内存区域增加数据而增加指针的偏移量。

同理head也是如此，开始的时候也是和data指向同一个位置。head的位置不变作为获取sk_buff最初位置的指针。而data是跟着协议封装header装载了多少而进行移动多少。

能看到这个方法分别对`sk_buff`几个核心的字段属性进行了初始化。值得注意的是，在这个data指向的数据区域中，初始化了`skb_shared_info`一个结构体。

```c
static inline unsigned char *skb_end_pointer(const struct sk_buff *skb)
{
	return skb->end;
}
/* Internal */
#define skb_shinfo(SKB)	((struct skb_shared_info *)(skb_end_pointer(SKB)))
```

这代表着在`sk_buff`的end之后的区域都是`skb_shared_info`。用一张图来表示就是如下：
![sock-skbuff.png](/images/sock-skbuff.png)

注意，sk_buff分为2个区域：线性内存区域和非线性内存区域。

其中从headers一直到`end`之间都是线性区域。从`end`开始就是非线形区域。

tail记录了当前sk_buff使用了多少的连续内存。

从图中能看到`skb_shared_info`保存这一个个page，这些page实际上也就是指向了通过`alloc_page`从伙伴系统 申请物理内存页。

设计`skb_shared_info`看起来和用户空间传递下来需要传输的网络数据包没有直接关联，这么做有什么好处呢？

如果阅读过我写的binder的读写，以及共享内存，还有Okio的解析就知道。实际上在优化io的时候，有一个常用的做法就是减少拷贝的次数。

为了减少拷贝的次数，有的设备支持聚合/分离。也就说IP层没有必要拷贝内存聚合到一处，而是可以原封不动的把分散的内存在设备层进行聚合，从而减少拷贝的代价。而`skb_shared_info` 持有了分散的page对象做的就是这个事情。


#### 2.3.tcp_skb_cb

```h
struct tcp_skb_cb {
	__u32		seq;		/* Starting sequence number	*/
	__u32		end_seq;	/* SEQ + FIN + SYN + datalen	*/
	union {
		/* Note : tcp_tw_isn is used in input path only
		 *	  (isn chosen by tcp_timewait_state_process())
		 *
		 * 	  tcp_gso_segs is used in write queue only,
		 *	  cf tcp_skb_pcount()
		 */
		__u32		tcp_tw_isn;
		__u32		tcp_gso_segs;
	};
	__u8		tcp_flags;	/* TCP header flags. (tcp[13])	*/

	__u8		sacked;		/* State flags for SACK/FACK.	*/
...

	__u8		ip_dsfield;	/* IPv4 tos or IPv6 dsfield	*/
	/* 1 byte hole */
	__u32		ack_seq;	/* Sequence number ACK'd	*/
	union {
		struct inet_skb_parm	h4;
#if IS_ENABLED(CONFIG_IPV6)
		struct inet6_skb_parm	h6;
#endif
	} header;	/* For incoming frames		*/
};
```

在这个结构体中有几个核心的字段：

- seq TCP网络包起始序列号
- end_seq 网络包最终的序列号
- ack_seq 当前TCP网络包所应答的序列号

#### 2.4 tcphdr tcp头部信息

一说起这个TCP封装的信息就需要了解下面这幅经典的图：

![TCP Header.png](/images/TCP Header.png)

所对应头部结构题如下：

```c
struct tcphdr {
	__be16	source;
	__be16	dest;
	__be32	seq;
	__be32	ack_seq;
#if defined(__LITTLE_ENDIAN_BITFIELD)
	__u16	res1:4,
		doff:4,
		fin:1,
		syn:1,
		rst:1,
		psh:1,
		ack:1,
		urg:1,
		ece:1,
		cwr:1;
#elif defined(__BIG_ENDIAN_BITFIELD)
	__u16	doff:4,
		res1:4,
		cwr:1,
		ece:1,
		urg:1,
		ack:1,
		psh:1,
		rst:1,
		syn:1,
		fin:1;
#else
#error	"Adjust your <asm/byteorder.h> defines"
#endif	
	__be16	window;
	__sum16	check;
	__be16	urg_ptr;
};
```

不难看出图和字段是一一对应的。这里有两个预编译的宏，仔细看实际上发现是其实是这些比特位互相颠倒。因为Linux内核作为一个跨平台的项目，遇到的CPU架构对数据的存储可能存在大尾端和小尾端。就是把末尾作为高位还是低位。因此会根据设置调整好每一个标志位在内存中的位置。而TCP协议中必须保证是大尾端的数据模型，因此需要做好适配，保证数据比特为必须是大尾端的被读取和写入。

#### 2.5.tcp_sock

```h
struct tcp_sock {
	/* inet_connection_sock has to be the first member of tcp_sock */
	struct inet_connection_sock	inet_conn;
	u16	tcp_header_len;	/* Bytes of tcp header to send		*/
...

/*
 *	RFC793 variables by their proper names. This means you can
 *	read the code and the spec side by side (and laugh ...)
 *	See RFC793 and RFC1122. The RFC writes these in capitals.
 */
 	u32	rcv_nxt;	/* What we want to receive next 	*/
...
	u32	rcv_wup;	/* rcv_nxt on last window update sent	*/
 	u32	snd_nxt;	/* Next sequence we send		*/

 	u32	snd_una;	/* First byte we want an ack for	*/
...
	u32	rcv_tstamp;	/* timestamp of last received ACK (for keepalives) */

...

	u32	snd_wl1;	/* Sequence for window update		*/
	u32	snd_wnd;	/* The window we expect to receive	*/
	u32	max_window;	/* Maximal window ever seen from peer	*/
	u32	mss_cache;	/* Cached effective mss, not including SACKS */

	u32	window_clamp;	/* Maximal window to advertise		*/
	u32	rcv_ssthresh;	/* Current window clamp			*/
...

/*
 *	Slow start and congestion control (see also Nagle, and Karn & Partridge)
 */
 	u32	snd_ssthresh;	/* Slow start size threshold		*/
 	u32	snd_cwnd;	/* Sending congestion window		*/
	u32	snd_cwnd_cnt;	/* Linear increase counter		*/
	u32	snd_cwnd_clamp; /* Do not allow snd_cwnd to grow above this */
	u32	snd_cwnd_used;
	u32	snd_cwnd_stamp;
 ...

 	u32	rcv_wnd;	/* Current receiver window		*/
	u32	write_seq;	/* Tail(+1) of data held in tcp send buffer */
  ...
...
};

```
在`tcp_sock`结构体中，有很多关键的字段，在这里我们只需要关注两个部分：
- `RFC793`开始定义 tcp相关的字段
- `拥塞窗口控制`相关的字段


- 1.rcv_nxt 希望接受的下一个序列号
- 2.rcv_wup 就是拥塞窗口上一次应答的字节
- 3.`snd_nxt` 发送端即将发出的下一序列号
- 4.`snd_una` 发送端想要应答的第一个字节
- 5.`snd_wl1` 记录发送窗口更新时，造成窗口更新的那个数据报的第一个序号。 它主要用于在下一次判断是否需要更新发送窗口
- 6.`snd_wnd` 发送窗口大小，数值来源于与TCP首部，也就是`tcphdr`的`window`字段
- 7.`max_window` 当前拥塞窗口的最大值
- 8.`window_clamp` 当前`advertise window`的最大值

- 9.`snd_cwnd` 表示在当前的拥塞控制窗口中已经发送的数据段的个数
- 10.`snd_ssthresh` 慢启动的阈值
- 11.`snd_cwnd_cnt` 线性增长的计数
- 12.`snd_cwnd_clamp` 不允许发送的拥塞窗口超过这个数值

- 13.`rcv_wnd` 接受窗口大小
- 14.`write_seq`tcp 发送网路包时候，当前写入的序列号


## TCP 协议中3个核心的概念

在了解了上述几个核心的数据结构之后，为了能够更加容易理解下面的源码还需要了解，TCP协议中的3个核心概念：

- 拥塞窗口
- TSO
- 接受窗口，发送窗口

##### 拥塞窗口

接下来在这段代码中涉及到了tcp协议中核心概念：`拥塞窗口(cwnd，congestion window)`。

拥塞窗口诞生的初衷是，为了缓解网络环境的紧张当年的硬件水平和网络环境并不是十分好，就需要一些算法缓解网络环境的紧张。在这个背景下诞生了拥塞窗口的概念。

本质上就是通过客户端和服务器的交流获得当前服务器的网络环境从而调整发包的速度。

为了实现这个目的，定义一个窗口的概念，在这个窗口之内的才能发送，超过这个窗口的就不能发送，来控制发送的频率。

窗口大小应该怎么调整呢？

下面有一副十分经典的图，几乎每一个人都见过的：

![拥塞窗口算法.png](/images/拥塞窗口算法.png)


.一开始窗口只有一个`mss`大小叫做慢启动。接着翻倍的增长窗口大小，直到`ssthresh`临界值，之后就变成线性增长。这个过程我们成为`拥塞避免`。当出现丢包的时候，就说明网络环境开始变得紧张，就会开始调整窗口大小。

拥塞窗口有两种调整窗口大小的逻辑：

- 1. 将窗口大小重新调整为1个`mss`，重新经历翻倍和线性增长。
- 2.将当前的窗口大小调整为当前的一半，重新以线性进行增长。


##### 接受窗口

再来看看接收端中有这么一个概念，`接受窗口rwnd(receive window)`,也叫做滑动窗口。

可以看成和拥塞窗口算法对应的概念。如果说拥塞窗口担心把网络拥塞了，在丢包的时候降低发送速度；那么滑动窗口就是担心把接收方给塞满了，从而控制发送速度。

从原理看来`滑动窗口` 和 `拥塞窗口` 两者之间上会有一定的互相调节的机制。实际上在tcp通信过程中，服务端会告诉客户端自己作为接收端的接受的上限的能力，超过就不会接受。

为了更好的控制从发送端发送来的数据包，滑动窗口中发送方的缓存会把发送的数据包分为如下几个部分：

![sock-滑动窗口下发送方的缓存.png](/images/sock-滑动窗口下发送方的缓存.png)


可以将数据包控制分为如下四个部分：

- 1.发送了并且已经确认的 这部分是已经发送完毕的网络包，这部分没有用了，可以回收。
- 2.发送了但尚未确认的 这部分，发送方要等待，万一发送不成功，还要重新发送，所以不能删除。
- 3.没有发送，但是已经等待发送的 这部分是接收方空闲的能力，可以马上发送，接收方收得了。
- 4.没有发送，并且暂时还不会发送的 这部分已经超过了服务端滑动窗口的承载，因此暂时不会发送

而在这个数据结构中，会通过两个标志为分辨当前数据包位于什么位置：

- lastByteAck 指向上一次回应包的字节位置
- lastByteSent 指向上一次发送包的字节位置

注意在这个过程中，把`已发送没有确认`和`没有发送可发送`加起来的红色区域为`advertise window`.这区域中就是tcp网络包在发送时候允许在内的边界


为了更好的理解下文，这边将几个核心的概念所对应在结构体中字段分别如下
![sock-滑动窗口发送端.png](/images/sock-滑动窗口发送端.png)


而滑动窗口的存在，通用会把接收方的缓存分为如下几个部分：

![滑动窗口下接收方缓存.png](/images/滑动窗口下接收方缓存.png)


在这个图中有三个部分：

- 1.接受已确认的 这部分是接受且确认好的数据包可以交给应用层处理
- 2.等接受未确认的 这部分的网络包到达了，但是还没有确认，不算完全完毕，有的还没有到达，那就是接收方可以接受的最大网络包数量
- 3.不可接受的 这部分是指超出了接收方能够接受最大限度

注意在这个过程中，把`已接受已确认`和`等待接受未确认`加起来的红色区域为`advertise window`.这区域中就是tcp网络包在发送时候允许在内的边界。

相同的，我们将上面tcp_sock结构体对应的字段填充在上图显示如下：
![sock-滑动窗口接收端.png](/images/sock-滑动窗口接收端.png)


##### TSO

在这里有一个核心的概念：`TSO（TCP Segmentation Offload）`，意思是指TCP 数据片分割输出。TCP协议中会对每一段数据包输出有一个上限的阈值，叫做`mss`，而这种分割行为就是`TSO`。可以简单看看分割是如何计算的：

下面这个方法就是通过`tcp_init_tso_segs` 方法调用，第一次进行切割大小计算的逻辑

```c
/* Initialize TSO segments for a packet. */
static void tcp_set_skb_tso_segs(const struct sock *sk, struct sk_buff *skb,
				 unsigned int mss_now)
{
	struct skb_shared_info *shinfo = skb_shinfo(skb);
...
	if (skb->len <= mss_now || skb->ip_summed == CHECKSUM_NONE) {
		/* Avoid the costly divide in the normal
		 * non-TSO case.
		 */
		tcp_skb_pcount_set(skb, 1);
		shinfo->gso_size = 0;
		shinfo->gso_type = 0;
	} else {
		tcp_skb_pcount_set(skb, DIV_ROUND_UP(skb->len, mss_now));
		shinfo->gso_size = mss_now;
		shinfo->gso_type = sk->sk_gso_type;
	}
}
```

如果sk_buff的数据长度小于等于`mss_now `阈值，那个就`tcp_skb_pcount_set `设置`tcp_gso_segs`为1.如果大于`mss_now`那么就通过`DIV_ROUND_UP(skb->len, mss_now)` 把数据长度整除`mss_now`的结果并向上取整，作为需要切多少片

- 接着就会调用`tcp_mss_split_point`进一步根据初步分片以及拥塞窗口情况，找到sk_buff中需要发送的区域。

```c
        limit = mss_now;
        if (tso_segs > 1 && !tcp_urg_mode(tp))
            limit = tcp_mss_split_point(sk, skb, mss_now,
                            min_t(unsigned int,
                              cwnd_quota,
                              sk->sk_gso_max_segs),
                            nonagle);
```

```c
static unsigned int tcp_mss_split_point(const struct sock *sk,
					const struct sk_buff *skb,
					unsigned int mss_now,
					unsigned int max_segs,
					int nonagle)
{
	const struct tcp_sock *tp = tcp_sk(sk);
	u32 partial, needed, window, max_len;

	window = tcp_wnd_end(tp) - TCP_SKB_CB(skb)->seq;
	max_len = mss_now * max_segs;

	if (likely(max_len <= window && skb != tcp_write_queue_tail(sk)))
		return max_len;

	needed = min(skb->len, window);

	if (max_len <= needed)
		return max_len;

	partial = needed % mss_now;

	if (tcp_nagle_check(partial != 0, tp, nonagle))
		return needed - partial;

	return needed;
}
```

注意：`tcp_wnd_end ` 这里获取的是可以发送出去的窗口长度大小。

```h
/* Returns end sequence number of the receiver's advertised window */
static inline u32 tcp_wnd_end(const struct tcp_sock *tp)
{
	return tp->snd_una + tp->snd_wnd;
}
```
`snd_una` 是指第第一个应答数据包的指针，`snd_wnd` 发送窗口根据接收方的应答所调整的窗口大小。

这里的计算规则如下：

> window 需要发送窗口大小(window) = 接收方的拥塞窗口结束序列号 - 当前数据包在窗口中序列号


 因此结合滑动窗口内容就能明白`tcp_wnd_end`的方法实际上计算的是整个发送端发送缓存的`Advertised Window`的大小。在`tcp_mss_split_point`方法中，再通过`Advertised Window`的大小减去当前tcp序列号，就能找到当前的`Advertised Window`剩下多少。这个`window`变量确定当前还有多少空间允许该网络包放置到缓存。


> 当前数据包需要发送最大长度(max_len) = mss * 最大切片数(max_segs)

 > 如果判断到当前的最大长度小于窗口序列号，并且当前的需要发送的数据缓冲区并非新生成的，就会直接返回`max_len`.

> 如果`max_len`比`window`小，也直接返回`max_len`.说明此时最大的长度在可发送范围内，直接发送。

> 如果`max_len` 大于`window`，则把`max_len`除`mss`获得最大切片数，并通过`nagle`规则校验。则返回切片后的大小。

`nagle`规则本质就是为了每次发送最小的应答包。将会遵循如下规则：

- 1 如果包长度达到MSS，则允许发送；
- 2 如果该包含有FIN，则允许发送；
- 3 设置了TCP_NODELAY选项，则允许发送；
- 4 未设置TCP_CORK选项时，若所有发出去的小数据包（包长度小于MSS）均被确认，则允许发送；
- 5 上述条件都未满足，但发生了超时（一般为200ms），则立即发送。


最后调用`tso_fragment `切割数据分片。不过一般很少调用到这里，一般是通过网络硬件进行切割，因为做这种事情多了几次拷贝会消耗cpu。


### 3.tcp_sendmsg tcp协议层发送网络包

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp.c)


```c
int tcp_sendmsg(struct kiocb *iocb, struct sock *sk, struct msghdr *msg,
		size_t size)
{
	struct iovec *iov;
	struct tcp_sock *tp = tcp_sk(sk);
	struct sk_buff *skb;
	int iovlen, flags, err, copied = 0;
	int mss_now = 0, size_goal, copied_syn = 0, offset = 0;
	bool sg;
	long timeo;

	lock_sock(sk);

	flags = msg->msg_flags;
...

...

	mss_now = tcp_send_mss(sk, &size_goal, flags);

	/* Ok commence sending. */
	iovlen = msg->msg_iovlen;
	iov = msg->msg_iov;
	copied = 0;

	err = -EPIPE;
	if (sk->sk_err || (sk->sk_shutdown & SEND_SHUTDOWN))
		goto out_err;

	sg = !!(sk->sk_route_caps & NETIF_F_SG);

	while (--iovlen >= 0) {
		size_t seglen = iov->iov_len;
		unsigned char __user *from = iov->iov_base;

		iov++;
		if (unlikely(offset > 0)) {  /* Skip bytes copied in SYN */
			if (offset >= seglen) {
				offset -= seglen;
				continue;
			}
			seglen -= offset;
			from += offset;
			offset = 0;
		}

		while (seglen > 0) {
			int copy = 0;
			int max = size_goal;

			skb = tcp_write_queue_tail(sk);
			if (tcp_send_head(sk)) {
				if (skb->ip_summed == CHECKSUM_NONE)
					max = mss_now;
				copy = max - skb->len;
			}

			if (copy <= 0) {
new_segment:
				/* Allocate new segment. If the interface is SG,
				 * allocate skb fitting to single page.
				 */
				if (!sk_stream_memory_free(sk))
					goto wait_for_sndbuf;

				skb = sk_stream_alloc_skb(sk,
							  select_size(sk, sg),
							  sk->sk_allocation);
				if (!skb)
					goto wait_for_memory;

				/*
				 * Check whether we can use HW checksum.
				 */
				if (sk->sk_route_caps & NETIF_F_ALL_CSUM)
					skb->ip_summed = CHECKSUM_PARTIAL;

				skb_entail(sk, skb);
				copy = size_goal;
				max = size_goal;

				/* All packets are restored as if they have
				 * already been sent. skb_mstamp isn't set to
				 * avoid wrong rtt estimation.
				 */
				if (tp->repair)
					TCP_SKB_CB(skb)->sacked |= TCPCB_REPAIRED;
			}

			/* Try to append data to the end of skb. */
			if (copy > seglen)
				copy = seglen;

			/* Where to copy to? */
			if (skb_availroom(skb) > 0) {
				/* We have some space in skb head. Superb! */
				copy = min_t(int, copy, skb_availroom(skb));
				err = skb_add_data_nocache(sk, skb, from, copy);
				if (err)
					goto do_fault;
			} else {
				bool merge = true;
				int i = skb_shinfo(skb)->nr_frags;
				struct page_frag *pfrag = sk_page_frag(sk);

				if (!sk_page_frag_refill(sk, pfrag))
					goto wait_for_memory;

				if (!skb_can_coalesce(skb, i, pfrag->page,
						      pfrag->offset)) {
					if (i == MAX_SKB_FRAGS || !sg) {
						tcp_mark_push(tp, skb);
						goto new_segment;
					}
					merge = false;
				}

				copy = min_t(int, copy, pfrag->size - pfrag->offset);

				if (!sk_wmem_schedule(sk, copy))
					goto wait_for_memory;

				err = skb_copy_to_page_nocache(sk, from, skb,
							       pfrag->page,
							       pfrag->offset,
							       copy);
				if (err)
					goto do_error;

				/* Update the skb. */
				if (merge) {
					skb_frag_size_add(&skb_shinfo(skb)->frags[i - 1], copy);
				} else {
					skb_fill_page_desc(skb, i, pfrag->page,
							   pfrag->offset, copy);
					get_page(pfrag->page);
				}
				pfrag->offset += copy;
			}

			if (!copied)
				TCP_SKB_CB(skb)->tcp_flags &= ~TCPHDR_PSH;

			tp->write_seq += copy;
			TCP_SKB_CB(skb)->end_seq += copy;
			tcp_skb_pcount_set(skb, 0);

			from += copy;
			copied += copy;
			if ((seglen -= copy) == 0 && iovlen == 0) {
				tcp_tx_timestamp(sk, skb);
				goto out;
			}

			if (skb->len < max || (flags & MSG_OOB) || unlikely(tp->repair))
				continue;

			if (forced_push(tp)) {
				tcp_mark_push(tp, skb);
				__tcp_push_pending_frames(sk, mss_now, TCP_NAGLE_PUSH);
			} else if (skb == tcp_send_head(sk))
				tcp_push_one(sk, mss_now);
			continue;

wait_for_sndbuf:
			set_bit(SOCK_NOSPACE, &sk->sk_socket->flags);
wait_for_memory:
			if (copied)
				tcp_push(sk, flags & ~MSG_MORE, mss_now,
					 TCP_NAGLE_PUSH, size_goal);

			if ((err = sk_stream_wait_memory(sk, &timeo)) != 0)
				goto do_error;

			mss_now = tcp_send_mss(sk, &size_goal, flags);
		}
	}

out:
	if (copied)
		tcp_push(sk, flags, mss_now, tp->nonagle, size_goal);
out_nopush:
	release_sock(sk);

	if (copied + copied_syn)
		uid_stat_tcp_snd(from_kuid(&init_user_ns, current_uid()),
				 copied + copied_syn);
	return copied + copied_syn;

do_fault:
	if (!skb->len) {
		tcp_unlink_write_queue(skb, sk);
		/* It is the one place in all of TCP, except connection
		 * reset, where we can be unlinking the send_head.
		 */
		tcp_check_send_head(sk, skb);
		sk_wmem_free_skb(sk, skb);
	}

do_error:
	if (copied + copied_syn)
		goto out;
out_err:
	err = sk_stream_error(sk, flags, err);
	release_sock(sk);
	return err;
}
EXPORT_SYMBOL(tcp_sendmsg);
```

这个方法特别长，做的事情也很多，这里拆开几段进行解析。不过这段代码的核心思路就是:

初始化一个`copied `变量为0.不断的通过发送数据，并每次拷贝数据到网络包的数据缓冲区后，获取到自增的变量copy。每一次发送后都会`copied += copy;`增加已拷贝的数据区域。

- `tcp_send_mss` 首先计算mss，也就是`Max Segment Size`网络数据包发送最大限制。

- 在这个方法中有两个巨大的循环，一个是基于`iovlen`变量，另一个在第一个循环中是基于`seglen `变量的循环。首先`iovlen`变量设置为1 代表消息发送的次数也就是只会执行一次，`seglen` 代表了经过偏移参数偏移后需要实际传送数据长度。


- `tcp_write_queue_tail`从`sk->sk_write_queue` 获取最后一个写入队列的skbuff(网络数据包缓冲区)。因为最后一个获取出来的skbuff很有可能是上次网络数据完全填充到这个从内存中申请的数据缓冲区。

- `tcp_send_head `获取上一次呆在写入队列中还没有发送出去的skbuff中。如果能获取到则开始通过`mss - skbuff长度`来判断当前的网络数据缓冲区还有多少空间提供给本次数据包。

- 计算出来的`copy`如果小于等于0，则通过`sk_stream_alloc_skb`申请一个skbuff给本次即将发送的数据包。`skb_entail`把`skbuff`添加到`sk->sk_write_queue` 队尾。之后`copy`变量就设置为`mss`的大小，当然如果copy比`seglen`大则设置为`seglen`大小

- `skb_availroom ` 判断到sk_buff还有`tail_room`空间，就会将用户控件需要传输的数据通过`skb_add_data_nocache`拷贝到`tail`的后方的连续区域。

- 如果`skb_availroom ` 判断到tail后方已经没有空间(或者根本没有申请出连续内存缓冲区),则会将数据拷贝到`skb_shared_info `的内存页中管理。

- 每一次的拷贝数据结束的循环最终都会调用`tcp_push `方法，通过`__tcp_push_pending_frames` 调用`tcp_write_xmit`发送数据包。


### 4.tcp_write_xmit

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp_output.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp_output.c)


```c
static bool tcp_write_xmit(struct sock *sk, unsigned int mss_now, int nonagle,
			   int push_one, gfp_t gfp)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct sk_buff *skb;
	unsigned int tso_segs, sent_pkts;
	int cwnd_quota;
	int result;
...

	while ((skb = tcp_send_head(sk))) {
		unsigned int limit;

		tso_segs = tcp_init_tso_segs(sk, skb, mss_now);
...

		cwnd_quota = tcp_cwnd_test(tp, skb);
		if (!cwnd_quota) {
			is_cwnd_limited = true;
			if (push_one == 2)
				/* Force out a loss probe pkt. */
				cwnd_quota = 1;
			else
				break;
		}
...
		if (unlikely(!tcp_snd_wnd_test(tp, skb, mss_now)))
			break;

		if (tso_segs == 1) {
			if (unlikely(!tcp_nagle_test(tp, skb, mss_now,
						     (tcp_skb_is_last(sk, skb) ?
						      nonagle : TCP_NAGLE_PUSH))))
				break;
		} else {
			if (!push_one &&
			    tcp_tso_should_defer(sk, skb, &is_cwnd_limited))
				break;
		}

		/* TCP Small Queues :
		 * Control number of packets in qdisc/devices to two packets / or ~1 ms.
		 * This allows for :
		 *  - better RTT estimation and ACK scheduling
		 *  - faster recovery
		 *  - high rates
		 * Alas, some drivers / subsystems require a fair amount
		 * of queued bytes to ensure line rate.
		 * One example is wifi aggregation (802.11 AMPDU)
		 */
		limit = max_t(unsigned int, sysctl_tcp_limit_output_bytes,
			      sk->sk_pacing_rate >> 10);

...
		limit = mss_now;
		if (tso_segs > 1 && !tcp_urg_mode(tp))
			limit = tcp_mss_split_point(sk, skb, mss_now,
						    min_t(unsigned int,
							  cwnd_quota,
							  sk->sk_gso_max_segs),
						    nonagle);

		if (skb->len > limit &&
		    unlikely(tso_fragment(sk, skb, limit, mss_now, gfp)))
			break;

		if (unlikely(tcp_transmit_skb(sk, skb, 1, gfp)))
			break;

repair:

		tcp_event_new_data_sent(sk, skb);

		tcp_minshall_update(tp, mss_now, skb);
		sent_pkts += tcp_skb_pcount(skb);

		if (push_one)
			break;
	}

	if (likely(sent_pkts)) {
		if (tcp_in_cwnd_reduction(sk))
			tp->prr_out += sent_pkts;

		/* Send one loss probe per tail loss episode. */
		if (push_one != 2)
			tcp_schedule_loss_probe(sk);
		tcp_cwnd_validate(sk, is_cwnd_limited);
		return false;
	}
	return (push_one == 2) || (!tp->packets_out && tcp_send_head(sk));
}
```

在这段不长的代码中涉及到几个核心的知识点。这里按照知识点的顺序来聊聊，不会完全根据方法的流程走。

注意`sk_send_head` 方法是获取第一个还没有发送的sk_buff 数据缓冲区。

- `tcp_init_tso_segs` 判断当前发送的数据包是否需要切分成几份发送出去。`tso_segs` 就是指需要切成几片。也就是负责了TSO的功能模块

- `tcp_cwnd_test ` 获取` tp->snd_cwnd`当前的拥塞窗口已经发送出去的数据大小,以及`tcp_packets_in_flight`获取正在发送的网络包数量。一旦发现正在发送的网络包超过了拥塞窗口的大小，则跳出循环，不再执行发送行为；如果此时是探测报文超时了，就会关注当前的超时探测报文，只发送该数据包。

```c
static inline unsigned int tcp_left_out(const struct tcp_sock *tp)
{
	return tp->sacked_out + tp->lost_out;
}

static inline unsigned int tcp_packets_in_flight(const struct tcp_sock *tp)
{
	return tp->packets_out - tcp_left_out(tp) + tp->retrans_out;
}
```

- `sacked_out` 代表了乱序包数量。在这里出现了一个`SACK`的概念。这里SACK是指在TCP头部中存在一个名为`SACK`选项部分，可通过`et.ipv4.tcp_sack = 1`启动。这个选项可以让接收方告诉发送方字节的实际接受情况。

- `lost_out` 代表丢包的数量

- `retrans_out` 是指重新发送的网络包个数

##### SACK解释
在这个过程能看到几个新的字段：


而在这个选项中有4组数据，每一组都有一对`left edge`和`right edge`.分别代表`已收到的第一个不连续序列号`以及`已收到的最后一个不连续序列号+1`，也就是左闭右开区间。

这样就能让发送端知道接收端究竟接受的情况是怎么样。

##### 

```c
static inline unsigned int tcp_cwnd_test(const struct tcp_sock *tp,
					 const struct sk_buff *skb)
{
	u32 in_flight, cwnd;

	/* Don't be strict about the congestion window for the final FIN.  */
	if ((TCP_SKB_CB(skb)->tcp_flags & TCPHDR_FIN) &&
	    tcp_skb_pcount(skb) == 1)
		return 1;

	in_flight = tcp_packets_in_flight(tp);
	cwnd = tp->snd_cwnd;
	if (in_flight < cwnd)
		return (cwnd - in_flight);

	return 0;
}
```


#### tcp_transmit_skb 填充网络包和发送tcp网络包

```c
static int tcp_transmit_skb(struct sock *sk, struct sk_buff *skb, int clone_it,
			    gfp_t gfp_mask)
{
	const struct inet_connection_sock *icsk = inet_csk(sk);
	struct inet_sock *inet;
	struct tcp_sock *tp;
	struct tcp_skb_cb *tcb;
	struct tcp_out_options opts;
	unsigned int tcp_options_size, tcp_header_size;
	struct tcp_md5sig_key *md5;
	struct tcphdr *th;
...

	inet = inet_sk(sk);
	tp = tcp_sk(sk);
	tcb = TCP_SKB_CB(skb);
	memset(&opts, 0, sizeof(opts));

...

	skb->ooo_okay = sk_wmem_alloc_get(sk) < SKB_TRUESIZE(1);

	skb_push(skb, tcp_header_size);
	skb_reset_transport_header(skb);

	skb_orphan(skb);
	skb->sk = sk;
	skb->destructor = tcp_wfree;
	skb_set_hash_from_sk(skb, sk);
	atomic_add(skb->truesize, &sk->sk_wmem_alloc);

	/* Build TCP header and checksum it. */
	th = tcp_hdr(skb);
	th->source		= inet->inet_sport;
	th->dest		= inet->inet_dport;
	th->seq			= htonl(tcb->seq);
	th->ack_seq		= htonl(tp->rcv_nxt);
	*(((__be16 *)th) + 6)	= htons(((tcp_header_size >> 2) << 12) |
					tcb->tcp_flags);

	if (unlikely(tcb->tcp_flags & TCPHDR_SYN)) {
		/* RFC1323: The window in SYN & SYN/ACK segments
		 * is never scaled.
		 */
		th->window	= htons(min(tp->rcv_wnd, 65535U));
	} else {
		th->window	= htons(tcp_select_window(sk));
	}
	th->check		= 0;
	th->urg_ptr		= 0;


	if (unlikely(tcp_urg_mode(tp) && before(tcb->seq, tp->snd_up))) {
		if (before(tp->snd_up, tcb->seq + 0x10000)) {
			th->urg_ptr = htons(tp->snd_up - tcb->seq);
			th->urg = 1;
		} else if (after(tcb->seq + 0xFFFF, tp->snd_nxt)) {
			th->urg_ptr = htons(0xFFFF);
			th->urg = 1;
		}
	}

	tcp_options_write((__be32 *)(th + 1), tp, &opts);
	if (likely((tcb->tcp_flags & TCPHDR_SYN) == 0))
		tcp_ecn_send(sk, skb, tcp_header_size);
...

	icsk->icsk_af_ops->send_check(sk, skb);

	if (likely(tcb->tcp_flags & TCPHDR_ACK))
		tcp_event_ack_sent(sk, tcp_skb_pcount(skb));

	if (skb->len != tcp_header_size)
		tcp_event_data_sent(tp, sk);

	if (after(tcb->end_seq, tp->snd_nxt) || tcb->seq == tcb->end_seq)
		TCP_ADD_STATS(sock_net(sk), TCP_MIB_OUTSEGS,
			      tcp_skb_pcount(skb));

	/* OK, its time to fill skb_shinfo(skb)->gso_segs */
	skb_shinfo(skb)->gso_segs = tcp_skb_pcount(skb);

	/* Our usage of tstamp should remain private */
	skb->tstamp.tv64 = 0;

	/* Cleanup our debris for IP stacks */
	memset(skb->cb, 0, max(sizeof(struct inet_skb_parm),
			       sizeof(struct inet6_skb_parm)));

	err = icsk->icsk_af_ops->queue_xmit(sk, skb, &inet->cork.fl);

	if (likely(err <= 0))
		return err;

	tcp_enter_cwr(sk);

	return net_xmit_eval(err);
}
```
这里有一张很经典的TCP 网络包的头部数据结构图：

![TCP Header.png](/images/TCP Header.png)

所对应头部结构题如下：

```c
struct tcphdr {
	__be16	source;
	__be16	dest;
	__be32	seq;
	__be32	ack_seq;
#if defined(__LITTLE_ENDIAN_BITFIELD)
	__u16	res1:4,
		doff:4,
		fin:1,
		syn:1,
		rst:1,
		psh:1,
		ack:1,
		urg:1,
		ece:1,
		cwr:1;
#elif defined(__BIG_ENDIAN_BITFIELD)
	__u16	doff:4,
		res1:4,
		cwr:1,
		ece:1,
		urg:1,
		ack:1,
		psh:1,
		rst:1,
		syn:1,
		fin:1;
#else
#error	"Adjust your <asm/byteorder.h> defines"
#endif	
	__be16	window;
	__sum16	check;
	__be16	urg_ptr;
};
```
实际上这个方法就是填充这些字段

实际上这个函数的过程就是往这个TCP数据包中填充数据：

- 1.`tcp_hdr`将当前的`sk_buff`读取中其中的`tcphdr `。也就是tcp头部结构体。
- 2.将`inet->inet_sport` 在应用层设置的源端口设置到`source`字段中。
- 3.`inet->inet_dport`在之前通过`netd`进程查询到目标端口
- 4.`htonl(tcb->seq)`获取当前保存在`tcp_skb_cb 序列号保存到`th->seq `，记住这个`htonl`是指TCP协议中数据的存储方式是大尾端方式(主机-网络尾端转化方式)，数据存储和平台相关可能和协议反正相反，因此需要写一个宏作为转化.
- 5.`htonl(tp->rcv_nxt)` 把从服务端接受的期望下一个序号作为应答序号。
- 6. 如果此时是SYN握手的的阶段，则吧window强制设置为`65536`大小，否则通过`tcp_select_window `计算新的窗口大小

- 7.如果打开了`urg`模式，那么就是校验`tcb->seq`所记录的序列号是否小于tcb所记录的urg数据指针`snd_up`。 如果`snd_up`小于`seq+65536`，那么指针将会指向`tp->snd_up - tcb->seq`.找到紧急数据所在的位置。

如果`tcb->seq + 65535` 大于下一个期望的数据，就是设置为`65535`。

```c
    if (unlikely(tcp_urg_mode(tp) && before(tcb->seq, tp->snd_up))) {
        if (before(tp->snd_up, tcb->seq + 0x10000)) {
            th->urg_ptr = htons(tp->snd_up - tcb->seq);
            th->urg = 1;
        } else if (after(tcb->seq + 0xFFFF, tp->snd_nxt)) {
            th->urg_ptr = htons(0xFFFF);
            th->urg = 1;
        }
    }
```

- 8.`icsk->icsk_af_ops->queue_xmit` 调用ip层的协议开始发送TCP数据包，在这个层级中将会填充ip协议需要的数据。

而这个函数指针为如下申明：

```c

const struct inet_connection_sock_af_ops ipv4_specific = {
        .queue_xmit        = ip_queue_xmit,
        .send_check        = tcp_v4_send_check,
        .rebuild_header    = inet_sk_rebuild_header,
        .sk_rx_dst_set     = inet_sk_rx_dst_set,
        .conn_request      = tcp_v4_conn_request,
        .syn_recv_sock     = tcp_v4_syn_recv_sock,
        .net_header_len    = sizeof(struct iphdr),
        .setsockopt        = ip_setsockopt,
        .getsockopt        = ip_getsockopt,
        .addr2sockaddr     = inet_csk_addr2sockaddr,
        .sockaddr_len      = sizeof(struct sockaddr_in),
        .mtu_reduced       = tcp_v4_mtu_reduced,
};
```

也就是`ip_queue_xmit`方法。


#### tcp_select_window 计算发送时advertise窗口大小

```c
static u16 tcp_select_window(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	u32 old_win = tp->rcv_wnd;
	u32 cur_win = tcp_receive_window(tp);
	u32 new_win = __tcp_select_window(sk);

	/* Never shrink the offered window */
	if (new_win < cur_win) {
		/* Danger Will Robinson!
		 * Don't update rcv_wup/rcv_wnd here or else
		 * we will not be able to advertise a zero
		 * window in time.  --DaveM
		 *
		 * Relax Will Robinson.
		 */
		if (new_win == 0)
			NET_INC_STATS(sock_net(sk),
				      LINUX_MIB_TCPWANTZEROWINDOWADV);
		new_win = ALIGN(cur_win, 1 << tp->rx_opt.rcv_wscale);
	}
	tp->rcv_wnd = new_win;
	tp->rcv_wup = tp->rcv_nxt;

	/* Make sure we do not exceed the maximum possible
	 * scaled window.
	 */
	if (!tp->rx_opt.rcv_wscale && sysctl_tcp_workaround_signed_windows)
		new_win = min(new_win, MAX_TCP_WINDOW);
	else
		new_win = min(new_win, (65535U << tp->rx_opt.rcv_wscale));

	/* RFC1323 scaling applied */
	new_win >>= tp->rx_opt.rcv_wscale;

	/* If we advertise zero window, disable fast path. */
	if (new_win == 0) {
		tp->pred_flags = 0;
		if (old_win)
			NET_INC_STATS(sock_net(sk),
				      LINUX_MIB_TCPTOZEROWINDOWADV);
	} else if (old_win == 0) {
		NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPFROMZEROWINDOWADV);
	}

	return new_win;
}

```

```c
u32 __tcp_select_window(struct sock *sk)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
	struct tcp_sock *tp = tcp_sk(sk);
	/* MSS for the peer's data.  Previous versions used mss_clamp
	 * here.  I don't know if the value based on our guesses
	 * of peer's MSS is better for the performance.  It's more correct
	 * but may be worse for the performance because of rcv_mss
	 * fluctuations.  --SAW  1998/11/1
	 */
	int mss = icsk->icsk_ack.rcv_mss;
	int free_space = tcp_space(sk);
	int allowed_space = tcp_full_space(sk);
	int full_space = min_t(int, tp->window_clamp, allowed_space);
	int window;

	if (mss > full_space)
		mss = full_space;

	if (free_space < (full_space >> 1)) {
		icsk->icsk_ack.quick = 0;

		if (sk_under_memory_pressure(sk))
			tp->rcv_ssthresh = min(tp->rcv_ssthresh,
					       4U * tp->advmss);

		/* free_space might become our new window, make sure we don't
		 * increase it due to wscale.
		 */
		free_space = round_down(free_space, 1 << tp->rx_opt.rcv_wscale);

		/* if free space is less than mss estimate, or is below 1/16th
		 * of the maximum allowed, try to move to zero-window, else
		 * tcp_clamp_window() will grow rcv buf up to tcp_rmem[2], and
		 * new incoming data is dropped due to memory limits.
		 * With large window, mss test triggers way too late in order
		 * to announce zero window in time before rmem limit kicks in.
		 */
		if (free_space < (allowed_space >> 4) || free_space < mss)
			return 0;
	}

	if (free_space > tp->rcv_ssthresh)
		free_space = tp->rcv_ssthresh;

	/* Don't do rounding if we are using window scaling, since the
	 * scaled window will not line up with the MSS boundary anyway.
	 */
	window = tp->rcv_wnd;
	if (tp->rx_opt.rcv_wscale) {
		window = free_space;

		/* Advertise enough space so that it won't get scaled away.
		 * Import case: prevent zero window announcement if
		 * 1<<rcv_wscale > mss.
		 */
		if (((window >> tp->rx_opt.rcv_wscale) << tp->rx_opt.rcv_wscale) != window)
			window = (((window >> tp->rx_opt.rcv_wscale) + 1)
				  << tp->rx_opt.rcv_wscale);
	} else {
		/* Get the largest window that is a nice multiple of mss.
		 * Window clamp already applied above.
		 * If our current window offering is within 1 mss of the
		 * free space we just keep it. This prevents the divide
		 * and multiply from happening most of the time.
		 * We also don't do any window rounding when the free space
		 * is too small.
		 */
		if (window <= free_space - mss || window > free_space)
			window = (free_space / mss) * mss;
		else if (mss == full_space &&
			 free_space > window + (full_space >> 1))
			window = free_space;
	}

	return window;
}
```


### 小结

关于TCP传输层协议相关的发送逻辑到这里了，下一篇文章来聊聊ip层一直到数据链路层的逻辑。·