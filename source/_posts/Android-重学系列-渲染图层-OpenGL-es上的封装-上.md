---
title: Android 重学系列 渲染图层-OpenGL es上的封装(上)
top: false
cover: false
date: 2020-01-25 23:38:42
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
经过探索，让我们理解了整个SF的消费者和生产者之间的关系。我们继续根据开机动画，来看看Android对OpenGL es的封装。

让我们回忆一下，上一篇开机动画OpenGL es 使用步骤，大致分为如下几个：
- 1.SurfaceComposerClient::getBuiltInDisplay 从SF中查询可用的物理屏幕
- 2.SurfaceComposerClient::getDisplayInfo 从SF中获取屏幕的详细信息
- 3.session()->createSurface 通过Client创建绘制平面控制中心
- 4.t.setLayer(control, 0x40000000) 设置当前layer的层级
- 5.control->getSurface 获取真正的绘制平面对象
- 6.eglGetDisplay 获取opengl es的默认主屏幕，加载OpenGL es
- 7.eglInitialize 初始化屏幕对象和着色器缓存
- 8.eglChooseConfig 自动筛选出最合适的配置
- 9.eglCreateWindowSurface 从Surface中创建一个opengl es的surface
- 10.eglCreateContext 创建当前opengl es 的上下文
- 11.eglQuerySurface 查找当前环境的宽高属性
- 12.eglMakeCurrent 把上下文Context，屏幕display还有渲染面surface,线程关联起来。
- 13.调用OpenGL es本身特性，绘制顶点，纹理等。
- 14.eglSwapBuffers 交换绘制好的缓冲区
- 15.销毁资源

上一篇文章聊了从1-5的步骤，本文将会聊聊从第6到第12的步骤。

如果遇到什么问题，欢迎到本文讨论[https://www.jianshu.com/p/03c40afab7a5](https://www.jianshu.com/p/03c40afab7a5)


# 正文

其实从第6步骤开始，才算是真正的OpenGL es的操作。如果经常编写OpenGL es的哥们就特别熟悉这些步骤，因为都是套路来的。不过这些套路的背后Android是怎么运行的呢？就让我们一探究竟。

注意本文，因为获取不到OpenGL es 驱动(服务端)的源码，本文就以Android封装的OpenGL es软件渲染进行解析，但是对外封装软硬件几乎看不出区别。来看看Google工程师对OpenGL es的设计，让我们反向推导硬件驱动是怎么实现OpenGL es的。

## eglGetDisplay 获取opengl es的默认主屏幕句柄
这个方法究竟做了什么？为什么必须要第一个调用？它有什么特殊的？Android中的所有OpenGL es都会汇总到eglApi中。

先来看看如何使用：
```cpp
EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[eglApi.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/eglApi.cpp)
```cpp
EGLDisplay eglGetDisplay(EGLNativeDisplayType display)
{
...

    uintptr_t index = reinterpret_cast<uintptr_t>(display);
    if (index >= NUM_DISPLAYS) {
        return setError(EGL_BAD_PARAMETER, EGL_NO_DISPLAY);
    }

    if (egl_init_drivers() == EGL_FALSE) {
        return setError(EGL_BAD_PARAMETER, EGL_NO_DISPLAY);
    }

    EGLDisplay dpy = egl_display_t::getFromNativeDisplay(display);
    return dpy;
}
```
EGLNativeDisplayType其实就是一个编译常量。
```cpp
#define EGL_DEFAULT_DISPLAY               EGL_CAST(EGLNativeDisplayType,0)
```
其实就是一个0.而NUM_DISPLAYS就是1.因此在Android只允许设置一个0的默认主屏幕。巧合的是刚好我们的主屏幕id也是0.解析来做了2个十分重要的事情：
- 1.egl_init_drivers 加载 OpenGL es 动态库，初始化OpenGL es的api
- 2.egl_display_t::getFromNativeDisplay 从OpenGL es中获取一个象征屏幕对象EGLDisplay。

### egl_init_drivers 初始化OpenGL es
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/egl.cpp)

```
egl_connection_t gEGLImpl;

EGLBoolean egl_init_drivers() {
    EGLBoolean res;
    pthread_mutex_lock(&sInitDriverMutex);
    res = egl_init_drivers_locked();
    pthread_mutex_unlock(&sInitDriverMutex);
    return res;
}

static EGLBoolean egl_init_drivers_locked() {
    if (sEarlyInitState) {
        // initialized by static ctor. should be set here.
        return EGL_FALSE;
    }

    // get our driver loader
    Loader& loader(Loader::getInstance());

    // dynamically load our EGL implementation
    egl_connection_t* cnx = &gEGLImpl;
    if (cnx->dso == 0) {
        cnx->hooks[egl_connection_t::GLESv1_INDEX] =
                &gHooks[egl_connection_t::GLESv1_INDEX];
        cnx->hooks[egl_connection_t::GLESv2_INDEX] =
                &gHooks[egl_connection_t::GLESv2_INDEX];
        cnx->dso = loader.open(cnx);
    }

    return cnx->dso ? EGL_TRUE : EGL_FALSE;
}
```
类型为egl_connection_t的gEGLImpl作为全局变量一开始没有初始化，因此此时里面所有的数据都是0.

将会调用一个静态变量Loader的open方法。

#### Loader open
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[Loader.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/Loader.cpp)

```cpp
void* Loader::open(egl_connection_t* cnx)
{
 

    void* dso;
    driver_t* hnd = 0;

    setEmulatorGlesValue();

    dso = load_driver("GLES", cnx, EGL | GLESv1_CM | GLESv2);
    if (dso) {
        hnd = new driver_t(dso);
    } else {
        // Always load EGL first
        dso = load_driver("EGL", cnx, EGL);
        if (dso) {
            hnd = new driver_t(dso);
            hnd->set( load_driver("GLESv1_CM", cnx, GLESv1_CM), GLESv1_CM );
            hnd->set( load_driver("GLESv2",    cnx, GLESv2),    GLESv2 );
        }
    }


    cnx->libEgl   = load_wrapper(EGL_WRAPPER_DIR "/libEGL.so");
    cnx->libGles2 = load_wrapper(EGL_WRAPPER_DIR "/libGLESv2.so");
    cnx->libGles1 = load_wrapper(EGL_WRAPPER_DIR "/libGLESv1_CM.so");

    return (void*)hnd;
}
```
load_driver尝试加载OpenGL es的库，最后把句柄赋值给driver_t。
```cpp
void *Loader::load_driver(const char* kind,
        egl_connection_t* cnx, uint32_t mask)
{
    ATRACE_CALL();

    void* dso = nullptr;
#ifndef __ANDROID_VNDK__
...
#endif
    if (!dso) {
        dso = load_system_driver(kind);
        if (!dso)
            return NULL;
    }

//加载api
    return dso;
}
```
我们不去关注VNDK的渲染库，还是来看看OpenGL es。
- 1.load_system_driver加载在几个固定名字so库。
- 2.调用init_api 初始化OpenGL es的api。

##### load_system_driver
这里只关注32位的情况，去掉了64位的情况。
```cpp
static void* load_system_driver(const char* kind) {
    ATRACE_CALL();
    class MatchFile {
    public:
        static std::string find(const char* kind) {
            std::string result;
            int emulationStatus = checkGlesEmulationStatus();
            switch (emulationStatus) {
                case 0:
                    result = "/vendor/lib/egl/libGLES_android.so";

                    return result;
                case 1:
                    result = std::string("/vendor/lib/egl/lib") + kind + "_emulation.so";
                    return result;
                case 2:
                    // Use guest side swiftshader library
                    result = std::string("/vendor/lib/egl/lib") + kind + "_swiftshader.so";
                    return result;
                default:
                    // Not in emulator, or use other guest-side implementation
                    break;
            }

            std::string pattern = std::string("lib") + kind;
            const char* const searchPaths[] = {
                    "/vendor/lib/egl",
                    "/system/lib/egl"
            };

            for (size_t i=0 ; i<NELEM(searchPaths) ; i++) {
                if (find(result, pattern, searchPaths[i], true)) {
                    return result;
                }
            }

            pattern.append("_");
            for (size_t i=0 ; i<NELEM(searchPaths) ; i++) {
                if (find(result, pattern, searchPaths[i], false)) {
                    return result;
                }
            }

            // we didn't find the driver. gah.
            result.clear();
            return result;
        }

    private:
        static bool find(std::string& result,
                const std::string& pattern, const char* const search, bool exact) {
            if (exact) {
                std::string absolutePath = std::string(search) + "/" + pattern + ".so";
                if (!access(absolutePath.c_str(), R_OK)) {
                    result = absolutePath;
                    return true;
                }
                return false;
            }

            DIR* d = opendir(search);
            if (d != NULL) {
                struct dirent* e;
                while ((e = readdir(d)) != NULL) {
                    if (e->d_type == DT_DIR) {
                        continue;
                    }
                    if (!strcmp(e->d_name, "libGLES_android.so")) {
                        // always skip the software renderer
                        continue;
                    }
                    if (strstr(e->d_name, pattern.c_str()) == e->d_name) {
                        if (!strcmp(e->d_name + strlen(e->d_name) - 3, ".so")) {
                            result = std::string(search) + "/" + e->d_name;
                            closedir(d);
                            return true;
                        }
                    }
                }
                closedir(d);
            }
            return false;
        }
    };


    std::string absolutePath = MatchFile::find(kind);
    if (absolutePath.empty()) {
        return 0;
    }
    const char* const driver_absolute_path = absolutePath.c_str();

    void* dso = do_android_load_sphal_library(driver_absolute_path,
                                              RTLD_NOW | RTLD_LOCAL);
    if (dso == 0) {
        const char* err = dlerror();
        return 0;
    }


    return dso;
}
```
通过checkGlesEmulationStatus检测此时在Android设定的系统变量ro.kernel.qemu和qemu.gles是什么。来判断加载什么模式。

如果是0则加载libGLES_android.so库，这就是Google模仿GPU驱动 OpenGLes写的软件渲染库。另外两个展示不讨论。其他则是状况则会按照如下规律查找有没有对应的so库：
> /{vendor|system}/lib/egl/lib{GLES | [EGL|GLESv1_CM|GLESv2]}_*.so

一般都是指libEGL.so这些就是默认的硬件驱动名字。当然还可以给特殊驱动厂商自定义名字，就是libEGL_*.so。这个名字一般被定义在egl.cfg中,如下：
```
0 0 android
0 1 adreno
```
第一个参数必定是0，第二个参数，0是软件渲染，1是硬件渲染。
adreno这个显卡厂商就会提供一个类似libEGL_adreno.so的名字。这样也算是找到。

找到后调用dlopen打开so库。

**记住，下文我全部以libGLES_android.so为基准解析OpenGL es软件渲染的实现**


##### 初始化OpenGL es api
继续啊看load_driver下半段
```cpp
     if (mask & EGL) {
        getProcAddress = (getProcAddressType)dlsym(dso, "eglGetProcAddress");

        egl_t* egl = &cnx->egl;
        __eglMustCastToProperFunctionPointerType* curr =
            (__eglMustCastToProperFunctionPointerType*)egl;
        char const * const * api = egl_names;
        while (*api) {
            char const * name = *api;
            __eglMustCastToProperFunctionPointerType f =
                (__eglMustCastToProperFunctionPointerType)dlsym(dso, name);
            if (f == NULL) {
                // couldn't find the entry-point, use eglGetProcAddress()
                f = getProcAddress(name);
                if (f == NULL) {
                    f = (__eglMustCastToProperFunctionPointerType)0;
                }
            }
            *curr++ = f;
            api++;
        }
    }

...
    if (mask & GLESv2) {
      init_api(dso, gl_names,
            (__eglMustCastToProperFunctionPointerType*)
                &cnx->hooks[egl_connection_t::GLESv2_INDEX]->gl,
            getProcAddress);
    }
```
接着就要给egl_t初始化。此时有一个egl_names变量，这个变量其实是egl_entries.in字符串。它实际上指向的是如下地址：
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[egl_entries.in](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/egl_entries.in)

里面包含着所有当前OpenGL es暴露出来的接口，接着以此为参数调用eglGetProcAddress获取所有函数的指针，并且赋值给curr指针数组中。接着init_api则是处理OpenGL es 版本1和2之间差异方法。

此时egl_connection_t中的egl持有了所有的方法指针。以后只需要使用egl这个结构体就能调用so库的逻辑了。注意这里面只包含操作OpenGL es中操作像素的api，关于着色器api编译链接并不在这里实现。

如果需要看着色器相关的软件渲染原理，需要去阅读模拟器是如何模拟的。这里已经超出讨论范围，有机会我们在来聊聊，如果之后有相关深入的工作的机会，我倒是会解析一遍软件解析着色器渲染流程。

注意这里有一个load_wrapper方法，加载了libGLESv2.so的动态库，这个实际上就是基于平台的如着色器这些和硬件相关的so。通过两个load方式，终于把OpenGL es完整加载到内存中。

这种软件机制我们也叫它pixelflinger。

### egl_display_t::getFromNativeDisplay 获取EGLDisplay对象
先来看看egl_display_t类,只关注属性
```cpp
class EGLAPI egl_display_t { // marked as EGLAPI for testing purposes
    static egl_display_t sDisplay[NUM_DISPLAYS];
...

public:
    enum {
        NOT_INITIALIZED = 0,
        INITIALIZED     = 1,
        TERMINATED      = 2
    };

...
    struct DisplayImpl {
        DisplayImpl() : dpy(EGL_NO_DISPLAY), state(NOT_INITIALIZED) { }
        EGLDisplay  dpy;
        EGLint      state;
        strings_t   queryString;
    };

private:
    uint32_t        magic;
...
public:
    DisplayImpl     disp;
...

private:
    friend class egl_display_ptr;
...
};
```
在这里面,有一个大小为1静态数组sDisplay用来控制egl_display_t一个最多控制一个屏幕id。其中DisplayImpl中的EGLDisplay其实就是对应着OpenGL es那边的对象。

解析来看看两个方法。
```
EGLDisplay egl_display_t::getFromNativeDisplay(EGLNativeDisplayType disp) {
    if (uintptr_t(disp) >= NUM_DISPLAYS)
        return NULL;

    return sDisplay[uintptr_t(disp)].getDisplay(disp);
}

EGLDisplay egl_display_t::getDisplay(EGLNativeDisplayType display) {

    std::lock_guard<std::mutex> _l(lock);
    Loader& loader(Loader::getInstance());

    egl_connection_t* const cnx = &gEGLImpl;
    if (cnx->dso && disp.dpy == EGL_NO_DISPLAY) {
        EGLDisplay dpy = cnx->egl.eglGetDisplay(display);
        disp.dpy = dpy;
        if (dpy == EGL_NO_DISPLAY) {
            loader.close(cnx->dso);
            cnx->dso = NULL;
        }
    }

    return EGLDisplay(uintptr_t(display) + 1U);
}
```
这里的核心其实就是调用egl_connection_t中的eglGetDisplay方法获取从OpenGL es中生成的EGLDisplay赋值给egl_display_t，最后返回这个包装对象。

#### OpenGL es 端的实现
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)
```cpp
EGLDisplay eglGetDisplay(NativeDisplayType display)
{
    if (gGLKey == -1) {
        pthread_mutex_lock(&gInitMutex);
        if (gGLKey == -1)
            pthread_key_create(&gGLKey, NULL);
        pthread_mutex_unlock(&gInitMutex);
    }

    if (display == EGL_DEFAULT_DISPLAY) {
        EGLDisplay dpy = (EGLDisplay)1;
        egl_display_t& d = egl_display_t::get_display(dpy);
        d.type = display;
        return dpy;
    }
    return EGL_NO_DISPLAY;
}
```
能看到只有设置了EGL_DEFAULT_DISPLAY(0)才会初始化，同时创建一个tls的key。此时强制设置了一个1的EGLDisplay(因为它是void*在声明在调用端，这里是int，其实绝大部分平台也是int)。

```cpp
struct egl_display_t
{
    egl_display_t() : type(0), initialized(0) { }

    static egl_display_t& get_display(EGLDisplay dpy);

    static EGLBoolean is_valid(EGLDisplay dpy) {
        return ((uintptr_t(dpy)-1U) >= NUM_DISPLAYS) ? EGL_FALSE : EGL_TRUE;
    }

    NativeDisplayType  type;
    std::atomic_size_t initialized;
};

static egl_display_t gDisplays[NUM_DISPLAYS];

egl_display_t& egl_display_t::get_display(EGLDisplay dpy) {
    return gDisplays[uintptr_t(dpy)-1U];
}
```
其实结果很简单，在OpenGL es中有一个对应的egl_display_t结构体对应上客户端的egl_display_t的类，也同时对应上EGLDisplay。

因此此时egl_display_t只是返回一个初始化了的句柄。

## eglInitialize始化屏幕状态
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[eglApi.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/eglApi.cpp)

```cpp
EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{

    egl_display_ptr dp = get_display(dpy);
    if (!dp) return setError(EGL_BAD_DISPLAY, (EGLBoolean)EGL_FALSE);

    EGLBoolean res = dp->initialize(major, minor);

    return res;
}
```
egl_display_ptr这个结构体很简单实际上就指的是egl_display_t指针。

### egl_display_t的初始化
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[egl_display.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/egl_display.cpp)

```cpp
EGLBoolean egl_display_t::initialize(EGLint *major, EGLint *minor) {

    { // scope for refLock
        std::unique_lock<std::mutex> _l(refLock);
        refs++;
        if (refs > 1) {
            if (major != NULL)
                *major = VERSION_MAJOR;
            if (minor != NULL)
                *minor = VERSION_MINOR;
            while(!eglIsInitialized) {
                refCond.wait(_l);
            }
            return EGL_TRUE;
        }
        while(eglIsInitialized) {
            refCond.wait(_l);
        }
    }

    { // scope for lock
        std::lock_guard<std::mutex> _l(lock);

        setGLHooksThreadSpecific(&gHooksNoContext);

        egl_connection_t* const cnx = &gEGLImpl;
        cnx->major = -1;
        cnx->minor = -1;
        if (cnx->dso) {
            EGLDisplay idpy = disp.dpy;
            if (cnx->egl.eglInitialize(idpy, &cnx->major, &cnx->minor)) {
                //ALOGD("initialized dpy=%p, ver=%d.%d, cnx=%p",
                //        idpy, cnx->major, cnx->minor, cnx);

                // display is now initialized
                disp.state = egl_display_t::INITIALIZED;

                // get the query-strings for this display for each implementation
                disp.queryString.vendor = cnx->egl.eglQueryString(idpy,
                        EGL_VENDOR);
                disp.queryString.version = cnx->egl.eglQueryString(idpy,
                        EGL_VERSION);
                disp.queryString.extensions = cnx->egl.eglQueryString(idpy,
                        EGL_EXTENSIONS);
                disp.queryString.clientApi = cnx->egl.eglQueryString(idpy,
                        EGL_CLIENT_APIS);

            } else {
...
            }
        }
//扩展属性字符串的初始化
...

        egl_cache_t::get()->initialize(this);
...
        if (major != NULL)
            *major = VERSION_MAJOR;
        if (minor != NULL)
            *minor = VERSION_MINOR;
    }

    { // scope for refLock
        std::unique_lock<std::mutex> _l(refLock);
        eglIsInitialized = true;
        refCond.notify_all();
    }

    return EGL_TRUE;
}
```
能看到这列开始进行了多线程的安全处理，当进行初始化之后，其他线程将会进行等待。主要做的事情有两件事：
- 1.cnx->egl.eglInitialize 调用OpenGL es的初始化
- 2.egl_cache_t::get()->initialize 进行OpenGL es的着色器缓存初始化。


### OpenGL es eglInitialize
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)
```cpp
EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
    if (egl_display_t::is_valid(dpy) == EGL_FALSE)
        return setError(EGL_BAD_DISPLAY, EGL_FALSE);

    EGLBoolean res = EGL_TRUE;
    egl_display_t& d = egl_display_t::get_display(dpy);

    if (d.initialized.fetch_add(1, std::memory_order_acquire) == 0) {
        // initialize stuff here if needed
        //pthread_mutex_lock(&gInitMutex);
        //pthread_mutex_unlock(&gInitMutex);
    }

    if (res == EGL_TRUE) {
        if (major != NULL) *major = VERSION_MAJOR;
        if (minor != NULL) *minor = VERSION_MINOR;
    }
    return res;
}
```
能看到这里也是同时把OpenGL es对应的egl_display_t结构体同时设置为已经初始化，也就是1.同时把OpenGL es中保存的版本号返回。

### egl_cache_t 着色器程序缓存初始化
这个缓存的初始化，其实十分重要，是编写OpenGL es的优化点。如果经常编写OpenGL es的朋友就会知道，着色器是一个十分重要的角色，它是为OpenGL es能够如此多样化的根本，但是我们在程序中很难看到着色的编译，链接的过程这是为什么呢？

奥妙就在这里。
```cpp
egl_cache_t egl_cache_t::sCache;

egl_cache_t* egl_cache_t::get() {
    return &sCache;
}

void egl_cache_t::initialize(egl_display_t *display) {
    std::lock_guard<std::mutex> lock(mMutex);

    egl_connection_t* const cnx = &gEGLImpl;
    if (cnx->dso && cnx->major >= 0 && cnx->minor >= 0) {
        const char* exts = display->disp.queryString.extensions;
        size_t bcExtLen = strlen(BC_EXT_STR);
        size_t extsLen = strlen(exts);
        bool equal = !strcmp(BC_EXT_STR, exts);
        bool atStart = !strncmp(BC_EXT_STR " ", exts, bcExtLen+1);
        bool atEnd = (bcExtLen+1) < extsLen &&
                !strcmp(" " BC_EXT_STR, exts + extsLen - (bcExtLen+1));
        bool inMiddle = strstr(exts, " " BC_EXT_STR " ") != nullptr;
        if (equal || atStart || atEnd || inMiddle) {
            PFNEGLSETBLOBCACHEFUNCSANDROIDPROC eglSetBlobCacheFuncsANDROID;
            eglSetBlobCacheFuncsANDROID =
                    reinterpret_cast<PFNEGLSETBLOBCACHEFUNCSANDROIDPROC>(
                            cnx->egl.eglGetProcAddress(
                                    "eglSetBlobCacheFuncsANDROID"));
            if (eglSetBlobCacheFuncsANDROID == NULL) {
                ALOGE("EGL_ANDROID_blob_cache advertised, "
                        "but unable to get eglSetBlobCacheFuncsANDROID");
                return;
            }

            eglSetBlobCacheFuncsANDROID(display->disp.dpy,
                    android::setBlob, android::getBlob);
            EGLint err = cnx->egl.eglGetError();
            if (err != EGL_SUCCESS) {
                ALOGE("eglSetBlobCacheFuncsANDROID resulted in an error: "
                        "%#x", err);
            }
        }
    }

    mInitialized = true;
}
```
这个方法核心有只有一个，首先通过eglGetProcAddress找到eglSetBlobCacheFuncsANDROID方法，并且调用设置缓存set和get的回调。

这个方法干是什么呢？用OpenGL es文档的解释，有的着色器文件太大了，编译和链接花的时间有点大。OpenGL es想到一个方法，那就是通过eglSetBlobCacheFuncsANDROID把二进制的着色器程序直接缓存下来，下次回来找的时候就不需要任何的编译过程，直接读取即可。

```cpp

void egl_cache_t::setBlob(const void* key, EGLsizeiANDROID keySize,
        const void* value, EGLsizeiANDROID valueSize) {
    std::lock_guard<std::mutex> lock(mMutex);

    if (keySize < 0 || valueSize < 0) {
        ALOGW("EGL_ANDROID_blob_cache set: negative sizes are not allowed");
        return;
    }

    if (mInitialized) {
        BlobCache* bc = getBlobCacheLocked();
        bc->set(key, keySize, value, valueSize);

        if (!mSavePending) {
            mSavePending = true;
            std::thread deferredSaveThread([this]() {
                sleep(deferredSaveDelay);
                std::lock_guard<std::mutex> lock(mMutex);
                if (mInitialized && mBlobCache) {
                    mBlobCache->writeToFile();
                }
                mSavePending = false;
            });
            deferredSaveThread.detach();
        }
    }
}

EGLsizeiANDROID egl_cache_t::getBlob(const void* key, EGLsizeiANDROID keySize,
        void* value, EGLsizeiANDROID valueSize) {
    std::lock_guard<std::mutex> lock(mMutex);

    if (keySize < 0 || valueSize < 0) {
        ALOGW("EGL_ANDROID_blob_cache set: negative sizes are not allowed");
        return 0;
    }

    if (mInitialized) {
        BlobCache* bc = getBlobCacheLocked();
        return bc->get(key, keySize, value, valueSize);
    }
    return 0;
}

void egl_set_cache_filename(const char* filename) {
    egl_cache_t::get()->setCacheFilename(filename);
}
```
能看到整个过程实际上由一个BlobCache控制保存起来。它仅仅只是一个简单的vector，通过key换算出index出来，直接插入到vector中。很简单，有兴趣自己去看。其实这种设计挺差的，为什么不干脆一点使用一个LRUCache的设计，干掉最近最少用的缓存呢？

不过这个方法其实不开放给客户端使用，因为不是每一个OpenGL es都实现。那么哪里使用呢？

那就要看谁调用egl_set_cache_filename了。其实就是ThreadedRenderer这个类
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[ThreadedRenderer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/ThreadedRenderer.java)
```cpp
    private static final String CACHE_PATH_SHADERS = "com.android.opengl.shaders_cache";
    private static final String CACHE_PATH_SKIASHADERS = "com.android.skia.shaders_cache";

    public static void setupDiskCache(File cacheDir) {
        ThreadedRenderer.setupShadersDiskCache(
                new File(cacheDir, CACHE_PATH_SHADERS).getAbsolutePath(),
                new File(cacheDir, CACHE_PATH_SKIASHADERS).getAbsolutePath());
    }
```
这个类其实就是硬件加速用到的。这个类这里就不多讨论了，之后聊到硬件加速就会解析到了。

## eglCreateWindowSurface 创建一个OpenGL es的Surface
```cpp
surface = eglCreateWindowSurface(display, config, s.get(), NULL);
```
```cpp
EGLSurface eglCreateWindowSurface(  EGLDisplay dpy, EGLConfig config,
                                    NativeWindowType window,
                                    const EGLint *attrib_list)
{
    const EGLint *origAttribList = attrib_list;
    clearError();

    egl_connection_t* cnx = NULL;
    egl_display_ptr dp = validate_display_connection(dpy, cnx);
    if (dp) {
...

        int value = 0;
        window->query(window, NATIVE_WINDOW_IS_VALID, &value);
...

        int result = native_window_api_connect(window, NATIVE_WINDOW_API_EGL);
...

        EGLDisplay iDpy = dp->disp.dpy;
        android_pixel_format format;
        getNativePixelFormat(iDpy, cnx, config, &format);

        // now select correct colorspace and dataspace based on user's attribute list
        EGLint colorSpace = EGL_UNKNOWN;
        std::vector<EGLint> strippedAttribList;
        if (!processAttributes(dp, window, format, attrib_list, &colorSpace,
                               &strippedAttribList)) {
            ...
            return setError(EGL_BAD_ATTRIBUTE, EGL_NO_SURFACE);
        }
        attrib_list = strippedAttribList.data();

        {
            int err = native_window_set_buffers_format(window, format);
            if (err != 0) {
               ...
                native_window_api_disconnect(window, NATIVE_WINDOW_API_EGL);
                return setError(EGL_BAD_NATIVE_WINDOW, EGL_NO_SURFACE);
            }
        }

        android_dataspace dataSpace = dataSpaceFromEGLColorSpace(colorSpace);
        if (dataSpace != HAL_DATASPACE_UNKNOWN) {
            int err = native_window_set_buffers_data_space(window, dataSpace);
            if (err != 0) {
                native_window_api_disconnect(window, NATIVE_WINDOW_API_EGL);
                return setError(EGL_BAD_NATIVE_WINDOW, EGL_NO_SURFACE);
            }
        }

        ANativeWindow* anw = reinterpret_cast<ANativeWindow*>(window);
        anw->setSwapInterval(anw, 1);

        EGLSurface surface = cnx->egl.eglCreateWindowSurface(
                iDpy, config, window, attrib_list);
        if (surface != EGL_NO_SURFACE) {
            egl_surface_t* s =
                    new egl_surface_t(dp.get(), config, window, surface,
                                      getReportedColorSpace(colorSpace), cnx);
            return s;
        }

        // EGLSurface creation failed
        native_window_set_buffers_format(window, 0);
        native_window_api_disconnect(window, NATIVE_WINDOW_API_EGL);
    }
    return EGL_NO_SURFACE;
}
```
这个方法分为如下几个步骤：
- 1.调用Surface的query 检查当前Surface是否存在图元生产者
- 2.native_window_api_connect 链接SF的图元生产者
- 3.processAttributes 根据颜色模式设置属性
- 4.native_window_set_buffers_format 设置图元的颜色模式
- 5.dataSpaceFromEGLColorSpace 设置OpenGL es颜色模式
- 6. eglCreateWindowSurface 生成EGLSurface对象
- 7.EGLSurface包裹成一个egl_surface_t 对象

### native_window_api_connect
```cpp
static inline int native_window_api_connect(
        struct ANativeWindow* window, int api)
{
    return window->perform(window, NATIVE_WINDOW_API_CONNECT, api);
}
```
最后调用到Surface的perform,又会调用dispatchConnect，接着调用connect方法。

文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[Surface.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/Surface.cpp)

```cpp
int Surface::connect(int api) {
    static sp<IProducerListener> listener = new DummyProducerListener();
    return connect(api, listener);
}

int Surface::connect(int api, const sp<IProducerListener>& listener) {
    return connect(api, listener, false);
}

int Surface::connect(
        int api, const sp<IProducerListener>& listener, bool reportBufferRemoval) {
    ATRACE_CALL();
    ALOGV("Surface::connect");
    Mutex::Autolock lock(mMutex);
    IGraphicBufferProducer::QueueBufferOutput output;
    mReportRemovedBuffers = reportBufferRemoval;
//mProducerControlledByApp 此时为false
    int err = mGraphicBufferProducer->connect(listener, api, mProducerControlledByApp, &output);
    if (err == NO_ERROR) {
        mDefaultWidth = output.width;
        mDefaultHeight = output.height;
        mNextFrameNumber = output.nextFrameNumber;

        if (mStickyTransform == 0) {
            mTransformHint = output.transformHint;
        }

        mConsumerRunningBehind = (output.numPendingBuffers >= 2);
    }
    if (!err && api == NATIVE_WINDOW_API_CPU) {
        mConnectedToCpu = true;
        mDirtyRegion.clear();
    } else if (!err) {
        // Initialize the dirty region for tracking surface damage
        mDirtyRegion = Region::INVALID_REGION;
    }

    return err;
}
```
核心方法就是调用mGraphicBufferProducer->connect联通SF的图元生产者，获取这一块的图元的属性，宽高等。同时清空脏区。mGraphicBufferProducer这个对象最终对应的是BufferQueueProducer。

#### BufferQueueProducer connect 图元缓冲区调整策略
```cpp
status_t BufferQueueProducer::connect(const sp<IProducerListener>& listener,
        int api, bool producerControlledByApp, QueueBufferOutput *output) {
    ATRACE_CALL();
    Mutex::Autolock lock(mCore->mMutex);
    mConsumerName = mCore->mConsumerName;
...

    int delta = mCore->getMaxBufferCountLocked(mCore->mAsyncMode,
            mDequeueTimeout < 0 ?
            mCore->mConsumerControlledByApp && producerControlledByApp : false,
            mCore->mMaxBufferCount) -
            mCore->getMaxBufferCountLocked();
    if (!mCore->adjustAvailableSlotsLocked(delta)) {
        return BAD_VALUE;
    }

    int status = NO_ERROR;
    switch (api) {
        case NATIVE_WINDOW_API_EGL:
        case NATIVE_WINDOW_API_CPU:
        case NATIVE_WINDOW_API_MEDIA:
        case NATIVE_WINDOW_API_CAMERA:
            mCore->mConnectedApi = api;

            output->width = mCore->mDefaultWidth;
            output->height = mCore->mDefaultHeight;
            output->transformHint = mCore->mTransformHint;
            output->numPendingBuffers =
                    static_cast<uint32_t>(mCore->mQueue.size());
            output->nextFrameNumber = mCore->mFrameCounter + 1;
            output->bufferReplaced = false;

            if (listener != NULL) {
                if (IInterface::asBinder(listener)->remoteBinder() != NULL) {
                    status = IInterface::asBinder(listener)->linkToDeath(
                            static_cast<IBinder::DeathRecipient*>(this));
                    if (status != NO_ERROR) {
                    }
                    mCore->mLinkedToDeath = listener;
                }
                if (listener->needsReleaseNotify()) {
                    mCore->mConnectedProducerListener = listener;
                }
            }
            break;
        default:
            status = BAD_VALUE;
            break;
    }
    mCore->mConnectedPid = IPCThreadState::self()->getCallingPid();
    mCore->mBufferHasBeenQueued = false;
    mCore->mDequeueBufferCannotBlock = false;
    if (mDequeueTimeout < 0) {
        mCore->mDequeueBufferCannotBlock =
                mCore->mConsumerControlledByApp && producerControlledByApp;
    }

    mCore->mAllowAllocation = true;
    VALIDATE_CONSISTENCY();
    return status;
}
```
这里做的事情有2件：
- 1.调整Slot的Free和unusedSlot区域
- 2.给QueueBufferOutput赋值参数，以及设置监听到BufferQueueCore中。

关键来看看这一段调整的代码。
```cpp
    int delta = mCore->getMaxBufferCountLocked(mCore->mAsyncMode,
            mDequeueTimeout < 0 ?
            mCore->mConsumerControlledByApp && producerControlledByApp : false,
            mCore->mMaxBufferCount) -
            mCore->getMaxBufferCountLocked();
    if (!mCore->adjustAvailableSlotsLocked(delta)) {
        return BAD_VALUE;
    }
```
先计算当前需要请求的数目和当前的最大缓存数目，最终是通过adjustAvailableSlotsLocked进行调整。

默认是-1.此时是由标志producerControlledByApp&&mCore->mConsumerControlledByApp两个标志控制。mMaxBufferCount默认是64.我们看看这两个方法是什么。
```cpp
int BufferQueueCore::getMaxBufferCountLocked(bool asyncMode,
        bool dequeueBufferCannotBlock, int maxBufferCount) const {
    int maxCount = mMaxAcquiredBufferCount + mMaxDequeuedBufferCount +
            ((asyncMode || dequeueBufferCannotBlock) ? 1 : 0);
    maxCount = std::min(maxBufferCount, maxCount);
    return maxCount;
}

int BufferQueueCore::getMaxBufferCountLocked() const {
    int maxBufferCount = mMaxAcquiredBufferCount + mMaxDequeuedBufferCount +
            ((mAsyncMode || mDequeueBufferCannotBlock) ? 1 : 0);

    // limit maxBufferCount by mMaxBufferCount always
    maxBufferCount = std::min(mMaxBufferCount, maxBufferCount);

    return maxBufferCount;
}
```
无论哪一个计算方式十分相似，当前的BufferQueue最多操作的数量永远是mMaxAcquiredBufferCount(请求要消费的图元)+mMaxDequeuedBufferCount(出队到应用的图元数量)+1(如果是异步模式或者非阻塞模式)。

mMaxDequeuedBufferCount这个可以被图元生产者控制。其实在BufferQueue调用createQueue方法的时候，如果关闭三缓冲就会设置为2。mMaxAcquiredBufferCount被消费者控制调控。

此时有一个mDequeueTimeout计算这个图元到应用是否设置了超时出队超时时间。设置的话，则需要判断producerControlledByApp的标志位，此时为false。或句话说，此时的delta为0.

#### BufferQueueCore adjustAvailableSlotsLocked
```cpp
bool BufferQueueCore::adjustAvailableSlotsLocked(int delta) {
    if (delta >= 0) {
        // If we're going to fail, do so before modifying anything
        if (delta > static_cast<int>(mUnusedSlots.size())) {
            return false;
        }
        while (delta > 0) {
            if (mUnusedSlots.empty()) {
                return false;
            }
            int slot = mUnusedSlots.back();
            mUnusedSlots.pop_back();
            mFreeSlots.insert(slot);
            delta--;
        }
    } else {
        // If we're going to fail, do so before modifying anything
        if (-delta > static_cast<int>(mFreeSlots.size() +
                mFreeBuffers.size())) {
            return false;
        }
        while (delta < 0) {
            if (!mFreeSlots.empty()) {
                auto slot = mFreeSlots.begin();
                clearBufferSlotLocked(*slot);
                mUnusedSlots.push_back(*slot);
                mFreeSlots.erase(slot);
            } else if (!mFreeBuffers.empty()) {
                int slot = mFreeBuffers.back();
                clearBufferSlotLocked(slot);
                mUnusedSlots.push_back(slot);
                mFreeBuffers.pop_back();
            } else {
                return false;
            }
            delta++;
        }
    }
    return true;
}
```
能看到这里有一个差值。如果差值大于等于0.说明需要更加多的Slot，因此缓冲队列中的mUnusedSlots会溢出队首的slot添加到free中。
**mFreeSlots和mUnusedSlots都是存放着mSlot数组对应的index**。

如果delta小于0。说明当前已经超过了需求了。不需要这么多缓存了。先会移除mFreeSlots过多的插槽到mUnusedSlots。再会检测mFreeBuffers，把多余的放到mUnusedSlots。

那么mFreeBuffers和mFreeSlots是什么区别呢？mFreeSlots是指还有缓冲队列中多少空闲的位置给图元缓冲使用。mFreeBuffers是指已经使用了的的图元缓冲，但是没有在工作的。
![Slots的调整.png](https://upload-images.jianshu.io/upload_images/9880421-549fecd2086b0244.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

##### clearBufferSlotLocked 清理slot中的缓存
```cpp
void BufferQueueCore::clearBufferSlotLocked(int slot) {
    BQ_LOGV("clearBufferSlotLocked: slot %d", slot);

    mSlots[slot].mGraphicBuffer.clear();
    mSlots[slot].mBufferState.reset();
    mSlots[slot].mRequestBufferCalled = false;
    mSlots[slot].mFrameNumber = 0;
    mSlots[slot].mAcquireCalled = false;
    mSlots[slot].mNeedsReallocation = true;

    // Destroy fence as BufferQueue now takes ownership
    if (mSlots[slot].mEglFence != EGL_NO_SYNC_KHR) {
        eglDestroySyncKHR(mSlots[slot].mEglDisplay, mSlots[slot].mEglFence);
        mSlots[slot].mEglFence = EGL_NO_SYNC_KHR;
    }
    mSlots[slot].mFence = Fence::NO_FENCE;
    mSlots[slot].mEglDisplay = EGL_NO_DISPLAY;

    if (mLastQueuedSlot == slot) {
        mLastQueuedSlot = INVALID_BUFFER_SLOT;
    }
}
```
能看到，此时一旦释放，就把mSlots中所有内容全部释放。其中mGraphicBuffer图元数据承载者第一次出现。记住它，以后会经常和它打交道。

### OpenGL es的eglCreateWindowSurface
其他就不做研究了，先来看看OpenGL es对应的eglCreateWindowSurface方法。最后会调用到createWindowSurface：

```cpp
static EGLSurface createWindowSurface(EGLDisplay dpy, EGLConfig config,
        NativeWindowType window, const EGLint* /*attrib_list*/)
{
...
    egl_surface_t* surface;
    surface = new egl_window_surface_v2_t(dpy, config, depthFormat,
            static_cast<ANativeWindow*>(window));

    if (!surface->initCheck()) {
        delete surface;
        surface = 0;
    }
    return surface;
}
```
核心是这一段，实际上EGLSurface是指egl_window_surface_v2_t对象，它是继承了egl_surface_t这个类。
```cpp
struct egl_window_surface_v2_t : public egl_surface_t
{
    egl_window_surface_v2_t(
            EGLDisplay dpy, EGLConfig config,
            int32_t depthFormat,
            ANativeWindow* window);

    ~egl_window_surface_v2_t();
    virtual     bool        initCheck() const { return true; } // TODO: report failure if ctor fails
    virtual     EGLBoolean  swapBuffers();
...
    
private:
    status_t lock(ANativeWindowBuffer* buf, int usage, void** vaddr);
    status_t unlock(ANativeWindowBuffer* buf);
    ANativeWindow*   nativeWindow;
    ANativeWindowBuffer*   buffer;
    ANativeWindowBuffer*   previousBuffer;
    int width;
    int height;
//像素数据
    void* bits;
    GGLFormat const* pixelFormatTable;


...
    private:
        Rect storage[4];
        ssize_t count;
    };
    
...
    Rect dirtyRegion;
    Rect oldDirtyRegion;
};
```
终于看到了，音视频开发十分熟悉的东西。一般开发都是通过lock先拿到ANativeWindowBuffer，接着写入数据到里面，最后unlock发送数据。还能看到在这个结构体有两个ANativeWindowBuffer，一个是previousBuffer，另一个buffer。其实这就是双缓冲，里面可以保存了像素数据的前后两帧。

最后initCheck默认返回true。

### eglCreateContext 创建 OpenGL es的运行环境的上下文
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[eglApi.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/eglApi.cpp)
```cpp
static inline
egl_context_t* get_context(EGLContext context) {
    return egl_to_native_cast<egl_context_t>(context);
}
```
```cpp
EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config,
                            EGLContext share_list, const EGLint *attrib_list)
{
    clearError();

    egl_connection_t* cnx = NULL;
    const egl_display_ptr dp = validate_display_connection(dpy, cnx);
    if (dp) {
        if (share_list != EGL_NO_CONTEXT) {
            ...
            egl_context_t* const c = get_context(share_list);
            share_list = c->context;
        }
        EGLContext context = cnx->egl.eglCreateContext(
                dp->disp.dpy, config, share_list, attrib_list);
        if (context != EGL_NO_CONTEXT) {
            // figure out if it's a GLESv1 or GLESv2
            int version = 0;
            if (attrib_list) {
                while (*attrib_list != EGL_NONE) {
                    GLint attr = *attrib_list++;
                    GLint value = *attrib_list++;
                    if (attr == EGL_CONTEXT_CLIENT_VERSION) {
                        if (value == 1) {
                            version = egl_connection_t::GLESv1_INDEX;
                        } else if (value == 2 || value == 3) {
                            version = egl_connection_t::GLESv2_INDEX;
                        }
                    }
                };
            }
            egl_context_t* c = new egl_context_t(dpy, context, config, cnx,
                    version);
            return c;
        }
    }
    return EGL_NO_CONTEXT;
}
```
提醒：share_list这个参数也是一个EGLContext，和一般的EGLContext不同，它是线程间共享。

这个方法本质上还是调用OpenGL es的eglCreateContext，创建本线程上下文。最后把创建后的配置列表拷贝出去，并且使用egl_context_t封装EGLDisplay，EGLContext，还有egl_connection_t。
```cpp
class egl_context_t: public egl_object_t {
protected:
    ~egl_context_t() {}
public:
    typedef egl_object_t::LocalRef<egl_context_t, EGLContext> Ref;

    egl_context_t(EGLDisplay dpy, EGLContext context, EGLConfig config,
            egl_connection_t const* cnx, int version);

    void onLooseCurrent();
    void onMakeCurrent(EGLSurface draw, EGLSurface read);

    EGLDisplay dpy;
    EGLContext context;
    EGLConfig config;
    EGLSurface read;
    EGLSurface draw;
    egl_connection_t const* cnx;
    int version;
    std::string gl_extensions;
    std::vector<std::string> tokenized_gl_extensions;
};
```

#### OpenGL es的eglCreateContext
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)

```cpp
EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config,
                            EGLContext /*share_list*/, const EGLint* /*attrib_list*/)
{
...
    ogles_context_t* gl = ogles_init(sizeof(egl_context_t));
    if (!gl) return setError(EGL_BAD_ALLOC, EGL_NO_CONTEXT);

    egl_context_t* c = static_cast<egl_context_t*>(gl->rasterizer.base);
    c->flags = egl_context_t::NEVER_CURRENT;
    c->dpy = dpy;
    c->config = config;
    c->read = 0;
    c->draw = 0;
    return (EGLContext)gl;
}
```
调用了ogles_init进行初始化，还能看到实际上egl_context_t其实是指ogles_context_t。由于ogles_context_t实在太大，为了能够更加直观的看到它的作用，将会依据着初始化，来看看底层源码出现最多次的纹理绘制的原理,有兴趣的读者可以自己阅读其他模块。

#### ogles_init
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[state.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/state.cpp)

```cpp
ogles_context_t *ogles_init(size_t extra)
{
    void* const base = malloc(extra + sizeof(ogles_context_t) + 32);
    if (!base) return 0;

    ogles_context_t *c =
            (ogles_context_t *)((ptrdiff_t(base) + extra + 31) & ~0x1FL);
    memset(c, 0, sizeof(ogles_context_t));
    ggl_init_context(&(c->rasterizer));

//舒适化Surface的管理器
    sp<EGLSurfaceManager> smgr(new EGLSurfaceManager());
    c->surfaceManager = smgr.get();
    c->surfaceManager->incStrong(c);

    sp<EGLBufferObjectManager> bomgr(new EGLBufferObjectManager());
    c->bufferObjectManager = bomgr.get();
    c->bufferObjectManager->incStrong(c);
//初始化array_t
    ogles_init_array(c);
//初始化tramsform_t
    ogles_init_matrix(c);
//初始化顶点缓冲
    ogles_init_vertex(c);
    ogles_init_light(c);
//初始化纹理
    ogles_init_texture(c);

    c->rasterizer.base = base;
    c->point.size = TRI_ONE;
    c->line.width = TRI_ONE;

    // in OpenGL, writing to the depth buffer is enabled by default.
    c->rasterizer.procs.depthMask(c, 1);

    // OpenGL enables dithering by default
    c->rasterizer.procs.enable(c, GL_DITHER);

    return c;
}
```
首先来看看ogles_context_t这个结构体：
```cpp
struct ogles_context_t {
    context_t               rasterizer;
    array_machine_t         arrays         __attribute__((aligned(32)));
    texture_state_t         textures;
    transform_state_t       transforms;
    vertex_cache_t          vc;
    prims_t                 prims;
    culling_t               cull;
    lighting_t              lighting;
    user_clip_planes_t      clipPlanes;
    compute_iterators_t     lerp           __attribute__((aligned(32)));
//当前的状态
    vertex_t                current;
    vec4_t                  currentColorClamped;
    vec3_t                  currentNormal;
    viewport_t              viewport;
    point_size_t            point;
    line_width_t            line;
    polygon_offset_t        polygonOffset;
    fog_t                   fog;
    uint32_t                perspective : 1;
    uint32_t                transformTextures : 1;
    EGLSurfaceManager*      surfaceManager;
    EGLBufferObjectManager* bufferObjectManager;

    GLenum                  error;

    static inline ogles_context_t* get() {
        return getGlThreadSpecific();
    }
};
```
这个结构体可以说代表了所有OpenGL 操作中关键操作对象：
- 1.context_t ogles_context_t结构体的核心，真正的操作都在这个结构体中完成。
- 2.array_machine_t 调用glDrawArray，glDrawElement的管理机
- 3.textures 调用纹理时候的管理机
- 4.transform_state_t 内置在OpenGL es内部的坐标转化器
- 5.vertex_cache_t 顶点数组对象VAO控制器
- 6.lighting_t 光照管理器
- 7.EGLSurfaceManager 控制EGLTextureObject ，EGLTextureObject管理每一个纹理中的图层。
- 8.EGLBufferObjectManager 管理缓冲数组VBO

对于ogles_context_t来说，更多的作用是管理整个OpenGL es的状态，控制多个图元行为的控制器。但是并非是实际的实现者。真正的实现行为交给context_t。

稍微看看象征着纹理管理器的结构体：
```cpp
struct texture_state_t
{
//纹理单元数组
    texture_unit_t      tmu[GGL_TEXTURE_UNIT_COUNT];
//活跃index
    int                 active;     // active tmu
//默认纹理对象
    EGLTextureObject*   defaultTexture;
    GGLContext*         ggl;
    uint8_t             packAlignment;
    uint8_t             unpackAlignment;
};
```

因此这个方法对应的几个init方法，实际上就是初始化这些管理结构体。其中ggl_init_context则是初始化context_t这个结构体。


#### ggl_init_context context_t的初始化
先来看看context_t的结构体：
```cpp
struct context_t {
	GGLContext          procs;
	state_t             state;
    shade_t             shade;
	iterators_t         iterators;
    generated_vars_t    generated_vars                __attribute__((aligned(32)));
    uint8_t             ditherMatrix[GGL_DITHER_SIZE] __attribute__((aligned(32)));
    uint32_t            packed;
    uint32_t            packed8888;
    const GGLFormat*    formats;
    uint32_t            dirty;
    texture_t*          activeTMU;
    uint32_t            activeTMUIndex;

    void                (*init_y)(context_t* c, int32_t y);
	void                (*step_y)(context_t* c);
	void                (*scanline)(context_t* c);
    void                (*span)(context_t* c);
    void                (*rect)(context_t* c, size_t yc);
    
    void*               base;
    Assembly*           scanline_as;
    GGLenum             error;
};
```
-1.procs GGLContext 里面包含所有像素，顶点，缓存等操作的核心函数指针。
- 2.state_t 是指当前的OpenGL es的状态,换句话说所有的操作焦点都会集中在这个state_t结构体,每一次切换操作都会把当前的state_t指向当前活跃的状态。

比如我们需要激活一个纹理就需要调用一次glActiveText方法。此时id就是指的是state_t中texture_t数组中的id，并且让activeTMU指向texture_t数组中的texture_t以及activeTMUIndex获得道歉活跃纹理的id，并且为context_t设置绘制区域下，线，点的函数。

因此第一次不活跃纹理会绘制不出东西，后面不活跃纹理就会绘制出问题。

```cpp
struct state_t {
//帧缓存
	framebuffer_t		buffers;
	texture_t			texture[GGL_TEXTURE_UNIT_COUNT];
//包含裁剪参数
    scissor_t           scissor;
    raster_t            raster;
	blend_state_t		blend;
    alpha_test_state_t  alpha_test;
    depth_test_state_t  depth_test;
    mask_state_t        mask;
//清除参数
    clear_state_t       clear;
//雾化参数
    fog_state_t         fog;
    logic_op_state_t    logic_op;
    uint32_t            enables;
//纹理是否允许
    uint32_t            enabled_tmu;
    needs_t             needs;
};
```
我们还是集中看看texture_t象征纹理是是一个怎么样子的。
```cpp
struct texture_t {
	surface_t			surface;
	texture_iterators_t	iterators;
    texture_shade_t     shade;
	uint32_t			s_coord;
	uint32_t            t_coord;
	uint16_t			s_wrap;
	uint16_t            t_wrap;
	uint16_t            min_filter;
	uint16_t            mag_filter;
    uint16_t            env;
    uint8_t             env_color[4];
	uint8_t				enable;
	uint8_t				dirty;
};
```
能看到这里面有十分熟悉的参数，有象征2纬的s和t，坐标系。还有fliter图像过滤器。还有更加重要的角色surface_t，它承载着纹理数据。
```cpp
struct surface_t {
    union {
        GGLSurface          s;
        // Keep the following struct field types in line with the corresponding
        // GGLSurface fields to avoid mismatches leading to errors.
        struct {
            GGLsizei        reserved;
            GGLuint         width;
            GGLuint         height;
            GGLint          stride;
            GGLubyte*       data;
            GGLubyte        format;
            GGLubyte        dirty;
            GGLubyte        pad[2];
        };
    };
    void                (*read) (const surface_t* s, context_t* c,
                                uint32_t x, uint32_t y, pixel_t* pixel);
    void                (*write)(const surface_t* s, context_t* c,
                                uint32_t x, uint32_t y, const pixel_t* pixel);
};
```
在surface_t有一个联合体，说明要么只有GGLSurface，下面那个用于解析像素数据的结构体(data数组承载着真正的数据)。还有两个函数指针，一个是读取像素数据，另一个是往data或者GGLSurface写入数据的方法。




文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libpixelflinger](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/)/[pixelflinger.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/pixelflinger.cpp)
```cpp
void ggl_init_procs(context_t* c)
{
    GGLContext& procs = *(GGLContext*)c;
    GGL_INIT_PROC(procs, scissor);
    GGL_INIT_PROC(procs, activeTexture);
    GGL_INIT_PROC(procs, bindTexture);
    GGL_INIT_PROC(procs, bindTextureLod);
    GGL_INIT_PROC(procs, colorBuffer);
    GGL_INIT_PROC(procs, readBuffer);
    GGL_INIT_PROC(procs, depthBuffer);
    GGL_INIT_PROC(procs, enable);
    GGL_INIT_PROC(procs, disable);
    GGL_INIT_PROC(procs, enableDisable);
    GGL_INIT_PROC(procs, shadeModel);
    GGL_INIT_PROC(procs, color4xv);
    GGL_INIT_PROC(procs, colorGrad12xv);
    GGL_INIT_PROC(procs, zGrad3xv);
    GGL_INIT_PROC(procs, wGrad3xv);
    GGL_INIT_PROC(procs, fogGrad3xv);
    GGL_INIT_PROC(procs, fogColor3xv);
    GGL_INIT_PROC(procs, blendFunc);
    GGL_INIT_PROC(procs, blendFuncSeparate);
    GGL_INIT_PROC(procs, texEnvi);
    GGL_INIT_PROC(procs, texEnvxv);
    GGL_INIT_PROC(procs, texParameteri);
    GGL_INIT_PROC(procs, texCoord2i);
    GGL_INIT_PROC(procs, texCoord2x);
    GGL_INIT_PROC(procs, texCoordGradScale8xv);
    GGL_INIT_PROC(procs, texGeni);
    GGL_INIT_PROC(procs, colorMask);
    GGL_INIT_PROC(procs, depthMask);
    GGL_INIT_PROC(procs, stencilMask);
    GGL_INIT_PROC(procs, alphaFuncx);
    GGL_INIT_PROC(procs, depthFunc);
    GGL_INIT_PROC(procs, logicOp);
    ggl_init_clear(c);
}
```
其实这个方法很简单就是给GGLContext赋值函数指针。让上下文中的OpenGL es真正拥有了操作像素的核心能力。

接下来看看初始化纹理管理器做了什么。

#### ogles_init_texture 始化纹理管理器
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[texture.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/texture.cpp)
```cpp
const int GGL_TEXTURE_UNIT_COUNT = 2;

void ogles_init_texture(ogles_context_t* c)
{
    c->textures.packAlignment   = 4;
    c->textures.unpackAlignment = 4;

    // each context has a default named (0) texture (not shared)
    c->textures.defaultTexture = new EGLTextureObject();
    c->textures.defaultTexture->incStrong(c);

    // bind the default texture to each texture unit
    for (int i=0; i<GGL_TEXTURE_UNIT_COUNT ; i++) {
        bindTextureTmu(c, i, 0, c->textures.defaultTexture);
        memset(c->current.texture[i].v, 0, sizeof(vec4_t));
        c->current.texture[i].Q = 0x10000;
    }
}
```
为ogles_context_t中texture_state_t的defaultTexture设置一个默认的纹理。接着调用bindTextureTmu初始化texture_state_t中数组中的内容。并且初始化current(当前操作的状态)的纹理数据。


```cpp
void bindTextureTmu(
    ogles_context_t* c, int tmu, GLuint texture, const sp<EGLTextureObject>& tex)
{
    if (tex.get() == c->textures.tmu[tmu].texture)
        return;

    // free the reference to the previously bound object
    texture_unit_t& u(c->textures.tmu[tmu]);
    if (u.texture)
        u.texture->decStrong(c);

    // bind this texture to the current active texture unit
    // and add a reference to this texture object
    u.texture = tex.get();
    u.texture->incStrong(c);
    u.name = texture;
    invalidate_texture(c, tmu);
}

static
void invalidate_texture(ogles_context_t* c, int tmu, uint8_t flags = 0xFF) {
    c->textures.tmu[tmu].dirty = flags;
}
```

能看到此时实际上texture_unit_t所有所有的元素都指向这个默认的空纹理。并且设置每一个的纹理的dirty状态。

让我们绘制一个UML图，来总结他们的关系
![纹理结构.png](https://upload-images.jianshu.io/upload_images/9880421-9da836d8609b6e83.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

实际上指的是egl_context_t中的 EGLContext是ogles_context_t结构体。

### eglMakeCurrent 绑定线程，屏幕，surface生成OpenGL es环境
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[eglApi.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/eglApi.cpp)

```cpp
static inline EGLContext getContext() { return egl_tls_t::getContext(); }

EGLBoolean eglMakeCurrent(  EGLDisplay dpy, EGLSurface draw,
                            EGLSurface read, EGLContext ctx)
{
    clearError();

    egl_display_ptr dp = validate_display(dpy);
...
    ContextRef _c(dp.get(), ctx);
    SurfaceRef _d(dp.get(), draw);
    SurfaceRef _r(dp.get(), read);

...
    EGLContext impl_ctx  = EGL_NO_CONTEXT;
    EGLSurface impl_draw = EGL_NO_SURFACE;
    EGLSurface impl_read = EGL_NO_SURFACE;

    egl_context_t       * c = NULL;
    egl_surface_t const * d = NULL;
    egl_surface_t const * r = NULL;
//获取当前的线程上下文
    egl_context_t * cur_c = get_context(getContext());

    if (ctx != EGL_NO_CONTEXT) {
        c = get_context(ctx);
        impl_ctx = c->context;
    } else {
        ...
    }

    if (draw != EGL_NO_SURFACE) {
       ...
        d = get_surface(draw);
        impl_draw = d->surface;
    }

    if (read != EGL_NO_SURFACE) {
        ...
        r = get_surface(read);
        impl_read = r->surface;
    }


    EGLBoolean result = dp->makeCurrent(c, cur_c,
            draw, read, ctx,
            impl_draw, impl_read, impl_ctx);

    if (result == EGL_TRUE) {
        if (c) {
            setGLHooksThreadSpecific(c->cnx->hooks[c->version]);
            egl_tls_t::setContext(ctx);
            _c.acquire();
            _r.acquire();
            _d.acquire();
        } else {
            setGLHooksThreadSpecific(&gHooksNoContext);
            egl_tls_t::setContext(EGL_NO_CONTEXT);
        }
    } else {

...
        }
        egl_connection_t* const cnx = &gEGLImpl;
        result = setError(cnx->egl.eglGetError(), (EGLBoolean)EGL_FALSE);
    }
    return result;
}
```

做的事情如下：
- 1.获取每个EGLSurface中的egl_surface_t对象，并且作为参数并且调用egl_display_ptr的makeCurrent方法。
- 2.setGLHooksThreadSpecific 把当前的上下文和当前的线程绑定起来。

#### egl_display_ptr 的makeCurrent
还记得egl_display_ptr这个其实是egl_display_t的地址吗。其实这里就是egl_display_t的makeCurrent。

```cpp
EGLBoolean egl_display_t::makeCurrent(egl_context_t* c, egl_context_t* cur_c,
        EGLSurface draw, EGLSurface read, EGLContext /*ctx*/,
        EGLSurface impl_draw, EGLSurface impl_read, EGLContext impl_ctx)
{
    EGLBoolean result;

    ContextRef _cur_c(cur_c);
    SurfaceRef _cur_r(cur_c ? get_surface(cur_c->read) : NULL);
    SurfaceRef _cur_d(cur_c ? get_surface(cur_c->draw) : NULL);

    { // scope for the lock
        std::lock_guard<std::mutex> _l(lock);
        if (c) {
            result = c->cnx->egl.eglMakeCurrent(
                    disp.dpy, impl_draw, impl_read, impl_ctx);
            if (result == EGL_TRUE) {
                c->onMakeCurrent(draw, read);
            }
        } else {
          ....
        }
    }

    if (result == EGL_TRUE) {
        _cur_c.release();
        _cur_r.release();
        _cur_d.release();
    }

    return result;
}
```
其实这里就是调用OpenGL es的eglMakeCurrent。

#### OpenGL es的eglMakeCurrent
文件：[ameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)
```cpp
EGLBoolean eglMakeCurrent(  EGLDisplay dpy, EGLSurface draw,
                            EGLSurface read, EGLContext ctx)
{
...
    if (draw) {
//检测draw的合法
        egl_surface_t* s = (egl_surface_t*)draw;
        if (!s->isValid())
            return setError(EGL_BAD_SURFACE, EGL_FALSE);
        if (s->dpy != dpy)
            return setError(EGL_BAD_DISPLAY, EGL_FALSE);
        // TODO: check that draw is compatible with the context
    }
    if (read && read!=draw) {
//检测read的合法
        egl_surface_t* s = (egl_surface_t*)read;
        if (!s->isValid())
            return setError(EGL_BAD_SURFACE, EGL_FALSE);
        if (s->dpy != dpy)
            return setError(EGL_BAD_DISPLAY, EGL_FALSE);
        // TODO: check that read is compatible with the context
    }

    EGLContext current_ctx = EGL_NO_CONTEXT;

...

    if (ctx == EGL_NO_CONTEXT) {
...
    } else {
//检测read和draw是否在一个线程
        egl_surface_t* d = (egl_surface_t*)draw;
        egl_surface_t* r = (egl_surface_t*)read;
        if ((d && d->ctx && d->ctx != ctx) ||
            (r && r->ctx && r->ctx != ctx)) {
            // one of the surface is bound to a context in another thread
            return setError(EGL_BAD_ACCESS, EGL_FALSE);
        }
    }

    ogles_context_t* gl = (ogles_context_t*)ctx;
    if (makeCurrent(gl) == 0) {
        if (ctx) {
            egl_context_t* c = egl_context_t::context(ctx);
            egl_surface_t* d = (egl_surface_t*)draw;
            egl_surface_t* r = (egl_surface_t*)read;
            
            if (c->draw) {
                egl_surface_t* s = reinterpret_cast<egl_surface_t*>(c->draw);
                s->disconnect();
                s->ctx = EGL_NO_CONTEXT;
                if (s->zombie)
                    delete s;
            }
            if (c->read) {
                // FIXME: unlock/disconnect the read surface too 
            }
            
            c->draw = draw;
            c->read = read;

            if (c->flags & egl_context_t::NEVER_CURRENT) {
                c->flags &= ~egl_context_t::NEVER_CURRENT;
                GLint w = 0;
                GLint h = 0;
                if (draw) {
                    w = d->getWidth();
                    h = d->getHeight();
                }
                ogles_surfaceport(gl, 0, 0);
                ogles_viewport(gl, 0, 0, w, h);
                ogles_scissor(gl, 0, 0, w, h);
            }
            if (d) {
                if (d->connect() == EGL_FALSE) {
                    return EGL_FALSE;
                }
                d->ctx = ctx;
                d->bindDrawSurface(gl);
            }
            if (r) {
                // FIXME: lock/connect the read surface too 
                r->ctx = ctx;
                r->bindReadSurface(gl);
            }
        } else {
           ...
        }
        return EGL_TRUE;
    }
    return setError(EGL_BAD_ACCESS, EGL_FALSE);
}
```
- 1.检测draw和read两个需要绑定的合法性，并且必须实在同一个线程中
- 2.makeCurrent绑定当前的ogles_context_t
- 3.绑定成功，如果当前的egl_context_t保存一个draw和read两个Surface，会disconnect draw的Surface，但是read的没做事。清空当前ogles_context_t的状态。
- 5.调用egl_window_surface_v2_t 的connect方法，初始化surface中的参数
- 4.bindDrawSurface绑定Draw和Read 绑定Surface的绘制缓冲区

##### egl_window_surface_v2_t connect 初始化图元ANativeWindowBuffer
```cpp
EGLBoolean egl_window_surface_v2_t::connect() 
{
    // we're intending to do software rendering
    native_window_set_usage(nativeWindow, 
            GRALLOC_USAGE_SW_READ_OFTEN | GRALLOC_USAGE_SW_WRITE_OFTEN);

    // dequeue a buffer
    int fenceFd = -1;
    if (nativeWindow->dequeueBuffer(nativeWindow, &buffer,
            &fenceFd) != NO_ERROR) {
        return setError(EGL_BAD_ALLOC, EGL_FALSE);
    }

    // wait for the buffer
    sp<Fence> fence(new Fence(fenceFd));
    if (fence->wait(Fence::TIMEOUT_NEVER) != NO_ERROR) {
        nativeWindow->cancelBuffer(nativeWindow, buffer, fenceFd);
        return setError(EGL_BAD_ALLOC, EGL_FALSE);
    }

    // allocate a corresponding depth-buffer
    width = buffer->width;
    height = buffer->height;
    if (depth.format) {
        depth.width   = width;
        depth.height  = height;
        depth.stride  = depth.width; // use the width here
        uint64_t allocSize = static_cast<uint64_t>(depth.stride) *
                static_cast<uint64_t>(depth.height) * 2;
        if (depth.stride < 0 || depth.height > INT_MAX ||
                allocSize > UINT32_MAX) {
            return setError(EGL_BAD_ALLOC, EGL_FALSE);
        }
        depth.data    = (GGLubyte*)malloc(allocSize);
        if (depth.data == 0) {
            return setError(EGL_BAD_ALLOC, EGL_FALSE);
        }
    }

    buffer->common.incRef(&buffer->common);

    // pin the buffer down
    if (lock(buffer, GRALLOC_USAGE_SW_READ_OFTEN | 
            GRALLOC_USAGE_SW_WRITE_OFTEN, &bits) != NO_ERROR) {
...
        return setError(EGL_BAD_ACCESS, EGL_FALSE);
        // FIXME: we should make sure we're not accessing the buffer anymore
    }
    return EGL_TRUE;
}
```
connect中实现了如下几个核心逻辑：
- 1.调用nativeWindow(也就是Surface)的dequeueBuffer，获得从图元生产者获得一个图元，也就是ANativeBuffer。
- 2.根据返回的图元参数，也记录在当前的egl_window_surface_v2_t中。
- 3.调用lock方法。
dequeueBuffer的逻辑先放放，稍后的文章有聊到。我们来看看lock方法。

```cpp
status_t egl_window_surface_v2_t::lock(
        ANativeWindowBuffer* buf, int usage, void** vaddr)
{
    auto& mapper = GraphicBufferMapper::get();
    return mapper.lock(buf->handle, usage,
            android::Rect(buf->width, buf->height), vaddr);
}
```
此时会使用一个单例GraphicBufferMapper，调用lock方法从gralloc中申请一段内存出来。值得注意的是后面那个vaddr也就是egl_window_surface_v2_t中的bits字段，实际上指向的是buf中的handle的base地址，两者在共享一块内存地址。



##### 绑定Surface的绘制缓冲区
```cpp
EGLBoolean egl_window_surface_v2_t::bindDrawSurface(ogles_context_t* gl)
{
    GGLSurface buffer;
    buffer.version = sizeof(GGLSurface);
    buffer.width   = this->buffer->width;
    buffer.height  = this->buffer->height;
    buffer.stride  = this->buffer->stride;
    buffer.data    = (GGLubyte*)bits;
    buffer.format  = this->buffer->format;
    gl->rasterizer.procs.colorBuffer(gl, &buffer);
    if (depth.data != gl->rasterizer.state.buffers.depth.data)
        gl->rasterizer.procs.depthBuffer(gl, &depth);

    return EGL_TRUE;
}
EGLBoolean egl_window_surface_v2_t::bindReadSurface(ogles_context_t* gl)
{
    GGLSurface buffer;
    buffer.version = sizeof(GGLSurface);
    buffer.width   = this->buffer->width;
    buffer.height  = this->buffer->height;
    buffer.stride  = this->buffer->stride;
    buffer.data    = (GGLubyte*)bits; // FIXME: hopefully is is LOCKED!!!
    buffer.format  = this->buffer->format;
    gl->rasterizer.procs.readBuffer(gl, &buffer);
   }
```
能看到在egl_window_surface_v2_t中的window中的bits数据数组地址和GGLSurface绑定起来。并且调用procs的colorBuffer和procs的readBuffer

procs其实就是GGLContext。。这样就把context_t和Android的Surface关联起来，只有这样OpenGL 想要显示的时候，才能把图元画到硬件。


```cpp
static void ggl_colorBuffer(void* con, const GGLSurface* surface)
{
    GGL_CONTEXT(c, con);
    if (surface->format != c->state.buffers.color.format)
        ggl_state_changed(c, GGL_CB_STATE);

    if (surface->width > c->state.buffers.coverageBufferSize) {
        // allocate the coverage factor buffer
        free(c->state.buffers.coverage);
        c->state.buffers.coverage = (int16_t*)malloc(surface->width * 2);
        c->state.buffers.coverageBufferSize =
                c->state.buffers.coverage ? surface->width : 0;
    }
    ggl_set_surface(c, &(c->state.buffers.color), surface);
    if (c->state.buffers.read.format == 0) {
        ggl_set_surface(c, &(c->state.buffers.read), surface);
    }
    ggl_set_scissor(c);
}
```

```cpp
void ggl_set_surface(context_t* c, surface_t* dst, const GGLSurface* src)
{
    dst->width = src->width;
    dst->height = src->height;
    dst->stride = src->stride;
    dst->data = src->data;
    dst->format = src->format;
    dst->dirty = 1;
    if (__builtin_expect(dst->stride < 0, false)) {
        const GGLFormat& pixelFormat(c->formats[dst->format]);
        const int32_t bpr = -dst->stride * pixelFormat.size;
        dst->data += bpr * (dst->height-1);
    }
}
```
从这里面看到只是简单的赋值，因此这里的意思就是把context_t中的buffer是framebuffer_t结构体，这个结构体是：
```cpp
struct framebuffer_t {
    surface_t           color;
    surface_t           read;
	surface_t			depth;
	surface_t			stencil;
    int16_t             *coverage;
    size_t              coverageBufferSize;
};
```
在这个帧缓存中，有两个surface_t，color和read就是我们那外面两个传进来Surface。

如果OpenGL es想要联通Android系统由于surface_t中的像素地址是共同，因此OpenGL es操作了里面的像素，也等于操作了ANativeWindow中的像素数据。


#### makeCurrent
```
static int makeCurrent(ogles_context_t* gl)
{
    ogles_context_t* current = (ogles_context_t*)getGlThreadSpecific();
    if (gl) {
        egl_context_t* c = egl_context_t::context(gl);
        if (c->flags & egl_context_t::IS_CURRENT) {
           ...
        } else {
            if (current) {
                // mark the current context as not current, and flush
                glFlush();
                egl_context_t::context(current)->flags &= ~egl_context_t::IS_CURRENT;
            }
        }
        if (!(c->flags & egl_context_t::IS_CURRENT)) {
            // The context is not current, make it current!
            setGlThreadSpecific(gl);
            c->flags |= egl_context_t::IS_CURRENT;
        }
    } else {
        if (current) {
            // mark the current context as not current, and flush
            glFlush();
            egl_context_t::context(current)->flags &= ~egl_context_t::IS_CURRENT;
        }
        // this thread has no context attached to it
        setGlThreadSpecific(0);
    }
    return 0;
}
```
这里也很简单，其实也是在OpenGL es服务端也保存一份当前线程上下文，为了能够快速查找。


# 总结
本文介绍了OpenGL es环境的初始化，下面是总结：
- 1. eglGetDisplay 做了两件事情，加载OpenGL es的so库，获取一个屏幕句柄对象。此时的EGLDisplay 其实就是egl_display_t。并且保存在数组中
- 2.eglInitialize 设置了EGLDisplay的状态。同时初始化着色器缓存。
- 3. eglChooseConfig 获取当前OpenGL es提供的参数中最佳参数
- 4. eglCreateWindowSurface 先调用调用了query检查图元生产者是否存在，connect调整SF的图元生产者的Slot策略，获取颜色格式。最后在OpenGL es创建一个egl_window_surface_v2_t(继承egl_surface_t)对应上当前的EGLSurface，并包裹成egl_surface_t返回。
- 5. eglCreateContext 创建一个OpenGL es的上下文。所有的运行都基于这个ogles_context_t结构体，真正的核心是context_t,其中state_t是当前状态集合结构体。ogles_context_t就对应上EGLContext，同时EGLContext被包装成egl_context_t返回。
- 6. eglMakeCurrent 绑定ogles_context_t结构体到当前线程，同时把ogles_context_t中context_t的state_t中的framebuffer_t的surface和Android的Surface数据存储地址关联起来，也就和ANativeWindowBuffer关联起来，形成一个联动。

只有完成这六步骤，才是完成一个OpenGL es的初始化。

![OpenGL 上下文结构.png](https://upload-images.jianshu.io/upload_images/9880421-04531d8ab3d783fe.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

我们终于剖开了OpenGL es第一层神秘面纱了。整体和系统之间的设计如下：

![OpenGL es设计.png](https://upload-images.jianshu.io/upload_images/9880421-5d021a54b24ea912.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

## 思考
我最早以为OpenGL es的服务端是显卡驱动厂商提供的驱动程序，有直接的协议访问显示那一块的内存的权限，直接通过自己的GPU计算完毕之后，就输入到硬件。但是实际并非如此，显卡仅仅只是一个超级计算机单元，并没有权限直接写数据到屏幕上。

如果熟悉OpenGL 和OpenCV的朋友就知道，在图像学中会经常和矩阵，循环计算打交道。这种计算每一段简单，但是时间复杂度很高。因此显卡作为多个简单的计算单元的超级组件，就能很轻松的胜任这个事情。那么显卡仅仅只是一个计算硬件，那用来加速人工智能的计算也是正常的。

虽然屏蔽了管道的原理，不过经过阅读源码，我突然想起为什么ui必须在主线程中完成？其实ui是可以多线程更新的，之前一段时间阅读了Litho的源码，还有听说了腾讯那边多线程更新ui的设计之后，他们并非是多个线程操作更新ui，而是让ui始终保持在业务逻辑之外的线程外，保证两者不耦合。不过创建的onCreate还是主线程，之后onResume通过Hook成为异步更新的线程。

那么所谓多线程更新ui，其实只是把ui放在一个ui线程，业务在业务线程中，成为一个并行的设计。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-871be68ad022ec20.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

问题就变成了为什么必须保证ui不能被多个线程同时更新。经过阅读本次源码之后，其实发现这背后真正的设计思想是一个Surface最好被同一个线程持有更新，不要多线程操作Surface。不管是OpenGL es处理图像信息，还是SF处理图元缓冲插槽，都尽可能减少上线程互斥锁，那么就有可能是一个线程不安全的操作。当然这样的考虑也是理所当然的，上锁了就会调用到内核api这样就会降低整个系统的处理像素的速度，从而帧数。

也正是因为这种设计，Android才强制在主线程更新ui。


好了，思考总结到这里，为了进一步理解OpenGL es结构体，下一篇文章将会和大家聊聊，纹理的绘制原理是怎么回事。


