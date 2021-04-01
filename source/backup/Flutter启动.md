# Flutter Application初始化启动入口
```java
FlutterMain.startInitialization(this);
```


## 1. FlutterMain startInitialization
```java
  public static void startInitialization(@NonNull Context applicationContext) {
    if (isRunningInRobolectricTest) {
      return;
    }
    FlutterLoader.getInstance().startInitialization(applicationContext);
  }
```

```java
  public void startInitialization(@NonNull Context applicationContext, @NonNull Settings settings) {
    // Do not run startInitialization more than once.
    if (this.settings != null) {
      return;
    }
    if (Looper.myLooper() != Looper.getMainLooper()) {
      throw new IllegalStateException("startInitialization must be called on the main thread");
    }

    // Ensure that the context is actually the application context.
    final Context appContext = applicationContext.getApplicationContext();

    this.settings = settings;

    initStartTimestampMillis = SystemClock.uptimeMillis();
    initConfig(appContext);
    VsyncWaiter.getInstance((WindowManager) appContext.getSystemService(Context.WINDOW_SERVICE))
        .init();

    Callable<InitResult> initTask =
        new Callable<InitResult>() {
          @Override
          public InitResult call() {
            ResourceExtractor resourceExtractor = initResources(appContext);

            System.loadLibrary("flutter");

            Executors.newSingleThreadExecutor()
                .execute(
                    new Runnable() {
                      @Override
                      public void run() {
                        FlutterJNI.nativePrefetchDefaultFontManager();
                      }
                    });

            if (resourceExtractor != null) {
              resourceExtractor.waitForCompletion();
            }

            return new InitResult(
                PathUtils.getFilesDir(appContext),
                PathUtils.getCacheDirectory(appContext),
                PathUtils.getDataDirectory(appContext));
          }
        };
    initResultFuture = Executors.newSingleThreadExecutor().submit(initTask);
  }
```
- 1.初始化VsyncWaiter 用于监听Vsync信号
- 2.initResources 初始化资源
- 3.启动单个线程池初始化libflutter.so的动态库
- 4.启动一个线程执行jni的nativePrefetchDefaultFontManager方法 预加载Skia的字体管理器
- 5.等待资源初始化成功后返回


### 2.FlutterLoader initResources
```java
  private ResourceExtractor initResources(@NonNull Context applicationContext) {
    ResourceExtractor resourceExtractor = null;
    if (BuildConfig.DEBUG || BuildConfig.JIT_RELEASE) {
      final String dataDirPath = PathUtils.getDataDirectory(applicationContext);
      final String packageName = applicationContext.getPackageName();
      final PackageManager packageManager = applicationContext.getPackageManager();
      final AssetManager assetManager = applicationContext.getResources().getAssets();
      resourceExtractor =
          new ResourceExtractor(dataDirPath, packageName, packageManager, assetManager);

      // In debug/JIT mode these assets will be written to disk and then
      // mapped into memory so they can be provided to the Dart VM.
      resourceExtractor
          .addResource(fullAssetPathFrom(vmSnapshotData))
          .addResource(fullAssetPathFrom(isolateSnapshotData))
          .addResource(fullAssetPathFrom(DEFAULT_KERNEL_BLOB));

      resourceExtractor.start();
    }
    return resourceExtractor;
  }
```
如果是JIT_RELEASE 模式或者是debug模式，这两个模式都是用于调试的。因此会提前调用AssetManager的open，解压内部压缩的资源。

### 3. 加载libflutter.so的动态库
```cpp
JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
  // Initialize the Java VM.
  fml::jni::InitJavaVM(vm);

  JNIEnv* env = fml::jni::AttachCurrentThread();
  bool result = false;

  // Register FlutterMain.
  result = flutter::FlutterMain::Register(env);
  FML_CHECK(result);

  // Register PlatformView
  result = flutter::PlatformViewAndroid::Register(env);
  FML_CHECK(result);

  // Register VSyncWaiter.
  result = flutter::VsyncWaiterAndroid::Register(env);
  FML_CHECK(result);

  return JNI_VERSION_1_4;
}
```
- 1.FlutterMain::Register FlutterMain注册一些方法到当前的JNI中
- 2.PlatformViewAndroid 注册当前的 JNI_ENV
- 3.VsyncWaiterAndroid 注册当前的JNI_ENV


### 4.FlutterMain::Register
```cpp

bool FlutterMain::Register(JNIEnv* env) {
  static const JNINativeMethod methods[] = {
      {
          .name = "nativeInit",
          .signature = "(Landroid/content/Context;[Ljava/lang/String;Ljava/"
                       "lang/String;Ljava/lang/String;Ljava/lang/String;)V",
          .fnPtr = reinterpret_cast<void*>(&Init),
      },
      {
          .name = "nativeRecordStartTimestamp",
          .signature = "(J)V",
          .fnPtr = reinterpret_cast<void*>(&RecordStartTimestamp),
      },
  };

  jclass clazz = env->FindClass("io/flutter/embedding/engine/FlutterJNI");

  if (clazz == nullptr) {
    return false;
  }

  return env->RegisterNatives(clazz, methods, fml::size(methods)) == 0;
}
```
动态注册了两个方法到到方法表中，一个是FlutterJNI.nativeInit 对应FlutterMain的Init。另一个是FlutterJNI. nativeRecordStartTimestamp对应RecordStartTimestamp。


### 5.PlatformViewAndroid::Register
```cpp
bool PlatformViewAndroid::Register(JNIEnv* env) {
...
  g_flutter_callback_info_class = new fml::jni::ScopedJavaGlobalRef<jclass>(
      env, env->FindClass("io/flutter/view/FlutterCallbackInformation"));
...

  g_flutter_callback_info_constructor = env->GetMethodID(
      g_flutter_callback_info_class->obj(), "<init>",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
...

  g_flutter_jni_class = new fml::jni::ScopedJavaGlobalRef<jclass>(
      env, env->FindClass("io/flutter/embedding/engine/FlutterJNI"));
...
  g_surface_texture_class = new fml::jni::ScopedJavaGlobalRef<jclass>(
      env, env->FindClass("android/graphics/SurfaceTexture"));
...

  g_attach_to_gl_context_method = env->GetMethodID(
      g_surface_texture_class->obj(), "attachToGLContext", "(I)V");

...

  g_update_tex_image_method =
      env->GetMethodID(g_surface_texture_class->obj(), "updateTexImage", "()V");
....

  g_get_transform_matrix_method = env->GetMethodID(
      g_surface_texture_class->obj(), "getTransformMatrix", "([F)V");

...

  g_detach_from_gl_context_method = env->GetMethodID(
      g_surface_texture_class->obj(), "detachFromGLContext", "()V");

...

  return RegisterApi(env);
}
```
实际上就是获取SurfaceTexture的相关Java方法操作缓存jni中

### 6.VsyncWaiterAndroid::Register
```cpp
bool VsyncWaiterAndroid::Register(JNIEnv* env) {
  static const JNINativeMethod methods[] = {{
      .name = "nativeOnVsync",
      .signature = "(JJJ)V",
      .fnPtr = reinterpret_cast<void*>(&OnNativeVsync),
  }};

  jclass clazz = env->FindClass("io/flutter/embedding/engine/FlutterJNI");

  if (clazz == nullptr) {
    return false;
  }

  g_vsync_waiter_class = new fml::jni::ScopedJavaGlobalRef<jclass>(env, clazz);


  g_async_wait_for_vsync_method_ = env->GetStaticMethodID(
      g_vsync_waiter_class->obj(), "asyncWaitForVsync", "(J)V");


  return env->RegisterNatives(clazz, methods, fml::size(methods)) == 0;
}
```
- 1.注册了一个nativeOnVsync jni方法
- 2.获取Java层FlutterJNI的asyncWaitForVsync。之后可以进行回调



# Flutter页面的初始化

```java
  public void onCreate(Bundle savedInstanceState) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
      Window window = activity.getWindow();
      window.addFlags(LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
      window.setStatusBarColor(0x40000000);
      window.getDecorView().setSystemUiVisibility(PlatformPlugin.DEFAULT_SYSTEM_UI);
    }

    String[] args = getArgsFromIntent(activity.getIntent());
    FlutterMain.ensureInitializationComplete(activity.getApplicationContext(), args);

    flutterView = viewFactory.createFlutterView(activity);
    if (flutterView == null) {
      FlutterNativeView nativeView = viewFactory.createFlutterNativeView();
      flutterView = new FlutterView(activity, null, nativeView);
      flutterView.setLayoutParams(matchParent);
      activity.setContentView(flutterView);
      launchView = createLaunchView();
      if (launchView != null) {
        addLaunchView();
      }
    }

    if (loadIntent(activity.getIntent())) {
      return;
    }

    String appBundlePath = FlutterMain.findAppBundlePath();
    if (appBundlePath != null) {
      runBundle(appBundlePath);
    }
  }
```
- 1. FlutterMain.ensureInitializationComplete 保证初始化结束
- 2.初始化一个FlutterNativeView作为flutter的承载体
- 3.runBundle 开始启动flutter应用


## FlutterLoader.ensureInitializationComplete
```java
  public void ensureInitializationComplete(
      @NonNull Context applicationContext, @Nullable String[] args) {
    if (initialized) {
      return;
    }
    if (Looper.myLooper() != Looper.getMainLooper()) {
      throw new IllegalStateException(
          "ensureInitializationComplete must be called on the main thread");
    }
    if (settings == null) {
      throw new IllegalStateException(
          "ensureInitializationComplete must be called after startInitialization");
    }
    try {
      InitResult result = initResultFuture.get();

      List<String> shellArgs = new ArrayList<>();
      shellArgs.add("--icu-symbol-prefix=_binary_icudtl_dat");

      ApplicationInfo applicationInfo = getApplicationInfo(applicationContext);
      shellArgs.add(
          "--icu-native-lib-path="
              + applicationInfo.nativeLibraryDir
              + File.separator
              + DEFAULT_LIBRARY);
      if (args != null) {
        Collections.addAll(shellArgs, args);
      }

      String kernelPath = null;
      if (BuildConfig.DEBUG || BuildConfig.JIT_RELEASE) {
        String snapshotAssetPath = result.dataDirPath + File.separator + flutterAssetsDir;
        kernelPath = snapshotAssetPath + File.separator + DEFAULT_KERNEL_BLOB;
        shellArgs.add("--" + SNAPSHOT_ASSET_PATH_KEY + "=" + snapshotAssetPath);
        shellArgs.add("--" + VM_SNAPSHOT_DATA_KEY + "=" + vmSnapshotData);
        shellArgs.add("--" + ISOLATE_SNAPSHOT_DATA_KEY + "=" + isolateSnapshotData);
      } else {
        shellArgs.add("--" + AOT_SHARED_LIBRARY_NAME + "=" + aotSharedLibraryName);

        shellArgs.add(
            "--"
                + AOT_SHARED_LIBRARY_NAME
                + "="
                + applicationInfo.nativeLibraryDir
                + File.separator
                + aotSharedLibraryName);
      }

      shellArgs.add("--cache-dir-path=" + result.engineCachesPath);
      if (settings.getLogTag() != null) {
        shellArgs.add("--log-tag=" + settings.getLogTag());
      }

      long initTimeMillis = SystemClock.uptimeMillis() - initStartTimestampMillis;

      Bundle bundle = applicationInfo.metaData;
      if (bundle != null) {
        boolean use_embedded_view = bundle.getBoolean("io.flutter.embedded_views_preview");
        if (use_embedded_view) {
          shellArgs.add("--use-embedded-view");
        }
      }

      FlutterJNI.nativeInit(
          applicationContext,
          shellArgs.toArray(new String[0]),
          kernelPath,
          result.appStoragePath,
          result.engineCachesPath,
          initTimeMillis);

      initialized = true;
    } catch (Exception e) {
      Log.e(TAG, "Flutter initialization failed.", e);
      throw new RuntimeException(e);
    }
  }
```
核心还是FlutterJNI.nativeInit，这个方法就是FlutterMain::Init

```cpp
void FlutterMain::Init(JNIEnv* env,
                       jclass clazz,
                       jobject context,
                       jobjectArray jargs,
                       jstring kernelPath,
                       jstring appStoragePath,
                       jstring engineCachesPath) {
  std::vector<std::string> args;
  args.push_back("flutter");
  for (auto& arg : fml::jni::StringArrayToVector(env, jargs)) {
    args.push_back(std::move(arg));
  }
  auto command_line = fml::CommandLineFromIterators(args.begin(), args.end());

  auto settings = SettingsFromCommandLine(command_line);


  flutter::DartCallbackCache::SetCachePath(
      fml::jni::JavaStringToString(env, appStoragePath));

  fml::paths::InitializeAndroidCachesPath(
      fml::jni::JavaStringToString(env, engineCachesPath));

  flutter::DartCallbackCache::LoadCacheFromDisk();

  if (!flutter::DartVM::IsRunningPrecompiledCode() && kernelPath) {
    auto application_kernel_path =
        fml::jni::JavaStringToString(env, kernelPath);

    if (fml::IsFile(application_kernel_path)) {
      settings.application_kernel_asset = application_kernel_path;
    }
  }

  settings.task_observer_add = [](intptr_t key, fml::closure callback) {
    fml::MessageLoop::GetCurrent().AddTaskObserver(key, std::move(callback));
  };

  settings.task_observer_remove = [](intptr_t key) {
    fml::MessageLoop::GetCurrent().RemoveTaskObserver(key);
  };

...


  g_flutter_main.reset(new FlutterMain(std::move(settings)));

  g_flutter_main->SetupObservatoryUriCallback(env);
}

```
- 1.记录资源路径
- 2.生成一个FlutterMain 在全局中，并在FlutterMain中保存了所有的设置信息

### FlutterView初始化
```java
public class FlutterView extends SurfaceView
    implements BinaryMessenger, TextureRegistry, MouseCursorPlugin.MouseCursorViewDelegate 
```
这是一个继承了SurfaceView的状态，扩展了Android和Flutter通道接口BinaryMessenger

```java
  public FlutterView(Context context, AttributeSet attrs, FlutterNativeView nativeView) {
    super(context, attrs);

    Activity activity = getActivity(getContext());
    if (activity == null) {
      throw new IllegalArgumentException("Bad context");
    }

    if (nativeView == null) {
      mNativeView = new FlutterNativeView(activity.getApplicationContext());
    } else {
      mNativeView = nativeView;
    }

    dartExecutor = mNativeView.getDartExecutor();
    flutterRenderer = new FlutterRenderer(mNativeView.getFlutterJNI());
    mIsSoftwareRenderingEnabled = mNativeView.getFlutterJNI().getIsSoftwareRenderingEnabled();
    mMetrics = new ViewportMetrics();
    mMetrics.devicePixelRatio = context.getResources().getDisplayMetrics().density;
    setFocusable(true);
    setFocusableInTouchMode(true);

    mNativeView.attachViewAndActivity(this, activity);

    mSurfaceCallback =
        new SurfaceHolder.Callback() {
          @Override
          public void surfaceCreated(SurfaceHolder holder) {
            assertAttached();
            mNativeView.getFlutterJNI().onSurfaceCreated(holder.getSurface());
          }

          @Override
          public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            assertAttached();
            mNativeView.getFlutterJNI().onSurfaceChanged(width, height);
          }

          @Override
          public void surfaceDestroyed(SurfaceHolder holder) {
            assertAttached();
            mNativeView.getFlutterJNI().onSurfaceDestroyed();
          }
        };
    getHolder().addCallback(mSurfaceCallback);

    mActivityLifecycleListeners = new ArrayList<>();
    mFirstFrameListeners = new ArrayList<>();

    // Create all platform channels
    navigationChannel = new NavigationChannel(dartExecutor);
    keyEventChannel = new KeyEventChannel(dartExecutor);
    lifecycleChannel = new LifecycleChannel(dartExecutor);
    localizationChannel = new LocalizationChannel(dartExecutor);
    platformChannel = new PlatformChannel(dartExecutor);
    systemChannel = new SystemChannel(dartExecutor);
    settingsChannel = new SettingsChannel(dartExecutor);

    PlatformPlugin platformPlugin = new PlatformPlugin(activity, platformChannel);
    addActivityLifecycleListener(
        new ActivityLifecycleListener() {
          @Override
          public void onPostResume() {
            platformPlugin.updateSystemUiOverlays();
          }
        });
    mImm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
    PlatformViewsController platformViewsController =
        mNativeView.getPluginRegistry().getPlatformViewsController();
    mTextInputPlugin =
        new TextInputPlugin(this, new TextInputChannel(dartExecutor), platformViewsController);
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      mMouseCursorPlugin = new MouseCursorPlugin(this, new MouseCursorChannel(dartExecutor));
    } else {
      mMouseCursorPlugin = null;
    }
    mLocalizationPlugin = new LocalizationPlugin(context, localizationChannel);
    androidKeyProcessor = new AndroidKeyProcessor(keyEventChannel, mTextInputPlugin);
    androidTouchProcessor =
        new AndroidTouchProcessor(flutterRenderer, /*trackMotionEvents=*/ false);
    platformViewsController.attachToFlutterRenderer(flutterRenderer);
    mNativeView
        .getPluginRegistry()
        .getPlatformViewsController()
        .attachTextInputPlugin(mTextInputPlugin);
    mNativeView.getFlutterJNI().setLocalizationPlugin(mLocalizationPlugin);

    // Send initial platform information to Dart
    mLocalizationPlugin.sendLocalesToFlutter(getResources().getConfiguration());
    sendUserPlatformSettingsToDart();
  }
```
- 1.创建FlutterNativeView，并绑定到当前的View和Activity
- 2.创建FlutterRender
- 3.创建监听SurfaceView的周期
- 4.生成各种插件，如通信通道，mouse，TextInput


#### 4.FlutterNativeView
```java
  public FlutterNativeView(@NonNull Context context, boolean isBackgroundView) {
    mContext = context;
    mPluginRegistry = new FlutterPluginRegistry(this, context);
    mFlutterJNI = new FlutterJNI();
    mFlutterJNI.addIsDisplayingFlutterUiListener(flutterUiDisplayListener);
    this.dartExecutor = new DartExecutor(mFlutterJNI, context.getAssets());
    mFlutterJNI.addEngineLifecycleListener(new EngineLifecycleListenerImpl());
    attach(this, isBackgroundView);
    assertAttached();
  }
```
- 1.生成FlutterPluginRegistry，系统的FlutterPlugin都要往里面注册，自带MessageChannel
- 2.实例化FlutterJNI
- 3.实例化DartExecutor 自带`flutter/isolate`MessageChannel
- 4.FlutterJNI 的attachToNative 方法
- 5. FlutterJNI 保存PlatformMessageHandler对象。

```java
  private void attach(FlutterNativeView view, boolean isBackgroundView) {
    mFlutterJNI.attachToNative(isBackgroundView);
    dartExecutor.onAttachedToJNI();
  }
```

#### 4.1FlutterJNI.attachToNative

```java
  public void attachToNative(boolean isBackgroundView) {
    ensureRunningOnMainThread();
    ensureNotAttachedToNative();
    nativePlatformViewId = performNativeAttach(this, isBackgroundView);
  }
  public long performNativeAttach(@NonNull FlutterJNI flutterJNI, boolean isBackgroundView) {
    return nativeAttach(flutterJNI, isBackgroundView);
  }

```

实际上就是指c++ platform_view_andrid_jni.cc 的AttachJNI方法.

```cpp
static jlong AttachJNI(JNIEnv* env,
                       jclass clazz,
                       jobject flutterJNI,
                       jboolean is_background_view) {
  fml::jni::JavaObjectWeakGlobalRef java_object(env, flutterJNI);
  auto shell_holder = std::make_unique<AndroidShellHolder>(
      FlutterMain::Get().GetSettings(), java_object, is_background_view);
  if (shell_holder->IsValid()) {
    return reinterpret_cast<jlong>(shell_holder.release());
  } else {
    return 0;
  }
}
```

实例化了一个很重要的对象 `AndroidShellHolder` 这个对象承载了所有Flutter在Android中实现的特性。

### 4.1.1AndroidShellHolder 初始化

```cpp
AndroidShellHolder::AndroidShellHolder(
    flutter::Settings settings,
    fml::jni::JavaObjectWeakGlobalRef java_object,
    bool is_background_view)
    : settings_(std::move(settings)), java_object_(java_object) {
  static size_t shell_count = 1;
  auto thread_label = std::to_string(shell_count++);

  if (is_background_view) {
    thread_host_ = {thread_label, ThreadHost::Type::UI};
  } else {
    thread_host_ = {thread_label, ThreadHost::Type::UI | ThreadHost::Type::GPU |
                                      ThreadHost::Type::IO};
  }

  auto jni_exit_task([key = thread_destruct_key_]() {
    FML_CHECK(pthread_setspecific(key, reinterpret_cast<void*>(1)) == 0);
  });
  thread_host_.ui_thread->GetTaskRunner()->PostTask(jni_exit_task);
  if (!is_background_view) {
    thread_host_.gpu_thread->GetTaskRunner()->PostTask(jni_exit_task);
  }

  fml::WeakPtr<PlatformViewAndroid> weak_platform_view;
  Shell::CreateCallback<PlatformView> on_create_platform_view =
      [is_background_view, java_object, &weak_platform_view](Shell& shell) {
        std::unique_ptr<PlatformViewAndroid> platform_view_android;
        if (is_background_view) {
          platform_view_android = std::make_unique<PlatformViewAndroid>(
              shell,                   // delegate
              shell.GetTaskRunners(),  // task runners
              java_object              // java object handle for JNI interop
          );

        } else {
          platform_view_android = std::make_unique<PlatformViewAndroid>(
              shell,                   // delegate
              shell.GetTaskRunners(),  // task runners
              java_object,             // java object handle for JNI interop
              shell.GetSettings()
                  .enable_software_rendering  // use software rendering
          );
        }
        weak_platform_view = platform_view_android->GetWeakPtr();
        return platform_view_android;
      };

  Shell::CreateCallback<Rasterizer> on_create_rasterizer = [](Shell& shell) {
    return std::make_unique<Rasterizer>(shell, shell.GetTaskRunners());
  };


  fml::MessageLoop::EnsureInitializedForCurrentThread();
  fml::RefPtr<fml::TaskRunner> gpu_runner;
  fml::RefPtr<fml::TaskRunner> ui_runner;
  fml::RefPtr<fml::TaskRunner> io_runner;
  fml::RefPtr<fml::TaskRunner> platform_runner =
      fml::MessageLoop::GetCurrent().GetTaskRunner();
  if (is_background_view) {
    auto single_task_runner = thread_host_.ui_thread->GetTaskRunner();
    gpu_runner = single_task_runner;
    ui_runner = single_task_runner;
    io_runner = single_task_runner;
  } else {
    gpu_runner = thread_host_.gpu_thread->GetTaskRunner();
    ui_runner = thread_host_.ui_thread->GetTaskRunner();
    io_runner = thread_host_.io_thread->GetTaskRunner();
  }
  flutter::TaskRunners task_runners(thread_label,     // label
                                    platform_runner,  // platform
                                    gpu_runner,       // gpu
                                    ui_runner,        // ui
                                    io_runner         // io
  );

  shell_ =
      Shell::Create(task_runners,             // task runners
                    settings_,                // settings
                    on_create_platform_view,  // platform view create callback
                    on_create_rasterizer      // rasterizer create callback
      );

  platform_view_ = weak_platform_view;

  is_valid_ = shell_ != nullptr;

...
}
```

- 1. thread_host_根据设置的掩码，生成不同的线程。如果is_background_view 为false（默认），在这里可以分为3种线程 ui线程，gpu线程，io线程，否则则只生成ui.当然还有一个默认的PlatformThread，默认情况下不会生成，特指Android主线程。每一个Thread中都有一个MessageLooper，Looper中存在一个TaskRunner对象（核心还是借助了Android的ALooper体系，最后通过epoll阻塞等待）

```
  enum Type {
    Platform = 1 << 0,
    UI = 1 << 1,
    GPU = 1 << 2,
    IO = 1 << 3,
  };
```

这个过程中如果PlatformThread没有初始化，就在本线程的tls中创建一个MessageLooper

- 2.创建一个方法指针on_create_platform_view，这个方法指针通过Shell的初始化，回调上来初始化AndroidShellHolder中的PlatformViewAndroid对象
- 3.创建一个方法指针on_create_rasterizer，用于创建rasterizer
- 4.为ThreadHost中获取每一个线程的TaskRunner对象，全部保存到TaskRunners中
- 5.通过Shell::Create方法，传入TaskRunners，on_create_platform_view，settings实例化Shell。无论是iOS还是Android最终都是通过Shell通信到Flutter。


#### 4.1.1.1 Shell::Create Shell的实例化

```cpp
std::unique_ptr<Shell> Shell::Create(
    TaskRunners task_runners,
    Settings settings,
    Shell::CreateCallback<PlatformView> on_create_platform_view,
    Shell::CreateCallback<Rasterizer> on_create_rasterizer) {
  PerformInitializationTasks(settings);

  TRACE_EVENT0("flutter", "Shell::Create");

  auto vm = DartVMRef::Create(settings);
  FML_CHECK(vm) << "Must be able to initialize the VM.";

  auto vm_data = vm->GetVMData();

  return Shell::Create(std::move(task_runners),             //
                       std::move(settings),                 //
                       vm_data->GetIsolateSnapshot(),       // isolate snapshot
                       DartSnapshot::Empty(),               // shared snapshot
                       std::move(on_create_platform_view),  //
                       std::move(on_create_rasterizer),     //
                       std::move(vm)                        //
  );
  
std::unique_ptr<Shell> Shell::Create(
    TaskRunners task_runners,
    Settings settings,
    fml::RefPtr<const DartSnapshot> isolate_snapshot,
    fml::RefPtr<const DartSnapshot> shared_snapshot,
    Shell::CreateCallback<PlatformView> on_create_platform_view,
    Shell::CreateCallback<Rasterizer> on_create_rasterizer,
    DartVMRef vm) {
  PerformInitializationTasks(settings);
...

  fml::AutoResetWaitableEvent latch;
  std::unique_ptr<Shell> shell;
  fml::TaskRunner::RunNowOrPostTask(
      task_runners.GetPlatformTaskRunner(),
      fml::MakeCopyable([&latch,                                          //
                         vm = std::move(vm),                              //
                         &shell,                                          //
                         task_runners = std::move(task_runners),          //
                         settings,                                        //
                         isolate_snapshot = std::move(isolate_snapshot),  //
                         shared_snapshot = std::move(shared_snapshot),    //
                         on_create_platform_view,                         //
                         on_create_rasterizer                             //
  ]() mutable {
        shell = CreateShellOnPlatformThread(std::move(vm),
                                            std::move(task_runners),      //
                                            settings,                     //
                                            std::move(isolate_snapshot),  //
                                            std::move(shared_snapshot),   //
                                            on_create_platform_view,      //
                                            on_create_rasterizer          //
        );
        latch.Signal();
      }));
  latch.Wait();
  return shell;
}
```
- 1.DartVMRef::Create 创建Dart虚拟机
- 2.在Platform线程中执行CreateShellOnPlatformThread，并阻塞等待完成。




##### 4.1.1.1.1 CreateShellOnPlatformThread

```java
std::unique_ptr<Shell> Shell::CreateShellOnPlatformThread(
    DartVMRef vm,
    TaskRunners task_runners,
    Settings settings,
    fml::RefPtr<const DartSnapshot> isolate_snapshot,
    fml::RefPtr<const DartSnapshot> shared_snapshot,
    Shell::CreateCallback<PlatformView> on_create_platform_view,
    Shell::CreateCallback<Rasterizer> on_create_rasterizer) {
  if (!task_runners.IsValid()) {
    FML_LOG(ERROR) << "Task runners to run the shell were invalid.";
    return nullptr;
  }

  auto shell =
      std::unique_ptr<Shell>(new Shell(std::move(vm), task_runners, settings));

  // Create the rasterizer on the GPU thread.
  std::promise<std::unique_ptr<Rasterizer>> rasterizer_promise;
  auto rasterizer_future = rasterizer_promise.get_future();
  fml::TaskRunner::RunNowOrPostTask(
      task_runners.GetGPUTaskRunner(), [&rasterizer_promise,   //
                                        on_create_rasterizer,  //
                                        shell = shell.get()    //
  ]() {
        TRACE_EVENT0("flutter", "ShellSetupGPUSubsystem");
        rasterizer_promise.set_value(on_create_rasterizer(*shell));
      });

  // Create the platform view on the platform thread (this thread).
  auto platform_view = on_create_platform_view(*shell.get());
  if (!platform_view || !platform_view->GetWeakPtr()) {
    return nullptr;
  }

  auto vsync_waiter = platform_view->CreateVSyncWaiter();
...

  std::promise<std::unique_ptr<ShellIOManager>> io_manager_promise;
  auto io_manager_future = io_manager_promise.get_future();
  std::promise<fml::WeakPtr<ShellIOManager>> weak_io_manager_promise;
  auto weak_io_manager_future = weak_io_manager_promise.get_future();
  auto io_task_runner = shell->GetTaskRunners().GetIOTaskRunner();
  fml::TaskRunner::RunNowOrPostTask(
      io_task_runner,
      [&io_manager_promise,                          //
       &weak_io_manager_promise,                     //
       platform_view = platform_view->GetWeakPtr(),  //
       io_task_runner                                //
  ]() {
        TRACE_EVENT0("flutter", "ShellSetupIOSubsystem");
        auto io_manager = std::make_unique<ShellIOManager>(
            platform_view->CreateResourceContext(), io_task_runner);
        weak_io_manager_promise.set_value(io_manager->GetWeakPtr());
        io_manager_promise.set_value(std::move(io_manager));
      });

  // Create the engine on the UI thread.
  std::promise<std::unique_ptr<Engine>> engine_promise;
  auto engine_future = engine_promise.get_future();
  fml::TaskRunner::RunNowOrPostTask(
      shell->GetTaskRunners().GetUITaskRunner(),
      fml::MakeCopyable([&engine_promise,                                 //
                         shell = shell.get(),                             //
                         isolate_snapshot = std::move(isolate_snapshot),  //
                         shared_snapshot = std::move(shared_snapshot),    //
                         vsync_waiter = std::move(vsync_waiter),          //
                         &weak_io_manager_future                          //
  ]() mutable {
        TRACE_EVENT0("flutter", "ShellSetupUISubsystem");
        const auto& task_runners = shell->GetTaskRunners();

        auto animator = std::make_unique<Animator>(*shell, task_runners,
                                                   std::move(vsync_waiter));

        engine_promise.set_value(std::make_unique<Engine>(
            *shell,                       //
            *shell->GetDartVM(),          //
            std::move(isolate_snapshot),  //
            std::move(shared_snapshot),   //
            task_runners,                 //
            shell->GetSettings(),         //
            std::move(animator),          //
            weak_io_manager_future.get()  //
            ));
      }));

  if (!shell->Setup(std::move(platform_view),  //
                    engine_future.get(),       //
                    rasterizer_future.get(),   //
                    io_manager_future.get())   //
  ) {
    return nullptr;
  }

  return shell;
}

```
- 1.在GPU线程中调用`on_create_rasterizer` 初始化 rasterizer(光栅器)
- 2.调用  `on_create_platform_view` 创建PlatformViewAndroid
- 3.调用 PlatformViewAndroid 的CreateVSyncWaiter 创建一个VsyncWaiter 监听Vsync信号
- 4.在IO线程创建一个ShellIOManager
- 5.在UI线程创建一个Engine，并调用Shell的SetUp方法

#### 4.1.1.1.1.1  Rasterizer

```cpp
Rasterizer::Rasterizer(
    TaskRunners task_runners,
    std::unique_ptr<flutter::CompositorContext> compositor_context)
    : Rasterizer(dummy_delegate_,
                 std::move(task_runners),
                 std::move(compositor_context)) {}
```
这个光栅器实际上就是用于处理OpenGL中layer树的合成

##### 4.1.1.1.1.2 PlatformViewAndroid的创建

```cpp
PlatformViewAndroid::PlatformViewAndroid(
    PlatformView::Delegate& delegate,
    flutter::TaskRunners task_runners,
    fml::jni::JavaObjectWeakGlobalRef java_object,
    bool use_software_rendering)
    : PlatformView(delegate, std::move(task_runners)),
      java_object_(java_object),
      android_surface_(AndroidSurface::Create(use_software_rendering)) {

}
```
创建一个AndroidSurface保存在其中。这是一个AndroidSurfaceGL对象，也就是GPUSurfaceGL对象。实际上就是一个nativewindow对象

##### 4.1.1.1.1.3 CreateVSyncWaiter创建

```cpp
std::unique_ptr<VsyncWaiter> PlatformViewAndroid::CreateVSyncWaiter() {
  return std::make_unique<VsyncWaiterAndroid>(task_runners_);
}

VsyncWaiterAndroid::VsyncWaiterAndroid(flutter::TaskRunners task_runners)
    : VsyncWaiter(std::move(task_runners)) {}
```
这是一个VsyncWaiterAndroid对象


##### 4.1.1.1.1.4 ShellIOManager创建

```cpp
ShellIOManager::ShellIOManager(
    sk_sp<GrContext> resource_context,
    fml::RefPtr<fml::TaskRunner> unref_queue_task_runner)
    : resource_context_(std::move(resource_context)),
      resource_context_weak_factory_(
          resource_context_ ? std::make_unique<fml::WeakPtrFactory<GrContext>>(
                                  resource_context_.get())
                            : nullptr),
      unref_queue_(fml::MakeRefCounted<flutter::SkiaUnrefQueue>(
          std::move(unref_queue_task_runner),
          fml::TimeDelta::FromMilliseconds(8))),
      weak_factory_(this) {

}
```

此时会创建GrContext以及SkiaUnrefQueue对象。

##### 4.1.1.1.1.5 Engine创建

```java
Engine::Engine(Delegate& delegate,
               DartVM& vm,
               fml::RefPtr<const DartSnapshot> isolate_snapshot,
               fml::RefPtr<const DartSnapshot> shared_snapshot,
               TaskRunners task_runners,
               Settings settings,
               std::unique_ptr<Animator> animator,
               fml::WeakPtr<IOManager> io_manager)
    : delegate_(delegate),
      settings_(std::move(settings)),
      animator_(std::move(animator)),
      activity_running_(true),
      have_surface_(false),
      image_decoder_(task_runners,
                     vm.GetConcurrentWorkerTaskRunner(),
                     io_manager),
      weak_factory_(this) {
  // Runtime controller is initialized here because it takes a reference to this
  // object as its delegate. The delegate may be called in the constructor and
  // we want to be fully initilazed by that point.
  runtime_controller_ = std::make_unique<RuntimeController>(
      *this,                                 // runtime delegate
      &vm,                                   // VM
      std::move(isolate_snapshot),           // isolate snapshot
      std::move(shared_snapshot),            // shared snapshot
      std::move(task_runners),               // task runners
      std::move(io_manager),                 // io manager
      image_decoder_.GetWeakPtr(),           // image decoder
      settings_.advisory_script_uri,         // advisory script uri
      settings_.advisory_script_entrypoint,  // advisory script entrypoint
      settings_.idle_notification_callback,  // idle notification callback
      settings_.isolate_create_callback,     // isolate create callback
      settings_.isolate_shutdown_callback    // isolate shutdown callback
  );
}
```
engine 就是整个Flutter的运行引起，里面包含了IOManager，taskRunner，虚拟机等总体控制器RuntimeController。

##### 5. RuntimeController 创建

```cpp
RuntimeController::RuntimeController(
    RuntimeDelegate& p_client,
    DartVM* p_vm,
    fml::RefPtr<const DartSnapshot> p_isolate_snapshot,
    fml::RefPtr<const DartSnapshot> p_shared_snapshot,
    TaskRunners p_task_runners,
    fml::WeakPtr<IOManager> p_io_manager,
    fml::WeakPtr<ImageDecoder> p_image_decoder,
    std::string p_advisory_script_uri,
    std::string p_advisory_script_entrypoint,
    std::function<void(int64_t)> idle_notification_callback,
    WindowData p_window_data,
    fml::closure p_isolate_create_callback,
    fml::closure p_isolate_shutdown_callback)
    : client_(p_client),
      vm_(p_vm),
      isolate_snapshot_(std::move(p_isolate_snapshot)),
      shared_snapshot_(std::move(p_shared_snapshot)),
      task_runners_(p_task_runners),
      io_manager_(p_io_manager),
      image_decoder_(p_image_decoder),
      advisory_script_uri_(p_advisory_script_uri),
      advisory_script_entrypoint_(p_advisory_script_entrypoint),
      idle_notification_callback_(idle_notification_callback),
      window_data_(std::move(p_window_data)),
      isolate_create_callback_(p_isolate_create_callback),
      isolate_shutdown_callback_(p_isolate_shutdown_callback) {

  auto strong_root_isolate =
      DartIsolate::CreateRootIsolate(vm_->GetVMData()->GetSettings(),  //
                                     isolate_snapshot_,                //
                                     shared_snapshot_,                 //
                                     task_runners_,                    //
                                     std::make_unique<Window>(this),   //
                                     io_manager_,                      //
                                     image_decoder_,                   //
                                     p_advisory_script_uri,            //
                                     p_advisory_script_entrypoint,     //
                                     nullptr,                          //
                                     isolate_create_callback_,         //
                                     isolate_shutdown_callback_        //
                                     )
          .lock();

...
  root_isolate_ = strong_root_isolate;

  strong_root_isolate->SetReturnCodeCallback([this](uint32_t code) {
    root_isolate_return_code_ = {true, code};
  });

  if (auto* window = GetWindowIfAvailable()) {
    tonic::DartState::Scope scope(strong_root_isolate);
    window->DidCreateIsolate();
...
  } else {
..
  }

...
}

```
- 1.一旦运行环境运行起来，就立即通过CreateRootIsolate启动过root ioslate
- 2. 一旦初始化成功根 isolate 就从 root ioslate获取Window对象


#### 6. CreateRootIsolate 创建 root ioslate

```cpp
std::weak_ptr<DartIsolate> DartIsolate::CreateRootIsolate(
    const Settings& settings,
    fml::RefPtr<const DartSnapshot> isolate_snapshot,
    fml::RefPtr<const DartSnapshot> shared_snapshot,
    TaskRunners task_runners,
    std::unique_ptr<Window> window,
    fml::WeakPtr<IOManager> io_manager,
    fml::WeakPtr<ImageDecoder> image_decoder,
    std::string advisory_script_uri,
    std::string advisory_script_entrypoint,
    Dart_IsolateFlags* flags,
    fml::closure isolate_create_callback,
    fml::closure isolate_shutdown_callback) {

  Dart_Isolate vm_isolate = nullptr;
  std::weak_ptr<DartIsolate> embedder_isolate;

  char* error = nullptr;


  auto root_embedder_data = std::make_unique<std::shared_ptr<DartIsolate>>(
      std::make_shared<DartIsolate>(
          settings,                     // settings
          std::move(isolate_snapshot),  // isolate snapshot
          std::move(shared_snapshot),   // shared snapshot
          task_runners,                 // task runners
          std::move(io_manager),        // IO manager
          std::move(image_decoder),     // Image Decoder
          advisory_script_uri,          // advisory URI
          advisory_script_entrypoint,   // advisory entrypoint
          nullptr,                      // child isolate preparer
          isolate_create_callback,      // isolate create callback
          isolate_shutdown_callback     // isolate shutdown callback
          ));

  std::tie(vm_isolate, embedder_isolate) = CreateDartVMAndEmbedderObjectPair(
      advisory_script_uri.c_str(),         // advisory script URI
      advisory_script_entrypoint.c_str(),  // advisory script entrypoint
      nullptr,                             // package root
      nullptr,                             // package config
      flags,                               // flags
      root_embedder_data.get(),            // parent embedder data
      true,                                // is root isolate
      &error                               // error (out)
  );

  if (error != nullptr) {
    free(error);
  }

  if (vm_isolate == nullptr) {
    return {};
  }

  std::shared_ptr<DartIsolate> shared_embedder_isolate =
      embedder_isolate.lock();
  if (shared_embedder_isolate) {
    shared_embedder_isolate->SetWindow(std::move(window));
  }

  root_embedder_data.release();

  return embedder_isolate;
}
```
- 1.创建DartIsolate 对象
- 2.CreateDartVMAndEmbedderObjectPair 创建DartVM
- 3. shared_embedder_isolate 绑定窗口

关于isolate有四种：
- 1.虚拟机isolate: `vm-isolate`，运行在ui线程
- 2.常见isolate：`isolate-xxx`，对于RootIsolate属于这个类别，运行在ui线程
- 3.虚拟机服务Isolate: `vm-service`,运行在独立线程
- 4.内核服务isolate：`kernel-service`

虚拟机创建于运行经历如下几个步骤：

- 1.DartVMRef::Create() 创建虚拟机
- 2.DartIsolate::CreateRootIsolate 创建isolate
- 3.DartIsolate::Run运行isolate

注意只有根isolate才能和window交互

### 7.Shell::SetUp

```cpp
bool Shell::Setup(std::unique_ptr<PlatformView> platform_view,
                  std::unique_ptr<Engine> engine,
                  std::unique_ptr<Rasterizer> rasterizer,
                  std::unique_ptr<ShellIOManager> io_manager) {
  if (is_setup_) {
    return false;
  }

  if (!platform_view || !engine || !rasterizer || !io_manager) {
    return false;
  }

  platform_view_ = std::move(platform_view);
  engine_ = std::move(engine);
  rasterizer_ = std::move(rasterizer);
  io_manager_ = std::move(io_manager);

  // The weak ptr must be generated in the platform thread which owns the unique
  // ptr.
  weak_engine_ = engine_->GetWeakPtr();
  weak_rasterizer_ = rasterizer_->GetWeakPtr();
  weak_platform_view_ = platform_view_->GetWeakPtr();

  is_setup_ = true;

  vm_->GetServiceProtocol()->AddHandler(this, GetServiceProtocolDescription());

  PersistentCache::GetCacheForProcess()->AddWorkerTaskRunner(
      task_runners_.GetIOTaskRunner());

  PersistentCache::GetCacheForProcess()->SetIsDumpingSkp(
      settings_.dump_skp_on_shader_compilation);

  display_refresh_rate_ = weak_engine_->GetDisplayRefreshRate();

  return true;
}

```
- 1.Shell缓存了PlatformView 也就是PlatformViewAndroid 一个NativeWindow
- 2.缓存了rasterizer 光栅器
- 3.缓存了Engine flutter的引擎对象

##  8.FlutterActivityDelegate.runBundle 启动dart程序
```java
  private void runBundle(String appBundlePath) {
    if (!flutterView.getFlutterNativeView().isApplicationRunning()) {
      FlutterRunArguments args = new FlutterRunArguments();
      args.bundlePath = appBundlePath;
      args.entrypoint = "main";
      flutterView.runFromBundle(args);
    }
  }
```

获取dart文件路径，需要反射调用的方法为main，最后作为参数传入FlutterView中

```java
  public void runFromBundle(FlutterRunArguments args) {
    assertAttached();
    preRun();
    mNativeView.runFromBundle(args);
    postRun();
  }
```
FlutterView 调用了FlutterNativeView的runFromBundle

```java
  public void runFromBundle(FlutterRunArguments args) {
    if (args.entrypoint == null) {
      throw new AssertionError("An entrypoint must be specified");
    }
    assertAttached();
    if (applicationIsRunning)
      throw new AssertionError("This Flutter engine instance is already running an application");
    mFlutterJNI.runBundleAndSnapshotFromLibrary(
        args.bundlePath, args.entrypoint, args.libraryPath, mContext.getResources().getAssets());

    applicationIsRunning = true;
  }
```
核心方法还是这个jni方法nativeRunBundleAndSnapshotFromLibrary

```java
  public void runBundleAndSnapshotFromLibrary(
      @NonNull String bundlePath,
      @Nullable String entrypointFunctionName,
      @Nullable String pathToEntrypointFunction,
      @NonNull AssetManager assetManager) {
    ensureRunningOnMainThread();
    ensureAttachedToNative();
    nativeRunBundleAndSnapshotFromLibrary(
        nativePlatformViewId,
        bundlePath,
        entrypointFunctionName,
        pathToEntrypointFunction,
        assetManager);
  }
```

## 9.RunBundleAndSnapshotFromLibrary

对应jni为：

```java
static void RunBundleAndSnapshotFromLibrary(JNIEnv* env,
                                            jobject jcaller,
                                            jlong shell_holder,
                                            jstring jBundlePath,
                                            jstring jEntrypoint,
                                            jstring jLibraryUrl,
                                            jobject jAssetManager) {
  auto asset_manager = std::make_shared<flutter::AssetManager>();

  asset_manager->PushBack(std::make_unique<flutter::APKAssetProvider>(
      env,                                             // jni environment
      jAssetManager,                                   // asset manager
      fml::jni::JavaStringToString(env, jBundlePath))  // apk asset dir
  );

  std::unique_ptr<IsolateConfiguration> isolate_configuration;
  if (flutter::DartVM::IsRunningPrecompiledCode()) {
    isolate_configuration = IsolateConfiguration::CreateForAppSnapshot();
  } else {
    std::unique_ptr<fml::Mapping> kernel_blob =
        fml::FileMapping::CreateReadOnly(
            ANDROID_SHELL_HOLDER->GetSettings().application_kernel_asset);
    if (!kernel_blob) {
      FML_DLOG(ERROR) << "Unable to load the kernel blob asset.";
      return;
    }
    isolate_configuration =
        IsolateConfiguration::CreateForKernel(std::move(kernel_blob));
  }

  RunConfiguration config(std::move(isolate_configuration),
                          std::move(asset_manager));

  {
    auto entrypoint = fml::jni::JavaStringToString(env, jEntrypoint);
    auto libraryUrl = fml::jni::JavaStringToString(env, jLibraryUrl);

    if ((entrypoint.size() > 0) && (libraryUrl.size() > 0)) {
      config.SetEntrypointAndLibrary(std::move(entrypoint),
                                     std::move(libraryUrl));
    } else if (entrypoint.size() > 0) {
      config.SetEntrypoint(std::move(entrypoint));
    }
  }

  ANDROID_SHELL_HOLDER->Launch(std::move(config));
}
```
- 1.从上层中获取了该Apk拥有的assetManager并保存到asset_manager 集合中
- 2.生成RunConfiguration 对象，保存了之后需要加载dart应用的路径以及需要启动程序的入口函数(此时为main)
- 3.调用AndroidShellHolder的Launch方法。


### 10.AndroidShellHolder  Launch

```cpp
void AndroidShellHolder::Launch(RunConfiguration config) {
  if (!IsValid()) {
    return;
  }

  shell_->RunEngine(std::move(config));
}
```
核心调用了Shell的RunEngine


#### 10.1 Shell的RunEngine

```cpp
void Shell::RunEngine(RunConfiguration run_configuration,
                      std::function<void(Engine::RunStatus)> result_callback) {
  auto result = [platform_runner = task_runners_.GetPlatformTaskRunner(),
                 result_callback](Engine::RunStatus run_result) {
    if (!result_callback) {
      return;
    }
    platform_runner->PostTask(
        [result_callback, run_result]() { result_callback(run_result); });
  };
  FML_DCHECK(is_setup_);
  FML_DCHECK(task_runners_.GetPlatformTaskRunner()->RunsTasksOnCurrentThread());

  if (!weak_engine_) {
    result(Engine::RunStatus::Failure);
  }
  fml::TaskRunner::RunNowOrPostTask(
      task_runners_.GetUITaskRunner(),
      fml::MakeCopyable(
          [run_configuration = std::move(run_configuration),
           weak_engine = weak_engine_, result]() mutable {
...
            auto run_result = weak_engine->Run(std::move(run_configuration));
...
            result(run_result);
          }));
}
```
核心是在Platform线程中调用了Engine的run方法。


#### 10.1.1 Engine的run

```cpp
Engine::RunStatus Engine::Run(RunConfiguration configuration) {
...

  auto isolate_launch_status =
      PrepareAndLaunchIsolate(std::move(configuration));
...
  std::shared_ptr<DartIsolate> isolate =
      runtime_controller_->GetRootIsolate().lock();

  bool isolate_running =
      isolate && isolate->GetPhase() == DartIsolate::Phase::Running;

  if (isolate_running) {
    tonic::DartState::Scope scope(isolate.get());

    if (settings_.root_isolate_create_callback) {
      settings_.root_isolate_create_callback();
    }

    if (settings_.root_isolate_shutdown_callback) {
      isolate->AddIsolateShutdownCallback(
          settings_.root_isolate_shutdown_callback);
    }

    std::string service_id = isolate->GetServiceId();
    fml::RefPtr<PlatformMessage> service_id_message =
        fml::MakeRefCounted<flutter::PlatformMessage>(
            kIsolateChannel,
            std::vector<uint8_t>(service_id.begin(), service_id.end()),
            nullptr);
    HandlePlatformMessage(service_id_message);
  }

  return isolate_running ? Engine::RunStatus::Success
                         : Engine::RunStatus::Failure;
}
```

- 1. PrepareAndLaunchIsolate 准备以及启动isolate的main方法
- 2.最后回调到FlutterJNI的handlePlatformMessageResponse 方法中告诉完成启动

#### 11. PrepareAndLaunchIsolate

```cpp
Engine::RunStatus Engine::PrepareAndLaunchIsolate(
    RunConfiguration configuration) {
  TRACE_EVENT0("flutter", "Engine::PrepareAndLaunchIsolate");

  UpdateAssetManager(configuration.GetAssetManager());

  auto isolate_configuration = configuration.TakeIsolateConfiguration();

  std::shared_ptr<DartIsolate> isolate =
      runtime_controller_->GetRootIsolate().lock();

  if (!isolate) {
    return RunStatus::Failure;
  }

  // This can happen on iOS after a plugin shows a native window and returns to
  // the Flutter ViewController.
  if (isolate->GetPhase() == DartIsolate::Phase::Running) {
    FML_DLOG(WARNING) << "Isolate was already running!";
    return RunStatus::FailureAlreadyRunning;
  }

  if (!isolate_configuration->PrepareIsolate(*isolate)) {
    FML_LOG(ERROR) << "Could not prepare to run the isolate.";
    return RunStatus::Failure;
  }

  if (configuration.GetEntrypointLibrary().empty()) {
    if (!isolate->Run(configuration.GetEntrypoint(),
                      settings_.dart_entrypoint_args)) {
      FML_LOG(ERROR) << "Could not run the isolate.";
      return RunStatus::Failure;
    }
  } else {
    if (!isolate->RunFromLibrary(configuration.GetEntrypointLibrary(),
                                 configuration.GetEntrypoint(),
                                 settings_.dart_entrypoint_args)) {
      FML_LOG(ERROR) << "Could not run the isolate.";
      return RunStatus::Failure;
    }
  }

  return RunStatus::Success;
}

Engine::RunStatus Engine::PrepareAndLaunchIsolate(
    RunConfiguration configuration) {
...

  UpdateAssetManager(configuration.GetAssetManager());

  auto isolate_configuration = configuration.TakeIsolateConfiguration();

  std::shared_ptr<DartIsolate> isolate =
      runtime_controller_->GetRootIsolate().lock();

...
...

  if (!isolate_configuration->PrepareIsolate(*isolate)) {
...
    return RunStatus::Failure;
  }

  if (configuration.GetEntrypointLibrary().empty()) {
    if (!isolate->Run(configuration.GetEntrypoint(),
                      settings_.dart_entrypoint_args)) {
...
      return RunStatus::Failure;
    }
  } else {
    if (!isolate->RunFromLibrary(configuration.GetEntrypointLibrary(),
                                 configuration.GetEntrypoint(),
                                 settings_.dart_entrypoint_args)) {
      FML_LOG(ERROR) << "Could not run the isolate.";
      return RunStatus::Failure;
    }
  }

  return RunStatus::Success;
}
```

启动的核心就是DartIsolate的Run方法，这个EntryPoint就是指main方法。

#### 12.DartIsolate::Run

```cpp
FML_WARN_UNUSED_RESULT
bool DartIsolate::Run(const std::string& entrypoint_name,
                      const std::vector<std::string>& args,
                      fml::closure on_run) {
  TRACE_EVENT0("flutter", "DartIsolate::Run");
  if (phase_ != Phase::Ready) {
    return false;
  }

  tonic::DartState::Scope scope(this);

  auto user_entrypoint_function =
      Dart_GetField(Dart_RootLibrary(), tonic::ToDart(entrypoint_name.c_str()));

  auto entrypoint_args = tonic::ToDart(args);

  if (!InvokeMainEntrypoint(user_entrypoint_function, entrypoint_args)) {
    return false;
  }

  phase_ = Phase::Running;
  FML_DLOG(INFO) << "New isolate is in the running state.";

  if (on_run) {
    on_run();
  }
  return true;
}
```

核心就是InvokeMainEntrypoint 方法，先通过Dart_GetField 方法获取到main方法对象，然乎通过对象这个方法反射到dart的main中。

```cpp
FML_WARN_UNUSED_RESULT
static bool InvokeMainEntrypoint(Dart_Handle user_entrypoint_function,
                                 Dart_Handle args) {
  if (tonic::LogIfError(user_entrypoint_function)) {
    FML_LOG(ERROR) << "Could not resolve main entrypoint function.";
    return false;
  }

  Dart_Handle start_main_isolate_function =
      tonic::DartInvokeField(Dart_LookupLibrary(tonic::ToDart("dart:isolate")),
                             "_getStartMainIsolateFunction", {});

  if (tonic::LogIfError(start_main_isolate_function)) {
    FML_LOG(ERROR) << "Could not resolve main entrypoint trampoline.";
    return false;
  }

  if (tonic::LogIfError(tonic::DartInvokeField(
          Dart_LookupLibrary(tonic::ToDart("dart:ui")), "_runMainZoned",
          {start_main_isolate_function, user_entrypoint_function, args}))) {
    FML_LOG(ERROR) << "Could not invoke the main entrypoint.";
    return false;
  }

  return true;
}
```

isolate的启动过程会经历如下几个方法的调用：
- 1. 从dart:isolate 的作用域中找到_getStartMainIsolateFunction 获取_startMainIsolate的方法

在这里https://github.com/dart-lang/sdk/blob/275d8657326ca59e741ca929246404cac90f7ba3/sdk/lib/_internal/vm/lib/isolate_patch.dart

```dart
@pragma("vm:entry-point", "call")
Function _getStartMainIsolateFunction() {
  return _startMainIsolate;
}

@pragma("vm:entry-point", "call")
void _startMainIsolate(Function entryPoint, List<String>? args) {
  _startIsolate(
      null, // no parent port
      entryPoint,
      args,
      null, // no message
      true, // isSpawnUri
      null, // no control port
      null); // no capabilities
}
```
就是这个方法指针。

- 2.获取dart:ui 下的_runMainZoned方法，执行该_startMainIsolate方法，在_startMainIsolate方法中执行main方法。

```dart
@pragma('vm:entry-point')
// ignore: unused_element
void _runMainZoned(Function startMainIsolateFunction,
                   Function userMainFunction,
                   List<String> args) {
  startMainIsolateFunction((){
    runZoned<void>(() {
      if (userMainFunction is _BinaryFunction) {
        (userMainFunction as dynamic)(args, '');
      } else if (userMainFunction is _UnaryFunction) {
        (userMainFunction as dynamic)(args);
      } else {
        userMainFunction();
      }
    }, onError: (Object error, StackTrace stackTrace) {
      _reportUnhandledException(error.toString(), stackTrace.toString());
    });
  }, null);
}
```

这个过程就是执行传入了_startMainIsolate方法，接着在回调中执行runZoned方法，最后在这个方法执行main方法，根据main是双参数，多参数还是无参数从而注入从顶层传递下来的args参数。 此时默认是无参数的(除非深入到Fluttermain::Init自定义,不然都是无参数)。

最后执行：

```dart
void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Bridge Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(title: 'Flutter Bridge Home Page'),
    );
  }
}

```

## Flutter 渲染

```dart
void runApp(Widget app) {
  WidgetsFlutterBinding.ensureInitialized()
    ..scheduleAttachRootWidget(app)
    ..scheduleWarmUpFrame();
}
```
- 1. WidgetsFlutterBinding.ensureInitialized Widget的初始化
- 2. scheduleAttachRootWidget 应用的Widget绑定为根
- 3. scheduleWarmUpFrame开始启动刷新

### 1.WidgetsFlutterBinding.ensureInitialized

```dart
class WidgetsFlutterBinding extends BindingBase with GestureBinding, SchedulerBinding, ServicesBinding, PaintingBinding, SemanticsBinding, RendererBinding, WidgetsBinding {

  static WidgetsBinding ensureInitialized() {
    if (WidgetsBinding.instance == null)
      WidgetsFlutterBinding();
    return WidgetsBinding.instance;
  }
}
```
能看到实际上这就是一个单例 的 WidgetsBinding 对象，这个对象是继承了BindingBase：

```dart
  BindingBase() {
    developer.Timeline.startSync('Framework initialization');

    assert(!_debugInitialized);
    initInstances();
    assert(_debugInitialized);

    assert(!_debugServiceExtensionsRegistered);
    initServiceExtensions();
    assert(_debugServiceExtensionsRegistered);

    developer.postEvent('Flutter.FrameworkInitialization', <String, String>{});

    developer.Timeline.finishSync();
  }
```

同时mixin了大量的对象，从右到左是：
- 1. WidgetsBinding
- 2. RendererBinding
- 3. SemanticsBinding
- 4. PaintingBinding
- 5. ServicesBinding
- 6. SchedulerBinding
- 7. GestureBinding

如果都有相同的方法执行也是按照从左到右的顺序执行。比如在BindingBase构造函数中执行了initInstances，发现WidgetsBinding存在initInstances则先执行WidgetsBinding 的initInstances

#### 1.1 GestureBinding initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
    window.onPointerDataPacket = _handlePointerDataPacket;
  }
```
这个方法就是接受从Android 原生传递下来的触点时间


#### 1.2 SchedulerBinding initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
...
  }
```
简单的持有当前对象。SchedulerBinding这个对象是用于处理事务调度，如Android原生需要flutter端开始刷新的一帧的监听。

#### 1.3 ServicesBinding initInstances

```dart

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
    _defaultBinaryMessenger = createBinaryMessenger();
    window.onPlatformMessage = defaultBinaryMessenger.handlePlatformMessage;
    initLicenses();
    SystemChannels.system.setMessageHandler(handleSystemMessage);
    SystemChannels.lifecycle.setMessageHandler(_handleLifecycleMessage);
    readInitialLifecycleStateFromNativeWindow();
  }

```
该对象创建了一个默认的通信管道`_DefaultBinaryMessenger`。并且设置该通信管道的handlePlatformMessage方法赋值给Window的onPlatformMessage。

并设置监听`flutter/system` 和`flutter/lifecycle`的监听，readInitialLifecycleStateFromNativeWindow 从本地窗口中读取状态。

##### 1.3.1 readInitialLifecycleStateFromNativeWindow

 ```dart
   @protected
  void readInitialLifecycleStateFromNativeWindow() {
    if (lifecycleState != null) {
      return;
    }
    final AppLifecycleState state = _parseAppLifecycleMessage(window.initialLifecycleState);
    if (state != null) {
      handleAppLifecycleStateChanged(state);
    }
  }
  
  
    @protected
  @mustCallSuper
  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    assert(state != null);
    _lifecycleState = state;
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        _setFramesEnabledState(true);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setFramesEnabledState(false);
        break;
    }
  }

 ```
 
 实际上就是读取当前Window的状态，只有resumed或者inactive 的时候才会执行_setFramesEnabledState 设置为true。
 
 
 
#### 1.3.1.1 _setFramesEnabledState
 
 ```dart
   void _setFramesEnabledState(bool enabled) {
    if (_framesEnabled == enabled)
      return;
    _framesEnabled = enabled;
    if (enabled)
      scheduleFrame();
  }
 ```
 如果此时传入了的enabled微true，说明此事窗口已经绑定了，可视化了需要开始绘制了。


 
#### 1.3.1.1.1 scheduleFrame
  
 ```dart
   void scheduleFrame() {
    if (_hasScheduledFrame || !framesEnabled)
      return;
    assert(() {
      if (debugPrintScheduleFrameStacks)
        debugPrintStack(label: 'scheduleFrame() called. Current phase is $schedulerPhase.');
      return true;
    }());
    ensureFrameCallbacksRegistered();
    window.scheduleFrame();
    _hasScheduledFrame = true;
  }

 ```
核心就是调用两个步骤：

- 1. ensureFrameCallbacksRegistered 注册了Window开始绘制和正在绘制的方法指针

```dart
  @protected
  void ensureFrameCallbacksRegistered() {
    window.onBeginFrame ??= _handleBeginFrame;
    window.onDrawFrame ??= _handleDrawFrame;
  }
```

- 2. window.scheduleFrame
```dart
  void scheduleFrame() native 'Window_scheduleFrame';
```

这里调用了Native层的 Window_scheduleFrame方法。可以看看在dart虚拟机也有类似jni的机制为注入一个c++的方法，这种方式成为ffi。

```cpp
void Window::RegisterNatives(tonic::DartLibraryNatives* natives) {
  natives->Register({
      {"Window_defaultRouteName", DefaultRouteName, 1, true},
      {"Window_scheduleFrame", ScheduleFrame, 1, true},
      {"Window_sendPlatformMessage", _SendPlatformMessage, 4, true},
      {"Window_respondToPlatformMessage", _RespondToPlatformMessage, 3, true},
      {"Window_render", Render, 2, true},
      {"Window_updateSemantics", UpdateSemantics, 2, true},
      {"Window_setIsolateDebugName", SetIsolateDebugName, 2, true},
      {"Window_reportUnhandledException", ReportUnhandledException, 2, true},
      {"Window_setNeedsReportTimings", SetNeedsReportTimings, 2, true},
  });
}
```

注入的时候，虚拟机会在底层new一个DartLibraryNatives 静态对象

```cpp
g_natives = new tonic::DartLibraryNatives();
```
所有的方法都会注入到这个对象中，之后需要查找就时候会从这个对象中获取注册号的方法指针。


#### 1.3.1.1.1.1 Window ScheduleFrame

```dart
void ScheduleFrame(Dart_NativeArguments args) {
  UIDartState::Current()->window()->client()->ScheduleFrame();
}
```

注意这里的WindowClient 其实就是RuntimeController

##### 1.3.1.1.1.1.1 RuntimeController ScheduleFrame 

```cpp
void RuntimeController::ScheduleFrame() {
  client_.ScheduleFrame();
}
```
调用了RuntimeDelegate的ScheduleFrame。注意RuntimeDelegate 就是Engine对象。

```cpp
void Engine::ScheduleFrame(bool regenerate_layer_tree) {
  animator_->RequestFrame(regenerate_layer_tree);
}
```

此时就是跳转到Animator的RequestFrame

###### 1.3.1.1.1.1.1.1 Animator::RequestFrame

```cpp
void Animator::RequestFrame(bool regenerate_layer_tree) {
  ...

  task_runners_.GetUITaskRunner()->PostTask([self = weak_factory_.GetWeakPtr(),
                                             frame_number = frame_number_]() {
    if (!self.get()) {
      return;
    }
    TRACE_EVENT_ASYNC_BEGIN0("flutter", "Frame Request Pending", frame_number);
    self->AwaitVSync();
  });
  frame_scheduled_ = true;
}

void Animator::AwaitVSync() {
  waiter_->AsyncWaitForVsync(
      [self = weak_factory_.GetWeakPtr()](fml::TimePoint frame_start_time,
                                          fml::TimePoint frame_target_time) {
        if (self) {
          if (self->CanReuseLastLayerTree()) {
            self->DrawLastLayerTree();
          } else {
            self->BeginFrame(frame_start_time, frame_target_time);
          }
        }
      });

  delegate_.OnAnimatorNotifyIdle(dart_frame_deadline_);
}
```

在ui线程中执行AwaitVSync方法，这个线程实际上就是调用了VsyncWaiter的AsyncWaitForVsync方法等待下一个Vsync信号的到来。

- 如果整个LayerTree可以复用则调用DrawLastLayerTree 绘制上一轮的渲染树
- 不能则调用BeginFrame 开始渲染。

#### VsyncWaiter AsyncWaitForVsync

```cpp
void VsyncWaiter::AsyncWaitForVsync(Callback callback) {
  if (!callback) {
    return;
  }


  {
    std::scoped_lock lock(callback_mutex_);

    callback_ = std::move(callback);
  }
  AwaitVSync();
}
```

注意这个VsyncWaiter是一个虚类，实际上实现在VsyncWaiterAndroid。


###### VsyncWaiterAndroid AwaitVSync

```cpp
void VsyncWaiterAndroid::AwaitVSync() {
  auto* weak_this = new std::weak_ptr<VsyncWaiter>(shared_from_this());
  jlong java_baton = reinterpret_cast<jlong>(weak_this);

  task_runners_.GetPlatformTaskRunner()->PostTask([java_baton]() {
    JNIEnv* env = fml::jni::AttachCurrentThread();
    env->CallStaticVoidMethod(g_vsync_waiter_class->obj(),     //
                              g_async_wait_for_vsync_method_,  //
                              java_baton                       //
    );
  });
}
```
此时就是指Java层的VsyncWaiter的asyncWaitForVsync

##### Java的VsyncWaiter asyncWaitForVsync

```java
  private final FlutterJNI.AsyncWaitForVsyncDelegate asyncWaitForVsyncDelegate =
      new FlutterJNI.AsyncWaitForVsyncDelegate() {
        @Override
        public void asyncWaitForVsync(long cookie) {
          Choreographer.getInstance()
              .postFrameCallback(
                  new Choreographer.FrameCallback() {
                    @Override
                    public void doFrame(long frameTimeNanos) {
                      float fps = windowManager.getDefaultDisplay().getRefreshRate();
                      long refreshPeriodNanos = (long) (1000000000.0 / fps);
                      FlutterJNI.nativeOnVsync(
                          frameTimeNanos, frameTimeNanos + refreshPeriodNanos, cookie);
                    }
                  });
        }
      };
```
也就是这个方法，实际上BeginFrame就是在Choreographer.getInstance 中注册Vsync的监听。当信号到来之后FlutterJNI.nativeOnVsync 通知Flutter 进行渲染，我们稍后再来看看。


#### 1.4 PaintingBinding initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
    _imageCache = createImageCache();
    if (shaderWarmUp != null) {
      shaderWarmUp.execute();
    }
  }
```
- 1.核心是构建通过createImageCache构建一个ImageCache 对象

```dart
class ImageCache {
  final Map<Object, _PendingImage> _pendingImages = <Object, _PendingImage>{};
  final Map<Object, _CachedImage> _cache = <Object, _CachedImage>{};

  final Map<Object, _LiveImage> _liveImages = <Object, _LiveImage>{};


  int get maximumSize => _maximumSize;
  int _maximumSize = _kDefaultSize;
```

能看到里面保存了几种缓存
- 1. _pendingImages 在Image空间中通过precache提前缓存下来的图片数据
- 2.如果_pendingImages 找不到，则从_cache中查找缓存的图片
- 3.如果_cache 中找不到则从_liveImages 中查找缓存的图片，找到了则更新当前缓存图片的时间轴

在这个过程中 _cache 是一个LRUCache

- 2. shaderWarmUp.execute

```dart
  Future<void> execute() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);

    await warmUpOnCanvas(canvas);

    final ui.Picture picture = recorder.endRecording();
    final TimelineTask shaderWarmUpTask = TimelineTask();
    shaderWarmUpTask.start('Warm-up shader');

    if (!kIsWeb) {
      await picture.toImage(size.width.ceil(), size.height.ceil());
    }
    shaderWarmUpTask.finish();
  }
```

```
 PictureRecorder() { _constructor(); }
  void _constructor() native 'PictureRecorder_constructor';
```
- 1.首先构造函数是对应native 中的PictureRecorder的constructor方法
- 2.创建一个ui.Canvas 在其中
- 3. warmUpOnCanvas 开始对整个Flutter的画板做一些初始化的处理
- 4. recorder.endRecording 绘制结束
- 5.生成一个TimelineTask 对象，并调用start
- 6.如果不是web环境，则调用picture.toImage转化

```dart
String _toImage(int width, int height, _Callback<Image> callback) native 'Picture_toImage';
``` 

- 7. shaderWarmUpTask.finish

#### 1.4.1 PictureRecorder_constructor

```cpp
static void PictureRecorder_constructor(Dart_NativeArguments args) {
  DartCallConstructor(&PictureRecorder::Create, args);
}


fml::RefPtr<PictureRecorder> PictureRecorder::Create() {
  return fml::MakeRefCounted<PictureRecorder>();
}
```
直接构造了一个PictureRecorder 返回。

#### 1.4.2 ui.Canvas 创建

```dart
  @pragma('vm:entry-point')
  Canvas(PictureRecorder recorder, [ Rect? cullRect ]) : assert(recorder != null) { // ignore: unnecessary_null_comparison
    if (recorder.isRecording)
      throw ArgumentError('"recorder" must not already be associated with another Canvas.');
    cullRect ??= Rect.largest;
    _constructor(recorder, cullRect.left, cullRect.top, cullRect.right, cullRect.bottom);
  }
  void _constructor(PictureRecorder recorder,
                    double left,
                    double top,
                    double right,
                    double bottom) native 'Canvas_constructor';
```
 
```cpp
fml::RefPtr<Canvas> Canvas::Create(PictureRecorder* recorder,
                                   double left,
                                   double top,
                                   double right,
                                   double bottom) {

  fml::RefPtr<Canvas> canvas = fml::MakeRefCounted<Canvas>(
      recorder->BeginRecording(SkRect::MakeLTRB(left, top, right, bottom)));
  recorder->set_canvas(canvas);
  return canvas;
}
```

- 1. 调用BeginRecording

```cpp
SkCanvas* PictureRecorder::BeginRecording(SkRect bounds) {
  return picture_recorder_.beginRecording(bounds, &rtree_factory_);
}
```

```cpp
SkCanvas* SkPictureRecorder::beginRecording(const SkRect& userCullRect,
                                            SkBBHFactory* bbhFactory /* = nullptr */,
                                            uint32_t recordFlags /* = 0 */) {
    const SkRect cullRect = userCullRect.isEmpty() ? SkRect::MakeEmpty() : userCullRect;

    fCullRect = cullRect;
    fFlags = recordFlags;

    if (bbhFactory) {
        fBBH.reset((*bbhFactory)(cullRect));
        SkASSERT(fBBH.get());
    }

    if (!fRecord) {
        fRecord.reset(new SkRecord);
    }
    SkRecorder::DrawPictureMode dpm = (recordFlags & kPlaybackDrawPicture_RecordFlag)
        ? SkRecorder::Playback_DrawPictureMode
        : SkRecorder::Record_DrawPictureMode;
    fRecorder->reset(fRecord.get(), cullRect, dpm, fMiniRecorder.get());
    fActivelyRecording = true;
    return this->getRecordingCanvas();
}

```
这个对象根据PictureRecorder 返回了一个SkCanvas对象，在上面绘制

- 2.把Canvas 保存在PictureRecorder中

#### 1.4.3 warmUpOnCanvas

```dart
 Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    const ui.RRect rrect = ui.RRect.fromLTRBXY(20.0, 20.0, 60.0, 60.0, 10.0, 10.0);
    final ui.Path rrectPath = ui.Path()..addRRect(rrect);

    final ui.Path circlePath = ui.Path()..addOval(
        ui.Rect.fromCircle(center: const ui.Offset(40.0, 40.0), radius: 20.0)
    );

    // The following path is based on
    // https://skia.org/user/api/SkCanvas_Reference#SkCanvas_drawPath
    final ui.Path path = ui.Path();
    path.moveTo(20.0, 60.0);
    path.quadraticBezierTo(60.0, 20.0, 60.0, 60.0);
    path.close();
    path.moveTo(60.0, 20.0);
    path.quadraticBezierTo(60.0, 60.0, 20.0, 60.0);

    final ui.Path convexPath = ui.Path();
    convexPath.moveTo(20.0, 30.0);
    convexPath.lineTo(40.0, 20.0);
    convexPath.lineTo(60.0, 30.0);
    convexPath.lineTo(60.0, 60.0);
    convexPath.lineTo(20.0, 60.0);
    convexPath.close();

    final List<ui.Path> paths = <ui.Path>[rrectPath, circlePath, path, convexPath];

    final List<ui.Paint> paints = <ui.Paint>[
      ui.Paint()
        ..isAntiAlias = true
        ..style = ui.PaintingStyle.fill,
      ui.Paint()
        ..isAntiAlias = false
        ..style = ui.PaintingStyle.fill,
      ui.Paint()
        ..isAntiAlias = true
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 10,
      ui.Paint()
        ..isAntiAlias = true
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 0.1,  // hairline
    ];

    // Warm up path stroke and fill shaders.
    for (int i = 0; i < paths.length; i += 1) {
      canvas.save();
      for (final ui.Paint paint in paints) {
        canvas.drawPath(paths[i], paint);
        canvas.translate(drawCallSpacing, 0.0);
      }
      canvas.restore();
      canvas.translate(0.0, drawCallSpacing);
    }

    // Warm up shadow shaders.
    const ui.Color black = ui.Color(0xFF000000);
    canvas.save();
    canvas.drawShadow(rrectPath, black, 10.0, true);
    canvas.translate(drawCallSpacing, 0.0);
    canvas.drawShadow(rrectPath, black, 10.0, false);
    canvas.restore();

    // Warm up text shaders.
    canvas.translate(0.0, drawCallSpacing);
    final ui.ParagraphBuilder paragraphBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textDirection: ui.TextDirection.ltr),
    )..pushStyle(ui.TextStyle(color: black))..addText('_');
    final ui.Paragraph paragraph = paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 60.0));
    canvas.drawParagraph(paragraph, const ui.Offset(20.0, 20.0));


    for (final double fraction in <double>[0.0, 0.5]) {
      canvas
        ..save()
        ..translate(fraction, fraction)
        ..clipRRect(ui.RRect.fromLTRBR(8, 8, 328, 248, const ui.Radius.circular(16)))
        ..drawRect(const ui.Rect.fromLTRB(10, 10, 320, 240), ui.Paint())
        ..restore();
      canvas.translate(drawCallSpacing, 0.0);
    }
    canvas.translate(0.0, drawCallSpacing);
  }
```
这里面的事情其实就是对SkCanvas中进行绘制操作，从而预热GPU和Skia。通过这个过程可以加载一些缓存到底层的着色器生成和编译。

#### 1.4.4  recorder.endRecording 

```cpp
fml::RefPtr<Picture> PictureRecorder::endRecording() {
  if (!isRecording())
    return nullptr;

  fml::RefPtr<Picture> picture = Picture::Create(UIDartState::CreateGPUObject(
      picture_recorder_.finishRecordingAsPicture()));
  canvas_->Clear();
  canvas_->ClearDartWrapper();
  canvas_ = nullptr;
  ClearDartWrapper();
  return picture;
}
```

当绘制结束后，就会通过 picture_recorder_.finishRecordingAsPicture

```cpp
sk_sp<SkPicture> SkPictureRecorder::finishRecordingAsPicture(uint32_t finishFlags) {
    fActivelyRecording = false;
    fRecorder->restoreToCount(1);  // If we were missing any restores, add them now.

    if (fRecord->count() == 0) {
        auto pic = fMiniRecorder->detachAsPicture(fBBH ? nullptr : &fCullRect);
        fBBH.reset(nullptr);
        return pic;
    }

    SkRecordOptimize(fRecord.get());

    SkDrawableList* drawableList = fRecorder->getDrawableList();
    SkBigPicture::SnapshotArray* pictList =
        drawableList ? drawableList->newDrawableSnapshot() : nullptr;

    if (fBBH.get()) {
        SkAutoTMalloc<SkRect> bounds(fRecord->count());
        SkRecordFillBounds(fCullRect, *fRecord, bounds);
        fBBH->insert(bounds, fRecord->count());

        SkRect bbhBound = fBBH->getRootBound();
        SkASSERT((bbhBound.isEmpty() || fCullRect.contains(bbhBound))
            || (bbhBound.isEmpty() && fCullRect.isEmpty()));
        fCullRect = bbhBound;
    }

    size_t subPictureBytes = fRecorder->approxBytesUsedBySubPictures();
    for (int i = 0; pictList && i < pictList->count(); i++) {
        subPictureBytes += pictList->begin()[i]->approximateBytesUsed();
    }
    return sk_make_sp<SkBigPicture>(fCullRect, fRecord.release(), pictList, fBBH.release(),
                                    subPictureBytes);
}
```

注意这里面就是fRecord.release 获取 中的内容生成SkBigPicture。这个fRecord 就是之前丢给flutter中绘制的RecordSkiaCanvas(在Android中)。

SkBigPicture最后保存在Picture中。


#### 1.4.5 TimelineTask start

```cpp
  void start(String name, {Map? arguments}) {
    if (!_hasTimeline) return;
    // TODO: When NNBD is complete, delete the following line.
    ArgumentError.checkNotNull(name, 'name');
    var block = new _AsyncBlock._(name, _taskId);
    _stack.add(block);

    var map = <Object?, Object?>{};
    if (arguments != null) {
      for (var key in arguments.keys) {
        map[key] = arguments[key];
      }
    }
    if (_parent != null) map['parentId'] = _parent!._taskId.toRadixString(16);
    if (_filterKey != null) map[_kFilterKey] = _filterKey;
    block._start(map);
  }
```

实际上就是生成一个名字为 `Warm-up shader` 的TimelineTask 时间轴任务通知到底层。


#### 1.4.6 picture.toImage

```dart
  Future<Image> toImage(int width, int height) {
    if (width <= 0 || height <= 0)
      throw Exception('Invalid image dimensions.');
    return _futurize(
      (_Callback<Image> callback) => _toImage(width, height, callback)
    );
  }


  String _toImage(int width, int height, _Callback<Image> callback) native 'Picture_toImage';
```

```
Future<T> _futurize<T>(_Callbacker<T> callbacker) {
  final Completer<T> completer = Completer<T>.sync();
  final String? error = callbacker((T t) {
    if (t == null) {
      completer.completeError(Exception('operation failed'));
    } else {
      completer.complete(t);
    }
  });
  if (error != null)
    throw Exception(error);
  return completer.future;
}
```

这里面实际上就是借助了Completer 的异步操作，调用了底层了 Picture_toImage。

这个过程实际上就是调用上面传递下来的callback，在这里就是调用了

```cpp
Dart_Handle Picture::toImage(uint32_t width,
                             uint32_t height,
                             Dart_Handle raw_image_callback) {
  if (!picture_.get()) {
    return tonic::ToDart("Picture is null");
  }

  return RasterizeToImage(picture_.get(), width, height, raw_image_callback);
}
```
核心就是RasterizeToImage

```cpp
Dart_Handle Picture::RasterizeToImage(sk_sp<SkPicture> picture,
                                      uint32_t width,
                                      uint32_t height,
                                      Dart_Handle raw_image_callback) {
  if (Dart_IsNull(raw_image_callback) || !Dart_IsClosure(raw_image_callback)) {
    return tonic::ToDart("Image callback was invalid");
  }

  if (width == 0 || height == 0) {
    return tonic::ToDart("Image dimensions for scene were invalid.");
  }

  auto* dart_state = UIDartState::Current();
  tonic::DartPersistentValue* image_callback =
      new tonic::DartPersistentValue(dart_state, raw_image_callback);
  auto unref_queue = dart_state->GetSkiaUnrefQueue();
  auto ui_task_runner = dart_state->GetTaskRunners().GetUITaskRunner();
  auto io_task_runner = dart_state->GetTaskRunners().GetIOTaskRunner();
  fml::WeakPtr<GrContext> resource_context = dart_state->GetResourceContext();

  auto picture_bounds = SkISize::Make(width, height);

  auto ui_task = fml::MakeCopyable([image_callback, unref_queue](
                                       sk_sp<SkImage> raster_image) mutable {
    auto dart_state = image_callback->dart_state().lock();
    if (!dart_state) {
      return;
    }
    tonic::DartState::Scope scope(dart_state);

    if (!raster_image) {
      tonic::DartInvoke(image_callback->Get(), {Dart_Null()});
      return;
    }

    auto dart_image = CanvasImage::Create();
    dart_image->set_image({std::move(raster_image), std::move(unref_queue)});
    auto* raw_dart_image = tonic::ToDart(std::move(dart_image));

    tonic::DartInvoke(image_callback->Get(), {raw_dart_image});

    delete image_callback;
  });

  fml::TaskRunner::RunNowOrPostTask(io_task_runner, [ui_task_runner, picture,
                                                     picture_bounds, ui_task,
                                                     resource_context] {
    sk_sp<SkSurface> surface =
        MakeSnapshotSurface(picture_bounds, resource_context);
    sk_sp<SkImage> raster_image = MakeRasterSnapshot(picture, surface);

    fml::TaskRunner::RunNowOrPostTask(
        ui_task_runner, [ui_task, raster_image]() { ui_task(raster_image); });
  });

  return Dart_Null();
}
```

整个核心就是在io线程中调用MakeRasterSnapshot方法获取surface中的SkImage对象。最后把这个raster_image对象通过ui线程执行`ui_task`任务，在这个任务中就把`raster_image`设置到dart的Image对象中。


#### 1.5 SemanticsBinding initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
    _accessibilityFeatures = window.accessibilityFeatures;
  }
```
获取window.accessibilityFeatures 到全局变量中


#### 1.6 RendererBinding initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
    _pipelineOwner = PipelineOwner(
      onNeedVisualUpdate: ensureVisualUpdate,
      onSemanticsOwnerCreated: _handleSemanticsOwnerCreated,
      onSemanticsOwnerDisposed: _handleSemanticsOwnerDisposed,
    );
    window
      ..onMetricsChanged = handleMetricsChanged
      ..onTextScaleFactorChanged = handleTextScaleFactorChanged
      ..onPlatformBrightnessChanged = handlePlatformBrightnessChanged
      ..onSemanticsEnabledChanged = _handleSemanticsEnabledChanged
      ..onSemanticsAction = _handleSemanticsAction;
    initRenderView();
    _handleSemanticsEnabledChanged();
    assert(renderView != null);
    addPersistentFrameCallback(_handlePersistentFrameCallback);
    initMouseTracker();
  }

```

- 1. 将window的响应的处理方法赋值对应的方法指针，设置PipelineOwner对象。
- 2. initRenderView 构建一个RenderView 准备绘制
- 3. _handleSemanticsEnabledChanged 如果window的semanticsEnabled 为true则设置_semanticsHandle为_pipelineOwner.ensureSemantics()
- 4. addPersistentFrameCallback 添加一个从Java中回调上的onDrawFrame，对应dart的handleDrawFrame。
- 5. initMouseTracker 初始化MouseTracker


##### 1.6.1 PipelineOwner

PipelineOwner 是flutter 用于控制渲染管道的。

```dart
class PipelineOwner {

  PipelineOwner({
    this.onNeedVisualUpdate,
    this.onSemanticsOwnerCreated,
    this.onSemanticsOwnerDisposed,
  });

  final VoidCallback onNeedVisualUpdate;

  final VoidCallback onSemanticsOwnerCreated;

  final VoidCallback onSemanticsOwnerDisposed;
  
   AbstractNode get rootNode => _rootNode;
  AbstractNode _rootNode;
  set rootNode(AbstractNode value) {
    if (_rootNode == value)
      return;
    _rootNode?.detach();
    _rootNode = value;
    _rootNode?.attach(this);
  }

  List<RenderObject> _nodesNeedingLayout = <RenderObject>[];
  List<RenderObject> _nodesNeedingLayout = <RenderObject>[];
  
    void flushLayout() {
    if (!kReleaseMode) {
      Timeline.startSync('Layout', arguments: timelineArgumentsIndicatingLandmarkEvent);
    }
    assert(() {
      _debugDoingLayout = true;
      return true;
    }());
    try {
      // TODO(ianh): assert that we're not allowing previously dirty nodes to redirty themselves
      while (_nodesNeedingLayout.isNotEmpty) {
        final List<RenderObject> dirtyNodes = _nodesNeedingLayout;
        _nodesNeedingLayout = <RenderObject>[];
        for (final RenderObject node in dirtyNodes..sort((RenderObject a, RenderObject b) => a.depth - b.depth)) {
          if (node._needsLayout && node.owner == this)
            node._layoutWithoutResize();
        }
      }
    } finally {
      assert(() {
        _debugDoingLayout = false;
        return true;
      }());
      if (!kReleaseMode) {
        Timeline.finishSync();
      }
    }
  }
  
    void flushCompositingBits() {
    if (!kReleaseMode) {
      Timeline.startSync('Compositing bits');
    }
    _nodesNeedingCompositingBitsUpdate.sort((RenderObject a, RenderObject b) => a.depth - b.depth);
    for (final RenderObject node in _nodesNeedingCompositingBitsUpdate) {
      if (node._needsCompositingBitsUpdate && node.owner == this)
        node._updateCompositingBits();
    }
    _nodesNeedingCompositingBitsUpdate.clear();
    if (!kReleaseMode) {
      Timeline.finishSync();
    }
  }

  List<RenderObject> _nodesNeedingPaint = <RenderObject>[];

  void flushPaint() {
    if (!kReleaseMode) {
      Timeline.startSync('Paint', arguments: timelineArgumentsIndicatingLandmarkEvent);
    }
    assert(() {
      _debugDoingPaint = true;
      return true;
    }());
    try {
      final List<RenderObject> dirtyNodes = _nodesNeedingPaint;
      _nodesNeedingPaint = <RenderObject>[];
      // Sort the dirty nodes in reverse order (deepest first).
      for (final RenderObject node in dirtyNodes..sort((RenderObject a, RenderObject b) => b.depth - a.depth)) {
        assert(node._layer != null);
        if (node._needsPaint && node.owner == this) {
          if (node._layer.attached) {
            PaintingContext.repaintCompositedChild(node);
          } else {
            node._skippedPaintingOnLayer();
          }
        }
      }
      assert(_nodesNeedingPaint.isEmpty);
    } finally {
      assert(() {
        _debugDoingPaint = false;
        return true;
      }());
      if (!kReleaseMode) {
        Timeline.finishSync();
      }
    }
  }

  
```

能看到这个管道的职责就是，作为入口刷新每一个RenderObject。


##### 1.6.2 initRenderView

```dart
  void initRenderView() {
    assert(renderView == null);
    renderView = RenderView(configuration: createViewConfiguration(), window: window);
    renderView.prepareInitialFrame();
  }
```

```dart
class RenderView extends RenderObject with RenderObjectWithChildMixin<RenderBox> {

  RenderView({
    RenderBox child,
    @required ViewConfiguration configuration,
    @required ui.Window window,
  }) : assert(configuration != null),
       _configuration = configuration,
       _window = window {
    this.child = child;
  }
```

- 1. RenderView 是一个RenderObject，会持有一个child。此时初始化并没有，单数传递了一个窗体下去。

- 2. renderView.prepareInitialFrame


###### 1.6.2.1 renderView.prepareInitialFrame

```dart
  void prepareInitialFrame() {
    assert(owner != null);
    assert(_rootTransform == null);
    scheduleInitialLayout();
    scheduleInitialPaint(_updateMatricesAndCreateNewRootLayer());
    assert(_rootTransform != null);
  }

```

- 1. scheduleInitialLayout 初始化布局

```dart
  @override
  PipelineOwner get owner => super.owner as PipelineOwner;
  
  void scheduleInitialLayout() {
    assert(attached);
    assert(parent is! RenderObject);
    assert(!owner._debugDoingLayout);
    assert(_relayoutBoundary == null);
    _relayoutBoundary = this;
    assert(() {
      _debugCanParentUseSize = false;
      return true;
    }());
    owner._nodesNeedingLayout.add(this);
  }
```
实际上就是给PipelineOwner的_nodesNeedingLayout 需要更新的RenderObject的集合将本根节点添加进去。

- 2. scheduleInitialPaint

```dart
  TransformLayer _updateMatricesAndCreateNewRootLayer() {
    _rootTransform = configuration.toMatrix();
    final TransformLayer rootLayer = TransformLayer(transform: _rootTransform);
    rootLayer.attach(this);
    assert(_rootTransform != null);
    return rootLayer;
  }
```

生成一个TransformLayer 并把TransformLayer和当前的RenderView绑定起来，在scheduleInitialPaint中设置好TransformLayer，并添加到_nodesNeedingPaint ，需要绘制的ContainerLayer节点(也就是Layer)

```dart
  void scheduleInitialPaint(ContainerLayer rootLayer) {
    assert(rootLayer.attached);
    assert(attached);
    assert(parent is! RenderObject);
    assert(!owner._debugDoingPaint);
    assert(isRepaintBoundary);
    assert(_layer == null);
    _layer = rootLayer;
    assert(_needsPaint);
    owner._nodesNeedingPaint.add(this);
  }

```

#### 1.7 WidgetsBinding  initInstances

```dart
  @override
  void initInstances() {
    super.initInstances();
    _instance = this;

    assert(() {
      _debugAddStackFilters();
      return true;
    }());

    _buildOwner = BuildOwner();
    buildOwner.onBuildScheduled = _handleBuildScheduled;
    window.onLocaleChanged = handleLocaleChanged;
    window.onAccessibilityFeaturesChanged = handleAccessibilityFeaturesChanged;
    SystemChannels.navigation.setMethodCallHandler(_handleNavigationInvocation);
    FlutterErrorDetails.propertiesTransformers.add(transformDebugCreator);
  }
```

- 1.window对象设置了onBuildScheduled 和onLocaleChanged回调方法。
- 2.设置一个Navgation的操作本地方法通信对象

```
  Future<dynamic> _handleNavigationInvocation(MethodCall methodCall) {
    switch (methodCall.method) {
      case 'popRoute':
        return handlePopRoute();
      case 'pushRoute':
        return handlePushRoute(methodCall.arguments as String);
    }
    return Future<dynamic>.value();
  }
```



### 2. scheduleAttachRootWidget

#### 2.1 WidgetsBinding scheduleAttachRootWidget

```dart
  @protected
  void scheduleAttachRootWidget(Widget rootWidget) {
    Timer.run(() {
      attachRootWidget(rootWidget);
    });
  }
```

通过Timer.run异步执行attachRootWidget



#### Timer 异步原理
```dart
  static void run(void Function() callback) {
    new Timer(Duration.zero, callback);
  }

```

```dart
  factory Timer(Duration duration, void Function() callback) {
    if (Zone.current == Zone.root) {
      return Zone.current.createTimer(duration, callback);
    }
    return Zone.current
        .createTimer(duration, Zone.current.bindCallbackGuarded(callback));
  }
```

```dart
  @patch
  static Timer _createTimer(Duration duration, void callback()) {
    final factory = VMLibraryHooks.timerFactory;
    if (factory == null) {
      throw new UnsupportedError("Timer interface not supported.");
    }
    int milliseconds = duration.inMilliseconds;
    if (milliseconds < 0) milliseconds = 0;
    return factory(milliseconds, (_) {
      callback();
    }, false);
  }

```


