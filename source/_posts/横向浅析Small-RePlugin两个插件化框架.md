---
title: '横向浅析Small,RePlugin两个插件化框架'
top: false
cover: false
date: 2018-09-01 23:01:51
img:
tag:
description:
author: yjy239
summary:
categories: Android 常用第三方库
tags:
- Android
- Android 常用第三方库
---
如果，读这篇文章发现错误或者疑惑的欢迎在这里讨论:
https://www.jianshu.com/p/d824056f510b
# 目录
---
- [一 背景](#背景)
- [二 个人实现思路](#个人实现思路)
    - [1.Activity注册问题](#1.Activity注册问题)
    - [2.源码分析原理](##源码分析原理)
    - [3.越过Android系统检测AndroidManifest第一步](##暗度粮仓第一步的原理)
    - [4.越过检测，查找对应的类](##2.由跨越检测AndroidManest.xml引出的问题。如何把插件中的类加载进主模块)
    - [5.解决跨插件导致资源找不到或者资源冲突问题](##3.解决跨插件导致资源找不到或者资源冲突问题)
    - [6.思路总结](##思路总结)
    - [7.反思](##反思)
- [三 Small](#Small)
	- [1.Small的三个基本概念介绍](##Small的三个基本概念介绍)
	- [2.Small源码分析](##Small源码分析)
	- [3.Small资源加载](####那么资源是怎么加载呢？)
	- [4.Small类的加载](####资源找到了，那类又怎么找到呢？)
	- [5.Small启动Activity](##Small启动Activity)
	- [6.Small思路总结](##Small思路总结)
- [四 RePlugin](#RePlugin)
	- [1.Host-Library宿主库](##Host-Library宿主库)
        - [1.Host中的RePlugin的关键类](###Host中的RePlugin的关键类)
        - [2.UI进程的初始化](###UI进程的初始化)
        - [3.RePlugin从UI进程启动常驻进程源码解析](###RePlugin从UI进程启动常驻进程)
        - [4.RePlugin的常驻进程的启动与初始化(类的查找原理)](###RePlugin的常驻进程的启动)
        - [5.RePlugin启动Activity原理](###RePlugin启动Activity原理)
	- [2.RePluginClassLoader和PluginDexClassLoader的分析比较(宿主到从插件的类加载原理)](###RePluginClassLoader和PluginDexClassLoader的分析比较。)
	- [3.Plugin-Library插件库(资源加载原理)](##Plugin-Library插件库)
- [五 Small和RePlugin的比较总结](#Small和RePlugin的比较总结)
- [六 总结](#总结)
- [七 结束语](#结束语)

# 正文
----
因为公司的技术方案的选型的原因，想要把整个工程框架往模块化/组件化的方向的重构一次。为此我去调研了一下常见的路由框架，并且进行了一场对ARouter的基本思想到源码的浅析讲座。

说到模块化，当然想到了后面的插件化，为了尽可能的提高方案的后续兼容性，我也稍微调研了Small和RePlugin。特此写一篇文章对这三者的原理和性能进行对比。由于两者设计的内容比较庞大，限于篇幅原因。有机会再分析阿里的Altas。而DroidPlugin我是两年前以它作为插件化框架学习的例子，这里就不多讲，讨论一下最新的几个插件化框架。

想要分析插件化框架，我们首先要知道插件化是做什么的？
# 背景
---
Android应用上线流程打好包上线之后，很难对上线的应用进行更新。万一出现紧急的bug或者突然出现临时的活动，这种时候只能重新发版。比起网页前端和后端来说，灵活性十分低。为此很多人想了很多办法解决问题。因此而诞生出了热更新，插件化等技术。

多说一句，希望看本篇文章的读者，可以对Android的Activity的启动流程有一定的了解，才好跟得上接下来的思路。

#### 在分析插件化之前，我们要思考一下，如果我们自己编写插件化究竟会遇到什么问题。

就以Android启动Activity为例子（最复杂也是Activity的启动）。假如我们想要跨越模块启动一个新的Activity。会遇到什么阻碍？
1.有点基础的Android工程师都知道。我们要启动一个Activity先要在AndroidManifest.xml中注册好对应的Activity，之后我们才能过AMS的验证，启动到对应的Activity。

问题是一旦牵扯到插件化，我们一般想要启动插件里面的Activity，我们几乎无可奈何，因为我们并没有注册把插件的Activity注册到我们的主模块或者说宿主中，也谈何启动新的Activity。

2.当我们想办法解决了Activity如何从插件中启动出来。接下来又遇到新的问题。当我们启动了启动了Activity之后，就要开始加载资源。



对于第二个问题，如果我们看过资源文件R.java之后，就知道Android实际上是把资源映射为一个id找到对应的资源。当我们拥有两个插件时候，如果我们通过取出对应的资源id的时候，往往会发现id取错了，取成了宿主的或者干脆找不到。

这一次我们的目标是解决这两个大问题。如果这两个问题解决了，实际上启动插件的Activity已经完成一大半。

在解析这些插件化框架的时候，先说说看整个插件化框架的雏形。

最后，我希望每个人看完这篇文章之后，能够知道这几个框架之间设计上和思想上的区别。最好能够有能力写属于自己的插件化框架。

# 个人实现思路
---
实际上，这些思路都是老东西了。我一年前早就试过了一遍了。其实并不是什么厉害的东西。你会发现实际上实现思路挺巧的。实际上绝大部分插件化框架也是顺着这个思路进行下去的。

## 1.Activity注册问题
---
先解决Activity的注册问题。我们先看看Android 7.0的源码。看看它究竟是怎么检测Activity的。

详细的可以去我的csdn看看Activity的启动流程。那是毕业那段时间写的文章，虽然写的不大好：https://blog.csdn.net/yujunyu12/article/details/52527567

我这里摆一张时序图出来：
![Activity的启动流程.jpg](/images/Activity的启动流程.jpg)

这里只跟踪了Activity中关键行为。这段源码我又花了一点时间再看了一遍了，从4.4一直到6.0都看了好几遍，只能说，核心的东西几乎没有什么变动，不熟悉的读者可以稍微看看我上面那个对Activity的源码解析，你或许会稍稍对这个流程有点理解。可能不是完全正确，但是至少十之八九的意思都表达出来了。


好了。源码的部分介绍的差不多。我们开始进入正题吧。

假如我们想要启动一个不存在在注册表中的Activity，那么思路很简单，我们就造一个假的Activity放在AndroidManifest.xml，用来骗过Android系统的检测。

#### 核心思想就是我们要下个钩子赶在Activity相关的信息进入到AMS之前做一次暗度粮仓，方法明面上启动的是我们没有注册的Activity，实际上在给到AMS的时候，没有注册好的代理Actvity会把信息放到注册好的Acitivty的Intent中，骗过Android系统。

#### 接着检测都通过之后，我们再借尸还魂，把代理的Acitivity中换成我们真正要启动的Activity。

这一次我就来hook一下Android 7.0的代码，来展示一下一年前的DoridPlugin的思路。

就算是到了7.0的代码大体上流程还是没有太多变化，到了8.0下钩子的地方稍稍出现了点变化。因为获取获取AMS的实例已经切换到了ActivityManager中。

废话不多说。先上代码。
我们先创建三个Activity,分别是RealActivity，ProxyActivity，MainActivity。RealActivity是我们真的想要从MainActivity跳转的Activity，而ProxyActivity则是作为一个代理承载RealActivity，用来欺骗Android的Activity检测。

## 源码分析原理
---

从上面的时序图我们可以知道，在ActivityManagerNative的时刻就会通过AIDL调用startActivity，跨进程到ActivityManagerService中，换句话说就是脱离了我们控制。同时也代表着ActivityManagerService之前我们可以下手脚。而到了ActivityStackSupervisor又通过scheduleLaunchActivity  跨进程回到我们的App的ActivityThread中，也就意味着我们可以在此时再做一些手脚。

而几乎所有的插件化框架都是沿用这套思路，入侵系统。

### 我们要骗过Android对AndroidMainfest的检测首先要知道哪里检测。

其实就在Instrumentation中：
```
    public ActivityResult execStartActivity(
            Context who, IBinder contextThread, IBinder token, Activity target,
            Intent intent, int requestCode, Bundle options) {
        IApplicationThread whoThread = (IApplicationThread) contextThread;
        Uri referrer = target != null ? target.onProvideReferrer() : null;
        if (referrer != null) {
            intent.putExtra(Intent.EXTRA_REFERRER, referrer);
        }
        if (mActivityMonitors != null) {
            synchronized (mSync) {
                final int N = mActivityMonitors.size();
                for (int i=0; i<N; i++) {
                    final ActivityMonitor am = mActivityMonitors.get(i);
                    if (am.match(who, null, intent)) {
                        am.mHits++;
                        if (am.isBlocking()) {
                            return requestCode >= 0 ? am.getResult() : null;
                        }
                        break;
                    }
                }
            }
        }
        try {
            intent.migrateExtraStreamToClipData();
            intent.prepareToLeaveProcess(who);
            int result = ActivityManagerNative.getDefault()
                .startActivity(whoThread, who.getBasePackageName(), intent,
                        intent.resolveTypeIfNeeded(who.getContentResolver()),
                        token, target != null ? target.mEmbeddedID : null,
                        requestCode, 0, null, options);
            checkStartActivityResult(result, intent);
        } catch (RemoteException e) {
            throw new RuntimeException("Failure from system", e);
        }
        return null;
    }
```

ActivityManagerNative.getDefault()的方法就是通过ActivityManagerNative获取IActivityManager实例。这个实例实际上是一个aidl用于和ActivityManangerService跨进程交互的。接着跨进程调用.startActivity的方法。

调用完之后，调用checkStartActivityResult来检测这个Activity是否检测了。

```
    /** @hide */
    public static void checkStartActivityResult(int res, Object intent) {
        if (res >= ActivityManager.START_SUCCESS) {
            return;
        }

        switch (res) {
            case ActivityManager.START_INTENT_NOT_RESOLVED:
            case ActivityManager.START_CLASS_NOT_FOUND:
                if (intent instanceof Intent && ((Intent)intent).getComponent() != null)
                    throw new ActivityNotFoundException(
                            "Unable to find explicit activity class "
                            + ((Intent)intent).getComponent().toShortString()
                            + "; have you declared this activity in your AndroidManifest.xml?");
                throw new ActivityNotFoundException(
                        "No Activity found to handle " + intent);
            case ActivityManager.START_PERMISSION_DENIED:
                throw new SecurityException("Not allowed to start activity "
                        + intent);
            case ActivityManager.START_FORWARD_AND_REQUEST_CONFLICT:
                throw new AndroidRuntimeException(
                        "FORWARD_RESULT_FLAG used while also requesting a result");
            case ActivityManager.START_NOT_ACTIVITY:
                throw new IllegalArgumentException(
                        "PendingIntent is not an activity");
            case ActivityManager.START_NOT_VOICE_COMPATIBLE:
                throw new SecurityException(
                        "Starting under voice control not allowed for: " + intent);
            case ActivityManager.START_VOICE_NOT_ACTIVE_SESSION:
                throw new IllegalStateException(
                        "Session calling startVoiceActivity does not match active session");
            case ActivityManager.START_VOICE_HIDDEN_SESSION:
                throw new IllegalStateException(
                        "Cannot start voice activity on a hidden session");
            case ActivityManager.START_CANCELED:
                throw new AndroidRuntimeException("Activity could not be started for "
                        + intent);
            default:
                throw new AndroidRuntimeException("Unknown error code "
                        + res + " when starting " + intent);
        }
    }
```
换句话说。我们要赶在这个方法调用之前，做一些手脚才能骗过Android系统。

## 暗度粮仓第一步的原理

上面说过了，我们需要在Activity在会通过通信ActivityManagerNative来通行ActivityManagerService。那很正常可以想到。如果我可以拿到ActivityManagerNative的实例，动态代理这个实例，把startActivity的方法拦截下来，修改注入的参数。

还有其他方案，我们稍后再跟着其他框架再聊聊。如果能有其他很妙的思路的，希望可以教教我。
我们显获取ActivityManangerNative实例。看看这个实例在哪里
```
    private static final Singleton<IActivityManager> gDefault = new Singleton<IActivityManager>() {
        protected IActivityManager create() {
            IBinder b = ServiceManager.getService("activity");
            if (false) {
                Log.v("ActivityManager", "default service binder = " + b);
            }
            IActivityManager am = asInterface(b);
            if (false) {
                Log.v("ActivityManager", "default service = " + am);
            }
            return am;
        }
    };
}
```
运气很好。动态代理只能代理实现了接口的类，而这个IActivityManager 恰好是一个接口。那么顺着这个思路继续往下走。

#### 实现获取ActivityManangerNative的实例
我们反射获取gDefault的实例，获取到内部ActivityManangerNative的实例之后，把这个类给动态代理下来。并且把startActivity方法拦截下来。

```
public void init(Context context){
        this.context = context;
        try {
            Class<?> amnClazz = Class.forName("android.app.ActivityManagerNative");
            Field defaultField = amnClazz.getDeclaredField("gDefault");
            defaultField.setAccessible(true);
            Object gDefaultObj = defaultField.get(null);

            Class<?> singletonClazz = Class.forName("android.util.Singleton");
            Field amsField = singletonClazz.getDeclaredField("mInstance");
            amsField.setAccessible(true);
            Object amsObj = amsField.get(gDefaultObj);


            amsObj = Proxy.newProxyInstance(context.getClass().getClassLoader(),
                    amsObj.getClass().getInterfaces(),new HookHandler(amsObj));

            amsField.set(gDefaultObj,amsObj);

            
        }catch (Exception e){
            e.printStackTrace();
        }

    }
```

既然要对startActivity的参数做处理，我们需要再看看我们要对那几个参数做处理才能骗过AMS（ActivityManagerService，以后用AMS代替）
```
            int result = ActivityManagerNative.getDefault()
                .startActivity(whoThread, who.getBasePackageName(), intent,
                        intent.resolveTypeIfNeeded(who.getContentResolver()),
                        token, target != null ? target.mEmbeddedID : null,
                        requestCode, 0, null, options);
```
第一个参数是ApplicationThread也可以说是ActivityThread中用来沟通AMS的Binder接口，是一种通行桥梁。第二个参数是当前的包名，第三个参数就是我们启动时候带的intent。看到这里就ok了。我们要做暗度粮仓第一件事当然要把粮偷偷的放到哪里，骗过敌人。很简单就是把我们要启动的Activity放到intent里面。

#### 实现暗度粮仓第一步
```
    class HookHandler implements InvocationHandler{

        private Object amsObj;


        public HookHandler(Object amsObj){
            this.amsObj = amsObj;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            Log.e("method",method.getName());
            if(method.getName().equals("startActivity")){
                // 启动Activity的方法,找到原来的Intent
                Intent proxyIntent = (Intent) args[2];
                // 代理的Intent
                Intent realIntent = new Intent();
                realIntent.setComponent(new ComponentName(context,"com.yjy.hookactivity.RealActivity"));
                // 把原来的Intent绑在代理Intent上面
                proxyIntent.putExtra("realIntent",realIntent);
                // 让proxyIntent去骗过Android系统
                args[2] = proxyIntent;


            }
            return method.invoke(amsObj,args);
        }
    }
```
做好了暗度粮仓的准备。别忘了我们度过之后要取出来，借着代理在AMS中做好的ActivityRecord做一次借尸还魂。

在这里我稍微提一下在整个ActivityThread中有一个mH的Handler作为整个App的事件总线。无论是哪个组件的的哪段生命周期，都是借助这个Handler完成的。
那么正常的想法就是在执行这个Handler的msg之前，如果可以执行我们自己的处理方法不就好了吗？这里就涉及到了Handler的源码的。看过我之前对Handler的分析的话，就会对Handler的源码十分熟悉。这里直接放出dispatchMessage的方法。
```
   public void dispatchMessage(Message msg) {
        if (msg.callback != null) {
            handleCallback(msg);
        } else {
            if (mCallback != null) {
                if (mCallback.handleMessage(msg)) {
                    return;
                }
            }
            handleMessage(msg);
        }
    }
```
可以知道如果当mCallback不等于空的时候，且mCallback.handleMessage(msg)返回false的时候，将会先执行mCallback的handleMessage再执行我们常用的handleMessage。很幸运，这又给我们提供可空子进入，可以赶在nH处理msg之前处理一次我们的暗度在里面的“粮”。
```
    public void hookLaunchActivity(){
        try {
            Class<?> mActivityThreadClazz = Class.forName("android.app.ActivityThread");
            Field sActivityThreadField = mActivityThreadClazz.getDeclaredField("sCurrentActivityThread");
            sActivityThreadField.setAccessible(true);
            Object sActivityThread = sActivityThreadField.get(null);

            Field mHField = mActivityThreadClazz.getDeclaredField("mH");
            mHField.setAccessible(true);
            Handler mH = (Handler)mHField.get(sActivityThread);

            Field callback = Handler.class.getDeclaredField("mCallback");
            callback.setAccessible(true);
            callback.set(mH,new ActivityThreadCallBack());

        }catch (Exception e){
            e.printStackTrace();
        }

    }

    class ActivityThreadCallBack implements Handler.Callback{

        @Override
        public boolean handleMessage(Message msg) {
            if(msg.what == LAUNCH_ACTIVITY){
                handleLaunchActivity(msg);
            }
            return false;
        }
    }

    private void handleLaunchActivity(Message msg) {
        try {
            //msg.obj ActivityClientRecord
            Object obj = msg.obj;
            Field intentField = obj.getClass().getDeclaredField("intent");
            intentField.setAccessible(true);
            Intent proxy = (Intent) intentField.get(obj);
            Intent orgin = proxy.getParcelableExtra("realIntent");
            if(orgin != null){
                intentField.set(obj,orgin);
            }

        }catch (Exception e){
            e.printStackTrace();
        }
    }
```

为什么我们hook ActivityClientRecord替换内部的intent起效果呢？可以去看看我上面毕业写的文章。这里稍微总结一下：我们会在ActivityStack中准备好Activity的的task，task之中的关系等等。之后我们再在[performLaunchActivity](http://androidxref.com/7.0.0_r1/s?refs=performLaunchActivity&project=frameworks)中，获取ActivityRecord通过反射生成新的Activity。

这样就完成了越过AndroidMainest.xml。下面就是越过AndroidMainest.xml的控制中心方法。只要在调用startActivity前调用一下init和hookLaunchActivity方法即可。


##### 很简单吧。但是事情还没完。因为插件化，我们往往连对方的包名+类名都完全不知道。只是第一步而已。接下来我就要通过PacketManagerService来解决这个问题。而且跨越检测也没有结束。因为在适配AppCompatActivity会出点问题。

## 2.由跨越检测AndroidManest.xml引出的问题。如何把插件中的类加载进主模块。

实际上这个也很简单。但是我们首先要熟悉Android源码和Java中类加载时候的双亲模型。这里我们先看看Android启动流程的源码。native层面上的启动源码我有机会和你们分析分析，这是去年学习的目标之一。实际上看了4.4到7.0这些核心东西也几乎太大变动

当我们通过Zyote进程fork（也有人叫孵化）出我们App进程的时候，会做一次类的加载以及Application的初始化。会走ActivityThread的main方法接着会调用它的attach方法。在attach中会跨进程走到AMS中的[attachApplication](http://androidxref.com/7.0.0_r1/s?defs=attachApplication&project=frameworks)，在里面分配pid等参数之后就会回到bindApplication走Application的onCreate方法。

关键方法是其中的[getPackageInfoNoCheck](http://androidxref.com/7.0.0_r1/s?refs=getPackageInfoNoCheck&project=frameworks)又会调用getPackageInfo方法。那为什么我们选择反射getPackageInfoNoCheck而不是getPackageInfo呢？因为最大的区别getPackageInfoNoCheck是public方法，getPackageInfo是私有方法。而在编码规范中public作为暴露出来的接口变动的可能性比较小。
```
private LoadedApk getPackageInfo(ApplicationInfo aInfo, CompatibilityInfo compatInfo,
            ClassLoader baseLoader, boolean securityViolation, boolean includeCode,
            boolean registerPackage) {
        synchronized (mResourcesManager) {
            WeakReference<LoadedApk> ref;
            if (includeCode) {
                ref = mPackages.get(aInfo.packageName);
            } else {
                ref = mResourcePackages.get(aInfo.packageName);
            }
            LoadedApk packageInfo = ref != null ? ref.get() : null;
            if (packageInfo == null || (packageInfo.mResources != null
                    && !packageInfo.mResources.getAssets().isUpToDate())) {
                if (localLOGV) Slog.v(TAG, (includeCode ? "Loading code package "
                        : "Loading resource-only package ") + aInfo.packageName
                        + " (in " + (mBoundApplication != null
                                ? mBoundApplication.processName : null)
                        + ")");
                packageInfo =
                    new LoadedApk(this, aInfo, compatInfo, baseLoader,
                            securityViolation, includeCode &&
                            (aInfo.flags&ApplicationInfo.FLAG_HAS_CODE) != 0, registerPackage);

                if (mSystemThread && "android".equals(aInfo.packageName)) {
                    packageInfo.installSystemApplicationInfo(aInfo,
                            getSystemContext().mPackageInfo.getClassLoader());
                }

                if (includeCode) {
                    mPackages.put(aInfo.packageName,
                            new WeakReference<LoadedApk>(packageInfo));
                } else {
                    mResourcePackages.put(aInfo.packageName,
                            new WeakReference<LoadedApk>(packageInfo));
                }
            }
            return packageInfo;
        }
    }
```
而返回LoadApk这个类指代的就是Apk在内存中的表示。上面的方法的意思是，假如在mPackage中找到我们要的LoadApk则直接返回，不然就新建一个新的LoadApk。


难道说我们只要给这个方法参数，反射调用这个方法，生成LoadApk就能获得插件的apk。然后加到系统的mPackage的Map中管理，欺骗系统说这个插件已经安装了。这样就能调用，实现我们的业务。思路是这样没错。

但是理想是丰满的，现实往往是骨感的。别忘了我们所有的Activity都是通过ClassLoader反射而来，宿主应用的classloader怎么加载的了插件的classloader呢？

这也就引申出了classloader的双亲委派。说穿了，也不是什么高大上的东西。实际上就是当前的ClassLoader先不去加载class，如果找不到则再去委托上层去查找class缓存，如果找到了就返回，没有则自上而下的查找有没有对应的class。

为了避免有人不太懂classloader，这里稍微提一句classloader实际上是会加载dex文件之后，从dex中查找出class文件对应的位置。插件的dex很明显和宿主的dex不同，所以无法通过classloader找到对应的class。

这里我借用网上一个挺好的示意图片
![ClassLoader设计.jpg](/images/ClassLoader设计.jpg)

在这里要提一点，Android出了上述几种ClassLoader之外，自己也定义了一套ClassLoader。分别是BaseDexClassLoader,DexClassLoader和PathClassLoader。实际上这部分就是上面所说的自定义类加载器。

>相应的PathClassLoader是用于加载已经安装好的apk的dex文件，DexClassLoader能够用于加载外部dex文件。


#### 查找外部class的方式
那么我们可以推测出两种做法。一种是直接全权用我们的classloader直接替代掉系统的classloader。第二种就是看看能不能hook一下BaseDexClassLoader让我们做事情。这就是网上所说的，比较粗暴的方法和温柔的方法。

其实两种我都试过了。这一次，我就讲讲暴力的方法。因为温柔的方式将会在Small中体现出来。

说穿了，实际上也是十分的简单。如果对上述的图熟悉的话，就十分简单。就是自己做一个ClassLoader专门用来读取dex文件的。这样就能在类的加载的时候找到这个文件。

#### 实现跨插件查找
不多说上代码;
1.先自定义一个classloader
```
public class PluginClassLoader extends DexClassLoader {
    public PluginClassLoader(String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent) {
        super(dexPath, optimizedDirectory, librarySearchPath, parent);
    }
}
```

这里说一下，第一个参数是你要读入的apk文件还是dex文件还是jar文件。到最后它都会解析dex文件。第二个参数是dex优化后的文件，也就是我们常说的odex文件。第三个是native的文件夹，第四个是指定自己的上层类加载器，用于委托。
```
public static void loadPlugin(Context context){

        try {
            dirPath = context.getCacheDir().getParentFile().getAbsolutePath()
                    +File.separator+"Plugin"+File.separator+"data"+File.separator+"com.yjy.pluginapplication";
            
            apk = new File(dirPath,"plugin.apk");
            if(apk.exists()){
                Log.e("apk","exist");
            }else {
                Log.e("apk","not exist");
                Utils.copyFileFromAssets(context,"plugin.apk",
                        dirPath+ File.separator +"plugin.apk");

            }


            cl = new PluginClassLoader(apk.getAbsolutePath(),
                    context.getDir("plugin.dex", 0).getAbsolutePath(),null,context.getClassLoader().getParent());
            hookPackageParser(apk);


        }catch (Exception e){
            e.printStackTrace();
        }


    }

  //查找是否存在对应的class
    public static Class<?> findClass(String path){
        try {
             Class<?> clazz = cl.loadClass(path);
             return clazz;
        }catch (Exception e){
            e.printStackTrace();
        }
        return null;
    }
```

好了如何跨越插件找class也做到了,只要让LoadApk里面的ClassLoader切换为我们的classloader就能找到我们类！！
我们接下来就是去下钩子加载我们的插件Activity，其实这个也不难。但是需要我们熟悉PackageManagerService.

让我们看看[getPackageInfoNoCheck](http://androidxref.com/7.0.0_r1/s?refs=getPackageInfoNoCheck&project=frameworks)这个方法是怎么样的。
```
    public final LoadedApk getPackageInfoNoCheck(ApplicationInfo ai,
            CompatibilityInfo compatInfo) {
        return getPackageInfo(ai, compatInfo, null, false, true, false);
    }
```

也就说我们需要找到ApplicationInfo这个参数和CompatibilityInfo 这个参数。CompatibilityInfo 这个参数好说，是一个数据类。无论我们本地造一个还是反射获取都ok。

但是ApplicationInfo就没这么好获得了。因为这个信息关系到我们的整个Application的关键信息。我们必须步步为营，小心翼翼的处理。最好能通过系统里面某个方法获得是最好的。

当然如果熟悉PackageManagerService就知道PMS流程中PackageParser的类有这么一个方法generateActivityInfo，专门用来获取ActivityInfo的。这里面当然也有ApplicationInfo这个参数。为什么要用这个函数呢？因为调用的ApplicationInfo是从ActivityInfo中获得的。

```
    public static final ActivityInfo generateActivityInfo(Activity a, int flags,
            PackageUserState state, int userId) {
        if (a == null) return null;
        if (!checkUseInstalledOrHidden(flags, state)) {
            return null;
        }
        if (!copyNeeded(flags, a.owner, state, a.metaData, userId)) {
            return a.info;
        }
        // Make shallow copies so we can store the metadata safely
        ActivityInfo ai = new ActivityInfo(a.info);
        ai.metaData = a.metaData;
        ai.applicationInfo = generateApplicationInfo(a.owner, flags, state, userId);
        return ai;
    }
```
第一个参数Activity 是指当前的Activity。我们需要一点特殊的技巧。如果我们熟悉Android的安装流程的话，就知道我们显通过PackageParser的parsePackage解析整个apk包，解析好的对象里面存放着apk里面所有四大组件的信息。

那么我们只需要做这几件事情，解析出这个包里面的Activity信息也就是PackageParser$Activity，取出我们想要的Activity，放进来调用这个方法生成想要的ActivityInfo即可。

```
    public Package parsePackage(File packageFile, int flags) throws PackageParserException {
        if (packageFile.isDirectory()) {
            return parseClusterPackage(packageFile, flags);
        } else {
            return parseMonolithicPackage(packageFile, flags);
        }
    }
```
这个PackageUserState这个类是关于package是否安装等信息，由于这个插件这个时候并没有相关，我们完全可以反射直接实例化出来即可。后者userId是在ActivityThread中attach方法中绑定userid，我们这里是单进程，单App模式直接拿本App的即可。万事俱备只欠东风了。

#### 思路整理


##### 1.在加载整个apk包进入classloader的时候，调用Package.paresPackage（File，flag）解析整个apk包，存下解析出来的activity信息
```
 /**
     * 解析包
     * @param apk
     */
    public static void hookPackageParser(File apk){
        try {
            packageParserClass = Class.forName("android.content.pm.PackageParser");
            mPackageParser = packageParserClass.newInstance();

            //先解析一次整个包名
            Method paresPackageMethod = packageParserClass.getDeclaredMethod("parsePackage",File.class,int.class);
            //Package.paresPackage（File，flag）
            Object mPackage = (Object) paresPackageMethod.invoke(mPackageParser,apk,0);

            //解析完整个包，获取Activity的集合,保存起来
            Field mActivitiesField = mPackage.getClass().getDeclaredField("activities");
            activities = (ArrayList<Object>) mActivitiesField.get(mPackage);
            Log.e("activites",activities.toString());


        }catch (Exception e){
            e.printStackTrace();
        }

    }
```

这里只展示Activity的流程。当然我们也能从中获取出apk包中其他信息，现在并没有想法去解决其他地方的问题。

##### 在上面的hook mH之后，添加一步把之前解析出来的包的信息运用起来。细分下去又是如下几步：

##### 1.使用上面解析的信息，调用PackageParser.generateActivityInfo获取ActivityInfo

##### 2.调用ActivityThread.getPackageInfoNoCheck获取LoadApk

##### 3.切换LoadApk中的classloader为我们的自己ClassLoader 也就是属性mClassLoader
为什么要这么做呢？我们看看源码就明白了，看看Android是怎么是实例化Activity的
```
java.lang.ClassLoader cl = r.packageInfo.getClassLoader();
            activity = mInstrumentation.newActivity(
                    cl, component.getClassName(), r.intent);
            StrictMode.incrementExpectedActivityCount(activity.getClass());
            r.intent.setExtrasClassLoader(cl);
            r.intent.prepareToEnterProcess();
            if (r.state != null) {
                r.state.setClassLoader(cl);
            }
```
这是从r. packageInfo获取classloader。而这个packageInfo又是什么呢？其实就是LoadApk。而这个r是指ActivityClientRecord，这是是在整个mH中作为obj对象作为Acitivity的启动流程在到处传递。也因为从这个packageInfo获取classloader所以我们要替换。

##### 4.把这个LoadApk放到mPackages这个在ActivityThread中保存着安装好的apk信息。
从上方的getPackageInfo方法中。可以得知当我们从mPackages这个ArrayMap中获取到包名对应的LoadApk的时候就会直接返回LoadApk。我们要做的是在系统自己调用getPackageInfoNoCheck之前，先把我们LoadApk放入mPackages中，欺骗系统我们已经安装这个插件了，就会直接返回我们自己的LoadApk。


##### 5.把这个ActivityInfo设置到ActivityClientRecord
当我们以为万事大吉的时候，忘记了这一步。你会发现我们并没有获取到我们自己LoadApk，为什么会这样呢？看看源码就知道了。
在ActivityThread的performLaunchActivity中有这么一个判断
```
        ActivityInfo aInfo = r.activityInfo;
        if (r.packageInfo == null) {
            r.packageInfo = getPackageInfo(aInfo.applicationInfo, r.compatInfo,
                    Context.CONTEXT_INCLUDE_CODE);
        }
```
就算我们创建了新的LoadApk如果ActivityClientRecord中的ActivityInfo为空的化，系统自己又回创建一个新的LoadApk，这样我们之前的工作就白做了。

#### 实现hookGetPackageInfoNoCheck
都分析出来了直接上源码。
```
    public static void hookGetPackageInfoNoCheck(Object mActivityClientRecordObj,Intent intent){
        //获取ActivityInfo
        try {
            Class<?> sPackageUserStateClass = Class.forName("android.content.pm.PackageUserState");
            Object mPackageUserState = sPackageUserStateClass.newInstance();
            Class<?> sActivityClass = Class.forName("android.content.pm.PackageParser$Activity");
            Method generateActivityInfoMethod = packageParserClass.getDeclaredMethod("generateActivityInfo",sActivityClass,int.class,sPackageUserStateClass,int.class);
            ComponentName name = intent.getComponent();
            Log.e("ComponentName",name.getClassName());

            //获取activityInfo
            //已经知道我们插件中的Activity信息只有一条，就没必要筛选了。作者本人懒了
            ActivityInfo activityInfo  = (ActivityInfo) generateActivityInfoMethod.invoke(mPackageParser,
                    activities.get(0),0,mPackageUserState, getCallingUserId());

            //有了activityInfo，再获取sDefaultCompatibilityInfo,调用getPackageInfoNoCheck方法
            Method getPackageInfoNoCheckMethod = mActivityThreadClazz.getDeclaredMethod("getPackageInfoNoCheck",ApplicationInfo.class,
                    CompatibilityInfoCompat.getMyClass());

            fixApplicationInfo(activityInfo,apk);

            //获取到LoadApk实例
            Object LoadApk = getPackageInfoNoCheckMethod.invoke(sActivityThread,activityInfo.applicationInfo,CompatibilityInfoCompat.DEFAULT_COMPATIBILITY_INFO());

            //把LoadApk中的classloader切换为我们的classloader
            Field mClassLoaderField = LoadApk.getClass().getDeclaredField("mClassLoader");
            mClassLoaderField.setAccessible(true);
            mClassLoaderField.set(LoadApk,cl);


            //把这个loadApk放到mPackages中
            Field LoadApkMapField = mActivityThreadClazz.getDeclaredField("mPackages");
            LoadApkMapField.setAccessible(true);

            Map LoadApkMap = (Map)LoadApkMapField.get(sActivityThread);


            //调用Map的put方法 mPackages.put(String,LoadApk)
            LoadApkMap.put(activityInfo.applicationInfo.packageName,new WeakReference<Object>(LoadApk));


            //设置回去
            LoadApkMapField.set(sActivityThread,LoadApkMap);
            
            Field activityInfoField = mActivityClientRecordObj.getClass().getDeclaredField("activityInfo");
            activityInfoField.setAccessible(true);
            activityInfoField.set(mActivityClientRecordObj,activityInfo);

            Thread.currentThread().setContextClassLoader(cl);



        }catch (Exception e){
            e.printStackTrace();
        }
    }
```

## 3. 解决跨插件导致资源找不到或者资源冲突问题
这样就万事大吉了吗？如果你直接上上面代码你会发现资源找不到导致系统崩溃。
那你一定会骂作者，不是说好的LoadApk代表了apk在内存中的数据吗？按照道理一定能找到里面的资源，一定是你的姿势不对。

确实是这样没错。细心的你一定会发现上面有一行方法我并没有解释，那就是fixApplicationInfo。

我们看看源码activity是怎么查找资源的。这里先上个时序图。
![Framework层的资源查找与context绑定.png](/images/Framework层的资源查找与context绑定.png)

了解整个资源是怎么查找的。我们再深入去看看源码的细节。

这个流程先放在这里，当作一个伏笔埋在这里。转个头来看看，当我们想要为Activity设置布局的时候，往往都需要调用setContentView。让我们看看setContentView的源码是怎么查找资源的。

熟知Activity的窗口绘制流程流程就能知道这段源码直接在PhoneWindow中查找。
```
    @Override
    public void setContentView(int layoutResID) {
        // Note: FEATURE_CONTENT_TRANSITIONS may be set in the process of installing the window
        // decor, when theme attributes and the like are crystalized. Do not check the feature
        // before this happens.
        if (mContentParent == null) {
            installDecor();
        } else if (!hasFeature(FEATURE_CONTENT_TRANSITIONS)) {
            mContentParent.removeAllViews();
        }

        if (hasFeature(FEATURE_CONTENT_TRANSITIONS)) {
            final Scene newScene = Scene.getSceneForLayout(mContentParent, layoutResID,
                    getContext());
            transitionTo(newScene);
        } else {
            mLayoutInflater.inflate(layoutResID, mContentParent);
        }
        mContentParent.requestApplyInsets();
        final Callback cb = getCallback();
        if (cb != null && !isDestroyed()) {
            cb.onContentChanged();
        }
        mContentParentExplicitlySet = true;
    }
```

我们不管上面创建DecorView，把焦点放在
```
mLayoutInflater.inflate(layoutResID, mContentParent);
```
实际上视图的创建就是通过LayoutInflater。这里也不讲LayoutInflater的原理，什么缓存模型，直奔inflate的方法。
```
    public View inflate(@LayoutRes int resource, @Nullable ViewGroup root, boolean attachToRoot) {
        final Resources res = getContext().getResources();
        if (DEBUG) {
            Log.d(TAG, "INFLATING from resource: \"" + res.getResourceName(resource) + "\" ("
                    + Integer.toHexString(resource) + ")");
        }

        final XmlResourceParser parser = res.getLayout(resource);
        try {
            return inflate(parser, root, attachToRoot);
        } finally {
            parser.close();
        }
    }
```
你们会发现实际上资源都会通过context内部绑定好的resource来获取真实的资源文件。

那么伏笔就来了。既然是从context来的resource。那么我们想到借助系统创建一个Activity中的Context，把Context里面的resources对象换成我们的资源。这个过程最好不要过多的干预系统，最好能让系统自己生成。

先关注时序图中的LoadApk的getResources方法
```
    public Resources getResources(ActivityThread mainThread) {
        if (mResources == null) {
            mResources = mainThread.getTopLevelResources(mResDir, mSplitResDirs, mOverlayDirs,
                    mApplicationInfo.sharedLibraryFiles, Display.DEFAULT_DISPLAY, this);
        }
        return mResources;
    }
```
发现实际上我们所有的数据都是通过getTopLevelResources去解析LoadApk中的存放好的资源目录来进行解析。

而这些LoadApk的数据是怎么来的，当然是调用[getPackageInfoNoCheck](http://androidxref.com/7.0.0_r1/s?refs=getPackageInfoNoCheck&project=frameworks)生成的，也就是说我们要赶在调用这个方法之前，把apk的目录填进去就能找到资源了。

```
    private static void fixApplicationInfo(ActivityInfo activityInfo,File mPluginFile){
        ApplicationInfo applicationInfo = activityInfo.applicationInfo;
        if (applicationInfo.sourceDir == null) {
            applicationInfo.sourceDir = mPluginFile.getPath();
        }
        if (applicationInfo.publicSourceDir == null) {
            applicationInfo.publicSourceDir = mPluginFile.getPath();
        }


        if (applicationInfo.dataDir == null) {
            String dirPath = context.getCacheDir().getParentFile().getAbsolutePath()
                    +File.separator+"Plugin"+File.separator+"data"+File.separator+applicationInfo.packageName;
            File dir = new File(dirPath);
            if(!dir.exists()){
                dir.mkdirs();
            }

            applicationInfo.dataDir = dirPath;
        }

        try {
            Field scanDirField = applicationInfo.getClass().getDeclaredField("scanSourceDir");
            scanDirField.setAccessible(true);
            scanDirField.set(applicationInfo,applicationInfo.dataDir);
        }catch (Exception e){
            e.printStackTrace();
        }


        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                Field PublicSourceDirField = applicationInfo.getClass().getDeclaredField("scanPublicSourceDir");
                PublicSourceDirField.setAccessible(true);
                PublicSourceDirField.set(applicationInfo,applicationInfo.dataDir);
            }
        }catch (Exception e){
            e.printStackTrace();
        }

        try {
            PackageInfo mHostPackageInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            applicationInfo.uid = mHostPackageInfo.applicationInfo.uid;
        }catch (Exception e){
            e.printStackTrace();
        }


        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            if (applicationInfo.splitSourceDirs == null) {
                applicationInfo.splitSourceDirs = new String[]{mPluginFile.getPath()};
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            if (applicationInfo.splitPublicSourceDirs == null) {
                applicationInfo.splitPublicSourceDirs = new String[]{mPluginFile.getPath()};
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    if (Build.VERSION.SDK_INT < 26) {
                        Field deviceEncryptedDirField = applicationInfo.getClass().getDeclaredField("deviceEncryptedDataDir");
                        deviceEncryptedDirField.setAccessible(true);
                        deviceEncryptedDirField.set(applicationInfo,applicationInfo.dataDir);


                        Field credentialEncryptedDirField = applicationInfo.getClass().getDeclaredField("credentialEncryptedDataDir");
                        credentialEncryptedDirField.setAccessible(true);
                        credentialEncryptedDirField.set(applicationInfo,applicationInfo.dataDir);
                    }

                    Field deviceProtectedDirField = applicationInfo.getClass().getDeclaredField("deviceProtectedDataDir");
                    deviceProtectedDirField.setAccessible(true);
                    deviceProtectedDirField.set(applicationInfo,applicationInfo.dataDir);

                    Field credentialProtectedDirField = applicationInfo.getClass().getDeclaredField("credentialProtectedDataDir");
                    credentialProtectedDirField.setAccessible(true);
                    credentialProtectedDirField.set(applicationInfo,applicationInfo.dataDir);

                } catch (Exception e) {
                    e.printStackTrace();
                }
            }

            if (TextUtils.isEmpty(applicationInfo.processName)) {
                applicationInfo.processName = applicationInfo.packageName;
            }
        }catch (Exception e){
            e.printStackTrace();
        }
    }
```
这样就能骗过系统获取到资源文件。

说句老实话，插件化难度不高，只是对源码的熟悉度提上去，加上一点取巧的思想，都能写出来。

## 反思
我写的demo是否有问题？问题当然是多多的。首先一点，反射代码冗余了，当然也和我想让读者能够一目了然反射是如何运作的才这么写。

第二点，LoadApk加入到了mPackages这个Map中作为弱引用包裹着。一旦出现了GC，我们的工作前功尽弃了，所以肯定需要亲自缓存下来。直接通过packagename从我们自己的缓存取出。

第三点，我这个demo没有适配Appcompat包，没有适配AppCompatActivity。这个包有点意思，通过LayoutInflater拦截view生成Appcompat对应的东西，需要单独处理。

除了这些问题之外，这个demo的设计也令人汗颜。不过这的确能够让人对这个模型一目了然。

## 思路总结
这里整理一个模型，来总结上述的流程
![插件化框架基础模型.png](/images/插件化框架基础模型.png)



以上是基于Android7.0源码，加上DroidPlugin源码写的demo。既然都清楚了整个插件化框架的流程，对于轻量级别的插件化框架Small和RePlugin也就好分析了。


# Small
为什么挑出Small这个插件化框架呢？看了源码你会发现这种插件化框架代表着现在插件化另外一种新思想，同时实现思路和DroidPlugin相比，属于另外一个方向。

那就是对插件的定义更为的广义。不单单只是指我们的独立之外的apk包，还指代了工程里面的所有模块也是插件。

闲话不多说。老规矩，我先贴上如何使用Small框架的文章，实际上很简单。里面的Sample也很简洁的显示出如何使用。
用法与常见问题：http://code.wequick.net/Small/cn/quickstart

一个不错的解析文章：https://www.jianshu.com/p/8eca24846445

除去对gradle的命令操作和工程上的命名配置层面，代码上细分为两步。

第一步：在Application调用一次
```
public Application() {
        // This should be the very first of the application lifecycle.
        // It's also ahead of the installing of content providers by what we can avoid
        // the ClassNotFound exception on if the provider is unimplemented in the host.
        Small.preSetUp(this);
    }
```

第二步：加载App内部的插件
```
Small.setUp(LaunchActivity.this, new net.wequick.small.Small.OnCompleteListener() {
            @Override
            public void onComplete() {
                long tEnd = System.nanoTime();
                se.putLong("setUpFinish", tEnd).apply();
                long offset = tEnd - tStart;
                if (offset < MIN_INTRO_DISPLAY_TIME) {
                    // 这个延迟仅为了让 "Small Logo" 显示足够的时间, 实际应用中不需要
                    getWindow().getDecorView().postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            Small.openUri("main", LaunchActivity.this);
                            finish();
                        }
                    }, (MIN_INTRO_DISPLAY_TIME - offset) / 1000000);
                } else {
                    Small.openUri("main", LaunchActivity.this);
                    finish();
                }
            }
        });
```

做了这两步就能将工程的模块插件都加载进来。

## Small的三个基本概念介绍

### Bundle

这个Bundle可不是我们Android常用来传递数据的Bundle，而是指代插件，类似Android中LoadApk的定位，指代的是Small中的插件，里面控制着每个插件之中的版本号，版本名，目录地址，每个Bundle的包名，类型，规则等等。这个概念也在阿里的Altas插件化框架中出现。

在这里Bundle对模块的名字做了规范，对于公共的模块，模块名字要叫做\**.lib.\*或 \**.lib\*.对于应用插件要叫做\**.app.\* 或 \**.app\*。或者在下方的bundle.json写好规则，详细的请去官网查看。


### bundle.json
这个是Small的配置文件。
Example:
```json
{
  "version": "1.0.0",
  "bundles": [
    {
      "type":"app",
      "uri": "home",
      "pkg": ".bundle.home",
      "rules": {
        "page1": ".MyPage1",
        "page2": ".MyPage2"
      }
    }
  ]
}
```
属性 | 介绍
-----|----
type|类型 可选 app lib web 
uri |跳转转的url别名
pkg|包名
rules|包含的页面数组 如LoginActivity或LoginFragment 则 "login":"Login"

这个文件从一定程度上代替了Android的Mainfest.xml。通过这个文件我们可以轻易的查找到，每个模块插件所包含的信息，从而通过openUri方法跳转。

### BundleLauncher
这个是整个Small框架的核心也不为过。这个BundleLauncher作为整个Small如何HookAndroid系统的核心抽象类。详细的等等再说。

这里先放出BundleLauncher类的关系图。

![BundleLauncher类图关系.png](/images/BundleLauncher类图关系.png)




这里稍微解释一下，ActivityLauncher主要是解析包的数据，特别是Activity。SoBundleLauncher主要是因为在Small框架中，编译的时候会把每个模块打成so（当然也能选择不大打成so）所以叫做SoBundleLauncher。而ApkBundleLauncher主要是指对Android系统中Activity的流程的反射处理。主要是处理上面我所说的骗过AndroidMainfest.xml的流程。。AssetBundleLuancher主要是对资源的处理。



## Small源码分析
我们跟着demo的流程走一遍源码。这里先放出时序图。
![Small启动流程图.png](/images/Small启动流程图.png)


从上面的时序图，我们可以清晰的清楚，在整个Small的启动加载流程中Bundle作为极其核心的地位，同时处理了三个BundleLauncher的地位。
按照类中的方法分析大致可以归为两类方法和属性。
静态属性都包含着List<BundleLauncher>和List<Bundle>等，静态方法包含register等。了解到Bundle的静态操作是用来控制BundleLauncher和Bundle整体的行为。
而非静态方法，则是单一控制我上面所说的Bundle的概念。

换句话说，Bundle类实际上充当了两个角色Bundle和Bundle、BundleLauncher的控制器。

重新整理一下，Small的启动分两步，第一步perSetUp，setUp前的准备。第二步setUp，主要是运行BundleLauncher和解析bundle.json生成Bundle。

跟着时序图，让我们开始Small的源码之旅。

### 1.Small perSetUp 
```
    public static void preSetUp(Application context) {
        if (sContext != null) {
            return;
        }

        sContext = context;

        // Register default bundle launchers
        registerLauncher(new ActivityLauncher());
        registerLauncher(new ApkBundleLauncher());
        registerLauncher(new WebBundleLauncher());
        Bundle.onCreateLaunchers(context);
    }
```

很简单也很重要，这里是通过Context来确定setUp前处理只有一次。接着把BundleLauncher注册到List中，以便后面循环统一调用对应的BundleLauncher的方法。

下面的onCreate的方法。实际上在这三个BundleLauncher中只有ApkBundleLauncher实现了该方法。让我们直接看看这个onCreate的方法做了什么。
```
 @Override
    public void onCreate(Application app) {
        super.onCreate(app);

        Object/*ActivityThread*/ thread;
        List<ProviderInfo> providers;
        Instrumentation base;
        ApkBundleLauncher.InstrumentationWrapper wrapper;
        Field f;

        // Get activity thread
        thread = ReflectAccelerator.getActivityThread(app);

        // Replace instrumentation
        try {
            f = thread.getClass().getDeclaredField("mInstrumentation");
            f.setAccessible(true);
            base = (Instrumentation) f.get(thread);
            wrapper = new ApkBundleLauncher.InstrumentationWrapper(base);
            f.set(thread, wrapper);
        } catch (Exception e) {
            throw new RuntimeException("Failed to replace instrumentation for thread: " + thread);
        }

        // Inject message handler
        ensureInjectMessageHandler(thread);

        // Get providers
        try {
            f = thread.getClass().getDeclaredField("mBoundApplication");
            f.setAccessible(true);
            Object/*AppBindData*/ data = f.get(thread);
            f = data.getClass().getDeclaredField("providers");
            f.setAccessible(true);
            providers = (List<ProviderInfo>) f.get(data);
        } catch (Exception e) {
            throw new RuntimeException("Failed to get providers from thread: " + thread);
        }

        sActivityThread = thread;
        sProviders = providers;
        sHostInstrumentation = base;
        sBundleInstrumentation = wrapper;
    }
```
殊途同归，根据注释，反射的名称和我之前所说的插件化基础模型，我们可以轻松的知道这个onCreate的思路。

#### 第一步先获取ActivityThread的实例，也就是为插件化基础模型后半段做预备处理。

#### 第二步获取mInstrumentation的实例，并把我们的mInstrumentation设置进去。实际上是为插件化基础模型前半段做准备。

##### 解释：
Small开发的作者并没有像DroidPlugin的作者一样，直接获取AMS的跨进程通信对象而是获取了Instrument这个类的对象。结合我最上面的Activity启动的时序图，你会发现Instrument也是在Activity传递给传递给AMS之前，准确的说是在Instrument检测AndroidMainfest之前处理。

但是不是说好的动态代理只能代理实现接口的类吗？这就有涉及到了另外一个下钩子的技能。通过继承，让Instrument内部的方法对我们开放，这个方法我也经常使用。

这种做法的好处是什么呢？

避免了ActivityManagerNative的实例的位置出现了变动。

Small作者所担心的事情确实出现了，在Android 8.0中，ActivityManangerNative的单例存放位置出现了变动，跑到了ActivityManager中了。所以比较新的插件化框架都选择了这种方式去处理，就怕这个实例的位置再次变动。

那么为什么Hook Instrument呢？好处很明显，这个类实际上是暴露给测试用的，权限是public，也就是说他变动的可能性不大。所以综合考虑，给Instrument下钩子优于ActivityManangerNative。

看看new ApkBundleLauncher.InstrumentationWrapper(base)的继承关系
```
protected static class InstrumentationWrapper extends Instrumentation
            implements InstrumentationInternal 
```
这个类，我们想要关注什么函数，直接在对应的函数中重写即可。这实际上也是用一种桥接的设计模式。重写方法，实际上工作的base实例。

既然如此，我们看看，我们关注的函数execStartActivity。

这个函数分为三步：
##### 第一步，包裹真实的Intent，用代理的Activity欺骗Android系统的检测。

##### 第二步， 反射ActivityThread的mH这个Handler

##### 第三步，反射调用execStartActivity这个方法。


详细就暂时不铺开说，之后我们再把这些线索串到一起。


#### 第三步获取Providers。获取ContentProvide组件。

熟悉源码的人都知道实际上在绑定Application的时候，会获取一个App内部所有的provider。详细就不铺开说了。想要详细了解的，可以去看看任玉刚的书。

基础模型前后都准备好了，只剩下类的加载和资源加载都明白了，就知道Small的基本原理是什么了。

### Small SetUp
根据上面的启动时序图，会直接走到loadBundles中，加载Bundle数据也就是模块插件。
直接看看源码。
```
private static void loadBundles(Context context) {
        JSONObject manifestData;
        try {
            File patchManifestFile = getPatchManifestFile();
            String manifestJson = getCacheManifest();
            if (manifestJson != null) {
                // Load from cache and save as patch
                if (!patchManifestFile.exists()) patchManifestFile.createNewFile();
                PrintWriter pw = new PrintWriter(new FileOutputStream(patchManifestFile));
                pw.print(manifestJson);
                pw.flush();
                pw.close();
                // Clear cache
                setCacheManifest(null);
            } else if (patchManifestFile.exists()) {
                // Load from patch
                BufferedReader br = new BufferedReader(new FileReader(patchManifestFile));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line);
                }

                br.close();
                manifestJson = sb.toString();
            } else {
                // Load from built-in `assets/bundle.json'
                InputStream builtinManifestStream = context.getAssets().open(BUNDLE_MANIFEST_NAME);
                int builtinSize = builtinManifestStream.available();
                byte[] buffer = new byte[builtinSize];
                builtinManifestStream.read(buffer);
                builtinManifestStream.close();
                manifestJson = new String(buffer, 0, builtinSize);
            }

            // Parse manifest file
            manifestData = new JSONObject(manifestJson);
        } catch (Exception e) {
            e.printStackTrace();
            return;
        }

        Manifest manifest = parseManifest(manifestData);
        if (manifest == null) return;

        setupLaunchers(context);

        loadBundles(manifest.bundles);
    }
```
这一段的源码实际上是在线程中处理的。我们可以从这段代码得知，实际上，Bundle第一次加载都会从asset的bundle.json文件中读取数据，通过这个json数据把插件里面的bundle实例化出来加载到List。看看parseManifest的方法。
```
    private static Manifest parseManifest(String version, JSONObject data) {
        if (version.equals("1.0.0")) {
            try {
                JSONArray bundleDescs = data.getJSONArray(BUNDLES_KEY);
                int N = bundleDescs.length();
                List<Bundle> bundles = new ArrayList<Bundle>(N);
                for (int i = 0; i < N; i++) {
                    try {
                        JSONObject object = bundleDescs.getJSONObject(i);
                        Bundle bundle = new Bundle(object);
                        bundles.add(bundle);
                    } catch (JSONException e) {
                        // Ignored
                    }
                }
                Manifest manifest = new Manifest();
                manifest.version = version;
                manifest.bundles = bundles;
                return manifest;
            } catch (JSONException e) {
                e.printStackTrace();
                return null;
            }
        }

        throw new UnsupportedOperationException("Unknown version " + version);
    }
```
通过bundle.json就能正确获取到每个插件中的信息了，以待后面调用。


#### setupLaunchers
实际上就是轮询加入到了BundleLauncher的List，调用setUp的方法。
依照顺序来看看都做了什么处理。

##### ActivityLauncher
```
   @Override
    public void setUp(Context context) {
        super.setUp(context);

        // Read the registered classes in host's manifest file
        File sourceFile = new File(context.getApplicationInfo().sourceDir);
        BundleParser parser = BundleParser.parsePackage(sourceFile, context.getPackageName());
        parser.collectActivities();
        ActivityInfo[] as = parser.getPackageInfo().activities;
        if (as != null) {
            sActivityClasses = new HashSet<String>();
            for (ActivityInfo ai : as) {
                sActivityClasses.add(ai.name);
            }
        }
    }
```

这个方法主要动作实际上是解析包内部的数据。获取ActivityInfo，并且加入到sActivityClasses中的List，用于快速检测是否有这个Activity。

稍微看看如何解析的。
```
public static BundleParser parsePackage(File sourceFile, String packageName) {
        if (sourceFile == null || !sourceFile.exists()) return null;

        BundleParser bp = new BundleParser(sourceFile, packageName);
        if (!bp.parsePackage()) return null;

        return bp;
    }

    public boolean parsePackage() {
        AssetManager assmgr = null;
        boolean assetError = true;
        try {
            assmgr = ReflectAccelerator.newAssetManager();
            if (assmgr == null) return false;

            int cookie = ReflectAccelerator.addAssetPath(assmgr, mArchiveSourcePath);
            if(cookie != 0) {
                parser = assmgr.openXmlResourceParser(cookie, "AndroidManifest.xml");
                assetError = false;
            } else {
                Log.w(TAG, "Failed adding asset path:"+mArchiveSourcePath);
            }
        } catch (Exception e) {
            Log.w(TAG, "Unable to read AndroidManifest.xml of "
                    + mArchiveSourcePath, e);
        }
        if (assetError) {
            if (assmgr != null) assmgr.close();
            return false;
        }

        res = new Resources(assmgr, mContext.getResources().getDisplayMetrics(), null);
        return parsePackage(res, parser);
    }
```
首先Small会在编译的时候会重新打包一次，通过Gradle的插件在AndroidManifest.xml中插入用来占坑的代理Activity。接着通过AssetMananger.addAssetPath解析整个包的资源。在这里补充一下，在上面资源查找的时序图中的getOrCreateResources方法中实际上就是调用AssetMananger.addAssetPath来解析的。这里是直接调用该方法解析。

```
public boolean collectActivities() {
        if (mPackageInfo == null || mPackageInfo.applicationInfo == null) return false;
        AttributeSet attrs = parser;

        int type;
        try {
            List<ActivityInfo> activities = new ArrayList<ActivityInfo>();
            while ((type = parser.next()) != XmlResourceParser.END_DOCUMENT) {
                if (type != XmlResourceParser.START_TAG) {
                    continue;
                }

                String tagName = parser.getName();
                if (!tagName.equals("activity")) continue;

                // <activity ...
                ActivityInfo ai = new ActivityInfo();
                ai.applicationInfo = mPackageInfo.applicationInfo;
                ai.packageName = ai.applicationInfo.packageName;

                TypedArray sa = res.obtainAttributes(attrs,
                        R.styleable.AndroidManifestActivity);
                String name = sa.getString(R.styleable.AndroidManifestActivity_name);
                if (name != null) {
                    ai.name = ai.targetActivity = buildClassName(mPackageName, name);
                }

              //资源解析，该出省略
                ...

                activities.add(ai);

                sa.recycle();

                // <intent-filter ...
                List<IntentFilter> intents = new ArrayList<IntentFilter>();
                int outerDepth = parser.getDepth();
                while ((type=parser.next()) != XmlResourceParser.END_DOCUMENT
                        && (type != XmlResourceParser.END_TAG
                        || parser.getDepth() > outerDepth)) {
                    if (type == XmlResourceParser.END_TAG || type == XmlResourceParser.TEXT) {
                        continue;
                    }

                    if (parser.getName().equals("intent-filter")) {
                        IntentFilter intent = new IntentFilter();
                        
                        parseIntent(res, parser, attrs, true, true, intent);

                        if (intent.countActions() == 0) {
                            Log.w(TAG, "No actions in intent filter at "
                                    + mArchiveSourcePath + " "
                                    + parser.getPositionDescription());
                        } else {
                            intents.add(intent);
                            if (intent.hasCategory(Intent.CATEGORY_LAUNCHER)) {
                                mLauncherActivityName = ai.name;
                            }
                        }
                    }
                }

                if (intents.size() > 0) {
                    if (mIntentFilters == null) {
                        mIntentFilters = new ConcurrentHashMap<String, List<IntentFilter>>();
                    }
                    mIntentFilters.put(ai.name, intents);
                }
            }

            int N = activities.size();
            if (N > 0) {
                mPackageInfo.activities = new ActivityInfo[N];
                mPackageInfo.activities = activities.toArray(mPackageInfo.activities);
            }
            return true;
        } catch (XmlPullParserException e) {
            e.printStackTrace();
        } catch (IOException e) {
            e.printStackTrace();
        }
        return false;
    }

```
这个方法就和上面DroidPlugin的思路不一样，上面DroidPlugin是希望让Android系统帮我们生成ActivityInfo，而这个是通过解析AndroidManifest.xml自己ActivityInfo。

这样关键点ActivityInfo就获取到了。同时ActivityLauncher也就完成了。

##### ApkLauncher
```
    @Override
    public void setUp(Context context) {
        super.setUp(context);

        Field f;

        // AOP for pending intent
        try {
            f = TaskStackBuilder.class.getDeclaredField("IMPL");
            f.setAccessible(true);
            final Object impl = f.get(TaskStackBuilder.class);
            InvocationHandler aop = new InvocationHandler() {
                @Override
                public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                    Intent[] intents = (Intent[]) args[1];
                    for (Intent intent : intents) {
                        sBundleInstrumentation.wrapIntent(intent);
                        intent.setAction(Intent.ACTION_MAIN);
                        intent.addCategory(Intent.CATEGORY_LAUNCHER);
                    }
                    return method.invoke(impl, args);
                }
            };
            Object newImpl = Proxy.newProxyInstance(context.getClassLoader(), impl.getClass().getInterfaces(), aop);
            f.set(TaskStackBuilder.class, newImpl);
        } catch (Exception ignored) {
            Log.e(TAG, "Failed to hook TaskStackBuilder. \n" +
                    "Please manually call `Small.wrapIntent` to ensure the notification intent can be opened. \n" +
                    "See https://github.com/wequick/Small/issues/547 for details.");
        }
    }
```
这个ApkLauncher的setUp方法是对TaskStackBuilder的进行一次包装，这个类用来创建一个回退栈。经常在点击通知的时候，通过这个类跳转到我们的需要跳转的Activity。点击回退就会到AndroidManifest.xml中配置的Activity。详细也不铺开说。由于也是启动Activity，那么也是用包装来骗过Android来打开插件的Activity。

##### WebBundleLauncher
```
@Override
    public void setUp(Context context) {
        super.setUp(context);
        if (Build.VERSION.SDK_INT < 24) return;

        Bundle.postUI(new Runnable() {
            @Override
            public void run() {
                // In android 7.0+, on firstly create WebView, it will replace the application
                // assets with the one who has join the WebView asset path.
                // If this happens after our assets replacement,
                // what we have done would be come to naught!
                // So, we need to push it enOOOgh ahead! (#347)
                new android.webkit.WebView(Small.getContext());
            }
        });
    }
```
对于7.0+的，WebView特殊处理。注释上已经很清晰了。就是因为第一次创建WebView会替换掉那些已经加入WebView的application的assetPath。所以需要先建立一个做准备。

### loadBundles

```
private static void loadBundles(List<Bundle> bundles) {
        sPreloadBundles = bundles;

        // Prepare bundle
        for (Bundle bundle : bundles) {
            bundle.prepareForLaunch();
        }

        // Handle I/O
        if (sIOActions != null) {
            ExecutorService executor = Executors.newFixedThreadPool(sIOActions.size());
            for (Runnable action : sIOActions) {
                executor.execute(action);
            }
            executor.shutdown();
            try {
                if (!executor.awaitTermination(LOADING_TIMEOUT_MINUTES, TimeUnit.MINUTES)) {
                    throw new RuntimeException("Failed to load bundles! (TIMEOUT > "
                            + LOADING_TIMEOUT_MINUTES + "minutes)");
                }
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
            sIOActions = null;
        }

        // Wait for the things to be done on UI thread before `postSetUp`,
        // as on 7.0+ we should wait a WebView been initialized. (#347)
        while (sRunningUIActionCount != 0) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        }

        // Notify `postSetUp' to all launchers
        for (BundleLauncher launcher : sBundleLaunchers) {
            launcher.postSetUp();
        }

        // Wait for the things to be done on UI thread after `postSetUp`,
        // like creating a bundle application.
        while (sRunningUIActionCount != 0) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        }

        // Free all unused temporary variables
        for (Bundle bundle : bundles) {
            if (bundle.parser != null) {
                bundle.parser.close();
                bundle.parser = null;
            }
            bundle.mBuiltinFile = null;
            bundle.mExtractPath = null;
        }
    }
```

读取Bundle的数据。分为以下三步，并分别解析：
##### 1.每个Bundle通过prepareForLaunch做一次使用Bundle前处理，之后做真正的loadBundle。

在调用prepareForLaunch会直接调用每个BundleLauncher的resolveBundle方法。
```
protected void prepareForLaunch() {
        if (mIntent != null) return;

        if (mApplicableLauncher == null && sBundleLaunchers != null) {
            for (BundleLauncher launcher : sBundleLaunchers) {
                if (launcher.resolveBundle(this)) {
                    mApplicableLauncher = launcher;
                    break;
                }
            }
        }
    }
```
```
public boolean resolveBundle(Bundle bundle) {
        if (!preloadBundle(bundle)) return false;

        loadBundle(bundle);
        return true;
    }
```
看看每个BundleLauncher的preloadBundle方法。

###### ActivityLauncher
```
@Override
    public boolean preloadBundle(Bundle bundle) {
        if (sActivityClasses == null) return false;

        String pkg = bundle.getPackageName();
        return (pkg == null || pkg.equals("main"));
    }
```
检测之前解析好的sActivityClasses究竟是否为空，以及bundle传进来的是否为空或者为main主模块名称。做这个判断只要是为了检查是否解析包名。同时检查出哪些宿主哪些是插件 。

而在这个BundleLauncher并没有重写loadBundle。也就是说没有这一步。

###### SoBundleLauncher
```
@Override
    public boolean preloadBundle(Bundle bundle) {
        String packageName = bundle.getPackageName();
        if (packageName == null) return false;

        // Check if supporting
        String[] types = getSupportingTypes();
        if (types == null) return false;

        boolean supporting = false;
        String bundleType = bundle.getType();
        if (bundleType != null) {
            // Consider user-defined type in `bundle.json'
            for (String type : types) {
                if (type.equals(bundleType)) {
                    supporting = true;
                    break;
                }
            }
        } else {
            // Consider explicit type specify in package name as following:
            //  - com.example.[type].any
            //  - com.example.[type]any
            String[] pkgs = packageName.split("\\.");
            int N = pkgs.length;
            String aloneType = N > 1 ? pkgs[N - 2] : null;
            String lastComponent = pkgs[N - 1];
            for (String type : types) {
                if ((aloneType != null && aloneType.equals(type))
                        || lastComponent.startsWith(type)) {
                    supporting = true;
                    break;
                }
            }
        }
        if (!supporting) return false;

        // Initialize the extract path
        File extractPath = getExtractPath(bundle);
        if (extractPath != null) {
            if (!extractPath.exists()) {
                extractPath.mkdirs();
            }
            bundle.setExtractPath(extractPath);
        }

        // Select the bundle entry-point, `built-in' or `patch'
        File plugin = bundle.getBuiltinFile();
        BundleParser parser = BundleParser.parsePackage(plugin, packageName);
        File patch = bundle.getPatchFile();
        BundleParser patchParser = BundleParser.parsePackage(patch, packageName);
        if (parser == null) {
            if (patchParser == null) {
                return false;
            } else {
                parser = patchParser; // use patch
                plugin = patch;
            }
        } else if (patchParser != null) {
            if (patchParser.getPackageInfo().versionCode <= parser.getPackageInfo().versionCode) {
                Log.d(TAG, "Patch file should be later than built-in!");
                patch.delete();
            } else {
                parser = patchParser; // use patch
                plugin = patch;
            }
        }
        bundle.setParser(parser);

        // Check if the plugin has not been modified
        long lastModified = plugin.lastModified();
        long savedLastModified = Small.getBundleLastModified(packageName);
        if (savedLastModified != lastModified) {
            // If modified, verify (and extract) each file entry for the bundle
            if (!parser.verifyAndExtract(bundle, this)) {
                bundle.setEnabled(false);
                return true; // Got it, but disabled
            }
            Small.setBundleLastModified(packageName, lastModified);
        }

        // Record version code for upgrade
        PackageInfo pluginInfo = parser.getPackageInfo();
        bundle.setVersionCode(pluginInfo.versionCode);
        bundle.setVersionName(pluginInfo.versionName);

        return true;
    }
```

这段代码主要是检测SoBundleLauncher支持怎么样的类型，通过抽象方法getSupportingTypes确定。接着再去解析Bundle，这一次的解析和上面的不一样，这一次的解析决定了是使用Asset中外部的插件，还是我们本工程的模块。

再来看看剩下两个子类launcher的loadBundle

###### ApkBundleLauncher
```
    @Override
    public void loadBundle(Bundle bundle) {
        String packageName = bundle.getPackageName();

        BundleParser parser = bundle.getParser();
        parser.collectActivities();
        PackageInfo pluginInfo = parser.getPackageInfo();

        // Load the bundle
        String apkPath = parser.getSourcePath();
        if (sLoadedApks == null) sLoadedApks = new ConcurrentHashMap<String, LoadedApk>();
        LoadedApk apk = sLoadedApks.get(packageName);
        if (apk == null) {
            apk = new LoadedApk();
            apk.packageName = packageName;
            apk.path = apkPath;
            apk.nonResources = parser.isNonResources();
            if (pluginInfo.applicationInfo != null) {
                apk.applicationName = pluginInfo.applicationInfo.className;
            }
            apk.packagePath = bundle.getExtractPath();
            apk.optDexFile = new File(apk.packagePath, FILE_DEX);

            // Load dex
            final LoadedApk fApk = apk;
            Bundle.postIO(new Runnable() {
                @Override
                public void run() {
                    try {
                        fApk.dexFile = DexFile.loadDex(fApk.path, fApk.optDexFile.getPath(), 0);
                    } catch (IOException e) {
                        throw new RuntimeException(e);
                    }
                }
            });

            // Extract native libraries with specify ABI
            String libDir = parser.getLibraryDirectory();
            if (libDir != null) {
                apk.libraryPath = new File(apk.packagePath, libDir);
            }
            sLoadedApks.put(packageName, apk);
        }

        if (pluginInfo.activities == null) {
            return;
        }

        // Record activities for intent redirection
        if (sLoadedActivities == null) sLoadedActivities = new ConcurrentHashMap<String, ActivityInfo>();
        for (ActivityInfo ai : pluginInfo.activities) {
            sLoadedActivities.put(ai.name, ai);
        }

        // Record intent-filters for implicit action
        ConcurrentHashMap<String, List<IntentFilter>> filters = parser.getIntentFilters();
        if (filters != null) {
            if (sLoadedIntentFilters == null) {
                sLoadedIntentFilters = new ConcurrentHashMap<String, List<IntentFilter>>();
            }
            sLoadedIntentFilters.putAll(filters);
        }

        // Set entrance activity
        bundle.setEntrance(parser.getDefaultActivityName());
    }
```
这里的操作就是我上面个插件化基础模型中，寻找ClassLoader，加载类的步骤。这里是Small作者自定义自己的一个LoadApk类，丢到Map中自己亲自管理。通过上面setUp的步骤解析出来的信息，自己亲自生成一个和系统一样的LoadedApk。同时设置好dex文件的位置，为后面postSetUp对ClassLoader的处理做准备。

###### AssetBundleLauncher
```
@Override
    public void loadBundle(Bundle bundle) {
        String packageName = bundle.getPackageName();
        File unzipDir = new File(getBasePath(), packageName);
        File indexFile = new File(unzipDir, getIndexFileName());

        // Prepare index url
        String uri = indexFile.toURI().toString();
        if (bundle.getQuery() != null) {
            uri += "?" + bundle.getQuery();
        }
        URL url;
        try {
            url = new URL(uri);
        } catch (MalformedURLException e) {
            Log.e(TAG, "Failed to parse url " + uri + " for bundle " + packageName);
            return;
        }
        String scheme = url.getProtocol();
        if (!scheme.equals("http") &&
                !scheme.equals("https") &&
                !scheme.equals("file")) {
            Log.e(TAG, "Unsupported scheme " + scheme + " for bundle " + packageName);
            return;
        }
        bundle.setURL(url);
    }
```
检验每个Bundle对应的Url是否合法，合法则设置。

##### 2.把之前通过postIO放入的线程操作全部运行


##### 3.每个BundleLauncher postSetUp setUp完毕处理
我们一样跟着顺序来看。
###### ActivityLauncher
并没有重写postSetUp方法。

###### ApkBundleLauncher
```
@Override
    public void postSetUp() {
        super.postSetUp();

        if (sLoadedApks == null) {
            Log.e(TAG, "Could not find any APK bundles!");
            return;
        }

        Collection<LoadedApk> apks = sLoadedApks.values();

        // Merge all the resources in bundles and replace the host one
        final Application app = Small.getContext();
        String[] paths = new String[apks.size() + 1];
        paths[0] = app.getPackageResourcePath(); // add host asset path
        int i = 1;
        for (LoadedApk apk : apks) {
            if (apk.nonResources) continue; // ignores the empty entry to fix #62
            paths[i++] = apk.path; // add plugin asset path
        }
        if (i != paths.length) {
            paths = Arrays.copyOf(paths, i);
        }
        ReflectAccelerator.mergeResources(app, sActivityThread, paths);

        // Merge all the dex into host's class loader
        ClassLoader cl = app.getClassLoader();
        i = 0;
        int N = apks.size();
        String[] dexPaths = new String[N];
        DexFile[] dexFiles = new DexFile[N];
        for (LoadedApk apk : apks) {
            dexPaths[i] = apk.path;
            dexFiles[i] = apk.dexFile;
            if (Small.getBundleUpgraded(apk.packageName)) {
                // If upgraded, delete the opt dex file for recreating
                if (apk.optDexFile.exists()) apk.optDexFile.delete();
                Small.setBundleUpgraded(apk.packageName, false);
            }
            i++;
        }
        ReflectAccelerator.expandDexPathList(cl, dexPaths, dexFiles);

        // Expand the native library directories for host class loader if plugin has any JNIs. (#79)
        List<File> libPathList = new ArrayList<File>();
        for (LoadedApk apk : apks) {
            if (apk.libraryPath != null) {
                libPathList.add(apk.libraryPath);
            }
        }
        if (libPathList.size() > 0) {
            ReflectAccelerator.expandNativeLibraryDirectories(cl, libPathList);
        }

        // Trigger all the bundle application `onCreate' event
        for (final LoadedApk apk : apks) {
            String bundleApplicationName = apk.applicationName;
            if (bundleApplicationName == null) continue;

            try {
                final Class applicationClass = Class.forName(bundleApplicationName);
                Bundle.postUI(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            BundleApplicationContext appContext = new BundleApplicationContext(app, apk);
                            Application bundleApplication = Instrumentation.newApplication(
                                    applicationClass, appContext);
                            sHostInstrumentation.callApplicationOnCreate(bundleApplication);
                        } catch (Exception e) {
                            e.printStackTrace();
                        }
                    }
                });
            } catch (Exception e) {
                e.printStackTrace();
            }
        }

        // Lazy init content providers
        ...

        // Free temporary variables
        sLoadedApks = null;
        sProviders = null;
    }
```
#### 这个是重点。Small对于类和资源的方式
我们回顾以下我上面写的插件化的基础模型。该反射的类有了，基础模型前后部分都准备好了，还差什么？当然还差怎么找插件的类和资源了？和DroidPlugin不同，Small选择了保守的方式来加载类和资源。

#### 那么资源是怎么加载呢？
这里要展开ResourcesManager来看看是怎么回事。根据我的流程图走到了getResources就会走内部的getOrCreateResources的方法。注意这里和Android6.0的源码有比较大的区别，这里就展开说了，还是按照7.0的源码说明。
```
    private @NonNull Resources getOrCreateResources(@Nullable IBinder activityToken,
            @NonNull ResourcesKey key, @NonNull ClassLoader classLoader) {
        synchronized (this) {
           ...
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
                    if (DEBUG) {
                        Slog.d(TAG, "- using existing impl=" + resourcesImpl);
                    }
                    return getOrCreateResourcesForActivityLocked(activityToken, classLoader,
                            resourcesImpl);
                }

                // We will create the ResourcesImpl object outside of holding this lock.

            } else {
                // Clean up any dead references so they don't pile up.
                ArrayUtils.unstableRemoveIf(mResourceReferences, sEmptyReferencePredicate);

                // Not tied to an Activity, find a shared Resources that has the right ResourcesImpl
                ResourcesImpl resourcesImpl = findResourcesImplForKeyLocked(key);
                if (resourcesImpl != null) {
                    if (DEBUG) {
                        Slog.d(TAG, "- using existing impl=" + resourcesImpl);
                    }
                    return getOrCreateResourcesLocked(classLoader, resourcesImpl);
                }

                // We will create the ResourcesImpl object outside of holding this lock.
            }
        }

        // If we're here, we didn't find a suitable ResourcesImpl to use, so create one now.
        ResourcesImpl resourcesImpl = createResourcesImpl(key);

        synchronized (this) {
            ResourcesImpl existingResourcesImpl = findResourcesImplForKeyLocked(key);
            if (existingResourcesImpl != null) {
                if (DEBUG) {
                    Slog.d(TAG, "- got beat! existing impl=" + existingResourcesImpl
                            + " new impl=" + resourcesImpl);
                }
                resourcesImpl.getAssets().close();
                resourcesImpl = existingResourcesImpl;
            } else {
                // Add this ResourcesImpl to the cache.
                mResourceImpls.put(key, new WeakReference<>(resourcesImpl));
            }

            final Resources resources;
            if (activityToken != null) {
                resources = getOrCreateResourcesForActivityLocked(activityToken, classLoader,
                        resourcesImpl);
            } else {
                resources = getOrCreateResourcesLocked(classLoader, resourcesImpl);
            }
            return resources;
        }
    }
```
根据上面的时序图，由于我们应用第一次查找资源的时候，activitytoken传进来是null。

都会走activityToken判断的下侧。首先清空缓存中不需要的资源，接着通过ResourceKey从mResourceImpls这个中寻找寻找ResourcesImpl这个资源实现类。找到则返回。
```
private ResourcesImpl findResourcesImplForKeyLocked(@NonNull ResourcesKey key) {
        WeakReference<ResourcesImpl> weakImplRef = mResourceImpls.get(key);
        ResourcesImpl impl = weakImplRef != null ? weakImplRef.get() : null;
        if (impl != null && impl.getAssets().isUpToDate()) {
            return impl;
        }
        return null;
    }
```
没有找到则从createResourcesImpl新建一个ResourcesImpl存放到mResourceImpls中。最后再通过getOrCreateResourcesLocked生成Resources类。
```
  private @NonNull Resources getOrCreateResourcesLocked(@NonNull ClassLoader classLoader,
            @NonNull ResourcesImpl impl) {
        // Find an existing Resources that has this ResourcesImpl set.
        final int refCount = mResourceReferences.size();
        for (int i = 0; i < refCount; i++) {
            WeakReference<Resources> weakResourceRef = mResourceReferences.get(i);
            Resources resources = weakResourceRef.get();
            if (resources != null &&
                    Objects.equals(resources.getClassLoader(), classLoader) &&
                    resources.getImpl() == impl) {
                if (DEBUG) {
                    Slog.d(TAG, "- using existing ref=" + resources);
                }
                return resources;
            }
        }

        // Create a new Resources reference and use the existing ResourcesImpl object.
        Resources resources = new Resources(classLoader);
        resources.setImpl(impl);
        mResourceReferences.add(new WeakReference<>(resources));
        if (DEBUG) {
            Slog.d(TAG, "- creating new ref=" + resources);
            Slog.d(TAG, "- setting ref=" + resources + " with impl=" + impl);
        }
        return resources;
    }
```
这样大家就明白实际上所有的ResourceImpl都会缓存到mResourceImpls，而Resource则会缓存到mResourceReferences。和Android6.0/5.0不同，6.0/5.0会缓存到mActiveResources中。

那么就会明白了，如果我们能够把反射获取这两个位置，将对应的Resources和ResourceImpl，把Resources加入。从原理上就能获取到Android的资源管理体系。

但是，问题还没有彻底解决，不同于DroidPlugin的思路，这里我们并非是把事情委托给系统完成，而是我们一步步来解决这些问题。所以我们还需要把对应路径下的资源读取出来才行，不然一切都是假的。

我们看看**AssetManager**源码和***ResourcesImpl**的构造方法
和Android6.0之前不一样的是，以前的Resources会直接管理AssetManager，而在这里就被ResourcesImpl接管。所以我们要去ResourcesImpl的构造方法。
```
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
这个createAssetManager就是关键。
```
 if (key.mResDir != null) {
            if (assets.addAssetPath(key.mResDir) == 0) {
                throw new Resources.NotFoundException("failed to add asset path " + key.mResDir);
            }
        }
```

其中这一段就是通过mResDir来生成对应的资源的管理类AssetManager。结合我之前的源码分析，很简单明白，如果我们想要获得自己的Resources，就要自己去调用一次这个方法，把生成的AssetManager生成一个ResourcesImpl就能生成自己想要的Resources了。

```
ReflectAccelerator.mergeResources(app, sActivityThread, paths);
```
#### Small 的资源加载源码
思路明白了，看看Small是怎么做的,这里只关注7.0部分。

```
public static void mergeResources(Application app, Object activityThread, String[] assetPaths) {
//第一段
        AssetManager newAssetManager;
        if (Build.VERSION.SDK_INT < 24) {
            newAssetManager = newAssetManager();
        } else {
            // On Android 7.0+, this should contains a WebView asset as base. #347
            newAssetManager = app.getAssets();
        }
        addAssetPaths(newAssetManager, assetPaths);
//第二段
        try {
            if (Build.VERSION.SDK_INT < 28) {
                Method mEnsureStringBlocks = AssetManager.class.getDeclaredMethod("ensureStringBlocks", new Class[0]);
                mEnsureStringBlocks.setAccessible(true);
                mEnsureStringBlocks.invoke(newAssetManager, new Object[0]);
            } else {
                // `AssetManager#ensureStringBlocks` becomes unavailable since android 9.0
            }

            Collection<WeakReference<Resources>> references;

            if (Build.VERSION.SDK_INT >= 19) {
                Class<?> resourcesManagerClass = Class.forName("android.app.ResourcesManager");
                Method mGetInstance = resourcesManagerClass.getDeclaredMethod("getInstance", new Class[0]);
                mGetInstance.setAccessible(true);
                Object resourcesManager = mGetInstance.invoke(null, new Object[0]);
                try {
                    ...
                } catch (NoSuchFieldException ignore) {
                    Field mResourceReferences = resourcesManagerClass.getDeclaredField("mResourceReferences");
                    mResourceReferences.setAccessible(true);

                    references = (Collection) mResourceReferences.get(resourcesManager);
                }

                if (Build.VERSION.SDK_INT >= 24) {
                    Field fMResourceImpls = resourcesManagerClass.getDeclaredField("mResourceImpls");
                    fMResourceImpls.setAccessible(true);
                    sResourceImpls = (ArrayMap)fMResourceImpls.get(resourcesManager);
                }
            } else {
               ...
            }

            //to array
            WeakReference[] referenceArrays = new WeakReference[references.size()];
            references.toArray(referenceArrays);

            for (int i = 0; i < referenceArrays.length; i++) {
                Resources resources = (Resources) referenceArrays[i].get();
                if (resources == null) continue;

                try {
                    Field mAssets = Resources.class.getDeclaredField("mAssets");
                    mAssets.setAccessible(true);
                    mAssets.set(resources, newAssetManager);
                } catch (Throwable ignore) {
                    Field mResourcesImpl = Resources.class.getDeclaredField("mResourcesImpl");
                    mResourcesImpl.setAccessible(true);
                    Object resourceImpl = mResourcesImpl.get(resources);
                    Field implAssets;
                    try {
                        implAssets = resourceImpl.getClass().getDeclaredField("mAssets");
                    } catch (NoSuchFieldException e) {
                        // Compat for MiUI 8+
                        implAssets = resourceImpl.getClass().getSuperclass().getDeclaredField("mAssets");
                    }
                    implAssets.setAccessible(true);
                    implAssets.set(resourceImpl, newAssetManager);

                    if (Build.VERSION.SDK_INT >= 24) {
                        if (resources == app.getResources()) {
                            sMergedResourcesImpl = resourceImpl;
                        }
                    }
                }

                resources.updateConfiguration(resources.getConfiguration(), resources.getDisplayMetrics());
            }
//第三段
            if (Build.VERSION.SDK_INT >= 21) {
                for (int i = 0; i < referenceArrays.length; i++) {
                    Resources resources = (Resources) referenceArrays[i].get();
                    if (resources == null) continue;

                    // android.util.Pools$SynchronizedPool<TypedArray>
                    Field mTypedArrayPool = Resources.class.getDeclaredField("mTypedArrayPool");
                    mTypedArrayPool.setAccessible(true);
                    Object typedArrayPool = mTypedArrayPool.get(resources);
                    // Clear all the pools
                    Method acquire = typedArrayPool.getClass().getMethod("acquire");
                    acquire.setAccessible(true);
                    while (acquire.invoke(typedArrayPool) != null) ;
                }
            }
        } catch (Throwable e) {
            throw new IllegalStateException(e);
        }
    }
```
这里的思路稍微有点不一样，Small作者的想法是merge也就是合并资源。也就是使用原有的AssetManager，但是把原来的资源路径添加进去。

也就是说ResourcesImpl的Assetmanager换成我们新的AssetManager，让它能够找到我们的资源。

第一段，就是新建一个AssetManager，并且通过addAssetPaths把资源读入AssetManager中。

第二段，在低于api28的时候，我们还需要调用一次ensureStringBlocks确定native层也加载了资源数据。

获取ResourcesManager的单例，接着获取mResourceReferences这个属性，拿到Resources这个List集合。如果Api大于24则会获取mResourceImpls这个ResourcesImpl的ArrayMap集合。把这个集合取出放到全局变量中。

第三段，则是清空typedArrayPool这个用来缓存TypeArray缓存的Pool。为的是避免出现一些错误。

记住sMergedResourcesImpl这个ResourcesImpl，因为这个直接放入mResourceImpls这个集合中有个问题，那就是实际上Map的key是一个弱引用，gc以来就丢失，所以Small的作者就放到了跳转的时候再一次处理。这个问题我们之后等到Activity的启动的时候，就能看到了。

这里稍微提一句，就算是合并了也存可能存在id可能一致而导致映射错误的情况，这种情况在去年尝试着用这种方式加载资源的时候遇到过。Small的解决办法是通过gradle重新打包，重新分配资源id。这里涉及到native层的源码，这里不铺开说了，详细的可以看源码。

如何Small分配资源id的规则：
https://github.com/wequick/Small/wiki/Android-dynamic-load-classes


#### 资源找到了，那类又怎么找到呢？

那么什么是保守的方式呢？我之前举出了两种方式，第二种就是看看能不能在BaseDexClassLoader做点事情，让他能找到我们的Class。这样我们又要稍微看看源码了。
```
public class BaseDexClassLoader extends ClassLoader {
    private final DexPathList pathList;
```
在BaseDexClassLoader中我们最后解析apk的dex数据都会到这个DexPathList中。

对于DexPathList这个类，注解是这么说的
```
 * A pair of lists of entries, associated with a {@code ClassLoader}.
 * One of the lists is a dex/resource path &mdash; typically referred
 * to as a "class path" &mdash; list, and the other names directories
 * containing native code libraries. Class path entries may be any of:
 * a {@code .jar} or {@code .zip} file containing an optional
 * top-level {@code classes.dex} file as well as arbitrary resources,
 * or a plain {@code .dex} file (with no possibility of associated
 * resources).
 *
 * <p>This class also contains methods to use these lists to look up
 * classes and resources.</p>
```
这里面包含了如何寻找相关类方法。也就是说我们只要获取这个对象，把我们插件dex的数据加到DexPathList的解析后面，就能通过App本身的ClassLoader找到我们的类了。

这就是我们所说的保守方式。

那解析的的dex数据又放在哪里呢？
```
    /**
     * List of dex/resource (class path) elements.
     * Should be called pathElements, but the Facebook app uses reflection
     * to modify 'dexElements' (http://b/7726934).
     */
    private Element[] dexElements;
```
就是这个dexElements，见名知其意。就是用来存放dex元素的。也就是说我们往这个dexElements后面添加我们解析好的数组就ok了。这个Element又是什么？实际上就是DexPathList的内部类，我们只要知道怎么把dex文件转化为Element就OK了。
```
public Element(File dir, boolean isDirectory, File zip, DexFile dexFile) {
            this.dir = dir;
            this.isDirectory = isDirectory;
            this.zip = zip;
            this.dexFile = dexFile;
        }

```

#### Small类的加载与原理解析
这里就直接看看Small怎么处理的。
调用方法如下：
```
ReflectAccelerator.expandDexPathList(cl, dexPaths, dexFiles);
```

核心方法：
```
public static boolean expandDexPathList(ClassLoader cl,
                                                String[] dexPaths, DexFile[] dexFiles) {
            try {
                int N = dexPaths.length;
                Object[] elements = new Object[N];
                for (int i = 0; i < N; i++) {
                    String dexPath = dexPaths[i];
                    File pkg = new File(dexPath);
                    DexFile dexFile = dexFiles[i];
                    elements[i] = makeDexElement(pkg, dexFile);
                }

                fillDexPathList(cl, elements);
            } catch (Exception e) {
                e.printStackTrace();
                return false;
            }
            return true;
        }
```
makeDexElement就是创造Element，就是简单的反射构造器，这里不解释。看看合并。
```
private static void fillDexPathList(ClassLoader cl, Object[] elements)
                throws NoSuchFieldException, IllegalAccessException {
            if (sPathListField == null) {
                sPathListField = getDeclaredField(DexClassLoader.class.getSuperclass(), "pathList");
            }
            Object pathList = sPathListField.get(cl);
            if (sDexElementsField == null) {
                sDexElementsField = getDeclaredField(pathList.getClass(), "dexElements");
            }
            expandArray(pathList, sDexElementsField, elements, true);
        }
```
果然是这样先反射获取DexElement在获取里面的Element数组
```
private static void expandArray(Object target, Field arrField,
                                    Object[] extraElements, boolean push)
            throws IllegalAccessException {
        Object[] original = (Object[]) arrField.get(target);
        Object[] combined = (Object[]) Array.newInstance(
                original.getClass().getComponentType(), original.length + extraElements.length);
        if (push) {
            System.arraycopy(extraElements, 0, combined, 0, extraElements.length);
            System.arraycopy(original, 0, combined, extraElements.length, original.length);
        } else {
            System.arraycopy(original, 0, combined, 0, original.length);
            System.arraycopy(extraElements, 0, combined, original.length, extraElements.length);
        }
        arrField.set(target, combined);
    }

```
接下来就是简单的把两个数组拼接到一起，再把数据设置回去就万事具备了。

#### WebBundleLauncher
并没重写postSetUp。

总的来说，Small将会在启动的时候，提供各种用来线索，组成了一个Small的插件化框架。只要等到我们使用openUri的时候，将会通过uri作为钥匙，把这些线索全部串起来。
那么这里可以给每个LauncherBundler在启动的时候整理出如下图的生命周期。

![BundleLauncher的启动生命周期.png](/images/BundleLauncher的启动生命周期.png)



## Small启动Activity
让我们看看Small是怎么启动Activity的。
```
Small.openUri("main", LaunchActivity.this);

 public static boolean openUri(String uriString, Context context) {
        return openUri(makeUri(uriString), context);
    }

public static boolean openUri(Uri uri, Context context) {
        // System url schemes
        String scheme = uri.getScheme();
        if (scheme != null
                && !scheme.equals("http")
                && !scheme.equals("https")
                && !scheme.equals("file")
                && ApplicationUtils.canOpenUri(uri, context)) {
            ApplicationUtils.openUri(uri, context);
            return true;
        }

        // Small url schemes
        Bundle bundle = Bundle.getLaunchableBundle(uri);
        if (bundle != null) {
            bundle.launchFrom(context);
            return true;
        }
        return false;
    }
```
从openUri可以得知，实际上是两步，第一步
```
protected static Bundle getLaunchableBundle(Uri uri) {
        if (sPreloadBundles != null) {
            for (Bundle bundle : sPreloadBundles) {
                if (bundle.matchesRule(uri)) {
                    if (bundle.mApplicableLauncher == null) {
                        break;
                    }

                    if (!bundle.enabled) return null; // Illegal bundle (invalid signature, etc.)
                    return bundle;
                }
            }
        }

        // Downgrade to show webView
        if (uri.getScheme() != null) {
            Bundle bundle = new Bundle();
            try {
                bundle.url = new URL(uri.toString());
            } catch (MalformedURLException e) {
                e.printStackTrace();
            }
            bundle.prepareForLaunch();
            bundle.setQuery(uri.getEncodedQuery()); // Fix issue #6 from Spring-Xu.
            bundle.mApplicableLauncher = new WebBundleLauncher();
            bundle.mApplicableLauncher.prelaunchBundle(bundle);
            return bundle;
        }
        return null;
    }
```

先从已经预加载的Bundle的List集合中寻找对应规则的的Bundle。如果找不到就认为可能是webview的界面跳转webview，也就是我们路由框架里面常说的降级处理。这个我们不关心，只看启动Activity。

第二步，调用launchFrom,拿到Application当前的主处理Launcher。
```
protected void launchFrom(Context context) {
        if (mApplicableLauncher != null) {
            mApplicableLauncher.launchBundle(this, context);
        }
    }
```

这个mApplicableLauncher会在prepareForLaunch判断出当前当前的全局主Bundle的登录处理类为哪个。上面有贴源码。也就是说如果是第一次进来，按照注册是顺序，依次是ActivityLauncher，ApkLauncher，WebLauncher。由于只需要找到第一个判断为true就break了。

所以默认情况下，如果找到预加载的Bundle是主模块则mApplicableLauncher为ActivityLauncher，如果预加载的Bundle是插件则mApplicableLauncher为ApkLauncher。这里只关注ApkLauncher，所以让我们看看ApkLauncher的launchBundle。

```
@Override
    public void launchBundle(Bundle bundle, Context context) {
        prelaunchBundle(bundle);
        super.launchBundle(bundle, context);
    }
```

先看看预登陆之前的准备。
```
@Override
    public void prelaunchBundle(Bundle bundle) {
        super.prelaunchBundle(bundle);
        Intent intent = new Intent();
        bundle.setIntent(intent);

        // Intent extras - class
        String activityName = bundle.getActivityName();
        if (!ActivityLauncher.containsActivity(activityName)) {
            if (sLoadedActivities == null) {
                throw new ActivityNotFoundException("Unable to find explicit activity class " +
                        "{ " + activityName + " }");
            }

            if (!sLoadedActivities.containsKey(activityName)) {
                if (activityName.endsWith("Activity")) {
                    throw new ActivityNotFoundException("Unable to find explicit activity class " +
                            "{ " + activityName + " }");
                }

                String tempActivityName = activityName + "Activity";
                if (!sLoadedActivities.containsKey(tempActivityName)) {
                    throw new ActivityNotFoundException("Unable to find explicit activity class " +
                            "{ " + activityName + "(Activity) }");
                }

                activityName = tempActivityName;
            }
        }
        intent.setComponent(new ComponentName(Small.getContext(), activityName));

        // Intent extras - params
        String query = bundle.getQuery();
        if (query != null) {
            intent.putExtra(Small.KEY_QUERY, '?'+query);
        }
    }
```
在这里是先判断主模块是否包含这个Bundle中对应的Activity。接着根据activityname生成我们要跳转的Intent。


再看看登录launchBundle
```
public void launchBundle(Bundle bundle, Context context) {
        if (!bundle.isLaunchable()) {
            // TODO: Exit app

            return;
        }

        if (context instanceof Activity) {
            Activity activity = (Activity) context;
            if (shouldFinishPreviousActivity(activity)) {
                activity.finish();
            }
            activity.startActivityForResult(bundle.getIntent(), Small.REQUEST_CODE_DEFAULT);
        } else {
            context.startActivity(bundle.getIntent());
        }
    }
```
在跳转方法中直接通过launchBundle直接跳转。

接下来的流程就是依照我最早给的Activity启动时序图，会到了mInstrumentation中，别忘了，这个mInstrumentation已经替换成我们的mInstrumentation，会先走我们自己的exactActivity方法。这个方法我早提过了。
```
       /** @Override V21+
         * Wrap activity from REAL to STUB */
        public ActivityResult execStartActivity(
                Context who, IBinder contextThread, IBinder token, Activity target,
                Intent intent, int requestCode, android.os.Bundle options) {
            wrapIntent(intent);
            ensureInjectMessageHandler(sActivityThread);
            return ReflectAccelerator.execStartActivity(mBase,
                    who, contextThread, token, target, intent, requestCode, options);
        }
```
wrapIntent 就是做我上面那个插件化基础模型的第一步，在跳转的时候，我们会造一个假的Intent，这个Intent实际上是一个通过gradle插件预编写好的，代理Activity。接着把我们要跳转的Activity的Intent存到代理的（占坑的）Activity的Intent中，设置到Bundle中进行跳转。这样就能骗过AMS了。

ensureInjectMessageHandler，也是Hook了mH，也就是构建了我的插件化基础模型的后半段。接着经过AMS的处理之后，会先走Small的Callback。
```
 @Override
        public boolean handleMessage(Message msg) {
            switch (msg.what) {
                case LAUNCH_ACTIVITY:
                    redirectActivity(msg);
                    break;
```
对Activity做一次重定向。
```
private void redirectActivity(Message msg) {
            final Object/*ActivityClientRecord*/ r = msg.obj;
            Intent intent = ReflectAccelerator.getIntent(r);
            tryReplaceActivityInfo(intent, new ActivityInfoReplacer() {
                @Override
                public void replace(ActivityInfo targetInfo) {
                    ReflectAccelerator.setActivityInfo(r, targetInfo);
                }
            });
        }
```
这个时候实际上也就走我的插件化基础模型的后半段。把Intent写解析出来，接着替换回去。借助tryReplaceActivityInfo设置好在ResourcesManager的资源
```
public static void ensureCacheResources() {
        if (Build.VERSION.SDK_INT < 24) return;
        if (sResourceImpls == null || sMergedResourcesImpl == null) return;

        Set<?> resourceKeys = sResourceImpls.keySet();
        for (Object resourceKey : resourceKeys) {
            WeakReference resourceImpl = (WeakReference)sResourceImpls.get(resourceKey);
            if (resourceImpl != null && resourceImpl.get() != sMergedResourcesImpl) {
                // Sometimes? the weak reference for the key was released by what
                // we can not find the cache resources we had merged before.
                // And the system will recreate a new one which only build with host resources.
                // So we needs to restore the cache. Fix #429.
                // FIXME: we'd better to find the way to KEEP the weak reference.
                sResourceImpls.put(resourceKey, new WeakReference<Object>(sMergedResourcesImpl));
            }
        }
    }
```
还记得sMergedResourcesImpl吗？这个时候将会将资源设置到sResourceImpls中，之后系统会调用ResourcesMananger生成Resources时候，发现有这个ResourcesImpl就会从插件包中生成正确的资源。

生成好之后别忘了把ActivityInfo设置回去，不然前功尽弃了。
```
public static void setActivityInfo(Object/*ActivityClientRecord*/ r, ActivityInfo ai) {
        if (sActivityClientRecord_activityInfo_field == null) {
            sActivityClientRecord_activityInfo_field = getDeclaredField(
                    r.getClass(), "activityInfo");
        }
        setValue(sActivityClientRecord_activityInfo_field, r, ai);
    }
```
## Small思路总结
到这里，就完成了Small的Activity的跳转。根据这个流程我们可以得到一个启动的思维图，比较简单这里就不上时序图

![Small的Activity跳转.png](/images/Small的Activity跳转.png)

看完源码之后，就很清楚的了解到，如果需要支持新的插件，或者更新插件。我们首先要更新bundle.json，接着重新setup一边Launcher，这样就能找到我们的新插件。实际上demo已经有了很好的演示了。

好的分析好之后，Small究竟从思想和源码的实现上大家估计都心中有数了。Small和RePlugin的比较我们放到后面去说。

别急先喝口水休息一下，我们慢慢来看看RePlugin。

# RePlugin
为什么拿出RePlugin呢？因为在我看来RePlugin虽然看起来都是360的，很可能和DroidPlugin相似。但是实际上RePlugin实现上在我看来打开了新世界的大门，其思路另辟蹊径。同时其思想，在本人看来又是一个另外一个层面的上的。最能让人另眼相看的有两点，首先打出了入侵最小的旗号，其次其工程的架构，将明确的区分了宿主和插件而且没有太多的代码入侵。宿主和插件双方能够单独运行。第三，灵活的使用了ContentProvider进行了跨进程的通信。第三点的技巧很值得我们学习。

让我们看看吧。这个插件化框架究竟是怎么回事。

老规矩先看用法。
先贴上github的wiki：
https://github.com/Qihoo360/RePlugin/wiki/%E5%BF%AB%E9%80%9F%E4%B8%8A%E6%89%8B

用法很简单，分为宿主和插件两块。
## 宿主配置
首先依赖
```
android {
    // ATTENTION!!! Must CONFIG this to accord with Gradle's standard, and avoid some error
    defaultConfig {
        applicationId "com.qihoo360.replugin.sample.host"
        ...
    }
    ...
}

// ATTENTION!!! Must be PLACED AFTER "android{}" to read the applicationId
apply plugin: 'replugin-host-gradle'

/**
 * 配置项均为可选配置，默认无需添加
 * 更多可选配置项参见replugin-host-gradle的RepluginConfig类
 * 可更改配置项参见 自动生成RePluginHostConfig.java
 */
repluginHostConfig {
    /**
     * 是否使用 AppCompat 库
     * 不需要个性化配置时，无需添加
     */
    useAppCompat = true
    /**
     * 背景不透明的坑的数量
     * 不需要个性化配置时，无需添加
     */
    countNotTranslucentStandard = 6
    countNotTranslucentSingleTop = 2
    countNotTranslucentSingleTask = 3
    countNotTranslucentSingleInstance = 2
}

dependencies {
    compile 'com.qihoo360.replugin:replugin-host-lib:2.2.4'
    ...
}
```
首先我们继承RePlugin的Application
```
public class SampleApplication extends RePluginApplication
```

接着可以添加各种自定义配置
```
 /**
     * RePlugin允许提供各种“自定义”的行为，让您“无需修改源代码”，即可实现相应的功能
     */
    @Override
    protected RePluginConfig createConfig() {
        RePluginConfig c = new RePluginConfig();

        // 允许“插件使用宿主类”。默认为“关闭”
        c.setUseHostClassIfNotFound(true);

        // FIXME RePlugin默认会对安装的外置插件进行签名校验，这里先关掉，避免调试时出现签名错误
        c.setVerifySign(!BuildConfig.DEBUG);

        // 针对“安装失败”等情况来做进一步的事件处理
        c.setEventCallbacks(new HostEventCallbacks(this));

        // FIXME 若宿主为Release，则此处应加上您认为"合法"的插件的签名，例如，可以写上"宿主"自己的。
        // RePlugin.addCertSignature("AAAAAAAAA");

        // 在Art上，优化第一次loadDex的速度
        // c.setOptimizeArtLoadDex(true);
        return c;
    }

    @Override
    protected RePluginCallbacks createCallbacks() {
        return new HostCallbacks(this);
    }

    /**
     * 宿主针对RePlugin的自定义行为
     */
    private class HostCallbacks extends RePluginCallbacks {

        private static final String TAG = "HostCallbacks";

        private HostCallbacks(Context context) {
            super(context);
        }

        @Override
        public boolean onPluginNotExistsForActivity(Context context, String plugin, Intent intent, int process) {
            // FIXME 当插件"没有安装"时触发此逻辑，可打开您的"下载对话框"并开始下载。
            // FIXME 其中"intent"需传递到"对话框"内，这样可在下载完成后，打开这个插件的Activity
            if (BuildConfig.DEBUG) {
                Log.d(TAG, "onPluginNotExistsForActivity: Start download... p=" + plugin + "; i=" + intent);
            }
            return super.onPluginNotExistsForActivity(context, plugin, intent, process);
        }

        /*
        @Override
        public PluginDexClassLoader createPluginClassLoader(PluginInfo pi, String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent) {
            String odexName = pi.makeInstalledFileName() + ".dex";
            if (RePlugin.getConfig().isOptimizeArtLoadDex()) {
                Dex2OatUtils.injectLoadDex(dexPath, optimizedDirectory, odexName);
            }

            long being = System.currentTimeMillis();
            PluginDexClassLoader pluginDexClassLoader = super.createPluginClassLoader(pi, dexPath, optimizedDirectory, librarySearchPath, parent);

            if (BuildConfig.DEBUG) {
                Log.d(Dex2OatUtils.TAG, "createPluginClassLoader use:" + (System.currentTimeMillis() - being));
                String odexAbsolutePath = (optimizedDirectory + File.separator + odexName);
                Log.d(Dex2OatUtils.TAG, "createPluginClassLoader odexSize:" + InterpretDex2OatHelper.getOdexSize(odexAbsolutePath));
            }

            return pluginDexClassLoader;
        }
        */
    }

    private class HostEventCallbacks extends RePluginEventCallbacks {

        private static final String TAG = "HostEventCallbacks";

        public HostEventCallbacks(Context context) {
            super(context);
        }

        @Override
        public void onInstallPluginFailed(String path, InstallResult code) {
            // FIXME 当插件安装失败时触发此逻辑。您可以在此处做“打点统计”，也可以针对安装失败情况做“特殊处理”
            // 大部分可以通过RePlugin.install的返回值来判断是否成功
            if (BuildConfig.DEBUG) {
                Log.d(TAG, "onInstallPluginFailed: Failed! path=" + path + "; r=" + code);
            }
            super.onInstallPluginFailed(path, code);
        }

        @Override
        public void onStartActivityCompleted(String plugin, String activity, boolean result) {
            // FIXME 当打开Activity成功时触发此逻辑，可在这里做一些APM、打点统计等相关工作
            super.onStartActivityCompleted(plugin, activity, result);
        }
    }
```

### 插件的配置
只需要添加配置
```
apply plugin: 'replugin-plugin-gradle'

dependencies {
    compile 'com.qihoo360.replugin:replugin-plugin-lib:2.2.4'
    ...
}
```

从上面可以清楚，实际上RePlugin对我们的代码入侵性十分低，同时也通过依赖不同的类库来区分出了宿主和插件。

了解如何使用，我们来思考这个问题，如何才能做到入侵性最少，换句说就是反射最少的系统源码下，能够完成插件的类与资源的读取。

当时我看到这个RePlugin的宣言时候，也在好奇怎么样才能做到最小的入侵性。确实如果真的要实现一个Activity的跳转，我一开始给插件化的基础模型是一个Activity跳转必备的流程，当时确实无法想到更加简单的办法。

反过来思考，在阅读了这么多的插件化源码，变化的永远是我们对不同版本以及对Android源码的理解而进行反射，让系统帮忙完成资源和类的加载。不变的是，我们永远需要通过ClassLoader来查找类。从变化中找不变，难道是对ClassLoader进行处理？在ClassLoader的loadClass的时候找我们想要的类，加载插件？很大胆的想法，而这种大胆的想法，还真的给RePlugin的团队实现了。

不得不说一声，一年前我学习DroidPlugin的时候为这个团队对源码的熟悉程度献上了膝盖。而现在对源码还算熟悉的我，再一次为RePlugin团队的极具开创性的想法再度献上膝盖。看了这么开源库能让我读着，读着就跳起来的，也就这两个库。

## Host-Library宿主库

### Host中的RePlugin的关键类
源码将分为宿主的host库和插件的plugin库分别分析,同时将会根据RePugin的插件服务进程与宿主进程区分来说明。在分析之前，我先对源码中几个重要的类先列出来，这里尽可能的少列出来。个人看法和大佬们的理解角度不一样，列出来的类或许不一样。

#### PmBase
作为整个RePlugin的核心类之一。控制了RePlugin的初始化。保存着从包中解析解析出来的占坑信息，类加载器，插件信息，以及其他核心类的实例。换句话说就是插件管理中心

#### Plugin
代表着RePlugin中插件在内存中的对象，这个类如同Small一样也会解析plugin-buildin.json生成对应的Plugin，同时也会解析外部插件的信息生成Plugin类

#### Loader
代表着RePlugin实际加载插件数据的执行器。

#### PmHostSvc
这个是指RePlugin插件管理器的进程总控制器。

#### PluginServiceServer
是指插件管理进程服务端的服务，只要是控制插件服务端的生命周期。

#### PluginManagerServer
是指插件管理进程服务端的插件管理中心，主要是通过它来完成跨进程插件操作。

#### PluginLibraryInternalProxy
是指插件的在宿主进程中实际的操作实现类。

#### PluginDexClassLoader
是用于插件寻找插件内类的类加载器

#### RePluginClassLoader
是用于宿主的类加载器。

接下来，我将围绕这几个类来对RePlugin的初始化和启动Activity展开讨论。

###RePlugin的启动
这里先给出两幅时序图以及进程初始化的图，第一幅是宿主的，第二幅是插件进程的。注意，这里的时序图只会根据关键信息给出主要流程。下面的源码分析，默认按照多进程框架进行分析。
###RePlugin的宿主进程（UI进程）的启动
![RePlugin的宿主进程的启动.png](/images/RePlugin的宿主进程的启动.png)

#### RePlugin的插件管理进程的启动
![RePlugin插件管理进程的启动.png](/images/RePlugin插件管理进程的启动.png)


标红的地方就是RePlugin宿主进程和插件管理进程的分割点。在RePlugin启动的时候，就区分出了所谓的UI进程和常驻进程。UI进程也就是我们的宿主主进程，而常驻进程是指插件管理器的进程。这里对启动做进一步的划分。

![RePlugin多进程初始化.png](/images/RePlugin多进程初始化.png)

通过两个进程初始化的比较，其实双方的相似度十分高，变化是从PmBase开始。那么两者之间的进程是怎么联系，UI进程是宿主可以默认启动，但是插件进程又是何时启动呢？接下来我将一一分析。提示，这里将不会对AIDL的原理进行分析，想要了解的，可以看看我csdn中对Binder的解析，或者网上也有很多优秀的文章。

实际上插件管理进程的初始化其中还有很多的细节。这里我就以Plugin为主要线索画出的建议流程图。实际上初始化的核心模块几乎都在PmBase中完成。所以我们其实可以先去PmBase中看看初始化的init的方法。

### UI进程的初始化
```
void init() {

        RePlugin.getConfig().getCallbacks().initPnPluginOverride();

        if (HostConfigHelper.PERSISTENT_ENABLE) {
            // （默认）“常驻进程”作为插件管理进程，则常驻进程作为Server，其余进程作为Client
            if (IPC.isPersistentProcess()) {
                // 初始化“Server”所做工作
                initForServer();
            } else {
                // 连接到Server
                initForClient();
            }
        } else {
            // “UI进程”作为插件管理进程（唯一进程），则UI进程既可以作为Server也可以作为Client
            ...
        }

        // 最新快照
        PluginTable.initPlugins(mPlugins);

        // 输出
        if (LOG) {
            for (Plugin p : mPlugins.values()) {
                LogDebug.d(PLUGIN_TAG, "plugin: p=" + p.mInfo);
            }
        }
    }
```

开始的时候默认HostConfigHelper.PERSISTENT_ENABLE为打开，允许使用插件进程来维护插件信息。刚开始我们通过Application的attachBaseContext进来的，也就是说此时一定是UI进程，那么一定会走下面的initForClient方法的分支。

从注释可以清楚，常驻进程为插件管理进程，其余的如插件和宿主统统都是客户端进程。

### initForClient
```
 /**
     * Client(UI进程)的初始化
     *
     */
    private final void initForClient() {
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "list plugins from persistent process");
        }

        // 1. 先尝试连接
        PluginProcessMain.connectToHostSvc();

        // 2. 然后从常驻进程获取插件列表
        refreshPluginsFromHostSvc();
    }
```

第一个方法是核心。当前作为UI进程会尝试的连接常驻进程。
```
/**
     * 非常驻进程调用，获取常驻进程的 IPluginHost
     */
    static final void connectToHostSvc() {
        Context context = PMF.getApplicationContext();

        //
        IBinder binder = PluginProviderStub.proxyFetchHostBinder(context);
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "host binder = " + binder);
        }
        if (binder == null) {
            // 无法连接到常驻进程，当前进程自杀
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "p.p fhb fail");
            }
            System.exit(1);
        }

        //
        try {
            binder.linkToDeath(new IBinder.DeathRecipient() {

                @Override
                public void binderDied() {
                    if (LOGR) {
                        LogRelease.i(PLUGIN_TAG, "p.p d, p.h s n");
                    }
                    // 检测到常驻进程退出，插件进程自杀
                    if (PluginManager.isPluginProcess()) {
                        if (LOGR) {
                            // persistent process exception, PLUGIN process quit now
                            LogRelease.i(MAIN_TAG, "p p e, pp q n");
                        }
                        System.exit(0);
                    }
                    sPluginHostRemote = null;

                    // 断开和插件化管理器服务端的连接，因为已经失效
                    PluginManagerProxy.disconnect();
                }
            }, 0);
        } catch (RemoteException e) {
            // 无法连接到常驻进程，当前进程自杀
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "p.p p.h l2a: " + e.getMessage(), e);
            }
            System.exit(1);
        }

        //
        sPluginHostRemote = IPluginHost.Stub.asInterface(binder);
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "host binder.i = " + PluginProcessMain.sPluginHostRemote);
        }

        // 连接到插件化管理器的服务端
        // Added by Jiongxuan Zhang
        try {
            PluginManagerProxy.connectToServer(sPluginHostRemote);

            // 将当前进程的"正在运行"列表和常驻做同步
            // TODO 若常驻进程重启，则应在启动时发送广播，各存活着的进程调用该方法来同步
            PluginManagerProxy.syncRunningPlugins();
        } catch (RemoteException e) {
            // 获取PluginManagerServer时出现问题，可能常驻进程突然挂掉等，当前进程自杀
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "p.p p.h l3a: " + e.getMessage(), e);
            }
            System.exit(1);
        }

        // 注册该进程信息到“插件管理进程”中
        PMF.sPluginMgr.attach();
    }
```
这个方法做两个事情，第一，尝试着通过ContentProvider来查找有没有连接插件进程的PmHostSvc这个插件进程的总控制器的aidl的IBinder。
```
/**
     * @param context
     * @param selection
     * @return
     */
    private static final IBinder proxyFetchHostBinder(Context context, String selection) {
        //
        Cursor cursor = null;
        try {
            Uri uri = ProcessPitProviderPersist.URI;
            cursor = context.getContentResolver().query(uri, PROJECTION_MAIN, selection, null, null);
            if (cursor == null) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "proxy fetch binder: cursor is null");
                }
                return null;
            }
            while (cursor.moveToNext()) {
                //
            }
            IBinder binder = BinderCursor.getBinder(cursor);
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "proxy fetch binder: binder=" + binder);
            }
            return binder;
        } finally {
            CloseableUtils.closeQuietly(cursor);
        }
    }
```


第二，尝试的连接着插件进程的服务,通过上面给予的IBinder，这个IBinder指代的是常驻进程的远程端的代理，换句话说就是通过调用常驻进程调用fetchManagerServer，获取常驻进程的插件服务。
```
/**
     * 连接到常驻进程，并缓存IPluginManagerServer对象
     *
     * @param host IPluginHost对象
     * @throws RemoteException 和常驻进程通讯出现异常
     */
    public static void connectToServer(IPluginHost host) throws RemoteException {
        if (sRemote != null) {
            if (LogDebug.LOG) {
                LogDebug.e(TAG, "connectToServer: Already connected! host=" + sRemote);
            }
            return;
        }

        sRemote = host.fetchManagerServer();
    }
```

是怎么连到插件进程的，这里先埋个伏笔。先假设我们都连接成功了。


#### refreshPluginsFromHostSvc
从PmHostSvc中刷新插件数据，PmHostSvc现在这里说明了，由于实现了IPluginHost.Stub，所以实际上就是常驻进程的总控制器。
```
private void refreshPluginsFromHostSvc() {
        List<PluginInfo> plugins = null;
        try {
            plugins = PluginProcessMain.getPluginHost().listPlugins();
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "lst.p: " + e.getMessage(), e);
            }
        }

        // 判断是否有需要更新的插件
        // FIXME 执行此操作前，判断下当前插件的运行进程，具体可以限制仅允许该插件运行在一个进程且为自身进程中
        List<PluginInfo> updatedPlugins = null;
        if (isNeedToUpdate(plugins)) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "plugins need to perform update operations");
            }
            try {
                updatedPlugins = PluginManagerProxy.updateAllPlugins();
            } catch (RemoteException e) {
                e.printStackTrace();
            }
        }

        if (updatedPlugins != null) {
            refreshPluginMap(updatedPlugins);
        } else {
            refreshPluginMap(plugins);
        }
    }
```
做了两件事情，先从PluginProcessMain获取常驻进程总控制器的远程代理。读取常驻进程中需要加载的插件信息列表。一旦发现我们有需要加载插件，则立即调用updateAllPlugins，来控制常驻进程的PluginManagerServer来加载安装进来的插件，最后再同步到UI进程的mPluginsList集合中。

#### PatchClassLoaderUtils.patch
接着也是RePlugin的核心之一，为宿主创造了宿主的ClassLoader，也是整个RePlugin体系唯一Hook的地方。
```
public static boolean patch(Application application) {
        try {
            // 获取Application的BaseContext （来自ContextWrapper）
            Context oBase = application.getBaseContext();
            ...

            // 获取mBase.mPackageInfo
            // 1. ApplicationContext - Android 2.1
            // 2. ContextImpl - Android 2.2 and higher
            // 3. AppContextImpl - Android 2.2 and higher
            Object oPackageInfo = ReflectUtils.readField(oBase, "mPackageInfo");
           ...
            // mPackageInfo的类型主要有两种：
            // 1. android.app.ActivityThread$PackageInfo - Android 2.1 - 2.3
            // 2. android.app.LoadedApk - Android 2.3.3 and higher
           ...
            // 获取mPackageInfo.mClassLoader
            ClassLoader oClassLoader = (ClassLoader) ReflectUtils.readField(oPackageInfo, "mClassLoader");
            if (oClassLoader == null) {
                if (LOGR) {
                    LogRelease.e(PLUGIN_TAG, "pclu.p: nf mpi. mb cl=" + oBase.getClass() + "; mpi cl=" + oPackageInfo.getClass());
                }
                return false;
            }

            // 外界可自定义ClassLoader的实现，但一定要基于RePluginClassLoader类
            ClassLoader cl = RePlugin.getConfig().getCallbacks().createClassLoader(oClassLoader.getParent(), oClassLoader);

            // 将新的ClassLoader写入mPackageInfo.mClassLoader
            ReflectUtils.writeField(oPackageInfo, "mClassLoader", cl);

            // 设置线程上下文中的ClassLoader为RePluginClassLoader
            // 防止在个别Java库用到了Thread.currentThread().getContextClassLoader()时，“用了原来的PathClassLoader”，或为空指针
            Thread.currentThread().setContextClassLoader(cl);

          
        } catch (Throwable e) {
            e.printStackTrace();
            return false;
        }
        return true;
    }
```
主要的想法是自己创造一个ClassLoader来替代掉Android系统中用来寻找类的类加载器。根据上面插件化基础框架中可以得知，所有的类查找都是通过获取LoadedAPk中的ClassLoader来查找类。那么这段话的意思就很简单了，就是替换掉系统的ClassLoader。让我们看看Applicaion中Context的mPackageInfo究竟是不是LoadedApk吧。Context的实现类是ContextImpl，我们直接看看里面是什么
```
final LoadedApk mPackageInfo;
```
确实思路是正确的，这里埋下第二个伏笔，将会在Activity的启动中让我们聊聊这个创建的RePluginClassLoader究竟在整个RePlugin起了什么作用。

#### callAttach
根据我们的时序图初始化接下来会走到callAttach这个方法，我们看看
```
final void callAttach() {
        //
        mClassLoader = PmBase.class.getClassLoader();

        // 挂载
        for (Plugin p : mPlugins.values()) {
            p.attach(mContext, mClassLoader, mLocal);
        }

        // 加载默认插件
        if (PluginManager.isPluginProcess()) {
            if (!TextUtils.isEmpty(mDefaultPluginName)) {
                //
                Plugin p = mPlugins.get(mDefaultPluginName);
                if (p != null) {
                    boolean rc = p.load(Plugin.LOAD_APP, true);
                    if (!rc) {
                        if (LOG) {
                            LogDebug.d(PLUGIN_TAG, "failed to load default plugin=" + mDefaultPluginName);
                        }
                    }
                    if (rc) {
                        mDefaultPlugin = p;
                        mClient.init(p);
                    }
                }
            }
        }
    }
```
下面部分是核心，如果是插件则会从Plugin中解析一次插件的信息，这里先不谈，到了常驻进程的时候会详细说说这个Plugin.load方法。

### onCreate
```
final void callAppCreate() {
        // 计算/获取cookie
        if (IPC.isPersistentProcess()) {
            mLocalCookie = PluginProcessMain.getPersistentCookie();
        } else {
...
        if (!IPC.isPersistentProcess()) {
            // 由于常驻进程已经在内部做了相关的处理，此处仅需要在UI进程注册并更新即可
            registerReceiverAction(ACTION_NEW_PLUGIN);
            registerReceiverAction(ACTION_UNINSTALL_PLUGIN);
        }
    }

```
这里则是注册了插件的安装和卸载的监听。

所以，先不论RePlugin的RePluginClassLoader究竟做了什么。实际上，如果启用了多进程框架的RePlugin的管理模式，其实插件的解析和加载都是在常驻进程中完成，而UI进程只是做一次插件信息的同步处理。

### RePlugin从UI进程启动常驻进程

还记得我上面的第一个伏笔吧。现在我们回到宿主在连接常驻进程的方法，proxyFetchHostBinder。
```
//selection
private static final String SELECTION_MAIN_BINDER = "main_binder";
private static final String PROJECTION_MAIN[] = {
        "main"
    };
    private static final String AUTHORITY_PREFIX = IPC.getPackageName() + ".loader.p.main";

//ProcessPitProviderPersist.URI
    public static final Uri URI = Uri.parse("content://" + AUTHORITY_PREFIX + "/main");

    private static final IBinder proxyFetchHostBinder(Context context, String selection) {
        //
        Cursor cursor = null;
        try {
            Uri uri = ProcessPitProviderPersist.URI;
            cursor = context.getContentResolver().query(uri, PROJECTION_MAIN, selection, null, null);
```
还记得ContentProvider的吧。这是内容提供器，因为开发中用的不多，我都几乎都忘记这个Android的四大组件之一的原理，但是用法还是记得的。

首先需要拿到和AndroidManifest中注册的权限和这里对应，找找看注册在注册文件中对应的内容提供器有什么猫腻。
```
  <provider android:name='com.qihoo360.replugin.component.process.ProcessPitProviderPersist' 
android:authorities='com.qihoo360.replugin.sample.host.loader.p.main'
 android:exported='false' 
android:process=':GuardService' />
```

你会发现这个用来注册在AndroidManifest的内容提供器，是位于GuardService进程的。从这里我们得知，我们在调用getContentResolver().query的方法，从这个GuardService进程中的内容提供器获取我们想要的IBinder。

这里我们可以进一步的猜测，整个常驻进程是不是就是指GuardService呢？

#### ContentProvider跨进程启动
这里我们就需要分析一下四大组件ContentProvider的源码了。
在整个App启动进程的时候，会从Zygote.cpp中fork一个新的进程出来，目标类是AppThread。换句话说就是，main方法为进程第一个运行的方法。
![ContentProvider安装与跨进程的启动.png](/images/ContentProvider安装与跨进程的启动.png)

如果不熟悉源码的可以根据我上面给的时序图读一遍源码。这里我稍微解释一下，每一次在进程启动的时候，都会绑定一次Application。加载ContentProvider的时期，这个时候会创建好Instrumentation,并且在makeApplication之后，Instrumentation的onCreate之前。换句话说就是在Application的attchBaseContext和onCreate之后。
```
            Application app = data.info.makeApplication(data.restrictedBackupMode, null);
            mInitialApplication = app;

            // don't bring up providers in restricted mode; they may depend on the
            // app's custom Application class
            if (!data.restrictedBackupMode) {
                if (!ArrayUtils.isEmpty(data.providers)) {
                    installContentProviders(app, data.providers);
                    // For process that contains content providers, we want to
                    // ensure that the JIT is enabled "at some point".
                    mH.sendEmptyMessageDelayed(H.ENABLE_JIT, 10*1000);
                }
            }

            // Do this after providers, since instrumentation tests generally start their
            // test thread at this point, and we don't want that racing.
            try {
                mInstrumentation.onCreate(data.instrumentationArgs);
            }
            catch (Exception e) {
                throw new RuntimeException(
                    "Exception thrown in onCreate() of "
                    + data.instrumentationName + ": " + e.toString(), e);
            }
```

这里多说一句也很重要，你自己往源码深处查看的时候，你会发现实际上这个加载的内容提供器，实际上会从PMS中解析的数据找出和当前进程名一致的内容提供器，而不一致的会被筛选掉。

我们可以看到PMS中这段源码
```
@Override
    public @NonNull ParceledListSlice<ProviderInfo> queryContentProviders(String processName,
            int uid, int flags) {
        final int userId = processName != null ? UserHandle.getUserId(uid)
                : UserHandle.getCallingUserId();
        if (!sUserManager.exists(userId)) return ParceledListSlice.emptyList();
        flags = updateFlagsForComponent(flags, userId, processName);

        ArrayList<ProviderInfo> finalList = null;
        // reader
        synchronized (mPackages) {
            final Iterator<PackageParser.Provider> i = mProviders.mProviders.values().iterator();
            while (i.hasNext()) {
                final PackageParser.Provider p = i.next();
                PackageSetting ps = mSettings.mPackages.get(p.owner.packageName);
                if (ps != null && p.info.authority != null
                        && (processName == null
                                || (p.info.processName.equals(processName)
                                        && UserHandle.isSameApp(p.info.applicationInfo.uid, uid)))
                        && mSettings.isEnabledAndMatchLPr(p.info, flags, userId)) {
                    if (finalList == null) {
                        finalList = new ArrayList<ProviderInfo>(3);
                    }
                    ProviderInfo info = PackageParser.generateProviderInfo(p, flags,
                            ps.readUserState(userId), userId);
                    if (info != null) {
                        finalList.add(info);
                    }
                }
            }
        }

        if (finalList != null) {
            Collections.sort(finalList, mProviderInitOrderSorter);
            return new ParceledListSlice<ProviderInfo>(finalList);
        }

        return ParceledListSlice.emptyList();
    }
```

结合源码解析出来的结果，以及RePlugin的源码。我们可以很清楚的明白，以下两点：

1. 实际上当我们第一次加载ContentProvider的时候是没有标记为GuardService进程的内容提供器。必须是通过我们ContentProvider.query的操作调起我们的常驻进程。
```
context.getContentResolver().query(uri, PROJECTION_MAIN, selection, null, null);
```
这段代码可说是UI进程初始化的核心。负担了两个角色，第一调起常驻进程，第二获取常驻进程的总控制器的远程代理。

2. 当我们重新拉起进程的时候，会重新走一边Application的初始化，也就是说会再走一次我们RePlugin的初始化代码，不同的是这一次是常驻进程，所以将会走到了不同的分支。

### RePlugin的常驻进程的启动
通过ContentProvider的源码的阅读，也就能够明白为什么顺序是上面的时序图样子。

还是一样我们直奔PmBase的initForServer
#### initForServer
```
private final void initForServer() {
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "search plugins from file system");
        }

        mHostSvc = new PmHostSvc(mContext, this);
        PluginProcessMain.installHost(mHostSvc);
        PluginProcessMain.schedulePluginProcessLoop(PluginProcessMain.CHECK_STAGE1_DELAY);

        // 兼容即将废弃的p-n方案 by Jiongxuan Zhang
        mAll = new Builder.PxAll();
        Builder.builder(mContext, mAll);
        refreshPluginMap(mAll.getPlugins());

        // [Newest!] 使用全新的RePlugin APK方案
        // Added by Jiongxuan Zhang
        try {
            List<PluginInfo> l = PluginManagerProxy.load();
            if (l != null) {
                // 将"纯APK"插件信息并入总的插件信息表中，方便查询
                // 这里有可能会覆盖之前在p-n中加入的信息。本来我们就想这么干，以"纯APK"插件为准
                refreshPluginMap(l);
            }
        } catch (RemoteException e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "lst.p: " + e.getMessage(), e);
            }
        }
    }
```

做了几件事情，这里分别实例化了PmHostSvc，这个服务端的总控制器，以及内部的PluginServiceServer和PluginManagerServer。

#### installHost
```
static final void installHost(IPluginHost host) {
        sPluginHostLocal = host;
        // 连接到插件化管理器的服务端
        // Added by Jiongxuan Zhang
        try {
            PluginManagerProxy.connectToServer(sPluginHostLocal);
        } catch (RemoteException e) {
            // 基本不太可能到这里，直接打出日志
            if (LOGR) {
                e.printStackTrace();
            }
        }
    }
```

```
    /**
     * 连接到常驻进程，并缓存IPluginManagerServer对象
     *
     * @param host IPluginHost对象
     * @throws RemoteException 和常驻进程通讯出现异常
     */
    public static void connectToServer(IPluginHost host) throws RemoteException {
        if (sRemote != null) {
            if (LogDebug.LOG) {
                LogDebug.e(TAG, "connectToServer: Already connected! host=" + sRemote);
            }
            return;
        }

        sRemote = host.fetchManagerServer();
    }
```

```
 @Override
    public IPluginManagerServer fetchManagerServer() throws RemoteException {
        return mManager.getService();
    }
```

这里很有意思，我们会再一次的尝试着通过PmHostSvc去获取IPluginManagerServer对象，但是实际上我们IPluginManagerServer这个对象现在指的是PluginManagerServer，已经在在PmHostSvc中实例化出来。
```
PmHostSvc(Context context, PmBase packm) {
        mContext = context;
        mPluginMgr = packm;
        mServiceMgr = new PluginServiceServer(context);
        mManager = new PluginManagerServer(context);
    }
```
虽然并不影响使用，但是按照我们多进程插件框架来说，这里的意思是在常驻进程中通过AIDL再一次的和常驻进程的服务端进行通信。相当于对着常驻进程再度切开两个接口PluginServiceServer和PluginManagerServer让外部进行跨进程通信。

这么做是为了在关闭常驻进程模式的时候，UI进程将会作为服务端和客服端，让其他插件的进程链接进来。

#### Builder.builder
```
static final void builder(Context context, PxAll all) {
        // 搜索所有本地插件和V5插件
        Finder.search(context, all);

        // 删除不适配的PLUGINs
        for (PluginInfo p : all.getOthers()) {
            // TODO 如果已存在built-in和V5则不删除
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "delete obsolote plugin=" + p);
            }
            boolean rc = p.deleteObsolote(context);
            if (!rc) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "can't delete obsolote plugin=" + p);
                }
            }
        }

        // 删除所有和PLUGINs不一致的DEX文件
        deleteUnknownDexs(context, all);

        // 删除所有和PLUGINs不一致的SO库目录
        // Added by Jiongxuan Zhang
        deleteUnknownLibs(context, all);

        // 构建数据
    }
```
这个方法中，我们着重看看Finder.search(context, all);扫描所有的插件数据并且转化为Plugin类
```
/**
     * 扫描插件
     */
    static final void search(Context context, PxAll all) {
        // 扫描内置插件
        FinderBuiltin.loadPlugins(context, all);

        // 扫描V5插件
        File pluginDir = context.getDir(Constant.LOCAL_PLUGIN_SUB_DIR, 0);
        V5Finder.search(context, pluginDir, all);

        // 扫描现有插件，包括刚才从V5插件文件更新过来的文件
        HashSet<File> deleted = new HashSet<File>();
        {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "search plugins: dir=" + pluginDir.getAbsolutePath());
            }
            searchLocalPlugins(pluginDir, all, deleted);
        }

        // 删除非插件文件和坏的文件
        for (File f : deleted) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "search: delete plugin dir invalid file=" + f.getAbsolutePath());
            }
            boolean rc = f.delete();
            if (!rc) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "search: can't delete plugin dir invalid file=" + f.getAbsolutePath());
                }
            }
        }
        deleted.clear();
    }
```

让我们先看看内置插件的逻辑
```
static final void loadPlugins(Context context, PxAll all) {
        InputStream in;

        // 读取内部配置
        in = null;
        try {
            in = context.getAssets().open("plugins-builtin.json");
            // TODO 简化参数 all
            readConfig(in, all);
        } catch (FileNotFoundException e0) {
            if (LOG) {
                LogDebug.e(PLUGIN_TAG, "plugins-builtin.json" + " not found");
            }
        } catch (Throwable e) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, e.getMessage(), e);
            }
        }
        CloseableUtils.closeQuietly(in);
    }

```
有点意思的地方是，这里实际上和Small的思路很像。也是通过读取Asset文件夹下面的plugins-builtin.json文件来获取插件信息。这个json文件并不需要我们自己编写实际上会通过host-gradle的gradle插件自己生成的。最后把数据保存到PxAll缓存中。

我的gradle插件这部分不太熟悉，但是好在gradle插件的语法简单，我们可以简单的明白这个json是通过读取插件中AndroidManifest里面的内容，生成的json文件
```
public PluginInfoParser(File pluginFile, def config) {

        pluginInfo = new PluginInfo()

        ApkFile apkFile = new ApkFile(pluginFile)

        String manifestXmlStr = apkFile.getManifestXml()
        ByteArrayInputStream inputStream = new ByteArrayInputStream(manifestXmlStr.getBytes("UTF-8"))

        SAXParserFactory factory = SAXParserFactory.newInstance()
        SAXParser parser = factory.newSAXParser()
        parser.parse(inputStream, this)

        String fullName = pluginFile.name
        pluginInfo.path = config.pluginDir + "/" + fullName

        String postfix = config.pluginFilePostfix
        pluginInfo.name = fullName.substring(0, fullName.length() - postfix.length())
    }
```
plugins-builtin.json里面的json是这样的。包含了插件的包名，路径名，版本以及其他信息。
```
{"high":null,"frm":null,"ver":104,"low":null,"pkg":"com.qihoo360.replugin.sample.demo1","path":"plugins/demo1.jar","name":"demo1"}
```
通过这些初步的生成了在Asset文件夹中内置的插件信息。和Small不同的，Small的build.json除了可以制定插件名还可以制定模块名以及相应的规则。

我们在看看所谓的V5插件也就是不存在Asset的外部插件，当然也有目录限制，就在“plugins_v3”这里，这里一般是指从外部下载进来的插件。
```
static final void search(Context context, File pluginDir, PxAll all) {
        // 扫描V5下载目录
        ArrayList<V5FileInfo> v5Plugins = new ArrayList<V5FileInfo>();
        {
            File dir = RePlugin.getConfig().getPnInstallDir();
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "search v5 files: dir=" + dir.getAbsolutePath());
            }
            searchV5Plugins(dir, v5Plugins);
        }

        // 同步V5原始插件文件到插件目录
        for (V5FileInfo p : v5Plugins) {

            ProcessLocker lock = new ProcessLocker(RePluginInternal.getAppContext(), p.mFile.getParent(), p.mFile.getName() + ".lock");

            /**
             * 此处逻辑的详细介绍请参照
             *
             * @see com.qihoo360.loader2.MP.pluginDownloaded(String path)
             */
            if (lock.isLocked()) {
                // 插件文件不可用，直接跳过
                continue;
            }

            PluginInfo info = p.updateV5FileTo(context, pluginDir, false, true);
            // 已检查版本
            if (info == null) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "search: fail to update v5 plugin");
                }
            } else {
                all.addV5(info);
            }
        }
    }
```

这里的思路会筛选出能够使用的下载哈见接着再更新到“plugins_v3”这个目录中，并且把数据保存到PxAll缓存中。这个下载路径我们可以通过RePlugin初始化配置下调配，这里就不多说了。

```
searchLocalPlugins(pluginDir, all, deleted);
```
这一句将会做一次对加载进来的信息，做一次筛选，找出是否版本号不一致需要更新的，是否有最新的需要更新等。

#### PluginManagerProxy.load();
我们再看看
```
PluginManagerProxy.load();
```
这个方法实际上调用的是PluginManagerServer远程端的load方法。我们看看load方法。
```
@Override
        public List<PluginInfo> load() throws RemoteException {
            synchronized (LOCKER) {
                return PluginManagerServer.this.loadLocked();
            }
        }

    private List<PluginInfo> loadLocked() {
        if (!mList.load(mContext)) {
            return null;
        }

        // 执行“更新或删除Pending”插件，并返回结果
        return updateAllLocked();
    }

public boolean load(Context context) {
         try {
            // 1. 新建或打开文件
            File d = context.getDir(Constant.LOCAL_PLUGIN_APK_SUB_DIR, 0);
            File f = new File(d, "p.l");
            if (!f.exists()) {
                // 不存在？直接创建一个新的即可
                if (!f.createNewFile()) {
                    if (LogDebug.LOG) {
                        LogDebug.e(TAG, "load: Create error!");
                    }
                    return false;
                } else {
                    if (LogDebug.LOG) {
                        LogDebug.i(TAG, "load: Create a new list file");
                    }
                    return true;
                }
            }

            // 2. 读出字符串
            String result = FileUtils.readFileToString(f, Charsets.UTF_8);
            if (TextUtils.isEmpty(result)) {
                if (LogDebug.LOG) {
                    LogDebug.e(TAG, "load: Read Json error!");
                }
                return false;
            }

            // 3. 解析出JSON
            mJson = new JSONArray(result);

        } catch (IOException e) {
            if (LogDebug.LOG) {
                LogDebug.e(TAG, "load: Load error!", e);
            }
            return false;
        } catch (JSONException e) {
            if (LogDebug.LOG) {
                LogDebug.e(TAG, "load: Parse Json Error!", e);
            }
            return false;
        }

        for (int i = 0; i < mJson.length(); i++) {
            JSONObject jo = mJson.optJSONObject(i);
            if (jo != null) {
                PluginInfo pi = PluginInfo.createByJO(jo);
                if (pi == null) {
                    if (LogDebug.LOG) {
                        LogDebug.e(TAG, "load: PluginInfo Invalid. Ignore! jo=" + jo);
                    }
                    continue;
                }
                addToMap(pi);
            }
        }
        return true;
    }
```
这里是指RePlugin将会检测通过install进来的安装进来的apk插件的安装信息，读取其中的json数据，再更新插件列表信息，同时生成PluginInfo这个外部插件的信息，并且更新到之前的json数据文件中。

通过这种方式，RePlugin控制了宿主内的插件，下载的V5插件以及安装进来的apk插件。

#### refreshPluginMap
```
/**
     * 更新所有的插件信息
     *
     * @param plugins
     */
    private final void refreshPluginMap(List<PluginInfo> plugins) {
        if (plugins == null) {
            return;
        }
        for (PluginInfo info : plugins) {
            Plugin plugin = Plugin.build(info);
            putPluginObject(info, plugin);
        }
    }

    /**
     * 把插件Add到插件列表
     *
     * @param info   待add插件的PluginInfo对象
     * @param plugin 待add插件的Plugin对象
     */
    private void putPluginObject(PluginInfo info, Plugin plugin) {
        if (mPlugins.containsKey(info.getAlias()) || mPlugins.containsKey(info.getPackageName())) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "当前内置插件列表中已经有" + info.getName() + "，需要看看谁的版本号大。");
            }

            // 找到已经存在的
            Plugin existedPlugin = mPlugins.get(info.getPackageName());
            if (existedPlugin == null) {
                existedPlugin = mPlugins.get(info.getAlias());
            }

            if (existedPlugin.mInfo.getVersion() < info.getVersion()) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "新传入的纯APK插件, name=" + info.getName() + ", 版本号比较大,ver=" + info.getVersion() + ",以TA为准。");
                }

                // 同时加入PackageName和Alias（如有）
                mPlugins.put(info.getPackageName(), plugin);
                if (!TextUtils.isEmpty(info.getAlias())) {
                    // 即便Alias和包名相同也可以再Put一次，反正只是覆盖了相同Value而已
                    mPlugins.put(info.getAlias(), plugin);
                }
            } else {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "新传入的纯APK插件" + info.getName() + "版本号还没有内置的大，什么都不做。");
                }
            }
        } else {
            // 同时加入PackageName和Alias（如有）
            mPlugins.put(info.getPackageName(), plugin);
            if (!TextUtils.isEmpty(info.getAlias())) {
                // 即便Alias和包名相同也可以再Put一次，反正只是覆盖了相同Value而已
                mPlugins.put(info.getAlias(), plugin);
            }
        }
    }
```
此时，无论是UI还是常驻进程将会通过refreshPluginMap通过PluginManagerServer生成的消息把安装的apk插件同步到内存中。


### callAttach
由于不是插件进程，所以并没有在意的地方。时序图后面的将会在Activity启动拿出来详细。


总结：初始化，实际上做的工作主要有两点：
第一，连接常驻进程，并且初始化相关的工作，如ClassLoader的替换等
第二，通过常驻进程解析插件信息，并且同步到UI进程。


### RePlugin启动Activity原理
终于来到重头戏了。RePlugin究竟是怎么样启动插件进程，或者说插件启动第二个进程的Activity。让我们先看看RePlugin是如何启动Activity的。
打开方式有两种，第一种直接用包名打开，第二种用别名打开。
```
RePlugin.startActivity(MainActivity.this, RePlugin.createIntent("com.qihoo360.replugin.sample.demo1", "com.qihoo360.replugin.sample.demo1.MainActivity"));


Intent intent = new Intent();
intent.setComponent(new ComponentName("demo1", "com.qihoo360.replugin.sample.demo1.activity.for_result.ForResultActivity"));
RePlugin.startActivityForResult(MainActivity.this, intent, REQUEST_CODE_DEMO1, null);
```

了解怎么打开。我们这里需要进一步的探究了。
这里先上时序图，这里的时序图稍微有点长，有兴趣的可以跟着我的时序图看看源码。不看也没关系，我这里会挑出重点逐个分析。
![RePlugin宿主启动Activity部分.png](/images/RePlugin宿主启动Activity部分.png)

根据这个时序图，我们直接看看PluginLibraryInternalProxy中的启动方法。这里只挑出核心方法
### startActivity
```
public boolean startActivity(Context context, Intent intent, String plugin, String activity, int process, boolean download) {
        ..
...
        // 如果插件状态出现问题，则每次弹此插件的Activity都应提示无法使用，或提示升级（如有新版）
        // Added by Jiongxuan Zhang
        if (PluginStatusController.getStatus(plugin) < PluginStatusController.STATUS_OK) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "PluginLibraryInternalProxy.startActivity(): Plugin Disabled. pn=" + plugin);
            }
            return RePlugin.getConfig().getCallbacks().onPluginNotExistsForActivity(context, plugin, intent, process);
        }

        // 若为首次加载插件，且是“大插件”，则应异步加载，同时弹窗提示“加载中”
        // Added by Jiongxuan Zhang
        if (!RePlugin.isPluginDexExtracted(plugin)) {
            PluginDesc pd = PluginDesc.get(plugin);
            if (pd != null && pd.isLarge()) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "PM.startActivity(): Large Plugin! p=" + plugin);
                }
                return RePlugin.getConfig().getCallbacks().onLoadLargePluginForActivity(context, plugin, intent, process);
            }
        }

        // WARNING：千万不要修改intent内容，尤其不要修改其ComponentName
        // 因为一旦分配坑位有误（或压根不是插件Activity），则外界还需要原封不动的startActivity到系统中
        // 可防止出现“本来要打开宿主，结果被改成插件”，进而无法打开宿主Activity的问题

        // 缓存打开前的Intent对象，里面将包括Action等内容
        Intent from = new Intent(intent);

        // 帮助填写打开前的Intent的ComponentName信息（如有。没有的情况如直接通过Action打开等）
        if (!TextUtils.isEmpty(plugin) && !TextUtils.isEmpty(activity)) {
            from.setComponent(new ComponentName(plugin, activity));
        }

        ComponentName cn = mPluginMgr.mLocal.loadPluginActivity(intent, plugin, activity, process);
        if (cn == null) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "plugin cn not found: intent=" + intent + " plugin=" + plugin + " activity=" + activity + " process=" + process);
            }
            return false;
        }

        // 将Intent指向到“坑位”。这样：
        // from：插件原Intent
        // to：坑位Intent
        intent.setComponent(cn);

        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "start activity: real intent=" + intent);
        }
        context.startActivity(intent);

        // 通知外界，已准备好要打开Activity了
        // 其中：from为要打开的插件的Intent，to为坑位Intent
        RePlugin.getConfig().getEventCallbacks().onPrepareStartPitActivity(context, from, intent);

        return true;
    }
```

省略了版本不一致提供下载回调等。这里做的事情有两件。
第一：还记得我之前构建的基础插件化模型吗？这里实际上是把我们的目标Intent通过RePlugin的占坑（代理）的Activity给包装起来，用于骗过Android系统。

第二，此时开始加载插件中信息的内容，并且拿到要启动对应的类的ComponentName。整个核心的部分在这里：
```
ComponentName cn = mPluginMgr.mLocal.loadPluginActivity(intent, plugin, activity, process);
        if (cn == null) {
```

### loadPluginActivity
```
public ComponentName loadPluginActivity(Intent intent, String plugin, String activity, int process) {

        ActivityInfo ai = null;
        String container = null;
        PluginBinderInfo info = new PluginBinderInfo(PluginBinderInfo.ACTIVITY_REQUEST);

        try {
            // 获取 ActivityInfo(可能是其它插件的 Activity，所以这里使用 pair 将 pluginName 也返回)
            ai = getActivityInfo(plugin, activity, intent);
            if (ai == null) {
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "PACM: bindActivity: activity not found");
                }
                return null;
            }

            // 存储此 Activity 在插件 Manifest 中声明主题到 Intent
            intent.putExtra(INTENT_KEY_THEME_ID, ai.theme);
            if (LOG) {
                LogDebug.d("theme", String.format("intent.putExtra(%s, %s);", ai.name, ai.theme));
            }

            // 根据 activity 的 processName，选择进程 ID 标识
            if (ai.processName != null) {
                process = PluginClientHelper.getProcessInt(ai.processName);
            }

            // 容器选择（启动目标进程）
            IPluginClient client = MP.startPluginProcess(plugin, process, info);
            if (client == null) {
                return null;
            }

            // 远程分配坑位
            container = client.allocActivityContainer(plugin, process, ai.name, intent);
            if (LOG) {
                LogDebug.i(PLUGIN_TAG, "alloc success: container=" + container + " plugin=" + plugin + " activity=" + activity);
            }
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "l.p.a spp|aac: " + e.getMessage(), e);
            }
        }

        // 分配失败
        if (TextUtils.isEmpty(container)) {
            return null;
        }

        PmBase.cleanIntentPluginParams(intent);

        // TODO 是否重复
        // 附上额外数据，进行校验
//        intent.putExtra(PluginManager.EXTRA_PLUGIN, plugin);
//        intent.putExtra(PluginManager.EXTRA_ACTIVITY, activity);
//        intent.putExtra(PluginManager.EXTRA_PROCESS, process);
//        intent.putExtra(PluginManager.EXTRA_CONTAINER, container);

        PluginIntent ii = new PluginIntent(intent);
        ii.setPlugin(plugin);
        ii.setActivity(ai.name);
        ii.setProcess(IPluginManager.PROCESS_AUTO);
        ii.setContainer(container);
        ii.setCounter(0);
        return new ComponentName(IPC.getPackageName(), container);
    }
```
这里主要做了三件事情。
第一件：getActivityInfo。读取插件中的数据，并且获取插件中要查找的Activity的ActivityInfo。

第二件：startPluginProcess。由于RePlugin有代理Activity有自己的进程，会查看你的Activity中是不是在其他的进程启动，并且分配进程给Activity。

第三件，组成ComponentName返回回去。

这里我们们先看看getActivityInfo的方法。
 ### PluginCommImpl.getActivityInfo
```
public ActivityInfo getActivityInfo(String plugin, String activity, Intent intent) {
        // 获取插件对象
        Plugin p = mPluginMgr.loadAppPlugin(plugin);
        if (p == null) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "PACM: bindActivity: may be invalid plugin name or load plugin failed: plugin=" + p);
            }
            return null;
        }

        ActivityInfo ai = null;

        // activity 不为空时，从插件声明的 Activity 集合中查找
        if (!TextUtils.isEmpty(activity)) {
            ai = p.mLoader.mComponents.getActivity(activity);
        } else {
            // activity 为空时，根据 Intent 匹配
            ai = IntentMatcherHelper.getActivityInfo(mContext, plugin, intent);
        }
        return ai;
    }
```
这里先通过loadAppPlugin加载插件数据，接着在从数据中获取ActivityInfo。这里loadAppPlugin会调用PmBase的loadPlugin
```
final Plugin loadPlugin(Plugin p, int loadType, boolean useCache) {
        if (p == null) {
            return null;
        }
        if (!p.load(loadType, useCache)) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "pmb.lp: f to l. lt=" + loadType + "; i=" + p.mInfo);
            }
            return null;
        }
        return p;
    }
```
实际上，这个load的方法就是RePlugin的加载插件数据的核心。RePlugin加载插件数据都会调用这个方法。


### Plugin.load
```
final boolean load(int load, boolean useCache) {
        PluginInfo info = mInfo;
        boolean rc = loadLocked(load, useCache);
        // 尝试在此处调用Application.onCreate方法
        // Added by Jiongxuan Zhang
        if (load == LOAD_APP && rc) {
            callApp();
        }
        // 如果info改了，通知一下常驻
        // 只针对P-n的Type转化来处理，一定要通知，这样Framework_Version也会得到更新
        if (rc && mInfo != info) {
            UpdateInfoTask task = new UpdateInfoTask((PluginInfo) mInfo.clone());
            Tasks.post2Thread(task);
        }
        return rc;
    }
```
loadLocked加载数据。创建PluginApplicationClient实例。并且异步拷贝插件数据同步到常驻进程中。

### loadLocked
```
private boolean loadLocked(int load, boolean useCache) {
        // 若插件被“禁用”，则即便上次加载过（且进程一直活着），这次也不能再次使用了
        // Added by Jiongxuan Zhang
        int status = PluginStatusController.getStatus(mInfo.getName(), mInfo.getVersion());
        if (status < PluginStatusController.STATUS_OK) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "loadLocked(): Disable in=" + mInfo.getName() + ":" + mInfo.getVersion() + "; st=" + status);
            }
            return false;
        }
        if (mInitialized) {
            if (mLoader == null) {
                if (LOG) {
                    LogDebug.i(MAIN_TAG, "loadLocked(): Initialized but mLoader is Null");
                }
                return false;
            }
            if (load == LOAD_INFO) {
                boolean rl = mLoader.isPackageInfoLoaded();
                if (LOG) {
                    LogDebug.i(MAIN_TAG, "loadLocked(): Initialized, pkginfo loaded = " + rl);
                }
                return rl;
            }
            if (load == LOAD_RESOURCES) {
                boolean rl = mLoader.isResourcesLoaded();
                if (LOG) {
                    LogDebug.i(MAIN_TAG, "loadLocked(): Initialized, resource loaded = " + rl);
                }
                return rl;
            }
            if (load == LOAD_DEX) {
                boolean rl = mLoader.isDexLoaded();
                if (LOG) {
                    LogDebug.i(MAIN_TAG, "loadLocked(): Initialized, dex loaded = " + rl);
                }
                return rl;
            }
            boolean il = mLoader.isAppLoaded();
            if (LOG) {
                LogDebug.i(MAIN_TAG, "loadLocked(): Initialized, is loaded = " + il);
            }
            return il;
        }
        mInitialized = true;

        // 若开启了“打印详情”则打印调用栈，便于观察
        if (RePlugin.getConfig().isPrintDetailLog()) {
            String reason = "";
            reason += "--- plugin: " + mInfo.getName() + " ---\n";
            reason += "load=" + load + "\n";
            StackTraceElement elements[] = Thread.currentThread().getStackTrace();
            for (StackTraceElement item : elements) {
                if (item.isNativeMethod()) {
                    continue;
                }
                String cn = item.getClassName();
                String mn = item.getMethodName();
                String filename = item.getFileName();
                int line = item.getLineNumber();
                if (LOG) {
                    LogDebug.i(PLUGIN_TAG, cn + "." + mn + "(" + filename + ":" + line + ")");
                }
                reason += cn + "." + mn + "(" + filename + ":" + line + ")" + "\n";
            }
            if (sLoadedReasons == null) {
                sLoadedReasons = new ArrayList<String>();
            }
            sLoadedReasons.add(reason);
        }

        // 这里先处理一下，如果cache命中，省了后面插件提取（如释放Jar包等）操作
        if (useCache) {
            boolean result = loadByCache(load);
            // 如果缓存命中，则直接返回
            if (result) {
                return true;
            }
        }

        Context context = mContext;
        ClassLoader parent = mParent;
        PluginCommImpl manager = mPluginManager;

        //
        String logTag = "try1";
        String lockFileName = String.format(Constant.LOAD_PLUGIN_LOCK, mInfo.getApkFile().getName());
        ProcessLocker lock = new ProcessLocker(context, lockFileName);
        if (LOG) {
            LogDebug.i(PLUGIN_TAG, "loadLocked(): Ready to lock! logtag = " + logTag + "; pn = " + mInfo.getName());
        }
        if (!lock.tryLockTimeWait(5000, 10)) {
            // 此处仅仅打印错误
            if (LOGR) {
                LogRelease.w(PLUGIN_TAG, logTag + ": failed to lock: can't wait plugin ready");
            }
        }
        //
        long t1 = System.currentTimeMillis();
        boolean rc = doLoad(logTag, context, parent, manager, load);
        if (LOG) {
            LogDebug.i(PLUGIN_TAG, "load " + mInfo.getPath() + " " + hashCode() + " c=" + load + " rc=" + rc + " delta=" + (System.currentTimeMillis() - t1));
        }
        //
        lock.unlock();
        if (LOG) {
            LogDebug.i(PLUGIN_TAG, "loadLocked(): Unlock! logtag = " + logTag + "; pn = " + mInfo.getName());
        }
        if (!rc) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, logTag + ": loading fail1");
            }
        }
        if (rc) {
            // 打印当前内存占用情况，只针对Dex和App加载做输出
            // 只有开启“详细日志”才会输出，防止“消耗性能”
            if (LOG && RePlugin.getConfig().isPrintDetailLog()) {
                if (load == LOAD_DEX || load == LOAD_APP) {
                    LogDebug.printPluginInfo(mInfo, load);
                    LogDebug.printMemoryStatus(LogDebug.TAG, "act=, loadLocked, flag=, End-1, pn=, " + mInfo.getName() + ", type=, " + load);
                }
            }
            try {
                // 至此，该插件已开始运行
                PluginManagerProxy.addToRunningPluginsNoThrows(mInfo.getName());
            } catch (Throwable e) {
                if (LOGR) {
                    LogRelease.e(PLUGIN_TAG, "p.u.1: " + e.getMessage(), e);
                }
            }

            return true;
        }

        //
        logTag = "try2";
       ...

        try {
            // 至此，该插件已开始运行
            PluginManagerProxy.addToRunningPluginsNoThrows(mInfo.getName());
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "p.u.2: " + e.getMessage(), e);
            }
        }

        return true;
    }
```

由于这里是加载插件，所以load的标志为LOAD_APP。这里做的事情，先是获取UI进程中有没有缓存，没有则加上一个进程锁，去跨进程的加载数据。提一句，进程锁的实现是通过文件锁完成的。实际上这个时候加载失败了还会解锁一次，再加载一次。最后加载成果，会进入到插件运行列表并且记录下来。

让我们看看doload这个核心方法。
```
private final boolean doLoad(String tag, Context context, ClassLoader parent, PluginCommImpl manager, int load) {
        if (mLoader == null) {
            // 试图释放文件
            PluginInfo info = null;
            if (mInfo.getType() == PluginInfo.TYPE_BUILTIN) {
                //
                File dir = context.getDir(Constant.LOCAL_PLUGIN_SUB_DIR, 0);
                File dexdir = mInfo.getDexParentDir();
                String dstName = mInfo.getApkFile().getName();
                boolean rc = AssetsUtils.quickExtractTo(context, mInfo, dir.getAbsolutePath(), dstName, dexdir.getAbsolutePath());
                if (!rc) {
                    // extract built-in plugin failed: plugin=
                    if (LOGR) {
                        LogRelease.e(PLUGIN_TAG, "p e b i p f " + mInfo);
                    }
                    return false;
                }
                File file = new File(dir, dstName);
                info = (PluginInfo) mInfo.clone();
                info.setPath(file.getPath());

                // FIXME 不应该是P-N，即便目录相同，未来会优化这里
                info.setType(PluginInfo.TYPE_PN_INSTALLED);

            } else if (mInfo.getType() == PluginInfo.TYPE_PN_JAR) {
                //
                V5FileInfo v5i = V5FileInfo.build(new File(mInfo.getPath()), mInfo.getV5Type());
                if (v5i == null) {
                    // build v5 plugin info failed: plugin=
                    if (LOGR) {
                        LogRelease.e(PLUGIN_TAG, "p e b v i f " + mInfo);
                    }
                    return false;
                }
                File dir = context.getDir(Constant.LOCAL_PLUGIN_SUB_DIR, 0);
                info = v5i.updateV5FileTo(context, dir, true, true);
                if (info == null) {
                    // update v5 file to failed: plugin=
                    if (LOGR) {
                        LogRelease.e(PLUGIN_TAG, "p u v f t f " + mInfo);
                    }
                    return false;
                }
                // 检查是否改变了？
                if (info.getLowInterfaceApi() != mInfo.getLowInterfaceApi() || info.getHighInterfaceApi() != mInfo.getHighInterfaceApi()) {
                    if (LOG) {
                        LogDebug.d(PLUGIN_TAG, "v5 plugin has changed: plugin=" + info + ", original=" + mInfo);
                    }
                    // 看看目标文件是否存在
                    String dstName = mInfo.getApkFile().getName();
                    File file = new File(dir, dstName);
                    if (!file.exists()) {
                        if (LOGR) {
                            LogRelease.e(PLUGIN_TAG, "can't load: v5 plugin has changed to "
                                    + info.getLowInterfaceApi() + "-" + info.getHighInterfaceApi()
                                    + ", orig " + mInfo.getLowInterfaceApi() + "-" + mInfo.getHighInterfaceApi()
                                    + " bare not exist");
                        }
                        return false;
                    }
                    // 重新构造
                    info = PluginInfo.build(file);
                    if (info == null) {
                        return false;
                    }
                }

            } else {
                //
            }

            //
            if (info != null) {
                // 替换
                mInfo = info;
            }

            //
            mLoader = new Loader(context, mInfo.getName(), mInfo.getPath(), this);
            if (!mLoader.loadDex(parent, load)) {
                return false;
            }

            // 设置插件为“使用过的”
            // 注意，需要重新获取当前的PluginInfo对象，而非使用“可能是新插件”的mInfo
            try {
                PluginManagerProxy.updateUsedIfNeeded(mInfo.getName(), true);
            } catch (RemoteException e) {
                // 同步出现问题，但仍继续进行
                if (LOGR) {
                    e.printStackTrace();
                }
            }

            // 若需要加载Dex，则还同时需要初始化插件里的Entry对象
            if (load == LOAD_APP) {
                // NOTE Entry对象是可以在任何线程中被调用到
                if (!loadEntryLocked(manager)) {
                    return false;
                }
                // NOTE 在此处调用则必须Post到UI，但此时有可能Activity已被加载
                //      会出现Activity.onCreate比Application更早的情况，故应放在load外面立即调用
                // callApp();
            }
        }

        if (load == LOAD_INFO) {
            return mLoader.isPackageInfoLoaded();
        } else if (load == LOAD_RESOURCES) {
            return mLoader.isResourcesLoaded();
        } else if (load == LOAD_DEX) {
            return mLoader.isDexLoaded();
        } else {
            return mLoader.isAppLoaded();
        }
    }
```
RePlugin先判断Loader也就是Plugin的加载器是否为空。第一次进来先是为空。这里会判断当前的记载的插件是什么。是内部插件还是jar包？是这两种则获取内部信息更新插件信息。核心不是这里，这个方法的核心有两个。

第一：loadDex加载插件中dex的数据，为插件生成对应的类加载器，Context等。

第二：启动插件内部插件框架。

我们一个个来看对应的方法。

### Loader.loadDex
```
final boolean loadDex(ClassLoader parent, int load) {
        try {
            PackageManager pm = mContext.getPackageManager();

            mPackageInfo = Plugin.queryCachedPackageInfo(mPath);
            if (mPackageInfo == null) {
                // PackageInfo
                mPackageInfo = pm.getPackageArchiveInfo(mPath,
                        PackageManager.GET_ACTIVITIES | PackageManager.GET_SERVICES | PackageManager.GET_PROVIDERS | PackageManager.GET_RECEIVERS | PackageManager.GET_META_DATA);
                if (mPackageInfo == null || mPackageInfo.applicationInfo == null) {
                    if (LOG) {
                        LogDebug.d(PLUGIN_TAG, "get package archive info null");
                    }
                    mPackageInfo = null;
                    return false;
                }
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "get package archive info, pi=" + mPackageInfo);
                }
                mPackageInfo.applicationInfo.sourceDir = mPath;
                mPackageInfo.applicationInfo.publicSourceDir = mPath;

                if (TextUtils.isEmpty(mPackageInfo.applicationInfo.processName)) {
                    mPackageInfo.applicationInfo.processName = mPackageInfo.applicationInfo.packageName;
                }

                // 添加针对SO库的加载
                // 此属性最终用于ApplicationLoaders.getClassLoader，在创建PathClassLoader时成为其参数
                // 这样findLibrary可不用覆写，即可直接实现SO的加载
                // Added by Jiongxuan Zhang
                PluginInfo pi = mPluginObj.mInfo;
                File ld = pi.getNativeLibsDir();
                mPackageInfo.applicationInfo.nativeLibraryDir = ld.getAbsolutePath();

//                // 若PluginInfo.getFrameworkVersion为FRAMEWORK_VERSION_UNKNOWN（p-n才会有），则这里需要读取并修改
//                if (pi.getFrameworkVersion() == PluginInfo.FRAMEWORK_VERSION_UNKNOWN) {
//                    pi.setFrameworkVersionByMeta(mPackageInfo.applicationInfo.metaData);
//                }

                // 缓存表: pkgName -> pluginName
                synchronized (Plugin.PKG_NAME_2_PLUGIN_NAME) {
                    Plugin.PKG_NAME_2_PLUGIN_NAME.put(mPackageInfo.packageName, mPluginName);
                }

                // 缓存表: pluginName -> fileName
                synchronized (Plugin.PLUGIN_NAME_2_FILENAME) {
                    Plugin.PLUGIN_NAME_2_FILENAME.put(mPluginName, mPath);
                }

                // 缓存表: fileName -> PackageInfo
                synchronized (Plugin.FILENAME_2_PACKAGE_INFO) {
                    Plugin.FILENAME_2_PACKAGE_INFO.put(mPath, new WeakReference<PackageInfo>(mPackageInfo));
                }
            }

            // TODO preload预加载虽然通知到常驻了(但pluginInfo是通过MP.getPlugin(name, true)完全clone出来的)，本进程的PluginInfo并没有得到更新
            // TODO 因此preload会造成某些插件真正生效时由于cache，造成插件版本号2.0或者以上无法生效。
            // TODO 这里是临时做法，避免发版前出现重大问题，后面可以修过修改preload的流程来优化
            // 若PluginInfo.getFrameworkVersion为FRAMEWORK_VERSION_UNKNOWN（p-n才会有），则这里需要读取并修改
            if (mPluginObj.mInfo.getFrameworkVersion() == PluginInfo.FRAMEWORK_VERSION_UNKNOWN) {
                mPluginObj.mInfo.setFrameworkVersionByMeta(mPackageInfo.applicationInfo.metaData);
                // 只有“P-n”插件才会到这里，故无需调用“纯APK”的保存功能
                // PluginInfoList.save();
            }

            // 创建或获取ComponentList表
            // Added by Jiongxuan Zhang
            mComponents = Plugin.queryCachedComponentList(mPath);
            if (mComponents == null) {
                // ComponentList
                mComponents = new ComponentList(mPackageInfo, mPath, mPluginObj.mInfo);

                // 动态注册插件中声明的 receiver
                regReceivers();

                // 缓存表：ComponentList
                synchronized (Plugin.FILENAME_2_COMPONENT_LIST) {
                    Plugin.FILENAME_2_COMPONENT_LIST.put(mPath, new WeakReference<>(mComponents));
                }

                /* 只调整一次 */
                // 调整插件中组件的进程名称
                adjustPluginProcess(mPackageInfo.applicationInfo);

                // 调整插件中 Activity 的 TaskAffinity
                adjustPluginTaskAffinity(mPluginName, mPackageInfo.applicationInfo);
            }

            if (load == Plugin.LOAD_INFO) {
                return isPackageInfoLoaded();
            }

            mPkgResources = Plugin.queryCachedResources(mPath);
            // LOAD_RESOURCES和LOAD_ALL都会获取资源，但LOAD_INFO不可以（只允许获取PackageInfo）
            if (mPkgResources == null) {
                // Resources
                try {
                    if (BuildConfig.DEBUG) {
                        // 如果是Debug模式的话，防止与Instant Run冲突，资源重新New一个
                        Resources r = pm.getResourcesForApplication(mPackageInfo.applicationInfo);
                        mPkgResources = new Resources(r.getAssets(), r.getDisplayMetrics(), r.getConfiguration());
                    } else {
                        mPkgResources = pm.getResourcesForApplication(mPackageInfo.applicationInfo);
                    }
                } catch (NameNotFoundException e) {
                    if (LOG) {
                        LogDebug.d(PLUGIN_TAG, e.getMessage(), e);
                    }
                    return false;
                }
                if (mPkgResources == null) {
                    if (LOG) {
                        LogDebug.d(PLUGIN_TAG, "get resources null");
                    }
                    return false;
                }
                if (LOG) {
                    LogDebug.d(PLUGIN_TAG, "get resources for app, r=" + mPkgResources);
                }

                // 缓存表: Resources
                synchronized (Plugin.FILENAME_2_RESOURCES) {
                    Plugin.FILENAME_2_RESOURCES.put(mPath, new WeakReference<>(mPkgResources));
                }
            }
            if (load == Plugin.LOAD_RESOURCES) {
                return isResourcesLoaded();
            }

            mClassLoader = Plugin.queryCachedClassLoader(mPath);
            if (mClassLoader == null) {
                // ClassLoader
                String out = mPluginObj.mInfo.getDexParentDir().getPath();
                //changeDexMode(out);

                //
                Log.i("dex", "load " + mPath + " ...");
                if (BuildConfig.DEBUG) {
                    // 因为Instant Run会替换parent为IncrementalClassLoader，所以在DEBUG环境里
                    // 需要替换为BootClassLoader才行
                    // Added by yangchao-xy & Jiongxuan Zhang
                    parent = ClassLoader.getSystemClassLoader();
                } else {
                    // 线上环境保持不变
                    parent = getClass().getClassLoader().getParent(); // TODO: 这里直接用父类加载器
                }
                String soDir = mPackageInfo.applicationInfo.nativeLibraryDir;

                long begin = 0;
                boolean isDexExist = false;

                if (LOG) {
                    begin = System.currentTimeMillis();
                    File dexFile = mPluginObj.mInfo.getDexFile();
                    if (dexFile.exists() && dexFile.length() > 0) {
                        isDexExist = true;
                    }
                }

                mClassLoader = RePlugin.getConfig().getCallbacks().createPluginClassLoader(mPluginObj.mInfo, mPath, out, soDir, parent);
                Log.i("dex", "load " + mPath + " = " + mClassLoader);

                if (mClassLoader == null) {
                    if (LOG) {
                        LogDebug.d(PLUGIN_TAG, "get dex null");
                    }
                    return false;
                }

                if (LOG) {
                    if (!isDexExist) {
                        Log.d(LOADER_TAG, " --释放DEX, " + "(plugin=" + mPluginName + ", version=" + mPluginObj.mInfo.getVersion() + ")"
                                + ", use:" + (System.currentTimeMillis() - begin)
                                + ", process:" + IPC.getCurrentProcessName());
                    } else {
                        Log.d(LOADER_TAG, " --无需释放DEX, " + "(plugin=" + mPluginName + ", version=" + mPluginObj.mInfo.getVersion() + ")"
                                + ", use:" + (System.currentTimeMillis() - begin)
                                + ", process:" + IPC.getCurrentProcessName());
                    }
                }

                // 缓存表：ClassLoader
                synchronized (Plugin.FILENAME_2_DEX) {
                    Plugin.FILENAME_2_DEX.put(mPath, new WeakReference<>(mClassLoader));
                }
            }
            if (load == Plugin.LOAD_DEX) {
                return isDexLoaded();
            }

            // Context
            mPkgContext = new PluginContext(mContext, android.R.style.Theme, mClassLoader, mPkgResources, mPluginName, this);
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "pkg context=" + mPkgContext);
            }

        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "p=" + mPath + " m=" + e.getMessage(), e);
            }
            return false;
        }

        return true;
    }
```
这里有一段方法我们必须注意：
```
 mPackageInfo = pm.getPackageArchiveInfo(mPath,
                        PackageManager.GET_ACTIVITIES | PackageManager.GET_SERVICES | PackageManager.GET_PROVIDERS | PackageManager.GET_RECEIVERS | PackageManager.GET_META_DATA);
```
如果写过插件换肤框架都知道。这个方法是能够获取对应路径下apk文件的内部信息。根据后面的标志，会取出对应数据填入PackageInfo 。为什么之前我的插件化基础框架并没有使用这种方式呢？实际上这中思想就是完全把资源交给自己管理，而我们平时所考虑的，往往想要Android能够帮我们完成一大部分的内容，毕竟如果完全拿出来管理，会发现整个插件框架很沉重，而且反射的地方又不会太多的减少，大大的增加不稳定性。

这里面的思想大致就是根据读取的模式来读取PackageInfo下的数据，并且缓存到对应的集合中，以待下次获取。

这里做了很重要的一步，获取了插件的信息，并通过这些信息如apk路径，在UI进程为插件生成了对应的ClassLoader也即是PluginDexClassLoader，生成对应的Context也即是PluginContext，这些全部保存在Plugin类的Loader对象中。为之后启动插件框架做准备。这里我先不放出PluginDexClassLoader中的逻辑，先埋个伏笔，到下面和RePluginClassLoader一起分析。

### loadEntryLocked
```
private boolean loadEntryLocked(PluginCommImpl manager) {
        if (mDummyPlugin) {
            ...
        } else {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "Plugin.loadEntryLocked(): Load entry, info=" + mInfo);
            }
            if (mLoader.loadEntryMethod2()) {
                ...
            } else if (mLoader.loadEntryMethod(false)) {
                ...
            } else if (mLoader.loadEntryMethod3()) {
                if (!mLoader.invoke2(manager)) {
                    return false;
                }
            } else {
                if (LOGR) {
                    LogRelease.e(PLUGIN_TAG, "p.lel f " + mInfo.getName());
                }
                return false;
            }
        }
        return true;
    }
```
这里我们只挑出我们需要关注的最新版本对应的分支。看看这个mLoader.loadEntryMethod3()究竟做了什么？
```
 /**
     * 新版SDK（RePlugin-library）插件入口报名前缀
     * 在插件中，该包名不能混淆
     */
    public static final String REPLUGIN_LIBRARY_ENTRY_PACKAGE_PREFIX = "com.qihoo360.replugin";

    /**
     * 插件的入口类
     * 在插件中，该名字不能混淆
     * @hide 内部框架使用
     */
    public static final String PLUGIN_ENTRY_CLASS_NAME = "Entry";

/**
     * 插件的入口类导出函数
     * 在插件中，该方法名不能混淆
     * 通过该函数创建IPlugin对象
     * @hide 内部框架使用
     */
    public static final String PLUGIN_ENTRY_EXPORT_METHOD_NAME = "create";

final boolean loadEntryMethod3() {
        //
        try {
            String className = Factory.REPLUGIN_LIBRARY_ENTRY_PACKAGE_PREFIX + "." + Factory.PLUGIN_ENTRY_CLASS_NAME;
            Class<?> c = mClassLoader.loadClass(className);
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "found entry: className=" + className + ", loader=" + c.getClassLoader());
            }
            mCreateMethod2 = c.getDeclaredMethod(Factory.PLUGIN_ENTRY_EXPORT_METHOD_NAME, Factory.PLUGIN_ENTRY_EXPORT_METHOD2_PARAMS);
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, e.getMessage(), e);
            }
        }
        return mCreateMethod2 != null;
    }
```

这个方法究竟在干啥？根据反射的String看看究竟调用了什么方法：
```
com.qihoo360.replugin.Entry.create( Context context, 
ClassLoader classloader, IBinder IBinder)
```
你会发现，找遍了整个host-library你都找不到这个方法。但是这个mClassLoader仔细的读者会发现实际上是指刚才生成的PluginDexClassLoader。换句话说，我们想要反射的是插件也就是plugin-library中的类。

我这里整理一下这里面的思路。

看到这里估计聪明的读者大概猜到后续的思路。实际上RePlugin实际上就是为插件生成一个ClassLoader，为自己创造一个classloader。在宿主想要启动插件的class的时候，会先通过自己classloader，用插件的classloader去查找对应的类就能找到我们想要的类。这样就做到了RePlugin所说的最小入侵。

继续回来。回到原来的思路，当我们知道怎么查找类的，让我们看看假如我们要跨进程启动Activity又是如何。还记得我上面说的MP. startPluginProcess方法吗？我们进去看看。

### MP.startPluginProcess
```
public static final IPluginClient startPluginProcess(String plugin, int process, PluginBinderInfo info) throws RemoteException {
        return PluginProcessMain.getPluginHost().startPluginProcess(plugin, process, info);
    }
```
还记得这个getPluginHost，此时我们在UI进程就是指的是AIDL的远程常驻进程PmHostSvc的代理类。

### startPluginProcessLocked
```
final IPluginClient startPluginProcessLocked(String plugin, int process, PluginBinderInfo info) {
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "start plugin process: plugin=" + plugin + " info=" + info);
        }

        // 强制使用UI进程
        if (Constant.ENABLE_PLUGIN_ACTIVITY_AND_BINDER_RUN_IN_MAIN_UI_PROCESS) {
            if (info.request == PluginBinderInfo.ACTIVITY_REQUEST) {
                if (process == IPluginManager.PROCESS_AUTO) {
                    process = IPluginManager.PROCESS_UI;
                }
            }
            if (info.request == PluginBinderInfo.BINDER_REQUEST) {
                if (process == IPluginManager.PROCESS_AUTO) {
                    process = IPluginManager.PROCESS_UI;
                }
            }
        }

        //
        PluginProcessMain.schedulePluginProcessLoop(PluginProcessMain.CHECK_STAGE1_DELAY);

        // 获取
        IPluginClient client = PluginProcessMain.probePluginClient(plugin, process, info);
        if (client != null) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "start plugin process: probe client ok, already running, plugin=" + plugin + " client=" + client);
            }
            return client;
        }

        // 分配
        int index = IPluginManager.PROCESS_AUTO;
        try {
            index = PluginProcessMain.allocProcess(plugin, process);
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "start plugin process: alloc process ok, plugin=" + plugin + " index=" + index);
            }
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "a.p.p: " + e.getMessage(), e);
            }
        }
        // 分配的坑位不属于UI、和自定义进程，就返回。
        if (!(index == IPluginManager.PROCESS_UI
                || PluginProcessHost.isCustomPluginProcess(index)
                || PluginManager.isPluginProcess(index))) {
            return null;
        }

        // 启动
        boolean rc = PluginProviderStub.proxyStartPluginProcess(mContext, index);
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "start plugin process: start process ok, plugin=" + plugin + " index=" + index);
        }
        if (!rc) {
            return null;
        }

        // 再次获取
        client = PluginProcessMain.probePluginClient(plugin, process, info);
        if (client == null) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "spp pc n");
            }
            return null;
        }

        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "start plugin process: probe client ok, plugin=" + plugin + " index=" + info.index);
        }

        return client;
    }
```
RePlugin的IPluginClient是被PluginProcessPer实现的。这里将会去常驻进程查看有没有已经可以分配好的进程，已经分配好的说明这个进程已经启动就没有必要启动。

假如没有启动进程就通过下面的方法分配进程。
```
index = PluginProcessMain.allocProcess(plugin, process);
```

真正启动进程的方法是下面
```
/**
     * @param context
     * @param index
     * @return
     */
    static final boolean proxyStartPluginProcess(Context context, int index) {
        //
        ContentValues values = new ContentValues();
        values.put(KEY_METHOD, METHOD_START_PROCESS);
        values.put(KEY_COOKIE, PMF.sPluginMgr.mLocalCookie);
        Uri uri = context.getContentResolver().insert(ProcessPitProviderBase.buildUri(index), values);
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "proxyStartPluginProcess insert.rc=" + (uri != null ? uri.toString() : "null"));
        }
        if (uri == null) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "proxyStartPluginProcess failed");
            }
            return false;
        }
        return true;
    }
```

那究竟是怎么分配进程的呢？
ProcessPitProviderBase这个是一个基础类。实际上我们会根据要启动的进程分配一下几种内容提供器。
![不同进程的内容提供器.png](/images/不同进程的内容提供器.png)

这样就是在这几个范围内加载RePlugin已经给予的进程坑位。当然这里面也涉及到了自己定义的进程Activity的情况，也会被RePlugin的Gradle插件修改RePlugin的坑位。

这就是RePlugin所说的这个框架本身支持多进程。

好的多进程大致上如何搭起来也明白，其他详细就有有好奇心的读者研究吧。这里篇幅原因就不继续分析。有了这些信息也能很好的明白其中的原理。

##### 当RePlugin分配好了进程，就要调用context.startActivity的方法，跑到RePluginClassLoader查找类。


### RePluginClassLoader和PluginDexClassLoader的分析比较。

这里我们其实只需要看两者的loadclass方法。
#### RePluginClassLoader
```
public class RePluginClassLoader extends PathClassLoader {

    private static final String TAG = "RePluginClassLoader";

    private final ClassLoader mOrig;

    /**
     * 用load系列代替
     */
    //private Method findClassMethod;

    private Method findResourceMethod;

    private Method findResourcesMethod;

    private Method findLibraryMethod;

    private Method getPackageMethod;

    public RePluginClassLoader(ClassLoader parent, ClassLoader orig) {

        // 由于PathClassLoader在初始化时会做一些Dir的处理，所以这里必须要传一些内容进来
        // 但我们最终不用它，而是拷贝所有的Fields
        super("", "", parent);
        mOrig = orig;

        // 将原来宿主里的关键字段，拷贝到这个对象上，这样骗系统以为用的还是以前的东西（尤其是DexPathList）
        // 注意，这里用的是“浅拷贝”
        // Added by Jiongxuan Zhang
        copyFromOriginal(orig);

        initMethods(orig);
    }

    private void initMethods(ClassLoader cl) {
        Class<?> c = cl.getClass();
        findResourceMethod = ReflectUtils.getMethod(c, "findResource", String.class);
        findResourceMethod.setAccessible(true);
        findResourcesMethod = ReflectUtils.getMethod(c, "findResources", String.class);
        findResourcesMethod.setAccessible(true);
        findLibraryMethod = ReflectUtils.getMethod(c, "findLibrary", String.class);
        findLibraryMethod.setAccessible(true);
        getPackageMethod = ReflectUtils.getMethod(c, "getPackage", String.class);
        getPackageMethod.setAccessible(true);
    }

    private void copyFromOriginal(ClassLoader orig) {
        if (LOG && IPC.isPersistentProcess()) {
            LogDebug.d(TAG, "copyFromOriginal: Fields=" + StringUtils.toStringWithLines(ReflectUtils.getAllFieldsList(orig.getClass())));
        }

        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.GINGERBREAD_MR1) {
            // Android 2.2 - 2.3.7，有一堆字段，需要逐一复制
            // 以下方法在较慢的手机上用时：8ms左右
            copyFieldValue("libPath", orig);
            copyFieldValue("libraryPathElements", orig);
            copyFieldValue("mDexs", orig);
            copyFieldValue("mFiles", orig);
            copyFieldValue("mPaths", orig);
            copyFieldValue("mZips", orig);
        } else {
            // Android 4.0以上只需要复制pathList即可
            // 以下方法在较慢的手机上用时：1ms
            copyFieldValue("pathList", orig);
        }
    }

    private void copyFieldValue(String field, ClassLoader orig) {
        try {
            Field f = ReflectUtils.getField(orig.getClass(), field);
            if (f == null) {
                if (LOGR) {
                    LogRelease.e(PLUGIN_TAG, "rpcl.cfv: null! f=" + field);
                }
                return;
            }

            // 删除final修饰符
            ReflectUtils.removeFieldFinalModifier(f);

            // 复制Field中的值到this里
            Object o = ReflectUtils.readField(f, orig);
            ReflectUtils.writeField(f, this, o);

            if (LOG) {
                Object test = ReflectUtils.readField(f, this);
                LogDebug.d(TAG, "copyFieldValue: Copied. f=" + field + "; actually=" + test + "; orig=" + o);
            }
        } catch (IllegalAccessException e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "rpcl.cfv: fail! f=" + field);
            }
        }
    }

    @Override
    protected Class<?> loadClass(String className, boolean resolve) throws ClassNotFoundException {
        //
        Class<?> c = null;
        c = PMF.loadClass(className, resolve);
        if (c != null) {
            return c;
        }
        //
        try {
            c = mOrig.loadClass(className);
            // 只有开启“详细日志”才会输出，防止“刷屏”现象
            if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                LogDebug.d(TAG, "loadClass: load other class, cn=" + className);
            }
            return c;
        } catch (Throwable e) {
            //
        }
        //
        return super.loadClass(className, resolve);
    }



    @Override
    protected Package getPackage(String name) {
        // 金立手机的某些ROM(F103,F103L,F303,M3)代码ClassLoader.getPackage去掉了关键的保护和错误处理(2015.11~2015.12左右)，会返回null
        // 悬浮窗某些draw代码触发getPackage(...).getName()，getName出现空指针解引，导致悬浮窗进程出现了大量崩溃
        // 此处实现和AOSP一致确保不会返回null
        // SONGZHAOCHUN, 2016/02/29
        if (name != null && !name.isEmpty()) {
            Package pack = null;
            try {
                pack = (Package) getPackageMethod.invoke(mOrig, name);
            } catch (IllegalArgumentException e) {
                e.printStackTrace();
            } catch (IllegalAccessException e) {
                e.printStackTrace();
            } catch (InvocationTargetException e) {
                e.printStackTrace();
            }
            if (pack == null) {
                if (LOGR) {
                    LogRelease.w(PLUGIN_TAG, "NRH lcl.gp.1: n=" + name);
                }
                pack = super.getPackage(name);
            }
            if (pack == null) {
                if (LOGR) {
                    LogRelease.w(PLUGIN_TAG, "NRH lcl.gp.2: n=" + name);
                }
                return definePackage(name, "Unknown", "0.0", "Unknown", "Unknown", "0.0", "Unknown", null);
            }
            return pack;
        }
        return null;
    }
}
```
首先这个ClassLoader是继承于PathClassLoader。这个classloader在Android内部是用来加载已经安装好的apk的dex文件。这个思想实际上使用的是我之前说的保守方案。

实际上着相当于一个原来宿主的classloader代理。我们将宿主的classloader的信息，pathList等注入到该classloader中。让这个classloader可以正常寻找宿主的类。这么做的目的就是为了下面这个方法

### PmBase.loadClass
```
 @Override
    protected Class<?> loadClass(String className, boolean resolve) throws ClassNotFoundException {
        //
        Class<?> c = null;
        c = PMF.loadClass(className, resolve);
        if (c != null) {
            return c;
        }
        //
        try {
            c = mOrig.loadClass(className);
            // 只有开启“详细日志”才会输出，防止“刷屏”现象
            if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                LogDebug.d(TAG, "loadClass: load other class, cn=" + className);
            }
            return c;
        } catch (Throwable e) {
            //
        }
        //
        return super.loadClass(className, resolve);
    }
```
在调用原来的classloader加载class之前，我们想要先去查找插件有没有这个类，有则直接返回。我们看看这个loadclass就是做了什么。这里我只取出关键的获取Activity类的片段
```
final Class<?> loadClass(String className, boolean resolve) {
        // 加载Service中介坑位
        if (className.startsWith(PluginPitService.class.getName())) {
            if (LOG) {
                LogDebug.i(TAG, "loadClass: Loading PitService Class... clz=" + className);
            }
            return PluginPitService.class;
        }

        //
        if (mContainerActivities.contains(className)) {
            Class<?> c = mClient.resolveActivityClass(className);
            if (c != null) {
                return c;
            }
            // 输出warn日志便于查看
            // use DummyActivity orig=
            if (LOGR) {
                LogRelease.w(PLUGIN_TAG, "p m hlc u d a o " + className);
            }
            return DummyActivity.class;
        }

        ...

        //
        return loadDefaultClass(className);
    }
```

关键方法在
```
mClient.resolveActivityClass(className);
```

### PluginProcessPer.resolveActivityClass
此时RePlugin会调用UI进程的resolveActivityClass方法。
```
final Class<?> resolveActivityClass(String container) {
        String plugin = null;
        String activity = null;

        // 先找登记的，如果找不到，则用forward activity
        PluginContainers.ActivityState state = mACM.lookupByContainer(container);
        if (state == null) {
            // PACM: loadActivityClass, not register, use forward activity, container=
            if (LOGR) {
                LogRelease.w(PLUGIN_TAG, "use f.a, c=" + container);
            }
            return ForwardActivity.class;
        }
        plugin = state.plugin;
        activity = state.activity;

        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "PACM: loadActivityClass in=" + container + " target=" + activity + " plugin=" + plugin);
        }

        Plugin p = mPluginMgr.loadAppPlugin(plugin);
        if (p == null) {
            // PACM: loadActivityClass, not found plugin
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, "load fail: c=" + container + " p=" + plugin + " t=" + activity);
            }
            return null;
        }

        ClassLoader cl = p.getClassLoader();
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "PACM: loadActivityClass, plugin activity loader: in=" + container + " activity=" + activity);
        }
        Class<?> c = null;
        try {
            c = cl.loadClass(activity);
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, e.getMessage(), e);
            }
        }
        if (LOG) {
            LogDebug.d(PLUGIN_TAG, "PACM: loadActivityClass, plugin activity loader: c=" + c + ", loader=" + cl);
        }

        return c;
    }
```
我们先从本地缓存中寻找在进程初始化的存在的对应启动模式的坑位。接着获取出样板的Plugin，在从loadAppPlugin方法读取。这个方法还记得吧，不过这个时候已经有了缓存，直接获取缓存即可。加载了插件的数据，并且生成插件对应的classloader和context。

由于这个classloader是使用apk对应路径生成的，所以可以找到插件类的类，并且成功返回。

### PluginDexClassLoader

我们看看这个给予插件的classloader是否有什么特殊。
```
public class PluginDexClassLoader extends DexClassLoader {

    private static final String TAG = "PluginDexClassLoader";

    private final ClassLoader mHostClassLoader;

    private static Method sLoadClassMethod;

    /**
     * 初始化插件的DexClassLoader的构造函数。插件化框架会调用此函数。
     *
     * @param pi                 the plugin's info,refer to {@link PluginInfo}
     * @param dexPath            the list of jar/apk files containing classes and
     *                           resources, delimited by {@code File.pathSeparator}, which
     *                           defaults to {@code ":"} on Android
     * @param optimizedDirectory directory where optimized dex files
     *                           should be written; must not be {@code null}
     * @param librarySearchPath  the list of directories containing native
     *                           libraries, delimited by {@code File.pathSeparator}; may be
     *                           {@code null}
     * @param parent             the parent class loader
     */
    public PluginDexClassLoader(PluginInfo pi, String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent) {
        super(dexPath, optimizedDirectory, librarySearchPath, parent);

        installMultiDexesBeforeLollipop(pi, dexPath, parent);

        mHostClassLoader = RePluginInternal.getAppClassLoader();

        initMethods(mHostClassLoader);
    }

    private static void initMethods(ClassLoader cl) {
        Class<?> clz = cl.getClass();
        if (sLoadClassMethod == null) {
            sLoadClassMethod = ReflectUtils.getMethod(clz, "loadClass", String.class, Boolean.TYPE);
            if (sLoadClassMethod == null) {
                throw new NoSuchMethodError("loadClass");
            }
        }
    }

    @Override
    protected Class<?> loadClass(String className, boolean resolve) throws ClassNotFoundException {
        // 插件自己的Class。从自己开始一直到BootClassLoader，采用正常的双亲委派模型流程，读到了就直接返回
        Class<?> pc = null;
        ClassNotFoundException cnfException = null;
        try {
            pc = super.loadClass(className, resolve);
            if (pc != null) {
                // 只有开启“详细日志”才会输出，防止“刷屏”现象
                if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                    LogDebug.d(TAG, "loadClass: load plugin class, cn=" + className);
                }
                return pc;
            }
        } catch (ClassNotFoundException e) {
            // Do not throw "e" now
            cnfException = e;
        }

        // 若插件里没有此类，则会从宿主ClassLoader中找，找到了则直接返回
        // 注意：需要读取isUseHostClassIfNotFound开关。默认为关闭的。可参见该开关的说明
        if (RePlugin.getConfig().isUseHostClassIfNotFound()) {
            try {
                return loadClassFromHost(className, resolve);
            } catch (ClassNotFoundException e) {
                // Do not throw "e" now
                cnfException = e;
            }
        }

        // At this point we can throw the previous exception
        if (cnfException != null) {
            throw cnfException;
        }
        return null;
    }

    private Class<?> loadClassFromHost(String className, boolean resolve) throws ClassNotFoundException {
        Class<?> c;
        try {
            c = (Class<?>) sLoadClassMethod.invoke(mHostClassLoader, className, resolve);
            // 只有开启“详细日志”才会输出，防止“刷屏”现象
            if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                LogDebug.w(TAG, "loadClass: load host class, cn=" + className + ", cz=" + c);
            }
        } catch (IllegalAccessException e) {
            // Just rethrow
            throw new ClassNotFoundException("Calling the loadClass method failed (IllegalAccessException)", e);
        } catch (InvocationTargetException e) {
            // Just rethrow
            throw new ClassNotFoundException("Calling the loadClass method failed (InvocationTargetException)", e);
        }
        return c;
    }

    /**
     * install extra dexes
     *
     * @param pi
     * @param dexPath
     * @param parent
     * @deprecated apply to ROM before Lollipop,may be deprecated
     */
    private void installMultiDexesBeforeLollipop(PluginInfo pi, String dexPath, ClassLoader parent) {

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            return;
        }

        try {

            // get paths of extra dex
            List<File> dexFiles = getExtraDexFiles(pi, dexPath);

            if (dexFiles != null && dexFiles.size() > 0) {

                List<Object[]> allElements = new LinkedList<>();

                // get dexElements of main dex
                Class<?> clz = Class.forName("dalvik.system.BaseDexClassLoader");
                Object pathList = ReflectUtils.readField(clz, this, "pathList");
                Object[] mainElements = (Object[]) ReflectUtils.readField(pathList.getClass(), pathList, "dexElements");
                allElements.add(mainElements);

                // get dexElements of extra dex (need to load dex first)
                String optimizedDirectory = pi.getExtraOdexDir().getAbsolutePath();

                for (File file : dexFiles) {
                    if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                        LogDebug.d(TAG, "dex file:" + file.getName());
                    }

                    DexClassLoader dexClassLoader = new DexClassLoader(file.getAbsolutePath(), optimizedDirectory, optimizedDirectory, parent);

                    Object obj = ReflectUtils.readField(clz, dexClassLoader, "pathList");
                    Object[] dexElements = (Object[]) ReflectUtils.readField(obj.getClass(), obj, "dexElements");
                    allElements.add(dexElements);
                }

                // combine Elements
                Object combineElements = combineArray(allElements);

                // rewrite Elements combined to classLoader
                ReflectUtils.writeField(pathList.getClass(), pathList, "dexElements", combineElements);

                // delete extra dex, after optimized
                FileUtils.forceDelete(pi.getExtraDexDir());

                //Test whether the Extra Dex is installed
                if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {

                    Object object = ReflectUtils.readField(pathList.getClass(), pathList, "dexElements");
                    int length = Array.getLength(object);
                    LogDebug.d(TAG, "dexElements length:" + length);
                }
            }

        } catch (Exception e) {
            e.printStackTrace();
        }

    }

    /**
     * combine dexElements Array
     *
     * @param allElements all dexElements of dexes
     * @return the combined dexElements
     */
    private Object combineArray(List<Object[]> allElements) {

        int startIndex = 0;
        int arrayLength = 0;
        Object[] originalElements = null;

        for (Object[] elements : allElements) {

            if (originalElements == null) {
                originalElements = elements;
            }

            arrayLength += elements.length;
        }

        Object[] combined = (Object[]) Array.newInstance(
                originalElements.getClass().getComponentType(), arrayLength);

        for (Object[] elements : allElements) {

            System.arraycopy(elements, 0, combined, startIndex, elements.length);
            startIndex += elements.length;
        }

        return combined;
    }

    /**
     * get paths of extra dex
     *
     * @param pi
     * @param dexPath
     * @return the File list of the extra dexes
     */
    private List<File> getExtraDexFiles(PluginInfo pi, String dexPath) {

        ZipFile zipFile = null;
        List<File> files = null;

        try {

            if (pi != null) {
                zipFile = new ZipFile(dexPath);
                files = traverseExtraDex(pi, zipFile);
            }

        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            CloseableUtils.closeQuietly(zipFile);
        }

        return files;

    }

    /**
     * traverse extra dex files
     *
     * @param pi
     * @param zipFile
     * @return the File list of the extra dexes
     */
    private static List<File> traverseExtraDex(PluginInfo pi, ZipFile zipFile) {

        String dir = null;
        List<File> files = new LinkedList<>();
        Enumeration<? extends ZipEntry> entries = zipFile.entries();
        while (entries.hasMoreElements()) {
            ZipEntry entry = entries.nextElement();
            String name = entry.getName();
            if (name.contains("../")) {
                // 过滤，防止被攻击
                continue;
            }

            try {
                if (name.contains(".dex") && !name.equals("classes.dex")) {

                    if (dir == null) {
                        dir = pi.getExtraDexDir().getAbsolutePath();
                    }

                    File file = new File(dir, name);
                    extractFile(zipFile, entry, file);
                    files.add(file);

                    if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                        LogDebug.d(TAG, "dex path:" + file.getAbsolutePath());
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }

        }

        return files;
    }

    /**
     * extract File
     *
     * @param zipFile
     * @param ze
     * @param outFile
     * @throws IOException
     */
    private static void extractFile(ZipFile zipFile, ZipEntry ze, File outFile) throws IOException {
        InputStream in = null;
        try {
            in = zipFile.getInputStream(ze);
            FileUtils.copyInputStreamToFile(in, outFile);
            if (LogDebug.LOG && RePlugin.getConfig().isPrintDetailLog()) {
                LogDebug.d(TAG, "extractFile(): Success! fn=" + outFile.getName());
            }
        } finally {
            CloseableUtils.closeQuietly(in);
        }
    }

}
```
实际上我们只要关注到loadClass还是原来的那个。还能了解到这个classloader还具备着寻找宿主的类，只是默认这个选项是关闭的。

通过这些步骤，RePlugin就能启动对应的类了。但是又是怎么找到资源的呢？接下来就到了插件库的登场。


## Plugin-Library插件库
还记得我之前说的Host库中通过反射，获取了插件库中的方法。我们看看对于插件库中，Entry.create方法都传了什么参数。
```
final boolean invoke2(PluginCommImpl x) {
        try {
            IBinder manager = null; // TODO
            IBinder b = (IBinder) mCreateMethod2.invoke(null, mPkgContext, getClass().getClassLoader(), manager);
            if (b == null) {
                if (LOGR) {
                    LogRelease.e(PLUGIN_TAG, "p.e.r.b n");
                }
                return false;
            }
            mBinderPlugin = new ProxyPlugin(b);
            mPlugin = mBinderPlugin;
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "Loader.invoke2(): plugin=" + mPath + ", plugin.binder.cl=" + b.getClass().getClassLoader());
            }
        } catch (Throwable e) {
            if (LOGR) {
                LogRelease.e(PLUGIN_TAG, e.getMessage(), e);
            }
            return false;
        }
        return true;
    }
```
这里mPkgContext实际上是上面生成的PluginContext，并且把当前宿主的classloader传递过去。通过这个方法生成了AIDL中Plugin远程代理类。由于这里是多进程框架的分析，所以这个AIDL起到了恰到好处，我们可以通过远程代理类来和插件进程进行交互。

接下来让我们正式的看看这个方法Entry.create究竟做了什么。
```
public static final IBinder create(Context context, ClassLoader cl, IBinder manager) {
        // 初始化插件框架
        RePluginFramework.init(cl);
        // 初始化Env
        RePluginEnv.init(context, cl, manager);

        return new IPlugin.Stub() {
            @Override
            public IBinder query(String name) throws RemoteException {
                return RePluginServiceManager.getInstance().getService(name);
            }
        };
    }
```

这里做了两件事情。
第一，初始化了插件框架，通过宿主传进来的classloader，初始化好所有所有调用宿主RePlugin宿主库的反射方法。

第二，保存context，classloader等数据，并且启动插件库的服务管理器。

到这里是不是就感觉结束了，并没有做什么动作也没有启动什么东西。感觉源码读不下去了。

其实这里RePlugin的Gradle插件还做了一件事情。我们看看LoaderActivityInjector中的
```
    def private static loaderActivityRules = [
            'android.app.Activity'                    : 'com.qihoo360.replugin.loader.a.PluginActivity',
            'android.app.TabActivity'                 : 'com.qihoo360.replugin.loader.a.PluginTabActivity',
            'android.app.ListActivity'                : 'com.qihoo360.replugin.loader.a.PluginListActivity',
            'android.app.ActivityGroup'               : 'com.qihoo360.replugin.loader.a.PluginActivityGroup',
            'android.support.v4.app.FragmentActivity' : 'com.qihoo360.replugin.loader.a.PluginFragmentActivity',
            'android.support.v7.app.AppCompatActivity': 'com.qihoo360.replugin.loader.a.PluginAppCompatActivity',
            'android.preference.PreferenceActivity'   : 'com.qihoo360.replugin.loader.a.PluginPreferenceActivity',
            'android.app.ExpandableListActivity'      : 'com.qihoo360.replugin.loader.a.PluginExpandableListActivity'
    ]

private def handleActivity(ClassPool pool, String activity, String classesDir) {
        def clsFilePath = classesDir + File.separatorChar + activity.replaceAll('\\.', '/') + '.class'
        if (!new File(clsFilePath).exists()) {
            return
        }

        println ">>> Handle $activity"

        def stream, ctCls
        try {
            stream = new FileInputStream(clsFilePath)
            ctCls = pool.makeClass(stream);
/*
             // 打印当前 Activity 的所有父类
            CtClass tmpSuper = ctCls.superclass
            while (tmpSuper != null) {
                println(tmpSuper.name)
                tmpSuper = tmpSuper.superclass
            }
*/
            // ctCls 之前的父类
            def originSuperCls = ctCls.superclass

            /* 从当前 Activity 往上回溯，直到找到需要替换的 Activity */
            def superCls = originSuperCls
            while (superCls != null && !(superCls.name in loaderActivityRules.keySet())) {
                // println ">>> 向上查找 $superCls.name"
                ctCls = superCls
                superCls = ctCls.superclass
            }

            // 如果 ctCls 已经是 LoaderActivity，则不修改
            if (ctCls.name in loaderActivityRules.values()) {
                // println "    跳过 ${ctCls.getName()}"
                return
            }

            /* 找到需要替换的 Activity, 修改 Activity 的父类为 LoaderActivity */
            if (superCls != null) {
                def targetSuperClsName = loaderActivityRules.get(superCls.name)
                // println "    ${ctCls.getName()} 的父类 $superCls.name 需要替换为 ${targetSuperClsName}"
                CtClass targetSuperCls = pool.get(targetSuperClsName)

                if (ctCls.isFrozen()) {
                    ctCls.defrost()
                }
                ctCls.setSuperclass(targetSuperCls)

                // 修改声明的父类后，还需要方法中所有的 super 调用。
                ctCls.getDeclaredMethods().each { outerMethod ->
                    outerMethod.instrument(new ExprEditor() {
                        @Override
                        void edit(MethodCall call) throws CannotCompileException {
                            if (call.isSuper()) {
                                if (call.getMethod().getReturnType().getName() == 'void') {
                                    call.replace('{super.' + call.getMethodName() + '($$);}')
                                } else {
                                    call.replace('{$_ = super.' + call.getMethodName() + '($$);}')
                                }
                            }
                        }
                    })
                }

                ctCls.writeFile(CommonData.getClassPath(ctCls.name))
                println "    Replace ${ctCls.name}'s SuperClass ${superCls.name} to ${targetSuperCls.name}"
            }

        } catch (Throwable t) {
            println "    [Warning] --> ${t.toString()}"
        } finally {
            if (ctCls != null) {
                ctCls.detach()
            }
            if (stream != null) {
                stream.close()
            }
        }
    }
```
实际上，这段源码的意思就是指把所有继承Activity，Fragment的类全部都变成
RePlugin提供的Activity。那我们就看看下面这个类，在启动的时候做了什么手脚。
```
com.qihoo360.replugin.loader.a.PluginActivity
```
### PluginActivity
```
public abstract class PluginActivity extends Activity {

    @Override
    protected void attachBaseContext(Context newBase) {
        newBase = RePluginInternal.createActivityContext(this, newBase);
        super.attachBaseContext(newBase);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        //
        RePluginInternal.handleActivityCreateBefore(this, savedInstanceState);

        super.onCreate(savedInstanceState);

        //
        RePluginInternal.handleActivityCreate(this, savedInstanceState);
    }
```
我们要明白RePlugin是怎么查找资源。实际上我们需要看的就只有attachBaseContext这个方法。

还记得我上面的Activity的启动流程时序图吗？
实际上在Activity调用onCreate之前会有一次绑定的操作。下面是ActivityThread.performLaunchActivity的方法片段：
```
 Context appContext = createBaseContextForActivity(r, activity);
                CharSequence title = r.activityInfo.loadLabel(appContext.getPackageManager());
                Configuration config = new Configuration(mCompatConfiguration);
                if (r.overrideConfig != null) {
                    config.updateFrom(r.overrideConfig);
                }
                if (DEBUG_CONFIGURATION) Slog.v(TAG, "Launching activity "
                        + r.activityInfo.name + " with config " + config);
                Window window = null;
                if (r.mPendingRemoveWindow != null && r.mPreserveWindow) {
                    window = r.mPendingRemoveWindow;
                    r.mPendingRemoveWindow = null;
                    r.mPendingRemoveWindowManager = null;
                }
                activity.attach(appContext, this, getInstrumentation(), r.token,
                        r.ident, app, r.intent, r.activityInfo, title, r.parent,
                        r.embeddedID, r.lastNonConfigurationInstances, config,
                        r.referrer, r.voiceInteractor, window);

                if (customIntent != null) {
                    activity.mIntent = customIntent;
                }
                r.lastNonConfigurationInstances = null;
                activity.mStartedActivity = false;
                int theme = r.activityInfo.getThemeResource();
                if (theme != 0) {
                    activity.setTheme(theme);
                }

                activity.mCalled = false;
                if (r.isPersistable()) {
                    mInstrumentation.callActivityOnCreate(activity, r.state, r.persistentState);
                } else {
                    mInstrumentation.callActivityOnCreate(activity, r.state);
                }
```
 
> 而这个绑定方法实际会调用attachBaseContext(context);把由系统生成的context绑定到Acitivity中。

那么在RePlugin插件库中的createActivityContext就是为了生成自己context去代替系统生成的context。
```
public static Context createActivityContext(Activity activity, Context newBase) {
        if (!RePluginFramework.mHostInitialized) {
            return newBase;
        }

        try {
            return (Context) ProxyRePluginInternalVar.createActivityContext.call(null, activity, newBase);
        } catch (Exception e) {
            if (LogDebug.LOG) {
                e.printStackTrace();
            }
        }

        return null;
    }
```
而这里做的工作就是判断插件库的是否初始化，没有则返回系统，有则反射获取宿主库的Context。
```
createActivityContext = new MethodInvoker(classLoader, factory2, 
"createActivityContext", new Class<?>[]{Activity.class, Context.class});
```

而宿主库下面这个方法
```
public Context createActivityContext(Activity activity, Context newBase) {
//        PluginContainers.ActivityState state = mPluginMgr.mClient.mACM.lookupLastLoading(activity.getClass().getName());
//        if (state == null) {
//            if (LOG) {
//                LogDebug.w(PLUGIN_TAG, "PACM: createActivityContext: can't found plugin activity: activity=" + activity.getClass().getName());
//            }
//            return null;
//        }
//        Plugin plugin = mPluginMgr.loadAppPlugin(state.mCN.getPackageName());

        // 此时插件必须被加载，因此通过class loader一定能找到对应的PLUGIN对象
        Plugin plugin = mPluginMgr.lookupPlugin(activity.getClass().getClassLoader());
        if (plugin == null) {
            if (LOG) {
                LogDebug.d(PLUGIN_TAG, "PACM: createActivityContext: can't found plugin object for activity=" + activity.getClass().getName());
            }
            return null;
        }

        return plugin.mLoader.createBaseContext(newBase);
    }
```
实际上就是我们在宿主寻找插件类时候初始化好的PluginContext。我们也能看看生成方法。
```
final Plugin lookupPlugin(ClassLoader loader) {
        for (Plugin p : mPlugins.values()) {
            if (p != null && p.getClassLoader() == loader) {
                return p;
            }
        }
        return null;
    }

final Context createBaseContext(Context newBase) {
        return new PluginContext(newBase, android.R.style.Theme, mClassLoader, mPkgResources, mPluginName, this);
    }
```

那么为什么我们要替代掉系统的Context呢？实际上替代掉Context的主要原因就是为了让插件能够寻找到我们的资源文件。

这里又涉及到了Activity如何加载资源的源码，我在上面已经讲解过一边。

>实际上当Android加载资源的时候，最终会调用LayoutInflater.inflate.而这个方法获取资源又是借用final Resources res = getContext().getResources();才获取到真正的资源对象。

所以当我们替换成为我们的PluginContext，就能让PluginActivity查找到了要加载的资源文件。

至此，RePlugin如何查找类，如何查找资源的过程全部明了，那么启动一个Activity也就顺其自然了。

这里借用[恋猫de小郭](https://juejin.im/user/582aca2ba22b9d006b59ae68)
大佬的一张图就能很清楚了解到两个ClassLoader之间的关系


![classloader关系图.png](/images/classloader关系图.png)

到这里RePlugin的源码解析就结束了。但是既然是横向分析，那么我们需要总结出Small和RePlugin的异同。

# Small和RePlugin的比较总结
实际上经过源码的分析，我们可以清楚：

### Small
Small是一个单进程，而且代码比较轻量化的插件化的框架。为什么说轻量化，一个主要之一就是代码量比起其他的框架少了至少一倍。在实现上，类的加载和资源的加载统一放在一处框架集中管理。

而且在思想上，Small对插件的理解是除了外部apk外，内部所有的模块都是插件。就可以明白，Small刚开始创造出来的初衷也是除了能够管理外部的插件，主要还是为了形成组件化，让整个工程解藕。让整个工程能够灵活的热插拔。

![Small插件化框架模型.png](/images/Small插件化框架模型.png)

### RePlugin
RePlugin则是一个支持多进程的，重量级的框架。为什么说重量级别，一个原因是代码量比起DroidPlugin少，但是比起Small多许多。第二个，当我们默认开启进程的时候，平均每个进程大致上会占用多5M的内存空间。但是有一个很大的优点，那就是几乎没有入侵Android的系统源码。毫不夸张的说，RePlugin只反射了一处系统源码，而这处几乎是没有变动过，如果Google没有很大变动的化，RePlugin将会毫无疑问的是最稳定的一款，甚至说，可以兼容Android未来的版本。

在实现上，让插件和宿主借助常驻进程维护自己的资源和类，和DroidPlugin相似的地方就是宿主不需要管理插件的资源和类，希望每个插件只关注自己的类和资源。

从思想上，可能是本人见识的少，这是本人第一次见识到了两个库协同运行的方法，不管其他人如何想的。对于我来说，这是收获最大的一次。但是有一点需要诟病，如果RePlugin能够想Small一样把整个加载抽象出来管理，我感觉就完美了。

![RePlugin插件框架模型.png](/images/RePlugin插件框架模型.png)



# 总结
从个人感觉来说，如果工程量不大，又对多进程没有太多的想法的工程完全可以优先使用Small。而如果整个工程量大，以后又可能使用多进程，追求稳定的大型项目还是推荐RePlugin。

这里如果好奇AppCompat应该如何兼容的读者可以看看：
红橙Darren：https://www.jianshu.com/p/e359fafe5c29

还有对我的插件化基础模型感兴趣的可以去我的github上：
https://github.com/yjy239/HostApplication

#结束语
这里我先要感谢红橙Darren，一年前就是他这篇文章让我打开了Android的新世界大门。

接着我要感谢下面DroidPlugin开发团队的wiki系列文章:
https://github.com/DroidPluginTeam/DroidPlugin/tree/master/DOC/tianweishu

感谢恋猫de小郭的文章：
https://juejin.im/post/59752eb1f265da6c3f70eed9

感谢[神罗天征_39a0](https://www.jianshu.com/u/cd39e3d28c15)：
https://www.jianshu.com/p/5994c2db1557

最后还要感谢RePlugin，Small作者给力的框架和思想，让鄙人学习到了很多东西。


如果有读者耐心的看到这里的读者，我先恭喜你，这片文章已经把绝大部分的插件化框架的思想都容纳了，至少在我眼里，自己改动别人的源码，甚至写属于自己的插件化框架也不在话下。

这篇横向分析插件化框架的分析文章花了整整一个多月的时间，每天晚上，周末两天都在沉浸这篇文章里面。其中大部分的时间都是在阅读新的7.0，8.0源码，复习源码。还有一个坏习惯，我有时候喜欢沉浸到源码里面看看，Android系统为什么是这样写，有时候跑远了，导致这篇文章花的时间太多了。

至于为什么把这篇文章写的这么长不拆开，主要的原因是认为，一开始所构建的插件基础模型是这篇文章的核心，所有的东西都是围绕着这个模型讨论。既然核心主题是由一贯穿，那么我也应该咬咬牙把这篇文章写出来。


















































