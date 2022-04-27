---
title: Android socket源码解析(二)socket的绑定与监听
top: false
cover: false
date: 2022-04-24 23:17:07
img:
tag: socket
description:
author: yjy239
summary:
---

# 前言

对socket在内核的设计又了初步的印象后，可以进一步的探索socket整个流程。在这里我们先讨论服务端中，如果把准备好一个socket 绑定并进行监听的。

如果遇到什么问题可以来 https://www.jianshu.com/p/62dd608667e2 本文下讨论

# 正文

来看看服务端初始化的核心：
　
```java
    ServerSocket server = new ServerSocket(port);
   
    Socket socket = server.accept();
```

首先看看初始化：

```java
    public ServerSocket(int port) throws IOException {
        this(port, 50, null);
    }

    public ServerSocket(int port, int backlog, InetAddress bindAddr) throws IOException {
        setImpl();
        if (port < 0 || port > 0xFFFF)
            throw new IllegalArgumentException(
                       "Port value out of range: " + port);
        if (backlog < 1)
          backlog = 50;
        try {
            bind(new InetSocketAddress(bindAddr, port), backlog);
        } catch(SecurityException e) {
            close();
            throw e;
        } catch(IOException e) {
            close();
            throw e;
        }
    }
```

首先限制了服务监听的端口号必须在0-65535 之间。一旦超出则直接报错`IllegalArgumentException`.

接着调用`bind`方法。

```java
 public void bind(SocketAddress endpoint, int backlog) throws IOException {
        if (isClosed())
            throw new SocketException("Socket is closed");
        if (!oldImpl && isBound())
            throw new SocketException("Already bound");
        if (endpoint == null)
            endpoint = new InetSocketAddress(0);
        if (!(endpoint instanceof InetSocketAddress))
            throw new IllegalArgumentException("Unsupported address type");
        InetSocketAddress epoint = (InetSocketAddress) endpoint;
        if (epoint.isUnresolved())
            throw new SocketException("Unresolved address");
        if (backlog < 1)
          backlog = 50;
        try {
            SecurityManager security = System.getSecurityManager();
            if (security != null)
                security.checkListen(epoint.getPort());
            getImpl().bind(epoint.getAddress(), epoint.getPort());
            getImpl().listen(backlog);
            bound = true;
        } catch(SecurityException e) {
            bound = false;
            throw e;
        } catch(IOException e) {
            bound = false;
            throw e;
        }
    }
```


首先在android中`getSecurityManager `返回的是空，这里不考察。

接着走的逻辑是两个步骤：

- 1. SocksSocketImpl 的 bind，参数就是传递进来的 `InetSocketAddress `
- 2. SocksSocketImpl 的listen ，参数为backlog的50



### 1.SocksSocketImpl bind

```java
    /**
     * Binds the socket to the specified address of the specified local port.
     * @param address the address
     * @param lport the port
     */
    protected synchronized void bind(InetAddress address, int lport)
        throws IOException
    {
       synchronized (fdLock) {
            if (!closePending && (socket == null || !socket.isBound())) {
                NetHooks.beforeTcpBind(fd, address, lport);
            }
        }
        socketBind(address, lport);
        if (socket != null)
            socket.setBound();
        if (serverSocket != null)
            serverSocket.setBound();
    }
```

核心调用了如下几个方法：

- 1.socketBind
- 2.setBound

#### socketBind

```java
    void socketBind(InetAddress address, int port) throws IOException {
        if (fd == null || !fd.valid()) {
            throw new SocketException("Socket closed");
        }

        IoBridge.bind(fd, address, port);

        this.address = address;
        if (port == 0) {
            // Now that we're a connected socket, let's extract the port number that the system
            // chose for us and store it in the Socket object.
            localport = IoBridge.getLocalInetSocketAddress(fd).getPort();
        } else {
            localport = port;
        }
    }

```

```java
    public static void bind(FileDescriptor fd, InetAddress address, int port) throws SocketException {
       ...
        try {
            Libcore.os.bind(fd, address, port);
        } catch (ErrnoException errnoException) {
            if (errnoException.errno == EADDRINUSE || errnoException.errno == EADDRNOTAVAIL ||
                errnoException.errno == EPERM || errnoException.errno == EACCES) {
                throw new BindException(errnoException.getMessage(), errnoException);
            } else {
                throw new SocketException(errnoException.getMessage(), errnoException);
            }
        }
    }

```

核心调用了`Linux`的`bind`方法。


#### 2.libcore_io_Linux  Linux_bind

文件： /[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[luni](http://androidxref.com/9.0.0_r3/xref/libcore/luni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/)/[native](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/)/[libcore_io_Linux.cpp](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/libcore_io_Linux.cpp)


```cpp
static void Linux_bind(JNIEnv* env, jobject, jobject javaFd, jobject javaAddress, jint port) {
    // We don't need the return value because we'll already have thrown.
    (void) NET_IPV4_FALLBACK(env, int, bind, javaFd, javaAddress, port, NULL_ADDR_FORBIDDEN);
}
```

核心是下面两个宏：

```cpp
#define NET_IPV4_FALLBACK(jni_env, return_type, syscall_name, java_fd, java_addr, port, null_addr_ok, args...) ({ \
    return_type _rc = -1; \
    do { \
        sockaddr_storage _ss; \
        socklen_t _salen; \
        if ((java_addr) == NULL && (null_addr_ok)) { \
            /* No IP address specified (e.g., sendto() on a connected socket). */ \
            _salen = 0; \
        } else if (!inetAddressToSockaddr(jni_env, java_addr, port, _ss, _salen)) { \
            /* Invalid socket address, return -1. inetAddressToSockaddr has already thrown. */ \
            break; \
        } \
        sockaddr* _sa = _salen ? reinterpret_cast<sockaddr*>(&_ss) : NULL; \
        /* inetAddressToSockaddr always returns an IPv6 sockaddr. Assume that java_fd was created \
         * by Java API calls, which always create IPv6 socket fds, and pass it in as is. */ \
        _rc = NET_FAILURE_RETRY(jni_env, return_type, syscall_name, java_fd, ##args, _sa, _salen); \
        if (_rc == -1 && errno == EAFNOSUPPORT && _salen && isIPv4MappedAddress(_sa)) { \
            /* We passed in an IPv4 address in an IPv6 sockaddr and the kernel told us that we got \
             * the address family wrong. Pass in the same address in an IPv4 sockaddr. */ \
            (jni_env)->ExceptionClear(); \
            if (!inetAddressToSockaddrVerbatim(jni_env, java_addr, port, _ss, _salen)) { \
                break; \
            } \
            _sa = reinterpret_cast<sockaddr*>(&_ss); \
            _rc = NET_FAILURE_RETRY(jni_env, return_type, syscall_name, java_fd, ##args, _sa, _salen); \
        } \
    } while (0); \
    _rc; }) \




#define NET_FAILURE_RETRY(jni_env, return_type, syscall_name, java_fd, ...) ({ \
    return_type _rc = -1; \
    int _syscallErrno; \
    do { \
        bool _wasSignaled; \
        { \
            int _fd = jniGetFDFromFileDescriptor(jni_env, java_fd); \
            AsynchronousCloseMonitor _monitor(_fd); \
            _rc = syscall_name(_fd, __VA_ARGS__); \
            _syscallErrno = errno; \
            _wasSignaled = _monitor.wasSignaled(); \
        } \
        if (_wasSignaled) { \
            jniThrowException(jni_env, "java/net/SocketException", "Socket closed"); \
            _rc = -1; \
            break; \
        } \
        if (_rc == -1 && _syscallErrno != EINTR) { \
            /* TODO: with a format string we could show the arguments too, like strace(1). */ \
            throwErrnoException(jni_env, # syscall_name); \
            break; \
        } \
    } while (_rc == -1); /* _syscallErrno == EINTR && !_wasSignaled */ \
    if (_rc == -1) { \
        /* If the syscall failed, re-set errno: throwing an exception might have modified it. */ \
        errno = _syscallErrno; \
    } \
    _rc; })
```

核心能看到通过jni反射获取FileDescriptor 中的fd 具柄，然后调用`bind`系统调用。

其中bind系统调用的参数,通过`inetAddressToSockaddr ` 把InetAddress 类获取fd，协议族类型，port转化成`sockaddr_in`结构体：

```c
struct sockaddr_in {
  __kernel_sa_family_t sin_family; // 族群
  __be16 sin_port; // port 端口
  struct in_addr sin_addr; // ip地址
  unsigned char __pad[__SOCK_SIZE__ - sizeof(short int) - sizeof(unsigned short int) - sizeof(struct in_addr)];
};
```

值得学习的一点是，在c的编程中使用 #define 的定义。可以使用do... while(0)的方法，保证一个代码域的完整性，不被如if等特殊的程序顺序符给截断宏的代码完整逻辑性


#### 3.内核的bind 系统调用

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[socket.c](http://androidxref.com/kernel_3.18/xref/net/socket.c)


```c
SYSCALL_DEFINE3(bind, int, fd, struct sockaddr __user *, umyaddr, int, addrlen)
{
	struct socket *sock;
	struct sockaddr_storage address;
	int err, fput_needed;

	sock = sockfd_lookup_light(fd, &err, &fput_needed);
	if (sock) {
		err = move_addr_to_kernel(umyaddr, addrlen, &address);
		if (err >= 0) {
			err = security_socket_bind(sock,
						   (struct sockaddr *)&address,
						   addrlen);
			if (!err)
				err = sock->ops->bind(sock,
						      (struct sockaddr *)
						      &address, addrlen);
		}
		fput_light(sock->file, fput_needed);
	}
	return err;
}
```

- 1.`sockfd_lookup_light` 通过fd找到文件结构体的`private_data`私有数据 ，也就是`socket`结构体

- 2. `move_addr_to_kernel` 方法 则是把用户态的`sockaddr` 转化为`sockaddr_storage `。

- 3.`security_socket_bind `进行selinux的校验，判断是否有权限调用socket文件描述符的bind方法。

- 4.没问题则调用`socket`结构体的`bind` 方法。

- 5.`fput_light ` 根据`fput_needed `决定是是否回收socket结构体中的fd 分配的句柄。

注意，这里的ops是指socket结构体中的`proto_ops`.如果此时是IPV4协议，那么就是指`inet_stream_ops `的`bind`方法指针，也就是inet_bind方法。

#### 3.1.proto_ops inet_bind

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[af_inet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/af_inet.c)

```c
int inet_bind(struct socket *sock, struct sockaddr *uaddr, int addr_len)
{
	struct sockaddr_in *addr = (struct sockaddr_in *)uaddr;
	struct sock *sk = sock->sk;
	struct inet_sock *inet = inet_sk(sk);
	struct net *net = sock_net(sk);
	unsigned short snum;
	int chk_addr_ret;
	int err;
	snum = ntohs(addr->sin_port);
	err = -EACCES;
	if (snum && snum < PROT_SOCK &&
	    !ns_capable(net->user_ns, CAP_NET_BIND_SERVICE))
		goto out;

	lock_sock(sk);

	/* Check these errors (active socket, double bind). */
	err = -EINVAL;
	if (sk->sk_state != TCP_CLOSE || inet->inet_num)
		goto out_release_sock;

	inet->inet_rcv_saddr = inet->inet_saddr = addr->sin_addr.s_addr;
	if (chk_addr_ret == RTN_MULTICAST || chk_addr_ret == RTN_BROADCAST)
		inet->inet_saddr = 0;  /* Use device */

	/* Make sure we are allowed to bind here. */
	if (sk->sk_prot->get_port(sk, snum)) {
		inet->inet_saddr = inet->inet_rcv_saddr = 0;
		err = -EADDRINUSE;
		goto out_release_sock;
	}

	if (inet->inet_rcv_saddr)
		sk->sk_userlocks |= SOCK_BINDADDR_LOCK;
	if (snum)
		sk->sk_userlocks |= SOCK_BINDPORT_LOCK;
	inet->inet_sport = htons(inet->inet_num);
	inet->inet_daddr = 0;
	inet->inet_dport = 0;
	sk_dst_reset(sk);
	err = 0;
out_release_sock:
	release_sock(sk);
out:
	return err;
}
EXPORT_SYMBOL(inet_bind);
```

这个过程实际上很简单，就是把socket结构体转化回`inet_sock `结构体。并在`inet_sock `的`inet_sport`记录来源的ip地址。初始化  `inet_daddr`以及  `inet_dport`.也就是初始化目标通信的端口ip和port。

- 注意这个过程中，先从`sockaddr`的`sin_port `获取到从jni中设置进去的端口号。

- 接着通过`sk->sk_prot->get_port`把端口`snum`设置到`inet_sock`的`inet_num`中，并校验当前的端口号是否小于`1024`,因为只有超级用户才能使用小于1024的端口号，如果发现非法则绑定失败。

- 最后才将`inet_num`设置到`inet_sport`作为服务端设置的端口号。




## 4.SocketServer socketListen

同理，listen也是类似的逻辑。最后会调用到`PlainSocketImpl `的`socketListen`

```java
    void socketListen(int count) throws IOException {
        if (fd == null || !fd.valid()) {
            throw new SocketException("Socket closed");
        }

        try {
            Libcore.os.listen(fd, count);
        } catch (ErrnoException errnoException) {
            throw errnoException.rethrowAsSocketException();
        }
    }
```

```cpp
static void Linux_listen(JNIEnv* env, jobject, jobject javaFd, jint backlog) {
    int fd = jniGetFDFromFileDescriptor(env, javaFd);
    throwIfMinusOne(env, "listen", TEMP_FAILURE_RETRY(listen(fd, backlog)));
}

template <typename rc_t>
static rc_t throwIfMinusOne(JNIEnv* env, const char* name, rc_t rc) {
    if (rc == rc_t(-1)) {
        throwErrnoException(env, name);
    }
    return rc;
}
```

能看到这个过程中，实际上还是调用了listen系统调用。不过一旦listen调用返回异常，就会把异常跑到了Java层。

#### 5.Linux 内核listen

```c
SYSCALL_DEFINE2(listen, int, fd, int, backlog)
{
	struct socket *sock;
	int err, fput_needed;
	int somaxconn;

	sock = sockfd_lookup_light(fd, &err, &fput_needed);
	if (sock) {
		somaxconn = sock_net(sock->sk)->core.sysctl_somaxconn;
		if ((unsigned int)backlog > somaxconn)
			backlog = somaxconn;

		err = security_socket_listen(sock, backlog);
		if (!err)
			err = sock->ops->listen(sock, backlog);

		fput_light(sock->file, fput_needed);
	}
	return err;
}
```

这里的逻辑和bind十分相似。本质上先从socket结构体中获取ops，也就是`proto_ops `结构体。在ipV4的协议中也就是指代`inet_stream_ops`。在这里也就是指向方法指针`inet_listen`
`

#### 5.1.inet_stream_ops inet_listen
文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[af_inet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/af_inet.c)

```c
int inet_listen(struct socket *sock, int backlog)
{
	struct sock *sk = sock->sk;
	unsigned char old_state;
	int err;

	lock_sock(sk);

	err = -EINVAL;
	if (sock->state != SS_UNCONNECTED || sock->type != SOCK_STREAM)
		goto out;

	old_state = sk->sk_state;
	if (!((1 << old_state) & (TCPF_CLOSE | TCPF_LISTEN)))
		goto out;

	if (old_state != TCP_LISTEN) {
		if ((sysctl_tcp_fastopen & TFO_SERVER_ENABLE) != 0 &&
		    inet_csk(sk)->icsk_accept_queue.fastopenq == NULL) {
			if ((sysctl_tcp_fastopen & TFO_SERVER_WO_SOCKOPT1) != 0)
				err = fastopen_init_queue(sk, backlog);
			else if ((sysctl_tcp_fastopen &
				  TFO_SERVER_WO_SOCKOPT2) != 0)
				err = fastopen_init_queue(sk,
				    ((uint)sysctl_tcp_fastopen) >> 16);
			else
				err = 0;
			if (err)
				goto out;
		}
		err = inet_csk_listen_start(sk, backlog);
		if (err)
			goto out;
	}
	sk->sk_max_ack_backlog = backlog;
	err = 0;

out:
	release_sock(sk);
	return err;
}
EXPORT_SYMBOL(inet_listen);
```

- 1.首先校验`sock`结构体中的`type`类型必须是`SOCK_STREAM`并且`state`是`SS_UNCONNECTED`没有链接状态，才能继续向下走逻辑。否则返回异常，并释放sock结构体。

- 2.`sock`结构体的state字段往左移动一位，并校验当前是否是LISTEN或者TCPF_CLOSE状态。如果是则释放sock结构体

- 3.如果当前的状态不是`TCP_LISTEN`,那么会通过`fastopen_init_queue`初始化在sock结构体中的accept队列，最后调用`inet_csk_listen_start` 刷新当前的状态为`TCP_LISTEN`。如果已经处于了`TCP_LISTEN`监听状态，那么就刷新`sk_max_ack_backlog`。

注意这个`sk_max_ack_backlog`数值就是accept的缓存区大小。

#### 5.2.fastopen_init_queue

```c
static inline int fastopen_init_queue(struct sock *sk, int backlog)
{
	struct request_sock_queue *queue =
	    &inet_csk(sk)->icsk_accept_queue;

	if (queue->fastopenq == NULL) {
		queue->fastopenq = kzalloc(
		    sizeof(struct fastopen_queue),
		    sk->sk_allocation);
		if (queue->fastopenq == NULL)
			return -ENOMEM;

		sk->sk_destruct = tcp_sock_destruct;
		spin_lock_init(&queue->fastopenq->lock);
	}
	queue->fastopenq->max_qlen = backlog;
	return 0;
}
```

这里面有一个十分重要的字段`icsk_accept_queue`.这个对象是一个承载来自客户端的请求数据链表结构体。

而在这个方法实际上初始化了`fastopen_queue`。这是TFO(TCP Fast Open)核心结构体.这个技术实际上在很早之前就植入到内核中了。

它本质上在三次握手的阶段，客户端和服务端可以在cookie校验成功后互相通信一些数据。三次握手中第一步生成校验cookie。而后在SYN回包中就可以带上一些数据。

至于这么做的原因是Google在2011年的时候，发现重新链接的场景比较多，且是耗时的一个原因。会大致上耗费多一个RTT。因此做了这个优化并放入到2.6.3的内核版本中。

详细的可以阅读这篇文章http://www.vants.org/?post=210

#### 服务端监听socket的核心结构体

来看看整个结构体的构成:

```c
struct request_sock {
	struct sock_common		__req_common;
	struct request_sock		*dl_next;
	u16				mss;
	u8				num_retrans; /* number of retransmits */
	u8				cookie_ts:1; /* syncookie: encode tcpopts in timestamp */
	u8				num_timeout:7; /* number of timeouts */
	/* The following two fields can be easily recomputed I think -AK */
	u32				window_clamp; /* window clamp at creation time */
	u32				rcv_wnd;	  /* rcv_wnd offered first time */
	u32				ts_recent;
	unsigned long			expires;
	const struct request_sock_ops	*rsk_ops;
	struct sock			*sk;
	u32				secid;
	u32				peer_secid;
};

/** struct listen_sock - listen state
 *
 * @max_qlen_log - log_2 of maximal queued SYNs/REQUESTs
 */
struct listen_sock {
	u8			max_qlen_log;
	u8			synflood_warned;
	/* 2 bytes hole, try to use */
	int			qlen;
	int			qlen_young;
	int			clock_hand;
	u32			hash_rnd;
	u32			nr_table_entries;
	struct request_sock	*syn_table[0];
};

struct fastopen_queue {
	struct request_sock	*rskq_rst_head; /* Keep track of past TFO */
	struct request_sock	*rskq_rst_tail; /* requests that caused RST.
						 * This is part of the defense
						 * against spoofing attack.
						 */
	spinlock_t	lock;
	int		qlen;		/* # of pending (TCP_SYN_RECV) reqs */
	int		max_qlen;	/* != 0 iff TFO is currently enabled */
};


struct request_sock_queue {
	struct request_sock	*rskq_accept_head;
	struct request_sock	*rskq_accept_tail;
	rwlock_t		syn_wait_lock;
	u8			rskq_defer_accept;
	/* 3 bytes hole, try to pack */
	struct listen_sock	*listen_opt;
	struct fastopen_queue	*fastopenq; /* This is non-NULL iff TFO has been
					     * enabled on this listener. Check
					     * max_qlen != 0 in fastopen_queue
					     * to determine if TFO is enabled
					     * right at this moment.
					     */
};
```

##### request_sock_queue

首先来看看最外层的核心结构体`request_sock_queue`的构成

- rskq_accept_head accept服务端接受客户端请求的链表队列头
- rskq_accept_tail accept服务端接受客户端请求的链表队列尾巴
- syn_wait_lock 一个读写锁，由于保护客户端请求链表的链表头的写入和变化
- listen_opt 记录监听状态
- fastopenq TFO 接受队列


##### request_sock
对于每一个请求来说，当客户端发送请求，通过网卡进入内核后，都会变成一个个`request_sock`缓存在队列中。等待服务端的消费处理。

- `__req_common ` sock_common结构体 在socket中最常用的结构体。sock_common这个结构体也存在在`sock`结构体中。存储着所有socket系统调用中常用的数据。比如socket使用的协议，接收端的地址和端口，发送端的地址等等。只是在之前看不到是因为通过define 宏定义定义了快速访问`sock_common`的方式。在这里意味着服务端接收到从哪个客户端的请求。

- `dl_next`链表链接的下一个`request_sock`
- `mss` 最长报文段
- `num_retrans`重传次数
- `num_timeout `超时次数
- `request_sock_ops ` 来自客户端请求所对应的操作方法
- `sk ` 对应客户端请求的socket结构体

在这里之所以会对应一个socket结构体，是因为在下面accept系统调用的时候会多创建一个新的socket。


#### fastopen_queue
能看到`fastopen_queue `这个结构体和`request_sock_queue`十分相似。因为他的定位就是在三次握手过程中传递数据。




#### inet_csk_listen_start

文件:/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[inet_connection_sock.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/inet_connection_sock.c)


```c
int inet_csk_listen_start(struct sock *sk, const int nr_table_entries)
{
	struct inet_sock *inet = inet_sk(sk);
	struct inet_connection_sock *icsk = inet_csk(sk);
	int rc = reqsk_queue_alloc(&icsk->icsk_accept_queue, nr_table_entries);

	if (rc != 0)
		return rc;

	sk->sk_max_ack_backlog = 0;
	sk->sk_ack_backlog = 0;
	inet_csk_delack_init(sk);

	sk->sk_state = TCP_LISTEN;
	if (!sk->sk_prot->get_port(sk, inet->inet_num)) {
		inet->inet_sport = htons(inet->inet_num);

		sk_dst_reset(sk);
		sk->sk_prot->hash(sk);

		return 0;
	}

	sk->sk_state = TCP_CLOSE;
	__reqsk_queue_destroy(&icsk->icsk_accept_queue);
	return -EADDRINUSE;
}
EXPORT_SYMBOL_GPL(inet_csk_listen_start);
```
- 把`sock`结构体转化成`inet_connection_sock`,并初始化`icsk_accept_queue`。注意在函数 `reqsk_queue_alloc`申请内存的过程中，会对`listen_sock`进行单独的计算。因为其中有一个特殊的字段`struct request_sock	*syn_table[0];`一个数组的第一项。因此此时会根据`backlog`大小决定这个数组指针的所指向的数组长度。

- 将`sock`的state(状态) 设置为`TCP_LISTEN`

- 记录当前服务端设置的源端口

## ServerSocket accept

```java
    public Socket accept() throws IOException {
        if (isClosed())
            throw new SocketException("Socket is closed");
        if (!isBound())
            throw new SocketException("Socket is not bound yet");
        Socket s = new Socket((SocketImpl) null);
        implAccept(s);
        return s;
    }
```

```java
    protected final void implAccept(Socket s) throws IOException {
        SocketImpl si = null;
        try {
            if (s.impl == null)
              s.setImpl();
            else {
                s.impl.reset();
            }
            si = s.impl;
            s.impl = null;
            si.address = new InetAddress();
            si.fd = new FileDescriptor();
            getImpl().accept(si);

            SecurityManager security = System.getSecurityManager();
            if (security != null) {
                security.checkAccept(si.getInetAddress().getHostAddress(),
                                     si.getPort());
            }
        } catch (IOException e) {
            if (si != null)
                si.reset();
            s.impl = si;
            throw e;
        } catch (SecurityException e) {
            if (si != null)
                si.reset();
            s.impl = si;
            throw e;
        }
        s.impl = si;
        s.postAccept();
    }
```

核心就是两个方法：

- 1.调用SocketImpl的accept方法
- 2.调用SocketImpl的postAccept

而SocketImpl是AbstractPlainSocketImpl派生类，而accept的方法是隶属SocketImpl

#### AbstractPlainSocketImpl accept

/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[ojluni](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/)/[net](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/)/[AbstractPlainSocketImpl.java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/AbstractPlainSocketImpl.java)


```java
    /**
     * Accepts connections.
     * @param s the connection
     */
    protected void accept(SocketImpl s) throws IOException {
        acquireFD();
        try {
            // Android-added: BlockGuard
            BlockGuard.getThreadPolicy().onNetwork();
            socketAccept(s);
        } finally {
            releaseFD();
        }
    }
```
socketAccept 方法则是由PlainSocketImpl 实现：

/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[ojluni](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/)/[net](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/)/[PlainSocketImpl.java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/PlainSocketImpl.java)


```java
    void socketAccept(SocketImpl s) throws IOException {
        if (fd == null || !fd.valid()) {
            throw new SocketException("Socket closed");
        }

        // poll() with a timeout of 0 means "poll for zero millis", but a Socket timeout == 0 means
        // "wait forever". When timeout == 0 we pass -1 to poll.
        if (timeout <= 0) {
            IoBridge.poll(fd, POLLIN | POLLERR, -1);
        } else {
            IoBridge.poll(fd, POLLIN | POLLERR, timeout);
        }

        InetSocketAddress peerAddress = new InetSocketAddress();
        try {
            FileDescriptor newfd = Libcore.os.accept(fd, peerAddress);

            s.fd.setInt$(newfd.getInt$());
            s.address = peerAddress.getAddress();
            s.port = peerAddress.getPort();
        } catch (ErrnoException errnoException) {
            if (errnoException.errno == EAGAIN) {
                throw new SocketTimeoutException(errnoException);
            } else if (errnoException.errno == EINVAL || errnoException.errno == EBADF) {
                throw new SocketException("Socket closed");
            }
            errnoException.rethrowAsSocketException();
        }

        s.localport = IoBridge.getLocalInetSocketAddress(s.fd).getPort();
    }
```

这里面的实现核心如下分为几点

- 1.先通过`IoBridge.poll` 调用poll系统调用，阻塞等待socket所对应的fd句柄。
- 2.当阻塞放开了，就通过端口号和地址调用`Libcore.os.accept`方法获取全新的FileDescriptor 句柄对象。
- 3.然后就可以通过获取socket的IO流读取数据的到来。

#### IoBridge.poll

这个方法最终回调用到`Libcore.os.poll`方法。而这个方法最终调用到一个native方法：

文件：/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[luni](http://androidxref.com/9.0.0_r3/xref/libcore/luni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/)/[native](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/)/[libcore_io_Linux.cpp](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/libcore_io_Linux.cpp)

```cpp
static jint Linux_poll(JNIEnv* env, jobject, jobjectArray javaStructs, jint timeoutMs) {
    static jfieldID fdFid = env->GetFieldID(JniConstants::structPollfdClass, "fd", "Ljava/io/FileDescriptor;");
    static jfieldID eventsFid = env->GetFieldID(JniConstants::structPollfdClass, "events", "S");
    static jfieldID reventsFid = env->GetFieldID(JniConstants::structPollfdClass, "revents", "S");

    // Turn the Java android.system.StructPollfd[] into a C++ struct pollfd[].
    size_t arrayLength = env->GetArrayLength(javaStructs);
    std::unique_ptr<struct pollfd[]> fds(new struct pollfd[arrayLength]);
    memset(fds.get(), 0, sizeof(struct pollfd) * arrayLength);
    size_t count = 0; // Some trailing array elements may be irrelevant. (See below.)
    for (size_t i = 0; i < arrayLength; ++i) {
        ScopedLocalRef<jobject> javaStruct(env, env->GetObjectArrayElement(javaStructs, i));
        if (javaStruct.get() == NULL) {
            break; // We allow trailing nulls in the array for caller convenience.
        }
        ScopedLocalRef<jobject> javaFd(env, env->GetObjectField(javaStruct.get(), fdFid));
        if (javaFd.get() == NULL) {
            break; // We also allow callers to just clear the fd field (this is what Selector does).
        }
        fds[count].fd = jniGetFDFromFileDescriptor(env, javaFd.get());
        fds[count].events = env->GetShortField(javaStruct.get(), eventsFid);
        ++count;
    }

    std::vector<AsynchronousCloseMonitor*> monitors;
    for (size_t i = 0; i < count; ++i) {
        monitors.push_back(new AsynchronousCloseMonitor(fds[i].fd));
    }

    int rc;
    while (true) {
        timespec before;
        clock_gettime(CLOCK_MONOTONIC, &before);

        rc = poll(fds.get(), count, timeoutMs);
        if (rc >= 0 || errno != EINTR) {
            break;
        }

        // We got EINTR. Work out how much of the original timeout is still left.
        if (timeoutMs > 0) {
            timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);

            timespec diff;
            diff.tv_sec = now.tv_sec - before.tv_sec;
            diff.tv_nsec = now.tv_nsec - before.tv_nsec;
            if (diff.tv_nsec < 0) {
                --diff.tv_sec;
                diff.tv_nsec += 1000000000;
            }

            jint diffMs = diff.tv_sec * 1000 + diff.tv_nsec / 1000000;
            if (diffMs >= timeoutMs) {
                rc = 0; // We have less than 1ms left anyway, so just time out.
                break;
            }

            timeoutMs -= diffMs;
        }
    }

    for (size_t i = 0; i < monitors.size(); ++i) {
        delete monitors[i];
    }
    if (rc == -1) {
        throwErrnoException(env, "poll");
        return -1;
    }

    // Update the revents fields in the Java android.system.StructPollfd[].
    for (size_t i = 0; i < count; ++i) {
        ScopedLocalRef<jobject> javaStruct(env, env->GetObjectArrayElement(javaStructs, i));
        if (javaStruct.get() == NULL) {
            return -1;
        }
        env->SetShortField(javaStruct.get(), reventsFid, fds[i].revents);
    }
    return rc;
}
```

这里面的逻辑很简单：

在一个死循环中被系统调用poll阻塞起来，而这个过程中会阻塞参数timeoutMs的时间。如果poll阻塞提前结束，但是阻塞的结果不是正常结束还会在这个循环中继续阻塞起来。

#### Libcore.os.accept

```cpp
static jobject Linux_accept(JNIEnv* env, jobject, jobject javaFd, jobject javaSocketAddress) {
    sockaddr_storage ss;
    socklen_t sl = sizeof(ss);
    memset(&ss, 0, sizeof(ss));
    sockaddr* peer = (javaSocketAddress != NULL) ? reinterpret_cast<sockaddr*>(&ss) : NULL;
    socklen_t* peerLength = (javaSocketAddress != NULL) ? &sl : 0;
    jint clientFd = NET_FAILURE_RETRY(env, int, accept, javaFd, peer, peerLength);
    if (clientFd == -1 || !fillSocketAddress(env, javaSocketAddress, ss, *peerLength)) {
        close(clientFd);
        return NULL;
    }
    return (clientFd != -1) ? (env, clientFd) : NULL;
}

```

```cpp
#define NET_FAILURE_RETRY(jni_env, return_type, syscall_name, java_fd, ...) ({ \
    return_type _rc = -1; \
    int _syscallErrno; \
    do { \
        bool _wasSignaled; \
        { \
            int _fd = jniGetFDFromFileDescriptor(jni_env, java_fd); \
            AsynchronousCloseMonitor _monitor(_fd); \
            _rc = syscall_name(_fd, __VA_ARGS__); \
            _syscallErrno = errno; \
            _wasSignaled = _monitor.wasSignaled(); \
        } \
        if (_wasSignaled) { \
            jniThrowException(jni_env, "java/net/SocketException", "Socket closed"); \
            _rc = -1; \
            break; \
        } \
        if (_rc == -1 && _syscallErrno != EINTR) { \
            /* TODO: with a format string we could show the arguments too, like strace(1). */ \
            throwErrnoException(jni_env, # syscall_name); \
            break; \
        } \
    } while (_rc == -1); /* _syscallErrno == EINTR && !_wasSignaled */ \
    if (_rc == -1) { \
        /* If the syscall failed, re-set errno: throwing an exception might have modified it. */ \
        errno = _syscallErrno; \
    } \
    _rc; })
```

核心就是这个define声明的宏调用了accept系统调用。关于这个宏为什么使用do while方式包裹之前的文章已经聊过了。

#### accept系统调用

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[socket.c](http://androidxref.com/kernel_3.18/xref/net/socket.c)


```c
SYSCALL_DEFINE4(accept4, int, fd, struct sockaddr __user *, upeer_sockaddr,
		int __user *, upeer_addrlen, int, flags)
{
	struct socket *sock, *newsock;
	struct file *newfile;
	int err, len, newfd, fput_needed;
	struct sockaddr_storage address;

	if (flags & ~(SOCK_CLOEXEC | SOCK_NONBLOCK))
		return -EINVAL;

	if (SOCK_NONBLOCK != O_NONBLOCK && (flags & SOCK_NONBLOCK))
		flags = (flags & ~SOCK_NONBLOCK) | O_NONBLOCK;

	sock = sockfd_lookup_light(fd, &err, &fput_needed);
...

	err = -ENFILE;
	newsock = sock_alloc();
...

	newsock->type = sock->type;
	newsock->ops = sock->ops;

	__module_get(newsock->ops->owner);

	newfd = get_unused_fd_flags(flags);
...
	newfile = sock_alloc_file(newsock, flags, sock->sk->sk_prot_creator->name);
	if (unlikely(IS_ERR(newfile))) {
		err = PTR_ERR(newfile);
		put_unused_fd(newfd);
		sock_release(newsock);
		goto out_put;
	}

	err = security_socket_accept(sock, newsock);
	if (err)
		goto out_fd;

	err = sock->ops->accept(sock, newsock, sock->file->f_flags);
	if (err < 0)
		goto out_fd;

	if (upeer_sockaddr) {
		if (newsock->ops->getname(newsock, (struct sockaddr *)&address,
					  &len, 2) < 0) {
			err = -ECONNABORTED;
			goto out_fd;
		}
		err = move_addr_to_user(&address,
					len, upeer_sockaddr, upeer_addrlen);
		if (err < 0)
			goto out_fd;
	}

	/* File flags are not inherited via accept() unlike another OSes. */

	fd_install(newfd, newfile);
	err = newfd;

...
}
```

首先能看到整个accpet系统调用中，实际上可以存在两个socket，两个socket所对应的fd。

- 1.首先先根据fd获取一开始通过new Socket声明的socket结构体，并校验合法性
- 2.然后会创建一个全新的socket结构体以及一个全新的fd句柄。并拷贝旧的socket的类型，以及协议操作符号。此时·如果是ipV4协议，那么就是inet4_stream_ops

- 3.接着把两个socket经过accpet所对应的安全策略校验
- 4.调用socket的ops的accept，也就是inet_stream_ops所对应的accept所指向的方法指针。把刚刚生成的新socket结构体作为参数传入
- 5.把新的文件句柄和新的socket联系起来。

#### inet_accept

文件： /[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[af_inet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/af_inet.c)

```c
int inet_accept(struct socket *sock, struct socket *newsock, int flags)
{
	struct sock *sk1 = sock->sk;
	int err = -EINVAL;
	struct sock *sk2 = sk1->sk_prot->accept(sk1, flags, &err);

	if (!sk2)
		goto do_err;

	lock_sock(sk2);

	sock_rps_record_flow(sk2);
	WARN_ON(!((1 << sk2->sk_state) &
		  (TCPF_ESTABLISHED | TCPF_SYN_RECV |
		  TCPF_CLOSE_WAIT | TCPF_CLOSE)));

	sock_graft(sk2, newsock);

	newsock->state = SS_CONNECTED;
	err = 0;
	release_sock(sk2);
do_err:
	return err;
}
EXPORT_SYMBOL(inet_accept);
```

注意这里的`sk1->sk_prot`则是指向了`proto `结构体。在IPV4中就是指`tcp_prot `.因此这个accept方法指针就是指`inet_csk_accept `方法。


#### inet_csk_accept

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[inet_connection_sock.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/inet_connection_sock.c)


```c
struct sock *inet_csk_accept(struct sock *sk, int flags, int *err)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
	struct request_sock_queue *queue = &icsk->icsk_accept_queue;
	struct sock *newsk;
	struct request_sock *req;
	int error;

	lock_sock(sk);

	/* We need to make sure that this socket is listening,
	 * and that it has something pending.
	 */
	error = -EINVAL;
	if (sk->sk_state != TCP_LISTEN)
		goto out_err;

	/* Find already established connection */
	if (reqsk_queue_empty(queue)) {
		long timeo = sock_rcvtimeo(sk, flags & O_NONBLOCK);

		/* If this is a non blocking socket don't sleep */
		error = -EAGAIN;
		if (!timeo)
			goto out_err;

		error = inet_csk_wait_for_connect(sk, timeo);
		if (error)
			goto out_err;
	}
	req = reqsk_queue_remove(queue);
	newsk = req->sk;

	sk_acceptq_removed(sk);
	if (sk->sk_protocol == IPPROTO_TCP && queue->fastopenq != NULL) {
		spin_lock_bh(&queue->fastopenq->lock);
		if (tcp_rsk(req)->listener) {
			/* We are still waiting for the final ACK from 3WHS
			 * so can't free req now. Instead, we set req->sk to
			 * NULL to signify that the child socket is taken
			 * so reqsk_fastopen_remove() will free the req
			 * when 3WHS finishes (or is aborted).
			 */
			req->sk = NULL;
			req = NULL;
		}
		spin_unlock_bh(&queue->fastopenq->lock);
	}
out:
	release_sock(sk);
	if (req)
		__reqsk_free(req);
	return newsk;
out_err:
	newsk = NULL;
	req = NULL;
	*err = error;
	goto out;
}
EXPORT_SYMBOL(inet_csk_accept);
```

- 首先保证在调用下面的核心逻辑之前，会判断当前sock结构体的状态必须是`LISTEN `  ，否则执行失败

- 通过`reqsk_queue_empty`判断`icsk_accept_queue`是否为空队列(通过判断链表头是否为空)。如果为空，此时会判断是否设置了`O_NONBLOCK `,没有设置则通过`inet_csk_wait_for_connect`进行阻塞直到超时；没有设置则直接返回

- 如果不为空,则通过`reqsk_queue_remove`，取出头部 `rskq_accept_head `字段，并用原链表头部的下一项设置为头部。`sk_acceptq_removed`减小`sk_ack_backlog`的值。

- 判断此时是TCP协议，并且`fastopenq`不为空，并获取监听器如果存在。说明此时还在等待TFO的最后ACK 来获取在握手期间所有的数据。此时就需要通过设置`request_sock `为空代表当前套子节被占用不允许被释放。


整个代码的核心还是`inet_csk_wait_for_connect `这个方法。


#### inet_csk_wait_for_connect

```c
static int inet_csk_wait_for_connect(struct sock *sk, long timeo)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
	DEFINE_WAIT(wait);
	int err;

	for (;;) {
		prepare_to_wait_exclusive(sk_sleep(sk), &wait,
					  TASK_INTERRUPTIBLE);
		release_sock(sk);
		if (reqsk_queue_empty(&icsk->icsk_accept_queue))
			timeo = schedule_timeout(timeo);
		lock_sock(sk);
		err = 0;
		if (!reqsk_queue_empty(&icsk->icsk_accept_queue))
			break;
		err = -EINVAL;
		if (sk->sk_state != TCP_LISTEN)
			break;
		err = sock_intr_errno(timeo);
		if (signal_pending(current))
			break;
		err = -EAGAIN;
		if (!timeo)
			break;
	}
	finish_wait(sk_sleep(sk), &wait);
	return err;
}
```

能看到这个过程实际上就是通过一个死循环阻塞整个accpet的执行流程。注意在这个过程中，将不会对已经建立连接的继续使用poll等方式阻塞。而是先通过`prepare_to_wait_exclusive`把当前进程设置为 `TASK_INTERRUPTIBLE` 状态并把当前进程加入到等待队列中。

如果此时为`icsk_accept_queue`队列为空，则会通过`schedule_timeout`不断的让渡CPU给其他进程直到超时。

当唤醒CPU后，就会再度检测`icsk_accept_queue`是否为空，不为空则返回，并且检测当前的sock的状态如果已经不是Listen监听状态也会直接返回。通过`signal_pending`检测是否有需要处理的信号·。

到这里就是完成了accpet的逻辑了。但是三次握手的逻辑呢？这部分的逻辑实际是由connect系统调用实现的。

## 小结

从这里能看到整个socket的接口api设计规范，实际上还是很整齐的，在整个socket结构体中可以分为两大类操作结构体：

-  proto_ops 结构体。以`inet_stream_ops`和`inet6_stream_ops`为代表，这种方法结构体在Socket初始化时机就可以通过协议族（family）得到对应的操作结构。而这些操作都会和Socket的操作一一对应。当Socket执行时候，并必定先调用到这个方法结构体中对应的方法指针。

- sk_prot 结构体。这个就是对应具体的传输层协议类型。如IPV4下的TCP，IPV4下的UDP等协议。就会对应上不同的协议结构体，比如TCP就是对应`tcp_prot `结构体。而这个结构体的执行都是等到`proto_ops`对应的操作完成后，就可能会执行。

熟悉这套流程后，以后阅读源码就能直接找到对应的方法。

对于服务端来说，除了创建一个socket，执行如下步骤：

- bind
- listen
- accept

### bind

服务端每次一次启动socket服务，都需要绑定一个端口。当然这个端口可以在java层设置为0，前提是你要在socket初始化的时候设置好端口port号。这样才能在socket关联的fd句柄中找到端口号并在bind方法中保存下来。

而这个过程中涉及了2个比较核心的数据结构：

- inet_sock
- sockaddr_in


```c
struct inet_sock {
	/* sk and pinet6 has to be the first two members of inet_sock */
	struct sock		sk;
#if IS_ENABLED(CONFIG_IPV6)
	struct ipv6_pinfo	*pinet6; //ipv6 的信息
#endif
	/* Socket demultiplex comparisons on incoming packets. */
#define inet_daddr		sk.__sk_common.skc_daddr //外部ip地址
#define inet_rcv_saddr		sk.__sk_common.skc_rcv_saddr //绑定的本地ip地址
#define inet_dport		sk.__sk_common.skc_dport //目标地址端口
#define inet_num		sk.__sk_common.skc_num // 本地绑定的端口

	__be32			inet_saddr; // 发送的源地址
	__s16			uc_ttl; //单播允许存活时间
	__u16			cmsg_flags;
	__be16			inet_sport; // 来源端口
	__u16			inet_id; // DF packages id

	struct ip_options_rcu __rcu	*inet_opt;
	int			rx_dst_ifindex;
	__u8			tos; //TOS 4 bit的TOS分别代表：最小时延、最大吞吐量、最高可靠性和最小费用
	__u8			min_ttl;
	__u8			mc_ttl; //多播允许存活时间
	__u8			pmtudisc;
	__u8			recverr:1,
				is_icsk:1, //是否是inet_connection_sock
				freebind:1,
				hdrincl:1,
				mc_loop:1,
				transparent:1,
				mc_all:1,
				nodefrag:1;
	__u8			rcv_tos;
	int			uc_index; //单播设备id
	int			mc_index;//多播设备id
	__be32			mc_addr;
	struct ip_mc_socklist __rcu	*mc_list;
	struct inet_cork_full	cork;
};
```

熟悉这个数据结构后来看看，整个bind的核心事件：

从`sockaddr`的`sin_port `获取·到端口号，`sk->sk_prot->get_port`把端口`snum`设置到`inet_sock`的`inet_num`中，并校验当前的端口号是否小于`1024`,因为只有超级用户才能使用小于1024的端口号，如果发现非法则绑定失败。最后绑定到`inet_dport`中。


### listen

这个过程做了三件事情：

- 初始化 `fastopen_queue` TFO消息队列
- 初始化`request_sock_queue `接受回包的消息队列
- 将socket耽状态设置为LISTEN

### accept

- 判断是否处于LISTEN状态，只有LISTEN状态才能进行accept
- `reqsk_queue_empty `判断`icsk_accept_queue `是否为空，为空则进行阻塞。不为空则返回链表头部。本质上就是一个消费者-生产者模型


到这里bind，listen，accept的准备工作完成了，就等待客户端connect进行三次握手联通服务器。

