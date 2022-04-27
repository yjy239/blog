---
title: Android socket源码解析(三)socket的connect源码解析
top: false
cover: false
date: 2022-04-24 23:19:45
img:
tag: socket
description:
author: yjy239
summary:
---


# 前言
上一篇文章着重的聊了socket服务端的bind，listen，accpet的逻辑。本文来着重聊聊connect都做了什么？

如果遇到什么问题，可以来本文 https://www.jianshu.com/p/da6089fdcfe1 下讨论

# 正文

## 1.Connect 系统调用

当服务端一切都准备好了。客户端就会尝试的通过`connect`系统调用，尝试的和服务端建立远程连接。

```
    protected void connect(SocketAddress address, int timeout)
            throws IOException {
        boolean connected = false;
        try {
            if (address == null || !(address instanceof InetSocketAddress))
                throw new IllegalArgumentException("unsupported address type");
            InetSocketAddress addr = (InetSocketAddress) address;
            if (addr.isUnresolved())
                throw new UnknownHostException(addr.getHostName());
            this.port = addr.getPort();
            this.address = addr.getAddress();

            connectToAddress(this.address, port, timeout);
            connected = true;
        } finally {
            if (!connected) {
                try {
                    close();
                } catch (IOException ioe) {
                    /* Do nothing. If connect threw an exception then
                       it will be passed up the call stack */
                }
            }
        }
    }

    private void connectToAddress(InetAddress address, int port, int timeout) throws IOException {
        if (address.isAnyLocalAddress()) {
            doConnect(InetAddress.getLocalHost(), port, timeout);
        } else {
            doConnect(address, port, timeout);
        }
    }

```

首先校验当前socket中是否有正确的目标地址。然后获取IP地址和端口调用`connectToAddress`。

```java
synchronized void doConnect(InetAddress address, int port, int timeout) throws IOException {
        synchronized (fdLock) {
            if (!closePending && (socket == null || !socket.isBound())) {
                NetHooks.beforeTcpConnect(fd, address, port);
            }
        }
        try {
            acquireFD();
            try {
                BlockGuard.getThreadPolicy().onNetwork();
                socketConnect(address, port, timeout);
                /* socket may have been closed during poll/select */
                synchronized (fdLock) {
                    if (closePending) {
                        throw new SocketException ("Socket closed");
                    }
                }

                if (socket != null) {
                    socket.setBound();
                    socket.setConnected();
                }
            } finally {
                releaseFD();
            }
        } catch (IOException e) {
            close();
            throw e;
        }
    }

```
在这个方法中，能看到有一个`NetHooks`跟踪socket的调用，也能看到`BlockGuard`跟踪了socket的connect调用。因此可以hook这两个地方跟踪socket，不过很少用就是了。

核心方法是`socketConnect`方法，这个方法就是调用`IoBridge.connect`方法。同理也会调用到jni中。

```cpp
static void Linux_connect(JNIEnv* env, jobject, jobject javaFd, jobject javaAddress, jint port) {
    (void) NET_IPV4_FALLBACK(env, int, connect, javaFd, javaAddress, port, NULL_ADDR_FORBIDDEN);
}
```

能看到也是调用了`connect`系统调用。

### 2.Linux内核的connect系统调用

```c
SYSCALL_DEFINE3(connect, int, fd, struct sockaddr __user *, uservaddr,
		int, addrlen)
{
	struct socket *sock;
	struct sockaddr_storage address;
	int err, fput_needed;

	sock = sockfd_lookup_light(fd, &err, &fput_needed);
	if (!sock)
		goto out;
	err = move_addr_to_kernel(uservaddr, addrlen, &address);
	if (err < 0)
		goto out_put;

	err =
	    security_socket_connect(sock, (struct sockaddr *)&address, addrlen);
	if (err)
		goto out_put;

	err = sock->ops->connect(sock, (struct sockaddr *)&address, addrlen,
				 sock->file->f_flags);
out_put:
	fput_light(sock->file, fput_needed);
out:
	return err;
}
```

- 1.sockfd_lookup_light 从fd中私有数据查找到`socket`结构体
- 2.move_addr_to_kernel 拷贝地址
- 3.security_socket_connect 通过SELinux校验当前文件描述符的对该操作是否有合法性
- 4.调用`inet_stream_ops `中对应的`connect`的方法指针。而这里的方法就是指向`inet_stream_connect `。


#### 2.1.inet_stream_ops inet_stream_connect

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[af_inet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/af_inet.c)

```c
int __inet_stream_connect(struct socket *sock, struct sockaddr *uaddr,
			  int addr_len, int flags)
{
	struct sock *sk = sock->sk;
	int err;
	long timeo;

	if (addr_len < sizeof(uaddr->sa_family))
		return -EINVAL;

	if (uaddr->sa_family == AF_UNSPEC) {
		err = sk->sk_prot->disconnect(sk, flags);
		sock->state = err ? SS_DISCONNECTING : SS_UNCONNECTED;
		goto out;
	}

	switch (sock->state) {
	default:
		err = -EINVAL;
		goto out;
	case SS_CONNECTED:
		err = -EISCONN;
		goto out;
	case SS_CONNECTING:
		err = -EALREADY;
		/* Fall out of switch with err, set for this state */
		break;
	case SS_UNCONNECTED:
		err = -EISCONN;
		if (sk->sk_state != TCP_CLOSE)
			goto out;

		err = sk->sk_prot->connect(sk, uaddr, addr_len);
		if (err < 0)
			goto out;

		sock->state = SS_CONNECTING;

		err = -EINPROGRESS;
		break;
	}

	timeo = sock_sndtimeo(sk, flags & O_NONBLOCK);

	if ((1 << sk->sk_state) & (TCPF_SYN_SENT | TCPF_SYN_RECV)) {
		int writebias = (sk->sk_protocol == IPPROTO_TCP) &&
				tcp_sk(sk)->fastopen_req &&
				tcp_sk(sk)->fastopen_req->data ? 1 : 0;

		/* Error code is set above */
		if (!timeo || !inet_wait_for_connect(sk, timeo, writebias))
			goto out;

		err = sock_intr_errno(timeo);
		if (signal_pending(current))
			goto out;
	}

	if (sk->sk_state == TCP_CLOSE)
		goto sock_error;


	sock->state = SS_CONNECTED;
	err = 0;
out:
	return err;

sock_error:
	err = sock_error(sk) ? : -ECONNABORTED;
	sock->state = SS_UNCONNECTED;
	if (sk->sk_prot->disconnect(sk, flags))
		sock->state = SS_DISCONNECTING;
	goto out;
}
EXPORT_SYMBOL(__inet_stream_connect);

int inet_stream_connect(struct socket *sock, struct sockaddr *uaddr,
			int addr_len, int flags)
{
	int err;

	lock_sock(sock->sk);
	err = __inet_stream_connect(sock, uaddr, addr_len, flags);
	release_sock(sock->sk);
	return err;
}
EXPORT_SYMBOL(inet_stream_connect);
```
在这个方法中做的事情如下：

- 1.首先校验地址类型是`AF_UNSPEC`,说明此时没有指定则返回
- 2.校验socket的状态，只有`SS_UNCONNECTED`状态下，才会执行核心方法`sk->sk_prot->connect`进行tcp的三次握手。并把socket的状态设置为`SS_CONNECTING`
- 3.然后校验`sock`结构体的状态，如果是`TCPF_SYN_SENT`或者`TCPF_SYN_RECV`，且`sock`结构体中判断协议类型为`IPPROTO_TCP`，并且`fastopen_req`的数据存在。那么就会通过`inet_wait_for_connect`等待sock结构体中TFO的数据传输完毕，并检查`signal_pending`是否有需要执行的信号
- 4.最后设置`socket`结构体状态为`SS_CONNECTED`.

注意`sk_prot`所指向的方法是，`tcp_prot `中`connect`所指向的方法，也就是指`tcp_v4_connect `.


#### 2.2.tcp_prot tcp_v4_connect

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp_ipv4.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp_ipv4.c)


```c
int tcp_v4_connect(struct sock *sk, struct sockaddr *uaddr, int addr_len)
{
	struct sockaddr_in *usin = (struct sockaddr_in *)uaddr;
	struct inet_sock *inet = inet_sk(sk);
	struct tcp_sock *tp = tcp_sk(sk);
	__be16 orig_sport, orig_dport;
	__be32 daddr, nexthop;
	struct flowi4 *fl4;
	struct rtable *rt;
	int err;
	struct ip_options_rcu *inet_opt;

	if (addr_len < sizeof(struct sockaddr_in))
		return -EINVAL;

	if (usin->sin_family != AF_INET)
		return -EAFNOSUPPORT;

	nexthop = daddr = usin->sin_addr.s_addr;
	inet_opt = rcu_dereference_protected(inet->inet_opt,
					     sock_owned_by_user(sk));
	if (inet_opt && inet_opt->opt.srr) {
		if (!daddr)
			return -EINVAL;
		nexthop = inet_opt->opt.faddr;
	}

	orig_sport = inet->inet_sport;
	orig_dport = usin->sin_port;
	fl4 = &inet->cork.fl.u.ip4;
	rt = ip_route_connect(fl4, nexthop, inet->inet_saddr,
			      RT_CONN_FLAGS(sk), sk->sk_bound_dev_if,
			      IPPROTO_TCP,
			      orig_sport, orig_dport, sk);
....
	if (!inet_opt || !inet_opt->opt.srr)
		daddr = fl4->daddr;

	if (!inet->inet_saddr)
		inet->inet_saddr = fl4->saddr;
	inet->inet_rcv_saddr = inet->inet_saddr;

	if (tp->rx_opt.ts_recent_stamp && inet->inet_daddr != daddr) {
		/* Reset inherited state */
		tp->rx_opt.ts_recent	   = 0;
		tp->rx_opt.ts_recent_stamp = 0;
		if (likely(!tp->repair))
			tp->write_seq	   = 0;
	}

	if (tcp_death_row.sysctl_tw_recycle &&
	    !tp->rx_opt.ts_recent_stamp && fl4->daddr == daddr)
		tcp_fetch_timewait_stamp(sk, &rt->dst);

	inet->inet_dport = usin->sin_port;
	inet->inet_daddr = daddr;

	inet_csk(sk)->icsk_ext_hdr_len = 0;
	if (inet_opt)
		inet_csk(sk)->icsk_ext_hdr_len = inet_opt->opt.optlen;

	tp->rx_opt.mss_clamp = TCP_MSS_DEFAULT;

	/* Socket identity is still unknown (sport may be zero).
	 * However we set state to SYN-SENT and not releasing socket
	 * lock select source port, enter ourselves into the hash tables and
	 * complete initialization after this.
	 */
	tcp_set_state(sk, TCP_SYN_SENT);
	err = inet_hash_connect(&tcp_death_row, sk);
	if (err)
		goto failure;

	inet_set_txhash(sk);

	rt = ip_route_newports(fl4, rt, orig_sport, orig_dport,
			       inet->inet_sport, inet->inet_dport, sk);
	if (IS_ERR(rt)) {
		err = PTR_ERR(rt);
		rt = NULL;
		goto failure;
	}
	/* OK, now commit destination to socket.  */
	sk->sk_gso_type = SKB_GSO_TCPV4;
	sk_setup_caps(sk, &rt->dst);

	if (!tp->write_seq && likely(!tp->repair))
		tp->write_seq = secure_tcp_sequence_number(inet->inet_saddr,
							   inet->inet_daddr,
							   inet->inet_sport,
							   usin->sin_port);

	inet->inet_id = tp->write_seq ^ jiffies;

	err = tcp_connect(sk);

	rt = NULL;
	if (err)
		goto failure;

	return 0;

failure:
...
	return err;
}
EXPORT_SYMBOL(tcp_v4_connect);
```

本质上核心任务有三件:

- ip_route_connect 查找/创建一个通过DDNS缓存好的目的地址对应的 rtable 缓存路由表
- ip_route_newports 会检查分配过的端口号是否在第一步出现了变更，并更新端口号
- `sk_setup_caps` 将获取的`rtable` 中的`dst_entry`保存到`sock`结构体的`sk_dst_cache`
- 通过`tcp_set_state(sk, TCP_SYN_SENT)` 将当前的sock结构体状态设置为`TCP_SYN_SENT`
- tcp_connect 进行tcp的三次握手操作


### 3.路由表的简单介绍

想要能够理解下文内容，先要明白什么是路由表。

> 在计算机网络中，路由表/路由择域选择库(RIB) 是一个存储在路由器或者计算机的电子表格或者数据库。路由表存储着指向特定网络地址的路径（在一些情况下，还记录有路径的路由度量值）。 路由表中含有网络周边的拓扑信息。路由表建立的主要目标是为了实现路由协议和静态路由选择。

路由表分为两大类：

- 静态路由表 由系统管理员事先设置好的路由表，一般在安装好的时候根据网络配置就确定
- 动态路由表 根据运行的网络系统而不断的发生变化的路由表。路由器会根据路由选择协议提供的功能自动学习和记忆网络的运行情况，必要的时候会计算出最大路径

每个路由器都有一个路由表(RIB)和转发表 (fib表)，路由表用于决策路由，转发表决策转发分组。下文会接触到这两种表。

这两个表有什么区别呢？

网上虽然给了如下的定义：

- RIB保存了每种协议的网络拓扑以及路由表。这里面将会包含许多相同前缀的路有地址
- FIB是从保存在内存中的多种协议中的路由表中找到最佳路径的路由。

但实际上在Linux 3.8.1中并没有明确的区分。整个路由相关的逻辑都是使用了fib转发表承担的。

先来看看几个和FIB转发表相关的核心结构体：


```c
struct rtable {
	struct dst_entry	dst;

	int			rt_genid;
	unsigned int		rt_flags;
	__u16			rt_type;
	__u8			rt_is_input;
	__u8			rt_uses_gateway;

	int			rt_iif;

	/* Info on neighbour */
	__be32			rt_gateway;

	/* Miscellaneous cached information */
	u32			rt_pmtu;

	struct list_head	rt_uncached;
};
```

熟悉Linux命令朋友一定就能认出这里面大部分的字段都可以通过route命令查找到。

命令执行结果如下：
![route命令.png](/images/route命令.png)

在这route命令结果的字段实际上都对应上了结构体中的字段含义：

- `dst` 也就是dst_entry结构体，这个结构体包含了十分多的内容，比如局域网中邻居的信息，xfrm 用于IP Spec的相关信息
- `rt_genid` 一个从0开始递增的序列号,当selinux初始化的时候为每一个net结构体中所对应的协议。当初每个进程的selinux的时候，会获取当前进程命令空间（namespace）中的网络抽象链表（net结构体）,遍历每个net增加一个序列号。
- `rt_flags` 对应了命令的Flags字段。大致上有如下几种：

|flags|含义
|-|-|
|U |路由是活动的|
|H | 目标是个主机|
|G | 需要经过网关|
|R |恢复动态路由产生的表项|
|D |由路由的后台程序动态地安装|
|M |由路由的后台程序修改|
|! |拒绝路由|

- `rt_type` 当前的路由的类型。对应在Linux内核就是如下这个枚举：
```c
/* rtm_type */

enum {
	RTN_UNSPEC,
	RTN_UNICAST,		/* 网关或者直接路由	*/
	RTN_LOCAL,		/* 本地路由		*/
	RTN_BROADCAST,		/* 接受本地广播，作为广播发送*/
	RTN_ANYCAST,		/* 接受本地广播，
但以单播方式发送 */
	RTN_MULTICAST,		/*多播路由	*/
	RTN_BLACKHOLE,		/* 丢包路由*/
	RTN_UNREACHABLE,	/*目标路由不可到达  */
	RTN_PROHIBIT,		/*	管理禁止*/
	RTN_THROW,		/* 不在表内		*/
	RTN_NAT,		/* 路由转化	*/
	RTN_XRESOLVE,		/* 使用外部解析器	*/
	__RTN_MAX
};
```

- `rt_is_input ` 判断当前的路由是输入还是输出

- `rt_uses_gateway ` 判断当前路由是否使用网关

- `rt_iif ` 套接口绑定了设备接口

- `rt_gateway` 路由所对应的网关

- `rt_pmtu`pmtu 最大路径信息

- `rt_uncached` 无法抵达的路由集合

知道路由表的的内容后。再来FIB转发表的内容。实际上从下面的源码其实可以得知，路由表的获取，实际上是先从fib转发表的路由字典树获取到后在同感加工获得路由表对象。

转发表的内容就更加简单

```c
struct fib_table {
	struct hlist_node	tb_hlist;
	u32			tb_id;
	int			tb_default;
	int			tb_num_default;
	unsigned long		tb_data[0];
};
```

- `tb_hlist` fib转发表的双端链表节点
- `tb_id` 路由标识，最多可以有256个路由表
- `tb_num_default`当前fib默认的序列号
- `tb_data` 指向转发表中真正的转发数据




### 4.本地路由分配原理

还记得在之前总结的ip地址的结构吗？

![IP报文.png](/images/IP报文.png)

需要进行一次tcp的通信，意味着需要把ip报文准备好。因此需要决定源ip地址和目标IP地址。目标ip地址在之前通过netd查询到了，此时需要得到本地发送的源ip地址。

然而在实际情况下，往往是面对如下这么情况：公网一个对外的ip地址，而内网会被映射成多个不同内网的ip地址。而这个过程就是通过DDNS动态的在内存中进行更新。

因此`ip_route_connect`实际上就是选择一个缓存好的，通过DDNS设置好的内网ip地址并找到作为结果返回，将会在之后发送包的时候填入这些存在结果信息。而查询内网ip地址的过程，可以成为RTNetLink。

在Linux中有一个常用的命令`ifconfig`也可以实现类似增加一个内网ip地址的功能：
 
```
ifconfig eth0 add 33ffe:3240:800:1005::2/64
```
比如说为网卡eth0增加一个IPV6的地址。而这个过程实际上就是调用了devinet内核模块设定好的添加新ip地址方式，并在回调中把该ip地址刷新到内存中。

注意`devinet`和`RTNetLink`严格来说不是一个存在同一个模块。虽然都是使用`rtnl_register`注册方法到rtnl模块中：


文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[devinet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/devinet.c)


```c
static __net_initdata struct pernet_operations devinet_ops = {
	.init = devinet_init_net,
	.exit = devinet_exit_net,
};

static struct rtnl_af_ops inet_af_ops = {
	.family		  = AF_INET,
	.fill_link_af	  = inet_fill_link_af,
	.get_link_af_size = inet_get_link_af_size,
	.validate_link_af = inet_validate_link_af,
	.set_link_af	  = inet_set_link_af,
};

void __init devinet_init(void)
{
	int i;

	for (i = 0; i < IN4_ADDR_HSIZE; i++)
		INIT_HLIST_HEAD(&inet_addr_lst[i]);

	register_pernet_subsys(&devinet_ops);

	register_gifconf(PF_INET, inet_gifconf);
	register_netdevice_notifier(&ip_netdev_notifier);

	queue_delayed_work(system_power_efficient_wq, &check_lifetime_work, 0);

	rtnl_af_register(&inet_af_ops);

	rtnl_register(PF_INET, RTM_NEWADDR, inet_rtm_newaddr, NULL, NULL);
	rtnl_register(PF_INET, RTM_DELADDR, inet_rtm_deladdr, NULL, NULL);
	rtnl_register(PF_INET, RTM_GETADDR, NULL, inet_dump_ifaddr, NULL);
	rtnl_register(PF_INET, RTM_GETNETCONF, inet_netconf_get_devconf,
		      inet_netconf_dump_devconf, NULL);
}
```

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[route.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/route.c)


```c
int __init ip_rt_init(void)
{
	int rc = 0;

	ip_idents = kmalloc(IP_IDENTS_SZ * sizeof(*ip_idents), GFP_KERNEL);
...

	ipv4_dst_ops.gc_thresh = ~0;
	ip_rt_max_size = INT_MAX;

	devinet_init();
	ip_fib_init();


	rtnl_register(PF_INET, RTM_GETROUTE, inet_rtm_getroute, NULL, NULL);
...
	register_pernet_subsys(&rt_genid_ops);
	register_pernet_subsys(&ipv4_inetpeer_ops);
	return rc;
}
```

实际上整个route模块，是跟着ipv4 内核模块一起初始化好的。能看到其中就根据不同的rtnl操作符号注册了对应不同的方法。

整个DDNS的工作流程大体如下：
- 1.内核空间初始化 rtnetlink 模块，创建 NETLINK_ROUTE 协议簇类型的 netlink 套接字；
- 2.用户空间创建 NETLINK_ROUTE 协议簇类型的 netlink 套接字，并且绑定到 RTMGRP_IPV4_IFADDR 组播 group 中；
- 3.用户空间接收从内核空间发来的消息，如果没有消息，则阻塞自身；
- 4.当主机被分配了新的 IPV4 地址，内核空间通过 netlink_broadcast，将 RTM_NEWADDR 消息发送到 RTNLGRP_IPV4_IFADDR 组播 group 中 ;
- 5.用户空间接收消息，进行验证、处理；

当然，在tcp三次握手执行之前，需要得到当前的源地址，那么就需要通过rtnl进行查询内存中分配的ip。

### 4.1.ip_route_connect

文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[net](http://androidxref.com/kernel_3.18/xref/include/net/)/[route.h](http://androidxref.com/kernel_3.18/xref/include/net/route.h)


```c
static inline struct rtable *ip_route_connect(struct flowi4 *fl4,
					      __be32 dst, __be32 src, u32 tos,
					      int oif, u8 protocol,
					      __be16 sport, __be16 dport,
					      struct sock *sk)
{
	struct net *net = sock_net(sk);
	struct rtable *rt;

	ip_route_connect_init(fl4, dst, src, tos, oif, protocol,
			      sport, dport, sk);

	if (!dst || !src) {
		rt = __ip_route_output_key(net, fl4);
		if (IS_ERR(rt))
			return rt;
		ip_rt_put(rt);
		flowi4_update_output(fl4, oif, tos, fl4->daddr, fl4->saddr);
	}
	security_sk_classify_flow(sk, flowi4_to_flowi(fl4));
	return ip_route_output_flow(net, fl4, sk);
}
```

这个方法核心就是`__ip_route_output_key `.当目的地址或者源地址有其一为空，则会调用`__ip_route_output_key `填充ip地址。目的地址为空说明可能是在回环链路中通信，如果源地址为空，那个说明可能往目的地址通信需要填充本地被DDNS分配好的内网地址。




#### 4.2.ip_route_connect_init

```c
static inline void ip_route_connect_init(struct flowi4 *fl4, __be32 dst, __be32 src,
					 u32 tos, int oif, u8 protocol,
					 __be16 sport, __be16 dport,
					 struct sock *sk)
{
	__u8 flow_flags = 0;

	if (inet_sk(sk)->transparent)
		flow_flags |= FLOWI_FLAG_ANYSRC;

	flowi4_init_output(fl4, oif, sk->sk_mark, tos, RT_SCOPE_UNIVERSE,
			   protocol, flow_flags, dst, src, dport, sport,
			   sock_i_uid(sk));
}
```

在这个方法中核心还是调用了`flowi4_init_output`进行flowi4结构体的初始化。

文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[net](http://androidxref.com/kernel_3.18/xref/include/net/)/[flow.h](http://androidxref.com/kernel_3.18/xref/include/net/flow.h)


```c
static inline void flowi4_init_output(struct flowi4 *fl4, int oif,
				      __u32 mark, __u8 tos, __u8 scope,
				      __u8 proto, __u8 flags,
				      __be32 daddr, __be32 saddr,
				      __be16 dport, __be16 sport,
				      kuid_t uid)
{
	fl4->flowi4_oif = oif;
	fl4->flowi4_iif = LOOPBACK_IFINDEX;
	fl4->flowi4_mark = mark;
	fl4->flowi4_tos = tos;
	fl4->flowi4_scope = scope;
	fl4->flowi4_proto = proto;
	fl4->flowi4_flags = flags;
	fl4->flowi4_secid = 0;
	fl4->flowi4_uid = uid;
	fl4->daddr = daddr;
	fl4->saddr = saddr;
	fl4->fl4_dport = dport;
	fl4->fl4_sport = sport;
}
```

能看到这个过程把数据中的源地址，目的地址，源地址端口和目的地址端口，协议类型等数据给记录下来，之后内网ip地址的查询与更新就会频繁的和这个结构体进行交互。

能看到实际上`flowi4`是一个用于承载数据的临时结构体，包含了本次路由操作需要的数据。

#### 4.3.__ip_route_output_key

```c
/*
 * Major route resolver routine.
 */

struct rtable *__ip_route_output_key(struct net *net, struct flowi4 *fl4)
{
	struct net_device *dev_out = NULL;
	__u8 tos = RT_FL_TOS(fl4);
	unsigned int flags = 0;
	struct fib_result res;
	struct rtable *rth;
	int orig_oif;

	res.tclassid	= 0;
	res.fi		= NULL;
	res.table	= NULL;

	orig_oif = fl4->flowi4_oif;

	fl4->flowi4_iif = LOOPBACK_IFINDEX;
	fl4->flowi4_tos = tos & IPTOS_RT_MASK;
	fl4->flowi4_scope = ((tos & RTO_ONLINK) ?
			 RT_SCOPE_LINK : RT_SCOPE_UNIVERSE);

	rcu_read_lock();
	if (fl4->saddr) {
		rth = ERR_PTR(-EINVAL);
		if (ipv4_is_multicast(fl4->saddr) ||
		    ipv4_is_lbcast(fl4->saddr) ||
		    ipv4_is_zeronet(fl4->saddr))
			goto out;

		/* I removed check for oif == dev_out->oif here.
		   It was wrong for two reasons:
		   1. ip_dev_find(net, saddr) can return wrong iface, if saddr
		      is assigned to multiple interfaces.
		   2. Moreover, we are allowed to send packets with saddr
		      of another iface. --ANK
		 */

		if (fl4->flowi4_oif == 0 &&
		    (ipv4_is_multicast(fl4->daddr) ||
		     ipv4_is_lbcast(fl4->daddr))) {
			/* It is equivalent to inet_addr_type(saddr) == RTN_LOCAL */
			dev_out = __ip_dev_find(net, fl4->saddr, false);
			if (dev_out == NULL)
				goto out;

			fl4->flowi4_oif = dev_out->ifindex;
			goto make_route;
		}

		if (!(fl4->flowi4_flags & FLOWI_FLAG_ANYSRC)) {
			/* It is equivalent to inet_addr_type(saddr) == RTN_LOCAL */
			if (!__ip_dev_find(net, fl4->saddr, false))
				goto out;
		}
	}


	if (fl4->flowi4_oif) {
		dev_out = dev_get_by_index_rcu(net, fl4->flowi4_oif);
		rth = ERR_PTR(-ENODEV);
		if (dev_out == NULL)
			goto out;

		/* RACE: Check return value of inet_select_addr instead. */
		if (!(dev_out->flags & IFF_UP) || !__in_dev_get_rcu(dev_out)) {
			rth = ERR_PTR(-ENETUNREACH);
			goto out;
		}
		if (ipv4_is_local_multicast(fl4->daddr) ||
		    ipv4_is_lbcast(fl4->daddr)) {
			if (!fl4->saddr)
				fl4->saddr = inet_select_addr(dev_out, 0,
							      RT_SCOPE_LINK);
			goto make_route;
		}
		if (!fl4->saddr) {
			if (ipv4_is_multicast(fl4->daddr))
				fl4->saddr = inet_select_addr(dev_out, 0,
							      fl4->flowi4_scope);
			else if (!fl4->daddr)
				fl4->saddr = inet_select_addr(dev_out, 0,
							      RT_SCOPE_HOST);
		}
	}

	if (!fl4->daddr) {
		fl4->daddr = fl4->saddr;
		if (!fl4->daddr)
			fl4->daddr = fl4->saddr = htonl(INADDR_LOOPBACK);
		dev_out = net->loopback_dev;
		fl4->flowi4_oif = LOOPBACK_IFINDEX;
		res.type = RTN_LOCAL;
		flags |= RTCF_LOCAL;
		goto make_route;
	}

	if (fib_lookup(net, fl4, &res)) {
		res.fi = NULL;
		res.table = NULL;
		if (fl4->flowi4_oif) {

			if (fl4->saddr == 0)
				fl4->saddr = inet_select_addr(dev_out, 0,
							      RT_SCOPE_LINK);
			res.type = RTN_UNICAST;
			goto make_route;
		}
		rth = ERR_PTR(-ENETUNREACH);
		goto out;
	}

	if (res.type == RTN_LOCAL) {
		if (!fl4->saddr) {
			if (res.fi->fib_prefsrc)
				fl4->saddr = res.fi->fib_prefsrc;
			else
				fl4->saddr = fl4->daddr;
		}
		dev_out = net->loopback_dev;
		fl4->flowi4_oif = dev_out->ifindex;
		flags |= RTCF_LOCAL;
		goto make_route;
	}

...

make_route:
	rth = __mkroute_output(&res, fl4, orig_oif, dev_out, flags);

out:
	rcu_read_unlock();
	return rth;
}
```

执行的事务如下：

- 1.首先校验`fl4->saddr`是否存在，存在说明我们设置了源ip地址。如果这个过程中发现没有绑定网卡设备id且这个ip地址是多播或者本地回环，那么就会尝试的调用`__ip_dev_find `找到源地址所对应的网卡驱动设备对应的ID，并绑定到`fl4->flowi4_oif`中，然后进入`make_route `标签创建路由

- 2.如果`fl4->flowi4_oif`存在，说明已经绑定了设备ID。那么就是尝试的通过`inet_select_addr `方法更新`fl4->saddr`所记录的ip地址

- 3.`fl4->daddr`目的地址为空，说明是本地传给本地，就会强制设置为`INADDR_LOOPBACK `本地回环地址，也就是本地网卡设备id，然后进入`make_route `标签创建路由对象

- 4.`fib_lookup `查找`fl4`所对应在路由表中的路由数据(包含下一跳网管，路由ip等)，承载这个结果的是`fib_result `而这个对象中最为核心是`fib_table`。如果找到数据，则通过`make_route `标签构建路由对象

- 4.如果通过`__ip_dev_find `查到的结果类型是`RTN_LOCAL `说明是本地回环网卡，就会将`dev_out->ifindex`赋值给`fl4->flowi4_oif `。并且flags增加`RTCF_LOCAL `.


### 4.4.fib表设计的数据结构以及路由路径压缩原理

想要弄清楚ip路由表的核心逻辑，必须明白路由表的几个核心的数据结构。当然网上搜索到的和本文很可能大为不同。本文是基于LInux 内核3.1.8.之后的设计几乎都沿用这一套。

而内核将路由表进行大规模的重新设计，很大一部分的原因是网络环境日益庞大且复杂。需要全新的方式进行优化管理系统中的路由表。

下面是fib_table 路由表所涉及的数据结构：

![fib路由表.png](/images/fib路由表.png)


依次从最外层的结构体介绍：

- `net` 结构体。该结构体一般保存在socket结构体中负责了网络相关的核心信息与操作
- `netns_ipv4`结构体。该结构体象征着在ipv4的协议下，所有路由表配置，路由表，路由表过滤器等相关操作
- `fib_table` 路由表
- `trie`  路由表字典树
- `leaf` trie字典树有两种节点，其中一种就是`leaf`象征着实际存储的路由数据
- `tnode`. trie 字典树中的另一种节点，该节点不包含任何内容，但是指示了真正存储数据的leaf结构体在何处
- `leaf_info` 保存在leaf的散列表中，该结构体缓存了相同/近似网段路由
- `fib_ailas`相同网段下都有各自的fib_ailas，不同fib_ailas并可以共享fib_info
- `fib_info` 每一个路由的具体信息
- `fib_nh` 路由的下一跳路由

能看到路由表的存储实际上通过字典树的数据结构压缩实现的。但是和常见的字典树有点区别，这种特殊的字典树称为LC-trie 快速路由查找算法。

这一篇文章对于快速路由查找算法的理解写的很不错: https://blog.csdn.net/dog250/article/details/6596046

#### 4.5.字典树(前缀树)

首先理解字典树：字典树简单的来说，就是把一串数据化为二进制格式，根据左0，右1的方式构成的。

如图下所示：
![trie.png](/images/trie.png)

这个过程用图来展示，就是沿着字典树路径不断向下读，比如依次读取abd节点就能得到00这个数字。依次读取abeh就能得到010这个数字。

说到底这种方式只是存储数据的一种方式。而使用数的好处就能很轻易的找到公共前缀，在字典树中找到公共最大子树，也就找到了公共前缀。

#### LC-trie

而LC-trie 则是在这之上做了压缩优化处理，想要理解这个算法，必须要明白在`tnode`中存在两个十分核心的数据：

- pos
- bits

这负责什么事情呢？下面就简单说说整个lc-trie的算法就能明白了。

- 比较每一次插入的路由项的二进制。比较本次和上一次已经插入的路由项目，找到不一样的二进制位数。找到后就生成一个`tnode`加入到当前的父`tnode`中。此时不同的位数决定了tnode中的pos的数值，bits决定的是这个tnode将会有多少的子节点/叶子节点(存储着真正的路由项目)

- 调整整个路由树的高度。调整的核心手段就是调整bits的大小。bits决定了一个节点能容纳的子节点。一旦bits小了，整个树就会增高。bits大了，整个树高度就会变矮。

当然先来看看方法`__ip_dev_find `是如何查找

```c
struct net_device *__ip_dev_find(struct net *net, __be32 addr, bool devref)
{
	u32 hash = inet_addr_hash(net, addr);
	struct net_device *result = NULL;
	struct in_ifaddr *ifa;

	rcu_read_lock();
	hlist_for_each_entry_rcu(ifa, &inet_addr_lst[hash], hash) {
		if (ifa->ifa_local == addr) {
			struct net_device *dev = ifa->ifa_dev->dev;

			if (!net_eq(dev_net(dev), net))
				continue;
			result = dev;
			break;
		}
	}
	if (!result) {
		struct flowi4 fl4 = { .daddr = addr };
		struct fib_result res = { 0 };
		struct fib_table *local;

		local = fib_get_table(net, RT_TABLE_LOCAL);
		if (local &&
		    !fib_table_lookup(local, &fl4, &res, FIB_LOOKUP_NOREF) &&
		    res.type == RTN_LOCAL)
			result = FIB_RES_DEV(res);
	}
	if (result && devref)
		dev_hold(result);
	rcu_read_unlock();
	return result;
}
EXPORT_SYMBOL(__ip_dev_find);
```

- 首先先从`inet_addr_lst`查找是否存在缓存好的路由所对应的设备驱动id。这个缓存是每一次通过类似ipconfig的命令添加动态进来的
- 如果找不到，说明没有访问过这个ip地址，接下来就会尝试的从磁盘等缓存获取ip地址相关的数据，核心方法就是`fib_table_lookup`。


文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[fib_trie.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/fib_trie.c)

```c
int fib_table_lookup(struct fib_table *tb, const struct flowi4 *flp,
		     struct fib_result *res, int fib_flags)
{
	struct trie *t = (struct trie *) tb->tb_data;
	int ret;
	struct rt_trie_node *n;
	struct tnode *pn;
	unsigned int pos, bits;
	t_key key = ntohl(flp->daddr);
	unsigned int chopped_off;
	t_key cindex = 0;
	unsigned int current_prefix_length = KEYLENGTH;
	struct tnode *cn;
	t_key pref_mismatch;

	rcu_read_lock();

	n = rcu_dereference(t->trie);
	if (!n)
		goto failed;

#ifdef CONFIG_IP_FIB_TRIE_STATS
	t->stats.gets++;
#endif

	/* Just a leaf? */
	if (IS_LEAF(n)) {
		ret = check_leaf(tb, t, (struct leaf *)n, key, flp, res, fib_flags);
		goto found;
	}

	pn = (struct tnode *) n;
	chopped_off = 0;

	while (pn) {
		pos = pn->pos;
		bits = pn->bits;

		if (!chopped_off)
			cindex = tkey_extract_bits(mask_pfx(key, current_prefix_length),
						   pos, bits);

		n = tnode_get_child_rcu(pn, cindex);

...
		}
	}
failed:
	ret = 1;
found:
	rcu_read_unlock();
	return ret;
}
EXPORT_SYMBOL_GPL(fib_table_lookup);
```

整个方法就是通过`tkey_extract_bits`生成tnode中对应的叶子节点所在index，从而通过`tnode_get_child_rcu`拿到tnode节点中index所对应的数组中获取叶下一级别的tnode或者叶子结点。

```c
static inline struct rt_trie_node *tnode_get_child_rcu(const struct tnode *tn, unsigned int i)
{
	BUG_ON(i >= 1U << tn->bits);

	return rcu_dereference_rtnl(tn->child[i]);
}
```

```c
#define KEYLENGTH (8*sizeof(t_key))

typedef unsigned int t_key;

static inline t_key tkey_extract_bits(t_key a, unsigned int offset, unsigned int bits)
{
	if (offset < KEYLENGTH)
		return ((t_key)(a << offset)) >> (KEYLENGTH - bits);
	else
		return 0;
}
```
其中查找index最为核心方法如上，这个过程，先通过key左移动pos个位，再向右边移动（32 - bits）算法找到对应index。

在这里能对路由压缩算法有一定的理解即可，本文重点不在这里。当从路由树中找到了结果就返回`fib_result `结构体。

```c
struct fib_result {
	unsigned char	prefixlen;
	unsigned char	nh_sel;
	unsigned char	type;
	unsigned char	scope;
	u32		tclassid;
	struct fib_info *fi;
	struct fib_table *table;
	struct list_head *fa_head;
};
```

查询的结果最为核心的就是`fib_table`路由表，存储了真正的路由转发信息

#### 4.6.__mkroute_output

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[route.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/route.c)

```c
/* called with rcu_read_lock() */
static struct rtable *__mkroute_output(const struct fib_result *res,
				       const struct flowi4 *fl4, int orig_oif,
				       struct net_device *dev_out,
				       unsigned int flags)
{
	struct fib_info *fi = res->fi;
	struct fib_nh_exception *fnhe;
	struct in_device *in_dev;
	u16 type = res->type;
	struct rtable *rth;
	bool do_cache;

	in_dev = __in_dev_get_rcu(dev_out);
...

	do_cache = true;
	if (type == RTN_BROADCAST) {
		flags |= RTCF_BROADCAST | RTCF_LOCAL;
		fi = NULL;
	} else if (type == RTN_MULTICAST) {
		flags |= RTCF_MULTICAST | RTCF_LOCAL;
		if (!ip_check_mc_rcu(in_dev, fl4->daddr, fl4->saddr,
				     fl4->flowi4_proto))
			flags &= ~RTCF_LOCAL;
		else
			do_cache = false;

		if (fi && res->prefixlen < 4)
			fi = NULL;
	}

	fnhe = NULL;
	do_cache &= fi != NULL;
	if (do_cache) {
		struct rtable __rcu **prth;
		struct fib_nh *nh = &FIB_RES_NH(*res);

		fnhe = find_exception(nh, fl4->daddr);
		if (fnhe)
			prth = &fnhe->fnhe_rth_output;
		else {
			if (unlikely(fl4->flowi4_flags &
				     FLOWI_FLAG_KNOWN_NH &&
				     !(nh->nh_gw &&
				       nh->nh_scope == RT_SCOPE_LINK))) {
				do_cache = false;
				goto add;
			}
			prth = raw_cpu_ptr(nh->nh_pcpu_rth_output);
		}
		rth = rcu_dereference(*prth);
		if (rt_cache_valid(rth)) {
			dst_hold(&rth->dst);
			return rth;
		}
	}

add:
	rth = rt_dst_alloc(dev_out,
			   IN_DEV_CONF_GET(in_dev, NOPOLICY),
			   IN_DEV_CONF_GET(in_dev, NOXFRM),
			   do_cache);
	if (!rth)
		return ERR_PTR(-ENOBUFS);

	rth->dst.output = ip_output;

	rth->rt_genid = rt_genid_ipv4(dev_net(dev_out));
	rth->rt_flags	= flags;
	rth->rt_type	= type;
	rth->rt_is_input = 0;
	rth->rt_iif	= orig_oif ? : 0;
	rth->rt_pmtu	= 0;
	rth->rt_gateway = 0;
	rth->rt_uses_gateway = 0;
	INIT_LIST_HEAD(&rth->rt_uncached);

	RT_CACHE_STAT_INC(out_slow_tot);

	if (flags & RTCF_LOCAL)
		rth->dst.input = ip_local_deliver;
	if (flags & (RTCF_BROADCAST | RTCF_MULTICAST)) {
		if (flags & RTCF_LOCAL &&
		    !(dev_out->flags & IFF_LOOPBACK)) {
			rth->dst.output = ip_mc_output;
			RT_CACHE_STAT_INC(out_slow_mc);
		}
#ifdef CONFIG_IP_MROUTE
		if (type == RTN_MULTICAST) {
			if (IN_DEV_MFORWARD(in_dev) &&
			    !ipv4_is_local_multicast(fl4->daddr)) {
				rth->dst.input = ip_mr_input;
				rth->dst.output = ip_mc_output;
			}
		}
#endif
	}

	rt_set_nexthop(rth, fl4->daddr, res, fnhe, fi, type, 0);

	return rth;
}
```

这个方法做的事情很简单，本质上就是想要找到这个路由的下一跳是哪里？


- 1.do_cache 首先设置为true，这样就是默认使用缓存的路由。

- 2。如果此时是多播，并通过`ip_check_mc_rcu `校验了多播相关的列表中，有目的地址相关的缓存，则do_cache 为false，不从`fib_nh`的`nh_pcpu_rth_output `查找缓存中已经缓存的rtable。

- 3.其他情况下，都默认会从`fib_nh`的`nh_pcpu_rth_output `查找缓存中已经缓存的rtable。如果这个过程，如果`rt_cache_valid`校验到该缓存的`rtable`所对应的网络设备号一致则有效，有效则返回。无效则进入到`add`标签中创建一个全新的`rtable`结构体。

- 4.rt_dst_alloc 创建一个全新的`rtable` 结构体。其中并设置好当前的协议类型，是否是输入型路由，rt_genid 生成唯一id等等。注意，这里需要额外注意设置在dst_entry的方法指针：`ip_output`.这个方法将会从数据链路arp协议传递上ip层的入口。也是`netfilter`的入口。

- 5.rt_set_nexthop 将会为`rtable` 设置和寻找下一跳的信息。一般来说，在一个局域网中，Linux服务器下一跳往往是指向网关。 设置好网关后返回`rtable`

####4.7. rt_set_nexthop

```c
static void rt_set_nexthop(struct rtable *rt, __be32 daddr,
			   const struct fib_result *res,
			   struct fib_nh_exception *fnhe,
			   struct fib_info *fi, u16 type, u32 itag)
{
	bool cached = false;

	if (fi) {
		struct fib_nh *nh = &FIB_RES_NH(*res);

		if (nh->nh_gw && nh->nh_scope == RT_SCOPE_LINK) {
			rt->rt_gateway = nh->nh_gw;
			rt->rt_uses_gateway = 1;
		}
		dst_init_metrics(&rt->dst, fi->fib_metrics, true);
#ifdef CONFIG_IP_ROUTE_CLASSID
		rt->dst.tclassid = nh->nh_tclassid;
#endif
		if (unlikely(fnhe))
			cached = rt_bind_exception(rt, fnhe, daddr);
		else if (!(rt->dst.flags & DST_NOCACHE))
			cached = rt_cache_route(nh, rt);
		if (unlikely(!cached)) {

			rt->dst.flags |= DST_NOCACHE;
			if (!rt->rt_gateway)
				rt->rt_gateway = daddr;
			rt_add_uncached_list(rt);
		}
	} else
		rt_add_uncached_list(rt);

#ifdef CONFIG_IP_ROUTE_CLASSID
#ifdef CONFIG_IP_MULTIPLE_TABLES
	set_class_tag(rt, res->tclassid);
#endif
	set_class_tag(rt, itag);
#endif
}
```

在这里面有一个核心的结构体名为`fib_nh_exception `。这个是指fib表中去往目的地址情况下最理想的下一跳的地址。

而这个结构体在上一个方法通过`find_exception`获得.遍历从`fib_result`获取到`fib_nh`结构体中的`nh_exceptions`链表。从这链表中找到一模一样的目的地址并返回得到的。

- 如果`fib_nh_exception`的不为空，那么就会执行`rt_bind_exception`方法，将fnhe和`rtable`绑定起来.注意`unlikely`说明大部分情况下都很难走到这分支。

- 如果`rtable`的`dst.flags`关闭了`DST_NOCACHE` 标志位。就会调用`rt_cache_route`。到了这里一般是没有找到下一跳地址，这个过程会通过`rt_cache_route`这个方法，将rtable 缓存到`nh->nh_rth_input`或者`nh->nh_pcpu_rth_output`.

- 如果不能缓存，且没有设置网关，则把目的地址设置到网关，并加入到不可达队列中

- 当然，无法从fib转发表中找到fib_info，也是加入到不可达队列中。

### 5. tcp_connect 开始进行三次握手
文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp_output.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp_output.c)


```c
/* Build a SYN and send it off. */
int tcp_connect(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct sk_buff *buff;
	int err;

	tcp_connect_init(sk);

	if (unlikely(tp->repair)) {
		tcp_finish_connect(sk, NULL);
		return 0;
	}

	buff = alloc_skb_fclone(MAX_TCP_HEADER + 15, sk->sk_allocation);
	if (unlikely(buff == NULL))
		return -ENOBUFS;

	skb_reserve(buff, MAX_TCP_HEADER);

	tcp_init_nondata_skb(buff, tp->write_seq++, TCPHDR_SYN);
	tp->retrans_stamp = tcp_time_stamp;
	tcp_connect_queue_skb(sk, buff);
	tcp_ecn_send_syn(sk, buff);

	err = tp->fastopen_req ? tcp_send_syn_data(sk, buff) :
	      tcp_transmit_skb(sk, buff, 1, sk->sk_allocation);
	if (err == -ECONNREFUSED)
		return err;

	tp->snd_nxt = tp->write_seq;
	tp->pushed_seq = tp->write_seq;
	TCP_INC_STATS(sock_net(sk), TCP_MIB_ACTIVEOPENS);

	/* Timer for repeating the SYN until an answer. */
	inet_csk_reset_xmit_timer(sk, ICSK_TIME_RETRANS,
				  inet_csk(sk)->icsk_rto, TCP_RTO_MAX);
	return 0;
}
EXPORT_SYMBOL(tcp_connect);
```

- tcp_connect_init 初始化sock转化成`tcp_sock `结构体，并初始化需要发送tcp 协议包所需要的数据

- `alloc_skb_fclone` 申请内存给`sk_buff`，这个对象`sk_buff`就是用于承载tcp发送的网络数据包真正的实体。

- `skb_reserve` 为`sk_buff`设置最大头部信息长度.这个长度大小如下：

```c
#if defined(CONFIG_WLAN) || IS_ENABLED(CONFIG_AX25)
# if defined(CONFIG_MAC80211_MESH)
#  define LL_MAX_HEADER 128
# else
#  define LL_MAX_HEADER 96
# endif
#else
# define LL_MAX_HEADER 32
#endif

#if !IS_ENABLED(CONFIG_NET_IPIP) && !IS_ENABLED(CONFIG_NET_IPGRE) && \
    !IS_ENABLED(CONFIG_IPV6_SIT) && !IS_ENABLED(CONFIG_IPV6_TUNNEL)
#define MAX_HEADER LL_MAX_HEADER
#else
#define MAX_HEADER (LL_MAX_HEADER + 48)
#endif

#define MAX_TCP_HEADER	(128 + MAX_HEADER)
```

如果是ipv4 且没有打开`CONFIG_WLAN`，`CONFIG_AX25`。此时给sk_buff的头部长度限制为`160`字节

- `tcp_init_nondata_skb`初始化发送`SYN`信号所需要的数据填充到`sk_buff`中。在这个过程中过去tcp_sock所记录的序列号`write_seq`加一填充再数据缓冲区。

- `tcp_connect_queue_skb` 将当前的`sk_buff`插入到sock结构体的`sk_write_queue`。

- `tcp_transmit_skb`将SYN 信号包发送出去。这里关于`tcp_transmit_skb`发送SYN数据包流程就不多说，放到之后的sock发送数据包流程聊。

- `inet_csk_reset_xmit_timer ` 设置一个定时器不断的保持活跃当前链接，直到接受到了SYN的应答信号。

这里指的注意的是`inet_csk_reset_xmit_timer`方法。

### 6.inet_csk_reset_xmit_timer

```c
static inline void inet_csk_reset_xmit_timer(struct sock *sk, const int what,
					     unsigned long when,
					     const unsigned long max_when)
{
	struct inet_connection_sock *icsk = inet_csk(sk);

	if (when > max_when) {
...
		when = max_when;
	}

	if (what == ICSK_TIME_RETRANS || what == ICSK_TIME_PROBE0 ||
	    what == ICSK_TIME_EARLY_RETRANS || what ==  ICSK_TIME_LOSS_PROBE) {
		icsk->icsk_pending = what;
		icsk->icsk_timeout = jiffies + when;
		sk_reset_timer(sk, &icsk->icsk_retransmit_timer, icsk->icsk_timeout);
	} else if (what == ICSK_TIME_DACK) {
		...
	}
#ifdef INET_CSK_DEBUG
	else {
		...
	}
#endif
}
```

将`sock`结构体转化为`inet_connection_sock`.此时设置的定时起类型为`ICSK_TIME_RETRANS`。因此会调用`sk_reset_timer`。将`inet_connection_sock`的`icsk_retransmit_timer`设置给sock的时间重试队列中。

其中超时时间已经在`tcp_connect_init `设置在`inet_connection_sock->icsk_rto `中

```c
#define TCP_TIMEOUT_INIT ((unsigned)(1*HZ))
```
也就是当前时间往后 100个中断，在Linux 2.6中就是100ms.


其中`icsk_retransmit_timer`方法指向就是`tcp_keepalive_timer`。

- 这个方法如果发现了tcp的状态已经处于了`TCP_LISTEN`,自己进程自己通信自己，或者已经是`TCP_CLOSE`不执行任何内容。

- 如果处于`TCP_FIN_WAIT2`,且sock已经`SOCK_DEAD`状态了，则销毁当前的sock结构体。

### 7.服务端接受到SYN回应接受 SYN_ACK 信息

而从下层传递到应用层的tcp协议进行处理，会调用到`tcp_v4_do_rcv`方法。

`tcp_v4_do_rcv`方法最终调用到 `tcp_rcv_state_process`

```c
int tcp_rcv_state_process(struct sock *sk, struct sk_buff *skb,
			  const struct tcphdr *th, unsigned int len)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct inet_connection_sock *icsk = inet_csk(sk);
...

	switch (sk->sk_state) {
	case TCP_CLOSE:
		goto discard;

	case TCP_LISTEN:
		if (th->ack)
			return 1;

		if (th->rst)
			goto discard;

		if (th->syn) {
			if (th->fin)
				goto discard;
			if (icsk->icsk_af_ops->conn_request(sk, skb) < 0)
				return 1;
			kfree_skb(skb);
			return 0;
		}
		goto discard;

	case TCP_SYN_SENT:
...
		return 0;
	}

...
	return 0;
}
EXPORT_SYMBOL(tcp_rcv_state_process);
```

此时的服务器应该是调用玩accpet和listen的方法，进入到了`TCP_LISTEN` 状态。

因此就会在这个方法中进入到`tcp_rcv_state_process`的`TCP_LISTEN`的分支.核心就是`icsk->icsk_af_ops->conn_request`.

而核心的方法是通过该结构体注入：

```
const struct inet_connection_sock_af_ops ipv4_specific = {
	.queue_xmit	   = ip_queue_xmit,
	.send_check	   = tcp_v4_send_check,
	.rebuild_header	   = inet_sk_rebuild_header,
	.sk_rx_dst_set	   = inet_sk_rx_dst_set,
	.conn_request	   = tcp_v4_conn_request,
	.syn_recv_sock	   = tcp_v4_syn_recv_sock,
	.net_header_len	   = sizeof(struct iphdr),
	.setsockopt	   = ip_setsockopt,
	.getsockopt	   = ip_getsockopt,
	.addr2sockaddr	   = inet_csk_addr2sockaddr,
	.sockaddr_len	   = sizeof(struct sockaddr_in),
	.bind_conflict	   = inet_csk_bind_conflict,
#ifdef CONFIG_COMPAT
	.compat_setsockopt = compat_ip_setsockopt,
	.compat_getsockopt = compat_ip_getsockopt,
#endif
	.mtu_reduced	   = tcp_v4_mtu_reduced,
};
```

也就是`tcp_v4_conn_request`方法。 当执行完该方法后，就会在`tcp_rcv_state_process`通过`tcp_check_req`方法将状态设置为`TCP_SYN_RECV`.

#### 7.1.tcp_v4_conn_request

```c
int tcp_v4_conn_request(struct sock *sk, struct sk_buff *skb)
{
	/* Never answer to SYNs send to broadcast or multicast */
	if (skb_rtable(skb)->rt_flags & (RTCF_BROADCAST | RTCF_MULTICAST))
		goto drop;

	return tcp_conn_request(&tcp_request_sock_ops,
				&tcp_request_sock_ipv4_ops, sk, skb);

drop:
	NET_INC_STATS_BH(sock_net(sk), LINUX_MIB_LISTENDROPS);
	return 0;
}
EXPORT_SYMBOL(tcp_v4_conn_request);
```

文件： /[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp_input.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp_input.c)


```c
int tcp_conn_request(struct request_sock_ops *rsk_ops,
		     const struct tcp_request_sock_ops *af_ops,
		     struct sock *sk, struct sk_buff *skb)
{
	struct tcp_options_received tmp_opt;
	struct request_sock *req;
	struct tcp_sock *tp = tcp_sk(sk);
	struct dst_entry *dst = NULL;
	__u32 isn = TCP_SKB_CB(skb)->tcp_tw_isn;
	bool want_cookie = false, fastopen;
	struct flowi fl;
	struct tcp_fastopen_cookie foc = { .len = -1 };
	int err;
  ...
        tcp_openreq_init(req, &tmp_opt, skb, sk);
...
	err = af_ops->send_synack(sk, dst, &fl, req,
				  skb_get_queue_mapping(skb), &foc);
...
	return 0;
}
EXPORT_SYMBOL(tcp_conn_request);
```

- 1.`tcp_openreq_init`先读取从客户端发送来的`sk_buff`socket数据缓冲区的内容。并`request_sock` 中的`rcv_nxt` 设置为客户端的序列号+1.也就是我们常说的读取SYN_ACK数据，并把客户端提供的 seq+1.


```c
static inline void tcp_openreq_init(struct request_sock *req,
				    struct tcp_options_received *rx_opt,
				    struct sk_buff *skb, struct sock *sk)
{
	struct inet_request_sock *ireq = inet_rsk(req);

	req->rcv_wnd = 0;		/* So that tcp_send_synack() knows! */
	req->cookie_ts = 0;
	tcp_rsk(req)->rcv_isn = TCP_SKB_CB(skb)->seq;
	tcp_rsk(req)->rcv_nxt = TCP_SKB_CB(skb)->seq + 1;
	tcp_rsk(req)->snt_synack = tcp_time_stamp;
...
}

```

这个方法将会调用`send_synack` 发送SYN-ACK 信号。而这个方法最终就是指向了`tcp_v4_send_synack`方法。

而这个方法最终还是会调用`tcp_make_synack`构建SYN_ACK数据包， 并通过ip_output方法发送出去。

```c
struct sk_buff *tcp_make_synack(struct sock *sk, struct dst_entry *dst,
				struct request_sock *req,
				struct tcp_fastopen_cookie *foc)
{
	struct tcphdr *th;
...
	th->syn = 1;
	th->ack = 1;
...
	tcp_init_nondata_skb(skb, tcp_rsk(req)->snt_isn,
			     TCPHDR_SYN | TCPHDR_ACK);

	th->seq = htonl(TCP_SKB_CB(skb)->seq);
	th->ack_seq = htonl(tcp_rsk(req)->rcv_nxt);

...
...
	return skb;
}
```

能看到实际上就是构建一个`sk_buff` socket数据缓冲区。`tcphdr`代表即将发送出去tcp封装数据包的协议头。这里会读取客户端发送的数据缓冲区，但是会修改tcp头部信息。

这里tcp的头部设置好标志位:把tcp封装的头部标志syn和ack 都设置为1. 并把seq设置为服务端的skb的序列号。同时设置`ack_seq`为再上面设置好的`rcv_nxt`，也就是客户端的序列号+1.




### 8.客户端接受到了来自服务端SYN-ACK信号后返回ACK的应答信号

还是`tcp_rcv_state_process` 方法处理来自服务端发送ACK信号。此时，客户端发送玩SYN信号，此时进入到了`TCP_SYN_SENT`状态。直接看`TCP_SYN_SENT`分支

```c
	case TCP_SYN_SENT:
		queued = tcp_rcv_synsent_state_process(sk, skb, th, len);
		if (queued >= 0)
			return queued;

		/* Do step6 onward by hand. */
		tcp_urg(sk, skb, th);
		__kfree_skb(skb);
		tcp_data_snd_check(sk);
		return 0;
	}
```

#### 8.1.tcp_rcv_synsent_state_process

```c
static int tcp_rcv_synsent_state_process(struct sock *sk, struct sk_buff *skb,
					 const struct tcphdr *th, unsigned int len)
{
...
 

		smp_mb();

		tcp_finish_connect(sk, skb);

	...

		if (sk->sk_write_pending ||
		    icsk->icsk_accept_queue.rskq_defer_accept ||
		    icsk->icsk_ack.pingpong) {
...
		} else {
			tcp_send_ack(sk);
		}
		return -1;
	}

...
}
```

- 1.`tcp_finish_connect` 将当前的客户端 设置为`TCP_ESTABLISHED`状态,告诉上层应用层已经准备就绪可以和服务端端通信

- 2.`tcp_send_ack` 发送ACK 数据包给服务器。



### 9. 服务器接受到客户端发送的ACK 数据包

服务端最后还是走到老方法`tcp_rcv_state_process `,此时服务端已经到了`TCP_RCVD`状态,进入到了该方法的`TCP_RCVD`的分支

```c
	case TCP_SYN_RECV:
...
		smp_mb();
		tcp_set_state(sk, TCP_ESTABLISHED);
		sk->sk_state_change(sk);
...
```

服务端直接设置状态为`TCP_ESTABLISHED`,告诉上层应用层已经准备就绪可以和客户端通信。

## 小结

到这里就结束了对socket的connect 系统调用解析。内容确实十分多。也涉及到了SYN，SYN-ACK，ACK数据包的发送逻辑，本文将会把数据包的发送解析放到下一篇文章进行详细的描述。老规矩，先进行总结。

#### FIB 路由

在connect 系统调用之前还是需要知道fib路由转发表的核心逻辑。

首先在Linux中路由表实际上指的就是FIB 表。而FIB转发表中最为核心的结构体就是fib_table. 而fib表记录了真实的路由数据也就是`fib_info`。而fib_table的管理的数据则是通过一个名为`LC-Trie`的前缀树进行管理。

每当需要发送数据包之前，都会从net结构体中寻找换存在fib_table的数据。通过保存在tnode的`pos`和`index`字段，通过位移的手段迅速找到对应的叶子结点从而找到缓存好的跳转表数据。


#### connect 系统调用

主要做了两件事情：

- 为三次握手查找目的地址所需要的路由，其中包含了下一跳等内容

- 进行三次握手。三次握手可以总结为如下的图：


![TCP三次握手.png](/images/TCP三次握手.png)


三次握手中发生了几次状态的变化。其实也是保证了包的顺序以及应答之间的状态。

总的来说就是三个步骤：
- 请求
- 应答
- 应答之应答 注意在这个步骤中将不等待服务端，在发送该数据包之前就设置为就绪状态。

下一篇章就来聊聊socket的发送数据包流程。