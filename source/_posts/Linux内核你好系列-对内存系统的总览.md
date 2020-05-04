---
title: Linux内核你好系列 对内存系统的总览
top: false
cover: false
date: 2019-12-15 21:55:56
img:
tag:
description:
author: yjy239
summary:
categories: Linux kernel
tags:
- Linux
---
# 前言

在阅读Android底层源码，特别是关于Linux内核的代码时候，如果对Linux内核整体上没有一定的认知，阅读起来一定很幸苦，本文就总结一下Linux内核内存管理系统的总览，之后有时间会把这些总览分为一个个详细的知识点一一解析其源码

可以在本文下讨论[https://www.jianshu.com/p/82b4454697ce](https://www.jianshu.com/p/82b4454697ce)


# 正文

为了作为Binder驱动一文的补充也好，还是为了下一篇的Ashmem的解析铺垫也好，本文继续补充一下Linux内存系统相关知识。很多人可能会分不清Linux的虚拟内存和物理内存什么时候使用，也弄不清虚拟内存为什么叫做虚拟，具体和物理内存有什么区别。也不清楚虚拟内存为什么可以有4g大小甚至超过内存卡中内存大小，这是怎么做到的？接下来，我们来讨论一下。

我们先不用管内存中的逻辑地址，线性地址，物理地址。首先在Linux中把内存分为2大类，一个是物理内存，虚拟内存。

顾名思义，物理内存是指真实的物理设备中的地址，虚拟内存是一个虚拟的概念概念，经过内核屏蔽后面向应用的内存，同一个物理地址可能通过映射在不同的进程显示出来的虚拟地址是不同的。

因此，我们想要弄清楚Linux的内存管理，需要了解三个方面：
- 1.物理内存管理
- 2.虚拟内存管理
- 3.物理内存是如何映射到虚拟内存的，而映射又分为用户态的映射以及内核态的映射。

那么Linux内核什么使用物理内存，什么时候虚拟内存呢？记住虽然内核拥有直接访问物理内存的权限，但是它不会这么做。换句话说，任何时候访问都是虚拟内存，只有进行物理内存绑定和分配的时候会使用物理内存。

### 虚拟内存的划分
首先我们要知道一个进程会使用什么内容需要放在内存中：
- 1.代码需要放在内存
- 2.全局变量
- 3.常量字符串
- 4.函数栈
- 5.堆
接下来是内核
- 6.内核代码也需要放在内存
- 7.内核也有全局变量
- 8.每一个进程都需要task_struct
- 9.每一个进程都需要内核栈
- 10.内核同样需要动态分配内存

为了保证这些数据都有充足的空间存放，在32位中就有2^32也就是4G的虚拟内存分配，为了更好的划分出哪一块是交给内核，哪一块是交给用户操作的，分为了内核态以及用户态。

同样进程为了可以正常运行，进程会为上面10点划分内存，这里就从进程的低位开始说起虚拟内存的布局：
- 1.Text Segment 存放二进制可执行代码
- 2.Data Segment 存放静态常量
- 3.BSS Segment 存放为初始化的静态常量
- 4.堆(Heap)段 堆是往高地址增长的，用来动态分配内存
- 5.Memory Mapping Segment 这一段是用来把文件映射进内存，如加载so库
- 6.栈(Stack)段 主线程的函数调用的函数栈

同样的内核中也有一样的结构.

![进程虚拟内存划分.jpg](/images/进程虚拟内存划分.jpg)


### 虚拟内存划分逻辑
了解了虚拟内存布局之后，我们想要进一步的理解的物理内存到虚拟内存的映射方式，就要重新复习一下mmap那一节和大家聊过的把虚拟空间分为多段保存，这里简单回顾一下，大致分为段式，页式，段页式管理这些虚拟内存。

#### 段式管理
段式的原理图如下：
![段式管理内存.jpg](/images/段式管理内存.jpg)

能看到这里面的原理很直观，段式管理分为2部分，段选择子和段内偏移量。段选择子中最重要的是段号，段号作为段表的索引.段表中存放着基地址，段界限，特权等级。段内偏移量应该在0到段界限之间，当我们尝试着找物理地址，就可以通过如下公式寻找：

> 物理地址 = 基地址 + 段内偏移量


DPL特权等级是指访问这一段地址的权限，如DPL为3则是用户态可以访问，0则是内核态

#### 页式管理
Linux更加偏向使用页式管理对内存进行分页，让虚拟内存转化为物理内存。这种方式有一种特殊处理方式，当一块内存长时间不用但是没有释放则会暂时写入到硬盘上，叫做换出。一旦需要，再加载进来叫做换入。这样就可以依靠硬盘大于内存卡数十倍的空间充分的利用物理设备，扩大可用物理内存，提高物理内存利用率。

一般控制Linux每一页的大小由PAGE_SIZE的宏控制的，大小默认设置为4kb。原理图如下：
![页管理原理.jpg](/images/页管理原理.jpg)

虚拟地址分为2部分，页号和页内偏移。页号作为页表的索引，页表包含着物理页每一页所在物理地址的基地址，就能依照如下的公式计算：

> 页基地址 + 页内偏移 = 物理地址

但是这样能找到的地址太少了，如果需要4G的内存，一页4kb，那就要1M的页表。这样太消耗内存了。因此Linux做了一个中间键，名为页目录，如果能通过目录再去查找就能消耗更小的内存。一个页目录的页表项有1k个，每一项只用4个字节大小，那页表只需要1k个。这样就能极大利用更多的物理空间

把整个流程画出图就是如下：
![页管理的总览.jpg](/images/页管理的总览.jpg)


### task_struct中的设计
文件：/[include](http://androidxref.com/kernel_3.18/xref/include/)/[linux](http://androidxref.com/kernel_3.18/xref/include/linux/)/[sched.h](http://androidxref.com/kernel_3.18/xref/include/linux/sched.h)
在代表进程结构体的task_struct下有这么一个结构体，象征着进程中所管理的虚拟内存。
```c
struct mm_struct    *mm;
```

这个结构体通过task_size把进程中的虚拟内存一分为二，task_size默认是3G，也就是用户态虚拟内存的大小
```c
unsigned long task_size; /* size of task vm space */
```

#### 用户态的布局
我们接下来看看mm_struct用户态中关键的属性
```c
unsigned long mmap_base;  /* 虚拟地址空间中用于内存映射的起始地址*/
unsigned long total_vm;   /*总共映射的页的总数*/
unsigned long locked_vm;  /* 被锁定不能换出的页 */
unsigned long pinned_vm;  /* 不能换出也不能移动的页 */
unsigned long data_vm;    /* 存放数据的页的数目*/
unsigned long exec_vm;    /* 存放可执行文件页的数目 */
unsigned long stack_vm;    /* 栈所占用页的数据 */
unsigned long start_code, end_code,/*可执行代码的起点和结束位置*/ start_data, end_data/*已经初始化数据开始位置和结束位置*/;
unsigned long start_brk/*堆起始的位置*/, brk/*堆当前结束的位置*/, start_stack/*栈起始的位置，栈的结束位置在寄存器的栈顶指针中*/;
unsigned long arg_start, arg_end,/*参数列表的位置*/ env_start, env_end/**环境变量的位置/;
```
还有其他的重要数据结构
```c
struct vm_area_struct *mmap;    /* list of VMAs */
struct rb_root mm_rb;
```
还记得我之前在Binder映射聊过的vm_area_struct吗？这个数据结构代表着用户空间的虚拟内存，vm_struct则代表内核空间的虚拟内存.所有的用户态的虚拟内存都会链接到mmap和mm_rb.红黑树的出现就为了让查找效率在O(logn)之内。
```c

struct vm_area_struct {
  /* The first cache line has the info for VMA tree walking. */
  unsigned long vm_start;    /* 用户空间的起点地址 */
  unsigned long vm_end;    /* 用户空间的 结束地址*/
  /* 把这一串区域链接到task_struct的链表上 */
  struct vm_area_struct *vm_next, *vm_prev;
  struct rb_node vm_rb/*把当前的虚拟内存区域挂载在task_struct红黑树上*/;
  struct mm_struct *vm_mm;  /* The address space we belong to. */
  struct list_head anon_vma_chain; /* Serialized by mmap_sem &
            * page_table_lock */
  struct anon_vma *anon_vma;  /* 匿名映射区域 */
  /* Function pointers to deal with this struct. */
  const struct vm_operations_struct *vm_ops ;/*操纵该虚拟内存的操作方法*/
  struct file * vm_file;    /* File we map to (can be NULL). */
  void * vm_private_data;    /* was vm_pte (shared mem) */
} __randomize_layout;
```

vm_area_struct什么时候把这些属性和真实的地址的数据起来呢。其实是在exec运行加载二进制文件的时候调用load_elf_binary完成的。

- 在这里面设置了mmap_base映射区域的起始地址；
- 栈的vm_area_struct，这里面设置了arg_start指向栈底；start_stack也同时赋值。
- elf_map将elf中的代码加载到内存
- set_brk设置了堆的vm_area_struct，设置了startbrk以及brk同时在堆顶
- load_elf_interp 将依赖的so映射到内存

![二进制加载到task_struct流程.jpeg](/images/二进制加载到task_struct流程.jpeg)

一旦映射完毕之后，我们想要修改映射，一般就是指malloc，free之类的方式申请堆内存或者执行函数加深函数栈等。可以分为2种情况：
- 1.函数调用修改栈顶指针
- 2.malloc申请堆内空间，要么申请小空间就直接修改brk的指向，要么直接执行mmap做大内存的映射。

malloc的核心原理就是如果在一页内足以分配直接修改brk指针，如果超过一页则会从vm_area_struct红黑树中查找能否是否有相应连续的空间并且合并不能合并则申请一个vm_area_struct挂载在红黑树和链表。

#### 内核态布局
原理图如下：
![内核态的内存布局.jpg](/images/内核态的内存布局.jpg)

记住整个内核态的虚拟内存和物理内存在不同的进程之间其实共用的是一份。在32位内核态中一般分配1G的大小。其中896M是直接映射区，所谓的直接映射区就是物理内存和虚拟内存有很简单的映射关系，其实就是如下：
> 物理地址 = 虚拟地址 - 3G

在着896M中，前1M已经被系统启动占用，从1M开始加载内核代码，然后是全局变量，BBS等，其实和上面那一副虚拟内存划分图几乎一致。

因为大部分的操作都在3G到3G+896M之间，这里会产生一种错觉，内核会直接操作物理内存而不是虚拟内存。然而这是错误的，内核有这么一个权限，但是它不会这么做的。

896M之上还有固定映射，持久映射，vmalloc，8M的空余。这些全部称为高端内存。高端内存是物理内存的概念，除了内存管理模块有机会直接操作物理内存其他模块还是通过虚拟内存的映射找物理内存。因此接下来高端内存也的操作其实也是通过虚拟内存操作的。

剩下的虚拟地址分为如下功能：
- 1.8M的空出
- 2.vmalloc的区称为内核动态映射区。一旦内核使用vmalloc申请内存，就是这个区间，这个区间是从分配的物理内存1.5G开始，需要使用页表记录这些内存和物理页之间的映射关系
- 3.持久映射区，当使用alloc_page的时候，在物理内存的高端内存中获取到struct page结构体可以通过kmap映射到该区域
- 4.固定映射区域，用于满足系统初期启动时候特殊需求
- 5.可以通过kmap_atomic实现临时的内核映射。当我们通过mmap映射把虚拟内存到物理内存之后，我们需要把虚拟内存中的数据写入到物理内存中就需要kmap_atomic做一个临时映射，当写入完毕，就解除映射。

![Linux虚拟内存分布.jpeg](/images/Linux虚拟内存分布.jpeg)


### 物理内存的布局

#### 物理内存的组织方式
如果物理内存是连续的，也是连续的，就称为是平坦内存模型。在使用这种模型下，CPU有很多，在总线的一侧。所有的内存组成一大片内存，在总线另一侧。cpu想要访问就需要越过总线，这种方式称为SMP，即对称多处理器模式。

后面就有了一种高级的模式NUMA，非一致内存访问。这种模式下，内存不是一整块，每个CPU都有自己的本地内存，之后CPU就能直接回到访问内存不需要过总线，每一个CPU和内存被称为一个NUMA节点。当本地内存不足的时候就会尝试的获取其他NUMA节点申请。

这里需要指出的是，NUMA 往往是非连续内存模型。而非连续内存模型不一定就是 NUMA，有时候一大片内存的情况下，也会有物理内存地址不连续的情况。

再后来内存继续支持热插拔。

![物理内存2种模型.jpeg](/images/物理内存2种模型.jpeg)

这里指讲解NUMA的模式。在这种模式下，有三个数据结构需要关注，节点，区域以及页。

#### 节点
```c
typedef struct pglist_data {
  struct zone node_zones[MAX_NR_ZONES];//区域数组
  struct zonelist node_zonelists[MAX_ZONELISTS];//备用节点和它区域的情况
  int nr_zones;//当前节点区域数目
  struct page *node_mem_map;//节点里面所有页
  unsigned long node_start_pfn;//这个节点的起始页号
  unsigned long node_present_pages; /* 这个节点包含的不连续物理内存地址的页面数*/
  unsigned long node_spanned_pages; /* 真正可用的物理内存页数 */
  int node_id;//节点id
......
} pg_data_t;
```
node_spanned_pages真正可用的物理内存页数是因为有的页是作为间隔空洞的作用，并不是用来存储。
每个节点分为一个个区域zone，在node_zones数组中有不同类型的区域如下：
```c

enum zone_type {
#ifdef CONFIG_ZONE_DMA
  ZONE_DMA,//直接内存存取，DMA模式允许CPU下发指令把事情交给外设完成
#endif
#ifdef CONFIG_ZONE_DMA32
  ZONE_DMA32,
#endif
  ZONE_NORMAL,// 直接映射区，从物理内存到虚拟内存的映射区域
#ifdef CONFIG_HIGHMEM
  ZONE_HIGHMEM,//高端内存，超过896M之上的地方
#endif
  ZONE_MOVABLE,//可移动区域，通过划分可移动不可移动区域，避免内存碎片化
  __MAX_NR_ZONES
};
```

#### 区域
```c

struct zone {
......
  struct pglist_data  *zone_pgdat;
  struct per_cpu_pageset __percpu *pageset;//区分冷热页


  unsigned long    zone_start_pfn;//zone的第一页


  /*
   * spanned_pages is the total pages spanned by the zone, including
   * holes, which is calculated as:
   *   spanned_pages = zone_end_pfn - zone_start_pfn;
   *
   * present_pages is physical pages existing within the zone, which
   * is calculated as:
   *  present_pages = spanned_pages - absent_pages(pages in holes);
   *
   * managed_pages is present pages managed by the buddy system, which
   * is calculated as (reserved_pages includes pages allocated by the
   * bootmem allocator):
   *  managed_pages = present_pages - reserved_pages;
   *
   */
  unsigned long    managed_pages;//被伙伴系统管理的页
  unsigned long    spanned_pages;//不管有没有空洞，末尾页-起始页
  unsigned long    present_pages;//真实存在所有的页


  const char    *name;
......
  /* free areas of different sizes */
  struct free_area  free_area[MAX_ORDER];

  /* zone flags, see below */
  unsigned long    flags;

  /* Primarily protects free_area */
  spinlock_t    lock;
......
} ____cacheline_internodealigned_in_
```
这里面涉及到了冷热页，什么是冷热页？CPU访问存储在高速缓存的页比直接访问内存速度快多了，存在高速缓存的页叫做热页，没有叫做冷页。每一个CPU都有一个自己的高速缓存。


#### 页
页都知道是结构体page，其实page的使用大致分为2种。

- 1.用这一整页和虚拟内存内存建立映射关系称为匿名页，用这一整页和文件关联，再和虚拟内存建立关系叫做内存映射文件。常规mmap和Binder就是匿名页，Ashmem和shmem则是内存映射文件。

在这个过程有一个关键的结构体address_space。这个结构体用于内存映射。如果是匿名页最低位为1，如果是内存映射文件最低位为0.

- 2.仅分配小内存。如刚开始申请一个task_struct的时候不需要这么大的空间，为了满足这种快速的小内存申请，Linux中有slab allocator技术，用于分配slab的一小块内存。基本原理就是从内存管理系统中申请一整页，划分多个小块内存用于分配，并且用复杂的数据结构保存。

当然还有一种叫做slob的分配机制，一般用于嵌入式系统。最后看看page的结构体
```c

    struct page {
      unsigned long flags;
      union {
        struct address_space *mapping;  
        void *s_mem;      /* slab first object */
        atomic_t compound_mapcount;  /* first tail page */
      };
      union {
        pgoff_t index;    /* Our offset within mapping. */
        void *freelist;    /* sl[aou]b first free object */
      };
      union {
        unsigned counters;
        struct {
          union {
            atomic_t _mapcount;
            unsigned int active;    /* SLAB */
            struct {      /* SLUB */
              unsigned inuse:16;
              unsigned objects:15;
              unsigned frozen:1;
            };
            int units;      /* SLOB */
          };
          atomic_t _refcount;
        };
      };
      union {
        struct list_head lru;  /* Pageout list   */
        struct dev_pagemap *pgmap; 
        struct {    /* slub per cpu partial pages */
          struct page *next;  /* Next partial slab */
          int pages;  /* Nr of partial slabs left */
          int pobjects;  /* Approximate # of objects */
        };
        struct rcu_head rcu_head;
        struct {
          unsigned long compound_head; /* If bit zero is set */
          unsigned int compound_dtor;
          unsigned int compound_order;
        };
      };
      union {
        unsigned long private;
        struct kmem_cache *slab_cache;  /* SL[AU]B: Pointer to slab */
      };
    ......
    }
```

#### 页的分配 伙伴系统
物理页的分配是有一种叫做伙伴系统的方式分配出合理大小的物理页，其实这个原理在Binder的时候已经聊过了，这里看看它的原理图：
![伙伴系统.jpeg](/images/伙伴系统.jpeg)

调用伙伴系统分配物理页，一般是使用alloc_pages方法进行分配。其核心原理就是当向内核请求分配 (2^(i-1) ，2^i] 数目的页块时，按照 2^i 页块请求处理。如果对应的页块链表中没有空闲页块，那我们就在更大的页块链表中去找。当分配的页块中有多余的页时，伙伴系统会根据多余的页块大小插入到对应的空闲页块链表中。

比如我们要申请一个128页的大小的页块，尝试的超着128页对应的链表中有没有空闲，有则取出，没有则往更加高一层，也就是256大小页块区域查找。找到有空闲，则把256拆成2部分，128和128，其中一个128拿去用，另一个128挂载128页项的空闲链表中。


整个物理页体系如下管理
![物理内存管理体系.jpeg](/images/物理内存管理体系.jpeg)


#### 小物理内存申请
![slab小内存划分.jpeg](/images/slab小内存划分.jpeg)
slab中小内存大致上是如此划分，每一个小内存都有指针指向下一个小内存，方便增加删除。

分配缓存块的时候，分为两种情况，一种是kmem_cache_cpu快通道，一种是kmem_cache_node普通通道。

每一次都会从kmem_cache_cpu快通道申请，freelist(2次机会)和partial(1次机会)两个内存链表发现没有足够的内存，接着才从普通通道申请，也是从freelist(2次机会)和partial(1次机会)中查找内存。

#### 页面的换入换出
页面的换入换出本质上就是为了实现虚拟内存很大，而物理内存没有这么多的问题。如果一段内存长时间不用了，就会把物理内存记录在硬盘，把活跃的内存交给活跃进程。

页面的换入换出的时机：
- 1.申请一页，最终会调用shrink_node，页面的换入换出是以节点为单位换入换出
- 2.当系统内存紧张时候，内核线程 kswapd开始换入换出内存页，最后也是调用shrink_node

内存也分为2中，匿名内存，内存映射文件。他们都有两个列表active活跃列表和inactive非活跃列表。换入换出也是选择从非活跃中获取这个LRU最不活跃的列表进行换入换出。

![申请内存到页的组件结构.jpeg](/images/申请内存到页的组件结构.jpeg)


## 物理内存到虚拟内存的映射
这个模块分为两部分来介绍，一个是用户态的内存映射，一个是内核态的内存映射。

### 用户态的内存映射
这里涉及到了mmap的源码，有兴趣可以去Binder系列下文过一遍源码：
[Android 重学系列 Binder驱动的初始化 映射原理](https://www.jianshu.com/p/4399aedb4d42)

其实在这个过程vm_area_struct结构体是从slab中申请出来的，并且会尝试这合并vm_area_struct结构体，最后会挂载到mm_struct 的红黑树。

对于内存映射文件，还会多处理一些逻辑。对于打开的文件有结构体file表示，里面有一个address_space的成员变量：
```c

struct address_space {
  struct inode    *host;    /* owner: inode, block_device */
......
  struct rb_root    i_mmap;    /* tree of private and shared mappings */
......
  const struct address_space_operations *a_ops;  /* methods */
......
}


static void __vma_link_file(struct vm_area_struct *vma)
{
  struct file *file;


  file = vma->vm_file;
  if (file) {
    struct address_space *mapping = file->f_mapping;
    vma_interval_tree_insert(vma, &mapping->i_mmap);
  }
```
所映射的内存将不会直接挂载到mm_struct中，而是挂载在这个结构体的i_mmap红黑树中。这个方式可以在shmem中看到。

到这些方式都只是在逻辑层面上让虚拟内存结构体和文件关联起来，并没有具体申请物理页。因为物理页很珍贵，需要用时获取。

那么一般情况下，什么时候才开始申请物理页。一般是尝试着操作这一段虚拟内存的时候发现没有映射物理页，就发出了缺页中断，系统就会申请物理页，而方法就是do_page_fault。

这个过程完成了如下步骤：
- 1.判断缺页是否在内核。是在内核则调用vmalloc_fault,这样就能把vmallo区中的建立起物理页和虚拟内存的关系
- 2.如果是用户态则调用handle_mm_fault映射。
- 3.handle_mm_fault建立起了pgd,p4d,pud,pmd,pte线性地址的五个组成部分。如果不看p4d。这里实际上就是我在Binder中聊过的页管理的组成部分，pgd全局目录，pud上层目录，pmd中间目录，pte直接页表项。最后还有一个offset。
- 4.调用handle_pte_fault。在这里面分为三种情况。

情况一：如果新的页表项，这个页是一个匿名页，要映射到某一段物理内存中，就会调用do_anonymous_page，最后会调用alloc_zeroed_user_highpage_movable通过伙伴系统分配物理页，最后塞进页表中。

情况二：映射到文件，就会调用__do_fault，其中调用了vm_operations_struct的fault的操作方法。在ext4文件系统中，如果文件已经有物理内存作为缓存直接获取对应的page，预读里面的数据；没有则分配一个物理页添加到lru表，调用address_space中readPage的方法读取数据到内存。

情况三：do_swap_page换入换出。首先查找swap文件有没有缓存。没有则通过swapin_readahead把数据从文件读取出来加载到内存，并生成页目录插入页表中。

还有一种名为TLB的方式，称为块表。专门做地址映射的硬件设备。不再内存中可存储的数据比内存少，但是比内存快。可以当成页表的Cache。查找方式如下。

![Linux查表.jpg](/images/Linux查表.jpg)



### 内核态的内存映射

实际上在fork等方式生成新的进程时候，会初始化mm_struct的pgd全局目录项，其中调用了pgd_ctor方法，而这个方法拷贝了swapper_pg_dir的引用，而这个引用就是内核态中的最顶级的全局目录页表。一个进程内存分为用户态和内核态，当然内存页也分为用户态和内核态的页表。

当进程调度的时候，内存会进行切换，会调用load_new_mm_cr3方法。这是指cr3寄存器，这个寄存器保存着当前进程的全局目录页表。如果进程要访问虚拟内存，会从cr3寄存器获取pgd地址，通过这个地址找到后面的页表查找真正的物理内存数据。

初始化内核态的页表本质上还是要看swapper_pg_dir这个属性是怎么初始化的。原理如图：
![内核态页表初始化.png](/images/内核态页表初始化.png)

#### vmalloc 和 kmap_atomic 原理
用户态通过malloc申请内存大的内存实际上调用的是mmap。

vmalloc也是十分相似，最后会调用__vmalloc_node_range，在vmalloc区进行逻辑上的关联。

kmap_atomic临时映射，如果是32位有高端地址则调用set_pte通过内核页表进行映射。

kmap_atomic发现没有页表，则会创建页表进行映射。vmalloc则是借助缺页中断进行分配物理页。

总结原理图如下：
![内核态分配物理页.png](/images/内核态分配物理页.png)









