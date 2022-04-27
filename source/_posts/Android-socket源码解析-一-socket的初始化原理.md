---
title: Android socket源码解析(一)socket的初始化原理
top: false
cover: false
date: 2022-04-23 23:50:16
img:
tag: socket
description:
author: yjy239
summary:
---

# 前言

前四篇文章讲述了Okhttp的核心原理，得知Okhttp是基于Socket开发的，而不是基于HttpUrlConnection开发的。

其中对于客户端来说，核心有如下四个步骤：

- 1.dns lookup 把资源地址转化为ip地址
- 2.socket.connect 通过socket把客户端和服务端联系起来
- 3.socket.starthandshake
- 4.socket.handshake

第五篇介绍了DNS的查询流程。本文开始聊聊Socket中的核心原理。而socket就是所有网络编程的核心，就算是DNS的查询实现也是通过socket为基础实现。

注意接下来涉及的内核源码是3.1.8。

# 正文

Socket是什么？在计算机术语中都叫套接字。这种翻译比较拗口且难以理解。我在网上看到一个比较有趣的解释，socket的在日常用法的语义为插槽。如果把语义延展开来，可以看成是两个服务器之间的用于通信的插槽，一旦通过connect链接起来就把两个服务器之间的通信通道通过socket插槽链接起来了。

#### 1.客户端使用
来看看Java中的用法（这里我们只关注客户端tcp传输的逻辑），一般使用如下：

- 1.声明一个Socket对象
```java
Socket socket = new Socket(host, port);
```
也可以直接想Okhttp中一样直接使用默认的构造函数
```java
Socket socket = new Socket();
```

- 2.如果之前没有设置过地址，那么此时就需要connect 链接对端的地址
```java
socket.connect(address, connectTimeout)
```

- 3. 获取到socket的读写流，往socket中写入数据，或者读取数据

```java
socket.getOutputStream().write(message.getBytes("UTF-8"));
InputStream inputStream = socket.getInputStream();
len = inputStream.read(bytes)
```

实际上客户端的用法十分简单。

对于服务端又是怎么使用的呢？

#### 2.服务端使用

- 1.构建一个ServerSocket 对象后，调用accept方法生成一个Socket对象
```java

    ServerSocket server = new ServerSocket(port);
   
    Socket socket = server.accept();
```

- 2.  通过获取读取流和写入流进行对客户端socket的发送的数据的读取以及应答。
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

当理解了整个使用后，我们依次来看看socket在底层中都做了什么？

## 正文

我们先从客户端Socket实例化，到服务端Socket的初始化并监听开始考察。

### 1.客户端Socket实例化

```java
    public Socket() {
        setImpl();
    }

    void setImpl() {
        if (factory != null) {
            impl = factory.createSocketImpl();
            checkOldImpl();
        } else {
            // SocketImpl!
            impl = new SocksSocketImpl();
        }
        if (impl != null)
            impl.setSocket(this);
    }
```

Socket所有的事情都会交给这个SocksSocketImpl完成。


#### 2.SocksSocketImpl 构造函数与初始化

先来看看SocksSocketImpl 的UML继承结构



![SocksSocketImpl.png](/images/SocksSocketImpl.png)


这个结构图中，`SocketOptions `定义了接口敞亮，抽象类`SocketImpl` 定义了connect等核心的抽象方法，`PlainSocketImpl `则定义了一个构造函数，这一个特殊的构造函数，这个构造函数为`PlainSocketImpl `创建了一个`FileDescriptor`文件描述符对象。

`SocksSocketImpl`无参构造函数并不会做任何事情：
```java

    SocksSocketImpl() {
        // Nothing needed
    }
```

而setSocket中，调用的是`SocketImpl `中方法：
```java
    void setSocket(Socket soc) {
        this.socket = soc;
    }
```
存储当前的socket对象


### 3.Socket connect 链接到客户端

上文中，当Okhttp客户端需要链接到某个地址，就会尝试着从域名中解析出地址和端口，然后通过这两个数据生成`InetSocketAddress`对象。

```kotlin
  open fun connectSocket(socket: Socket, address: InetSocketAddress, connectTimeout: Int) {
    socket.connect(address, connectTimeout)
  }
```

```java
   public void connect(SocketAddress endpoint, int timeout) throws IOException {


        InetSocketAddress epoint = (InetSocketAddress) endpoint;
        InetAddress addr = epoint.getAddress ();
        int port = epoint.getPort();
        checkAddress(addr, "connect");

        SecurityManager security = System.getSecurityManager();
        if (security != null) {
            if (epoint.isUnresolved())
                security.checkConnect(epoint.getHostName(), port);
            else
                security.checkConnect(addr.getHostAddress(), port);
        }
        if (!created)
            createImpl(true);
        if (!oldImpl)
            impl.connect(epoint, timeout);
        else if (timeout == 0) {
            if (epoint.isUnresolved())
                impl.connect(addr.getHostName(), port);
            else
                impl.connect(addr, port);
        } else
            throw new UnsupportedOperationException("SocketImpl.connect(addr, timeout)");


        connected = true;
        bound = true;
    }
```

- 1.首先通过SecurityManager 校验即将链接的服务器地址和端口号是否合，不合法则直接抛出异常

- 2.如果没有创建过，则调用`createImpl` 创建一个底层的Socket对象

- 3.如果不是使用以前的Socket的对象，也就是`oldImpl`为false，那么就调用`SocksSocketImpl`的`connect`进行链接。



#### 3.1.Socket createImpl 创建一个底层的Socket对象

```java
     void createImpl(boolean stream) throws SocketException {
        if (impl == null)
            setImpl();
        try {
            impl.create(stream);
            created = true;
        } catch (IOException e) {
            throw new SocketException(e.getMessage());
        }
    }
```

核心还是`SocksSocketImpl`的`create` 方法。


##### 3.2.AbstractPlainSocketImpl create
 
文件：/[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[ojluni](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/)/[java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/)/[net](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/)/[AbstractPlainSocketImpl.java](http://androidxref.com/9.0.0_r3/xref/libcore/ojluni/src/main/java/java/net/AbstractPlainSocketImpl.java)


```java
    protected synchronized void create(boolean stream) throws IOException {
        this.stream = stream;
        if (!stream) {
            ResourceManager.beforeUdpCreate();

            try {
                socketCreate(false);
            } catch (IOException ioe) {
...
            }
        } else {
            socketCreate(true);
        }
        if (socket != null)
            socket.setCreated();
        if (serverSocket != null)
            serverSocket.setCreated();

        if (fd != null && fd.valid()) {
            guard.open("close");
        }
    }
```


核心是由`PlainSocketImpl`实现的抽象方法`socketCreate`完成的。

```java
    void socketCreate(boolean isStream) throws IOException {
        fd.setInt$(IoBridge.socket(AF_INET6, isStream ? SOCK_STREAM : SOCK_DGRAM, 0).getInt$());

        if (serverSocket != null) {
            IoUtils.setBlocking(fd, false);
            IoBridge.setSocketOption(fd, SO_REUSEADDR, true);
        }
    }
```

通过`IoBridge.socket`创建一个socket对象后，并返回这个对象对应的文件描述符具柄设置到`PlainSocketImpl`中缓存的文件描述符对象.注意这个过程写死了`AF_INET6` 作为ip地址族传入。说明必定是可以接受ipv6协议的地址数据。

```java
    public static FileDescriptor socket(int domain, int type, int protocol) throws SocketException {
        FileDescriptor fd;
        try {
            fd = Libcore.os.socket(domain, type, protocol);

            return fd;
        } catch (ErrnoException errnoException) {
            throw errnoException.rethrowAsSocketException();
        }
    }
```

注意这个方法是一个native方法，我们去下面文件中：
[libcore](http://androidxref.com/9.0.0_r3/xref/libcore/)/[luni](http://androidxref.com/9.0.0_r3/xref/libcore/luni/)/[src](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/)/[main](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/)/[native](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/)/[libcore_io_Linux.cpp](http://androidxref.com/9.0.0_r3/xref/libcore/luni/src/main/native/libcore_io_Linux.cpp)


```java
static jobject Linux_socket(JNIEnv* env, jobject, jint domain, jint type, jint protocol) {
    if (domain == AF_PACKET) {
        protocol = htons(protocol);  // Packet sockets specify the protocol in host byte order.
    }
    int fd = throwIfMinusOne(env, "socket", TEMP_FAILURE_RETRY(socket(domain, type, protocol)));
    return fd != -1 ? jniCreateFileDescriptor(env, fd) : NULL;
}
```

能看到实际上就是调用了系统调用`socket` 为套接字创建一个对应的文件描述符后，返回一个Java的FileDescriptor 对象返回。


### 4.Socket系统调用

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[socket.c](http://androidxref.com/kernel_3.18/xref/net/socket.c)


```c
SYSCALL_DEFINE3(socket, int, family, int, type, int, protocol)
{
	int retval;
	struct socket *sock;
	int flags;

...

	flags = type & ~SOCK_TYPE_MASK;
	if (flags & ~(SOCK_CLOEXEC | SOCK_NONBLOCK))
		return -EINVAL;
	type &= SOCK_TYPE_MASK;

	if (SOCK_NONBLOCK != O_NONBLOCK && (flags & SOCK_NONBLOCK))
		flags = (flags & ~SOCK_NONBLOCK) | O_NONBLOCK;

	retval = sock_create(family, type, protocol, &sock);
	if (retval < 0)
		goto out;

	retval = sock_map_fd(sock, flags & (O_CLOEXEC | O_NONBLOCK));
	if (retval < 0)
		goto out_release;

out:
	/* It may be already another descriptor 8) Not kernel problem. */
	return retval;

out_release:
	sock_release(sock);
	return retval;
}
```

分为2个步骤：

- 1.sock_create 创建一个socket 结构体
- 2.sock_map_fd 把结构体和fd具柄关联起来

为了更加清晰的理解`socket`结构体的内容我们看看这个结构体都包含了什么字段？

```c
struct socket {
	socket_state		state;

	kmemcheck_bitfield_begin(type);
	short			type;
	kmemcheck_bitfield_end(type);

	unsigned long		flags;

	struct socket_wq __rcu	*wq;

	struct file		*file;
	struct sock		*sk;
	const struct proto_ops	*ops;
};
```
- 1.socket_state 当前socket的枚举状态
- 2.type 当前socket对应的类型
- 3.flag 当前socket带上的标识为
- 4.socket中对应的等待队列
- 5.file socket对应的文件描述符
- 6.sock 结构体是指socket中更为核心的具体操作函数以及标志位
- 7.proto_ops 对应的协议操作结构体


#### 4.1.__sock_create 创建socket结构体

```c
int __sock_create(struct net *net, int family, int type, int protocol,
			 struct socket **res, int kern)
{
	int err;
	struct socket *sock;
	const struct net_proto_family *pf;
...


	err = security_socket_create(family, type, protocol, kern);
	if (err)
		return err;


	sock = sock_alloc();
...

	sock->type = type;

...

	rcu_read_lock();
	pf = rcu_dereference(net_families[family]);
	err = -EAFNOSUPPORT;
	if (!pf)
		goto out_release;

	if (!try_module_get(pf->owner))
		goto out_release;

	/* Now protected by module ref count */
	rcu_read_unlock();

	err = pf->create(net, sock, protocol, kern);
	if (err < 0)
		goto out_module_put;


	if (!try_module_get(sock->ops->owner))
		goto out_module_busy;

	module_put(pf->owner);
	err = security_socket_post_create(sock, family, type, protocol, kern);
	if (err)
		goto out_sock_release;
	*res = sock;

	return 0;

...
}
```

- 1.`security_socket_create ` 通过SELinux进行校验。SELinux本质上就是在一个文件中写好了每一个进程允许做的事情，当需要读取文件数据，socket等敏感操作时候将会进行一次check。可以通过security_register 进行注册。

- 2. 一旦校验通过后，则会调用`sock_alloc `创建一个`sock`结构体，该并在结构体记录当前type，常见的数据类型如下：

```c
enum sock_type {
SOCK_STREAM = 1,
SOCK_DGRAM = 2,
SOCK_RAW = 3,
...
}
```

`SOCK_STREAM` 是指面向数据流属于TCP协议；`SOCK_DGRAM`面向数据报文属于UDP协议；`SOCK_RAW` 是指原始ip包

- 3. rcu_dereference 进行rcu（Read-Copy-update）模式保护当前net_families (地址族)数组中对应引用的指针。`rcu`实际上就是我之前说过的一种特殊的线程设计，任意读取数据，写时候需要进行同步的方式。当读取的情况比较多的时候，就可以采用这种方式。  注意`net_families` 是指当前的传递下来的`domain `,也就是这是`ipv4`还是`ipv6`族。

- 4.调用`net_families`中对应族的的create方法。


在这里涉及到了几个比较核心结构体。


### 4.1.1.socket  结构体的创建与socket 内核模块的初始化

```c
static struct socket *sock_alloc(void)
{
	struct inode *inode;
	struct socket *sock;

	inode = new_inode_pseudo(sock_mnt->mnt_sb);
	if (!inode)
		return NULL;

	sock = SOCKET_I(inode);

	kmemcheck_annotate_bitfield(sock, type);
	inode->i_ino = get_next_ino();
	inode->i_mode = S_IFSOCK | S_IRWXUGO;
	inode->i_uid = current_fsuid();
	inode->i_gid = current_fsgid();
	inode->i_op = &sockfs_inode_ops;

	this_cpu_add(sockets_in_use, 1);
	return sock;
}
```

- 1.new_inode_pseudo 通过虚拟文件系统创建一个inode对象。注意这里是通过结构体为名为`sock_mnt`的`vfsmount` 创建一个inode


- 2. `SOCKET_I` 从inode中创建socket结构体。



#### 4.1.2.socket模块的初始化以及对应vfsmount生成原理

关于`sock_mnt` 初始化，在socket内核模块加载时候就加载好了：

```c
static int __init sock_init(void)
{
	int err;
	err = net_sysctl_init();
	if (err)
		goto out;

	skb_init();


	init_inodecache();

	err = register_filesystem(&sock_fs_type);
	if (err)
		goto out_fs;
	sock_mnt = kern_mount(&sock_fs_type);
...
}
```

这个过程实际上就是初始化好socket对应的虚拟文件系统操作,把`sock_fs_type`注册在虚拟文件系统中，并通过kern_mount 调用操作结构体的`mount`指针挂在在系统中，返回`mnt` 结构体挂载对象进行操作。

```c
static struct file_system_type sock_fs_type = {
	.name =		"sockfs",
	.mount =	sockfs_mount,
	.kill_sb =	kill_anon_super,
};
```

结合第一段代码，可以得知，实际上整个socket内核模块初始化调用的就是`sockfs_mount`。

```c
static struct dentry *sockfs_mount(struct file_system_type *fs_type,
			 int flags, const char *dev_name, void *data)
{
	return mount_pseudo(fs_type, "socket:", &sockfs_ops,
		&sockfs_dentry_operations, SOCKFS_MAGIC);
}
```

```c
static const struct super_operations sockfs_ops = {
	.alloc_inode	= sock_alloc_inode,
	.destroy_inode	= sock_destroy_inode,
	.statfs		= simple_statfs,
};

static const struct dentry_operations sockfs_dentry_operations = {
	.d_dname  = sockfs_dname,
};
```

`mount_pseudo` 会为当前socket对应的超级块设置一套操作结构体，生成对应的inode的时候会先调用`dentry_operations` 生成一个个detry(你可以看成文件路径),接着调用`sockfs_ops`的`alloc_inode` 生成inode。


###### 4.1.3.sock_alloc_inode 生成对应的inode

```c
static struct inode *sock_alloc_inode(struct super_block *sb)
{
	struct socket_alloc *ei;
	struct socket_wq *wq;

	ei = kmem_cache_alloc(sock_inode_cachep, GFP_KERNEL);
	if (!ei)
		return NULL;
	wq = kmalloc(sizeof(*wq), GFP_KERNEL);
	if (!wq) {
		kmem_cache_free(sock_inode_cachep, ei);
		return NULL;
	}
	init_waitqueue_head(&wq->wait);
	wq->fasync_list = NULL;
	RCU_INIT_POINTER(ei->socket.wq, wq);

	ei->socket.state = SS_UNCONNECTED;
	ei->socket.flags = 0;
	ei->socket.ops = NULL;
	ei->socket.sk = NULL;
	ei->socket.file = NULL;

	return &ei->vfs_inode;
}
```
这个过程实际上从快速缓存中生成一个`socket_alloc` 对象，这个对象中持有inode结构体。并初始化对应的那个等待队列。

```c
static inline struct socket *SOCKET_I(struct inode *inode)
{
	return &container_of(inode, struct socket_alloc, vfs_inode)->socket;
}
```

当需要获取对应的socket结构体时候，就会通过`inode`反过来查找`socket_alloc`中的`socket`.

```c
struct socket_alloc {
	struct socket socket;
	struct inode vfs_inode;
};
```

### 4.1.4.Linux内核网络模块初始化 net_families 地址族的注册

知道socket结构体是如何生成的。再来关注`net_families`是什么时候注册的。地址族是什么？顾名思义就是指地址类别，比如ipv4，ipv6等地址类型。

我们看看文件：
/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[af_inet.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/af_inet.c)

对应ipv4 内核模块的注册代码：

```c
static int __init inet_init(void)
{
	struct inet_protosw *q;
	struct list_head *r;
	int rc = -EINVAL;

	rc = proto_register(&tcp_prot, 1);
	if (rc)
		goto out;

	rc = proto_register(&udp_prot, 1);
	if (rc)
		goto out_unregister_tcp_proto;

	rc = proto_register(&raw_prot, 1);
	if (rc)
		goto out_unregister_udp_proto;

	rc = proto_register(&ping_prot, 1);
	if (rc)
		goto out_unregister_raw_proto;

	/*
	 *	Tell SOCKET that we are alive...
	 */

	(void)sock_register(&inet_family_ops);

#ifdef CONFIG_SYSCTL
	ip_static_sysctl_init();
#endif

	/*
	 *	Add all the base protocols.
	 */

	if (inet_add_protocol(&icmp_protocol, IPPROTO_ICMP) < 0)
		pr_crit("%s: Cannot add ICMP protocol\n", __func__);
	if (inet_add_protocol(&udp_protocol, IPPROTO_UDP) < 0)
		pr_crit("%s: Cannot add UDP protocol\n", __func__);
	if (inet_add_protocol(&tcp_protocol, IPPROTO_TCP) < 0)
		pr_crit("%s: Cannot add TCP protocol\n", __func__);


	for (r = &inetsw[0]; r < &inetsw[SOCK_MAX]; ++r)
		INIT_LIST_HEAD(r);

	for (q = inetsw_array; q < &inetsw_array[INETSW_ARRAY_LEN]; ++q)
		inet_register_protosw(q);


	arp_init();


	ip_init();

	tcp_v4_init();


	tcp_init();

	udp_init();


	udplite4_register();

	ping_init();


...


	ipfrag_init();

	dev_add_pack(&ip_packet_type);

	rc = 0;
...
}

fs_initcall(inet_init);
```


这一段其实就是Linux内核对网络模块的初始化：

- 1. proto_register 将`tcp_prot`(tcp协议),`udp_prot`(udp协议),`raw_prot`(原始ip包),`ping_prot`( ping 协议) 结构体注册到全局变量`proto_list`。

简单的看看`tcp_prot` 结构体内容：

```c
struct proto tcp_prot = {
	.name			= "TCP",
	.owner			= THIS_MODULE,
	.close			= tcp_close,
	.connect		= tcp_v4_connect,
	.disconnect		= tcp_disconnect,
	.accept			= inet_csk_accept,
	.ioctl			= tcp_ioctl,
	.init			= tcp_v4_init_sock,
	.destroy		= tcp_v4_destroy_sock,
	.shutdown		= tcp_shutdown,
	.setsockopt		= tcp_setsockopt,
	.getsockopt		= tcp_getsockopt,
	.recvmsg		= tcp_recvmsg,
	.sendmsg		= tcp_sendmsg,
	.sendpage		= tcp_sendpage,
	.backlog_rcv		= tcp_v4_do_rcv,
	.release_cb		= tcp_release_cb,
	.hash			= inet_hash,
	.unhash			= inet_unhash,
	.get_port		= inet_csk_get_port,
	.enter_memory_pressure	= tcp_enter_memory_pressure,
	.stream_memory_free	= tcp_stream_memory_free,
	.sockets_allocated	= &tcp_sockets_allocated,
	.orphan_count		= &tcp_orphan_count,
	.memory_allocated	= &tcp_memory_allocated,
	.memory_pressure	= &tcp_memory_pressure,
	.sysctl_mem		= sysctl_tcp_mem,
	.sysctl_wmem		= sysctl_tcp_wmem,
	.sysctl_rmem		= sysctl_tcp_rmem,
	.max_header		= MAX_TCP_HEADER,
	.obj_size		= sizeof(struct tcp_sock),
	.slab_flags		= SLAB_DESTROY_BY_RCU,
	.twsk_prot		= &tcp_timewait_sock_ops,
	.rsk_prot		= &tcp_request_sock_ops,
	.h.hashinfo		= &tcp_hashinfo,
	.no_autobind		= true,
...
};
```

在这个结构体定义了tcp协议的面向网络链接的操作符

- 2.`sock_register `初始化socket模块以及协议族，从严格意义来说在`proto_register`注册过程中已经完成了常用协议的注册。

- 3.`inet_add_protocol` 将`icmp_protocol`,`udp_protocol`,`tcp_protocol` 等回调协议添加到`inet_protos` 链表中。

```c
int inet_add_protocol(const struct net_protocol *prot, unsigned char protocol)
{
...
	return !cmpxchg((const struct net_protocol **)&inet_protos[protocol],
			NULL, prot) ? 0 : -1;
}
```


我们调tcp协议对应的`tcp_protocol`结构体看看里面定义了什么操作函数：

```c
static const struct net_protocol tcp_protocol = {
	.early_demux	=	tcp_v4_early_demux,
	.handler	=	tcp_v4_rcv,
	.err_handler	=	tcp_v4_err,
	.no_policy	=	1,
	.netns_ok	=	1,
	.icmp_strict_tag_validation = 1,
};
```

主要函数`handler` 所对应的`tcp_v4_rcv`方法。这个方法决定了tcp协议数据从另一端到来后的操作。

- 4. 遍历`inetsw_array` 数组，把每个元素通过`inet_register_protosw`方法注册到`inetsw`数组中。

来看看`inetsw_array` 内容：

```c
static struct inet_protosw inetsw_array[] =
{
	{
		.type =       SOCK_STREAM,
		.protocol =   IPPROTO_TCP,
		.prot =       &tcp_prot,
		.ops =        &inet_stream_ops,
		.flags =      INET_PROTOSW_PERMANENT |
			      INET_PROTOSW_ICSK,
	},

	{
		.type =       SOCK_DGRAM,
		.protocol =   IPPROTO_UDP,
		.prot =       &udp_prot,
		.ops =        &inet_dgram_ops,
		.flags =      INET_PROTOSW_PERMANENT,
       },

       {
		.type =       SOCK_DGRAM,
		.protocol =   IPPROTO_ICMP,
		.prot =       &ping_prot,
		.ops =        &inet_dgram_ops,
		.flags =      INET_PROTOSW_REUSE,
       },

       {
	       .type =       SOCK_RAW,
	       .protocol =   IPPROTO_IP,	/* wild card */
	       .prot =       &raw_prot,
	       .ops =        &inet_sockraw_ops,
	       .flags =      INET_PROTOSW_REUSE,
       }
};
```

这个数组决定了tcp层协议的操作符，协议类型，以及协议面向外部的模块处理方法。

举一个tcp的例子：

- 类型 为SOCK_STREAM 代表是面向数据流
- protocol 为 `IPPROTO_TCP` 代表当前协议是tcp协议
- prot 为`tcp_prot` 就是tcp协议的特殊操作方法
- ops 为`inet_stream_ops` 是指当前数据流对应的文件描述符中复写的操作是什么
- flags 是指当前的协议状态。`INET_PROTOSW_PERMANENT` 是指永久不变的协议，`INET_PROTOSW_REUSE` 是指该协议会复用端口。

```c
const struct proto_ops inet_stream_ops = {
	.family		   = PF_INET,
	.owner		   = THIS_MODULE,
	.release	   = inet_release,
	.bind		   = inet_bind,
	.connect	   = inet_stream_connect,
	.socketpair	   = sock_no_socketpair,
	.accept		   = inet_accept,
	.getname	   = inet_getname,
	.poll		   = tcp_poll,
	.ioctl		   = inet_ioctl,
	.listen		   = inet_listen,
	.shutdown	   = inet_shutdown,
	.setsockopt	   = sock_common_setsockopt,
	.getsockopt	   = sock_common_getsockopt,
	.sendmsg	   = inet_sendmsg,
	.recvmsg	   = inet_recvmsg,
	.mmap		   = sock_no_mmap,
	.sendpage	   = inet_sendpage,
	.splice_read	   = tcp_splice_read,
#ifdef CONFIG_COMPAT
...
#endif
};
```

从这个结构体中，我们就能大致猜到整个tcp的设计框架了。必定是先找到socket文件描述符中对应的协议文件描述符`inet_stream_ops`,接着找到`tcp_prot`结构体进行进一步的处理。


- 5. arp_init 对数据链路层的arp协议相关的邻居表进行初始化。

- 6. ip_init  对网络层的ip模块的初始化，在这里初始化ip对应的route_table 内存。

- 7. tcp_v4_init 与 tcp_init 可以看作一个整体都是初始化tcp模块。`tcp_init` 初始化了`inet_hashinfo`结构体。这个结构体实际上就是用于管理分配给socket端口。该结构体会通过一个哈希表对端口进行一次管理。


- 8. `tcp_init` 方法则是初始化请求需要的内存，以及`inet_hashinfo`中的hash表， 并计算之后每一个请求和接受的临时缓冲区计算好大小阈值。发送缓冲区为16kb，接受缓冲区大小约为85kb。


- 9.`udp_init` 初始化了UDP需要的内存阈值，`udplite4_register`  则是注册一个全新的UDLITE协议到内核中。在这个过程就能看到内核添加一个自定义协议的原始三步骤: `proto_register` ,`inet_add_protocol`,`inet_register_protosw`

```c
void __init udplite4_register(void)
{
	udp_table_init(&udplite_table, "UDP-Lite");
	if (proto_register(&udplite_prot, 1))
		goto out_register_err;

	if (inet_add_protocol(&udplite_protocol, IPPROTO_UDPLITE) < 0)
		goto out_unregister_proto;

	inet_register_protosw(&udplite4_protosw);

....
}
```

- 10. `ping_init` 对Ping协议进行初始化

- 11. `ipfrag_init ` 初始化`inet_frags`结构体。该结构体实际上负责了整个数据流临时缓冲区的分片。


我们把重心放在`sock_register`中。


##### 4.1.5.sock_register 注册创建地址族结构体

```c
int sock_register(const struct net_proto_family *ops)
{
	int err;

	if (ops->family >= NPROTO) {
		return -ENOBUFS;
	}

	spin_lock(&net_family_lock);
	if (rcu_dereference_protected(net_families[ops->family],
				      lockdep_is_held(&net_family_lock)))
		err = -EEXIST;
	else {
		rcu_assign_pointer(net_families[ops->family], ops);
		err = 0;
	}
	spin_unlock(&net_family_lock);

	return err;
}
```

能看到是做了一个rcu的锁进行保护后，把`net_proto_family`注册到`net_families` 数组中。

来看看注册的对象，`family`的字段为`PF_INET`，能通过`net_families`寻找下标为`PF_INET` 找到`inet_family_ops`.这样就注册到socket模块中。

```c
static const struct net_proto_family inet_family_ops = {
	.family = PF_INET,
	.create = inet_create,
	.owner	= THIS_MODULE,
};
```

在socket进行初始化的时候，调用了`net_families` 中对应family下的`net_proto_family`，设置的是`AF_INET6`的参数。说明是进入了对应的ipv6的内核模块进行创建，我们来看看ipv6内核模块加载的核心方法。

这里注意，如果你去看源码你会发现在Java源码中对应`AF_INET6` 是一个placeholder方法返回的默认数值是0.实际上这个过程是JVM加载的时候设置进去的。而设置的数据可以打印`AF_INET6`出来 也是对应上内核`AF_INET6`一样的数值`10`


#### 4.1.6.ipv6 ip地址族内核模块初始化

```c
static int __init inet6_init(void)
{
...
	err = sock_register(&inet6_family_ops);
...
...
}
module_init(inet6_init);
```

注册这个结构体：
```c
static const struct net_proto_family inet6_family_ops = {
	.family = PF_INET6,
	.create = inet6_create,
	.owner	= THIS_MODULE,
};

```

说明此时注册在socket模块中`net_families ` 对应下标是`PF_INET6`的创建协议族方法。

我们回到最初的`__sock_create`方法创建socket结构体的下面这段话

```c
 err = pf->create(net, sock, protocol, kern);
```

就能明白，实际上就是调用了`inet6_create`方法。


##### 4.1.7.inet6_create 创建ipv6的协议族

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv6](http://androidxref.com/kernel_3.18/xref/net/ipv6/)/[af_inet6.c](http://androidxref.com/kernel_3.18/xref/net/ipv6/af_inet6.c)


注意此时传下来的参数是socket结构体，`socket->type` 为`SOCK_STREAM `（此时我们讨论的是TCP）

```c
static int inet6_create(struct net *net, struct socket *sock, int protocol,
			int kern)
{
	struct inet_sock *inet;
	struct ipv6_pinfo *np;
	struct sock *sk;
	struct inet_protosw *answer;
	struct proto *answer_prot;
	unsigned char answer_flags;
	int try_loading_module = 0;
	int err;

...
	err = -ESOCKTNOSUPPORT;
	rcu_read_lock();
	list_for_each_entry_rcu(answer, &inetsw6[sock->type], list) {

		err = 0;
		/* Check the non-wild match. */
		if (protocol == answer->protocol) {
			if (protocol != IPPROTO_IP)
				break;
		} else {
			/* Check for the two wild cases. */
			if (IPPROTO_IP == protocol) {
				protocol = answer->protocol;
				break;
			}
			if (IPPROTO_IP == answer->protocol)
				break;
		}
		err = -EPROTONOSUPPORT;
	}

	if (err) {
...
	}

	err = -EPERM;
	if (sock->type == SOCK_RAW && !kern && !capable(CAP_NET_RAW))
		goto out_rcu_unlock;

	sock->ops = answer->ops;
	answer_prot = answer->prot;
	answer_flags = answer->flags;
	rcu_read_unlock();

	WARN_ON(answer_prot->slab == NULL);

	err = -ENOBUFS;
	sk = sk_alloc(net, PF_INET6, GFP_KERNEL, answer_prot);
	if (sk == NULL)
		goto out;

	sock_init_data(sock, sk);

	err = 0;
	if (INET_PROTOSW_REUSE & answer_flags)
		sk->sk_reuse = SK_CAN_REUSE;

	inet = inet_sk(sk);
	inet->is_icsk = (INET_PROTOSW_ICSK & answer_flags) != 0;

	if (SOCK_RAW == sock->type) {
		inet->inet_num = protocol;
		if (IPPROTO_RAW == protocol)
			inet->hdrincl = 1;
	}

	sk->sk_destruct		= inet_sock_destruct;
	sk->sk_family		= PF_INET6;
	sk->sk_protocol		= protocol;

	sk->sk_backlog_rcv	= answer->prot->backlog_rcv;

	inet_sk(sk)->pinet6 = np = inet6_sk_generic(sk);
	np->hop_limit	= -1;
	np->mcast_hops	= IPV6_DEFAULT_MCASTHOPS;
	np->mc_loop	= 1;
	np->pmtudisc	= IPV6_PMTUDISC_WANT;
	sk->sk_ipv6only	= net->ipv6.sysctl.bindv6only;

...

	if (inet->inet_num) {

		inet->inet_sport = htons(inet->inet_num);
		sk->sk_prot->hash(sk);
	}
	if (sk->sk_prot->init) {
		err = sk->sk_prot->init(sk);
		if (err) {
			sk_common_release(sk);
			goto out;
		}
	}

...
}
```

- 1.遍历保存在`inetsw6 `的协议列表中对应type的协议结构体,赋值到answer中。对应在ipv6中的tcp协议结构体是如下：
```c
static struct inet_protosw tcpv6_protosw = {
	.type		=	SOCK_STREAM,
	.protocol	=	IPPROTO_TCP,
	.prot		=	&tcpv6_prot,
	.ops		=	&inet6_stream_ops`,
	.flags		=	INET_PROTOSW_PERMANENT |
				INET_PROTOSW_ICSK,
};
```

此时`socket`结构体中的ops就被替换成了`inet6_stream_ops`,如果是v4，则是替换成`inet_stream_ops`.


- 2.通过`sk_alloc `方法创建sock结构体，并且把`tcpv6_prot`赋值给`sock`结构体.并记录当前的协议类型，`sock_init_data `则初始化sock的的关键操作。

```c
void sock_init_data(struct socket *sock, struct sock *sk)
{
	skb_queue_head_init(&sk->sk_receive_queue);
	skb_queue_head_init(&sk->sk_write_queue);
	skb_queue_head_init(&sk->sk_error_queue);

	sk->sk_send_head	=	NULL;

	init_timer(&sk->sk_timer);

	sk->sk_allocation	=	GFP_KERNEL;
	sk->sk_rcvbuf		=	sysctl_rmem_default;
	sk->sk_sndbuf		=	sysctl_wmem_default;
	sk->sk_state		=	TCP_CLOSE;
	sk_set_socket(sk, sock);

	sock_set_flag(sk, SOCK_ZAPPED);

	if (sock) {
		sk->sk_type	=	sock->type;
		sk->sk_wq	=	sock->wq;
		sock->sk	=	sk;
	} else
		sk->sk_wq	=	NULL;

	spin_lock_init(&sk->sk_dst_lock);
	rwlock_init(&sk->sk_callback_lock);
	lockdep_set_class_and_name(&sk->sk_callback_lock,
			af_callback_keys + sk->sk_family,
			af_family_clock_key_strings[sk->sk_family]);

	sk->sk_state_change	=	sock_def_wakeup;
	sk->sk_data_ready	=	sock_def_readable;
	sk->sk_write_space	=	sock_def_write_space;
	sk->sk_error_report	=	sock_def_error_report;
	sk->sk_destruct		=	sock_def_destruct;

	sk->sk_frag.page	=	NULL;
	sk->sk_frag.offset	=	0;
	sk->sk_peek_off		=	-1;

	sk->sk_peer_pid 	=	NULL;
	sk->sk_peer_cred	=	NULL;
	sk->sk_write_pending	=	0;
	sk->sk_rcvlowat		=	1;
	sk->sk_rcvtimeo		=	MAX_SCHEDULE_TIMEOUT;
	sk->sk_sndtimeo		=	MAX_SCHEDULE_TIMEOUT;

	sk->sk_stamp = ktime_set(-1L, 0);

#ifdef CONFIG_NET_RX_BUSY_POLL
	sk->sk_napi_id		=	0;
	sk->sk_ll_usec		=	sysctl_net_busy_read;
#endif

	sk->sk_max_pacing_rate = ~0U;
	sk->sk_pacing_rate = ~0U;
	/*
	 * Before updating sk_refcnt, we must commit prior changes to memory
	 * (Documentation/RCU/rculist_nulls.txt for details)
	 */
	smp_wmb();
	atomic_set(&sk->sk_refcnt, 1);
	atomic_set(&sk->sk_drops, 0);
}
EXPORT_SYMBOL(sock_init_data);
```

```c
struct proto tcpv6_prot = {
	.name			= "TCPv6",
	.owner			= THIS_MODULE,
	.close			= tcp_close,
	.connect		= tcp_v6_connect,
	.disconnect		= tcp_disconnect,
	.accept			= inet_csk_accept,
	.ioctl			= tcp_ioctl,
	.init			= tcp_v6_init_sock,
	.destroy		= tcp_v6_destroy_sock,
	.shutdown		= tcp_shutdown,
	.setsockopt		= tcp_setsockopt,
	.getsockopt		= tcp_getsockopt,
	.recvmsg		= tcp_recvmsg,
	.sendmsg		= tcp_sendmsg,
	.sendpage		= tcp_sendpage,
	.backlog_rcv		= tcp_v6_do_rcv,
	.release_cb		= tcp_release_cb,
	.hash			= tcp_v6_hash,
	.unhash			= inet_unhash,
	.get_port		= inet_csk_get_port,
	.enter_memory_pressure	= tcp_enter_memory_pressure,
	.stream_memory_free	= tcp_stream_memory_free,
	.sockets_allocated	= &tcp_sockets_allocated,
	.memory_allocated	= &tcp_memory_allocated,
	.memory_pressure	= &tcp_memory_pressure,
	.orphan_count		= &tcp_orphan_count,
	.sysctl_mem		= sysctl_tcp_mem,
	.sysctl_wmem		= sysctl_tcp_wmem,
	.sysctl_rmem		= sysctl_tcp_rmem,
	.max_header		= MAX_TCP_HEADER,
	.obj_size		= sizeof(struct tcp6_sock),
	.slab_flags		= SLAB_DESTROY_BY_RCU,
	.twsk_prot		= &tcp6_timewait_sock_ops,
	.rsk_prot		= &tcp6_request_sock_ops,
	.h.hashinfo		= &tcp_hashinfo,
	.no_autobind		= true,
...
};
```

- 3.调用了sk_prot的init方法。其实对应就是`tcpv6_prot`的init方法。



##### 4.1.8.sk_alloc 创建sock结构体

```c
struct sock *sk_alloc(struct net *net, int family, gfp_t priority,
		      struct proto *prot)
{
	struct sock *sk;

	sk = sk_prot_alloc(prot, priority | __GFP_ZERO, family);
	if (sk) {
		sk->sk_family = family;
		sk->sk_prot = sk->sk_prot_creator = prot;
	}

	return sk;
}
EXPORT_SYMBOL(sk_alloc);
```

这里值得注意的是sock结构体真正进行初始化的是通过 `sk_prot_alloc`，当初始化结束后，才对sock结构体中的数据进行赋值。注意在这里`sock`结构体把对应协议`proto`结构体保存在`sk_prot`字段中。


```c
static struct sock *sk_prot_alloc(struct proto *prot, gfp_t priority,
		int family)
{
	struct sock *sk;
	struct kmem_cache *slab;

	slab = prot->slab;
	if (slab != NULL) {
...
	} else
		sk = kmalloc(prot->obj_size, priority);
...

	return sk;
...
}
```

能看到是通过`kmalloc`从高速缓冲区中初始化一段结构体大小为`obj_size`的内存。这个大小是什么呢？

实际上并非是一致暴露在我们眼中`sock`结构体而是`tcp6_sock`
```c
.obj_size       = sizeof(struct tcp6_sock),
```

只是这个结构体拥有了`sock`结构体所有的字段，且内存结构一致而直接转化成`sock`结构体.

文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[linux](http://androidxref.com/kernel_3.18/xref/include/linux/)/[ipv6.h](http://androidxref.com/kernel_3.18/xref/include/linux/ipv6.h)

```c
struct tcp6_sock {
	struct tcp_sock	  tcp;
	/* ipv6_pinfo has to be the last member of tcp6_sock, see inet6_sk_generic */
	struct ipv6_pinfo inet6;
};
```


能看到这个`tcp6_sock`结构体包含了`tcp_sock` 真正包含sock结构体和一个`ipv6_pinfo` ipv6地址内容的结构体.

让我们继续深挖`tcp_sock`的内存结构：
文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[linux](http://androidxref.com/kernel_3.18/xref/include/linux/)/[tcp.h](http://androidxref.com/kernel_3.18/xref/include/linux/tcp.h)


```c
struct tcp_sock {
	/* inet_connection_sock has to be the first member of tcp_sock */
	struct inet_connection_sock	inet_conn;
...
};
```

但是还不够清晰，继续深挖，因为可以直接无缝强转`sock`结构体必定包含这个结构体在`inet_connection_sock`中。


文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[net](http://androidxref.com/kernel_3.18/xref/include/net/)/[inet_connection_sock.h](http://androidxref.com/kernel_3.18/xref/include/net/inet_connection_sock.h)


```c
struct inet_connection_sock {
	/* inet_sock has to be the first member! */
	struct inet_sock	  icsk_inet;
...
};
```

文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[net](http://androidxref.com/kernel_3.18/xref/include/net/)/[inet_sock.h](http://androidxref.com/kernel_3.18/xref/include/net/inet_sock.h)

```c
struct inet_sock {
	/* sk and pinet6 has to be the first two members of inet_sock */
	struct sock		sk;
...
};
```

终于看到了，`sock`结构体在这里。实际上这个思想想不想我们java的继承呢？只是内存结构上有一定要求而已。

![sock内存结构.png](/images/sock内存结构.png)


##### 4.1.9.tcpv6_prot init

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv6](http://androidxref.com/kernel_3.18/xref/net/ipv6/)/[tcp_ipv6.c](http://androidxref.com/kernel_3.18/xref/net/ipv6/tcp_ipv6.c)


```c
static int tcp_v6_init_sock(struct sock *sk)
{
	struct inet_connection_sock *icsk = inet_csk(sk);

	tcp_init_sock(sk);

	icsk->icsk_af_ops = &ipv6_specific;


	return 0;
}
```

- 1.inet_csk 其实就是相当于把`sock`强转成`inet_connection_sock`。因为`inet_connection_sock`结构体内存结构前半段和`sock`一致，因此可以无缝转化。

- 2.tcp_init_sock 初始化`inet_connection_sock`结构体

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[ipv4](http://androidxref.com/kernel_3.18/xref/net/ipv4/)/[tcp.c](http://androidxref.com/kernel_3.18/xref/net/ipv4/tcp.c)

```c
void tcp_init_sock(struct sock *sk)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
	struct tcp_sock *tp = tcp_sk(sk);

	__skb_queue_head_init(&tp->out_of_order_queue);
	tcp_init_xmit_timers(sk);
	tcp_prequeue_init(tp);
	INIT_LIST_HEAD(&tp->tsq_node);

	icsk->icsk_rto = TCP_TIMEOUT_INIT;
	tp->mdev_us = jiffies_to_usecs(TCP_TIMEOUT_INIT);

...

	icsk->icsk_sync_mss = tcp_sync_mss;

	sk->sk_sndbuf = sysctl_tcp_wmem[1];
	sk->sk_rcvbuf = sysctl_tcp_rmem[1];
...
}
```

在这里转化sock结构体为`tcp_sock`和`inet_connection_sock`.

为`tcp_sock` 设置`sk_buf`的缓存队列，设置tcp一次允许超时的时间为1000个时间钟；初始化`tcp_sock`的`out_of_order_queue`队列，初始化`sk_buff_head` scok预缓冲数据包队列

为`sock` 结构体设置定时器,设置之前计算好的接受和发送缓冲区的大小。


### 4.2.sock_map_fd 把socket结构体和文件描述符关联起来

文件：/[net](http://androidxref.com/kernel_3.18/xref/net/)/[socket.c](http://androidxref.com/kernel_3.18/xref/net/socket.c)


```c
static int sock_map_fd(struct socket *sock, int flags)
{
	struct file *newfile;
	int fd = get_unused_fd_flags(flags);
	if (unlikely(fd < 0))
		return fd;

	newfile = sock_alloc_file(sock, flags, NULL);
	if (likely(!IS_ERR(newfile))) {
		fd_install(fd, newfile);
		return fd;
	}

	put_unused_fd(fd);
	return PTR_ERR(newfile);
}
```

核心就是调用了`sock_alloc_file`方法，为socket结构体创建一个file结构体。

在看socket对应的文件描述符的生成之前，我们需要补充如下的知识点：

```c
	err = register_filesystem(&sock_fs_type);
	if (err)
		goto out_fs;
	sock_mnt = kern_mount(&sock_fs_type);
```

```c
static struct file_system_type sock_fs_type = {
	.name =		"sockfs",
	.mount =	sockfs_mount,
	.kill_sb =	kill_anon_super,
};
```

从这两个代码段，可以得知。socket模块在初始化时候会加载一个结构体为`file_system_type`。这个结构体是用于注册VFS 也就是虚拟文件系统的类型结构体。

这里的含义是，注册并挂载了`sockfs`虚拟文件系统。而在下面的`sock_alloc_file` 所创建的socket文件描述符就是创建在这个虚拟文件系统中。


```c
struct file *sock_alloc_file(struct socket *sock, int flags, const char *dname)
{
	struct qstr name = { .name = "" };
	struct path path;
	struct file *file;

	if (dname) {
		name.name = dname;
		name.len = strlen(name.name);
	} else if (sock->sk) {
		name.name = sock->sk->sk_prot_creator->name;
		name.len = strlen(name.name);
	}
	path.dentry = d_alloc_pseudo(sock_mnt->mnt_sb, &name);
...
	path.mnt = mntget(sock_mnt);

	d_instantiate(path.dentry, SOCK_INODE(sock));
	SOCK_INODE(sock)->i_fop = &socket_file_ops;

	file = alloc_file(&path, FMODE_READ | FMODE_WRITE,
		  &socket_file_ops);
	if (unlikely(IS_ERR(file))) {
		/* drop dentry, keep inode */
		ihold(path.dentry->d_inode);
		path_put(&path);
		return file;
	}

	sock->file = file;
	file->f_flags = O_RDWR | (flags & O_NONBLOCK);
	file->private_data = sock;
	return file;
}
```

注意这里面`sk->sk_prot_creator`是指`inet6_create `中调用的`sk_alloc`，在此时就是指`tcpv6_prot `.

注意在socket内存文件申请时候，使用socket文件系统中，对应mount挂载对象生成对应的内存文件路径。

核心源码如下；

```c
static char *sockfs_dname(struct dentry *dentry, char *buffer, int buflen)
{
	return dynamic_dname(dentry, buffer, buflen, "socket:[%lu]",
				dentry->d_inode->i_ino);
}
```

文件名为`socket:[inode号]`。 

当生成了socket对应的file内存文件后，就会保存到`socket` 结构体中。


在Linux内核初始化时候，会初始化Socket内核模块对应的自定义文件系统(`file_system_type` )  `sock_fs_type` 结构体。
```c
static struct file_system_type sock_fs_type = {
	.name =		"sockfs",
	.mount =	sockfs_mount,
	.kill_sb =	kill_anon_super,
};
```

该结构体定义了挂载函数，文件系统名，删除数据时候对超级块的清理操作


```c
static const struct super_operations sockfs_ops = {
	.alloc_inode	= sock_alloc_inode,
	.destroy_inode	= sock_destroy_inode,
	.statfs		= simple_statfs,
};
```

而这种文件系统实际上设置的就是对超级块的操作。当挂载成功后，又注册了如下的信息：
```c
static const struct super_operations sockfs_ops = {
	.alloc_inode	= sock_alloc_inode,
	.destroy_inode	= sock_destroy_inode,
	.statfs		= simple_statfs,
};

/*
 * sockfs_dname() is called from d_path().
 */
static char *sockfs_dname(struct dentry *dentry, char *buffer, int buflen)
{
	return dynamic_dname(dentry, buffer, buflen, "socket:[%lu]",
				dentry->d_inode->i_ino);
}

static const struct dentry_operations sockfs_dentry_operations = {
	.d_dname  = sockfs_dname,
};

static struct dentry *sockfs_mount(struct file_system_type *fs_type,
			 int flags, const char *dev_name, void *data)
{
	return mount_pseudo(fs_type, "socket:", &sockfs_ops,
		&sockfs_dentry_operations, SOCKFS_MAGIC);
}
```

此时就定义了文件目录对象操作`dentry_operations` 这里面决定了目录名为对应`socket:[inode]`号，并且设置了`sockfs_ops` 申请`inode`的操作对象。


### 小结

到这里就聊完了客户端对应的socket是如何通过socket系统调用初始化的。能看到在创建socket的时候，内核创建的结构体嵌套层级十分多，在这里先中断源码解析流程，进行一次总结。


在Linux内核中，无法直接访问socket所对应的文件描述符，因为对应socket的`file_operation` 是禁止的。只能通过socket系统调用访问socket对应的socket描述符。

在内核启动初期，会启动socket内核模块，并挂载socket内核模块对应的文件系统。并初始化默认的协议集。

当Java调用了Socket.connect 方法后。一个socket对象才会开始通过`SocksSocketImpl `创建 socket对象。

而这个方法本质上调用还是`socket`系统调用。将会创建一个复杂且庞大的结构体。

不过我们需要记住一点，无论怎么变都不可能脱离七层网络协议。socket系统调用是对`传输层`，`网络层`，`数据链路层`,`物理层`的封装。那么相对的，生成出来的socket结构体也是根据这一层层的设计，进行封装的。

暴露在最外层的是`socket`结构体,将会根据设置的socket类型，从而找到对应的地址族以及协议类型。

在这个过程中`socket`结构体存在如下几个核心结构体：
- 1.`sock` socket 持有通用的核心操作以及核心字段
- 2.`inet6_stream_ops ` 则是不同协议下不同的操作行为



因此整个关系如下图：

![socket结构体.png](/images/socket结构体.png)


在整个`socket`通信过程，暴露向外的如上层应用层，或者说是面向开发者来说是`socket`结构体。对于内核来说就是`sock`结构体。值得注意的是，这两者之间是互相持有的.`sock` 通过`sk_socket ` 找到`socket`；`socket`通过`sk`找到`sock`.





