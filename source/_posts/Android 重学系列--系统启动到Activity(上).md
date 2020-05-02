---
title: Android 重学系列--系统启动到Activity
top: false
cover: false
date: 2019-02-25 16:39:11
img: 
description:
author: yjy239
summary:
tags: 
- Android
- Linux
- Android Framework
---


# 背景
为什么要写这个，是因为做android到今天，发现自己的基础不牢固，很多东西早年明白是怎么回事，下意识的知道怎么做，android这一块做久了过多的思考业务与设计，反而原理开始模模糊糊了。但是探究其原因，是过久没接触，成为了下意识行为。这是个不好的信号，也是一个不好的开始。最近又听闻在tx的哥们，以及面试大厂成功的哥们，一问起他们的面试题，以及工作情况，原以为自己的水平还算过的去，发现自己在腾讯连个t2等级的岗位都感觉很悬，真的是坐井观天。

于是今天我要端正态度，下定决心从头开始复习，为自己的基础打牢固，希望自己能够持之以恒，让自己走到更高的高度。那么就从我们最熟悉的四大组件的Activity开始吧。

从这次开始，我会将长博客分开几次来写。不会像之前的，一次性写完。主要是发现一口气写完数万字，可读性太差了。


# 正文
Activity的生命周期有七大生命周期：onCreate,onStart,onResume,onStop,onPause,onDestroy,onRestart.为什么这么划分，这么划分有什么好处，这些生命周期分别在做什么，在经历这些生命周期之前，Android做了又做了什么行为，这一切的一切值得让人探讨。

从系统启动到Activity。我们启动系统，到界面点击App的图标开始，研究Activity吧。

接下来，所有的源码都来自Android 7.0系统。

# 系统启动

从系统启动开始复习。我想起我当时的毕业设计，是第一次真正意义上的接触Linux系统。现在要把这些知识，从脑海中回忆整理出来。

Android系统的内核实际上是一个Linux内核，系统的一切启动，都是从Linux内核开始启动。

复习一下，Linux系统启动流程：
Linux启动流程大致分为2个步骤：
引导和启动。

##### 引导：
分为BIOS上电子检(POST)和引导装载程序（GRUB）

##### 启动
内核引导，内核init初始化，启动 systemd，其是所有进程之父。


## Android系统启动
这里Android启动流程系统稍微有点不一样。
这里借别人的一幅图：
![启动流程.png](/images/启动流程.png)

到了BootLoader内核引导程序的装载之后，会启动Linux内核。此时Linux内核就去启动第一个进程，init进程。

启动进程，那么一定会启动到init.cpp中的main函数。


文件：/[system](http://androidxref.com/7.0.0_r1/xref/system/)/[core](http://androidxref.com/7.0.0_r1/xref/system/core/)/[init](http://androidxref.com/7.0.0_r1/xref/system/core/init/)/[init.cpp](http://androidxref.com/7.0.0_r1/xref/system/core/init/init.cpp)

```cpp
Parser& parser = Parser::GetInstance();
parser.AddSectionParser("service",std::make_unique<ServiceParser>());
parser.AddSectionParser("on", std::make_unique<ActionParser>());
parser.AddSectionParser("import", std::make_unique<ImportParser>());
parser.ParseConfig("/init.rc");
```

此时会通过Parser方法去解析当前目录下的init.rc文件中的语法。
文件开头会配置下面这个文件：
```
import /init.${ro.zygote}.rc
```
这里稍微提一下rc的语法，import的意思和js里面css的import意思很相近，就是解析这个文件里面的内容。

此时会判断当前系统的位数是多少。现在就以32位为例子。
此时对应的文件就会替换中间的变量变成init.zygote32.rc.

```
service zygote /system/bin/app_process -Xzygote /system/bin --zygote --start-system-server
    class main
    socket zygote stream 660 root system
    onrestart write /sys/android_power/request_state wake
    onrestart write /sys/power/state on
    onrestart restart audioserver
    onrestart restart cameraserver
    onrestart restart media
    onrestart restart netd
    writepid /dev/cpuset/foreground/tasks /dev/stune/foreground/tasks
```
此时rc的脚本，意思是service是启动一个服务名字是zygote，通过/system/bin/app_process。 此时为zygote创建socket，访问权限600，onrestrat是指当这些服务需要重新启动时，执行重新启动。更多相关可以去看看：/[system](http://androidxref.com/7.0.0_r1/xref/system/)/[core](http://androidxref.com/7.0.0_r1/xref/system/core/)/[init](http://androidxref.com/7.0.0_r1/xref/system/core/init/)/[readme.txt](http://androidxref.com/7.0.0_r1/xref/system/core/init/readme.txt)

我们转到/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[cmds](http://androidxref.com/7.0.0_r1/xref/frameworks/base/cmds/)/[app_process](http://androidxref.com/7.0.0_r1/xref/frameworks/base/cmds/app_process/)/[app_main.cpp](http://androidxref.com/7.0.0_r1/xref/frameworks/base/cmds/app_process/app_main.cpp)

找到下个核心，Zygote启动主函数。

### Zygote（孵化进程）启动
Zygote从名字上就知道，这个初始进程的作用像一个母鸡一样，孵化所有的App的进程。

```cpp
int main(int argc, char* const argv[])
{
    ...
    AppRuntime runtime(argv[0], computeArgBlockSize(argc, argv));
    ...
    // Parse runtime arguments.  Stop at first unrecognized option.
//解析命令
    bool zygote = false;
    bool startSystemServer = false;
    bool application = false;
    String8 niceName;
    String8 className;

    ++i;  // Skip unused "parent dir" argument.
    while (i < argc) {
        const char* arg = argv[i++];
        if (strcmp(arg, "--zygote") == 0) {
            zygote = true;
            niceName = ZYGOTE_NICE_NAME;
        } else if (strcmp(arg, "--start-system-server") == 0) {
            startSystemServer = true;
        } else if (strcmp(arg, "--application") == 0) {
            application = true;
        } else if (strncmp(arg, "--nice-name=", 12) == 0) {
            niceName.setTo(arg + 12);
        } else if (strncmp(arg, "--", 2) != 0) {
            className.setTo(arg);
            break;
        } else {
            --i;
            break;
        }
    }

    Vector<String8> args;
    if (!className.isEmpty()) {
        // We're not in zygote mode, the only argument we need to pass
        // to RuntimeInit is the application argument.
        //
        // The Remainder of args get passed to startup class main(). Make
        // copies of them before we overwrite them with the process name.
        args.add(application ? String8("application") : String8("tool"));
        runtime.setClassNameAndArgs(className, argc - i, argv + i);
    } else {
...
//设置启动模式
    if (zygote) {
        runtime.start("com.android.internal.os.ZygoteInit", args, zygote);
    } else if (className) {
        runtime.start("com.android.internal.os.RuntimeInit", args, zygote);
    } else {
        fprintf(stderr, "Error: no class name or --zygote supplied.\n");
        app_usage();
        LOG_ALWAYS_FATAL("app_process: no class name or --zygote supplied.");
        return 10;
    }
}
```
实际上这里主要分两步：
第一步：解析刚才传进来的配置。
第二步：根据配置来决定app_main启动模式

根据我们的命令我们可以知道系统启动调用的命令会使得zygote标识位为true。

此时进入到ZygoteInit里面初始化。在这之前，我们看看这个runtime对象在start方法做了什么事情。AppRuntime继承于AndroidRuntime

文件：/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[core](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/)/[jni](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/jni/)/[AndroidRuntime.cpp](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/jni/AndroidRuntime.cpp)
#### AndroidRuntime::start
```cpp
void AndroidRuntime::start(const char* className, const Vector<String8>& options, bool zygote)
{
    ALOGD(">>>>>> START %s uid %d <<<<<<\n",
            className != NULL ? className : "(unknown)", getuid());

    static const String8 startSystemServer("start-system-server");

    /*
     * 'startSystemServer == true' means runtime is obsolete and not run from
     * init.rc anymore, so we print out the boot start event here.
     */
    for (size_t i = 0; i < options.size(); ++i) {
        if (options[i] == startSystemServer) {
           /* track our progress through the boot sequence */
           const int LOG_BOOT_PROGRESS_START = 3000;
           LOG_EVENT_LONG(LOG_BOOT_PROGRESS_START,  ns2ms(systemTime(SYSTEM_TIME_MONOTONIC)));
        }
    }
//确认Android目录环境
    const char* rootDir = getenv("ANDROID_ROOT");
    if (rootDir == NULL) {
        rootDir = "/system";
        if (!hasDir("/system")) {
            LOG_FATAL("No root directory specified, and /android does not exist.");
            return;
        }
        setenv("ANDROID_ROOT", rootDir, 1);
    }

    //const char* kernelHack = getenv("LD_ASSUME_KERNEL");
    //ALOGD("Found LD_ASSUME_KERNEL='%s'\n", kernelHack);
//启动虚拟机
    /* start the virtual machine */
    JniInvocation jni_invocation;
    jni_invocation.Init(NULL);
    JNIEnv* env;
    if (startVm(&mJavaVM, &env, zygote) != 0) {
        return;
    }
    onVmCreated(env);

//注册jni方法
    /*
     * Register android functions.
     */
    if (startReg(env) < 0) {
        ALOGE("Unable to register all android natives\n");
        return;
    }

//准备好环境之后，为传入的选项转化为java 层的String对象
    /*
     * We want to call main() with a String array with arguments in it.
     * At present we have two arguments, the class name and an option string.
     * Create an array to hold them.
     */
    jclass stringClass;
    jobjectArray strArray;
    jstring classNameStr;

    stringClass = env->FindClass("java/lang/String");
    assert(stringClass != NULL);
    strArray = env->NewObjectArray(options.size() + 1, stringClass, NULL);
    assert(strArray != NULL);
    classNameStr = env->NewStringUTF(className);
    assert(classNameStr != NULL);
    env->SetObjectArrayElement(strArray, 0, classNameStr);

    for (size_t i = 0; i < options.size(); ++i) {
        jstring optionsStr = env->NewStringUTF(options.itemAt(i).string());
        assert(optionsStr != NULL);
        env->SetObjectArrayElement(strArray, i + 1, optionsStr);
    }

//根据传进来的class name,反射启动对应的类
    /*
     * Start VM.  This thread becomes the main thread of the VM, and will
     * not return until the VM exits.
     */
    char* slashClassName = toSlashClassName(className);
    jclass startClass = env->FindClass(slashClassName);
    if (startClass == NULL) {
        ALOGE("JavaVM unable to locate class '%s'\n", slashClassName);
        /* keep going */
    } else {
        jmethodID startMeth = env->GetStaticMethodID(startClass, "main",
            "([Ljava/lang/String;)V");
        if (startMeth == NULL) {
            ALOGE("JavaVM unable to find main() in '%s'\n", className);
            /* keep going */
        } else {
            env->CallStaticVoidMethod(startClass, startMeth, strArray);

#if 0
            if (env->ExceptionCheck())
                threadExitUncaughtException(env);
#endif
        }
    }
    free(slashClassName);

    ALOGD("Shutting down VM\n");
    if (mJavaVM->DetachCurrentThread() != JNI_OK)
        ALOGW("Warning: unable to detach main thread\n");
    if (mJavaVM->DestroyJavaVM() != 0)
        ALOGW("Warning: VM did not shut down cleanly\n");
}
```

这个方法实际上包含了极大量的工作。此时我们能看到的是Zygote从app_main的入口想要启动ZyogteInit的类。我们看到这个签名就知道这是Android系统启动以来第一个要加载的Java类。那么此时我们必须保证虚拟机启动完成。

所以AndroidRunTime要进行的步骤一共为三大步骤：

- 1.初始化虚拟机
- 2.注册jni方法
- 3.反射启动ZygoteInit。

### 1.初始化虚拟机
```cpp
    JniInvocation jni_invocation;
    jni_invocation.Init(NULL);
    JNIEnv* env;
    if (startVm(&mJavaVM, &env, zygote) != 0) {
        return;
    }
    onVmCreated(env);
```
我们来研究看看这几个方法究竟做了啥。
先看看jni_invocation的初始化方法
```cpp
    JniInvocation jni_invocation;
    jni_invocation.Init(NULL);
```
```cpp
static const char* kLibrarySystemProperty = "persist.sys.dalvik.vm.lib.2";
static const char* kDebuggableSystemProperty = "ro.debuggable";
#endif
static const char* kLibraryFallback = "libart.so";

bool JniInvocation::Init(const char* library) {
#ifdef __ANDROID__
  char buffer[PROP_VALUE_MAX];
#else
  char* buffer = NULL;
#endif
  library = GetLibrary(library, buffer);
  // Load with RTLD_NODELETE in order to ensure that libart.so is not unmapped when it is closed.
  // This is due to the fact that it is possible that some threads might have yet to finish
  // exiting even after JNI_DeleteJavaVM returns, which can lead to segfaults if the library is
  // unloaded.
  const int kDlopenFlags = RTLD_NOW | RTLD_NODELETE;
  handle_ = dlopen(library, kDlopenFlags);
  if (handle_ == NULL) {
    if (strcmp(library, kLibraryFallback) == 0) {
      // Nothing else to try.
      ALOGE("Failed to dlopen %s: %s", library, dlerror());
      return false;
    }
    // Note that this is enough to get something like the zygote
    // running, we can't property_set here to fix this for the future
    // because we are root and not the system user. See
    // RuntimeInit.commonInit for where we fix up the property to
    // avoid future fallbacks. http://b/11463182
    ALOGW("Falling back from %s to %s after dlopen error: %s",
          library, kLibraryFallback, dlerror());
    library = kLibraryFallback;
    handle_ = dlopen(library, kDlopenFlags);
    if (handle_ == NULL) {
      ALOGE("Failed to dlopen %s: %s", library, dlerror());
      return false;
    }
  }
  if (!FindSymbol(reinterpret_cast<void**>(&JNI_GetDefaultJavaVMInitArgs_),
                  "JNI_GetDefaultJavaVMInitArgs")) {
    return false;
  }
  if (!FindSymbol(reinterpret_cast<void**>(&JNI_CreateJavaVM_),
                  "JNI_CreateJavaVM")) {
    return false;
  }
  if (!FindSymbol(reinterpret_cast<void**>(&JNI_GetCreatedJavaVMs_),
                  "JNI_GetCreatedJavaVMs")) {
    return false;
  }
  return true;
}
```

核心方法实际上只有一处：
```cpp
library = GetLibrary(library, buffer);
handle_ = dlopen(library, kDlopenFlags);
```
dlopen是指读取某个链接库。这个library是通过getlibrary获得的。这个方法就不贴出来了。这个方法解释就是通过读取kLibrarySystemProperty下的属性，来确定加载什么so库。而这个so库就是我们的虚拟机so库。

如果对那些做过编译Android机子的朋友就能明白，实际上这个属性在/art/Android.mk中设定的。里面设定的字符串一般是libart.so或者libdvm.so.这两个分别代表这是art虚拟机还是dvm虚拟机。

当然这是允许自己编写虚拟机，自己设置的。因此，在这个方法的最后会检测，这个so是否包含以下三个函数：
1. JNI_GetDefaultJavaVMInitArgs
2. JNI_CreateJavaVM
3. JNI_GetCreatedJavaVMs

只有包含这三个函数，Android初始化才会认可这个虚拟机做进一步的初始化工作。


这么实现很眼熟是不是？不错这个实现，实际上就和代理模式+工厂模式如出一辙。

> 这样在Android framework初始化的时候不必要关注虚拟机是什么，将初始化任务代理交给JniInvocation来完成。同时，Android.mk作为工厂来决定Android系统加载什么虚拟机。


因此，JniInvocation这个类抽离了三个方法出来：
```cpp
JniInvocation::JniInvocation() :
    handle_(NULL),
    JNI_GetDefaultJavaVMInitArgs_(NULL),
    JNI_CreateJavaVM_(NULL),
    JNI_GetCreatedJavaVMs_(NULL) {

  LOG_ALWAYS_FATAL_IF(jni_invocation_ != NULL, "JniInvocation instance already initialized");
  jni_invocation_ = this;
}
```

如果不是这是几个so库无法通过接口实现来完成，那么这个设计模式uml如下：

![虚拟机兼容设计.png](/images/虚拟机兼容设计.png)

这里我将不涉及虚拟机初始化的流程，我将会专门开一个文章来总结。

此时我们已经初始化好了art虚拟机（此时是Android 7.0），我们要开始启动虚拟机了。

### 2.启动化虚拟机
```cpp
    JNIEnv* env;
    if (startVm(&mJavaVM, &env, zygote) != 0) {
        return;
    }
    onVmCreated(env);
```

在startVm中做了两个工作，第一个把对虚拟机设置的参数设置进去，第二点，调用虚拟机的JNI_CreateJavaVM方法。核心方法如下：
```cpp
    /*
     * Initialize the VM.
     *
     * The JavaVM* is essentially per-process, and the JNIEnv* is per-thread.
     * If this call succeeds, the VM is ready, and we can start issuing
     * JNI calls.
     */
    if (JNI_CreateJavaVM(pJavaVM, pEnv, &initArgs) < 0) {
        ALOGE("JNI_CreateJavaVM failed\n");
        return -1;
    }

    return 0;
```
此时如果创建成功，返回的int是大于等于0，小于0则是创建异常。并且把初始化好之后的数据类型赋值给JavaVm，JniEnv。

而下面这个函数onVmCreated(env);
```cpp
void AndroidRuntime::onVmCreated(JNIEnv* env)
{
    // If AndroidRuntime had anything to do here, we'd have done it in 'start'.
}
```
是不做任何处理的。这里等下说，还有什么妙用。

### 2.注册jni方法
```cpp
    if (startReg(env) < 0) {
        ALOGE("Unable to register all android natives\n");
        return;
    }
```

我们看看这个注册是做什么的。
```cpp
/*static*/ int AndroidRuntime::startReg(JNIEnv* env)
{
    ATRACE_NAME("RegisterAndroidNatives");
    /*
     * This hook causes all future threads created in this process to be
     * attached to the JavaVM.  (This needs to go away in favor of JNI
     * Attach calls.)
     */
    androidSetCreateThreadFunc((android_create_thread_fn) javaCreateThreadEtc);

    ALOGV("--- registering native functions ---\n");

    /*
     * Every "register" function calls one or more things that return
     * a local reference (e.g. FindClass).  Because we haven't really
     * started the VM yet, they're all getting stored in the base frame
     * and never released.  Use Push/Pop to manage the storage.
     */
    env->PushLocalFrame(200);

    if (register_jni_procs(gRegJNI, NELEM(gRegJNI), env) < 0) {
        env->PopLocalFrame(NULL);
        return -1;
    }
    env->PopLocalFrame(NULL);

    //createJavaThread("fubar", quickTest, (void*) "hello");

    return 0;
}
```

实际上这个核心方法是register_jni_procs。注册jni方法。
```cpp
static int register_jni_procs(const RegJNIRec array[], size_t count, JNIEnv* env)
{
    for (size_t i = 0; i < count; i++) {
        if (array[i].mProc(env) < 0) {
#ifndef NDEBUG
            ALOGD("----------!!! %s failed to load\n", array[i].mName);
#endif
            return -1;
        }
    }
    return 0;
}
```
RegJNIRec这个是一个结构体。mProc就是每个方法的方法指针：
```cpp
struct RegJNIRec {
        int (*mProc)(JNIEnv*);
    };
```

每一次都会调用注册这个数组中的方法。我们看看这个array的数组都有什么。
```cpp
static const RegJNIRec gRegJNI[] = {
    REG_JNI(register_com_android_internal_os_RuntimeInit),
  ...
    REG_JNI(register_com_android_internal_os_Zygote),
    REG_JNI(register_com_android_internal_util_VirtualRefBasePtr),
    REG_JNI(register_android_hardware_Camera),
    REG_JNI(register_android_hardware_camera2_CameraMetadata),
    REG_JNI(register_android_hardware_camera2_legacy_LegacyCameraDevice),
    REG_JNI(register_android_hardware_camera2_legacy_PerfMeasurement),
    REG_JNI(register_android_hardware_camera2_DngCreator),
    REG_JNI(register_android_hardware_Radio),
    REG_JNI(register_android_hardware_SensorManager),
    REG_JNI(register_android_hardware_SerialPort),
    REG_JNI(register_android_hardware_SoundTrigger),
    REG_JNI(register_android_hardware_UsbDevice),
    REG_JNI(register_android_hardware_UsbDeviceConnection),
    REG_JNI(register_android_hardware_UsbRequest),
    ....
};
```

看到了把。这些方法无一不是我们熟悉的方法，什么Bitmap，Parcel，Camera等等api，这些需要调用native的类。

这就说回来了，onVmCreated这个留下的空函数做什么的。一般我们开发留下一个空函数一般不是兼容版本，就是交给用户做额外处理。实际我们开发jni的时候，我们可以通过这个方法，常做的两件事情，第一，创建一个JniEnv并为其绑定线程，第二，我们可以在这个时刻做好方法映射，让我们内部的方法，不需要遵守jni的命名规则（包+方法名），这样能够大大的扩展我们so的编写的可读性和复用。

### 3.反射启动ZygoteInit
```cpp
    char* slashClassName = toSlashClassName(className);
    jclass startClass = env->FindClass(slashClassName);
    if (startClass == NULL) {
        ALOGE("JavaVM unable to locate class '%s'\n", slashClassName);
        /* keep going */
    } else {
        jmethodID startMeth = env->GetStaticMethodID(startClass, "main",
            "([Ljava/lang/String;)V");
        if (startMeth == NULL) {
            ALOGE("JavaVM unable to find main() in '%s'\n", className);
            /* keep going */
        } else {
            env->CallStaticVoidMethod(startClass, startMeth, strArray);

#if 0
            if (env->ExceptionCheck())
                threadExitUncaughtException(env);
#endif
        }
    }
    free(slashClassName);

    ALOGD("Shutting down VM\n");
    if (mJavaVM->DetachCurrentThread() != JNI_OK)
        ALOGW("Warning: unable to detach main thread\n");
    if (mJavaVM->DestroyJavaVM() != 0)
        ALOGW("Warning: VM did not shut down cleanly\n");
```
此时就走到反射调用ZygoteInit流程，此时传进来的slashClassName就是ZygoteInit的包名。
```cpp
        jmethodID startMeth = env->GetStaticMethodID(startClass, "main",
            "([Ljava/lang/String;)V");
        if (startMeth == NULL) {
            ALOGE("JavaVM unable to find main() in '%s'\n", className);
            /* keep going */
        } else {
            env->CallStaticVoidMethod(startClass, startMeth, strArray);

#if 0
            if (env->ExceptionCheck())
                threadExitUncaughtException(env);
#endif
        }
```
启动结束，就释放掉，java层的String类，以及为JavaVM接触当前线程的绑定，并回收掉JavaVm内存。

## ZygoteInit
此时进入到ZygoteInit的类中。我们看看main方法

文件：/[frameworks](http://androidxref.com/7.0.0_r1/xref/frameworks/)/[base](http://androidxref.com/7.0.0_r1/xref/frameworks/base/)/[core](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/)/[java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/)/[com](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/)/[os](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/)/[ZygoteInit.java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/ZygoteInit.java)

```java
public static void main(String argv[]) {
        // Mark zygote start. This ensures that thread creation will throw
        // an error.
        ZygoteHooks.startZygoteNoThreadCreation();

        try {
            Trace.traceBegin(Trace.TRACE_TAG_DALVIK, "ZygoteInit");
            RuntimeInit.enableDdms();
            // Start profiling the zygote initialization.
            SamplingProfilerIntegration.start();

            boolean startSystemServer = false;
            String socketName = "zygote";
            String abiList = null;
//解析传进来的命令，主要是确定是否要启动SystemServer
            for (int i = 1; i < argv.length; i++) {
                if ("start-system-server".equals(argv[i])) {
                    startSystemServer = true;
                } else if (argv[i].startsWith(ABI_LIST_ARG)) {
                    abiList = argv[i].substring(ABI_LIST_ARG.length());
                } else if (argv[i].startsWith(SOCKET_NAME_ARG)) {
                    socketName = argv[i].substring(SOCKET_NAME_ARG.length());
                } else {
                    throw new RuntimeException("Unknown command line argument: " + argv[i]);
                }
            }

            if (abiList == null) {
                throw new RuntimeException("No ABI list supplied.");
            }
//注册监听
            registerZygoteSocket(socketName);
//准备资源
            preload();
//装载好虚拟机之后，做一次gc
           gcAndFinalize();
          ...

            // Zygote process unmounts root storage spaces.
            Zygote.nativeUnmountStorageOnInit();

            ZygoteHooks.stopZygoteNoThreadCreation();
//启动SystemServer
            if (startSystemServer) {
                startSystemServer(abiList, socketName);
            }
//启动循环
            Log.i(TAG, "Accepting command socket connections");
            runSelectLoop(abiList);

            closeServerSocket();
        } catch (MethodAndArgsCaller caller) {
            caller.run();
        } catch (RuntimeException ex) {
            Log.e(TAG, "Zygote died with exception", ex);
            closeServerSocket();
            throw ex;
        }
    }
```

这里做的事情主要是三步：
第一步：解析命令是否要启动SystemServer
第二步：registerZygoteSocket来打开socket监听命令，是否孵化新的进程
第三步：启动SystemServer
第三步：runSelectLoop 启动一个系统的looper循环


第一步很简单，就跳过。直接看看第二步registerZygoteSocket
```java
    private static void registerZygoteSocket(String socketName) {
        if (sServerSocket == null) {
            int fileDesc;
            final String fullSocketName = ANDROID_SOCKET_PREFIX + socketName;
            try {
                String env = System.getenv(fullSocketName);
                fileDesc = Integer.parseInt(env);
            } catch (RuntimeException ex) {
                throw new RuntimeException(fullSocketName + " unset or invalid", ex);
            }

            try {
                FileDescriptor fd = new FileDescriptor();
                fd.setInt$(fileDesc);
                sServerSocket = new LocalServerSocket(fd);
            } catch (IOException ex) {
                throw new RuntimeException(
                        "Error binding to local socket '" + fileDesc + "'", ex);
            }
        }
    }
```
通过创建一个文件描述符，对这个文件描述符进行监听，来做到一个本地socket的功能。

很有趣，没想到socket还能这么创建，平时我们使用socket的时候往往都是使用ServerSocket这些类去完成，没想到可以使用监听文件描述符来办到socket的监听，不过实际上想想Linux下一切皆文件，也就不再觉得意料之外。

之后这个sServerSocket对象将会作为Zygote作为监听外侧的耳目。
 
### 启动SystemServer
```java
    private static boolean startSystemServer(String abiList, String socketName)
            throws MethodAndArgsCaller, RuntimeException {
...
        ZygoteConnection.Arguments parsedArgs = null;

 String args[] = {
            "--setuid=1000",
            "--setgid=1000",
            "--setgroups=1001,1002,1003,1004,1005,1006,1007,1008,1009,1010,1018,1021,1032,3001,3002,3003,3006,3007,3009,3010",
            "--capabilities=" + capabilities + "," + capabilities,
            "--nice-name=system_server",
            "--runtime-args",
            "com.android.server.SystemServer",
        };
        int pid;

        try {
            parsedArgs = new ZygoteConnection.Arguments(args);
            ZygoteConnection.applyDebuggerSystemProperty(parsedArgs);
            ZygoteConnection.applyInvokeWithSystemProperty(parsedArgs);
//启动新的进程forkSystemServer
            /* Request to fork the system server process */
            pid = Zygote.forkSystemServer(
                    parsedArgs.uid, parsedArgs.gid,
                    parsedArgs.gids,
                    parsedArgs.debugFlags,
                    null,
                    parsedArgs.permittedCapabilities,
                    parsedArgs.effectiveCapabilities);
        } catch (IllegalArgumentException ex) {
            throw new RuntimeException(ex);
        }

        /* For child process */
        if (pid == 0) {
            if (hasSecondZygote(abiList)) {
                waitForSecondaryZygote(socketName);
            }

            handleSystemServerProcess(parsedArgs);
        }

        return true;
    }
```

这个方法分两步：
1.fork出SystemServer进程
2.初始化SystemServer

##### 1.fork出SystemServer进程
这个步骤的核心方法是fork出SystemServer进程
我们稍微往这个方法下面看看，究竟有什么问题？

```java
public static int forkSystemServer(int uid, int gid, int[] gids, int debugFlags,
            int[][] rlimits, long permittedCapabilities, long effectiveCapabilities) {
        VM_HOOKS.preFork();
        int pid = nativeForkSystemServer(
                uid, gid, gids, debugFlags, rlimits, permittedCapabilities, effectiveCapabilities);
        // Enable tracing as soon as we enter the system_server.
       if (pid == 0) {
            Trace.setTracingEnabled(true);
        }
        VM_HOOKS.postForkCommon();
}
```
核心方法是调用native方法进行fork。
文件[com_android_internal_os_Zygote.cpp](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp)

```cpp
static jint com_android_internal_os_Zygote_nativeForkSystemServer(
        JNIEnv* env, jclass, uid_t uid, gid_t gid, jintArray gids,
        jint debug_flags, jobjectArray rlimits, jlong permittedCapabilities,
        jlong effectiveCapabilities) {
  pid_t pid = ForkAndSpecializeCommon(env, uid, gid, gids,
                                      debug_flags, rlimits,
                                      permittedCapabilities, effectiveCapabilities,
                                      MOUNT_EXTERNAL_DEFAULT, NULL, NULL, true, NULL,
                                      NULL, NULL);
  if (pid > 0) {
      // The zygote process checks whether the child process has died or not.
      ALOGI("System server process %d has been created", pid);
      gSystemServerPid = pid;
      // There is a slight window that the system server process has crashed
      // but it went unnoticed because we haven't published its pid yet. So
      // we recheck here just to make sure that all is well.
      int status;
      if (waitpid(pid, &status, WNOHANG) == pid) {
          ALOGE("System server process %d has died. Restarting Zygote!", pid);
          RuntimeAbort(env, __LINE__, "System server process has died. Restarting Zygote!");
      }
  }
  return pid;
}
```
ForkAndSpecializeCommon这个方法就是所有进程fork都会调用这个这个native函数。这个函数实际上是调用linux的fork函数来拷贝出新的进程。

##### 2.初始化SystemServer进程
```java
        if (pid == 0) {
            if (hasSecondZygote(abiList)) {
                waitForSecondaryZygote(socketName);
            }

            handleSystemServerProcess(parsedArgs);
        }
```
孵化好新的进程。这里返回结果。加入结果pid是等于0.说明会走这个分支。我们这里只看一个孵化进程的情况。看看这个方法handleSystemServerProcess(parsedArgs);
```java
    private static void handleSystemServerProcess(
            ZygoteConnection.Arguments parsedArgs)
            throws ZygoteInit.MethodAndArgsCaller {

        closeServerSocket();
...
            /*
             * Pass the remaining arguments to SystemServer.
             */
            RuntimeInit.zygoteInit(parsedArgs.targetSdkVersion, parsedArgs.remainingArgs, cl);
        }

        /* should never reach here */
    }

```
由于这个新的进程不需要接收消息，去孵化进程，所以第一件事情就是关闭socket的监听。第二件事就是通过RuntimeInit初始化SystemServer。

文件：[com](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/)/[os](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/)/[RuntimeInit.java](http://androidxref.com/7.0.0_r1/xref/frameworks/base/core/java/com/android/internal/os/RuntimeInit.java)

```java
    public static final void zygoteInit(int targetSdkVersion, String[] argv, ClassLoader classLoader)
            throws ZygoteInit.MethodAndArgsCaller {
        if (DEBUG) Slog.d(TAG, "RuntimeInit: Starting application from zygote");

        Trace.traceBegin(Trace.TRACE_TAG_ACTIVITY_MANAGER, "RuntimeInit");
        redirectLogStreams();

        commonInit();
        nativeZygoteInit();
        applicationInit(targetSdkVersion, argv, classLoader);
    }
```
此时nativeZygoteInit会初始化我们ProcessState时候，同时初始化我们鼎鼎大名的Binder驱动。

我们看看核心方法applicationInit做了啥：
```java
   private static void applicationInit(int targetSdkVersion, String[] argv, ClassLoader classLoader)
            throws ZygoteInit.MethodAndArgsCaller {
...
        // Remaining arguments are passed to the start class's static main
        invokeStaticMain(args.startClass, args.startArgs, classLoader);
    }
```

就是这个方法把传进来的参数初始化，把之前“com.android.server.SystemServer”参数反射其main方法。
```java
   public static void main(String[] args) {
        new SystemServer().run();
    }
```
这里初始化“android_servers”的so库，里面包含了大量的Android的native需要加载的native服务，以及我们经常会用到各种服务（Display，powermanager，alarm，inputmanager,AMS,WMS）。创建了我们熟悉的SystemServerManger，为这个进程创建了Looper。

### runSelectLoop启动一个Zygote的循环。
```java
private static void runSelectLoop(String abiList) throws MethodAndArgsCaller {
//sServerSocket中文件描述符的集合
        ArrayList<FileDescriptor> fds = new ArrayList<FileDescriptor>();
        ArrayList<ZygoteConnection> peers = new ArrayList<ZygoteConnection>();

        fds.add(sServerSocket.getFileDescriptor());
        peers.add(null);
//等待事件的循环
        while (true) {
            StructPollfd[] pollFds = new StructPollfd[fds.size()];
            for (int i = 0; i < pollFds.length; ++i) {
                pollFds[i] = new StructPollfd();
                pollFds[i].fd = fds.get(i);
                pollFds[i].events = (short) POLLIN;
            }
            try {
                Os.poll(pollFds, -1);
            } catch (ErrnoException ex) {
                throw new RuntimeException("poll failed", ex);
            }
            for (int i = pollFds.length - 1; i >= 0; --i) {
                if ((pollFds[i].revents & POLLIN) == 0) {
                    continue;
                }
                if (i == 0) {
//每一次执行完了动作之后，等到又新的进程进来等待唤醒
                    ZygoteConnection newPeer = acceptCommandPeer(abiList);
                    peers.add(newPeer);
                    fds.add(newPeer.getFileDesciptor());
                } else {
//执行的核心
                    boolean done = peers.get(i).runOnce();
                    if (done) {
                        peers.remove(i);
                        fds.remove(i);
                    }
                }
            }
        }
    }
```
先介绍下面两个队列
```java
        ArrayList<FileDescriptor> fds = new ArrayList<FileDescriptor>();
        ArrayList<ZygoteConnection> peers = new ArrayList<ZygoteConnection>();

        fds.add(sServerSocket.getFileDescriptor());
        peers.add(null);
```
- 1.fds 文件描述符的队列.一般情况下，这个队列从头到尾只有一个，保证了当前只有一个Zygote在等待外面的监听。

- 2.peers ZygoteConnection队列。这个队列决定还有多少个socket事件没有处理。

这是构建的一段死循环。可以说是系统主Loop，就像iOS，ActivityThread中的Looper，用来响应外界的事件。
```java
 while (true) {
            StructPollfd[] pollFds = new StructPollfd[fds.size()];
            for (int i = 0; i < pollFds.length; ++i) {
                pollFds[i] = new StructPollfd();
                pollFds[i].fd = fds.get(i);
                pollFds[i].events = (short) POLLIN;
            }
            try {
                Os.poll(pollFds, -1);
            } catch (ErrnoException ex) {
                throw new RuntimeException("poll failed", ex);
            }
            for (int i = pollFds.length - 1; i >= 0; --i) {
                if ((pollFds[i].revents & POLLIN) == 0) {
                    continue;
                }
                if (i == 0) {
//每一次执行完了动作之后，等到又新的进程进来等待唤醒
                    ZygoteConnection newPeer = acceptCommandPeer(abiList);
                    peers.add(newPeer);
                    fds.add(newPeer.getFileDesciptor());
                } else {
//执行的核心
                    boolean done = peers.get(i).runOnce();
                    if (done) {
                        peers.remove(i);
                        fds.remove(i);
                    }
                }
            }
        }
```
这里面简单的逻辑如下，一旦有socket中监听到了数据过来，将会执行runOnce()方法，接着把对应的socket等待处理事件以及，对应的socket文件符移除掉。此时事件队列为0，这个循环再一次把Zygote监听添加回来。

#### runOnce
我们看看runOnce方法
```java
    boolean runOnce() throws ZygoteInit.MethodAndArgsCaller {

        String args[];
        Arguments parsedArgs = null;
        FileDescriptor[] descriptors;

        try {
            args = readArgumentList();
            descriptors = mSocket.getAncillaryFileDescriptors();
        } catch (IOException ex) {
            Log.w(TAG, "IOException on command socket " + ex.getMessage());
            closeSocket();
            return true;
        }

        if (args == null) {
            // EOF reached.
            closeSocket();
            return true;
        }

        /** the stderr of the most recent request, if avail */
        PrintStream newStderr = null;

        if (descriptors != null && descriptors.length >= 3) {
            newStderr = new PrintStream(
                    new FileOutputStream(descriptors[2]));
        }

        int pid = -1;
        FileDescriptor childPipeFd = null;
        FileDescriptor serverPipeFd = null;

        try {
//读取socket数据
            parsedArgs = new Arguments(args);

            if (parsedArgs.abiListQuery) {
                return handleAbiListQuery();
            }

            ...
            fd = null;
//fork子进程
            pid = Zygote.forkAndSpecialize(parsedArgs.uid, parsedArgs.gid, parsedArgs.gids,
                    parsedArgs.debugFlags, rlimits, parsedArgs.mountExternal, parsedArgs.seInfo,
                    parsedArgs.niceName, fdsToClose, parsedArgs.instructionSet,
                    parsedArgs.appDataDir);
        } catch (ErrnoException ex) {
            logAndPrintError(newStderr, "Exception creating pipe", ex);
        } catch (IllegalArgumentException ex) {
            logAndPrintError(newStderr, "Invalid zygote arguments", ex);
        } catch (ZygoteSecurityException ex) {
            logAndPrintError(newStderr,
                    "Zygote security policy prevents request: ", ex);
        }

        try {
            if (pid == 0) {
                // in child//处理子进程的后续
                IoUtils.closeQuietly(serverPipeFd);
                serverPipeFd = null;
                handleChildProc(parsedArgs, descriptors, childPipeFd, newStderr);

                // should never get here, the child is expected to either
                // throw ZygoteInit.MethodAndArgsCaller or exec().
                return true;
            } else {
                // in parent...pid of < 0 means failure
                IoUtils.closeQuietly(childPipeFd);
                childPipeFd = null;
//处理父亲进程的后续
                return handleParentProc(pid, descriptors, serverPipeFd, parsedArgs);
            }
        } finally {
            IoUtils.closeQuietly(childPipeFd);
            IoUtils.closeQuietly(serverPipeFd);
        }
    }
```
runOnce做的事情分为三部分：

- 1. 调用readArgumentList读取socket传过来的数据
- 2.  通过 forkAndSpecialize fork新进程
- 3. 处理fork出来的子进程

#### handleParentProc
```java
    private boolean handleParentProc(int pid,
            FileDescriptor[] descriptors, FileDescriptor pipeFd, Arguments parsedArgs) {

        if (pid > 0) {
            setChildPgid(pid);
        }

        if (descriptors != null) {
            for (FileDescriptor fd: descriptors) {
                IoUtils.closeQuietly(fd);
            }
        }

        boolean usingWrapper = false;
        if (pipeFd != null && pid > 0) {
            DataInputStream is = new DataInputStream(new FileInputStream(pipeFd));
            int innerPid = -1;
            try {
                innerPid = is.readInt();
            } catch (IOException ex) {
                Log.w(TAG, "Error reading pid from wrapped process, child may have died", ex);
            } finally {
                try {
                    is.close();
                } catch (IOException ex) {
                }
            }
...

        try {
            mSocketOutStream.writeInt(pid);
            mSocketOutStream.writeBoolean(usingWrapper);
        } catch (IOException ex) {
            Log.e(TAG, "Error writing to command socket", ex);
            return true;
        }

        return false;
    }
```
父进程关闭fd入口，同时设置好子进程的pid。而fork出来的子进程将会在下篇继续



这里按照惯例，我们画一幅时序图，总结

![Zygote孵化进程时序图.png](/images/Zygote孵化进程时序图.png)
