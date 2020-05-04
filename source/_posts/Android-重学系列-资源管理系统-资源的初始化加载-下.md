---
title: Android 重学系列 资源管理系统 资源的初始化加载(下)
top: false
cover: false
date: 2019-11-03 23:23:06
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
上一篇文章，聊到了资源管理中解析Package数据模块中的LoadedPackage::Load方法开始解析Package数据块。本文将会详细解析Package数据块的解析，以及AssetManager如何管理。接下来解析resource.arsc还是依照下面这幅图进行解析：
![resource.arsc结构.png](/images/resource.arsc结构.png)

如果遇到问题欢迎在这个地址下留言：[https://www.jianshu.com/p/02a2539890dc](https://www.jianshu.com/p/02a2539890dc)


# 正文
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[LoadedArsc.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/LoadedArsc.cpp)

LoadedPackage::Load有点长，我拆开两部分聊。
### 解析Package数据包前的准备
```cpp
const static int kAppPackageId = 0x7f;

std::unique_ptr<const LoadedPackage> LoadedPackage::Load(const Chunk& chunk,
                                                         const LoadedIdmap* loaded_idmap,
                                                         bool system, bool load_as_shared_library) {

  std::unique_ptr<LoadedPackage> loaded_package(new LoadedPackage());

//计算结构体的大小
  constexpr size_t kMinPackageSize =
      sizeof(ResTable_package) - sizeof(ResTable_package::typeIdOffset);
  const ResTable_package* header = chunk.header<ResTable_package, kMinPackageSize>();


  loaded_package->system_ = system;

  loaded_package->package_id_ = dtohl(header->id);
  if (loaded_package->package_id_ == 0 ||
      (loaded_package->package_id_ == kAppPackageId && load_as_shared_library)) {
    // Package ID of 0 means this is a shared library.
    loaded_package->dynamic_ = true;
  }

  if (loaded_idmap != nullptr) {
    // This is an overlay and so it needs to pretend to be the target package.
    loaded_package->package_id_ = loaded_idmap->TargetPackageId();
    loaded_package->overlay_ = true;
  }

  if (header->header.headerSize >= sizeof(ResTable_package)) {
    uint32_t type_id_offset = dtohl(header->typeIdOffset);
 ...
    loaded_package->type_id_offset_ = static_cast<int>(type_id_offset);
  }

  util::ReadUtf16StringFromDevice(header->name, arraysize(header->name),
                                  &loaded_package->package_name_);

  ...
}
```
这一段是为解析package数据块的准备，首先解析Package数据块头部信息。实际上解析是下面这部分模块：
![RES_TABLE_PACKAGE_TYPE头部.png](/images/RES_TABLE_PACKAGE_TYPE头部.png)

首先取出当前的header的id并且获取交换低高位作为packageId(0x7f000000交换高低位变成0x7f)，如果当前的id是0x7f且打开了作为load_as_shared_library的标识位，或者id是0x00则作为动态资源加载，如果是第三方资源库则id为0.

如果上面传下来了loaded_idmap说明这部分的资源需要重新被覆盖。最后设置loaded_idmap。

此时可以得知，一般的App应用中的apk包中packageID是0x7f

### 解析Package数据
```cpp
  std::unordered_map<int, std::unique_ptr<TypeSpecPtrBuilder>> type_builder_map;

  ChunkIterator iter(chunk.data_ptr(), chunk.data_size());
  while (iter.HasNext()) {
    const Chunk child_chunk = iter.Next();
    switch (child_chunk.type()) {
      case RES_STRING_POOL_TYPE: {
        const uintptr_t pool_address =
            reinterpret_cast<uintptr_t>(child_chunk.header<ResChunk_header>());
        const uintptr_t header_address = reinterpret_cast<uintptr_t>(header);
        if (pool_address == header_address + dtohl(header->typeStrings)) {
          // This string pool is the type string pool.
          status_t err = loaded_package->type_string_pool_.setTo(
              child_chunk.header<ResStringPool_header>(), child_chunk.size());
         ...
        } else if (pool_address == header_address + dtohl(header->keyStrings)) {
          // This string pool is the key string pool.
          status_t err = loaded_package->key_string_pool_.setTo(
              child_chunk.header<ResStringPool_header>(), child_chunk.size());
      ...
        } else {
         ...
        }
      } break;

      case RES_TABLE_TYPE_SPEC_TYPE: {
        const ResTable_typeSpec* type_spec = child_chunk.header<ResTable_typeSpec>();
      ...
        // The data portion of this chunk contains entry_count 32bit entries,
        // each one representing a set of flags.
        // Here we only validate that the chunk is well formed.
        const size_t entry_count = dtohl(type_spec->entryCount);

        // There can only be 2^16 entries in a type, because that is the ID
        // space for entries (EEEE) in the resource ID 0xPPTTEEEE.
....

        // If this is an overlay, associate the mapping of this type to the target type
        // from the IDMAP.
        const IdmapEntry_header* idmap_entry_header = nullptr;
        if (loaded_idmap != nullptr) {
          idmap_entry_header = loaded_idmap->GetEntryMapForType(type_spec->id);
        }

        std::unique_ptr<TypeSpecPtrBuilder>& builder_ptr = type_builder_map[type_spec->id - 1];
        if (builder_ptr == nullptr) {
          builder_ptr = util::make_unique<TypeSpecPtrBuilder>(type_spec, idmap_entry_header);
        } else {
...
        }
      } break;

      case RES_TABLE_TYPE_TYPE: {
        const ResTable_type* type = child_chunk.header<ResTable_type, kResTableTypeMinSize>();
...

        // Type chunks must be preceded by their TypeSpec chunks.
        std::unique_ptr<TypeSpecPtrBuilder>& builder_ptr = type_builder_map[type->id - 1];
        if (builder_ptr != nullptr) {
          builder_ptr->AddType(type);
        } else {
         ...
        }
      } break;

      case RES_TABLE_LIBRARY_TYPE: {
        const ResTable_lib_header* lib = child_chunk.header<ResTable_lib_header>();
   ...

        loaded_package->dynamic_package_map_.reserve(dtohl(lib->count));

        const ResTable_lib_entry* const entry_begin =
            reinterpret_cast<const ResTable_lib_entry*>(child_chunk.data_ptr());
        const ResTable_lib_entry* const entry_end = entry_begin + dtohl(lib->count);
        for (auto entry_iter = entry_begin; entry_iter != entry_end; ++entry_iter) {
          std::string package_name;
          util::ReadUtf16StringFromDevice(entry_iter->packageName,
                                          arraysize(entry_iter->packageName), &package_name);

         ...

          loaded_package->dynamic_package_map_.emplace_back(std::move(package_name),
                                                            dtohl(entry_iter->packageId));
        }

      } break;

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
```
上一篇文章稍微总结这部分源码聊了什么，这本将拆开这几个case看看里面究竟做了什么事情。

#### 解析Package数据包中的字符串池子
```cpp
      case RES_STRING_POOL_TYPE: {
        const uintptr_t pool_address =
            reinterpret_cast<uintptr_t>(child_chunk.header<ResChunk_header>());
        const uintptr_t header_address = reinterpret_cast<uintptr_t>(header);
        if (pool_address == header_address + dtohl(header->typeStrings)) {
          // This string pool is the type string pool.
          status_t err = loaded_package->type_string_pool_.setTo(
              child_chunk.header<ResStringPool_header>(), child_chunk.size());
         ...
        } else if (pool_address == header_address + dtohl(header->keyStrings)) {
          // This string pool is the key string pool.
          status_t err = loaded_package->key_string_pool_.setTo(
              child_chunk.header<ResStringPool_header>(), child_chunk.size());
      ...
        } else {
         ...
        }
      } break;
```
在这个case中，实际上做的事情很简单，解析的是下面这部分
![资源类型字符串.png](/images/资源类型字符串.png)

和这张图不一样的是，在这个字符串资源池其实还有一个header，这里面疏漏了。这里面算法很简单，如下：
> 资源类型字符串池地址 = ResTable_package.header + typeString (偏移量)

> 资源项名称字符串池地址 = ResTable_package.header + keyStrings(偏移量)

最后通过这个地址和当前chunk的子chunk比较地址，看看和哪个相等，相等则赋值到对应的资源池。

至此，已经有三个全局资源池，global_string_pool_全局内容资源池，loaded_package->type_string_pool_ 资源类型字符串资源池，loaded_package->key_string_pool_资源项名称字符串资源池。


#### 解析资源类型数据
```cpp
      case RES_TABLE_TYPE_SPEC_TYPE: {
        const ResTable_typeSpec* type_spec = child_chunk.header<ResTable_typeSpec>();
      ...
        // The data portion of this chunk contains entry_count 32bit entries,
        // each one representing a set of flags.
        // Here we only validate that the chunk is well formed.
        const size_t entry_count = dtohl(type_spec->entryCount);

        // There can only be 2^16 entries in a type, because that is the ID
        // space for entries (EEEE) in the resource ID 0xPPTTEEEE.
....

        // If this is an overlay, associate the mapping of this type to the target type
        // from the IDMAP.
        const IdmapEntry_header* idmap_entry_header = nullptr;
        if (loaded_idmap != nullptr) {
          idmap_entry_header = loaded_idmap->GetEntryMapForType(type_spec->id);
        }

        std::unique_ptr<TypeSpecPtrBuilder>& builder_ptr = type_builder_map[type_spec->id - 1];
        if (builder_ptr == nullptr) {
          builder_ptr = util::make_unique<TypeSpecPtrBuilder>(type_spec, idmap_entry_header);
        } else {
...
        }
      } break;
```
此时解析的是下面这个数据块:
![资源类型规范.png](/images/资源类型规范.png)


首先来看看资源类型的结构体:
```cpp
struct ResTable_typeSpec
{
    struct ResChunk_header header;

    // The type identifier this chunk is holding.  Type IDs start
    // at 1 (corresponding to the value of the type bits in a
    // resource identifier).  0 is invalid.
    uint8_t id;
    
    // Must be 0.
    uint8_t res0;
    // Must be 0.
    uint16_t res1;
    
    // Number of uint32_t entry configuration masks that follow.
    uint32_t entryCount;

    enum : uint32_t {
        // Additional flag indicating an entry is public.
        SPEC_PUBLIC = 0x40000000u,

        // Additional flag indicating an entry is overlayable at runtime.
        // Added in Android-P.
        SPEC_OVERLAYABLE = 0x80000000u,
    };
};
```
该结构体定义了每一个资源类型的id，以及可以配置的entryCount。id是逐一递增，而entryCount的意思就是指该资源类型中，每一个资源项能跟着几个配置。比如说，layout中可以跟着几个layout-v21,v22等等，里面都包含着对应的具体布局文件值资源值。

如果传下的loaded_idmap 不为空，则说明这个package需要覆盖掉某个package的资源类型，就尝试着通过id去找到IdmapEntry_header。做覆盖准备。

此时就做了如下事情:
> type_builder_map[typeSpec的id - 1] = 新建一个TypeSpecPtrBuilder（type_spec，IdmapEntry_header）

初步构建了每个资源类型和id之间的映射关系。


#### 解析资源项
```cpp
      case RES_TABLE_TYPE_TYPE: {
        const ResTable_type* type = child_chunk.header<ResTable_type, kResTableTypeMinSize>();
...

        // Type chunks must be preceded by their TypeSpec chunks.
        std::unique_ptr<TypeSpecPtrBuilder>& builder_ptr = type_builder_map[type->id - 1];
        if (builder_ptr != nullptr) {
          builder_ptr->AddType(type);
        } else {
         ...
        }
      } break;

```
此时解析的是下面这个数据块:
![所有的资源类型.png](/images/所有的资源类型.png)
在上一节中解析每一个资源类型的时候构建了TypeSpecPtrBuilder对象。当没遇到一个新的资源项时候，将会取出这个TypeSpecPtrBuilder，并且通过AddType到这个对象中。这样就完成了id到资源类型到资源项的映射。
看看资源项的数据结构：
```cpp
struct ResTable_type
{
    struct ResChunk_header header;

    enum {
        NO_ENTRY = 0xFFFFFFFF
    };
    
    // The type identifier this chunk is holding.  Type IDs start
    // at 1 (corresponding to the value of the type bits in a
    // resource identifier).  0 is invalid.
    uint8_t id;
    
    enum {
        // If set, the entry is sparse, and encodes both the entry ID and offset into each entry,
        // and a binary search is used to find the key. Only available on platforms >= O.
        // Mark any types that use this with a v26 qualifier to prevent runtime issues on older
        // platforms.
        FLAG_SPARSE = 0x01,
    };
    uint8_t flags;

    // Must be 0.
    uint16_t reserved;
    
    // Number of uint32_t entry indices that follow.
    uint32_t entryCount;

    // Offset from header where ResTable_entry data starts.
    uint32_t entriesStart;

    // Configuration this collection of entries is designed for. This must always be last.
    ResTable_config config;
};
```
能看到每一个资源项里面包含了一个头部，一个配置(语言环境)，还有entry的偏移量，entry是指什么呢？
![解析restable_entry.png](/images/解析restable_entry.png)

这个entry就是我们编程读取到的数据。



最后让我们看看，TypeSpecPtrBuilder
```cpp
class TypeSpecPtrBuilder {
 public:
  explicit TypeSpecPtrBuilder(const ResTable_typeSpec* header,
                              const IdmapEntry_header* idmap_header)
      : header_(header), idmap_header_(idmap_header) {
  }

  void AddType(const ResTable_type* type) {
    types_.push_back(type);
  }

  TypeSpecPtr Build() {
    // Check for overflow.
    using ElementType = const ResTable_type*;
    if ((std::numeric_limits<size_t>::max() - sizeof(TypeSpec)) / sizeof(ElementType) <
        types_.size()) {
      return {};
    }
    TypeSpec* type_spec =
        (TypeSpec*)::malloc(sizeof(TypeSpec) + (types_.size() * sizeof(ElementType)));
    type_spec->type_spec = header_;
    type_spec->idmap_entries = idmap_header_;
    type_spec->type_count = types_.size();
    memcpy(type_spec + 1, types_.data(), types_.size() * sizeof(ElementType));
    return TypeSpecPtr(type_spec);
  }

 private:
  DISALLOW_COPY_AND_ASSIGN(TypeSpecPtrBuilder);

  const ResTable_typeSpec* header_;
  const IdmapEntry_header* idmap_header_;
  std::vector<const ResTable_type*> types_;
};
```
能看到这个数据类型很简单。里面保存了ResTable_typeSpec对应的header，需要覆盖的idmap_header_，以及添加进来数据项。

#### 解析第三方资源库资源(特指资源共享库，那些只有资源没有代码的库)
```cpp
      case RES_TABLE_LIBRARY_TYPE: {
        const ResTable_lib_header* lib = child_chunk.header<ResTable_lib_header>();
   ...

        loaded_package->dynamic_package_map_.reserve(dtohl(lib->count));

        const ResTable_lib_entry* const entry_begin =
            reinterpret_cast<const ResTable_lib_entry*>(child_chunk.data_ptr());
        const ResTable_lib_entry* const entry_end = entry_begin + dtohl(lib->count);
        for (auto entry_iter = entry_begin; entry_iter != entry_end; ++entry_iter) {
          std::string package_name;
          util::ReadUtf16StringFromDevice(entry_iter->packageName,
                                          arraysize(entry_iter->packageName), &package_name);

         ...

          loaded_package->dynamic_package_map_.emplace_back(std::move(package_name),
                                                            dtohl(entry_iter->packageId));
        }

      } break;
```
这里也很简单，实际上就是把每一个ResTable_lib_entry，添加到loaded_package的dynamic_package_map_中管理。而ResTable_lib_entry数据也很简单，只是记录了这个资源隶属于那个package的id以及name
```cpp
struct ResTable_lib_entry
{
    // The package-id this shared library was assigned at build time.
    // We use a uint32 to keep the structure aligned on a uint32 boundary.
    uint32_t packageId;

    // The package name of the shared library. \0 terminated.
    uint16_t packageName[128];
};
```

### 构建LoadPackage中的映射关系
```cpp
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
```
能看到，此时将会把type_builder_map中缓存的每一项数据都构建成TypeSpecPtr 对象，并且根据当前的id-1保存起来。

因此LoadPackage中就有了所有资源的映射关系。提一句，为什么第一个资源目录anim typeid为1了吧。这是为了让下层计算可以从下标为0开始。


#### 小结
在整个AssetManager初始化体系中，所有的字符串资源保存在三个字符串资源池中：
- 1.global_string_pool_全局内容资源池
- 2.loaded_package->type_string_pool_ 资源类型字符串资源池
- 3.loaded_package->key_string_pool_资源项名称字符串资源池。

接下来就会保存package数据块的数据。所有的package数据块都保存到loadedPackage对象中，该对象保存着所有的TypeSpec对象，这个对象就是一个资源类型，而这个TypeSpec对象中保存着大量的ResTable_type，这个对象只是用用当前具体资源entryID，还没有具体的数据。还保存着一个提供给第三方资源库的动态映射表

### 回到ApkAsset
思路离开的有点远了，回顾一下，上文中所有的事情都是在NativeLoad完成的事情，而上述过程仅仅只是填充ApkAssets对象中loaded_arsc_对象做的事情。

完成了这个事情之后就会回到该方法，把native对象地址回传给java层。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ApkAssets.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ApkAssets.java)
```java
    private ApkAssets(@NonNull String path, boolean system, boolean forceSharedLib, boolean overlay)
            throws IOException {
        Preconditions.checkNotNull(path, "path");
        mNativePtr = nativeLoad(path, system, forceSharedLib, overlay);
        mStringBlock = new StringBlock(nativeGetStringBlock(mNativePtr), true /*useSparse*/);
    }
```
接下来会通过nativeGetStringBlock再起一次回去native层，获取native的StringBlock对象。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_content_res_ApkAssets.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_content_res_ApkAssets.cpp)

```cpp
static jlong NativeGetStringBlock(JNIEnv* /*env*/, jclass /*clazz*/, jlong ptr) {
  const ApkAssets* apk_assets = reinterpret_cast<const ApkAssets*>(ptr);
  return reinterpret_cast<jlong>(apk_assets->GetLoadedArsc()->GetStringPool());
}
```

```cpp
inline const ResStringPool* GetStringPool() const {
    return &global_string_pool_;
 }
```
能看到此时StringBlock获取的是从resource.arsc的全局字符串资源池。内含着所有资源具体的值。

此时ApkAssets就持有两个native对象，一个是native层对应的ApkAssets以及字符串资源池。

## AssetManager的创建
上文就知道，AssetManager的创建实际上是不断的添加ApkAssets对象到builder对象中，最后调用build创建。
```java
public static class Builder {
        private ArrayList<ApkAssets> mUserApkAssets = new ArrayList<>();

        public Builder addApkAssets(ApkAssets apkAssets) {
            mUserApkAssets.add(apkAssets);
            return this;
        }

        public AssetManager build() {
            // Retrieving the system ApkAssets forces their creation as well.
            final ApkAssets[] systemApkAssets = getSystem().getApkAssets();

            final int totalApkAssetCount = systemApkAssets.length + mUserApkAssets.size();
            final ApkAssets[] apkAssets = new ApkAssets[totalApkAssetCount];

            System.arraycopy(systemApkAssets, 0, apkAssets, 0, systemApkAssets.length);

            final int userApkAssetCount = mUserApkAssets.size();
            for (int i = 0; i < userApkAssetCount; i++) {
                apkAssets[i + systemApkAssets.length] = mUserApkAssets.get(i);
            }

            // Calling this constructor prevents creation of system ApkAssets, which we took care
            // of in this Builder.
            final AssetManager assetManager = new AssetManager(false /*sentinel*/);
            assetManager.mApkAssets = apkAssets;
            AssetManager.nativeSetApkAssets(assetManager.mObject, apkAssets,
                    false /*invalidateCaches*/);
            return assetManager;
        }
    }
```
在build方法中，可以看到整个ApkAssets被划分为两类，一类是System的，一类是应用App的。这两类ApkAssets都会被AssetManager 持有，并且通过nativeSetApkAssets设置到native层。

#### 获取System资源包
```java
private static final String FRAMEWORK_APK_PATH = "/system/framework/framework-res.apk";
static AssetManager sSystem = null;

    public static AssetManager getSystem() {
        synchronized (sSync) {
            createSystemAssetsInZygoteLocked();
            return sSystem;
        }
    }

    private static void createSystemAssetsInZygoteLocked() {
        if (sSystem != null) {
            return;
        }

        // Make sure that all IDMAPs are up to date.
        nativeVerifySystemIdmaps();

        try {
            final ArrayList<ApkAssets> apkAssets = new ArrayList<>();
            apkAssets.add(ApkAssets.loadFromPath(FRAMEWORK_APK_PATH, true /*system*/));
            loadStaticRuntimeOverlays(apkAssets);

            sSystemApkAssetsSet = new ArraySet<>(apkAssets);
            sSystemApkAssets = apkAssets.toArray(new ApkAssets[apkAssets.size()]);
            sSystem = new AssetManager(true /*sentinel*/);
            sSystem.setApkAssets(sSystemApkAssets, false /*invalidateCaches*/);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to create system AssetManager", e);
        }
    }
```
能看到此时会先构建一个静态的AssetManager，这个AssetManager只管理一个资源包：/system/framework/framework-res.apk。而且还好根据/data/resource-cache/overlays.list的复写资源文件，把需要重叠的资源覆盖在系统apk上。

打开其中的resource.arsc文件，发现packageID和应用的0x7f不一样，是0x01
![系统资源id.png](/images/系统资源id.png)



#### AssetManager的构建
```java
    private AssetManager(boolean sentinel) {
        mObject = nativeCreate();
        ...
    }
```
在构造函数中只做了一件事情，通过nativeCreate创建native下的GuardedAssetManager对象。


```cpp
struct GuardedAssetManager : public ::AAssetManager {
  Guarded<AssetManager2> guarded_assetmanager;
};

static jlong NativeCreate(JNIEnv* /*env*/, jclass /*clazz*/) {
  // AssetManager2 needs to be protected by a lock. To avoid cache misses, we allocate the lock and
  // AssetManager2 in a contiguous block (GuardedAssetManager).
  return reinterpret_cast<jlong>(new GuardedAssetManager());
}
```
这本质上是一个包裹着AssetManager2的AAssetManager 对象。Guarded有点像智能指针，不过这是让对象自己持有有mutex，自己的操作保持原子性。



#### nativeSetApkAssets设置所有的ApkAssets给AssetManager2对象
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AssetManager2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AssetManager2.cpp)
```cpp
Guarded<AssetManager2>* AssetManagerForNdkAssetManager(::AAssetManager* assetmanager) {
  if (assetmanager == nullptr) {
    return nullptr;
  }
  return &reinterpret_cast<GuardedAssetManager*>(assetmanager)->guarded_assetmanager;
}

static Guarded<AssetManager2>& AssetManagerFromLong(jlong ptr) {
  return *AssetManagerForNdkAssetManager(reinterpret_cast<AAssetManager*>(ptr));
}


static void NativeSetApkAssets(JNIEnv* env, jclass /*clazz*/, jlong ptr,
                               jobjectArray apk_assets_array, jboolean invalidate_caches) {

  const jsize apk_assets_len = env->GetArrayLength(apk_assets_array);
  std::vector<const ApkAssets*> apk_assets;
  apk_assets.reserve(apk_assets_len);
  for (jsize i = 0; i < apk_assets_len; i++) {
    jobject obj = env->GetObjectArrayElement(apk_assets_array, i);
    if (obj == nullptr) {
      std::string msg = StringPrintf("ApkAssets at index %d is null", i);
      jniThrowNullPointerException(env, msg.c_str());
      return;
    }

    jlong apk_assets_native_ptr = env->GetLongField(obj, gApkAssetsFields.native_ptr);
    if (env->ExceptionCheck()) {
      return;
    }
    apk_assets.push_back(reinterpret_cast<const ApkAssets*>(apk_assets_native_ptr));
  }

  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  assetmanager->SetApkAssets(apk_assets, invalidate_caches);
}
```

实际上逻辑很简单，就是把Java的数组转化为vector设置到AssetManager2.


#### AssetManager2构建内存中的资源表
```cpp
bool AssetManager2::SetApkAssets(const std::vector<const ApkAssets*>& apk_assets,
                                 bool invalidate_caches) {
  apk_assets_ = apk_assets;
  BuildDynamicRefTable();
  RebuildFilterList();
  if (invalidate_caches) {
    InvalidateCaches(static_cast<uint32_t>(-1));
  }
  return true;
}
```
从方法中可以得知整个AssetManager2会在内存中构建一个动态的资源表：
- 1.BuildDynamicRefTable构建动态的资源引用表
- 2.RebuildFilterList 构建过滤后的配置列表
- 3.InvalidateCaches刷新缓存

##### 构建动态的资源引用表
```cpp
void AssetManager2::BuildDynamicRefTable() {
  package_groups_.clear();
  package_ids_.fill(0xff);

  // 0x01 is reserved for the android package.
  int next_package_id = 0x02;
  const size_t apk_assets_count = apk_assets_.size();
  for (size_t i = 0; i < apk_assets_count; i++) {
    const LoadedArsc* loaded_arsc = apk_assets_[i]->GetLoadedArsc();

    for (const std::unique_ptr<const LoadedPackage>& package : loaded_arsc->GetPackages()) {
      // Get the package ID or assign one if a shared library.
      int package_id;
      if (package->IsDynamic()) {
        package_id = next_package_id++;
      } else {
        package_id = package->GetPackageId();
      }

      // Add the mapping for package ID to index if not present.
      uint8_t idx = package_ids_[package_id];
      if (idx == 0xff) {
        package_ids_[package_id] = idx = static_cast<uint8_t>(package_groups_.size());
        package_groups_.push_back({});
        DynamicRefTable& ref_table = package_groups_.back().dynamic_ref_table;
        ref_table.mAssignedPackageId = package_id;
        ref_table.mAppAsLib = package->IsDynamic() && package->GetPackageId() == 0x7f;
      }
      PackageGroup* package_group = &package_groups_[idx];

      // Add the package and to the set of packages with the same ID.
      package_group->packages_.push_back(ConfiguredPackage{package.get(), {}});
      package_group->cookies_.push_back(static_cast<ApkAssetsCookie>(i));

      // Add the package name -> build time ID mappings.
      for (const DynamicPackageEntry& entry : package->GetDynamicPackageMap()) {
        String16 package_name(entry.package_name.c_str(), entry.package_name.size());
        package_group->dynamic_ref_table.mEntries.replaceValueFor(
            package_name, static_cast<uint8_t>(entry.package_id));
      }
    }
  }

  // Now assign the runtime IDs so that we have a build-time to runtime ID map.
  const auto package_groups_end = package_groups_.end();
  for (auto iter = package_groups_.begin(); iter != package_groups_end; ++iter) {
    const std::string& package_name = iter->packages_[0].loaded_package_->GetPackageName();
    for (auto iter2 = package_groups_.begin(); iter2 != package_groups_end; ++iter2) {
      iter2->dynamic_ref_table.addMapping(String16(package_name.c_str(), package_name.size()),
                                          iter->dynamic_ref_table.mAssignedPackageId);
    }
  }
}
```
为什么需要构建一个动态的资源映射表？在原本的LoadArsc对象中已经构建了几乎所有资源之间的关系。

但是有一个问题就出现，这个第三方资源的packageID编译到这个位置的时候，实际上是根据编译顺序按顺序加载并且递增设置packageID。从第一个双重循环看来，我们运行中还有一个packageID，是根据加载到内存的顺序。

这样就出现一个很大的问题？假如有一个第三方资源库是0x03的packageId，此时加载顺序是第1个，这样在内存中对应的packageID就是0x02(0x01永远给系统)，这样就会找错对象。


因此第二个循环就是为了解决这个问题。

- 1.双重循环做的事情实际上是收集所有保存在LoadArsc对象中的所有的package放到package_group中，并且为每一个index设置一个cookie，这个cookie本质上是一个int类型，随着package的增大而增加。紧接着，为每一个动态资源库加载自己的packageId。并且设置到DynamicPackageEntry的mEntries中。


- 2.获取package_group中所有的数据，循环所有的package_group，并且调用addMapping:
```cpp
status_t DynamicRefTable::addMapping(const String16& packageName, uint8_t packageId)
{
    ssize_t index = mEntries.indexOfKey(packageName);
    if (index < 0) {
        return UNKNOWN_ERROR;
    }
    mLookupTable[mEntries.valueAt(index)] = packageId;
    return NO_ERROR;
}
```
从上面能知道，mEntries保存的是编译时packageID，mLookupTable则保存的是运行时id。这样就能正确的通过运行时id找到编译时id。

#### RebuildFilterList 构建过滤后的entry列表
```cpp
void AssetManager2::RebuildFilterList() {
  for (PackageGroup& group : package_groups_) {
    for (ConfiguredPackage& impl : group.packages_) {
      // Destroy it.
      impl.filtered_configs_.~ByteBucketArray();

      // Re-create it.
      new (&impl.filtered_configs_) ByteBucketArray<FilteredConfigGroup>();

      // Create the filters here.
      impl.loaded_package_->ForEachTypeSpec([&](const TypeSpec* spec, uint8_t type_index) {
        FilteredConfigGroup& group = impl.filtered_configs_.editItemAt(type_index);
        const auto iter_end = spec->types + spec->type_count;
        for (auto iter = spec->types; iter != iter_end; ++iter) {
          ResTable_config this_config;
          this_config.copyFromDtoH((*iter)->config);
          if (this_config.match(configuration_)) {
            group.configurations.push_back(this_config);
            group.types.push_back(*iter);
          }
        }
      });
    }
  }
}
```
TypeSpec这个对象就是生成ApkAssets的时候保存着所有资源映射关系。
这个方法就是通过循环筛选当前的config(如语言环境，sim卡环境)一致的config，有选择性的获取ResTable_type（资源项）。

这样我们就能把所有的关系都映射到package_groups_对象中。

#### 清除缓存所有的资源id
```cpp
void AssetManager2::InvalidateCaches(uint32_t diff) {
  if (diff == 0xffffffffu) {
    // Everything must go.
    cached_bags_.clear();
    return;
  }

  for (auto iter = cached_bags_.cbegin(); iter != cached_bags_.cend();) {
    if (diff & iter->second->type_spec_flags) {
      iter = cached_bags_.erase(iter);
    } else {
      ++iter;
    }
  }
}
```
cached_bags_实际上缓存着过去生成过资源id，如果需要则会清除，一般这种情况如AssetManager配置发生变化都会清除一下避免干扰cached_bags_。

经过着三个步骤之后，native层AssetManager就变相的通过package_group持有apk中资源映射关系。



## 总结
限于篇幅的原因，下一篇文章将会和大家剖析Android是如何通过初始化好的资源体系，进行资源的查找。你将会看到，本文还没有使用过的ResTable_entry以及保存着真实数据的Res_Value是如何在资源查找中运作。

首先先上一副，囊括Java层和native层时序图：
![Android资源体系的初始化.png](/images/Android资源体系的初始化.png)

流程很长，也并不是很全，只是照顾到了主干。可以得知，在整个流程在频繁的和native层不断交流。仅仅依靠时序图，可能总结起来是不够好。

在这里我们可以得知如下信息：
AssetManager 在Java层会控制着ApkAsset。相对的AssetManager会对应着native层的AssetManager2，而AssetManager2控制着native层的ApkAsset对象。
![AssetManager设计.png](/images/AssetManager设计.png)


换句话说，ApkAsset就是资源文件夹单位，而AssetManager只会控制到这个粒度。同时ApkAsset中存在四个十分重要的数据结构：
- 1. resources_asset_  象征着一个本质上是resource.arsc zip资源FileMap的Asset
- 2. loaded_arsc_ 实际上是一个LoadedArsc，这个是resource.arsc解析资源后生成的映射关系对象。

LoadedArsc也有2个很重要的数据结构：
- 1. global_string_pool_ 全局字符串资源池
- 2. LoadedPackage package数据对象

LoadedPackage里面有着大量的资源对象相关信息，以及真实数据，其中也包含几个很重要的数据结构:
- 1. type_string_pool_ 资源类型字符串，如layout，menu，anim这些文件夹对应的名字
- 2. key_string_pool_ 资源项字符串，资源对应的名字
- 3. type_specs_ 里面保存着所有资源类型和资源项的映射关系
- 4. dynamic_package_map_ 是为了处理第三方资源库编译的packgeID和运行时ID冲突而构建的2次映射，但是解决冲突不是在这里解决

ApkAsset有了这些信息，才能够根据resource.arsc 完整的构建出资源之间的关系。
![ApkAssets的构成.png](/images/ApkAssets的构成.png)


当然，仅仅又这些还不足，当ApkAsset设置到AssetManager2中的时候，AssetManager2为了更加快速，准确的加载内存做了如下努力：
- 1.保存着多个PackageGroup对象(内含ConfiguredPackage)，里面包含着所有package数据块。
- 2.构建动态资源表，放在package_group中，为了解决packageID运行时和编译时冲突问题
- 3.提前筛选出符合当前环境的资源配置到FilteredConfigGroup，为了可以快速访问。
- 4.缓存已经访问过的BagID，也就是完整的资源ID。
![AssetManager2的构成.png](/images/AssetManager2的构成.png)


所以，才叫Asset的Manager。同时我们能够看到，在整个流程中，资源的解析流程将会以resource.arsc为引导，解析整个Apk资源。但是本质上还是zip解压缩获取对应的数据块，只有访问这些zipentry才能真正的访问数据。当然，相关的字符串会集中控制在三个字符串缓存池中，如果遇到想要相应获取，可以从这几个缓存池对应的index获取。

那么，我们继续接着上一次的缓存话题，看看Android系统为了读取的效率又作出什么努力，这里继续总结一下整个资源的缓存情况：
- 1.activityResources 一个面向Resources弱引用的ArrayList
- 2.以ResourcesKey为key，ResourcesImpl的弱引用为value的Map缓存。
- 3.ApkAssets在内存中也有一层缓存，缓存拆成两部分，mLoadedApkAssets已经加载的活跃ApkAssets，mCacheApkAssets已经加载了但是不活跃的ApkAssets
- 4.在ApkAsset保存着三个全局字符串资源池子，提供快速查找，对应到Java层的对象一般为StringBlock
- 5.为了能够快速查找符合当前环境配置的资源(屏幕密度，语言环境等)，同样在过滤构建资源阶段，有一个FilteredConfigGroup对象，提供快速查找。
- 6.缓存BagID
![Android资源体系的缓存.png](/images/Android资源体系的缓存.png)

分析资源管理系统，可以总结出什么Android性能优化结论呢？
> 1.包体积的优化，我们可以通过混淆资源文件，是的包体积变小。为什么呢？因为通过资源的混淆，就可以减少resource.arsc中字符串资源池的大小，从而缩小资源大小。

> 2.资源管理系统查找资源本质上是一个比较耗时的过程，因此Android系统做了6层缓存。保证资源的可以相对快速的查找。而这也是为什么在如果使用方法卡顿检测第一次应哟启动的时候，经常会报告资源解析方法卡顿的问题。解决的方案是打开一个线程池适当的解析提前解析资源。

> 3.同样阅读这段源码之后，我们同样能够理解为什么各个插件化，热修复只要涉及到资源的修复，就必须重新更新StringBlock。以前我没有解释，现在应该明白StringBlock里面保存着全局字符串资源池，如果修复之后不及时重新更新资源池，就是出现资源查找异常。当然Tinker里面所说的"系统资源提前加载需要清除，否则导致异常"话处理思路结果是正确的，但是出现错误的根本原因倒是出分析错了。

> 4.当然，我们从这个过程中，其实可以察觉到其实整个Android资源体系其实可以进一步优化的：1.asset等资源文件并没有压缩，我们拿出来的其实就是apk中asset文件夹对应的ZipEntry。其实我们可以自己进行一次压缩，拿到数据流之后进一步解压缩。不过只是一种用时间来替代空间的策略罢了。2.在整个过程中字符串资源池保存的是完整的资源，其实我们可以用哈夫曼编码进一步压缩字符串资源池中的数据，当然这样就需要入侵到编译流程中，现在的我还没有这种水平。



下一篇文章是资源管理系统最后一篇，探索一下Android的资源是如何查找的。






