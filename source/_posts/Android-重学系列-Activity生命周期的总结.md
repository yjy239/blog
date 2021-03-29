---
title: Android 重学系列 Activity生命周期的总结
top: false
cover: false
date: 2020-09-13 10:34:59
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---

# 前言
这是之前欠下的Activity 启动到销毁的系列文章的总结。Activity是四大组件中最为复杂的一环，就算是我也没办法说我全面的理解了，因此还是有必要把如下三篇文章，做一次小的总结。

- [Android 重学系列 Activity的启动流程(一)](https://www.jianshu.com/p/91feec107d4b)
- [Android 重学系列 Activity的启动流程(二)](https://www.jianshu.com/p/4d34de4418e0)
- [Android 重学系列 Activity的启动流程(三)](https://www.jianshu.com/p/ac7b6a525b96)

这三篇分别论述了Activity在启动中，做的三个大事情：
- Activity 启动准备， 准备好ActivityRecord对象
- Activity 栈的转移与变化
- AMS 如何通信到Activity中执行Activity对应的生命周期


# 正文

我们先上时序图：
![Android9.0中Activity启动流程.png](/images/Android9.0中Activity启动流程.png)

注意：红色线代表跨越Binder一次进程。

##  Activity 启动准备

在Activity的前期准备中，做了如下事情：
- 1.通过`ActivityStackSupervisor `调用`resolveIntentInternal ` 从PMS中通过Intent筛选出符合目标的Activity，如果符合多个则切换成另一个弹窗Activity的启动，这个Activity包含了当前多个符合Intent目标的Activity信息 也就是`ActivityInfo `。

- 2.获取重量级进程,这种进程只允许在一个Android系统内只有一个，一旦需要开启另一个重量级进程的Activity，就会弹出一个弹框的Activity替换代替当前的Activity，不过在其中就有了选择哪一个进程Activity的选项

- 3.Android 9.0比起低版本来说多做不少事情,在`startActivityMayWait`方法中，会进一步调用`startActivity`真正执行启动方法。根据执行方法返回的状态代码执行如下几种状态：
  - START_SUCCESS 代表Activity启动成功。往往这种情况下，很少会遇到。一般是进程在启动的时候，被阻塞起来。直到进程启动后，执行了加入栈的处理设置了状态码为`START_TASK_TO_FRONT `后，解开阻塞。进入到`START_TASK_TO_FRONT`中.

  - START_DELIVERED_TO_TOP 代表存在的Activity重新回到顶部

  - START_TASK_TO_FRONT 并没真正的启动Activity，但是Activity对应的栈跑到用户交互前台。而这个过程中，又会阻塞整个AMS，直到这个Activity可视化为止。

能看到AMS比起之前来说，约束了整个Binder通信的吞吐量。从创建到加入Activity栈，再到可视化都变成了一环扣着一环的了。这么做确实可以减少那些不可见的(不怎么紧急的)Activity启动，占用过多系统资源。

- 4.从进程LRU缓存中，查找这些进程中是否有对应的ActivityRecord是否已经存在在某一个栈。从`ActivityDisplay `中的`ActivityStack `寻找`ActivityRecord `

![Android进程LRU缓存调整.png](/images/Android进程LRU缓存调整.png)

- 5.处理Intent的Flag:`FORWARD_RESULT `.这个标志位就是透传requestCode时候的行为。一般是中间有一个临时的Activity，此时必定可以找到启动这个临时Activity的Activity对应的`ActivityRecord `,并且设置`ActivityRecord`为`sourceRecord `,并获取`sourceRecord `中的`requestCode`和`resultWho`作为参数进行覆盖。并要把获取当前临时Activity的栈作为新的Activity启动对应的栈。

- 6.判断当前的启动权限，判断条件有三：是被判断为应用有害；被禁止启动的进程;被设置为静音模式，只要不通过都是启动失败

- 7.根据`requestCode`，`resultWho`，`ActivityInfo`等关键信息生成一个新的`ActivityRecord`

### 进程优先级
说起进程，大致分为如下几个adj优先级级别:
注意每个版本的都可能数值不一样，这里是Android 9.0版本的：

| ADJ级别                | 取值  | 解释                                                              |
| ---------------------- | ----- | ----------------------------------------------------------------- |
| UNKNOWN_ADJ            | 1001  | 一般是指缓存进程也就是空进程                                      |
| CACHED_APP_MAX_ADJ     | 906   | 不可见进程的adj最大值                                             |
| CACHED_APP_MIN_ADJ     | 900   | 不可见进程的adj最小值                                             |
| SERVICE_B_ADJ          | 800   | B List中的Service（较老的、使用可能性更小）                       |
| PREVIOUS_APP_ADJ       | 700   | 上一个App的进程(往往通过按返回键)                                 |
| HOME_APP_ADJ           | 600   | Home 进程                                                         |
| SERVICE_ADJ            | 500   | 包含Service的服务进程                                             |
| HEAVY_WEIGHT_APP_ADJ   | 400   | 后台的重量级进程，system/rootdir/init.rc文件中设置                |
| BACKUP_APP_ADJ         | 300   | 备份进程                                                          |
| PERCEPTIBLE_APP_ADJ    | 200   | 可感知进程(后台服务播放音乐等)                                    |
| VISIBLE_APP_ADJ        | 100   | 可见进程                                                          |
| FOREGROUND_APP_ADJ     | 0     | 前台进程                                                          |
| PERSISTENT_SERVICE_ADJ | -700  | 关联着系统或persistent进程                                        |
| PERSISTENT_PROC_ADJ    | -800  | 系统persistent进程，比如telephony电话                             |
| SYSTEM_ADJ             | -900  | 系统进程                                                          |
| NATIVE_ADJ             | -1000 | native 进程，不受系统管控 如从init.cpp中fork出来的,如内核线程等等 |

总结下来，面试中常问的Android中进程优先级，一般可以分为如下几种：
  - 1.前台进程 
  - 2.可视进程
  - 3.服务进程
  - 4.后台进程
  - 5.空进程

从上至下，进程重要的等级越来越低，等级越低的adj数值越高，越高adj的数值越有可能被`lmk` 也就是lowmemorykiller 进程通过某种策略杀掉。

对应Android系统来说，`UNKNOWN_ADJ ` 说明此时进程的优先级不明确，在调整adj的时候，并不会通知`lmk`进程处理这个进程。

把这5个进程等级拆分出来稍微解释一下。所有调整adj数值都在`computeOomAdjLocked`方法中

#### 前台进程

是指当前用户必须执行的进程。只有进程真的没内存了，才会杀掉。一般是指adj等级为`FOREGROUND_APP_ADJ `
```java
  if (PROCESS_STATE_CUR_TOP == ActivityManager.PROCESS_STATE_TOP && app == TOP_APP) {
            adj = ProcessList.FOREGROUND_APP_ADJ;
...
        } else if (app.runningRemoteAnimation) {
...
        } else if (app.instr != null) {
            adj = ProcessList.FOREGROUND_APP_ADJ;
...
        } else if (isReceivingBroadcastLocked(app, mTmpBroadcastQueue)) {
            adj = ProcessList.FOREGROUND_APP_ADJ;
...
        } else if (app.executingServices.size() > 0) {
.
            adj = ProcessList.FOREGROUND_APP_ADJ;
...
        } else if (app == TOP_APP) {
            adj = ProcessList.FOREGROUND_APP_ADJ;
...
        }
...

            if (cpr.hasExternalProcessHandles()) {
                if (adj > ProcessList.FOREGROUND_APP_ADJ) {
                    adj = ProcessList.FOREGROUND_APP_ADJ;
...
            }
```
从上面可知，满足前台进程的的情况如下：

- 1.正在交互的Activity，也就是当前的Activity正在onResume的生命周期
- 2.某个进程正在被profile监听
- 3.某个Service绑定到用户正在交互的Activity
- 4.某个进程拥有并执行了调用了`startForeground`的前台服务
- 5.某个进程的广播接收器正在接受消息
- 6.如果某个非系统进程的ContentProvider的进程正在被依赖其他进程依赖获取数据，也是前台进程
- 7.拥有正执行一个生命周期回调的 Service（onCreate()、onStart() 或 onDestroy()）

#### 可见进程
虽然没有任何前台的组件(指交互中的Activity，接收消息中的Receiver，被依赖获取数据的CP，前台服务等)，但是依然会影响屏幕上的内容。在这里是指`VISIBLE_APP_ADJ`

```java
 else if (app.runningRemoteAnimation) {
            adj = ProcessList.VISIBLE_APP_ADJ;
...
        } 
```
```java
                if (r.visible) {
                    if (adj > ProcessList.VISIBLE_APP_ADJ) {
                        adj = ProcessList.VISIBLE_APP_ADJ;
...
                    }
```

```java
            for (int conni = s.connections.size()-1;
                    conni >= 0 && (adj > ProcessList.FOREGROUND_APP_ADJ
                            || schedGroup == ProcessList.SCHED_GROUP_BACKGROUND
                            || procState > ActivityManager.PROCESS_STATE_TOP);
                    conni--) {
...
                                    if (adj > ProcessList.VISIBLE_APP_ADJ) {
                                        newAdj = Math.max(clientAdj, ProcessList.VISIBLE_APP_ADJ);
                                    } else {
                                        newAdj = adj;
                                    }
...
}
```

- 1.拥有不再前台，但是可见也就是onPause的Activity
- 2.拥有或者绑定到前台或者可见Activity的Service
- 3.正在执行远程组件动画的进程



#### 服务进程
一般是指与用户所见内容没有直接的关联，但是他们通常正在执行用户关心的任务(如后台播放音乐，或者从网络下载数据)。
这里的adj是指 `PERCEPTIBLE_APP_ADJ `

```java
if (r.visible) {
...
                } else if (r.isState(ActivityState.PAUSING, ActivityState.PAUSED)) {
                    if (adj > ProcessList.PERCEPTIBLE_APP_ADJ) {
                        adj = ProcessList.PERCEPTIBLE_APP_ADJ;
                        app.adjType = "pause-activity";
                    }
                    if (procState > PROCESS_STATE_CUR_TOP) {
                        procState = PROCESS_STATE_CUR_TOP;
                        app.adjType = "pause-activity";
                    }
                    if (schedGroup < ProcessList.SCHED_GROUP_DEFAULT) {
                        schedGroup = ProcessList.SCHED_GROUP_DEFAULT;
                    }
                    app.cached = false;
                    app.empty = false;
                    foregroundActivities = true;
                } else if (r.isState(ActivityState.STOPPING)) {
                    if (adj > ProcessList.PERCEPTIBLE_APP_ADJ) {
                        adj = ProcessList.PERCEPTIBLE_APP_ADJ;
                        app.adjType = "stop-activity";
                    }
...
                    app.cached = false;
                    app.empty = false;
                    foregroundActivities = true;
                } else {
...
                }
            }
```

- 1.不可见的Activity，并且是正在执行onPause或者onPause执行完毕
- 2.不可见的Activity，且是正在执行onStop

```java
        if (adj > ProcessList.PERCEPTIBLE_APP_ADJ
                || procState > ActivityManager.PROCESS_STATE_FOREGROUND_SERVICE) {
            if (app.foregroundServices) {
                adj = ProcessList.PERCEPTIBLE_APP_ADJ;
                procState = ActivityManager.PROCESS_STATE_FOREGROUND_SERVICE;
                app.cached = false;
                app.adjType = "fg-service";
                schedGroup = ProcessList.SCHED_GROUP_DEFAULT;

            } else if (app.hasOverlayUi) {
                adj = ProcessList.PERCEPTIBLE_APP_ADJ;
                procState = ActivityManager.PROCESS_STATE_IMPORTANT_FOREGROUND;
                app.cached = false;
                app.adjType = "has-overlay-ui";
                schedGroup = ProcessList.SCHED_GROUP_DEFAULT;

            }
        }

        if (adj > ProcessList.PERCEPTIBLE_APP_ADJ
                || procState > ActivityManager.PROCESS_STATE_TRANSIENT_BACKGROUND) {
            if (app.forcingToImportant != null) {
                adj = ProcessList.PERCEPTIBLE_APP_ADJ;
                procState = ActivityManager.PROCESS_STATE_TRANSIENT_BACKGROUND;
                app.cached = false;
                app.adjType = "force-imp";
                app.adjSource = app.forcingToImportant;
                schedGroup = ProcessList.SCHED_GROUP_DEFAULT;
            }
        }
```
- 3.adj优先级低于`PERCEPTIBLE_APP_ADJ`，且比 拥有前台服务进程的优先级低，则判断是否持有前台服务，持有也会设置为`PERCEPTIBLE_APP_ADJ`；如果当前的进程在执行`OverlayUi`也会设置为`PERCEPTIBLE_APP_ADJ`。

- 4.adj优先级低于`PERCEPTIBLE_APP_ADJ`,且进程状态等级低于`PROCESS_STATE_TRANSIENT_BACKGROUND`正在运行的后台服务的进程，此时发现`ProcessRecord `持有一个`forcingToImportant`的token。这个token的设置实际是当我们需要显示Toast时候调用`NotificationManagerService `的`enqueueToast`入队排序显示吐司，为了显示`Toast`此时Android系统为了可以正常显示，就会调用`keepProcessAliveIfNeededLocked` 设置进程对应的`token` 保证进程在最低限度的存活。

- 5.通过startService正在运行的进程.在这些进程中找到那些最近显示过ui的但是现在没有显示的，或者此时没有显示ui进程且没有显示toast的进程，都降级为`PERCEPTIBLE_APP_ADJ`.

```java
            for (int conni = s.connections.size()-1;
                    conni >= 0 && (adj > ProcessList.FOREGROUND_APP_ADJ
                            || schedGroup == ProcessList.SCHED_GROUP_BACKGROUND
                            || procState > ActivityManager.PROCESS_STATE_TOP);
                    conni--) {
                ArrayList<ConnectionRecord> clist = s.connections.valueAt(conni);
                for (int i = 0;
                        i < clist.size() && (adj > ProcessList.FOREGROUND_APP_ADJ
                                || schedGroup == ProcessList.SCHED_GROUP_BACKGROUND
                                || procState > ActivityManager.PROCESS_STATE_TOP);
                        i++) {
                    if ((cr.flags&Context.BIND_WAIVE_PRIORITY) == 0) {
                        if (adj > clientAdj) {
                            if (app.hasShownUi && app != mHomeProcess
                                    && clientAdj > ProcessList.PERCEPTIBLE_APP_ADJ) {
...
                            } else {
                                int newAdj;
                                if ((cr.flags&(Context.BIND_ABOVE_CLIENT
                                        |Context.BIND_IMPORTANT)) != 0) {
                                    if (clientAdj >= ProcessList.PERSISTENT_SERVICE_ADJ) {
                                       ...
                                    } else {
                                        newAdj = ProcessList.PERSISTENT_SERVICE_ADJ;
                                        schedGroup = ProcessList.SCHED_GROUP_DEFAULT;
                                        procState = ActivityManager.PROCESS_STATE_PERSISTENT;
                                    }
                                } else if ((cr.flags&Context.BIND_NOT_VISIBLE) != 0
                                        && clientAdj < ProcessList.PERCEPTIBLE_APP_ADJ
                                        && adj > ProcessList.PERCEPTIBLE_APP_ADJ) {
                                    newAdj = ProcessList.PERCEPTIBLE_APP_ADJ;
                                } else if (clientAdj >= ProcessList.PERCEPTIBLE_APP_ADJ) {
                                   ...
                                } else {
                                    if (adj > ProcessList.VISIBLE_APP_ADJ) {
                                        newAdj = Math.max(clientAdj, ProcessList.VISIBLE_APP_ADJ);
                                    } else {
                                        newAdj = adj;
                                    }
                                }
                                if (!client.cached) {
                                    app.cached = false;
                                }
                                if (adj >  newAdj) {
                                    adj = newAdj;
                                    adjType = "service";
                                }
                            }
                        }
                    }
  }
}
```


#### 后台进程

后台进程对用户体验没有任何影响，因此进程可能会随时回收掉这种进程，以获得更多的内存。通常会有很多后台进程正在运行，这些进程都会保存在我刚刚说的LRU表中。如果Activity正常的执行了生命周期并且缓存了状态，当终止进程时不会产生明显用户体验的影响，当通过导航重新打开，Activity将会读取缓存并可见。

在这里adj是指从`BACKUP_APP_ADJ ` 一直到`SERVICE_B_ADJ `中间。但是只有`HOME_APP_ADJ `桌面进程例外。这个过程有什么魔法呢？实际上是在`lmkd`进程通信到`lowmemorykiller`内核模块(驱动)之前，对`600`数值对应的adj数值进行了特殊处理，强制设置为`200`.
/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[lmkd](http://androidxref.com/9.0.0_r3/xref/system/core/lmkd/)/[lmkd.c](http://androidxref.com/9.0.0_r3/xref/system/core/lmkd/lmkd.c)
```c
static void cmd_procprio(LMKD_CTRL_PACKET packet) {
    struct proc *procp;
    char path[80];
    char val[20];
    int soft_limit_mult;
    struct lmk_procprio params;

    lmkd_pack_get_procprio(packet, &params);

    if (params.oomadj < OOM_SCORE_ADJ_MIN ||
        params.oomadj > OOM_SCORE_ADJ_MAX) {
        ALOGE("Invalid PROCPRIO oomadj argument %d", params.oomadj);
        return;
    }

    snprintf(path, sizeof(path), "/proc/%d/oom_score_adj", params.pid);
    snprintf(val, sizeof(val), "%d", params.oomadj);
    writefilestring(path, val);

    if (use_inkernel_interface)
        return;

    if (low_ram_device) {
        if (params.oomadj >= 900) {
            soft_limit_mult = 0;
        } else if (params.oomadj >= 800) {
            soft_limit_mult = 0;
        } else if (params.oomadj >= 700) {
            soft_limit_mult = 0;
        } else if (params.oomadj >= 600) {
            // Launcher should be perceptible, don't kill it.
            params.oomadj = 200;
            soft_limit_mult = 1;
        } else if (params.oomadj >= 500) {
            soft_limit_mult = 0;
        } else if (params.oomadj >= 400) {
            soft_limit_mult = 0;
        } else if (params.oomadj >= 300) {
            soft_limit_mult = 1;
        } else if (params.oomadj >= 200) {
            soft_limit_mult = 2;
        } else if (params.oomadj >= 100) {
            soft_limit_mult = 10;
        } else if (params.oomadj >=   0) {
            soft_limit_mult = 20;
        } else {
            // Persistent processes will have a large
            // soft limit 512MB.
            soft_limit_mult = 64;
        }

        snprintf(path, sizeof(path),
             "/dev/memcg/apps/uid_%d/pid_%d/memory.soft_limit_in_bytes",
             params.uid, params.pid);
        snprintf(val, sizeof(val), "%d", soft_limit_mult * EIGHT_MEGA);
        writefilestring(path, val);
    }

    procp = pid_lookup(params.pid);
    if (!procp) {
            procp = malloc(sizeof(struct proc));
            if (!procp) {
                // Oh, the irony.  May need to rebuild our state.
                return;
            }

            procp->pid = params.pid;
            procp->uid = params.uid;
            procp->oomadj = params.oomadj;
            proc_insert(procp);
    } else {
        proc_unslot(procp);
        procp->oomadj = params.oomadj;
        proc_slot(procp);
    }
}
```
注意这里面的oomadj参数就是设置给lowmemorykiller 驱动参数。在Android的Linux内核中，每一个task_struct都包含了一个`signal_struct`，其中就包含了进程的优先级`oom_score_adj`。

#### 空进程
就是已经什么都不存了，存储只是缓存起来的进程对象，缩短下次在其中运行组件所需的启动时间。

代表的adj数值是`CACHED_APP_MIN_ADJ `到`CACHED_APP_MAX_ADJ `

#### lmk lowmemorykiller 驱动原理
稍微总结一下lmkd守护进程 是如何根据adj杀死无用进程的。
如下图：
![lmkd.png](/images/lmkd.png)


整个lmk的流程需要从这几个方向上理解。调整adj的时机有两个：
- 1.WMS的配置发生了配置，此时就会调用`updateOomLevels`刷新每一个进程的OOM等级核心计算方式如下：
```java
    private final int[] mOomAdj = new int[] {
            FOREGROUND_APP_ADJ, VISIBLE_APP_ADJ, PERCEPTIBLE_APP_ADJ,
            BACKUP_APP_ADJ, CACHED_APP_MIN_ADJ, CACHED_APP_MAX_ADJ
    };
    // These are the low-end OOM level limits.  This is appropriate for an
    // HVGA or smaller phone with less than 512MB.  Values are in KB.
    private final int[] mOomMinFreeLow = new int[] {
            12288, 18432, 24576,
            36864, 43008, 49152
    };
    // These are the high-end OOM level limits.  This is appropriate for a
    // 1280x800 or larger screen with around 1GB RAM.  Values are in KB.
    private final int[] mOomMinFreeHigh = new int[] {
            73728, 92160, 110592,
            129024, 147456, 184320
    };
    // The actual OOM killer memory levels we are using.
    private final int[] mOomMinFree = new int[mOomAdj.length];
```
首先，lmk只会处理`FOREGROUND_APP_ADJ`,`VISIBLE_APP_ADJ`,`PERCEPTIBLE_APP_ADJ`,`BACKUP_APP_ADJ`，`CACHED_APP_MIN_ADJ`,`CACHED_APP_MAX_ADJ` 这6个级别的adj对应的进程。

每一次WMS的配置发生了变更，也就是屏幕相关的信息发生了变化，每一个进程可用的最小内存也会随之发生变化，计算公式如下：

> LMK杀死进程的阈值 = mOomMinFreeLow[对应adj等级在mOomAdj的index] + （mOomMinFreeHigh[对应adj等级在mOomAdj的index] - mOomMinFreeLow[对应adj等级在mOomAdj的index]）* scale

比如说:
> 此时是CACHED_APP_MAX_ADJ，在mOomMinFreeLow对应的内存是49152，在mOomMinFreeHigh对应的是184320，则：49152+(184320-49152)*scale


这个scale数值的计算是根据屏幕状态变化而变化:
> scaleMem(内存系数) = （系统的总内存(单位MB) - 350）/ 350
> scaleDisp(屏幕内存系数) = ((屏幕宽*屏幕高) - (480 * 800)) / ((1280 * 800) - (480 * 800))

实际上第一个内存系数就是获取当前内存以350M为一个单位看看还有多少份；第二个屏幕内存系数是看看一个屏幕下总像素的内存进行均值化 （有兴趣可以看看[线性回归与梯度下降](https://www.jianshu.com/p/87089a152327)）从而获得屏幕像素归一到(480 * 800) (最小屏幕大小)和(1280 * 800) 最大屏幕大小(很明显现实中比最大的大，比最小的小比比皆是)，从而获得一个合适的像素内存系数。

比较两者取较大的数值
> scale = scaleMem > scaleDisp ? scaleMem : scaleDisp

最后把计算出来的对应的adj对应的最小内存保存到mOomMinFree数组中发送到lowmemorykiller驱动中缓存起来。

- 2.当进程中四大组件的行为发生了变更，则会每一个进程对应adj数值。此时会先通过socket通信到`lmkd`守护进程中，此时会通过Linux的`cgroup`把当前对应的内存限额写入对应的进程中。等到内核需要回收的时候，就会通过`lowkmemorykiller`遍历找到最大的rss内存，最大的adj通过发送中断信号`SIGKILL`杀死进程。


### Activity 栈的变化

要彻底弄明白Activity的栈变化需要了解如下数据结构，可以阅读我写过的[WMS在Activity启动中的职责(二)](https://www.jianshu.com/p/c7cc335b880a)一文，里面介绍了不仅仅是Activity启动时候，对应栈的数据结构，还对应了WMS如何控制这些数据结构的显示：
![ConfigurationContainer之间联系.png](/images/ConfigurationContainer之间联系.png)

先从这个图中关键的四个的数据结构开始说起：
- 1. `ActivityDisplay` 代表每一个Activity显示的显示屏，内持有逻辑显示屏对应的id。这个对象将会持有三个核心的数据结构`DisplayWindowController `,`DisplayContent `,`ActivityStack`.前两者控制整个栈对应的显示区域如何摆放.后者则是以一个应用进程的维度控制栈

- 2. `ActivityStack` 是指进程中有多少个Activity的栈。这个栈持有了一个`mHistory`集合。这个栈才是正常开发中接触到的栈。

- 3.TaskRecord 就是我们开发中接触的栈，这个栈持有了taskid，affinity等标识参数。其中持有一个核心数据结构mActivities的集合`mActivities`。

- 4.ActivityRecord  实际上就是Activity在AMS中标示对象。系统通过持有ActivityRecord从而得知每一个应用进程中每一个Activity的状态。

如下图：

![AMS栈的设计.png](/images/AMS栈的设计.png)

对于我们开发者来说只有TaskRecord才是可见的。

理解了这些之后，在方法`startActivityUnchecked `会处理绝大部分的关于Task相关的操作。

回顾一下Activity四大启动模式：
- 1.standard 意味着默认启动方式。继承上一个Activity对应的Task进行启动
- 2.singleTop 如果Activity处于栈顶则不需要创建，不在栈顶则创建新的。意味这这里的栈顶也就是TaskRecord的mActivities处于末尾顶部
- 3.singleTask 是指栈内唯一，此时会从TaskRecord的mActivities中查找能否有复用的ActivityRecord
- 4.singleInstance 这个是指新建一个TaskRecord保存在mTaskHistory中，并新建一个新的ActivityRecord。

实际上AMS，并不是根据这四个启动模式进行处理的。而是这四个启动模式，会转化成Intent中对应的flag进行出来。


其实很简单，如果我们忽略了分屏操作的行为，实际上在AMS眼里可以把启动带上的flag分为如下四类：
- 1.如果是启动的flag打上了`FLAG_ACTIVITY_NEW_TASK`，调用`setTaskFromReuseOrCreateNewTask `
- 2.继承上一个`ActivityRecord`对应的`TaskRecord` 调用`setTaskFromSourceRecord `
- 3.不继承上一个`ActivityRecord`的`TaskRecord`,但是因为指定了`TaskRecord`的`affinity`,`id`等方式提前得知了对应的`TaskRecord`,从而移动到另一个`TaskRecord` 调用`setTaskFromInTask `
- 4.其他模式 调用`setTaskToCurrentTopOrCreateNewTask `

第三点，是系统内部调用`startActivityInPackage`时候明确知道TaskRecord是什么。我们不去讨论。

#### setTaskFromReuseOrCreateNewTask

这个方法就是专门处理`FLAG_ACTIVITY_NEW_TASK` 标志位的。

在执行这个判断之前，会调用`computeLaunchingTaskFlags `方法判断调用startActivity的调用者，是否存在启动的Activity对象且没有确定的TaskRecord(mInTask)，此时就是。

-没有复用的`TaskRecord` ： 在`setTaskFromReuseOrCreateNewTask`这个方法就会创建一个新的`TaskRecord`.在准备的步骤，已经找到对应的`ActivityRecord`.，或者创建一个全新的`ActivityRecord`.就会调用`addOrReparentStartingActivity ` 绑定这个全新的`TaskRecord`.

- 存在复用`TaskRecord` ：则直接调用`addOrReparentStartingActivity ` 重新绑定`TaskRecord`.从而实现栈内唯一。指的注意的是，如果此时的`launchMode `是`LAUNCH_SINGLE_INSTANCE ` 或者`LAUNCH_SINGLE_TASK ` 则强制把对应的登录flag添加一个`FLAG_ACTIVITY_NEW_TASK `.


#### setTaskFromSourceRecord

这个过程中，就会获得调用者`ActivityRecord`的`TaskRecord`以及`ActivityStack `,新的ActivityRecord并准备继承这些对象。

- 1. 判断是否带上`FLAG_ACTIVITY_CLEAR_TOP`标志位且不需要添加到TaskRecord，带则调用`TaskRecord`的`performClearTaskLocked` 调用这个方法调用之前复用`ActivityRecord`之前的所有Activity的finish的方法。

- 2.并把对应的`ActivityStack`，`TaskRecord`移动到集合的末尾，作为当前的焦点。

- 3.`addOrReparentStartingActivity `绑定或者新增到TaskRecord中

#### setTaskToCurrentTopOrCreateNewTask
```java
    private void setTaskToCurrentTopOrCreateNewTask() {
        mTargetStack = computeStackFocus(mStartActivity, false, mLaunchFlags, mOptions);
        if (mDoResume) {
            mTargetStack.moveToFront("addingToTopTask");
        }
        final ActivityRecord prev = mTargetStack.getTopActivity();
        final TaskRecord task = (prev != null) ? prev.getTask() : mTargetStack.createTaskRecord(
                mSupervisor.getNextTaskIdForUserLocked(mStartActivity.userId), mStartActivity.info,
                mIntent, null, null, true, mStartActivity, mSourceRecord, mOptions);
        addOrReparentStartingActivity(task, "setTaskToCurrentTopOrCreateNewTask");
        mTargetStack.positionChildWindowContainerAtTop(task);
    }
```
其他情况就是拿到焦点的`ActivityStack`后再拿到顶部运行的`TaskRecord`，把新的`ActivityRecord`绑定起来。

### Activity跨进程启动

在方法`realStartActivityLocked `中真正的开始进行跨进程通信，在继续聊之前看看几个重要的对象：
![ClientTransaction.png](/images/ClientTransaction.png)

ClientTransaction 是AMS通信到App应用进程的核心对象。

- 1.ClientTransaction 客户端事务控制者
- 2.ClientLifecycleManager 客户端的生命周期事务控制者
- 3.TransactionExecutor 远程通信事务执行者
- 4.LaunchActivityItem 远程App端的onCreate生命周期事务
- 5.ResumeActivityItem 远程App端的onResume生命周期事务
- 6.PauseActivityItem 远程App端的onPause生命周期事务
- 7.StopActivityItem 远程App端的onStop生命周期事务
- 8.DestroyActivityItem 远程App端onDestroy生命周期事务。
- 9.ClientTransactionHandler App端对ClientTransaction的处理。


#### LaunchActivityItem

LaunchActivityItem 通信到在AppThread做了如下事情：
- 1.反射生成Activity实例
- 2.获取当前的应用的Application对象并且调用attach绑定
- 3.最后通过Instrument调用callActivityOnCreate调用到Activity实例中的onCreate方法

#### ResumeActivityItem
- 1.调用`ActivityThread ` 的`handleStartActivity `,执行`Activity`的`onStart`方法
- 2.调用`ActivityThread ` 的`performResumeActivity `
- 3.如果pendingIntent不为空，则以此执行执行`onNewIntent`,`onActivityResult`
- 4.执行`Activity`的`onResume`
- 5.执行View的绘制流程
- 6.执行handler的idle事件，这个事件就是`Idler`对象。关于idle相关的内容可以阅读[Handler与相关系统调用的剖析(上)](https://www.jianshu.com/p/416de2a3a1d6).这个事件就是Handler没有什么重要事件执行的，执行的内容就是`activityIdle`这个方法就会调用所有不可见Activity的onStop


#### PauseActivityItem
- 1.调用`callActivityOnSaveInstanceState `方法保存当前`Activity`的状态
- 2.调用`Activity`的`onPause`
- 3.此时一旦判断当前ActivityRecord已经绑定了App端的数据，说明已经启动了，并且当前的ActivityRecord的visible为false，或者点击了锁屏使其睡眠，都会调用addToStopping.到activityIdle方法就会执行Activity的onStop，因此如果是可见的dialog，由于此时Activity还是可见，因此不会走到onStop方法

#### StopActivityItem
- 1.调用过`ActivityThread`的handleStopActivity方法
- 2.如果没有调用过`onPause` 则调用`onPause`
- 3.调用`Activity`的`onStop`
- 4.等待SP写入磁盘
- 5.执行AMS的activityStopped，在`activityStoppedLocked`里面判断ActivityRecord是否通过makeFinishingLocked设置了finishing为true，从而判断是否需要执行后续的周期。

#### DestroyActivityItem
当调用了Activity的`finish`方法后，就会跨进程调用的`finishActivity `:
- 1.当前要finish的Activity刚好就是当前的正在交互的Activity，则调用`onPause`和`onStop `,调用`ActivityStack`的`destroyActivityLocked `

- 2.当finish的Activity不是onPause，尝试调用`finishCurrentActivityLocked`，finish对应的Activity,接着会尝试的调用addToStopping，会调到onStop方法，接着也会调用destroyActivityLocked。

- 3.执行`DestroyActivityItem `中对应的跨进程操作

- 4.调用Activity的OnDestroy

- 5.将会清空Activity中设置的window数据以及设置的ContentView

- 6.最后通过activityDestroyed通知AMS

#### onRestart
肯定有人觉得奇怪，七大声明周期之一的onRestart呢？他其实和onStart一样隐藏在TransactionExecutor 中。
来看看/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[servertransaction](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/)/[TransactionExecutorHelper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/servertransaction/TransactionExecutorHelper.java)
：
```java
   public IntArray getLifecyclePath(int start, int finish, boolean excludeLastState) {
        if (start == UNDEFINED || finish == UNDEFINED) {
            throw new IllegalArgumentException("Can't resolve lifecycle path for undefined state");
        }
        if (start == ON_RESTART || finish == ON_RESTART) {
            throw new IllegalArgumentException(
                    "Can't start or finish in intermittent RESTART state");
        }
        if (finish == PRE_ON_CREATE && start != finish) {
            throw new IllegalArgumentException("Can only start in pre-onCreate state");
        }

        mLifecycleSequence.clear();
        if (finish >= start) {
            // just go there
...
        } else { // finish < start, can't just cycle down
            if (start == ON_PAUSE && finish == ON_RESUME) {
                // Special case when we can just directly go to resumed state.
                mLifecycleSequence.add(ON_RESUME);
            } else if (start <= ON_STOP && finish >= ON_START) {
                // Restart and go to required state.

                // Go to stopped state first.
                for (int i = start + 1; i <= ON_STOP; i++) {
                    mLifecycleSequence.add(i);
                }
                // Restart
                mLifecycleSequence.add(ON_RESTART);
                // Go to required state
                for (int i = ON_START; i <= finish; i++) {
                    mLifecycleSequence.add(i);
                }
            } else {
                // Relaunch and go to required state

                // Go to destroyed state first.
                for (int i = start + 1; i <= ON_DESTROY; i++) {
                    mLifecycleSequence.add(i);
                }
                // Go to required state
                for (int i = ON_CREATE; i <= finish; i++) {
                    mLifecycleSequence.add(i);
                }
            }
        }

...
        return mLifecycleSequence;
    }
```
注意这里的参数start是指当前Activity的状态，finish是指经过TransactionExecutor执行后，每一个`ActivityLifecycleItem `对应的目标Activity需要达到什么声明周期。

- 1.如果当前的Activity是`ON_PAUSE`状态，目标是`ON_RESUME`，此时只需要执行一个`ON_RESUME`

- 2.如果此时的状态是`ON_STOP`之后的状态，且目标是`ON_START`.一般来说此时都是执行的是`ResumeActivityItem` 需要从AMS让此时的Activity转化为可见。此时的`Activity`已经执行了onStop，就会把小于`ON_STOP`的状态添加进来(没有就跳过了),再把`ON_RESTART`声明周期添加进来，最后把`onStart`和`onResume`(因为`ResumeActivityItem` 目标就是`onResume`)添加进来

- 3.最后到达了TransactionExecutor中执行每一个`ActivityLifecycleItem `的生命周期，从而执行了ActivityThread的`onRestart`后执行，`onStart`,`onResume`


### 实际案例
有一道常见的面试题：
- Activity A 启动 Activity B 声明周期怎么执行
- Activity B 在onCreate，onResume执行finish是怎么执行声明周期的。


第一种情况下：A启动了B。

此时A会先执行PauseActivityItem，从而执行onPause,此时AMS会阻塞住不会前往执行B的启动。

onPause执行结束之后，就会继续执行A的onCreate，onStart,onResume,接着执行一个idle事件，通知AMS执行所有不可见的Activity的`onStop`,如下图：
```java
2020-09-12 22:44:20.745 9287-9287/com.yjy.superjsbridge E/A: onStart
2020-09-12 22:44:20.747 9287-9287/com.yjy.superjsbridge E/A: onResume
2020-09-12 22:44:31.746 9287-9287/com.yjy.superjsbridge E/A: onPause
2020-09-12 22:44:31.768 9287-9287/com.yjy.superjsbridge E/B: onCreate
2020-09-12 22:44:32.598 9287-9287/com.yjy.superjsbridge E/B: onStart
2020-09-12 22:44:32.603 9287-9287/com.yjy.superjsbridge E/B: onResume
2020-09-12 22:44:33.083 9287-9287/com.yjy.superjsbridge E/A: onStop
2020-09-12 22:54:31.631 9287-9287/com.yjy.superjsbridge E/B: onPause
2020-09-12 22:54:31.688 9287-9287/com.yjy.superjsbridge E/B: onStop
```

 一旦熄掉屏幕后，重新打开，或者从Home/其他App回来后就会执行：
```java
2020-09-12 23:00:14.342 9287-9287/com.yjy.superjsbridge E/B: onRestart
2020-09-12 23:00:14.418 9287-9287/com.yjy.superjsbridge E/B: onStart
2020-09-12 23:00:14.433 9287-9287/com.yjy.superjsbridge E/B: onResume
```

第二种：Activity A 在onCreate，onResume执行finish是怎么执行声明周期的。其实就是考察了对`finishActivityLocked `的理解。
当调用了finish之后，会执行如下方法：
```java
            if (mResumedActivity == r) {
....
                r.setVisibility(false);

                if (mPausingActivity == null) {
                    startPausingLocked(false, false, null, pauseImmediately);
                }

                if (endTask) {
                    mService.getLockTaskController().clearLockedTask(task);
                }
            } else if (!r.isState(PAUSING)) {
  ....
                final int finishMode = (r.visible || r.nowVisible) ? FINISH_AFTER_VISIBLE
                        : FINISH_AFTER_PAUSE;
                final boolean removedActivity = finishCurrentActivityLocked(r, finishMode, oomAdj,
                        "finishActivityLocked") == null;

               ....
                return removedActivity;
            } else {
            }
```
只分为两种情况：
- 当前的Activity在onResume，此时设置了visible为false，并开始调用onPause方法。所以就会调用`onPause`,当执行完后，就会调用`completePauseLocked `方法，此时是不可见的，就会添加到addToStop对象，并且执行onStop的方法以及onDestory

- 如果此时不是正在执行`PAUSING`。则根据是否显示来决定是finish的方法是可视化之后再finish(`FINISH_AFTER_VISIBLE`)，另一个是pause之后在finish（`FINISH_AFTER_PAUSE`）。

  - `FINISH_AFTER_VISIBLE` 则通过`startPausingLocked`调用`addToStop`，通知AMS的Handler执行`activityIdleInternalLocked`方法，这个方法就是执行ActivityThread的onStop的入口。在`ActivityThread`中会校验`onPause`是否执行，没执行过则执行，最后执行`onStop`，并在`activityIdleInternalLocked`的后半段立即返回来执行`finishActivityLocked`方法，此时就是`FINISH_AFTER_PAUSE` 的方式

- `FINISH_AFTER_PAUSE` 把状态设置为`FINISHING `，调用`destroyActivityLocked `开始真正执行onDestroy周期。发送一个Handler消息最后把ActivityRecord从TaskRecord 中移除，如果此时TaskRecord已经不存在ActivityRecord，则从ActivityStack移除

都是在之前的文章详细说过的。

那么，放在这里：
- 如果B在onCreate执行了onDestroy，此时走的就是`FINISH_AFTER_PAUSE`直接finish掉
```java
2020-09-12 23:42:19.043 13942-13942/com.yjy.superjsbridge E/B: onCreate
2020-09-12 23:42:19.921 13942-13942/com.yjy.superjsbridge E/B: onDestroy
```

- onStart周期比较特殊，因为onStart是跟在ResumeActivityItem中间走的，但是执行到了执行完了onStart就设置为finishing状态，导致onResume无法走下去。此时相当于visible还没有设置为true，走的是`FINISH_AFTER_PAUSE`,直接执行onDestroy的周期，注意下面这段代码,此时根据当前`ActivityClientRecord`的标志位来决定是否需要补充执行`onPause`，和`onStop`
```java
    ActivityClientRecord performDestroyActivity(IBinder token, boolean finishing,
            int configChanges, boolean getNonConfigInstance, String reason) {
        ActivityClientRecord r = mActivities.get(token);
        Class<? extends Activity> activityClass = null;
        if (r != null) {
            activityClass = r.activity.getClass();
            r.activity.mConfigChangeFlags |= configChanges;
            if (finishing) {
                r.activity.mFinished = true;
            }

            performPauseActivityIfNeeded(r, "destroy");

            if (!r.stopped) {
                callActivityOnStop(r, false /* saveState */, "destroy");
            }
...
            try {
                r.activity.mCalled = false;
                mInstrumentation.callActivityOnDestroy(r.activity);
...
            } catch (SuperNotCalledException e) {
...
            } catch (Exception e) {
...
            }
            r.setState(ON_DESTROY);
        }
        mActivities.remove(token);
        StrictMode.decrementExpectedActivityCount(activityClass);
        return r;
    }
```

注意，每一次声明周期的执行后,都会调用如下方法：
```java
        public void setState(@LifecycleState int newLifecycleState) {
            mLifecycleState = newLifecycleState;
            switch (mLifecycleState) {
                case ON_CREATE:
                    paused = true;
                    stopped = true;
                    break;
                case ON_START:
                    paused = true;
                    stopped = false;
                    break;
                case ON_RESUME:
                    paused = false;
                    stopped = false;
                    break;
                case ON_PAUSE:
                    paused = true;
                    stopped = false;
                    break;
                case ON_STOP:
                    paused = true;
                    stopped = true;
                    break;
            }
        }
```
能发现`onCreate`执行之后`paused`和`stopped`都是true，所以performDestroyActivity不会补充执行`onPause`,`onStop`直接执行`onDestroy`.

如果是`onStart`执行之后,`paused`为true,`stopped`是false，所以，在`onDestroy补充执行onStop

```java
2020-09-12 23:49:07.902 15359-15359/com.yjy.superjsbridge E/B: onCreate
2020-09-12 23:49:08.066 15359-15359/com.yjy.superjsbridge E/B: onStart
2020-09-12 23:49:08.107 15359-15359/com.yjy.superjsbridge E/B: onStop
2020-09-12 23:49:08.107 15359-15359/com.yjy.superjsbridge E/B: onDestroy
```


如果A在onResume，onPause，onStop方法执行finish,就会走`FINISH_AFTER_VISIBLE` 流程，依次走完剩下的流程再走onDestroy.

onResume 中finish：
```java
020-09-13 10:15:36.193 1071-1071/com.yjy.superjsbridge E/B: onCreate
2020-09-13 10:15:36.813 1071-1071/com.yjy.superjsbridge E/B: onStart
2020-09-13 10:15:36.818 1071-1071/com.yjy.superjsbridge E/B: onResume
2020-09-13 10:15:36.843 1071-1071/com.yjy.superjsbridge E/B: onPause
2020-09-13 10:15:36.860 1071-1071/com.yjy.superjsbridge E/A: onResume
2020-09-13 10:15:36.894 1071-1071/com.yjy.superjsbridge E/B: onStop
2020-09-13 10:15:36.895 1071-1071/com.yjy.superjsbridge E/B: onDestroy
```
onPause 中finish：
```java
E/B: onPause
E/B: onStop
E/B: onDestroy
```

onStop 中finish：
```java
2020-09-13 10:28:10.311 12235-12235/com.yjy.superjsbridge E/B: onPause
2020-09-13 10:28:10.385 12235-12235/com.yjy.superjsbridge E/B: onStop
2020-09-13 10:28:10.654 12235-12235/com.yjy.superjsbridge E/B: onDestroy
```

同理在onRestart也是类似的,因为点击了Home等情况，所以已经执行过了onStop，所以会继续走完下面的周期：
```java
2020-09-13 10:29:43.099 12412-12412/com.yjy.superjsbridge E/B: onRestart
2020-09-13 10:29:43.540 12412-12412/com.yjy.superjsbridge E/B: onDestroy
```

`