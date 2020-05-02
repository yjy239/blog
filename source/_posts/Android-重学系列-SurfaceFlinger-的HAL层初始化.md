---
title: Android 重学系列 SurfaceFlinger 的HAL层初始化
top: false
cover: false
date: 2020-01-21 15:47:28
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---
# 前言
上一篇文章我们研究了SF的初始化。但是还有一个很大也是核心的模块没有聊到，那就是HAL层对应的初始化。什么是HAL层，有简单的话来讲就是硬件驱动和软件之间的中间层，为了更好的兼容Android系统而诞生。

在Android 8.0之后会涉及应用开发及其少接触的一个新类型文件.hal文件。本质上.hal和.aidl文件十分相似，设计初衷和aidl也很相似。aidl为的是Android跨进程通信，而.hal则是为了让android软件层和硬件层通信而做的隔离，因此这种交互方式又称为HIDL。

闲话不多说，我们先来看看hal文件的用法之后，再去看看SF中IComposer，IComposerClient中都做了什么事情。

如果遇到什么问题可以来本文讨论：[https://www.jianshu.com/p/8e29c3d9b27a](https://www.jianshu.com/p/8e29c3d9b27a)


# 正文

在Android 8.0之后，Google为了各大手机厂商的方便，执行了一个名为Treble计划，其目的就是为了让各大手机厂商和硬件商能够在最小代价在Android系统升级的时候，能快速更新硬件相关的特性。

![hal的升级历程.png](https://upload-images.jianshu.io/upload_images/9880421-2fa3022f3f7ffd18.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

大致可以把hal层的历史分为如下3个时期:
- 1.Legacy Hal：Android 8.0 之前版本的 HAL 都是编译成 so，然后动态链接到各个 frameworks service 中去。

- 2.Passthrough Hal：该模式是为了兼容旧版的 HAL，旧版 HAL 实现仍以动态库的方式提供，只是 binder service 链接了动态库 HAL 实现，即 binder service 通过 hw_get_module 链接了旧版的 hal 实现，而用户端通过与 binder service IPC 通信，间接实现了与旧版 HAL 的交互。

- 3.Binderized HAL：HAL 与 用户调用在不同的进程中，HAL 被写成 binder service，而用户接口如 frameworks 作为 binder client 通过 IPC 机制实现跨进程接口调用。这个是 Google 的最终设计目标。

能看到，从历史来看，整个hal层的隔离越来越厉害，越来越接近AIDL的方向设计。因此，Google选择和AIDL的方式，构建一个hal文件，让硬件商和系统只需要关注暴露在hal文件中接口的逻辑即可。

注意一下，这里面的binder 并非是我之前分析的那个Binder，而是hwBinder，不过代码和原理是一摸一样。不过前者负责进程间通信，hwBinder则负责硬件进程和上层进程的通信。

这样设计其实很简单，如果阅读过我的Binder源码解析就能明白，Binder中有一套复杂的事务传输逻辑，如果把硬件驱动也接进来，就没办法达到软件可以快速响应硬件回调或者软件调用硬件。

为了更好的理解HIDL语言，我们可以完全把它当作AIDL这种语言进行类比学习。

本文重点不是hidl的原理，只是作为基础知识和大家介绍。具体的细节，有机会再和大家聊聊。

## hal文件介绍
我们就以IComposer.hal为例子,先来看看2.1版本。
文件:/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[IComposer.hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/IComposer.hal)
```java
package android.hardware.graphics.composer@2.1;

import IComposerClient;

interface IComposer {

    enum Capability : int32_t {
        INVALID = 0,

        SIDEBAND_STREAM = 1,

        SKIP_CLIENT_COLOR_TRANSFORM = 2,

        PRESENT_FENCE_IS_NOT_RELIABLE = 3,
    };

    @entry
    @exit
    @callflow(next="*")
    getCapabilities() generates (vec<Capability> capabilities);

    @entry
    @exit
    @callflow(next="*")
    dumpDebugInfo() generates (string debugInfo);

    @entry
    @callflow(next="*")
    createClient() generates (Error error, IComposerClient client);
};
```
能看到在hal文件中，只能注意的是，我上一篇文章聊到的createClient方法，创建一个IComposerClient对象返回上层。

能看到实际上和aidl十分相似不是吗。当我们把它类比成aidl就特别好理解了。一般的，编写了一个hal文件之后，就需要使用hidl-gen工具，类似aidl一样生成一个真正的cpp文件，里面包含着真正的跨进程通信逻辑，以及相关的接口文件。

当我们写好hal文件之后，并且通过hidl-gen生成的文件中实现接口后，写好Android.bp文件。大致上能得到类似的目录：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-ea17159e346744d4.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
当然这是composer 2.2版本，不过从大体设计看来差距不是很大。

一般的会在default子目录编写好入口方法：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-83cd401972ebe5bd.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到2.2版本下只剩下一个service.cpp。我们再看看2.1版本又是如何：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-dc0cbe1b1cc988e5.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到2.1版本中，多了一个cpp文件passthrough。顾名思义，passthrough就是直通模式，service就是binder service模式。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[default](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/)/[Android.bp](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/Android.bp)

```
cc_library_shared {
    name: "android.hardware.graphics.composer@2.1-impl",
    defaults: ["hidl_defaults"],
    vendor: true,
    relative_install_path: "hw",
    srcs: ["passthrough.cpp"],
    header_libs: [
        "android.hardware.graphics.composer@2.1-passthrough",
    ],
    shared_libs: [
        "android.hardware.graphics.composer@2.1",
        "android.hardware.graphics.mapper@2.0",
        "libbase",
        "libcutils",
        "libfmq",
        "libhardware",
        "libhidlbase",
        "libhidltransport",
        "liblog",
        "libsync",
        "libutils",
        "libhwc2on1adapter",
        "libhwc2onfbadapter",
    ],
    cflags: [
        "-DLOG_TAG=\"ComposerHal\""
    ],
}

cc_binary {
    name: "android.hardware.graphics.composer@2.1-service",
    defaults: ["hidl_defaults"],
    vendor: true,
    relative_install_path: "hw",
    srcs: ["service.cpp"],
    init_rc: ["android.hardware.graphics.composer@2.1-service.rc"],
    shared_libs: [
        "android.hardware.graphics.composer@2.1",
        "libbinder",
        "libhidlbase",
        "libhidltransport",
        "liblog",
        "libsync",
        "libutils",
    ],
}
```
能看到这个bp文件中，有两个cc编译工具，一个是以passthrough.cpp为入口，一个是以service.cpp为入口。也就是说，不同的模式启动Composer，将会打包进不同的入口。

值得注意的一点是，在share_libs一行中已经打包进了实现的so文件android.hardware.graphics.composer@2.1 以及 图元申请工具android.hardware.graphics.mapper@2.0。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[Android.bp](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/Android.bp)
```
hidl_interface {
    name: "android.hardware.graphics.composer@2.1",
    root: "android.hardware",
    vndk: {
        enabled: true,
    },
    srcs: [
        "types.hal",
        "IComposer.hal",
        "IComposerCallback.hal",
        "IComposerClient.hal",
    ],
    interfaces: [
        "android.hardware.graphics.common@1.0",
        "android.hidl.base@1.0",
    ],
    types: [
        "Error",
    ],
    gen_java: false,
}
```
就能看到这个时候就看是引入了我们之前写入的hal文件。在整个Composer的HAL层包含了三个文件，一个在Composer中的是IComposer对象，一个是IComposerClient对象，还有一个是实现了IComposerCallback进行监听刷新屏幕热插拔的ComposerCallbackBridge。全部都囊括在内。

当我们选择的是直通模式，将会到下面这个android.hardware.graphics.composer@2.1-passthrough实现中，而这个对应的bp如下：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/)/[Android.bp](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/Android.bp)
```
cc_library_headers {
    name: "android.hardware.graphics.composer@2.1-passthrough",
    defaults: ["hidl_defaults"],
    vendor: true,
    shared_libs: [
        "libhardware",
        "libhwc2on1adapter",
        "libhwc2onfbadapter",
    ],
    export_shared_lib_headers: [
        "libhardware",
        "libhwc2on1adapter",
        "libhwc2onfbadapter",
    ],
    header_libs: [
        "android.hardware.graphics.composer@2.1-hal",
    ],
    export_header_lib_headers: [
        "android.hardware.graphics.composer@2.1-hal",
    ],
    export_include_dirs: ["include"],
}
```
能看到进一步的引入了hal，以及compser2.2转2.1的adapter等。值得注意的是export_include_dirs这个命令，这个命令是指把这个目录下的头文件全部引入到该模块中,而在这个文件夹中，就是hal硬件抽象层的实现代码。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-f935c4e77cc284a0.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

而这两个文件就是Composer在hal中passthrough模式进入到具体业务的入口。



最后，我们需要在下面如同应用程序注册四大组建一样，注册到Android系统的xml中:
文件：/[device](http://androidxref.com/9.0.0_r3/xref/device/)/[linaro](http://androidxref.com/9.0.0_r3/xref/device/linaro/)/[hikey](http://androidxref.com/9.0.0_r3/xref/device/linaro/hikey/)/[manifest.xml](http://androidxref.com/9.0.0_r3/xref/device/linaro/hikey/manifest.xml)
```xml
    <hal format="hidl">
        <name>android.hardware.graphics.composer</name>
        <transport arch="32+64">passthrough</transport>
        <version>2.1</version>
        <interface>
            <name>IComposer</name>
            <instance>default</instance>
        </interface>
    </hal>
```
能看到的是hikey海思就是这么注册composer的，同时使用的还是passthrough模式。

当然，还有其他的如Google给的案例：
```xml
    <hal format="hidl">
        <name>android.hardware.graphics.composer</name>
        <transport>hwbinder</transport>
        <version>2.1</version>
        <interface>
            <name>IComposer</name>
            <instance>default</instance>
        </interface>
      </hal>
```
这里则是使用Binder的方式注册hal层逻辑。

别忘了最后编写一个rc文件，让init进程解析运行起来：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[default](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/)/[android.hardware.graphics.composer@2.1-service.rc](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/android.hardware.graphics.composer%402.1-service.rc)

```
service vendor.hwcomposer-2-1 /vendor/bin/hw/android.hardware.graphics.composer@2.1-service
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    writepid /dev/cpuset/system-background/tasks

on property:init.svc.surfaceflinger=stopped
    restart vendor.hwcomposer-2-1

```

其实了解这么多就可以了，如果想要全面的了解hidl的使用，不妨阅读下面这片文章：
- [hidl的使用](https://www.cnblogs.com/hellokitty2/p/10598227.html)

如果想要探索hwBinder 进程service的方式是如何把Compser hal进程注册到hwServiceManager，又是如何找到对应的进程的，不妨看看下面这篇文章，写的挺好的：
- [AndroidO Treble架构下Hal进程启动及HIDL服务注册过程](https://blog.csdn.net/yangwen123/article/details/79854267)


当我们有了一定的了解之后，我们可以进行对Composer的HAL进行解析。无论是直通模式还是binder service模式，只是启动方式不一样而已，不影响我们研究整个Composer 的HAL核心机制。

本文就以直通模式来和大家聊聊，其中的原理。

#### 小结 hidl的启动与注册
简单的总结一下，Hal进程的启动和HIDL服务注册的原理:
还记得获得IComposer服务的方式如下：
```cpp
mComposer = V2_1::IComposer::getService(serviceName);
```
通过getService获取。这个函数做的事情有如下几件事情：
- 1.先通过hwservicemanager 查询已经从manifest解析好的数据，先检查该服务需要以哪种形式启动的也就是Transport类型，是hwbinder的绑定模式还是passthrough的直通模式。

- 2.当为hwbinder模式时候，将会从hwservicemanager查询服务

- 3.当为passthrough模式时候，将会从PassthroughServiceManager获取服务

- 4.如果是passthrough启动，则会先先从系统目录下查找有没有对应的so，接着通过dlopen打开so，并用dlsym查找**HIDL_FETCH_I**+interface的名字，也就是HIDL_FETCH_IComposer方法获取IComposer对象，并执行起来。

- 5.拿到IComposer之后，就会注册到hwservicemanager

#### HAL passthrough模式的启动入口
我们先来看IComposer 2.1版本：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[default](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/)/[passthrough.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/default/passthrough.cpp)
```cpp
#include <android/hardware/graphics/composer/2.1/IComposer.h>
#include <composer-passthrough/2.1/HwcLoader.h>

using android::hardware::graphics::composer::V2_1::IComposer;
using android::hardware::graphics::composer::V2_1::passthrough::HwcLoader;

extern "C" IComposer* HIDL_FETCH_IComposer(const char* /* name */) {
    return HwcLoader::load();
}
```
可以看到本质上是HwcLoader调用了load方法实例化出来的。

### HwcLoader使用IComposer 初始化
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/)/[composer-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/2.1/)/[HwcLoader.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/2.1/HwcLoader.h)

```cpp
static IComposer* load() {
        const hw_module_t* module = loadModule();
        if (!module) {
            return nullptr;
        }

        auto hal = createHalWithAdapter(module);
        if (!hal) {
            return nullptr;
        }

        return createComposer(std::move(hal));
    }
```
能从该方法初步看到，IComposer初始化分为三个步骤：
- 1.loadModule 加载hw_module_t 结构体，这个结构体实际上是一个hal模块的结构体。
- 2.createHalWithAdapter 通过hw_module_t 初始化hwc2_device_t结构体，让其拥有和顶层通信的能力也就是函数指针，并且适配2.1和2.2版本
- 3.createComposer 把hwc2_device_t转化为IComposer上传给客户端，也就是SF。

接下来，我们就围绕着着三个方法，来聊聊整个逻辑。

### loadModule 加载 hw_module_t
```cpp
#define HWC_HARDWARE_MODULE_ID "hwcomposer"
```

```cpp
#define GRALLOC_HARDWARE_MODULE_ID "gralloc"
```

```cpp
    // load hwcomposer2 module
    static const hw_module_t* loadModule() {
        const hw_module_t* module;
        int error = hw_get_module(HWC_HARDWARE_MODULE_ID, &module);
        if (error) {
            ALOGI("falling back to gralloc module");
            error = hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module);
        }

        if (error) {
            ALOGE("failed to get hwcomposer or gralloc module");
            return nullptr;
        }

        return module;
    }
```
能看到这个过程中会调用hw_get_module尝试获取对应名字的模块hwcomposer，如果获取不到则退化成gralloc，整个机制也就蜕化成HWC还没有出现之前的版本.我们先不去探索失败，我们来看看成功。

#### hw_get_module 查找 hw_module_t
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[libhardware](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware/)/[hardware.c](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware/hardware.c)
```cpp
int hw_get_module_by_class(const char *class_id, const char *inst,
                           const struct hw_module_t **module)
{

...

found:
    /* load the module, if this fails, we're doomed, and we should not try
     * to load a different variant. */
    return load(class_id, path, module);
}

int hw_get_module(const char *id, const struct hw_module_t **module)
{
    return hw_get_module_by_class(id, NULL, module);
}
```
这个过程会根据传进来的id名字来查找是否已经有如下几个路径下的so，
```
#define HAL_LIBRARY_PATH1 "/system/lib64/hw"
#define HAL_LIBRARY_PATH2 "/vendor/lib64/hw"
#define HAL_LIBRARY_PATH3 "/odm/lib64/hw"
#else
#define HAL_LIBRARY_PATH1 "/system/lib/hw"
#define HAL_LIBRARY_PATH2 "/vendor/lib/hw"
#define HAL_LIBRARY_PATH3 "/odm/lib/hw"
```
找到了则执行load方法：
```cpp
static int load(const char *id,
        const char *path,
        const struct hw_module_t **pHmi)
{
    int status = -EINVAL;
    void *handle = NULL;
    struct hw_module_t *hmi = NULL;
#ifdef __ANDROID_VNDK__
    const bool try_system = false;
#else
    const bool try_system = true;
#endif

    /*
     * load the symbols resolving undefined symbols before
     * dlopen returns. Since RTLD_GLOBAL is not or'd in with
     * RTLD_NOW the external symbols will not be global
     */
    if (try_system &&
        strncmp(path, HAL_LIBRARY_PATH1, strlen(HAL_LIBRARY_PATH1)) == 0) {
        /* If the library is in system partition, no need to check
         * sphal namespace. Open it with dlopen.
         */
        handle = dlopen(path, RTLD_NOW);
    } else {
        handle = android_load_sphal_library(path, RTLD_NOW);
    }
    if (handle == NULL) {
        char const *err_str = dlerror();
        ALOGE("load: module=%s\n%s", path, err_str?err_str:"unknown");
        status = -EINVAL;
        goto done;
    }

    /* Get the address of the struct hal_module_info. */
    const char *sym = HAL_MODULE_INFO_SYM_AS_STR;
    hmi = (struct hw_module_t *)dlsym(handle, sym);
    if (hmi == NULL) {
        ALOGE("load: couldn't find symbol %s", sym);
        status = -EINVAL;
        goto done;
    }

    /* Check that the id matches */
    if (strcmp(id, hmi->id) != 0) {
        ALOGE("load: id=%s != hmi->id=%s", id, hmi->id);
        status = -EINVAL;
        goto done;
    }

    hmi->dso = handle;

    /* success */
    status = 0;

    done:
    if (status != 0) {
        hmi = NULL;
        if (handle != NULL) {
            dlclose(handle);
            handle = NULL;
        }
    } else {
        ALOGV("loaded HAL id=%s path=%s hmi=%p handle=%p",
                id, path, *pHmi, handle);
    }

    *pHmi = hmi;

    return status;
}
```
如果没有打开，则执行dlopen拿到对应so的句柄，接着同dlsym查找HMI字符，这个字符所指向的内存地址就是我们所说的hw_module_t.换算到现在名字可能是hwcomposer.xx.so

我们随便挑选一个作为源码解析，就以msm8960为例子：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc.cpp)

```cpp
static struct hw_module_methods_t hwc_module_methods = {
    open: hwc_device_open
};

hwc_module_t HAL_MODULE_INFO_SYM = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .version_major = 2,
        .version_minor = 0,
        .id = HWC_HARDWARE_MODULE_ID,
        .name = "Qualcomm Hardware Composer Module",
        .author = "CodeAurora Forum",
        .methods = &hwc_module_methods,
        .dso = 0,
        .reserved = {0},
    }
};
```

这样就能找到hwc_module_t对应在底层的结构体。


### createHalWithAdapter 生成hw_device_t
```cpp
  // create a ComposerHal instance, insert an adapter if necessary
    static std::unique_ptr<hal::ComposerHal> createHalWithAdapter(const hw_module_t* module) {
        bool adapted;
        hwc2_device_t* device = openDeviceWithAdapter(module, &adapted);
        if (!device) {
            return nullptr;
        }
        auto hal = std::make_unique<HwcHal>();
        return hal->initWithDevice(std::move(device), !adapted) ? std::move(hal) : nullptr;
    }
```
这个过程做了两件事情，第一件事情就是openDeviceWithAdapter初始化hwc2_device_t，第二件事情就是实例化HwcHal对象并且设置hwc2_device_t。

```cpp
    static hwc2_device_t* openDeviceWithAdapter(const hw_module_t* module, bool* outAdapted) {
        if (module->id && std::string(module->id) == GRALLOC_HARDWARE_MODULE_ID) {
            *outAdapted = true;
            return adaptGrallocModule(module);
        }

        hw_device_t* device;
        int error = module->methods->open(module, HWC_HARDWARE_COMPOSER, &device);
        if (error) {
            ALOGE("failed to open hwcomposer device: %s", strerror(-error));
            return nullptr;
        }

        int major = (device->version >> 24) & 0xf;
        if (major != 2) {
            *outAdapted = true;
            return adaptHwc1Device(std::move(reinterpret_cast<hwc_composer_device_1*>(device)));
        }

        *outAdapted = false;
        return reinterpret_cast<hwc2_device_t*>(device);
    }
```
能够看到，如果失败则会调用adaptGrallocModule，初始化的是gralloc的hal模块。成果则会调用hw_module_t中的open方法。判断如果当前主版本不是2，则调用adaptHwc1Device适配hw_device_t，最后返回。

这里需要注意一点hw_device_t，会被向下转型成hwc_composer_device_1对象后传入adaptHwc1Device。其原理和类的继承很相似，因为hwc_composer_device_1包裹了一个hw_device_t。又因为struct是连续分配的空间，这样才能够强转(这种设计在socket系统调用到处都是)。
```cpp
typedef struct hwc_composer_device_1 {
   
    struct hw_device_t common;


    int (*prepare)(struct hwc_composer_device_1 *dev,
                    size_t numDisplays, hwc_display_contents_1_t** displays);

    int (*set)(struct hwc_composer_device_1 *dev,
                size_t numDisplays, hwc_display_contents_1_t** displays);

    int (*eventControl)(struct hwc_composer_device_1* dev, int disp,
            int event, int enabled);

    union {
      
        int (*blank)(struct hwc_composer_device_1* dev, int disp, int blank);

        int (*setPowerMode)(struct hwc_composer_device_1* dev, int disp,
                int mode);
    };


    int (*query)(struct hwc_composer_device_1* dev, int what, int* value);


    void (*dump)(struct hwc_composer_device_1* dev, char *buff, int buff_len);

    int (*getDisplayConfigs)(struct hwc_composer_device_1* dev, int disp,
            uint32_t* configs, size_t* numConfigs);

    int (*getDisplayAttributes)(struct hwc_composer_device_1* dev, int disp,
            uint32_t config, const uint32_t* attributes, int32_t* values);

    int (*getActiveConfig)(struct hwc_composer_device_1* dev, int disp);

    int (*setActiveConfig)(struct hwc_composer_device_1* dev, int disp,
            int index);

    int (*setCursorPositionAsync)(struct hwc_composer_device_1 *dev, int disp, int x_pos, int y_pos);

    void* reserved_proc[1];

} hwc_composer_device_1_t;
```


在上文能看到此时open的方法，指向的是hwc_device_open函数指针。

##### hwc_device_open 初始化hw_device_t
```cpp
static int hwc_device_open(const struct hw_module_t* module, const char* name,
                           struct hw_device_t** device)
{
    int status = -EINVAL;

    if (!strcmp(name, HWC_HARDWARE_COMPOSER)) {
        struct hwc_context_t *dev;
        dev = (hwc_context_t*)malloc(sizeof(*dev));
        memset(dev, 0, sizeof(*dev));

        //Initialize hwc context
        initContext(dev);

        //Setup HWC methods
        dev->device.common.tag          = HARDWARE_DEVICE_TAG;
        dev->device.common.version      = HWC_DEVICE_API_VERSION_1_2;
        dev->device.common.module       = const_cast<hw_module_t*>(module);
        dev->device.common.close        = hwc_device_close;
        dev->device.prepare             = hwc_prepare;
        dev->device.set                 = hwc_set;
        dev->device.eventControl        = hwc_eventControl;
        dev->device.blank               = hwc_blank;
        dev->device.query               = hwc_query;
        dev->device.registerProcs       = hwc_registerProcs;
        dev->device.dump                = hwc_dump;
        dev->device.getDisplayConfigs   = hwc_getDisplayConfigs;
        dev->device.getDisplayAttributes = hwc_getDisplayAttributes;
        *device = &dev->device.common;
        status = 0;
    }
    return status;
}
```
能看到在这个方法中，为hw_device_t这个结构体每一个函数指针都真正赋予了其含义，最后所有的hal层执行都会走到hwc.cpp这里。

这里要注意了version的计算并不是上面那个version_major,而是HWC_DEVICE_API_VERSION_1_2。其实他的计算如下
```cpp
define HWC_DEVICE_API_VERSION_1_2  HARDWARE_DEVICE_API_VERSION_2(1, 2, HWC_HEADER_VERSION)
```
```cpp
#define HARDWARE_MAKE_API_VERSION_2(maj,min,hdr) \
            ((((maj) & 0xff) << 24) | (((min) & 0xff) << 16) | ((hdr) & 0xffff))
```
很有误导性，其实是1在高24位，5在低16位，最后一个是头信息。因此是其实1.2版本，而不是版本2。


所以接下来会走到适配的分之adaptHwc1Device。


#### adaptHwc1Device 适配hwc2_device_t
```cpp
    static hwc2_device_t* adaptHwc1Device(hwc_composer_device_1* device) {
        int minor = (device->common.version >> 16) & 0xf;
        if (minor < 1) {
            ALOGE("hwcomposer 1.0 is not supported");
            device->common.close(&device->common);
            return nullptr;
        }

        return new HWC2On1Adapter(device);
    }
```
能看到小版本小于1则非法，只会适配大于等于的版本，就会生成一个HWC2On1Adapter对象。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hwc2on1adapter](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/)/[HWC2On1Adapter.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/HWC2On1Adapter.cpp)

其实这个对象就是hwc2_device_t：
```cpp
class HWC2On1Adapter : public hwc2_device_t
```
我们来看看他的构造函数。

```cpp
HWC2On1Adapter::HWC2On1Adapter(hwc_composer_device_1_t* hwc1Device)
  : mDumpString(),
    mHwc1Device(hwc1Device),
    mHwc1MinorVersion(getMinorVersion(hwc1Device)),
    mHwc1SupportsVirtualDisplays(false),
    mHwc1SupportsBackgroundColor(false),
    mHwc1Callbacks(std::make_unique<Callbacks>(*this)),
    mCapabilities(),
    mLayers(),
    mHwc1VirtualDisplay(),
    mStateMutex(),
    mCallbacks(),
    mHasPendingInvalidate(false),
    mPendingVsyncs(),
    mPendingHotplugs(),
    mDisplays(),
    mHwc1DisplayMap()
{
    common.close = closeHook;
    getCapabilities = getCapabilitiesHook;
    getFunction = getFunctionHook;
    populateCapabilities();
    populatePrimary();
    mHwc1Device->registerProcs(mHwc1Device,
            static_cast<const hwc_procs_t*>(mHwc1Callbacks.get()));
}
```
在这里面设置两个很核心的东西一个是getFunctionHook，一个调用了hwc_device_t的registerProcs方法。

前者是一个模版方法，调用hwc_device_t中方法指针。后者是hal层注册监听驱动的核心逻辑。

首先看看mHwc1Callbacks实际上是HWC2On1Adapter::Callbacks：
```cpp
class HWC2On1Adapter::Callbacks : public hwc_procs_t {
    public:
        explicit Callbacks(HWC2On1Adapter& adapter) : mAdapter(adapter) {
            invalidate = &invalidateHook;
            vsync = &vsyncHook;
            hotplug = &hotplugHook;
        }

        static void invalidateHook(const hwc_procs_t* procs) {
            auto callbacks = static_cast<const Callbacks*>(procs);
            callbacks->mAdapter.hwc1Invalidate();
        }

        static void vsyncHook(const hwc_procs_t* procs, int display,
                int64_t timestamp) {
            auto callbacks = static_cast<const Callbacks*>(procs);
            callbacks->mAdapter.hwc1Vsync(display, timestamp);
        }

        static void hotplugHook(const hwc_procs_t* procs, int display,
                int connected) {
            auto callbacks = static_cast<const Callbacks*>(procs);
            callbacks->mAdapter.hwc1Hotplug(display, connected);
        }

    private:
        HWC2On1Adapter& mAdapter;
};
```
可以看到三个十分熟悉的回调，invalidate，vsync，hotplug。那么其实这个回调就是从底层驱动程序上传第一个回调，之后才有其他的。每个方法又会调用HWC2On1Adapter对应的回调方法。

记住，在这里面同时把hwc_procs_t三个函数指针invalidate，vsync，hotplug都指向了这个回调中的方法。换句话说所有从底层响应上来，都该类中调用所有的回调，最终都会汇总到这个Callback。

我们暂时把流程停在这里，稍后让我把监听的接进来，再去更加底层看看是怎么回事？

#### HwcHal的初始化
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/)/[composer-passthrough](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/2.1/)/[HwcHal.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/passthrough/include/composer-passthrough/2.1/HwcHal.h)
```cpp
namespace android {
namespace hardware {
namespace graphics {
namespace composer {
namespace V2_1 {
namespace passthrough {

namespace detail {

using android::hardware::graphics::common::V1_0::ColorMode;
using android::hardware::graphics::common::V1_0::ColorTransform;
using android::hardware::graphics::common::V1_0::Dataspace;
using android::hardware::graphics::common::V1_0::Hdr;
using android::hardware::graphics::common::V1_0::PixelFormat;
using android::hardware::graphics::common::V1_0::Transform;

// HwcHalImpl implements V2_*::hal::ComposerHal on top of hwcomposer2
template <typename Hal>
class HwcHalImpl : public Hal {
   public:
    virtual ~HwcHalImpl() {
        if (mDevice) {
            hwc2_close(mDevice);
        }
    }

...
    bool initWithDevice(hwc2_device_t* device, bool requireReliablePresentFence) {
        // we own the device from this point on
        mDevice = device;

        initCapabilities();
        if (requireReliablePresentFence &&
            hasCapability(HWC2_CAPABILITY_PRESENT_FENCE_IS_NOT_RELIABLE)) {
            ALOGE("present fence must be reliable");
            mDevice->common.close(&mDevice->common);
            mDevice = nullptr;
            return false;
        }

        if (!initDispatch()) {
            mDevice->common.close(&mDevice->common);
            mDevice = nullptr;
            return false;
        }

        return true;
    }

...

}  // namespace detail

using HwcHal = detail::HwcHalImpl<hal::ComposerHal>;

}  // namespace passthrough
}  // namespace V2_1
}  // namespace composer
}  // namespace graphics
}  // namespace hardware
}  // namespace android
```
HwcHalImpl 本质上就是继承hal::ComposerHal，也就是说ComposerHal持有
将会持有一个hw_device_t结构体，作为真正的操作对象。

第二点，调用initDispatch，为mDispatch结构体中所有的函数指针都初始化。之后所有调用函数都是是通过mDispatch调用hw_device_t的方法
```c
    struct {
        HWC2_PFN_ACCEPT_DISPLAY_CHANGES acceptDisplayChanges;
        HWC2_PFN_CREATE_LAYER createLayer;
        HWC2_PFN_CREATE_VIRTUAL_DISPLAY createVirtualDisplay;
        HWC2_PFN_DESTROY_LAYER destroyLayer;
        HWC2_PFN_DESTROY_VIRTUAL_DISPLAY destroyVirtualDisplay;
        HWC2_PFN_DUMP dump;
        HWC2_PFN_GET_ACTIVE_CONFIG getActiveConfig;
        HWC2_PFN_GET_CHANGED_COMPOSITION_TYPES getChangedCompositionTypes;
        HWC2_PFN_GET_CLIENT_TARGET_SUPPORT getClientTargetSupport;
        HWC2_PFN_GET_COLOR_MODES getColorModes;
        HWC2_PFN_GET_DISPLAY_ATTRIBUTE getDisplayAttribute;
        HWC2_PFN_GET_DISPLAY_CONFIGS getDisplayConfigs;
        HWC2_PFN_GET_DISPLAY_NAME getDisplayName;
        HWC2_PFN_GET_DISPLAY_REQUESTS getDisplayRequests;
        HWC2_PFN_GET_DISPLAY_TYPE getDisplayType;
        HWC2_PFN_GET_DOZE_SUPPORT getDozeSupport;
        HWC2_PFN_GET_HDR_CAPABILITIES getHdrCapabilities;
        HWC2_PFN_GET_MAX_VIRTUAL_DISPLAY_COUNT getMaxVirtualDisplayCount;
        HWC2_PFN_GET_RELEASE_FENCES getReleaseFences;
        HWC2_PFN_PRESENT_DISPLAY presentDisplay;
        HWC2_PFN_REGISTER_CALLBACK registerCallback;
        HWC2_PFN_SET_ACTIVE_CONFIG setActiveConfig;
        HWC2_PFN_SET_CLIENT_TARGET setClientTarget;
        HWC2_PFN_SET_COLOR_MODE setColorMode;
        HWC2_PFN_SET_COLOR_TRANSFORM setColorTransform;
        HWC2_PFN_SET_CURSOR_POSITION setCursorPosition;
        HWC2_PFN_SET_LAYER_BLEND_MODE setLayerBlendMode;
        HWC2_PFN_SET_LAYER_BUFFER setLayerBuffer;
        HWC2_PFN_SET_LAYER_COLOR setLayerColor;
        HWC2_PFN_SET_LAYER_COMPOSITION_TYPE setLayerCompositionType;
        HWC2_PFN_SET_LAYER_DATASPACE setLayerDataspace;
        HWC2_PFN_SET_LAYER_DISPLAY_FRAME setLayerDisplayFrame;
        HWC2_PFN_SET_LAYER_PLANE_ALPHA setLayerPlaneAlpha;
        HWC2_PFN_SET_LAYER_SIDEBAND_STREAM setLayerSidebandStream;
        HWC2_PFN_SET_LAYER_SOURCE_CROP setLayerSourceCrop;
        HWC2_PFN_SET_LAYER_SURFACE_DAMAGE setLayerSurfaceDamage;
        HWC2_PFN_SET_LAYER_TRANSFORM setLayerTransform;
        HWC2_PFN_SET_LAYER_VISIBLE_REGION setLayerVisibleRegion;
        HWC2_PFN_SET_LAYER_Z_ORDER setLayerZOrder;
        HWC2_PFN_SET_OUTPUT_BUFFER setOutputBuffer;
        HWC2_PFN_SET_POWER_MODE setPowerMode;
        HWC2_PFN_SET_VSYNC_ENABLED setVsyncEnabled;
        HWC2_PFN_VALIDATE_DISPLAY validateDisplay;
    } mDispatch = {};
```

### createComposer 构建IComposer对象
```c
    static IComposer* createComposer(std::unique_ptr<hal::ComposerHal> hal) {
        return hal::Composer::create(std::move(hal)).release();
    }
```

文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[Composer.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/Composer.h)
```c
    static std::unique_ptr<ComposerImpl> create(std::unique_ptr<Hal> hal) {
        return std::make_unique<ComposerImpl>(std::move(hal));
    }
```
很简单，本质上就是一个ComposerImpl持有了ComposerHal。

嵌套的层级有点深，接下来让我把整个UML图画出来就清晰了，再结合一下上一篇文章，梳理一下。
![HWC关键数据结构.jpg](https://upload-images.jianshu.io/upload_images/9880421-36b6605c236800a7.jpg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)




### Composer初始化中Hal的工作
在上一篇文章中有两个hal方法没有进一步的聊，第一个是createClient创建IComposerClient，另一个是注册监听。

#### Composer创建ComposerClient
我们先把视角转移到
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[ComposerHal.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/ComposerHal.cpp)

```cpp
Composer::Composer(const std::string& serviceName)
    : mWriter(kWriterInitialSize),
      mIsUsingVrComposer(serviceName == std::string("vr"))
{
    mComposer = V2_1::IComposer::getService(serviceName);

    mComposer->createClient(
            [&](const auto& tmpError, const auto& tmpClient)
            {
                if (tmpError == Error::NONE) {
                    mClient = tmpClient;
                }
            });
...

    // 2.2 support is optional
    sp<IComposer> composer_2_2 = IComposer::castFrom(mComposer);
    if (composer_2_2 != nullptr) {
        mClient_2_2 = IComposerClient::castFrom(mClient);
...
    }
}
```
mComposer通过getService拿到hal层的IComposer对象。

文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[Composer.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/Composer.h)
```cpp
    Return<void> createClient(IComposer::createClient_cb hidl_cb) override {
        std::unique_lock<std::mutex> lock(mClientMutex);
        if (!waitForClientDestroyedLocked(lock)) {
            hidl_cb(Error::NO_RESOURCES, nullptr);
            return Void();
        }

        sp<IComposerClient> client = createClient();
        if (!client) {
            hidl_cb(Error::NO_RESOURCES, nullptr);
            return Void();
        }

        mClient = client;
        hidl_cb(Error::NONE, client);
        return Void();
    }

    void onClientDestroyed() {
        std::lock_guard<std::mutex> lock(mClientMutex);
        mClient.clear();
        mClientDestroyedCondition.notify_all();
    }

    virtual IComposerClient* createClient() {
        auto client = ComposerClient::create(mHal.get());
        if (!client) {
            return nullptr;
        }

        auto clientDestroyed = [this]() { onClientDestroyed(); };
        client->setOnClientDestroyed(clientDestroyed);

        return client.release();
    }
```
实际上还是调用了ComposerClient::create方法实例化一个IComposerClient方法，接着才会把这个这个方法通过回调回调出去。同时让Composer持有一个mClient对象，当销毁的时候，会调用mClient的clear方法，并且唤起阻塞。也就是指销毁一个HWC::Device的mClient对象。

接下来看看ComposerClient的create方法：
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[ComposerClient.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/ComposerClient.h)

```cpp
    static std::unique_ptr<ComposerClientImpl> create(Hal* hal) {
        auto client = std::make_unique<ComposerClientImpl>(hal);
        return client->init() ? std::move(client) : nullptr;
    }

    bool init() {
        mResources = createResources();
        if (!mResources) {
            ALOGE("failed to create composer resources");
            return false;
        }

        mCommandEngine = createCommandEngine();

        return true;
    }

    virtual std::unique_ptr<ComposerResources> createResources() {
        return ComposerResources::create();
    }

    virtual std::unique_ptr<ComposerCommandEngine> createCommandEngine() {
        return std::make_unique<ComposerCommandEngine>(mHal, mResources.get());
    }
```
能看到Client会持有两个对象，一个是ComposerResources，一个是ComposerCommandEngine。

- ComposerResources 控制整个SF的Hal的资源，如绘制面Layer，如图元
- ComposerCommandEngine 处理从SF上层到hal层的一些命令，用来实现一些需要直接通信到驱动的命令。


#### ComposerResources 初始化
```cpp
 static std::unique_ptr<ComposerResources> create() {
        auto resources = std::make_unique<ComposerResources>();
        return resources->init() ? std::move(resources) : nullptr;
    }

    bool init() { return mImporter.init(); }
```
在ComposerResources初始化的同时，还会初始化ComposerHandleImporter对象。
```cpp
class ComposerHandleImporter {
   public:
    bool init() {
        mMapper = mapper::V2_0::IMapper::getService();
        return mMapper != nullptr;
    }
```
该对象初始化了一个IMapper的Hal服务，其实该Hal服务就是图元申请器。换句话说Composer将会通过ComposerResources调用ComposerHandleImporter控制图元的状态。


#### ComposerCommandEngine 初始化
```cpp
    ComposerCommandEngine(ComposerHal* hal, ComposerResources* resources)
        : mHal(hal), mResources(resources) {}
```
这个对象等到用的时候再去理解。

这两个对象很重要，记住就好，后面会和它们打交道。

#### IComposer通过注册监听Hal层实现监听驱动的关键动作
还记得在SF的init方法中，我们还注册了一个Callback到Hal层中:
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[HWC2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWC2.cpp)

```cpp
void Device::registerCallback(ComposerCallback* callback, int32_t sequenceId) {
    if (mRegisteredCallback) {
        ALOGW("Callback already registered. Ignored extra registration "
                "attempt.");
        return;
    }
    mRegisteredCallback = true;
    sp<ComposerCallbackBridge> callbackBridge(
            new ComposerCallbackBridge(callback, sequenceId));
    mComposer->registerCallback(callbackBridge);
}
```
Device中的mComposer，其实是Composer，而这个对象才是统一处理HIDL对应在客户端的对象。

```cpp
void Composer::registerCallback(const sp<IComposerCallback>& callback)
{
    auto ret = mClient->registerCallback(callback);
    if (!ret.isOk()) {
        ALOGE("failed to register IComposerCallback");
    }
}
```

文件:/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[ComposerClient.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/ComposerClient.h)

```cpp
    Return<void> registerCallback(const sp<IComposerCallback>& callback) override {
        // no locking as we require this function to be called only once
        mHalEventCallback = std::make_unique<HalEventCallback>(callback, mResources.get());
        mHal->registerEventCallback(mHalEventCallback.get());
        return Void();
    }
```
能看到在这里面会把IComposerCallback再一次包裹成HalEventCallback对象，才会注册到mHal，也就是HwcHalImpl对象。

来看看HalEventCallback这个包裹类：
```cpp
    class HalEventCallback : public Hal::EventCallback {
       public:
        HalEventCallback(const sp<IComposerCallback> callback, ComposerResources* resources)
            : mCallback(callback), mResources(resources) {}

        void onHotplug(Display display, IComposerCallback::Connection connected) {
            if (connected == IComposerCallback::Connection::CONNECTED) {
                mResources->addPhysicalDisplay(display);
            } else if (connected == IComposerCallback::Connection::DISCONNECTED) {
                mResources->removeDisplay(display);
            }

            auto ret = mCallback->onHotplug(display, connected);
            ALOGE_IF(!ret.isOk(), "failed to send onHotplug: %s", ret.description().c_str());
        }

        void onRefresh(Display display) {
            auto ret = mCallback->onRefresh(display);
            ALOGE_IF(!ret.isOk(), "failed to send onRefresh: %s", ret.description().c_str());
        }

        void onVsync(Display display, int64_t timestamp) {
            auto ret = mCallback->onVsync(display, timestamp);
            ALOGE_IF(!ret.isOk(), "failed to send onVsync: %s", ret.description().c_str());
        }

       protected:
        const sp<IComposerCallback> mCallback;
        ComposerResources* const mResources;
    };
```
这个方法本质上就是为了集中IComposerCallback和mResources处理。在HalEventCallback中对应每一种回调都有自己的方法，他除了会调用IComposerCallback对应的回调之外，还会特别处理屏幕的热插拔，如果是插入则将一个屏幕对象添加到ComposerResources，进行管理。


```cpp
    void registerEventCallback(hal::ComposerHal::EventCallback* callback) override {
        mMustValidateDisplay = true;
        mEventCallback = callback;

        mDispatch.registerCallback(mDevice, HWC2_CALLBACK_HOTPLUG, this,
                                   reinterpret_cast<hwc2_function_pointer_t>(hotplugHook));
        mDispatch.registerCallback(mDevice, HWC2_CALLBACK_REFRESH, this,
                                   reinterpret_cast<hwc2_function_pointer_t>(refreshHook));
        mDispatch.registerCallback(mDevice, HWC2_CALLBACK_VSYNC, this,
                                   reinterpret_cast<hwc2_function_pointer_t>(vsyncHook));
    }
```
此时将会调用mDispatch的registerCallback方法。其实这个方法是一个模版方法，其实就是调用mDevice的registerCallback方法，并且把后面几个作为参数设置进去。

从上文就解析到mDevice其实是hw2_device_t结构体也是HWC2On1Adapter，那么其实就是调用HWC2On1Adapter中的注册方法。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hwc2on1adapter](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/include/)/[hwc2on1adapter](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/include/hwc2on1adapter/)/[HWC2On1Adapter.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hwc2on1adapter/include/hwc2on1adapter/HWC2On1Adapter.h)

```cpp
Error HWC2On1Adapter::registerCallback(Callback descriptor,
        hwc2_callback_data_t callbackData, hwc2_function_pointer_t pointer) {
    if (!isValid(descriptor)) {
        return Error::BadParameter;
    }


    std::unique_lock<std::recursive_timed_mutex> lock(mStateMutex);

    if (pointer != nullptr) {
        mCallbacks[descriptor] = {callbackData, pointer};
    } else {
        ALOGI("unregisterCallback(%s)", to_string(descriptor).c_str());
        mCallbacks.erase(descriptor);
        return Error::None;
    }

    bool hasPendingInvalidate = false;
    std::vector<hwc2_display_t> displayIds;
    std::vector<std::pair<hwc2_display_t, int64_t>> pendingVsyncs;
    std::vector<std::pair<hwc2_display_t, int>> pendingHotplugs;

    if (descriptor == Callback::Refresh) {
        hasPendingInvalidate = mHasPendingInvalidate;
        if (hasPendingInvalidate) {
            for (auto& displayPair : mDisplays) {
                displayIds.emplace_back(displayPair.first);
            }
        }
        mHasPendingInvalidate = false;
    } else if (descriptor == Callback::Vsync) {
        for (auto pending : mPendingVsyncs) {
            auto hwc1DisplayId = pending.first;
            if (mHwc1DisplayMap.count(hwc1DisplayId) == 0) {
                ALOGE("hwc1Vsync: Couldn't find display for HWC1 id %d",
                        hwc1DisplayId);
                continue;
            }
            auto displayId = mHwc1DisplayMap[hwc1DisplayId];
            auto timestamp = pending.second;
            pendingVsyncs.emplace_back(displayId, timestamp);
        }
        mPendingVsyncs.clear();
    } else if (descriptor == Callback::Hotplug) {
        // Hotplug the primary display
        pendingHotplugs.emplace_back(mHwc1DisplayMap[HWC_DISPLAY_PRIMARY],
                static_cast<int32_t>(Connection::Connected));

        for (auto pending : mPendingHotplugs) {
            auto hwc1DisplayId = pending.first;
            if (mHwc1DisplayMap.count(hwc1DisplayId) == 0) {
                ALOGE("hwc1Hotplug: Couldn't find display for HWC1 id %d",
                        hwc1DisplayId);
                continue;
            }
            auto displayId = mHwc1DisplayMap[hwc1DisplayId];
            auto connected = pending.second;
            pendingHotplugs.emplace_back(displayId, connected);
        }
    }

    // Call pending callbacks without the state lock held
    lock.unlock();

    if (hasPendingInvalidate) {
        auto refresh = reinterpret_cast<HWC2_PFN_REFRESH>(pointer);
        for (auto displayId : displayIds) {
            refresh(callbackData, displayId);
        }
    }
    if (!pendingVsyncs.empty()) {
        auto vsync = reinterpret_cast<HWC2_PFN_VSYNC>(pointer);
        for (auto& pendingVsync : pendingVsyncs) {
            vsync(callbackData, pendingVsync.first, pendingVsync.second);
        }
    }
    if (!pendingHotplugs.empty()) {
        auto hotplug = reinterpret_cast<HWC2_PFN_HOTPLUG>(pointer);
        for (auto& pendingHotplug : pendingHotplugs) {
            hotplug(callbackData, pendingHotplug.first, pendingHotplug.second);
        }
    }
    return Error::None;
}
```
能看到有2个集合，一个标志位在Hal判断是否需要回调当顶层。当mPendingHotplugs存在还没有被通知的屏幕热插拔消息的时候将会调用hotplug；当mPendingVsyncs存在还没有通知到的屏幕的同步也会调用vsync；如果需要刷新则会有hasPendingInvalidate设置true的标志。

但是，如果是SF第一次进来就肯定不会有回调，因为此时还没有任何的拿到底层的任何数据。但是会把当前的监听类型和回调的方法指针都保存到mCallbacks数组中。

此时就会直接转型为每一个回调到上层，此时就是HwcHalImpl中的refreshHook，hotplugHook，vsyncHook。


#### HwcHalImpl refreshHook
```cpp
    static void refreshHook(hwc2_callback_data_t callbackData, hwc2_display_t display) {
        auto hal = static_cast<HwcHalImpl*>(callbackData);
        hal->mMustValidateDisplay = true;
        hal->mEventCallback->onRefresh(display);
    }
```
此时就会回调到IComposerClient的HalEventCallback。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[ComposerClient.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/ComposerClient.h)

```cpp
        void onRefresh(Display display) {
            auto ret = mCallback->onRefresh(display);
        }
```
这个Callback就是上层的ComposerCallbackBridge
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[HWC2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWC2.cpp)

```cpp
    Return<void> onRefresh(Hwc2::Display display) override
    {
        mCallback->onRefreshReceived(mSequenceId, display);
        return Void();
    }
```
而这个Callback就是SF。此时就会走到SF的页面刷新
```cpp
void SurfaceFlinger::onRefreshReceived(int sequenceId,
                                       hwc2_display_t /*display*/) {
    Mutex::Autolock lock(mStateLock);
    if (sequenceId != getBE().mComposerSequenceId) {
        return;
    }
    repaintEverything();
}
```
repaintEverything这个方法将会更新所有Layer中的图元。具体是什么意思，在之后的文章将会和大家聊聊

##### HwcHalImpl vsyncHook

```cpp
    static void vsyncHook(hwc2_callback_data_t callbackData, hwc2_display_t display,
                          int64_t timestamp) {
        auto hal = static_cast<HwcHalImpl*>(callbackData);
        hal->mEventCallback->onVsync(display, timestamp);
    }
```

##### HalEventCallback onVsync
```cpp
        void onVsync(Display display, int64_t timestamp) {
            auto ret = mCallback->onVsync(display, timestamp);
        }
```

##### ComposerCallbackBridge onVsync
```cpp
    Return<void> onVsync(Hwc2::Display display, int64_t timestamp) override
    {
        mCallback->onVsyncReceived(mSequenceId, display, timestamp);
        return Void();
    }
```
最后就会走到SF中的回调
```cpp
void SurfaceFlinger::onVsyncReceived(int32_t sequenceId,
        hwc2_display_t displayId, int64_t timestamp) {
    Mutex::Autolock lock(mStateLock);
    // Ignore any vsyncs from a previous hardware composer.
    if (sequenceId != getBE().mComposerSequenceId) {
        return;
    }

    int32_t type;
    if (!getBE().mHwc->onVsync(displayId, timestamp, &type)) {
        return;
    }

    bool needsHwVsync = false;

    { // Scope for the lock
        Mutex::Autolock _l(mHWVsyncLock);
        if (type == DisplayDevice::DISPLAY_PRIMARY && mPrimaryHWVsyncEnabled) {
            needsHwVsync = mPrimaryDispSync.addResyncSample(timestamp);
        }
    }

    if (needsHwVsync) {
        enableHardwareVsync();
    } else {
        disableHardwareVsync(false);
    }
}
```
在这个回调中，会从硬件传来一个时间戳，对整个Vsync进行一次调整。究竟是怎么一个逻辑，我将放在后面的文章来聊。

本文最重要将会关注屏幕热插拔的回调。

#### HwcHalImpl hotplugHook
```
    static void hotplugHook(hwc2_callback_data_t callbackData, hwc2_display_t display,
                            int32_t connected) {
        auto hal = static_cast<HwcHalImpl*>(callbackData);
        hal->mEventCallback->onHotplug(display,
                                       static_cast<IComposerCallback::Connection>(connected));
    }
```

#### HalEventCallback hotplugHook
```cpp

        void onHotplug(Display display, IComposerCallback::Connection connected) {
            if (connected == IComposerCallback::Connection::CONNECTED) {
                mResources->addPhysicalDisplay(display);
            } else if (connected == IComposerCallback::Connection::DISCONNECTED) {
                mResources->removeDisplay(display);
            }

            auto ret = mCallback->onHotplug(display, connected);
            ALOGE_IF(!ret.isOk(), "failed to send onHotplug: %s", ret.description().c_str());
        }
```
能看到在这个过程中就不是简单的回调，而是把回调上来的hwc2_display_t对象添加到ComposerResources中。

#### ComposerResources 添加Display管理
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[interfaces](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/)/[graphics](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/)/[composer](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/)/[utils](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/)/[hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/)/[include](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/)/[composer-hal](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/)/[2.1](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/)/[ComposerResources.h](http://androidxref.com/9.0.0_r3/xref/hardware/interfaces/graphics/composer/2.1/utils/hal/include/composer-hal/2.1/ComposerResources.h)
```cpp
    Error addPhysicalDisplay(Display display) {
        auto displayResource =
            createDisplayResource(ComposerDisplayResource::DisplayType::PHYSICAL, 0);

        std::lock_guard<std::mutex> lock(mDisplayResourcesMutex);
        auto result = mDisplayResources.emplace(display, std::move(displayResource));
        return result.second ? Error::NONE : Error::BAD_DISPLAY;
    }

    virtual std::unique_ptr<ComposerDisplayResource> createDisplayResource(
        ComposerDisplayResource::DisplayType type, uint32_t outputBufferCacheSize) {
        return std::make_unique<ComposerDisplayResource>(type, mImporter, outputBufferCacheSize);
    }
```
在这个过程中，Composer会把每一个hwc2_display_t最终封装成一个个ComposerDisplayResource，加入到集合当中。
```cpp
class ComposerDisplayResource {
   public:
    enum class DisplayType {
        PHYSICAL,
        VIRTUAL,
    };

    ComposerDisplayResource(DisplayType type, ComposerHandleImporter& importer,
                            uint32_t outputBufferCacheSize)
        : mType(type),
          mClientTargetCache(importer),
          mOutputBufferCache(importer, ComposerHandleCache::HandleType::BUFFER,
                             outputBufferCacheSize) {}
```
能看到，此时就是把ComposerResources中的图元申请服务交给ComposerDisplayResource持有，让Display自己拥有控制图元的能力，同时初始化缓存为0.

当缓存好ComposerDisplayResource之后就会继续回调，到顶层

#### ComposerCallbackBridge onHotplug
```
    Return<void> onHotplug(Hwc2::Display display,
                           IComposerCallback::Connection conn) override
    {
        HWC2::Connection connection = static_cast<HWC2::Connection>(conn);
        mCallback->onHotplugReceived(mSequenceId, display, connection);
        return Void();
    }
```
此时终于来到了上一篇文章中解析的SF层中屏幕的初始化流程中。

#### 注意小结
了解了整个回调机制之后，我们能够发现其实registerCallback在Hwc1OnAdapter(也是hwc2_device_t)中做的事情仅仅只是把当前的方法指针和回调类型存储起来，同时让刚注册进来的监听消费掉还没有回调上去的消息。

到这里，整个逻辑链路似乎就断开了。我曾经看源码也苦恼了很久，发现其实真正从硬件回调上来的地方其实是Hwc1OnAdapter::Callback中的回调。他是在hwc_device_t的registerProcs的时候注册进去的。

接下来让我们探索一下他的原理。


#### hwc_device_t的registerProcs
调用如下：
```cpp
    mHwc1Device->registerProcs(mHwc1Device,
            static_cast<const hwc_procs_t*>(mHwc1Callbacks.get()));
```


文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc.cpp)

```c
static void hwc_registerProcs(struct hwc_composer_device_1* dev,
                              hwc_procs_t const* procs)
{
    hwc_context_t* ctx = (hwc_context_t*)(dev);
    if(!ctx) {
        return;
    }
    ctx->proc = procs;

    init_uevent_thread(ctx);
    init_vsync_thread(ctx);
}
```
又一次见到这种设计把hwc_composer_device_1转型成hwc_context_t.
```cpp
struct hwc_context_t {
    hwc_composer_device_1_t device;
    const hwc_procs_t* proc;

    qhwc::CopyBit *mCopyBit[MAX_DISPLAYS];

    overlay::Overlay *mOverlay;
    overlay::RotMgr *mRotMgr;

    //Primary and external FB updater
    qhwc::IFBUpdate *mFBUpdate[MAX_DISPLAYS];
    // External display related information
    qhwc::ExternalDisplay *mExtDisplay;
    qhwc::MDPInfo mMDP;
    qhwc::VsyncState vstate;
    qhwc::DisplayAttributes dpyAttr[MAX_DISPLAYS];
    qhwc::ListStats listStats[MAX_DISPLAYS];
    qhwc::LayerProp *layerProp[MAX_DISPLAYS];
    qhwc::LayerRotMap *mLayerRotMap[MAX_DISPLAYS];
    qhwc::MDPComp *mMDPComp[MAX_DISPLAYS];
    qhwc::CablProp mCablProp;
    overlay::utils::Whf mPrevWHF[MAX_DISPLAYS];

    //Securing in progress indicator
    bool mSecuring;
    //External Display configuring progress indicator
    bool mExtDispConfiguring;
    //Display in secure mode indicator
    bool mSecureMode;
    //Lock to prevent set from being called while blanking
    mutable Locker mBlankLock;
    //Lock to protect set when detaching external disp
    mutable Locker mExtSetLock;
    //DMA used for rotator
    bool mDMAInUse;
    //MDP rotater needed
    bool mNeedsRotator;
    //Check if base pipe is set up
    bool mBasePipeSetup;
    //Flags the transition of a video session
    bool mVideoTransFlag;
};
```
能看到这个方法初始化了2个线程，一个是vsync同步信号线程，一个是uevent的事件信号线程。还会把当前的hwc_procs_t这个回调结构体存储起来。

#### hwc 初始化事件线程
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc_uevents.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc_uevents.cpp)

```cpp
static void *uevent_loop(void *param)
{
    int len = 0;
    static char udata[PAGE_SIZE];
    hwc_context_t * ctx = reinterpret_cast<hwc_context_t *>(param);
    char thread_name[64] = HWC_UEVENT_THREAD_NAME;
    prctl(PR_SET_NAME, (unsigned long) &thread_name, 0, 0, 0);
    setpriority(PRIO_PROCESS, 0, HAL_PRIORITY_URGENT_DISPLAY);
    uevent_init();

    while(1) {
        len = uevent_next_event(udata, sizeof(udata) - 2);
        handle_uevent(ctx, udata, len);
    }

    return NULL;
}

void init_uevent_thread(hwc_context_t* ctx)
{
    pthread_t uevent_thread;
    int ret;

    ALOGI("Initializing UEVENT Thread");
    ret = pthread_create(&uevent_thread, NULL, uevent_loop, (void*) ctx);
    if (ret) {
        ALOGE("%s: failed to create %s: %s", __FUNCTION__,
            HWC_UEVENT_THREAD_NAME, strerror(ret));
    }
}
```
能看到该方法其实就是实例化一个最高优先级的pthread线程，经过一个uevent_init初始化后进入了uevent_loop的循环。关键能看到下面这个死循环：
```c
    while(1) {
        len = uevent_next_event(udata, (int)sizeof(udata) - 2);
        handle_uevent(ctx, udata, len);
    }
```
uevent_next_event不断的获取下一个需要处理事件，handle_uevent进行处理。


#### uevent_init
文件： /[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[libhardware_legacy](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware_legacy/)/[uevent.c](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware_legacy/uevent.c)

```cpp
int uevent_init()
{
    struct sockaddr_nl addr;
    int sz = 64*1024;
    int s;

    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = getpid();
    addr.nl_groups = 0xffffffff;

    s = socket(PF_NETLINK, SOCK_DGRAM, NETLINK_KOBJECT_UEVENT);
    if(s < 0)
        return 0;

    setsockopt(s, SOL_SOCKET, SO_RCVBUFFORCE, &sz, sizeof(sz));

    if(bind(s, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        close(s);
        return 0;
    }

    fd = s;
    return (fd > 0);
}
```
能看到在msm8994中event的初始化其实就是一个socket服务端。这个socket设置协议族为SOCK_DGRAM也就是面向数据包的协议。同时设置了该socket是接收端，还设置了bind绑定了地址，并且回调了socket中的fd。

#### uevent_next_event 获取需要处理的事件
文件： /[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[libhardware_legacy](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware_legacy/)/[uevent.c](http://androidxref.com/9.0.0_r3/xref/hardware/libhardware_legacy/uevent.c)

```cpp
int uevent_next_event(char* buffer, int buffer_length)
{
    while (1) {
        struct pollfd fds;
        int nr;
    
        fds.fd = fd;
        fds.events = POLLIN;
        fds.revents = 0;
        nr = poll(&fds, 1, -1);
     
        if(nr > 0 && (fds.revents & POLLIN)) {
            int count = recv(fd, buffer, buffer_length, 0);
            if (count > 0) {
                struct uevent_handler *h;
                pthread_mutex_lock(&uevent_handler_list_lock);
                LIST_FOREACH(h, &uevent_handler_list, list)
                    h->handler(h->handler_data, buffer, buffer_length);
                pthread_mutex_unlock(&uevent_handler_list_lock);

                return count;
            } 
        }
    }
    
    // won't get here
    return 0;
}
```
其核心方法就是调用了poll系统调用，监听socket文件描述符中数据流的变化。一旦nr大于0，说明又说来了，就调用recv从socket中读取数据，回去遍历查找已经通过uevent_add_native_handler添加进来的回调，并返回发生变化的数量。

然而这里面并没有通过uevent_add_native_handler进来一个回调。而是直接交给下一个函数处理。

#### handle_uevent
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc_uevents.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc_uevents.cpp)

此时用过uevent_next_event已经把数据拷贝到uevent_data中,就开始解析数据
```cpp
enum {
    EXTERNAL_OFFLINE = 0,
    EXTERNAL_ONLINE,
    EXTERNAL_PAUSE,
    EXTERNAL_RESUME
};


static void handle_uevent(hwc_context_t* ctx, const char* udata, int len)
{
    const char *str = udata;
    bool usecopybit = false;
    int compositionType =
        qdutils::QCCompositionType::getInstance().getCompositionType();

    if (compositionType & (qdutils::COMPOSITION_TYPE_DYN |
                           qdutils::COMPOSITION_TYPE_MDP |
                           qdutils::COMPOSITION_TYPE_C2D)) {
        usecopybit = true;
    }

    if(!strcasestr("change@/devices/virtual/switch/hdmi", str) &&
       !strcasestr("change@/devices/virtual/switch/wfd", str)) {
        return;
    }
    int connected = -1; // initial value - will be set to  1/0 based on hotplug
    int extDpyNum = HWC_DISPLAY_EXTERNAL;
    char property[PROPERTY_VALUE_MAX];
    if((property_get("persist.sys.wfd.virtual", property, NULL) > 0) &&
            (!strncmp(property, "1", PROPERTY_VALUE_MAX ) ||
             (!strncasecmp(property,"true", PROPERTY_VALUE_MAX )))) {
        // This means we are using Google API to trigger WFD Display
        extDpyNum = HWC_DISPLAY_VIRTUAL;

    }

    int dpy = isHDMI(str) ? HWC_DISPLAY_EXTERNAL : extDpyNum;

    // update extDpyNum
    ctx->mExtDisplay->setExtDpyNum(dpy);

    while(*str) {
        if (!strncmp(str, "SWITCH_STATE=", strlen("SWITCH_STATE="))) {
            connected = atoi(str + strlen("SWITCH_STATE="));
            //Disabled until SF calls unblank
            ctx->dpyAttr[HWC_DISPLAY_EXTERNAL].isActive = false;
            //Ignored for Virtual Displays
            //ToDo: we can do this in a much better way
            ctx->dpyAttr[HWC_DISPLAY_VIRTUAL].isActive = true;
            break;
        }
        str += strlen(str) + 1;
        if (str - udata >= len)
            break;
    }

    switch(connected) {
        case EXTERNAL_OFFLINE:
            {   // disconnect event
                ctx->mExtDisplay->processUEventOffline(udata);
                if(ctx->mFBUpdate[dpy]) {
                    Locker::Autolock _l(ctx->mExtSetLock);
                    delete ctx->mFBUpdate[dpy];
                    ctx->mFBUpdate[dpy] = NULL;
                }
                if(ctx->mCopyBit[dpy]){
                    Locker::Autolock _l(ctx->mExtSetLock);
                    delete ctx->mCopyBit[dpy];
                    ctx->mCopyBit[dpy] = NULL;
                }
                if(ctx->mMDPComp[dpy]) {
                    delete ctx->mMDPComp[dpy];
                    ctx->mMDPComp[dpy] = NULL;
                }
                ctx->dpyAttr[dpy].connected = false;
                Locker::Autolock _l(ctx->mExtSetLock);
                //hwc comp could be on
                ctx->proc->hotplug(ctx->proc, dpy, connected);
                break;
            }
        case EXTERNAL_ONLINE:
            {   // connect case
                ctx->mExtDispConfiguring = true;
                ctx->mExtDisplay->processUEventOnline(udata);
                ctx->mFBUpdate[dpy] =
                        IFBUpdate::getObject(ctx->dpyAttr[dpy].xres, dpy);
                ctx->dpyAttr[dpy].isPause = false;
                if(usecopybit)
                    ctx->mCopyBit[dpy] = new CopyBit();
                ctx->mMDPComp[dpy] =  MDPComp::getObject(
                        ctx->dpyAttr[dpy].xres, dpy);
                ctx->dpyAttr[dpy].connected = true;
                Locker::Autolock _l(ctx->mExtSetLock); //hwc comp could be on
                ctx->proc->hotplug(ctx->proc, dpy, connected);
                break;
            }
        case EXTERNAL_PAUSE:
            {   // pause case
                ctx->mExtDispConfiguring = true;
                ctx->dpyAttr[dpy].isActive = true;
                ctx->dpyAttr[dpy].isPause = true;
                break;
            }
        case EXTERNAL_RESUME:
            {  // resume case
                ctx->dpyAttr[dpy].isActive = true;
                ctx->dpyAttr[dpy].isPause = false;
                break;
            }
        default:
           ...
    }
}
```
其实这里表达的观点很简单，首先它只解析以"change@/devices/virtual/switch/hdmi"或者"change@/devices/virtual/switch/wfd"开头的消息。这种消息的格式如下：
```
change@/devices/virtual/switch/hdmi ACTION=change
SWITCH_STATE=0
```
需要判断的类型就是SWITCH_STATE对应的字符的int是什么进行响应的处理。有4个状态：
- 1.EXTERNAL_OFFLINE 0
- 2.EXTERNAL_ONLINE 1
- 3.EXTERNAL_PAUSE 2
- 4.EXTERNAL_RESUME 3

同时dpy代表屏幕类型，如果是change@/devices/virtual/switch/hdmi消息来了，说明是物理屏幕HWC_DISPLAY_EXTERNAL

> 当为EXTERNAL_OFFLINE 的时候就代表屏幕被关闭或者拔出。先调用 qhwc::ExternalDisplay->processUEventOffline，销毁保存在数组中数据，并让dpyAttr对应的id变成false，最后调用hotPlugin回调

> EXTERNAL_ONLINE 代表屏幕联通了。先调用ExternalDisplay的processUEventOnline，申请资源，最后调用hotPlugin回调

> EXTERNAL_PAUSE 屏幕冻结了，设置dpyAttr标志位

> EXTERNAL_RESUME 屏幕恢复了，设置dpyAttr标志位

暂时理解这么多即可。

#### vysnc线程初始化
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc_vsync.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc_vsync.cpp)
```cpp
void init_vsync_thread(hwc_context_t* ctx)
{
    int ret;
    pthread_t vsync_thread;
    ret = pthread_create(&vsync_thread, NULL, vsync_loop, (void*) ctx);
...
}
```

```cpp
static void *vsync_loop(void *param)
{
    const char* vsync_timestamp_fb0 = "/sys/class/graphics/fb0/vsync_event";
    const char* vsync_timestamp_fb1 = "/sys/class/graphics/fb1/vsync_event";
    int dpy = HWC_DISPLAY_PRIMARY;

    hwc_context_t * ctx = reinterpret_cast<hwc_context_t *>(param);

    char thread_name[64] = HWC_VSYNC_THREAD_NAME;
    prctl(PR_SET_NAME, (unsigned long) &thread_name, 0, 0, 0);
    setpriority(PRIO_PROCESS, 0, HAL_PRIORITY_URGENT_DISPLAY +
                android::PRIORITY_MORE_FAVORABLE);

    const int MAX_DATA = 64;
    static char vdata[MAX_DATA];

    uint64_t cur_timestamp=0;
    ssize_t len = -1;
    int fd_timestamp = -1;
    bool fb1_vsync = false;
    bool logvsync = false;

    char property[PROPERTY_VALUE_MAX];
    if(property_get("debug.hwc.fakevsync", property, NULL) > 0) {
        if(atoi(property) == 1)
            ctx->vstate.fakevsync = true;
    }

    if(property_get("debug.hwc.logvsync", property, 0) > 0) {
        if(atoi(property) == 1)
            logvsync = true;
    }

    fd_timestamp = open(vsync_timestamp_fb0, O_RDONLY);
    if (fd_timestamp < 0) {
        ...
        ctx->vstate.fakevsync = true;
    }

    do {
        if (LIKELY(!ctx->vstate.fakevsync)) {
            len = pread(fd_timestamp, vdata, MAX_DATA, 0);
            if (len < 0) {
               ...
                continue;
            }
            // extract timestamp
            const char *str = vdata;
            if (!strncmp(str, "VSYNC=", strlen("VSYNC="))) {
                cur_timestamp = strtoull(str + strlen("VSYNC="), NULL, 0);
            }
        } else {
            usleep(16666);
            cur_timestamp = systemTime();
        }
        // send timestamp to HAL
        if(ctx->vstate.enable) {
            ctx->proc->vsync(ctx->proc, dpy, cur_timestamp);
        }

    } while (true);
    if(fd_timestamp >= 0)
        close (fd_timestamp);

    return NULL;
}
```
其核心原理十分简单，也是进入到一个死循环。该循环会读取/sys/class/graphics/fb0/vsync_event下的驱动文件，如果失败说明没有硬件驱动，那就使用软件模拟，能看到这里面就会沉睡16.66毫秒。

如果成功则读取里面的数据,一般为如下格式：
> VSYNC=41800875994
获取后面的数值，最后把该时间顶层回调即可。

本文对vysnc同步的信号的探索到这里，之后会结合整个SF聊聊它的原理。

#### 回调到HWC2On1Adapter::Callbacks
我们现在暂时只关注一个屏幕的热插拔逻辑。
```cpp
        static void hotplugHook(const hwc_procs_t* procs, int display,
                int connected) {
            auto callbacks = static_cast<const Callbacks*>(procs);
            callbacks->mAdapter.hwc1Hotplug(display, connected);
        }
```
```cpp
void HWC2On1Adapter::hwc1Hotplug(int hwc1DisplayId, int connected) {
    ALOGV("Received hwc1Hotplug(%d, %d)", hwc1DisplayId, connected);

    if (hwc1DisplayId != HWC_DISPLAY_EXTERNAL) {
        return;
    }

    std::unique_lock<std::recursive_timed_mutex> lock(mStateMutex);

    if (mCallbacks.count(Callback::Hotplug) == 0) {
        mPendingHotplugs.emplace_back(hwc1DisplayId, connected);
        return;
    }

    hwc2_display_t displayId = UINT64_MAX;
    if (mHwc1DisplayMap.count(hwc1DisplayId) == 0) {
        if (connected == 0) {
            ALOGW("hwc1Hotplug: Received disconnect for unconnected display");
            return;
        }

        auto display = std::make_shared<HWC2On1Adapter::Display>(*this,
                HWC2::DisplayType::Physical);
        display->setHwc1Id(HWC_DISPLAY_EXTERNAL);
        display->populateConfigs();
        displayId = display->getId();
        mHwc1DisplayMap[HWC_DISPLAY_EXTERNAL] = displayId;
        mDisplays.emplace(displayId, std::move(display));
    } else {
        if (connected != 0) {
            ALOGW("hwc1Hotplug: Received connect for previously connected "
                    "display");
            return;
        }

        displayId = mHwc1DisplayMap[hwc1DisplayId];
        mHwc1DisplayMap.erase(HWC_DISPLAY_EXTERNAL);
        mDisplays.erase(displayId);
    }

    const auto& callbackInfo = mCallbacks[Callback::Hotplug];


    lock.unlock();

    auto hotplug = reinterpret_cast<HWC2_PFN_HOTPLUG>(callbackInfo.pointer);
    auto hwc2Connected = (connected == 0) ?
            HWC2::Connection::Disconnected : HWC2::Connection::Connected;
    hotplug(callbackInfo.data, displayId, static_cast<int32_t>(hwc2Connected));
}
```
如果没有注册热插拔的监听，则会保存到mPendingHotplugs集合中，等待回调监听。

该回调只处理物理屏幕的逻辑。如果connect是0且mHwc1DisplayMap大于0说明有屏幕链接过，现在断开链接了，则从mHwc1DisplayMap中销毁对应id，销毁mDisplays对应的屏幕对象对象。

如果connect为1，说明有屏幕链接进来了。此时会生成一个HWC2On1Adapter::Display对象保存mDisplays。最后就是走上面registerCallback之上的逻辑了。


## 总结
重新梳理一遍：
- Composer其实最重要的行为就是createClient，创建一个ComposerClient，ComposerClient此时真正的逻辑核心。
- ComposerClient会持有HwcHalImpl，该类因为持有这hw2_device_t，所以拥有了和硬件通信的能力。ComposerResource中持有ComposerInputHandler这个对象负责图元服务的控制。ComposerCommandEngine则是处理一些来自上层的命令。
- HWC2On1Adapter则是为了适配hw_device_t和版本2之间的区别，同时注册一个监听到驱动中。
- 对于回调来讲，分为两部分，当registerCallback的时候会消耗从底层回调上来。另一部分则是从底层直接拿到对应的HwcHalImpl的hook函数向上回调。

原理如图：
![ComposerCallback.png](https://upload-images.jianshu.io/upload_images/9880421-ba953bffd1a640a3.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


了解Hal层的运作原理，为之后的逻辑打下基础。

最后再补上一副hal层对应的SF的数据结构：
