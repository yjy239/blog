---
title: 存储性能优化 MMKV源码解析
top: false
cover: false
date: 2020-04-29 10:53:52
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
- 性能优化
- Android 常用第三方库
---
# 前言
好久没有更新常用的第三方库了。让我们来聊聊MMKV这个常用的第三方库。MMKV这个库是做什么的呢？他本质上的定位和sp有点相似，经常用于持久化小数据的键值对。其速度可以说是当前所有同类型中速度最快，性能最优的库。

它的最早的诞生，主要是因为在微信iOS端有一个重大的bug，一个特殊的文本可以导致微信的iOS端闪退，而且还出现了不止一次。为了统计这种闪退的字符出现频率以及过滤，但是由于出现的次数，发现原来的键值对存储组件NSUserDefaults根本达不到要求，会导致cell的滑动卡顿。

因此iOS端就开始创造一个高新性能的键值对存储组件。于此同时，Android端SharedPreferences也有如下几个缺点：
- 1.跨进程不安全 就算使用了MODE_MULTI_PROCESS，频繁的写入还是会会造成数据丢失。

- 2.加载缓慢 SharedPreferences使用异步加载，由于线程没有设置优先级，按照默认的线程优先级会造成时间片抢占机会小导致主线程长时间的等待。

- 3.全量写入 无论是调用 commit() 还是 apply()，即使我们只改动其中的一个条目，都会把整个内容全部写到文件

- 4.卡顿 由于提供了异步落盘的 apply 机制，在崩溃或者其他一些异常情况可能会导致数据丢失。所以当应用收到系统广播，或者被调用 onPause 等一些时机，系统会强制把所有的 SharedPreferences 对象数据落地到磁盘。如果没有落地完成，这时候主线程会被一直阻塞。这样非常容易造成卡顿，甚至是 ANR，从线上数据来看 SP 卡顿占比一般会超过 5%

因此Android也开始复用iOS的MMKV，而后Android有了多进程的写入数据的需求，Android组又在这个基础上进行改进。


这里是官方的性能的比较图：
### Android端 1000次的读写性能比较：
![mmkv_android比较.png](/images/mmkv_android比较.png)

### iOS 10000次的性能比较：
![mmkv_iOS性能比较.png](/images/mmkv_iOS性能比较.png)

能看到mmkv比起我们开发常用的组件要快上数百倍。

那么本文将会从源码角度围绕MMKV的性能为什么会如此高，以及SharePrefences为什么可能出现ANR的原因。

请注意下文是以MMKV 1.1.1版本源码为例子分析。如果遇到什么问题欢迎来到本文[https://www.jianshu.com/p/c12290a9a3f7](https://www.jianshu.com/p/c12290a9a3f7)互相讨论。


# 正文
老规矩，先来看看MMKV怎么使用。mmkv其实和SharePrefences一样，有增删查改四种操作。

## MMKV 前置知识
MMKV作为一个键值对存储组件，也对了存储对象的序列化方式进行了优化。常用的方式比如有json，Twitter的Serial。而MMKV使用的是Google开源的序列化方案:Protocol Buffers。

Protocol Buffers这个方案比起json来说就高级不少：
- 1.从体积上，使用了二进制的压缩。比起json小上不少。
- 2.兼容性上，Protocol Buffers有自己的语法，可以跨语言跨平台。
- 3.使用成本上，比起json就要高上不少。需要定义.proto 文件，并用工具生成对应的辅助类。辅助类特有一些序列化的辅助方法，所有要序列化的对象，都需要先转化为辅助类的对象，这让序列化代码跟业务代码大量耦合，是侵入性较强的一种方式。

使用方式可以阅读下面这篇文章：[https://www.jianshu.com/p/e8712962f0e9](https://www.jianshu.com/p/e8712962f0e9)

下面进行比较几个对象序列化之间的要素比较
要素|Serial|JSON|Protocol Buffers
-|-|-|-
正确性|优|优|优
时间开销|良(Json>性能>Serializable)|良(性能<Protocol Buffers)|优|
空间开销|良(对象序列化，空间较大)|良 (数据序列化,保留可读性牺牲空间)|优(二进制压缩)|
开发成本|良(比起Serializable麻烦需要额外接入)|良(对引用,继承支持有限)|差(不支持对象之间引用和继承)|
兼容性|良(和平台相关)|优(跨平台跨语言支持)|优(跨平台跨语言支持)|

而MMKV就是看重了Protocol Buffers的时间开销小，选择Protocol Buffers进行对象缓存的核心。

## MMKV的使用
使用前请初始化：
```
MMKV.initialize(this)
```

#### mmkv写入键值对
```kotlin
var mmkv = MMKV.defaultMMKV()
mmkv.encode("bool",true)
mmkv.encode("int",1)
mmkv.encode("String","test")
mmkv.encode("float",1.0f)
mmkv.encode("double",1.0)
```
当然mmkv除了能够写入这些基本类型，只要SharePrefences支持的，它也一定能够支持。

#### mmkv读取键值对
```kotlin
var mmkv = MMKV.defaultMMKV()
var bo = mmkv.decodeBool("bool")
Log.e(TAG,"bool:${bo}")
var i = mmkv.decodeInt("int")
Log.e(TAG,"int:${i}")
var s = mmkv.decodeString("String")
Log.e(TAG,"String:${s}")
var f = mmkv.decodeFloat("float")
Log.e(TAG,"float:${f}")
var d = mmkv.decodeDouble("double")
Log.e(TAG,"double:${d}")
```
同上，每一个key读取的数据类型就是decodexxx对应的类型名字。使用起来十分简单。

#### mmkv 删除键值对和查键值对
```kotlin
var mmkv = MMKV.defaultMMKV()
mmkv.removeValueForKey("String")
mmkv.removeValuesForKeys(arrayOf("int","bool"))
mmkv.containsKey("String")
```
能够删除单个key对应的value，也能删除多个key分别对应的value。containsKey判断mmkv的磁盘缓存中是否存在对应的key。

#### mmkv的其他用法
mmkv和SharePrefences一样，还能根据模块和业务划分对应的缓存文件：
```kotlin
var mmkv = MMKV.mmkvWithID("a")
mmkv.encode("String","test111")
```
这里创建了一个id为a的实例在磁盘中，进行数据的缓存。


当需要多进程缓存的时候：
```kotlin
var mmkv = MMKV.mmkvWithID("a",MMKV.MULTI_PROCESS_MODE)
```
##### MMKV使用Ashmem匿名内存
MMKV可以使用Ashmem的匿名内存进行更加快速的大对象传输：
进程1：
```java
m_ashmemMMKV = MMKV.mmkvWithAshmemID(BenchMarkBaseService.this, id, AshmemMMKV_Size,
                                                 MMKV.MULTI_PROCESS_MODE, CryptKey);
            m_ashmemMMKV.encode("bool", true);
```

##### MMKV迁移到SharePrefences
最重要的一点，mmkv把SharePrefences的缓存迁移到mmkv中，之后的使用就和SharePrefences一致。
```kotlin
var preferences = MMKV.mmkvWithID("myData")
        var originPrefences = getSharedPreferences("myData", Context.MODE_PRIVATE)
        preferences.importFromSharedPreferences(originPrefences)
        originPrefences.edit().clear().commit()
```
这里就是把SharedPreferences的myData数据迁移到mmkv中。当然如果我们需要保持SharePreferences的用法不变需要自己进行自定义一个SharePreferences。

mmkv的用法极其简单，接下来我们关注他的原理。

## MMKV 源码解析
首先来看看MMKV的初始化。
```java
    public static String initialize(Context context) {
        String root = context.getFilesDir().getAbsolutePath() + "/mmkv";
        MMKVLogLevel logLevel = MMKVLogLevel.LevelInfo;
        return initialize(root, (MMKV.LibLoader)null, logLevel);
    }

    public static String initialize(String rootDir, LibLoader loader, MMKVLogLevel logLevel) {
        if (loader != null) {
            if (BuildConfig.FLAVOR.equals("SharedCpp")) {
                loader.loadLibrary("c++_shared");
            }
            loader.loadLibrary("mmkv");
        } else {
            if (BuildConfig.FLAVOR.equals("SharedCpp")) {
                System.loadLibrary("c++_shared");
            }
            System.loadLibrary("mmkv");
        }
        MMKV.rootDir = rootDir;
        jniInitialize(MMKV.rootDir, logLevel2Int(logLevel));
        return rootDir;
    }
```
能看到实际上initialize分为如下几个步骤：
- 1.创建一个app内的/data/data/包名/files/mmkv的目录。所有的文件都保存在里面。
- 2.加载两个so库，c++_shared以及mmkv。这里有点迷惑，c++_shared是什么条件加载的：
```gradle
defaultPublishConfig "StaticCppRelease"
flavorDimensions "stl_mode"
    productFlavors {
        StaticCpp {
            dimension "stl_mode"
            ext.artifactIdSuffix = 'static'
            externalNativeBuild {
                cmake {
                    arguments = ["-DANDROID_STL=c++_static"]
                }
            }
        }
        SharedCpp {
            dimension "stl_mode"
            ext.artifactIdSuffix = ''
            externalNativeBuild {
                cmake {
                    arguments = ["-DANDROID_STL=c++_shared"]
                }
            }
        }
    }
```
能看到其实就是做这个判断。由于此时设置的是libc++的打包方式。此时BuildConfig.FLAVOR就是StaticCpp，就不会加载c++_shared。当然，如果我们已经使用了c++_shared库，则没有必要打包进去，使用defaultPublishConfig "SharedCppRelease"会尝试的查找动态链接库_shared。这样就能少2M的大小。

- 3. jniInitialize 初始化jni层,以及打印模块。

### MMKV native层的初始化
请注意一个前提的知识，jni的初始化，在调用了  System.loadLibrary之后，会通过dlopen把so加载到内存后，调用dlsym，调用jni中的JNI_OnLoad方法。



```cpp
extern "C" JNIEXPORT JNICALL jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_currentJVM = vm;
    JNIEnv *env;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }

    if (g_cls) {
        env->DeleteGlobalRef(g_cls);
    }
    static const char *clsName = "com/tencent/mmkv/MMKV";
    jclass instance = env->FindClass(clsName);
    if (!instance) {
        MMKVError("fail to locate class: %s", clsName);
        return -2;
    }
    g_cls = reinterpret_cast<jclass>(env->NewGlobalRef(instance));
    if (!g_cls) {
        MMKVError("fail to create global reference for %s", clsName);
        return -3;
    }
    int ret = registerNativeMethods(env, g_cls);
    if (ret != 0) {
        MMKVError("fail to register native methods for class %s, ret = %d", clsName, ret);
        return -4;
    }
    g_fileID = env->GetFieldID(g_cls, "nativeHandle", "J");
    if (!g_fileID) {
        MMKVError("fail to locate fileID");
        return -5;
    }

    g_callbackOnCRCFailID = env->GetStaticMethodID(g_cls, "onMMKVCRCCheckFail", "(Ljava/lang/String;)I");
    if (!g_callbackOnCRCFailID) {
        MMKVError("fail to get method id for onMMKVCRCCheckFail");
    }
    g_callbackOnFileLengthErrorID = env->GetStaticMethodID(g_cls, "onMMKVFileLengthError", "(Ljava/lang/String;)I");
    if (!g_callbackOnFileLengthErrorID) {
        MMKVError("fail to get method id for onMMKVFileLengthError");
    }
    g_mmkvLogID =
        env->GetStaticMethodID(g_cls, "mmkvLogImp", "(ILjava/lang/String;ILjava/lang/String;Ljava/lang/String;)V");
    if (!g_mmkvLogID) {
        MMKVError("fail to get method id for mmkvLogImp");
    }
    g_callbackOnContentChange =
        env->GetStaticMethodID(g_cls, "onContentChangedByOuterProcess", "(Ljava/lang/String;)V");
    if (!g_callbackOnContentChange) {
        MMKVError("fail to get method id for onContentChangedByOuterProcess()");
    }

    // get current API level by accessing android.os.Build.VERSION.SDK_INT
    jclass versionClass = env->FindClass("android/os/Build$VERSION");
    if (versionClass) {
        jfieldID sdkIntFieldID = env->GetStaticFieldID(versionClass, "SDK_INT", "I");
        if (sdkIntFieldID) {
            g_android_api = env->GetStaticIntField(versionClass, sdkIntFieldID);
            MMKVInfo("current API level = %d", g_android_api);
        } else {
            MMKVError("fail to get field id android.os.Build.VERSION.SDK_INT");
        }
    } else {
        MMKVError("fail to get class android.os.Build.VERSION");
    }

    // get CPU status of ARMv8 extensions (CRC32, AES)
#ifdef __aarch64__
    auto hwcaps = getauxval(AT_HWCAP);
    if (hwcaps & HWCAP_AES) {
        AES_set_encrypt_key = openssl_aes_armv8_set_encrypt_key;
        AES_encrypt = openssl_aes_armv8_encrypt;
        MMKVInfo("armv8 AES instructions is supported");
    }
    if (hwcaps & HWCAP_CRC32) {
        CRC32 = mmkv::armv8_crc32;
        MMKVInfo("armv8 CRC32 instructions is supported");
    }
#endif

    return JNI_VERSION_1_6;
}
```
实际上这里面做的事情十分简单：
- 1.注册MMKV类在jni的反射对象，以及MMKV的java层对应的native方法：
```cpp
static JNINativeMethod g_methods[] = {
    {"onExit", "()V", (void *) mmkv::onExit},
    {"cryptKey", "()Ljava/lang/String;", (void *) mmkv::cryptKey},
    {"reKey", "(Ljava/lang/String;)Z", (void *) mmkv::reKey},
    {"checkReSetCryptKey", "(Ljava/lang/String;)V", (void *) mmkv::checkReSetCryptKey},
    {"pageSize", "()I", (void *) mmkv::pageSize},
    {"mmapID", "()Ljava/lang/String;", (void *) mmkv::mmapID},
    {"lock", "()V", (void *) mmkv::lock},
    {"unlock", "()V", (void *) mmkv::unlock},
    {"tryLock", "()Z", (void *) mmkv::tryLock},
    {"allKeys", "()[Ljava/lang/String;", (void *) mmkv::allKeys},
    {"removeValuesForKeys", "([Ljava/lang/String;)V", (void *) mmkv::removeValuesForKeys},
    {"clearAll", "()V", (void *) mmkv::clearAll},
    {"trim", "()V", (void *) mmkv::trim},
    {"close", "()V", (void *) mmkv::close},
    {"clearMemoryCache", "()V", (void *) mmkv::clearMemoryCache},
    {"sync", "(Z)V", (void *) mmkv::sync},
    {"isFileValid", "(Ljava/lang/String;)Z", (void *) mmkv::isFileValid},
    {"ashmemFD", "()I", (void *) mmkv::ashmemFD},
    {"ashmemMetaFD", "()I", (void *) mmkv::ashmemMetaFD},
    {"jniInitialize", "(Ljava/lang/String;I)V", (void *) mmkv::jniInitialize},
    {"getMMKVWithID", "(Ljava/lang/String;ILjava/lang/String;Ljava/lang/String;)J", (void *) mmkv::getMMKVWithID},
    {"getMMKVWithIDAndSize", "(Ljava/lang/String;IILjava/lang/String;)J", (void *) mmkv::getMMKVWithIDAndSize},
    {"getDefaultMMKV", "(ILjava/lang/String;)J", (void *) mmkv::getDefaultMMKV},
    {"getMMKVWithAshmemFD", "(Ljava/lang/String;IILjava/lang/String;)J", (void *) mmkv::getMMKVWithAshmemFD},
    {"encodeBool", "(JLjava/lang/String;Z)Z", (void *) mmkv::encodeBool},
    {"decodeBool", "(JLjava/lang/String;Z)Z", (void *) mmkv::decodeBool},
    {"encodeInt", "(JLjava/lang/String;I)Z", (void *) mmkv::encodeInt},
    {"decodeInt", "(JLjava/lang/String;I)I", (void *) mmkv::decodeInt},
    {"encodeLong", "(JLjava/lang/String;J)Z", (void *) mmkv::encodeLong},
    {"decodeLong", "(JLjava/lang/String;J)J", (void *) mmkv::decodeLong},
    {"encodeFloat", "(JLjava/lang/String;F)Z", (void *) mmkv::encodeFloat},
    {"decodeFloat", "(JLjava/lang/String;F)F", (void *) mmkv::decodeFloat},
    {"encodeDouble", "(JLjava/lang/String;D)Z", (void *) mmkv::encodeDouble},
    {"decodeDouble", "(JLjava/lang/String;D)D", (void *) mmkv::decodeDouble},
    {"encodeString", "(JLjava/lang/String;Ljava/lang/String;)Z", (void *) mmkv::encodeString},
    {"decodeString", "(JLjava/lang/String;Ljava/lang/String;)Ljava/lang/String;", (void *) mmkv::decodeString},
    {"encodeSet", "(JLjava/lang/String;[Ljava/lang/String;)Z", (void *) mmkv::encodeSet},
    {"decodeStringSet", "(JLjava/lang/String;)[Ljava/lang/String;", (void *) mmkv::decodeStringSet},
    {"encodeBytes", "(JLjava/lang/String;[B)Z", (void *) mmkv::encodeBytes},
    {"decodeBytes", "(JLjava/lang/String;)[B", (void *) mmkv::decodeBytes},
    {"containsKey", "(JLjava/lang/String;)Z", (void *) mmkv::containsKey},
    {"count", "(J)J", (void *) mmkv::count},
    {"totalSize", "(J)J", (void *) mmkv::totalSize},
    {"removeValueForKey", "(JLjava/lang/String;)V", (void *) mmkv::removeValueForKey},
    {"valueSize", "(JLjava/lang/String;Z)I", (void *) mmkv::valueSize},
    {"setLogLevel", "(I)V", (void *) mmkv::setLogLevel},
    {"setCallbackHandler", "(ZZ)V", (void *) mmkv::setCallbackHandler},
    {"createNB", "(I)J", (void *) mmkv::createNB},
    {"destroyNB", "(JI)V", (void *) mmkv::destroyNB},
    {"writeValueToNB", "(JLjava/lang/String;JI)I", (void *) mmkv::writeValueToNB},
    {"setWantsContentChangeNotify", "(Z)V", (void *) mmkv::setWantsContentChangeNotify},
    {"checkContentChangedByOuterProcess", "()V", (void *) mmkv::checkContentChanged},
};

static int registerNativeMethods(JNIEnv *env, jclass cls) {
    return env->RegisterNatives(cls, g_methods, sizeof(g_methods) / sizeof(g_methods[0]));
}
```
能从这些native方法中看到了所有MMKV的存储方法，设置支持共享内存ashemem的存储，支持直接获取native malloc申请的内存

- 3.获取当前编译的版本号并且记录下来。

### MMKV jniInitialize
接下来就是MMKV正式的初始化方法了。
```cpp
MMKV_JNI void jniInitialize(JNIEnv *env, jobject obj, jstring rootDir, jint logLevel) {
    if (!rootDir) {
        return;
    }
    const char *kstr = env->GetStringUTFChars(rootDir, nullptr);
    if (kstr) {
        MMKV::initializeMMKV(kstr, (MMKVLogLevel) logLevel);
        env->ReleaseStringUTFChars(rootDir, kstr);
    }
}

void initialize() {
    g_instanceDic = new unordered_map<string, MMKV *>;
    g_instanceLock = new ThreadLock();
    g_instanceLock->initialize();

    mmkv::DEFAULT_MMAP_SIZE = mmkv::getPageSize();
    MMKVInfo("page size:%d", DEFAULT_MMAP_SIZE);
}

ThreadOnceToken_t once_control = ThreadOnceUninitialized;

void MMKV::initializeMMKV(const MMKVPath_t &rootDir, MMKVLogLevel logLevel) {
    g_currentLogLevel = logLevel;

    ThreadLock::ThreadOnce(&once_control, initialize);

    g_rootDir = rootDir;
    mkPath(g_rootDir);

    MMKVInfo("root dir: " MMKV_PATH_FORMAT, g_rootDir.c_str());
}
```
- 1.获取rootDir的url char指针数组字符串，调用MMKV::initializeMMKV进一步初始化。
- 2.调用ThreadLock::ThreadOnce调用方法指针initialize进行初始化。在方法指针initialize中，则是初始化了一个全局的线程锁ThreadLock。以及一个全局的散列表g_instanceDic。在MMKV中，设置好每一页(page)的大小，一般来说我们在32位的机子中一页都是4kb大小。设置一个全局的打印对象g_currentLogLevel。

这个方法实际上调用的是pthread_once方法。它一般是在多线程环境中，根据内核的调度策略，选择一个线程初始化一次的方法。
```cpp
ThreadLock::ThreadLock() {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);

    pthread_mutex_init(&m_lock, &attr);

    pthread_mutexattr_destroy(&attr);
}
```
- 3.mkPath根据路径创建文件夹
```cpp
extern bool mkPath(const MMKVPath_t &str) {
    char *path = strdup(str.c_str());

    struct stat sb = {};
    bool done = false;
    char *slash = path;

    while (!done) {
        slash += strspn(slash, "/");
        slash += strcspn(slash, "/");

        done = (*slash == '\0');
        *slash = '\0';

        if (stat(path, &sb) != 0) {
            if (errno != ENOENT || mkdir(path, 0777) != 0) {
                MMKVWarning("%s : %s", path, strerror(errno));
                free(path);
                return false;
            }
        } else if (!S_ISDIR(sb.st_mode)) {
            MMKVWarning("%s: %s", path, strerror(ENOTDIR));
            free(path);
            return false;
        }

        *slash = '/';
    }
    free(path);

    return true;
}
```
其实这里面的算法很简单：
- 1.strdup拷贝一份字符串到path中。
- 2.strspn 是一直找到匹配字符串，直到出现第一个不是"/"
- 3.strcspn 则是一直找不匹配的字符串，直到出现第一个“/”
经过这样拆解，就能把路径一个个分割开。通过这中方式就能直到什么时候遍历完整个路径。
- 4.stat获取path每一个文件夹的权限状态，必须保证每一级别的文件都是0777，也就是读写执行全部权限打开。

### MMKV 的实例化 defaultMMKV与mmkvWithID

#### MMKV java层的实例化
```java
    public static MMKV defaultMMKV() {
        if (rootDir == null) {
            throw new IllegalStateException("You should Call MMKV.initialize() first.");
        }

        long handle = getDefaultMMKV(SINGLE_PROCESS_MODE, null);
        return new MMKV(handle);
    }
```
defaultMMKV此时调用的是getDefaultMMKV这个native方法，默认是单进程模式。从这里的设计都能猜到getDefaultMMKV会从native层实例化一个MMKV对象，并且让实例化好的Java层MMKV对象持有。之后Java层的方法和native层的方法一一映射就能实现一个直接操作native对象的Java对象。

我们再来看看MMKV的mmkvWithID。
```java
    public static MMKV mmkvWithID(String mmapID) {
        if (rootDir == null) {
            throw new IllegalStateException("You should Call MMKV.initialize() first.");
        }

        long handle = getMMKVWithID(mmapID, SINGLE_PROCESS_MODE, null, null);
        return new MMKV(handle);
    }
```
感觉上和defaultMMKV有点相似，也是调用native层方法进行初始化，并且让java层MMKV对象持有native层。那么我们可否认为这两个实例化本质上在底层调用同一个方法，只是多了一个id设置呢？

#### MMKV native层实例化
```cpp
MMKV_JNI jlong getDefaultMMKV(JNIEnv *env, jobject obj, jint mode, jstring cryptKey) {
    MMKV *kv = nullptr;

    if (cryptKey) {
        string crypt = jstring2string(env, cryptKey);
        if (crypt.length() > 0) {
            kv = MMKV::defaultMMKV((MMKVMode) mode, &crypt);
        }
    }
    if (!kv) {
        kv = MMKV::defaultMMKV((MMKVMode) mode, nullptr);
    }

    return (jlong) kv;
}

#define DEFAULT_MMAP_ID "mmkv.default"

MMKV *MMKV::defaultMMKV(MMKVMode mode, string *cryptKey) {
#ifndef MMKV_ANDROID
    return mmkvWithID(DEFAULT_MMAP_ID, mode, cryptKey);
#else
    return mmkvWithID(DEFAULT_MMAP_ID, DEFAULT_MMAP_SIZE, mode, cryptKey);
#endif
}
```
可以看看MMKV.h文件：
```cpp
    static MMKV *mmkvWithID(const std::string &mmapID,
                            int size = mmkv::DEFAULT_MMAP_SIZE,
                            MMKVMode mode = MMKV_SINGLE_PROCESS,
                            std::string *cryptKey = nullptr,
                            MMKVPath_t *relativePath = nullptr);
```
这里就能看到上面的推测是正确的，只要是实例化，最后都是调用mmkvWithID进行实例化。默认的mmkv的id就是mmkv.default。Android端则会设置一个默认的page大小,假设4kb为例子。

```cpp
#    define string2MMKVPath_t(str) (str)

string mmapedKVKey(const string &mmapID, MMKVPath_t *relativePath) {
    if (relativePath && g_rootDir != (*relativePath)) {
        return md5(*relativePath + MMKV_PATH_SLASH + string2MMKVPath_t(mmapID));
    }
    return mmapID;
}


MMKV *MMKV::mmkvWithID(const string &mmapID, int size, MMKVMode mode, string *cryptKey, string *relativePath) {

    if (mmapID.empty()) {
        return nullptr;
    }
    SCOPED_LOCK(g_instanceLock);

    auto mmapKey = mmapedKVKey(mmapID, relativePath);
    auto itr = g_instanceDic->find(mmapKey);
    if (itr != g_instanceDic->end()) {
        MMKV *kv = itr->second;
        return kv;
    }
    if (relativePath) {
        if (!isFileExist(*relativePath)) {
            if (!mkPath(*relativePath)) {
                return nullptr;
            }
        }
        MMKVInfo("prepare to load %s (id %s) from relativePath %s", mmapID.c_str(), mmapKey.c_str(),
                 relativePath->c_str());
    }
    auto kv = new MMKV(mmapID, size, mode, cryptKey, relativePath);
    (*g_instanceDic)[mmapKey] = kv;
    return kv;
}
```
所有的mmkvID以及对应的MMKV实例都会保存在之前实例化的g_instanceDic散列表中。其中mmkv每一个id对应一个文件的路径，其中路径是这么处理的：
> 相对路径(android中是 data/data/包名/files/mmkv) + / + mmkvID

如果发现对应路径下的mmkv在散列表中已经缓存了，则直接返回。否则就会把相对路径保存下来，传递给MMKV进行实例化，并保存在g_instanceDic散列表中。

### MMKV 的构造函数
```cpp
MMKV::MMKV(const string &mmapID, int size, MMKVMode mode, string *cryptKey, string *relativePath)
    : m_mmapID(mmapedKVKey(mmapID, relativePath)) // historically Android mistakenly use mmapKey as mmapID
    , m_path(mappedKVPathWithID(m_mmapID, mode, relativePath))
    , m_crcPath(crcPathWithID(m_mmapID, mode, relativePath))
    , m_file(new MemoryFile(m_path, size, (mode & MMKV_ASHMEM) ? MMFILE_TYPE_ASHMEM : MMFILE_TYPE_FILE))
    , m_metaFile(new MemoryFile(m_crcPath, DEFAULT_MMAP_SIZE, m_file->m_fileType))
    , m_metaInfo(new MMKVMetaInfo())
    , m_crypter(nullptr)
    , m_lock(new ThreadLock())
    , m_fileLock(new FileLock(m_metaFile->getFd(), (mode & MMKV_ASHMEM)))
    , m_sharedProcessLock(new InterProcessLock(m_fileLock, SharedLockType))
    , m_exclusiveProcessLock(new InterProcessLock(m_fileLock, ExclusiveLockType))
    , m_isInterProcess((mode & MMKV_MULTI_PROCESS) != 0 || (mode & CONTEXT_MODE_MULTI_PROCESS) != 0) {
    m_actualSize = 0;
    m_output = nullptr;

    if (cryptKey && cryptKey->length() > 0) {
        m_crypter = new AESCrypt(cryptKey->data(), cryptKey->length());
    }

    m_needLoadFromFile = true;
    m_hasFullWriteback = false;

    m_crcDigest = 0;

    m_sharedProcessLock->m_enable = m_isInterProcess;
    m_exclusiveProcessLock->m_enable = m_isInterProcess;

    // sensitive zone
    {
        SCOPED_LOCK(m_sharedProcessLock);
        loadFromFile();
    }
}
```
我们来看看MMKV构造函数中几个关键的字段是怎么初始化。
- 1.m_mmapID MMKV的ID通过mmapedKVKey创建：
```cpp
string mmapedKVKey(const string &mmapID, MMKVPath_t *relativePath) {
    if (relativePath && g_rootDir != (*relativePath)) {
        return md5(*relativePath + MMKV_PATH_SLASH + string2MMKVPath_t(mmapID));
    }
    return mmapID;
}
```
mmkvID就是经过md5后对应缓存文件对应的路径。

- 2.m_path mmkv 缓存的路径通过mappedKVPathWithID生成

```cpp
MMKVPath_t mappedKVPathWithID(const string &mmapID, MMKVMode mode, MMKVPath_t *relativePath) {
#ifndef MMKV_ANDROID
...
#else
    if (mode & MMKV_ASHMEM) {
        return ashmemMMKVPathWithID(encodeFilePath(mmapID));
    } else if (relativePath) {
#endif
        return *relativePath + MMKV_PATH_SLASH + encodeFilePath(mmapID);
    }
    return g_rootDir + MMKV_PATH_SLASH + encodeFilePath(mmapID);
}
```
能看到这里是根据当前的mode初始化id，如果不是ashmem匿名共享内存模式进行创建，则会和上面的处理类似。id就是经过md5后对应缓存文件对应的路径。

注意这里mode设置的是MMKV_ASHMEM，也就是ashmem匿名共享内存模式则是如下创建方法：
```cpp
constexpr char ASHMEM_NAME_DEF[] = "/dev/ashmem";

MMKVPath_t ashmemMMKVPathWithID(const MMKVPath_t &mmapID) {
    return MMKVPath_t(ASHMEM_NAME_DEF) + MMKV_PATH_SLASH + mmapID;
}
```
实际上就是在驱动目录下的一个内存文件地址。

- 3.m_crcPath 一个.crc文件的路径。这个crc文件实际上用于保存crc数据校验key，避免出现传输异常的数据进行保存了。
- 4.m_file 一个依据m_path构建的内存文件MemoryFile对象。
- 5.m_metaFile 一个依据m_crcPath构建的内存文件MemoryFile对象。
- 6.m_metaInfo 一个MMKVMetaInfo结构体，这个结构体一般是读写的时候，带上的MMKV的版本信息，映射的内存大小，加密crc的key等。
- 7.m_crypter 默认是一个AESCrypt 对称加密器
- 8.m_lock ThreadLock线程锁
- 9.m_fileLock 一个以m_metaFile的fd 文件锁
- 10.m_sharedProcessLock 类型是InterProcessLock，这是一种文件共享锁
- 11.m_exclusiveProcessLock 类型是InterProcessLock，这是一种排他锁
- 12.m_isInterProcess 判断是否打开了多进程模式的标志位，一旦关闭了，所有进程锁都会失效。

接下来，在构造函数中使用了共享的文件锁进行保护后，调用loadFromFile进一步的初始化MMKV内部的数据。

我们大致的了解MMKV中每一个字段的负责的职责，但是具体如何进行工作下文都会解析。

在这里面我们遇到了看起来十分核心的类MemoryFile，它的名字有点像[Ashmem匿名共享内存](https://www.jianshu.com/p/6a8513fdb792)一文中描述过Java层的映射的匿名内存文件。

我们先来看看MemoryFile的初始化。

### MemoryFile的初始化
```cpp
constexpr char ASHMEM_NAME_DEF[] = "/dev/ashmem";

MemoryFile::MemoryFile(const string &path, size_t size, FileType fileType)
    : m_name(path), m_fd(-1), m_ptr(nullptr), m_size(0), m_fileType(fileType) {
    if (m_fileType == MMFILE_TYPE_FILE) {
        reloadFromFile();
    } else {
        // round up to (n * pagesize)
        if (size < DEFAULT_MMAP_SIZE || (size % DEFAULT_MMAP_SIZE != 0)) {
            size = ((size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;
        }
        auto filename = m_name.c_str();
        auto ptr = strstr(filename, ASHMEM_NAME_DEF);
        if (ptr && ptr[sizeof(ASHMEM_NAME_DEF) - 1] == '/') {
            filename = ptr + sizeof(ASHMEM_NAME_DEF);
        }
        m_fd = ASharedMemory_create(filename, size);
        if (m_fd >= 0) {
            m_size = size;
            auto ret = mmap();
            if (!ret) {
                doCleanMemoryCache(true);
            }
        }
    }
}
```
MemeoryFile分为两个模式进行初始化：
##### 1.按照普通的内存文件进行映射到内存
```cpp
void MemoryFile::reloadFromFile() {
...
    m_fd = open(m_name.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, S_IRWXU);
    if (m_fd < 0) {
        MMKVError("fail to open:%s, %s", m_name.c_str(), strerror(errno));
    } else {
        FileLock fileLock(m_fd);
        InterProcessLock lock(&fileLock, ExclusiveLockType);
        SCOPED_LOCK(&lock);

        mmkv::getFileSize(m_fd, m_size);
        // round up to (n * pagesize)
        if (m_size < DEFAULT_MMAP_SIZE || (m_size % DEFAULT_MMAP_SIZE != 0)) {
            size_t roundSize = ((m_size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;
            truncate(roundSize);
        } else {
            auto ret = mmap();
            if (!ret) {
                doCleanMemoryCache(true);
            }
        }
...
    }
}
```
这里的处理很简单：
- 1.首先尝试的打开该路径下file文件,如果fd小于0，说明file没有真正的创建过，则会调用mmap方法在内存中进行映射对应大小的内存。
```cpp
bool MemoryFile::mmap() {
    m_ptr = (char *) ::mmap(m_ptr, m_size, PROT_READ | PROT_WRITE, MAP_SHARED, m_fd, 0);
    if (m_ptr == MAP_FAILED) {
        MMKVError("fail to mmap [%s], %s", m_name.c_str(), strerror(errno));
        m_ptr = nullptr;
        return false;
    }

    return true;
}
```
能看到此时将会调用mmap系统调用，通过设置标志位可读写，MAP_SHARED的模式进行打开。这样就file就在在内核中映射了一段4kb内存，以后访问文件可以不经过内核，直接访问file映射的这一段内存。

关于mmap系统调用的源码解析可以看这一篇[Binder驱动的初始化 映射原理](https://www.jianshu.com/p/4399aedb4d42)。

- 2.如果此时对应的内存文件已经映射过了，将会检测其大小是否是为0，或者是不是刚好是4kb的倍数。如果不是，则找到当前大小最近的4kb倍数同感ftruncate系统调用进行扩容。这样就能保证mmap映射的数据是整齐的页的倍数。这么做就能有效的减少内存碎片。
```cpp
bool MemoryFile::truncate(size_t size) {
...
    auto oldSize = m_size;
    m_size = size;
    // round up to (n * pagesize)
    if (m_size < DEFAULT_MMAP_SIZE || (m_size % DEFAULT_MMAP_SIZE != 0)) {
        m_size = ((m_size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;
    }

    if (::ftruncate(m_fd, static_cast<off_t>(m_size)) != 0) {
        MMKVError("fail to truncate [%s] to size %zu, %s", m_name.c_str(), m_size, strerror(errno));
        m_size = oldSize;
        return false;
    }
    if (m_size > oldSize) {
        if (!zeroFillFile(m_fd, oldSize, m_size - oldSize)) {
            MMKVError("fail to zeroFile [%s] to size %zu, %s", m_name.c_str(), m_size, strerror(errno));
            m_size = oldSize;
            return false;
        }
    }

    if (m_ptr) {
        if (munmap(m_ptr, oldSize) != 0) {
            MMKVError("fail to munmap [%s], %s", m_name.c_str(), strerror(errno));
        }
    }
    auto ret = mmap();
    if (!ret) {
        doCleanMemoryCache(true);
    }
    return ret;
}
```
能看到在这个过程中实际上还是通过ftruncate进行扩容，接着调用zeroFillFile，先通过lseek把指针移动当前容量的最后，并把剩余的部分都填充空数据'\0'。最后映射指向的地址是有效的，会先解开后重新进行映射。

为什么要做最后这个步骤呢？如果阅读过我解析的mmap的源码一文，实际上就能明白，file使用MAP_SHARED的模式本质上是给file结构体绑定一段vma映射好的内存。ftruncate只是给file结构体进行了扩容，但是还没有对对应绑定虚拟内存进行扩容，因此需要解开一次映射后，重新mmap一次。

##### 2.通过Ashmem驱动映射一段共享匿名内存
```cpp
int ASharedMemory_create(const char *name, size_t size) {
    int fd = -1;
    if (g_android_api >= __ANDROID_API_O__) {
        static auto handle = loadLibrary();
        static AShmem_create_t funcPtr =
            (handle != nullptr) ? reinterpret_cast<AShmem_create_t>(dlsym(handle, "ASharedMemory_create")) : nullptr;
        if (funcPtr) {
            fd = funcPtr(name, size);
            if (fd < 0) {
                MMKVError("fail to ASharedMemory_create %s with size %zu, errno:%s", name, size, strerror(errno));
            }
        } else {
            MMKVWarning("fail to locate ASharedMemory_create() from loading libandroid.so");
        }
    }
    if (fd < 0) {
        fd = open(ASHMEM_NAME_DEF, O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            MMKVError("fail to open ashmem:%s, %s", name, strerror(errno));
        } else {
            if (ioctl(fd, ASHMEM_SET_NAME, name) != 0) {
                MMKVError("fail to set ashmem name:%s, %s", name, strerror(errno));
            } else if (ioctl(fd, ASHMEM_SET_SIZE, size) != 0) {
                MMKVError("fail to set ashmem:%s, size %zu, %s", name, size, strerror(errno));
            }
        }
    }
    return fd;
}
```
MMKV在如果使用Ashmem模式打开：
- 1.如果大于Android O就会从libandroid.so中查找ASharedMemory_create 描述符也就是方法地址，直接通过这个方法通过ashmem创建一个映射在ashmem驱动的内存。Ashmem驱动的核心原理请看[Ashmem匿名共享内存](https://www.jianshu.com/p/6a8513fdb792)。

- 2.否则则使用我在Ashmem的文章所说，按照三个步骤进行Ashmem驱动的映射，首先open打开在Ashmem中的映射，接着使用ASHMEM_SET_NAME给匿名内存命名，最后调用ASHMEM_SET_SIZE设置需要在Ashmem中映射的内存大小。

接下来loadFromFile 这个方法可以说是MMKV的核心方法，所有的读写，还是扩容都需要这个方法，从映射的文件内存，缓存到MMKV的内存中。

#### MMKV的初始化 loadFromFile
```cpp
void MMKV::loadFromFile() {
    if (m_metaFile->isFileValid()) {
        m_metaInfo->read(m_metaFile->getMemory());
    }
    if (m_crypter) {
        if (m_metaInfo->m_version >= MMKVVersionRandomIV) {
            m_crypter->resetIV(m_metaInfo->m_vector, sizeof(m_metaInfo->m_vector));
        }
    }

    if (!m_file->isFileValid()) {
        m_file->reloadFromFile();
    }
    if (!m_file->isFileValid()) {
        MMKVError("file [%s] not valid", m_path.c_str());
    } else {
        // error checking
        bool loadFromFile = false, needFullWriteback = false;
        checkDataValid(loadFromFile, needFullWriteback);
...
        auto ptr = (uint8_t *) m_file->getMemory();
        // loading
        if (loadFromFile && m_actualSize > 0) {
....
            MMBuffer inputBuffer(ptr + Fixed32Size, m_actualSize, MMBufferNoCopy);
            if (m_crypter) {
                decryptBuffer(*m_crypter, inputBuffer);
            }
            clearDictionary(m_dic);
            if (needFullWriteback) {
                MiniPBCoder::greedyDecodeMap(m_dic, inputBuffer);
            } else {
                MiniPBCoder::decodeMap(m_dic, inputBuffer);
            }
            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            m_output->seek(m_actualSize);
            if (needFullWriteback) {
                fullWriteback();
            }
        } else {
            // file not valid or empty, discard everything
            SCOPED_LOCK(m_exclusiveProcessLock);

            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            if (m_actualSize > 0) {
                writeActualSize(0, 0, nullptr, IncreaseSequence);
                sync(MMKV_SYNC);
            } else {
                writeActualSize(0, 0, nullptr, KeepSequence);
            }
        }
...
    }

    m_needLoadFromFile = false;
}
```
进入到这个方法后进行如下的处理：
- 1.从m_metaFile内存文件中获取当前MMKV实例的配置保存到m_metaInfo 这个MMKVMetaInfo结构体中。由于是第一次实例化这个时候，内容全是空。稍微看看这个结构体的内容：
```cpp
struct MMKVMetaInfo {
    uint32_t m_crcDigest = 0; //crc校验的数据
    uint32_t m_version = MMKVVersionSequence; //MMKV的状态MMKVVersionSequence = 1,
    uint32_t m_sequence = 0; // full write-back count
    unsigned char m_vector[AES_KEY_LEN] = {};//aes的加密key
    uint32_t m_actualSize = 0;//真实的大小

    // confirmed info: it's been synced to file
    struct {
        uint32_t lastActualSize = 0;
        uint32_t lastCRCDigest = 0;
        uint32_t __reserved__[16] = {};
    } m_lastConfirmedMetaInfo;//已经同步到文件的数据

    void write(void *ptr) {
        MMKV_ASSERT(ptr);
        memcpy(ptr, this, sizeof(MMKVMetaInfo));
    }

    void writeCRCAndActualSizeOnly(void *ptr) {
        MMKV_ASSERT(ptr);
        auto other = (MMKVMetaInfo *) ptr;
        other->m_crcDigest = m_crcDigest;
        other->m_actualSize = m_actualSize;
    }

    void read(const void *ptr) {
        MMKV_ASSERT(ptr);
        memcpy(this, ptr, sizeof(MMKVMetaInfo));
    }
};
```

在这里，遇到了一个比较有歧义的字段m_version ，从名字看起来有点像MMKV的版本号。其实它指代的是MMKV当前的状态，由一个枚举对象代表：
```cpp
enum MMKVVersion : uint32_t {
    MMKVVersionDefault = 0,

    // 记录当前MMKV的完整写回次数
    MMKVVersionSequence = 1,

    // 对随机数据进行加密存储
    MMKVVersionRandomIV = 2,

    // 保存了crc校验和存储存储大小，避免文件损坏
    MMKVVersionActualSize = 3,
};
```



- 2.m_crypter不为空，则判断m_metaInfo中的m_version号是否大于等于2(MMKVVersionRandomIV)，是则调用resetIV方法进行aes加密的初始化。
```cpp
constexpr size_t AES_KEY_LEN = 16;
void AESCrypt::resetIV(const void *iv, size_t ivLength) {
    m_number = 0;
    if (iv && ivLength > 0) {
        memcpy(m_vector, iv, (ivLength > AES_KEY_LEN) ? AES_KEY_LEN : ivLength);
    } else {
        memcpy(m_vector, m_key, AES_KEY_LEN);
    }
}
```
注意m_vector是一个长度16的char数组。其实很简单，就是把文件保存的m_vector获取16位拷贝到m_metaInfo的m_vector中。因为aes的加密必须以16的倍数才能正常运作。


- 3.m_file 真正工作的内存文件发现fd申请的有问题，就重新读取文件映射。

- 4.调用checkDataValid进行MMKV的初始化数据的检测。同时获取到两个标志位loadFromFile 代表是否从能从m_file中正常读取；needFullWriteback是否需要一口气完全写回到内存。

- 5.如果成功读取MemoryFile中的数据，且缓存的数据大小大于0.接下来将会获取内存文件中的数据保存到MMBuffer类中。并且调用AESCrypt的decryptBuffer解密MMBuffer中的内容。清空MMKV中存储键值对的m_dic散列表，并且从本地文件读取。

- 6.如果发现读取MemoryFile中的数据是空的，说明是第一次创建这个缓存文件，我们需要往m_metaFile写入当前MMKV的相关的信息。

初始化分为这6点，我们从最后三点开始聊聊MMKV的初始化的核心逻辑。我们还需要开始关注MMKV中内存存储的结构。

#### checkDataValid 校验MMKV数据有效性机制
```cpp
void MMKV::checkDataValid(bool &loadFromFile, bool &needFullWriteback) {
    // try auto recover from last confirmed location
    auto fileSize = m_file->getFileSize();
    auto checkLastConfirmedInfo = [&] {
        if (m_metaInfo->m_version >= MMKVVersionActualSize) {
            // downgrade & upgrade support
            uint32_t oldStyleActualSize = 0;
            memcpy(&oldStyleActualSize, m_file->getMemory(), Fixed32Size);
            if (oldStyleActualSize != m_actualSize) {
...
                if (oldStyleActualSize < fileSize && (oldStyleActualSize + Fixed32Size) <= fileSize) {
                    if (checkFileCRCValid(oldStyleActualSize, m_metaInfo->m_crcDigest)) {
...
                        return;
                    }
                } else {
...
                }
            }

            auto lastActualSize = m_metaInfo->m_lastConfirmedMetaInfo.lastActualSize;
            if (lastActualSize < fileSize && (lastActualSize + Fixed32Size) <= fileSize) {
                auto lastCRCDigest = m_metaInfo->m_lastConfirmedMetaInfo.lastCRCDigest;
                if (checkFileCRCValid(lastActualSize, lastCRCDigest)) {
                    loadFromFile = true;
                    writeActualSize(lastActualSize, lastCRCDigest, nullptr, KeepSequence);
                } else {
                    ...
                }
            } else {
               ....
            }
        }
    };

    m_actualSize = readActualSize();

    if (m_actualSize < fileSize && (m_actualSize + Fixed32Size) <= fileSize) {
        if (checkFileCRCValid(m_actualSize, m_metaInfo->m_crcDigest)) {
            loadFromFile = true;
        } else {
            checkLastConfirmedInfo();

            if (!loadFromFile) {
                auto strategic = onMMKVCRCCheckFail(m_mmapID);
                if (strategic == OnErrorRecover) {
                    loadFromFile = true;
                    needFullWriteback = true;
                }
                ...
            }
        }
    } else {
        ....

        checkLastConfirmedInfo();

        if (!loadFromFile) {
            auto strategic = onMMKVFileLengthError(m_mmapID);
            if (strategic == OnErrorRecover) {
                // make sure we don't over read the file
                m_actualSize = fileSize - Fixed32Size;
                loadFromFile = true;
                needFullWriteback = true;
            }
            ...
        }
    }
}
``` 
- 1.首先调用readActualSize尝试读取m_file中记录已经存储的数据长度。
```cpp
constexpr uint32_t LittleEdian32Size = 4;

constexpr uint32_t pbFixed32Size() {
    return LittleEdian32Size;
}

constexpr uint32_t Fixed32Size = pbFixed32Size();
```
```cpp
size_t MMKV::readActualSize() {
    MMKV_ASSERT(m_file->getMemory());
    MMKV_ASSERT(m_metaFile->isFileValid());

    uint32_t actualSize = 0;
    memcpy(&actualSize, m_file->getMemory(), Fixed32Size);

    if (m_metaInfo->m_version >= MMKVVersionActualSize) {
        if (m_metaInfo->m_actualSize != actualSize) {
...
        }
        return m_metaInfo->m_actualSize;
    } else {
        return actualSize;
    }
}
```
能看到首先从m_file获取映射的指针地址，往后读取4位数据。这4位数据就是actualSize 真实数据。但是如果是m_metaInfo的m_version 大于等于3，则获取m_metaInfo中保存的actualSize。

- 2.如果读取的到已经存储的数据小于映射内存的大小，或者读取已经读取的数据+4小于等于映射的内存大小，说明可以继续往里面存储不需要扩容。需要进一步的通过checkFileCRCValid校验里面的数据数据是否异常。
```cpp
bool MMKV::checkFileCRCValid(size_t actualSize, uint32_t crcDigest) {
    auto ptr = (uint8_t *) m_file->getMemory();
    if (ptr) {
        m_crcDigest = (uint32_t) CRC32(0, (const uint8_t *) ptr + Fixed32Size, (uint32_t) actualSize);

        if (m_crcDigest == crcDigest) {
            return true;
        }
        MMKVError("check crc [%s] fail, crc32:%u, m_crcDigest:%u", m_mmapID.c_str(), crcDigest, m_crcDigest);
    }
    return false;
}
```
其校验的手段，是通过比较m_metaInfo保存的crcDigest和从m_file中读取的crcDigest进行比较，如果一致说明数据无误，则返回true，设置loadFromFile为true。


- 2.如果crc校验失败则会调用进行如下代码段进行处理。
```cpp
 auto checkLastConfirmedInfo = [&] {
        if (m_metaInfo->m_version >= MMKVVersionActualSize) {
            // downgrade & upgrade support
            uint32_t oldStyleActualSize = 0;
            memcpy(&oldStyleActualSize, m_file->getMemory(), Fixed32Size);
            if (oldStyleActualSize != m_actualSize) {
...
                if (oldStyleActualSize < fileSize && (oldStyleActualSize + Fixed32Size) <= fileSize) {
                    if (checkFileCRCValid(oldStyleActualSize, m_metaInfo->m_crcDigest)) {
...
                        return;
                    }
                } else {
...
                }
            }

            auto lastActualSize = m_metaInfo->m_lastConfirmedMetaInfo.lastActualSize;
            if (lastActualSize < fileSize && (lastActualSize + Fixed32Size) <= fileSize) {
                auto lastCRCDigest = m_metaInfo->m_lastConfirmedMetaInfo.lastCRCDigest;
                if (checkFileCRCValid(lastActualSize, lastCRCDigest)) {
                    loadFromFile = true;
                    writeActualSize(lastActualSize, lastCRCDigest, nullptr, KeepSequence);
                } else {
                    ...
                }
            } else {
               ....
            }
        }
    };
```
其实这里面只处理m_metaInfo的m_version的状态大于等于3的状态。我们回忆一下，在readActualSize方法中，把读取当前存储的数据长度，分为两个逻辑进行读取。如果大于等于3，则从m_metaInfo中获取。

crc校验失败，说明我们写入的时候发生异常。需要强制进行recover恢复数据。
首先要清除crc校验校验了什么东西：
> 1.可以检测出所有奇数位的错。
2.可以检测出双比特的错
3.可以检测出小于等于检测校验长度的突发错


MMKV做了如下处理，只处理状态等级在MMKVVersionActualSize情况。这个情况，在m_metaInfo记录上一次MMKV中的信息。因此可以通过m_metaInfo进行校验已经存储的数据长度，进而更新真实的已经记录数据的长度。

最后读取上一次MMKV还没有更新的备份数据长度和crc校验字段，通过writeActualSize记录在映射的内存中。

如果最后弥补的校验还是crc校验错误，最后会回调onMMKVCRCCheckFail这个方法。这个方法会反射Java层实现的异常处理策略
```cpp
 if (!loadFromFile) {
                auto strategic = onMMKVCRCCheckFail(m_mmapID);
                if (strategic == OnErrorRecover) {
                    loadFromFile = true;
                    needFullWriteback = true;
                }
                MMKVInfo("recover strategic for [%s] is %d", m_mmapID.c_str(), strategic);
            }
```
如果是OnErrorRecover，则设置loadFromFile和needFullWriteback都为true，尽可能的恢复数据。当然如果OnErrorDiscard，则会丢弃掉所有的数据。

- 3.判断此时MMKV中预设的缓存已经满了，避免出现中间出现了上述的异常，也调用了一次checkLastConfirmedInfo进行状态的校验。发现loadFromFile确实为false，说明需要进行可能需要扩容：
```cpp
if (!loadFromFile) {
            auto strategic = onMMKVFileLengthError(m_mmapID);
            if (strategic == OnErrorRecover) {
                m_actualSize = fileSize - Fixed32Size;
                loadFromFile = true;
                needFullWriteback = true;
            }
        }
```
如果发现MMKV在外部进行初始化，异常处理策略是OnErrorRecover,尝试着扩容数据。则给loadFromFile和needFullWriteback都设置为true。m_actualSize为了避免覆盖掉了前面的长度记录，
> 设置真实记录长度 = 文件长度- 4

之后就以这个大小为基准进行扩容，在reloadFromFile方法中进行扩容。


### MMKV第一次初始化或者读取文件失败
```cpp
enum : bool {
    KeepSequence = false,
    IncreaseSequence = true,
};

```
```cpp

            SCOPED_LOCK(m_exclusiveProcessLock);

            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            if (m_actualSize > 0) {
                writeActualSize(0, 0, nullptr, IncreaseSequence);
                sync(MMKV_SYNC);
            } else {
                writeActualSize(0, 0, nullptr, KeepSequence);
            }
```
走到这个分支有两个条件，第一个是读取文件发现大小为0。第二个是读取文件出现了问题。第一个情况将会调用writeActualSize设置KeepSequence，第二个情况则设置IncreaseSequence。

其实writeActualSize这个方法就是往m_metaInfo记录相关于MMKV的信息。

##### writeActualSize
```cpp
#ifndef MMKV_WIN32
#    ifndef likely
#        define unlikely(x) (__builtin_expect(bool(x), 0))
#        define likely(x) (__builtin_expect(bool(x), 1))
#    endif
#else
```
注意if(unlikely(value))和if(likely(value))  都等价于if(value)。唯一不同的是对编译器指令的优化。比如说这里的unlikely的意思是，判断到为假的可能性更大；相对的likely的意思是指，判断到真的可能性更大。

这样的话，编译器就能按照这个思路进行预先优化，将可能性更大的代码段接在判断的后面，减少跳转等指令的调用。


```cpp
bool MMKV::writeActualSize(size_t size, uint32_t crcDigest, const void *iv, bool increaseSequence) {
    // backward compatibility
    oldStyleWriteActualSize(size);

    if (!m_metaFile->isFileValid()) {
        return false;
    }

    bool needsFullWrite = false;
    m_actualSize = size;
    m_metaInfo->m_actualSize = static_cast<uint32_t>(size);
    m_crcDigest = crcDigest;
    m_metaInfo->m_crcDigest = crcDigest;
    if (m_metaInfo->m_version < MMKVVersionSequence) {
        m_metaInfo->m_version = MMKVVersionSequence;
        needsFullWrite = true;
    }
    if (unlikely(iv)) {
        memcpy(m_metaInfo->m_vector, iv, sizeof(m_metaInfo->m_vector));
        if (m_metaInfo->m_version < MMKVVersionRandomIV) {
            m_metaInfo->m_version = MMKVVersionRandomIV;
        }
        needsFullWrite = true;
    }
    if (unlikely(increaseSequence)) {
        m_metaInfo->m_sequence++;
        m_metaInfo->m_lastConfirmedMetaInfo.lastActualSize = static_cast<uint32_t>(size);
        m_metaInfo->m_lastConfirmedMetaInfo.lastCRCDigest = crcDigest;
        if (m_metaInfo->m_version < MMKVVersionActualSize) {
            m_metaInfo->m_version = MMKVVersionActualSize;
        }
        needsFullWrite = true;
    }
#ifdef MMKV_IOS
...
#else
    if (unlikely(needsFullWrite)) {
        m_metaInfo->write(m_metaFile->getMemory());
    } else {
        m_metaInfo->writeCRCAndActualSizeOnly(m_metaFile->getMemory());
    }
    return true;
#endif
}
```
在上文提到过的结构体MMKVMetaInfo其实就是在这里进行赋值。记录了m_actualSize以及crc校验的m_crcDigest。

如果是存储没有数据的话，m_actualSize为0，此时increaseSequence为false；存储过数据m_actualSize则大于0，increaseSequence为true。


- 1.m_version默认是MMKVVersionSequence且iv为null。那么m_version将会设置为MMKVVersionRandomIV。一般来说这个iv的变化说明crc校验码发生了变化。

- 2.如果此时是IncreaseSequence为true，将会把当前的size和crc校验记录到m_lastConfirmedMetaInfo中，并且m_version升级成MMKVVersionActualSize。needsFullWrite都设置为true,m_sequence写回计数+1.

-3.如果是第一次初始化，文件为空或者数据丢失，此时increaseSequence是KeepSequence为false，则不会记录相关写回的数据。

- 3.needsFullWrite为true,所以会走到writeCRCAndActualSizeOnly中。
```cpp
void writeCRCAndActualSizeOnly(void *ptr) {
        MMKV_ASSERT(ptr);
        auto other = (MMKVMetaInfo *) ptr;
        other->m_crcDigest = m_crcDigest;
        other->m_actualSize = m_actualSize;
    }
```
能看到实际上就是把m_crcDigest和m_actualSize拷贝到m_metaFile内存文件映射的文件中。

### MMKV已经初始化过了，第二次打开与异常处理机制
```cpp
        if (loadFromFile && m_actualSize > 0) {
...
            MMBuffer inputBuffer(ptr + Fixed32Size, m_actualSize, MMBufferNoCopy);
            if (m_crypter) {
                decryptBuffer(*m_crypter, inputBuffer);
            }
            clearDictionary(m_dic);
            if (needFullWriteback) {
                MiniPBCoder::greedyDecodeMap(m_dic, inputBuffer);
            } else {
                MiniPBCoder::decodeMap(m_dic, inputBuffer);
            }
            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            m_output->seek(m_actualSize);
            if (needFullWriteback) {
                fullWriteback();
            }
        }
```
这里需要注意一个类MMBuffer，这个类是MMKV的内存单元，里面保存了对应映射的指针，当然在iOS中就是一个NSData指针。
```cpp
class MMBuffer {
private:
    void *ptr;
    size_t size;
    MMBufferCopyFlag isNoCopy;
#ifdef MMKV_APPLE
    NSData *m_data = nil;
#endif

public:
    explicit MMBuffer(size_t length = 0);
    MMBuffer(void *source, size_t length, MMBufferCopyFlag flag = MMBufferCopy);
#ifdef MMKV_APPLE
    explicit MMBuffer(NSData *data, MMBufferCopyFlag flag = MMBufferCopy);
#endif

    MMBuffer(MMBuffer &&other) noexcept;
    MMBuffer &operator=(MMBuffer &&other) noexcept;

    ~MMBuffer();

    void *getPtr() const { return ptr; }

    size_t length() const { return size; }

    // those are expensive, just forbid it for possibly misuse
    explicit MMBuffer(const MMBuffer &other) = delete;
    MMBuffer &operator=(const MMBuffer &other) = delete;
};
```

另一个是MiniPBCoder类，这个类实际上是用于解析Protocol Buffers的对象。这个对象是什么呢？其实可以和json进行类比。和json一样是一种对象序列化的手段。

#### 1.decryptBuffer解析inputBuffer中被AESCrypt加密的数据。
```cpp
void decryptBuffer(AESCrypt &crypter, MMBuffer &inputBuffer) {
    size_t length = inputBuffer.length();
    MMBuffer tmp(length);

    auto input = inputBuffer.getPtr();
    auto output = tmp.getPtr();
    crypter.decrypt(input, output, length);

    inputBuffer = std::move(tmp);
}

void AESCrypt::decrypt(const void *input, void *output, size_t length) {
    if (!input || !output || length == 0) {
        return;
    }
    AES_cfb128_decrypt((const unsigned char *) input, (unsigned char *) output, length, m_aesKey, m_vector, &m_number);
}
```
在这里面使用了OpenSSL 的AES CFB模式进行解析。解析后的数据指针将会指向inputBuffer。

#### 2.needFullWriteback 不管是否为true都会把inputBuffer中的数据加载到全局散列表的m_dic中。
```cpp
void MiniPBCoder::decodeMap(MMKVMap &dic, const MMBuffer &oData, size_t size) {
    MiniPBCoder oCoder(&oData);
    oCoder.decodeOneMap(dic, size, false);
}

void MiniPBCoder::greedyDecodeMap(MMKVMap &dic, const MMBuffer &oData, size_t size) {
    MiniPBCoder oCoder(&oData);
    oCoder.decodeOneMap(dic, size, true);
}
```
能发现其实所有的工作都会通过MiniPBCoder进行解析。在这里我就不对protbuf进行过多的解析，直接看MMKV的核心流程：
```cpp
void MiniPBCoder::decodeOneMap(MMKVMap &dic, size_t size, bool greedy) {
    auto block = [size, this](MMKVMap &dictionary) {
        if (size == 0) {
            [[maybe_unused]] auto length = m_inputData->readInt32();
        }
        while (!m_inputData->isAtEnd()) {
            const auto &key = m_inputData->readString();
            if (key.length() > 0) {
                auto value = m_inputData->readData();
                if (value.length() > 0) {
                    dictionary[key] = move(value);
                } else {
                    dictionary.erase(key);
                }
            }
        }
    };

    if (greedy) {
        try {
            block(dic);
        } catch (std::exception &exception) {
            MMKVError("%s", exception.what());
        }
    } else {
        try {
            MMKVMap tmpDic;
            block(tmpDic);
            dic.swap(tmpDic);
        } catch (std::exception &exception) {
            MMKVError("%s", exception.what());
        }
    }
}
```
实际上decodeOneMap的工作就是把保存在MiniPBCoder中的m_inputData进行解析，在这里就是指MMBuffer。把这些数据解析成一对对的键值对保存在MMKVMap这个m_dic散列表中。

##### 初始化的异常处理机制
而greedy的区别就是指是否直接把数据拷贝到m_dic中，不是则通过一个临时MMKVMap作为中转。我们稍微回忆一下。当MMKV尝试从MMKV缓存数据的文件进行加载时候失败或者内容已经满了，才会设置needFullWriteback为true。换句话说，设置异常处理OnErrorRecover这个标志位只有长度异常和crc校验不通过，且异常处理机制为尽可能的恢复。

那么解析这个地方就很简单了。
如果说此时needFullWriteback为false:如果MMKV在初始化数据是正常的，通过tmp进行swap中转的时候就会正常的设置到m_dic中。但是如果出现了错误，dic还没有从tmp交换容器内容就被异常抛出，m_dic将无法读取出数据。

如果说此时needFullWriteback为true：如果MMKV初始化异常，则因为没有swap直接通过block获取数据，就会尽可能的把缓存在磁盘的数据读取到内存中。


#### 3.通过m_file的映射的内存生成CodedOutputData对象，并且调用seek方法跳到已经记录的数据末尾。
CodedOutputData的实例化可以看到此时是通过m_file往后移动4位之后开始拷贝到CodedOutputData中，其长度fileSize - 4位信息。
```cpp
class CodedOutputData {
    uint8_t *const m_ptr;//内存指针
    size_t m_size;//内存区域大小
    size_t m_position;//读取到哪个位置
...
};

```

```cpp
void CodedOutputData::seek(size_t addedSize) {
    m_position += addedSize;

    if (m_position > m_size) {
        throw out_of_range("OutOfSpace");
    }
}

```

#### 4.needFullWriteback如果为true则调用fullWriteback方法。说明此时出现了crc校验或者文件长度异常，同时异常处理机制为OnErrorRecover。
```cpp
bool MMKV::fullWriteback() {
...

    if (m_dic.empty()) {
        clearAll();
        return true;
    }

    auto allData = MiniPBCoder::encodeDataWithObject(m_dic);
    SCOPED_LOCK(m_exclusiveProcessLock);
    if (allData.length() > 0) {
        auto fileSize = m_file->getFileSize();
        if (allData.length() + Fixed32Size <= fileSize) {
            return doFullWriteBack(std::move(allData));
        } else {

            return ensureMemorySize(allData.length() + Fixed32Size - fileSize);
        }
    }
    return false;
}
```
这里可以分为如下几个步骤：
- 1.如果发现m_dic从磁盘缓存中读取PB数据是空的，则调用clearAll进行处理。
```cpp
void MMKV::clearAll() {
    MMKVInfo("cleaning all key-values from [%s]", m_mmapID.c_str());
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);

    if (m_needLoadFromFile) {
        m_file->reloadFromFile();
    }

    m_file->truncate(DEFAULT_MMAP_SIZE);
    auto ptr = m_file->getMemory();
    if (ptr) {
        memset(ptr, 0, m_file->getFileSize());
    }
    m_file->msync(MMKV_SYNC);

    unsigned char newIV[AES_KEY_LEN];
    AESCrypt::fillRandomIV(newIV);
    if (m_crypter) {
        m_crypter->resetIV(newIV, sizeof(newIV));
    }
    writeActualSize(0, 0, newIV, IncreaseSequence);
    m_metaFile->msync(MMKV_SYNC);

    clearMemoryCache();
    loadFromFile();
}
```
会发生这种情况说明我们就算想要强制恢复数据，发现从磁盘中读取PB数据根本没办法解析任何东西，可以认为这个文件已经完全损坏了，这个文件存在也没有意义，进行如下步骤的处理：
- 调整m_file映射的大小。就会把file中映射的内存全部设置为0初始化，调用msync进行同步处理。
- 重新设置一个新的AESCrypt的key，设置到AESCrypt中，把这些数据通过writeActualSize写到meta_file中进行缓存。清空m_file映射数据后，重新通过loadFromFile初始化m_dic等数据。

- 2.如果发现m_dic调用encodeDataWithObject方法进行PB压缩加密为MMBuffer之后，发现MMBuffer比原来的文件内容要小，则调用doFullWriteBack把完好的数据通过doFullWriteBack写回到错误的文件中。
```cpp
bool MMKV::doFullWriteBack(MMBuffer &&allData) {
    unsigned char newIV[AES_KEY_LEN];
    if (m_crypter) {
        AESCrypt::fillRandomIV(newIV);
        m_crypter->resetIV(newIV, sizeof(newIV));
        auto ptr = allData.getPtr();
        m_crypter->encrypt(ptr, ptr, allData.length());
    }

    auto ptr = (uint8_t *) m_file->getMemory();
    delete m_output;
    m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
    m_output->writeRawData(allData); // note: don't write size of data

    m_actualSize = allData.length();
    if (m_crypter) {
        recaculateCRCDigestWithIV(newIV);
    } else {
        recaculateCRCDigestWithIV(nullptr);
    }
    m_hasFullWriteback = true;
    // make sure lastConfirmedMetaInfo is saved
    sync(MMKV_SYNC);
    return true;
}
```
这里的逻辑很简单，也是做了类似的处理。先经过AES加密后，把MMBuffer的数据通过CodedOutputData写入到m_file中，并更新crc的校验码。

- 3.如果发现encodeDataWithObject压缩后的大小比文件内容大，则会调用ensureMemorySize进行扩容，尝试着扩容成
> 尝试扩容的大小 = 压缩后数据总大小 - 当前文件大小 - 4位长度标志位

```cpp
bool MMKV::ensureMemorySize(size_t newSize) {
....
    // make some room for placeholder
    constexpr size_t ItemSizeHolderSize = 4;
    if (m_dic.empty()) {
        newSize += ItemSizeHolderSize;
    }
    if (newSize >= m_output->spaceLeft() || m_dic.empty()) {
        // try a full rewrite to make space
        auto fileSize = m_file->getFileSize();
        MMBuffer data = MiniPBCoder::encodeDataWithObject(m_dic);
        size_t lenNeeded = data.length() + Fixed32Size + newSize;
        size_t avgItemSize = lenNeeded / std::max<size_t>(1, m_dic.size());
        size_t futureUsage = avgItemSize * std::max<size_t>(8, (m_dic.size() + 1) / 2);
        // 1. no space for a full rewrite, double it
        // 2. or space is not large enough for future usage, double it to avoid frequently full rewrite
        if (lenNeeded >= fileSize || (lenNeeded + futureUsage) >= fileSize) {
            size_t oldSize = fileSize;
            do {
                fileSize *= 2;
            } while (lenNeeded + futureUsage >= fileSize);

            if (!m_file->truncate(fileSize)) {
                return false;
            }

            // check if we fail to make more space
            if (!isFileValid()) {
                return false;
            }
        }
        return doFullWriteBack(std::move(data));
    }
    return true;
}
```
这里的算法也很简单：
- 1.首先算出此时总共需要多少内存：
> 总数据长度 = 原数据长度+标志位+需要扩充大小

- 2.计算平均m_dic中每一项平均占用大小：
> 每一项内存平均大小 = 总数据长度 / max(1,m_dic 的项数)

- 3.futureUsage 扩充的额外容量，减少map的hash散列冲突，相当于扩充了1.5倍
> 扩充的额外容量 =  每一项内存平均大小 * max(8 , (m_dic的项数+1)/2)

- 4.不断的把原来的file大小扩容2倍，直到比扩充的额外容量的大小要大为止，最后通过truncate，把大小变成4kb的倍数。

- 5.doFullWriteBack 写回m_file中记录数据。

到这里MMKV的初始化和错误校验和恢复流程的处理就结束了，我们来看看MMKV是如何读写的。

### MMKV encode 写入数据
这里以常见的encodeString为例子。
根据上面注册的native 方法，我们可以知道对应如下的方法：
```cpp
static string jstring2string(JNIEnv *env, jstring str) {
    if (str) {
        const char *kstr = env->GetStringUTFChars(str, nullptr);
        if (kstr) {
            string result(kstr);
            env->ReleaseStringUTFChars(str, kstr);
            return result;
        }
    }
    return "";
}

MMKV_JNI jboolean encodeString(JNIEnv *env, jobject, jlong handle, jstring oKey, jstring oValue) {
    MMKV *kv = reinterpret_cast<MMKV *>(handle);
    if (kv && oKey) {
        string key = jstring2string(env, oKey);
        if (oValue) {
            string value = jstring2string(env, oValue);
            return (jboolean) kv->set(value, key);
        } else {
            kv->removeValueForKey(key);
            return (jboolean) true;
        }
    }
    return (jboolean) false;
}
```
能看到在这里面本质上就是调用了MMKV的set方法。

```cpp
bool MMKV::set(const string &value, MMKVKey_t key) {
    if (isKeyEmpty(key)) {
        return false;
    }
    auto data = MiniPBCoder::encodeDataWithObject(value);
    return setDataForKey(std::move(data), key);
}
```
这里做了两件事情：
- 1.encodeDataWithObject 编码压缩内容
- 2.setDataForKey 保存数据

#### encodeDataWithObject 编码压缩内容
```cpp
static MMBuffer encodeDataWithObject(const T &obj) {
        try {
            MiniPBCoder pbcoder;
            return pbcoder.getEncodeData(obj);
        } catch (const std::exception &exception) {
            MMKVError("%s", exception.what());
            return MMBuffer();
        }
    }
```
```cpp
MMBuffer MiniPBCoder::getEncodeData(const string &str) {
    m_encodeItems = new vector<PBEncodeItem>();
    size_t index = prepareObjectForEncode(str);
    PBEncodeItem *oItem = (index < m_encodeItems->size()) ? &(*m_encodeItems)[index] : nullptr;
    if (oItem && oItem->compiledSize > 0) {
        m_outputBuffer = new MMBuffer(oItem->compiledSize);
        m_outputData = new CodedOutputData(m_outputBuffer->getPtr(), m_outputBuffer->length());

        writeRootObject();
    }

    return move(*m_outputBuffer);
}
```
- 1.prepareObjectForEncode 这个方法会解析当前的数据，设置相关的编码准备数据。
- 2.根据prepareObjectForEncode的index获取对应的PBEncodeItem对象，通过writeRootObject把数据保存到MMBuffer 临时开辟的缓存中。

#### prepareObjectForEncode
```cpp
size_t MiniPBCoder::prepareObjectForEncode(const string &str) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_String;
        encodeItem->value.strValue = &str;
        encodeItem->valueSize = static_cast<int32_t>(str.size());
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}
```
能看到在这个过程中会把PBEncodeItem缓存到m_encodeItems这个vector集合中。并且设置encodeItem的类型为String，保存string内容，以及字符串大小。最后设置compiledSize记录编码后的大小，这个大小包含了标志位的大小，因此会比原来的大。

#### writeRootObject
```cpp
void MiniPBCoder::writeRootObject() {
    for (size_t index = 0, total = m_encodeItems->size(); index < total; index++) {
        PBEncodeItem *encodeItem = &(*m_encodeItems)[index];
        switch (encodeItem->type) {
            case PBEncodeItemType_Data: {
                m_outputData->writeData(*(encodeItem->value.bufferValue));
                break;
            }
            case PBEncodeItemType_Container: {
                m_outputData->writeUInt32(encodeItem->valueSize);
                break;
            }
            case PBEncodeItemType_String: {
                m_outputData->writeString(*(encodeItem->value.strValue));
                break;
            }

            case PBEncodeItemType_None: {
                MMKVError("%d", encodeItem->type);
                break;
            }
        }
    }
}
```
这里实际上是调用了CodedOutputData的writeString把数据保存到映射的内存中。
```cpp
void CodedOutputData::writeString(const string &value) {
    size_t numberOfBytes = value.size();
    this->writeRawVarint32((int32_t) numberOfBytes);
    if (m_position + numberOfBytes > m_size) {
        auto msg = "m_position: " + to_string(m_position) + ", numberOfBytes: " + to_string(numberOfBytes) +
                   ", m_size: " + to_string(m_size);
        throw out_of_range(msg);
    }
    memcpy(m_ptr + m_position, ((uint8_t *) value.data()), numberOfBytes);
    m_position += numberOfBytes;
}
```
能看到实际上十分简单，就是把数据直接拷贝MMBuffer的临时缓冲区中。并且把存储的位置向后移动存储的长度。并通过m_position保存起来，下一次就从这里开始保存。

最后把这个临时缓冲区MMBuffer返回。

### setDataForKey 保存数据到映射的文件
```cpp
bool MMKV::setDataForKey(MMBuffer &&data, MMKVKey_t key) {
    if (data.length() == 0 || isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();

    auto ret = appendDataWithKey(data, key);
    if (ret) {
        m_dic[key] = std::move(data);
        m_hasFullWriteback = false;
    }
    return ret;
}
```
因为需要开始写入数据了，这里设置了互斥锁，和线程锁。整个步骤分为两步骤：
- 1.checkLoadData 保存数据之前，校验已经存储的数据
- 2.appendDataWithKey 进行数据的保存

#### checkLoadData
```cpp
void MMKV::checkLoadData() {
 ...
    // TODO: atomic lock m_metaFile?
    MMKVMetaInfo metaInfo;
    metaInfo.read(m_metaFile->getMemory());
    if (m_metaInfo->m_sequence != metaInfo.m_sequence) {

        SCOPED_LOCK(m_sharedProcessLock);

        clearMemoryCache();
        loadFromFile();
        notifyContentChanged();
    } else if (m_metaInfo->m_crcDigest != metaInfo.m_crcDigest) {
  
        SCOPED_LOCK(m_sharedProcessLock);

        size_t fileSize = m_file->getActualFileSize();
        if (m_file->getFileSize() != fileSize) {
            clearMemoryCache();
            loadFromFile();
        } else {
            partialLoadFromFile();
        }
        notifyContentChanged();
    }
}
```
- 1.如果发现记录在m_metaFile中的m_sequence和缓存在内存中的m_sequence不一致。说明这个过程中发生过writeActualSize的调用。而这个方法的调用一般是文件读取发生了异常，要么是长度不足，要么是crc校验过不去。此时会进行一次初始化异常处理，因此重新读取一次m_file进行初始化。记住MMKV是支持多进程的，需要不断的校验内存文件是否被另一个进程给写坏了。

- 2.crc发现了变动，说明文件可能进行了扩容，扩容了可能会进行内存重排(重新绑定了mmap)，因此需要重新读取数据。

如果相等说明文件没有扩容，但是因为内存触顶，重新设置MMKV的加密key，而触发了fullWriteback 完全写回，导致文件可能更新了crc校验码。这个过程将会调用partialLoadFromFile从内存文件中更新crc校验码，缓存的数据，数据写入位置到内存中。

#### appendDataWithKey
```cpp
bool MMKV::appendDataWithKey(const MMBuffer &data, MMKVKey_t key) {

    size_t keyLength = key.length();
    // size needed to encode the key
    size_t size = keyLength + pbRawVarint32Size((int32_t) keyLength);
    // size needed to encode the value
    size += data.length() + pbRawVarint32Size((int32_t) data.length());

    SCOPED_LOCK(m_exclusiveProcessLock);

    bool hasEnoughSize = ensureMemorySize(size);
    if (!hasEnoughSize || !isFileValid()) {
        return false;
    }

    m_output->writeString(key);

    m_output->writeData(data); // note: write size of data

    auto ptr = (uint8_t *) m_file->getMemory() + Fixed32Size + m_actualSize;
    if (m_crypter) {
        m_crypter->encrypt(ptr, ptr, size);
    }
    m_actualSize += size;
    updateCRCDigest(ptr, size);

    return true;
}
```
这个过程就很简单了，判断是否有足够的空间，没有则调用ensureMemorySize进行扩容，实在无法从内存中映射出来，那说明系统没空间了就返回异常。

正常情况下，是往全局缓冲区CodedOutputData 先后在文件内存的末尾写入key和value的数据。并对这部分的数据进行一次加密，最后更新这个存储区域的crc校验码。


### decode MMKV读取数据
接下来关注MMKV是如何读取数据的。还是以String为例子
```cpp
MMKV_JNI jstring decodeString(JNIEnv *env, jobject obj, jlong handle, jstring oKey, jstring oDefaultValue) {
    MMKV *kv = reinterpret_cast<MMKV *>(handle);
    if (kv && oKey) {
        string key = jstring2string(env, oKey);
        string value;
        bool hasValue = kv->getString(key, value);
        if (hasValue) {
            return string2jstring(env, value);
        }
    }
    return oDefaultValue;
}
```

```cpp
bool MMKV::getString(MMKVKey_t key, string &result) {
    if (isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    auto &data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            result = MiniPBCoder::decodeString(data);
            return true;
        } catch (std::exception &exception) {
            MMKVError("%s", exception.what());
        }
    }
    return false;
}
```
大致可以分分为两步：
- 1.getDataForKey 通过key找缓存的数据
- 2.decodeString 对获取到的数据进行解码

#### getDataForKey 
```cpp
const MMBuffer &MMKV::getDataForKey(MMKVKey_t key) {
    checkLoadData();
    auto itr = m_dic.find(key);
    if (itr != m_dic.end()) {
        return itr->second;
    }
    static MMBuffer nan;
    return nan;
}
```
由于是一个多进程的组件，因此每一次进行读写之前都需要进行一次checkLoadData的校验。而这个方法从上文可知，通过crc校验码，写回计数，文件长度来判断文件是否发生了变更，是否追加删除数据，从而是否需要重新充内存文件中获取数据缓存到m_dic。

也因此，在getDataForKey方法中，可以直接从m_dic中通过key找value。

#### decodeString
```cpp
string MiniPBCoder::decodeString(const MMBuffer &oData) {
    MiniPBCoder oCoder(&oData);
    return oCoder.decodeOneString();
}
```

```cpp
string MiniPBCoder::decodeOneString() {
    return m_inputData->readString();
}
```

```cpp
string CodedInputData::readString() {
    int32_t size = readRawVarint32();
    if (size < 0) {
        throw length_error("InvalidProtocolBuffer negativeSize");
    }

    auto s_size = static_cast<size_t>(size);
    if (s_size <= m_size - m_position) {
        string result((char *) (m_ptr + m_position), s_size);
        m_position += s_size;
        return result;
    } else {
        throw out_of_range("InvalidProtocolBuffer truncatedMessage");
    }
}
```
能看到实际上很简单就是从m_dic找到对应的MMBuffer数据，此时的可以通过CodedInputData对MMBuffer对应的内存块(已经知道内存起始地址，长度)进行解析数据。


### MMKV 初始化读写的小结
当然可能有人觉得奇怪，当时encode不是已经加密了一个键值对的数据块了吗？为什么在读取时候没有进行AES的解析呢？这里就要说一下AES加密解密都是以128位为一个单位进行加解密。当我们调用loadFromFile方法的时候，在更新m_dic方法就会对整个缓存文件数据进行解密。怎么保证整个文件大小是16位的倍数呢？调用encrypt 也就是AES_cfb128_encrypt的加密时候就会进行一次保险的数据填充。

同理crc校验码实际上并非是对整个内存文件的数据进行一次校对，而实际上是对上一次存储的内存进行一次crc校对。如果上一次存储的内容crc校验码正常，则说明整个MMKV的读写是正确的。

那么我们可以理解MMKVMetaInfo中的m_lastConfirmedMetaInfo结构体的意思了。因为保证了每一次读写的正确性，因此如果想要恢复，只需要通过m_lastConfirmedMetaInfo记录最近一次读写的状态，对meta_file进行恢复即可达到原来的MMKV应有的配置。


### MMKV 进程锁设计
MMKV作为一个多进程组件，其多进程如何进行同步也是值得我们学习的。重新回顾一下，进程的文件锁有几种操作方式：
> 1. LOCK_EX 排他锁 定义的代码范围中只允许一个进程操作
> 2.LOCK_SH 共享锁 定义的代码范围中允许多个进程操作
> 3.LOCK_UN 释放锁 释放锁定的区域


其实在早两年前，我写过一章关于线程的设计与思考。其中有聊到过读写锁。其实对于一个文件还是内存读写而言，最害怕的是读取出来的信息有误。有什么方法避免呢？其实就可以通过读写锁的设计进行避免。当写的时候只允许一个进程或者线程，这样就能保证文件或者内存中的内容不变。这样读取数据的时候也没有必要进行加锁处理。这种思路在进程锁也是同理。

所以在MMKV中用排他锁作为写锁，用共享锁作为读锁。

这是一个很简单且通用的思想。但是MMKV选择自己实现了一个文件锁？而不是直接使用Linux系统提供的api flock，这是为什么呢？这就是大神和普通程序员的区别了。

他们除了考虑了单一锁的情况，还考虑更加特殊常见的锁加完再加锁的递归锁问题以及锁的升降级。文件锁不支持锁的升降级。如果支持锁的升级，容易发生死锁。

> 死锁发生的四个条件：
> 1.互斥条件： 一段时间内资源只允许一个任务持有
> 2.不可剥夺条件： 任务所获的的资源只能由自己释放
> 3.请求与保持条件：任务已经持有了一个资源，但是又提出了新的资源请求，而该资源被另一个任务持有，此时请求的行为被阻塞，不释放自己的资源
> 4.循环等待 若干任务形成首尾相接的循环等待资源

死锁产生的两个原因:
> 1.系统资源的竞争
> 2.任务运行的推进顺序顺序不当

注:这里的任务特指进程或者线程

在这个过程中，如果2个进程中持有了读锁，都想升级为写锁，就可能被阻塞进入到死锁状态。其次文件锁也不支持锁的降级，一旦解开了就消失了。

可以在MMKV的构造函数中，知道有两种进程锁会存在其中。一个是排他锁，一个是共享锁。他们的类型都是InterProcessLock。InterProcessLock其中的核心就是FileLock文件锁。
```cpp
class InterProcessLock {
    FileLock *m_fileLock;
    LockType m_lockType;

public:
    InterProcessLock(FileLock *fileLock, LockType lockType)
        : m_fileLock(fileLock), m_lockType(lockType), m_enable(true) {
        MMKV_ASSERT(m_fileLock);
    }

    bool m_enable;

    void lock() {
        if (m_enable) {
            m_fileLock->lock(m_lockType);
        }
    }

    bool try_lock() {
        if (m_enable) {
            return m_fileLock->try_lock(m_lockType);
        }
        return false;
    }

    void unlock() {
        if (m_enable) {
            m_fileLock->unlock(m_lockType);
        }
    }
};
```
这里面对应MMKV Java的native api有三个，lock，unlock，try_lock。分别是上锁，解锁，尝试上锁。我们先来看看上锁逻辑

#### MMKV 文件锁上锁
```cpp
bool FileLock::lock(LockType lockType) {
    return doLock(lockType, true);
}

bool FileLock::try_lock(LockType lockType) {
    return doLock(lockType, false);
}
```
能看到本质上就是一个都是调用doLock方法。
```cpp
bool FileLock::doLock(LockType lockType, bool wait) {
    if (!isFileLockValid()) {
        return false;
    }
    bool unLockFirstIfNeeded = false;

    if (lockType == SharedLockType) {
        // don't want shared-lock to break any existing locks
        if (m_sharedLockCount > 0 || m_exclusiveLockCount > 0) {
            m_sharedLockCount++;
            return true;
        }
    } else {
        // don't want exclusive-lock to break existing exclusive-locks
        if (m_exclusiveLockCount > 0) {
            m_exclusiveLockCount++;
            return true;
        }
        // prevent deadlock
        if (m_sharedLockCount > 0) {
            unLockFirstIfNeeded = true;
        }
    }

    auto ret = platformLock(lockType, wait, unLockFirstIfNeeded);
    if (ret) {
        if (lockType == SharedLockType) {
            m_sharedLockCount++;
        } else {
            m_exclusiveLockCount++;
        }
    }
    return ret;
}
```
- 1.如果是共享锁想要加锁，判断到已经有共享锁或者排他锁已经在本进程已经添加了，此时共享锁直接返回true，不需要真的调用lock方法。
- 2.排斥锁类型想要加锁，如果发现已经加了排他锁(m_exclusiveLockCount 排他锁计数)，则直接返回。如果m_sharedLockCount 共享锁加锁计数大于0则设置unLockFirstIfNeeded为true(防止死锁)。

换句话说，如果是共享锁想要加锁，只有m_sharedLockCount和m_exclusiveLockCount计数都为0，才会真的走到platformLock执行。

如果排他锁想要加锁，只有m_exclusiveLockCount 排他锁计数为0才会执行platformLock。

只有platformLock 执行成功了，才会给对应类型锁的对应计数+1.

#### platformLock
```cpp
static int32_t LockType2FlockType(LockType lockType) {
    switch (lockType) {
        case SharedLockType:
            return LOCK_SH;
        case ExclusiveLockType:
            return LOCK_EX;
    }
    return LOCK_EX;
}

bool FileLock::platformLock(LockType lockType, bool wait, bool unLockFirstIfNeeded) {
#    ifdef MMKV_ANDROID
    if (m_isAshmem) {
        return ashmemLock(lockType, wait, unLockFirstIfNeeded);
    }
#    endif
    auto realLockType = LockType2FlockType(lockType);
    auto cmd = wait ? realLockType : (realLockType | LOCK_NB);
    if (unLockFirstIfNeeded) {
        // try lock
        auto ret = flock(m_fd, realLockType | LOCK_NB);
        if (ret == 0) {
            return true;
        }
        // let's be gentleman: unlock my shared-lock to prevent deadlock
        ret = flock(m_fd, LOCK_UN);
        if (ret != 0) {
            ...
        }
    }

    auto ret = flock(m_fd, cmd);
    if (ret != 0) {
...
        // try recover my shared-lock
        if (unLockFirstIfNeeded) {
            ret = flock(m_fd, LockType2FlockType(SharedLockType));
            if (ret != 0) {
                // let's hope this never happen
....
            }
        }
        return false;
    } else {
        return true;
    }
}
```
- 1.如果发现锁是Ashmem匿名内存的锁，则调用ashmemLock处理

- 2.unLockFirstIfNeeded 这个标志位只有在排他锁(写锁)想要上锁的时候，发现有共享锁(读锁)已经上锁了才为true。则会尝试进行进行排他锁(写锁)的阻塞的上锁等待，一旦失败，则解开共享锁(读锁)，在加上排他锁(写锁)。这样能避免2个读锁同时存在，另一个进程也想升级成排他锁(写锁)。

- 3.其他情况则根据wait标志位来决定是否需要进行阻塞,这就是tryLock和lock的区别，tryLock不会阻塞。

- 4.最后如果此时已经有读锁，想上写锁的情况下，则会把写锁降级为读锁并返回false。

到这里就完成了MMKV的进程锁的解析。


## 总结
限于篇幅问题，MMKV的源码解析到这里就结束了。不过MMKV比较核心的思想已经解析了，剩下的就是关于AES和CRC校验算法，以及Ashmem如何进行同步的问题。不过有了这些基础，继续研读MMKV代码就不会那么吃力了。

老规矩，先用一幅图来总结MMKV:
![MMKV.jpg](/images/MMKV.jpg)



其实从[OKio](https://www.jianshu.com/p/5061860545ef)一文中我已经讨论过几种基于映射的共享内存读写和普通的io读写的区别。

由于MMKV读写是直接读写到mmap文件映射的内存上，绕开了普通读写io需要进入内核，写到磁盘的过程。光是这种级别优化，都可以拉开三个数量级的性能差距。但是也诞生了一个很大的问题，一个进程在32位的机子中有4g的虚拟内存限制，而我们把文件映射到虚拟内存中，如果文件过大虚拟内存就会出现大量的消耗最后出现异常，对于不熟悉Linux的朋友就无法理解这种现象。

当然这里不说OOM是因为Java虚拟机在初始化时候就提前预定好一段映射的内存，这里暂时不说了，之后会有虚拟机解析的专题，我们在详细聊聊。

阅读源码后，这里有几个关于MMKV使用的注意事项：
- 1.保证每一个文件存储的数据都比较小，也就说需要把数据根据业务线存储分散。这要就不会把虚拟内存消耗过快。

- 2.还需要在适当的时候释放一部分内存数据，比如在App中监听onTrimMemory方法，在Java内存吃紧的情况下进行MMKV的trim操作(不准确，我们暂时以此为信号，最好自己监听进程中内存使用情况)。

- 2.在不需要使用的时候，最好把MMKV给close掉。甚至调用exit方法。

SharedPreferences的源码解析放到下一篇，我们来快速看看为什么SharedPreferences会出现卡顿甚至ANR，我们该怎么自定义一个属于自己的SharedPreferences


