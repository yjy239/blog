---
title: Android 重学系列 View的绘制流程 (一)View的初始化
top: false
cover: false
date: 2019-09-26 08:31:35
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
View的绘制流程这一篇文章其实十分不好写，因为在网上已经有千篇一律的文章，导致我一直不太想写这一篇文章。不过既然是Android重学系列，还是一步一脚印来分析分析里面的细节。如果对这个流程很熟悉的人来说，本文就没必要阅读了。如果不是很熟悉的朋友可以阅读本文，看看系统上设计的优点以及可以优化的地方。


# 正文
在整个View的绘制流程中，从大的方向看来，大致上分为两部分：
- 在Activity的onCreate生命周期，实例化所有的View。
- Activity的onResume生命周期，测量，布局，绘制所有的View。

暂时不去看Activity如何联通SurfaceFlinger，之后会有专门的专题再来聊聊。
那么Activity是怎么管理View的绘制的呢？接下来我们会以上面两点为线索来分析一下源码。

不过内容很多，本文集中重点聊聊view的实例化是怎么回事。

### 总览
- Activity的初始化与分层
- LayoutInflater原理，以及思考
- AsyncLayoutInflater的原理以及缺陷

## Activity onCreate的绑定
其实Activity的生命周期仅仅只是管理着Activity这个对象的活跃状态，并没有真的去管理View，那么Activity是怎么通过管理View的绘制的呢？我们来看看在ActivityThread调用performLaunchActivity：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ActivityThread.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ActivityThread.java)

```java
                Window window = null;
                if (r.mPendingRemoveWindow != null && r.mPreserveWindow) {
                    window = r.mPendingRemoveWindow;
                    r.mPendingRemoveWindow = null;
                    r.mPendingRemoveWindowManager = null;
                }
                appContext.setOuterContext(activity);
                activity.attach(appContext, this, getInstrumentation(), r.token,
                        r.ident, app, r.intent, r.activityInfo, title, r.parent,
                        r.embeddedID, r.lastNonConfigurationInstances, config,
                        r.referrer, r.voiceInteractor, window, r.configCallback);

```
能看到在这个步骤中，对着实例化的Activity做了一次绑定操作。具体做什么呢？
```java
    final void attach(Context context, ActivityThread aThread,
            Instrumentation instr, IBinder token, int ident,
            Application application, Intent intent, ActivityInfo info,
            CharSequence title, Activity parent, String id,
            NonConfigurationInstances lastNonConfigurationInstances,
            Configuration config, String referrer, IVoiceInteractor voiceInteractor,
            Window window, ActivityConfigCallback activityConfigCallback) {
        attachBaseContext(context);

        mFragments.attachHost(null /*parent*/);

        mWindow = new PhoneWindow(this, window, activityConfigCallback);
        mWindow.setWindowControllerCallback(this);
        mWindow.setCallback(this);
        mWindow.setOnWindowDismissedCallback(this);
        mWindow.getLayoutInflater().setPrivateFactory(this);
        if (info.softInputMode != WindowManager.LayoutParams.SOFT_INPUT_STATE_UNSPECIFIED) {
            mWindow.setSoftInputMode(info.softInputMode);
        }
...
        mUiThread = Thread.currentThread();

        mMainThread = aThread;
        mInstrumentation = instr;
        mToken = token;
        mIdent = ident;
        mApplication = application;
        mIntent = intent;
        mReferrer = referrer;
        mComponent = intent.getComponent();
        mActivityInfo = info;
....
        mWindow.setWindowManager(
                (WindowManager)context.getSystemService(Context.WINDOW_SERVICE),
                mToken, mComponent.flattenToString(),
                (info.flags & ActivityInfo.FLAG_HARDWARE_ACCELERATED) != 0);
        if (mParent != null) {
            mWindow.setContainer(mParent.getWindow());
        }
        mWindowManager = mWindow.getWindowManager();
        mCurrentConfig = config;

        mWindow.setColorMode(info.colorMode);

...
    }
```

能看到在attach中实际上最为重要的工作就是实例化一个PhoneWindow对象，并且把当前Phone相关的监听，如点击事件的回调，窗体消失的回调等等。

并且把ActivityThread，ActivityInfo，Application等重要的信息绑定到当前的Activity。

从上一个专栏WMS，就能知道，实际上承载视图真正的对象实际上是Window窗口。那么这个Window对象又是什么做第一次的视图加载呢？

其实是调用了我们及其熟悉的api：
```java
    public void setContentView(@LayoutRes int layoutResID) {
        getWindow().setContentView(layoutResID);
        initWindowDecorActionBar();
    }
```
在这个api中设置了PhoneWindow的内容视图区域。这也是每一个Android开发的接触到的第一个api。因为其至关重要承载了Android接下来要显示什么内容。

接下来我们很容易想到setContentView究竟做了什么事情，来初始化所有的View对象。

### PhoneWindow.setContentView
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/)/[internal](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/)/[policy](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/)/[PhoneWindow.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/PhoneWindow.java)

```java
    @Override
    public void setContentView(int layoutResID) {
        if (mContentParent == null) {
            installDecor();
        } else if (!hasFeature(FEATURE_CONTENT_TRANSITIONS)) {
...
        }

        if (hasFeature(FEATURE_CONTENT_TRANSITIONS)) {
....
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
我们这里只关注核心逻辑。能看到当mContentParent为空的时候，会调用installDecor生成一个父容器，最终会通过我们另一个熟悉的函数LayoutInflater.inflate把所有的View都实例化出来。

那么同理，我们把整个步骤分为2部分：
- 1.installDecor生成DecorView安装在FrameLayout作为所有View的顶层View
- 2.LayoutInflater.inflate 实例化传进来的内容。

### installDecor生成DecorView作为所有View的顶层View
```java
    private void installDecor() {
        mForceDecorInstall = false;
        if (mDecor == null) {
//核心事件1
            mDecor = generateDecor(-1);
            mDecor.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
            mDecor.setIsRootNamespace(true);
            if (!mInvalidatePanelMenuPosted && mInvalidatePanelMenuFeatures != 0) {
                mDecor.postOnAnimation(mInvalidatePanelMenuRunnable);
            }
        } else {
            mDecor.setWindow(this);
        }
        if (mContentParent == null) {
//核心事件二
            mContentParent = generateLayout(mDecor);

            // Set up decor part of UI to ignore fitsSystemWindows if appropriate.
            mDecor.makeOptionalFitsSystemWindows();

            final DecorContentParent decorContentParent = (DecorContentParent) mDecor.findViewById(
                    R.id.decor_content_parent);

            if (decorContentParent != null) {
...
            } else {
...
            }

            if (mDecor.getBackground() == null && mBackgroundFallbackResource != 0) {
                mDecor.setBackgroundFallback(mBackgroundFallbackResource);
            }

            // Only inflate or create a new TransitionManager if the caller hasn't
            // already set a custom one.
            if (hasFeature(FEATURE_ACTIVITY_TRANSITIONS)) {
...
            }
        }
    }
```
我们抽出核心逻辑看看这个installDecor做的事情实际上很简单：
- 1.generateDecor生成DecorView
- 2.generateLayout 获取DecorView中的内容区域
- 3.寻找DecorView中的DecorContentParent处理PanelMenu等系统内置的挂在view。
- 4.处理专场动画。

我们只需要把关注点放在头两项。这两个才是本文的重点。第四项的处理实际上是处理

#### generateDecor生成DecorView
```java
    protected DecorView generateDecor(int featureId) {
        // System process doesn't have application context and in that case we need to directly use
        // the context we have. Otherwise we want the application context, so we don't cling to the
        // activity.
        Context context;
        if (mUseDecorContext) {
            Context applicationContext = getContext().getApplicationContext();
            if (applicationContext == null) {
                context = getContext();
            } else {
                context = new DecorContext(applicationContext, getContext().getResources());
                if (mTheme != -1) {
                    context.setTheme(mTheme);
                }
            }
        } else {
            context = getContext();
        }
        return new DecorView(context, featureId, this, getAttributes());
    }
```
能看到里面十分简单，声明DecorContext，注入到DecorView。如果处理著名的键盘内存泄漏的时候，把打印打开，当切换到另一个Activity的时候，就会看到这个这个Context。

在Android系统看来DecorView必须拥有自己的Context的原因是，DecorView是系统自己的服务，因此需要做Context的隔离。不过虽然是系统服务，但是还是添加到我们的View当中。

#### generateLayout 获取DecorView中的内容区域
```java
 protected ViewGroup generateLayout(DecorView decor) {
        // Apply data from current theme.

        TypedArray a = getWindowStyle();
//获取当前窗体所有的标志位
   ...
//根据标志位做初步处理，如背景
  ....

 ...

        // 根据标志位设置资源id
        int layoutResource;
        int features = getLocalFeatures();
        // System.out.println("Features: 0x" + Integer.toHexString(features));
        if ((features & (1 << FEATURE_SWIPE_TO_DISMISS)) != 0) {
      ...
        } else if ((features & ((1 << FEATURE_LEFT_ICON) | (1 << FEATURE_RIGHT_ICON))) != 0) {
 ...
        } else if ((features & ((1 << FEATURE_PROGRESS) | (1 << FEATURE_INDETERMINATE_PROGRESS))) != 0
                && (features & (1 << FEATURE_ACTION_BAR)) == 0) {
   ...
        } else if ((features & (1 << FEATURE_CUSTOM_TITLE)) != 0) {
...
        } else if ((features & (1 << FEATURE_NO_TITLE)) == 0) {
...
        } else if ((features & (1 << FEATURE_ACTION_MODE_OVERLAY)) != 0) {
            layoutResource = R.layout.screen_simple_overlay_action_mode;
        } else {
            // Embedded, so no decoration is needed.
            layoutResource = R.layout.screen_simple;
            // System.out.println("Simple!");
        }

        mDecor.startChanging();
        mDecor.onResourcesLoaded(mLayoutInflater, layoutResource);

        ViewGroup contentParent = (ViewGroup)findViewById(ID_ANDROID_CONTENT);
        if (contentParent == null) {
            throw new RuntimeException("Window couldn't find content container view");
        }

 ...

        return contentParent;
    }
```
这里做的事情如下：
- 1.获取设置在xml中的窗体style，设置相应的标志位如mFloat等
- 2.获取DecorView窗体的属性，进一步处理一些背景，根据当前的Android版本，style重新设置窗体的属性，以供后面使用。
- 3.根据上面设置的标志位设置合适的窗体资源
- 4.获取ID_ANDROID_CONTENT中的内容区域。

假如，我们当前使用的是最普通的状态，将会加载R.layout.screen_simple;资源文件到DecorView中，当实例化好当前的xml资源之后，将会从DecorView找到我们的内容区域部分。


我们看看screen_simple是什么东西：
```xml
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:fitsSystemWindows="true"
    android:orientation="vertical">
    <ViewStub android:id="@+id/action_mode_bar_stub"
              android:inflatedId="@+id/action_mode_bar"
              android:layout="@layout/action_mode_bar"
              android:layout_width="match_parent"
              android:layout_height="wrap_content"
              android:theme="?attr/actionBarTheme" />
    <FrameLayout
         android:id="@android:id/content"
         android:layout_width="match_parent"
         android:layout_height="match_parent"
         android:foregroundInsidePadding="false"
         android:foregroundGravity="fill_horizontal|top"
         android:foreground="?android:attr/windowContentOverlay" />
</LinearLayout>
```
能看到这是一个LinearLayout包裹着的一个FrameLayout。把当前的View设置一个windowContentOverlay属性。这个属性可以在Activity生成之后，渲染速度太慢可以设置成白色透明或者图片。一个ViewStub用来优化显示actionbar

和startingWindow有本质上的区别，startingWindow的出现是为了处理还没有进入Activity，绘制在屏幕的窗体，同时还能获取之前保留下来的屏幕像素渲染在上面。是一个优化显示体验的设计。

最后找到这个id为content的内容区域返回回去。

这样我们就知道网上那个Android的显示区域划分图是怎么来的。
![Android显示View的构成.png](/images/Android显示View的构成.jpeg)

如果我们把对象考虑进来大致上是如此：
![对象包含图.png](/images/对象包含图.jpeg)


### LayoutInflater.inflate实例化所有内容视图
核心代码如下：
```java
mLayoutInflater.inflate(layoutResID, mContentParent);
```

实际上对于Android开发来说，这个api也熟悉的不能再熟悉了。我们看看LayoutInflater常用的用法。
```java
    public static LayoutInflater from(Context context) {
        LayoutInflater LayoutInflater =
                (LayoutInflater) context.getSystemService(Context.LAYOUT_INFLATER_SERVICE);
        if (LayoutInflater == null) {
            throw new AssertionError("LayoutInflater not found.");
        }
        return LayoutInflater;
    }
```

可以去结合我上一个专栏的WMS的getSystemService分析。实际上在这里面LayoutInflater是一个全局单例。为什么一定要设计为单例这是有原因的。看到后面就知道为什么了。

#### LayoutInflater.inflate原理
接下来我们把注意力转移到inflater如何实例化view上面：
```java
  public View inflate(@LayoutRes int resource, @Nullable ViewGroup root) {
        return inflate(resource, root, root != null);
    }

    public View inflate(XmlPullParser parser, @Nullable ViewGroup root) {
        return inflate(parser, root, root != null);
    }

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
我们常用的LayoutInflater其实有三种方式，最后都会调用三个参数的inflate方法。
分为2个步骤
- 1.首先先通过Resource获取XmlResourceParser的解析器
- 2.inflate按照解析器实例化View。

换句话说，为了弄清楚View怎么实例化这个流程，我们必须看Android是怎么获取资源的。

#### Resource解析xml
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
            throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id)
                    + " type #0x" + Integer.toHexString(value.type) + " is not valid");
        } finally {
            releaseTempTypedValue(value);
        }
    }
```
能看到此时是通过loadXmlResourceParser来告诉底层解析的是Layout资源。能看到此时会把工作交给ResourcesImpl和AssetManager去完成。这个类如果看过我的文章的朋友就很熟悉了，这两个类就是Java层加载资源的核心类，当我们做插件化的时候，是不可避免的接触这个类。

经过的方法，大致上我们把资源读取的步骤分为3部分：
- 1.获取TypedValue
- 2.读取资源文件，生成保存着xml解析内容的对象
- 3.释放掉TypedValue

这个步骤和我们平时开发自定义View设置自定义属性的时候何其相似，都是通过obtainStyledAttributes打开TypeArray，读取其中的数据，最后关闭TypeArray。

这背后隐藏这什么玄机呢？我们之后会有文章专门探索，我们不要打断当前的思绪。


#### inflate解析Xml解析器中的数据
```java
    public View inflate(XmlPullParser parser, @Nullable ViewGroup root, boolean attachToRoot) {
        synchronized (mConstructorArgs) {
            Trace.traceBegin(Trace.TRACE_TAG_VIEW, "inflate");

            final Context inflaterContext = mContext;
            final AttributeSet attrs = Xml.asAttributeSet(parser);
            Context lastContext = (Context) mConstructorArgs[0];
            mConstructorArgs[0] = inflaterContext;
            View result = root;

            try {
                // Look for the root node.
                int type;
                while ((type = parser.next()) != XmlPullParser.START_TAG &&
                        type != XmlPullParser.END_DOCUMENT) {
                    // Empty
                }

                if (type != XmlPullParser.START_TAG) {
                    throw new InflateException(parser.getPositionDescription()
                            + ": No start tag found!");
                }
                final String name = parser.getName();
...
                if (TAG_MERGE.equals(name)) {
                    if (root == null || !attachToRoot) {
                        throw new InflateException("<merge /> can be used only with a valid "
                                + "ViewGroup root and attachToRoot=true");
                    }

                    rInflate(parser, root, inflaterContext, attrs, false);
                } else {
                    // Temp is the root view that was found in the xml
                    final View temp = createViewFromTag(root, name, inflaterContext, attrs);

                    ViewGroup.LayoutParams params = null;

                    if (root != null) {
                        // Create layout params that match root, if supplied
                        params = root.generateLayoutParams(attrs);
                        if (!attachToRoot) {
                            temp.setLayoutParams(params);
                        }
                    }
                    rInflateChildren(parser, temp, attrs, true);

                    // We are supposed to attach all the views we found (int temp)
                    // to root. Do that now.
                    if (root != null && attachToRoot) {
                        root.addView(temp, params);
                    }

                    if (root == null || !attachToRoot) {
                        result = temp;
                    }
                }

            } catch (XmlPullParserException e) {
...
            } catch (Exception e) {
...
            } finally {
                // Don't retain static reference on context.
                mConstructorArgs[0] = lastContext;
                mConstructorArgs[1] = null;

                Trace.traceEnd(Trace.TRACE_TAG_VIEW);
            }

            return result;
        }
    }
```
从这我们就能看到是否添加父布局以及是否绑定父布局之间的差别了。

首先不断的从xml的头部开始查找(第一个“<”)，直到找到第一个view的进行解析。接下来就分为两个路线：
- 1.此时xml布局使用了merge优化，调用rInflate。请注意直接使用LayoutInflate实例化merge标签，请设置根布局不然会报错。
- 2.xml是普通的布局，调用rInflateChildren

先来看看第二种不普通情况，在没有merge布局的情况：
- 1.先通过createViewFromTag实例化对应的view。
- 2.接着根据查看当前有没有root需要绑定的父布局，如果有，则获取根布局的generLayout：
```java
    public LayoutParams generateLayoutParams(AttributeSet attrs) {
        return new LayoutParams(getContext(), attrs);
    }
```
根据xml当前标签的属性生成适配根布局的LayoutParams。

attachToRoot如果为true，则会直接添加到根布局中。

- 3.rInflateChildren继续解析当前布局下的根布局，进入递归。


**这也解释了三个inflate方法之间的区别，带着根部布局参数的inflate能够将当前根部的标签的参数生成一个适配根部LayoutParams，也就保留了根部布局的属性。而最后一个bool仅仅是代表用不用系统自动帮你添加到根布局中**

在这里面有一个核心的函数createViewFromTag，这是就是如何创建View的核心。

#### createViewFromTag创建View
```java
    private View createViewFromTag(View parent, String name, Context context, AttributeSet attrs) {
        return createViewFromTag(parent, name, context, attrs, false);
    }

    View createViewFromTag(View parent, String name, Context context, AttributeSet attrs,
            boolean ignoreThemeAttr) {
        if (name.equals("view")) {
            name = attrs.getAttributeValue(null, "class");
        }

        // Apply a theme wrapper, if allowed and one is specified.
        if (!ignoreThemeAttr) {
            final TypedArray ta = context.obtainStyledAttributes(attrs, ATTRS_THEME);
            final int themeResId = ta.getResourceId(0, 0);
            if (themeResId != 0) {
                context = new ContextThemeWrapper(context, themeResId);
            }
            ta.recycle();
        }

        if (name.equals(TAG_1995)) {
            // Let's party like it's 1995!
            return new BlinkLayout(context, attrs);
        }

        try {
            View view;
            if (mFactory2 != null) {
                view = mFactory2.onCreateView(parent, name, context, attrs);
            } else if (mFactory != null) {
                view = mFactory.onCreateView(name, context, attrs);
            } else {
                view = null;
            }

            if (view == null && mPrivateFactory != null) {
                view = mPrivateFactory.onCreateView(parent, name, context, attrs);
            }

            if (view == null) {
                final Object lastContext = mConstructorArgs[0];
                mConstructorArgs[0] = context;
                try {
                    if (-1 == name.indexOf('.')) {
                        view = onCreateView(parent, name, attrs);
                    } else {
                        view = createView(name, null, attrs);
                    }
                } finally {
                    mConstructorArgs[0] = lastContext;
                }
            }

            return view;
        } catch (InflateException e) {
...
        } catch (ClassNotFoundException e) {
...
        } catch (Exception e) {
...
        }
    }
```
实际上这里面很简单和很巧妙，也能发现Android 中的新特性。
- 1.如果标签直接是view，则直接获取xml标签中系统中class的属性，这样就能找到view对应的类名。
- 2.如果name是blink，则创建一个深度链接的布局
- 3.通过三层的Factory拦截view的创建，分别是Factory，Factory2，privateFactory。
- 4.如果经过上层由用户或者系统定义的特殊view的生成拦截没有生成，则会判断当前的标签名又没有"."。有“.”说明是自定义view，没有说明是系统控件。

- 1.系统控件调用onCreateView创建View。
- 2.自定义View调用createView创建View。

在继续下一步之前，让我们把目光放回系统生成LayoutInflater的方法中，看看生成LayoutInflater有什么猫腻？
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[SystemServiceRegistry.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/SystemServiceRegistry.java)
```java
        registerService(Context.LAYOUT_INFLATER_SERVICE, LayoutInflater.class,
                new CachedServiceFetcher<LayoutInflater>() {
            @Override
            public LayoutInflater createService(ContextImpl ctx) {
                return new PhoneLayoutInflater(ctx.getOuterContext());
            }});
```
能看到系统初期实例化的是一个PhoneLayoutInflater，并非是一个普通的LayoutInflater，而这个类重载了一个很重要的方法：
文件：[http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/PhoneLayoutInflater.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/com/android/internal/policy/PhoneLayoutInflater.java)

```java
    private static final String[] sClassPrefixList = {
//常用控件
        "android.widget.",
//一般指WebView
        "android.webkit.",
//一般指Fragment
        "android.app."
    };

    @Override protected View onCreateView(String name, AttributeSet attrs) throws ClassNotFoundException {
        for (String prefix : sClassPrefixList) {
            try {
                View view = createView(name, prefix, attrs);
                if (view != null) {
                    return view;
                }
            } catch (ClassNotFoundException e) {
                // In this case we want to let the base class take a crack
                // at it.
            }
        }

        return super.onCreateView(name, attrs);
    }
```
能看到这样就手动为View添加了前缀，还是调用了createView创建View。举个例子，如果是一个Linearlayout，就会为这个标签添加android.widget.前缀，称为android.widget.Linearlayout。这样就能找到相对完整的类名。


#### createView创建View的核心动作
```java
    public final View createView(String name, String prefix, AttributeSet attrs)
            throws ClassNotFoundException, InflateException {
//所有view对应构造函数
        Constructor<? extends View> constructor = sConstructorMap.get(name);
        if (constructor != null && !verifyClassLoader(constructor)) {
            constructor = null;
            sConstructorMap.remove(name);
        }
        Class<? extends View> clazz = null;

        try {
            Trace.traceBegin(Trace.TRACE_TAG_VIEW, name);

            if (constructor == null) {
                // Class not found in the cache, see if it's real, and try to add it
                clazz = mContext.getClassLoader().loadClass(
                        prefix != null ? (prefix + name) : name).asSubclass(View.class);

                if (mFilter != null && clazz != null) {
                    boolean allowed = mFilter.onLoadClass(clazz);
                    if (!allowed) {
                        failNotAllowed(name, prefix, attrs);
                    }
                }
                constructor = clazz.getConstructor(mConstructorSignature);
                constructor.setAccessible(true);
                sConstructorMap.put(name, constructor);
            } else {
                // If we have a filter, apply it to cached constructor
                if (mFilter != null) {
                    // Have we seen this name before?
                    Boolean allowedState = mFilterMap.get(name);
                    if (allowedState == null) {
                        // New class -- remember whether it is allowed
                        clazz = mContext.getClassLoader().loadClass(
                                prefix != null ? (prefix + name) : name).asSubclass(View.class);

                        boolean allowed = clazz != null && mFilter.onLoadClass(clazz);
                        mFilterMap.put(name, allowed);
                        if (!allowed) {
                            failNotAllowed(name, prefix, attrs);
                        }
                    } else if (allowedState.equals(Boolean.FALSE)) {
                        failNotAllowed(name, prefix, attrs);
                    }
                }
            }

            Object lastContext = mConstructorArgs[0];
            if (mConstructorArgs[0] == null) {
                // Fill in the context if not already within inflation.
                mConstructorArgs[0] = mContext;
            }
            Object[] args = mConstructorArgs;
            args[1] = attrs;

            final View view = constructor.newInstance(args);
            if (view instanceof ViewStub) {
                // Use the same context when inflating ViewStub later.
                final ViewStub viewStub = (ViewStub) view;
                viewStub.setLayoutInflater(cloneInContext((Context) args[0]));
            }
            mConstructorArgs[0] = lastContext;
            return view;

        } catch (NoSuchMethodException e) {
...
        } catch (ClassCastException e) {
...
        } catch (ClassNotFoundException e) {
...
        } catch (Exception e) {
...
        } finally {
            Trace.traceEnd(Trace.TRACE_TAG_VIEW);
        }
    }
```
实际上我们能够看到在实例化View有一个关键的数据结构：sConstructorMap.

这个数据结构保存着app应用内所有实例化过的View对应的构造函数。主要经过存储一次，就以name为key存储对应的构造函数，就不用一直反射获取了。

实际上这段代码就是做这个事情：
- 1.当从name找构造函数，找的到，就直接通过构造函数实例化
- 2.没有找到构造函数，则通过prefix+name的方式查找类的构造函数，接着再实例化。



**这也解释了为什么LayoutInflater一定要做成全局单例的方式，原因很简单就是为了加速view实例化的过程，共用反射的构造函数的缓存。**

#### View布局优化细节
- 当然也能看到ViewStub实际上在这里面没有做太多事情，把当前的Layoutflater复制一份进去，延后实例化里面的View。
- merge优化原理，也能明白了，实际上在正常的分支会直接实例化一个View之后再添加，接着递归子view继续添加当前的View。而merge则是跳出第一次实例化View步骤，直接进入递归。

merge能做到什么事情呢？我当然知道是压缩层级？一般是压缩include标签的层级。

这里就解释了怎么压缩层级。换句话说，我们使用merge的时候完全不用添加父布局，直接用merge标签包裹子view即可，当我们不能预览，在merge上添加parentTag即可。

举个例子：
```xml
<FrameLayout>
   <include layout="@layout/layout2"/>
</FrameLayout>
```
layout2.xml:
```xml
<merge>
   <TextView />
</merge>
```
合并之后就是如下：
```xml
<FrameLayout>
   <TextView />
</FrameLayout>
```

如果把include作为根布局呢？很明显会找不到android.view.include这个文件。

### rInflate递归解析View

当我们生成View之后，就需要继续递归子View，让我们看看其核心逻辑是什么。

能看到无论是是走merge分支还是正常解析分支也好，本质上都会调用到rInflate这个方法。

```java
    final void rInflateChildren(XmlPullParser parser, View parent, AttributeSet attrs,
            boolean finishInflate) throws XmlPullParserException, IOException {
        rInflate(parser, parent, parent.getContext(), attrs, finishInflate);
    }

    void rInflate(XmlPullParser parser, View parent, Context context,
            AttributeSet attrs, boolean finishInflate) throws XmlPullParserException, IOException {

        final int depth = parser.getDepth();
        int type;
        boolean pendingRequestFocus = false;

        while (((type = parser.next()) != XmlPullParser.END_TAG ||
                parser.getDepth() > depth) && type != XmlPullParser.END_DOCUMENT) {

            if (type != XmlPullParser.START_TAG) {
                continue;
            }

            final String name = parser.getName();

            if (TAG_REQUEST_FOCUS.equals(name)) {
                pendingRequestFocus = true;
                consumeChildElements(parser);
            } else if (TAG_TAG.equals(name)) {
                parseViewTag(parser, parent, attrs);
            } else if (TAG_INCLUDE.equals(name)) {
                if (parser.getDepth() == 0) {
                    throw new InflateException("<include /> cannot be the root element");
                }
                parseInclude(parser, context, parent, attrs);
            } else if (TAG_MERGE.equals(name)) {
                throw new InflateException("<merge /> must be the root element");
            } else {
                final View view = createViewFromTag(parent, name, context, attrs);
                final ViewGroup viewGroup = (ViewGroup) parent;
                final ViewGroup.LayoutParams params = viewGroup.generateLayoutParams(attrs);
                rInflateChildren(parser, view, attrs, true);
                viewGroup.addView(view, params);
            }
        }

        if (pendingRequestFocus) {
            parent.restoreDefaultFocus();
        }

        if (finishInflate) {
            parent.onFinishInflate();
        }
    }
```
在一段代码就是不断循环当前的当前xml的节点解析内部的标签，直到到了标签的末尾("/>")
分为如下几个分支：
- 1.如果发现需要requestFoucs，则设置当前view标志为聚焦
- 2.如果发现标签是include，则调用parseInclude，解开include内部的layout进行解析。
- 3.标签是tag，则保存tag中的内容
- 4.发现标签是merge则报错
- 5.其他情况，如正常一般，会正常生成View，并且添加当前的父布局中。

最后会回调onFinishInflate监听。


### LayoutInflater Factory的妙用
或许有人会觉得LayoutInflater中设置Factory干什么的？实际上这个Factory到处有在用，只是我们没有注意到过而已。

举一个例子，肯定有人注意过吧。当我们使用AppCompatActivity的时候，如果打印或者打断点，会发现内部的ImageView这些view，会被替换掉，变成AppCompat开头的view，如AppCompatImageView。

我们来看看AppCompatActivity的onCreate方法：
```java
  @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        final AppCompatDelegate delegate = getDelegate();
        delegate.installViewFactory();
        delegate.onCreate(savedInstanceState);
}
```
实际上AppCompatDelegate本质上是AppCompatDelegateImpl，在这个类中调用了installViewFactory的方法。
```java
    public void installViewFactory() {
        LayoutInflater layoutInflater = LayoutInflater.from(mContext);
        if (layoutInflater.getFactory() == null) {
            LayoutInflaterCompat.setFactory2(layoutInflater, this);
        } else {
...
        }
    }
```
既然我们直到Factory需要重写onCreateView的方法，我们直接看看这个类中的方法：
```java
    public View createView(View parent, final String name, @NonNull Context context,
            @NonNull AttributeSet attrs) {
        if (mAppCompatViewInflater == null) {
            TypedArray a = mContext.obtainStyledAttributes(R.styleable.AppCompatTheme);
            String viewInflaterClassName =
                    a.getString(R.styleable.AppCompatTheme_viewInflaterClass);
            if ((viewInflaterClassName == null)
                    || AppCompatViewInflater.class.getName().equals(viewInflaterClassName)) {
...
                mAppCompatViewInflater = new AppCompatViewInflater();
            } else {
                try {
                    Class viewInflaterClass = Class.forName(viewInflaterClassName);
                    mAppCompatViewInflater =
                            (AppCompatViewInflater) viewInflaterClass.getDeclaredConstructor()
                                    .newInstance();
                } catch (Throwable t) {
..
                    mAppCompatViewInflater = new AppCompatViewInflater();
                }
            }
        }

...
        return mAppCompatViewInflater.createView(parent, name, context, attrs, inheritContext,
                IS_PRE_LOLLIPOP, /* Only read android:theme pre-L (L+ handles this anyway) */
                true, /* Read read app:theme as a fallback at all times for legacy reasons */
                VectorEnabledTintResources.shouldBeUsed() /* Only tint wrap the context if enabled */
        );
    }
```
能看到此时，会实例化AppCompatViewInflater，把实例化View交给它来处理。

#### AppCompatViewInflater.createView
```java
    final View createView(View parent, final String name, @NonNull Context context,
            @NonNull AttributeSet attrs, boolean inheritContext,
            boolean readAndroidTheme, boolean readAppTheme, boolean wrapContext) {
        final Context originalContext = context;

        // We can emulate Lollipop's android:theme attribute propagating down the view hierarchy
        // by using the parent's context
        if (inheritContext && parent != null) {
            context = parent.getContext();
        }
        if (readAndroidTheme || readAppTheme) {
            // We then apply the theme on the context, if specified
            context = themifyContext(context, attrs, readAndroidTheme, readAppTheme);
        }
        if (wrapContext) {
            context = TintContextWrapper.wrap(context);
        }

        View view = null;

        // We need to 'inject' our tint aware Views in place of the standard framework versions
        switch (name) {
            case "TextView":
                view = createTextView(context, attrs);
                verifyNotNull(view, name);
                break;
            case "ImageView":
                view = createImageView(context, attrs);
                verifyNotNull(view, name);
                break;
            case "Button":
                view = createButton(context, attrs);
                verifyNotNull(view, name);
                break;
            case "EditText":
                view = createEditText(context, attrs);
                verifyNotNull(view, name);
                break;
            case "Spinner":
                view = createSpinner(context, attrs);
                verifyNotNull(view, name);
                break;
            case "ImageButton":
                view = createImageButton(context, attrs);
                verifyNotNull(view, name);
                break;
            case "CheckBox":
                view = createCheckBox(context, attrs);
                verifyNotNull(view, name);
                break;
            case "RadioButton":
                view = createRadioButton(context, attrs);
                verifyNotNull(view, name);
                break;
            case "CheckedTextView":
                view = createCheckedTextView(context, attrs);
                verifyNotNull(view, name);
                break;
            case "AutoCompleteTextView":
                view = createAutoCompleteTextView(context, attrs);
                verifyNotNull(view, name);
                break;
            case "MultiAutoCompleteTextView":
                view = createMultiAutoCompleteTextView(context, attrs);
                verifyNotNull(view, name);
                break;
            case "RatingBar":
                view = createRatingBar(context, attrs);
                verifyNotNull(view, name);
                break;
            case "SeekBar":
                view = createSeekBar(context, attrs);
                verifyNotNull(view, name);
                break;
            default:
                // The fallback that allows extending class to take over view inflation
                // for other tags. Note that we don't check that the result is not-null.
                // That allows the custom inflater path to fall back on the default one
                // later in this method.
                view = createView(context, name, attrs);
        }

        if (view == null && originalContext != context) {
            // If the original context does not equal our themed context, then we need to manually
            // inflate it using the name so that android:theme takes effect.
            view = createViewFromTag(context, name, attrs);
        }

        if (view != null) {
            // If we have created a view, check its android:onClick
            checkOnClickListener(view, attrs);
        }

        return view;
    }
```
能看到吧，此时把根据name去生成不同的View，这样就替换原来的View加入到布局中。

**从官方的App包我们能够得到什么启发？我们可以通过在这里做一个Factory，做一次View的生成拦截。实际上这种思路，已经被用于换肤框架中，其中一种，且个人认为最好的流派。就是这样设计的**


当然除了App包有这种操作，实际上在Activity里面也有一样的设计，不过是专门针对Fragment的。

#### Fragment标签的实例化
还记得开篇的attach方法吗？其中一行设置了当前LayoutInflater的PrivateFactory
```java
mWindow.getLayoutInflater().setPrivateFactory(this);
```

这个Factory也是有一个onCreateView的接口，我们直接看看做了什么：
```java
    public View onCreateView(@Nullable View parent, @NonNull String name,
            @NonNull Context context, @NonNull AttributeSet attrs) {
        if (!"fragment".equals(name)) {
            return onCreateView(name, context, attrs);
        }

        return mFragments.onCreateView(parent, name, context, attrs);
    }
```
能看到在PrivateFactory拦截的正是fragment标签。接着就通过mFragments.onCreateView创建Fragment。关于Fragment，我之后专门用一篇文章聊聊。

正是因为Fragment不是一个View，因此才需要做这种特殊处理。

### AsyncLayoutInflater的性能优化
在Android的渲染中，其实大部分的事情都在ui线程中完成。我们稍微思考其中的工作，我们暂时只考虑Java可以轻易看见的地方。做了反射，做了测量布局，渲染，都在一个线程中。除此之外还有很多业务逻辑，这样会导致ui线程十分重量级。

为了解决这个问题，官方也好，各大厂商也好，都做十分巨大的努力去优化这个ui渲染速度。

接下来AsyncLayoutInflater就是官方提供优化工具，实际上这是一个封装好的异步LayoutInflater，这样就能降低ui线程的压力。想法是好的，实际上不过这个api设计上有点缺陷，导致有点鸡肋。

我们看看怎么使用
```java
        new AsyncLayoutInflater(Activity.this)
                .inflate(R.layout.async_layout, null, new AsyncLayoutInflater.OnInflateFinishedListener() {
                    @Override
                    public void onInflateFinished(View view, int resid, ViewGroup parent) {
                        setContentView(view);
                    }
                });
```

能看到当异步实例化好View之后，再去setContentView。

我们直接看看构造函数，以及实例化的方法：
```java
 public AsyncLayoutInflater(@NonNull Context context) {
        mInflater = new BasicInflater(context);
        mHandler = new Handler(mHandlerCallback);
        mInflateThread = InflateThread.getInstance();
    }

    @UiThread
    public void inflate(@LayoutRes int resid, @Nullable ViewGroup parent,
            @NonNull OnInflateFinishedListener callback) {
        if (callback == null) {
            throw new NullPointerException("callback argument may not be null!");
        }
        InflateRequest request = mInflateThread.obtainRequest();
        request.inflater = this;
        request.resid = resid;
        request.parent = parent;
        request.callback = callback;
        mInflateThread.enqueue(request);
    }
```

能看到实际上每一次调用，都会把一个所有需要实例化的request封装起来，丢进mInflateThread实例化队列中。
```java
private static class InflateThread extends Thread {
        private static final InflateThread sInstance;
        static {
            sInstance = new InflateThread();
            sInstance.start();
        }

        public static InflateThread getInstance() {
            return sInstance;
        }

        private ArrayBlockingQueue<InflateRequest> mQueue = new ArrayBlockingQueue<>(10);
        private SynchronizedPool<InflateRequest> mRequestPool = new SynchronizedPool<>(10);

        // Extracted to its own method to ensure locals have a constrained liveness
        // scope by the GC. This is needed to avoid keeping previous request references
        // alive for an indeterminate amount of time, see b/33158143 for details
        public void runInner() {
            InflateRequest request;
            try {
                request = mQueue.take();
            } catch (InterruptedException ex) {
                // Odd, just continue
                Log.w(TAG, ex);
                return;
            }

            try {
                request.view = request.inflater.mInflater.inflate(
                        request.resid, request.parent, false);
            } catch (RuntimeException ex) {
                // Probably a Looper failure, retry on the UI thread
                Log.w(TAG, "Failed to inflate resource in the background! Retrying on the UI"
                        + " thread", ex);
            }
            Message.obtain(request.inflater.mHandler, 0, request)
                    .sendToTarget();
        }

        @Override
        public void run() {
            while (true) {
                runInner();
            }
        }

        public InflateRequest obtainRequest() {
            InflateRequest obj = mRequestPool.acquire();
            if (obj == null) {
                obj = new InflateRequest();
            }
            return obj;
        }

        public void releaseRequest(InflateRequest obj) {
            obj.callback = null;
            obj.inflater = null;
            obj.parent = null;
            obj.resid = 0;
            obj.view = null;
            mRequestPool.release(obj);
        }

        public void enqueue(InflateRequest request) {
            try {
                mQueue.put(request);
            } catch (InterruptedException e) {
                throw new RuntimeException(
                        "Failed to enqueue async inflate request", e);
            }
        }
    }
```
能看到这个线程的run方法中是一个死循环，在这个死循环里面会不断读取mQueue的的请求，进行一次次的实例化。一旦实例化完成之后，将会通过Handler通知回调完成。

通过AsyncLayoutInflater和正常的LayoutInflater比较就能清楚，双方的差异是什么？

我们稍微浏览一下用于实例化操作真正的LayoutInflater
```java
    private static class BasicInflater extends LayoutInflater {
        private static final String[] sClassPrefixList = {
            "android.widget.",
            "android.webkit.",
            "android.app."
        };

        BasicInflater(Context context) {
            super(context);
        }

        @Override
        public LayoutInflater cloneInContext(Context newContext) {
            return new BasicInflater(newContext);
        }

        @Override
        protected View onCreateView(String name, AttributeSet attrs) throws ClassNotFoundException {
            for (String prefix : sClassPrefixList) {
                try {
                    View view = createView(name, prefix, attrs);
                    if (view != null) {
                        return view;
                    }
                } catch (ClassNotFoundException e) {
                    // In this case we want to let the base class take a crack
                    // at it.
                }
            }

            return super.onCreateView(name, attrs);
        }
    }
```

- 首先AsyncLayoutInflater不能设置Factory，那么也就没办法创建AppCompat系列的View,也没有办法创建Fragment。
- 其次AsyncLayoutInflater包含的阻塞队列居然只有10个，如果遇到RecyclerView这种多个子布局，超过了10个需要实例化的View，反而需要主线程的阻塞。可以使用线程池子处理
- 如果是setContentView的话，本身就是处于ui线程的第一步，也就没有必要异步。
- 甚至如果线程工作满了，可以把部分任务丢给主线程处理。
- 而且在run中写一个死循环进行读取实例化任务，不合理。完全有更好的异步等到做法，如生产者消费者模式。


处理这几个问题确实不难，阅读过源码当然知道怎么处理，这里就不继续赘述了。

### 总结
本文总结了Activity的分层，本质上android从视图上来看，是一个DecorView包裹所有的View，我们绘制的内容区域一般在R.id.content中。

LayoutInflater本质上是通过一个构造函数的缓存map来加速反射View的速度，同时merge压缩层级原理就是越过本次View的生成，将内部的view生成出来直接添加到父布局，因此如果include需要的父布局和外层一直，就没有必要在内部也添加一个一模一样的布局。

AsyncLayoutInflater本质上就是把反射的工作丢给一个专门的线程去处理。但是其鸡肋的设计导致使用场景不广泛。


下一篇将和大家聊聊资源是怎么加载到我们的App的，把本篇遗留的问题解决了。













