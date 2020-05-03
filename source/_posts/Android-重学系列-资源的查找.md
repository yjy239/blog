---
title: Android 重学系列 资源的查找
top: false
cover: false
date: 2019-11-03 23:23:46
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
上一篇文章已经聊了资源系统的初始化，本文就来看看资源适合查找到的。

如果遇到问题，欢迎在下面这个地址下留言：[https://www.jianshu.com/p/b153d63d60b3](https://www.jianshu.com/p/b153d63d60b3)


# 正文
## 资源的查找,Xml布局文件的读取
到这里AssetManager就生成了，我们来看看资源是怎么查找的。我们来看看之前我没有深入探讨的解析Xml方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[Resources.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/Resources.java)

```java
    public XmlResourceParser getLayout(@LayoutRes int id) throws NotFoundException {
        return loadXmlResourceParser(id, "layout");
    }

    XmlResourceParser loadXmlResourceParser(@AnyRes int id, @NonNull String type)
            throws NotFoundException {
        final TypedValue value = obtainTempTypedValue();
        try {
            final ResourcesImpl impl = mResourcesImpl;
            impl.getValue(id, value, true);
            if (value.type == TypedValue.TYPE_STRING) {
                return impl.loadXmlResourceParser(value.string.toString(), id,
                        value.assetCookie, type);
            }
           ...
        } finally {
            releaseTempTypedValue(value);
        }
    }

```
这里大致分为两个步骤：
- 1.通过ResourcesImpl.getValue获取当前resId对应的资源，设置到TypedValue
- 2.如果当前返回的数据类型是String，则直接调用loadXmlResourceParser 读取资源具体的内容中，如Xml布局文件。
- 3.缓存当前资源

#### 查找resId对应的资源
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ResourcesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ResourcesImpl.java)
```java
    void getValue(@AnyRes int id, TypedValue outValue, boolean resolveRefs)
            throws NotFoundException {
        boolean found = mAssets.getResourceValue(id, 0, outValue, resolveRefs);
        if (found) {
            return;
        }
        ...
    }
```
能看到这里面调用了AssetManager的getResourceValue方法。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[AssetManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/AssetManager.java)

```java
    boolean getResourceValue(@AnyRes int resId, int densityDpi, @NonNull TypedValue outValue,
            boolean resolveRefs) {
        synchronized (this) {
            ensureValidLocked();
            final int cookie = nativeGetResourceValue(
                    mObject, resId, (short) densityDpi, outValue, resolveRefs);

            outValue.changingConfigurations = ActivityInfo.activityInfoConfigNativeToJava(
                    outValue.changingConfigurations);

            if (outValue.type == TypedValue.TYPE_STRING) {
                outValue.string = mApkAssets[cookie - 1].getStringFromPool(outValue.data);
            }
            return true;
        }
    }
```

在这里面会调用nativeGetResourceValue获取到Asset的cookie，从底层复制数据到TypedValue中。如果判断到TypedValue中解析出来的数据是String类型，则从全局字符串字符串中获取对应TypeValue中data对应的字符串数据。

那么我们可以推测，如果当前的资源类型是一个字符串(说明找到)，那么nativeGetResourceValue方法实际上并不会赋值给outValue.string。因为可以通过字符串资源池更加快速查找字符串的方法。

### 获取native层资源id对应的资源
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_util_AssetManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_util_AssetManager.cpp)
```cpp
using ApkAssetsCookie = int32_t;

enum : ApkAssetsCookie {
  kInvalidCookie = -1,
};
```
```cpp
static jint NativeGetResourceValue(JNIEnv* env, jclass /*clazz*/, jlong ptr, jint resid,
                                   jshort density, jobject typed_value,
                                   jboolean resolve_references) {
  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  Res_value value;
  ResTable_config selected_config;
  uint32_t flags;
  ApkAssetsCookie cookie =
      assetmanager->GetResource(static_cast<uint32_t>(resid), false /*may_be_bag*/,
                                static_cast<uint16_t>(density), &value, &selected_config, &flags);
  if (cookie == kInvalidCookie) {
    return ApkAssetsCookieToJavaCookie(kInvalidCookie);
  }

  uint32_t ref = static_cast<uint32_t>(resid);
  if (resolve_references) {
    cookie = assetmanager->ResolveReference(cookie, &value, &selected_config, &flags, &ref);
    if (cookie == kInvalidCookie) {
      return ApkAssetsCookieToJavaCookie(kInvalidCookie);
    }
  }
  return CopyValue(env, cookie, value, ref, flags, &selected_config, typed_value);
}
```
在里面设计到一个比较核心的结构体ApkAssetsCookie。这个对象是在构建动态资源映射表时候，按照顺序递增加入到packageGroup中。这个结构体能看到，是十分简单的只包含一个int类型。

换句话说，ApkAssetsCookie对应到Java层的Cookie实际上就是指当前的资源来源于packageGroup中cookie的index，注意加入逻辑，cookie添加的顺序实际上和package数据包添加的顺序是一致，也就是说，可以通过这个cookief反向查找package数据包。

能看到这里面有一个比较核心的方法，assetmanager->GetResource。

### AssetManager2 GetResource
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AssetManager2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AssetManager2.cpp)

```cpp
ApkAssetsCookie AssetManager2::GetResource(uint32_t resid, bool may_be_bag,
                                           uint16_t density_override, Res_value* out_value,
                                           ResTable_config* out_selected_config,
                                           uint32_t* out_flags) const {
  FindEntryResult entry;
  ApkAssetsCookie cookie =
      FindEntry(resid, density_override, false /* stop_at_first_match */, &entry);
  if (cookie == kInvalidCookie) {
    return kInvalidCookie;
  }

  if (dtohs(entry.entry->flags) & ResTable_entry::FLAG_COMPLEX) {
    if (!may_be_bag) {
     ...
      return kInvalidCookie;
    }

    // Create a reference since we can't represent this complex type as a Res_value.
    out_value->dataType = Res_value::TYPE_REFERENCE;
    out_value->data = resid;
    *out_selected_config = entry.config;
    *out_flags = entry.type_flags;
    return cookie;
  }

  const Res_value* device_value = reinterpret_cast<const Res_value*>(
      reinterpret_cast<const uint8_t*>(entry.entry) + dtohs(entry.entry->size));
  out_value->copyFrom_dtoh(*device_value);

  // Convert the package ID to the runtime assigned package ID.
  entry.dynamic_ref_table->lookupResourceValue(out_value);

  *out_selected_config = entry.config;
  *out_flags = entry.type_flags;
  return cookie;
}
```
这个方法中包含了两种情况：
- 1.当当前的引用属于比较复杂的时候，是一个引用，并非真实的资源数据，则data返回的是当前引用中的resid。

- 2.通过FindEntry，查找每一个资源的entry，还记得上面说过的，每一个entry会包含真实的资源数据，这个时候out_value会获取当前entry中的真实数据。接着会覆盖当前的资源id，以及相关的配置等信息。

#### FindEntry查找资源Entry
```cpp
ApkAssetsCookie AssetManager2::FindEntry(uint32_t resid, uint16_t density_override,
                                         bool /*stop_at_first_match*/,
                                         FindEntryResult* out_entry) const {
  // Might use this if density_override != 0.
  ResTable_config density_override_config;

  // Select our configuration or generate a density override configuration.
  const ResTable_config* desired_config = &configuration_;
  if (density_override != 0 && density_override != configuration_.density) {
    density_override_config = configuration_;
    density_override_config.density = density_override;
    desired_config = &density_override_config;
  }

  if (!is_valid_resid(resid)) {
    LOG(ERROR) << base::StringPrintf("Invalid ID 0x%08x.", resid);
    return kInvalidCookie;
  }

  const uint32_t package_id = get_package_id(resid);
  const uint8_t type_idx = get_type_id(resid) - 1;
  const uint16_t entry_idx = get_entry_id(resid);

  const uint8_t package_idx = package_ids_[package_id];
  if (package_idx == 0xff) {
  ...
    return kInvalidCookie;
  }

  const PackageGroup& package_group = package_groups_[package_idx];
  const size_t package_count = package_group.packages_.size();

  ApkAssetsCookie best_cookie = kInvalidCookie;
  const LoadedPackage* best_package = nullptr;
  const ResTable_type* best_type = nullptr;
  const ResTable_config* best_config = nullptr;
  ResTable_config best_config_copy;
  uint32_t best_offset = 0u;
  uint32_t type_flags = 0u;

  // If desired_config is the same as the set configuration, then we can use our filtered list
  // and we don't need to match the configurations, since they already matched.
  const bool use_fast_path = desired_config == &configuration_;

  for (size_t pi = 0; pi < package_count; pi++) {
    const ConfiguredPackage& loaded_package_impl = package_group.packages_[pi];
    const LoadedPackage* loaded_package = loaded_package_impl.loaded_package_;
    ApkAssetsCookie cookie = package_group.cookies_[pi];

    // If the type IDs are offset in this package, we need to take that into account when searching
    // for a type.
    const TypeSpec* type_spec = loaded_package->GetTypeSpecByTypeIndex(type_idx);
    if (UNLIKELY(type_spec == nullptr)) {
      continue;
    }

    uint16_t local_entry_idx = entry_idx;

    // If there is an IDMAP supplied with this package, translate the entry ID.
    if (type_spec->idmap_entries != nullptr) {
      if (!LoadedIdmap::Lookup(type_spec->idmap_entries, local_entry_idx, &local_entry_idx)) {
        // There is no mapping, so the resource is not meant to be in this overlay package.
        continue;
      }
    }

    type_flags |= type_spec->GetFlagsForEntryIndex(local_entry_idx);

    // If the package is an overlay, then even configurations that are the same MUST be chosen.
    const bool package_is_overlay = loaded_package->IsOverlay();

    const FilteredConfigGroup& filtered_group = loaded_package_impl.filtered_configs_[type_idx];
    if (use_fast_path) {
      const std::vector<ResTable_config>& candidate_configs = filtered_group.configurations;
      const size_t type_count = candidate_configs.size();
      for (uint32_t i = 0; i < type_count; i++) {
        const ResTable_config& this_config = candidate_configs[i];

        // We can skip calling ResTable_config::match() because we know that all candidate
        // configurations that do NOT match have been filtered-out.
        if ((best_config == nullptr || this_config.isBetterThan(*best_config, desired_config)) ||
            (package_is_overlay && this_config.compare(*best_config) == 0)) {
          const ResTable_type* type_chunk = filtered_group.types[i];
          const uint32_t offset = LoadedPackage::GetEntryOffset(type_chunk, local_entry_idx);
          if (offset == ResTable_type::NO_ENTRY) {
            continue;
          }

          best_cookie = cookie;
          best_package = loaded_package;
          best_type = type_chunk;
          best_config = &this_config;
          best_offset = offset;
        }
      }
    } else {

      const auto iter_end = type_spec->types + type_spec->type_count;
      for (auto iter = type_spec->types; iter != iter_end; ++iter) {
        ResTable_config this_config;
        this_config.copyFromDtoH((*iter)->config);

        if (this_config.match(*desired_config)) {
          if ((best_config == nullptr || this_config.isBetterThan(*best_config, desired_config)) ||
              (package_is_overlay && this_config.compare(*best_config) == 0)) {
            const uint32_t offset = LoadedPackage::GetEntryOffset(*iter, local_entry_idx);
            if (offset == ResTable_type::NO_ENTRY) {
              continue;
            }

            best_cookie = cookie;
            best_package = loaded_package;
            best_type = *iter;
            best_config_copy = this_config;
            best_config = &best_config_copy;
            best_offset = offset;
          }
        }
      }
    }
  }

  if (UNLIKELY(best_cookie == kInvalidCookie)) {
    return kInvalidCookie;
  }

  const ResTable_entry* best_entry = LoadedPackage::GetEntryFromOffset(best_type, best_offset);
  if (UNLIKELY(best_entry == nullptr)) {
    return kInvalidCookie;
  }

  out_entry->entry = best_entry;
  out_entry->config = *best_config;
  out_entry->type_flags = type_flags;
  out_entry->type_string_ref = StringPoolRef(best_package->GetTypeStringPool(), best_type->id - 1);
  out_entry->entry_string_ref =
      StringPoolRef(best_package->GetKeyStringPool(), best_entry->key.index);
  out_entry->dynamic_ref_table = &package_group.dynamic_ref_table;
  return best_cookie;
}
```
在这里，我们先回顾一下资源ID的组成：
> 资源ID：0xPPTTEEEE  。最高两位PP是指PackageID，一般编译之后，应用资源包是0x7f，系统资源包是0x01，而第三方资源包，则是从0x02开始逐个递增。接下来的两位TT，代表着当前资源类型id，如anim文件夹下的资源就是0x01,组合起来就是0x7f01.最后四位是指资源entryID，是指的资源每一项对应的id，可能是0000，一般是按照资源编译顺序递增，如果是0001，则当前资源完整就是0x7f010001.

而这个方法就需要寻找通过资源id去寻找正确的资源。步骤如下：
- 1.解析当前资源id中packageID，typeID，entryID
- 2.获取AssetManager2中的packageID对应的packageGroup，在这个packageGroup中，根据typeID寻找对应资源类型。如果发现typeSpec中有idmap说明有id需要被覆盖，就尝试通过Loadedmap::Lookup，转化一下entryID(从IdEntryMap的数组获取对应entry数组中的id)，接着从ConfiguredPackage获取到对应的package数据。

接下来有两种情况，一种是和原来的配置config一致，一种是不一致。
- 1.一致的情况下，在ConfiguredPackage中存放着在根据config已经过滤好的资源列表，直接从里面循环直接拿到对应资源Type，并调用方法GetEntryOffset根据资源entryId获取对应的资源entry对象。
- 2. 不一致的情况下，则循环typeSpec中映射好的资源关系，先寻找合适的config接着在尝试寻找有没有对应的entryID。

- 最后确定已经存在了资源的存在，则会通过当前的资源类型以及资源类型中的偏移数组通过方法GetEntryFromOffset获取对应的entry。

最后返回当前的cookie。

#### 通过id寻找是否存在对应的entry
文件；/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[LoadedArsc.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/LoadedArsc.cpp)

```cpp
uint32_t LoadedPackage::GetEntryOffset(const ResTable_type* type_chunk, uint16_t entry_index) {

  const size_t entry_count = dtohl(type_chunk->entryCount);
  const size_t offsets_offset = dtohs(type_chunk->header.headerSize);

...

  const uint32_t* entry_offsets = reinterpret_cast<const uint32_t*>(
      reinterpret_cast<const uint8_t*>(type_chunk) + offsets_offset);
  return dtohl(entry_offsets[entry_index]);
}
```
能看到通过获取资源ResTable_type起始地址+ResTable_type的头部大小+头部起点地址，来找到entry偏移数组。
![寻找Res_table_entry.png](/images/寻找Res_table_entry.png)
通过偏移数组中的结果来确定当前的entry是否存在。


#### GetEntryFromOffset 查找具体的内容
```cpp
const ResTable_entry* LoadedPackage::GetEntryFromOffset(const ResTable_type* type_chunk,
                                                        uint32_t offset) {
...
  return reinterpret_cast<const ResTable_entry*>(reinterpret_cast<const uint8_t*>(type_chunk) +
                                                 offset + dtohl(type_chunk->entriesStart));
}
```
因为在type中记录对应entry中数据的偏移量，因此，可以通过简单的相加找到对应的地址。
![寻找Res_table_entry2.png](/images/寻找Res_table_entry2.png)

而entry当中就有一个Res_value对象.这个对象保存着真实的数据，最后会通过CopyValue的方法，把Res_value.data拷贝到TypeValue中。此时就拥有了当前资源真实数据。换到当前情景就是指，找到了布局文件,layout/xxx.xml字符串对应的index。



#### 通过cookie以及解析资源信息尝试查找非Asset资源中具体内容
上一个步骤中已经准备好了资源包对应的cookie，确认了资源的存在以及位置，可以尝试的着读取数据。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ResourcesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ResourcesImpl.java)

```java
    XmlResourceParser loadXmlResourceParser(@NonNull String file, @AnyRes int id, int assetCookie,
            @NonNull String type)
            throws NotFoundException {
        if (id != 0) {
            try {
                synchronized (mCachedXmlBlocks) {
                    final int[] cachedXmlBlockCookies = mCachedXmlBlockCookies;
                    final String[] cachedXmlBlockFiles = mCachedXmlBlockFiles;
                    final XmlBlock[] cachedXmlBlocks = mCachedXmlBlocks;
                    // First see if this block is in our cache.
                    final int num = cachedXmlBlockFiles.length;
                    for (int i = 0; i < num; i++) {
                        if (cachedXmlBlockCookies[i] == assetCookie && cachedXmlBlockFiles[i] != null
                                && cachedXmlBlockFiles[i].equals(file)) {
                            return cachedXmlBlocks[i].newParser();
                        }
                    }

                   
                    final XmlBlock block = mAssets.openXmlBlockAsset(assetCookie, file);
                    if (block != null) {
                        final int pos = (mLastCachedXmlBlockIndex + 1) % num;
                        mLastCachedXmlBlockIndex = pos;
                        final XmlBlock oldBlock = cachedXmlBlocks[pos];
                        if (oldBlock != null) {
                            oldBlock.close();
                        }
                        cachedXmlBlockCookies[pos] = assetCookie;
                        cachedXmlBlockFiles[pos] = file;
                        cachedXmlBlocks[pos] = block;
                        return block.newParser();
                    }
                }
            } catch (Exception e) {
               ...
            }
        }

        ...
    }
```
能看见在整个ResourcesImpl中会对所有加载过的Xml文件有一层mCachedXmlBlockFiles缓存，如果找不到则会尝试着通过openXmlBlockAsset从native查找数据。最后会通过XmlBlock生成解析器。

我们看看AssetManager的openXmlBlockAsset方法。

```java
    @NonNull XmlBlock openXmlBlockAsset(int cookie, @NonNull String fileName) throws IOException {
        Preconditions.checkNotNull(fileName, "fileName");
        synchronized (this) {
            ensureOpenLocked();
            final long xmlBlock = nativeOpenXmlAsset(mObject, cookie, fileName);
            if (xmlBlock == 0) {
                throw new FileNotFoundException("Asset XML file: " + fileName);
            }
            final XmlBlock block = new XmlBlock(this, xmlBlock);
            incRefsLocked(block.hashCode());
            return block;
        }
    }
```
该方法会调用native方法 nativeOpenXmlAsset。这个方法最后会获取native层数据块对应的地址，并且交给XmlBlock进行操控。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_util_AssetManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_util_AssetManager.cpp)

```cpp
static jlong NativeOpenXmlAsset(JNIEnv* env, jobject /*clazz*/, jlong ptr, jint jcookie,
                                jstring asset_path) {
  ApkAssetsCookie cookie = JavaCookieToApkAssetsCookie(jcookie);
  ScopedUtfChars asset_path_utf8(env, asset_path);
...
  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  std::unique_ptr<Asset> asset;
  if (cookie != kInvalidCookie) {
    asset = assetmanager->OpenNonAsset(asset_path_utf8.c_str(), cookie, Asset::ACCESS_RANDOM);
  } else {
    asset = assetmanager->OpenNonAsset(asset_path_utf8.c_str(), Asset::ACCESS_RANDOM, &cookie);
  }
  ....

  const DynamicRefTable* dynamic_ref_table = assetmanager->GetDynamicRefTableForCookie(cookie);

  std::unique_ptr<ResXMLTree> xml_tree = util::make_unique<ResXMLTree>(dynamic_ref_table);
  status_t err = xml_tree->setTo(asset->getBuffer(true), asset->getLength(), true);
  asset.reset();
 ...
  return reinterpret_cast<jlong>(xml_tree.release());
}
```
这里大致上分为如下几个步骤：
- 1.通过OpenNonAsset读取资源名称对应的Asset
- 2.获取AssetManager2的动态映射表，并且把cookie对应的动态映射表转化为ResXMLTree，读取asset中对应的数据，设置到ResXMLTree中。等待解析。


#### OpenNonAsset读取资源名称对应的Asset
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AssetManager2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AssetManager2.cpp)
这个方法是要打开所有非Asset资源对象，这种资源还是以zip的entry方式读取出来。
```cpp
std::unique_ptr<Asset> AssetManager2::OpenNonAsset(const std::string& filename,
                                                   Asset::AccessMode mode,
                                                   ApkAssetsCookie* out_cookie) const {
  for (int32_t i = apk_assets_.size() - 1; i >= 0; i--) {
    std::unique_ptr<Asset> asset = apk_assets_[i]->Open(filename, mode);
    if (asset) {
      if (out_cookie != nullptr) {
        *out_cookie = i;
      }
      return asset;
    }
  }

  if (out_cookie != nullptr) {
    *out_cookie = kInvalidCookie;
  }
  return {};
}
```
循环每一个AssetManager2管理的ApkAsset对象，获取对应资源Asset。此时的Asset，就是之前我们nativeLoad的时候解析resource.arsc生成的对象。

而方法名中的Asset的这个Asset并非是native层的解析resource.arsc的Asset资源，而是指Asset文件夹


#### ApkAssets::Open
```cpp
std::unique_ptr<Asset> ApkAssets::Open(const std::string& path, Asset::AccessMode mode) const {
  CHECK(zip_handle_ != nullptr);

  ::ZipString name(path.c_str());
  ::ZipEntry entry;
  int32_t result = ::FindEntry(zip_handle_.get(), name, &entry);
 ...
  if (entry.method == kCompressDeflated) {
    std::unique_ptr<FileMap> map = util::make_unique<FileMap>();
  ....
    std::unique_ptr<Asset> asset =
        Asset::createFromCompressedMap(std::move(map), entry.uncompressed_length, mode);
  ...
    return asset;
  } else {
    std::unique_ptr<FileMap> map = util::make_unique<FileMap>();
    ...

    std::unique_ptr<Asset> asset = Asset::createFromUncompressedMap(std::move(map), mode);
   ...
    return asset;
  }
}
```
这里的逻辑其实和之前说过解包resource.arsc的逻辑一样。注意这里这个方法名也叫FindEntry，不过找的是zip包中压缩单位，而不是资源数据中的资源entry。这样就能找到资源的layout布局文件，在资源目录下的数据。


#### XmlBlock生成解析器
```java
    XmlBlock(@Nullable AssetManager assets, long xmlBlock) {
        mAssets = assets;
        mNative = xmlBlock;
        mStrings = new StringBlock(nativeGetStringBlock(xmlBlock), false);
    }

```
此时XmlBlock会持有之前从zip包中解析出来的xmlBlock，以及全局字符串，方便之后解析Xml文件。

接下来就是解析一个树状的数据结构，获取里面所有的属性了，这里就不赘述。


## AssetManager查找Asset资源
上面一大段聊了非Asset资源的查找，接下来让我们看看Asset资源的查找。而方法名中的Asset的这个Asset并非是native层的解析resource.arsc的Asset资源，而是指Asset文件夹。

当我们想要打开Asset目录下资源文件的时候，一般会调用如下方法：
```java
    public @NonNull InputStream open(@NonNull String fileName, int accessMode) throws IOException {
        Preconditions.checkNotNull(fileName, "fileName");
        synchronized (this) {
            ensureOpenLocked();
            final long asset = nativeOpenAsset(mObject, fileName, accessMode);
            if (asset == 0) {
                throw new FileNotFoundException("Asset file: " + fileName);
            }
            final AssetInputStream assetInputStream = new AssetInputStream(asset);
            incRefsLocked(assetInputStream.hashCode());
            return assetInputStream;
        }
    }
```

而这个方法最后会调用native层下的如下方法：
```cpp
std::unique_ptr<Asset> AssetManager2::Open(const std::string& filename, ApkAssetsCookie cookie,
                                           Asset::AccessMode mode) const {
  const std::string new_path = "assets/" + filename;
  return OpenNonAsset(new_path, cookie, mode);
}
```
系统这种方式，设置了相对路径。一样还是从OpenNonAsset中查找数据。最后会把Asset返回回去。此时AssetInputStream就会尝试着操作这个Asset对象，会持有着对应zipEntry，生成的FileMap。

当我们尝试着读取数据的时候会调用AssetInputStream中的read方法：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_util_AssetManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_util_AssetManager.cpp)

```cpp
static jint NativeAssetReadChar(JNIEnv* /*env*/, jclass /*clazz*/, jlong asset_ptr) {
  Asset* asset = reinterpret_cast<Asset*>(asset_ptr);
  uint8_t b;
  ssize_t res = asset->read(&b, sizeof(b));
  return res == sizeof(b) ? static_cast<jint>(b) : -1;
}
```

## 资源属性的获取
在资源管理体系中，还有一个很重要的知识点，那就是解析View标签中写的属性。在此之前，想要理解整个资源Theme属性是如何获取的，先来看看Theme是如何初始化的。

### Theme的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)
```java
private Activity performLaunchActivity(ActivityClientRecord r, Intent customIntent) {
....
                int theme = r.activityInfo.getThemeResource();
                if (theme != 0) {
                    activity.setTheme(theme);
                }
....
}
```

一般在Activity的onCreate的生命周期，会调用setTheme设置从Xml中解析出来的主题Theme。而这个方法最后会调用到ContextImpl中：
```java
    @Override
    public void setTheme(int resId) {
        synchronized (mSync) {
            if (mThemeResource != resId) {
                mThemeResource = resId;
                initializeTheme();
            }
        }
    }

    private void initializeTheme() {
        if (mTheme == null) {
            mTheme = mResources.newTheme();
        }
        mTheme.applyStyle(mThemeResource, true);
    }
```
能看到其实整个主题是有一个Theme对象在控制，最后才把resID设置到Theme对象中进去。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[Resources.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/Resources.java)
```java
    public final Theme newTheme() {
        Theme theme = new Theme();
        theme.setImpl(mResourcesImpl.newThemeImpl());
        synchronized (mThemeRefs) {
            mThemeRefs.add(new WeakReference<>(theme));

            if (mThemeRefs.size() > mThemeRefsNextFlushSize) {
                mThemeRefs.removeIf(ref -> ref.get() == null);
                mThemeRefsNextFlushSize = Math.max(MIN_THEME_REFS_FLUSH_SIZE,
                        2 * mThemeRefs.size());
            }
        }
        return theme;
    }
```
在Resources中，能看到每一个主题都换缓存到弱引用下来，方便下次查找。核心方法是实例化了一个ThemeImpl对象。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ResourcesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ResourcesImpl.java)

```java
    ThemeImpl newThemeImpl() {
        return new ThemeImpl();
    }

    public class ThemeImpl {
        /**
         * Unique key for the series of styles applied to this theme.
         */
        private final Resources.ThemeKey mKey = new Resources.ThemeKey();

        @SuppressWarnings("hiding")
        private final AssetManager mAssets;
        private final long mTheme;

        /**
         * Resource identifier for the theme.
         */
        private int mThemeResId = 0;

        /*package*/ ThemeImpl() {
            mAssets = ResourcesImpl.this.mAssets;
            mTheme = mAssets.createTheme();
        }
...
}
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[AssetManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/AssetManager.java)

```java
    long createTheme() {
        synchronized (this) {
            ensureValidLocked();
            long themePtr = nativeThemeCreate(mObject);
            incRefsLocked(themePtr);
            return themePtr;
        }
    }
```

调用native方法实例化底层的Theme对象.

文件；/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[jni](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/)/[android_util_AssetManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/jni/android_util_AssetManager.cpp)
```cpp
static jlong NativeThemeCreate(JNIEnv* /*env*/, jclass /*clazz*/, jlong ptr) {
  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  return reinterpret_cast<jlong>(assetmanager->NewTheme().release());
}
```
```cpp
std::unique_ptr<Theme> AssetManager2::NewTheme() {
  return std::unique_ptr<Theme>(new Theme(this));
}
```
这样就对应着Java层中ThemeImpl，在native中同样生成一样的Theme。

### ThemeImpl.applyStyle
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[ResourcesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/ResourcesImpl.java)

```java
        void applyStyle(int resId, boolean force) {
            synchronized (mKey) {
                mAssets.applyStyleToTheme(mTheme, resId, force);
                mThemeResId = resId;
                mKey.append(resId, force);
            }
        }
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[res](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/)/[AssetManager.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/res/AssetManager.java)

```java
    void applyStyleToTheme(long themePtr, @StyleRes int resId, boolean force) {
        synchronized (this) {
            ensureValidLocked();
            nativeThemeApplyStyle(mObject, themePtr, resId, force);
        }
    }

```
```cpp
static void NativeThemeApplyStyle(JNIEnv* env, jclass /*clazz*/, jlong ptr, jlong theme_ptr,
                                  jint resid, jboolean force) {

  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  Theme* theme = reinterpret_cast<Theme*>(theme_ptr);
  CHECK(theme->GetAssetManager() == &(*assetmanager));
  (void) assetmanager;
  theme->ApplyStyle(static_cast<uint32_t>(resid), force);
}

```
可以看到在设置Theme过程中，核心方法是Theme的ApplyStyle。

#### Theme的ApplyStyle
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AssetManager2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AssetManager2.cpp)

```cpp
bool Theme::ApplyStyle(uint32_t resid, bool force) {

  const ResolvedBag* bag = asset_manager_->GetBag(resid);

  type_spec_flags_ |= bag->type_spec_flags;

  int last_type_idx = -1;
  int last_package_idx = -1;
  Package* last_package = nullptr;
  ThemeType* last_type = nullptr;

  using reverse_bag_iterator = std::reverse_iterator<const ResolvedBag::Entry*>;
  const auto bag_iter_end = reverse_bag_iterator(begin(bag));
  for (auto bag_iter = reverse_bag_iterator(end(bag)); bag_iter != bag_iter_end; ++bag_iter) {
    const uint32_t attr_resid = bag_iter->key;

    const int package_idx = get_package_id(attr_resid);
    const int type_idx = get_type_id(attr_resid);
    const int entry_idx = get_entry_id(attr_resid);

    if (last_package_idx != package_idx) {
      std::unique_ptr<Package>& package = packages_[package_idx];
      if (package == nullptr) {
        package.reset(new Package());
      }
      last_package_idx = package_idx;
      last_package = package.get();
      last_type_idx = -1;
    }

    if (last_type_idx != type_idx) {
      util::unique_cptr<ThemeType>& type = last_package->types[type_idx];
      if (type == nullptr) {
        type.reset(reinterpret_cast<ThemeType*>(
            calloc(sizeof(ThemeType) + (entry_idx + 1) * sizeof(ThemeEntry), 1)));
        type->entry_count = entry_idx + 1;
      } else if (entry_idx >= type->entry_count) {
        const int new_count = entry_idx + 1;
        type.reset(reinterpret_cast<ThemeType*>(
            realloc(type.release(), sizeof(ThemeType) + (new_count * sizeof(ThemeEntry)))));

        memset(type->entries + type->entry_count, 0,
               (new_count - type->entry_count) * sizeof(ThemeEntry));
        type->entry_count = new_count;
      }
      last_type_idx = type_idx;
      last_type = type.get();
    }

    ThemeEntry& entry = last_type->entries[entry_idx];
    if (force || (entry.value.dataType == Res_value::TYPE_NULL &&
                  entry.value.data != Res_value::DATA_NULL_EMPTY)) {
      entry.cookie = bag_iter->cookie;
      entry.type_spec_flags |= bag->type_spec_flags;
      entry.value = bag_iter->value;
    }
  }
  return true;
}
```
- 1.首先先通过resId找到对应的bag，通过Bag获取对应的packageID，typeID，entryID
- 2.检查当前Theme对象中，之前是否缓存了当前要查找的packageID对应的Package对象，没有则继续啊检查是否包含对应packageID的package对象。都没有就会创建一个新的Package对象。
- 3.检查当前的package对象中，是否缓存了当前要查找typeID，是否包含对应typeID的ThemeType对象，没有则创建一个新的(大小为entry的大小*typeID)，如果typeID超过了当前ThemeType的容量，则扩容。
- 4.根据entryID，查找ThemeType的entries对应index的ThemeEntry，最后把bag中的数据赋值进来。

因此在这里面有一个核心方法GetBag。

#### AssetManager2的GetBag
```cpp
const ResolvedBag* AssetManager2::GetBag(uint32_t resid, std::vector<uint32_t>& child_resids) {
  auto cached_iter = cached_bags_.find(resid);
  if (cached_iter != cached_bags_.end()) {
    return cached_iter->second.get();
  }

  FindEntryResult entry;
  ApkAssetsCookie cookie =
      FindEntry(resid, 0u /* density_override */, false /* stop_at_first_match */, &entry);
  if (cookie == kInvalidCookie) {
    return nullptr;
  }

  if (dtohs(entry.entry->size) < sizeof(ResTable_map_entry) ||
      (dtohs(entry.entry->flags) & ResTable_entry::FLAG_COMPLEX) == 0) {
    // Not a bag, nothing to do.
    return nullptr;
  }

  const ResTable_map_entry* map = reinterpret_cast<const ResTable_map_entry*>(entry.entry);
  const ResTable_map* map_entry =
      reinterpret_cast<const ResTable_map*>(reinterpret_cast<const uint8_t*>(map) + map->size);
  const ResTable_map* const map_entry_end = map_entry + dtohl(map->count);

  child_resids.push_back(resid);

  uint32_t parent_resid = dtohl(map->parent.ident);
  if (parent_resid == 0 || std::find(child_resids.begin(), child_resids.end(), parent_resid)
      != child_resids.end()) {

    const size_t entry_count = map_entry_end - map_entry;
    util::unique_cptr<ResolvedBag> new_bag{reinterpret_cast<ResolvedBag*>(
        malloc(sizeof(ResolvedBag) + (entry_count * sizeof(ResolvedBag::Entry))))};
    ResolvedBag::Entry* new_entry = new_bag->entries;
    for (; map_entry != map_entry_end; ++map_entry) {
      uint32_t new_key = dtohl(map_entry->name.ident);

      new_entry->cookie = cookie;
      new_entry->key = new_key;
      new_entry->key_pool = nullptr;
      new_entry->type_pool = nullptr;
      new_entry->value.copyFrom_dtoh(map_entry->value);
      status_t err = entry.dynamic_ref_table->lookupResourceValue(&new_entry->value);
      
      ++new_entry;
    }
    new_bag->type_spec_flags = entry.type_flags;
    new_bag->entry_count = static_cast<uint32_t>(entry_count);
    ResolvedBag* result = new_bag.get();
    cached_bags_[resid] = std::move(new_bag);
    return result;
  }

  entry.dynamic_ref_table->lookupResourceId(&parent_resid);

  const ResolvedBag* parent_bag = GetBag(parent_resid, child_resids);

  const size_t max_count = parent_bag->entry_count + dtohl(map->count);
  util::unique_cptr<ResolvedBag> new_bag{reinterpret_cast<ResolvedBag*>(
      malloc(sizeof(ResolvedBag) + (max_count * sizeof(ResolvedBag::Entry))))};
  ResolvedBag::Entry* new_entry = new_bag->entries;

  const ResolvedBag::Entry* parent_entry = parent_bag->entries;
  const ResolvedBag::Entry* const parent_entry_end = parent_entry + parent_bag->entry_count;

  while (map_entry != map_entry_end && parent_entry != parent_entry_end) {
    uint32_t child_key = dtohl(map_entry->name.ident);

    if (child_key <= parent_entry->key) {

      new_entry->cookie = cookie;
      new_entry->key = child_key;
      new_entry->key_pool = nullptr;
      new_entry->type_pool = nullptr;
      new_entry->value.copyFrom_dtoh(map_entry->value);
      status_t err = entry.dynamic_ref_table->lookupResourceValue(&new_entry->value);

      ++map_entry;
    } else {
      // Take the parent entry as-is.
      memcpy(new_entry, parent_entry, sizeof(*new_entry));
    }

    if (child_key >= parent_entry->key) {
      // Move to the next parent entry if we used it or it was overridden.
      ++parent_entry;
    }
    // Increment to the next entry to fill.
    ++new_entry;
  }


  while (map_entry != map_entry_end) {
    uint32_t new_key = dtohl(map_entry->name.ident);

    new_entry->cookie = cookie;
    new_entry->key = new_key;
    new_entry->key_pool = nullptr;
    new_entry->type_pool = nullptr;
    new_entry->value.copyFrom_dtoh(map_entry->value);
    status_t err = entry.dynamic_ref_table->lookupResourceValue(&new_entry->value);

    ++map_entry;
    ++new_entry;
  }

  if (parent_entry != parent_entry_end) {

    const size_t num_entries_to_copy = parent_entry_end - parent_entry;
    memcpy(new_entry, parent_entry, num_entries_to_copy * sizeof(*new_entry));
    new_entry += num_entries_to_copy;
  }

  const size_t actual_count = new_entry - new_bag->entries;
  if (actual_count != max_count) {
    new_bag.reset(reinterpret_cast<ResolvedBag*>(realloc(
        new_bag.release(), sizeof(ResolvedBag) + (actual_count * sizeof(ResolvedBag::Entry)))));
  }

  new_bag->type_spec_flags = entry.type_flags | parent_bag->type_spec_flags;
  new_bag->entry_count = static_cast<uint32_t>(actual_count);
  ResolvedBag* result = new_bag.get();
  cached_bags_[resid] = std::move(new_bag);
  return result;
}
```
- 1.首先通过FindEntry找到对应的FindEntryResult对象，里面包含着ResTable_entry,相关的配置，以及资源池中指向的字符串。
```cpp
struct FindEntryResult {
//查找到的entry结果
  const ResTable_entry* entry;
//配置
  ResTable_config config;

  uint32_t type_flags;
//动态映射表
  const DynamicRefTable* dynamic_ref_table;

//entry对应的类型名
  StringPoolRef type_string_ref;
//entry名
  StringPoolRef entry_string_ref;
};
```
- 2.如果当前的ResTable_entry不是ResTable_map_entry对象则返回，通过大小的来确定。并且获取后面ResTable_map对象。ResTable_map_entry的数据结构如下:
```cpp
struct ResTable_map_entry : public ResTable_entry
{
    //指向父ResTable_map_entry的引用
    ResTable_ref parent;
    // 后面ResTable_map的数量
    uint32_t count;
};
```
ResTable_map的位置计算如下:
> ResTable_map = ResTable_map_entry的起点+ResTable_map_entry大小

刚好在ResTable_map_entry后面。ResTable_map的数据结构如下：
```cpp
struct ResTable_map
{
    // The resource identifier defining this mapping's name.  For attribute
    // resources, 'name' can be one of the following special resource types
    // to supply meta-data about the attribute; for all other resource types
    // it must be an attribute resource.
    ResTable_ref name;

....
    // This mapping's value.
    Res_value value;
};
```
能看到ResTable_map才是真正持有Res_value的对象。ResTable_map里面包含着键值对。分别指的是当前资源当前的命名以及资源中的值。

- 3.接下来分为两种情况，一种是ResTable_map_entry不包含父资源或者已经在原来child_resids找到了，一种的是包含父资源。
1 .当不包含父资源的时候，则循环ResTable_map中的引用，把里面的包含的资源真实数据，cookie都设置到ResolveBag的Entry指针中。这样ResolveBag就包含了当前ResTable_entry中所有的数据。一般的一个ResolveBag就包含一个ResTable_map。
2 .当包含父资源的时候，将会通过动态映射表去查找对应的父资源的packageID，递归当前的方法，找到所有父资源的数据，获取父ResolveBag。当遇到每一个子资源和父资源冲突，则让子资源覆盖父资源。

这样就把所有的父子资源压缩到一起交给了ResolveBag中保管了，并且缓存到cached_bags_中。

### 查找当前主题下的属性的值常用方法

接下来，让我们探索一下，当我们编写自定义View，以及自定义属性时候常用三种在当前主题下查找对应的资源属性中的值。

```java
public TypedArray obtainStyledAttributes(@StyleableRes int[] attrs) {
            return mThemeImpl.obtainStyledAttributes(this, null, attrs, 0, 0);
        }

        TypedArray resolveAttributes(@NonNull Resources.Theme wrapper,
                @NonNull int[] values,
                @NonNull int[] attrs) {
            synchronized (mKey) {
                final int len = attrs.length;
                if (values == null || len != values.length) {
                    throw new IllegalArgumentException(
                            "Base attribute values must the same length as attrs");
                }

                final TypedArray array = TypedArray.obtain(wrapper.getResources(), len);
                mAssets.resolveAttrs(mTheme, 0, 0, values, attrs, array.mData, array.mIndices);
                array.mTheme = wrapper;
                array.mXml = null;
                return array;
            }
        }

        boolean resolveAttribute(int resid, TypedValue outValue, boolean resolveRefs) {
            synchronized (mKey) {
                return mAssets.getThemeValue(mTheme, resid, outValue, resolveRefs);
            }
        }
```
而这两个方法都会调用ThemeImpl中的下面方法。
```java
        TypedArray resolveAttributes(@NonNull Resources.Theme wrapper,
                @NonNull int[] values,
                @NonNull int[] attrs) {
            synchronized (mKey) {
                final int len = attrs.length;
                if (values == null || len != values.length) {
                    throw new IllegalArgumentException(
                            "Base attribute values must the same length as attrs");
                }

                final TypedArray array = TypedArray.obtain(wrapper.getResources(), len);
                mAssets.resolveAttrs(mTheme, 0, 0, values, attrs, array.mData, array.mIndices);
                array.mTheme = wrapper;
                array.mXml = null;
                return array;
            }
        }


        TypedArray obtainStyledAttributes(@NonNull Resources.Theme wrapper,
                AttributeSet set,
                @StyleableRes int[] attrs,
                @AttrRes int defStyleAttr,
                @StyleRes int defStyleRes) {
            synchronized (mKey) {
                final int len = attrs.length;
                final TypedArray array = TypedArray.obtain(wrapper.getResources(), len);

                final XmlBlock.Parser parser = (XmlBlock.Parser) set;
                mAssets.applyStyle(mTheme, defStyleAttr, defStyleRes, parser, attrs,
                        array.mDataAddress, array.mIndicesAddress);
                array.mTheme = wrapper;
                array.mXml = parser;
                return array;
            }
        }
```

其核心原理是十分相似。首先在ActivityThread的handleLaunch阶段，会设置一个Theme。这个Theme就是ThemeImpl，同时会在native层中生成一个Theme对象。

最后分别调用AssetManager的resolveAttrs以及applyStyle方法。
```java
    void applyStyle(long themePtr, @AttrRes int defStyleAttr, @StyleRes int defStyleRes,
            @Nullable XmlBlock.Parser parser, @NonNull int[] inAttrs, long outValuesAddress,
            long outIndicesAddress) {
        synchronized (this) {

            nativeApplyStyle(mObject, themePtr, defStyleAttr, defStyleRes,
                    parser != null ? parser.mParseState : 0, inAttrs, outValuesAddress,
                    outIndicesAddress);
        }
    }

    boolean resolveAttrs(long themePtr, @AttrRes int defStyleAttr, @StyleRes int defStyleRes,
            @Nullable int[] inValues, @NonNull int[] inAttrs, @NonNull int[] outValues,
            @NonNull int[] outIndices) {
        synchronized (this) {

            return nativeResolveAttrs(mObject,
                    themePtr, defStyleAttr, defStyleRes, inValues, inAttrs, outValues, outIndices);
        }
    }

    boolean getThemeValue(long theme, @AnyRes int resId, @NonNull TypedValue outValue,
            boolean resolveRefs) {
        Preconditions.checkNotNull(outValue, "outValue");
        synchronized (this) {
            ensureValidLocked();
            final int cookie = nativeThemeGetAttributeValue(mObject, theme, resId, outValue,
                    resolveRefs);
            if (cookie <= 0) {
                return false;
            }

            // Convert the changing configurations flags populated by native code.
            outValue.changingConfigurations = ActivityInfo.activityInfoConfigNativeToJava(
                    outValue.changingConfigurations);

            if (outValue.type == TypedValue.TYPE_STRING) {
                outValue.string = mApkAssets[cookie - 1].getStringFromPool(outValue.data);
            }
            return true;
        }
    }
```

### obtainStyledAttributes 工作原理
```cpp
static void NativeApplyStyle(JNIEnv* env, jclass /*clazz*/, jlong ptr, jlong theme_ptr,
                             jint def_style_attr, jint def_style_resid, jlong xml_parser_ptr,
                             jintArray java_attrs, jlong out_values_ptr, jlong out_indices_ptr) {
  ScopedLock<AssetManager2> assetmanager(AssetManagerFromLong(ptr));
  Theme* theme = reinterpret_cast<Theme*>(theme_ptr);
  CHECK(theme->GetAssetManager() == &(*assetmanager));
  (void) assetmanager;

  ResXMLParser* xml_parser = reinterpret_cast<ResXMLParser*>(xml_parser_ptr);
  uint32_t* out_values = reinterpret_cast<uint32_t*>(out_values_ptr);
  uint32_t* out_indices = reinterpret_cast<uint32_t*>(out_indices_ptr);

  jsize attrs_len = env->GetArrayLength(java_attrs);
  jint* attrs = reinterpret_cast<jint*>(env->GetPrimitiveArrayCritical(java_attrs, nullptr));
...
  ApplyStyle(theme, xml_parser, static_cast<uint32_t>(def_style_attr),
             static_cast<uint32_t>(def_style_resid), reinterpret_cast<uint32_t*>(attrs), attrs_len,
             out_values, out_indices);
  env->ReleasePrimitiveArrayCritical(java_attrs, attrs, JNI_ABORT);
}
```
核心方法调用ApplyStyle
文件；/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AttributeResolution.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AttributeResolution.cpp)

```cpp
void ApplyStyle(Theme* theme, ResXMLParser* xml_parser, uint32_t def_style_attr,
                uint32_t def_style_resid, const uint32_t* attrs, size_t attrs_length,
                uint32_t* out_values, uint32_t* out_indices) {


  AssetManager2* assetmanager = theme->GetAssetManager();
  ResTable_config config;
  Res_value value;

  int indices_idx = 0;

  uint32_t def_style_flags = 0u;
  if (def_style_attr != 0) {
    Res_value value;
    if (theme->GetAttribute(def_style_attr, &value, &def_style_flags) != kInvalidCookie) {
      if (value.dataType == Res_value::TYPE_REFERENCE) {
        def_style_resid = value.data;
      }
    }
  }

  // Retrieve the style resource ID associated with the current XML tag's style attribute.
  uint32_t style_resid = 0u;
  uint32_t style_flags = 0u;
  if (xml_parser != nullptr) {
    ssize_t idx = xml_parser->indexOfStyle();
    if (idx >= 0 && xml_parser->getAttributeValue(idx, &value) >= 0) {
      if (value.dataType == value.TYPE_ATTRIBUTE) {
        // Resolve the attribute with out theme.
        if (theme->GetAttribute(value.data, &value, &style_flags) == kInvalidCookie) {
          value.dataType = Res_value::TYPE_NULL;
        }
      }

      if (value.dataType == value.TYPE_REFERENCE) {
        style_resid = value.data;
      }
    }
  }

  const ResolvedBag* default_style_bag = nullptr;
  if (def_style_resid != 0) {
    default_style_bag = assetmanager->GetBag(def_style_resid);
    if (default_style_bag != nullptr) {
      def_style_flags |= default_style_bag->type_spec_flags;
    }
  }

  BagAttributeFinder def_style_attr_finder(default_style_bag);

  const ResolvedBag* xml_style_bag = nullptr;
  if (style_resid != 0) {
    xml_style_bag = assetmanager->GetBag(style_resid);
    if (xml_style_bag != nullptr) {
      style_flags |= xml_style_bag->type_spec_flags;
    }
  }

  BagAttributeFinder xml_style_attr_finder(xml_style_bag);

  XmlAttributeFinder xml_attr_finder(xml_parser);

  for (size_t ii = 0; ii < attrs_length; ii++) {
    const uint32_t cur_ident = attrs[ii];

    ApkAssetsCookie cookie = kInvalidCookie;
    uint32_t type_set_flags = 0u;

    value.dataType = Res_value::TYPE_NULL;
    value.data = Res_value::DATA_NULL_UNDEFINED;
    config.density = 0;

    const size_t xml_attr_idx = xml_attr_finder.Find(cur_ident);
    if (xml_attr_idx != xml_attr_finder.end()) {
      xml_parser->getAttributeValue(xml_attr_idx, &value);
    }

    if (value.dataType == Res_value::TYPE_NULL && value.data != Res_value::DATA_NULL_EMPTY) {
      const ResolvedBag::Entry* entry = xml_style_attr_finder.Find(cur_ident);
      if (entry != xml_style_attr_finder.end()) {
        cookie = entry->cookie;
        type_set_flags = style_flags;
        value = entry->value;
      }
    }

    if (value.dataType == Res_value::TYPE_NULL && value.data != Res_value::DATA_NULL_EMPTY) {
      const ResolvedBag::Entry* entry = def_style_attr_finder.Find(cur_ident);
      if (entry != def_style_attr_finder.end()) {
        cookie = entry->cookie;
        type_set_flags = def_style_flags;
        value = entry->value;
      }
    }

    uint32_t resid = 0u;
    if (value.dataType != Res_value::TYPE_NULL) {
      ApkAssetsCookie new_cookie =
          theme->ResolveAttributeReference(cookie, &value, &config, &type_set_flags, &resid);
      if (new_cookie != kInvalidCookie) {
        cookie = new_cookie;
      }

    } else if (value.data != Res_value::DATA_NULL_EMPTY) {
      ApkAssetsCookie new_cookie = theme->GetAttribute(cur_ident, &value, &type_set_flags);
      if (new_cookie != kInvalidCookie) {
        new_cookie =
            assetmanager->ResolveReference(new_cookie, &value, &config, &type_set_flags, &resid);
        if (new_cookie != kInvalidCookie) {
          cookie = new_cookie;
        }
      }
    }

    if (value.dataType == Res_value::TYPE_REFERENCE && value.data == 0) {
      value.dataType = Res_value::TYPE_NULL;
      value.data = Res_value::DATA_NULL_UNDEFINED;
      cookie = kInvalidCookie;
    }

    out_values[STYLE_TYPE] = value.dataType;
    out_values[STYLE_DATA] = value.data;
    out_values[STYLE_ASSET_COOKIE] = ApkAssetsCookieToJavaCookie(cookie);
    out_values[STYLE_RESOURCE_ID] = resid;
    out_values[STYLE_CHANGING_CONFIGURATIONS] = type_set_flags;
    out_values[STYLE_DENSITY] = config.density;

    if (value.dataType != Res_value::TYPE_NULL || value.data == Res_value::DATA_NULL_EMPTY) {
      indices_idx++;
      out_indices[indices_idx] = ii;
    }

    out_values += STYLE_NUM_ENTRIES;
  }

  out_indices[0] = indices_idx;
}
```
- 1.首先通过GetAttribute检查当前传进来的默认的属性，如果当前传进来了XML当前块的解析对象，则获取style的位置之后，尝试获取style中的值，是引用则记录当前的id。如果是Attribute则通过GetAttribute获取值。
- 2.如果默认的style的id不为0，则获取styleID对应的ResolveBag作为默认对象。
- 3.此时获取从上面传下来的attr引用指针，在这个情况一般是值R.styleable.xxx的一个数组，里面含有大量的属性。开始循环传下来的attr数组，逐一查找对应数组中每一个资源值对应的index。
- 4.如果xml_attr_finder找到对应的index，则通过xml_parser->getAttributeValue(xml_attr_idx, &value);解析里面内容，并且拷贝到outValue中。记住如果是引用，则会通过ResolveReference方法解包引用，通过GetResources找到真正的值。如果数据为空，则从默认的style中读取。

能看到这个过程中有2个核心方法我们未曾接触过，让我们着重看看里面做了什么事情：
- GetAttribute
-  xml_parser->getAttributeValue

#### GetAttribute 获取属性
```cpp
ApkAssetsCookie Theme::GetAttribute(uint32_t resid, Res_value* out_value,
                                    uint32_t* out_flags) const {
  int cnt = 20;

  uint32_t type_spec_flags = 0u;

  do {
    const int package_idx = get_package_id(resid);
    const Package* package = packages_[package_idx].get();
    if (package != nullptr) {
      // The themes are constructed with a 1-based type ID, so no need to decrement here.
      const int type_idx = get_type_id(resid);
      const ThemeType* type = package->types[type_idx].get();
      if (type != nullptr) {
        const int entry_idx = get_entry_id(resid);
        if (entry_idx < type->entry_count) {
          const ThemeEntry& entry = type->entries[entry_idx];
          type_spec_flags |= entry.type_spec_flags;

          if (entry.value.dataType == Res_value::TYPE_ATTRIBUTE) {
            if (cnt > 0) {
              cnt--;
              resid = entry.value.data;
              continue;
            }
            return kInvalidCookie;
          }

          // @null is different than @empty.
          if (entry.value.dataType == Res_value::TYPE_NULL &&
              entry.value.data != Res_value::DATA_NULL_EMPTY) {
            return kInvalidCookie;
          }

          *out_value = entry.value;
          *out_flags = type_spec_flags;
          return entry.cookie;
        }
      }
    }
    break;
  } while (true);
  return kInvalidCookie;
}
```
能看到实际上很简单，在native层已经保存了当前主题中所有xml的映射关系，因此可以通过当前Package，ThemeType找到对应的ResTable_entry中的数据。因此我们可以得知，在obtainStyledAttributes中，设置默认的属性不是什么都可以设置，需要设置Theme中有的才能正常运作。

#### getAttributeValue解析Xml数据块中的属性值
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[ResourceTypes.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/ResourceTypes.cpp)

```cpp
ssize_t ResXMLParser::getAttributeValue(size_t idx, Res_value* outValue) const
{
    if (mEventCode == START_TAG) {
        const ResXMLTree_attrExt* tag = (const ResXMLTree_attrExt*)mCurExt;
        if (idx < dtohs(tag->attributeCount)) {
            const ResXMLTree_attribute* attr = (const ResXMLTree_attribute*)
                (((const uint8_t*)tag)
                 + dtohs(tag->attributeStart)
                 + (dtohs(tag->attributeSize)*idx));
            outValue->copyFrom_dtoh(attr->typedValue);
            if (mTree.mDynamicRefTable != NULL &&
                    mTree.mDynamicRefTable->lookupResourceValue(outValue) != NO_ERROR) {
                return BAD_TYPE;
            }
            return sizeof(Res_value);
        }
    }
    return BAD_TYPE;
}
```
十分简单，就是通过当前保存的解析树中ResXMLTree_attribute对应index的属性值。还有一个resolveAttribute的方法本质上还是从ApplyStyle中查找方法。

到这里我们已经理解了obtainStyledAttributes的工作流程，让我们看看resolveAttributes。

#### resolveAttributes的工作原理
这个方法最终会调用native的ResolveAttrs方法。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/)/[androidfw](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/)/[AttributeResolution.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/base/libs/androidfw/AttributeResolution.cpp)
```cpp
bool ResolveAttrs(Theme* theme, uint32_t def_style_attr, uint32_t def_style_res,
                  uint32_t* src_values, size_t src_values_length, uint32_t* attrs,
                  size_t attrs_length, uint32_t* out_values, uint32_t* out_indices) {
  AssetManager2* assetmanager = theme->GetAssetManager();
  ResTable_config config;
  Res_value value;

  int indices_idx = 0;

  // Load default style from attribute, if specified...
  uint32_t def_style_flags = 0u;
  if (def_style_attr != 0) {
    Res_value value;
    if (theme->GetAttribute(def_style_attr, &value, &def_style_flags) != kInvalidCookie) {
      if (value.dataType == Res_value::TYPE_REFERENCE) {
        def_style_res = value.data;
      }
    }
  }

  const ResolvedBag* default_style_bag = nullptr;
  if (def_style_res != 0) {
    default_style_bag = assetmanager->GetBag(def_style_res);
    if (default_style_bag != nullptr) {
      def_style_flags |= default_style_bag->type_spec_flags;
    }
  }

  BagAttributeFinder def_style_attr_finder(default_style_bag);

  for (size_t ii = 0; ii < attrs_length; ii++) {
    const uint32_t cur_ident = attrs[ii];

    ApkAssetsCookie cookie = kInvalidCookie;
    uint32_t type_set_flags = 0;

    value.dataType = Res_value::TYPE_NULL;
    value.data = Res_value::DATA_NULL_UNDEFINED;
    config.density = 0;

    if (src_values_length > 0 && src_values[ii] != 0) {
      value.dataType = Res_value::TYPE_ATTRIBUTE;
      value.data = src_values[ii];
    } else {
      const ResolvedBag::Entry* const entry = def_style_attr_finder.Find(cur_ident);
      if (entry != def_style_attr_finder.end()) {
        cookie = entry->cookie;
        type_set_flags = def_style_flags;
        value = entry->value;
      }
    }

    uint32_t resid = 0;
    if (value.dataType != Res_value::TYPE_NULL) {
      ApkAssetsCookie new_cookie =
          theme->ResolveAttributeReference(cookie, &value, &config, &type_set_flags, &resid);
      if (new_cookie != kInvalidCookie) {
        cookie = new_cookie;
      }
    } else if (value.data != Res_value::DATA_NULL_EMPTY) {
      // If we still don't have a value for this attribute, try to find it in the theme!
      ApkAssetsCookie new_cookie = theme->GetAttribute(cur_ident, &value, &type_set_flags);
      if (new_cookie != kInvalidCookie) {
        new_cookie =
            assetmanager->ResolveReference(new_cookie, &value, &config, &type_set_flags, &resid);
        if (new_cookie != kInvalidCookie) {
          cookie = new_cookie;
        }
      }
    }

...
    // Write the final value back to Java.
    out_values[STYLE_TYPE] = value.dataType;
    out_values[STYLE_DATA] = value.data;
    out_values[STYLE_ASSET_COOKIE] = ApkAssetsCookieToJavaCookie(cookie);
    out_values[STYLE_RESOURCE_ID] = resid;
    out_values[STYLE_CHANGING_CONFIGURATIONS] = type_set_flags;
    out_values[STYLE_DENSITY] = config.density;

    if (out_indices != nullptr &&
        (value.dataType != Res_value::TYPE_NULL || value.data == Res_value::DATA_NULL_EMPTY)) {
      indices_idx++;
      out_indices[indices_idx] = ii;
    }

    out_values += STYLE_NUM_ENTRIES;
  }

  if (out_indices != nullptr) {
    out_indices[0] = indices_idx;
  }
  return true;
}
```
这里的逻辑和上面的obtainStyledAttributes十分相似。唯一不同的是，obtainStyledAttributes解析的是Xml中的属性。而这里不需要解析Xml的属性，而是直接通过BagAttributeFinder查找有没有对应的属性。obtainStyledAttributes当没有在Xml中找到也是通过BagAttributeFinder去查找默认的属性。而这个方法本质上就是ResolvedBag这个数组指针，迭代查找Theme中所有的属性中的值。

```java
  mAssets.resolveAttrs(mTheme, 0, 0, values, attrs, array.mData, array.mIndices);
```
resolveAttributes在Java层并没有传递默认的style以及attr，因此获取的是当前values中index对应的属性值。我之前试着使用这个方法获取的时候，也是出现了问题，找错了方法，看了源码之后才明白是怎么回事。

## 总结
总结资源查找的原理。对于AssetManager来说，资源大致分为两类：
- 1.非Asset文件夹下的资源 
- 2.Asset文件夹下的资源
- 3.查找Theme中的属性

对于非Asset文件夹下的资源来说，查找过程一般遵循如下流程：
- 1.解析资源ID，根据packageID从package_groups中获取到对应的PackageGroup，接着获取每一个Group当中对应的LoadPackage对象。

- 2.LoadPackage对象中保存着TypeSpec对象。这个对象保存着资源类型和资源类型内容之间的映射关系。Android系统为了加速资源加载提前把当前资源环境一直的资源另外放置在一个FilteredConfigGroup中。一旦发现是一致的环境则从这个快速通道进行查找，否则则进行全局的遍历。最后通过GetEntryFromOffset找到偏移数组并且赋值到TypedValue中

- 3.最后就可以从TypedValue读取数据。如果是布局这种大型文件，就会保存到native的Xml的解析器中，通过mmap的方式映射读取内存数据。


对于Asset文件夹下的文件来说，查找过程很简单一般遵循如下步骤:
- 1.为路径新增一个asset的路径前缀。
- 2.把zip数据流交给AssetInputStream 这个Stream对象处理


对于Theme中的属性，分为初始化Theme以及从Theme中查找2个步骤:
- 1.初始化Native下的Theme的时候，会通过ApplyStyle方法先解析当前的资源结构。通过FindEntry的方法和解析一个ResTable_entry对象出来.
- 2.拿到ResTable_entry之后，会通过起点加上该对象的大小能拿到对应的ResTable_map对象，而这个对象中就保存着ResTable_value，也就是资源的真实内容；接着循环从子资源一路向父资源查找所有的资源属性，子资源将会覆盖掉父资源并压缩到ResloveBag中；最后保存到cached_bags_缓存中。
- 3.最后底层的Theme对象，将会层层缓存，根据packageid，typeid，缓存下来。并遍历ResloveBag中所有的数据出处到Theme的entry数组中

- 4.当进行查找时候，将会解析当前Theme中保存下来的映射对象，并且返回到Java层。



## 后话
其实刚好这段时间在摆弄公司的基础库，抽离了一个ui公共库。经常接触这些资源解析，资源查找，因此也运气挺好的顺手写了这些东西，总结了之前的所用。

到这里，所有常规的资源查找方法就全部解析完毕。接下来，我会开启Android渲染体系的文章系列。