---
title: Android 重学系列 WMS在Activity启动中的职责 添加窗体(三)
top: false
cover: false
date: 2019-09-26 08:30:57
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
经过上一篇章的讨论，我们理清楚了ActivityRecord，TaskRecord和窗体容器之间的关系。同时达到了应用启动时，启动的第一个启动窗口，StartingWindow。这个时候，我们可以看到一个直指核心的代码段：
```java
            wm = (WindowManager) context.getSystemService(WINDOW_SERVICE);
            view = win.getDecorView();

...
            wm.addView(view, params);
```
这个方法联通了WMS中的addView方法。

上一篇：[Android 重学系列 WMS在Activity启动中的职责(二)](https://www.jianshu.com/p/c7cc335b880a)


# 正文
## Context 获取系统服务
在正式聊WMS之前，我们先来看看context.getSystemService其核心原理，才能找到WindowManager的实现类：
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)

```java
    @Override
    public Object getSystemService(String name) {
        return SystemServiceRegistry.getSystemService(this, name);
    }
```
文件： /[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[SystemServiceRegistry.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/SystemServiceRegistry.java)

```java
private static final HashMap<String, ServiceFetcher<?>> SYSTEM_SERVICE_FETCHERS =
            new HashMap<String, ServiceFetcher<?>>();

public static Object getSystemService(ContextImpl ctx, String name) {
        ServiceFetcher<?> fetcher = SYSTEM_SERVICE_FETCHERS.get(name);
        return fetcher != null ? fetcher.getService(ctx) : null;
    }
```
能看到是实际上所有的我们通过Context获取系统服务，是通过SYSTEM_SERVICE_FETCHERS这个提前存放在HashMap的服务集合中。这个服务是在静态代码域中提前注册。
```java
        registerService(Context.WINDOW_SERVICE, WindowManager.class,
                new CachedServiceFetcher<WindowManager>() {
            @Override
            public WindowManager createService(ContextImpl ctx) {
                return new WindowManagerImpl(ctx);
            }});
```
能看到此时实际上WindowManager的interface是由WindowManagerImpl实现的。

这里先上一个WindowManager的UML类图。
![WindowManager.png](https://upload-images.jianshu.io/upload_images/9880421-f1e04dd40e0c438d.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


我们能够从这个UML图能够看到，其实所有的事情都委托给WindowManagerGlobal工作。因此我们只需要看WindowManagerGlobal中做了什么。

因此我们要寻求WindowManager的addView的方法，实际上就是看WindowManagerGlobal的addView方法。
```java
public void addView(View view, ViewGroup.LayoutParams params,
            Display display, Window parentWindow) {
       ...
        final WindowManager.LayoutParams wparams = (WindowManager.LayoutParams) params;
        if (parentWindow != null) {
         parentWindow.adjustLayoutParamsForSubWindow(wparams);
        } else {
            // If there's no parent, then hardware acceleration for this view is
            // set from the application's hardware acceleration setting.
            final Context context = view.getContext();
            if (context != null
                    && (context.getApplicationInfo().flags
                            & ApplicationInfo.FLAG_HARDWARE_ACCELERATED) != 0) {
                wparams.flags |= WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
            }
        }

        ViewRootImpl root;
        View panelParentView = null;

        synchronized (mLock) {
            // Start watching for system property changes.
            ...
            int index = findViewLocked(view, false);
            if (index >= 0) {
                if (mDyingViews.contains(view)) {
                    // Don't wait for MSG_DIE to make it's way through root's queue.
                    mRoots.get(index).doDie();
                } else {
                    throw new IllegalStateException("View " + view
                            + " has already been added to the window manager.");
                }
                // The previous removeView() had not completed executing. Now it has.
            }

            // If this is a panel window, then find the window it is being
            // attached to for future reference.
            if (wparams.type >= WindowManager.LayoutParams.FIRST_SUB_WINDOW &&
                    wparams.type <= WindowManager.LayoutParams.LAST_SUB_WINDOW) {
                final int count = mViews.size();
                for (int i = 0; i < count; i++) {
                    if (mRoots.get(i).mWindow.asBinder() == wparams.token) {
                        panelParentView = mViews.get(i);
                    }
                }
            }

            root = new ViewRootImpl(view.getContext(), display);

            view.setLayoutParams(wparams);

            mViews.add(view);
            mRoots.add(root);
            mParams.add(wparams);

            // do this last because it fires off messages to start doing things
            try {
                root.setView(view, wparams, panelParentView);
            } catch (RuntimeException e) {
                // BadTokenException or InvalidDisplayException, clean up.
                if (index >= 0) {
                    removeViewLocked(index, true);
                }
                throw e;
            }
        }
    }
```
这里能够看到一个新的addView的时候，会找到是否有父Window。没有则继续往后走，判断新建窗体的type是否是子窗口类型，是则查找传进来的Binder对象和存储在缓存中的Binder对象又没有对应的Window。有则作为本次新建窗口的复窗口。

最后能够看到我们熟悉的类ViewRootImpl。这个类可以说是所有View绘制的根部核心，这个类会在后面View绘制流程聊聊。最后会调用ViewRootImpl的setView进一步的沟通系统应用端。

这里涉及到了几个有趣的宏，如WindowManager.LayoutParams.FIRST_SUB_WINDOW 。它们象征这当前Window处于什么层级。

## Window的层级
Window的层级，我们大致可以分为3大类：System Window(系统窗口)，Application Window(应用窗口)，Sub Window(子窗口)

### Application Window(应用窗口)
Application值得注意的有这么几个宏：
type|描述
-|-
FIRST_APPLICATION_WINDOW = 1|应用程序窗口初始值
TYPE_BASE_APPLICATION = 1|应用窗口类型初始值，其他窗口以此为基准
TYPE_APPLICATION = 2|普通应用程序窗口类型
TYPE_APPLICATION_STARTING = 3|应用程序的启动窗口类型，不是应用进程支配，当第一个应用进程诞生了启动窗口就会销毁
TYPE_DRAWN_APPLICATION = 4|应用显示前WindowManager会等待这种窗口类型绘制完毕，一般在多用户使用
LAST_APPLICATION_WINDOW = 99|应用窗口类型最大值

因此此时我们能够清楚，应用窗口的范围在1～99之间。

### Sub Window(子窗口)

type|描述
-|-
FIRST_SUB_WINDOW = 1000|子窗口初始值
TYPE_APPLICATION_PANEL = FIRST_SUB_WINDOW|应用的panel窗口，在父窗口上显示
TYPE_APPLICATION_MEDIA = FIRST_SUB_WINDOW + 1|多媒体内容子窗口，在父窗口之下
TYPE_APPLICATION_SUB_PANEL = FIRST_SUB_WINDOW + 2|也是一种panel子窗口，位于所有TYPE_APPLICATION_PANEL之上
TYPE_APPLICATION_ATTACHED_DIALOG = FIRST_SUB_WINDOW + 3|dialog弹窗
TYPE_APPLICATION_MEDIA_OVERLAY  = FIRST_SUB_WINDOW + 4|多媒体内容窗口的覆盖层
TYPE_APPLICATION_ABOVE_SUB_PANEL = FIRST_SUB_WINDOW + 5|位于子panel之上窗口
LAST_SUB_WINDOW = 1999|子窗口类型最大值

能够看到子窗口的范围从1000～1999

### System Window(系统窗口)
type|描述
-|-
FIRST_SYSTEM_WINDOW     = 2000|系统窗口初始值
TYPE_STATUS_BAR = FIRST_SYSTEM_WINDOW|系统状态栏
TYPE_SEARCH_BAR = FIRST_SYSTEM_WINDOW+1|搜索条窗口
TYPE_PHONE = FIRST_SYSTEM_WINDOW+2|通话窗口
TYPE_SYSTEM_ALERT = FIRST_SYSTEM_WINDOW+3|alert窗口，电量不足时警告
TYPE_KEYGUARD  = FIRST_SYSTEM_WINDOW+4|屏保窗口
 TYPE_TOAST = FIRST_SYSTEM_WINDOW+5|Toast提示窗口
 TYPE_SYSTEM_OVERLAY  = FIRST_SYSTEM_WINDOW+6|系统覆盖层窗口，这个层不会响应点击事件
TYPE_PRIORITY_PHONE  = FIRST_SYSTEM_WINDOW+7|电话优先层，在屏保状态下显示通话
 TYPE_SYSTEM_DIALOG = FIRST_SYSTEM_WINDOW+8|系统层级的dialog，比如RecentAppDialog
TYPE_KEYGUARD_DIALOG= FIRST_SYSTEM_WINDOW+9|屏保时候对话框(如qq屏保时候的聊天框)
 TYPE_SYSTEM_ERROR= FIRST_SYSTEM_WINDOW+10|系统错误窗口
TYPE_INPUT_METHOD= FIRST_SYSTEM_WINDOW+11|输入法窗口
TYPE_INPUT_METHOD_DIALOG= FIRST_SYSTEM_WINDOW+12|输入法窗口上的对话框
TYPE_WALLPAPER= FIRST_SYSTEM_WINDOW+13|壁纸窗口
TYPE_STATUS_BAR_PANEL   = FIRST_SYSTEM_WINDOW+14|滑动状态栏窗口
LAST_SYSTEM_WINDOW      = 2999|系统窗口最大值

常见的系统级别窗口主要是这几个。能够注意到系统窗口层级是从2000～2999。

这些层级有什么用的？这些层级会作为参考，将会插入到显示栈的位置，层级值越高，越靠近用户。这个逻辑之后会聊到。


## ViewRootImpl setView
ViewRootImpl里面包含了许多事情，主要是包含了我们熟悉的View的绘制流程，以及添加Window实例的流程。

本文是关于WMS，因此我们只需要看下面这个核心函数

```java
public void setView(View view, WindowManager.LayoutParams attrs, View panelParentView) {
        synchronized (this) {
            if (mView == null) {
                mView = view;

                mAttachInfo.mDisplayState = mDisplay.getState();
//注册屏幕变换监听
                mDisplayManager.registerDisplayListener(mDisplayListener, mHandler);

                mViewLayoutDirectionInitial = mView.getRawLayoutDirection();
//点击事件分发
                mFallbackEventHandler.setView(view);
                mWindowAttributes.copyFrom(attrs);
                if (mWindowAttributes.packageName == null) {
                    mWindowAttributes.packageName = mBasePackageName;
                }
                attrs = mWindowAttributes;
                setTag();

              ...
                // Keep track of the actual window flags supplied by the client.
                mClientWindowLayoutFlags = attrs.flags;

                setAccessibilityFocus(null, null);

....

            ...
                mSoftInputMode = attrs.softInputMode;
                mWindowAttributesChanged = true;
                mWindowAttributesChangesFlag = WindowManager.LayoutParams.EVERYTHING_CHANGED;
                mAttachInfo.mRootView = view;
                mAttachInfo.mScalingRequired = mTranslator != null;
                mAttachInfo.mApplicationScale =
                        mTranslator == null ? 1.0f : mTranslator.applicationScale;
                if (panelParentView != null) {
                    mAttachInfo.mPanelParentWindowToken
                            = panelParentView.getApplicationWindowToken();
                }
                mAdded = true;
                int res; /* = WindowManagerImpl.ADD_OKAY; */

                // Schedule the first layout -before- adding to the window
                // manager, to make sure we do the relayout before receiving
                // any other events from the system.
                requestLayout();
                if ((mWindowAttributes.inputFeatures
                        & WindowManager.LayoutParams.INPUT_FEATURE_NO_INPUT_CHANNEL) == 0) {
                    mInputChannel = new InputChannel();
                }
                mForceDecorViewVisibility = (mWindowAttributes.privateFlags
                        & PRIVATE_FLAG_FORCE_DECOR_VIEW_VISIBILITY) != 0;
                try {
                    mOrigWindowType = mWindowAttributes.type;
                    mAttachInfo.mRecomputeGlobalAttributes = true;
                    collectViewAttributes();
                    res = mWindowSession.addToDisplay(mWindow, mSeq, mWindowAttributes,
                            getHostVisibility(), mDisplay.getDisplayId(), mWinFrame,
                            mAttachInfo.mContentInsets, mAttachInfo.mStableInsets,
                            mAttachInfo.mOutsets, mAttachInfo.mDisplayCutout, mInputChannel);
                } catch (RemoteException e) {
                    mAdded = false;
                    mView = null;
                    mAttachInfo.mRootView = null;
                    mInputChannel = null;
                    mFallbackEventHandler.setView(null);
                    unscheduleTraversals();
                    setAccessibilityFocus(null, null);
                    throw new RuntimeException("Adding window failed", e);
                } finally {
                    if (restore) {
                        attrs.restore();
                    }
                }

         ...

        }
    }
```

这个方法有两个核心requestLayout以及addToDisplay。
- 1.requestLayout实际上就是指View的绘制流程，并且最终会把像素数据发送到Surface底层。
- 2.mWindowSession.addToDisplay 添加Window实例到WMS中。

本文主要讨论WMS，requestLayout的方法暂时不谈。
## WindowManager的Session设计思想
先来看看Session类：
```java
class Session extends IWindowSession.Stub implements IBinder.DeathRecipient
```
得知此时Session实现了一个IWindowSession的Binder对象。并且实现了Binder的死亡监听。

那么这个Session是从哪里来的呢？实际上是通过WMS通过跨进程通信把数据这个Binder对象传递过来的：
```java
    @Override
    public IWindowSession openSession(IWindowSessionCallback callback, IInputMethodClient client,
            IInputContext inputContext) {
        if (client == null) throw new IllegalArgumentException("null client");
        if (inputContext == null) throw new IllegalArgumentException("null inputContext");
        Session session = new Session(this, callback, client, inputContext);
        return session;
    }
```
通着这种方式，就能把一个Session带上WMS相关的环境送给客户端操作。这种方式和什么很相似，实际上和servicemanager查询服务Binder的思路几乎一模一样。

```java
@Override
    public int addToDisplay(IWindow window, int seq, WindowManager.LayoutParams attrs,
            int viewVisibility, int displayId, Rect outFrame, Rect outContentInsets,
            Rect outStableInsets, Rect outOutsets,
            DisplayCutout.ParcelableWrapper outDisplayCutout, InputChannel outInputChannel) {
        return mService.addWindow(this, window, seq, attrs, viewVisibility, displayId, outFrame,
                outContentInsets, outStableInsets, outOutsets, outDisplayCutout, outInputChannel);
    }
```
很有趣的是，我们能够看到，按照道理我们需要添加窗体实例到WMS中。从逻辑上来讲，我们只需要做一次跨进程通信即可。但是为什么需要一个Session作为中转站呢？

![image.png](https://upload-images.jianshu.io/upload_images/9880421-0cb4e3ec93bd327e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能够看到实际上Session(会话)做的事情不仅仅只有沟通WMS这么简单。实际上它还同时处理了窗口上的拖拽，输入法等逻辑，更加重要的是Session面对着系统多个服务，但是通过这个封装，应用程序只需要面对这个Sesion接口，真的是名副其实的"会话"。

这种设计想什么？实际上就是我们常说的门面设计模式。

### IWindow对象
注意，这里面除了IWindowSession之外,当我们调用addWindow添加Window到WMS中的时候，其实还存在一个IWindow接口.这个IWindow是指PhoneWindow吗？

很遗憾。并不是。PhoneWindow基础的接口只有Window接口。它并不是一个IBinder对象。我们转过头看看ViewRootImpl.
```java
public ViewRootImpl(Context context, Display display) {
        mContext = context;
        mWindowSession = WindowManagerGlobal.getWindowSession();
        mDisplay = display;
        mBasePackageName = context.getBasePackageName();
        mThread = Thread.currentThread();
        mLocation = new WindowLeaked(null);
        mLocation.fillInStackTrace();
        mWidth = -1;
        mHeight = -1;
        mDirty = new Rect();
        mTempRect = new Rect();
        mVisRect = new Rect();
        mWinFrame = new Rect();
        mWindow = new W(this);
        mTargetSdkVersion = context.getApplicationInfo().targetSdkVersion;
        mViewVisibility = View.GONE;
        mTransparentRegion = new Region();
        mPreviousTransparentRegion = new Region();
        mFirst = true; // true for the first time the view is added
        mAdded = false;
        mAttachInfo = new View.AttachInfo(mWindowSession, mWindow, display, this, mHandler, this,
                context);
...
        mViewConfiguration = ViewConfiguration.get(context);
        mDensity = context.getResources().getDisplayMetrics().densityDpi;
        mNoncompatDensity = context.getResources().getDisplayMetrics().noncompatDensityDpi;
        mFallbackEventHandler = new PhoneFallbackEventHandler(context);
        mChoreographer = Choreographer.getInstance();
        mDisplayManager = (DisplayManager)context.getSystemService(Context.DISPLAY_SERVICE);

        if (!sCompatibilityDone) {
            sAlwaysAssignFocus = mTargetSdkVersion < Build.VERSION_CODES.P;

            sCompatibilityDone = true;
        }

        loadSystemProperties();
    }
```
能看到此时，实际上在ViewRootImpl的构造函数会对应当前生成一个W的内部类。这个内部类：
```java
static class W extends IWindow.Stub
```

这个内部类实际上就是一个Binder类，里面回调了很多方法来操作当前的ViewRootImpl。换句话说，就是把当前的ViewRootImpl的代理W交给WMS去管理。

那么我们可以总结，IWindow是WMS用来间接操作ViewRootImpl中的View，IWindowSession是App用来间接操作WMS。

## WMS.addWindow
WMS的addWindow很长，因此我这边拆开成3部分聊
### 添加窗体的准备步骤
```java
public int addWindow(Session session, IWindow client, int seq,
            LayoutParams attrs, int viewVisibility, int displayId, Rect outFrame,
            Rect outContentInsets, Rect outStableInsets, Rect outOutsets,
            DisplayCutout.ParcelableWrapper outDisplayCutout, InputChannel outInputChannel) {
        int[] appOp = new int[1];
        int res = mPolicy.checkAddPermission(attrs, appOp);
        if (res != WindowManagerGlobal.ADD_OKAY) {
            return res;
        }

        boolean reportNewConfig = false;
        WindowState parentWindow = null;
        long origId;
        final int callingUid = Binder.getCallingUid();
        final int type = attrs.type;

        synchronized(mWindowMap) {
            if (!mDisplayReady) {
                throw new IllegalStateException("Display has not been initialialized");
            }

            final DisplayContent displayContent = getDisplayContentOrCreate(displayId);

            if (displayContent == null) {
...
                return WindowManagerGlobal.ADD_INVALID_DISPLAY;
            }
            if (!displayContent.hasAccess(session.mUid)
                    && !mDisplayManagerInternal.isUidPresentOnDisplay(session.mUid, displayId)) {
...
                return WindowManagerGlobal.ADD_INVALID_DISPLAY;
            }

            if (mWindowMap.containsKey(client.asBinder())) {
  ...
                return WindowManagerGlobal.ADD_DUPLICATE_ADD;
            }

            if (type >= FIRST_SUB_WINDOW && type <= LAST_SUB_WINDOW) {
//如果是子窗口，则通过Binder找父窗口
                parentWindow = windowForClientLocked(null, attrs.token, false);
                if (parentWindow == null) {
...
                    return WindowManagerGlobal.ADD_BAD_SUBWINDOW_TOKEN;
                }
                if (parentWindow.mAttrs.type >= FIRST_SUB_WINDOW
                        && parentWindow.mAttrs.type <= LAST_SUB_WINDOW) {
...
                    return WindowManagerGlobal.ADD_BAD_SUBWINDOW_TOKEN;
                }
            }

            if (type == TYPE_PRIVATE_PRESENTATION && !displayContent.isPrivate()) {
...
                return WindowManagerGlobal.ADD_PERMISSION_DENIED;
            }

            AppWindowToken atoken = null;
            final boolean hasParent = parentWindow != null;
//从DisplayContent找到对应的WIndowToken
            WindowToken token = displayContent.getWindowToken(
                    hasParent ? parentWindow.mAttrs.token : attrs.token);

            final int rootType = hasParent ? parentWindow.mAttrs.type : type;

....
    }
```
我们抛开大部分的校验逻辑。实际上可以把这个过程总结为以下几点：
- 1.判断又没有相关的权限
- 2.尝试着获取当前displayId对应的DisplayContent，没有则创建。其逻辑实际上和我上一篇说的创建DisplayContent一摸一样
- 3.通过mWindowMap，判断当前IWindow是否被添加过，是的话说明已经存在这个Window，不需要继续添加
- 4.如果当前窗口类型是子窗口，则会通过WindowToken.attrs参数中的token去查找当前窗口的父窗口是什么。
- 5.如果有父窗口，则从DisplayContent中以父窗口的IWindow获取父窗口WindowToken的对象，否则尝试的获取当前窗口对应的WindowToken对象。

我们稍微探索一下其中的几个核心：
#### 通过windowForClientLocked查找父窗口的WindowState
```java
final WindowState windowForClientLocked(Session session, IBinder client, boolean throwOnError) {
        WindowState win = mWindowMap.get(client);
        if (localLOGV) Slog.v(TAG_WM, "Looking up client " + client + ": " + win);
        if (win == null) {
            if (throwOnError) {
                throw new IllegalArgumentException(
                        "Requested window " + client + " does not exist");
            }
            Slog.w(TAG_WM, "Failed looking up window callers=" + Debug.getCallers(3));
            return null;
        }
        if (session != null && win.mSession != session) {
            if (throwOnError) {
                throw new IllegalArgumentException("Requested window " + client + " is in session "
                        + win.mSession + ", not " + session);
            }
            Slog.w(TAG_WM, "Failed looking up window callers=" + Debug.getCallers(3));
            return null;
        }

        return win;
    }
```
实际上可以看到这里面是从mWindowMap通过IWindow获取WindowState对象。还记得我上篇说过很重要的数据结构吗？mWindowMap实际上是保存着WMS中IWindow对应WindowState对象。IWindow本质上是WMS控制ViewRootImpl的Binder接口。因此我们可以把WindowState看成应用进程的对应的对象也未尝不可。

### 获取对应的WindowToken
```java
            AppWindowToken atoken = null;
            final boolean hasParent = parentWindow != null;
//从DisplayContent找到对应的WIndowToken
            WindowToken token = displayContent.getWindowToken(
                    hasParent ? parentWindow.mAttrs.token : attrs.token);
```
从这里面我们能够看到WindowToken，是通过DisplayContent获取到的。
```
WindowToken getWindowToken(IBinder binder) {
        return mTokenMap.get(binder);
    }
```

这样就能看到我前两篇提到过的很重要的数据结构:mTokenMap以及mWindowMap。这两者要稍微区分一下：
mWindowMap是以IWindow为key，WindowState为value。
mTokenMap是以WindowState的IBinder(一般为IApplicationToken)为key，WindowToken为value

还记得mTokenMap在Activity的启动流程中做的事情吗？在创建AppWIndowContainer的时候，会同时创建AppWindowToken，AppWIndowToken的构造会把当前的IBinder作为key，AppWindowToken作为value添加到mTokenMap中。

也就是说，如果系统想要通过应用进程给的IWindow找到真正位于WMS中Window的句柄，必须通过这两层变换才能真正找到。

### 拆分情况获取对应的WindowToken和AppWindowToken
这个时候就分为两种情况，一种是存在WindowToken，一种是不存在WindowToken。
```java
            boolean addToastWindowRequiresToken = false;

            if (token == null) {
            //校验窗口参数是否合法  
            ...
                
                final IBinder binder = attrs.token != null ? attrs.token : client.asBinder();
                final boolean isRoundedCornerOverlay =
                        (attrs.privateFlags & PRIVATE_FLAG_IS_ROUNDED_CORNERS_OVERLAY) != 0;
                token = new WindowToken(this, binder, type, false, displayContent,
                        session.mCanAddInternalSystemWindow, isRoundedCornerOverlay);
            } else if (rootType >= FIRST_APPLICATION_WINDOW && rootType <= LAST_APPLICATION_WINDOW) {
                atoken = token.asAppWindowToken();
                  if (atoken == null) {
                    return WindowManagerGlobal.ADD_NOT_APP_TOKEN;
                } 
...
                } else if (atoken.removed) {
...
                } else if (type == TYPE_APPLICATION_STARTING && atoken.startingWindow != null) {
...
                 
                }
            } else if (rootType == TYPE_INPUT_METHOD) {
...
                   
            } else if (rootType == TYPE_VOICE_INTERACTION) {
...
            } else if (rootType == TYPE_WALLPAPER) {
 ...
            } else if (rootType == TYPE_DREAM) {
...
            } else if (rootType == TYPE_ACCESSIBILITY_OVERLAY) {
...
            } else if (type == TYPE_TOAST) {
....
           } else if (type == TYPE_QS_DIALOG) {
...
            } else if (token.asAppWindowToken() != null) {

                attrs.token = null;
                token = new WindowToken(this, client.asBinder(), type, false, displayContent,
                        session.mCanAddInternalSystemWindow);
            }

```
当我们通过mTokenMap获取WindowToken的时候，大致分为四种情况。WindowToken会尝试的获取父窗口对应的Token，找不到则使用WindowManager.LayoutParams中的WindowToken。一般来说我们找到的都有父亲的WindowToken。

- 1.无关应用的找不到WindowToken
- 2.有关应用找不到WindowToken。
- 3.无关应用找到WindowToken
- 4.有关应用找到WindowToken

#### 前两种情况解析
实际上前两种情况，一旦发现找不到WindowToken，如果当前的窗口和应用相关的，就一定爆错误。如Toast，输入法，应用窗口等等。

因此在Android 8.0开始，当我们想要显示Toast的时候，加入传入的Context是Application而不是Activity，此时一旦发现mTokenMap中找不到IApplicationToken对应的WindowToken就爆出了错误。正确的做法应该是需要获取Activity当前的Context。

在上面的情况应用启动窗口，此时并没有启动Activity。因此不可能会被校验拦下，因此并没有异常抛出。就会自己创建一个WindowToken。


#### 后两种的解析
当找到WindowToken，一般是指Activity启动之后，在AppWindowToken初始化后，自动加入了mTokenMap中。此时的情况稍微复杂了点。

当是子窗口的时候，则会判断当前的WindowToken是不是AppWindowToken。不是，或者被移除等异常情况则报错。

如果是壁纸，输入法，系统弹窗，toast等窗口模式，子窗口和父窗口的模式必须一致。

当此时的AppWindowToken不为空的时候，说明在New的时候已经生成，且没有移除，将会生成一个新的WindowToken。

为什么要生成一个新的windowToken?可以翻阅之前我写的文章，只要每一次调用一次构造函数将会把当前的WindowToken添加到mTokenMap中，实际上也是担心，对应的AppWindowToken出现的重新绑定的问题。


### 添加WindowState实例到数据结构
但是别忘了，我们这个时候还需要把相关的数据结构存储到全局。

```java
            final WindowState win = new WindowState(this, session, client, token, parentWindow,
                    appOp[0], seq, attrs, viewVisibility, session.mUid,
                    session.mCanAddInternalSystemWindow);
            if (win.mDeathRecipient == null) {
...
                return WindowManagerGlobal.ADD_APP_EXITING;
            }

            if (win.getDisplayContent() == null) {
...
                return WindowManagerGlobal.ADD_INVALID_DISPLAY;
            }

            final boolean hasStatusBarServicePermission =
                    mContext.checkCallingOrSelfPermission(permission.STATUS_BAR_SERVICE)
                            == PackageManager.PERMISSION_GRANTED;
            mPolicy.adjustWindowParamsLw(win, win.mAttrs, hasStatusBarServicePermission);
            win.setShowToOwnerOnlyLocked(mPolicy.checkShowToOwnerOnly(attrs));

            res = mPolicy.prepareAddWindowLw(win, attrs);
            if (res != WindowManagerGlobal.ADD_OKAY) {
                return res;
            }
            // From now on, no exceptions or errors allowed!

            res = WindowManagerGlobal.ADD_OKAY;
            if (mCurrentFocus == null) {
                mWinAddedSinceNullFocus.add(win);
            }

            if (excludeWindowTypeFromTapOutTask(type)) {
                displayContent.mTapExcludedWindows.add(win);
            }

            origId = Binder.clearCallingIdentity();

            win.attach();
//以IWindow为key，WindowState为value存放到WindowMap中
            mWindowMap.put(client.asBinder(), win);

            win.initAppOpsState();

....
            win.mToken.addWindow(win);

```
因为完全可能出现新的WindowToken，因此干脆会创建一个新的WindowState。此时会对调用WindowState.attach方法
```
    void attach() {
        mSession.windowAddedLocked(mAttrs.packageName);
    }
```
这方法挺重要的，Session做了一次添加锁定。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[Session.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/Session.java)

```java
void windowAddedLocked(String packageName) {
        mPackageName = packageName;
        mRelayoutTag = "relayoutWindow: " + mPackageName;
        if (mSurfaceSession == null) {
            if (WindowManagerService.localLOGV) Slog.v(
                TAG_WM, "First window added to " + this + ", creating SurfaceSession");
            mSurfaceSession = new SurfaceSession();
            if (SHOW_TRANSACTIONS) Slog.i(
                    TAG_WM, "  NEW SURFACE SESSION " + mSurfaceSession);
            mService.mSessions.add(this);
            if (mLastReportedAnimatorScale != mService.getCurrentAnimatorScale()) {
                mService.dispatchNewAnimatorScaleLocked(this);
            }
        }
        mNumWindow++;
    }
```
此时的工作是什么？联系上下文，当我们新增了PhoneWindow，就会一个ViewRootImpl，也因此新增了Session。此时说明诞生一个新界面，此时已经诞生了相关的容器对象，但是相关的绘制到底层对象还没有创建出来。

命名逻辑和Session很相似。Session是WMS给应用App的会话对象，SurfaceSession是SurfaceFlinger面向上层每一个WIndow需要绘制内容对象。

这个SurfaceSession和SurfaceControl都是重点，联通到SurfaceFlinger很重要的对象。

最后再添加到mWindowMap中。并且把WindowState添加到WindowToken中，让每一个WindowToken赋予状态的信息。我们稍微探索一下addWindow的方法。

## WindowState 添加Window的策略
有没有考虑过WindowManager.LayoutParams是从哪里来的token？

当我们没有指定当前窗口的type，则会自动设置为TYPE_APPLICATION = 2，同时token将会是原来的appwindowtoken.当我们在addView传入了父亲窗口时候，则会通过adjustLayoutParamsForSubWindow先不设定application的值，而是先拿到父亲窗口的token:
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[Window.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/Window.java)

```java
void adjustLayoutParamsForSubWindow(WindowManager.LayoutParams wp) {
        CharSequence curTitle = wp.getTitle();
        if (wp.type >= WindowManager.LayoutParams.FIRST_SUB_WINDOW &&
                wp.type <= WindowManager.LayoutParams.LAST_SUB_WINDOW) {
            if (wp.token == null) {
                View decor = peekDecorView();
                if (decor != null) {
                    wp.token = decor.getWindowToken();
                }
            }
           ...
        } else if (wp.type >= WindowManager.LayoutParams.FIRST_SYSTEM_WINDOW &&
                wp.type <= WindowManager.LayoutParams.LAST_SYSTEM_WINDOW) {
            //设置title
        } else {
            if (wp.token == null) {
                wp.token = mContainer == null ? mAppToken : mContainer.mAppToken;
            }
           //设置title
        }
        if (wp.packageName == null) {
            wp.packageName = mContext.getPackageName();
        }
        if (mHardwareAccelerated ||
                (mWindowAttributes.flags & FLAG_HARDWARE_ACCELERATED) != 0) {
            wp.flags |= FLAG_HARDWARE_ACCELERATED;
        }
    }
```
能够看到此时将会初始化WindowManager.LayoutParams的Token。此时Token在Activity启动流程中已经先一步初始化AppWindowToken。

在聊WindowState的添加窗口的策略之前，我们先来看看WindowState的构造函数。
```java
WindowState(WindowManagerService service, Session s, IWindow c, WindowToken token,
            WindowState parentWindow, int appOp, int seq, WindowManager.LayoutParams a,
            int viewVisibility, int ownerId, boolean ownerCanAddInternalSystemWindow,
            PowerManagerWrapper powerManagerWrapper) {
        super(service);
....
        try {
            c.asBinder().linkToDeath(deathRecipient, 0);
        } catch (RemoteException e) {
...
            return;
        }
        mDeathRecipient = deathRecipient;

        if (mAttrs.type >= FIRST_SUB_WINDOW && mAttrs.type <= LAST_SUB_WINDOW) {
            // The multiplier here is to reserve space for multiple
            // windows in the same type layer.
            mBaseLayer = mPolicy.getWindowLayerLw(parentWindow)
                    * TYPE_LAYER_MULTIPLIER + TYPE_LAYER_OFFSET;
            mSubLayer = mPolicy.getSubWindowLayerFromTypeLw(a.type);
            mIsChildWindow = true;


            parentWindow.addChild(this, sWindowSubLayerComparator);

            mLayoutAttached = mAttrs.type !=
                    WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG;
            mIsImWindow = parentWindow.mAttrs.type == TYPE_INPUT_METHOD
                    || parentWindow.mAttrs.type == TYPE_INPUT_METHOD_DIALOG;
            mIsWallpaper = parentWindow.mAttrs.type == TYPE_WALLPAPER;
        } else {
            // The multiplier here is to reserve space for multiple
            // windows in the same type layer.
            mBaseLayer = mPolicy.getWindowLayerLw(this)
                    * TYPE_LAYER_MULTIPLIER + TYPE_LAYER_OFFSET;
            mSubLayer = 0;
            mIsChildWindow = false;
            mLayoutAttached = false;
            mIsImWindow = mAttrs.type == TYPE_INPUT_METHOD
                    || mAttrs.type == TYPE_INPUT_METHOD_DIALOG;
            mIsWallpaper = mAttrs.type == TYPE_WALLPAPER;
        }
        mIsFloatingLayer = mIsImWindow || mIsWallpaper;

        if (mAppToken != null && mAppToken.mShowForAllUsers) {
            // Windows for apps that can show for all users should also show when the device is
            // locked.
            mAttrs.flags |= FLAG_SHOW_WHEN_LOCKED;
        }

...
    }
```
我们把目光几种在mBaseLayer和mSubLayer的初始化上。我们能够看到在初始化WindowState的时候，会获取WindowState的type是子窗口还是不是子窗口。

此时我们把这个问题分为两种情况：
#### 1.是子窗口
当我们发现当前窗口子窗口，会分为如下2个层级作为基准值。获取当前传进进来的层级type：
符合如下公式:
> mBaselayer = 父窗口层级type(见上文Window层级的表格) * 10000 + 1000；
> mSubLayer = 子窗口本身的层级type(见上文Window层级的表格)
```java
    private static final Comparator<WindowState> sWindowSubLayerComparator =
            new Comparator<WindowState>() {
                @Override
                public int compare(WindowState w1, WindowState w2) {
                    final int layer1 = w1.mSubLayer;
                    final int layer2 = w2.mSubLayer;
                    if (layer1 < layer2 || (layer1 == layer2 && layer2 < 0 )) {
                        return -1;
                    }
                    return 1;
                };
            };

```

此时就会直接添加到parentWindow当中。会不断的比对比当前mSubLayer大的值，直到找到第一个插入。

#### 2.不是子窗口
此时也会根据当前传进来的层级去计算当前window应该插入的地方。
符合如下公式:
>  mBaselayer = 当前的窗口层级type(见上文Window层级的表格) * 10000 + 1000；
> mSubLayer = 0;

将会在接下来通过WindowState的addWindow做进一步调整。


文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[wm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/)/[WindowToken.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/wm/WindowToken.java)
```java
    private final Comparator<WindowState> mWindowComparator =
            (WindowState newWindow, WindowState existingWindow) -> {
        final WindowToken token = WindowToken.this;
        if (newWindow.mToken != token) {
            throw new IllegalArgumentException("newWindow=" + newWindow
                    + " is not a child of token=" + token);
        }

        if (existingWindow.mToken != token) {
            throw new IllegalArgumentException("existingWindow=" + existingWindow
                    + " is not a child of token=" + token);
        }

        return isFirstChildWindowGreaterThanSecond(newWindow, existingWindow) ? 1 : -1;
    };

    protected boolean isFirstChildWindowGreaterThanSecond(WindowState newWindow,
            WindowState existingWindow) {
        // New window is considered greater if it has a higher or equal base layer.
        return newWindow.mBaseLayer >= existingWindow.mBaseLayer;
    }
    void addWindow(final WindowState win) {
        if (DEBUG_FOCUS) Slog.d(TAG_WM,
                "addWindow: win=" + win + " Callers=" + Debug.getCallers(5));

        if (win.isChildWindow()) {
            // Child windows are added to their parent windows.
            return;
        }
        if (!mChildren.contains(win)) {
            if (DEBUG_ADD_REMOVE) Slog.v(TAG_WM, "Adding " + win + " to " + this);
            addChild(win, mWindowComparator);
            mService.mWindowsChanged = true;
            // TODO: Should we also be setting layout needed here and other places?
        }
    }
```
这一段都是继上面调整非子窗口逻辑，能够很轻松的看出来，实际上此时会去不断的比对mBaseLayer直到找到一个大于等于的层级添加到上面。


### 层级初步计算总结
还记得此时在DisplayContent中，把整个WindowContainer的集合拆分成几个层次吗？栈区域，statusbar区域，壁纸区域，输入法区域。

每当我们new了一个WindowToken，将会自动的根据此时窗口类型绑定到对应的区域的末尾。这个时候，当我们addWindow要添加WindowState的时候，将会根据这个句柄去查找WindowToken中的层级，插入到对应的层级中。

用一幅图总结如下:
![Window的层级插入.png](https://upload-images.jianshu.io/upload_images/9880421-3e28fcfa09643a1a.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

### 层级第二次计算
经过上面的区域划分，把窗体大致上区分到了几个区域当中，并且有了大致的顺序，但是实际上，我们只是粗略的处理了Window。实际上在App应用中不是简单的摆好,我们在平时使用的时候并非如此。

还有一种情况需要特殊处理，当我们尝试着执行窗口动画的时候，一般很少遇到有什么东西把Activity的Window动画给遮挡住。实际上也是得益于第二次的调整。
```java
            

            if (type == TYPE_INPUT_METHOD) {
                win.mGivenInsetsPending = true;
                setInputMethodWindowLocked(win);
                imMayMove = false;
            } else if (type == TYPE_INPUT_METHOD_DIALOG) {
                displayContent.computeImeTarget(true /* updateImeTarget */);
                imMayMove = false;
            } else {
                if (type == TYPE_WALLPAPER) {
                    displayContent.mWallpaperController.clearLastWallpaperTimeoutTime();
                    displayContent.pendingLayoutChanges |= FINISH_LAYOUT_REDO_WALLPAPER;
                } else if ((attrs.flags&FLAG_SHOW_WALLPAPER) != 0) {
                    displayContent.pendingLayoutChanges |= FINISH_LAYOUT_REDO_WALLPAPER;
                } else if (displayContent.mWallpaperController.isBelowWallpaperTarget(win)) {

                    displayContent.pendingLayoutChanges |= FINISH_LAYOUT_REDO_WALLPAPER;
                }
            }
...
            if (imMayMove) {
                displayContent.computeImeTarget(true /* updateImeTarget */);
            }
            // Don't do layout here, the window must call
            // relayout to be displayed, so we'll do it there.
            win.getParent().assignChildLayers();
....
```
此时，会从DisplayContent顶部向下重新对层级进行排序。能看到核心方法是就是computeImeTarget以及assignChildLayers。

### computeImeTarget
```java
    WindowState computeImeTarget(boolean updateImeTarget) {
        if (mService.mInputMethodWindow == null) {
            if (updateImeTarget) {
                setInputMethodTarget(null, mService.mInputMethodTargetWaitingAnim);
            }
            return null;
        }

        final WindowState curTarget = mService.mInputMethodTarget;
        if (!canUpdateImeTarget()) {
            return curTarget;
        }

        mUpdateImeTarget = updateImeTarget;
        WindowState target = getWindow(mComputeImeTargetPredicate);


        if (target != null && target.mAttrs.type == TYPE_APPLICATION_STARTING) {
            final AppWindowToken token = target.mAppToken;
            if (token != null) {
                final WindowState betterTarget = token.getImeTargetBelowWindow(target);
                if (betterTarget != null) {
                    target = betterTarget;
                }
            }
        }

        if (curTarget != null && curTarget.isDisplayedLw() && curTarget.isClosing()
                && (target == null || target.isActivityTypeHome())) {
            return curTarget;
        }


        if (target == null) {
            if (updateImeTarget) {
                setInputMethodTarget(null, mService.mInputMethodTargetWaitingAnim);
            }

            return null;
        }

        if (updateImeTarget) {
            AppWindowToken token = curTarget == null ? null : curTarget.mAppToken;
            if (token != null) {

                WindowState highestTarget = null;
                if (token.isSelfAnimating()) {
                    highestTarget = token.getHighestAnimLayerWindow(curTarget);
                }

                if (highestTarget != null) {
                    final AppTransition appTransition = mService.mAppTransition;
                    if (appTransition.isTransitionSet()) {
                        setInputMethodTarget(highestTarget, true);
                        return highestTarget;
                    } else if (highestTarget.mWinAnimator.isAnimationSet() &&
                            highestTarget.mWinAnimator.mAnimLayer > target.mWinAnimator.mAnimLayer) {

                        setInputMethodTarget(highestTarget, true);
                        return highestTarget;
                    }
                }
            }

            setInputMethodTarget(target, false);
        }

        return target;
    }
```

这里面有两个对象需要区分以下，一个是curTarget，一个是Target。
- curTarget是来自WMS的mInputMethodTarget。也就意味着此时是WMS预定的输入法窗口层级。也就代表当前的输入法窗口。


- target 是来自DisplayContent对自己的孩子进行搜索到最顶部能够称为输入法窗口的WIndow。也就代表着下一个层级最高（可见的）输入法窗口。根据之前的文章，我们可以推断出来此时就是找添加到DisplayContent层级最高的NonMagnifiableWindowContainers的弹窗。也就是下一个要弹出的窗口

- 1.如果此时WMS中没有IME(输入法)的Window，此时就没有生成顶部的Window，就直接获取mInputMethodTargetWaitingAnim (因为此时需要做输入法窗口动画)作为新的输入法弹窗，并不需要调整。

- 2.通过getWindow找到最顶层能够成为输入法弹窗层级的DisplayContent的子窗口。也就是NonMagnifiableWindowContainers。

- 3.如果当前可以作为输入法弹窗是启动窗口类型，因为启动窗口本身很特殊，类似中转站的角色。则会自动找到下面那一层的窗口，判断是否能够作为弹窗。

- 4.如果当前的输入法弹窗不为空，同时当前的进程还存在，并且下一个要启动的窗口是Home。则直接返回当前进程的输入法弹窗。避免屏幕闪动。这里也就解释为什么，我们在自己应用启动了输入法弹窗，点击回退键盘回退Home之后，有些时候，输入法还留在Home上。

- 5.下一个目标输入法弹窗为空，则获取上一个。

- 6.输入法动画播放，会根据方法参数updateImeTarget这个标志位是否打开，来判断是否处理弹窗动画。因为是做需要做动画，所以需要找到当前输入法弹窗下，最高层级(可见)的窗口。

这个方法到处都调用了另一个比较核心的方法setInputMethodTarget，去设定当前的输入法弹窗目标。

#### setInputMethodTarget
```java
    private void setInputMethodTarget(WindowState target, boolean targetWaitingAnim) {
        if (target == mService.mInputMethodTarget
                && mService.mInputMethodTargetWaitingAnim == targetWaitingAnim) {
            return;
        }

        mService.mInputMethodTarget = target;
        mService.mInputMethodTargetWaitingAnim = targetWaitingAnim;
        assignWindowLayers(false /* setLayoutNeeded */);
    }
```
能看到除了赋值之外，还做一个和我上面提过十分相似的方法assignWindowLayers。


#### assignWindowLayers
```java
/** Updates the layer assignment of windows on this display. */
    void assignWindowLayers(boolean setLayoutNeeded) {

        assignChildLayers(getPendingTransaction());
        if (setLayoutNeeded) {
            setLayoutNeeded();
        }

        scheduleAnimation();
    }
```
能看到此时会调用assignChildLayers这个方法，并且执行窗口动画。

#### assignChildLayers
```java
    void assignChildLayers(Transaction t) {
        int layer = 0;

        // We use two passes as a way to promote children which
        // need Z-boosting to the end of the list.
        for (int j = 0; j < mChildren.size(); ++j) {
            final WindowContainer wc = mChildren.get(j);
            wc.assignChildLayers(t);
            if (!wc.needsZBoost()) {
                wc.assignLayer(t, layer++);
            }
        }
        for (int j = 0; j < mChildren.size(); ++j) {
            final WindowContainer wc = mChildren.get(j);
            if (wc.needsZBoost()) {
                wc.assignLayer(t, layer++);
            }
        }
    }

    void assignChildLayers() {
        assignChildLayers(getPendingTransaction());
        scheduleAnimation();
    }

```

这里做了什么事情呢？实际上很巧妙，首先对整个WindowContainer的子窗体做一次调整，接着打开了needsZBoost标志位的窗口再添加到上面。

这样就分离了需要做动画的层级，以及普通层级。保证了做动画的窗口一定再普通窗口之上。


## 添加窗口层级调整总结
从这里我们看到，Android 9.0对窗口层级的管理，比起过去的Android4.4的窗口层级调整有了十足的进步。

Android 4.4的窗口管理通过复杂的循环对窗口进行管理，这里就不分析了。到了Android 9.0 先把窗口层级大致划分出几个区域之后，再对每个区域进行循环管理，最后再调整动画的窗口。这么做的有点很显然易见，那就是抽象出了WIndowContainer提高了扩展性，并且减少了循环次数。

到这里窗口添加的大致上的逻辑，大体上已经弄透彻了，但是还有其他内容。

接下来让我们继续聊聊WMS面向应用暴露的三个接口，剩下的两个接口，updateViewLayout,removeView.以及Window如何计算Window的边缘。

## updateViewLayout
从上一篇文章看到ViewManager还有另外一个很重要的方法updateViewLayout。我们直奔WindowManagerGlobal看看真正的实现类做了什么：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[WindowManagerGlobal.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/WindowManagerGlobal.java)

```java
public void updateViewLayout(View view, ViewGroup.LayoutParams params) {
        if (view == null) {
            throw new IllegalArgumentException("view must not be null");
        }
        if (!(params instanceof WindowManager.LayoutParams)) {
            throw new IllegalArgumentException("Params must be WindowManager.LayoutParams");
        }

        final WindowManager.LayoutParams wparams = (WindowManager.LayoutParams)params;

        view.setLayoutParams(wparams);

        synchronized (mLock) {
            int index = findViewLocked(view, true);
            ViewRootImpl root = mRoots.get(index);
            mParams.remove(index);
            mParams.add(index, wparams);
            root.setLayoutParams(wparams, false);
        }
    }
```

能看到其核心十分简单，就是获取Windowmanager.LayoutParams需要更新的ViewRootImpl，最后调用setLayoutParams把新的LayoutParams设置到ViewRootImpl中，最后通过requestLayout做一次更新。

由于这是基于ViewRootImpl做一次一个逻辑屏幕上所有View的更新，因此使用的地方并不多。

### removeView
removeView是最后一个ViewManager的接口。这个接口使用的次数很多。我们接着启动窗口继续聊聊，既然我们在启动我们自己的真正的窗口之前会现有一个启动窗口显示，那么当Activity准备好下一步创建的时候，就必定会移除这个启动窗口，让我们找找看，是哪里移除的。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityStack.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java)
让我们把焦点放在：resumeTopActivityInnerLocked方法上.只有这个方法，才是真正开始跨进程通信，准备启动应用的Activity。

```java
 private boolean resumeTopActivityInnerLocked(ActivityRecord prev, ActivityOptions options) {
        if (!mService.mBooting && !mService.mBooted) {
            // Not ready yet!
            return false;
        }

        // Find the next top-most activity to resume in this stack that is not finishing and is
        // focusable. If it is not focusable, we will fall into the case below to resume the
        // top activity in the next focusable task.
        final ActivityRecord next = topRunningActivityLocked(true /* focusableOnly */);

        final boolean hasRunningActivity = next != null;

        // TODO: Maybe this entire condition can get removed?
        if (hasRunningActivity && !isAttached()) {
            return false;
        }

        mStackSupervisor.cancelInitializingActivities();

  ....
        return true;
    }
```

销毁启动窗口就是通过ActivityStackSupervisor.cancelInitializingActivities。

```java
    void cancelInitializingActivities() {
        for (int displayNdx = mActivityDisplays.size() - 1; displayNdx >= 0; --displayNdx) {
            final ActivityDisplay display = mActivityDisplays.valueAt(displayNdx);
            for (int stackNdx = display.getChildCount() - 1; stackNdx >= 0; --stackNdx) {
                final ActivityStack stack = display.getChildAt(stackNdx);
                stack.cancelInitializingActivities();
            }
        }
    }
```

能看到会获取ActivityDisplay中ActivityStack中所有的启动窗口，进行销毁。
```java
    void cancelInitializingActivities() {
        final ActivityRecord topActivity = topRunningActivityLocked();
        boolean aboveTop = true;
        // We don't want to clear starting window for activities that aren't behind fullscreen
        // activities as we need to display their starting window until they are done initializing.
        boolean behindFullscreenActivity = false;

        if (!shouldBeVisible(null)) {
            // The stack is not visible, so no activity in it should be displaying a starting
            // window. Mark all activities below top and behind fullscreen.
            aboveTop = false;
            behindFullscreenActivity = true;
        }

        for (int taskNdx = mTaskHistory.size() - 1; taskNdx >= 0; --taskNdx) {
            final ArrayList<ActivityRecord> activities = mTaskHistory.get(taskNdx).mActivities;
            for (int activityNdx = activities.size() - 1; activityNdx >= 0; --activityNdx) {
                final ActivityRecord r = activities.get(activityNdx);
                if (aboveTop) {
                    if (r == topActivity) {
                        aboveTop = false;
                    }
                    behindFullscreenActivity |= r.fullscreen;
                    continue;
                }

                r.removeOrphanedStartingWindow(behindFullscreenActivity);
                behindFullscreenActivity |= r.fullscreen;
            }
        }
    }
```

aboveTop默认是true。换句话说，从Task历史栈中获取所有Activity的启动窗口亲切销毁，如果当前的要销毁启动窗口的Activity和本次要启动的Activity是同一个对象，说明没有必要再去销毁。


文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityRecord.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityRecord.java)

```java
    void removeOrphanedStartingWindow(boolean behindFullscreenActivity) {
        if (mStartingWindowState == STARTING_WINDOW_SHOWN && behindFullscreenActivity) {
            if (DEBUG_VISIBILITY) Slog.w(TAG_VISIBILITY, "Found orphaned starting window " + this);
            mStartingWindowState = STARTING_WINDOW_REMOVED;
            mWindowContainerController.removeStartingWindow();
        }
    }
```

behindFullscreenActivity 这个标志位代表着是否真的执行销毁启动窗体，只要有一个Activity是全屏模式，就一定会去销毁。


###AppWindowContainerController.removeStartingWindow
```java
public void removeStartingWindow() {
        synchronized (mWindowMap) {
        final StartingSurface surface;
....
            // Use the same thread to remove the window as we used to add it, as otherwise we end up
            // with things in the view hierarchy being called from different threads.
            mService.mAnimationHandler.post(() -> {
                if (DEBUG_STARTING_WINDOW) Slog.v(TAG_WM, "Removing startingView=" + surface);
                try {
                    surface.remove();
                } catch (Exception e) {
                    Slog.w(TAG_WM, "Exception when removing starting window", e);
                }
            });
        }
    }
```
能看到此时的操作和addStartingWindow相似，也是把操作丢给WMS的动画处理Handler mAnimationHandler完成，对这个StartingSurface 进行移除。

而这个StartingSurface 在上一篇文章我们就能看到，实际上是一个SplashScreenSurface对象。
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[policy](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/policy/)/[SplashScreenSurface.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/policy/SplashScreenSurface.java)
```java
    public void remove() {
        final WindowManager wm = mView.getContext().getSystemService(WindowManager.class);
        wm.removeView(mView);
    }
```

能看到此时就是通过WindowManagerService对启动窗体进行销毁。

### WindowManagerGlobal removeView
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[view](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/)/[WindowManagerGlobal.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/view/WindowManagerGlobal.java)
```java
    private int findViewLocked(View view, boolean required) {
        final int index = mViews.indexOf(view);
        if (required && index < 0) {
            throw new IllegalArgumentException("View=" + view + " not attached to window manager");
        }
        return index;
    }

    public void removeView(View view, boolean immediate) {
        if (view == null) {
            throw new IllegalArgumentException("view must not be null");
        }

        synchronized (mLock) {
            int index = findViewLocked(view, true);
            View curView = mRoots.get(index).getView();
            removeViewLocked(index, immediate);
            if (curView == view) {
                return;
            }

            throw new IllegalStateException("Calling with view " + view
                    + " but the ViewAncestor is attached to " + curView);
        }
    }
```

在removeView的时候，我们需要注意view为空有异常，当我们要销毁的view，从mViews中找到和mRoot中找到的不一致，则会报错。这两个对象都是在addView，同步添加到mRoots和mView中。

因为此时是WindowManager的销毁，那么必定会去销毁当前对应的ViewRootImpl，换句话，我们要销毁ViewGroup中的View的时候当然不会使用这个方法销毁，这个方法销毁的是整个窗体对应的根部View。

#### removeViewLocked
```java
    private void removeViewLocked(int index, boolean immediate) {
        ViewRootImpl root = mRoots.get(index);
        View view = root.getView();

        if (view != null) {
            InputMethodManager imm = InputMethodManager.getInstance();
            if (imm != null) {
                imm.windowDismissed(mViews.get(index).getWindowToken());
            }
        }
        boolean deferred = root.die(immediate);
        if (view != null) {
            view.assignParent(null);
            if (deferred) {
                mDyingViews.add(view);
            }
        }
    }
```

能看到在清除的行为中，首先获取对应的ViewRootImpl，先通过windowDismissed销毁输入法。通过ViewRootImpl做一次相关的销毁行为，再通过assignParent清除其View指定的父View，如果不是立即销毁则把view对象添加到正在死亡的View集合中，等到做完所有的清除操作后，再清除这个集合中的view。


#### ViewRootImpl die
```java
    boolean die(boolean immediate) {
        // Make sure we do execute immediately if we are in the middle of a traversal or the damage
        // done by dispatchDetachedFromWindow will cause havoc on return.
        if (immediate && !mIsInTraversal) {
            doDie();
            return false;
        }

        if (!mIsDrawing) {
            destroyHardwareRenderer();
        } else {
            Log.e(mTag, "Attempting to destroy the window while drawing!\n" +
                    "  window=" + this + ", title=" + mWindowAttributes.getTitle());
        }
        mHandler.sendEmptyMessage(MSG_DIE);
        return true;
    }

    void doDie() {
        checkThread();
        if (LOCAL_LOGV) Log.v(mTag, "DIE in " + this + " of " + mSurface);
        synchronized (this) {
            if (mRemoved) {
                return;
            }
            mRemoved = true;
            if (mAdded) {
                dispatchDetachedFromWindow();
            }

            if (mAdded && !mFirst) {
                destroyHardwareRenderer();

                if (mView != null) {
                    int viewVisibility = mView.getVisibility();
                    boolean viewVisibilityChanged = mViewVisibility != viewVisibility;
                    if (mWindowAttributesChanged || viewVisibilityChanged) {
                        // If layout params have been changed, first give them
                        // to the window manager to make sure it has the correct
                        // animation info.
                        try {
                            if ((relayoutWindow(mWindowAttributes, viewVisibility, false)
                                    & WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME) != 0) {
                                mWindowSession.finishDrawing(mWindow);
                            }
                        } catch (RemoteException e) {
                        }
                    }

                    mSurface.release();
                }
            }

            mAdded = false;
        }
        WindowManagerGlobal.getInstance().doRemoveView(this);
    }
```
能看到，如果需要理解销毁则会直接执行doDie的方法，否则会把doDie委托到handler中完成。

doDie做了几件事情，一个是分发DetachedFromWindow事件给下面的View，接着销毁所有的硬件加速的渲染线程内该View的资源(这里不做更多讨论，之后会有专门的文章讨论)，释放绘制对象Surface，如果当前的View是可见的则通过Session沟通WMS进行结束绘制，最后调用WindowManagerGlobal的doRemoveView。

我们这里暂时只关心两个方法finishDrawing以及doRemoveView。让我们一个个的看一遍里面做了什么东西。

### WMS finishDrawingWindow
```java
void finishDrawingWindow(Session session, IWindow client) {
        final long origId = Binder.clearCallingIdentity();
        try {
            synchronized (mWindowMap) {
                WindowState win = windowForClientLocked(session, client, false);
                if (DEBUG_ADD_REMOVE) Slog.d(TAG_WM, "finishDrawingWindow: " + win + " mDrawState="
                        + (win != null ? win.mWinAnimator.drawStateToString() : "null"));
                if (win != null && win.mWinAnimator.finishDrawingLocked()) {
                    if ((win.mAttrs.flags & FLAG_SHOW_WALLPAPER) != 0) {
                        win.getDisplayContent().pendingLayoutChanges |=
                                WindowManagerPolicy.FINISH_LAYOUT_REDO_WALLPAPER;
                    }
                    win.setDisplayLayoutNeeded();
                    mWindowPlacerLocked.requestTraversal();
                }
            }
        } finally {
            Binder.restoreCallingIdentity(origId);
        }
    }
```
此时先找到IWindow对应的WindowState，设置对应WindowState中的DisplayContent标志位设置为true。并且重新测量窗体边缘。稍后会稍微深入WindowPlacerLocked.requestTraversal中做了什么事情。

###WindowManagerGlobal doRemoveView
```java
    void doRemoveView(ViewRootImpl root) {
        synchronized (mLock) {
            final int index = mRoots.indexOf(root);
            if (index >= 0) {
                mRoots.remove(index);
                mParams.remove(index);
                final View view = mViews.remove(index);
                mDyingViews.remove(view);
            }
        }
        if (ThreadedRenderer.sTrimForeground && ThreadedRenderer.isAvailable()) {
            doTrimForeground();
        }
    }

    private void doTrimForeground() {
        boolean hasVisibleWindows = false;
        synchronized (mLock) {
            for (int i = mRoots.size() - 1; i >= 0; --i) {
                final ViewRootImpl root = mRoots.get(i);
                if (root.mView != null && root.getHostVisibility() == View.VISIBLE
                        && root.mAttachInfo.mThreadedRenderer != null) {
                    hasVisibleWindows = true;
                } else {
                    root.destroyHardwareResources();
                }
            }
        }
        if (!hasVisibleWindows) {
            ThreadedRenderer.trimMemory(
                    ComponentCallbacks2.TRIM_MEMORY_COMPLETE);
        }
    }
```
能看到，经过doDie释放了必须的资源，如硬件渲染启动时候的渲染线程和Surface。并且重新计算窗体边缘。
最后再把WindowManagerGlobal 中的mRoots中的对象和mDyingView的对象全部移除。doTrimForeground则是清除那些看不见的Window中的view对应的渲染线程的资源。


removeView的核心逻辑就是这么多了。


### 小结
updateViewLayout本质上是设置WindowParams，重新测量绘制整个Window中的view。
removeView做了以下几个事情:
- 1.关闭键盘
- 2.ViewRootImpl调用die方法，清除硬件加速渲染线程中对应的view资源，重新执行Window的大小计算。
- 3.清空残留在WindowManagerGlobal中的对象。



