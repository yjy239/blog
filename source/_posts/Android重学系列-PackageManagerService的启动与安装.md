---
title: Android重学系列 PackageManagerService的启动与安装(上)
top: false
cover: false
date: 2020-08-22 22:40:15
img:
tag:
description:
author: yjy239
summary:
categories: PMS
tags:
- Android
- Android Framework
---

# 前言
PackageManagerService 是Android系统中对所有apk包的管理服务中心，之后我将成其为PMS。PMS除了管理所有已经安装好的apk包的数据，还包含了安装apk的服务，让我们一探究竟。

# 正文

## PMS的启动

PMS的启动，从SystemServer开始,更加详细的原理可以去[SystemServer到Home的启动](https://www.jianshu.com/p/a59068928590)下阅读：

/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/server/)/[SystemServer.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/java/com/android/server/SystemServer.java)

```java
    private void startBootstrapServices() {
...
        mPackageManagerService = PackageManagerService.main(mSystemContext, installer,
                mFactoryTestMode != FactoryTest.FACTORY_TEST_OFF, mOnlyCore);
        mFirstBoot = mPackageManagerService.isFirstBoot();
...

    }

    private void startOtherServices() {
...
        if (!mOnlyCore) {
            try {
                mPackageManagerService.updatePackagesIfNeeded();
            } catch (Throwable e) {
                reportWtf("update packages", e);
            }
            traceEnd();
        }
...
        try {
            mPackageManagerService.performFstrimIfNeeded();
        } catch (Throwable e) {
            reportWtf("performing fstrim", e);
        }
...
        mPackageManagerService.systemReady();
...
        mActivityManagerService.systemReady(() -> {
...
            mPackageManagerService.waitForAppDataPrepared();
...
       }
    }
```
在SystemServer的启动依照如下顺序：
- 1.PackageManagerService.main 将安装服务Intstaller传入，并实例化PMS
- 2.mPackageManagerService.updatePackagesIfNeeded
- 3.mPackageManagerService.performFstrimIfNeeded
- 4.mPackageManagerService. systemReady
- 5.mPackageManagerService. waitForAppDataPrepared

### PackageManagerService.main
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/)/[PackageManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/PackageManagerService.java)

```java
    public static PackageManagerService main(Context context, Installer installer,
            boolean factoryTest, boolean onlyCore) {

        PackageManagerService m = new PackageManagerService(context, installer,
                factoryTest, onlyCore);
        m.enableSystemUserPackages();
        ServiceManager.addService("package", m);
        final PackageManagerNative pmn = m.new PackageManagerNative();
        ServiceManager.addService("package_native", pmn);
        return m;
    }
```
在PMS的构造函数中，完成了两个对象的实例化，并加入到ServiceManager中。
- PackageManagerService
- PackageManagerNative PackageManagerNative 是PMS的Binder接口对象，我们可以不用看，主要看看PMS本身的实例化都做了什么。

#### PackageManagerService的实例化

整个构造函数方法很长，我们拆分为几段和大家聊聊：

```java
    public PackageManagerService(Context context, Installer installer,
            boolean factoryTest, boolean onlyCore) {
        LockGuard.installLock(mPackages, LockGuard.INDEX_PACKAGES);

        mContext = context;

        mFactoryTest = factoryTest;
        mOnlyCore = onlyCore;
        mMetrics = new DisplayMetrics();
        mInstaller = installer;

        // Create sub-components that provide services / data. Order here is important.
        synchronized (mInstallLock) {
        synchronized (mPackages) {
            // Expose private service for system components to use.
            LocalServices.addService(
                    PackageManagerInternal.class, new PackageManagerInternalImpl());
            sUserManager = new UserManagerService(context, this,
                    new UserDataPreparer(mInstaller, mInstallLock, mContext, mOnlyCore), mPackages);
            mPermissionManager = PermissionManagerService.create(context,
                    new DefaultPermissionGrantedCallback() {
                        @Override
                        public void onDefaultRuntimePermissionsGranted(int userId) {
                            synchronized(mPackages) {
                                mSettings.onDefaultRuntimePermissionsGrantedLPr(userId);
                            }
                        }
                    }, mPackages /*externalLock*/);
            mDefaultPermissionPolicy = mPermissionManager.getDefaultPermissionGrantPolicy();
            mSettings = new Settings(mPermissionManager.getPermissionSettings(), mPackages);
        }
        }
        mSettings.addSharedUserLPw("android.uid.system", Process.SYSTEM_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.phone", RADIO_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.log", LOG_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.nfc", NFC_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.bluetooth", BLUETOOTH_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.shell", SHELL_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);
        mSettings.addSharedUserLPw("android.uid.se", SE_UID,
                ApplicationInfo.FLAG_SYSTEM, ApplicationInfo.PRIVATE_FLAG_PRIVILEGED);

....

    }
```
- 1.实例化DisplayMetrics对象，这个对象出现过很多次，里面包含了Display的屏幕信息

- 2.实例化一个PackageManagerInternalImpl对象，这个对象将会作为本地的服务对外提供一些PMS的功能

- 3.实例化UserManagerService 用户管理服务。在Android系统中是一个多用户系统，每一个应用就代表一个用户。而这个服务其实就是管理每一个应用用户相关的权限和信息。

- 4.实例化PermissionManagerService 动态权限服务，所有的动态权限最终都会到这个服务下进行权限的设置操作，把权限相关的信息写入到一个名字为"package-perms-"+userId的文件中。

- 5.实例化一个关键的对象，Settings对象。这个对象管理了开机时候需要读取的文件，如记录每一个安装的apk包中所有组件的packages.list，如记录每一个应用动态权限文件。

- 6.Settings将会添加如下几个公共用户id:
  - SYSTEM_UID 系统
  - RADIO_UID 电话
  - LOG_UID 打印
  - NFC_UID NFC设备
  - BLUETOOTH_UID 蓝牙设备
  - SHELL_UID shell 命令
  - SE_UID selinux

```java
    public static final int SYSTEM_UID = 1000;
    public static final int PHONE_UID = 1001;
    public static final int SHELL_UID = 2000;
    public static final int LOG_UID = 1007;
    public static final int NFC_UID = 1027;
    public static final int BLUETOOTH_UID = 1002;
    public static final int SE_UID = 1068;
```

我们来看看核心对象Settings是怎么实现的。至于UserManagerService，PermissionManagerService等暂时不再讨论范围内。

##### Settings 初始化

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/)/[Settings.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/Settings.java)

```java
    Settings(PermissionSettings permissions, Object lock) {
        this(Environment.getDataDirectory(), permissions, lock);
    }

    Settings(File dataDir, PermissionSettings permission, Object lock) {
        mLock = lock;
        mPermissions = permission;
        mRuntimePermissionsPersistence = new RuntimePermissionPersistence(mLock);

        mSystemDir = new File(dataDir, "system");
        mSystemDir.mkdirs();
        FileUtils.setPermissions(mSystemDir.toString(),
                FileUtils.S_IRWXU|FileUtils.S_IRWXG
                |FileUtils.S_IROTH|FileUtils.S_IXOTH,
                -1, -1);
        mSettingsFilename = new File(mSystemDir, "packages.xml");
        mBackupSettingsFilename = new File(mSystemDir, "packages-backup.xml");
        mPackageListFilename = new File(mSystemDir, "packages.list");
        FileUtils.setPermissions(mPackageListFilename, 0640, SYSTEM_UID, PACKAGE_INFO_GID);

        final File kernelDir = new File("/config/sdcardfs");
        mKernelMappingFilename = kernelDir.exists() ? kernelDir : null;

        // Deprecated: Needed for migration
        mStoppedPackagesFilename = new File(mSystemDir, "packages-stopped.xml");
        mBackupStoppedPackagesFilename = new File(mSystemDir, "packages-stopped-backup.xml");
    }
```
- 1.整个PMS的Settings 也就是设置相关的文件都保存在根目录`/data` 文件夹下。

- 2.接着在data文件夹下创建一个system文件夹'/data/system'，并为这个文件夹设置只有本进程用户能读写执行，同一个进程用户组也能读写执行，其他进程组只能读或者执行，定义如下：
```java
    public static final int S_IRWXU = 00700;
    public static final int S_IRUSR = 00400;
    public static final int S_IWUSR = 00200;
    public static final int S_IXUSR = 00100;

    public static final int S_IRWXG = 00070;
    public static final int S_IRGRP = 00040;
    public static final int S_IWGRP = 00020;
    public static final int S_IXGRP = 00010;

    public static final int S_IRWXO = 00007;
    public static final int S_IROTH = 00004;
    public static final int S_IWOTH = 00002;
    public static final int S_IXOTH = 00001;
```
- 3.在'/data/system' 下创建一个配置文件`packages.xml`，以及一个备份的配置文件`packages-backup.xml`,该文件将会存储每一个apk包的java代码的文件夹以及so库的文件夹位置

- 4.创建缓存所有应用相关信息的`packages.list`文件，并且设置当前的权限是0640，也就是本进程用户能读写，同一个进程(用户)组只能读，其他进程没有任何权限.

- 5.判断`/config/sdcardfs`文件是否存在，存在则mKernelMappingFilename

- 6.`packages-stopped.xml`维护的是被停掉的应用,`packages-stopped-backup.xml`则是它的备份信息。

本文关注的重点是关于包存储信息`packages.list`以及`packages.xml`，我们扒一扒这文件中存储的是什么东西？


##### packages.list文件内容
注意在Android 9.0中，已经没有权限打开这个权限。因此我将打开低版本Android 4.3中缓存的数据作为例子：
这里是`packages.list`文件内容：
```
com.google.android.location 10018 0 /data/data/com.google.android.location default
com.android.soundrecorder 10038 0 /data/data/com.android.soundrecorder release
com.android.sdksetup 10036 0 /data/data/com.android.sdksetup platform
com.android.defcontainer 10010 0 /data/data/com.android.defcontainer platform
com.android.launcher 10022 0 /data/data/com.android.launcher shared
com.android.smoketest 10047 0 /data/data/com.android.smoketest default
com.android.quicksearchbox 10035 0 /data/data/com.android.quicksearchbox shared
com.android.contacts 10000 0 /data/data/com.android.contacts shared
....
```
能看到在`packages.list`可以把这个数据分为如下几个部分：
- `com.google.android.location` 包名
- `10018` 这个应用对应的userId，也正是因为记录当前的userId，所以每一次才能保证userId是一致的，保证了在Android系统中可以通过userId正确的找到应用
- `0`当前是否是debug模式，由AndroidManifest.xml中是否设置了`android:debuggable`
- `/data/data/com.google.android.location` 确定了当前的应用存储数据的目录
- `default` / `release` / `platform` / `shared` 这些字符串为在`mac_permission.xml`为每一个进程定义好的seinfo标签，seinfo不是描述文件的安全性，而是用来在`seapp_contexts`文件中查找对应的类型对象。

mac_permission.xml如下设置：
```
<signer signature="@PLATFORM" >
  <seinfo value="platform" />
</signer>

<!-- Media key in AOSP -->
<signer signature="@MEDIA" >
  <seinfo value="media" />
</signer>
```

那么在seapp_contexts文件中有:
···java
user=_app seinfo=platform domain=platform_app type=app_data_file levelFrom=user
···

当 PackageManagerService 安装 App 的时候，它就会根据其签名或者包名查找到对应的 seinfo，并且将这个 seinfo 传递给另外一个守护进程 installed。

这部分属于SELinux的内容了，感兴趣的可以去阅读这一篇文章：[SELinux的介绍](https://blog.csdn.net/qq_19923217/article/details/81240027)。总之一句话就是，SELinux就是控制了不同权限的资源只能由对应的不同权限的进程才能访问。


##### packages.xml 内容
```java
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<packages>
  <version sdkVersion="xx" databaseVersion="xx" fingerprint="xxx" />
  <version volumeUuid="xxx" sdkVersion="xx" databaseVersion="xx" fingerprint="xxx"/>
  <permission-trees>
    ...
  </permission-trees>
  <permissions>
     ...
  </permissions>
  <package ...>
    ...
  </package>

  <shared-user ...>
    ...
  </shared-user>

<packages>
```

在packages大标签中，分为如下几个部分：
- permissions  里面包含如`<item name="android.permission.ACCESS_NETWORK_STATE" package="android" />` 。permissions定义了所有在Android系统中当前的系统和App权限。可以分为两个两类：系统和App应用拥有的权限

- package 代表了每一个安装在系统中App的应用。
```xml
   <package name="com.google.android.location" codePath="/system/app/NetworkLocation.apk" nativeLibraryPath="/data/app-lib/NetworkLocation" flags="4767301" ft="15b3647e0e0" it="15b3647e0e0" ut="15b3647e0e0" version="1110" sharedUserId="10018">
        <sigs count="1">
            <cert index="0" key="30820...." />
        </sigs>
    </package>
```
该package标签包含了如下内容：
  - 1.`name` 包名
  - 2.`codePath` apk安装路径.主要是`/system/app`和`/data/app`两种
  - 3.`nativeLibraryPath` 是so文件保存的位置
  - 4.`userId` 是当前应用的userId
  - 5.`sigs` 签名内容

- shared-user标签包含如下内容
```
    <shared-user name="com.google.android.apps.maps" userId="10026">
        <sigs count="1">
            <cert index="0" />
        </sigs>
        <perms>
            <item name="android.permission.NFC" />
            <item name="android.permission.READ_EXTERNAL_STORAGE" />
            <item name="android.permission.USE_CREDENTIALS" />
            <item name="android.permission.WRITE_EXTERNAL_STORAGE" />
            <item name="android.permission.ACCESS_WIFI_STATE" />
            <item name="android.permission.ACCESS_COARSE_LOCATION" />
            <item name="android.permission.GET_ACCOUNTS" />
            <item name="com.google.android.providers.gsf.permission.READ_GSERVICES" />
            <item name="android.permission.DISABLE_KEYGUARD" />
            <item name="android.permission.INTERNET" />
            <item name="android.permission.ACCESS_FINE_LOCATION" />
            <item name="android.permission.MANAGE_ACCOUNTS" />
            <item name="android.permission.VIBRATE" />
            <item name="android.permission.ACCESS_NETWORK_STATE" />
        </perms>
    </shared-user>
```
`shared-user`这标签就是指能够访问共享的进程。 `com.google.android.apps.maps`就是这个共享进程的包名，userId 是指当前进程的userId，以及perms是指这个进程中的权限


#### PMS实例化第二段

```java
        mPackageDexOptimizer = new PackageDexOptimizer(installer, mInstallLock, context,
                "*dexopt*");
        DexManager.Listener dexManagerListener = DexLogger.getListener(this,
                installer, mInstallLock);
        mDexManager = new DexManager(mContext, this, mPackageDexOptimizer, installer, mInstallLock,
                dexManagerListener);
        mArtManagerService = new ArtManagerService(mContext, this, installer, mInstallLock);
        mMoveCallbacks = new MoveCallbacks(FgThread.get().getLooper());

        mOnPermissionChangeListeners = new OnPermissionChangeListeners(
                FgThread.get().getLooper());

        getDefaultDisplayMetrics(context, mMetrics);


        SystemConfig systemConfig = SystemConfig.getInstance();
        mAvailableFeatures = systemConfig.getAvailableFeatures();


        mProtectedPackages = new ProtectedPackages(mContext);

        synchronized (mInstallLock) {

        synchronized (mPackages) {
            mHandlerThread = new ServiceThread(TAG,
                    Process.THREAD_PRIORITY_BACKGROUND, true /*allowIo*/);
            mHandlerThread.start();
            mHandler = new PackageHandler(mHandlerThread.getLooper());
            mProcessLoggingHandler = new ProcessLoggingHandler();
            Watchdog.getInstance().addThread(mHandler, WATCHDOG_TIMEOUT);
            mInstantAppRegistry = new InstantAppRegistry(this);

            ArrayMap<String, String> libConfig = systemConfig.getSharedLibraries();
            final int builtInLibCount = libConfig.size();
            for (int i = 0; i < builtInLibCount; i++) {
                String name = libConfig.keyAt(i);
                String path = libConfig.valueAt(i);
                addSharedLibraryLPw(path, null, name, SharedLibraryInfo.VERSION_UNDEFINED,
                        SharedLibraryInfo.TYPE_BUILTIN, PLATFORM_PACKAGE_NAME, 0);
            }

            SELinuxMMAC.readInstallPolicy();


            FallbackCategoryProvider.loadFallbacks();


            mFirstBoot = !mSettings.readLPw(sUserManager.getUsers(false));

            final int packageSettingCount = mSettings.mPackages.size();
            for (int i = packageSettingCount - 1; i >= 0; i--) {
                PackageSetting ps = mSettings.mPackages.valueAt(i);
                if (!isExternal(ps) && (ps.codePath == null || !ps.codePath.exists())
                        && mSettings.getDisabledSystemPkgLPr(ps.name) != null) {
                    mSettings.mPackages.removeAt(i);
                    mSettings.enableSystemPackageLPw(ps.name);
                }
            }

            if (mFirstBoot) {
                requestCopyPreoptedFiles();
            }

....       
...
```
- 1.构造了一个PackageDexOptimizer对象，这个对象将会操作Installer对象，对dex文件进行优化成odex文件。odex文件是经过dex文件的优化，进行一些提前的校验，切换18种指令为更加高效的指令，构建vtable 虚方法table等。之后有机会会解析dex2oat,实际上其实dex2oat 几乎也完成了dexopt的工作。

- 2.构造了DexManager对象，用于控制PackageDexOptimizer对象,是Dex优化管理器。

- 3.构建ArtManagerService对象，这是一个Binder对象。开放给其他服务,在运行时进行art编译处理。

- 4.创建一个ServiceThread对象，这是一个HandlerThread对象。这就是一个带着Looper的线程，可以把Looper赋值给PackageHandler，创建PMS中的异步线程Handler对象。

- 5.创建一个WatchDog，监听PMS的死锁等情况

- 6.从系统配置systemConfig中，获取系统允许共享出来的共享库，保存在mSharedLibraries中。

- 7.调用readLPw读取保存在系统中所有安装的packages.xml的包中所有的信息，通过返回值确定是否是第一次启动PMS。读取完所有的所有的包后，从Settings的包集合判断这些包中是否还包含代码路径，调用enableSystemPackageLPw方法，处理是否是保存在mDisabledSysPackages集合中，也就是禁止使用的系统应用，如果存在则重新添加，不存则返回。

- 8.如果是第一次启动PMS，则调用requestCopyPreoptedFiles方法。

核心方法是readLPw。

##### Settings readLPw
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/)/[Settings.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/Settings.java)
```java
    boolean readLPw(@NonNull List<UserInfo> users) {
        FileInputStream str = null;
        if (mBackupSettingsFilename.exists()) {
            try {
                str = new FileInputStream(mBackupSettingsFilename);
                mReadMessages.append("Reading from backup settings file\n");
                PackageManagerService.reportSettingsProblem(Log.INFO,
                        "Need to read from backup settings file");
                if (mSettingsFilename.exists()) {

                    mSettingsFilename.delete();
                }
            } catch (java.io.IOException e) {
                // We'll try for the normal settings file.
            }
        }

        mPendingPackages.clear();
        mPastSignatures.clear();
        mKeySetRefs.clear();
        mInstallerPackages.clear();

        try {
            if (str == null) {
                if (!mSettingsFilename.exists()) {
                    mReadMessages.append("No settings file found\n");
                    PackageManagerService.reportSettingsProblem(Log.INFO,
                            "No settings file; creating initial state");

                    findOrCreateVersion(StorageManager.UUID_PRIVATE_INTERNAL).forceCurrent();
                    findOrCreateVersion(StorageManager.UUID_PRIMARY_PHYSICAL).forceCurrent();
                    return false;
                }
                str = new FileInputStream(mSettingsFilename);
            }
            XmlPullParser parser = Xml.newPullParser();
            parser.setInput(str, StandardCharsets.UTF_8.name());

            int type;
            while ((type = parser.next()) != XmlPullParser.START_TAG
                    && type != XmlPullParser.END_DOCUMENT) {
                ;
            }

            if (type != XmlPullParser.START_TAG) {
...
                return false;
            }

            int outerDepth = parser.getDepth();
            while ((type = parser.next()) != XmlPullParser.END_DOCUMENT
                    && (type != XmlPullParser.END_TAG || parser.getDepth() > outerDepth)) {
                if (type == XmlPullParser.END_TAG || type == XmlPullParser.TEXT) {
                    continue;
                }

                String tagName = parser.getName();
                if (tagName.equals("package")) {
                    readPackageLPw(parser);
                } else if (tagName.equals("permissions")) {
...
                } else if (tagName.equals("permission-trees")) {
...
                } else if (tagName.equals("shared-user")) {
...
                } else if (tagName.equals("preferred-packages")) {
                } else if (tagName.equals("preferred-activities")) {

...
                } else if (tagName.equals(TAG_PERSISTENT_PREFERRED_ACTIVITIES)) {
...
                } else if (tagName.equals(TAG_CROSS_PROFILE_INTENT_FILTERS)) {
                 ...
                } else if (tagName.equals(TAG_DEFAULT_BROWSER)) {
...
                } else if (tagName.equals("updated-package")) {
...
                } else if (tagName.equals("cleaning-package")) {
....
                } else if (tagName.equals("renamed-package")) {
....
                } else if (tagName.equals("restored-ivi")) {
....
                } else if (tagName.equals("last-platform-version")) {
....
                } else if (tagName.equals("database-version")) {
....
                } else if (tagName.equals("verifier")) {
...
                } else if (TAG_READ_EXTERNAL_STORAGE.equals(tagName)) {
...
                } else if (tagName.equals("keyset-settings")) {
...
                } else if (TAG_VERSION.equals(tagName)) {
...
                } else {
 ...
                }
            }

            str.close();

        } catch (XmlPullParserException e) {
     ...
        } catch (java.io.IOException e) {
...
        }

        if (PackageManagerService.CLEAR_RUNTIME_PERMISSIONS_ON_UPGRADE) {
            final VersionInfo internal = getInternalVersion();
            if (!Build.FINGERPRINT.equals(internal.fingerprint)) {
                for (UserInfo user : users) {
                    mRuntimePermissionsPersistence.deleteUserRuntimePermissionsFile(user.id);
                }
            }
        }

        final int N = mPendingPackages.size();

        for (int i = 0; i < N; i++) {
            final PackageSetting p = mPendingPackages.get(i);
            final int sharedUserId = p.getSharedUserId();
            final Object idObj = getUserIdLPr(sharedUserId);
            if (idObj instanceof SharedUserSetting) {
                final SharedUserSetting sharedUser = (SharedUserSetting) idObj;
                p.sharedUser = sharedUser;
                p.appId = sharedUser.userId;
                addPackageSettingLPw(p, sharedUser);
            } else if (idObj != null) {
         ...
            } else {
 ....
            }
        }
        mPendingPackages.clear();

        if (mBackupStoppedPackagesFilename.exists()
                || mStoppedPackagesFilename.exists()) {
            // Read old file
            readStoppedLPw();
            mBackupStoppedPackagesFilename.delete();
            mStoppedPackagesFilename.delete();
            // Migrate to new file format
            writePackageRestrictionsLPr(UserHandle.USER_SYSTEM);
        } else {
            for (UserInfo user : users) {
                readPackageRestrictionsLPr(user.id);
            }
        }

        for (UserInfo user : users) {
            mRuntimePermissionsPersistence.readStateForUserSyncLPr(user.id);
        }


        final Iterator<PackageSetting> disabledIt = mDisabledSysPackages.values().iterator();
        while (disabledIt.hasNext()) {
            final PackageSetting disabledPs = disabledIt.next();
            final Object id = getUserIdLPr(disabledPs.appId);
            if (id != null && id instanceof SharedUserSetting) {
                disabledPs.sharedUser = (SharedUserSetting) id;
            }
        }

        mReadMessages.append("Read completed successfully: " + mPackages.size() + " packages, "
                + mSharedUsers.size() + " shared uids\n");

        writeKernelMappingLPr();

        return true;
    }
```
- 1.首先尝试的查找是否有备份的package.xml数据，存在则说明可能发生过错误，则读取备份文件中的FileStream。并删除了package.xml原来文件

- 2.不存备份文件，则直接读取packages.xml的FileStream。

- 3.在这个过程中，就能看到就是一个简单的解析xml文件的过程，每遇到一个标签就进行对应的解析行为。如package信息，权限信息等。

- 解析完所有的信息后，并开始处理mPendingPackages数据。最后再检测是否存在备份文件或者packages-stopped.xml ，存在两者其一，则读取packages-stopped.xml中的数据，并把备份数据重新写入到新的packages.xml文件中。

值得注意的是解析标签`package`,在介些这个标签的时候执行了`readPackageLPw `方法对`package`标签进一步的解析：
```java
 else if (userId > 0) {
                packageSetting = addPackageLPw(name.intern(), realName, new File(codePathStr),
                        new File(resourcePathStr), legacyNativeLibraryPathStr, primaryCpuAbiString,
                        secondaryCpuAbiString, cpuAbiOverrideString, userId, versionCode, pkgFlags,
                        pkgPrivateFlags, parentPackageName, null /*childPackageNames*/,
                        null /*usesStaticLibraries*/, null /*usesStaticLibraryVersions*/);
...
                } else {
                    packageSetting.setTimeStamp(timeStamp);
                    packageSetting.firstInstallTime = firstInstallTime;
                    packageSetting.lastUpdateTime = lastUpdateTime;
                }
            }
```
调用addPackageLPw添加到缓存中。

###### addPackageLPw
```java
    PackageSetting addPackageLPw(String name, String realName, File codePath, File resourcePath,
            String legacyNativeLibraryPathString, String primaryCpuAbiString,
            String secondaryCpuAbiString, String cpuAbiOverrideString, int uid, long vc, int
            pkgFlags, int pkgPrivateFlags, String parentPackageName,
            List<String> childPackageNames, String[] usesStaticLibraries,
            long[] usesStaticLibraryNames) {
        PackageSetting p = mPackages.get(name);
        if (p != null) {
            if (p.appId == uid) {
                return p;
            }
            PackageManagerService.reportSettingsProblem(Log.ERROR,
                    "Adding duplicate package, keeping first: " + name);
            return null;
        }
        p = new PackageSetting(name, realName, codePath, resourcePath,
                legacyNativeLibraryPathString, primaryCpuAbiString, secondaryCpuAbiString,
                cpuAbiOverrideString, vc, pkgFlags, pkgPrivateFlags, parentPackageName,
                childPackageNames, 0 /*userId*/, usesStaticLibraries, usesStaticLibraryNames);
        p.appId = uid;
        if (addUserIdLPw(uid, p, name)) {
            mPackages.put(name, p);
            return p;
        }
        return null;
    }
```
很简单，就是根据当前的路径名，资源文件路径，代码文件路径，so库路径生成一个App应用PackageSetting的配置内存文件，保存到mPackages中。




#### PMS 实例化第三段

```java
            final String bootClassPath = System.getenv("BOOTCLASSPATH");
            final String systemServerClassPath = System.getenv("SYSTEMSERVERCLASSPATH");


            File frameworkDir = new File(Environment.getRootDirectory(), "framework");

            final VersionInfo ver = mSettings.getInternalVersion();
            mIsUpgrade = !Build.FINGERPRINT.equals(ver.fingerprint);


            mPromoteSystemApps =
                    mIsUpgrade && ver.sdkVersion <= Build.VERSION_CODES.LOLLIPOP_MR1;


            mIsPreNUpgrade = mIsUpgrade && ver.sdkVersion < Build.VERSION_CODES.N;

            mIsPreNMR1Upgrade = mIsUpgrade && ver.sdkVersion < Build.VERSION_CODES.N_MR1;


            if (mPromoteSystemApps) {
...
            }

            mCacheDir = preparePackageParserCache(mIsUpgrade);


            int scanFlags = SCAN_BOOTING | SCAN_INITIAL;

            if (mIsUpgrade || mFirstBoot) {
                scanFlags = scanFlags | SCAN_FIRST_BOOT_OR_UPGRADE;
            }


            scanDirTracedLI(new File(VENDOR_OVERLAY_DIR),
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_VENDOR,
                    0);
            scanDirTracedLI(new File(PRODUCT_OVERLAY_DIR),
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_PRODUCT,
                    0);

            mParallelPackageParserCallback.findStaticOverlayPackages();

    
            scanDirTracedLI(frameworkDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_NO_DEX
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_PRIVILEGED,
                    0);

            final File privilegedAppDir = new File(Environment.getRootDirectory(), "priv-app");
            scanDirTracedLI(privilegedAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_PRIVILEGED,
                    0);


            final File systemAppDir = new File(Environment.getRootDirectory(), "app");
            scanDirTracedLI(systemAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM,
                    0);

            File privilegedVendorAppDir = new File(Environment.getVendorDirectory(), "priv-app");
            try {
                privilegedVendorAppDir = privilegedVendorAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(privilegedVendorAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_VENDOR
                    | SCAN_AS_PRIVILEGED,
                    0);

            // Collect ordinary vendor packages.
            File vendorAppDir = new File(Environment.getVendorDirectory(), "app");
            try {
                vendorAppDir = vendorAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(vendorAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_VENDOR,
                    0);


            File privilegedOdmAppDir = new File(Environment.getOdmDirectory(),
                        "priv-app");
            try {
                privilegedOdmAppDir = privilegedOdmAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(privilegedOdmAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_VENDOR
                    | SCAN_AS_PRIVILEGED,
                    0);


            File odmAppDir = new File(Environment.getOdmDirectory(), "app");
            try {
                odmAppDir = odmAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(odmAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_VENDOR,
                    0);

            // Collect all OEM packages.
            final File oemAppDir = new File(Environment.getOemDirectory(), "app");
            scanDirTracedLI(oemAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_OEM,
                    0);

            File privilegedProductAppDir = new File(Environment.getProductDirectory(), "priv-app");
            try {
                privilegedProductAppDir = privilegedProductAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(privilegedProductAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_PRODUCT
                    | SCAN_AS_PRIVILEGED,
                    0);


            File productAppDir = new File(Environment.getProductDirectory(), "app");
            try {
                productAppDir = productAppDir.getCanonicalFile();
            } catch (IOException e) {
                // failed to look up canonical path, continue with original one
            }
            scanDirTracedLI(productAppDir,
                    mDefParseFlags
                    | PackageParser.PARSE_IS_SYSTEM_DIR,
                    scanFlags
                    | SCAN_AS_SYSTEM
                    | SCAN_AS_PRODUCT,
                    0);
```
解析来这一段的工作实际上就是给第三方厂商的提供的包名应用，提供的服务通过scanDirTracedLI方法，把整个包的数据解析扫描到PMS的内存。

这里就有如下几个大目录：
- 1.mCacheDir 首先通过preparePackageParserCache方法获取当前PMS下扫描结果的缓存目录：`/data/system/package_cache/` 所有的包扫描的结果都会缓存到这里

- 2.`/vendor/overlay`

- 3.`/product/overlay`  第2和第3点都是第三方厂商提供的资源复写目录

- 4.`/system/framework` Android系统framework层内置提供的java的核心jar包，odex等

- 5.`/system/priv-app`,`/system/app` ,这里面提供了Android系统或者厂商默认的系统应用

- 6.`/vendor/priv-app`,`/vendor/app` 这是交给硬件厂商的目录，允许他们内置内置一些系统应用服务。我之前常说的hal层，就是在这个vendor目录安装提供的。

- 7.`/odm/priv-app`,`/odm/app` 可以看作是vendor目录的一种延伸。

> 原始设计制造商 (ODM) 能够为其特定设备（开发板）自定义系统芯片 (SoC) 供应商板级支持包 (BSP).这样，他们就可以为板级组件、板级守护进程或者其基于硬件抽象层 (HAL) 的自有功能实现内核模块。他们可能还需要替换或自定义 SoC 组件。

我们不是搞hal层的，没必要进一步探讨了。

- 8.`/oem/app` ，`/product/priv-app`,`/product/app`  

> OEM 会自定义 AOSP 系统映像，以实现自己的功能并满足运营商的要求

product分区则是从Android 9.0开始支持的分区。oem是老版本的product分区，product可以依赖oem分区。product可以多次刷新，oem不可刷新只能出厂一次。这两个分区就是支持自定义 AOSP 系统映像，product的分区出现能够更加灵活多语言多地区的系统映像。

能发现每一个目录下，都调用了整个PMS最核心的方法scanDirTracedLI 对apk，jar包的解析方法。

scanDirTracedLI这个方法我们稍后再看，现在我们可以得知这个方法执行后，PMS就能知道安装apk包中具体的信息了，并把解析出来的PackageParser.Package对象保存在PMS全局变量mPackages中


#### PMS 第四段
```java

            final List<String> possiblyDeletedUpdatedSystemApps = new ArrayList<>();

            final List<String> stubSystemApps = new ArrayList<>();
            if (!mOnlyCore) {

                final Iterator<PackageParser.Package> pkgIterator = mPackages.values().iterator();
                while (pkgIterator.hasNext()) {
                    final PackageParser.Package pkg = pkgIterator.next();
                    if (pkg.isStub) {
                        stubSystemApps.add(pkg.packageName);
                    }
                }

                final Iterator<PackageSetting> psit = mSettings.mPackages.values().iterator();
                while (psit.hasNext()) {
                    PackageSetting ps = psit.next();

                    if ((ps.pkgFlags & ApplicationInfo.FLAG_SYSTEM) == 0) {
                        continue;
                    }

                    final PackageParser.Package scannedPkg = mPackages.get(ps.name);
                    if (scannedPkg != null) {

                        if (mSettings.isDisabledSystemPackageLPr(ps.name)) {

                            removePackageLI(scannedPkg, true);
                            mExpectingBetter.put(ps.name, ps.codePath);
                        }

                        continue;
                    }

                    if (!mSettings.isDisabledSystemPackageLPr(ps.name)) {
                        psit.remove();


                    } else {

                        final PackageSetting disabledPs =
                                mSettings.getDisabledSystemPkgLPr(ps.name);
                        if (disabledPs.codePath == null || !disabledPs.codePath.exists()
                                || disabledPs.pkg == null) {
                            possiblyDeletedUpdatedSystemApps.add(ps.name);
                        }
                    }
                }
            }

            //delete tmp files
            deleteTempPackageFiles();

...
            if (!mOnlyCore) {
                
                scanDirTracedLI(sAppInstallDir, 0, scanFlags | SCAN_REQUIRE_KNOWN, 0);

                scanDirTracedLI(sDrmAppPrivateInstallDir, mDefParseFlags
                        | PackageParser.PARSE_FORWARD_LOCK,
                        scanFlags | SCAN_REQUIRE_KNOWN, 0);

                for (String deletedAppName : possiblyDeletedUpdatedSystemApps) {
                    PackageParser.Package deletedPkg = mPackages.get(deletedAppName);
                    mSettings.removeDisabledSystemPackageLPw(deletedAppName);
                    final String msg;
                    if (deletedPkg == null) {

                    } else {

                        msg = "Updated system package + " + deletedAppName
                                + " no longer exists; revoking system privileges";


                        final PackageSetting deletedPs = mSettings.mPackages.get(deletedAppName);
                        deletedPkg.applicationInfo.flags &= ~ApplicationInfo.FLAG_SYSTEM;
                        deletedPs.pkgFlags &= ~ApplicationInfo.FLAG_SYSTEM;
                    }
                    logCriticalInfo(Log.WARN, msg);
                }


                for (int i = 0; i < mExpectingBetter.size(); i++) {
                    final String packageName = mExpectingBetter.keyAt(i);
                    if (!mPackages.containsKey(packageName)) {
                        final File scanFile = mExpectingBetter.valueAt(i);


                        final @ParseFlags int reparseFlags;
                        final @ScanFlags int rescanFlags;
                        if (FileUtils.contains(privilegedAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_PRIVILEGED;
                        } else if (FileUtils.contains(systemAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM;
                        } else if (FileUtils.contains(privilegedVendorAppDir, scanFile)
                                || FileUtils.contains(privilegedOdmAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_VENDOR
                                    | SCAN_AS_PRIVILEGED;
                        } else if (FileUtils.contains(vendorAppDir, scanFile)
                                || FileUtils.contains(odmAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_VENDOR;
                        } else if (FileUtils.contains(oemAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_OEM;
                        } else if (FileUtils.contains(privilegedProductAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_PRODUCT
                                    | SCAN_AS_PRIVILEGED;
                        } else if (FileUtils.contains(productAppDir, scanFile)) {
                            reparseFlags =
                                    mDefParseFlags |
                                    PackageParser.PARSE_IS_SYSTEM_DIR;
                            rescanFlags =
                                    scanFlags
                                    | SCAN_AS_SYSTEM
                                    | SCAN_AS_PRODUCT;
                        } else {
                            Slog.e(TAG, "Ignoring unexpected fallback path " + scanFile);
                            continue;
                        }

                        mSettings.enableSystemPackageLPw(packageName);

                        try {
                            scanPackageTracedLI(scanFile, reparseFlags, rescanFlags, 0, null);
                        } catch (PackageManagerException e) {
                            Slog.e(TAG, "Failed to parse original system package: "
                                    + e.getMessage());
                        }
                    }
                }

                decompressSystemApplications(stubSystemApps, scanFlags);

                final int cachedNonSystemApps = PackageParser.sCachedPackageReadCount.get()
                                - cachedSystemApps;

                final long dataScanTime = SystemClock.uptimeMillis() - systemScanTime - startTime;
                final int dataPackagesCount = mPackages.size() - systemPackagesCount;

                if (mIsUpgrade && dataPackagesCount > 0) {
                    MetricsLogger.histogram(null, "ota_package_manager_data_app_avg_scan_time",
                            ((int) dataScanTime) / dataPackagesCount);
                }
            }
            mExpectingBetter.clear();


            mStorageManagerPackage = getStorageManagerPackageName();


            mSetupWizardPackage = getSetupWizardPackageName();
            if (mProtectedFilters.size() > 0) {

                for (ActivityIntentInfo filter : mProtectedFilters) {
                    if (filter.activity.info.packageName.equals(mSetupWizardPackage)) {
   
                        continue;
                    }

                    filter.setPriority(0);
                }
            }

            mSystemTextClassifierPackage = getSystemTextClassifierPackageName();

            mDeferProtectedFilters = false;
            mProtectedFilters.clear();

            updateAllSharedLibrariesLPw(null);

....

            mPackageUsage.read(mPackages);
            mCompilerStats.read();

...

            mPrepareAppDataFuture = SystemServerInitThreadPool.get().submit(() -> {
                TimingsTraceLog traceLog = new TimingsTraceLog("SystemServerTimingAsync",
                        Trace.TRACE_TAG_PACKAGE_MANAGER);
                traceLog.traceBegin("AppDataFixup");
                try {
                    mInstaller.fixupAppData(StorageManager.UUID_PRIVATE_INTERNAL,
                            StorageManager.FLAG_STORAGE_DE | StorageManager.FLAG_STORAGE_CE);
                } catch (InstallerException e) {
                    Slog.w(TAG, "Trouble fixing GIDs", e);
                }
                traceLog.traceEnd();

                traceLog.traceBegin("AppDataPrepare");
                if (deferPackages == null || deferPackages.isEmpty()) {
                    return;
                }
                int count = 0;
                for (String pkgName : deferPackages) {
                    PackageParser.Package pkg = null;
                    synchronized (mPackages) {
                        PackageSetting ps = mSettings.getPackageLPr(pkgName);
                        if (ps != null && ps.getInstalled(UserHandle.USER_SYSTEM)) {
                            pkg = ps.pkg;
                        }
                    }
                    if (pkg != null) {
                        synchronized (mInstallLock) {
                            prepareAppDataAndMigrateLIF(pkg, UserHandle.USER_SYSTEM, storageFlags,
                                    true /* maybeMigrateAppData */);
                        }
                        count++;
                    }
                }
                traceLog.traceEnd();
                Slog.i(TAG, "Deferred reconcileAppsData finished " + count + " packages");
            }, "prepareAppData");

...
            mSettings.writeLPr();
...
            

            final Map<Integer, List<PackageInfo>> userPackages = new HashMap<>();
            final int[] currentUserIds = UserManagerService.getInstance().getUserIds();
            for (int userId : currentUserIds) {
                userPackages.put(userId, getInstalledPackages(/*flags*/ 0, userId).getList());
            }
            mDexManager.load(userPackages);
            if (mIsUpgrade) {
                MetricsLogger.histogram(null, "ota_package_manager_init_time",
                        (int) (SystemClock.uptimeMillis() - startTime));
            }
        } // synchronized (mPackages)
        } // synchronized (mInstallLock)


        Runtime.getRuntime().gc();

        mInstaller.setWarnIfHeld(mPackages);
```
- 1.扫描所以在上面安装好系统apk等文件，查找哪些系统禁止的包名，则调用removePackageLI从缓存中移除。删除所有的临时包文件

- 2.接下来扫描我们应用开发最重要的2个目录：`/data/app`,`/data/app-private`.

`/data/app` 是app安装的路径。所有的app都会安装到这个目录下，可以进进一步的通过对应的包名找到我们的apk应用中的代码等数据。`/data/app-private`这是每一个应用存储除了代码和资源的其他私密数据。


- 3.在扫描app安装目录之后，遍历possiblyDeletedUpdatedSystemApps，看看有没有那个apk是需要删除，则调用removeDisabledSystemPackageLPw 从系统配置中移除。这个possiblyDeletedUpdatedSystemApps集合就是系统设置的禁用包集合

- 4.扫描mExpectingBetter集合中保存的apk包。这个集合说明的是app中有更加新的版本，期望进行更新，所以会进行扫描替换原来的app应用

- 5.调用Settings的writeLPr方法。更新`package.list`中的安装包数据列表。

- 6.通过SystemServerInitThreadPool启动一个特殊的线程池，赋值为mPrepareAppDataFuture对象。执行了如下内容：
  - 1.调用了Installd的fixupAppData方法,创建一个`/data/user/用户id`和`/data/data`目录，这个目录由StoreManagerService进行管理。这里要和每一个应用的userId要区分开，其实是指登陆Android不同的用户。也就是我们常见的`/data/user/0`.`/data/user/用户id`是`/data/data`的软链接。不同的用户id只能访问到不同userid对应的app安装内容。可以认为其实每一个app安装的实际路径是`/data/user/用户ID/包名/`。而我们常见到的`/data/data/包名`其实是他的软连接。

  - 2.调用prepareAppDataAndMigrateLIF方法，准备应用数据。最终会调用到prepareAppDataLeafLIF方法中：

```java
  private void prepareAppDataLeafLIF(PackageParser.Package pkg, int userId, int flags) {
...
        try {
            ceDataInode = mInstaller.createAppData(volumeUuid, packageName, userId, flags,
                    appId, seInfo, app.targetSdkVersion);
        } catch (InstallerException e) {
        ....
        }

        if (mIsUpgrade || mFirstBoot || (userId != UserHandle.USER_SYSTEM)) {
            mArtManagerService.prepareAppProfiles(pkg, userId);
        }

...

        prepareAppDataContentsLeafLIF(pkg, userId, flags);
    }
```

   - 1.Installer的createAppData 实际上就是遍历所有的包名，为每一个包名创建一个`cache`以及`code_cache`的目录，用于缓存编译优化后的结果。

    - 2.prepareAppProfiles，这个方法最后调用了IInstalld的prepareAppProfile方法，并且调用保存在`/system/bin/profman` 这个程序，在程序目录下生成一个`.prof`文件，这个文件可以加速dex2oat编译优化的速度。

- 3.prepareAppDataContentsLeafLIF 核心就是调用了IInstalld的linkNativeLibraryDirectory。其实就是把app的安装so库的目录`/data/data/包名/lib`和`/data/user/用户id/包名/lib`链接上。


- 7.初始化数据存储服务，InstantApp的扫描，以及让DexManager检查持有每一个分配了用户id的应用的代码路径，保存在PackageDexUsage中。


到这里PMS的实例化，大体上都过了一遍，能看到实际上PMS就是在引导时候，把所有之后Android需要使用的代码包都进行了扫描，并且加载了所有包的配置等文件。其中扫描最为重要，扫描核心方法就是scanDirTracedLI。

暂且放一放，我们继续走PMS初始化流程，我们最后回头看看这个方法都做了什么？


### PMS updatePackagesIfNeeded
```java
    public void updatePackagesIfNeeded() {
        enforceSystemOrRoot("Only the system can request package update");


        boolean causeUpgrade = isUpgrade();


        boolean causeFirstBoot = isFirstBoot() || mIsPreNUpgrade;


        boolean causePrunedCache = VMRuntime.didPruneDalvikCache();

        if (!causeUpgrade && !causeFirstBoot && !causePrunedCache) {
            return;
        }

        List<PackageParser.Package> pkgs;
        synchronized (mPackages) {
            pkgs = PackageManagerServiceUtils.getPackagesForDexopt(mPackages.values(), this);
        }

        final long startTime = System.nanoTime();
        final int[] stats = performDexOptUpgrade(pkgs, mIsPreNUpgrade /* showDialog */,
                    causeFirstBoot ? REASON_FIRST_BOOT : REASON_BOOT,
                    false /* bootComplete */);
...
    }
```
这里面做了两件事情：
- 1.PackageManagerServiceUtils的getPackagesForDexopt方法，对需要在开机时候进行dexopt优化的apk包进行优化。此时会对PMS有一个dex优化的优先级顺序，其顺序依次为：
  - 1.coreApp 也就是系统核心app服务的包最早进行优化
  - 2.其次是哪些需要接受`Intent.ACTION_PRE_BOOT_COMPLETED`的广播接受者对应的apk包
  - 3.还有被前两种apk依赖的代码 apk包

- 2.最终循环调用performDexOptUpgrade。其中PackageDexOptimizer对象的performDexOpt方法。这个方法最终会调用Installer的dexopt方法，通知Intsalld服务，也是一个Binder对象，跨进程通信到Intsalld服务执行dexopt，对dex文件进行优化

更加详细的超出本文讨论范围，之后有空在聊dex2oat的时候一起聊了。


### PMS performFstrimIfNeeded
```java
    public void performFstrimIfNeeded() {
        enforceSystemOrRoot("Only the system can request fstrim");

        try {
            IStorageManager sm = PackageHelper.getStorageManager();
            if (sm != null) {
                boolean doTrim = false;
                final long interval = android.provider.Settings.Global.getLong(
                        mContext.getContentResolver(),
                        android.provider.Settings.Global.FSTRIM_MANDATORY_INTERVAL,
                        DEFAULT_MANDATORY_FSTRIM_INTERVAL);
                if (interval > 0) {
                    final long timeSinceLast = System.currentTimeMillis() - sm.lastMaintenance();
                    if (timeSinceLast > interval) {
                        doTrim = true;
                    }
                }
                if (doTrim) {
                    final boolean dexOptDialogShown;
                    synchronized (mPackages) {
                        dexOptDialogShown = mDexOptDialogShown;
                    }
                    if (!isFirstBoot() && dexOptDialogShown) {
                        try {
                            ActivityManager.getService().showBootMessage(
                                    mContext.getResources().getString(
                                            R.string.android_upgrading_fstrim), true);
                        } catch (RemoteException e) {
                        }
                    }
                    sm.runMaintenance();
                }
            } else {

            }
        } catch (RemoteException e) {

        }
    }

```
这里只做了一件事情：获取StorageManagerService对象，判断此时的时间和上一次操作Android系统的存储磁盘最晚的时间差是多少。默认是超过了3天，则调用StorageManagerService的runMaintenance方法，删除哪些不再有效的数据(注意在操作系统中，文件删除不是立即从磁盘中删除，而是把磁盘中的block中的数据，打上一个标记允许其他数据覆盖)。 之后有机会，会在Linux内核中和大家聊聊整个Linux如何管理磁盘的。


### PMS systemReady
```java
    public void systemReady() {
        enforceSystemOrRoot("Only the system can claim the system is ready");

        mSystemReady = true;
        final ContentResolver resolver = mContext.getContentResolver();
        ContentObserver co = new ContentObserver(mHandler) {
            @Override
            public void onChange(boolean selfChange) {
                mWebInstantAppsDisabled =
                        (Global.getInt(resolver, Global.ENABLE_EPHEMERAL_FEATURE, 1) == 0) ||
                                (Secure.getInt(resolver, Secure.INSTANT_APPS_ENABLED, 1) == 0);
            }
        };
        mContext.getContentResolver().registerContentObserver(android.provider.Settings.Global
                        .getUriFor(Global.ENABLE_EPHEMERAL_FEATURE),
                false, co, UserHandle.USER_SYSTEM);
        mContext.getContentResolver().registerContentObserver(android.provider.Settings.Secure
                        .getUriFor(Secure.INSTANT_APPS_ENABLED), false, co, UserHandle.USER_SYSTEM);
        co.onChange(true);
...
        sUserManager.systemReady();
        // If we upgraded grant all default permissions before kicking off.
        for (int userId : grantPermissionsUserIds) {
            mDefaultPermissionPolicy.grantDefaultPermissions(userId);
        }

        if (grantPermissionsUserIds == EMPTY_INT_ARRAY) {
mDefaultPermissionPolicy.scheduleReadDefaultPermissionExceptions();
        }


        synchronized (mPackages) {
            mPermissionManager.updateAllPermissions(
                    StorageManager.UUID_PRIVATE_INTERNAL, false, mPackages.values(),
                    mPermissionCallback);
        }

        // Kick off any messages waiting for system ready
        if (mPostSystemReadyMessages != null) {
            for (Message msg : mPostSystemReadyMessages) {
                msg.sendToTarget();
            }
            mPostSystemReadyMessages = null;
        }

        // Watch for external volumes that come and go over time
        final StorageManager storage = mContext.getSystemService(StorageManager.class);
        storage.registerListener(mStorageListener);

        mInstallerService.systemReady();
        mDexManager.systemReady();
        mPackageDexOptimizer.systemReady();

        StorageManagerInternal StorageManagerInternal = LocalServices.getService(
                StorageManagerInternal.class);
        StorageManagerInternal.addExternalStoragePolicy(
                new StorageManagerInternal.ExternalStorageMountPolicy() {
            @Override
            public int getMountMode(int uid, String packageName) {
                if (Process.isIsolated(uid)) {
                    return Zygote.MOUNT_EXTERNAL_NONE;
                }
                if (checkUidPermission(READ_EXTERNAL_STORAGE, uid) == PERMISSION_DENIED) {
                    return Zygote.MOUNT_EXTERNAL_DEFAULT;
                }
                if (checkUidPermission(WRITE_EXTERNAL_STORAGE, uid) == PERMISSION_DENIED) {
                    return Zygote.MOUNT_EXTERNAL_READ;
                }
                return Zygote.MOUNT_EXTERNAL_WRITE;
            }

            @Override
            public boolean hasExternalStorage(int uid, String packageName) {
                return true;
            }
        });

        // Now that we're mostly running, clean up stale users and apps
        sUserManager.reconcileUsers(StorageManager.UUID_PRIVATE_INTERNAL);
        reconcileApps(StorageManager.UUID_PRIVATE_INTERNAL);

        mPermissionManager.systemReady();

        if (mInstantAppResolverConnection != null) {
            mContext.registerReceiver(new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    mInstantAppResolverConnection.optimisticBind();
                    mContext.unregisterReceiver(this);
                }
            }, new IntentFilter(Intent.ACTION_BOOT_COMPLETED));
        }
    }
```
- 1.设置了两个两个CP组件的数据变化监听者，分别是`Global.ENABLE_EPHEMERAL_FEATURE`以及`Secure.INSTANT_APPS_ENABLED`  

```java
public static final String ENABLE_EPHEMERAL_FEATURE = "enable_ephemeral_feature"
public static final String INSTANT_APPS_ENABLED = "instant_apps_enabled"
```

这两个标志位共同决定了mWebInstantAppsDisabled 也就是Web的InstantApp是否可以生效。

- 2.调用UserManager的systemReady

- 3.注册了StorageManager的监听

- 4.PackageInstallerService 的systemReady

- 5.DexManager的systemReady

- 6.PackageDexOptimizer的systemReady

- 7.PermissionManagerService的systemReady

- 8.注册一个`Intent.ACTION_BOOT_COMPLETED` 系统系统启动完成的广播


### PMS waitForAppDataPrepared
当AMS调用了systemReady之后，说明Android系统其实可以启动第一个App也就是桌面应用了，但是此时会调用waitForAppDataPrepared等待PMS的一些事务完成。
```java
    public void waitForAppDataPrepared() {
        if (mPrepareAppDataFuture == null) {
            return;
        }
        ConcurrentUtils.waitForFutureNoInterrupt(mPrepareAppDataFuture, "wait for prepareAppData");
        mPrepareAppDataFuture = null;
    }
```
其实就是等待mPrepareAppDataFuture的完成。而这个对象在PMS的实例化小结聊过，其实就是为每一个应用包创建对应的软连接和目录。


### PMS scanDirTracedLI 扫描应用的原理
对于PMS的启动有了一个总体的概括之后，我们来看看PMS中最为的核心方法没有之一的scanDirTracedLI中做了什么？怎么解析apk包的。
```java
    private void scanDirLI(File scanDir, int parseFlags, int scanFlags, long currentTime) {
        final File[] files = scanDir.listFiles();

        try (ParallelPackageParser parallelPackageParser = new ParallelPackageParser(
                mSeparateProcesses, mOnlyCore, mMetrics, mCacheDir,
                mParallelPackageParserCallback)) {
            // Submit files for parsing in parallel
            int fileCount = 0;
            for (File file : files) {
                final boolean isPackage = (isApkFile(file) || file.isDirectory())
                        && !PackageInstallerService.isStageName(file.getName());
                if (!isPackage) {
                    // Ignore entries which are not packages
                    continue;
                }
                parallelPackageParser.submit(file, parseFlags);
                fileCount++;
            }

            for (; fileCount > 0; fileCount--) {
                ParallelPackageParser.ParseResult parseResult = parallelPackageParser.take();
                Throwable throwable = parseResult.throwable;
                int errorCode = PackageManager.INSTALL_SUCCEEDED;

                if (throwable == null) {

                    if (parseResult.pkg.applicationInfo.isStaticSharedLibrary()) {
                        renameStaticSharedLibraryPackage(parseResult.pkg);
                    }
                    try {
                        if (errorCode == PackageManager.INSTALL_SUCCEEDED) {
                            scanPackageChildLI(parseResult.pkg, parseFlags, scanFlags,
                                    currentTime, null);
                        }
                    } catch (PackageManagerException e) {
...
                    }
                } else if (throwable instanceof PackageParser.PackageParserException) {
                    PackageParser.PackageParserException e = (PackageParser.PackageParserException)
                            throwable;
                    errorCode = e.error;

                } else {
...
                }

                // Delete invalid userdata apps
                if ((scanFlags & SCAN_AS_SYSTEM) == 0 &&
                        errorCode != PackageManager.INSTALL_SUCCEEDED) {
                    removeCodePathLI(parseResult.scanFile);
                }
            }
        }
    }
```
- 把mCacheDir作为参数，构造了一个ParallelPackageParser 并行执行的包解析器。
```java
class ParallelPackageParser implements AutoCloseable {

    private static final int QUEUE_CAPACITY = 10;
    private static final int MAX_THREADS = 4;

    private final String[] mSeparateProcesses;
    private final boolean mOnlyCore;
    private final DisplayMetrics mMetrics;
    private final File mCacheDir;
    private final PackageParser.Callback mPackageParserCallback;
    private volatile String mInterruptedInThread;

    private final BlockingQueue<ParseResult> mQueue = new ArrayBlockingQueue<>(QUEUE_CAPACITY);

    private final ExecutorService mService = ConcurrentUtils.newFixedThreadPool(MAX_THREADS,
            "package-parsing-thread", Process.THREAD_PRIORITY_FOREGROUND);

    ParallelPackageParser(String[] separateProcesses, boolean onlyCoreApps,
            DisplayMetrics metrics, File cacheDir, PackageParser.Callback callback) {
        mSeparateProcesses = separateProcesses;
        mOnlyCore = onlyCoreApps;
        mMetrics = metrics;
        mCacheDir = cacheDir;
        mPackageParserCallback = callback;
    }
```
能看到在ParallelPackageParser中存在一个名字为`package-parsing-thread`的线程池，而这个线程吃最大并行数量为4.以及一个ArrayBlockingQueue，这个同步阻塞队列大小为10.

- 2.遍历该目录所有的文件，如果判断是可以进行解析的apk包，则调用submit方法，为ParallelPackageParser提交一个解析任务。
```java
    public void submit(File scanFile, int parseFlags) {
        mService.submit(() -> {
            ParseResult pr = new ParseResult();
            try {
                PackageParser pp = new PackageParser();
                pp.setSeparateProcesses(mSeparateProcesses);
                pp.setOnlyCoreApps(mOnlyCore);
                pp.setDisplayMetrics(mMetrics);
                pp.setCacheDir(mCacheDir);
                pp.setCallback(mPackageParserCallback);
                pr.scanFile = scanFile;
                pr.pkg = parsePackage(pp, scanFile, parseFlags);
            } catch (Throwable e) {
                ...
            } finally {
               ...
            }
            try {
                mQueue.put(pr);
            } catch (InterruptedException e) {
...
            }
        });
    }
```
当在线程中开始执行的时候，就会实例化一个新的PackageParser对象，并且调用parsePackage方法执行解析，最后把解析的结果放在ArrayBlockingQueue中，等待获取。ArrayBlockingQueue这个队列很简单，就是一个生产者消费者模式，当没数据想取出的时候会被阻塞，等到数据加入后唤醒。当想要放入任务进行消费，但是满了，就会阻塞不允许放入任务。

而parsePackage方法会调用PackageParser.parsePackage.


#### PackageParser parsePackage
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/)/[PackageParser.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/PackageParser.java)
```java
    public Package parsePackage(File packageFile, int flags, boolean useCaches)
            throws PackageParserException {
        Package parsed = useCaches ? getCachedResult(packageFile, flags) : null;
        if (parsed != null) {
            return parsed;
        }

        if (packageFile.isDirectory()) {
            parsed = parseClusterPackage(packageFile, flags);
        } else {
            parsed = parseMonolithicPackage(packageFile, flags);
        }

        long cacheTime = LOG_PARSE_TIMINGS ? SystemClock.uptimeMillis() : 0;
        cacheResult(packageFile, flags, parsed);
...
        }
        return parsed;
    }
```
- 1.首先尝试的通过getCachedResult获取是否已经有解析好的缓存数据，有则直接返回Package
- 2.没有缓存，则判断当前的packageFile是文件夹还是文件：
  - 1.是文件夹则调用parseClusterPackage方法
  - 2.是文件则调用parseMonolithicPackage方法
- 3.最后通过cacheResult 缓存下来。

我们先跳过缓存的逻辑看看PackageParser是怎么解析的。由于一般存在`data/app`下都是一个apk文件，所以我们以parseMonolithicPackage为例子

##### PackageParser parseMonolithicPackage
```java
    public Package parseMonolithicPackage(File apkFile, int flags) throws PackageParserException {
        final PackageLite lite = parseMonolithicPackageLite(apkFile, flags);
....

        final SplitAssetLoader assetLoader = new DefaultSplitAssetLoader(lite, flags);
        try {
            final Package pkg = parseBaseApk(apkFile, assetLoader.getBaseAssetManager(), flags);
            pkg.setCodePath(apkFile.getCanonicalPath());
            pkg.setUse32bitAbi(lite.use32bitAbi);
            return pkg;
        } catch (IOException e) {
...
        } finally {
            IoUtils.closeQuietly(assetLoader);
        }
    }
```
先构造一个DefaultSplitAssetLoader对象，这个对象实际上就是通过ApkAssets进行解析，并获取AssetsManager对象。关于AssetsManager相关的原理可以阅读[ 资源管理系统系列文章](https://www.jianshu.com/p/817a787910f2)。

调用parseBaseApk解析apk.

##### PackageParser parseBaseApk
```java
  public static final String ANDROID_MANIFEST_FILENAME = "AndroidManifest.xml";
    private Package parseBaseApk(File apkFile, AssetManager assets, int flags)
            throws PackageParserException {
        final String apkPath = apkFile.getAbsolutePath();

        String volumeUuid = null;
        if (apkPath.startsWith(MNT_EXPAND)) {
            final int end = apkPath.indexOf('/', MNT_EXPAND.length());
            volumeUuid = apkPath.substring(MNT_EXPAND.length(), end);
        }

        mParseError = PackageManager.INSTALL_SUCCEEDED;
        mArchiveSourcePath = apkFile.getAbsolutePath();


        XmlResourceParser parser = null;
        try {
            final int cookie = assets.findCookieForPath(apkPath);
...
            parser = assets.openXmlResourceParser(cookie, ANDROID_MANIFEST_FILENAME);
            final Resources res = new Resources(assets, mMetrics, null);

            final String[] outError = new String[1];
            final Package pkg = parseBaseApk(apkPath, res, parser, flags, outError);
...

            pkg.setVolumeUuid(volumeUuid);
            pkg.setApplicationVolumeUuid(volumeUuid);
            pkg.setBaseCodePath(apkPath);
            pkg.setSigningDetails(SigningDetails.UNKNOWN);

            return pkg;

        } catch (PackageParserException e) {
...
        } catch (Exception e) {
...
        } finally {
            IoUtils.closeQuietly(parser);
        }
    }
```
很简单，就是通过findCookieForPath找到apk缓存对应的cookieId，并以此为索引，调用AssetManager.openXmlResourceParser方法，打开AndroidManifest.xml的流，等待后面parseBaseApk的解析


##### parseBaseApk
```java
    private Package parseBaseApk(String apkPath, Resources res, XmlResourceParser parser, int flags,
            String[] outError) throws XmlPullParserException, IOException {
        final String splitName;
        final String pkgName;

        try {
            Pair<String, String> packageSplit = parsePackageSplitNames(parser, parser);
            pkgName = packageSplit.first;
            splitName = packageSplit.second;

            if (!TextUtils.isEmpty(splitName)) {
...
                return null;
            }
        } catch (PackageParserException e) {
...
            return null;
        }

        if (mCallback != null) {
            String[] overlayPaths = mCallback.getOverlayPaths(pkgName, apkPath);
            if (overlayPaths != null && overlayPaths.length > 0) {
                for (String overlayPath : overlayPaths) {
                    res.getAssets().addOverlayPath(overlayPath);
                }
            }
        }

        final Package pkg = new Package(pkgName);

        TypedArray sa = res.obtainAttributes(parser,
                com.android.internal.R.styleable.AndroidManifest);

        pkg.mVersionCode = sa.getInteger(
                com.android.internal.R.styleable.AndroidManifest_versionCode, 0);
        pkg.mVersionCodeMajor = sa.getInteger(
                com.android.internal.R.styleable.AndroidManifest_versionCodeMajor, 0);
        pkg.applicationInfo.setVersionCode(pkg.getLongVersionCode());
        pkg.baseRevisionCode = sa.getInteger(
                com.android.internal.R.styleable.AndroidManifest_revisionCode, 0);
        pkg.mVersionName = sa.getNonConfigurationString(
                com.android.internal.R.styleable.AndroidManifest_versionName, 0);
        if (pkg.mVersionName != null) {
            pkg.mVersionName = pkg.mVersionName.intern();
        }

        pkg.coreApp = parser.getAttributeBooleanValue(null, "coreApp", false);

        pkg.mCompileSdkVersion = sa.getInteger(
                com.android.internal.R.styleable.AndroidManifest_compileSdkVersion, 0);
        pkg.applicationInfo.compileSdkVersion = pkg.mCompileSdkVersion;
        pkg.mCompileSdkVersionCodename = sa.getNonConfigurationString(
                com.android.internal.R.styleable.AndroidManifest_compileSdkVersionCodename, 0);
        if (pkg.mCompileSdkVersionCodename != null) {
            pkg.mCompileSdkVersionCodename = pkg.mCompileSdkVersionCodename.intern();
        }
        pkg.applicationInfo.compileSdkVersionCodename = pkg.mCompileSdkVersionCodename;

        sa.recycle();

        return parseBaseApkCommon(pkg, null, res, parser, flags, outError);
    }
```
- 1.生成Package对象，获取包名以及<split> 标签做的AndroidManifest分割部分(这种很少用，其实就是bundle模块，允许动态切割资源和包，分配提交市场)。

- 2.从`AndroidManifest`解析出版本名，版本号等常用参数设置到App应用中。

- 3.parseBaseApkCommon进行解析Application标签，uses-permission等同等级数据。
```java
            if (tagName.equals(TAG_APPLICATION)) {
                if (foundApp) {
                    if (RIGID_PARSER) {
                        outError[0] = "<manifest> has more than one <application>";
                        mParseError = PackageManager.INSTALL_PARSE_FAILED_MANIFEST_MALFORMED;
                        return null;
                    } else {
                        Slog.w(TAG, "<manifest> has more than one <application>");
                        XmlUtils.skipCurrentTag(parser);
                        continue;
                    }
                }

                foundApp = true;
                if (!parseBaseApplication(pkg, res, parser, flags, outError)) {
                    return null;
                }
            } 
```
能看到这里进行了Application数目的校验，只允许一个存在。接着开始解析parseBaseApplication中的组件信息。


###### parseBaseApplication
这个方法很长，解析所有在Application标签的参数，我们重点关注四大组件是如何解析的
```java
    private boolean parseBaseApplication(Package owner, Resources res,
            XmlResourceParser parser, int flags, String[] outError)
        throws XmlPullParserException, IOException {
        final ApplicationInfo ai = owner.applicationInfo;
        final String pkgName = owner.applicationInfo.packageName;

        TypedArray sa = res.obtainAttributes(parser,
                com.android.internal.R.styleable.AndroidManifestApplication);

...

        while ((type = parser.next()) != XmlPullParser.END_DOCUMENT
                && (type != XmlPullParser.END_TAG || parser.getDepth() > innerDepth)) {
            if (type == XmlPullParser.END_TAG || type == XmlPullParser.TEXT) {
                continue;
            }

            String tagName = parser.getName();
            if (tagName.equals("activity")) {
                Activity a = parseActivity(owner, res, parser, flags, outError, cachedArgs, false,
                        owner.baseHardwareAccelerated);
                if (a == null) {
                    mParseError = PackageManager.INSTALL_PARSE_FAILED_MANIFEST_MALFORMED;
                    return false;
                }

                hasActivityOrder |= (a.order != 0);
                owner.activities.add(a);

            } else if (tagName.equals("receiver")) {
                Activity a = parseActivity(owner, res, parser, flags, outError, cachedArgs,
                        true, false);
                if (a == null) {
                    mParseError = PackageManager.INSTALL_PARSE_FAILED_MANIFEST_MALFORMED;
                    return false;
                }

                hasReceiverOrder |= (a.order != 0);
                owner.receivers.add(a);

            } else if (tagName.equals("service")) {
                Service s = parseService(owner, res, parser, flags, outError, cachedArgs);
                if (s == null) {
                    mParseError = PackageManager.INSTALL_PARSE_FAILED_MANIFEST_MALFORMED;
                    return false;
                }

                hasServiceOrder |= (s.order != 0);
                owner.services.add(s);

            } else if (tagName.equals("provider")) {
                Provider p = parseProvider(owner, res, parser, flags, outError, cachedArgs);
                if (p == null) {
                    mParseError = PackageManager.INSTALL_PARSE_FAILED_MANIFEST_MALFORMED;
                    return false;
                }

                owner.providers.add(p);

            }
}

...

}
```

- 1.解析`activity`标签：parseActivity解析出了一个Activity对象，保存到Package的activities集合中
- 2.解析`receiver`标签: 还是调用parseActivity方法，解析了一个Activity，保存到Package的receivers集合中
- 3.解析`service`标签: 调用了parseService方法，解析出了Service，保存到Package的services集合中
- 4.解析`provider`标签: 调用了parseProvider方法，解析出了Provider，保存到Package的providers集合中


这四个方法没什么好说的，都是很简单的解析xml中的内容，接着设置到了对应的结构对象中并返回。

#### PackageParser缓存原理
每一次解析完成之前都会有进行缓存校验和获取。因为每一次解析apk包中的  `AndroidManifest.xml`确实比较耗时。

获取和存储分别由两个方法完成：
```java
Package parsed = useCaches ? getCachedResult(packageFile, flags) : null;
```
```java
cacheResult(packageFile, flags, parsed);
```
我们先来看看cacheResult是怎么存储的。


##### PackageParser cacheResult
```java

    private String getCacheKey(File packageFile, int flags) {
        StringBuilder sb = new StringBuilder(packageFile.getName());
        sb.append('-');
        sb.append(flags);

        return sb.toString();
    }


    private void cacheResult(File packageFile, int flags, Package parsed) {
        if (mCacheDir == null) {
            return;
        }

        try {
            final String cacheKey = getCacheKey(packageFile, flags);
            final File cacheFile = new File(mCacheDir, cacheKey);

            if (cacheFile.exists()) {
                if (!cacheFile.delete()) {
                    
                }
            }

            final byte[] cacheEntry = toCacheEntry(parsed);

            if (cacheEntry == null) {
                return;
            }

            try (FileOutputStream fos = new FileOutputStream(cacheFile)) {
                fos.write(cacheEntry);
            } catch (IOException ioe) {
                cacheFile.delete();
            }
        } catch (Throwable e) {
            Slog.w(TAG, "Error saving package cache.", e);
        }
    }
```
- 通过getCacheKey构建出来的key为`包名_flag`,也就是`包名_0`，并在`/data/system/package_cache/`生成一个对应的文件，也就是`/data/system/package_cache/包名_0`.

- 通过toCacheEntry方法，获取获取Package所有的内容，如果为空则返回。

- 不为空，则通过FileOutputStream把Package存储好的二进制数据全部写到`/data/system/package_cache/包名_0`文件中。

toCacheEntry系统如何快速获取该文件中所有的内容呢？

##### toCacheEntry
```java
    protected byte[] toCacheEntry(Package pkg) {
        return toCacheEntryStatic(pkg);

    }

    /** static version of {@link #toCacheEntry} for unit tests. */
    @VisibleForTesting
    public static byte[] toCacheEntryStatic(Package pkg) {
        final Parcel p = Parcel.obtain();
        final WriteHelper helper = new WriteHelper(p);

        pkg.writeToParcel(p, 0 /* flags */);

        helper.finishAndUninstall();

        byte[] serialized = p.marshall();
        p.recycle();

        return serialized;
    }
```
很有趣：
- 1.就是通过Parcel，把package写入到Parcel中。

- 2.调用了WriteHelper的finishAndUninstall方法。
```java
    public static class WriteHelper extends Parcel.ReadWriteHelper {
        private final ArrayList<String> mStrings = new ArrayList<>();

        private final HashMap<String, Integer> mIndexes = new HashMap<>();

        private final Parcel mParcel;
        private final int mStartPos;

        public WriteHelper(Parcel p) {
            mParcel = p;
            mStartPos = p.dataPosition();
            mParcel.writeInt(0); // We come back later here and write the pool position.

            mParcel.setReadWriteHelper(this);
        }

        @Override
        public void writeString(Parcel p, String s) {
            final Integer cur = mIndexes.get(s);
            if (cur != null) {
                // String already in the pool. Just write the index.
                p.writeInt(cur); // Already in the pool.
                if (DEBUG) {
                    Log.i(TAG, "Duplicate '" + s + "' at " + cur);
                }
            } else {
                final int index = mStrings.size();
                mIndexes.put(s, index);
                mStrings.add(s);

                p.writeInt(index);
            }
        }

        public void finishAndUninstall() {
            // Uninstall first, so that writeStringList() uses the native writeString.
            mParcel.setReadWriteHelper(null);

            final int poolPosition = mParcel.dataPosition();
            mParcel.writeStringList(mStrings);

            mParcel.setDataPosition(mStartPos);
            mParcel.writeInt(poolPosition);

            mParcel.setDataPosition(mParcel.dataSize());
            if (DEBUG) {
                Log.i(TAG, "Wrote " + mStrings.size() + " strings");
            }
        }
    }
```

注意因为这里设置了setReadWriteHelper。在Package对象中调用writeToParcel全是writeString，此时调用的是WriteHelper的writeString。所有的数据都将写入到mStrings中。此时调用finishAndUninstall，把list中所有的String统一写入到Parcel中。

- 3.调用了Parcel的marshall方法,核心方法如下
```java
static jbyteArray android_os_Parcel_marshall(JNIEnv* env, jclass clazz, jlong nativePtr)
{
    Parcel* parcel = reinterpret_cast<Parcel*>(nativePtr);
    if (parcel == NULL) {
       return NULL;
    }
...
    jbyteArray ret = env->NewByteArray(parcel->dataSize());

    if (ret != NULL)
    {
        jbyte* array = (jbyte*)env->GetPrimitiveArrayCritical(ret, 0);
        if (array != NULL)
        {
            memcpy(array, parcel->data(), parcel->dataSize());
            env->ReleasePrimitiveArrayCritical(ret, array, 0);
        }
    }

    return ret;
}
```
就是在jni中通过memcpy，把数据全部拷贝到java层并返回。


同理，我们来看看PackageParser是怎么读取数据的。

#### PackageParser getCachedResult
```java
    private Package getCachedResult(File packageFile, int flags) {
        if (mCacheDir == null) {
            return null;
        }

        final String cacheKey = getCacheKey(packageFile, flags);
        final File cacheFile = new File(mCacheDir, cacheKey);

        try {
            if (!isCacheUpToDate(packageFile, cacheFile)) {
                return null;
            }

            final byte[] bytes = IoUtils.readFileAsByteArray(cacheFile.getAbsolutePath());
            Package p = fromCacheEntry(bytes);
            if (mCallback != null) {
                String[] overlayApks = mCallback.getOverlayApks(p.packageName);
                if (overlayApks != null && overlayApks.length > 0) {
                    for (String overlayApk : overlayApks) {
                        // If a static RRO is updated, return null.
                        if (!isCacheUpToDate(new File(overlayApk), cacheFile)) {
                            return null;
                        }
                    }
                }
            }
            return p;
        } catch (Throwable e) {
...
            cacheFile.delete();
            return null;
        }
    }
```

- 1.能看到同样是构造了`/data/system/package_cache/包名_0`文件

- 2.isCacheUpToDate 判断当前的缓存文件是否过期了。
```java
    private static boolean isCacheUpToDate(File packageFile, File cacheFile) {
        try {

            final StructStat pkg = android.system.Os.stat(packageFile.getAbsolutePath());
            final StructStat cache = android.system.Os.stat(cacheFile.getAbsolutePath());
            return pkg.st_mtime < cache.st_mtime;
        } catch (ErrnoException ee) {
            if (ee.errno != OsConstants.ENOENT) {
                Slog.w("Error while stating package cache : ", ee);
            }

            return false;
        }
    }
```

很简单，就是检查apk本身安装的时间，和缓存本身的时间哪个更加老。如果缓存更新。，说明当前的缓存有效。更老了，说明apk版本安装更新了，需要重新读取了


- 3.readFileAsByteArray 读取文件中所有的内容，并调用fromCacheEntry方法逆向转化为package对象。接着检查overlayapk的的时效和当前的缓存相比较。


## 总结
到这里就把PMS的启动原理大体上和大家聊完了。老规矩，先上时序图
![PMS启动流程.png](/images/PMS启动流程.png)

在PMS初始化中做了如下的事情：
- 1.实例化Settings PMS的配置对象，内含`packages.list`和`packages.xml`.
  - 1.1.`packages.list`记录了Android系统中安装的应用列表以及对应的userID
  - 2.2.`packages.xml`记录了每一个安装包的名字，代码路径，so路径，签名等信息


- 2.对整个Android系统进行分区，扫描分区中所有的尝试提供的服务以及App安装的包，分为如下区域

- 2.1.`/data/system/package_cache/` 所有的包扫描的结果都会缓存到这里,每一个结果的缓存为`/data/system/package_cache/包名_0`

  - 2.2.`/vendor/overlay`

  - 2.3.`/product/overlay`  第2和第3点都是第三方厂商提供的资源复写目录

  - 2.4.`/system/framework` Android系统framework层内置提供的java的核心jar包，odex等

  - 2.5.`/system/priv-app`,`/system/app` ,这里面提供了Android系统或者厂商默认的系统应用

  - 2.6.`/vendor/priv-app`,`/vendor/app` 这是交给硬件厂商的目录，允许他们内置内置一些系统应用服务。我之前常说的hal层，就是在这个vendor目录安装提供的。

  - 2.7.`/odm/priv-app`,`/odm/app` 可以看作是vendor目录的一种延伸。

  - 2.8.`/oem/app` ，`/product/priv-app`,`/product/app`  

  - 2.9.`/data/app`,`/data/app-private`.所有的应用apk对象都会拷贝到`/data/app`

  - 2.10.通过Installd. fixupAppData 在`/data/user/用户ID/包名/`下构造每一个安装后真正的数据保存路径，并把这个目录链接到`/data/data/包名`中

  - 2.11.Installd.createAppData  为每一个包名下创建`/data/user/用户ID/包名/cache` 或`/data/user/用户ID/包名/code_cache`.用于缓存安装过程中编译优化好的文件，如art，odex，vdex,dex等等

  - 2.12. prepareAppDataContentsLeafLIF 会调用Installd. linkNativeLibraryDirectory创建每一个应用so库的扫描目录`/data/user/用户id/包名/lib`。并把这个目录链接到`/data/data/包名/lib`中

  - 2.13.还会调用`/system/bin/profman` 程序生成每一个应用包名的`/data/data/包名/包名.prof`文件用于加速后面的dex2oat的编译优化。

- 3.在扫描的过程中，就以我们开发安装的应用微粒子。会从`/data/app`目录下取出apk文件，拿到其中的`AndroidManifest.xml`，解析里面所有的组件和标签并保存到package对象。并把这个package对象通过Parcel进行序列化，保存到`data/system/package_cache/包名_0`中。

下一次就会优先从这个缓存中获取，直到出现缓存的文件的修改日期时间比`/data/app`中保存的apk文件修改时间早，说明apk发生了版本更新，才会重新从`/data/app`中读取。






