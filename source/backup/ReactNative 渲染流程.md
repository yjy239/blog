## ReactNative 渲染流程

### 1.入口ReactActivityDelegate.onCreate

```java
  protected void onCreate(Bundle savedInstanceState) {
    String mainComponentName = getMainComponentName();
    mReactDelegate =
        new ReactDelegate(
            getPlainActivity(), getReactNativeHost(), mainComponentName, getLaunchOptions()) {
          @Override
          protected ReactRootView createRootView() {
            return ReactActivityDelegate.this.createRootView();
          }
        };
    if (mMainComponentName != null) {
      loadApp(mainComponentName);
    }
  }
```

### 2.构建ReactDelegate

### 3. ReactActivityDelegate.loadApp 初始化环境启动js应用

```java
  protected void loadApp(String appKey) {
    mReactDelegate.loadApp(appKey);
    getPlainActivity().setContentView(mReactDelegate.getReactRootView());
  }
```

### 4.ReactDelegate loadApp
```java
  public void loadApp(String appKey) {
    if (mReactRootView != null) {
      throw new IllegalStateException("Cannot loadApp while app is already running.");
    }
    mReactRootView = createRootView();
    mReactRootView.startReactApplication(
        getReactNativeHost().getReactInstanceManager(), appKey, mLaunchOptions);
  }
```
- mLaunchOptions 是启动时候设置的参数。
- createRootView 构建ReactRootView
- ReactRootView.startReactApplication

### 5.getReactInstanceManager 构建React环境对象
```java
  protected ReactInstanceManager createReactInstanceManager() {

    ReactInstanceManagerBuilder builder =
        ReactInstanceManager.builder()
            .setApplication(mApplication)
            .setJSMainModulePath(getJSMainModuleName())
            .setUseDeveloperSupport(getUseDeveloperSupport())
            .setRedBoxHandler(getRedBoxHandler())
            .setJavaScriptExecutorFactory(getJavaScriptExecutorFactory())
            .setUIImplementationProvider(getUIImplementationProvider())
            .setJSIModulesPackage(getJSIModulePackage())
            .setInitialLifecycleState(LifecycleState.BEFORE_CREATE);

    for (ReactPackage reactPackage : getPackages()) {
      builder.addPackage(reactPackage);
    }

    String jsBundleFile = getJSBundleFile();
    if (jsBundleFile != null) {
      builder.setJSBundleFile(jsBundleFile);
    } else {
      builder.setBundleAssetName(Assertions.assertNotNull(getBundleAssetName()));
    }
    ReactInstanceManager reactInstanceManager = builder.build();

    return reactInstanceManager;
  }
```

- 添加java的ReactPackage对象，以及js的名字
- ReactInstanceManager 持有React运行上下文，以及所有的本地模块


### 6.ReactRootView.startReactApplication
```java
public void startReactApplication(
      ReactInstanceManager reactInstanceManager,
      String moduleName,
      @Nullable Bundle initialProperties,
      @Nullable String initialUITemplate) {
    try {
      mReactInstanceManager = reactInstanceManager;
      mJSModuleName = moduleName;
      mAppProperties = initialProperties;
      mInitialUITemplate = initialUITemplate;

      mReactInstanceManager.createReactContextInBackground();
      attachToReactInstanceManager();
    } finally {
    }
  }
```
- createReactContextInBackground 启动现场初始化React环境
- 绑定React环境到当前的View上，启动js

### 7. createReactContextInBackground
```java
  private void runCreateReactContextOnNewThread(final ReactContextInitParams initParams) {

    synchronized (mAttachedReactRoots) {
      synchronized (mReactContextLock) {
        if (mCurrentReactContext != null) {
          tearDownReactContext(mCurrentReactContext);
          mCurrentReactContext = null;
        }
      }
    }

    mCreateReactContextThread =
        new Thread(
            null,
            new Runnable() {
              @Override
              public void run() {
                synchronized (ReactInstanceManager.this.mHasStartedDestroying) {
                  while (ReactInstanceManager.this.mHasStartedDestroying) {
                    try {
                      ReactInstanceManager.this.mHasStartedDestroying.wait();
                    } catch (InterruptedException e) {
                      continue;
                    }
                  }
                }
                mHasStartedCreatingInitialContext = true;

                try {
                  Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY);
                  ReactMarker.logMarker(VM_INIT);
                  final ReactApplicationContext reactApplicationContext =
                      createReactContext(
                          initParams.getJsExecutorFactory().create(),
                          initParams.getJsBundleLoader());

                  mCreateReactContextThread = null;
                  ReactMarker.logMarker(PRE_SETUP_REACT_CONTEXT_START);
                  final Runnable maybeRecreateReactContextRunnable =
                      new Runnable() {
                        @Override
                        public void run() {
                          if (mPendingReactContextInitParams != null) {
                            runCreateReactContextOnNewThread(mPendingReactContextInitParams);
                            mPendingReactContextInitParams = null;
                          }
                        }
                      };
                  Runnable setupReactContextRunnable =
                      new Runnable() {
                        @Override
                        public void run() {
                          try {
                            setupReactContext(reactApplicationContext);
                          } catch (Exception e) {
                          }
                        }
                      };

                  reactApplicationContext.runOnNativeModulesQueueThread(setupReactContextRunnable);
                  UiThreadUtil.runOnUiThread(maybeRecreateReactContextRunnable);
                } catch (Exception e) {
                  mDevSupportManager.handleException(e);
                }
              }
            },
            "create_react_context");
 
    mCreateReactContextThread.start();
  }
```
- mCreateReactContextThread 为初始化现场，通过执行maybeRecreateReactContextRunnable，递归执行初始化直到成功

- createReactContext 构建React环境上下文`ReactApplicationContext`.初始化了CatalystInstanceImpl ReactNative和Android的桥接对象 ，本地所有模块并注入到JSI。初始化所有的React的运行线程
- setupReactContextRunnable  setupReactContext正式启动

#### 7.1 createReactContext
```
  private ReactApplicationContext createReactContext(
      JavaScriptExecutor jsExecutor, JSBundleLoader jsBundleLoader) {


    final ReactApplicationContext reactContext = new ReactApplicationContext(mApplicationContext);

    NativeModuleCallExceptionHandler exceptionHandler =
        mNativeModuleCallExceptionHandler != null
            ? mNativeModuleCallExceptionHandler
            : mDevSupportManager;
    reactContext.setNativeModuleCallExceptionHandler(exceptionHandler);

    NativeModuleRegistry nativeModuleRegistry = processPackages(reactContext, mPackages, false);

    CatalystInstanceImpl.Builder catalystInstanceBuilder =
        new CatalystInstanceImpl.Builder()
            .setReactQueueConfigurationSpec(ReactQueueConfigurationSpec.createDefault())
            .setJSExecutor(jsExecutor)
            .setRegistry(nativeModuleRegistry)
            .setJSBundleLoader(jsBundleLoader)
            .setNativeModuleCallExceptionHandler(exceptionHandler);

    final CatalystInstance catalystInstance;
    try {
      catalystInstance = catalystInstanceBuilder.build();
    } finally {

    }

    reactContext.initializeWithInstance(catalystInstance);

    if (mJSIModulePackage != null) {
      catalystInstance.addJSIModules(
          mJSIModulePackage.getJSIModules(
              reactContext, catalystInstance.getJavaScriptContextHolder()));

      if (ReactFeatureFlags.useTurboModules) {
        JSIModule turboModuleManager =
            catalystInstance.getJSIModule(JSIModuleType.TurboModuleManager);
        catalystInstance.setTurboModuleManager(turboModuleManager);

        TurboModuleRegistry registry = (TurboModuleRegistry) turboModuleManager;

        for (String moduleName : registry.getEagerInitModuleNames()) {
          registry.getModule(moduleName);
        }
      }
    }
    if (mBridgeIdleDebugListener != null) {
      catalystInstance.addBridgeIdleDebugListener(mBridgeIdleDebugListener);
    }

    catalystInstance.runJSBundle();

    return reactContext;
  }
```
- 构建CatalystInstanceImpl 初始化所有的模块到JSI
- initializeWithInstance 获取所有线程对象执行线程
- CatalystInstanceImpl runJSBundle 启动js

#### 7.1.1 CatalystInstanceImpl 初始化
```java
  private CatalystInstanceImpl(
      final ReactQueueConfigurationSpec reactQueueConfigurationSpec,
      final JavaScriptExecutor jsExecutor,
      final NativeModuleRegistry nativeModuleRegistry,
      final JSBundleLoader jsBundleLoader,
      NativeModuleCallExceptionHandler nativeModuleCallExceptionHandler) {
    mHybridData = initHybrid();

    mReactQueueConfiguration =
        ReactQueueConfigurationImpl.create(
            reactQueueConfigurationSpec, new NativeExceptionHandler());
    mBridgeIdleListeners = new CopyOnWriteArrayList<>();
    mNativeModuleRegistry = nativeModuleRegistry;
    mJSModuleRegistry = new JavaScriptModuleRegistry();
    mJSBundleLoader = jsBundleLoader;
    mNativeModuleCallExceptionHandler = nativeModuleCallExceptionHandler;
    mNativeModulesQueueThread = mReactQueueConfiguration.getNativeModulesQueueThread();
    mTraceListener = new JSProfilerTraceListener(this);

    initializeBridge(
        new BridgeCallback(this),
        jsExecutor,
        mReactQueueConfiguration.getJSQueueThread(),
        mNativeModulesQueueThread,
        mNativeModuleRegistry.getJavaModules(this),
        mNativeModuleRegistry.getCxxModules());


    mJavaScriptContextHolder = new JavaScriptContextHolder(getJavaScriptContext());
  }
```
- ReactQueueConfigurationImpl.create 初始化ui，nativeModule，js三个线程
- initializeBridge 注入到native中，把所有模块保存在到js的proxyNativeModule对象中

##### 7.1.1.1 初始化桥接对象
```java
void Instance::initializeBridge(
    std::unique_ptr<InstanceCallback> callback,
    std::shared_ptr<JSExecutorFactory> jsef,
    std::shared_ptr<MessageQueueThread> jsQueue,
    std::shared_ptr<ModuleRegistry> moduleRegistry) {
  callback_ = std::move(callback);
  moduleRegistry_ = std::move(moduleRegistry);
  jsQueue->runOnQueueSync([this, &jsef, jsQueue]() mutable {
    nativeToJsBridge_ = std::make_shared<NativeToJsBridge>(
        jsef.get(), moduleRegistry_, jsQueue, callback_);

    nativeToJsBridge_->initializeRuntime();
    jsCallInvoker_->setNativeToJsBridgeAndFlushCalls(nativeToJsBridge_);

    std::lock_guard<std::mutex> lock(m_syncMutex);
    m_syncReady = true;
    m_syncCV.notify_all();
  });

}
```

##### 7.1.1.2 nativeToJsBridge_  initializeRuntime

```cpp
void JSIExecutor::initializeRuntime() {
  SystraceSection s("JSIExecutor::initializeRuntime");
  runtime_->global().setProperty(
      *runtime_,
      "nativeModuleProxy",
      Object::createFromHostObject(
          *runtime_, std::make_shared<NativeModuleProxy>(nativeModules_)));

  runtime_->global().setProperty(
      *runtime_,
      "nativeFlushQueueImmediate",
      Function::createFromHostFunction(
          *runtime_,
          PropNameID::forAscii(*runtime_, "nativeFlushQueueImmediate"),
          1,
          [this](
              jsi::Runtime &,
              const jsi::Value &,
              const jsi::Value *args,
              size_t count) {
            if (count != 1) {
              throw std::invalid_argument(
                  "nativeFlushQueueImmediate arg count must be 1");
            }
            callNativeModules(args[0], false);
            return Value::undefined();
          }));

  runtime_->global().setProperty(
      *runtime_,
      "nativeCallSyncHook",
      Function::createFromHostFunction(
          *runtime_,
          PropNameID::forAscii(*runtime_, "nativeCallSyncHook"),
          1,
          [this](
              jsi::Runtime &,
              const jsi::Value &,
              const jsi::Value *args,
              size_t count) { return nativeCallSyncHook(args, count); }));

  if (runtimeInstaller_) {
    runtimeInstaller_(*runtime_);
  }

}
```
- 往js运行环境runtime中注入 nativeModuleProxy 对象获取通信本地Java/C++模块
- 往js运行环境runtime中注入 nativeFlushQueueImmediate 用于执行方法
- 往js运行环境runtime中注 nativeCallSyncHook 用于执行同步方法

##### 7.1.1.2 线程实例化
```java
 private ReactQueueConfigurationImpl(
      MessageQueueThreadImpl uiQueueThread,
      MessageQueueThreadImpl nativeModulesQueueThread,
      MessageQueueThreadImpl jsQueueThread) {
    mUIQueueThread = uiQueueThread;
    mNativeModulesQueueThread = nativeModulesQueueThread;
    mJSQueueThread = jsQueueThread;
  }
```


#### 7.1.2 CatalystInstanceImpl  runJSBundle
```java
 public void runJSBundle() {
    mJSBundleLoader.loadScript(CatalystInstanceImpl.this);

    synchronized (mJSCallsPendingInitLock) {

      mAcceptCalls = true;

      for (PendingJSCall function : mJSCallsPendingInit) {
        function.call(this);
      }
      mJSCallsPendingInit.clear();
      mJSBundleHasLoaded = true;
    }

  }
```
- 通过 `jniLoadScriptFromAssets` 读取asset下的文件对象

```cpp
__attribute__((visibility("default"))) std::unique_ptr<const JSBigString>
loadScriptFromAssets(AAssetManager *manager, const std::string &assetName) {
#ifdef WITH_FBSYSTRACE
  FbSystraceSection s(
      TRACE_TAG_REACT_CXX_BRIDGE,
      "reactbridge_jni_loadScriptFromAssets",
      "assetName",
      assetName);
#endif
  if (manager) {
    auto asset = AAssetManager_open(
        manager,
        assetName.c_str(),
        AASSET_MODE_STREAMING); // Optimized for sequential read: see
                                // AssetManager.java for docs
    if (asset) {
      auto buf = std::make_unique<JSBigBufferString>(AAsset_getLength(asset));
      size_t offset = 0;
      int readbytes;
      while ((readbytes = AAsset_read(
                  asset, buf->data() + offset, buf->size() - offset)) > 0) {
        offset += readbytes;
      }
      AAsset_close(asset);
      if (offset == buf->size()) {
        return std::move(buf);
      }
    }
  }

}
```
获取路径下所有的string资源

##### 7.1.3 Instance loadBundle

```cpp
void Instance::loadBundle(
    std::unique_ptr<RAMBundleRegistry> bundleRegistry,
    std::unique_ptr<const JSBigString> string,
    std::string sourceURL) {
  callback_->incrementPendingJSCalls();
  SystraceSection s("Instance::loadBundle", "sourceURL", sourceURL);
  nativeToJsBridge_->loadBundle(
      std::move(bundleRegistry), std::move(string), std::move(sourceURL));
}
```

```cpp
void NativeToJsBridge::loadBundle(
    std::unique_ptr<RAMBundleRegistry> bundleRegistry,
    std::unique_ptr<const JSBigString> startupScript,
    std::string startupScriptSourceURL) {
  runOnExecutorQueue(
      [this,
       bundleRegistryWrap = folly::makeMoveWrapper(std::move(bundleRegistry)),
       startupScript = folly::makeMoveWrapper(std::move(startupScript)),
       startupScriptSourceURL =
           std::move(startupScriptSourceURL)](JSExecutor *executor) mutable {
        auto bundleRegistry = bundleRegistryWrap.move();
        if (bundleRegistry) {
          executor->setBundleRegistry(std::move(bundleRegistry));
        }
        try {
          executor->loadBundle(
              std::move(*startupScript), std::move(startupScriptSourceURL));
        } catch (...) {
          m_applicationScriptHasFailure = true;
          throw;
        }
      });
}
```

```cpp
void JSIExecutor::loadBundle(
    std::unique_ptr<const JSBigString> script,
    std::string sourceURL) {

  std::string scriptName = simpleBasename(sourceURL);
  if (hasLogger) {
    ReactMarker::logTaggedMarker(
        ReactMarker::RUN_JS_BUNDLE_START, scriptName.c_str());
  }
  runtime_->evaluateJavaScript(
      std::make_unique<BigStringBuffer>(std::move(script)), sourceURL);
  flush();
}
```

```cpp
jsi::Value JSCRuntime::evaluateJavaScript(
    const std::shared_ptr<const jsi::Buffer> &buffer,
    const std::string &sourceURL) {
  std::string tmp(
      reinterpret_cast<const char *>(buffer->data()), buffer->size());
  JSStringRef sourceRef = JSStringCreateWithUTF8CString(tmp.c_str());
  JSStringRef sourceURLRef = nullptr;
  if (!sourceURL.empty()) {
    sourceURLRef = JSStringCreateWithUTF8CString(sourceURL.c_str());
  }
  JSValueRef exc = nullptr;
  JSValueRef res =
      JSEvaluateScript(ctx_, sourceRef, nullptr, sourceURLRef, 0, &exc);
  JSStringRelease(sourceRef);
  if (sourceURLRef) {
    JSStringRelease(sourceURLRef);
  }
  checkException(res, exc);
  return createValue(res);
}
```

最后转化为`JSEvaluateScript`构建了一个js运行对象在底层.
```java
JSGlobalContextRef ctx_;
```

资源加载到了runtime中，得以运行。

#### 7.2 setupReactContext 回调初始化Context完毕，初始化initialize告诉js端java模块加载完毕，设置线程优先级
```java
  private void setupReactContext(final ReactApplicationContext reactContext) {
    Log.d(ReactConstants.TAG, "ReactInstanceManager.setupReactContext()");
    ReactMarker.logMarker(PRE_SETUP_REACT_CONTEXT_END);
    ReactMarker.logMarker(SETUP_REACT_CONTEXT_START);
    Systrace.beginSection(TRACE_TAG_REACT_JAVA_BRIDGE, "setupReactContext");
    synchronized (mAttachedReactRoots) {
      synchronized (mReactContextLock) {
        mCurrentReactContext = Assertions.assertNotNull(reactContext);
      }

      CatalystInstance catalystInstance =
          Assertions.assertNotNull(reactContext.getCatalystInstance());

      catalystInstance.initialize();

      mDevSupportManager.onNewReactContextCreated(reactContext);
      mMemoryPressureRouter.addMemoryPressureListener(catalystInstance);
      moveReactContextToCurrentLifecycleState();

      for (ReactRoot reactRoot : mAttachedReactRoots) {
        attachRootViewToInstance(reactRoot);
      }
     
    }
....
    reactContext.runOnJSQueueThread(
        new Runnable() {
          @Override
          public void run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT);
          }
        });
    reactContext.runOnNativeModulesQueueThread(
        new Runnable() {
          @Override
          public void run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT);
          }
        });
  }

```

#### 7.3 attachRootViewToInstance ReactRootView设置RootTag和initialProperties
```java
  private void attachRootViewToInstance(final ReactRoot reactRoot) {


    UIManager uiManager =
        UIManagerHelper.getUIManager(mCurrentReactContext, reactRoot.getUIManagerType());

    @Nullable Bundle initialProperties = reactRoot.getAppProperties();

    final int rootTag =
        uiManager.addRootView(
            reactRoot.getRootViewGroup(),
            initialProperties == null
                ? new WritableNativeMap()
                : Arguments.fromBundle(initialProperties),
            reactRoot.getInitialUITemplate());
    reactRoot.setRootViewTag(rootTag);
    if (reactRoot.getUIManagerType() == FABRIC) {
...
    } else {
      reactRoot.runApplication();
    }

    UiThreadUtil.runOnUiThread(
        new Runnable() {
          @Override
          public void run() {

            reactRoot.onStage(ReactStage.ON_ATTACH_TO_INSTANCE);
          }
        });
  }
```
- UIManagerModule addRootView 
- ReactRootView  runApplication

#### 7.4 UIManagerModule addRootView 
```java
  public <T extends View> int addRootView(
      final T rootView, WritableMap initialProps, @Nullable String initialUITemplate) {
  
    final int tag = ReactRootViewTagGenerator.getNextRootViewTag();
    final ReactApplicationContext reactApplicationContext = getReactApplicationContext();
    final ThemedReactContext themedRootContext =
        new ThemedReactContext(
            reactApplicationContext, rootView.getContext(), ((ReactRoot) rootView).getSurfaceID());

    mUIImplementation.registerRootView(rootView, tag, themedRootContext);

  }
```

#### 7.4.1 UIImplementation registerRootView
```java
  public <T extends View> void registerRootView(T rootView, int tag, ThemedReactContext context) {
    synchronized (uiImplementationThreadLock) {
      final ReactShadowNode rootCSSNode = createRootShadowNode();
      rootCSSNode.setReactTag(tag); // Thread safety needed here
      rootCSSNode.setThemedContext(context);

      context.runOnNativeModulesQueueThread(
          new Runnable() {
            @Override
            public void run() {
              mShadowNodeRegistry.addRootNode(rootCSSNode);
            }
          });

      // register it within NativeViewHierarchyManager
      mOperationsQueue.addRootView(tag, rootView);
    }
  }
```
构建了一个ShadowNode作为根部的Node，在NativeModule线程汇总执行addRootNode。

#### 7.4.1.2 ShadowNodeRegistry.addRootNode
```java
  public void addRootNode(ReactShadowNode node) {
    mThreadAsserter.assertNow();
    int tag = node.getReactTag();
    mTagsToCSSNodes.put(tag, node);
    mRootTags.put(tag, true);
  }
```

mOperationsQueue.addRootView  实际上执行的是NativeViewHierarchyManager 

```java
  public synchronized void addRootView(int tag, View view) {
    addRootViewGroup(tag, view);
  }

  protected final synchronized void addRootViewGroup(int tag, View view) {

    mTagsToViews.put(tag, view);
    mTagsToViewManagers.put(tag, mRootViewManager);
    mRootTags.put(tag, true);
    view.setId(tag);
  }
```
view的id就是Tag，此时就是1.


#### 7.4 ReactRootView runApplication
```java
  public void runApplication() {
    try {
      if (mReactInstanceManager == null || !mIsAttachedToInstance) {
        return;
      }

      ReactContext reactContext = mReactInstanceManager.getCurrentReactContext();
      if (reactContext == null) {
        return;
      }

      CatalystInstance catalystInstance = reactContext.getCatalystInstance();
      String jsAppModuleName = getJSModuleName();

      if (mUseSurface) {
        // TODO call surface's runApplication
      } else {
        if (mWasMeasured) {
          updateRootLayoutSpecs(mWidthMeasureSpec, mHeightMeasureSpec);
        }

        WritableNativeMap appParams = new WritableNativeMap();
        appParams.putDouble("rootTag", getRootViewTag());
        @Nullable Bundle appProperties = getAppProperties();
        if (appProperties != null) {
          appParams.putMap("initialProps", Arguments.fromBundle(appProperties));
        }

        mShouldLogContentAppeared = true;

        catalystInstance.getJSModule(AppRegistry.class).runApplication(jsAppModuleName, appParams);
      }
    } finally {

    }
  }
```
通过catalystInstance.getJSModule 获取JS中AppRegistry对象，调用runApplication方法，并传输之前设置的Bundle。

最简单的例子：

```javascript
AppRegistry.registerComponent(appName, () => App);
```
## js端初始化原理

### 8. registerComponent 注册组件
```javascript
 registerComponent(
    appKey: string,
    componentProvider: ComponentProvider,
    section?: boolean,
  ): string {
    let scopedPerformanceLogger = createPerformanceLogger();
    runnables[appKey] = {
      componentProvider,
      run: appParameters => {
        renderApplication(
          componentProviderInstrumentationHook(
            componentProvider,
            scopedPerformanceLogger,
          ),
          appParameters.initialProps,
          appParameters.rootTag,
          wrapperComponentProvider && wrapperComponentProvider(appParameters),
          appParameters.fabric,
          showArchitectureIndicator,
          scopedPerformanceLogger,
          appKey === 'LogBox',
        );
      },
    };
    if (section) {
      sections[appKey] = runnables[appKey];
    }
    return appKey;
  },
```

注册了一个组件到runnables 数组中。这个runnables 是一个指代执行renderApplication方法。

### 9.AppRegistry runApplication

```javascript
runApplication(appKey: string, appParameters: any): void {
    if (appKey !== 'LogBox') {
      const msg =
        'Running "' + appKey + '" with ' + JSON.stringify(appParameters);
      infoLog(msg);
      BugReporting.addSource(
        'AppRegistry.runApplication' + runCount++,
        () => msg,
      );
    }


    SceneTracker.setActiveScene({name: appKey});
    runnables[appKey].run(appParameters);
  }
```
执行所有的runnables方法，并把Android/iOS端传入的appParameters一起传递下去。

### 10. renderApplication.js  renderApplication
```javascript
function renderApplication<Props: Object>(
  RootComponent: React.ComponentType<Props>,
  initialProps: Props,
  rootTag: any,
  WrapperComponent?: ?React.ComponentType<*>,
  fabric?: boolean,
  showArchitectureIndicator?: boolean,
  scopedPerformanceLogger?: IPerformanceLogger,
  isLogBox?: boolean,
) {

  const performanceLogger = scopedPerformanceLogger ?? GlobalPerformanceLogger;

  const renderable = (
    <PerformanceLoggerContext.Provider value={performanceLogger}>
      <AppContainer
        rootTag={rootTag}
        fabric={fabric}
        showArchitectureIndicator={showArchitectureIndicator}
        WrapperComponent={WrapperComponent}
        initialProps={initialProps ?? Object.freeze({})}
        internal_excludeLogBox={isLogBox}>
        <RootComponent {...initialProps} rootTag={rootTag} />
      </AppContainer>
    </PerformanceLoggerContext.Provider>
  );
  if (fabric) {
    require('../Renderer/shims/ReactFabric').render(renderable, rootTag);
  } else {
    require('../Renderer/shims/ReactNative').render(renderable, rootTag);
  }

}

module.exports = renderApplication;
```

构建一个renderable 的jsx对象(实际上可以想象成编译时转化，转化成React.createElement)。

- PerformanceLoggerContext.Provider 日志的上下文打印
- AppContainer RN 最根部的组件

- 1.是fabric执行ReactFabric的render
- 2.传统执行ReactNative render

先来看ReactNative render.

### 11. ReactNative render
```javascript
if (__DEV__) {
  ReactNative = require('../implementations/ReactNativeRenderer-dev');
} else {
  ReactNative = require('../implementations/ReactNativeRenderer-prod');
}
```
生产包执行ReactNativeRenderer-prod.

### 12. ReactNativeRenderer-prod. render
```javascript
exports.render = function(element, containerTag, callback) {
  var root = roots.get(containerTag);
  if (!root) {
    root = new FiberRootNode(containerTag, 0, !1);
    var uninitializedFiber = new FiberNode(3, null, null, 0);
    root.current = uninitializedFiber;
    uninitializedFiber.stateNode = root;
    initializeUpdateQueue(uninitializedFiber);
    roots.set(containerTag, root);
  }
  updateContainer(element, root, null, callback);
  a: if (((element = root.current), element.child))
    switch (element.child.tag) {
      case 5:
        element = element.child.stateNode;
        break a;
      default:
        element = element.child.stateNode;
    }
  else element = null;
  return element;
}

function initializeUpdateQueue(fiber) {
  fiber.updateQueue = {
    baseState: fiber.memoizedState,
    baseQueue: null,
    shared: { pending: null },
    effects: null
  };
}
```
- 1.生成 FiberRootNode 根部React DoM对象
- 2.生成FiberNode 非根部React DoM对象
- 3. initializeUpdateQueue 初始化FiberNode中的updateQueue对象
- 4. updateContainer 开始初始化遍历RootDOM 后渲染

#### 13. updateContainer
```javascript
function updateContainer(element, container, parentComponent, callback) {
  var current = container.current,
    currentTime = requestCurrentTimeForUpdate(),
    suspenseConfig = ReactCurrentBatchConfig.suspense;
  currentTime = computeExpirationForFiber(currentTime, current, suspenseConfig);
...
  container = createUpdate(currentTime, suspenseConfig);
  container.payload = { element: element };
  callback = void 0 === callback ? null : callback;
  null !== callback && (container.callback = callback);
  enqueueUpdate(current, container);
  scheduleWork(current, currentTime);
  return currentTime;
}
```
- 1.构造更新状态

```javascript
function createUpdate(expirationTime, suspenseConfig) {
  expirationTime = {
    expirationTime: expirationTime,
    suspenseConfig: suspenseConfig,
    tag: 0,
    payload: null,
    callback: null,
    next: null
  };
  return (expirationTime.next = expirationTime);
}
```

- 2.enqueueUpdate 更新对象进入到FiberNode的updateQueue队列

```javascript
function enqueueUpdate(fiber, update) {
  fiber = fiber.updateQueue;
  if (null !== fiber) {
    fiber = fiber.shared;
    var pending = fiber.pending;
    null === pending
      ? (update.next = update)
      : ((update.next = pending.next), (pending.next = update));
    fiber.pending = update;
  }
}
```
如果没有pending 则把update放到update的末尾，如果有pending的next放到update的next，pending的next放到update中。就是说pending和update合并起来

更新pending链表为update。

- 3. scheduleWork 开始渲染

#### 14.scheduleWork
```javascript
function scheduleWork(fiber, expirationTime) {
...
  fiber = markUpdateTimeFromFiberToRoot(fiber, expirationTime);
  if (null !== fiber) {
    var priorityLevel = getCurrentPriorityLevel();
    1073741823 === expirationTime
      ? (executionContext & LegacyUnbatchedContext) !== NoContext &&
        (executionContext & (RenderContext | CommitContext)) === NoContext
        ? performSyncWorkOnRoot(fiber)
        : (ensureRootIsScheduled(fiber),
          executionContext === NoContext && flushSyncCallbackQueue())
      : ensureRootIsScheduled(fiber);
    (executionContext & 4) === NoContext ||
      (98 !== priorityLevel && 99 !== priorityLevel) ||
      (null === rootsWithPendingDiscreteUpdates
        ? (rootsWithPendingDiscreteUpdates = new Map([[fiber, expirationTime]]))
        : ((priorityLevel = rootsWithPendingDiscreteUpdates.get(fiber)),
          (void 0 === priorityLevel || priorityLevel > expirationTime) &&
            rootsWithPendingDiscreteUpdates.set(fiber, expirationTime)));
  }
}
```

- 第一次渲染走performSyncWorkOnRoot
- 之后的渲染，先通过ensureRootIsScheduled 加入到syncQueue中，通过Scheduler 循环调度，根据每一个Node的优先级执行performSyncWorkOnRoot

#### 15.performSyncWorkOnRoot
```javascript
function performSyncWorkOnRoot(root) {

  if (
    root === workInProgressRoot &&
    0 !== (root.expiredLanes & workInProgressRootRenderLanes)
  ) {
    var lanes = workInProgressRootRenderLanes;
    var exitStatus = renderRootSync(root, lanes);
    0 !== (workInProgressRootIncludedLanes & workInProgressRootUpdatedLanes) &&
      ((lanes = getNextLanes(root, lanes)),
      (exitStatus = renderRootSync(root, lanes)));
  } else
    (lanes = getNextLanes(root, 0)), (exitStatus = renderRootSync(root, lanes));
  0 !== root.tag &&
    2 === exitStatus &&
    ((executionContext |= 64),
    root.hydrate && (root.hydrate = !1),
    (lanes = getLanesToRetrySynchronouslyOnError(root)),
    0 !== lanes && (exitStatus = renderRootSync(root, lanes)));

  root.finishedWork = root.current.alternate;
  root.finishedLanes = lanes;
  commitRoot(root);
  ensureRootIsScheduled(root, now());
  return null;
}
```
- renderRootSync 绒布从根部刷新Render DOM
- commitRoot 提交根部开始的刷新行为
- ensureRootIsScheduled 确定根部是否在调度

##### 15.1 renderRootSync
```javascript
function renderRootSync(root, expirationTime) {
  var prevExecutionContext = executionContext;
  executionContext |= RenderContext;
  var prevDispatcher = pushDispatcher();
  (root === workInProgressRoot && expirationTime === renderExpirationTime$1) ||
    prepareFreshStack(root, expirationTime);
  do
    try {
      workLoopSync();
      break;
    } catch (thrownValue) {
      handleError(root, thrownValue);
    }
  while (1);
  resetContextDependencies();
  executionContext = prevExecutionContext;
  ReactCurrentDispatcher$1.current = prevDispatcher;

  workInProgressRoot = null;
  return workInProgressRootExitStatus;
}
```
- 1. prepareFreshStack 准备刷新的栈。从上一次遍历刷新到的最深的ReactNode 开始向上推出栈，推出所有的Context，Container。并且通过createWorkInProgress为每一个孩子创建一个FiberNode
- workLoopSync进入到工作的loop
- 重新设置上下文的依赖
- 设置ReactCurrentDispatcher的current为prevDispatcher

##### 15.1.1 workLoopSync
```javascript
function workLoopSync() {
  for (; null !== workInProgress; )
    workInProgress = performUnitOfWork(workInProgress);
}

function performUnitOfWork(unitOfWork) {
  var next = beginWork$1(
    unitOfWork.alternate,
    unitOfWork,
    renderExpirationTime$1
  );
  unitOfWork.memoizedProps = unitOfWork.pendingProps;
  null === next && (next = completeUnitOfWork(unitOfWork));
  ReactCurrentOwner$2.current = null;
  return next;
}
```
- 1.beginWork 开始构造组件
- 2. completeUnitOfWork 完成工作

##### 15.1.1.1 beginWork
```javascript
beginWork$1 = function(current, workInProgress, renderExpirationTime) {
  var updateExpirationTime = workInProgress.expirationTime;
  if (null !== current)
    if (
      current.memoizedProps !== workInProgress.pendingProps ||
      didPerformWorkStackCursor.current
    )
      didReceiveUpdate = !0;
    else {
      if (updateExpirationTime < renderExpirationTime) {
        didReceiveUpdate = !1;
        switch (workInProgress.tag) {
          case 3:
            pushHostRootContext(workInProgress);
            break;
          case 5:
            pushHostContext(workInProgress);
            break;
          case 1:
            isContextProvider(workInProgress.type) &&
              pushContextProvider(workInProgress);
            break;
          case 4:
            pushHostContainer(
              workInProgress,
              workInProgress.stateNode.containerInfo
            );
            break;
          case 10:
            updateExpirationTime = workInProgress.memoizedProps.value;
            var context = workInProgress.type._context;
            push(valueCursor, context._currentValue);
            context._currentValue = updateExpirationTime;
            break;
          case 13:
            if (null !== workInProgress.memoizedState) {
              updateExpirationTime = workInProgress.child.childExpirationTime;
              if (
                0 !== updateExpirationTime &&
                updateExpirationTime >= renderExpirationTime
              )
                return updateSuspenseComponent(
                  current,
                  workInProgress,
                  renderExpirationTime
                );
              push(suspenseStackCursor, suspenseStackCursor.current & 1);
              workInProgress = bailoutOnAlreadyFinishedWork(
                current,
                workInProgress,
                renderExpirationTime
              );
              return null !== workInProgress ? workInProgress.sibling : null;
            }
            push(suspenseStackCursor, suspenseStackCursor.current & 1);
            break;
          case 19:
            updateExpirationTime =
              workInProgress.childExpirationTime >= renderExpirationTime;
            if (0 !== (current.effectTag & 64)) {
              if (updateExpirationTime)
                return updateSuspenseListComponent(
                  current,
                  workInProgress,
                  renderExpirationTime
                );
              workInProgress.effectTag |= 64;
            }
            context = workInProgress.memoizedState;
            null !== context &&
              ((context.rendering = null), (context.tail = null));
            push(suspenseStackCursor, suspenseStackCursor.current);
            if (!updateExpirationTime) return null;
        }
        return bailoutOnAlreadyFinishedWork(
          current,
          workInProgress,
          renderExpirationTime
        );
      }
      didReceiveUpdate = !1;
    }
  else didReceiveUpdate = !1;
  workInProgress.expirationTime = 0;
  switch (workInProgress.tag) {
    case 2:
      updateExpirationTime = workInProgress.type;
      null !== current &&
        ((current.alternate = null),
        (workInProgress.alternate = null),
        (workInProgress.effectTag |= 2));
      current = workInProgress.pendingProps;
      context = getMaskedContext(workInProgress, contextStackCursor.current);
      prepareToReadContext(workInProgress, renderExpirationTime);
      context = renderWithHooks(
        null,
        workInProgress,
        updateExpirationTime,
        current,
        context,
        renderExpirationTime
      );
      workInProgress.effectTag |= 1;
      if (
        "object" === typeof context &&
        null !== context &&
        "function" === typeof context.render &&
        void 0 === context.$$typeof
      ) {
        workInProgress.tag = 1;
        workInProgress.memoizedState = null;
        workInProgress.updateQueue = null;
        if (isContextProvider(updateExpirationTime)) {
          var hasContext = !0;
          pushContextProvider(workInProgress);
        } else hasContext = !1;
        workInProgress.memoizedState =
          null !== context.state && void 0 !== context.state
            ? context.state
            : null;
        initializeUpdateQueue(workInProgress);
        var getDerivedStateFromProps =
          updateExpirationTime.getDerivedStateFromProps;
        "function" === typeof getDerivedStateFromProps &&
          applyDerivedStateFromProps(
            workInProgress,
            updateExpirationTime,
            getDerivedStateFromProps,
            current
          );
        context.updater = classComponentUpdater;
        workInProgress.stateNode = context;
        context._reactInternalFiber = workInProgress;
        mountClassInstance(
          workInProgress,
          updateExpirationTime,
          current,
          renderExpirationTime
        );
        workInProgress = finishClassComponent(
          null,
          workInProgress,
          updateExpirationTime,
          !0,
          hasContext,
          renderExpirationTime
        );
      } else
        (workInProgress.tag = 0),
          reconcileChildren(
            null,
            workInProgress,
            context,
            renderExpirationTime
          ),
          (workInProgress = workInProgress.child);
      return workInProgress;
    case 16:
      a: {
        context = workInProgress.elementType;
        null !== current &&
          ((current.alternate = null),
          (workInProgress.alternate = null),
          (workInProgress.effectTag |= 2));
        current = workInProgress.pendingProps;
        initializeLazyComponentType(context);
        if (1 !== context._status) throw context._result;
        context = context._result;
        workInProgress.type = context;
        hasContext = workInProgress.tag = resolveLazyComponentTag(context);
        current = resolveDefaultProps(context, current);
        switch (hasContext) {
          case 0:
            workInProgress = updateFunctionComponent(
              null,
              workInProgress,
              context,
              current,
              renderExpirationTime
            );
            break a;
          case 1:
            workInProgress = updateClassComponent(
              null,
              workInProgress,
              context,
              current,
              renderExpirationTime
            );
            break a;
          case 11:
            workInProgress = updateForwardRef(
              null,
              workInProgress,
              context,
              current,
              renderExpirationTime
            );
            break a;
          case 14:
            workInProgress = updateMemoComponent(
              null,
              workInProgress,
              context,
              resolveDefaultProps(context.type, current),
              updateExpirationTime,
              renderExpirationTime
            );
            break a;
        }
        throw Error(
          "Element type is invalid. Received a promise that resolves to: " +
            context +
            ". Lazy element type must resolve to a class or function."
        );
      }
      return workInProgress;
    case 0:
      return (
        (updateExpirationTime = workInProgress.type),
        (context = workInProgress.pendingProps),
        (context =
          workInProgress.elementType === updateExpirationTime
            ? context
            : resolveDefaultProps(updateExpirationTime, context)),
        updateFunctionComponent(
          current,
          workInProgress,
          updateExpirationTime,
          context,
          renderExpirationTime
        )
      );
    case 1:
      return (
        (updateExpirationTime = workInProgress.type),
        (context = workInProgress.pendingProps),
        (context =
          workInProgress.elementType === updateExpirationTime
            ? context
            : resolveDefaultProps(updateExpirationTime, context)),
        updateClassComponent(
          current,
          workInProgress,
          updateExpirationTime,
          context,
          renderExpirationTime
        )
      );
    case 3:
      pushHostRootContext(workInProgress);
      updateExpirationTime = workInProgress.updateQueue;
      if (null === current || null === updateExpirationTime)
        throw Error(
          "If the root does not have an updateQueue, we should have already bailed out. This error is likely caused by a bug in React. Please file an issue."
        );
      updateExpirationTime = workInProgress.pendingProps;
      context = workInProgress.memoizedState;
      context = null !== context ? context.element : null;
      cloneUpdateQueue(current, workInProgress);
      processUpdateQueue(
        workInProgress,
        updateExpirationTime,
        null,
        renderExpirationTime
      );
      updateExpirationTime = workInProgress.memoizedState.element;
      updateExpirationTime === context
        ? (workInProgress = bailoutOnAlreadyFinishedWork(
            current,
            workInProgress,
            renderExpirationTime
          ))
        : (reconcileChildren(
            current,
            workInProgress,
            updateExpirationTime,
            renderExpirationTime
          ),
          (workInProgress = workInProgress.child));
      return workInProgress;
    case 5:
      return (
        pushHostContext(workInProgress),
        (updateExpirationTime = workInProgress.pendingProps.children),
        markRef(current, workInProgress),
        reconcileChildren(
          current,
          workInProgress,
          updateExpirationTime,
          renderExpirationTime
        ),
        (workInProgress = workInProgress.child),
        workInProgress
      );
    case 6:
      return null;
    case 13:
      return updateSuspenseComponent(
        current,
        workInProgress,
        renderExpirationTime
      );
    case 4:
      return (
        pushHostContainer(
          workInProgress,
          workInProgress.stateNode.containerInfo
        ),
        (updateExpirationTime = workInProgress.pendingProps),
        null === current
          ? (workInProgress.child = reconcileChildFibers(
              workInProgress,
              null,
              updateExpirationTime,
              renderExpirationTime
            ))
          : reconcileChildren(
              current,
              workInProgress,
              updateExpirationTime,
              renderExpirationTime
            ),
        workInProgress.child
      );
    case 11:
      return (
        (updateExpirationTime = workInProgress.type),
        (context = workInProgress.pendingProps),
        (context =
          workInProgress.elementType === updateExpirationTime
            ? context
            : resolveDefaultProps(updateExpirationTime, context)),
        updateForwardRef(
          current,
          workInProgress,
          updateExpirationTime,
          context,
          renderExpirationTime
        )
      );
    case 7:
      return (
        reconcileChildren(
          current,
          workInProgress,
          workInProgress.pendingProps,
          renderExpirationTime
        ),
        workInProgress.child
      );
    case 8:
      return (
        reconcileChildren(
          current,
          workInProgress,
          workInProgress.pendingProps.children,
          renderExpirationTime
        ),
        workInProgress.child
      );
    case 12:
      return (
        reconcileChildren(
          current,
          workInProgress,
          workInProgress.pendingProps.children,
          renderExpirationTime
        ),
        workInProgress.child
      );
    case 10:
      a: {
        updateExpirationTime = workInProgress.type._context;
        context = workInProgress.pendingProps;
        getDerivedStateFromProps = workInProgress.memoizedProps;
        hasContext = context.value;
        var context$jscomp$0 = workInProgress.type._context;
        push(valueCursor, context$jscomp$0._currentValue);
        context$jscomp$0._currentValue = hasContext;
        if (null !== getDerivedStateFromProps)
          if (
            ((context$jscomp$0 = getDerivedStateFromProps.value),
            (hasContext = objectIs(context$jscomp$0, hasContext)
              ? 0
              : ("function" ===
                typeof updateExpirationTime._calculateChangedBits
                  ? updateExpirationTime._calculateChangedBits(
                      context$jscomp$0,
                      hasContext
                    )
                  : 1073741823) | 0),
            0 === hasContext)
          ) {
            if (
              getDerivedStateFromProps.children === context.children &&
              !didPerformWorkStackCursor.current
            ) {
              workInProgress = bailoutOnAlreadyFinishedWork(
                current,
                workInProgress,
                renderExpirationTime
              );
              break a;
            }
          } else
            for (
              context$jscomp$0 = workInProgress.child,
                null !== context$jscomp$0 &&
                  (context$jscomp$0.return = workInProgress);
              null !== context$jscomp$0;

            ) {
              var list = context$jscomp$0.dependencies;
              if (null !== list) {
                getDerivedStateFromProps = context$jscomp$0.child;
                for (
                  var dependency = list.firstContext;
                  null !== dependency;

                ) {
                  if (
                    dependency.context === updateExpirationTime &&
                    0 !== (dependency.observedBits & hasContext)
                  ) {
                    1 === context$jscomp$0.tag &&
                      ((dependency = createUpdate(renderExpirationTime, null)),
                      (dependency.tag = 2),
                      enqueueUpdate(context$jscomp$0, dependency));
                    context$jscomp$0.expirationTime < renderExpirationTime &&
                      (context$jscomp$0.expirationTime = renderExpirationTime);
                    dependency = context$jscomp$0.alternate;
                    null !== dependency &&
                      dependency.expirationTime < renderExpirationTime &&
                      (dependency.expirationTime = renderExpirationTime);
                    scheduleWorkOnParentPath(
                      context$jscomp$0.return,
                      renderExpirationTime
                    );
                    list.expirationTime < renderExpirationTime &&
                      (list.expirationTime = renderExpirationTime);
                    break;
                  }
                  dependency = dependency.next;
                }
              } else
                getDerivedStateFromProps =
                  10 === context$jscomp$0.tag
                    ? context$jscomp$0.type === workInProgress.type
                      ? null
                      : context$jscomp$0.child
                    : context$jscomp$0.child;
              if (null !== getDerivedStateFromProps)
                getDerivedStateFromProps.return = context$jscomp$0;
              else
                for (
                  getDerivedStateFromProps = context$jscomp$0;
                  null !== getDerivedStateFromProps;

                ) {
                  if (getDerivedStateFromProps === workInProgress) {
                    getDerivedStateFromProps = null;
                    break;
                  }
                  context$jscomp$0 = getDerivedStateFromProps.sibling;
                  if (null !== context$jscomp$0) {
                    context$jscomp$0.return = getDerivedStateFromProps.return;
                    getDerivedStateFromProps = context$jscomp$0;
                    break;
                  }
                  getDerivedStateFromProps = getDerivedStateFromProps.return;
                }
              context$jscomp$0 = getDerivedStateFromProps;
            }
        reconcileChildren(
          current,
          workInProgress,
          context.children,
          renderExpirationTime
        );
        workInProgress = workInProgress.child;
      }
      return workInProgress;
    case 9:
      return (
        (context = workInProgress.type),
        (hasContext = workInProgress.pendingProps),
        (updateExpirationTime = hasContext.children),
        prepareToReadContext(workInProgress, renderExpirationTime),
        (context = readContext(context, hasContext.unstable_observedBits)),
        (updateExpirationTime = updateExpirationTime(context)),
        (workInProgress.effectTag |= 1),
        reconcileChildren(
          current,
          workInProgress,
          updateExpirationTime,
          renderExpirationTime
        ),
        workInProgress.child
      );
    case 14:
      return (
        (context = workInProgress.type),
        (hasContext = resolveDefaultProps(
          context,
          workInProgress.pendingProps
        )),
        (hasContext = resolveDefaultProps(context.type, hasContext)),
        updateMemoComponent(
          current,
          workInProgress,
          context,
          hasContext,
          updateExpirationTime,
          renderExpirationTime
        )
      );
    case 15:
      return updateSimpleMemoComponent(
        current,
        workInProgress,
        workInProgress.type,
        workInProgress.pendingProps,
        updateExpirationTime,
        renderExpirationTime
      );
    case 17:
      return (
        (updateExpirationTime = workInProgress.type),
        (context = workInProgress.pendingProps),
        (context =
          workInProgress.elementType === updateExpirationTime
            ? context
            : resolveDefaultProps(updateExpirationTime, context)),
        null !== current &&
          ((current.alternate = null),
          (workInProgress.alternate = null),
          (workInProgress.effectTag |= 2)),
        (workInProgress.tag = 1),
        isContextProvider(updateExpirationTime)
          ? ((current = !0), pushContextProvider(workInProgress))
          : (current = !1),
        prepareToReadContext(workInProgress, renderExpirationTime),
        constructClassInstance(workInProgress, updateExpirationTime, context),
        mountClassInstance(
          workInProgress,
          updateExpirationTime,
          context,
          renderExpirationTime
        ),
        finishClassComponent(
          null,
          workInProgress,
          updateExpirationTime,
          !0,
          current,
          renderExpirationTime
        )
      );
    case 19:
      return updateSuspenseListComponent(
        current,
        workInProgress,
        renderExpirationTime
      );
  }
  throw Error(
    "Unknown unit of work tag (" +
      workInProgress.tag +
      "). This error is likely caused by a bug in React. Please file an issue."
  );
};
```
- 1. updateFunctionComponent  更新方法组件
- 2. updateClassComponent 更新类组件

##### 15.1.1.2 updateFunctionComponent
```javascript
function updateFunctionComponent(
  current,
  workInProgress,
  Component,
  nextProps,
  renderExpirationTime
) {
  var context = isContextProvider(Component)
    ? previousContext
    : contextStackCursor.current;
  context = getMaskedContext(workInProgress, context);
  prepareToReadContext(workInProgress, renderExpirationTime);
  Component = renderWithHooks(
    current,
    workInProgress,
    Component,
    nextProps,
    context,
    renderExpirationTime
  );
  if (null !== current && !didReceiveUpdate)
    return (
      (workInProgress.updateQueue = current.updateQueue),
      (workInProgress.effectTag &= -517),
      current.expirationTime <= renderExpirationTime &&
        (current.expirationTime = 0),
      bailoutOnAlreadyFinishedWork(
        current,
        workInProgress,
        renderExpirationTime
      )
    );
  workInProgress.effectTag |= 1;
  reconcileChildren(current, workInProgress, Component, renderExpirationTime);
  return workInProgress.child;
}
```
- 1.核心是renderWithHooks方法，渲染的同时处理useState，useEffect
- 2. reconcileChildren
- 3. bailoutOnAlreadyFinishedWork

##### 15.1.1.3 renderWithHooks
```javascript
function renderWithHooks(
  current,
  workInProgress,
  Component,
  props,
  secondArg,
  nextRenderExpirationTime
) {
  renderExpirationTime = nextRenderExpirationTime;
  currentlyRenderingFiber$1 = workInProgress;
  workInProgress.memoizedState = null;
  workInProgress.updateQueue = null;
  workInProgress.expirationTime = 0;
  ReactCurrentDispatcher.current =
    null === current || null === current.memoizedState
      ? HooksDispatcherOnMount
      : HooksDispatcherOnUpdate;
  current = Component(props, secondArg);
  if (workInProgress.expirationTime === renderExpirationTime) {
    nextRenderExpirationTime = 0;
    do {
      workInProgress.expirationTime = 0;
      if (!(25 > nextRenderExpirationTime))
        throw Error(
          "Too many re-renders. React limits the number of renders to prevent an infinite loop."
        );
      nextRenderExpirationTime += 1;
      workInProgressHook = currentHook = null;
      workInProgress.updateQueue = null;
      ReactCurrentDispatcher.current = HooksDispatcherOnRerender;
      current = Component(props, secondArg);
    } while (workInProgress.expirationTime === renderExpirationTime);
  }
  ReactCurrentDispatcher.current = ContextOnlyDispatcher;
  workInProgress = null !== currentHook && null !== currentHook.next;
  renderExpirationTime = 0;
  workInProgressHook = currentHook = currentlyRenderingFiber$1 = null;
  didScheduleRenderPhaseUpdate = !1;
  if (workInProgress)
    throw Error(
      "Rendered fewer hooks than expected. This may be caused by an accidental early return statement."
    );
  return current;
}
```
根据当前的节点的情况设置hook处理函数：
- 1.如果是第一次渲染 HooksDispatcherOnMount
- 2.如果是非首次渲染 则设置HooksDispatcherOnUpdate

此时我们在组件中使用的useState和useEffect就是包装过的方法，其实不是一个东西。

```javascript
  HooksDispatcherOnUpdate = {
    readContext: readContext,
    useCallback: updateCallback,
    useContext: readContext,
    useEffect: updateEffect,
    useImperativeHandle: updateImperativeHandle,
    useLayoutEffect: updateLayoutEffect,
    useMemo: updateMemo,
    useReducer: updateReducer,
    useRef: updateRef,
    useState: function() {
      return updateReducer(basicStateReducer);
    },
...
  }
```

```javascript
  HooksDispatcherOnMount = {
    readContext: readContext,
    useCallback: mountCallback,
    useContext: readContext,
    useEffect: mountEffect,
    useImperativeHandle: function(ref, create, deps) {
      deps = null !== deps && void 0 !== deps ? deps.concat([ref]) : null;
      return mountEffectImpl(
        4,
        2,
        imperativeHandleEffect.bind(null, create, ref),
        deps
      );
    },
    useLayoutEffect: function(create, deps) {
      return mountEffectImpl(4, 2, create, deps);
    },
    useMemo: function(nextCreate, deps) {
      var hook = mountWorkInProgressHook();
      deps = void 0 === deps ? null : deps;
      nextCreate = nextCreate();
      hook.memoizedState = [nextCreate, deps];
      return nextCreate;
    },
    useReducer: function(reducer, initialArg, init) {
      var hook = mountWorkInProgressHook();
      initialArg = void 0 !== init ? init(initialArg) : initialArg;
      hook.memoizedState = hook.baseState = initialArg;
      reducer = hook.queue = {
        pending: null,
        dispatch: null,
        lastRenderedReducer: reducer,
        lastRenderedState: initialArg
      };
      reducer = reducer.dispatch = dispatchAction.bind(
        null,
        currentlyRenderingFiber$1,
        reducer
      );
      return [hook.memoizedState, reducer];
    },
    useRef: function(initialValue) {
      var hook = mountWorkInProgressHook();
      initialValue = { current: initialValue };
      return (hook.memoizedState = initialValue);
    },
    useState: mountState,
    useDebugValue: mountDebugValue,
...
  }
```

##### 15.1.1.4 reconcileChildren
```javascript
function reconcileChildren(
  current,
  workInProgress,
  nextChildren,
  renderExpirationTime
) {
  workInProgress.child =
    null === current
      ? mountChildFibers(
          workInProgress,
          null,
          nextChildren,
          renderExpirationTime
        )
      : reconcileChildFibers(
          workInProgress,
          current.child,
          nextChildren,
          renderExpirationTime
        );
}
```
```javascript
export const reconcileChildFibers = ChildReconciler(true);
export const mountChildFibers = ChildReconciler(false);
```
其实是同一个方法，只是首次为false，非首次为true。

##### ChildReconciler
```javascript 
  return function(returnFiber, currentFirstChild, newChild, expirationTime) {
    var isUnkeyedTopLevelFragment =
      "object" === typeof newChild &&
      null !== newChild &&
      newChild.type === REACT_FRAGMENT_TYPE &&
      null === newChild.key;
    isUnkeyedTopLevelFragment && (newChild = newChild.props.children);
    var isObject = "object" === typeof newChild && null !== newChild;
    if (isObject)
      switch (newChild.$$typeof) {
        case REACT_ELEMENT_TYPE:
          a: {
            isObject = newChild.key;
            for (
              isUnkeyedTopLevelFragment = currentFirstChild;
              null !== isUnkeyedTopLevelFragment;

            ) {
              if (isUnkeyedTopLevelFragment.key === isObject) {
                switch (isUnkeyedTopLevelFragment.tag) {
                  case 7:
                    if (newChild.type === REACT_FRAGMENT_TYPE) {
                      deleteRemainingChildren(
                        returnFiber,
                        isUnkeyedTopLevelFragment.sibling
                      );
                      currentFirstChild = useFiber(
                        isUnkeyedTopLevelFragment,
                        newChild.props.children
                      );
                      currentFirstChild.return = returnFiber;
                      returnFiber = currentFirstChild;
                      break a;
                    }
                    break;
                  default:
                    if (
                      isUnkeyedTopLevelFragment.elementType === newChild.type
                    ) {
                      deleteRemainingChildren(
                        returnFiber,
                        isUnkeyedTopLevelFragment.sibling
                      );
                      currentFirstChild = useFiber(
                        isUnkeyedTopLevelFragment,
                        newChild.props
                      );
                      currentFirstChild.ref = coerceRef(
                        returnFiber,
                        isUnkeyedTopLevelFragment,
                        newChild
                      );
                      currentFirstChild.return = returnFiber;
                      returnFiber = currentFirstChild;
                      break a;
                    }
                }
                deleteRemainingChildren(returnFiber, isUnkeyedTopLevelFragment);
                break;
              } else deleteChild(returnFiber, isUnkeyedTopLevelFragment);
              isUnkeyedTopLevelFragment = isUnkeyedTopLevelFragment.sibling;
            }
            newChild.type === REACT_FRAGMENT_TYPE
              ? ((currentFirstChild = createFiberFromFragment(
                  newChild.props.children,
                  returnFiber.mode,
                  expirationTime,
                  newChild.key
                )),
                (currentFirstChild.return = returnFiber),
                (returnFiber = currentFirstChild))
              : ((expirationTime = createFiberFromTypeAndProps(
                  newChild.type,
                  newChild.key,
                  newChild.props,
                  null,
                  returnFiber.mode,
                  expirationTime
                )),
                (expirationTime.ref = coerceRef(
                  returnFiber,
                  currentFirstChild,
                  newChild
                )),
                (expirationTime.return = returnFiber),
                (returnFiber = expirationTime));
          }
          return placeSingleChild(returnFiber);
        case REACT_PORTAL_TYPE:
          a: {
            for (
              isUnkeyedTopLevelFragment = newChild.key;
              null !== currentFirstChild;

            ) {
              if (currentFirstChild.key === isUnkeyedTopLevelFragment)
                if (
                  4 === currentFirstChild.tag &&
                  currentFirstChild.stateNode.containerInfo ===
                    newChild.containerInfo &&
                  currentFirstChild.stateNode.implementation ===
                    newChild.implementation
                ) {
                  deleteRemainingChildren(
                    returnFiber,
                    currentFirstChild.sibling
                  );
                  currentFirstChild = useFiber(
                    currentFirstChild,
                    newChild.children || []
                  );
                  currentFirstChild.return = returnFiber;
                  returnFiber = currentFirstChild;
                  break a;
                } else {
                  deleteRemainingChildren(returnFiber, currentFirstChild);
                  break;
                }
              else deleteChild(returnFiber, currentFirstChild);
              currentFirstChild = currentFirstChild.sibling;
            }
            currentFirstChild = createFiberFromPortal(
              newChild,
              returnFiber.mode,
              expirationTime
            );
            currentFirstChild.return = returnFiber;
            returnFiber = currentFirstChild;
          }
          return placeSingleChild(returnFiber);
      }
    if ("string" === typeof newChild || "number" === typeof newChild)
      return (
        (newChild = "" + newChild),
        null !== currentFirstChild && 6 === currentFirstChild.tag
          ? (deleteRemainingChildren(returnFiber, currentFirstChild.sibling),
            (currentFirstChild = useFiber(currentFirstChild, newChild)),
            (currentFirstChild.return = returnFiber),
            (returnFiber = currentFirstChild))
          : (deleteRemainingChildren(returnFiber, currentFirstChild),
            (currentFirstChild = createFiberFromText(
              newChild,
              returnFiber.mode,
              expirationTime
            )),
            (currentFirstChild.return = returnFiber),
            (returnFiber = currentFirstChild)),
        placeSingleChild(returnFiber)
      );
    if (isArray(newChild))
      return reconcileChildrenArray(
        returnFiber,
        currentFirstChild,
        newChild,
        expirationTime
      );
    if (getIteratorFn(newChild))
      return reconcileChildrenIterator(
        returnFiber,
        currentFirstChild,
        newChild,
        expirationTime
      );
    isObject && throwOnInvalidObjectType(returnFiber, newChild);
    if ("undefined" === typeof newChild && !isUnkeyedTopLevelFragment)
      switch (returnFiber.tag) {
        case 1:
        case 0:
          throw ((returnFiber = returnFiber.type),
          Error(
            (returnFiber.displayName || returnFiber.name || "Component") +
              "(...): Nothing was returned from render. This usually means a return statement is missing. Or, to render nothing, return null."
          ));
      }
    return deleteRemainingChildren(returnFiber, currentFirstChild);
  };
}
```
- 1.一般的是`REACT_ELEMENT_TYPE `类型的组件
- 2.脱离父组件，游离在这之上的是`REACT_PORTAL_TYPE `，弹唱组件
- 3.文本执行 reconcileSingleTextNode
- 4.执行最后的deleteRemainingChildren，则更新的节点是空，删除原来节点

前两点都是先调用`createFiberFromTypeAndProps ` 创建子FiberNode，然后调用placeSingleChild返回FiberNode。

到这里 beginWork就获得了FirberNode

##### 15.1.1.6 completeUnitOfWork
```javascript
function completeUnitOfWork(unitOfWork) {
  workInProgress = unitOfWork;
  do {
    var current = workInProgress.alternate;
    unitOfWork = workInProgress.return;
    if (0 === (workInProgress.effectTag & 2048)) {
      current = completeWork(current, workInProgress, renderExpirationTime$1);
      if (
        1 === renderExpirationTime$1 ||
        1 !== workInProgress.childExpirationTime
      ) {
        for (
          var newChildExpirationTime = 0, _child = workInProgress.child;
          null !== _child;

        ) {
          var _childUpdateExpirationTime = _child.expirationTime,
            _childChildExpirationTime = _child.childExpirationTime;
          _childUpdateExpirationTime > newChildExpirationTime &&
            (newChildExpirationTime = _childUpdateExpirationTime);
          _childChildExpirationTime > newChildExpirationTime &&
            (newChildExpirationTime = _childChildExpirationTime);
          _child = _child.sibling;
        }
        workInProgress.childExpirationTime = newChildExpirationTime;
      }
      if (null !== current) return current;
      null !== unitOfWork &&
        0 === (unitOfWork.effectTag & 2048) &&
        (null === unitOfWork.firstEffect &&
          (unitOfWork.firstEffect = workInProgress.firstEffect),
        null !== workInProgress.lastEffect &&
          (null !== unitOfWork.lastEffect &&
            (unitOfWork.lastEffect.nextEffect = workInProgress.firstEffect),
          (unitOfWork.lastEffect = workInProgress.lastEffect)),
        1 < workInProgress.effectTag &&
          (null !== unitOfWork.lastEffect
            ? (unitOfWork.lastEffect.nextEffect = workInProgress)
            : (unitOfWork.firstEffect = workInProgress),
          (unitOfWork.lastEffect = workInProgress)));
    } else {
      current = unwindWork(workInProgress);
      if (null !== current) return (current.effectTag &= 2047), current;
      null !== unitOfWork &&
        ((unitOfWork.firstEffect = unitOfWork.lastEffect = null),
        (unitOfWork.effectTag |= 2048));
    }
    current = workInProgress.sibling;
    if (null !== current) return current;
    workInProgress = unitOfWork;
  } while (null !== workInProgress);
  workInProgressRootExitStatus === RootIncomplete &&
    (workInProgressRootExitStatus = RootCompleted);
  return null;
}
```
核心是completeWork方法。

##### 16. completeWork
```
function completeWork(current, workInProgress, renderExpirationTime) {
  var newProps = workInProgress.pendingProps;
  switch (workInProgress.tag) {

   case 5:
      popHostContext(workInProgress);
      var rootContainerInstance = requiredContext(
        rootInstanceStackCursor.current
      );
      renderExpirationTime = workInProgress.type;
      if (null !== current && null != workInProgress.stateNode)
        updateHostComponent$1(
          current,
          workInProgress,
          renderExpirationTime,
          newProps,
          rootContainerInstance
        ),
          current.ref !== workInProgress.ref &&
            (workInProgress.effectTag |= 128);
      else {
        if (!newProps) {
          if (null === workInProgress.stateNode)
            throw Error(
              "We must have new props for new mounts. This error is likely caused by a bug in React. Please file an issue."
            );
          return null;
        }
        requiredContext(contextStackCursor$1.current);
        current = allocateTag();
        renderExpirationTime = getViewConfigForType(renderExpirationTime);
        var updatePayload = diffProperties(
          null,
          emptyObject,
          newProps,
          renderExpirationTime.validAttributes
        );
        ReactNativePrivateInterface.UIManager.createView(
          current,
          renderExpirationTime.uiViewClassName,
          rootContainerInstance,
          updatePayload
        );
        rootContainerInstance = new ReactNativeFiberHostComponent(
          current,
          renderExpirationTime,
          workInProgress
        );
        instanceCache.set(current, workInProgress);
        instanceProps.set(current, newProps);
        appendAllChildren(rootContainerInstance, workInProgress, !1, !1);
        workInProgress.stateNode = rootContainerInstance;
        finalizeInitialChildren(rootContainerInstance) &&
          (workInProgress.effectTag |= 4);
        null !== workInProgress.ref && (workInProgress.effectTag |= 128);
      }
      return null;
  }
  
}
```
- 1.diffProperties 计算前后两次不同的节点（属性不同）
- 2.调用java的UIManager.createView
- 3. appendAllChildren 把当前的节点全部添加到workInProgress

#### 17. UIManagerModule.createView
```java
  public void createView(int tag, String className, int rootViewTag, ReadableMap props) {
    mUIImplementation.createView(tag, className, rootViewTag, props);
  }
```
由真正的实现类实现。
实际上这个对象是通过下面这个方法实例化：

```java
  UIImplementation createUIImplementation(
      ReactApplicationContext reactContext,
      ViewManagerRegistry viewManagerRegistry,
      EventDispatcher eventDispatcher,
      int minTimeLeftInFrameForNonBatchedOperationMs) {
    return new UIImplementation(
        reactContext,
        viewManagerRegistry,
        eventDispatcher,
        minTimeLeftInFrameForNonBatchedOperationMs);
  }
```
也就是UIImplementation。

```java
  public void createView(int tag, String className, int rootViewTag, ReadableMap props) {
    synchronized (uiImplementationThreadLock) {
      ReactShadowNode cssNode = createShadowNode(className);
      ReactShadowNode rootNode = mShadowNodeRegistry.getNode(rootViewTag);
      cssNode.setReactTag(tag); // Thread safety needed here
      cssNode.setViewClassName(className);
      cssNode.setRootTag(rootNode.getReactTag());
      cssNode.setThemedContext(rootNode.getThemedContext());

      mShadowNodeRegistry.addNode(cssNode);

      ReactStylesDiffMap styles = null;
      if (props != null) {
        styles = new ReactStylesDiffMap(props);
        cssNode.updateProperties(styles);
      }

      handleCreateView(cssNode, rootViewTag, styles);
    }
  }
```

```java
  protected ReactShadowNode createShadowNode(String className) {
    ViewManager viewManager = mViewManagers.get(className);
    return viewManager.createShadowNodeInstance(mReactContext);
  }
 
```

```java
  public @NonNull C createShadowNodeInstance(@NonNull ReactApplicationContext context) {
    return createShadowNodeInstance();
  }
  
```

- 1. createShadowNode 从ViewManagerRegisty中获取注册好的Java 的View模块,通过ViewManager的createShadowNodeInstance创建一个新的ShadowNode 一个YogaNode实例对象。

比如说一个ImageView对应的ReactImageManager，实现如下方法：

```java
  @Override
  public LayoutShadowNode createShadowNodeInstance() {
    return new LayoutShadowNode();
  }
```
此时不会立即构建一个ImageView对象而是先生成一个影子节点对象也就是YogaNode在native层。

- 2. 把该ShadowNode添加到mShadowNodeRegistry 集合中记录起来
- 3. 把从js端设置好的View属性状态通过ShadowNode记录下来
- 4. 调用handleCreateView创建真正的View实例对象

```java
  protected void handleCreateView(
      ReactShadowNode cssNode, int rootViewTag, @Nullable ReactStylesDiffMap styles) {
    if (!cssNode.isVirtual()) {
      mNativeViewHierarchyOptimizer.handleCreateView(cssNode, cssNode.getThemedContext(), styles);
    }
  }

```


#### 18.NativeViewHierarchyOptimizer handleCreateView 创建View实例对象
```java
  public void handleCreateView(
      ReactShadowNode node,
      ThemedReactContext themedContext,
      @Nullable ReactStylesDiffMap initialProps) {
    if (!ENABLED) {
      assertNodeSupportedWithoutOptimizer(node);
      int tag = node.getReactTag();
      mUIViewOperationQueue.enqueueCreateView(
          themedContext, tag, node.getViewClass(), initialProps);
      return;
    }

    boolean isLayoutOnly =
        node.getViewClass().equals(ViewProps.VIEW_CLASS_NAME)
            && isLayoutOnlyAndCollapsable(initialProps);
    node.setIsLayoutOnly(isLayoutOnly);

    if (node.getNativeKind() != NativeKind.NONE) {
      mUIViewOperationQueue.enqueueCreateView(
          themedContext, node.getReactTag(), node.getViewClass(), initialProps);
    }
  }
```
把node对应的tag和需要实例化的View的class名构成的任务，保存到UIViewOperationQueue中。

```
  public void enqueueCreateView(
      ThemedReactContext themedContext,
      int viewReactTag,
      String viewClassName,
      @Nullable ReactStylesDiffMap initialProps) {
    synchronized (mNonBatchedOperationsLock) {
      mCreateViewCount++;
      mNonBatchedOperations.addLast(
          new CreateViewOperation(themedContext, viewReactTag, viewClassName, initialProps));
    }
  }
```

在UIViewOperationQueue中，会生成一个View的操作对象CreateViewOperation ，并胶乳到mNonBatchedOperations。

#### 19.ReactNative 构建View的时机
什么时候开始构建呢？
在UIManagerModule中会监听Activity的生命周期，如果resume了，会执行如下方法：

```java
  public void onHostResume() {
    mUIImplementation.onHostResume();
  }
```
这个方法会调用队列开始添加消费存储在mNonBatchedOperations中的View操作队列监听。

```java
  public void onHostResume() {
    mOperationsQueue.resumeFrameCallback();
  }
```

```java
  /* package */ void resumeFrameCallback() {
    mIsDispatchUIFrameCallbackEnqueued = true;
    ReactChoreographer.getInstance()
        .postFrameCallback(ReactChoreographer.CallbackType.DISPATCH_UI, mDispatchUIFrameCallback);
  }
```

注意此时RN就开始监听Vsync信号，在下一次信号到来之后就会开始实例化。

```java
    public void doFrameGuarded(long frameTimeNanos) {
      if (mIsInIllegalUIState) {
        FLog.w(
            ReactConstants.TAG,
            "Not flushing pending UI operations because of previously thrown Exception");
        return;
      }

      Systrace.beginSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "dispatchNonBatchedUIOperations");
      try {
        dispatchPendingNonBatchedOperations(frameTimeNanos);
      } finally {
        Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
      }

      flushPendingBatches();

      ReactChoreographer.getInstance()
          .postFrameCallback(ReactChoreographer.CallbackType.DISPATCH_UI, this);
    }

    private void dispatchPendingNonBatchedOperations(long frameTimeNanos) {
      while (true) {
        long timeLeftInFrame = FRAME_TIME_MS - ((System.nanoTime() - frameTimeNanos) / 1000000);
        if (timeLeftInFrame < mMinTimeLeftInFrameForNonBatchedOperationMs) {
          break;
        }

        UIOperation nextOperation;
        synchronized (mNonBatchedOperationsLock) {
          if (mNonBatchedOperations.isEmpty()) {
            break;
          }

          nextOperation = mNonBatchedOperations.pollFirst();
        }

        try {
          long nonBatchedExecutionStartTime = SystemClock.uptimeMillis();
          nextOperation.execute();
          mNonBatchedExecutionTotalTime +=
              SystemClock.uptimeMillis() - nonBatchedExecutionStartTime;
        } catch (Exception e) {
          mIsInIllegalUIState = true;
          throw e;
        }
      }
    }
```
能看到在每一帧到来之后，就会循环取出所有的View操作对象，调用起execute方法。

而这个execute方法就是调用如下：

```java
    public void execute() {
      mNativeViewHierarchyManager.createView(mThemedContext, mTag, mClassName, mInitialProps);
    }
```
 
 这个方法开始真正的实例化View对象：
 
 ```java
  public synchronized void createView(
      ThemedReactContext themedContext,
      int tag,
      String className,
      @Nullable ReactStylesDiffMap initialProps) {
    UiThreadUtil.assertOnUiThread();
    try {
      ViewManager viewManager = mViewManagers.get(className);

      View view = viewManager.createView(themedContext, null, null, mJSResponderHandler);
      mTagsToViews.put(tag, view);
      mTagsToViewManagers.put(tag, viewManager);

      view.setId(tag);
      if (initialProps != null) {
        viewManager.updateProperties(view, initialProps);
      }
    } finally {
...
    }
  }
 ```
 
 - 1.viewManager.createView 创建一个新的View对象。
 
 - 2.viewManager 更新view中对应的属性，状态。

 
  
#### 20. viewManager.createView
 
 ```java
   public @NonNull T createView(
      @NonNull ThemedReactContext reactContext,
      @Nullable ReactStylesDiffMap props,
      @Nullable StateWrapper stateWrapper,
      JSResponderHandler jsResponderHandler) {
    T view = createViewInstance(reactContext, props, stateWrapper);
    if (view instanceof ReactInterceptingViewGroup) {
      ((ReactInterceptingViewGroup) view).setOnInterceptTouchEventListener(jsResponderHandler);
    }
    return view;
  }
 ```
 举个例子在RactImageManager中实现了如下方法：
 
```java
  public ReactImageView createViewInstance(ThemedReactContext context) {
    Object callerContext =
        mCallerContextFactory != null
            ? mCallerContextFactory.getOrCreateCallerContext(context, null)
            : getCallerContext();
    return new ReactImageView(
        context, getDraweeControllerBuilder(), mGlobalImageLoadListener, callerContext);
  }
```

可以得到一个ReactImageView 添加到mTagsToViews中。

这样就能通过tag找到ShadowNode和真正的View。


直接来看看ReactRootView 的onMeasure和onLayout做了什么？


#### ReactRootView onMeasure
```java
  protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
    // TODO: T60453649 - Add test automation to verify behavior of onMeasure

    if (mUseSurface) {
      super.onMeasure(widthMeasureSpec, heightMeasureSpec);
      return;
    }

    Systrace.beginSection(TRACE_TAG_REACT_JAVA_BRIDGE, "ReactRootView.onMeasure");
    try {
      boolean measureSpecsUpdated =
          widthMeasureSpec != mWidthMeasureSpec || heightMeasureSpec != mHeightMeasureSpec;
      mWidthMeasureSpec = widthMeasureSpec;
      mHeightMeasureSpec = heightMeasureSpec;

      int width = 0;
      int height = 0;
      int widthMode = MeasureSpec.getMode(widthMeasureSpec);
      if (widthMode == MeasureSpec.AT_MOST || widthMode == MeasureSpec.UNSPECIFIED) {
        for (int i = 0; i < getChildCount(); i++) {
          View child = getChildAt(i);
          int childSize =
              child.getLeft()
                  + child.getMeasuredWidth()
                  + child.getPaddingLeft()
                  + child.getPaddingRight();
          width = Math.max(width, childSize);
        }
      } else {
        width = MeasureSpec.getSize(widthMeasureSpec);
      }
      int heightMode = MeasureSpec.getMode(heightMeasureSpec);
      if (heightMode == MeasureSpec.AT_MOST || heightMode == MeasureSpec.UNSPECIFIED) {
        for (int i = 0; i < getChildCount(); i++) {
          View child = getChildAt(i);
          int childSize =
              child.getTop()
                  + child.getMeasuredHeight()
                  + child.getPaddingTop()
                  + child.getPaddingBottom();
          height = Math.max(height, childSize);
        }
      } else {
        height = MeasureSpec.getSize(heightMeasureSpec);
      }
      setMeasuredDimension(width, height);
      mWasMeasured = true;

      // Check if we were waiting for onMeasure to attach the root view.
      if (mReactInstanceManager != null && !mIsAttachedToInstance) {
        attachToReactInstanceManager();
      } else if (measureSpecsUpdated || mLastWidth != width || mLastHeight != height) {
        updateRootLayoutSpecs(mWidthMeasureSpec, mHeightMeasureSpec);
      }
      mLastWidth = width;
      mLastHeight = height;

    } finally {
      Systrace.endSection(TRACE_TAG_REACT_JAVA_BRIDGE);
    }
  }
```

```java
  private void updateRootLayoutSpecs(final int widthMeasureSpec, final int heightMeasureSpec) {
    if (mReactInstanceManager == null) {
      FLog.w(TAG, "Unable to update root layout specs for uninitialized ReactInstanceManager");
      return;
    }
    final ReactContext reactApplicationContext = mReactInstanceManager.getCurrentReactContext();

    if (reactApplicationContext != null) {
      @Nullable
      UIManager uiManager =
          UIManagerHelper.getUIManager(reactApplicationContext, getUIManagerType());
      // Ignore calling updateRootLayoutSpecs if UIManager is not properly initialized.
      if (uiManager != null) {
        uiManager.updateRootLayoutSpecs(getRootViewTag(), widthMeasureSpec, heightMeasureSpec);
      }
    }
  }
```

如果判断到整个View发生了变动，那么就会通知uiManager从根部开始转化。

onLayout完全没有任何行为，那么ReactNative是如何摆放这些View的呢？

#### js执行完所有的方法
我们把目光放到一个方法JSI中，当调用完一次js到native通信。会执行如下步骤：

- 1.从NativeModule的nativeModuleProxy中获取C++的Module，这个对象就是c++的NativeModuleProxy。
- 2.在NativeModuleProxy中找不到，就会调用createModule方法创建一个JSINativeModules
- 3. createModule 会调用js端的__fbGenNativeModule 方法尝试通信native创建一个本地模块
- 4. __fbGenNativeModule 就是genModule，这个方法会拿到当前模块的配置，扫描每一个方法，调用genMethod的js代码，把一个个native代码代理注入到js中
- 5. genMethod 有两种一种是通过`NativeModule. callNativeSyncHook` 执行return方法，另一种是通过`NativeModule. enqueueNativeCall `执行异步方法。
- 6.异步方法会调用c++注入的全局静态方法`nativeFlushQueueImmediate `,这个方法会调用`callNativeModules `

native通信到js：
- 1.则会通过动态代理JavaScriptModuleInvocationHandler中处理
- 2.核心是调用了 mCatalystInstance.callFunction
- 3.callFunction调用了jni的callFunction方法。

最后会调用到NativeBridge的方法：


```c++
void NativeToJsBridge::callFunction(
    std::string &&module,
    std::string &&method,
    folly::dynamic &&arguments) {
  int systraceCookie = -1;


  runOnExecutorQueue([this,
                      module = std::move(module),
                      method = std::move(method),
                      arguments = std::move(arguments),
                      systraceCookie](JSExecutor *executor) {


#ifdef WITH_FBSYSTRACE
    FbSystraceAsyncFlow::end(
        TRACE_TAG_REACT_CXX_BRIDGE, "JSCall", systraceCookie);
    SystraceSection s(
        "NativeToJsBridge::callFunction", "module", module, "method", method);
#else
    (void)(systraceCookie);
#endif
    executor->callFunction(module, method, arguments);
  });
}
```

实际上就是交给了JSIExecutor的callFunction。
```java
void JSIExecutor::callFunction(
    const std::string &moduleId,
    const std::string &methodId,
    const folly::dynamic &arguments) {
  SystraceSection s(
      "JSIExecutor::callFunction", "moduleId", moduleId, "methodId", methodId);
  if (!callFunctionReturnFlushedQueue_) {
    bindBridge();
  }

  auto errorProducer = [=] {
    std::stringstream ss;
    ss << "moduleID: " << moduleId << " methodID: " << methodId
       << " arguments: " << folly::toJson(arguments);
    return ss.str();
  };

  Value ret = Value::undefined();
  try {
    scopedTimeoutInvoker_(
        [&] {
          ret = callFunctionReturnFlushedQueue_->call(
              *runtime_,
              moduleId,
              methodId,
              valueFromDynamic(*runtime_, arguments));
        },
        std::move(errorProducer));
  } catch (...) {
    std::throw_with_nested(
        std::runtime_error("Error calling " + moduleId + "." + methodId));
  }

  callNativeModules(ret, true);
}
```
此时就会通过callFunctionReturnFlushedQueue_方法调用js的方法。执行完后就会调用callNativeModules回调给Android端。

最后还是会调用Bridge中：
```c++
  void callNativeModules(
      __unused JSExecutor &executor,
      folly::dynamic &&calls,
      bool isEndOfBatch) override {
    m_batchHadNativeModuleOrTurboModuleCalls =
        m_batchHadNativeModuleOrTurboModuleCalls || !calls.empty();

    std::vector<MethodCall> methodCalls = parseMethodCalls(std::move(calls));
    BridgeNativeModulePerfLogger::asyncMethodCallBatchPreprocessEnd(
        (int)methodCalls.size());
    for (auto &call : methodCalls) {
      m_registry->callNativeMethod(
          call.moduleId, call.methodId, std::move(call.arguments), call.callId);
    }
    if (isEndOfBatch) {
      if (m_batchHadNativeModuleOrTurboModuleCalls) {
        m_callback->onBatchComplete();
        m_batchHadNativeModuleOrTurboModuleCalls = false;
      }
      m_callback->decrementPendingJSCalls();
    }
  }
```
注意最后一个参数决定了是否回调到java端的监听了OnBatchComplete中。
也就是CatalystInstanceImpl:
```java
    public void onBatchComplete() {
      CatalystInstanceImpl impl = mOuter.get();
      if (impl != null) {
        impl.mNativeModuleRegistry.onBatchComplete();
      }
    }
```

此时就会回调所有注册的本地模块的onBatchComplete，也会调用到UIManagerModule的onBatchComplete。
```java
  public void onBatchComplete() {
    int batchId = mBatchId;
    mBatchId++;

    for (UIManagerModuleListener listener : mListeners) {
      listener.willDispatchViewUpdates(this);
    }
    try {
      mUIImplementation.dispatchViewUpdates(batchId);
    } finally {
      Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
    }
  }
```

核心就是这个dispatchViewUpdates。


#### UIImplementation dispatchViewUpdates
```java
  public void dispatchViewUpdates(int batchId) {
    SystraceMessage.beginSection(
            Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "UIImplementation.dispatchViewUpdates")
        .arg("batchId", batchId)
        .flush();
    final long commitStartTime = SystemClock.uptimeMillis();
    try {
      updateViewHierarchy();
      mNativeViewHierarchyOptimizer.onBatchComplete();
      mOperationsQueue.dispatchViewUpdates(batchId, commitStartTime, mLastCalculateLayoutTime);
    } finally {
      Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
    }
  }

```

- 1. updateViewHierarchy YogaNode开始计算flex布局

```java
  protected void updateViewHierarchy() {
    Systrace.beginSection(
        Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "UIImplementation.updateViewHierarchy");
    try {
      for (int i = 0; i < mShadowNodeRegistry.getRootNodeCount(); i++) {
        int tag = mShadowNodeRegistry.getRootTag(i);
        ReactShadowNode cssRoot = mShadowNodeRegistry.getNode(tag);

        if (cssRoot.getWidthMeasureSpec() != null && cssRoot.getHeightMeasureSpec() != null) {

              .flush();
          try {
            notifyOnBeforeLayoutRecursive(cssRoot);
          } finally {
            Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
          }

          calculateRootLayout(cssRoot);

          try {
            applyUpdatesRecursive(cssRoot, 0f, 0f);
          } finally {

          }

        }
      }
    } finally {

    }
  }
  
    protected void calculateRootLayout(ReactShadowNode cssRoot) {
    SystraceMessage.beginSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "cssRoot.calculateLayout")
        .arg("rootTag", cssRoot.getReactTag())
        .flush();
    long startTime = SystemClock.uptimeMillis();
    try {
      int widthSpec = cssRoot.getWidthMeasureSpec();
      int heightSpec = cssRoot.getHeightMeasureSpec();
      cssRoot.calculateLayout(
          MeasureSpec.getMode(widthSpec) == MeasureSpec.UNSPECIFIED
              ? YogaConstants.UNDEFINED
              : MeasureSpec.getSize(widthSpec),
          MeasureSpec.getMode(heightSpec) == MeasureSpec.UNSPECIFIED
              ? YogaConstants.UNDEFINED
              : MeasureSpec.getSize(heightSpec));
    } finally {
      Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
      mLastCalculateLayoutTime = SystemClock.uptimeMillis() - startTime;
    }
  }
```



此时开始在c++中计算布局了

```java
  public void calculateLayout(float width, float height) {
    mYogaNode.calculateLayout(width, height);
  }

```

- 2.mTagsWithLayoutVisited 清空访问的节点对象
- 3.第一次会执行所有的View渲染操作

```java
  public void dispatchViewUpdates(
      final int batchId, final long commitStartTime, final long layoutTime) {
    SystraceMessage.beginSection(
            Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "UIViewOperationQueue.dispatchViewUpdates")
        .arg("batchId", batchId)
        .flush();
    try {
      final long dispatchViewUpdatesTime = SystemClock.uptimeMillis();
      final long nativeModulesThreadCpuTime = SystemClock.currentThreadTimeMillis();

      final ArrayList<DispatchCommandViewOperation> viewCommandOperations;
      if (!mViewCommandOperations.isEmpty()) {
        viewCommandOperations = mViewCommandOperations;
        mViewCommandOperations = new ArrayList<>();
      } else {
        viewCommandOperations = null;
      }

      final ArrayList<UIOperation> batchedOperations;
      if (!mOperations.isEmpty()) {
        batchedOperations = mOperations;
        mOperations = new ArrayList<>();
      } else {
        batchedOperations = null;
      }

      final ArrayDeque<UIOperation> nonBatchedOperations;
      synchronized (mNonBatchedOperationsLock) {
        if (!mNonBatchedOperations.isEmpty()) {
          nonBatchedOperations = mNonBatchedOperations;
          mNonBatchedOperations = new ArrayDeque<>();
        } else {
          nonBatchedOperations = null;
        }
      }

      if (mViewHierarchyUpdateDebugListener != null) {
        mViewHierarchyUpdateDebugListener.onViewHierarchyUpdateEnqueued();
      }

      Runnable runOperations =
          new Runnable() {
            @Override
            public void run() {

              try {
                long runStartTime = SystemClock.uptimeMillis();

                if (viewCommandOperations != null) {
                  for (DispatchCommandViewOperation op : viewCommandOperations) {
                    try {
                      op.executeWithExceptions();
                    } catch (RetryableMountingLayerException e) {

                      if (op.getRetries() == 0) {
                        op.incrementRetries();
                        mViewCommandOperations.add(op);
                      } else {
                        // Retryable exceptions should be logged, but never crash in debug.
                        ReactSoftException.logSoftException(TAG, new ReactNoCrashSoftException(e));
                      }
                    } catch (Throwable e) {
                      // Non-retryable exceptions should be logged in prod, and crash in Debug.
                      ReactSoftException.logSoftException(TAG, e);
                    }
                  }
                }

                if (nonBatchedOperations != null) {
                  for (UIOperation op : nonBatchedOperations) {
                    op.execute();
                  }
                }

                if (batchedOperations != null) {
                  for (UIOperation op : batchedOperations) {
                    op.execute();
                  }
                }

                if (mIsProfilingNextBatch && mProfiledBatchCommitStartTime == 0) {
                  mProfiledBatchCommitStartTime = commitStartTime;
                  mProfiledBatchCommitEndTime = SystemClock.uptimeMillis();
                  mProfiledBatchLayoutTime = layoutTime;
                  mProfiledBatchDispatchViewUpdatesTime = dispatchViewUpdatesTime;
                  mProfiledBatchRunStartTime = runStartTime;
                  mProfiledBatchRunEndTime = mProfiledBatchCommitEndTime;
                  mThreadCpuTime = nativeModulesThreadCpuTime;

                  Systrace.beginAsyncSection(
                      Systrace.TRACE_TAG_REACT_JAVA_BRIDGE,
                      "delayBeforeDispatchViewUpdates",
                      0,
                      mProfiledBatchCommitStartTime * 1000000);
                  Systrace.endAsyncSection(
                      Systrace.TRACE_TAG_REACT_JAVA_BRIDGE,
                      "delayBeforeDispatchViewUpdates",
                      0,
                      mProfiledBatchDispatchViewUpdatesTime * 1000000);
                  Systrace.beginAsyncSection(
                      Systrace.TRACE_TAG_REACT_JAVA_BRIDGE,
                      "delayBeforeBatchRunStart",
                      0,
                      mProfiledBatchDispatchViewUpdatesTime * 1000000);
                  Systrace.endAsyncSection(
                      Systrace.TRACE_TAG_REACT_JAVA_BRIDGE,
                      "delayBeforeBatchRunStart",
                      0,
                      mProfiledBatchRunStartTime * 1000000);
                }

                // Clear layout animation, as animation only apply to current UI operations batch.
                mNativeViewHierarchyManager.clearLayoutAnimation();

                if (mViewHierarchyUpdateDebugListener != null) {
                  mViewHierarchyUpdateDebugListener.onViewHierarchyUpdateFinished();
                }
              } catch (Exception e) {
                mIsInIllegalUIState = true;
                throw e;
              } finally {
                Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
              }
            }
          };

      SystraceMessage.beginSection(
              Systrace.TRACE_TAG_REACT_JAVA_BRIDGE, "acquiring mDispatchRunnablesLock")
          .arg("batchId", batchId)
          .flush();
      synchronized (mDispatchRunnablesLock) {
        Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
        mDispatchUIRunnables.add(runOperations);
      }

      if (!mIsDispatchUIFrameCallbackEnqueued) {
        UiThreadUtil.runOnUiThread(
            new GuardedRunnable(mReactApplicationContext) {
              @Override
              public void runGuarded() {
                flushPendingBatches();
              }
            });
      }
    } finally {
      Systrace.endSection(Systrace.TRACE_TAG_REACT_JAVA_BRIDGE);
    }
  }
```

但是是怎么知道整个层级顺序呢？

```java
public class ReactShadowNodeImpl implements ReactShadowNode<ReactShadowNodeImpl> {

  private static final YogaConfig sYogaConfig;

  static {
    sYogaConfig = ReactYogaConfigProvider.get();
  }

  private int mReactTag;
  private @Nullable String mViewClassName;
  private int mRootTag;
  private @Nullable ThemedReactContext mThemedContext;
  private boolean mShouldNotifyOnLayout;
  private boolean mNodeUpdated = true;
  private @Nullable ArrayList<ReactShadowNodeImpl> mChildren;
  private @Nullable ReactShadowNodeImpl mParent;
  private @Nullable ReactShadowNodeImpl mLayoutParent;

  // layout-only nodes
  private boolean mIsLayoutOnly;
  private int mTotalNativeChildren = 0;
  private @Nullable ReactShadowNodeImpl mNativeParent;
  private @Nullable ArrayList<ReactShadowNodeImpl> mNativeChildren;
  private int mScreenX;
  private int mScreenY;
  private int mScreenWidth;
  private int mScreenHeight;
  private final Spacing mDefaultPadding;
  private final float[] mPadding = new float[Spacing.ALL + 1];
  private final boolean[] mPaddingIsPercent = new boolean[Spacing.ALL + 1];
  private YogaNode mYogaNode;
  private Integer mWidthMeasureSpec;
  private Integer mHeightMeasureSpec;

```
