---
title: Shadow源码解析
top: false
cover: false
date: 2022-04-24 23:29:40
img:
tag: Android常用第三方库
description:
author: yjy239
summary:
---

## 前言

时隔4年。本文再次来聊聊Shadow 这个0 hook的插件库。目前看来，确实是腾讯这个Shadow 插件库做到0 hook api实现插件化。在腾讯内部也是广泛使用，其设计上解藕的非常好，可以独立升级插件的插件依赖库很少造成冲突，可以几个版本的Shadow插件混用不造成异常。

如果还在观望的朋友，相信阅读完本文可以对这个插件库有更多的信心。当然如果是到海外，Google市场，可能需要自己斟酌一二再使用Shadow。毕竟对于Google来说动态更新这个行为也不是它希望的。

不熟悉插件化原理的，可以阅读我之前写插件文章[横向浅析Small,RePlugin两个插件化框架](https://www.jianshu.com/p/d824056f510b)，在里面深刻的描述了3年前的插件化的原理。

有什么问题可以来本文https://www.jianshu.com/p/e1738998abd1 下讨论

# 正文

Shadow 比起其他插件库多了几个特殊概念。很多人就是上来如何使用，实际上不对Shadow 的整体有一个初步的概念，很难用的好这个库。

对于Shadow来说，可其他的插件库一样分为宿主和插件两个部分。从设计的角度上更加接近RePlugin，需要宿主和插件业务，分别依赖宿主库和插件库。

实际上，对于Shadow来说，插件业务生成的插件包，不仅仅只有一个插件业务的apk。往往是一个由如下4部分组成：

- 1.manger.apk 专门用于联通宿主apk。当宿主apk启动插件的时候，需要启动manager模块，加载 loader.apk,runtime.apk,以及业务插件apk。
- 2.loader.apk 专门用于映射坑位Activity/Broadcast/Service/ContentProvider 与 业务插件中四大组件对应的类名
- 3.runtime.apk 用于申明四大组件的类。注意runtime.apk中的AndroidManifest 中不需要声明。这些坑位需要直接声明到宿主中
- 4.插件业务生成的apk 业务的实现


## 关于0 hook的思考

在聊Shadow的使用和实现方案之前，我们稍微的回顾一下hook点最少的RePlugin框架。Hook了一个Context注入了自己的ClassLoader。那么如何在这个基础上进一步前进，实现0 hook。

能不能想办法达到不 hook任何一个位置，从而实现宿主管理插件的功能呢？当然我也没有想出来，只是有不少人已经想出来了，并进行实现。

RePlugin的思路简单说一下，RePlugin把插件框架氛围两个部分：
- 宿主 用于控制插件版本和加载插件。并反射插件进程中的固定入口，启动插件中的组件
- 插件 主要是通过Gradle 插件替换了四大组件为自己的代理类这几个类是自己在插件库实现的PluginActivity。

为什么需要Hook Context呢？为了让插件和宿主可以互相通信。RePlugin会生成一个PluginClassLoader 用于宿主和插件互相查找对方类。而apk的classLoader 最早是存在Context中，因此需要Hook Context。


既然知道了为什么需要Hook Context了？我们可否想办法处理一下，避免Hook Context。其实方案已经摆在眼前了。

就以坑位Activity为例子。插件库的Gradle 插件转化的PluginActivity 需要正常工作就需要Hook Context。那么我们为何不做如下行为，干脆把Context也交给我们来代理好了，PluginActivity不继承任何类。PluginActivity 将会实现所有Activity 对外的接口，而他所有行为直接以来宿主的坑位Activity了，不久好了吗？


回头来想想我四年前说过的，插件化需要跨越的三大问题，这么做是否解决？

- 越过AndroidManifest的校验。
- 查找插件的Class
- 加载插件资源

##### 三个问题的解决方式

- 对于第一个问题：目前的方案，因为是插件库把Activity转化成一个不继承任何类的PluginActivity，并依赖坑位Activity的行为。因此只需要声明坑位的Activity，只是这个坑位的Activity需要做特殊处理，可以注入PluginActivity，并调用公有回调

- 对于第二个问题，也解决了。因为不是通过内置的ClassLoader查找Class。而是通过自己生成的ClassLoader 查找Class

- 第三个问题，更好解决。Context都是自己创建的了，为什么不可以自己在自己的Context做好资源管理呢？

这么想，0 hook 通过代理设计模式实现插件化似乎可行。而Shadow 也是如此思想。接下来看看他如何使用，如何解耦插件库和宿主库的。

## Shadow 使用

为了避免插件库影响原来的业务逻辑，一般会常见一个壳模块。这个模块作为主模块，被业务工程依赖。

#### 根目录工程

在工程根目录的build.gradle 新增

```groovy
buildscript {
    repositories {
        if (!System.getenv().containsKey("DISABLE_TENCENT_MAVEN_MIRROR")) {
            maven { url 'https://mirrors.tencent.com/nexus/repository/maven-public/' }
        } else {
            google()
            jcenter()
        }



        maven {
            name = "GitHubPackages"
            url "https://maven.pkg.github.com/tencent/shadow"
            //一个只读账号兼容Github Packages暂时不支持匿名下载
            //https://github.community/t/download-from-github-package-registry-without-authentication/14407
            credentials {
                username = 'readonlypat'
                password = '\u0062\u0036\u0064\u0037\u0035\u0032\u0062\u0061\u0035\u0038\u0063\u0064\u0032\u0061\u0038\u0037\u0064\u0033\u0034\u0033\u0039\u0038\u0035\u0036\u0032\u0034\u0065\u0039\u0031\u0036\u0066\u0065\u0065\u0062\u0031\u0065\u0033\u0037\u0061\u0039'
            }
        }

    }
    ext.shadow_version = 'local-d93420c5-SNAPSHOT'
    dependencies {
        c
        classpath "com.tencent.shadow.core:gradle-plugin:$shadow_version"
        // NOTE: Do not place your application dependencies here; they belong
        // in the individual module build.gradle files
    }
    apply from: 'buildscriptAdditions.gradle', to: buildscript
}

apply from: 'baseBuildAdditions.gradle'

allprojects {
    repositories {
        google()
        mavenCentral()

        maven {
            name = "GitHubPackages"
            url "https://maven.pkg.github.com/tencent/shadow"
            //一个只读账号兼容Github Packages暂时不支持匿名下载
            //https://github.community/t/download-from-github-package-registry-without-authentication/14407
            credentials {
                username = 'readonlypat'
                password = '\u0062\u0036\u0064\u0037\u0035\u0032\u0062\u0061\u0035\u0038\u0063\u0064\u0032\u0061\u0038\u0037\u0064\u0033\u0034\u0033\u0039\u0038\u0035\u0036\u0032\u0034\u0065\u0039\u0031\u0036\u0066\u0065\u0065\u0062\u0031\u0065\u0033\u0037\u0061\u0039'
            }
        }

    }
}

```


注意，classpath，`com.tencent.shadow.core:gradle-plugin` 插件是将所有的四大组件，替换成Shadow的对应的代理类。而这些代理类会把工作交给runtime中真正的Activity组件实现



#### 2 创建一个模块plugin-shadow-apk：

```groovy
dependencies {
    //Shadow Transform后业务代码会有一部分实际引用runtime中的类
    //如果不以compileOnly方式依赖，会导致其他Transform或者Proguard找不到这些类
    compileOnly "com.tencent.shadow.core:runtime:$shadow_version"
}


apply plugin: 'com.tencent.shadow.plugin'

shadow {
    packagePlugin {
        pluginTypes {
            debug {
                loaderApkConfig = new Tuple2('sample-loader-debug.apk', ':sample-loader:assembleDebug')
                runtimeApkConfig = new Tuple2('sample-runtime-debug.apk', ':sample-runtime:assembleDebug')
                pluginApks {
                    pluginApk1 {
                        businessName = 'sample-plugin'//businessName相同的插件，context获取的Dir是相同的。businessName留空，表示和宿主相同业务，直接使用宿主的Dir。
                        partKey = 'sample-plugin'
                        buildTask = 'assembleDebug'
                        apkName = 'plugin-shadow-apk-debug.apk'
                        apkPath = 'plugin-shadow-apk/build/outputs/apk/debug/plugin-shadow-apk-debug.apk'
                    }
                }
            }

            release {
                loaderApkConfig = new Tuple2('sample-loader-release.apk', ':sample-loader:assembleRelease')
                runtimeApkConfig = new Tuple2('sample-runtime-release.apk', ':sample-runtime:assembleRelease')
                pluginApks {
                    pluginApk1 {
                        businessName = 'demo'
                        partKey = 'sample-plugin'
                        buildTask = 'assembleRelease'
                        apkName = 'plugin-shadow-apk-release.apk'
                        apkPath = 'plugin-shadow-apk/build/outputs/apk/release/plugin-shadow-apk-release.apk'
                    }
                }
            }
        }

        loaderApkProjectPath = 'sample-loader'

        runtimeApkProjectPath = 'sample-runtime'

        version = 4
        compactVersion = [1, 2, 3]
        uuidNickName = "1.1.5"
    }
}
```



有了这个`shadow`任务实现后，就能通过命令`./gradlew packageDebugPlugin ` 直接生成`runtime的apk` + `loade的apk` + `插件业务的apk`  的压缩包。


最后记得依赖业务模块

#### 2.Shadow 的宿主

```groovy
dependencies {
    implementation project(':introduce-shadow-lib')

    //如果introduce-shadow-lib发布到Maven，在pom中写明此依赖，宿主就不用写这个依赖了。
    implementation "com.tencent.shadow.dynamic:host:$shadow_version"
}
```

宿主通过如下方法启动插件的Activity


```
public static final int FROM_ID_START_ACTIVITY = 1001;
public static final int FROM_ID_CALL_SERVICE = 1002;
pluginManager.enter(MainActivity.this, FROM_ID_START_ACTIVITY, new Bundle(), new EnterCallback() {
    @Override
    public void onShowLoadingView(View view) {
        MainActivity.this.setContentView(view);//显示Manager传来的Loading页面
    }

    @Override
    public void onCloseLoadingView() {
        MainActivity.this.setContentView(linearLayout);
    }

    @Override
    public void onEnterComplete() {
        v.setEnabled(true);
    }
});

```




#### 3.Shadow 中的runtime

构建一个 application 级别的工程，依赖

```groovy
implementation "com.tencent.shadow.core:activity-container:$shadow_version"
```



请实现几个坑位Activity:

```java
public class PluginDefaultProxyActivity extends PluginContainerActivity {
}



public class PluginNativeProxyActivity extends NativePluginContainerActivity {
}



public class PluginSingleInstance1ProxyActivity extends PluginContainerActivity {
}



public class PluginSingleTask1ProxyActivity extends PluginContainerActivity {
}
```


紧接着，生成一个loader-apk即可。


这几个Activity可以不用注册当前apk的AndroidManifest中，需要注册到宿主apk中的AndroidManifest。对于Shadow来说，只需要能在这个apk中找到这个Class就可以了。



请在宿主的AndroidManifest 注册上面申明的Activity





宿主：
```xml
 <service
    android:name=".MainPluginProcessService"
    android:process=":plugin" />


<activity
    android:name="com.tencent.shadow.sample.runtime.PluginDefaultProxyActivity"
    android:launchMode="standard"
    android:screenOrientation="portrait"
    android:configChanges="mcc|mnc|locale|touchscreen|keyboard|keyboardHidden|navigation|screenLayout|fontScale|uiMode|orientation|screenSize|smallestScreenSize|layoutDirection"
    android:hardwareAccelerated="true"
    android:theme="@style/PluginContainerActivity"
    android:process=":plugin" />

<activity
    android:name="com.tencent.shadow.sample.runtime.PluginSingleInstance1ProxyActivity"
    android:launchMode="singleInstance"
    android:screenOrientation="portrait"
    android:configChanges="mcc|mnc|locale|touchscreen|keyboard|keyboardHidden|navigation|screenLayout|fontScale|uiMode|orientation|screenSize|smallestScreenSize|layoutDirection"
    android:hardwareAccelerated="true"
    android:theme="@style/PluginContainerActivity"
    android:process=":plugin" />

<activity
    android:name="com.tencent.shadow.sample.runtime.PluginSingleTask1ProxyActivity"
    android:launchMode="singleTask"
    android:screenOrientation="portrait"
    android:configChanges="mcc|mnc|locale|touchscreen|keyboard|keyboardHidden|navigation|screenLayout|fontScale|uiMode|orientation|screenSize|smallestScreenSize|layoutDirection"
    android:hardwareAccelerated="true"
    android:theme="@style/PluginContainerActivity"
    android:process=":plugin" />

<provider
    android:authorities="com.tencent.shadow.contentprovider.authority.dynamic"
    android:name="com.tencent.shadow.core.runtime.container.PluginContainerContentProvider" />
```

请注意必须都申明好`android:process=":plugin"`，需要和承载插件业务`MainPluginProcessService` 在同一个进程，这样才能在插件进程中从ClassLoader找到这几个类。


#### 4.Shadow的 loader

构建一个 application 级别的工程，依赖

```groovy
dependencies {
    implementation "com.tencent.shadow.dynamic:loader-impl:$shadow_version"

    compileOnly "com.tencent.shadow.core:activity-container:$shadow_version"
    compileOnly "com.tencent.shadow.core:common:$shadow_version"
    //下面这行依赖是为了防止在proguard的时候找不到LoaderFactory接口
    compileOnly "com.tencent.shadow.dynamic:host:$shadow_version"
}
```


构建一个`CoreLoaderFactoryImpl`:

```java
package com.tencent.shadow.dynamic.loader.impl;
public class CoreLoaderFactoryImpl implements CoreLoaderFactory {

    @NotNull
    @Override
    public ShadowPluginLoader build(@NotNull Context context) {
        return new SamplePluginLoader(context);
    }
}
```


注意 CoreLoaderFactoryImpl 这个类名必须固定，这是Shadow自身的hook点。宿主会通过manager 进行查找。


```java
public class SamplePluginLoader extends ShadowPluginLoader {

    private final static String TAG = "shadow";

    private ComponentManager componentManager;

    public SamplePluginLoader(Context hostAppContext) {
        super(hostAppContext);
        componentManager = new SampleComponentManager(hostAppContext);
    }

    @Override
    public ComponentManager getComponentManager() {
        return componentManager;
    }

}
```



核心是构建`ComponentManager`.这个类中，loader将会实现把 runtime 中写好的代理Activity和插件业务的Activity进行一一映射。



案例如下：


```
public class SampleComponentManager extends ComponentManager {

    /**
     * sample-runtime 模块中定义的壳子Activity，需要在宿主AndroidManifest.xml注册
     */
    private static final String DEFAULT_ACTIVITY = "com.tencent.shadow.sample.runtime.PluginDefaultProxyActivity";
    private static final String SINGLE_INSTANCE_ACTIVITY = "com.tencent.shadow.sample.runtime.PluginSingleInstance1ProxyActivity";
    private static final String SINGLE_TASK_ACTIVITY = "com.tencent.shadow.sample.runtime.PluginSingleTask1ProxyActivity";
    private static final String DEFAULT_NATIVE_ACTIVITY = "com.tencent.shadow.sample.runtime.PluginNativeProxyActivity";

    private Context context;

    public SampleComponentManager(Context context) {
        this.context = context;
    }


    /**
     * 配置插件Activity 到 壳子Activity的对应关系
     *
     * @param pluginActivity 插件Activity
     * @return 壳子Activity
     */
    @Override
    public ComponentName onBindContainerActivity(ComponentName pluginActivity) {
        switch (pluginActivity.getClassName()) {
            /**
             * 这里配置对应的对应关系
             */
            case "com.sample.test.SampleActivity":
                return new ComponentName(context, DEFAULT_NATIVE_ACTIVITY);
        }
        return new ComponentName(context, DEFAULT_ACTIVITY);
    }

    /**
     * 配置对应宿主中预注册的壳子contentProvider的信息
     */
    @Override
    public ContainerProviderInfo onBindContainerContentProvider(ComponentName pluginContentProvider) {
        return new ContainerProviderInfo(
                "com.tencent.shadow.runtime.container.PluginContainerContentProvider",
                "com.tencent.shadow.contentprovider.authority.dynamic");
    }

    @Override
    public List<BroadcastInfo> getBroadcastInfoList(String partKey) {
        List<ComponentManager.BroadcastInfo> broadcastInfos = new ArrayList<>();

        //如果有静态广播需要像下面代码这样注册
//        if (partKey.equals(Constant.PART_KEY_PLUGIN_MAIN_APP)) {
//            broadcastInfos.add(
//                    new ComponentManager.BroadcastInfo(
//                            "com.tencent.shadow.demo.usecases.receiver.MyReceiver",
//                            new String[]{"com.tencent.test.action"}
//                    )
//            );
//        }
        return broadcastInfos;
    }

}
```

到运行的时候，GameActivity 所有的行为将会依赖PluginNativeProxyActivity 的实现。

其他的Activity 映射到 普通的PluginDefaultProxyActivity 即可



#### 5.Shadow 中的manager



需要专门构建一个Android工程，这个工程可以参照github中的案例。



新增配置：
```
allprojects {
    repositories {
        if (!System.getenv().containsKey("DISABLE_TENCENT_MAVEN_MIRROR")) {
            maven { url 'https://mirrors.tencent.com/nexus/repository/maven-public/' }
        } else {
            google()
            jcenter()
        }
        maven { url 'https://mirrors.tencent.com/repository/maven/cubershiTempShadowPublish' }
        maven {
            name = "GitHubPackages"
            url "https://maven.pkg.github.com/tencent/shadow"
            //一个只读账号兼容Github Packages暂时不支持匿名下载
            //https://github.community/t/download-from-github-package-registry-without-authentication/14407
            credentials {
                username = 'readonlypat'
                password = '\u0062\u0036\u0064\u0037\u0035\u0032\u0062\u0061\u0035\u0038\u0063\u0064\u0032\u0061\u0038\u0037\u0064\u0033\u0034\u0033\u0039\u0038\u0035\u0036\u0032\u0034\u0065\u0039\u0031\u0036\u0066\u0065\u0065\u0062\u0031\u0065\u0033\u0037\u0061\u0039'
            }
        }
        mavenLocal()
    }
}
```

新增依赖：


```
dependencies {
    implementation "com.tencent.shadow.dynamic:manager:$shadow_version"
    compileOnly "com.tencent.shadow.core:common:$shadow_version"
    compileOnly "com.tencent.shadow.dynamic:host:$shadow_version"
}
```



继承FastPluginManager


```java
public class SamplePluginManager extends FastPluginManager {

    private ExecutorService executorService = Executors.newSingleThreadExecutor();

    private Context mCurrentContext;

    public SamplePluginManager(Context context) {
        super(context);
        mCurrentContext = context;
    }

    /**
     * @return PluginManager实现的别名，用于区分不同PluginManager实现的数据存储路径
     */
    @Override
    protected String getName() {
        return "sample-manager";
    }

    /**
     * @return demo插件so的abi
     */
    @Override
    public String getAbi() {
        return "armeabi-v7a";
    }

    /**
     * @return 宿主中注册的PluginProcessService实现的类名
     */
    @Override
    protected String getPluginProcessServiceName() {
        return "com.tencent.shadow.sample.introduce_shadow_lib.MainPluginProcessService";
    }

    @Override
    public void enter(final Context context, long fromId, Bundle bundle, final EnterCallback callback) {
        if (fromId == Constant.FROM_ID_START_ACTIVITY) {
            bundle.putString(Constant.KEY_PLUGIN_ZIP_PATH, "/data/local/tmp/plugin-debug.zip");
            bundle.putString(Constant.KEY_PLUGIN_PART_KEY, "sample-plugin");
            bundle.putString(Constant.KEY_ACTIVITY_CLASSNAME, "com.sample.test.SampleActivity");
            onStartActivity(context, bundle, callback);
        } else if (fromId == Constant.FROM_ID_CALL_SERVICE) {
            callPluginService(context);
        } else {
            throw new IllegalArgumentException("不认识的fromId==" + fromId);
        }
    }

    private void onStartActivity(final Context context, Bundle bundle, final EnterCallback callback) {
        final String pluginZipPath = bundle.getString(Constant.KEY_PLUGIN_ZIP_PATH);
        final String partKey = bundle.getString(Constant.KEY_PLUGIN_PART_KEY);
        final String className = bundle.getString(Constant.KEY_ACTIVITY_CLASSNAME);
        if (className == null) {
            throw new NullPointerException("className == null");
        }
        final Bundle extras = bundle.getBundle(Constant.KEY_EXTRAS);

        if (callback != null) {
            final View view = LayoutInflater.from(mCurrentContext).inflate(R.layout.activity_load_plugin, null);
            callback.onShowLoadingView(view);
        }

        executorService.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    InstalledPlugin installedPlugin
                            = installPlugin(pluginZipPath, null, true);//这个调用是阻塞的
                    Intent pluginIntent = new Intent();
                    pluginIntent.setClassName(
                            context.getPackageName(),
                            className
                    );
                    if (extras != null) {
                        pluginIntent.replaceExtras(extras);
                    }

                    startPluginActivity(context, installedPlugin, partKey, pluginIntent);
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
                if (callback != null) {
                    Handler uiHandler = new Handler(Looper.getMainLooper());
                    uiHandler.post(new Runnable() {
                        @Override
                        public void run() {
                            callback.onCloseLoadingView();
                            callback.onEnterComplete();
                        }
                    });
                }
            }
        });
    }
}
```

- getName 用于控制插件版本等信息的名字。manager会通过这个名字找到数据库存储的信息加载合适数据
- getAbi 当前加载的so 是什么cpu框架的
- enter 可以通过id 来判断当前的行为，从而根据id跳转到合适的Activity


## Shadow 的源码解析

先来看看宿主的原理。宿主想要启动插件中的某个Activity需要经历如下几个步骤：

- 1.通过 `new DynamicPluginManager(fixedPathPmUpdater);` 声明DynamicPluginManager对象

- 2.调用`DynamicPluginManager`的enter方法启动插件中Manager.apk的相同id的行为。

```java
                pluginManager.enter(MainActivity.this, FROM_ID_START_ACTIVITY, new Bundle(), new EnterCallback() {
                    @Override
                    public void onShowLoadingView(View view) {
                        MainActivity.this.setContentView(view);//显示Manager传来的Loading页面
                    }

                    @Override
                    public void onCloseLoadingView() {
                        MainActivity.this.setContentView(linearLayout);
                    }

                    @Override
                    public void onEnterComplete() {
                        v.setEnabled(true);
                    }
                });
```

### 1.DynamicPluginManager enter

```java
    @Override
    public void enter(Context context, long fromId, Bundle bundle, EnterCallback callback) {
        if (mLogger.isInfoEnabled()) {
            mLogger.info("enter fromId:" + fromId + " callback:" + callback);
        }
        updateManagerImpl(context);
        mManagerImpl.enter(context, fromId, bundle, callback);
        mUpdater.update();
    }
```

#### 1.1.updateManagerImpl

```java
  FixedPathPmUpdater fixedPathPmUpdater
                = new FixedPathPmUpdater(new File("/data/local/tmp/sample-manager-debug.apk"));
```

```java
private void updateManagerImpl(Context context) {
        File latestManagerImplApk = mUpdater.getLatest();
        String md5 = md5File(latestManagerImplApk);
        if (mLogger.isInfoEnabled()) {
            mLogger.info("TextUtils.equals(mCurrentImplMd5, md5) : " + (TextUtils.equals(mCurrentImplMd5, md5)));
        }
        if (!TextUtils.equals(mCurrentImplMd5, md5)) {
            ManagerImplLoader implLoader = new ManagerImplLoader(context, latestManagerImplApk);
            PluginManagerImpl newImpl = implLoader.load();
            Bundle state;
            if (mManagerImpl != null) {
                state = new Bundle();
                mManagerImpl.onSaveInstanceState(state);
                mManagerImpl.onDestroy();
            } else {
                state = null;
            }
            newImpl.onCreate(state);
            mManagerImpl = newImpl;
            mCurrentImplMd5 = md5;
        }
    }
```
在这个方法中实际上就是校验了`manager.apk`的和之前的md5是否一致，不是则需要更新。

发现了更新则执行如下几个步骤：

- 1. ManagerImplLoader 的 load 方法创建一个`PluginManagerImpl`对象
- 2. 原来的ManagerImplLoader 不为空，则依次调用`PluginManagerImpl`的`onSaveInstanceState`和`onDestroy`
- 3. `PluginManagerImpl`的onCreate方法，更新`mManagerImpl`。

#### 1.3.`ManagerImplLoader.load`创建 `PluginManagerImpl`对象

```java

    private static final String MANAGER_FACTORY_CLASS_NAME = "com.tencent.shadow.dynamic.impl.ManagerFactoryImpl";
    private static final String[] REMOTE_PLUGIN_MANAGER_INTERFACES = new String[]
            {
                    "com.tencent.shadow.core.common",
                    "com.tencent.shadow.dynamic.host"
            };
    final private Context applicationContext;
    final private InstalledApk installedApk;

    ManagerImplLoader(Context context, File apk) {
        applicationContext = context.getApplicationContext();
        File root = new File(applicationContext.getFilesDir(), "ManagerImplLoader");
        File odexDir = new File(root, Long.toString(apk.lastModified(), Character.MAX_RADIX));
        odexDir.mkdirs();
        installedApk = new InstalledApk(apk.getAbsolutePath(), odexDir.getAbsolutePath(), null);
    }

    PluginManagerImpl load() {
        ApkClassLoader apkClassLoader = new ApkClassLoader(
                installedApk,
                getClass().getClassLoader(),
                loadWhiteList(installedApk),
                1
        );

        Context pluginManagerContext = new ChangeApkContextWrapper(
                applicationContext,
                installedApk.apkFilePath,
                apkClassLoader
        );

        try {
            ManagerFactory managerFactory = apkClassLoader.getInterface(
                    ManagerFactory.class,
                    MANAGER_FACTORY_CLASS_NAME
            );
            return managerFactory.buildManager(pluginManagerContext);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
```
`ManagerImplLoader` 实际上是获得了`manager.apk`文件后，
并根据`manager.apk`文件生成两个对象：
- 对应的`ApkClassLoader`用于查找manager.apk的类。
- 生成`ChangeApkContextWrapper`用于获取资源和获取`ApkClassLoader`。

最后通过`ApkClassLoader` 查找这个apk中的`com.tencent.shadow.dynamic.impl.ManagerFactoryImpl` 类并实例化后，调用`buildManager` 生成`PluginManagerImpl`对象。


接下来的逻辑就是进入到了Manager.apk中了，是不是有点Replugin那味道了。


#### 2.ManagerFactoryImpl buildManager
```java
/**
 * 此类包名及类名固定
 */
public final class ManagerFactoryImpl implements ManagerFactory {
    @Override
    public PluginManagerImpl buildManager(Context context) {
        return new SamplePluginManager(context);
    }
}
```
因此在manager工程中需要 写一个类名`ManagerFactoryImpl`，作为Manager.apk逻辑的入口。因此此时在宿主中返回的`PluginManagerImpl` 实际上就是自己编写的manager工程中返回的`SamplePluginManager`类。

在这个案例中，`SamplePluginManager`继承的是`PluginManagerThatUseDynamicLoader`.紧接着调用SamplePluginManager 的 onCreate 和 onDestroy。


#### 2.3. SamplePluginManager enter

demo中的enter

```java
    @Override
    public void enter(final Context context, long fromId, Bundle bundle, final EnterCallback callback) {
        if (fromId == Constant.FROM_ID_START_ACTIVITY) {
            bundle.putString(Constant.KEY_PLUGIN_ZIP_PATH, "/data/local/tmp/plugin-debug.zip");
            bundle.putString(Constant.KEY_PLUGIN_PART_KEY, "sample-plugin");
            bundle.putString(Constant.KEY_ACTIVITY_CLASSNAME, "com.sample.test.SampleActivity");
            onStartActivity(context, bundle, callback);
        } else if (fromId == Constant.FROM_ID_CALL_SERVICE) {
            callPluginService(context);
        } else {
            throw new IllegalArgumentException("不认识的fromId==" + fromId);
        }
    }

```

一般的在SampleManager 中都会，都会根据`fromId`的业务类型来判断当前执行行为。就以`FROM_ID_START_ACTIVITY`为例子。这里尝试着启动`plugin-debug.zip`插件包中的插件。

而这个插件包存在着三个apk，`loader.apk`,`runtime.apk`,`$插件业务.apk`.因此可以说manager.apk管理了当前插件的加载逻辑。

##### 2.4. SamplePluginManager.onStartActivity

```java
    private void onStartActivity(final Context context, Bundle bundle, final EnterCallback callback) {
        final String pluginZipPath = bundle.getString(Constant.KEY_PLUGIN_ZIP_PATH);
        final String partKey = bundle.getString(Constant.KEY_PLUGIN_PART_KEY);
        final String className = bundle.getString(Constant.KEY_ACTIVITY_CLASSNAME);
        if (className == null) {
            throw new NullPointerException("className == null");
        }
        final Bundle extras = bundle.getBundle(Constant.KEY_EXTRAS);

        if (callback != null) {
            final View view = LayoutInflater.from(mCurrentContext).inflate(R.layout.activity_load_plugin, null);
            callback.onShowLoadingView(view);
        }

        executorService.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    InstalledPlugin installedPlugin = installPlugin(pluginZipPath, null, true);
                    Intent pluginIntent = new Intent();
                    pluginIntent.setClassName(
                            context.getPackageName(),
                            className
                    );
                    if (extras != null) {
                        pluginIntent.replaceExtras(extras);
                    }

                    startPluginActivity(installedPlugin, partKey, pluginIntent);
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
                if (callback != null) {
                    callback.onCloseLoadingView();
                }
            }
        });
    }
```
为了不阻塞进程，一般都会开启一个线程，进行加载插件包apk的数据。当加载成功后，就会启动插件的Activity。

##### 2.4.1 FastPluginManager.installPlugin

```java
    public InstalledPlugin installPlugin(String zip, String hash , boolean odex) throws IOException, JSONException, InterruptedException, ExecutionException {
        final PluginConfig pluginConfig = installPluginFromZip(new File(zip), hash);
        final String uuid = pluginConfig.UUID;
        List<Future> futures = new LinkedList<>();
        if (pluginConfig.runTime != null && pluginConfig.pluginLoader != null) {
            Future odexRuntime = mFixedPool.submit(new Callable() {
                @Override
                public Object call() throws Exception {
                    oDexPluginLoaderOrRunTime(uuid, InstalledType.TYPE_PLUGIN_RUNTIME,
                            pluginConfig.runTime.file);
                    return null;
                }
            });
            futures.add(odexRuntime);
            Future odexLoader = mFixedPool.submit(new Callable() {
                @Override
                public Object call() throws Exception {
                    oDexPluginLoaderOrRunTime(uuid, InstalledType.TYPE_PLUGIN_LOADER,
                            pluginConfig.pluginLoader.file);
                    return null;
                }
            });
            futures.add(odexLoader);
        }
        for (Map.Entry<String, PluginConfig.PluginFileInfo> plugin : pluginConfig.plugins.entrySet()) {
            final String partKey = plugin.getKey();
            final File apkFile = plugin.getValue().file;
            Future extractSo = mFixedPool.submit(new Callable() {
                @Override
                public Object call() throws Exception {
                    extractSo(uuid, partKey, apkFile);
                    return null;
                }
            });
            futures.add(extractSo);
            if (odex) {
                Future odexPlugin = mFixedPool.submit(new Callable() {
                    @Override
                    public Object call() throws Exception {
                        oDexPlugin(uuid, partKey, apkFile);
                        return null;
                    }
                });
                futures.add(odexPlugin);
            }
        }

        for (Future future : futures) {
            future.get();
        }
        onInstallCompleted(pluginConfig);

        return getInstalledPlugins(1).get(0);
    }
```

- 1.oDexPluginLoaderOrRunTime 安装 压缩包的runtime和loader的apk，并转化成dex。并复制到目标文件夹
- 2.extractSo 安装记录so的位置并复制到目标文件夹
- 3.oDexPlugin 把业务的apk转化成dex，拷贝到目标目录


#### 2.4.2 FastPluginManager startPluginActivity

```java
    public void startPluginActivity( InstalledPlugin installedPlugin, String partKey, Intent pluginIntent) throws RemoteException, TimeoutException, FailedException {
        Intent intent = convertActivityIntent(installedPlugin, partKey, pluginIntent);
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        mPluginLoader.startActivityInPluginProcess(intent);

    }

    public Intent convertActivityIntent(InstalledPlugin installedPlugin, String partKey, Intent pluginIntent) throws RemoteException, TimeoutException, FailedException {
        loadPlugin(installedPlugin.UUID, partKey);
        Map map = mPluginLoader.getLoadedPlugin();
        Boolean isCall = (Boolean) map.get(partKey);
        if (isCall == null || !isCall) {
            mPluginLoader.callApplicationOnCreate(partKey);
        }
        return mPluginLoader.convertActivityIntent(pluginIntent);
    }

    private void loadPluginLoaderAndRuntime(String uuid, String partKey) throws RemoteException, TimeoutException, FailedException {
        if (mPpsController == null) {
            bindPluginProcessService(getPluginProcessServiceName(partKey));
            waitServiceConnected(10, TimeUnit.SECONDS);
        }
        loadRunTime(uuid);
        loadPluginLoader(uuid);
    }

    private void loadPlugin(String uuid, String partKey) throws RemoteException, TimeoutException, FailedException {
        loadPluginLoaderAndRuntime(uuid, partKey);
        Map map = mPluginLoader.getLoadedPlugin();
        if (!map.containsKey(partKey)) {
            mPluginLoader.loadPlugin(partKey);
        }
    }
```

能看到这三个方法之间的关系：
- 1.启动一个Service服务，并等待服务10秒。在这10秒中会创建一个`mPluginLoader`对象
- 2.loadRunTime 通过`mPluginLoader` 加载runtime.apk的数据
- 3.loadPluginLoader 通过`mPluginLoader` 加载loader.apk的数据
- 4.mPluginLoader.loadPlugin 加载插件
- 5.mPluginLoader.callApplicationOnCreate 调用插件的Application的onCreate方法
- 6.convertActivityIntent 检查坑位和插件Activity的映射关系
- 7.mPluginLoader.startActivityInPluginProcess 启动Activity在插件进程


#### 2.5. manager工程通过BaseDynamicPluginManager启动插件进程

还记得在SampleManager中重载的`getPluginProcessServiceName `方法，其中写死了一个Service的类名：

```java
    @Override
    protected String getPluginProcessServiceName() {
        return "com.tencent.shadow.sample.introduce_shadow_lib.MainPluginProcessService";
    }
```

实际上是通过`bindPluginProcessService`这个方法启动这个Service：

```java
    public final void bindPluginProcessService(final String serviceName) {
        if (mServiceConnecting.get()) {
            if (mLogger.isInfoEnabled()) {
                mLogger.info("pps service connecting");
            }
            return;
        }
        if (mLogger.isInfoEnabled()) {
            mLogger.info("bindPluginProcessService " + serviceName);
        }

        mConnectCountDownLatch.set(new CountDownLatch(1));

        mServiceConnecting.set(true);

        final CountDownLatch startBindingLatch = new CountDownLatch(1);
        final boolean[] asyncResult = new boolean[1];
        mUiHandler.post(new Runnable() {
            @Override
            public void run() {
                Intent intent = new Intent();
                intent.setComponent(new ComponentName(mHostContext, serviceName));
                boolean binding = mHostContext.bindService(intent, new ServiceConnection() {
                    @Override
                    public void onServiceConnected(ComponentName name, IBinder service) {
                        if (mLogger.isInfoEnabled()) {
                            mLogger.info("onServiceConnected connectCountDownLatch:" + mConnectCountDownLatch);
                        }
                        mServiceConnecting.set(false);

                        // service connect 后处理逻辑
                        onPluginServiceConnected(name, service);

                        mConnectCountDownLatch.get().countDown();

                        if (mLogger.isInfoEnabled()) {
                            mLogger.info("onServiceConnected countDown:" + mConnectCountDownLatch);
                        }
                    }

                    @Override
                    public void onServiceDisconnected(ComponentName name) {
                        if (mLogger.isInfoEnabled()) {
                            mLogger.info("onServiceDisconnected");
                        }
                        mServiceConnecting.set(false);
                        onPluginServiceDisconnected(name);
                    }
                }, BIND_AUTO_CREATE);
                asyncResult[0] = binding;
                startBindingLatch.countDown();
            }
        });
        try {
            //等待bindService真正开始
            startBindingLatch.await(10, TimeUnit.SECONDS);
            if (!asyncResult[0]) {
                throw new IllegalArgumentException("无法绑定PPS:" + serviceName);
            }
        } catch (InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

    public final void waitServiceConnected(int timeout, TimeUnit timeUnit) throws TimeoutException {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw new RuntimeException("waitServiceConnected 不能在主线程中调用");
        }
        try {
            if (mLogger.isInfoEnabled()) {
                mLogger.info("waiting service connect connectCountDownLatch:" + mConnectCountDownLatch);
            }
            long s = System.currentTimeMillis();
            boolean isTimeout = !mConnectCountDownLatch.get().await(timeout, timeUnit);
            if (isTimeout) {
                throw new TimeoutException("连接Service超时 ,等待了：" + (System.currentTimeMillis() - s));
            }
            if (mLogger.isInfoEnabled()) {
                mLogger.info("service connected " + (System.currentTimeMillis() - s));
            }
        } catch (InterruptedException e) {
            throw new RuntimeException(e);
        }
    }
```
能看到这个过程十分的简单，实际上就是通过宿主的Context的bindService方法，启动一个固定类名的Service。并监听`onServiceConnected`方法，回调抽象方法`onPluginServiceConnected`.

而`onPluginServiceConnected`有两种实现，BaseDynamicPluginManager 的子类有两个：

- 1.`PluginManagerThatSupportMultiLoader` 
- 2.`PluginManagerThatUseDynamicLoader`

这里就挑选`PluginManagerThatUseDynamicLoader`进行解析。


##### 2.5.1  PluginManagerThatUseDynamicLoader onPluginServiceConnected

```java
   /**
     * 插件进程PluginProcessService的接口
     */
    protected PpsController mPpsController;

    /**
     * 插件加载服务端接口6
     */
    protected PluginLoader mPluginLoader;

    protected PluginManagerThatUseDynamicLoader(Context context) {
        super(context);
    }

    @Override
    protected void onPluginServiceConnected(ComponentName name, IBinder service) {
        mPpsController = PluginProcessService.wrapBinder(service);
        try {
            mPpsController.setUuidManager(new UuidManagerBinder(PluginManagerThatUseDynamicLoader.this));
        } catch (DeadObjectException e) {
            if (mLogger.isErrorEnabled()) {
                mLogger.error("onServiceConnected RemoteException:" + e);
            }
        } catch (RemoteException e) {
            if (e.getClass().getSimpleName().equals("TransactionTooLargeException")) {
                if (mLogger.isErrorEnabled()) {
                    mLogger.error("onServiceConnected TransactionTooLargeException:" + e);
                }
            } else {
                throw new RuntimeException(e);
            }
        }

        try {
            IBinder iBinder = mPpsController.getPluginLoader();
            if (iBinder != null) {
                mPluginLoader = new BinderPluginLoader(iBinder);
            }
        } catch (RemoteException ignored) {
            if (mLogger.isErrorEnabled()) {
                mLogger.error("onServiceConnected mPpsController getPluginLoader:", ignored);
            }
        }
    }
```
能看到这个过程，把对方服务端回调的Binder对象包裹成`PpsController`对象。

并调用PpsController对象的setUuidManager设置uuid给远端Service进程。接着通过`getPluginLoader`获取远端Service的Binder对象，并包装成`BinderPluginLoader`用于通信。

之后把所有的数据都往PpsController和PluginLoader通信相当于让所有的行为都交给远端Service所在的进程处理。

因为Context是从宿主中传递过来的，因此需要把该`getPluginProcessServiceName`对应的服务端类名注册到宿主中，且Class也需要声明在宿主中。

简单的看看宿主都做了什么吧。


##### 2.5.2 宿主声明的插件进程服务

需要现在宿主中声明：

```xml
        <service
            android:name=".MainPluginProcessService"
            android:process=":plugin" />
```

然后MainPluginProcessService继承PluginProcessService。

```java
/**
 * 一个PluginProcessService（简称PPS）代表一个插件进程。插件进程由PPS启动触发启动。
 * 新建PPS子类允许一个宿主中有多个互不影响的插件进程。
 */
public class MainPluginProcessService extends PluginProcessService {
}
```

所有的事务交给`PluginProcessService`处理。能看到在这里，一般都会通过`android:process`标示完全不同的进程。所有的组件也会生存在这个进程，因此在声明坑位的时候，需要和`MainPluginProcessService`标示为同一个进程。

```xml
        <activity
            android:name="com.tencent.shadow.sample.runtime.PluginDefaultProxyActivity"
            android:launchMode="standard"
            android:screenOrientation="portrait"
            android:configChanges="mcc|mnc|locale|touchscreen|keyboard|keyboardHidden|navigation|screenLayout|fontScale|uiMode|orientation|screenSize|smallestScreenSize|layoutDirection"
            android:hardwareAccelerated="true"
            android:theme="@style/PluginContainerActivity"
            android:process=":plugin" />
```

##### 2.4.2.2.1.PluginProcessService loadRuntime

```java
    void loadRuntime(String uuid) throws FailedException {
        checkUuidManagerNotNull();
        setUuid(uuid);
        if (mRuntimeLoaded) {
            throw new FailedException(ERROR_CODE_RELOAD_RUNTIME_EXCEPTION
                    , "重复调用loadRuntime");
        }
        try {
            if (mLogger.isInfoEnabled()) {
                mLogger.info("loadRuntime uuid:" + uuid);
            }
            InstalledApk installedApk;
            try {
                installedApk = mUuidManager.getRuntime(uuid);
            } catch (RemoteException e) {
                throw new FailedException(ERROR_CODE_UUID_MANAGER_DEAD_EXCEPTION, e.getMessage());
            } catch (NotFoundException e) {
                throw new FailedException(ERROR_CODE_FILE_NOT_FOUND_EXCEPTION, "uuid==" + uuid + "的Runtime没有找到。cause:" + e.getMessage());
            }

            InstalledApk installedRuntimeApk = new InstalledApk(installedApk.apkFilePath, installedApk.oDexPath, installedApk.libraryPath);
            boolean loaded = DynamicRuntime.loadRuntime(installedRuntimeApk);
            if (loaded) {
                DynamicRuntime.saveLastRuntimeInfo(this, installedRuntimeApk);
            }
            mRuntimeLoaded = true;
        } catch (RuntimeException e) {
            if (mLogger.isErrorEnabled()) {
                mLogger.error("loadRuntime发生RuntimeException", e);
            }
            throw new FailedException(e);
        }
    }
```

- 1.mUuidManager.getRuntime 实际上就是通信到Manager 所在的主进程获取之前在Manager中安装的runtime.apk的信息
- 2.DynamicRuntime.loadRuntime 装载runtime的ClassLoader
- 3.如果加载好了，就调用`saveLastRuntimeInfo` 把apk中的信息dex地址，so地址，apk地址都保存在sp中。


###### 2.5.3.DynamicRuntime loadRuntime

```java
    public static boolean loadRuntime(InstalledApk installedRuntimeApk) {
        ClassLoader contextClassLoader = DynamicRuntime.class.getClassLoader();
        RuntimeClassLoader runtimeClassLoader = getRuntimeClassLoader();
        if (runtimeClassLoader != null) {
            String apkPath = runtimeClassLoader.apkPath;
            if (mLogger.isInfoEnabled()) {
                mLogger.info("last apkPath:" + apkPath + " new apkPath:" + installedRuntimeApk.apkFilePath);
            }
            if (TextUtils.equals(apkPath, installedRuntimeApk.apkFilePath)) {
                //已经加载相同版本的runtime了,不需要加载
                if (mLogger.isInfoEnabled()) {
                    mLogger.info("已经加载相同apkPath的runtime了,不需要加载");
                }
                return false;
            } else {
                //版本不一样，说明要更新runtime，先恢复正常的classLoader结构
                if (mLogger.isInfoEnabled()) {
                    mLogger.info("加载不相同apkPath的runtime了,先恢复classLoader树结构");
                }
                try {
                    recoveryClassLoader();
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
            }
        }
        //正常处理，将runtime 挂到pathclassLoader之上
        try {
            hackParentToRuntime(installedRuntimeApk, contextClassLoader);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        return true;
    }

private static RuntimeClassLoader getRuntimeClassLoader() {
        ClassLoader contextClassLoader = DynamicRuntime.class.getClassLoader();
        ClassLoader tmpClassLoader = contextClassLoader.getParent();
        while (tmpClassLoader != null) {
            if (tmpClassLoader instanceof RuntimeClassLoader) {
                return (RuntimeClassLoader) tmpClassLoader;
            }
            tmpClassLoader = tmpClassLoader.getParent();
        }
        return null;
    }


    private static void hackParentToRuntime(InstalledApk installedRuntimeApk, ClassLoader contextClassLoader) throws Exception {
        RuntimeClassLoader runtimeClassLoader = new RuntimeClassLoader(installedRuntimeApk.apkFilePath, installedRuntimeApk.oDexPath,
                installedRuntimeApk.libraryPath, contextClassLoader.getParent());
        hackParentClassLoader(contextClassLoader, runtimeClassLoader);
    }

    static class RuntimeClassLoader extends BaseDexClassLoader {
        /**
         * 加载的apk路径
         */
        private String apkPath;


        RuntimeClassLoader(String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent) {
            super(dexPath, optimizedDirectory == null ? null : new File(optimizedDirectory), librarySearchPath, parent);
            this.apkPath = dexPath;
        }
    }
```
能看到这个过程是十分简单的，就是把runtime.apk 的路径生成一个RuntimeClassLoader，并通过反射，设置为为当前进程ClassLoader父ClassLoader。

由于ClassLoader的双亲委托机制，当前进程要查找runtime中设置的坑位时候，通过委托机制会优先交给RuntimeClassLoader进行查找。这样宿主的`AndroidManifest.xml`注册了坑位，且在插件进程的ClassLoader 也注入了Class。

这样就保证了在插件进程，看起来就像AndroidManifest和Class 都在同一模块一样。这么做的好处是显而易见的，可以拆开实现，这样就能在插件包中自定义坑位逻辑，而不需要更新宿主。


##### 2.5.4.PluginProcessService loadPluginLoader

```java
    void loadPluginLoader(String uuid) throws FailedException {
        if (mLogger.isInfoEnabled()) {
            mLogger.info("loadPluginLoader uuid:" + uuid + " mPluginLoader:" + mPluginLoader);
        }
        checkUuidManagerNotNull();
        setUuid(uuid);
        if (mPluginLoader != null) {
            throw new FailedException(ERROR_CODE_RELOAD_LOADER_EXCEPTION
                    , "重复调用loadPluginLoader");
        }
        try {
            InstalledApk installedApk;
            try {
...
            PluginLoaderImpl pluginLoader = new LoaderImplLoader().load(installedApk, uuid, getApplicationContext());
            pluginLoader.setUuidManager(mUuidManager);
            mPluginLoader = pluginLoader;
        } catch (RuntimeException e) {
...
        } catch (FailedException e) {
...
        } catch (Exception e) {
..
        }
    }
```

通过`LoaderImplLoader.load`方法，开始加载loader.apk中的内容。并调用`pluginLoader.setUuidManager`设置`mUuidManager`.最后`PluginLoaderImpl`作为全局变量保存下来。

接下来就到了loader.apk的加载时机了


#### 2.5.5 LoaderImplLoader.load 加载loader.apk

```java
final class LoaderImplLoader extends ImplLoader {
    /**
     * 加载{@link #sLoaderFactoryImplClassName}时
     * 需要从宿主PathClassLoader（含双亲委派）中加载的类
     */
    private static final String[] sInterfaces = new String[]{
            //当runtime是动态加载的时候，runtime的ClassLoader是PathClassLoader的parent，
            // 所以不需要写在这个白名单里。但是写在这里不影响，也可以兼容runtime打包在宿主的情况。
            "com.tencent.shadow.core.runtime.container",
            "com.tencent.shadow.dynamic.host",
            "com.tencent.shadow.core.common"
    };

    private final static String sLoaderFactoryImplClassName
            = "com.tencent.shadow.dynamic.loader.impl.LoaderFactoryImpl";

    PluginLoaderImpl load(InstalledApk installedApk, String uuid, Context appContext) throws Exception {
        ApkClassLoader pluginLoaderClassLoader = new ApkClassLoader(
                installedApk,
                LoaderImplLoader.class.getClassLoader(),
                loadWhiteList(installedApk),
                1
        );
        LoaderFactory loaderFactory = pluginLoaderClassLoader.getInterface(
                LoaderFactory.class,
                sLoaderFactoryImplClassName
        );

        return loaderFactory.buildLoader(uuid, appContext);
    }

    @Override
    String[] getCustomWhiteList() {
        return sInterfaces;
    }
}
```
能看到这个过程也是类似的，通过loader.apk生成一个`ApkClassLoader`，并获取一个固定的类名`LoaderFactoryImpl`并实例化，最后调用`buildLoader`方法。

```kotlin
@Deprecated("兼容旧版本dynamic-host访问这个类名", level = DeprecationLevel.HIDDEN)
class LoaderFactoryImpl : com.tencent.shadow.dynamic.loader.impl.LoaderFactoryImpl() {
}
```

```kotlin
open class LoaderFactoryImpl : LoaderFactory {
    override fun buildLoader(p0: String, p2: Context): PluginLoaderImpl {
        return PluginLoaderBinder(DynamicPluginLoader(p2, p0))
    }
}
```

能看到实际上就是返回了`PluginLoaderBinder`对象。注意这是一个Binder对象。当有Manager所在的进程调用PluginLoader对应的方式时候，实际上调用就是`DynamicPluginLoader`对象对应的方法。


来看看`DynamicPluginLoader `的构造函数。

##### 2.5.6.DynamicPluginLoader 构建SamplePluginLoader

```kotlin
    open val delegateProviderKey: String = DelegateProviderHolder.DEFAULT_KEY
```

```kotlin
    companion object {
        private const val CORE_LOADER_FACTORY_IMPL_NAME =
                "com.tencent.shadow.dynamic.loader.impl.CoreLoaderFactoryImpl"
    }
    init {
        try {
            val coreLoaderFactory = mDynamicLoaderClassLoader.getInterface(
                    CoreLoaderFactory::class.java,
                    CORE_LOADER_FACTORY_IMPL_NAME
            )
            mPluginLoader = coreLoaderFactory.build(hostContext)
            DelegateProviderHolder.setDelegateProvider(mPluginLoader.delegateProviderKey, mPluginLoader)
            ContentProviderDelegateProviderHolder.setContentProviderDelegateProvider(mPluginLoader)
            mPluginLoader.onCreate()
        } catch (e: Exception) {
            throw RuntimeException("当前的classLoader找不到PluginLoader的实现", e)
        }
        mContext = hostContext;
        mUuid = uuid;
    }
```

- 这个过程先反射loader.apk中的`CoreLoaderFactoryImpl`对象，并调用build方法。此时在`DynamicPluginLoader`中的`mPluginLoader`,实际上就是指我们自定义的SamplePluginLoader。注意这个对象是继承于`ShadowPluginLoader`.

- DelegateProviderHolder.setDelegateProvider 缓存SamplePluginLoader到一个map中，key为`DEFAULT_KEY`. 说明其实在Shadow的manager进程中，支持多个Loader来处理映射关系

- 将`mPluginLoader`缓存到`ContentProviderDelegateProviderHolder`的静态变量`contentProviderDelegateProvider`.

- 调用`mPluginLoader`的`onCreate`


```kotlin
    fun onCreate(){
        mComponentManager = getComponentManager()
        mComponentManager.setPluginContentProviderManager(mPluginContentProviderManager)
    }
```

很简单就是取出了SamplePluginLoader中声明的SampleComponentManager 对象，保存到`ShadowPluginLoader`中



##### 2.5.6 Manager进程 loadPlugin

注意在 `PluginProcessService`中返回如下Binder

```java
    private final PpsBinder mPpsControllerBinder = new PpsBinder(this);

    @Override
    public IBinder onBind(Intent intent) {
        if (mLogger.isInfoEnabled()) {
            mLogger.info("onBind:" + this);
        }
        return mPpsControllerBinder;
    }
```

实际上这个Binder就是操作`PluginProcessService`。

在Manager进程中做了两个步骤进行加载插件

- 1.获取PluginProcessService 的 PluginLoaderImpl 对象
- 2.调用PluginLoaderImpl的loadPlugin

而这个`PluginLoaderImpl`就是指上文的`PluginLoaderBinder`对象.此时loadPlugin调用的就是DynamicPluginLoader如下方法：

```java
    fun loadPlugin(partKey: String) {
        val installedApk = mUuidManager.getPlugin(mUuid, partKey)
        val future = mPluginLoader.loadPlugin(installedApk)
        future.get()
    }
```

###### ShadowPluginLoader loadPlugin

```kotlin
    @Throws(LoadPluginException::class)
    open fun loadPlugin(
            installedApk: InstalledApk
    ): Future<*> {
        val loadParameters = installedApk.getLoadParameters()
        if (mLogger.isInfoEnabled) {
            mLogger.info("start loadPlugin")
        }
        // 在这里初始化PluginServiceManager
        mPluginServiceManagerLock.withLock {
            if (!::mPluginServiceManager.isInitialized) {
                mPluginServiceManager = PluginServiceManager(this, mHostAppContext)
            }

            mComponentManager.setPluginServiceManager(mPluginServiceManager)
        }

        return LoadPluginBloc.loadPlugin(
                mExecutorService,
                mPluginPackageInfoSet,
                ::allPluginPackageInfo,
                mComponentManager,
                mLock,
                mPluginPartsMap,
                mHostAppContext,
                installedApk,
                loadParameters)
    }
```
- 1.创建一个mPluginServiceManager 对象并保存到mComponentManager 中
- 2.在LoadPluginBloc方法将会对Plugin所有的核心数据进行解析

##### LoadPluginBloc loadPlugin

```kotlin
 @Throws(LoadPluginException::class)
    fun loadPlugin(
            executorService: ExecutorService,
            pluginPackageInfoSet: MutableSet<PackageInfo>,
            allPluginPackageInfo: () -> (Array<PackageInfo>),
            componentManager: ComponentManager,
            lock: ReentrantLock,
            pluginPartsMap: MutableMap<String, PluginParts>,
            hostAppContext: Context,
            installedApk: InstalledApk,
            loadParameters: LoadParameters
    ): Future<*> {
        if (installedApk.apkFilePath == null) {
            throw LoadPluginException("apkFilePath==null")
        } else {
            val buildClassLoader = executorService.submit(Callable {
                lock.withLock {
                    LoadApkBloc.loadPlugin(installedApk, loadParameters, pluginPartsMap)
                }
            })

            val getPackageInfo = executorService.submit(Callable {
                val archiveFilePath = installedApk.apkFilePath
                val packageManager = hostAppContext.packageManager

                val packageArchiveInfo = packageManager.getPackageArchiveInfo(
                        archiveFilePath,
                        PackageManager.GET_ACTIVITIES
                                or PackageManager.GET_META_DATA
                                or PackageManager.GET_SERVICES
                                or PackageManager.GET_PROVIDERS
                                or PackageManager.GET_SIGNATURES
                )
                        ?: throw NullPointerException("getPackageArchiveInfo return null.archiveFilePath==$archiveFilePath")

                val tempContext = ShadowContext(hostAppContext, 0).apply {
                    setBusinessName(loadParameters.businessName)
                }
                val dataDir = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    tempContext.dataDir
                } else {
                    File(tempContext.filesDir, "dataDir")
                }
                dataDir.mkdirs()

                packageArchiveInfo.applicationInfo.nativeLibraryDir = installedApk.libraryPath
                packageArchiveInfo.applicationInfo.dataDir = dataDir.absolutePath
                packageArchiveInfo.applicationInfo.processName = hostAppContext.applicationInfo.processName
                packageArchiveInfo.applicationInfo.uid = hostAppContext.applicationInfo.uid

                lock.withLock { pluginPackageInfoSet.add(packageArchiveInfo) }
                packageArchiveInfo
            })

            val buildPluginInfo = executorService.submit(Callable {
                val packageInfo = getPackageInfo.get()
                ParsePluginApkBloc.parse(packageInfo, loadParameters, hostAppContext)
            })

            val buildPackageManager = executorService.submit(Callable {
                val packageInfo = getPackageInfo.get()
                val hostPackageManager = hostAppContext.packageManager
                PluginPackageManagerImpl(hostPackageManager, packageInfo, allPluginPackageInfo)
            })

            val buildResources = executorService.submit(Callable {
                val packageInfo = getPackageInfo.get()
                CreateResourceBloc.create(packageInfo, installedApk.apkFilePath, hostAppContext)
            })

            val buildAppComponentFactory = executorService.submit(Callable<ShadowAppComponentFactory> {
                val pluginClassLoader = buildClassLoader.get()
                val pluginInfo = buildPluginInfo.get()
                if (pluginInfo.appComponentFactory != null) {
                    val clazz = pluginClassLoader.loadClass(pluginInfo.appComponentFactory)
                    ShadowAppComponentFactory::class.java.cast(clazz.newInstance())
                } else ShadowAppComponentFactory()
            })

            val buildApplication = executorService.submit(Callable {
                val pluginClassLoader = buildClassLoader.get()
                val resources = buildResources.get()
                val pluginInfo = buildPluginInfo.get()
                val packageInfo = getPackageInfo.get()
                val appComponentFactory = buildAppComponentFactory.get()

                CreateApplicationBloc.createShadowApplication(
                        pluginClassLoader,
                        pluginInfo,
                        resources,
                        hostAppContext,
                        componentManager,
                        packageInfo.applicationInfo,
                        appComponentFactory
                )
            })

            val buildRunningPlugin = executorService.submit {
                if (File(installedApk.apkFilePath).exists().not()) {
                    throw LoadPluginException("插件文件不存在.pluginFile==" + installedApk.apkFilePath)
                }
                val pluginPackageManager = buildPackageManager.get()
                val pluginClassLoader = buildClassLoader.get()
                val resources = buildResources.get()
                val pluginInfo = buildPluginInfo.get()
                val shadowApplication = buildApplication.get()
                val appComponentFactory = buildAppComponentFactory.get()
                lock.withLock {
                    componentManager.addPluginApkInfo(pluginInfo)
                    pluginPartsMap[pluginInfo.partKey] = PluginParts(
                            appComponentFactory,
                            shadowApplication,
                            pluginClassLoader,
                            resources,
                            pluginInfo.businessName,
                            pluginPackageManager
                    )
                    PluginPartInfoManager.addPluginInfo(pluginClassLoader, PluginPartInfo(shadowApplication, resources,
                            pluginClassLoader, pluginPackageManager))
                }
            }

            return buildRunningPlugin
        }
    }
```

能看到整个过程都是通过线程的Future方式并发执行的。

- 1. buildClassLoader 实际上就是转化apk的路径为一个PluginClassLoader
- 2.getPackageInfo 则是通过`packageManager.getPackageArchiveInfo`读取该apk中所有的四大组件相关的信息
- 3. buildPluginInfo 根据getPackageInfo返回的内容生成PluginInfo。注意在这个过程中会校验宿主的Context的packageName是否和插件包的xml中的包名一直。只有一致才会继续解析出插件信息。

```kotlin
    @Throws(ParsePluginApkException::class)
    fun parse(packageArchiveInfo: PackageInfo, loadParameters: LoadParameters, hostAppContext: Context): PluginInfo {
        if (packageArchiveInfo.applicationInfo.packageName != hostAppContext.packageName) {
            /*
            要求插件和宿主包名一致有两方面原因：
            1.正常的构建过程中，aapt会将包名写入到arsc文件中。插件正常安装运行时，如果以
            android.content.Context.getPackageName为参数传给
            android.content.res.Resources.getIdentifier方法，可以正常获取到资源。但是在插件环境运行时，
            Context.getPackageName会得到宿主的packageName，则getIdentifier方法不能正常获取到资源。为此，
            一个可选的办法是继承Resources，覆盖getIdentifier方法。但是Resources的构造器已经被标记为
            @Deprecated了，未来可能会不可用，因此不首选这个方法。

            2.Android系统，更多情况下是OEM修改的Android系统，会在我们的context上调用getPackageName或者
            getOpPackageName等方法，然后将这个packageName跨进程传递做它用。系统的其他代码会以这个packageName
            去PackageManager中查询权限等信息。如果插件使用自己的包名，就需要在Context的getPackageName等实现中
            new Throwable()，然后判断调用来源以决定返回自己的包名还是插件的包名。但是如果保持采用宿主的包名，则没有
            这个烦恼。

            我们也可以始终认为Shadow App是宿主的扩展代码，使用是宿主的一部分，那么采用宿主的包名就是理所应当的了。
             */
            throw ParsePluginApkException("插件和宿主包名不一致。宿主:${hostAppContext.packageName} 插件:${packageArchiveInfo.applicationInfo.packageName}")
        }

        /*
        partKey的作用是用来区分一个Component是来自于哪个插件apk的
         */
        val partKey = loadParameters.partKey

        val pluginInfo = PluginInfo(
                loadParameters.businessName
                , partKey
                , packageArchiveInfo.applicationInfo.packageName
                , packageArchiveInfo.applicationInfo.className
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pluginInfo.appComponentFactory = packageArchiveInfo.applicationInfo.appComponentFactory
        }
        packageArchiveInfo.activities?.forEach {
            pluginInfo.putActivityInfo(PluginActivityInfo(it.name, it.themeResource, it))
        }
        packageArchiveInfo.services?.forEach { pluginInfo.putServiceInfo(PluginServiceInfo(it.name)) }
        packageArchiveInfo.providers?.forEach {
            pluginInfo.putPluginProviderInfo(PluginProviderInfo(it.name, it.authority, it))
        }
        return pluginInfo
    }
```

注解上说的挺好的。如果不明白的，可以阅读我之前写的[Android资源管理系列文章](https://www.jianshu.com/p/817a787910f2)。这里面详细的阐述了Android是如何管理资源的。

简单来说就是在Android的资源管理中，有多重缓存。这里不想像我之前写的插件化文章一样一个自己生成ResourceImpl 设置进去管理，因为方法被标记为`@Deprecated`了。

其次就是动态权限相关的，如果阅读过相关的源码就能明白在动态权限中，所有的信息都保存在一个xml文件中。这个xml权限将以packageName+permissionName等为key记录相关信息。在Shadow看来，一来插件并不是真正的安装在Android系统中不符合规范，而来实际上插件对于宿主来说也是一种延伸。

因此需要保证宿主的packageName和插件记录在AndroidManifest中的packageName一致。

- 4.生成一个PluginPackageManagerImpl 对象

- 5.CreateResourceBloc.create 更新宿主的ResourceImpl。这个方式属于比较熟悉源码的人才能明白。

```kotlin
    fun create(packageArchiveInfo: PackageInfo, archiveFilePath: String, hostAppContext: Context): Resources {
        //先用宿主context初始化一个WebView，以便WebView的逻辑去修改sharedLibraryFiles，将webview.apk添加进去
        val latch = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            WebView(hostAppContext)
            latch.countDown()
        }
        latch.await()

        val packageManager = hostAppContext.packageManager
        packageArchiveInfo.applicationInfo.publicSourceDir = archiveFilePath
        packageArchiveInfo.applicationInfo.sourceDir = archiveFilePath
        packageArchiveInfo.applicationInfo.sharedLibraryFiles = hostAppContext.applicationInfo.sharedLibraryFiles
        try {
            return packageManager.getResourcesForApplication(packageArchiveInfo.applicationInfo)
        } catch (e: PackageManager.NameNotFoundException) {
            throw RuntimeException(e)
        }
    }
```
在这过程中，核心的方法只有`getResourcesForApplication`这个。它最终会调用到ResourceManager的`getOrCreateResources `方法中。那么此时会在ResourceManager中为当前的apk资源创建一个全新的ResourceImpl。

- 6.创建一个`ShadowAppComponentFactory`,用于对于xml中的`appComponentFactory`。

- 7.`CreateApplicationBloc.createShadowApplication`根据以上plugin信息实例化一个插件的Application，但是插件的Application的已经通过gradle插件转化为ShadowApplication了

- 8. `componentManager.addPluginApkInfo` 对坑位和插件的Activity进行映射。

```kotlin
    fun addPluginApkInfo(pluginInfo: PluginInfo) {
        fun common(pluginComponentInfo: PluginComponentInfo,componentName:ComponentName) {
            packageNameMap[pluginComponentInfo.className!!] = pluginInfo.packageName
            val previousValue = pluginInfoMap.put(componentName, pluginInfo)
            if (previousValue != null) {
                throw IllegalStateException("重复添加Component：$componentName")
            }
            pluginComponentInfoMap[componentName] = pluginComponentInfo
        }

        pluginInfo.mActivities.forEach {
            val componentName = ComponentName(pluginInfo.packageName, it.className!!)
            common(it,componentName)
            componentMap[componentName] = onBindContainerActivity(componentName)
        }

        pluginInfo.mServices.forEach {
            val componentName = ComponentName(pluginInfo.packageName, it.className!!)
            common(it,componentName)
        }

        pluginInfo.mProviders.forEach {
            val componentName = ComponentName(pluginInfo.packageName, it.className!!)
            mPluginContentProviderManager!!.addContentProviderInfo(pluginInfo.partKey,it,onBindContainerContentProvider(componentName))
        }
    }
```

核心方法在`onBindContainerActivity`.这个方法需要我们进行重载，如上文的

```java
    private static final String DEFAULT_ACTIVITY = "com.tencent.shadow.sample.runtime.PluginDefaultProxyActivity";
    @Override
    public ComponentName onBindContainerActivity(ComponentName pluginActivity) {
        switch (pluginActivity.getClassName()) {
            /**
             * 这里配置对应的对应关系
             */
            case "com.sample.test.SampleActivity":
                return new ComponentName(context, DEFAULT_NATIVE_ACTIVITY);
        }
        return new ComponentName(context, DEFAULT_ACTIVITY);
    }
```
因此这个方法是对runtime中的坑位和实际插件业务Activity之间的映射关系。

- 9.最后把这些信息都保存到PluginPartInfoManager。


### 3.BinderPluginLoader.callApplicationOnCreate

接下来在Manager进程就会调用`PluginLoader.callApplicationOnCreate`.而这个PluginLoader对象实际上是一个Binder对象，最后会调用到DynamicPluginLoader中。而这个方法最后又会调用到ShadowPluginLoader中。

当然这个过程只会调用一次，通过一个Map来记录那些插件是已经加载过了。

```kotlin
    fun callApplicationOnCreate(partKey: String) {
        fun realAction() {
            val pluginParts = getPluginParts(partKey)
            pluginParts?.let {
                val application = pluginParts.application
                application.attachBaseContext(mHostAppContext)
                mPluginContentProviderManager.createContentProviderAndCallOnCreate(
                        application, partKey, pluginParts)
                application.onCreate()
            }
        }
        if (isUiThread()) {
            realAction()
        } else {
            val waitUiLock = CountDownLatch(1)
            mUiHandler.post {
                realAction()
                waitUiLock.countDown()
            }
            waitUiLock.await();
        }
    }
```
```java

    fun createContentProviderAndCallOnCreate(mContext: Context, partKey: String, pluginParts: PluginParts?) {
        pluginProviderInfoMap[partKey]?.forEach {
            try {
                val contentProvider = pluginParts!!.appComponentFactory
                        .instantiateProvider(pluginParts.classLoader, it.className)
                contentProvider?.attachInfo(mContext, it.providerInfo)
                providerMap[it.authority!!] = contentProvider
            } catch (e: Exception) {
                throw RuntimeException("partKey==$partKey className==${it.className} providerInfo==${it.providerInfo}", e)
            }
        }

    }
```

能看到这里的顺序，和源码的顺序一致：依次调用业务插件Application的`attachBaseContext`，`CP的attachInfo`,`Application的onCreate`


#### 4. DynamicPluginLoader convertActivityIntent

接下来Mananager进程，调用BinderPluginLoader的convertActivityIntent，而这个方法最终还是调用到了`DynamicPluginLoader`中。

```kotlin
    fun convertActivityIntent(pluginActivityIntent: Intent): Intent? {
        return mPluginLoader.mComponentManager.convertPluginActivityIntent(pluginActivityIntent)
    }
```

```kotlin
    override fun convertPluginActivityIntent(pluginIntent: Intent): Intent {
        return if (pluginIntent.isPluginComponent()) {
            pluginIntent.toActivityContainerIntent()
        } else {
            pluginIntent
        }
    }

    /**
     * 调用前必须先调用isPluginComponent判断Intent确实一个插件内的组件
     */
    private fun Intent.toActivityContainerIntent(): Intent {
        val bundleForPluginLoader = Bundle()
        val pluginComponentInfo = pluginComponentInfoMap[component]!!
        bundleForPluginLoader.putParcelable(CM_ACTIVITY_INFO_KEY, pluginComponentInfo)
        return toContainerIntent(bundleForPluginLoader)
    }

    /**
     * 构造pluginIntent对应的ContainerIntent
     * 调用前必须先调用isPluginComponent判断Intent确实一个插件内的组件
     */
    private fun Intent.toContainerIntent(bundleForPluginLoader: Bundle): Intent {
        val component = this.component!!
        val className = component.className
        val packageName = packageNameMap[className]!!
        this.component = ComponentName(packageName, className)
        val containerComponent = componentMap[component]!!
        val businessName = pluginInfoMap[component]!!.businessName
        val partKey = pluginInfoMap[component]!!.partKey

        val pluginExtras: Bundle? = extras
        replaceExtras(null as Bundle?)

        val containerIntent = Intent(this)
        containerIntent.component = containerComponent

        bundleForPluginLoader.putString(CM_CLASS_NAME_KEY, className)
        bundleForPluginLoader.putString(CM_PACKAGE_NAME_KEY, packageName)

        containerIntent.putExtra(CM_EXTRAS_BUNDLE_KEY, pluginExtras)
        containerIntent.putExtra(CM_BUSINESS_NAME_KEY, businessName)
        containerIntent.putExtra(CM_PART_KEY, partKey)
        containerIntent.putExtra(CM_LOADER_BUNDLE_KEY, bundleForPluginLoader)
        containerIntent.putExtra(LOADER_VERSION_KEY, BuildConfig.VERSION_NAME)
        containerIntent.putExtra(PROCESS_ID_KEY, DelegateProviderHolder.sCustomPid)
        return containerIntent
    }
```
Shadow，在启动插件Activity的时候，直接写入类名到Intent中。接着会在DynamicPluginLoader中检查之前通过addPluginInfo 完成的映射关系。把插件的Activity对应的坑位变成目标启动的Activity。而原来插件的Activity将会存到Intent中。

等待坑位的处理。


此时我们假设是映射的是一个`PluginDefaultProxyActivity`.那么`PluginDefaultProxyActivity(继承了PluginContainerActivity)`这个Activity声明在AndroidManifest.xml的进程刚好是`plugin`。就是通过这个手段达到的跨进程启动Activity的手段。


##### 5.坑位PluginContainerActivity 构造函数


```java
    public PluginContainerActivity() {
        HostActivityDelegate delegate;
        DelegateProvider delegateProvider = DelegateProviderHolder.getDelegateProvider(getDelegateProviderKey());
        if (delegateProvider != null) {
            delegate = delegateProvider.getHostActivityDelegate(this.getClass());
            delegate.setDelegator(this);
        } else {
            Log.e(TAG, "PluginContainerActivity: DelegateProviderHolder没有初始化");
            delegate = null;
        }
        super.hostActivityDelegate = delegate;
        hostActivityDelegate = delegate;
    }
```

还记得之前把`SamplePluginLoader`存到了`DelegateProviderHolder`中。此时把它取出来。而刚好的是loader和runtime正好在插件进程。

因此这样才能那个在找到SamplePluginLoader。而这里`delegateProvider`就是指`SamplePluginLoader`.

```kotlin
    override fun getHostActivityDelegate(aClass: Class<out HostActivityDelegator>): HostActivityDelegate {
        return ShadowActivityDelegate(this)
    }
```

此时会返回一个`ShadowActivityDelegate`对象并把调用`setDelegator`，设置当前的Activity为代理者。并设置到全局`hostActivityDelegate`.

之后所有坑位相关的生命周期都会传递到`ShadowActivityDelegate`中处理。就以onCreate为例子

#### 5.PluginContainerActivity onCreate

```java
    @Override
    final protected void onCreate(Bundle savedInstanceState) {
        isBeforeOnCreate = false;
        mHostTheme = null;//释放资源

        boolean illegalIntent = isIllegalIntent(savedInstanceState);
        if (illegalIntent) {
            super.hostActivityDelegate = null;
            hostActivityDelegate = null;
            Log.e(TAG, "illegalIntent savedInstanceState==" + savedInstanceState + " getIntent().getExtras()==" + getIntent().getExtras());
        }

        if (hostActivityDelegate != null) {
            hostActivityDelegate.onCreate(savedInstanceState);
        } else {
            //这里是进程被杀后重启后走到，当需要恢复fragment状态的时候，由于系统保留了TAG，会因为找不到fragment引起crash
            super.onCreate(null);
            Log.e(TAG, "onCreate: hostActivityDelegate==null finish activity");
            finish();
            System.exit(0);
        }
    }
```

首先校验插件包对应的loader版本是否和VersionName一致，以及判断进程号是否改变了。一旦出现了问题则拒绝启动插件的Activity。

接着才会走到`ShadowActivityDelegate`的onCreate


#### 6.ShadowActivityDelegate onCreate 

```kotlin
  override fun onCreate(savedInstanceState: Bundle?) {
        val pluginInitBundle = savedInstanceState ?: mHostActivityDelegator.intent.extras!!

        mCallingActivity = pluginInitBundle.getParcelable(CM_CALLING_ACTIVITY_KEY)
        mBusinessName = pluginInitBundle.getString(CM_BUSINESS_NAME_KEY, "")
        val partKey = pluginInitBundle.getString(CM_PART_KEY)!!
        mPartKey = partKey
        mDI.inject(this, partKey)
        mDependenciesInjected = true

        mMixResources = MixResources(mHostActivityDelegator.superGetResources(), mPluginResources)

        val bundleForPluginLoader = pluginInitBundle.getBundle(CM_LOADER_BUNDLE_KEY)!!
        mBundleForPluginLoader = bundleForPluginLoader
        bundleForPluginLoader.classLoader = this.javaClass.classLoader
        val pluginActivityClassName = bundleForPluginLoader.getString(CM_CLASS_NAME_KEY)!!
        val pluginActivityInfo: PluginActivityInfo = bundleForPluginLoader.getParcelable(CM_ACTIVITY_INFO_KEY)!!

        mCurrentConfiguration = Configuration(resources.configuration)
        mPluginHandleConfigurationChange =
                (pluginActivityInfo.activityInfo!!.configChanges
                        or ActivityInfo.CONFIG_SCREEN_SIZE//系统本身就会单独对待这个属性，不声明也不会重启Activity。
                        or ActivityInfo.CONFIG_SMALLEST_SCREEN_SIZE//系统本身就会单独对待这个属性，不声明也不会重启Activity。
                        or 0x20000000 //见ActivityInfo.CONFIG_WINDOW_CONFIGURATION 系统处理属性
                        )
        if (savedInstanceState == null) {
            mRawIntentExtraBundle = pluginInitBundle.getBundle(CM_EXTRAS_BUNDLE_KEY)
            mHostActivityDelegator.intent.replaceExtras(mRawIntentExtraBundle)
        }
        mHostActivityDelegator.intent.setExtrasClassLoader(mPluginClassLoader)

        try {
            val pluginActivity = mAppComponentFactory.instantiateActivity(
                    mPluginClassLoader,
                    pluginActivityClassName,
                    mHostActivityDelegator.intent
            )
            initPluginActivity(pluginActivity, pluginActivityInfo)
            super.pluginActivity = pluginActivity

            if (mLogger.isDebugEnabled) {
                mLogger.debug("{} mPluginHandleConfigurationChange=={}", mPluginActivity.javaClass.canonicalName, mPluginHandleConfigurationChange)
            }

            //使PluginActivity替代ContainerActivity接收Window的Callback
            mHostActivityDelegator.window.callback = pluginActivity

            //设置插件AndroidManifest.xml 中注册的WindowSoftInputMode
            mHostActivityDelegator.window.setSoftInputMode(pluginActivityInfo.activityInfo.softInputMode)

            //Activity.onCreate调用之前应该先收到onWindowAttributesChanged。
            if (mCallOnWindowAttributesChanged) {
                pluginActivity.onWindowAttributesChanged(
                    mBeforeOnCreateOnWindowAttributesChangedCalledParams
                )
                mBeforeOnCreateOnWindowAttributesChangedCalledParams = null
            }

            val pluginSavedInstanceState: Bundle? =
                savedInstanceState?.getBundle(PLUGIN_OUT_STATE_KEY)
            pluginSavedInstanceState?.classLoader = mPluginClassLoader
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                notifyPluginActivityPreCreated(pluginActivity, pluginSavedInstanceState)
            }
            pluginActivity.onCreate(pluginSavedInstanceState)
            mPluginActivityCreated = true
        } catch (e: Exception) {
            throw RuntimeException(e)
        }
    }
```

这个过程实际上很简单，实例化插件的Activity对象后。

- initPluginActivity 初始化插件的Activity。注意插件的Activity已经被替换成了ShadowActivity了。这个方法中为插件Activity设置了classLoader，application等核心参数
- 插件的Activity监听来自坑位的Window.Callback.以及处理setSoftInputMode
- 调用插件Activity的onCreate


#### 7.gradle-plugin插件库的原理

这里就不详细描述插件业务依赖的gradle插件原理。核心方法在`ShadowPlugin`中。这个插件的职责是打包出插件包以及转化插件工程中组件集成的对象。如继承于Activity，就被转化成继承ShadowActivity。

不熟悉Gradle的读者，可以阅读我之前写的[Gradle入门](https://www.jianshu.com/p/d1099b77a753)

核心就是这个task
```groovy
        if (!project.hasProperty("disable_shadow_transform")) {
            baseExtension.registerTransform(ShadowTransform(
                    project,
                    classPoolBuilder,
                    { shadowExtension.transformConfig.useHostContext }
            ))
        }
```

其中他设置了如下转化器

```groovy
class TransformManager(ctClassInputMap: Map<CtClass, InputClass>,
                       classPool: ClassPool,
                       useHostContext: () -> Array<String>
) : AbstractTransformManager(ctClassInputMap, classPool) {

    override val mTransformList: List<SpecificTransform> = listOf(
            ApplicationTransform(),
            ActivityTransform(),
            ServiceTransform(),
            IntentServiceTransform(),
            InstrumentationTransform(),
            FragmentSupportTransform(),
            DialogSupportTransform(),
            WebViewTransform(),
            ContentProviderTransform(),
            PackageManagerTransform(),
            PackageItemInfoTransform(),
            AppComponentFactoryTransform(),
            LayoutInflaterTransform(),
            KeepHostContextTransform(useHostContext())
    )
}

class ApplicationTransform : SimpleRenameTransform(
        mapOf(
                "android.app.Application"
                        to "com.tencent.shadow.core.runtime.ShadowApplication"
                ,
                "android.app.Application\$ActivityLifecycleCallbacks"
                        to "com.tencent.shadow.core.runtime.ShadowActivityLifecycleCallbacks"
        )
)

class ActivityTransform : SimpleRenameTransform(
        mapOf(
                "android.app.Activity"
                        to "com.tencent.shadow.core.runtime.ShadowActivity"
        )
)
```

能看到这个映射方式，很简单。就是把代码中的Application 全部替换成ShadowApplication。Activity全部替换成ShadowActivity。

因此插件库中所有的Activity本质上就是ShadowActivity。

## 总结

用一张图简单总结：
![Shadow.png](/images/Shadow.png)


## 后记

至此Shadow的全流程就解析就完成了。后续会恢复正常，开始有规律的开始更新文章。