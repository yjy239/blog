---
title: Android重学系列 ContentProvider 启动原理
top: false
cover: false
date: 2020-08-15 22:10:34
img:
tag:
description:
author: yjy239
summary:
categories: Android Framework
tags:
- Android Framework
- Android
---

# 前言

终于来到了四大组件的最后一个了，ContentProvider(之后简称CP)开发中用的不是很多，但这不代表这不重要。很多开源库不少巧妙的思路就是借用CP巧妙实现的，如头条的AutoSize是如何自动获取Context的，360的RePlugin是如何管理异步进程的Binder对象。还有比如说插件化管理多个LoadedApk对象，也是从CP的源码中汲取灵感。

当然我们常用的手段都是把CP作为开放给另一个进程或者服务的查询接口。先来看看怎么使用的。

# 正文

```java
public class MyCP extends ContentProvider {
    @Override
    public boolean onCreate() {
        return false;
    }

    @Nullable
    @Override
    public Cursor query(@NonNull Uri uri, @Nullable String[] projection, @Nullable String selection, @Nullable String[] selectionArgs, @Nullable String sortOrder) {
        return null;
    }

    @Nullable
    @Override
    public String getType(@NonNull Uri uri) {
        return null;
    }

    @Nullable
    @Override
    public Uri insert(@NonNull Uri uri, @Nullable ContentValues values) {
        return null;
    }

    @Override
    public int delete(@NonNull Uri uri, @Nullable String selection, @Nullable String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(@NonNull Uri uri, @Nullable ContentValues values, @Nullable String selection, @Nullable String[] selectionArgs) {
        return 0;
    }
}
```
先继承ContentProvider，实现自己的增删查改四个接口。来处理自己可以允许外部操作的数据。一般为SQLite 数据库等敏感数据，从而做到隔离的目的。

接着在在AndroidManifest中声明:
```xml
        <provider
            android:name=".MyCP"
            android:authorities="com.example.data"
            />
```
这样就能让外部的应用，或者本进程应用进行访问通过android:authorities进行访问这个CP中对外开放的数据了。

注意CP支持跨进程，跨应用查询数据，这是怎么做到的呢？本文就来重点探索。

## 本进程启动时的CP启动

在我写的[ActivityThread的初始化](https://www.jianshu.com/p/2b1d43ffeba6)一文中，handleBindApplication方法中，有这么一段：
```java
            if (!data.restrictedBackupMode) {
                if (!ArrayUtils.isEmpty(data.providers)) {
                    installContentProviders(app, data.providers);
                    mH.sendEmptyMessageDelayed(H.ENABLE_JIT, 10*1000);
                }
            }
```
当执行绑定Application的时候，会调用installContentProviders方法。获取AppBindData中所有的从PMS中解析出来来自apk包中所有的ProviderInfo信息，也就是AndroidManifest中所有注册在xml中ContentProvider。

### installContentProviders
```java

    private void installContentProviders(
            Context context, List<ProviderInfo> providers) {
        final ArrayList<ContentProviderHolder> results = new ArrayList<>();

        for (ProviderInfo cpi : providers) {
            ContentProviderHolder cph = installProvider(context, null, cpi,
                    false /*noisy*/, true /*noReleaseNeeded*/, true /*stable*/);
            if (cph != null) {
                cph.noReleaseNeeded = true;
                results.add(cph);
            }
        }

        try {
            ActivityManager.getService().publishContentProviders(
                getApplicationThread(), results);
        } catch (RemoteException ex) {
            throw ex.rethrowFromSystemServer();
        }
    }
```
- 1.遍历每一个ProviderInfo，并且调用installProvider生成对应ContentProvider
- 2.跨进程调用AMS的publishContentProviders方法。

####  installProvider 生成ContentProvider

注意这个方法由于支持不同的应用CP的创建，这里的Context不一定是本进程，ContentProviderHolder包含的进程信息也不一定的本进程，因此会做重要的特殊处理：
```java
    private ContentProviderHolder installProvider(Context context,
            ContentProviderHolder holder, ProviderInfo info,
            boolean noisy, boolean noReleaseNeeded, boolean stable) {
        ContentProvider localProvider = null;
        IContentProvider provider;
        if (holder == null || holder.provider == null) {

            Context c = null;
            ApplicationInfo ai = info.applicationInfo;
            if (context.getPackageName().equals(ai.packageName)) {
                c = context;
            } else if (mInitialApplication != null &&
                    mInitialApplication.getPackageName().equals(ai.packageName)) {
                c = mInitialApplication;
            } else {
                try {
                    c = context.createPackageContext(ai.packageName,
                            Context.CONTEXT_INCLUDE_CODE);
                } catch (PackageManager.NameNotFoundException e) {
                    // Ignore
                }
            }
            if (c == null) {

                return null;
            }

            if (info.splitName != null) {
                try {
                    c = c.createContextForSplit(info.splitName);
                } catch (NameNotFoundException e) {
                    throw new RuntimeException(e);
                }
            }

            try {
                final java.lang.ClassLoader cl = c.getClassLoader();
                LoadedApk packageInfo = peekPackageInfo(ai.packageName, true);
                if (packageInfo == null) {

                    packageInfo = getSystemContext().mPackageInfo;
                }
                localProvider = packageInfo.getAppFactory()
                        .instantiateProvider(cl, info.name);
                provider = localProvider.getIContentProvider();
                if (provider == null) {

                    return null;
                }

                localProvider.attachInfo(c, info);
            } catch (java.lang.Exception e) {
...
                return null;
            }
        } else {
            provider = holder.provider;

        }

        ContentProviderHolder retHolder;

        synchronized (mProviderMap) {

            IBinder jBinder = provider.asBinder();
            if (localProvider != null) {
                ComponentName cname = new ComponentName(info.packageName, info.name);
                ProviderClientRecord pr = mLocalProvidersByName.get(cname);
                if (pr != null) {

                    provider = pr.mProvider;
                } else {
                    holder = new ContentProviderHolder(info);
                    holder.provider = provider;
                    holder.noReleaseNeeded = true;
                    pr = installProviderAuthoritiesLocked(provider, localProvider, holder);
                    mLocalProviders.put(jBinder, pr);
                    mLocalProvidersByName.put(cname, pr);
                }
                retHolder = pr.mHolder;
            } else {
....
            }
        }
        return retHolder;
    }
```
- 1.如果此时ContentProviderHolder为空，或者ContentProviderHolder中的CP为空，说明需要初始化。会根据ProviderInfo中保存的包名信息创造如下三种Context：
  - 1.1.如果包名和下传的Context 上下文的包名一致，CP则使用这个Context创建
  - 1.2.如果Context不一致，则判断执行的当前进程的包名和ProviderInfo的包名是否一致，一致则取mInitialApplication当前进程的Application的Context为CP的上下文
  - 1.3.剩下的情况就是，为CP对应的包名创建一个自己的上下文Context对象。

- 2.从LoadedApk的缓存中获取是否有加载的其他apk的包名对应的LoadedApk对象。LoadedApk其实就是指Apk加载到内存后的对象，详细可以阅读[ActivityThread的初始化](https://www.jianshu.com/p/2b1d43ffeba6)。找不到则使用系统Context的包名的LoadedApk对象。使用LoadedApk的AppFactory反射实例化ContentProvider对象。

- 3.获取ContentProvider中的IContentProvider对象，并调用ContentProvider的attachInfo方法。

- 4.如果此时创建出来的CP不为空。
  - 4.1.通过当前CP的包名信息ComponentName从缓存mLocalProvidersByName获取ProviderClientRecord对象。
    - 4.1.1.如果能从缓存中获取，IContentProvider则获取ProviderClientRecord中的mProvider对象。
    - 4.1.2.如果无法从缓存中获取，则新创建ContentProviderHolder对象，并为该对象赋值CP的IContentProvider Binder对象。
    - 4.1.3.installProviderAuthoritiesLocked 使用 IContentProvider，CP创建ProviderClientRecord，最后把ProviderClientRecord缓存到mLocalProvidersByName中。

来看看ContentProvider的attachInfo，以及installProviderAuthoritiesLocked。

有一个核心的方法，getIContentProvider方法获取IContentProvider Binder对象，先来看看这个方法做了什么？

#### 位于ContentProvider中的Binder对象 Transport
```java

    private Transport mTransport = new Transport();

    public IContentProvider getIContentProvider() {
        return mTransport;
    }
```
这个对象实际上就是Transport。
```java
class Transport extends ContentProviderNative
```
他实际上就是一个派生于ContentProviderNative的Transport对象。所有跨进程通信都是通过这个内部类，通信外部的ContentProvider的。


#### ContentProvider attachInfo

```java
    public void attachInfo(Context context, ProviderInfo info) {
        attachInfo(context, info, false);
    }

    private void attachInfo(Context context, ProviderInfo info, boolean testing) {
        mNoPerms = testing;

        /*
         * Only allow it to be set once, so after the content service gives
         * this to us clients can't change it.
         */
        if (mContext == null) {
            mContext = context;
            if (context != null) {
                mTransport.mAppOpsManager = (AppOpsManager) context.getSystemService(
                        Context.APP_OPS_SERVICE);
            }
            mMyUid = Process.myUid();
            if (info != null) {
                setReadPermission(info.readPermission);
                setWritePermission(info.writePermission);
                setPathPermissions(info.pathPermissions);
                mExported = info.exported;
                mSingleUser = (info.flags & ProviderInfo.FLAG_SINGLE_USER) != 0;
                setAuthorities(info.authority);
            }
            ContentProvider.this.onCreate();
        }
    }
```
能看到这里面做了两件很重要的事情：
- 1.从PMS解析出来的ProviderInfo中获取装载CP的权限
- 2.调用ContentProvider的onCreate方法。

#### ActivityThread installProviderAuthoritiesLocked
```java
    private ProviderClientRecord installProviderAuthoritiesLocked(IContentProvider provider,
            ContentProvider localProvider, ContentProviderHolder holder) {
        final String auths[] = holder.info.authority.split(";");
        final int userId = UserHandle.getUserId(holder.info.applicationInfo.uid);

        if (provider != null) {
            // If this provider is hosted by the core OS and cannot be upgraded,
            // then I guess we're okay doing blocking calls to it.
            for (String auth : auths) {
                switch (auth) {
                    case ContactsContract.AUTHORITY:
                    case CallLog.AUTHORITY:
                    case CallLog.SHADOW_AUTHORITY:
                    case BlockedNumberContract.AUTHORITY:
                    case CalendarContract.AUTHORITY:
                    case Downloads.Impl.AUTHORITY:
                    case "telephony":
                        Binder.allowBlocking(provider.asBinder());
                }
            }
        }

        final ProviderClientRecord pcr = new ProviderClientRecord(
                auths, provider, localProvider, holder);
        for (String auth : auths) {
            final ProviderKey key = new ProviderKey(auth, userId);
            final ProviderClientRecord existing = mProviderMap.get(key);
            if (existing != null) {
...
            } else {
                mProviderMap.put(key, pcr);
            }
        }
        return pcr;
    }
```
- 1.如果当前的CP中的权限是：联系方式，下载，日历等，则说明这个CP是由系统托管且不能升级，则允许阻塞调用。
- 2.创建一个ProviderClientRecord对象，获取当前CP中所有的权限和当前userID生成一个Key，保存到mProviderMap中。

这个缓存相当于可以通过CP的权限协议，快速找到ProviderClientRecord对象。

### AMS publishContentProviders
当App端生成并保存好缓存后，则调用AMS的publishContentProviders。
```java
    public final void publishContentProviders(IApplicationThread caller,
            List<ContentProviderHolder> providers) {
        if (providers == null) {
            return;
        }


        synchronized (this) {
            final ProcessRecord r = getRecordForAppLocked(caller);

            final long origId = Binder.clearCallingIdentity();

            final int N = providers.size();
            for (int i = 0; i < N; i++) {
                ContentProviderHolder src = providers.get(i);
                if (src == null || src.info == null || src.provider == null) {
                    continue;
                }
                ContentProviderRecord dst = r.pubProviders.get(src.info.name);

                if (dst != null) {
                    ComponentName comp = new ComponentName(dst.info.packageName, dst.info.name);
                    mProviderMap.putProviderByClass(comp, dst);
                    String names[] = dst.info.authority.split(";");
                    for (int j = 0; j < names.length; j++) {
                        mProviderMap.putProviderByName(names[j], dst);
                    }

                    int launchingCount = mLaunchingProviders.size();
                    int j;
                    boolean wasInLaunchingProviders = false;
                    for (j = 0; j < launchingCount; j++) {
                        if (mLaunchingProviders.get(j) == dst) {
                            mLaunchingProviders.remove(j);
                            wasInLaunchingProviders = true;
                            j--;
                            launchingCount--;
                        }
                    }
                    if (wasInLaunchingProviders) {
                        mHandler.removeMessages(CONTENT_PROVIDER_PUBLISH_TIMEOUT_MSG, r);
                    }
                    synchronized (dst) {
                        dst.provider = src.provider;
                        dst.proc = r;
                        dst.notifyAll();
                    }
                    updateOomAdjLocked(r, true);
                    maybeUpdateProviderUsageStatsLocked(r, src.info.packageName,
                            src.info.authority);
                }
            }

            Binder.restoreCallingIdentity(origId);
        }
    }
```
- 1. mProviderMap 中做了两级缓存：
  - 1.1.以当前的实例化好的CP包名为key，把保存在ContentProviderHolder的ContentProviderRecord保存起来。
  - 1.2.以当前的实例化好的CP权限协议为key，把保存在ContentProviderHolder的ContentProviderRecord保存起来。

- 2.如果mLaunchingProviders 不为空，且当前启动的CP是正在启动的mLaunchingProviders中一员，则移除CONTENT_PROVIDER_PUBLISH_TIMEOUT_MSG这个CP的ANR消息。这个时间是10秒。埋入的时机是进入attachApplicationLocked方法，也就是跨进程调用Activitythread的bindApplication之前：
```java
        List<ProviderInfo> providers = normalMode ? generateApplicationProvidersLocked(app) : null;

        if (providers != null && checkAppInLaunchingProvidersLocked(app)) {
            Message msg = mHandler.obtainMessage(CONTENT_PROVIDER_PUBLISH_TIMEOUT_MSG);
            msg.obj = app;
            mHandler.sendMessageDelayed(msg, CONTENT_PROVIDER_PUBLISH_TIMEOUT);
        }
```

- 3.更新App应用的adj优先级。

正是因为在App进程调用Application的onCreate之后会尝试启动本进程中的CP组件，所以想头条的AndroidAutoSize才能没有在Application中写注册代码就能获取到当前应用的上下文。

## 通过getContentResolver 创建CP

通过getContentResolver 获取CP对象是我们更加常用的方式。一般使用方法如下：
```java
 Cursor cursor = null;
cursor = getContentResolver().query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                null, null, null, null);
```
通过getContentResolver获取到CP对象后，调用query查询本进程或者其他进程通过CP开放的数据(一般来说就是数据库的数据)。通过Cursor 游标遍历获取的数据集中的数据。

```java
    public ContentResolver getContentResolver() {
        return mContentResolver;
    }
```
那么mContentResolver这个对象又是从哪里什么时候创建的呢？
```java
    private ContextImpl(@Nullable ContextImpl container, @NonNull ActivityThread mainThread,
            @NonNull LoadedApk packageInfo, @Nullable String splitName,
            @Nullable IBinder activityToken, @Nullable UserHandle user, int flags,
            @Nullable ClassLoader classLoader) {
....
        mContentResolver = new ApplicationContentResolver(this, mainThread);
    }
```
实际上我们操作的就是ApplicationContentResolver对象,这个对象继承于ContentResolver。

```java
private static final class ApplicationContentResolver extends ContentResolver 
```

我们先跟着ContentResolver的query，看看它做了什么事情

### ContentResolver query
```java
    public final @Nullable Cursor query(@RequiresPermission.Read @NonNull Uri uri,
            @Nullable String[] projection, @Nullable String selection,
            @Nullable String[] selectionArgs, @Nullable String sortOrder) {
        return query(uri, projection, selection, selectionArgs, sortOrder, null);
    }

    public final @Nullable Cursor query(@RequiresPermission.Read @NonNull Uri uri,
            @Nullable String[] projection, @Nullable String selection,
            @Nullable String[] selectionArgs, @Nullable String sortOrder,
            @Nullable CancellationSignal cancellationSignal) {
        Bundle queryArgs = createSqlQueryBundle(selection, selectionArgs, sortOrder);
        return query(uri, projection, queryArgs, cancellationSignal);
    }

    public final @Nullable Cursor query(final @RequiresPermission.Read @NonNull Uri uri,
            @Nullable String[] projection, @Nullable Bundle queryArgs,
            @Nullable CancellationSignal cancellationSignal) {
        Preconditions.checkNotNull(uri, "uri");
        IContentProvider unstableProvider = acquireUnstableProvider(uri);
        if (unstableProvider == null) {
            return null;
        }
        IContentProvider stableProvider = null;
        Cursor qCursor = null;
        try {
            long startTime = SystemClock.uptimeMillis();

....
            try {
                qCursor = unstableProvider.query(mPackageName, uri, projection,
                        queryArgs, remoteCancellationSignal);
            } catch (DeadObjectException e) {

                unstableProviderDied(unstableProvider);
                stableProvider = acquireProvider(uri);
                if (stableProvider == null) {
                    return null;
                }
                qCursor = stableProvider.query(
                        mPackageName, uri, projection, queryArgs, remoteCancellationSignal);
            }
            if (qCursor == null) {
                return null;
            }


            qCursor.getCount();
            long durationMillis = SystemClock.uptimeMillis() - startTime;
      ...
            final IContentProvider provider = (stableProvider != null) ? stableProvider
                    : acquireProvider(uri);
            final CursorWrapperInner wrapper = new CursorWrapperInner(qCursor, provider);
            stableProvider = null;
            qCursor = null;
            return wrapper;
        } catch (RemoteException e) {

            return null;
        } finally {
            if (qCursor != null) {
                qCursor.close();
            }
            if (cancellationSignal != null) {
                cancellationSignal.setRemote(null);
            }
            if (unstableProvider != null) {
                releaseUnstableProvider(unstableProvider);
            }
            if (stableProvider != null) {
                releaseProvider(stableProvider);
            }
        }
    }
```
- 1.acquireUnstableProvider 先获取一个先从ActivityThread中获取一个IContentProvider Binder对象
- 2.调用IContentProvider的query方法。
- 3.如果query方法爆出了Binder死亡异常的错误，先调用unstableProviderDied销毁原来的对象，再一次调用acquireProvider方法获取IContentProvider对象，再进行一次query的方法，查询数据结果。
- 4.stableProvider为空，也就说没有经过弥补查询的过程，则调用acquireProvider获取IContentProvider对象，并把获取到的数据浮标Cursor和IContentProvider封装成CursorWrapperInner返回。

- 5.如果stableProvider不为空，说明出现过异常，弥补了异常，直接使用stableProvider封装成CursorWrapperInner返回。

核心的方法有三个：
- 1.acquireUnstableProvider 获取IContentProvider
- 2.acquireProvider 获取IContentProvider
- 3.IContentProvider的query方法。

#### acquireProvider和acquireUnstableProvider
在ContentResolver中：
```java
    public final IContentProvider acquireUnstableProvider(Uri uri) {
        if (!SCHEME_CONTENT.equals(uri.getScheme())) {
            return null;
        }
        String auth = uri.getAuthority();
        if (auth != null) {
            return acquireUnstableProvider(mContext, uri.getAuthority());
        }
        return null;
    }

    public final IContentProvider acquireProvider(Uri uri) {
        if (!SCHEME_CONTENT.equals(uri.getScheme())) {
            return null;
        }
        final String auth = uri.getAuthority();
        if (auth != null) {
            return acquireProvider(mContext, auth);
        }
        return null;
    }
```
核心的实现还是它的派生类ApplicationContentResolver

```java
        @Override
        protected IContentProvider acquireUnstableProvider(Context c, String auth) {
            return mMainThread.acquireProvider(c,
                    ContentProvider.getAuthorityWithoutUserId(auth),
                    resolveUserIdFromAuthority(auth), false);
        }


        @Override
        protected IContentProvider acquireProvider(Context context, String auth) {
            return mMainThread.acquireProvider(context,
                    ContentProvider.getAuthorityWithoutUserId(auth),
                    resolveUserIdFromAuthority(auth), true);
        }

```
能看到这两个方法最后都是调用了ActivityThread的acquireProvider方法。

##### ActivityThread acquireProvider

```java
    public final IContentProvider acquireProvider(
            Context c, String auth, int userId, boolean stable) {
        final IContentProvider provider = acquireExistingProvider(c, auth, userId, stable);
        if (provider != null) {
            return provider;
        }


        ContentProviderHolder holder = null;
        try {
            synchronized (getGetProviderLock(auth, userId)) {
                holder = ActivityManager.getService().getContentProvider(
                        getApplicationThread(), auth, userId, stable);
            }
        } catch (RemoteException ex) {
            throw ex.rethrowFromSystemServer();
        }
        if (holder == null) {
            Slog.e(TAG, "Failed to find provider info for " + auth);
            return null;
        }

        holder = installProvider(c, holder, holder.info,
                true /*noisy*/, holder.noReleaseNeeded, stable);
        return holder.provider;
    }

    private Object getGetProviderLock(String auth, int userId) {
        final ProviderKey key = new ProviderKey(auth, userId);
        synchronized (mGetProviderLocks) {
            Object lock = mGetProviderLocks.get(key);
            if (lock == null) {
                lock = key;
                mGetProviderLocks.put(key, lock);
            }
            return lock;
        }
    }
```

- 1.首先通过acquireExistingProvider 使用CP的uri权限获取已经保存在mProviderMap缓存好的IContentProvider对象，增加引用计数。如果找到了IContentProvider对象，则直接返回。
```java
    public final IContentProvider acquireExistingProvider(
            Context c, String auth, int userId, boolean stable) {
        synchronized (mProviderMap) {
            final ProviderKey key = new ProviderKey(auth, userId);
            final ProviderClientRecord pr = mProviderMap.get(key);
            if (pr == null) {
                return null;
            }

            IContentProvider provider = pr.mProvider;
            IBinder jBinder = provider.asBinder();
            if (!jBinder.isBinderAlive()) {

                handleUnstableProviderDiedLocked(jBinder, true);
                return null;
            }

            ProviderRefCount prc = mProviderRefCountMap.get(jBinder);
            if (prc != null) {
                incProviderRefLocked(prc, stable);
            }
            return provider;
        }
    }
```

- 2.如果当前进程不存在一个IContentProvider对象，说明当前CP对象是其他进程提供的，或者是当前的进程还有启动这个CP对象。那么通过auth从mGetProviderLocks获取一个互斥锁，通过AMS跨进程获取ContentProviderHolder对象，接着通过installProvider把这个CP对象装载在本进程中。

#### AMS getContentProvider
```java
    public final ContentProviderHolder getContentProvider(
            IApplicationThread caller, String name, int userId, boolean stable) {
        enforceNotIsolatedCaller("getContentProvider");
...
        return getContentProviderImpl(caller, name, null, stable, userId);
    }
```
从AMS获取一个ContentProviderHolder对象核心还是getContentProviderImpl

##### getContentProviderImpl
下面这个方法很长，我们分为几个阶段来聊聊。
```java
    private ContentProviderHolder getContentProviderImpl(IApplicationThread caller,
            String name, IBinder token, boolean stable, int userId) {
        ContentProviderRecord cpr;
        ContentProviderConnection conn = null;
        ProviderInfo cpi = null;

        synchronized(this) {
            long startTime = SystemClock.uptimeMillis();

            ProcessRecord r = null;
            if (caller != null) {
                r = getRecordForAppLocked(caller);
...
            }

            boolean checkCrossUser = true;

     

            cpr = mProviderMap.getProviderByName(name, userId);

...
            boolean providerRunning = cpr != null && cpr.proc != null && !cpr.proc.killed;
            if (providerRunning) {
                cpi = cpr.info;
                String msg;

...

                if (r != null && cpr.canRunHere(r)) {

                    holder.provider = null;
                    return holder;
                }
               
                try {
                    if (AppGlobals.getPackageManager()
                            .resolveContentProvider(name, 0 /*flags*/, userId) == null) {
                        return null;
                    }
                } catch (RemoteException e) {
                }

                final long origId = Binder.clearCallingIdentity();

                conn = incProviderCountLocked(r, cpr, token, stable);
                if (conn != null && (conn.stableCount+conn.unstableCount) == 1) {
                    if (cpr.proc != null && r.setAdj <= ProcessList.PERCEPTIBLE_APP_ADJ) {

                        updateLruProcessLocked(cpr.proc, false, null);

                    }
                }

                final int verifiedAdj = cpr.proc.verifiedAdj;
                boolean success = updateOomAdjLocked(cpr.proc, true);

                if (success && verifiedAdj != cpr.proc.setAdj && !isProcessAliveLocked(cpr.proc)) {
                    success = false;
                }
                maybeUpdateProviderUsageStatsLocked(r, cpr.info.packageName, name);
 ...
                Binder.restoreCallingIdentity(origId);
            }

...
    }
```
- 1. 首先先从mProviderMap，通过权限名和userId查找AMS中已经启动的ContentProviderRecord对象。注意在ProviderMap有4层缓存：
```java
    private final HashMap<String, ContentProviderRecord> mSingletonByName
            = new HashMap<String, ContentProviderRecord>();
    private final HashMap<ComponentName, ContentProviderRecord> mSingletonByClass
            = new HashMap<ComponentName, ContentProviderRecord>();

    private final SparseArray<HashMap<String, ContentProviderRecord>> mProvidersByNamePerUser
            = new SparseArray<HashMap<String, ContentProviderRecord>>();
    private final SparseArray<HashMap<ComponentName, ContentProviderRecord>> mProvidersByClassPerUser
            = new SparseArray<HashMap<ComponentName, ContentProviderRecord>>();
```
能通过Class的包名查找ContentProviderRecord，能直接通过name也就是CP的权限名查找ContentProviderRecord。

如果在这两个缓存中找不到，说明ContentProviderRecord对象会根据userID作为key 保存在SparseArray集合中。可以通过userId在对应的应用查找启动过的CP对象

注意此时调用query的时候传入的是一个uri格式，会获取uri的authority部分作为线索在AMS中查找缓存。同样的userId也是从authority中获取。也就是说如果想要对着某一个userID的缓存下查询CP对象,权限就要符合下面的格式:
```java
userId@authority
```
会截取@之前的数字作为userId。

接下来就会根据ProviderMap的结果，得到此时需要当前需要访问的CP是否还存活？


###### CP 对象存活
```java
            if (providerRunning) {
                cpi = cpr.info;
                String msg;

...

                if (r != null && cpr.canRunHere(r)) {

                    ContentProviderHolder holder = cpr.newHolder(null);

                    holder.provider = null;
                    return holder;
                }

                try {
                    if (AppGlobals.getPackageManager()
                            .resolveContentProvider(name, 0 /*flags*/, userId) == null) {
                        return null;
                    }
                } catch (RemoteException e) {
                }

                final long origId = Binder.clearCallingIdentity();


                conn = incProviderCountLocked(r, cpr, token, stable);
                if (conn != null && (conn.stableCount+conn.unstableCount) == 1) {
                    if (cpr.proc != null && r.setAdj <= ProcessList.PERCEPTIBLE_APP_ADJ) {
                        updateLruProcessLocked(cpr.proc, false, null);

                    }
                }

                final int verifiedAdj = cpr.proc.verifiedAdj;
                boolean success = updateOomAdjLocked(cpr.proc, true);

....
            }
```
- 1.则调用ContentProviderRecord.canRunHere,校验CP对象是否能在调用方的进程运行

- 2.如果可以则ContentProviderRecord.newHolder 生成一个ContentProviderHolder，设置其中的provider为空返回。

- 3.增加引用计数，更新进程的adj优先级

###### ContentProviderRecord canRunHere
```java
    public boolean canRunHere(ProcessRecord app) {
        return (info.multiprocess || info.processName.equals(app.processName))
                && uid == app.info.uid;
    }
```
是否允许运行在当前进程，满足两个条件其一即可：
- 1.`android:multiprocess="true"`在AndroidManifest中打开这个设置，允许CP在另外一个进程运行
- 2.uid一致且进程名一致

如果是允许多进程执行，那就不关心这个CP运行在哪一个进程了，直接返回ContentProviderHolder。注意如果android:multiprocess没有打开，就如同系统查询手机联系人一样：
```java
        <provider android:name="CallLogProvider"
            android:authorities="call_log"
            android:syncable="false" android:multiprocess="false"
            android:exported="true"
            android:readPermission="android.permission.READ_CALL_LOG"
            android:writePermission="android.permission.WRITE_CALL_LOG">
        </provider>
```
它不允许多进程运行，必须是当前进程执行。那么会直接到了方法最底部直接调用ContentProviderRecord.newHolder返回，不同的是传入了ContentProviderConnection

###### ContentProviderRecord newHolder
```java
    public ContentProviderHolder newHolder(ContentProviderConnection conn) {
        ContentProviderHolder holder = new ContentProviderHolder(info);
        holder.provider = provider;
        holder.noReleaseNeeded = noReleaseNeeded;
        holder.connection = conn;
        return holder;
    }
```
返回了IContentProvider对象以及传入一个ContentProviderConnection对象，此时是空，我们暂时不去考虑。


##### CP对象还没有启动

如果通过权限没办法找到对应的ContentProviderRecord对象，说明很可能没有启动.

```java
            if (!providerRunning) {
                try {

                    cpi = AppGlobals.getPackageManager().
                        resolveContentProvider(name,
                            STOCK_PM_FLAGS | PackageManager.GET_URI_PERMISSION_PATTERNS, userId);

                } catch (RemoteException ex) {
                }
                if (cpi == null) {
                    return null;
                }

                boolean singleton = isSingleton(cpi.processName, cpi.applicationInfo,
                        cpi.name, cpi.flags)
                        && isValidSingletonCall(r.uid, cpi.applicationInfo.uid);
                if (singleton) {
                    userId = UserHandle.USER_SYSTEM;
                }
                cpi.applicationInfo = getAppInfoForUser(cpi.applicationInfo, userId);


                String msg;

                if ((msg = checkContentProviderPermissionLocked(cpi, r, userId, !singleton))
                        != null) {
                    throw new SecurityException(msg);
                }


                if (!mProcessesReady
                        && !cpi.processName.equals("system")) {

                    throw new IllegalArgumentException(
                            "Attempt to launch content provider before system ready");
                }

...

                ComponentName comp = new ComponentName(cpi.packageName, cpi.name);

                cpr = mProviderMap.getProviderByClass(comp, userId);

                final boolean firstClass = cpr == null;
                if (firstClass) {
                    final long ident = Binder.clearCallingIdentity();
...
                    try {

                        ApplicationInfo ai =
                            AppGlobals.getPackageManager().
                                getApplicationInfo(
                                        cpi.applicationInfo.packageName,
                                        STOCK_PM_FLAGS, userId);
  
                        if (ai == null) {
                            return null;
                        }
                        ai = getAppInfoForUser(ai, userId);
                        cpr = new ContentProviderRecord(this, cpi, ai, comp, singleton);
                    } catch (RemoteException ex) {
                        // pm is in same process, this will never happen.
                    } finally {
                        Binder.restoreCallingIdentity(ident);
                    }
                }

                if (r != null && cpr.canRunHere(r)) {
                    return cpr.newHolder(null);
                }
....
                final int N = mLaunchingProviders.size();
                int i;
                for (i = 0; i < N; i++) {
                    if (mLaunchingProviders.get(i) == cpr) {
                        break;
                    }
                }


                if (i >= N) {
                    final long origId = Binder.clearCallingIdentity();

                    try {
...
                        ProcessRecord proc = getProcessRecordLocked(
                                cpi.processName, cpr.appInfo.uid, false);
                        if (proc != null && proc.thread != null && !proc.killed) {

                            if (!proc.pubProviders.containsKey(cpi.name)) {

                                proc.pubProviders.put(cpi.name, cpr);
                                try {
                                    proc.thread.scheduleInstallProvider(cpi);
                                } catch (RemoteException e) {
                                }
                            }
                        } else {

                            proc = startProcessLocked(cpi.processName,
                                    cpr.appInfo, false, 0, "content provider",
                                    new ComponentName(cpi.applicationInfo.packageName,
                                            cpi.name), false, false, false);

                            if (proc == null) {

                                return null;
                            }
                        }
                        cpr.launchingApp = proc;
                        mLaunchingProviders.add(cpr);
                    } finally {
                        Binder.restoreCallingIdentity(origId);
                    }
                }

                if (firstClass) {
                    mProviderMap.putProviderByClass(comp, cpr);
                }

                mProviderMap.putProviderByName(name, cpr);
                conn = incProviderCountLocked(r, cpr, token, stable);
                if (conn != null) {
                    conn.waiting = true;
                }
            }

            grantEphemeralAccessLocked(userId, null /*intent*/,
                    cpi.applicationInfo.uid, UserHandle.getAppId(Binder.getCallingUid()));
        }
```
- 1.首先resolveContentProvider从PMS中获取AndroidManifest中解析出对应的ProviderInfo对象。

- 2.通过ProviderInfo，获取其中的包名和类名,判断是否希望启动系统唯一的CP独享,但是发现运行的程序不是系统且没有运行则会报错。

- 3.根据ProviderInfo中保存的包名和类名从ProviderMap中查找是否有启动过的ContentProviderRecord对象。

- 4.通过AMS获取ProviderInfo的应用信息，根据应用信息和ProviderInfo生成ContentProviderRecord对象。接着校验ContentProviderRecord是否可以在调用进程运行，如果可以则返回ContentProviderHolder，在App进程生成CP对象。

- 5.接下来就是如果不可以在调用进程运行，说明此时这个不是该应用的CP注册没有打开多进程的标志。
  - 5.1.那么遍历mLaunchingProviders中是否存在现在需要启动的ContentProviderRecord对象。
    - 5.1.1.如果有，说明正在启动的CP对应的进程正在启动或者进程还在存活正在装载CP对象，此时则直接返回ContentProviderHolder。

- 6.如果没有在mLaunchingProviders找到CP对应的进程正在启动，进一步的判断这个进程是否还存活：
  - 6.1.如果当前的进程还存活，进程对象ProcessRecord的pubProviders保存当前的ProviderInfo的包名，并且调用scheduleInstallProvider方法。
  - 6.2.如果当前进程已经死亡了，那么就会调用startProcessLocked，先启动进程，接着mLaunchingProviders保存当前的ContentProviderRecord，mProviderMap根据权限保存当前的ContentProviderRecord对象，接着执行下面这段代码：

```java

        synchronized (cpr) {
            while (cpr.provider == null) {
                if (cpr.launchingApp == null) {

                    return null;
                }
                try {

                    if (conn != null) {
                        conn.waiting = true;
                    }
                    cpr.wait();
                } catch (InterruptedException ex) {
                } finally {
                    if (conn != null) {
                        conn.waiting = false;
                    }
                }
            }
        }
        return cpr != null ? cpr.newHolder(conn) : null;
```
这一段代码很简单，如果是因为启动CP对象，而需要启动的进程，就会把ContentProviderRecord作为Montor监控器，阻塞这个线程，等待CP所属的进程启动完成。


对于CP还没有运行起来，这里就分为两个大逻辑：
- 1.CP所属进程还存活，就会调用scheduleInstallProvider安装CP对象
- 2.CP的进程不存活，则会阻塞当前的进程，知道进程启动成功后唤醒，才会继续返回方法。

返回之后调用installProvider方法

##### ActivityThread scheduleInstallProvider

这个方法最后调用handleInstallProvider方法
```java
    public void handleInstallProvider(ProviderInfo info) {
        final StrictMode.ThreadPolicy oldPolicy = StrictMode.allowThreadDiskWrites();
        try {
            installContentProviders(mInitialApplication, Arrays.asList(info));
        } finally {
            StrictMode.setThreadPolicy(oldPolicy);
        }
    }
```

##### CP所属的App进程启动后唤醒，AMS的阻塞
这一段其实就是当App进程启动后，调用installProvider装载好CP之后，调用publishContentProviders方法，跨进程调用AMS的publishContentProviders：
```java
    public final void publishContentProviders(IApplicationThread caller,
            List<ContentProviderHolder> providers) {
        if (providers == null) {
            return;
        }

        enforceNotIsolatedCaller("publishContentProviders");
        synchronized (this) {
...
            final long origId = Binder.clearCallingIdentity();

            final int N = providers.size();
            for (int i = 0; i < N; i++) {
...
                if (dst != null) {
...
                    int launchingCount = mLaunchingProviders.size();
                    int j;
                    boolean wasInLaunchingProviders = false;
                    for (j = 0; j < launchingCount; j++) {
                        if (mLaunchingProviders.get(j) == dst) {
                            mLaunchingProviders.remove(j);
                            wasInLaunchingProviders = true;
                            j--;
                            launchingCount--;
                        }
                    }
                    if (wasInLaunchingProviders) {
                        mHandler.removeMessages(CONTENT_PROVIDER_PUBLISH_TIMEOUT_MSG, r);
                    }
                    synchronized (dst) {
                        dst.provider = src.provider;
                        dst.proc = r;
                        dst.notifyAll();
                    }
....
                }
            }

            Binder.restoreCallingIdentity(origId);
        }
    }
```
就是在这里，当CP所属进程绑定好Application之后，publishContentProviders查询之前在getContentProviderImpl添加到mLaunchingProviders集合中的ContentProviderRecord对象。调用ContentProviderRecord的notifyAll，唤醒还在等待的调用端。



  - 2.接着通过Context中的ClassLoader，反射生成CP对象。注意这里反射的时候是使用系统Context的AppFactory，也就是说无法使用自定义的AppFactory做特殊处理。

- 3.最后保存到本地缓存mLocalProviders中，并生成新的ContentProviderHolder返回给AMS中进行缓存。


这个过程是不是很熟悉，其实就是插件化的核心原理，关于插件化的原理可以阅读我写的[横向浅析Small,RePlugin两个插件化框架](https://www.jianshu.com/p/d824056f510b)实际上就是从这里获取到灵感的。



#### CP 调用query查询数据

我们继续`getContentResolve().query`方法的流程，当准备好之后CP对象后，就调用ContentProvider中的Transport对象的query方法进行查询：
```java
        public Cursor query(String callingPkg, Uri uri, @Nullable String[] projection,
                @Nullable Bundle queryArgs, @Nullable ICancellationSignal cancellationSignal) {
            validateIncomingUri(uri);
            uri = maybeGetUriWithoutUserId(uri);
            if (enforceReadPermission(callingPkg, uri, null) != AppOpsManager.MODE_ALLOWED) {

                if (projection != null) {
                    return new MatrixCursor(projection, 0);
                }

                Cursor cursor = ContentProvider.this.query(
                        uri, projection, queryArgs,
                        CancellationSignal.fromTransport(cancellationSignal));
                if (cursor == null) {
                    return null;
                }

                return new MatrixCursor(cursor.getColumnNames(), 0);
            }
            final String original = setCallingPackage(callingPkg);
            try {
                return ContentProvider.this.query(
                        uri, projection, queryArgs,
                        CancellationSignal.fromTransport(cancellationSignal));
            } finally {
                setCallingPackage(original);
            }
        }
```
在查询的时候会校验，当前CP是否设置了`android:readPermission`读取权限，如果设置了需要进行校验才能进行查询。同理增删改三个操作则是需要设置`android:writePermission`写入权限是否设置并允许。

如果此时不允许，且搜索的行列不为空，返回一个空数据的MatrixCursor。如果调用了query之后查询到的浮标是空则返回空。否则返回带了所有列名的空数据浮标

如果允许则调用ContentProvider的query方法，直接返回。在这里直接返回了Cursor 包含数据窗口的浮标。如果是SQLCursor的实现，那么就是来自sqlite数据库的数据。

当时进行SQLCursor查询的时候，会把索引填充好在整个CursorWindow中，等待浮标的移动进行查询。


## 总结与思考

CP的启动可以分为如下三种情况：

### CP 异进程的启动与安装小结
本应用的CP在本应用中是如何安装，这个很简单。就是在Application 绑定之后，调用installProvider实例化每一个来自本应用中所有在AndroidManifest的privder标签。如下图：
![本应用的ContentProvider在本应用启动.png](/images/本应用的ContentProvider在本应用启动.png)


真正可能让人弄迷糊的问题就是，客户端应用需要访问一个不属于客户端应用的CP对象。

可以分为两个情况，一个是添加了`android:multiprocess="true"`的CP，一个是没有。

- 对于没有打开多进程标签，也会生成一个ContentProviderHolder对象，保存到mLauncherProviders集合中，并阻塞获取ContentProviderHolder对象的流程。
  - 然后等到启动CP所属真正的进程，实例化好ContentProvider后。再实例化一个ContentProviderHolder对象，不过这个时候ContentProviderHolder就有了Transport 这个Binder对象。
  - 通过AMS的publishContentProviders保存当前CP对应的CP名和ContentProviderHolder对象在ProviderMap中，让之后其他应用可以通过这个Binder通信到CP所属的进程进行数据上的交互。

如图：
![其他应用的CP在不允许多进程启动模式.png](/images/其他应用的CP在不允许多进程启动模式.png)




- 对于打开了多进程标签，会返回一个ContentProviderHolder对象，而这个对象中IContentProvider Binder对象，也就是Transport对象。接下来则比较复杂：
  - 1.在installProvider方法中，先通过createPackageContext，创建出包名对应的Context上下文出来：
```java
    public Context createPackageContextAsUser(String packageName, int flags, UserHandle user)
            throws NameNotFoundException {
        if (packageName.equals("system") || packageName.equals("android")) {
            // The system resources are loaded in every application, so we can safely copy
            // the context without reloading Resources.
            return new ContextImpl(this, mMainThread, mPackageInfo, null, mActivityToken, user,
                    flags, null);
        }

        LoadedApk pi = mMainThread.getPackageInfo(packageName, mResources.getCompatibilityInfo(),
                flags | CONTEXT_REGISTER_PACKAGE, user.getIdentifier());
        if (pi != null) {
            ContextImpl c = new ContextImpl(this, mMainThread, pi, null, mActivityToken, user,
                    flags, null);

            final int displayId = mDisplay != null
                    ? mDisplay.getDisplayId() : Display.DEFAULT_DISPLAY;

            c.setResources(createResources(mActivityToken, pi, null, displayId, null,
                    getDisplayAdjustments(displayId).getCompatibilityInfo()));
            if (c.mResources != null) {
                return c;
            }
        }

        throw new PackageManager.NameNotFoundException(
                "Application package " + packageName + " not found");
    }
```
能看到这个过程很熟悉，就是通过getPackageInfo从PMS中获取包名对应的LoadedApk对象，这个对象就是apk在内存中的表示，接着装载资源到Context中，并返回Context。

如图：
![非本应用的CP打开多进程模式.png](/images/非本应用的CP打开多进程模式.png)


关于资源是如何加载的可以阅读我写的[资源管理系统系列](https://www.jianshu.com/p/817a787910f2)，关于Context和Application是如何绑定可以阅读我写的[ActivityThread的初始化](https://www.jianshu.com/p/2b1d43ffeba6)。



#### 思考

基于CP这种初始化的特殊性，开发者们也在此基础上做了各种奇思妙想。比如说，我不想过多的涉足应用的Application中，可以把初始化放到CP中进行，最经典就是[AndroidAutoSize](https://github.com/JessYanCoding/AndroidAutoSize/blob/master/autosize/src/main/java/me/jessyan/autosize/InitProvider.java)的初始化。当然，我自己在编写自定义腾讯Matrix插件时候也用到这种思路。

RePlugin在管理每一个插件的Binder接口时候，也是包装成一个Cursor返回。

那么为什么Cursor没有实现Binder对象，也能进行数据共享呢？因为在客户端也提供了一个CP对象，把另一个进程的代码和ClassLoader也加载到本进程中。

为什么要这么做？因为CP本身经常和SQLite一起出现，由于Cursor中包含了数据库的浮标。每一次进行数据查询都会填充浮标中的浮标窗口，它的数据量很可能超过了Binder的传输限制，因此Google官方才会这么做。

其实这个CP加载把别的应用apk加载到另一个应用的过程，就是我们常说的插件化。插件化最初的灵感就是来源于此，关于插件化的具体原理，可以阅读[横向浅析Small,RePlugin两个插件化框架](https://www.jianshu.com/p/d824056f510b)


## 后话

关于ContentProvider的启动就到这里了，但是我并没有深入聊CP中链接到数据库的原理，如何查询，数据如何填充CursorWindow的。关于这部分的知识等，后面有机会我们来解析Android的sqlite是如何实现的吧。

还有一句话，如果从重学系列一直跟着阅读到现在的朋友，现在应该可以把我两年前写的插件化原理绝大部分的内容都看懂了。接下来再让我写完最后一个PMS的模块，就可以把写了2年的Android重学系列给完结了。

