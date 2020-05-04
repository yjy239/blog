---
title: Android 重学系列 资源管理系统 资源的初始化加载(上)
top: false
cover: false
date: 2019-11-03 23:22:40
img:
tag:
description:
author: yjy239
summary:
categories: Android 资源系统
tags:
- Android
- Android Framework
---
# 前言
如果遇到问题欢迎在这个地址下留言：[https://www.jianshu.com/p/817a787910f2](https://www.jianshu.com/p/817a787910f2)

上一篇文章和大家聊了聊Android是如何进行View的实例化。但是还是遗留了一个问题，Android是怎么读取资源文件的，本文将会和大家来聊聊关于Resources类是怎么读取到底层资源的。

其实这部分，有部分内容在我写插件化的文章里面有聊到过，也画过一张简单的时序图，不过这只是Resources类在Java层怎么初始化，怎么获取对应资源的。本文将会更加重点的，系统的探索，native的初始化以及读取数据。

![Framework层的资源查找与context绑定.png](/images/Framework层的资源查找与context绑定.png)

不过，这仅仅只是一个很粗略的时序图。实际上每个Resources都会被ResourcesManager管理着。但是Resources相当于一个代理类，实际上真正的操作都是由ResourcesImpl去完成。

ResourcesImpl管理着什么？它一般管理着一个apk中各种资源文件，其中它有一个很核心的类AssetManager，这才是真正连通native层进行解析。别看AssetManager的名字上好像指管理着asset文件夹，但是它的管理范围一般是ApkAsset这个资源抽象对象。

有了大致的印象，我们来看看整个Android系统是如何管理ApksAsset以及AssetManager；就大致上弄明白了Android系统的资源管理体系。

# 正文

从上面时序图中，我们可以主要的关注一下ContextImpl是怎么初始化的？怎么获取到资源访问的能力的，把目光放在createActivityContext方法上。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)
```java
    static ContextImpl createActivityContext(ActivityThread mainThread,
            LoadedApk packageInfo, ActivityInfo activityInfo, IBinder activityToken, int displayId,
            Configuration overrideConfiguration) {
        if (packageInfo == null) throw new IllegalArgumentException("packageInfo");

        String[] splitDirs = packageInfo.getSplitResDirs();
        ClassLoader classLoader = packageInfo.getClassLoader();

        if (packageInfo.getApplicationInfo().requestsIsolatedSplitLoading()) {
            try {
                classLoader = packageInfo.getSplitClassLoader(activityInfo.splitName);
                splitDirs = packageInfo.getSplitPaths(activityInfo.splitName);
            } catch (NameNotFoundException e) {
                // Nothing above us can handle a NameNotFoundException, better crash.
                throw new RuntimeException(e);
            } finally {
            }
        }

        ContextImpl context = new ContextImpl(null, mainThread, packageInfo, activityInfo.splitName,
                activityToken, null, 0, classLoader);

        // Clamp display ID to DEFAULT_DISPLAY if it is INVALID_DISPLAY.
        displayId = (displayId != Display.INVALID_DISPLAY) ? displayId : Display.DEFAULT_DISPLAY;

        final CompatibilityInfo compatInfo = (displayId == Display.DEFAULT_DISPLAY)
                ? packageInfo.getCompatibilityInfo()
                : CompatibilityInfo.DEFAULT_COMPATIBILITY_INFO;

        final ResourcesManager resourcesManager = ResourcesManager.getInstance();

        // Create the base resources for which all configuration contexts for this Activity
        // will be rebased upon.
        context.setResources(resourcesManager.createBaseActivityResources(activityToken,
                packageInfo.getResDir(),
                splitDirs,
                packageInfo.getOverlayDirs(),
                packageInfo.getApplicationInfo().sharedLibraryFiles,
                displayId,
                overrideConfiguration,
                compatInfo,
                classLoader));
        context.mDisplay = resourcesManager.getAdjustedDisplay(displayId,
                context.getResources());
        return context;
    }
```
这里面我们能够看到之前在插件话分析一文熟悉的LoadApk对象，这个对象代表这apk包在Android中的内存对象。关于这个对象，将会在PMS中和大家解析解析。

我们先不去细究这个对象是怎么来的。但是我们可以方法名字大致上知道做了如下几个事情：
-  1.读取保存在LoadApk中的资源文件夹
- 2.读取LoadApk中的classLoader，作为当前应用的主要ClassLoader。
- 3.实例化ContextImpl，这个ContextImpl在绝大部分情况下就是我们应用开发常用的Context。
- 4.初始化ResourceManager，资源管理器
- 5. 把资源管理设置到Context中，之后Context才具有访问资源的能力。

本文主要关注资源的加载，因此我们只需要研究ResourceManager，就能明白资源加载的原理了，关注下面这两行代码：
```java
        final ResourcesManager resourcesManager = ResourcesManager.getInstance();

        // Create the base resources for which all configuration contexts for this Activity
        // will be rebased upon.
        context.setResources(resourcesManager.createBaseActivityResources(activityToken,
                packageInfo.getResDir(),
                splitDirs,
                packageInfo.getOverlayDirs(),
                packageInfo.getApplicationInfo().sharedLibraryFiles,
                displayId,
                overrideConfiguration,
                compatInfo,
                classLoader));
```

因此，资源的初始化放在这个函数上：
- createBaseActivityResources 打开资源映射，初步解析Resource中的资源

## createBaseActivityResources 打开资源映射
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ResourcesManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ResourcesManager.java)

```java
    public @Nullable Resources createBaseActivityResources(@NonNull IBinder activityToken,
            @Nullable String resDir,
            @Nullable String[] splitResDirs,
            @Nullable String[] overlayDirs,
            @Nullable String[] libDirs,
            int displayId,
            @Nullable Configuration overrideConfig,
            @NonNull CompatibilityInfo compatInfo,
            @Nullable ClassLoader classLoader) {
        try {
            final ResourcesKey key = new ResourcesKey(
                    resDir,
                    splitResDirs,
                    overlayDirs,
                    libDirs,
                    displayId,
                    overrideConfig != null ? new Configuration(overrideConfig) : null, // Copy
                    compatInfo);
            classLoader = classLoader != null ? classLoader : ClassLoader.getSystemClassLoader();


            synchronized (this) {
                // Force the creation of an ActivityResourcesStruct.
                getOrCreateActivityResourcesStructLocked(activityToken);
            }

            // Update any existing Activity Resources references.
            updateResourcesForActivity(activityToken, overrideConfig, displayId,
                    false /* movedToDifferentDisplay */);

            // Now request an actual Resources object.
            return getOrCreateResources(activityToken, key, classLoader);
        } finally {
        }
    }
```
- 1.基于所有的资源目录，显示屏id，配置生成一个ResourcesKey。
- 2. getOrCreateActivityResourcesStructLocked 生成ActivityResources并且保存在缓存到map。
- 3. 根据ResourcesKey，生成一个资源的实际操作者ResourceImpl。

### 缓存ActivityResources到list中
```java
    private ActivityResources getOrCreateActivityResourcesStructLocked(
            @NonNull IBinder activityToken) {
        ActivityResources activityResources = mActivityResourceReferences.get(activityToken);
        if (activityResources == null) {
            activityResources = new ActivityResources();
            mActivityResourceReferences.put(activityToken, activityResources);
        }
        return activityResources;
    }

    private static class ActivityResources {
        public final Configuration overrideConfig = new Configuration();
        public final ArrayList<WeakReference<Resources>> activityResources = new ArrayList<>();
    }
```
这个缓存对象本质上控制着所有在Apk中所有的Resources资源对象，有了缓存之后，之后读取资源就不需要重新打开资源目录这些耗时操作。本质上和View的实例化一节中聊过的一样，为了减少反射的次数，会把已经反射过的View的构造函数保存下来，等待下次使用。

### 根据ResourcesKey，生成ResourceImpl

#### updateResourcesForActivity
先来看看updateResourcesForActivity方法，更新Resource的配置。
```java
    public void updateResourcesForActivity(@NonNull IBinder activityToken,
            @Nullable Configuration overrideConfig, int displayId,
            boolean movedToDifferentDisplay) {
        try {
            synchronized (this) {
                final ActivityResources activityResources =
                        getOrCreateActivityResourcesStructLocked(activityToken);

...

                // Rebase each Resources associated with this Activity.
                final int refCount = activityResources.activityResources.size();
                for (int i = 0; i < refCount; i++) {
                    WeakReference<Resources> weakResRef = activityResources.activityResources.get(
                            i);
                    Resources resources = weakResRef.get();
                    if (resources == null) {
                        continue;
                    }

                    // Extract the ResourcesKey that was last used to create the Resources for this
                    // activity.
                    final ResourcesKey oldKey = findKeyForResourceImplLocked(resources.getImpl());
                    if (oldKey == null) {
                        continue;
                    }

                    // Build the new override configuration for this ResourcesKey.
                    final Configuration rebasedOverrideConfig = new Configuration();
                    if (overrideConfig != null) {
                        rebasedOverrideConfig.setTo(overrideConfig);
                    }

                    if (activityHasOverrideConfig && oldKey.hasOverrideConfiguration()) {
                        // Generate a delta between the old base Activity override configuration and
                        // the actual final override configuration that was used to figure out the
                        // real delta this Resources object wanted.
                        Configuration overrideOverrideConfig = Configuration.generateDelta(
                                oldConfig, oldKey.mOverrideConfiguration);
                        rebasedOverrideConfig.updateFrom(overrideOverrideConfig);
                    }

                    // Create the new ResourcesKey with the rebased override config.
                    final ResourcesKey newKey = new ResourcesKey(oldKey.mResDir,
                            oldKey.mSplitResDirs,
                            oldKey.mOverlayDirs, oldKey.mLibDirs, displayId,
                            rebasedOverrideConfig, oldKey.mCompatInfo);


                    ResourcesImpl resourcesImpl = findResourcesImplForKeyLocked(newKey);
                    if (resourcesImpl == null) {
                        resourcesImpl = createResourcesImpl(newKey);
                        if (resourcesImpl != null) {
                            mResourceImpls.put(newKey, new WeakReference<>(resourcesImpl));
                        }
                    }

                    if (resourcesImpl != null && resourcesImpl != resources.getImpl()) {
                        // Set the ResourcesImpl, updating it for all users of this Resources
                        // object.
                        resources.setImpl(resourcesImpl);
                    }
                }
            }
        } finally {

        }
    }
```
这个方法本质上是更新保存在activityResources的Resource实例。能看到每一次都会尝试通过组合出来的ResourceKey来寻找之前是否存在ResourcesKey老的ResourceKey。

没有则不会继续下去，有则会根据原来的老ResourceKey重新生成新的ResourceKey，中间改变的是配置，接着根据新的ResourceKey寻找ResourceImpl，不存在则创建一个，并且把key和ResourceImpl设置mResourceImpls。

能看到中间有2个核心的方法：
- findResourcesImplForKeyLocked 查找对应ResourcesImpl
- createResourcesImpl 创建一个ResourcesImpl
先暂停在这里，我们先去看看getOrCreateResources，再回头看看这两个方法。

#### getOrCreateResources
```java
    private @Nullable Resources getOrCreateResources(@Nullable IBinder activityToken,
            @NonNull ResourcesKey key, @NonNull ClassLoader classLoader) {
        synchronized (this) {


            if (activityToken != null) {
                final ActivityResources activityResources =
                        getOrCreateActivityResourcesStructLocked(activityToken);

                // Clean up any dead references so they don't pile up.
                ArrayUtils.unstableRemoveIf(activityResources.activityResources,
                        sEmptyReferencePredicate);

                // Rebase the key's override config on top of the Activity's base override.
...
                ResourcesImpl resourcesImpl = findResourcesImplForKeyLocked(key);
                if (resourcesImpl != null) {

                    return getOrCreateResourcesForActivityLocked(activityToken, classLoader,
                            resourcesImpl, key.mCompatInfo);
                }

                // We will create the ResourcesImpl object outside of holding this lock.

            } else {
                // Clean up any dead references so they don't pile up.
                ArrayUtils.unstableRemoveIf(mResourceReferences, sEmptyReferencePredicate);

                // Not tied to an Activity, find a shared Resources that has the right ResourcesImpl
                ResourcesImpl resourcesImpl = findResourcesImplForKeyLocked(key);
                if (resourcesImpl != null) {

                    return getOrCreateResourcesLocked(classLoader, resourcesImpl, key.mCompatInfo);
                }

                // We will create the ResourcesImpl object outside of holding this lock.
            }

            // If we're here, we didn't find a suitable ResourcesImpl to use, so create one now.
            ResourcesImpl resourcesImpl = createResourcesImpl(key);
            if (resourcesImpl == null) {
                return null;
            }

            // Add this ResourcesImpl to the cache.
            mResourceImpls.put(key, new WeakReference<>(resourcesImpl));

            final Resources resources;
            if (activityToken != null) {
                resources = getOrCreateResourcesForActivityLocked(activityToken, classLoader,
                        resourcesImpl, key.mCompatInfo);
            } else {
                resources = getOrCreateResourcesLocked(classLoader, resourcesImpl, key.mCompatInfo);
            }
            return resources;
        }
    }
```
这里分为两种情况：
- 1.存在activityToken 是指开发应用层的应用
- 2.不存在activityToken 是指系统应用



#### 当activityToken存在的时候
当activityToken存在的时候，这里是指应用启动的时候要做的事情。
- 1.首先会尝试去查找ResourcesImpl是否缓存起来，如下：
```java
    private ResourcesImpl findResourcesImplForKeyLocked(@NonNull ResourcesKey key) {
        WeakReference<ResourcesImpl> weakImplRef = mResourceImpls.get(key);
        ResourcesImpl impl = weakImplRef != null ? weakImplRef.get() : null;
        if (impl != null && impl.getAssets().isUpToDate()) {
            return impl;
        }
        return null;
    }
```
能看到每一个ResourcesImpl将会保存到mResourceImpls这个ArrayMap中。


当ResourceImpl存在会调用getOrCreateResourcesLocked，当通过ResourcesImpl反过来查找Resource代理类，没有找到，则会重新生成一个新的Resource，添加到mResourceReferences弱引用缓存中。

##### ResourcesImpl的创建
当ResourcesImpl不存在的时候，就需要创建ResourcesImpl。
```java
    private @NonNull ResourcesImpl createResourcesImpl(@NonNull ResourcesKey key) {
        final DisplayAdjustments daj = new DisplayAdjustments(key.mOverrideConfiguration);
        daj.setCompatibilityInfo(key.mCompatInfo);

        final AssetManager assets = createAssetManager(key);
        final DisplayMetrics dm = getDisplayMetrics(key.mDisplayId, daj);
        final Configuration config = generateConfig(key, dm);
        final ResourcesImpl impl = new ResourcesImpl(assets, dm, config, daj);
        if (DEBUG) {
            Slog.d(TAG, "- creating impl=" + impl + " with key: " + key);
        }
        return impl;
    }
```
能看到在创建ResourcesImpl的同时会创建AssetManager。而这个AssetManager就是管理apk包中asset资源的管理者，我们只要需要访问资源就一定和它打交道。

## AssetManager的创建准备
```java
    protected @Nullable AssetManager createAssetManager(@NonNull final ResourcesKey key) {
        final AssetManager.Builder builder = new AssetManager.Builder();

        if (key.mResDir != null) {
            try {
                builder.addApkAssets(loadApkAssets(key.mResDir, false /*sharedLib*/,
                        false /*overlay*/));
            } catch (IOException e) {
                Log.e(TAG, "failed to add asset path " + key.mResDir);
                return null;
            }
        }

        if (key.mSplitResDirs != null) {
            for (final String splitResDir : key.mSplitResDirs) {
                try {
                    builder.addApkAssets(loadApkAssets(splitResDir, false /*sharedLib*/,
                            false /*overlay*/));
                } catch (IOException e) {
...
                    return null;
                }
            }
        }

        if (key.mOverlayDirs != null) {
            for (final String idmapPath : key.mOverlayDirs) {
                try {
                    builder.addApkAssets(loadApkAssets(idmapPath, false /*sharedLib*/,
                            true /*overlay*/));
                } catch (IOException e) {
...
                }
            }
        }

        if (key.mLibDirs != null) {
            for (final String libDir : key.mLibDirs) {
                if (libDir.endsWith(".apk")) {
                    // Avoid opening files we know do not have resources,
                    // like code-only .jar files.
                    try {
                        builder.addApkAssets(loadApkAssets(libDir, true /*sharedLib*/,
                                false /*overlay*/));
                    } catch (IOException e) {
....
                    }
                }
            }
        }

        return builder.build();
    }
```
看到这里，我们稍微回忆一下我写的插件化框架一文，其中有一段就是需要加载插件中的资源，在Android 9.0中需要用到一个核心方法addApkAssets；而在老版本中这里面的方法是assets.addAssetPath代替。为什么我们知道这样加载资源，是因为资源正是使用这种方式把资源加载到AssetManager。

这里的步骤可以分为2个步骤：
- loadApkAssets 读取资源目录的资源生成ApkAsset对象
- addApkAssets把所有的对象都添加到AssetManager建造者中，最后生成AssetManager对象

那么这里就有三个核心方法，一个是通过建造模式创建AssetManager，一个addApkAssets，一个loadApkAssets读取目录下的资源接下来，接下来一次看看这些完成什么？


### loadApkAssets 读取目录的资源，生成ApkAsset对象
```java
    private @NonNull ApkAssets loadApkAssets(String path, boolean sharedLib, boolean overlay)
            throws IOException {
        final ApkKey newKey = new ApkKey(path, sharedLib, overlay);
        ApkAssets apkAssets = mLoadedApkAssets.get(newKey);
        if (apkAssets != null) {
            return apkAssets;
        }

        // Optimistically check if this ApkAssets exists somewhere else.
        final WeakReference<ApkAssets> apkAssetsRef = mCachedApkAssets.get(newKey);
        if (apkAssetsRef != null) {
            apkAssets = apkAssetsRef.get();
            if (apkAssets != null) {
                mLoadedApkAssets.put(newKey, apkAssets);
                return apkAssets;
            } else {
                // Clean up the reference.
                mCachedApkAssets.remove(newKey);
            }
        }

        if (overlay) {
            apkAssets = ApkAssets.loadOverlayFromPath(overlayPathToIdmapPath(path),
                    false /*system*/);
        } else {
            apkAssets = ApkAssets.loadFromPath(path, false /*system*/, sharedLib);
        }
        mLoadedApkAssets.put(newKey, apkAssets);
        mCachedApkAssets.put(newKey, new WeakReference<>(apkAssets));
        return apkAssets;
    }
```
##### 资源缓存思路
> 我们能看到所有的资源目录路径下都会生成一个ApkAssets对象，并且缓存起来，做了二级缓存。

- 第一级缓存：mLoadedApkAssets保存这所有已经加载的了ApkAssets的强引用。
- 第二级缓存：mCachedApkAssets保存这所有加载过的ApkAssets的弱引用。

首先先从mLoadedApkAssets查找是否已经存在已经加载的资源，找不到则尝试着从mCachedApkAssets中查找，如果找到了，则从mCachedApkAssets中移除，并且添加到mLoadedApkAssets中。

实际上这种思路在Glide中有体现，我们可以把这种缓存看作内存缓存，把缓存拆分两部分，活跃缓存以及非活跃缓存。活跃缓存持有强引用避免GC销毁，而非活跃活跃缓存则持有弱引用，就算GC销毁了也不会有什么问题。

当什么都找不到，只好从磁盘中读取资源。

### 创建ApkAssets资源对象
ApkAssets可以通过两种方式创建：
- ApkAssets.loadOverlayFromPath 当apk使用到了额外重叠的资源目录对应的ApkAsset
- ApkAssets.loadFromPath 当apk使用一般的资源，比如的value资源，第三方资源库等创建对应的ApkAsset。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ApkAssets.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ApkAssets.java)
```java
   public static @NonNull ApkAssets loadOverlayFromPath(@NonNull String idmapPath, boolean system)
            throws IOException {
        return new ApkAssets(idmapPath, system, false /*forceSharedLibrary*/, true /*overlay*/);
    }

    public static @NonNull ApkAssets loadFromPath(@NonNull String path, boolean system,
            boolean forceSharedLibrary) throws IOException {
        return new ApkAssets(path, system, forceSharedLibrary, false /*overlay*/);
    }

    public static @NonNull ApkAssets loadFromPath(@NonNull String path, boolean system)
            throws IOException {
        return new ApkAssets(path, system, false /*forceSharedLib*/, false /*overlay*/);
    }

    private ApkAssets(@NonNull String path, boolean system, boolean forceSharedLib, boolean overlay)
            throws IOException {
        mNativePtr = nativeLoad(path, system, forceSharedLib, overlay);
        mStringBlock = new StringBlock(nativeGetStringBlock(mNativePtr), true /*useSparse*/);
    }

```

可以看到每一个静态方法，最后都会通过构造函数的nativeLoad在native生成一个对应的地址指针，以及创建一个StringBlock。这里面究竟做了什么呢？让我们先来看看nativeLoad。


#### ApkAssets的nativeLoad 创建native对象
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_content_res_ApkAssets.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_content_res_ApkAssets.cpp)

```cpp
static jlong NativeLoad(JNIEnv* env, jclass /*clazz*/, jstring java_path, jboolean system,
                        jboolean force_shared_lib, jboolean overlay) {
  ScopedUtfChars path(env, java_path);
...

  std::unique_ptr<const ApkAssets> apk_assets;
  if (overlay) {
    apk_assets = ApkAssets::LoadOverlay(path.c_str(), system);
  } else if (force_shared_lib) {
    apk_assets = ApkAssets::LoadAsSharedLibrary(path.c_str(), system);
  } else {
    apk_assets = ApkAssets::Load(path.c_str(), system);
  }

  if (apk_assets == nullptr) {
...
    return 0;
  }
  return reinterpret_cast<jlong>(apk_assets.release());
}
```
能看到，在这个native方法中一样分成三种情况去读取资源数据，生成ApkAssets native对象返回给java层。
- LoadOverlay 加载重叠资源
- LoadAsSharedLibrary 加载第三方库资源
- Load 加载一般的资源

什么是重叠资源,引用罗生阳的解释？
> 假设我们正在编译的是Package-1，这时候我们可以设置另外一个Package-2，用来告诉aapt，如果Package-2定义有和Package-1一样的资源，那么就用定义在Package-2的资源来替换掉定义在Package-1的资源。通过这种Overlay机制，我们就可以对资源进行定制，而又不失一般性。

举一个例子，当我们下载某个主题并替换的时候，将会把整个Android相关的资源全部替换掉。此时会在overlay的文件夹中包含这个apk，这个apk只有资源，没有dex，并且把相关能替换的id写在某个文件。此时在初始化AssetManager会根据这个id替换掉所有的资源。和换肤框架相比，这是framework层面上的替换。

我们首先来看看加载一般资源的逻辑，Load。

##### ApkAssets::Load 读取磁盘的资源
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[ApkAssets.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/ApkAssets.cpp)

```cpp
static const std::string kResourcesArsc("resources.arsc");

std::unique_ptr<const ApkAssets> ApkAssets::Load(const std::string& path, bool system) {
  return LoadImpl({} /*fd*/, path, nullptr, nullptr, system, false /*load_as_shared_library*/);
}

std::unique_ptr<const ApkAssets> ApkAssets::LoadImpl(
    unique_fd fd, const std::string& path, std::unique_ptr<Asset> idmap_asset,
    std::unique_ptr<const LoadedIdmap> loaded_idmap, bool system, bool load_as_shared_library) {
  ::ZipArchiveHandle unmanaged_handle;
  int32_t result;
  if (fd >= 0) {
    result =
        ::OpenArchiveFd(fd.release(), path.c_str(), &unmanaged_handle, true /*assume_ownership*/);
  } else {
    result = ::OpenArchive(path.c_str(), &unmanaged_handle);
  }

...
  std::unique_ptr<ApkAssets> loaded_apk(new ApkAssets(unmanaged_handle, path));

  // Find the resource table.
  ::ZipString entry_name(kResourcesArsc.c_str());
  ::ZipEntry entry;
  result = ::FindEntry(loaded_apk->zip_handle_.get(), entry_name, &entry);
  if (result != 0) {
  ...
    loaded_apk->loaded_arsc_ = LoadedArsc::CreateEmpty();
    return std::move(loaded_apk);
  }

  if (entry.method == kCompressDeflated) {
    ...
  }


  loaded_apk->resources_asset_ = loaded_apk->Open(kResourcesArsc, Asset::AccessMode::ACCESS_BUFFER);
  if (loaded_apk->resources_asset_ == nullptr) {
...
    return {};
  }


  loaded_apk->idmap_asset_ = std::move(idmap_asset);

  const StringPiece data(
      reinterpret_cast<const char*>(loaded_apk->resources_asset_->getBuffer(true /*wordAligned*/)),
      loaded_apk->resources_asset_->getLength());
  loaded_apk->loaded_arsc_ =
      LoadedArsc::Load(data, loaded_idmap.get(), system, load_as_shared_library);
  if (loaded_apk->loaded_arsc_ == nullptr) {
   ...
    return {};
  }

  return std::move(loaded_apk);
}
```
在LoadImpl中可以看见，资源的压缩算法是zip算法，因此我们看到在这个核心方法中，大致上把资源读取分为如下4个步骤：
- 1.OpenArchive 打开zip文件，并且生成ApkAssets对象
 -2.通过FindEntry，寻找apk包中的resource.arsc文件
 - 3.读取apk包中的resource.arsc文件，读取里面包含的id相关的map，以及资源asset文件夹中。
- 4.生成StringPiece对象，接着通过LoadedArsc::Load读取其中的数据。

关于zip有一篇写的比较好的文章：[https://www.cnblogs.com/xumaojun/p/8544127.html](https://www.cnblogs.com/xumaojun/p/8544127.html)

zip算法本质上是一种无损压缩，通过短语式压缩，编码压缩(哈夫曼编码)进行压缩。同时我们看到Android中使用的是libziparchive,而这个内置的系统库不支持ZIP64，也就限制了包压缩的大小(必须小于32位字节就是4G)，这根本原因是系统限制了大小，而不是单单因为市场自己限制了apk大小。换句说，就算你强制生成一个过大apk包，android系统也会拒绝解析，核心检测在这里：
```cpp
if (file_length > static_cast<off64_t>(0xffffffff)) {
....
}
```
如果熟悉这一块流程的哥们就一定知道resource.arsc是作为ResTable(资源表)的核心文件，等下我们在LoadedArsc::Load看看究竟做了什么。

现在我们只需要关心ApkAssets生成之后，Open方法读取了什么东西，StringPiece又是指代什么。

#### ApkAssets.Open
```cpp
std::unique_ptr<Asset> ApkAssets::Open(const std::string& path, Asset::AccessMode mode) const {
  CHECK(zip_handle_ != nullptr);

  ::ZipString name(path.c_str());
  ::ZipEntry entry;
  int32_t result = ::FindEntry(zip_handle_.get(), name, &entry);
  if (result != 0) {
    return {};
  }

  if (entry.method == kCompressDeflated) {
    std::unique_ptr<FileMap> map = util::make_unique<FileMap>();
    if (!map->create(path_.c_str(), ::GetFileDescriptor(zip_handle_.get()), entry.offset,
                     entry.compressed_length, true /*readOnly*/)) {
...
      return {};
    }

    std::unique_ptr<Asset> asset =
        Asset::createFromCompressedMap(std::move(map), entry.uncompressed_length, mode);
    if (asset == nullptr) {
     ...
      return {};
    }
    return asset;
  } else {
    std::unique_ptr<FileMap> map = util::make_unique<FileMap>();
    if (!map->create(path_.c_str(), ::GetFileDescriptor(zip_handle_.get()), entry.offset,
                     entry.uncompressed_length, true /*readOnly*/)) {
     ....
      return {};
    }

    std::unique_ptr<Asset> asset = Asset::createFromUncompressedMap(std::move(map), mode);
    if (asset == nullptr) {
      ...
      return {};
    }
    return asset;
  }
}
```
open方法的意思是，判断当前传进来的Zip的Entry，判断当前的entry是否是经过压缩。
- 如果是经过压缩的模块，先通过FileMap把ZipEntry通过mmap映射到虚拟内存中(详细可以看看Binder的mmap映射原理一文)，接着通过Asset::createFromCompressedMap通过_CompressedAsset::openChunk拿到StreamingZipInflater，返回_CompressedAsset对象。

- 如果是没有压缩的模块，通过FileMap把ZipEntry通过mmap映射到虚拟内存中，最后Asset::createFromUncompressedMap，获取FileAsset对象.

在这里，resource.arsc并没有在apk中没有压缩，因此走的下面，直接返回对应的FileAsset。


由此，可以得知，ApkAsset将会管理由ZipEntry映射出来的FileMap的Asset对象。

### resource.arsc存储内容
这个方法就是解析整个Android资源表的方法，只要了解这个方法，就能明白，Android是怎么找到id资源的。可能光看源码很难有直观的了解其中的数据结构，先来看看apk包中resource.arsc究竟有什么东西。我们借助AS的解析器看看内部:
![resource.arsc存储内容.png](/images/resource.arsc存储内容.png)

从这个表中能看到左边是资源的类型，右边是资源id以及资源具体的路径(或者具体的资源内容)。通常的，我们把resource.arsc中保存的资源映射表称为ResTable(资源表)。当然如果是类似String，id后面对应将会是字符串内容：
![资源id.png](/images/资源id.png)


当我们使用apk内部资源的时候，一般会使用如R.id.xxx的方式引入，本质上R.id就是对应在这个的int类型。在打包的时候，会把对应的id打包到resource.arsc中，在运行阶段会解析这个文件，通过这个映射id，找到对应的路径，才能正确的找到我们需要资源。

之前在插件化基础框架一文中，曾经粗略的聊过每一个资源id的组成结构，这里就详细聊聊。
一旦提到resource.arsc文件中的数据结构，就一定会提到下面这幅图
![resource.arsc资源结构.png](/images/resource.arsc资源结构.png)

#### Android资源打包过程
在聊resource.arsc之前，我先聊聊Android中这个目录下的资源打包工具[/frameworks/base/tools/aapt/](http://androidxref.com/9.0.0_r3/xref/frameworks/base/tools/aapt/)

aapt是我们开发中中经常打交道，但是从来没有注意过的工具。这个工具主要为我们apk收集打包资源文件，并且生成resource.arsc文件。在这个过程中，打包所有的xml资源文件的时候，会从文本格式转化为二进制格式。
这么做原因有两个：
- 1.二进制的xml文件占用的空间更加小，所有的字符串都会被收集到字符串字典中(也叫字符串资源池)，对所有的字符串进行去重，重复的字符串都有个索引，本质上和zip的压缩很相似。
- 2.二进制的读取解析速度比文本速度快，因为字符串去重，需要读取的数据就小很多。

 在整个apk包中拥有这如下几种资源：
- 1.二进制xml文件
- 2.resource.arsc文件
- 3.没有经过压缩的asset文件以及so库

那么整个apk资源打包必然包含这几个过程。大致上可以分为如下三个大步骤：
- 1.收集资源
- 2.收集Xml资源，压平Xml文件，转化为二进制Xml
- 3.收集资源生成resource.arsc文件

整个打包大致上分为如下几个步骤：
##### 收集资源：
- 1.解析AndroidManifest.xml,根据package标签创建ResourcesTable
- 2.添加被引用资源包。如系统的layout_width，如应用自己定义的资源，这些引用的资源包都会被添加进来。
- 3.收集资源文件
- 4.将收集到的资源文件添加到资源表
- 5.编译value类资源，在这个时候会为每一个资源的type添加一个资源的entry，每一个entry会根据配置生成不同的config。就如上图String资源，每一项字符串都称为entry，而字符串根据不同的语言映射着不同的真正字符串，这些称为config(配置)
- 6.给Bag资源分配ID。类型为values的资源除了是string之外，还有其它很多类型的资源，其中有一些比较特殊，如bag、style、plurals和array类的资源。这些资源会给自己定义一些专用的值，这些带有专用值的资源就统称为Bag资源

##### 收集Xml资源
- 7.编译Xml资源文件： 解析Xml文件，生成XMLNode
- 8.编译Xml资源文件：赋予属性名称资源ID,每一个Xml文件都是从根节点开始给属性名称赋予资源ID，然后再给递归给每一个子节点的属性名称赋予资源ID，直到每一个节点的属性名称都获得了资源ID为止。如下
![view的标签.png](/images/view的标签.png)
- 9.编译Xml资源文件：解析属性值; 上一步是对Xml元素的属性的名称进行解析，这一步是对Xml元素的属性的值进行解析。通过上一步的资源id来查找bag中的对应的字符串，这就作为解析的结果。("@+id/XXX"+符号的意思是如果没有对应的资源id就创建一个)

##### 压平Xml资源
准备好Xml解析的资源就开始压平Xml文件，把文本的文件转化为二进制文件.

- 10.收集具有资源id属性名称和字符串; 这一步除了收集那些具有资源ID的Xml元素属性的名称字符串之外，还会将对应的资源ID收集起来放在一个数组中。这里收集到的属性名称字符串保存在一个字符串资源池中，它们与收集到的资源ID数组是一一对应的。
- 11.收集其它字符串,如控件名称，命名空间等等
- 12.写入Xml文件头。包含了代表头部的type(RES_XML_TYPE)，头部大小，整个xml文件大小.最终编译出来的Xml二进制文件是一系列的chunk组成的，每一个chunk都有一个头部，用来描述chunk的元信息。同时，整个Xml二进制文件又可以看成一块总的chunk，它有一个类型为ResXMLTree_header的头部。

- 13.写入字符串资源池，此时把10步骤和11步骤的字符串严格按照顺序写入字符串池子。此时写入头部大小以及type为RES_STRING_POOL_TYPE
- 14.写入资源ID,在第10步骤中收集到的ID，将会按照顺序作为一个单独的chunk写入到xml文件中，这个chunk位于字符串池子后面。
- 15.压平Xml文件，把所有的字符串替换成字符串池子中的索引

##### 生成resource.arsc资源表
从第一大步骤中，收集了大量的关于资源的数据，并且保存在资源表中(此时在内存)，此时需要真正的生成一个文件。
- 16.收集类型字符串 如layout，id等
- 17.收集资源项名称字符串 获取类型字符串中每一项名称
- 18.收集资源项值字符串 获取每一项资源中具体的值。
- 14.写入Package资源项元信息数据块头部，写入type RES_TABLE_PACKAGE_TYPE
- 15.写入类型字符串资源池，指代的是(layout，menu,strings等xml文件名称)
- 16.写入资源项名称字符串资源池，指代的是每个资源类型中的数据项名称(如layout中有一个main.xml的文件名)
- 17.写入类型规范数据块，type为RES_TABLE_TYPE_SPEC_TYPE;类型规范指代就是这些（文件夹layout,menu中各种数据）。
- 18. 写入类型资源项数据块，type为RES_TABLE_TYPE_TYPE，用来描述一个类型资源项头部。每一个资源项数据块都会指向一个资源entry，里面有着当前当前资源项在各种情况的真实数据,如mipmap，drawable在不同分辨率文件夹下具体文件路径。
- 19. 写入资源索引表头部，type为RES_TABLE_TYPE，此时size就是指resource.arsc大小
- 20.写入资源项的值字符串资源池
- 21.写入Package数据块

到这里就完成了resource.arsc文件的生成。

最后还需要几个额外的步骤，完善apk还没有打包的资源。
- 1.AndroidMainfest.xml转化二进制文件
- 2.生成R.java文件
- 3.把assets目录，resources.arsc，二进制Xml文件打包到apk。

至此，这就是Android打包的大致流程。

### resource.arsc文件数据结构剖析
根据上图以及上一节的打包流程，来分析resource.arsc文件。

在整个表的顶部保存着RES_TABLE_TYPE的标示位来标示着整个资源映射表是从哪里开始解析。后面接着这个头部的大小，整个文件的大小，保存着多少package的资源。

在整个资源映射表中，第一个chunk是字符串池子。type是RES_STRING_POOL_TYPE。在整个生成文件过程所有的资源值字符串都会经过收集，放到这个池子中，变成索引。

最后这一大块，就是生成resource.arsc文件最后写入的Package数据块。
packge数据大致分为如下几大块:
- 1.Package的头部，type为RES_TABLE_PACKAGE_TYPE。
- 2.Package的类型规范名称字符串，资源类型值名称字符串资源池
- 3.Package的RES_TABLE_TYPE_SPEC_TYPE类型规范的头部
- 4.Package RES_TABLE_TYPE_TYPE 类型资源项的头部，里面有指向entry的指针。

大致上了解整个resource.arsc文件后，看看LoadedArsc::Load是如何解析的。


#### LoadedArsc::Load
```cpp
std::unique_ptr<const LoadedArsc> LoadedArsc::Load(const StringPiece& data,
                                                   const LoadedIdmap* loaded_idmap, bool system,
                                                   bool load_as_shared_library) {

  std::unique_ptr<LoadedArsc> loaded_arsc(new LoadedArsc());
  loaded_arsc->system_ = system;

  ChunkIterator iter(data.data(), data.size());
  while (iter.HasNext()) {
    const Chunk chunk = iter.Next();
    switch (chunk.type()) {
      case RES_TABLE_TYPE:
        if (!loaded_arsc->LoadTable(chunk, loaded_idmap, load_as_shared_library)) {
          return {};
        }
        break;

      default:
        ...
        break;
    }
  }
...
}
```
进来第一件事情就是把所有zip的chunk解析出来后，迭代寻找resource.arsc文件的标志头RES_TABLE_TYPE。找到之后，开始读取这个数据，寻找的是上面结构的如下结构:
![RES_TABLE_TYPE.png](/images/RES_TABLE_TYPE.png)


#### LoadedArsc::LoadTable
```cpp
bool LoadedArsc::LoadTable(const Chunk& chunk, const LoadedIdmap* loaded_idmap,
                           bool load_as_shared_library) {
  const ResTable_header* header = chunk.header<ResTable_header>();
...
  const size_t package_count = dtohl(header->packageCount);
  size_t packages_seen = 0;

  packages_.reserve(package_count);

  ChunkIterator iter(chunk.data_ptr(), chunk.data_size());
  while (iter.HasNext()) {
    const Chunk child_chunk = iter.Next();
    switch (child_chunk.type()) {
      case RES_STRING_POOL_TYPE:
        if (global_string_pool_.getError() == NO_INIT) {
          status_t err = global_string_pool_.setTo(child_chunk.header<ResStringPool_header>(),
                                                   child_chunk.size());

        } else {
...
        }
        break;

      case RES_TABLE_PACKAGE_TYPE: {
        if (packages_seen + 1 > package_count) {
....
          return false;
        }
        packages_seen++;

        std::unique_ptr<const LoadedPackage> loaded_package =
            LoadedPackage::Load(child_chunk, loaded_idmap, system_, load_as_shared_library);
        if (!loaded_package) {
          return false;
        }
        packages_.push_back(std::move(loaded_package));
      } break;

      default:
...
        break;
    }
  }
...
}
```
在LoadPackage方法中，分别加载两个大区域的数据：
- 1.RES_STRING_POOL_TYPE 象征着资源中所有字符串,style的资源池(不包括资源类型名称，以及资源数据项名称)。解析的是如下部分：
![RES_STRING_POOL_TYPE.png](/images/RES_STRING_POOL_TYPE.png)
比如：string.xml,某个R.string.xxx 中的值，比如drawable文件夹中，某个文件的具体路径

- 2.RES_TABLE_PACKAGE_TYPE  象征着整个Package数据块，解析的是如下这部分:
![RES_TABLE_PACKAGE_TYPE.png](/images/RES_TABLE_PACKAGE_TYPE.png)


#### ResStringPool的解析过程
我们先来看看加载到内存中的Xml字符串资源池的结构体:
```cpp
struct ResStringPool_header
{
    struct ResChunk_header header;

    // Number of strings in this pool (number of uint32_t indices that follow
    // in the data).
    uint32_t stringCount;

    // Number of style span arrays in the pool (number of uint32_t indices
    // follow the string indices).
    uint32_t styleCount;

    // Flags.
    enum {
        // If set, the string index is sorted by the string values (based
        // on strcmp16()).
        SORTED_FLAG = 1<<0,

        // String pool is encoded in UTF-8
        UTF8_FLAG = 1<<8
    };
    uint32_t flags;

    // Index from header of the string data.
    uint32_t stringsStart;

    // Index from header of the style data.
    uint32_t stylesStart;
};
```
这个数据结构实际上是字符串资源池的这一部分:
![ResStringPool_header.png](/images/ResStringPool_header.png)

我们可以从该头部解析到整个资源池的大小，字符串个数，style个数，标记，以及字符串池子起始位置偏移量和style池子的起始位置偏移量。

计算原理实际上就很简单：
 > 字符串池子的起点位置 = header地址+stringsStart
> style 资源池的起点位置 = header地址+stylesStart

值得注意的是字符串/style的个数并是指写入字符串/style的条数。为在setTo方法中会通过偏移量去计算整个资源StringPool/StylePool占用多少char。

我们还有一处值得注意的是，在整个字符串资源池中，还有两个比较重要的Entrys还没聊,这两个entry(偏移数组)的位置在图中如下，在header的后方:
![偏移数组.png](/images/偏移数组.png)

这两个偏移数组做的事情比较重要，当我们尝试着通过index去查找String的内容，就要访问这个偏移数组，来找到对应字符串的在整个池子中的位置。计算方法如下：
> 字符串偏移数组起点 = header + header.size
> style偏移数组起点位置 = 字符串偏移数组起点 + 字符串大小


因为资源的写入是严格按照顺序写入的，那么通过index互相查找资源成为了可能,我们来看看string8At查找字符串的方法看看：
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[ResourceTypes.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/ResourceTypes.cpp)
```cpp
const char* ResStringPool::string8At(size_t idx, size_t* outLen) const
{
    if (mError == NO_ERROR && idx < mHeader->stringCount) {
        if ((mHeader->flags&ResStringPool_header::UTF8_FLAG) == 0) {
            return NULL;
        }
        const uint32_t off = mEntries[idx]/sizeof(char);
        if (off < (mStringPoolSize-1)) {
            const uint8_t* strings = (uint8_t*)mStrings;
            const uint8_t* str = strings+off;

            decodeLength(&str);

            const size_t encLen = decodeLength(&str);
            *outLen = encLen;

            if ((uint32_t)(str+encLen-strings) < mStringPoolSize) {
                return stringDecodeAt(idx, str, encLen, outLen);

            } else {
                ...
            }
        } else {
            ...
        }
    }
    return NULL;
}
```
在Android底层有一层缓存mCache，里面存放着已经解析过的长度为uint_16较长的资源字符串。

解析String的算法如下：
> 首先通过index，找到对应Entry中的数组中对应的元素off. uint32_t off = Entries[index]

> 当偏移元素 off 最高两位没有设置，说明这就是当前字符串的距离资源池起点的偏移量，如果设置了最高两位，则清除掉当前的最高位置，把当前的len和下个字符的加到一起。这样就灵活合并了字符串。

> 对应字符串string 起点地址(单位uint8_t) = mString(字符串资源池起点地址) + off

最后调用下面这个方法解析资源池中的字符串：
```cpp
const char* ResStringPool::stringDecodeAt(size_t idx, const uint8_t* str,
                                          const size_t encLen, size_t* outLen) const {
    const uint8_t* strings = (uint8_t*)mStrings;

    size_t i = 0, end = encLen;
    while ((uint32_t)(str+end-strings) < mStringPoolSize) {
        if (str[end] == 0x00) {
            if (i != 0) {
                ...
            }

            *outLen = end;
            return (const char*)str;
        }

        end = (++i << (sizeof(uint8_t) * 8 * 2 - 1)) | encLen;
    }

    // Reject malformed (non null-terminated) strings
 ...
    return NULL;
}
```
能看到这里面这里面的算法如下：
> 在String资源池的大小限制下，unit_8长度下，不断的写入字符串，并且整个数据不断向左移动15位，遇到了0x00就停止解析，并且把结果设置到outLen中。一般的outLen是指向encLen的指针，encLen是内容，而encLen是通过解析str的内容来的，因此这个方法本质上就是写入到str中。

确实很绕，不过没有这么难懂。

最后再把这个资源池，设置到全局资源global_string_pool_中，方便后面的查找。

#### Package数据块解析，LoadedPackage::Load
```cpp
std::unique_ptr<const LoadedPackage> LoadedPackage::Load(const Chunk& chunk,
                                                         const LoadedIdmap* loaded_idmap,
                                                         bool system, bool load_as_shared_library) {
  ATRACE_NAME("LoadedPackage::Load");
  std::unique_ptr<LoadedPackage> loaded_package(new LoadedPackage());

  // typeIdOffset was added at some point, but we still must recognize apps built before this
  // was added.
  constexpr size_t kMinPackageSize =
      sizeof(ResTable_package) - sizeof(ResTable_package::typeIdOffset);
  const ResTable_package* header = chunk.header<ResTable_package, kMinPackageSize>();
  if (header == nullptr) {
   ...
    return {};
  }

  loaded_package->system_ = system;

  loaded_package->package_id_ = dtohl(header->id);
  if (loaded_package->package_id_ == 0 ||
      (loaded_package->package_id_ == kAppPackageId && load_as_shared_library)) {
    // Package ID of 0 means this is a shared library.
    loaded_package->dynamic_ = true;
  }

  if (loaded_idmap != nullptr) {
    ...
    loaded_package->package_id_ = loaded_idmap->TargetPackageId();
    loaded_package->overlay_ = true;
  }

  if (header->header.headerSize >= sizeof(ResTable_package)) {
    uint32_t type_id_offset = dtohl(header->typeIdOffset);
    if (type_id_offset > std::numeric_limits<uint8_t>::max()) {
     ...
      return {};
    }
    loaded_package->type_id_offset_ = static_cast<int>(type_id_offset);
  }

  util::ReadUtf16StringFromDevice(header->name, arraysize(header->name),
                                  &loaded_package->package_name_);

 
  std::unordered_map<int, std::unique_ptr<TypeSpecPtrBuilder>> type_builder_map;

  ChunkIterator iter(chunk.data_ptr(), chunk.data_size());
  while (iter.HasNext()) {
    const Chunk child_chunk = iter.Next();
    switch (child_chunk.type()) {
      case RES_STRING_POOL_TYPE: {
        break;

      case RES_TABLE_TYPE_SPEC_TYPE: {
       ...
break;

      case RES_TABLE_TYPE_TYPE: 
        ...
break;

      case RES_TABLE_LIBRARY_TYPE: 
...
        
     break;

      default:
 ...
        break;
    }
  }

 ...

  // Flatten and construct the TypeSpecs.
  for (auto& entry : type_builder_map) {
    uint8_t type_idx = static_cast<uint8_t>(entry.first);
    TypeSpecPtr type_spec_ptr = entry.second->Build();
...
    // We only add the type to the package if there is no IDMAP, or if the type is
    // overlaying something.
    if (loaded_idmap == nullptr || type_spec_ptr->idmap_entries != nullptr) {
      // If this is an overlay, insert it at the target type ID.
      if (type_spec_ptr->idmap_entries != nullptr) {
        type_idx = dtohs(type_spec_ptr->idmap_entries->target_type_id) - 1;
      }
      loaded_package->type_specs_.editItemAt(type_idx) = std::move(type_spec_ptr);
    }
  }

  return std::move(loaded_package);
}
```

根据type，我们就能区分如下几种类型：
- 1.RES_TABLE_PACKAGE_TYPE   解析头部，解析如下部分的数据:
![RES_TABLE_PACKAGE_TYPE头部.png](/images/RES_TABLE_PACKAGE_TYPE头部.png)
- 2.RES_STRING_POOL_TYPE 从资源类型字符串池子和资源项名称字符串池子解析所有资源类型名称，资源数据项名称中的字符串
![资源类型字符串.png](/images/资源类型字符串.png)
- 3.RES_TABLE_TYPE_SPEC_TYPE 解析所有的资源类型规范
![资源类型规范.png](/images/资源类型.png)
- 4.RES_TABLE_TYPE_TYPE 解析所有的资源类型
![所有的资源类型.png](/images/所有的资源类型.png)
- 5.RES_TABLE_LIBRARY_TYPE 解析所有的第三方库资源，这里的图片没有显示。

## 小结
限于文章的长度，本文剖析到这里，下一篇将会剖析资源类型规范，资源数据项，AssetManager的核心原理。在这里面，本文讲述了如下内容:
Resource 是由ResourcesImpl控制的。ApkAssets是每个资源文件夹在内存中的对象。AssetManager伴随着ResourcesImpl初始化而存在，其目的是为了更好的管理每一个ApkAssets。
在整个Android 资源体系的Java层中有四重缓存:
- 1.activityResources 一个面向Resources弱引用的ArrayList
- 2.以ResourcesKey为key，ResourcesImpl的弱引用为value的Map缓存。
- 3.ApkAssets在内存中也有一层缓存，缓存拆成两部分，mLoadedApkAssets已经加载的活跃ApkAssets，mCacheApkAssets已经加载了但是不活跃的ApkAssets
- 4.native加载磁盘资源(加载磁盘资源过程中还有一些缓存)

对于Android系统来说，resources.arsc文件尤为重要，它充当了Android系统解析资源的向导，没有了它，Android中的应用无法正常解析数据。

该文件大致分为如下几个部分，注意一下虽然存在多个字符串资源池但是存放的数据不一样:
- 1.resources.arsc头部信息，type为RES_TABLE_TYPE
- 2.解析资源中所有的字符串，style字符串，type为RES_STRING_POOL_TYPE
- 3.剩下全部为Package数据块，type为RES_TABLE_PACKAGE_TYPE
- 4. RES_TABLE_PACKAGE_TYPE 代表这Package数据块的头部
- 5.在Package数据块中同样存在着资源池，不过这个资源池存放的是资源类型规范字符串以及资源数据字符串。type为RES_STRING_POOL_TYPE
- 6. RES_TABLE_TYPE_SPEC_TYPE 代表这所有资源类型规范数据块(chunk)
- 7.RES_TABLE_TYPE_TYPE 代表着所有资源数据数据块
 - 8.RES_TABLE_LIBRARY_TYPE代表所有的第三方资源库。

三个不同的字符串资源池，就以layout文件夹为例子：
![三个不同的字符串资源池.png](/images/三个不同的字符串资源池.png)

- 下标1最左侧指代的是资源类型名称，也就是位于package数据块中，typeString偏移数组以及类型字符串资源池的数据，RES_TABLE_TYPE_SPEC_TYPE 也是从这里找到正确的名称
- 下标2 指代的是的是资源数据项名称，也就是位于package数据块中，String偏移数组以及资源数据项字符串资源池，RES_TABLE_TYPE_TYPE 也是从这里找到正确的名称。
- 下标3,指代的是资源字符串，位于package数据块之外，最大的字符串资源池。

通过这几个资源池，加上资源数据项中指向的config数据项中的数据，就能正确的从resource.arsc文件中复原资源出来。

Android为了加速资源的加载速度，并不是直接通过File读写操作读取资源信息。而是通过FileMap的方式，也就是mmap把文件地址映射到虚拟内存中，时刻准备读写。这么做的好处，就是mmap回返回文件的地址，可以对文件进行操作，节省系统调用的开销，坏处就是mmap会映射到虚拟内存中，是的虚拟内存增大。更加详细的讨论，在Binder的mmap映射原理一文中。


















