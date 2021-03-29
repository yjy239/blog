---
title: Android重学系列 BroadcastReceiver原理
top: false
cover: false
date: 2020-08-01 15:17:58
img:
tag:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---

# 前言
之前把Activity中View的绘制流程和IMS触点监听，来聊聊BroadcastReceiver中的原理。

# 正文
BroadcastReceiver是广播监听器，一般是用于监听来自App内部或者外部的消息。广播的监听器一般分为2种注册方式：
- 使用registerReceiver动态注册BroadcastReceiver
- 在AndroidManifest.xml中注册好BroadcastReceiver

简单的用法就不必多看，我们先来看看动态注册的核心原理。

## BroadcastReceiver 动态注册
方法入口是registerReceiver。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)
```java
    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        return registerReceiver(receiver, filter, null, null);
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            int flags) {
        return registerReceiver(receiver, filter, null, null, flags);
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, Handler scheduler) {
        return registerReceiverInternal(receiver, getUserId(),
                filter, broadcastPermission, scheduler, getOuterContext(), 0);
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, Handler scheduler, int flags) {
        return registerReceiverInternal(receiver, getUserId(),
                filter, broadcastPermission, scheduler, getOuterContext(), flags);
    }
    private Intent registerReceiverInternal(BroadcastReceiver receiver, int userId,
            IntentFilter filter, String broadcastPermission,
            Handler scheduler, Context context, int flags) {
        IIntentReceiver rd = null;
        if (receiver != null) {
            if (mPackageInfo != null && context != null) {
                if (scheduler == null) {
                    scheduler = mMainThread.getHandler();
                }
                rd = mPackageInfo.getReceiverDispatcher(
                    receiver, context, scheduler,
                    mMainThread.getInstrumentation(), true);
            } else {
....
            }
        }
        try {
            final Intent intent = ActivityManager.getService().registerReceiver(
                    mMainThread.getApplicationThread(), mBasePackageName, rd, filter,
                    broadcastPermission, userId, flags);
            if (intent != null) {
                intent.setExtrasClassLoader(getClassLoader());
                intent.prepareToEnterProcess();
            }
            return intent;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
大致上分为2个步骤：
- 调用LoadedApk的getReceiverDispatcher方法获取IIntentReceiver对象
- 调用AMS的服务端的registerReceiver方法，把IIntentReceiver作为参数设置进去启动。

### LoadedApk getReceiverDispatcher
```java
    public IIntentReceiver getReceiverDispatcher(BroadcastReceiver r,
            Context context, Handler handler,
            Instrumentation instrumentation, boolean registered) {
        synchronized (mReceivers) {
            LoadedApk.ReceiverDispatcher rd = null;
            ArrayMap<BroadcastReceiver, LoadedApk.ReceiverDispatcher> map = null;
            if (registered) {
                map = mReceivers.get(context);
                if (map != null) {
                    rd = map.get(r);
                }
            }
            if (rd == null) {
                rd = new ReceiverDispatcher(r, context, handler,
                        instrumentation, registered);
                if (registered) {
                    if (map == null) {
                        map = new ArrayMap<BroadcastReceiver, LoadedApk.ReceiverDispatcher>();
                        mReceivers.put(context, map);
                    }
                    map.put(r, rd);
                }
            } else {
                rd.validate(context, handler);
            }
            rd.mForgotten = false;
            return rd.getIIntentReceiver();
        }
    }
```
在这个过程中能看到在LoadApk中缓存了一个mReceivers的Map对象。mReceivers对象实际上缓存了ArrayMap对象。这个ArrayMap对象一个BroadcastReceiver对象对应一个ReceiverDispatcher。

这样就能通过当前注册的上下文Context，找到缓存的BroadcastReceiver，进一步找到缓存的ReceiverDispatcher。

当缓存的map中不存在对应的ReceiverDispatcher，那就需要生成一个新的ReceiverDispatcher保存到map中。

ReceiverDispatcher是做什么的呢？顾名思义，实际上是BroadcastReceiver的广播事件分发者。

拿到ReceiverDispatcher后，返回ReceiverDispatcher中的IIntentReceiver这个Binder远程端对象


#### ReceiverDispatcher 广播事件分发者介绍
```java
    static final class ReceiverDispatcher {

        final static class InnerReceiver extends IIntentReceiver.Stub {
            final WeakReference<LoadedApk.ReceiverDispatcher> mDispatcher;
            final LoadedApk.ReceiverDispatcher mStrongRef;

            InnerReceiver(LoadedApk.ReceiverDispatcher rd, boolean strong) {
                mDispatcher = new WeakReference<LoadedApk.ReceiverDispatcher>(rd);
                mStrongRef = strong ? rd : null;
            }

            @Override
            public void performReceive(Intent intent, int resultCode, String data,
                    Bundle extras, boolean ordered, boolean sticky, int sendingUser) {
                final LoadedApk.ReceiverDispatcher rd;
                if (intent == null) {
                    Log.wtf(TAG, "Null intent received");
                    rd = null;
                } else {
                    rd = mDispatcher.get();
                }

                if (rd != null) {
                    rd.performReceive(intent, resultCode, data, extras,
                            ordered, sticky, sendingUser);
                } else {

                    IActivityManager mgr = ActivityManagerNative.getDefault();
                    try {
                        if (extras != null) {
                            extras.setAllowFds(false);
                        }
                        mgr.finishReceiver(this, resultCode, data, extras, false, intent.getFlags());
                    } catch (RemoteException e) {
                        throw e.rethrowFromSystemServer();
                    }
                }
            }
        }

        final IIntentReceiver.Stub mIIntentReceiver;
        final BroadcastReceiver mReceiver;
        final Context mContext;
        final Handler mActivityThread;
        final Instrumentation mInstrumentation;
        final boolean mRegistered;
        final IntentReceiverLeaked mLocation;
        RuntimeException mUnregisterLocation;
        boolean mForgotten;

        final class Args extends BroadcastReceiver.PendingResult implements Runnable {
            private Intent mCurIntent;
            private final boolean mOrdered;
            private boolean mDispatched;

            public Args(Intent intent, int resultCode, String resultData, Bundle resultExtras,
                    boolean ordered, boolean sticky, int sendingUser) {
                super(resultCode, resultData, resultExtras,
                        mRegistered ? TYPE_REGISTERED : TYPE_UNREGISTERED, ordered,
                        sticky, mIIntentReceiver.asBinder(), sendingUser, intent.getFlags());
                mCurIntent = intent;
                mOrdered = ordered;
            }
            
            public void run() {
                final BroadcastReceiver receiver = mReceiver;
                final boolean ordered = mOrdered;
...
                final IActivityManager mgr = ActivityManagerNative.getDefault();
                final Intent intent = mCurIntent;

                mCurIntent = null;
                mDispatched = true;
                if (receiver == null || intent == null || mForgotten) {
                    if (mRegistered && ordered) {
                        sendFinished(mgr);
                    }
                    return;
                }

                try {
                    ClassLoader cl =  mReceiver.getClass().getClassLoader();
                    intent.setExtrasClassLoader(cl);
                    intent.prepareToEnterProcess();
                    setExtrasClassLoader(cl);
                    receiver.setPendingResult(this);
                    receiver.onReceive(mContext, intent);
                } catch (Exception e) {
                    if (mRegistered && ordered) {

                        sendFinished(mgr);
                    }

                }
                
                if (receiver.getPendingResult() != null) {
                    finish();
                }
                
            }
        }

        ReceiverDispatcher(BroadcastReceiver receiver, Context context,
                Handler activityThread, Instrumentation instrumentation,
                boolean registered) {
            if (activityThread == null) {
                throw new NullPointerException("Handler must not be null");
            }

            mIIntentReceiver = new InnerReceiver(this, !registered);
            mReceiver = receiver;
            mContext = context;
            mActivityThread = activityThread;
            mInstrumentation = instrumentation;
            mRegistered = registered;
            mLocation = new IntentReceiverLeaked(null);
            mLocation.fillInStackTrace();
        }
...

        IntentReceiverLeaked getLocation() {
            return mLocation;
        }

        BroadcastReceiver getIntentReceiver() {
            return mReceiver;
        }

        IIntentReceiver getIIntentReceiver() {
            return mIIntentReceiver;
        }

        void setUnregisterLocation(RuntimeException ex) {
            mUnregisterLocation = ex;
        }

        RuntimeException getUnregisterLocation() {
            return mUnregisterLocation;
        }

        public void performReceive(Intent intent, int resultCode, String data,
                Bundle extras, boolean ordered, boolean sticky, int sendingUser) {
            final Args args = new Args(intent, resultCode, data, extras, ordered,
                    sticky, sendingUser);

            if (intent == null || !mActivityThread.post(args)) {
                if (mRegistered && ordered) {
                    IActivityManager mgr = ActivityManagerNative.getDefault();
                    args.sendFinished(mgr);
                }
            }
        }

    }
```
在ReceiverDispatcher中，能看到两个内部类：
- InnerReceiver
- Args

实际上，如果跟着我写的系列一直阅读过来的读者，就能理解明白他们之间的联系。
- InnerReceiver 是Binder的客户端(远程端)直接接收Binder传递过来的消息。他持有了ReceiverDispatcher对象。一旦接收到消息后调用ReceiverDispatcher. performReceive。

- Args对象是一个BroadcastReceiver.PendingResult也是一个Runnable对象。每当ReceiverDispatcher执行了performReceive方法。Args会执行mActivityThread的post方法执行Args中的Runnable方法。在这个方法中执行BroadcastReceiver的实例化以及调用onReceive方法。

### AMS registerReceiver

至ActivityManager的registerReceiver于怎么通过Binder查找到AMS的registerReceiver方法并执行。可以阅读我写的Binder系列文章和Activity启动系列文章。本文就不多赘述了，我们直接到AMS中看看原理。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[ActivityManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)

```java
    public Intent registerReceiver(IApplicationThread caller, String callerPackage,
            IIntentReceiver receiver, IntentFilter filter, String permission, int userId,
            int flags) {
        enforceNotIsolatedCaller("registerReceiver");
        ArrayList<Intent> stickyIntents = null;
        ProcessRecord callerApp = null;
        final boolean visibleToInstantApps
                = (flags & Context.RECEIVER_VISIBLE_TO_INSTANT_APPS) != 0;
        int callingUid;
        int callingPid;
        boolean instantApp;
        synchronized(this) {
            if (caller != null) {
                callerApp = getRecordForAppLocked(caller);
                if (callerApp == null) {
...
                }
                if (callerApp.info.uid != SYSTEM_UID &&
                        !callerApp.pkgList.containsKey(callerPackage) &&
                        !"android".equals(callerPackage)) {
...
                }
                callingUid = callerApp.info.uid;
                callingPid = callerApp.pid;
            } else {
                callerPackage = null;
                callingUid = Binder.getCallingUid();
                callingPid = Binder.getCallingPid();
            }

            instantApp = isInstantApp(callerApp, callerPackage, callingUid);
            userId = mUserController.handleIncomingUser(callingPid, callingUid, userId, true,
                    ALLOW_FULL_ONLY, "registerReceiver", callerPackage);

            Iterator<String> actions = filter.actionsIterator();
            if (actions == null) {
                ArrayList<String> noAction = new ArrayList<String>(1);
                noAction.add(null);
                actions = noAction.iterator();
            }

            int[] userIds = { UserHandle.USER_ALL, UserHandle.getUserId(callingUid) };
            while (actions.hasNext()) {
                String action = actions.next();
                for (int id : userIds) {
                    ArrayMap<String, ArrayList<Intent>> stickies = mStickyBroadcasts.get(id);
                    if (stickies != null) {
                        ArrayList<Intent> intents = stickies.get(action);
                        if (intents != null) {
                            if (stickyIntents == null) {
                                stickyIntents = new ArrayList<Intent>();
                            }
                            stickyIntents.addAll(intents);
                        }
                    }
                }
            }
        }

        ArrayList<Intent> allSticky = null;
        if (stickyIntents != null) {
            final ContentResolver resolver = mContext.getContentResolver();
            for (int i = 0, N = stickyIntents.size(); i < N; i++) {
                Intent intent = stickyIntents.get(i);
                if (instantApp &&
                        (intent.getFlags() & Intent.FLAG_RECEIVER_VISIBLE_TO_INSTANT_APPS) == 0) {
                    continue;
                }

                if (filter.match(resolver, intent, true, TAG) >= 0) {
                    if (allSticky == null) {
                        allSticky = new ArrayList<Intent>();
                    }
                    allSticky.add(intent);
                }
            }
        }

        Intent sticky = allSticky != null ? allSticky.get(0) : null;

        if (receiver == null) {
            return sticky;
        }

        synchronized (this) {
            if (callerApp != null && (callerApp.thread == null
                    || callerApp.thread.asBinder() != caller.asBinder())) {
                return null;
            }
            ReceiverList rl = mRegisteredReceivers.get(receiver.asBinder());
            if (rl == null) {
                rl = new ReceiverList(this, callerApp, callingPid, callingUid,
                        userId, receiver);
                if (rl.app != null) {
                    final int totalReceiversForApp = rl.app.receivers.size();
                    if (totalReceiversForApp >= MAX_RECEIVERS_ALLOWED_PER_APP) {
...
                    }
                    rl.app.receivers.add(rl);
                } else {
                    try {
                        receiver.asBinder().linkToDeath(rl, 0);
                    } catch (RemoteException e) {
                        return sticky;
                    }
                    rl.linkedToDeath = true;
                }
                mRegisteredReceivers.put(receiver.asBinder(), rl);
            } else if (rl.uid != callingUid) {
                ...
            } else if (rl.pid != callingPid) {
               ...
            } else if (rl.userId != userId) {
                ...
            }
            BroadcastFilter bf = new BroadcastFilter(filter, rl, callerPackage,
                    permission, callingUid, userId, instantApp, visibleToInstantApps);
            if (rl.containsFilter(filter)) {
...
            } else {
                rl.add(bf);

                mReceiverResolver.addFilter(bf);
            }


            if (allSticky != null) {
                ArrayList receivers = new ArrayList();
                receivers.add(bf);

                final int stickyCount = allSticky.size();
                for (int i = 0; i < stickyCount; i++) {
                    Intent intent = allSticky.get(i);
                    BroadcastQueue queue = broadcastQueueForIntent(intent);
                    BroadcastRecord r = new BroadcastRecord(queue, intent, null,
                            null, -1, -1, false, null, null, OP_NONE, null, receivers,
                            null, 0, null, null, false, true, true, -1);
                    queue.enqueueParallelBroadcastLocked(r);
                    queue.scheduleBroadcastsLocked();
                }
            }

            return sticky;
        }
    }
```
在这个方法中分为三个大部分：
- 1.mStickyBroadcasts获取所有粘性广播的过滤IntentFilter并保存在stickyIntents中。如果传递下来的Intent的监听对象也是符合IntentFilter中的过滤条件则添加到allSticky。说明当前BroadcastReceiver符合粘性广播分发的条件。

- 2.如果broadcastReceiver 是第一次添加，那么会先把IIntentReceiver封装成ReceiverList对象。并且把ReceiverList添加到ProcessRecord中到receivers 中,这是一个ReceiverList的ArrayList对象。最后把IIntentReceiver的服务端作为key，ReceiverList为value保存在mRegisteredReceivers中。

- 3.此时会根据ReceiverList以及IntentFilter生成一个BroadcastFilter对象。这样BroadcastFilter就持有了一个广播接受者的客户端对象以及过滤接收条件。并把BroadcastFilter保存到mReceiverResolver中。之后需要查询就能从mReceiverResolver对象中直接查到需要分发的对象以及过滤条件。/

- 4.如果allSticky不为空，则通过broadcastQueueForIntent获取BroadcastQueue对象，通过BroadcastQueue进行消息的分发。这里的逻辑我们先放一放。

不过能从这里看到一个和EventBus设计几乎一致的地方。粘性事件的设计。粘性事件可以向没有注册BroadcastReceiver静态注册发送事件，一旦注册了，和普通的BroadcastReceiver不同的是不会出现事件丢失，而是进行分发。


到这里IIntentReceiver就保存到了AMS的mRegisteredReceivers这个map中缓存起来。


### BroadcastReceiver静态注册
BroadcastReceiver的静态注册，就是在AndroidManifest中静态注册好。在早期的Android版本中，Android可以通过这种静态注册监听一些开机等特殊监听。

那么我们可以猜测Android什么实例化好BroadcastReceiver，应该是安装的时候就保存好了。

#### BroadcastReceiver安装解析
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/)/[PackageParser.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/PackageParser.java)
```java
    private boolean parseBaseApplication(Package owner, Resources res,
            XmlResourceParser parser, int flags, String[] outError)
        throws XmlPullParserException, IOException {
...
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

            } 
....
}
```
PMS(PackageManagerService)安装系统的时候，会通过scanPakageLi方法调用PakcageParser对apk包进行解析。上面的代码段就是解析AndroidManifest.xml中找到receiver的xml的节点后，生成一个Activity对象保存到Package的receivers集合中。

此时在SystemServer进程中就持有了静态注册好的BroadcastReceiver对象了。

详细的，我们放到后面的PMS专题来聊聊。

### BroadcastReceiver的发送原理

BroadcastReceiver的发送一般是通过sendBroadcast发送一个广播后，在BroadcastReceiver的onReceiver中接收到。让我们来考察sendBroadcast方法。

```java
    @Override
    public void sendBroadcast(Intent intent) {
        warnIfCallingFromSystemProcess();
        String resolvedType = intent.resolveTypeIfNeeded(getContentResolver());
        try {
            intent.prepareToLeaveProcess(this);
            ActivityManager.getService().broadcastIntent(
                    mMainThread.getApplicationThread(), intent, resolvedType, null,
                    Activity.RESULT_OK, null, null, null, AppOpsManager.OP_NONE, null, false, false,
                    getUserId());
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```

核心的方法就是AMS的broadcastIntent方法。

#### AMS broadcastIntent

```java
    public final int broadcastIntent(IApplicationThread caller,
            Intent intent, String resolvedType, IIntentReceiver resultTo,
            int resultCode, String resultData, Bundle resultExtras,
            String[] requiredPermissions, int appOp, Bundle bOptions,
            boolean serialized, boolean sticky, int userId) {
        enforceNotIsolatedCaller("broadcastIntent");
        synchronized(this) {
            intent = verifyBroadcastLocked(intent);

            final ProcessRecord callerApp = getRecordForAppLocked(caller);
            final int callingPid = Binder.getCallingPid();
            final int callingUid = Binder.getCallingUid();
            final long origId = Binder.clearCallingIdentity();
            int res = broadcastIntentLocked(callerApp,
                    callerApp != null ? callerApp.info.packageName : null,
                    intent, resolvedType, resultTo, resultCode, resultData, resultExtras,
                    requiredPermissions, appOp, bOptions, serialized, sticky,
                    callingPid, callingUid, userId);
            Binder.restoreCallingIdentity(origId);
            return res;
        }
    }
```
核心是通过当前的IApplicationThread获取到ProcessRecord进程信息后，调用
broadcastIntentLocked方法。

#### AMS broadcastIntentLocked

我们把这个方法分为四个部分来考察。

```java
    final int broadcastIntentLocked(ProcessRecord callerApp,
            String callerPackage, Intent intent, String resolvedType,
            IIntentReceiver resultTo, int resultCode, String resultData,
            Bundle resultExtras, String[] requiredPermissions, int appOp, Bundle bOptions,
            boolean ordered, boolean sticky, int callingPid, int callingUid, int userId) {
        intent = new Intent(intent);

        final boolean callerInstantApp = isInstantApp(callerApp, callerPackage, callingUid);

        if (callerInstantApp) {
            intent.setFlags(intent.getFlags() & ~Intent.FLAG_RECEIVER_VISIBLE_TO_INSTANT_APPS);
        }

        intent.addFlags(Intent.FLAG_EXCLUDE_STOPPED_PACKAGES);


        if (!mProcessesReady && (intent.getFlags()&Intent.FLAG_RECEIVER_BOOT_UPGRADE) == 0) {
            intent.addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY);
        }


        userId = mUserController.handleIncomingUser(callingPid, callingUid, userId, true,
                ALLOW_NON_FULL, "broadcast", callerPackage);


...

        final String action = intent.getAction();
...

        if (sticky) {
...
            ArrayMap<String, ArrayList<Intent>> stickies = mStickyBroadcasts.get(userId);
            if (stickies == null) {
                stickies = new ArrayMap<>();
                mStickyBroadcasts.put(userId, stickies);
            }
            ArrayList<Intent> list = stickies.get(intent.getAction());
            if (list == null) {
                list = new ArrayList<>();
                stickies.put(intent.getAction(), list);
            }
            final int stickiesCount = list.size();
            int i;
            for (i = 0; i < stickiesCount; i++) {
                if (intent.filterEquals(list.get(i))) {
                    // This sticky already exists, replace it.
                    list.set(i, new Intent(intent));
                    break;
                }
            }
            if (i >= stickiesCount) {
                list.add(new Intent(intent));
            }
        }

...
        return ActivityManager.BROADCAST_SUCCESS;
    }
```
在第一段代码中，做了如下的事情：
- 判断当前的App是否是Instant App。如果是，则关闭FLAG_RECEIVER_VISIBLE_TO_INSTANT_APPS标志位。说明Instant App是不能接收Broadcast广播的。关于什么是Instant App，可以阅读[https://www.jianshu.com/p/b66535262dfb](https://www.jianshu.com/p/b66535262dfb)这篇文章。可以当成一个缩减版本的应用。


- 默认给Intent添加一个FLAG_EXCLUDE_STOPPED_PACKAGES，不允许发送消息给还没有启动的App。

- 如果AMS还没有启动完毕，且FLAG_RECEIVER_BOOT_UPGRADE没有打开。说明此时发送的消息是普通广播不是什么开机广播。此时可能PMS也没有准备好，因此添加FLAG_RECEIVER_REGISTERED_ONLY，只发送给那些动态注册的广播接收者。


- 获取保存在mStickyBroadcasts中的需要分发的广播Intent。如果当前发送的是粘性广播。则会先保存到mStickyBroadcasts这个ArrayMap中，保证发送的广播找不到符合的广播接收者也不会丢失。


```java
        int[] users;
        if (userId == UserHandle.USER_ALL) {
            users = mUserController.getStartedUserArray();
        } else {
            users = new int[] {userId};
        }

        List receivers = null;
        List<BroadcastFilter> registeredReceivers = null;
        if ((intent.getFlags()&Intent.FLAG_RECEIVER_REGISTERED_ONLY)
                 == 0) {
            receivers = collectReceiverComponents(intent, resolvedType, callingUid, users);
        }
        if (intent.getComponent() == null) {
            if (userId == UserHandle.USER_ALL && callingUid == SHELL_UID) {
                for (int i = 0; i < users.length; i++) {
                    if (mUserController.hasUserRestriction(
                            UserManager.DISALLOW_DEBUGGING_FEATURES, users[i])) {
                        continue;
                    }
                    List<BroadcastFilter> registeredReceiversForUser =
                            mReceiverResolver.queryIntent(intent,
                                    resolvedType, false /*defaultOnly*/, users[i]);
                    if (registeredReceivers == null) {
                        registeredReceivers = registeredReceiversForUser;
                    } else if (registeredReceiversForUser != null) {
                        registeredReceivers.addAll(registeredReceiversForUser);
                    }
                }
            } else {
                registeredReceivers = mReceiverResolver.queryIntent(intent,
                        resolvedType, false /*defaultOnly*/, userId);
            }
        }

....
```
- 1.如果关闭FLAG_RECEIVER_REGISTERED_ONLY标志位，则调用collectReceiverComponents获取静态广播的集合。这个标志位代表只发送给动态注册的广播。

- 2.如果Intent没有设置getComponent目标，则从mReceiverResolver中获取当前应用对应userId的所有广播保存到registeredReceivers这个BroadcastFilter集合中。

核心来看看collectReceiverComponents是怎么获取静态广播接收器以及mReceiverResolver是如何获取动态广播接收器的。

##### collectReceiverComponents 查找静态广播接受者
```java
    private List<ResolveInfo> collectReceiverComponents(Intent intent, String resolvedType,
            int callingUid, int[] users) {
        int pmFlags = STOCK_PM_FLAGS | MATCH_DEBUG_TRIAGED_MISSING;

        List<ResolveInfo> receivers = null;
        try {
            HashSet<ComponentName> singleUserReceivers = null;
            boolean scannedFirstReceivers = false;
            for (int user : users) {

                if (callingUid == SHELL_UID
                        && mUserController.hasUserRestriction(
                                UserManager.DISALLOW_DEBUGGING_FEATURES, user)
                        && !isPermittedShellBroadcast(intent)) {
                    continue;
                }
                List<ResolveInfo> newReceivers = AppGlobals.getPackageManager()
                        .queryIntentReceivers(intent, resolvedType, pmFlags, user).getList();
                if (user != UserHandle.USER_SYSTEM && newReceivers != null) {

                    for (int i=0; i<newReceivers.size(); i++) {
                        ResolveInfo ri = newReceivers.get(i);
                        if ((ri.activityInfo.flags&ActivityInfo.FLAG_SYSTEM_USER_ONLY) != 0) {
                            newReceivers.remove(i);
                            i--;
                        }
                    }
                }
                if (newReceivers != null && newReceivers.size() == 0) {
                    newReceivers = null;
                }
                if (receivers == null) {
                    receivers = newReceivers;
                } else if (newReceivers != null) {

                    if (!scannedFirstReceivers) {
                        scannedFirstReceivers = true;
                        for (int i=0; i<receivers.size(); i++) {
                            ResolveInfo ri = receivers.get(i);
                            if ((ri.activityInfo.flags&ActivityInfo.FLAG_SINGLE_USER) != 0) {
                                ComponentName cn = new ComponentName(
                                        ri.activityInfo.packageName, ri.activityInfo.name);
                                if (singleUserReceivers == null) {
                                    singleUserReceivers = new HashSet<ComponentName>();
                                }
                                singleUserReceivers.add(cn);
                            }
                        }
                    }

                    for (int i=0; i<newReceivers.size(); i++) {
                        ResolveInfo ri = newReceivers.get(i);
                        if ((ri.activityInfo.flags&ActivityInfo.FLAG_SINGLE_USER) != 0) {
                            ComponentName cn = new ComponentName(
                                    ri.activityInfo.packageName, ri.activityInfo.name);
                            if (singleUserReceivers == null) {
                                singleUserReceivers = new HashSet<ComponentName>();
                            }
                            if (!singleUserReceivers.contains(cn)) {
                                singleUserReceivers.add(cn);
                                receivers.add(ri);
                            }
                        } else {
                            receivers.add(ri);
                        }
                    }
                }
            }
        } catch (RemoteException ex) {
        }
        return receivers;
    }
```
- 1.先通过PMS的queryIntentReceivers方法从PMS中获取所有符合当前Intent设置的Action等条件和userId的ResolveInfo对象保存到newReceivers集合中。

- 2.如果userId不是UserHandle.USER_SYSTEM(不是系统)，则遍历newReceivers集合，移除掉所有打开了FLAG_SYSTEM_USER_ONLY的广播接受者。因为不是系统应用也发送不到系统的广播接受者。

- 3.注意这里面获取的userId的数组。而这个数组只有两种情况，一种是UserHandle.USER_ALL也就是所有启动的应用(现在Android已经变成了一个user对应一个应用了)，一种就是当前userId对应的应用。
  - 如果当前遍历所有用户中的id中所有的广播接受者有设置了FLAG_SINGLE_USER，也就是在AndroidManifest中设置了singleUser标志位，说明全局只有一个广播接受者。在这个过程只会对第一个userId数组中做一次校验(这里是指系统的userID)，就会把ComponentName添加到singleUserReceivers中。
  - 遍历每一个userId中所有的广播接受者，并把ComponentName添加到singleUserReceivers中，以及ResolveInfo保存到receivers中。

最后把receivers返回。

这段代码中的核心就是PMS的queryIntentReceivers，是怎么查询的。


###### PMS queryIntentReceivers
```java
   private @NonNull List<ResolveInfo> queryIntentReceiversInternal(Intent intent,
            String resolvedType, int flags, int userId, boolean allowDynamicSplits) {
        if (!sUserManager.exists(userId)) return Collections.emptyList();
        final int callingUid = Binder.getCallingUid();
        mPermissionManager.enforceCrossUserPermission(callingUid, userId,
                false /*requireFullPermission*/, false /*checkShell*/,
                "query intent receivers");
        final String instantAppPkgName = getInstantAppPackageName(callingUid);
        flags = updateFlagsForResolve(flags, userId, intent, callingUid,
                false /*includeInstantApps*/);
        ComponentName comp = intent.getComponent();
        if (comp == null) {
            if (intent.getSelector() != null) {
                intent = intent.getSelector();
                comp = intent.getComponent();
            }
        }
        if (comp != null) {
            final List<ResolveInfo> list = new ArrayList<ResolveInfo>(1);
            final ActivityInfo ai = getReceiverInfo(comp, flags, userId);
            if (ai != null) {

                final boolean matchInstantApp =
                        (flags & PackageManager.MATCH_INSTANT) != 0;
                final boolean matchVisibleToInstantAppOnly =
                        (flags & PackageManager.MATCH_VISIBLE_TO_INSTANT_APP_ONLY) != 0;
                final boolean matchExplicitlyVisibleOnly =
                        (flags & PackageManager.MATCH_EXPLICITLY_VISIBLE_ONLY) != 0;
                final boolean isCallerInstantApp =
                        instantAppPkgName != null;
                final boolean isTargetSameInstantApp =
                        comp.getPackageName().equals(instantAppPkgName);
                final boolean isTargetInstantApp =
                        (ai.applicationInfo.privateFlags
                                & ApplicationInfo.PRIVATE_FLAG_INSTANT) != 0;
                final boolean isTargetVisibleToInstantApp =
                        (ai.flags & ActivityInfo.FLAG_VISIBLE_TO_INSTANT_APP) != 0;
                final boolean isTargetExplicitlyVisibleToInstantApp =
                        isTargetVisibleToInstantApp
                        && (ai.flags & ActivityInfo.FLAG_IMPLICITLY_VISIBLE_TO_INSTANT_APP) == 0;
                final boolean isTargetHiddenFromInstantApp =
                        !isTargetVisibleToInstantApp
                        || (matchExplicitlyVisibleOnly && !isTargetExplicitlyVisibleToInstantApp);
                final boolean blockResolution =
                        !isTargetSameInstantApp
                        && ((!matchInstantApp && !isCallerInstantApp && isTargetInstantApp)
                                || (matchVisibleToInstantAppOnly && isCallerInstantApp
                                        && isTargetHiddenFromInstantApp));
                if (!blockResolution) {
                    ResolveInfo ri = new ResolveInfo();
                    ri.activityInfo = ai;
                    list.add(ri);
                }
            }
            return applyPostResolutionFilter(
                    list, instantAppPkgName, allowDynamicSplits, callingUid, false, userId,
                    intent);
        }

        // reader
        synchronized (mPackages) {
            String pkgName = intent.getPackage();
            if (pkgName == null) {
                final List<ResolveInfo> result =
                        mReceivers.queryIntent(intent, resolvedType, flags, userId);
                return applyPostResolutionFilter(
                        result, instantAppPkgName, allowDynamicSplits, callingUid, false, userId,
                        intent);
            }
            final PackageParser.Package pkg = mPackages.get(pkgName);
            if (pkg != null) {
                final List<ResolveInfo> result = mReceivers.queryIntentForPackage(
                        intent, resolvedType, flags, pkg.receivers, userId);
                return applyPostResolutionFilter(
                        result, instantAppPkgName, allowDynamicSplits, callingUid, false, userId,
                        intent);
            }
            return Collections.emptyList();
        }
    }
```
- 1.如果ComponentName中不为空，有目标的包名字或者目标的类名，则getReceiverInfo获取ActivityInfo对象。声明一个ResolveInfo对象，添加到list中。

- 2.尝试的从Intent中获取PackageName，如果PackageName为空，则mReceivers从mReceivers的queryIntent方法中获取ResolveInfo集合，并返回

- 3.如果packageName不为空，则mReceivers的queryIntentForPackage根据当前的包名获取ResolveInfo。

在PMS中，有两种搜寻方法一种是从mReceivers这个ActivityIntentResolver集合中获取，一种是知道了目标对象调用getReceiverInfo方法获取。

###### getReceiverInfo

```java
    public ActivityInfo getReceiverInfo(ComponentName component, int flags, int userId) {
        if (!sUserManager.exists(userId)) return null;
        final int callingUid = Binder.getCallingUid();
        flags = updateFlagsForComponent(flags, userId, component);
        mPermissionManager.enforceCrossUserPermission(callingUid, userId,
                false /* requireFullPermission */, false /* checkShell */, "get receiver info");
        synchronized (mPackages) {
            PackageParser.Activity a = mReceivers.mActivities.get(component);
            if (a != null && mSettings.isEnabledAndMatchLPr(a.info, flags, userId)) {
                PackageSetting ps = mSettings.mPackages.get(component.getPackageName());
                if (ps == null) return null;
                if (filterAppAccessLPr(ps, callingUid, component, TYPE_RECEIVER, userId)) {
                    return null;
                }
                return PackageParser.generateActivityInfo(
                        a, flags, ps.readUserState(userId), userId);
            }
        }
        return null;
    }
```
能看到在这个过程中是也是从mReceivers中的mActivities对象根据component直接获得对应的PackageParser.Activity，进而获取ActivityInfo对象。

mReceivers中是什么时候添加这些对象的呢？实际上就是静态注册时候执行完扫描AndroidManifest之后返回了Package对象后，添加到mReceivers中。

###### ActivityIntentResolver queryIntent 查询符合过滤条件的BroadcastReceiver

```java
    final class ActivityIntentResolver
            extends IntentResolver<PackageParser.ActivityIntentInfo, ResolveInfo> {
        public List<ResolveInfo> queryIntent(Intent intent, String resolvedType,
                boolean defaultOnly, int userId) {
            if (!sUserManager.exists(userId)) return null;
            mFlags = (defaultOnly ? PackageManager.MATCH_DEFAULT_ONLY : 0);
            return super.queryIntent(intent, resolvedType, defaultOnly, userId);
        }

        public List<ResolveInfo> queryIntent(Intent intent, String resolvedType, int flags,
                int userId) {
            if (!sUserManager.exists(userId)) return null;
            mFlags = flags;
            return super.queryIntent(intent, resolvedType,
                    (flags & PackageManager.MATCH_DEFAULT_ONLY) != 0,
                    userId);
        }
```
能看到这个过程核心还是调用了父类IntentResolver的queryIntent方法。
```java
    public List<R> queryIntent(Intent intent, String resolvedType, boolean defaultOnly,
            int userId) {
        String scheme = intent.getScheme();

        ArrayList<R> finalList = new ArrayList<R>();

        final boolean debug = localLOGV ||
                ((intent.getFlags() & Intent.FLAG_DEBUG_LOG_RESOLUTION) != 0);


        F[] firstTypeCut = null;
        F[] secondTypeCut = null;
        F[] thirdTypeCut = null;
        F[] schemeCut = null;

        if (resolvedType != null) {
            int slashpos = resolvedType.indexOf('/');
            if (slashpos > 0) {
                final String baseType = resolvedType.substring(0, slashpos);
                if (!baseType.equals("*")) {
                    if (resolvedType.length() != slashpos+2
                            || resolvedType.charAt(slashpos+1) != '*') {

                        firstTypeCut = mTypeToFilter.get(resolvedType);

                        secondTypeCut = mWildTypeToFilter.get(baseType);
                    } else {

                        firstTypeCut = mBaseTypeToFilter.get(baseType);
                        secondTypeCut = mWildTypeToFilter.get(baseType);

                    }

                    thirdTypeCut = mWildTypeToFilter.get("*");
                    if (debug) Slog.v(TAG, "Third type cut: " + Arrays.toString(thirdTypeCut));
                } else if (intent.getAction() != null) {

                    firstTypeCut = mTypedActionToFilter.get(intent.getAction());

                }
            }
        }

        if (scheme != null) {
            schemeCut = mSchemeToFilter.get(scheme);
        }

        if (resolvedType == null && scheme == null && intent.getAction() != null) {
            firstTypeCut = mActionToFilter.get(intent.getAction());
        
        }

        FastImmutableArraySet<String> categories = getFastIntentCategories(intent);
        if (firstTypeCut != null) {
            buildResolveList(intent, categories, debug, defaultOnly, resolvedType,
                    scheme, firstTypeCut, finalList, userId);
        }
        if (secondTypeCut != null) {
            buildResolveList(intent, categories, debug, defaultOnly, resolvedType,
                    scheme, secondTypeCut, finalList, userId);
        }
        if (thirdTypeCut != null) {
            buildResolveList(intent, categories, debug, defaultOnly, resolvedType,
                    scheme, thirdTypeCut, finalList, userId);
        }
        if (schemeCut != null) {
            buildResolveList(intent, categories, debug, defaultOnly, resolvedType,
                    scheme, schemeCut, finalList, userId);
        }
        filterResults(finalList);
        sortResults(finalList);

        return finalList;
    }
```
- 1.第一个resolvedType不为null的逻辑中，实际上判断的是Intent中MIME数据符合的IntentFilter
- 2.判断scheme也就是协议头符合当前Intent的IntentFilter
- 3.如果没有MIME和scheme，则尝试查找那些匹配Intent中Action的IntentFilter
- 4.获取所有的categories，最后根据上面三个判断以及categories通过buildResolveList最终构造成返回结果IntentFilter集合。

```java
    private void buildResolveList(Intent intent, FastImmutableArraySet<String> categories,
            boolean debug, boolean defaultOnly, String resolvedType, String scheme,
            F[] src, List<R> dest, int userId) {
        final String action = intent.getAction();
        final Uri data = intent.getData();
        final String packageName = intent.getPackage();

        final boolean excludingStopped = intent.isExcludingStopped();
...

        final int N = src != null ? src.length : 0;
        boolean hasNonDefaults = false;
        int i;
        F filter;
        for (i=0; i<N && (filter=src[i]) != null; i++) {
            int match;
...

            match = filter.match(action, resolvedType, scheme, data, categories, TAG);
            if (match >= 0) {
                if (!defaultOnly || filter.hasCategory(Intent.CATEGORY_DEFAULT)) {
                    final R oneResult = newResult(filter, match, userId);
                    if (oneResult != null) {
                        dest.add(oneResult);
                    }
                } else {
                    hasNonDefaults = true;
                }
            } else {

            }
        }

    }
```
核心代码还是遍历上一个代码段筛选出来的IntentFilter，调用IntentFilter的match方法判断是否匹配。

```java
    public final int match(ContentResolver resolver, Intent intent,
            boolean resolve, String logTag) {
        String type = resolve ? intent.resolveType(resolver) : intent.getType();
        return match(intent.getAction(), type, intent.getScheme(),
                     intent.getData(), intent.getCategories(), logTag);
    }

    public final int match(String action, String type, String scheme,
            Uri data, Set<String> categories, String logTag) {
        if (action != null && !matchAction(action)) {
            return NO_MATCH_ACTION;
        }

        int dataMatch = matchData(type, scheme, data);
        if (dataMatch < 0) {
            return dataMatch;
        }

        String categoryMismatch = matchCategories(categories);
        if (categoryMismatch != null) {
            return NO_MATCH_CATEGORY;
        }


        return dataMatch;
    }
```
依次匹配了action，type，scheme，data，categories。我们从整个代码逻辑链上思考，就能明白Androidmanifest中IntentFilter的匹配规则：

- 如果想要IntentFilter，意图过滤生效。满足三个条件之一，一个是必须存在Intent的action，另一个是getContentReslover的字符串不为空，最后一个是scheme不为空。这决定了解析是否能拆分出四个子部分进行匹配

- categories并非是必须的，就算没有也可以通过action，data，scheme，type进行匹配。

- 当存在action，就会从中获取所有符合条件的所有ActivityIntentInfo对象，在此基础上，对依次对data，categories进行匹配。如果data匹配成功了就直接返回，如果data匹配失败了就会尝试匹配categories。

如果存在多个data只需要匹配其中一个data返回即可。

### 2种发送广播类型

##### 发送并行广播
```java
        final boolean replacePending =
                (intent.getFlags()&Intent.FLAG_RECEIVER_REPLACE_PENDING) != 0;


        int NR = registeredReceivers != null ? registeredReceivers.size() : 0;
        if (!ordered && NR > 0) {

            if (isCallerSystem) {
                checkBroadcastFromSystem(intent, callerApp, callerPackage, callingUid,
                        isProtectedBroadcast, registeredReceivers);
            }
            final BroadcastQueue queue = broadcastQueueForIntent(intent);
            BroadcastRecord r = new BroadcastRecord(queue, intent, callerApp,
                    callerPackage, callingPid, callingUid, callerInstantApp, resolvedType,
                    requiredPermissions, appOp, brOptions, registeredReceivers, resultTo,
                    resultCode, resultData, resultExtras, ordered, sticky, false, userId);

            final boolean replaced = replacePending
                    && (queue.replaceParallelBroadcastLocked(r) != null);

            if (!replaced) {
                queue.enqueueParallelBroadcastLocked(r);
                queue.scheduleBroadcastsLocked();
            }
            registeredReceivers = null;
            NR = 0;
        }

```
- 1.如果当前动态注册的广播接受者不为0，且不是有序广播。
- 2.通过broadcastQueueForIntent获取BroadcastQueue对象。
- 3.根据动态注册的广播接受者，生成BroadcastRecord对象。
- 4.如果FLAG_RECEIVER_REPLACE_PENDING关闭并且BroadcastQueue校验当前的BroadcastRecord不需要替换，则调用enqueueParallelBroadcastLocked进入并行队列，接着调用scheduleBroadcastsLocked执行发送。

核心方法有如下几个：
 - broadcastQueueForIntent
- enqueueParallelBroadcastLocked
- scheduleBroadcastsLocked

让我们来一一考察。

##### broadcastQueueForIntent
```java
    BroadcastQueue broadcastQueueForIntent(Intent intent) {
        final boolean isFg = (intent.getFlags() & Intent.FLAG_RECEIVER_FOREGROUND) != 0;
        return (isFg) ? mFgBroadcastQueue : mBgBroadcastQueue;
    }
```

根据Intent是否开启FLAG_RECEIVER_FOREGROUND，则返回前台广播队列，否则返回后台队列。这两个方法的初始化时机在AMS的构造函数中：
```java
    static final int BROADCAST_FG_TIMEOUT = 10*1000;
    static final int BROADCAST_BG_TIMEOUT = 60*1000;

        mFgBroadcastQueue = new BroadcastQueue(this, mHandler,
                "foreground", BROADCAST_FG_TIMEOUT, false);
        mBgBroadcastQueue = new BroadcastQueue(this, mHandler,
                "background", BROADCAST_BG_TIMEOUT, true);
        mBroadcastQueues[0] = mFgBroadcastQueue;
        mBroadcastQueues[1] = mBgBroadcastQueue;
```
都是BroadcastQueue对象，只是两者之间的超时时间一个是10秒，一个是60秒,最后一个蚕食后台为true。

###### BroadcastQueue
文件：[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[am](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/)/[BroadcastQueue.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/am/BroadcastQueue.java)
```java
    BroadcastQueue(ActivityManagerService service, Handler handler,
            String name, long timeoutPeriod, boolean allowDelayBehindServices) {
        mService = service;
        mHandler = new BroadcastHandler(handler.getLooper());
        mQueueName = name;
        mTimeoutPeriod = timeoutPeriod;
        mDelayBehindServices = allowDelayBehindServices;
    }
```
BroadcastQueue中共用了AMS的Looper构造了一个Handler对象。
mDelayBehindServices而这个标志位代表了是否是后台执行发送广播。

###### BroadcastQueue enqueueParallelBroadcastLocked
```java
    public void enqueueParallelBroadcastLocked(BroadcastRecord r) {
        mParallelBroadcasts.add(r);
        enqueueBroadcastHelper(r);
    }

    private void enqueueBroadcastHelper(BroadcastRecord r) {
        r.enqueueClockTime = System.currentTimeMillis();

        if (Trace.isTagEnabled(Trace.TRACE_TAG_ACTIVITY_MANAGER)) {
            Trace.asyncTraceBegin(Trace.TRACE_TAG_ACTIVITY_MANAGER,
                createBroadcastTraceTitle(r, BroadcastRecord.DELIVERY_PENDING),
                System.identityHashCode(r));
        }
    }
```
很简单，其实就是把BroadcastRecord添加到mParallelBroadcasts队列中。

scheduleBroadcastsLocked这个方法我们最后再来考察

#### 发送有序广播

```java
        int ir = 0;
        if (receivers != null) {

            String skipPackages[] = null;
            if (Intent.ACTION_PACKAGE_ADDED.equals(intent.getAction())
                    || Intent.ACTION_PACKAGE_RESTARTED.equals(intent.getAction())
                    || Intent.ACTION_PACKAGE_DATA_CLEARED.equals(intent.getAction())) {
                Uri data = intent.getData();
                if (data != null) {
                    String pkgName = data.getSchemeSpecificPart();
                    if (pkgName != null) {
                        skipPackages = new String[] { pkgName };
                    }
                }
            } else if (Intent.ACTION_EXTERNAL_APPLICATIONS_AVAILABLE.equals(intent.getAction())) {
                skipPackages = intent.getStringArrayExtra(Intent.EXTRA_CHANGED_PACKAGE_LIST);
            }
            if (skipPackages != null && (skipPackages.length > 0)) {
                for (String skipPackage : skipPackages) {
                    if (skipPackage != null) {
                        int NT = receivers.size();
                        for (int it=0; it<NT; it++) {
                            ResolveInfo curt = (ResolveInfo)receivers.get(it);
                            if (curt.activityInfo.packageName.equals(skipPackage)) {
                                receivers.remove(it);
                                it--;
                                NT--;
                            }
                        }
                    }
                }
            }

            int NT = receivers != null ? receivers.size() : 0;
            int it = 0;
            ResolveInfo curt = null;
            BroadcastFilter curr = null;
            while (it < NT && ir < NR) {
                if (curt == null) {
                    curt = (ResolveInfo)receivers.get(it);
                }
                if (curr == null) {
                    curr = registeredReceivers.get(ir);
                }
                if (curr.getPriority() >= curt.priority) {
                    receivers.add(it, curr);
                    ir++;
                    curr = null;
                    it++;
                    NT++;
                } else {
                    // Skip to the next ResolveInfo in the final list.
                    it++;
                    curt = null;
                }
            }
        }
        while (ir < NR) {
            if (receivers == null) {
                receivers = new ArrayList();
            }
            receivers.add(registeredReceivers.get(ir));
            ir++;
        }

        if (isCallerSystem) {
            checkBroadcastFromSystem(intent, callerApp, callerPackage, callingUid,
                    isProtectedBroadcast, receivers);
        }

        if ((receivers != null && receivers.size() > 0)
                || resultTo != null) {
            BroadcastQueue queue = broadcastQueueForIntent(intent);
            BroadcastRecord r = new BroadcastRecord(queue, intent, callerApp,
                    callerPackage, callingPid, callingUid, callerInstantApp, resolvedType,
                    requiredPermissions, appOp, brOptions, receivers, resultTo, resultCode,
                    resultData, resultExtras, ordered, sticky, false, userId);


            final BroadcastRecord oldRecord =
                    replacePending ? queue.replaceOrderedBroadcastLocked(r) : null;
            if (oldRecord != null) {
                if (oldRecord.resultTo != null) {
                    final BroadcastQueue oldQueue = broadcastQueueForIntent(oldRecord.intent);
                    try {
                        oldQueue.performReceiveLocked(oldRecord.callerApp, oldRecord.resultTo,
                                oldRecord.intent,
                                Activity.RESULT_CANCELED, null, null,
                                false, false, oldRecord.userId);
                    } catch (RemoteException e) {
...

                    }
                }
            } else {
                queue.enqueueOrderedBroadcastLocked(r);
                queue.scheduleBroadcastsLocked();
            }
        } else {

            if (intent.getComponent() == null && intent.getPackage() == null
                    && (intent.getFlags()&Intent.FLAG_RECEIVER_REGISTERED_ONLY) == 0) {
                // This was an implicit broadcast... let's record it for posterity.
                addBroadcastStatLocked(intent.getAction(), callerPackage, 0, 0, 0);
            }
        }
```
这个过程实际上是把静态注册的广播接受者和动态广播接受者合并到一个队列。
在这段代码开始之前：
- receivers保存的是静态注册的广播接受者
- registeredReceivers保存的是动态注册的广播接受者

- 1.receivers不为空，第一部分实际上就是处理Intent.ACTION_PACKAGE_ADDED的情况。这个Intent标志位代表了有新的app包安装好了。此时会剔除这些Intent对应的应用的包名中的receivers静态注册广播接受者集合。避免的是一安装了就被广播流氓的拉起应用。
  - 第二部分就是把动态注册广播和静态注册的广播接受者比较优先级，根据Priority从小到大排序，同一个级别的动态接受者必定在静态接受者的receivers下标的后方。
  - 把剩余的动态注册的广播接受者放在最后。



这得益于receivers本身没有确定好泛型，可以存入任意的Object

- 2.broadcastQueueForIntent 获取对应的BroadcastQueue；
- 3.根据receivers生成BroadcastRecord对象
- 4.enqueueOrderedBroadcastLocked 把BroadcastRecord存入BroadcastRecord中的队列。
- 5.scheduleBroadcastsLocked 执行发送行为。

来看看和并行发送广播中存入队列方法不同的enqueueOrderedBroadcastLocked。

##### BroadcastQueue enqueueOrderedBroadcastLocked
```java
    public void enqueueOrderedBroadcastLocked(BroadcastRecord r) {
        mOrderedBroadcasts.add(r);
        enqueueBroadcastHelper(r);
    }
```
很简单，就是保存到mOrderedBroadcasts这个ArrayList中。


最后我们考察scheduleBroadcastsLocked方法。

#### scheduleBroadcastsLocked 发送广播
```java
    public void scheduleBroadcastsLocked() {

        if (mBroadcastsScheduled) {
            return;
        }
        mHandler.sendMessage(mHandler.obtainMessage(BROADCAST_INTENT_MSG, this));
        mBroadcastsScheduled = true;
    }
```
很简单通过Hander发送了一个BROADCAST_INTENT_MSG消息

##### BroadcastHandler
```java
    private final class BroadcastHandler extends Handler {
        public BroadcastHandler(Looper looper) {
            super(looper, null, true);
        }

        @Override
        public void handleMessage(Message msg) {
            switch (msg.what) {
                case BROADCAST_INTENT_MSG: {

                    processNextBroadcast(true);
                } break;
                case BROADCAST_TIMEOUT_MSG: {
                    synchronized (mService) {
                        broadcastTimeoutLocked(true);
                    }
                } break;
            }
        }
    }
```
能看到BroadcastHandler中处理了两个消息：
- 1.processNextBroadcast 发送广播行为
- 2.broadcastTimeoutLocked 发送广播超时

注意broadcastTimeoutLocked这个方法是最后是否爆出ANR是由BroadcastQueue构造函数决定的分别是10秒，60秒。

我们重点关注processNextBroadcast中的核心方法。


##### processNextBroadcast
我这里把这个方法分为三个部分尽心考察
```java
    final void processNextBroadcastLocked(boolean fromMsg, boolean skipOomAdj) {
        BroadcastRecord r;


        mService.updateCpuStats();

        if (fromMsg) {
            mBroadcastsScheduled = false;
        }

        while (mParallelBroadcasts.size() > 0) {
            r = mParallelBroadcasts.remove(0);
            r.dispatchTime = SystemClock.uptimeMillis();
            r.dispatchClockTime = System.currentTimeMillis();


            final int N = r.receivers.size();

            for (int i=0; i<N; i++) {
                Object target = r.receivers.get(i);

                deliverToRegisteredReceiverLocked(r, (BroadcastFilter)target, false, i);
            }
            addBroadcastToHistoryLocked(r);

        }

        // Now take care of the next serialized one...


        if (mPendingBroadcast != null) {

            boolean isDead;
            if (mPendingBroadcast.curApp.pid > 0) {
                synchronized (mService.mPidsSelfLocked) {
                    ProcessRecord proc = mService.mPidsSelfLocked.get(
                            mPendingBroadcast.curApp.pid);
                    isDead = proc == null || proc.crashing;
                }
            } else {
                final ProcessRecord proc = mService.mProcessNames.get(
                        mPendingBroadcast.curApp.processName, mPendingBroadcast.curApp.uid);
                isDead = proc == null || !proc.pendingStart;
            }
            if (!isDead) {

                return;
            } else {
                mPendingBroadcast.state = BroadcastRecord.IDLE;
                mPendingBroadcast.nextReceiver = mPendingBroadcastRecvIndex;
                mPendingBroadcast = null;
            }
        }

...
    }
```

- 1.遍历保存在mParallelBroadcasts 这个ArrayList中的并行发送广播队列。获取mParallelBroadcasts中的receivers动态注册的广播对象。
- 2.调用deliverToRegisteredReceiverLocked方法，把receiver对象强转为BroadcastFIlter进行跨进程的发送。
- 3.mPendingBroadcast 是上一次执行完processNextBroadcastLocked方法，本次即将发送的对象。此时校验在本次准备发送mPendingBroadcast对应的广播接受者之前，判断广播接受者所在的进程是否还存活。

```java
        boolean looped = false;

        do {
            if (mOrderedBroadcasts.size() == 0) {
                mService.scheduleAppGcsLocked();
                if (looped) {

                    mService.updateOomAdjLocked();
                }
                return;
            }
            r = mOrderedBroadcasts.get(0);
            boolean forceReceive = false;

            int numReceivers = (r.receivers != null) ? r.receivers.size() : 0;
            if (mService.mProcessesReady && r.dispatchTime > 0) {
                long now = SystemClock.uptimeMillis();
                if ((numReceivers > 0) &&
                        (now > r.dispatchTime + (2*mTimeoutPeriod*numReceivers))) {

                    broadcastTimeoutLocked(false); 
                    forceReceive = true;
                    r.state = BroadcastRecord.IDLE;
                }
            }

            if (r.state != BroadcastRecord.IDLE) {

                return;
            }

            if (r.receivers == null || r.nextReceiver >= numReceivers
                    || r.resultAbort || forceReceive) {

                if (r.resultTo != null) {
                    try {

                        performReceiveLocked(r.callerApp, r.resultTo,
                            new Intent(r.intent), r.resultCode,
                            r.resultData, r.resultExtras, false, false, r.userId);

                        r.resultTo = null;
                    } catch (RemoteException e) {
                        r.resultTo = null;

                    }
                }


                cancelBroadcastTimeoutLocked();


                addBroadcastToHistoryLocked(r);
                if (r.intent.getComponent() == null && r.intent.getPackage() == null
                        && (r.intent.getFlags()&Intent.FLAG_RECEIVER_REGISTERED_ONLY) == 0) {

                    mService.addBroadcastStatLocked(r.intent.getAction(), r.callerPackage,
                            r.manifestCount, r.manifestSkipCount, r.finishTime-r.dispatchTime);
                }
                mOrderedBroadcasts.remove(0);
                r = null;
                looped = true;
                continue;
            }
        } while (r == null);

```
遍历了之前添加到mOrderedBroadcasts的序列发送广播队列中，在这个过程做了三件事情：
- 1.mOrderedBroadcasts取出第一个BroadcastRecord对象。BroadcastRecord中持有了所有需要分发的广播接受者集合receiver。判断到当前分发时间点进行超时判断：
 > 当前时间 >  分发的时间点 + 2 * 当前BroadcastQueue的超时时间 * 广播接受者数量

这个阈值代表了当前必定有广播接受者执行超时了。

- 2.如果此时广播遍历所有的BroadcastRecord，发现BroadcastRecord的没有待分发的广播接受者，且resultTo不为空，则调用performReceiveLocked方法进行广播的分发。

  - 2.1.cancelBroadcastTimeoutLocked 取消BroadcastReceiver中Handler预设的ANR炸弹。也就是移除BROADCAST_TIMEOUT_MSG消息。addBroadcastToHistoryLocked把BroadcastRecord添加在历史队列中。mOrderedBroadcasts移除当前的BroadcastRecord。跳出遍历的循环。


```java

        int recIdx = r.nextReceiver++;


        r.receiverTime = SystemClock.uptimeMillis();
        if (recIdx == 0) {
            r.dispatchTime = r.receiverTime;
            r.dispatchClockTime = System.currentTimeMillis();


        }
        if (! mPendingBroadcastTimeoutMessage) {
            long timeoutTime = r.receiverTime + mTimeoutPeriod;

            setBroadcastTimeoutLocked(timeoutTime);
        }

        final BroadcastOptions brOptions = r.options;
        final Object nextReceiver = r.receivers.get(recIdx);

        if (nextReceiver instanceof BroadcastFilter) {

            BroadcastFilter filter = (BroadcastFilter)nextReceiver;

            deliverToRegisteredReceiverLocked(r, filter, r.ordered, recIdx);
            if (r.receiver == null || !r.ordered) {

                r.state = BroadcastRecord.IDLE;
                scheduleBroadcastsLocked();
            } else {
                if (brOptions != null && brOptions.getTemporaryAppWhitelistDuration() > 0) {
                    scheduleTempWhitelistLocked(filter.owningUid,
                            brOptions.getTemporaryAppWhitelistDuration(), r);
                }
            }
            return;
        }

        ResolveInfo info =
            (ResolveInfo)nextReceiver;
        ComponentName component = new ComponentName(
                info.activityInfo.applicationInfo.packageName,
                info.activityInfo.name);
....
        if (r.curApp != null && r.curApp.crashing) {

            skip = true;
        }

        if (r.callingUid != Process.SYSTEM_UID && isSingleton
                && mService.isValidSingletonCall(r.callingUid, receiverUid)) {
            info.activityInfo = mService.getActivityInfoForUser(info.activityInfo, 0);
        }
        String targetProcess = info.activityInfo.processName;
        ProcessRecord app = mService.getProcessRecordLocked(targetProcess,
                info.activityInfo.applicationInfo.uid, false);

....

        if (skip) {

            r.delivery[recIdx] = BroadcastRecord.DELIVERY_SKIPPED;
            r.receiver = null;
            r.curFilter = null;
            r.state = BroadcastRecord.IDLE;
            r.manifestSkipCount++;
            scheduleBroadcastsLocked();
            return;
        }
        r.manifestCount++;

        r.delivery[recIdx] = BroadcastRecord.DELIVERY_DELIVERED;
        r.state = BroadcastRecord.APP_RECEIVE;
        r.curComponent = component;
        r.curReceiver = info.activityInfo;


        if (brOptions != null && brOptions.getTemporaryAppWhitelistDuration() > 0) {
            scheduleTempWhitelistLocked(receiverUid,
                    brOptions.getTemporaryAppWhitelistDuration(), r);
        }

        try {
            AppGlobals.getPackageManager().setPackageStoppedState(
                    r.curComponent.getPackageName(), false, UserHandle.getUserId(r.callingUid));
        } catch (RemoteException e) {
        } catch (IllegalArgumentException e) {

        }

        if (app != null && app.thread != null && !app.killed) {
            try {
                app.addPackage(info.activityInfo.packageName,
                        info.activityInfo.applicationInfo.versionCode, mService.mProcessStats);
                processCurBroadcastLocked(r, app, skipOomAdj);
                return;
            } catch (RemoteException e) {

            } catch (RuntimeException e) {

                logBroadcastReceiverDiscardLocked(r);
                finishReceiverLocked(r, r.resultCode, r.resultData,
                        r.resultExtras, r.resultAbort, false);
                scheduleBroadcastsLocked();
                r.state = BroadcastRecord.IDLE;
                return;
            }

        }


        if ((r.curApp=mService.startProcessLocked(targetProcess,
                info.activityInfo.applicationInfo, true,
                r.intent.getFlags() | Intent.FLAG_FROM_BACKGROUND,
                "broadcast", r.curComponent,
                (r.intent.getFlags()&Intent.FLAG_RECEIVER_BOOT_UPGRADE) != 0, false, false))
                        == null) {

            logBroadcastReceiverDiscardLocked(r);
            finishReceiverLocked(r, r.resultCode, r.resultData,
                    r.resultExtras, r.resultAbort, false);
            scheduleBroadcastsLocked();
            r.state = BroadcastRecord.IDLE;
            return;
        }

        mPendingBroadcast = r;
        mPendingBroadcastRecvIndex = recIdx;
```

此时已经从mOrderedBroadcasts取出第一个BroadcastRecord对象到r中。
在这个过程中BroadcastRecord的recIdx记录的是当前已经遍历到了BroadcastRecord中receiver哪一个广播接受者。每一次都是先获取index，再+1.

- 1.如果当前的是BroadcastFilter，也就是动态注册的广播接受者。就会调用deliverToRegisteredReceiverLocked分发广播。并且调用scheduleBroadcastsLocked方法，进入方法递归，继续执行Handler中的发送广播的handler消息。不断的通过handler循环执行当前processNextBroadcastLocked方法，知道把BroadcastFilter中所有的receiver执行完

- 2.不是BroadcastFilter对象，说明是静态注册的广播对象。此时会先从ResolveInfo获取包名和分发的类名。
  - 2.1.校验权限没有问题，且是安装的包或者是系统应用。继续通过AMS的getProcessRecordLocked获取当前进程对象ProcessRecord。
  - 2.2.如果当前的静态广播因为权限等问题需要跳过分发，则直接执行scheduleBroadcastsLocked方法。
  - 2.3.如果当前的广播需要分发的进程还存活，则调用processCurBroadcastLocked方法进行分发。
  - 2.4.此时说明接受的广播进程并没有启动，就需要AMS的startProcessLocked启动完进程后，再调用scheduleBroadcastsLocked进入下一个looper进行分发。


真正跨进程分发广播的行为方法有两个：
- 1.deliverToRegisteredReceiverLocked 跨进程分发动态注册的广播
- 2.processCurBroadcastLocked 跨进程分发静态注册的广播
- 3.performReceiveLocked 根据进程直接分发广播

#### deliverToRegisteredReceiverLocked 跨进程分发动态注册的广播
```java
    private void deliverToRegisteredReceiverLocked(BroadcastRecord r,
            BroadcastFilter filter, boolean ordered, int index) {
        boolean skip = false;
...
        r.delivery[index] = BroadcastRecord.DELIVERY_DELIVERED;

        if (ordered) {
            r.receiver = filter.receiverList.receiver.asBinder();
            r.curFilter = filter;
            filter.receiverList.curBroadcast = r;
            r.state = BroadcastRecord.CALL_IN_RECEIVE;
            if (filter.receiverList.app != null) {

                r.curApp = filter.receiverList.app;
                filter.receiverList.app.curReceivers.add(r);
                mService.updateOomAdjLocked(r.curApp, true);
            }
        }
        try {

            if (filter.receiverList.app != null && filter.receiverList.app.inFullBackup) {
...
            } else {
                performReceiveLocked(filter.receiverList.app, filter.receiverList.receiver,
                        new Intent(r.intent), r.resultCode, r.resultData,
                        r.resultExtras, r.ordered, r.initialSticky, r.userId);
            }
            if (ordered) {
                r.state = BroadcastRecord.CALL_DONE_RECEIVE;
            }
        } catch (RemoteException e) {

        }
    }
```
- 1.先更新进程中OomAdj的进程优先级
- 2.从filter中找到对应的进程，调用performReceiveLocked进行分发。

#### processCurBroadcastLocked 跨进程分发静态注册的广播
```java
    private final void processCurBroadcastLocked(BroadcastRecord r,
            ProcessRecord app, boolean skipOomAdj) throws RemoteException {

        if (app.thread == null) {
            throw new RemoteException();
        }
        if (app.inFullBackup) {
            skipReceiverLocked(r);
            return;
        }

        r.receiver = app.thread.asBinder();
        r.curApp = app;
        app.curReceivers.add(r);
        app.forceProcessStateUpTo(ActivityManager.PROCESS_STATE_RECEIVER);
        mService.updateLruProcessLocked(app, false, null);
        if (!skipOomAdj) {
            mService.updateOomAdjLocked();
        }


        r.intent.setComponent(r.curComponent);

        boolean started = false;
        try {
            mService.notifyPackageUse(r.intent.getComponent().getPackageName(),
                                      PackageManager.NOTIFY_PACKAGE_USE_BROADCAST_RECEIVER);
            app.thread.scheduleReceiver(new Intent(r.intent), r.curReceiver,
                    mService.compatibilityInfoForPackageLocked(r.curReceiver.applicationInfo),
                    r.resultCode, r.resultData, r.resultExtras, r.ordered, r.userId,
                    app.repProcState);

            started = true;
        } finally {
            if (!started) {
                r.receiver = null;
                r.curApp = null;
                app.curReceivers.remove(r);
            }
        }
    }
```
很简单，此时就是直接从BroadcastRecord中保存了的Intent消息发送到App进程的ActivityThread中的ApplicationThread的scheduleReceiver方法。

#### performReceiveLocked 根据进程直接分发广播
```java
    void performReceiveLocked(ProcessRecord app, IIntentReceiver receiver,
            Intent intent, int resultCode, String data, Bundle extras,
            boolean ordered, boolean sticky, int sendingUser) throws RemoteException {

        if (app != null) {
            if (app.thread != null) {

                try {
                    app.thread.scheduleRegisteredReceiver(receiver, intent, resultCode,
                            data, extras, ordered, sticky, sendingUser, app.repProcState);

                } catch (RemoteException ex) {

                    synchronized (mService) {
                        app.scheduleCrash("can't deliver broadcast");
                    }
                    throw ex;
                }
            } else {
                throw new RemoteException("app.thread must not be null");
            }
        } else {
            receiver.performReceive(intent, resultCode, data, extras, ordered,
                    sticky, sendingUser);
        }
    }
```
这个方法调用了App进程的ActivityThread的scheduleRegisteredReceiver方法。如果App进程已经不存在了则调用receiver的performReceive方法，也就是在SystemServer进程处理广播消息。

能发现在App进程有两个入口分别处理广播消息。

#### ActivityThread scheduleRegisteredReceiver 处理动态注册广播
```java
        public void scheduleRegisteredReceiver(IIntentReceiver receiver, Intent intent,
                int resultCode, String dataStr, Bundle extras, boolean ordered,
                boolean sticky, int sendingUser, int processState) throws RemoteException {
            updateProcessState(processState, false);
            receiver.performReceive(intent, resultCode, dataStr, extras, ordered,
                    sticky, sendingUser);
        }

```
这个方法实际上就是专门处理动态注册的广播接受者。把BroadcastFilter中的IIntentReceiver对象带过来。并直接执行IIntentReceiver的performReceive方法。

关于这个方法的原理在动态注册介绍的时候已经说过了，最后会走到下面这个方法：
```java
            public void run() {
                final BroadcastReceiver receiver = mReceiver;
                final boolean ordered = mOrdered;
...
                final IActivityManager mgr = ActivityManagerNative.getDefault();
                final Intent intent = mCurIntent;

                mCurIntent = null;
                mDispatched = true;
                if (receiver == null || intent == null || mForgotten) {
                    if (mRegistered && ordered) {
                        sendFinished(mgr);
                    }
                    return;
                }

                try {
                    ClassLoader cl =  mReceiver.getClass().getClassLoader();
                    intent.setExtrasClassLoader(cl);
                    intent.prepareToEnterProcess();
                    setExtrasClassLoader(cl);
                    receiver.setPendingResult(this);
                    receiver.onReceive(mContext, intent);
                } catch (Exception e) {
                    if (mRegistered && ordered) {

                        sendFinished(mgr);
                    }

                }
                
                if (receiver.getPendingResult() != null) {
                    finish();
                }
                
            }
```
注意此时的Context是当前申请的Activity的ContextImpl。此时会获取ClassLoader设置在Intent中，并调用动态注册的BroadcastReceiver的onReceive方法，把Intent和context一起传入。

#### ActivityThread scheduleReceiver 处理静态注册广播
```java
        public final void scheduleReceiver(Intent intent, ActivityInfo info,
                CompatibilityInfo compatInfo, int resultCode, String data, Bundle extras,
                boolean sync, int sendingUser, int processState) {
            updateProcessState(processState, false);
            ReceiverData r = new ReceiverData(intent, resultCode, data, extras,
                    sync, false, mAppThread.asBinder(), sendingUser);
            r.info = info;
            r.compatInfo = compatInfo;
            sendMessage(H.RECEIVER, r);
        }
```
此时很简单，把从AMS来的数据封装成ReceiverData，在ActivityThreade的主Looper中分发RECEIVER消息。

```java
                case RECEIVER:
                    handleReceiver((ReceiverData)msg.obj);
                    break;
```
核心方法调用了handleReceiver方法。

##### handleReceiver
```java
    private void handleReceiver(ReceiverData data) {

        unscheduleGcIdler();

        String component = data.intent.getComponent().getClassName();

        LoadedApk packageInfo = getPackageInfoNoCheck(
                data.info.applicationInfo, data.compatInfo);

        IActivityManager mgr = ActivityManager.getService();

        Application app;
        BroadcastReceiver receiver;
        ContextImpl context;
        try {
            app = packageInfo.makeApplication(false, mInstrumentation);
            context = (ContextImpl) app.getBaseContext();
            if (data.info.splitName != null) {
                context = (ContextImpl) context.createContextForSplit(data.info.splitName);
            }
            java.lang.ClassLoader cl = context.getClassLoader();
            data.intent.setExtrasClassLoader(cl);
            data.intent.prepareToEnterProcess();
            data.setExtrasClassLoader(cl);
            receiver = packageInfo.getAppFactory()
                    .instantiateReceiver(cl, data.info.name, data.intent);
        } catch (Exception e) {
...
        }

        try {

            sCurrentBroadcastIntent.set(data.intent);
            receiver.setPendingResult(data);
            receiver.onReceive(context.getReceiverRestrictedContext(),
                    data.intent);
        } catch (Exception e) {
            data.sendFinished(mgr);
            if (!mInstrumentation.onException(receiver, e)) {
                throw new RuntimeException(
                    "Unable to start receiver " + component
                    + ": " + e.toString(), e);
            }
        } finally {
            sCurrentBroadcastIntent.set(null);
        }

        if (receiver.getPendingResult() != null) {
            data.finish();
        }
    }
```
在这里有很多关于LoadedApk的操作。具体的解析可以阅读[ActivityThread的初始化](https://www.jianshu.com/p/2b1d43ffeba6).

执行了如下方法：
- 1.从LoadedApk获取缓存的Application对象
- 2.获取Application的Context
- 3.通过LoadedApk的AppComponentFactory创建一个BroadcastReceiver。
- 4.调用BroadcastReceiver的onReceive方法
- 5.调用ReceiverData返回消息。

重点来看看AppComponentFactory是如何创建BroadcastReceiver。

###### AppComponentFactory instantiateReceiver
其实Androidx也有重写这个AppComponentFactory对象
```java
    public @NonNull BroadcastReceiver instantiateReceiver(@NonNull ClassLoader cl,
            @NonNull String className, @Nullable Intent intent)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        return (BroadcastReceiver) cl.loadClass(className).newInstance();
    }
```
很简单就是反射实例化。

#### ReceiverData 返回发送成功
```java
        public final void finish() {
            if (mType == TYPE_COMPONENT) {
                final IActivityManager mgr = ActivityManager.getService();
                if (QueuedWork.hasPendingWork()) {
                    QueuedWork.queue(new Runnable() {
                        @Override public void run() {

                            sendFinished(mgr);
                        }
                    }, false);
                } else {
                    sendFinished(mgr);
                }
            } else if (mOrderedHint && mType != TYPE_UNREGISTERED) {

                final IActivityManager mgr = ActivityManager.getService();
                sendFinished(mgr);
            }
        }

        public void sendFinished(IActivityManager am) {
            synchronized (this) {
                if (mFinished) {
                    throw new IllegalStateException("Broadcast already finished");
                }
                mFinished = true;

                try {
                    if (mResultExtras != null) {
                        mResultExtras.setAllowFds(false);
                    }
                    if (mOrderedHint) {
                        am.finishReceiver(mToken, mResultCode, mResultData, mResultExtras,
                                mAbortBroadcast, mFlags);
                    } else {
                        am.finishReceiver(mToken, 0, null, null, false, mFlags);
                    }
                } catch (RemoteException ex) {
                }
            }
        }
```
这个过程就是调用了AMS的finishReceiver方法。

###### AMS finishReceiver

```java
    public void finishReceiver(IBinder who, int resultCode, String resultData,
            Bundle resultExtras, boolean resultAbort, int flags) {
        if (DEBUG_BROADCAST) Slog.v(TAG_BROADCAST, "Finish receiver: " + who);

        // Refuse possible leaked file descriptors
        if (resultExtras != null && resultExtras.hasFileDescriptors()) {
            throw new IllegalArgumentException("File descriptors passed in Bundle");
        }

        final long origId = Binder.clearCallingIdentity();
        try {
            boolean doNext = false;
            BroadcastRecord r;

            synchronized(this) {
                BroadcastQueue queue = (flags & Intent.FLAG_RECEIVER_FOREGROUND) != 0
                        ? mFgBroadcastQueue : mBgBroadcastQueue;
                r = queue.getMatchingOrderedReceiver(who);
                if (r != null) {
                    doNext = r.queue.finishReceiverLocked(r, resultCode,
                        resultData, resultExtras, resultAbort, true);
                }
                if (doNext) {
                    r.queue.processNextBroadcastLocked(/*fromMsg=*/ false, /*skipOomAdj=*/ true);
                }
                trimApplicationsLocked();
            }

        } finally {
            Binder.restoreCallingIdentity(origId);
        }
    }
```
- 调用BroadcastQueue的finishReceiverLocked方法，告诉BroadcastQueue对应的广播已经处理完了。
- 通过finishReceiverLocked判断是否还有需要处理的BroadcastRecord，如果有则processNextBroadcastLocked继续处理所有的并行消息和有序消息。

###### BroadcastQueue finishReceiverLocked
```java
    public boolean finishReceiverLocked(BroadcastRecord r, int resultCode,
            String resultData, Bundle resultExtras, boolean resultAbort, boolean waitForServices) {
        final int state = r.state;
        final ActivityInfo receiver = r.curReceiver;
        r.state = BroadcastRecord.IDLE;

        r.receiver = null;
        r.intent.setComponent(null);
        if (r.curApp != null && r.curApp.curReceivers.contains(r)) {
            r.curApp.curReceivers.remove(r);
        }
        if (r.curFilter != null) {
            r.curFilter.receiverList.curBroadcast = null;
        }
        r.curFilter = null;
        r.curReceiver = null;
        r.curApp = null;
        mPendingBroadcast = null;

        r.resultCode = resultCode;
        r.resultData = resultData;
        r.resultExtras = resultExtras;
        if (resultAbort && (r.intent.getFlags()&Intent.FLAG_RECEIVER_NO_ABORT) == 0) {
            r.resultAbort = resultAbort;
        } else {
            r.resultAbort = false;
        }

        if (waitForServices && r.curComponent != null && r.queue.mDelayBehindServices
                && r.queue.mOrderedBroadcasts.size() > 0
                && r.queue.mOrderedBroadcasts.get(0) == r) {
            ActivityInfo nextReceiver;
            if (r.nextReceiver < r.receivers.size()) {
                Object obj = r.receivers.get(r.nextReceiver);
                nextReceiver = (obj instanceof ActivityInfo) ? (ActivityInfo)obj : null;
            } else {
                nextReceiver = null;
            }

            if (receiver == null || nextReceiver == null
                    || receiver.applicationInfo.uid != nextReceiver.applicationInfo.uid
                    || !receiver.processName.equals(nextReceiver.processName)) {
                if (mService.mServices.hasBackgroundServicesLocked(r.userId)) {
                    r.state = BroadcastRecord.WAITING_SERVICES;
                    return false;
                }
            }
        }

        r.curComponent = null;

        return state == BroadcastRecord.APP_RECEIVE
                || state == BroadcastRecord.CALL_DONE_RECEIVE;
    }
```
- 1.清除ProcessRecord中的curReceivers保存的BroadcastRecord
- 2.清除BroadcastRecord中的ReceiverList，mPendingBroadcast
- 3.注意在分发有序广播分发已经给了BroadcastRecord的state设置为BroadcastRecord.APP_RECEIVE;换句话说，只要接下来的BroadcastQueue的有序广播消息不为空，那么这个方法一般返回为true。让BroadcastQueue继续分发广播消息。

## 总结
先来看看BroadcastReceiver的注册流程。

BroadcastReceiver分为静态注册和动态注册：

- BroadcastReceiver的静态注册，本质上就是在安装过程中AndroidManifest解析后把解析到的receiver数据保存ActivityInfo到PMS中。当需要查询的时候就会封装成ResolveInfo保存到

- BroadcastReceiver的动态注册，本质上就是把BroadcastReceiver转化为ReceiverDispatcher。如果获取ReceiverDispatcher发现在LoadedApk对象中的mReceivers缓存中已经保存了，则直接返回。
  - ReceiverDispatcher中IIntentReceiver一个Binder对象，并把这个对象跨进程传输到AMS中。在AMS中先把这个对象封装成ReceiverList；
  - 接着和IntentFilter进一步保存BroadcastFilter。
  - 这样动态注册的BroadcastReceiver的对象就持有了当前广播接受者的类以及过滤条件。最后把BroadcastFilter保存到mReceiverResolver中。mReceiverResolver是一个ActivityIntentResolver。
  - 在这个过程会检测粘性广播，每一次注册之后会检测所有符合条件的粘性广播接受者并分发。注意粘性广播都是分发给动态注册的广播，也只有动态注册才会出现分发广播的时候还不存在。

下面是总结的图:
![BroadcastReceiver.png](/images/BroadcastReceiver.png)

结合上面总结的图，我们来总结发送广播，BroadcastReceiver 接受的过程。

就是专门处理如下三个函数的逻辑：
```java
    public abstract void sendBroadcast(@RequiresPermission Intent intent);

    public abstract void sendOrderedBroadcast(@RequiresPermission Intent intent,
            @Nullable String receiverPermission);

```

- 1.发送广播后，调用了broadcastIntent进行分发广播。发现此时的广播消息是粘性消息，先把广播保存起来

- 2.如果当前的Intent的flag设置了FLAG_RECEIVER_REGISTERED_ONLY，说明只会获取动态注册的广播，就不会从PMS中查找符合过滤条件静态注册的广播放到receiver集合中

- 3.接着从ActivityIntentResolver获取符合当前IntentFilter也就是符合过滤条件动态注册的广播接受者，放入registeredReceivers集合中

- 4.如果当前发送的广播消息是非有序，则把当前从registeredReceivers集合中查找到符合条件的BroadcastFilter添加通过enqueueParallelBroadcastLocked到BroadcastQueue的并发队列中；并且调用scheduleBroadcastsLocked让BroadcastQueue中Handler执行发送消息方法processNextBroadcast。

- 5.接着把获取到的静态广播接受者和动态广播接受者合并到一个队列receivers，并且包装receivers生成BroadcastRecord对象通过enqueueOrderedBroadcastLocked放入BroadcastQueue有序队列中，通过scheduleBroadcastsLocked调用Handler的发送消息方法processNextBroadcast。

- 6.通过Handler唤醒的BroadcastHandler，遍历保存在mParallelBroadcasts 这个ArrayList中的并行发送广播队列。
  - 获取mParallelBroadcasts中的receivers动态注册的广播对象BroadcastFilter，并且最后都调用跨进程调用方法scheduleReceiver通知ApplicationThread的scheduleRegisteredReceiver方法。
  - scheduleRegisteredReceiver则会调用传递进来的IIntentReceiver这个Binder对象，并通过他执行BroadcastReceiver的onReceiver。


- 7.遍历保存在mOrderedBroadcasts中的广播接受者有序队列。如果当前元素是BroadcastReceiver说明是动态注册的广播接受者，将会重复第6点的逻辑。  
  - 如果当前元素ResolveInfo说明是静态注册的广播接受者，最后会调用ApplicationThread的scheduleReceiver方法。
  - scheduleReceiver会通过App的主线程的Looper执行handleReceiver方法，每一次都生成一个新的BroadcastReceiver，把广播消息发送给BroadcastReceiver的onReceive方法。

- 8.当每一次广播执行完了都会执行BroadcastReceiver.PendingResult的sendFinished方法。而这个方法会清除一些在BroadcastQueue的残留属性之外还会询问是否有需要消息的有序消息，如果是则继续执行processNextBroadcast。

## 注意事项
值得注意的是在Android高版本如果在Intent不设置好Package，不会发现AMS拒绝发送这条广播到对应的广播接受者。
```java
        if (!skip) {
            final int allowed = mService.getAppStartModeLocked(
                    info.activityInfo.applicationInfo.uid, info.activityInfo.packageName,
                    info.activityInfo.applicationInfo.targetSdkVersion, -1, true, false, false);
            if (allowed != ActivityManager.APP_START_MODE_NORMAL) {
                // We won't allow this receiver to be launched if the app has been
                // completely disabled from launches, or it was not explicitly sent
                // to it and the app is in a state that should not receive it
                // (depending on how getAppStartModeLocked has determined that).
                if (allowed == ActivityManager.APP_START_MODE_DISABLED) {
                    Slog.w(TAG, "Background execution disabled: receiving "
                            + r.intent + " to "
                            + component.flattenToShortString());
                    skip = true;
                } else if (((r.intent.getFlags()&Intent.FLAG_RECEIVER_EXCLUDE_BACKGROUND) != 0)
                        || (r.intent.getComponent() == null
                            && r.intent.getPackage() == null
                            && ((r.intent.getFlags()
                                    & Intent.FLAG_RECEIVER_INCLUDE_BACKGROUND) == 0)
                            && !isSignaturePerm(r.requiredPermissions))) {
                    mService.addBackgroundCheckViolationLocked(r.intent.getAction(),
                            component.getPackageName());
                    Slog.w(TAG, "Background execution not allowed: receiving "
                            + r.intent + " to "
                            + component.flattenToShortString());
                    skip = true;
                }
            }
        }
```
一般会爆出下面这个分支的异常，从而跳出当前分发逻辑。一般就是因为在这个过程校验了Intent的getPackage和getComponent都为空且没有打开FLAG_RECEIVER_INCLUDE_BACKGROUND的flag；或者打开了FLAG_RECEIVER_EXCLUDE_BACKGROUND。

这两个标志位处理了该消息是否包含了后台Receiver。注意这里的后台是相对，对于Intent来说只要没有知道他的包名或者Component。和发送的时候添加Intent.FLAG_RECEIVER_FOREGROUND不是一样的意思。

> FLAG_RECEIVER_FOREGROUND 当发送广播的时候设置了这个标志，会允许接收者以前台的优先级运行，有更短的时间间隔。正常广播的接受者是后台优先级，不会被自动提升。

为了适配BroadcastReceiver，我们必须添加好包名避免出现问题。或者添加：
```java
int ent.addFlags(0x01000000);
```
也就是FLAG_RECEIVER_INCLUDE_BACKGROUND才会正常。

这个坑在我为公司编写根据渠道自动切换推送库踩过，这里提示一下。

### Intent的意图过滤原理

- 如果想要IntentFilter，意图过滤生效。满足三个条件之一，一个是必须存在Intent的action，另一个是getContentReslover的字符串不为空，最后一个是scheme不为空。这决定了解析是否能拆分出四个子部分进行匹配

- categories并非是必须的，就算没有也可以通过action，data，scheme，type进行匹配。

- 当存在action，就会从中获取所有符合条件的所有ActivityIntentInfo对象，在此基础上，对依次对data，categories进行匹配。如果data匹配成功了就直接返回，如果data匹配失败了就会尝试匹配categories。

如果存在多个data只需要匹配其中一个data返回即可。


