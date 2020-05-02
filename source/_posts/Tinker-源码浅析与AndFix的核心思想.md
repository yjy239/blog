---
title: Tinker 源码浅析与AndFix的核心思想
top: false
cover: false
date: 2019-07-18 16:41:02
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android 常用第三方库
---

# 前言
对于现在稍微大一点的工程来说，我们需要一些手段来保证工程在线上的稳定性。毕竟频繁的发版解决问题，这对用户体验来说是十分糟糕的。而且，用户也不一定每一次都跟上最新的版本。因此，有了这种需要线上打补丁的应急方案。因此诞生了热修复的方案。

刚好，这段时间我预研了热修复，顺便把2年前研究过的AndFix，和现在看过的Tinker源码稍微总结一下。

在阅读本文之前，最好阅读过我之前写过的那一篇横向分析Small和RePlugin插件化框架一文。实际上插件化的一部分关键技术就是热修复中的关键技术。而在这里我不会再对重复的内容，再一次剖析源码。

本文将会和大家剖析一下代表腾讯系热修复Tinker源码的核心流程和思想，以及阿里系热修复的思想基础AndFix.

如果阅读了本文，发现什么错漏或者需要交流的，到[https://www.jianshu.com/p/8a0a05c34c43](https://www.jianshu.com/p/8a0a05c34c43)下面互相交流。


## AndFix
让我们先说说AndFix这个轻量级别的热修复框架。AndFix在我看来像是阿里系热修复的起点，不过正因为是起点，所以能支持修复的情况几乎不多，所以热修复就不要使用AndFix。然而里面的思路十分值得我们学习。从这里面我们可以发现一个特点，阿里系的热修复喜欢做native hook，并且对虚拟机有深刻的理解。

聊聊AndFix的核心思想。

### AndFix的修复总览
在AndFix中只有有三个角色十分重要。
- 1.PatchManager 差分包管理
- 2.AndFixManager 热修复管理
- 3.AndFix 热修复native实现类

在聊AndFix之前，有些基础知识必须知道。首先，Java的在运行的时候，会通过通过加载生成的dex.classes文件，找到对应的类并且加载。其过程包含三个阶段：
- 1.dvmResolveClass 
- 2.dvmLinkClass
- 3.dvmInitClass
这里我就不详细展开说了，之后会在虚拟机专栏中，分析类的加载流程。

而阿里系的热修复，喜欢在这些逻辑上思考，弄一些有趣的hook。

AndFix的热修复分为三个步骤：
- 1.通过工具生成带@MethodReplace的dex.classes差分包。这个注解，是标示着类出现变化的地方
- 2.通过PatchManager 加载差分包
- 3.通过AndFixManager修复两个dex之间差异的类，用差分包代替掉原包中的差异。


### AndFix的细节

#### PatchManager 加载差分包
当AndFix尝试着通过PatchManager 读取差分包的时候。将会调用如下方法。
```
/**
	 * load specific patch
	 * 
	 * @param patch
	 *            patch
	 */
	private void loadPatch(Patch patch) {
		Set<String> patchNames = patch.getPatchNames();
		ClassLoader cl;
		List<String> classes;
		for (String patchName : patchNames) {
			if (mLoaders.containsKey("*")) {
				cl = mContext.getClassLoader();
			} else {
				cl = mLoaders.get(patchName);
			}
			if (cl != null) {
				classes = patch.getClasses(patchName);
				mAndFixManager.fix(patch.getFile(), cl, classes);
			}
		}
	}
```

拿到差分包对象的解析对象Patch之后，会调用AndFixManager进行一次fix的修复行为。

接下来的方法就是核心.
```
public synchronized void fix(File file, ClassLoader classLoader,
			List<String> classes) {
		if (!mSupport) {
			return;
		}

		if (!mSecurityChecker.verifyApk(file)) {// security check fail
			return;
		}

		try {
			File optfile = new File(mOptDir, file.getName());
			boolean saveFingerprint = true;
			if (optfile.exists()) {
				// need to verify fingerprint when the optimize file exist,
				// prevent someone attack on jailbreak device with
				// Vulnerability-Parasyte.
				// btw:exaggerated android Vulnerability-Parasyte
				// http://secauo.com/Exaggerated-Android-Vulnerability-Parasyte.html
				if (mSecurityChecker.verifyOpt(optfile)) {
					saveFingerprint = false;
				} else if (!optfile.delete()) {
					return;
				}
			}

			final DexFile dexFile = DexFile.loadDex(file.getAbsolutePath(),
					optfile.getAbsolutePath(), Context.MODE_PRIVATE);

			if (saveFingerprint) {
				mSecurityChecker.saveOptSig(optfile);
			}

			ClassLoader patchClassLoader = new ClassLoader(classLoader) {
				@Override
				protected Class<?> findClass(String className)
						throws ClassNotFoundException {
					Class<?> clazz = dexFile.loadClass(className, this);
					if (clazz == null
							&& className.startsWith("com.alipay.euler.andfix")) {
						return Class.forName(className);// annotation’s class
														// not found
					}
					if (clazz == null) {
						throw new ClassNotFoundException(className);
					}
					return clazz;
				}
			};
			Enumeration<String> entrys = dexFile.entries();
			Class<?> clazz = null;
			while (entrys.hasMoreElements()) {
				String entry = entrys.nextElement();
				if (classes != null && !classes.contains(entry)) {
					continue;// skip, not need fix
				}
				clazz = dexFile.loadClass(entry, patchClassLoader);
				if (clazz != null) {
					fixClass(clazz, classLoader);
				}
			}
		} catch (IOException e) {
			Log.e(TAG, "pacth", e);
		}
	}
```

这里面，我分为三段聊聊。
- 1.AndFixManager将会校验当前的差分包是否合法。
- 2.调用DexFile.loadDex 来加载借助工具生成的差分包中的差分的classes.dex文件，把dex文件加载到内存。
- 3.生成一个classLoader，用来查找差分包生成dexFile中的类。借助dexFile获取内部所有的类名，开始循环差分包中包含的类。最后找到差分包和原包对应的类文件，调用fixClass尝试修复。

实际上在这个过程中，差分包实际上会通过@MehodReplace的注解方式，找到类中不一样的方法，并且注解。并把不一样的类文件打入差分包中。

因此，从这里面，可以发现实际上AndFix是在比对差分包中的类，和原来包中的类的差异性。


#### 通过AndFixManager修复两个dex之间差异的类
```
private void fixClass(Class<?> clazz, ClassLoader classLoader) {
		Method[] methods = clazz.getDeclaredMethods();
		MethodReplace methodReplace;
		String clz;
		String meth;
		for (Method method : methods) {
			methodReplace = method.getAnnotation(MethodReplace.class);
			if (methodReplace == null)
				continue;
			clz = methodReplace.clazz();
			meth = methodReplace.method();
			if (!isEmpty(clz) && !isEmpty(meth)) {
				replaceMethod(classLoader, clz, meth, method);
			}
		}
	}
```
这里面是从差分包中获取class中对应的加了@MethodReplace的方法。调用replace的方法，把原来的方法替代掉。

```
private void replaceMethod(ClassLoader classLoader, String clz,
			String meth, Method method) {
		try {
			String key = clz + "@" + classLoader.toString();
			Class<?> clazz = mFixedClass.get(key);
			if (clazz == null) {// class not load
				Class<?> clzz = classLoader.loadClass(clz);
				// initialize target class
				clazz = AndFix.initTargetClass(clzz);
			}
			if (clazz != null) {// initialize class OK
				mFixedClass.put(key, clazz);
				Method src = clazz.getDeclaredMethod(meth,
						method.getParameterTypes());
				AndFix.addReplaceMethod(src, method);
			}
		} catch (Exception e) {
			Log.e(TAG, "replaceMethod", e);
		}
	}
```

能看到接下来就是替换方法的核心逻辑。

这里分为两步：
- 1.当前的class发现又在差分包中，但是没有在缓存中，说明还有没有初始化这个class里面的属性，需要一次initTargetClass。
- 2.当已经初始化好了，开始执行方法替换。


#### AndFix初始化要替换的Class中的属性
在init的时候会调用这个方法，获取class里面所有的属性调用setFieldFlag。
```
private static void initFields(Class<?> clazz) {
		Field[] srcFields = clazz.getDeclaredFields();
		for (Field srcField : srcFields) {
			Log.d(TAG, "modify " + clazz.getName() + "." + srcField.getName()
					+ " flag:");
			setFieldFlag(srcField);
		}
	}
```
```
static void setFieldFlag(JNIEnv* env, jclass clazz, jobject field) {
	if (isArt) {
		art_setFieldFlag(env, field);
	} else {
		dalvik_setFieldFlag(env, field);
	}
}
```
而这里则是分别按照是否是Art虚拟机来判断(判断标准是获取虚拟机的Version是否是2)。接着按照art或者dalvik虚拟机处理这些属性。

我们只看art_setFieldFlag的7.0版本(AndFix也只兼容到7.0)。
```
void setFieldFlag_7_0(JNIEnv* env, jobject field) {
	art::mirror::ArtField* artField =
			(art::mirror::ArtField*) env->FromReflectedField(field);
	artField->access_flags_ = artField->access_flags_ & (~0x0002) | 0x0001;
	LOGD("setFieldFlag_7_0: %d ", artField->access_flags_);
}
```
这一段代码的意义就有点特殊，本质上是要把当前的属性全部转化为public的方法
这里涉及到ArtField access_flags_的含义:
- 1. ACC_PUBLIC 0x0001
- 2.ACC_PRIVATE 0x0002
- 3.ACC_PROTECTED 0x0004
- 4.ACC_STATIC 0x0008
- 5.ACC_FINAL 0x0010
- 6.ACC_VOLATILE 0x0040
- 6.ACC_TRANSIENT 0x0080
- 6.ACC_SYNTHENTIC 0x1000
- 6.ACC_ENUM 0x4000

能看到，在这里改变了最后的一位，使其变成public属性，可以让其他类访问。

#### AndFix执行替换
```
void replace_7_0(JNIEnv* env, jobject src, jobject dest) {
	art::mirror::ArtMethod* smeth =
			(art::mirror::ArtMethod*) env->FromReflectedMethod(src);

	art::mirror::ArtMethod* dmeth =
			(art::mirror::ArtMethod*) env->FromReflectedMethod(dest);

//	reinterpret_cast<art::mirror::Class*>(smeth->declaring_class_)->class_loader_ =
//			reinterpret_cast<art::mirror::Class*>(dmeth->declaring_class_)->class_loader_; //for plugin classloader
	reinterpret_cast<art::mirror::Class*>(dmeth->declaring_class_)->clinit_thread_id_ =
			reinterpret_cast<art::mirror::Class*>(smeth->declaring_class_)->clinit_thread_id_;
	reinterpret_cast<art::mirror::Class*>(dmeth->declaring_class_)->status_ =
			reinterpret_cast<art::mirror::Class*>(smeth->declaring_class_)->status_ -1;
	//for reflection invoke
	reinterpret_cast<art::mirror::Class*>(dmeth->declaring_class_)->super_class_ = 0;

	smeth->declaring_class_ = dmeth->declaring_class_;
	smeth->access_flags_ = dmeth->access_flags_  | 0x0001;
	smeth->dex_code_item_offset_ = dmeth->dex_code_item_offset_;
	smeth->dex_method_index_ = dmeth->dex_method_index_;
	smeth->method_index_ = dmeth->method_index_;
	smeth->hotness_count_ = dmeth->hotness_count_;

	smeth->ptr_sized_fields_.dex_cache_resolved_methods_ =
			dmeth->ptr_sized_fields_.dex_cache_resolved_methods_;
	smeth->ptr_sized_fields_.dex_cache_resolved_types_ =
			dmeth->ptr_sized_fields_.dex_cache_resolved_types_;

	smeth->ptr_sized_fields_.entry_point_from_jni_ =
			dmeth->ptr_sized_fields_.entry_point_from_jni_;
	smeth->ptr_sized_fields_.entry_point_from_quick_compiled_code_ =
			dmeth->ptr_sized_fields_.entry_point_from_quick_compiled_code_;

	LOGD("replace_7_0: %d , %d",
			smeth->ptr_sized_fields_.entry_point_from_quick_compiled_code_,
			dmeth->ptr_sized_fields_.entry_point_from_quick_compiled_code_);

}
```

可以看到，实际上对于虚拟机来说，所有的方法都是ArtMethods。此时传递进来补丁包中的方法，和原来class中的方法，把方法的指针指向补丁包就完成了修复方法中的内容。

实际上其思想很简单,如下图所示：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-d2283459c8d007f4.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


那么确定就很明显了，为什么AndFix的兼容性这么差。很大的原因是，自己拷贝了ArtMethod的结构体，让方法强转为这个对象之后，把结构体里面的内容替换了。但是别忘了这是开源的，万一厂商修改了这个结构体，那就前功尽弃了。

而且还有一个很大的问题，因为是方法比对和替换，当类出现较大的变化时候，如增加内部类，增加方法等等都会造成修正失败。实际上，这种修复方式就是热替换修复的限制。更不用说增加新的类，增加Android资源了。

总结一句话，热替换修复实际上支持修改方法中的逻辑，并且不涉及新的资源。

很快，这种方式由于支持的场景十分有限，开始诞生了新方案。最出名，支持面最广的如Sophix，Tinker,Amgo。

这里就扒一扒Tinker的源码。

## Tinker
Tinker作为腾讯重磅推出的热修复框架自然有其道理，因为它不想AndFix一样，大量的机型不适配。为了避免出现AndFix的问题，Tinker并没有采用AndFix一样热替换的思路，而是使用冷启动修复的方式。
这里有一张神图
![image.png](https://upload-images.jianshu.io/upload_images/9880421-0785669ab5f8f616.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
这里面显示了世面上热修复支持的功能，以及涉及到的技术。

接下来就以Tinker为例子聊聊，现在热修复的原理。然而我将不会过于详细解读源码，因为很多技术都是在我的插件化框架中已经聊过了。

### Tinker角色重要总览
- 1.TinkerAplication
Tinker启动时，必要的环境，继承于Application，以及修复dex。

- 2.TinkerLoader
Tinker 修复的执行者

- 3.TinkerDexLoader
Tinker 修复工程代码执行者,本质上就是修复dex文件

- 4.TinkerResourceLoader
Tinker 修复工程中的资源文件的执行者

- 5.TinkerSoLoader
Tinker 修复工程中so的执行者。

这些角色分别对应上图中热修复几个的功能模块。接下来我们将围绕着这几个角色解析源码。作为总览先给出这几个类关系的UML的图。
![Tinker Loader.png](https://upload-images.jianshu.io/upload_images/9880421-9b91d34239ed68bc.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到的是TinkerLoader是通过tryLoad的方法来对每一种修复对应的Loader进行检测执行。

### Tinker 使用浏览
老规矩，先看看Tinker的Demo是怎么使用的。首先让工程的AndroidMainfest的application指向如下：
```
<application
        android:name=".app.SampleApplication"
```

接着创建SampleApplicationLike，继承于DefaultApplicationLike。并且把Application的逻辑移动进来。如下所示:
```
@DefaultLifeCycle(application = "tinker.sample.android.app.SampleApplication",
                  flags = ShareConstants.TINKER_ENABLE_ALL,
                  loadVerifyFlag = false)
public class SampleApplicationLike extends DefaultApplicationLike {
    private static final String TAG = "Tinker.SampleApplicationLike";

    public SampleApplicationLike(Application application, int tinkerFlags, boolean tinkerLoadVerifyFlag,
                                 long applicationStartElapsedTime, long applicationStartMillisTime, Intent tinkerResultIntent) {
        super(application, tinkerFlags, tinkerLoadVerifyFlag, applicationStartElapsedTime, applicationStartMillisTime, tinkerResultIntent);
    }

    /**
     * install multiDex before install tinker
     * so we don't need to put the tinker lib classes in the main dex
     *
     * @param base
     */
    @TargetApi(Build.VERSION_CODES.ICE_CREAM_SANDWICH)
    @Override
    public void onBaseContextAttached(Context base) {
        super.onBaseContextAttached(base);
        //you must install multiDex whatever tinker is installed!
        MultiDex.install(base);

        SampleApplicationContext.application = getApplication();
        SampleApplicationContext.context = getApplication();
        TinkerManager.setTinkerApplicationLike(this);

        TinkerManager.initFastCrashProtect();
        //should set before tinker is installed
        TinkerManager.setUpgradeRetryEnable(true);

        //optional set logIml, or you can use default debug log
        TinkerInstaller.setLogIml(new MyLogImp());

        //installTinker after load multiDex
        //or you can put com.tencent.tinker.** to main dex
        TinkerManager.installTinker(this);
        Tinker tinker = Tinker.with(getApplication());
    }

    @TargetApi(Build.VERSION_CODES.ICE_CREAM_SANDWICH)
    public void registerActivityLifecycleCallbacks(Application.ActivityLifecycleCallbacks callback) {
        getApplication().registerActivityLifecycleCallbacks(callback);
    }

}
```

当我们下载完一个补丁包之后，要去按照的时候，要调用该方法:
```
TinkerInstaller.onReceiveUpgradePatch(getApplicationContext(), Environment.getExternalStorageDirectory().getAbsolutePath() + "/patch_signed_7zip.apk");
```

这就是Tinker的基本用法。多的也就不展开说明，来聊聊TinkerApplication构建了一个什么环境.

### TinkerApplication
```
public class SampleApplication extends TinkerApplication {
    public SampleApplication() {
        super(7, "tinker.sample.android.app.SampleApplicationLike", "com.tencent.tinker.loader.TinkerLoader", false);
    }
}
```

能看到在案例中SampleApplication 传入了ApplicationLike的类名以及Tinker热修复加载类名。看到这样设计，我们就能猜到，TinkerApplication将会反射SampleApplicationLike对应的onBaseContextAttached以及onCreate的方法。

同时TinkerApplication，也给予我们自定义自己ApplicationLike和修复加载类的余地。

既然是这样，接下来看看Application生命周期中，attachBaseContext和onCreate都分别做了什么？

#### attachBaseContext
看看attachBaseContext的工作
```
@Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        Thread.setDefaultUncaughtExceptionHandler(new TinkerUncaughtHandler(this));
        onBaseContextAttached(base);
    }

private void onBaseContextAttached(Context base) {
        try {
            applicationStartElapsedTime = SystemClock.elapsedRealtime();
            applicationStartMillisTime = System.currentTimeMillis();
//反射tryLoad方法
            loadTinker();
            ensureDelegate();
            invokeAppLikeOnBaseContextAttached(applicationLike, base);
            //reset save mode
            if (useSafeMode) {
                ShareTinkerInternals.setSafeModeCount(this, 0);
            }
        } catch (TinkerRuntimeException e) {
            throw e;
        } catch (Throwable thr) {
            throw new TinkerRuntimeException(thr.getMessage(), thr);
        }
    }
```
能看到实际上在Application中最先回调的attachBaseContext的绑定Context方法中，做了如下的事情

- 1.Tinker会注册一个全局的异常捕捉，专门捕捉Tinker修复时候的TinkerUncaughtHandler异常。并且生成异常日志，名字为tinker_last_crash。如有需要，我们可以把异常日志上传了。

- 2.会反射TaskLoader的类对象，并且调用其tryLoad的方法，尝试加载所有的补丁包。

- 3.反射实例化从上面传下来的ApplicationLike对象，并且调用其onBaseContextAttached方法。

- 4.最后判断是否打开安全模式。该模式的作用是，当Tinker修复超过了3次失败，说明Tinker出现不可避免的异常，需要关闭Tinker修复的功能。

#### onCreate
```
    @Override
    public void onCreate() {
        super.onCreate();
        try {
            ensureDelegate();
            try {
                ComponentHotplug.ensureComponentHotplugInstalled(this);
            } catch (UnsupportedEnvironmentException e) {
                throw new TinkerRuntimeException("failed to make sure that ComponentHotplug logic is fine.", e);
            }
            invokeAppLikeOnCreate(applicationLike);
        } catch (TinkerRuntimeException e) {
            throw e;
        } catch (Throwable thr) {
            throw new TinkerRuntimeException(thr.getMessage(), thr);
        }
    }
```
onCreate的方法，最主要做的事情就是，反射Activity的启动流程中必要的系统类，为后续的加载新增资源，新增Activity等热插件做准备。

最后反射ApplicationLike的onCreate的方法。

为什么要这么设计呢？实际上Tinker是这么考虑的，如果直接开放Application给用户使用，万一异常是修复是在Application中怎么办？还没有走到修复环节就崩溃又怎么办？因此Tinker做了一个ApplicationLike的类，里面会被Application的生命周期一一回调到相同的方法中。

### TinkerLoader
根据上面的时序图，能够发现TinkerLoader将会通过一个tryLoad来一次检测每一种修复加载器是否修复完成，并且会保留一个Intent全局，确认当前Tinker修复状态是否成功，或者说在哪一步出现了问题。

可以说整个Tinker的核心机制就在这个tryLoader中，只要弄懂了这个逻辑，Tinker绝大部分的修复原理就明白了。方法十分长，我们把它拆解出来分析一下。这里大致分为4个步骤:
- 1.读取tinker配置文件中的信息，确认是否需要修复。
- 2.使用TinkerDexLoader检测是否已经修复完毕。
- 3.使用TinkerSoLoader检查So文件是否修复完毕。
- 4.使用TinkerResourcesLoader检查资源文件是否修复完毕。
- 5.TinkerDexLoader调用loadTinkerJars修复dex文件和so文件。
- 6.TinkerResourcesLoader调用loadTinkerResources修复资源文件。

#### 检测补丁包PatchInfo的合法性以及Tinker内置的标志位
```
private void tryLoadPatchFilesInternal(TinkerApplication app, Intent resultIntent) {
        final int tinkerFlag = app.getTinkerFlags();

        if (!ShareTinkerInternals.isTinkerEnabled(tinkerFlag)) {
            Log.w(TAG, "tryLoadPatchFiles: tinker is disable, just return");
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_DISABLE);
            return;
        }
        if (ShareTinkerInternals.isInPatchProcess(app)) {
            Log.w(TAG, "tryLoadPatchFiles: we don't load patch with :patch process itself, just return");
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_DISABLE);
            return;
        }
        //tinker
        File patchDirectoryFile = SharePatchFileUtil.getPatchDirectory(app);
        if (patchDirectoryFile == null) {
            Log.w(TAG, "tryLoadPatchFiles:getPatchDirectory == null");
            //treat as not exist
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_DIRECTORY_NOT_EXIST);
            return;
        }
        String patchDirectoryPath = patchDirectoryFile.getAbsolutePath();

        //check patch directory whether exist
        if (!patchDirectoryFile.exists()) {
            Log.w(TAG, "tryLoadPatchFiles:patch dir not exist:" + patchDirectoryPath);
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_DIRECTORY_NOT_EXIST);
            return;
        }

        //tinker/patch.info
        File patchInfoFile = SharePatchFileUtil.getPatchInfoFile(patchDirectoryPath);

        //check patch info file whether exist
        if (!patchInfoFile.exists()) {
            Log.w(TAG, "tryLoadPatchFiles:patch info not exist:" + patchInfoFile.getAbsolutePath());
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_INFO_NOT_EXIST);
            return;
        }
        //old = 641e634c5b8f1649c75caf73794acbdf
        //new = 2c150d8560334966952678930ba67fa8
        File patchInfoLockFile = SharePatchFileUtil.getPatchInfoLockFile(patchDirectoryPath);

        patchInfo = SharePatchInfo.readAndCheckPropertyWithLock(patchInfoFile, patchInfoLockFile);
        if (patchInfo == null) {
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_INFO_CORRUPTED);
            return;
        }

        final boolean isProtectedApp = patchInfo.isProtectedApp;
        resultIntent.putExtra(ShareIntentUtil.INTENT_IS_PROTECTED_APP, isProtectedApp);

        String oldVersion = patchInfo.oldVersion;
        String newVersion = patchInfo.newVersion;
        String oatDex = patchInfo.oatDir;

        if (oldVersion == null || newVersion == null || oatDex == null) {
            //it is nice to clean patch
            Log.w(TAG, "tryLoadPatchFiles:onPatchInfoCorrupted");
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_INFO_CORRUPTED);
            return;
        }

        boolean mainProcess = ShareTinkerInternals.isInMainProcess(app);
        boolean isRemoveNewVersion = patchInfo.isRemoveNewVersion;

        // So far new version is not loaded in main process and other processes.
        // We can remove new version directory safely.
        if (mainProcess && isRemoveNewVersion) {
            Log.w(TAG, "found clean patch mark and we are in main process, delete patch file now.");
            String patchName = SharePatchFileUtil.getPatchVersionDirectory(newVersion);
            if (patchName != null) {
                String patchVersionDirFullPath = patchDirectoryPath + "/" + patchName;
                SharePatchFileUtil.deleteDir(patchVersionDirFullPath);
                if (oldVersion.equals(newVersion)) {
                    // !oldVersion.equals(newVersion) means new patch is applied, just fall back to old one in that case.
                    // Or we will set oldVersion and newVersion to empty string to clean patch.
                    oldVersion = "";
                }
                newVersion = oldVersion;
                patchInfo.oldVersion = oldVersion;
                patchInfo.newVersion = newVersion;
                patchInfo.isRemoveNewVersion = false;
                SharePatchInfo.rewritePatchInfoFileWithLock(patchInfoFile, patchInfo, patchInfoLockFile);
                ShareTinkerInternals.killProcessExceptMain(app);

                ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_DIRECTORY_NOT_EXIST);
                return;
            }
        }

        resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_OLD_VERSION, oldVersion);
        resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_NEW_VERSION, newVersion);

        boolean versionChanged = !(oldVersion.equals(newVersion));
        boolean oatModeChanged = oatDex.equals(ShareConstants.CHANING_DEX_OPTIMIZE_PATH);
        oatDex = ShareTinkerInternals.getCurrentOatMode(app, oatDex);
        resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_OAT_DIR, oatDex);

        String version = oldVersion;
        if (versionChanged && mainProcess) {
            version = newVersion;
        }
        if (ShareTinkerInternals.isNullOrNil(version)) {
            Log.w(TAG, "tryLoadPatchFiles:version is blank, wait main process to restart");
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_INFO_BLANK);
            return;
        }

        //patch-641e634c
        String patchName = SharePatchFileUtil.getPatchVersionDirectory(version);
        if (patchName == null) {
            Log.w(TAG, "tryLoadPatchFiles:patchName is null");
            //we may delete patch info file
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_VERSION_DIRECTORY_NOT_EXIST);
            return;
        }
        //tinker/patch.info/patch-641e634c
        String patchVersionDirectory = patchDirectoryPath + "/" + patchName;

        File patchVersionDirectoryFile = new File(patchVersionDirectory);

        if (!patchVersionDirectoryFile.exists()) {
            Log.w(TAG, "tryLoadPatchFiles:onPatchVersionDirectoryNotFound");
            //we may delete patch info file
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_VERSION_DIRECTORY_NOT_EXIST);
            return;
        }

        //tinker/patch.info/patch-641e634c/patch-641e634c.apk
        final String patchVersionFileRelPath = SharePatchFileUtil.getPatchVersionFile(version);
        File patchVersionFile = (patchVersionFileRelPath != null ? new File(patchVersionDirectoryFile.getAbsolutePath(), patchVersionFileRelPath) : null);

        if (!SharePatchFileUtil.isLegalFile(patchVersionFile)) {
            Log.w(TAG, "tryLoadPatchFiles:onPatchVersionFileNotFound");
            //we may delete patch info file
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_VERSION_FILE_NOT_EXIST);
            return;
        }

        ShareSecurityCheck securityCheck = new ShareSecurityCheck(app);

        int returnCode = ShareTinkerInternals.checkTinkerPackage(app, tinkerFlag, patchVersionFile, securityCheck);
        if (returnCode != ShareConstants.ERROR_PACKAGE_CHECK_OK) {
            Log.w(TAG, "tryLoadPatchFiles:checkTinkerPackage");
            resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_PACKAGE_PATCH_CHECK, returnCode);
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_PACKAGE_CHECK_FAIL);
            return;
        }

        resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_PACKAGE_CONFIG, securityCheck.getPackagePropertiesIfPresent());

....
    }
```
- 1.当Tinker设置了disable的时候，将不会执行下面的所有方法。同时Tinker要保证此时调用修复的方法是在主进程中执行。因为后续的操作都是需要hook当前app进程中一些系统类。这么做是为了避免如RePlugin这种不同进程的插件去使用Tinker修复。这样修复的毫无意义，因为本身作为插件，就能为了能够热插拔。

- 2.接着下面很长一个步骤就是获取tinker/patch.info下面对应每个版本的补丁包配置文件中的信息。这个文件信息的更新点是调用onReceiveUpgradePatch方法的时候。

我们看看patchInfo有什么东西:
```

#from old version:84462d28923d8ea340c3ce27cbac367b to new version:84462d28923d8ea340c3ce27cbac367b
#Wed Jul 17 16:42:59 GMT+08:00 2019
dir=odex
is_protected_app=0
new=84462d28923d8ea340c3ce27cbac367b
old=84462d28923d8ea340c3ce27cbac367b
print=samsung/SM-G955N/dream2lteks\:4.4.2/NRD90M/381180508\:user/release-keys
is_remove_new_version=0
```
最主要做的事情有，告诉tinker接下来要合并的dex目录文件夹在odex下面，新老版本对应的版本号，以及is_remove_new_version是否移除新版本，一旦移除了则把新版本的version清空成老版本的版本号，这个一般的这个标志位都是0对应false。

而这个version是做什么用的呢？在tinker中会管理各种各样的补丁包，而决定去修复什么补丁包，就是由这个version决定去下面哪个版本的文件夹获取对应的补丁包。

![补丁包的管理目录](https://upload-images.jianshu.io/upload_images/9880421-54cc84a4b4307686.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
能看到是取出version的头8位作为标识判断，按照上述代码逻辑，一般情况是按照patch.info获取new的字段中的补丁包。

- 3.获取ShareSecurityCheck 对象。使用checkTinkerPackage检测在asset文件夹中的配置文件。
```
public static int checkTinkerPackage(Context context, int tinkerFlag, File patchFile, ShareSecurityCheck securityCheck) {
        int returnCode = checkSignatureAndTinkerID(context, patchFile, securityCheck);
        if (returnCode == ShareConstants.ERROR_PACKAGE_CHECK_OK) {
            returnCode = checkPackageAndTinkerFlag(securityCheck, tinkerFlag);
        }
        return returnCode;
    }
```
该方法主要是做了这么一件事情，读取asset文件下的配置文件，dex_meta.txt和package_meta.txt两个配置文件。
文件：dex_meta.txt
```
classes.dex,,1bfeb65ee027efc48c86443d52f98595,1bfeb65ee027efc48c86443d52f98595,7f94ef3ab04da09741174c48290e6240,2589377679,1428985330,jar
test.dex,,56900442eb5b7e1de45449d0685e6e00,56900442eb5b7e1de45449d0685e6e00,0,0,0,jar
```
需要合并的dex文件名，实际上是对应下图的这些
![image.png](https://upload-images.jianshu.io/upload_images/9880421-2f0af2b981d470ab.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

![image.png](https://upload-images.jianshu.io/upload_images/9880421-8db45800e5518afa.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到的是，在这一步也仅仅只是校验文件中的dex文件是否合法以及读取里面的内容，因为在打补丁jar包的时候，tinker会生成一个rsa不对称的秘钥，会在这个checkSignatureAndTinkerID中进行一次校验。

文件:package_meta.txt
```
#base package config field
#Wed Jul 17 16:41:29 CST 2019
platform=all
NEW_TINKER_ID=tinker_id_1
TINKER_ID=tinker_id_1
is_protected_app=0
patchMessage=tinker is sample to use
patchVersion=1.0
```
这里面包含了该报名中所有的信息，包的tinker_id以及is_protected_app是否适配加固app，以及补丁包的版本。

把这些都校验结束了，可以对每个修复步骤进行校验是否合法。

####  TinkerDexLoader checkComplete
```
        final boolean isEnabledForDex = ShareTinkerInternals.isTinkerEnabledForDex(tinkerFlag);

        if (isEnabledForDex) {
            //tinker/patch.info/patch-641e634c/dex
            boolean dexCheck = TinkerDexLoader.checkComplete(patchVersionDirectory, securityCheck, oatDex, resultIntent);
            if (!dexCheck) {
                //file not found, do not load patch
                Log.w(TAG, "tryLoadPatchFiles:dex check fail");
                return;
            }
        }
```
这个方法做的事情本质上只有一件，从dex_meta拿到配置文件所有的dex名字，检测每一个dex目录下的dex对应的名字是否是合法文件，并且添加到全局变量LOAD_DEX_LIST中，以及把dex的拆分文件(classesN.dex)添加到classNDexInfo中

#### TinkerSoLoader
```
        final boolean isEnabledForNativeLib = ShareTinkerInternals.isTinkerEnabledForNativeLib(tinkerFlag);

        if (isEnabledForNativeLib) {
            //tinker/patch.info/patch-641e634c/lib
            boolean libCheck = TinkerSoLoader.checkComplete(patchVersionDirectory, securityCheck, resultIntent);
            if (!libCheck) {
                //file not found, do not load patch
                Log.w(TAG, "tryLoadPatchFiles:native lib check fail");
                return;
            }
        }

```

获取so_meta.txt配置文件下，需要更新的so文件是否都是合法文件，如大小不为0之类的。

#### TinkerResourceLoader
```
        //check resource
        final boolean isEnabledForResource = ShareTinkerInternals.isTinkerEnabledForResource(tinkerFlag);
        Log.w(TAG, "tryLoadPatchFiles:isEnabledForResource:" + isEnabledForResource);
        if (isEnabledForResource) {
            boolean resourceCheck = TinkerResourceLoader.checkComplete(app, patchVersionDirectory, securityCheck, resultIntent);
            if (!resourceCheck) {
                //file not found, do not load patch
                Log.w(TAG, "tryLoadPatchFiles:resource check fail");
                return;
            }
        }
        //only work for art platform oat，because of interpret, refuse 4.4 art oat
        //android o use quicken default, we don't need to use interpret mode
        boolean isSystemOTA = ShareTinkerInternals.isVmArt()
            && ShareTinkerInternals.isSystemOTA(patchInfo.fingerPrint)
            && Build.VERSION.SDK_INT >= 21 && !ShareTinkerInternals.isAfterAndroidO();

        resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_SYSTEM_OTA, isSystemOTA);

        //we should first try rewrite patch info file, if there is a error, we can't load jar
        if (mainProcess) {
            if (versionChanged) {
                patchInfo.oldVersion = version;
            }
            if (oatModeChanged) {
                patchInfo.oatDir = oatDex;
                // delete interpret odex
                // for android o, directory change. Fortunately, we don't need to support android o interpret mode any more
                Log.i(TAG, "tryLoadPatchFiles:oatModeChanged, try to delete interpret optimize files");
                SharePatchFileUtil.deleteDir(patchVersionDirectory + "/" + ShareConstants.INTERPRET_DEX_OPTIMIZE_PATH);
            }
        }

        if (!checkSafeModeCount(app)) {
            resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_EXCEPTION, new TinkerRuntimeException("checkSafeModeCount fail"));
            ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_UNCAUGHT_EXCEPTION);
            Log.w(TAG, "tryLoadPatchFiles:checkSafeModeCount fail");
            return;
        }
```

获取res_meta.txt配置文件:
```
resources_out.zip,1230293426,1e7b3c35906aee81af4cc698ede8a50c
pattern:3
resources.arsc
res/*
assets/*
large modify:1
resources.arsc,1e7b3c35906aee81af4cc698ede8a50c,2426865942
add:167
res/drawable-ldrtl-mdpi-v4/abc_ic_ab_back_mtrl_am_alpha.png
```

会获取这个配置文件中的第三个参数作为MD5，进行校验基准。校验成功后，会获取对应的资源文件夹。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-d038df423925f767.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
chakan
查看这个资源补丁包是否合法。最后再调用isResourceCanPatch，初始化资源修复的环境。

初始化资源的修复环境可以看看我一年前写的插件化基础框架一文中，Small修复资源文件的部分。
[插件化基础框架](https://www.jianshu.com/p/d824056f510b)
这里稍微多嘴一下，为什么要Hook AssetManager。

实际上从源码上就知道，如果直接addAssetPath，把新的资源往里面加载，会用一个重大的问题，那就是如果出现重复资源id的时候，会先返回原来已经加载上的资源id，因此需要重新构建AssetManager，并且把补丁包的资源合并到新的AssetManager资源数组的前方。


#### TinkerDexLoader loadTinkerJars
```
      //now we can load patch jar
        if (isEnabledForDex) {
            boolean loadTinkerJars = TinkerDexLoader.loadTinkerJars(app, patchVersionDirectory, oatDex, resultIntent, isSystemOTA, isProtectedApp);

            if (isSystemOTA) {
                // update fingerprint after load success
                patchInfo.fingerPrint = Build.FINGERPRINT;
                patchInfo.oatDir = loadTinkerJars ? ShareConstants.INTERPRET_DEX_OPTIMIZE_PATH : ShareConstants.DEFAULT_DEX_OPTIMIZE_PATH;
                // reset to false
                oatModeChanged = false;

                if (!SharePatchInfo.rewritePatchInfoFileWithLock(patchInfoFile, patchInfo, patchInfoLockFile)) {
                    ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_REWRITE_PATCH_INFO_FAIL);
                    Log.w(TAG, "tryLoadPatchFiles:onReWritePatchInfoCorrupted");
                    return;
                }
                // update oat dir
                resultIntent.putExtra(ShareIntentUtil.INTENT_PATCH_OAT_DIR, patchInfo.oatDir);
            }
            if (!loadTinkerJars) {
                Log.w(TAG, "tryLoadPatchFiles:onPatchLoadDexesFail");
                return;
            }
        }
```

到这一步，Tinker就正式开始修复dex文件和资源文件。更新完之后，会更新一次patch.info文件。其核心方法如下：
```
public static boolean loadTinkerJars(final TinkerApplication application, String directory, String oatDir, Intent intentResult, boolean isSystemOTA, boolean isProtectedApp) {
        if (LOAD_DEX_LIST.isEmpty() && classNDexInfo.isEmpty()) {
            Log.w(TAG, "there is no dex to load");
            return true;
        }

        BaseDexClassLoader classLoader = (BaseDexClassLoader) TinkerDexLoader.class.getClassLoader();
        if (classLoader != null) {
            Log.i(TAG, "classloader: " + classLoader.toString());
        } else {
            Log.e(TAG, "classloader is null");
            ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_VERSION_DEX_CLASSLOADER_NULL);
            return false;
        }
        String dexPath = directory + "/" + DEX_PATH + "/";

        ArrayList<File> legalFiles = new ArrayList<>();

        for (ShareDexDiffPatchInfo info : LOAD_DEX_LIST) {
            //for dalvik, ignore art support dex
            if (isJustArtSupportDex(info)) {
                continue;
            }

            String path = dexPath + info.realName;
            File file = new File(path);

            if (application.isTinkerLoadVerifyFlag()) {
                long start = System.currentTimeMillis();
                String checkMd5 = getInfoMd5(info);
                if (!SharePatchFileUtil.verifyDexFileMd5(file, checkMd5)) {
                    //it is good to delete the mismatch file
                    ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_VERSION_DEX_MD5_MISMATCH);
                    intentResult.putExtra(ShareIntentUtil.INTENT_PATCH_MISMATCH_DEX_PATH,
                        file.getAbsolutePath());
                    return false;
                }
                Log.i(TAG, "verify dex file:" + file.getPath() + " md5, use time: " + (System.currentTimeMillis() - start));
            }
            legalFiles.add(file);
        }
        // verify merge classN.apk
        if (isVmArt && !classNDexInfo.isEmpty()) {
            File classNFile = new File(dexPath + ShareConstants.CLASS_N_APK_NAME);
            long start = System.currentTimeMillis();

            if (application.isTinkerLoadVerifyFlag()) {
                for (ShareDexDiffPatchInfo info : classNDexInfo) {
                    if (!SharePatchFileUtil.verifyDexFileMd5(classNFile, info.rawName, info.destMd5InArt)) {
                        ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_VERSION_DEX_MD5_MISMATCH);
                        intentResult.putExtra(ShareIntentUtil.INTENT_PATCH_MISMATCH_DEX_PATH,
                            classNFile.getAbsolutePath());
                        return false;
                    }
                }
            }
            Log.i(TAG, "verify dex file:" + classNFile.getPath() + " md5, use time: " + (System.currentTimeMillis() - start));

            legalFiles.add(classNFile);
        }
        File optimizeDir = new File(directory + "/" + oatDir);

        if (isSystemOTA) {
            final boolean[] parallelOTAResult = {true};
            final Throwable[] parallelOTAThrowable = new Throwable[1];
            String targetISA;
            try {
                targetISA = ShareTinkerInternals.getCurrentInstructionSet();
            } catch (Throwable throwable) {
                Log.i(TAG, "getCurrentInstructionSet fail:" + throwable);
                // try {
                //     targetISA = ShareOatUtil.getOatFileInstructionSet(testOptDexFile);
                // } catch (Throwable throwable) {
                // don't ota on the front
                deleteOutOfDateOATFile(directory);

                intentResult.putExtra(ShareIntentUtil.INTENT_PATCH_INTERPRET_EXCEPTION, throwable);
                ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_GET_OTA_INSTRUCTION_SET_EXCEPTION);
                return false;
                // }
            }

            deleteOutOfDateOATFile(directory);

            Log.w(TAG, "systemOTA, try parallel oat dexes, targetISA:" + targetISA);
            // change dir
            optimizeDir = new File(directory + "/" + INTERPRET_DEX_OPTIMIZE_PATH);

            TinkerDexOptimizer.optimizeAll(
                legalFiles, optimizeDir, true, targetISA,
                new TinkerDexOptimizer.ResultCallback() {
                    long start;

                    @Override
                    public void onStart(File dexFile, File optimizedDir) {
                        start = System.currentTimeMillis();
                        Log.i(TAG, "start to optimize dex:" + dexFile.getPath());
                    }

                    @Override
                    public void onSuccess(File dexFile, File optimizedDir, File optimizedFile) {
                        // Do nothing.
                        Log.i(TAG, "success to optimize dex " + dexFile.getPath() + ", use time " + (System.currentTimeMillis() - start));
                    }

                    @Override
                    public void onFailed(File dexFile, File optimizedDir, Throwable thr) {
                        parallelOTAResult[0] = false;
                        parallelOTAThrowable[0] = thr;
                        Log.i(TAG, "fail to optimize dex " + dexFile.getPath() + ", use time " + (System.currentTimeMillis() - start));
                    }
                }
            );


            if (!parallelOTAResult[0]) {
                Log.e(TAG, "parallel oat dexes failed");
                intentResult.putExtra(ShareIntentUtil.INTENT_PATCH_INTERPRET_EXCEPTION, parallelOTAThrowable[0]);
                ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_OTA_INTERPRET_ONLY_EXCEPTION);
                return false;
            }
        }
        try {
            SystemClassLoaderAdder.installDexes(application, classLoader, optimizeDir, legalFiles, isProtectedApp);
        } catch (Throwable e) {
            Log.e(TAG, "install dexes failed");
            intentResult.putExtra(ShareIntentUtil.INTENT_PATCH_EXCEPTION, e);
            ShareIntentUtil.setIntentReturnCode(intentResult, ShareConstants.ERROR_LOAD_PATCH_VERSION_DEX_LOAD_EXCEPTION);
            return false;
        }

        return true;
    }
```
这里面的分为两步就是先把之前通过checkComplete方法收集起来的dex文件全部收集起来。
- 1.如果当前系统是大于21且虚拟机支持oat则调用TinkerDexOptimizer优化所有的dex文件。
现在大部分的手机都是支持oat的。因此我们看看这个Tinker的Dex优化器做了什么事情。

为了避免阻塞主线程，会为每一个dex创建一个线程去处理。同时在这个方法中，默认是打开拦截模式。
```
public boolean run() {
            try {
                if (!SharePatchFileUtil.isLegalFile(dexFile)) {
                    if (callback != null) {
                        callback.onFailed(dexFile, optimizedDir,
                            new IOException("dex file " + dexFile.getAbsolutePath() + " is not exist!"));
                        return false;
                    }
                }
                if (callback != null) {
                    callback.onStart(dexFile, optimizedDir);
                }
                String optimizedPath = SharePatchFileUtil.optimizedPathFor(this.dexFile, this.optimizedDir);
                if (useInterpretMode) {
                    interpretDex2Oat(dexFile.getAbsolutePath(), optimizedPath);
                } else {
                    DexFile.loadDex(dexFile.getAbsolutePath(), optimizedPath, 0);
                }
                if (callback != null) {
                    callback.onSuccess(dexFile, optimizedDir, new File(optimizedPath));
                }
            } catch (final Throwable e) {
                Log.e(TAG, "Failed to optimize dex: " + dexFile.getAbsolutePath(), e);
                if (callback != null) {
                    callback.onFailed(dexFile, optimizedDir, e);
                    return false;
                }
            }
            return true;
        }
```

因此会走到interpretDex2Oat方法中。
```
private void interpretDex2Oat(String dexFilePath, String oatFilePath) throws IOException {
            // add process lock for interpret mode
            final File oatFile = new File(oatFilePath);
            if (!oatFile.exists()) {
                oatFile.getParentFile().mkdirs();
            }

            File lockFile = new File(oatFile.getParentFile(), INTERPRET_LOCK_FILE_NAME);
            ShareFileLockHelper fileLock = null;
            try {
                fileLock = ShareFileLockHelper.getFileLock(lockFile);

                final List<String> commandAndParams = new ArrayList<>();
                commandAndParams.add("dex2oat");
                // for 7.1.1, duplicate class fix
                if (Build.VERSION.SDK_INT >= 24) {
                    commandAndParams.add("--runtime-arg");
                    commandAndParams.add("-classpath");
                    commandAndParams.add("--runtime-arg");
                    commandAndParams.add("&");
                }
                commandAndParams.add("--dex-file=" + dexFilePath);
                commandAndParams.add("--oat-file=" + oatFilePath);
                commandAndParams.add("--instruction-set=" + targetISA);
                if (Build.VERSION.SDK_INT > 25) {
                    commandAndParams.add("--compiler-filter=quicken");
                } else {
                    commandAndParams.add("--compiler-filter=interpret-only");
                }

                final ProcessBuilder pb = new ProcessBuilder(commandAndParams);
                pb.redirectErrorStream(true);
                final Process dex2oatProcess = pb.start();
                StreamConsumer.consumeInputStream(dex2oatProcess.getInputStream());
                StreamConsumer.consumeInputStream(dex2oatProcess.getErrorStream());
                try {
                    final int ret = dex2oatProcess.waitFor();
                    if (ret != 0) {
                        throw new IOException("dex2oat works unsuccessfully, exit code: " + ret);
                    }
                } catch (InterruptedException e) {
                    throw new IOException("dex2oat is interrupted, msg: " + e.getMessage(), e);
                }
            } finally {
                try {
                    if (fileLock != null) {
                        fileLock.close();
                    }
                } catch (IOException e) {
                    Log.w(TAG, "release interpret Lock error", e);
                }
            }
        }
    }
```
能看见此时Tinker构建了dex2oat的命令，把优化行为交给系统去完成，把优化有的dex保存到odex中。此时会fork一个子进程，并且阻塞当前线程知道任务完成为止。当然不管这个是时候是否已经完成了oat的优化，Tinker会继续往下走，执行合并dex的方法。

为了让下一次合并能够合并到优化后的dex，这个时候会去修改patch.info中dex的存放目录为odex。因此当下次启动的时候，会依据上图的patch.info去加载已经是优化好了dex。

这实际上这是Tinker的对启动速度的妥协，如果能够等待oat生成去加载那是极好，但是这样会造成启动速度会几何倍数的减慢，这是任何一个有点规模的App都不能容忍的。



- 2.接着SystemClassLoaderAdder.installDexes去合成新的dex文件。
```
public static void installDexes(Application application, BaseDexClassLoader loader, File dexOptDir, List<File> files, boolean isProtectedApp)
        throws Throwable {
        Log.i(TAG, "installDexes dexOptDir: " + dexOptDir.getAbsolutePath() + ", dex size:" + files.size());

        if (!files.isEmpty()) {
            files = createSortedAdditionalPathEntries(files);
            ClassLoader classLoader = loader;
            if (Build.VERSION.SDK_INT >= 24 && !isProtectedApp) {
                classLoader = AndroidNClassLoader.inject(loader, application);
            }
            //because in dalvik, if inner class is not the same classloader with it wrapper class.
            //it won't fail at dex2opt
            if (Build.VERSION.SDK_INT >= 23) {
                V23.install(classLoader, files, dexOptDir);
            } else if (Build.VERSION.SDK_INT >= 19) {
                V19.install(classLoader, files, dexOptDir);
            } else if (Build.VERSION.SDK_INT >= 14) {
                V14.install(classLoader, files, dexOptDir);
            } else {
                V4.install(classLoader, files, dexOptDir);
            }
            //install done
            sPatchDexCount = files.size();
            Log.i(TAG, "after loaded classloader: " + classLoader + ", dex size:" + sPatchDexCount);

            if (!checkDexInstall(classLoader)) {
                //reset patch dex
                SystemClassLoaderAdder.uninstallPatchDex(classLoader);
                throw new TinkerRuntimeException(ShareConstants.CHECK_DEX_INSTALL_FAIL);
            }
        }
    }
```
核心方法V23.install，其核心原理也在我写的:[插件化基础框架](https://www.jianshu.com/p/d824056f510b)一文中有涉及。这里采用的是保守的class合并方式。反射DexPathList 中的Element数组，并且把补丁包合并到数组前方，让查找的时候骗过系统，去读取补丁包对应的类。

AndroidNClassLoader.inject这个方法我暂时不确定，应该是处理instance run的问题。哪个哥们熟悉可以留言交流。

#### TinkerResourceLoader loadTinkerResources
```
        //now we can load patch resource
        if (isEnabledForResource) {
            boolean loadTinkerResources = TinkerResourceLoader.loadTinkerResources(app, patchVersionDirectory, resultIntent);
            if (!loadTinkerResources) {
                Log.w(TAG, "tryLoadPatchFiles:onPatchLoadResourcesFail");
                return;
            }
        }

        // Init component hotplug support.
        if (isEnabledForDex && isEnabledForResource) {
            ComponentHotplug.install(app, securityCheck);
        }

        // Before successfully exit, we should update stored version info and kill other process
        // to make them load latest patch when we first applied newer one.
        if (mainProcess && versionChanged) {
            //update old version to new
            if (!SharePatchInfo.rewritePatchInfoFileWithLock(patchInfoFile, patchInfo, patchInfoLockFile)) {
                ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_PATCH_REWRITE_PATCH_INFO_FAIL);
                Log.w(TAG, "tryLoadPatchFiles:onReWritePatchInfoCorrupted");
                return;
            }

            ShareTinkerInternals.killProcessExceptMain(app);
        }

        //all is ok!
        ShareIntentUtil.setIntentReturnCode(resultIntent, ShareConstants.ERROR_LOAD_OK);
        Log.i(TAG, "tryLoadPatchFiles: load end, ok!");
        return;
```
这一段做了2件事情，loadTinkerResources调用TinkerResourcePatcher.monkeyPatchExistingResources合并资源文件，其原理也在我的写的插件化框架的Small中已经聊过了，甚至举出的方式比它更多。在资源修复中有三种大的方向：
- 1.一种是在App调用系统资源之前，也就是Application最初的attachBaseContext，AssetManager.addAssetPath注入自己的资源包，通过反射生成一个新的AssetManager代替掉原来的.而Tinker采用是这种方式。


- 2.就是hook 原来的AssetMananger，并把补丁包的资源文件和原来的文件合并。这么做的好处的就是能够动态加载资源，但是这样会造成补丁包的资源文件id和源文件的id一致。Sophix采用的方法和Small一致，就是在生成补丁包/插件的时候，注意到AS生成的资源id都是0x7f开头的int形，如Sophix则是修改为0x66开头。

- 3.自己管理资源文件，hook classLoader，返回对应的数据。

举个例子，如R.layout.main_activity的resId是0x7f040019.0x7f代表的是packageId。资源的id为0x04。而0x0019是指main_activity.换句话说，在Type String Pool的0x04项的0x0019的位置就是main_activity这个资源。

这涉及到了C++的源码，之后有机会会在Android重学系列中，慢慢解析一番。

# 总结
实际上到这里Tinker的修复原理就结束了。后面还有Tinker为后续的热插件做了预备处理，这个目的主要是为了修复新增Activity的情况。这种方式我在[插件化基础框架](https://www.jianshu.com/p/d824056f510b)一文中已经很详细的描述其中的原理，这里就不铺开描述了。

如果使用插件化，就不要使用Tinker，虽然它实现了部分功能，但是hook点有点多，不稳定。如果有这方面需求，还是试试看现在腾讯号称0hook的[Shadow](https://github.com/Tencent/Shadow)吧,在RePlugin社区观察了一段时间，发现确实不活跃，加之现在又有了更好的设计，我也不推荐RePlugin了。

关于Shadow的源码，有机会再和大家聊聊吧。
