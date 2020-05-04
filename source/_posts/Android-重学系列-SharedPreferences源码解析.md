---
title: Android 重学系列 SharedPreferences源码解析
top: false
cover: false
date: 2020-05-04 21:42:22
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
- 性能优化
---
# 前言
分析了[MMKV的源码解析](https://www.jianshu.com/p/c12290a9a3f7)后，我们来看看Android中常用的键值对组件SharedPreferences的实现。究竟源码中出现了什么问题，导致了SharedPreferences的卡顿和ANR呢？

# 正文
关于SharedPreferences的用法，这里就不多赘述了，如果不懂用法的，随意找一篇看一下就好了。我们一般都是通过context获取SharePreferences。
```java
SharedPreferences sharedPreferences = getSharedPreferences("test", Context.MODE_PRIVATE);
```
我们就从这个方法看看究竟做了什么。


## 获取SharedPreferences 实例
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[ContextWrapper.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/ContextWrapper.java)

```java
    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        return mBase.getSharedPreferences(name, mode);
    }
```
这里面的mBase实际上是ContextImpl，这个逻辑的解析可以在资源管理或者ActivityThread的初始化两篇文章中了解到。

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)
```java
    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        if (mPackageInfo.getApplicationInfo().targetSdkVersion <
                Build.VERSION_CODES.KITKAT) {
            if (name == null) {
                name = "null";
            }
        }

        File file;
        synchronized (ContextImpl.class) {
            if (mSharedPrefsPaths == null) {
                mSharedPrefsPaths = new ArrayMap<>();
            }
            file = mSharedPrefsPaths.get(name);
            if (file == null) {
                file = getSharedPreferencesPath(name);
                mSharedPrefsPaths.put(name, file);
            }
        }
        return getSharedPreferences(file, mode);
    }
```
- 1.在每一个ContextWrapper中都会缓存一个mSharedPrefsPaths，这个ArrayMap缓存了SharedPreferences的名字为键，file文件对象为值。如果发现mSharedPrefsPaths没有缓存，则会通过getSharedPreferencesPath创建一个file文件出来。

```java
    private File getPreferencesDir() {
        synchronized (mSync) {
            if (mPreferencesDir == null) {
                mPreferencesDir = new File(getDataDir(), "shared_prefs");
            }
            return ensurePrivateDirExists(mPreferencesDir);
        }
    }

    private File makeFilename(File base, String name) {
        if (name.indexOf(File.separatorChar) < 0) {
            return new File(base, name);
        }
        throw new IllegalArgumentException(
                "File " + name + " contains a path separator");
    }

    @Override
    public File getSharedPreferencesPath(String name) {
        return makeFilename(getPreferencesDir(), name + ".xml");
    }
```
能看到实际上这个文件就是应用目录下的一个xml文件
> data/shared_prefs/+ sp的名字 + .xml

- 2.getSharedPreferences通过file和mode获取SharedPreferences实例。

### getSharedPreferences
```java
    @Override
    public SharedPreferences getSharedPreferences(File file, int mode) {
        SharedPreferencesImpl sp;
        synchronized (ContextImpl.class) {
            final ArrayMap<File, SharedPreferencesImpl> cache = getSharedPreferencesCacheLocked();
            sp = cache.get(file);
            if (sp == null) {
                checkMode(mode);
                if (getApplicationInfo().targetSdkVersion >= android.os.Build.VERSION_CODES.O) {
                    if (isCredentialProtectedStorage()
                            && !getSystemService(UserManager.class)
                                    .isUserUnlockingOrUnlocked(UserHandle.myUserId())) {
                        throw new IllegalStateException("SharedPreferences in credential encrypted "
                                + "storage are not available until after user is unlocked");
                    }
                }
                sp = new SharedPreferencesImpl(file, mode);
                cache.put(file, sp);
                return sp;
            }
        }
        if ((mode & Context.MODE_MULTI_PROCESS) != 0 ||
            getApplicationInfo().targetSdkVersion < android.os.Build.VERSION_CODES.HONEYCOMB) {
            // If somebody else (some other process) changed the prefs
            // file behind our back, we reload it.  This has been the
            // historical (if undocumented) behavior.
            sp.startReloadIfChangedUnexpectedly();
        }
        return sp;
    }
```
- 1.先调用getSharedPreferencesCacheLocked 获取缓存好的SharedPreferencesImpl实例。如果找不到实例，则检查设置的mode是否合法，并且实例化一个新的SharedPreferencesImpl对象，并保存在cache中，同时返回sp对象。
```java
    private ArrayMap<File, SharedPreferencesImpl> getSharedPreferencesCacheLocked() {
        if (sSharedPrefsCache == null) {
            sSharedPrefsCache = new ArrayMap<>();
        }

        final String packageName = getPackageName();
        ArrayMap<File, SharedPreferencesImpl> packagePrefs = sSharedPrefsCache.get(packageName);
        if (packagePrefs == null) {
            packagePrefs = new ArrayMap<>();
            sSharedPrefsCache.put(packageName, packagePrefs);
        }

        return packagePrefs;
    }
```
能看到在ContextImpl的静态变量sSharedPrefsCache中，根据包名缓存了一个以File和SharedPreferencesImpl为键值对的ArrayMap。当前ContextWrapper是从这个静态变量中检查是否缓存了对应的SharedPreferencesImpl对象。

- 2.如果mode是MODE_MULTI_PROCESS 多进程模式，通过api低于3.0则调用sp的startReloadIfChangedUnexpectedly方法。这里比较特殊就不展开讨论了。

### SharedPreferencesImpl 实例化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[SharedPreferencesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/SharedPreferencesImpl.java)

```java
    SharedPreferencesImpl(File file, int mode) {
        mFile = file;
        mBackupFile = makeBackupFile(file);
        mMode = mode;
        mLoaded = false;
        mMap = null;
        mThrowable = null;
        startLoadFromDisk();
    }
```
在这个过程中有两个很重要的过程：
- 1.makeBackupFile 根据当前的xml的file 获取一个备份的file,就是原来file的路径后加一个.bak
```java
    static File makeBackupFile(File prefsFile) {
        return new File(prefsFile.getPath() + ".bak");
    }
```

- 2.startLoadFromDisk 开始从磁盘中加载数据。

```java
    private void startLoadFromDisk() {
        synchronized (mLock) {
            mLoaded = false;
        }
        new Thread("SharedPreferencesImpl-load") {
            public void run() {
                loadFromDisk();
            }
        }.start();
    }
```
能看到此时是新增了一个线程调用loadFromDisk进行磁盘的读取操作。

#### loadFromDisk
```java
    private void loadFromDisk() {
        synchronized (mLock) {
            if (mLoaded) {
                return;
            }
            if (mBackupFile.exists()) {
                mFile.delete();
                mBackupFile.renameTo(mFile);
            }
        }

...

        Map<String, Object> map = null;
        StructStat stat = null;
        Throwable thrown = null;
        try {
            stat = Os.stat(mFile.getPath());
            if (mFile.canRead()) {
                BufferedInputStream str = null;
                try {
                    str = new BufferedInputStream(
                            new FileInputStream(mFile), 16 * 1024);
                    map = (Map<String, Object>) XmlUtils.readMapXml(str);
                } catch (Exception e) {
                    Log.w(TAG, "Cannot read " + mFile.getAbsolutePath(), e);
                } finally {
                    IoUtils.closeQuietly(str);
                }
            }
        } catch (ErrnoException e) {
            // An errno exception means the stat failed. Treat as empty/non-existing by
            // ignoring.
        } catch (Throwable t) {
            thrown = t;
        }

        synchronized (mLock) {
            mLoaded = true;
            mThrowable = thrown;

            // It's important that we always signal waiters, even if we'll make
            // them fail with an exception. The try-finally is pretty wide, but
            // better safe than sorry.
            try {
                if (thrown == null) {
                    if (map != null) {
                        mMap = map;
                        mStatTimestamp = stat.st_mtim;
                        mStatSize = stat.st_size;
                    } else {
                        mMap = new HashMap<>();
                    }
                }
                // In case of a thrown exception, we retain the old map. That allows
                // any open editors to commit and store updates.
            } catch (Throwable t) {
                mThrowable = t;
            } finally {
                mLock.notifyAll();
            }
        }
    }
```

这个方法分为三部分：
- 1.如果mBackupFile存在，说明有备份文件，则把构造函数传递进来的mFile删除，并把mBackupFile移动到为mFile的path。
- 2.先读取当前路径下文件的权限，读取file中xml中所有的存储的键值对数据，保存在一个临时的HashMap中。
- 3.如果发现没有任何的异常，则把临时的map赋值给全局的mMap中，并记录文件下的大小，以及上次一次修改的时间。

记住这里面有一个mLock全局对象十分重要。当没有初始化读取文件中缓存的数据之前，就是通过该对象进行阻塞。

## SharedPreferences 增删查改
### SharedPreferences增加键值对
提一下SharedPreferences是如何进行增删查改的。当获取到SharedPreferences对象后会调用edit方法，实例化一个SharedPreferences.Editor对象。
```java
    @GuardedBy("mLock")
    private void awaitLoadedLocked() {
        if (!mLoaded) {
            BlockGuard.getThreadPolicy().onReadFromDisk();
        }
        while (!mLoaded) {
            try {
                mLock.wait();
            } catch (InterruptedException unused) {
            }
        }
        if (mThrowable != null) {
            throw new IllegalStateException(mThrowable);
        }
    }

    @Override
    public Editor edit() {
        synchronized (mLock) {
            awaitLoadedLocked();
        }

        return new EditorImpl();
    }

```
能看到这这个过程中，实际上会进行一次mLock的阻塞，知道读取磁盘的Thread工作完成后，才能实例化一个新的EditorImpl对象，进行增加键值对的操作。

我们就以增加一个String为例子
```java
private final Object mEditorLock = new Object();

        @GuardedBy("mEditorLock")
        private final Map<String, Object> mModified = new HashMap<>();

        @GuardedBy("mEditorLock")
        private boolean mClear = false;

        @Override
        public Editor putString(String key, @Nullable String value) {
            synchronized (mEditorLock) {
                mModified.put(key, value);
                return this;
            }
        }
```
能看到这个过程中能看到本质上就是把键值对，暂时存到mModified一个map中。

### SharedPreferences删除键值对
```java
        @Override
        public Editor remove(String key) {
            synchronized (mEditorLock) {
                mModified.put(key, this);
                return this;
            }
        }
```
这里面也很简单，把当前的Key对应键值设置为Editor，并没有像常见设置为null。

### SharedPreferences 查询键值对
查询键值对，逻辑和增加删除的不一致。
```java
    @Override
    @Nullable
    public String getString(String key, @Nullable String defValue) {
        synchronized (mLock) {
            awaitLoadedLocked();
            String v = (String)mMap.get(key);
            return v != null ? v : defValue;
        }
    }
```
查询键值对则会通过从xml中获取的mMap缓存数据中进行查询。

### SharedPreferences 同步数据
当editor操作完成后，就会进行数据的同步。SharedPreferences同步数据到磁盘有两种，一种是commit同步，另一种是apply异步同步。

#### SharedPreferences commit同步到磁盘中
```java
        @Override
        public boolean commit() {
            long startTime = 0;

            if (DEBUG) {
                startTime = System.currentTimeMillis();
            }

            MemoryCommitResult mcr = commitToMemory();

            SharedPreferencesImpl.this.enqueueDiskWrite(
                mcr, null /* sync write on this thread okay */);
            try {
                mcr.writtenToDiskLatch.await();
            } catch (InterruptedException e) {
                return false;
            } finally {
              ...
            }
            notifyListeners(mcr);
            return mcr.writeToDiskResult;
        }
```
在这个过程中，可以分为三步：
- 1.commitToMemory 把刚才缓存在Editor的HashMap生成一个内存提交对象MemoryCommitResult。
- 2.调用enqueueDiskWrite的enqueueDiskWrite，把这个提交对象提交到磁盘中，并且调用writtenToDiskLatch进行等待。
- 3.完成后调用notifyListeners通知监听已经完成。

先来看看MemoryCommitResult 对象中承载了什么数据。
#### MemoryCommitResult
```java
    private static class MemoryCommitResult {
        final long memoryStateGeneration;
        @Nullable final List<String> keysModified;
        @Nullable final Set<OnSharedPreferenceChangeListener> listeners;
        final Map<String, Object> mapToWriteToDisk;
        final CountDownLatch writtenToDiskLatch = new CountDownLatch(1);

        @GuardedBy("mWritingToDiskLock")
        volatile boolean writeToDiskResult = false;
        boolean wasWritten = false;

        private MemoryCommitResult(long memoryStateGeneration, @Nullable List<String> keysModified,
                @Nullable Set<OnSharedPreferenceChangeListener> listeners,
                Map<String, Object> mapToWriteToDisk) {
            this.memoryStateGeneration = memoryStateGeneration;
            this.keysModified = keysModified;
            this.listeners = listeners;
            this.mapToWriteToDisk = mapToWriteToDisk;
        }

        void setDiskWriteResult(boolean wasWritten, boolean result) {
            this.wasWritten = wasWritten;
            writeToDiskResult = result;
            writtenToDiskLatch.countDown();
        }
    }
```
能看到这个对象中有一个关键的对象mapToWriteToDisk，这个散列表将会持有SharePreferenceImpl.Editor用于提交到磁盘的临时散列表。

另外，这个过程中，还有writtenToDiskLatch进行线程工作完成的计数。每当一个线程完成工作后，将会调用writtenToDiskLatch的计数减一，实现阻塞放开,最后在apply或者commit的末尾通知监听者已经完成了一次操作。

我们暂时放一放commit的后续流程，来看看apply异步同步磁盘方法中有多少和commit相似的逻辑。

### apply 异步同步磁盘
```java
        @Override
        public void apply() {
            final long startTime = System.currentTimeMillis();

            final MemoryCommitResult mcr = commitToMemory();
            final Runnable awaitCommit = new Runnable() {
                    @Override
                    public void run() {
                        try {
                            mcr.writtenToDiskLatch.await();
                        } catch (InterruptedException ignored) {
                        }

....
                    }
                };

            QueuedWork.addFinisher(awaitCommit);

            Runnable postWriteRunnable = new Runnable() {
                    @Override
                    public void run() {
                        awaitCommit.run();
                        QueuedWork.removeFinisher(awaitCommit);
                    }
                };

            SharedPreferencesImpl.this.enqueueDiskWrite(mcr, postWriteRunnable);

            notifyListeners(mcr);
        }
```
能看到大体上的逻辑和commit很相似。一样通过commitToMemory生成一个MemoryCommitResult对象。同样是通过enqueueDiskWrite把写入磁盘的事务放入事件队列中。

唯一不同的是多了两个Runnable，一个是awaitCommit，另一个是postWriteRunnable。awaitCommit会进行MemoryCommitResult的阻塞等待，会添加到QueuedWork中，并在postWriteRunnable中执行awaitCommit的run方法。postWriteRunnable传递给enqueueDiskWrite。

#### commitToMemory
```java
        private MemoryCommitResult commitToMemory() {
            long memoryStateGeneration;
            List<String> keysModified = null;
            Set<OnSharedPreferenceChangeListener> listeners = null;
            Map<String, Object> mapToWriteToDisk;

            synchronized (SharedPreferencesImpl.this.mLock) {
                // We optimistically don't make a deep copy until
                // a memory commit comes in when we're already
                // writing to disk.
                if (mDiskWritesInFlight > 0) {
                    // We can't modify our mMap as a currently
                    // in-flight write owns it.  Clone it before
                    // modifying it.
                    // noinspection unchecked
                    mMap = new HashMap<String, Object>(mMap);
                }
                mapToWriteToDisk = mMap;
                mDiskWritesInFlight++;

                boolean hasListeners = mListeners.size() > 0;
                if (hasListeners) {
                    keysModified = new ArrayList<String>();
                    listeners = new HashSet<OnSharedPreferenceChangeListener>(mListeners.keySet());
                }

                synchronized (mEditorLock) {
                    boolean changesMade = false;

                    if (mClear) {
                        if (!mapToWriteToDisk.isEmpty()) {
                            changesMade = true;
                            mapToWriteToDisk.clear();
                        }
                        mClear = false;
                    }

                    for (Map.Entry<String, Object> e : mModified.entrySet()) {
                        String k = e.getKey();
                        Object v = e.getValue();
                        // "this" is the magic value for a removal mutation. In addition,
                        // setting a value to "null" for a given key is specified to be
                        // equivalent to calling remove on that key.
                        if (v == this || v == null) {
                            if (!mapToWriteToDisk.containsKey(k)) {
                                continue;
                            }
                            mapToWriteToDisk.remove(k);
                        } else {
                            if (mapToWriteToDisk.containsKey(k)) {
                                Object existingValue = mapToWriteToDisk.get(k);
                                if (existingValue != null && existingValue.equals(v)) {
                                    continue;
                                }
                            }
                            mapToWriteToDisk.put(k, v);
                        }

                        changesMade = true;
                        if (hasListeners) {
                            keysModified.add(k);
                        }
                    }

                    mModified.clear();

                    if (changesMade) {
                        mCurrentMemoryStateGeneration++;
                    }

                    memoryStateGeneration = mCurrentMemoryStateGeneration;
                }
            }
            return new MemoryCommitResult(memoryStateGeneration, keysModified, listeners,
                    mapToWriteToDisk);
        }
```
- 1.在这段逻辑中mDiskWritesInFlight这个计数器十分重要，如果mDiskWritesInFlight这个计数大于0，说明有其他线程在异步的进行commit处理，由于HashMap本身不是一个线程安全的集合，因此会对全局的mMap进行一次拷贝，让其他线程可以正常的查询数据。

- 2.判断此时mModified中的value是不是null或者Editor对象，是则说明键对应的值已经设置为null。在这里以Editor为value判空只是一个避免多线程的修改而处理的魔数。

- 3.最后把mModified中的数据拷贝到mapToWriteToDisk。一旦出现了数据的变化，mCurrentMemoryStateGeneration的计数就会加1.最后生成MemoryCommitResult返回。


### enqueueDiskWrite 推入SP的写入磁盘队列
```java
    private void enqueueDiskWrite(final MemoryCommitResult mcr,
                                  final Runnable postWriteRunnable) {
        final boolean isFromSyncCommit = (postWriteRunnable == null);

        final Runnable writeToDiskRunnable = new Runnable() {
                @Override
                public void run() {
                    synchronized (mWritingToDiskLock) {
                        writeToFile(mcr, isFromSyncCommit);
                    }
                    synchronized (mLock) {
                        mDiskWritesInFlight--;
                    }
                    if (postWriteRunnable != null) {
                        postWriteRunnable.run();
                    }
                }
            };

        // Typical #commit() path with fewer allocations, doing a write on
        // the current thread.
        if (isFromSyncCommit) {
            boolean wasEmpty = false;
            synchronized (mLock) {
                wasEmpty = mDiskWritesInFlight == 1;
            }
            if (wasEmpty) {
                writeToDiskRunnable.run();
                return;
            }
        }

        QueuedWork.queue(writeToDiskRunnable, !isFromSyncCommit);
    }

```
- 1.writeToDiskRunnable 这个runnable能看到实际上是真正的调用writeToFile写入到磁盘中，每一次写入完毕就会减少mDiskWritesInFlight的计数，说明一个线程已经工作了，最后再执行postWriteRunnable的run方法。

- 2.isFromSyncCommit这个判断的是否进行同步处理的标志位，就是通过postWriteRunnable是否为null判断的。如果为空说明是commit方法进行处理。此时会判断mDiskWritesInFlight是否为1，为1说明只有一个线程在执行，那就可以直接执行的writeToDiskRunnable的方法直接写入磁盘。但是mDiskWritesInFlight大于1说明有其他线程正在准备提交，那么还是和apply一样需要放到QueuedWork中排队执行。

在SP中所有的异步操作都会进入到QueuedWork中进行排队操作，我们来看看
QueuedWork是怎么设计的。

### QueuedWork
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[QueuedWork.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/QueuedWork.java)
我们首先来看看addFinish是做了什么
```java
    /** Finishers {@link #addFinisher added} and not yet {@link #removeFinisher removed} */
    @GuardedBy("sLock")
    private static final LinkedList<Runnable> sFinishers = new LinkedList<>();

    /** Lock for this class */
    private static final Object sLock = new Object();

    public static void addFinisher(Runnable finisher) {
        synchronized (sLock) {
            sFinishers.add(finisher);
        }
    }

    /**
     * Remove a previously {@link #addFinisher added} finisher-runnable.
     *
     * @param finisher The runnable to remove.
     */
    public static void removeFinisher(Runnable finisher) {
        synchronized (sLock) {
            sFinishers.remove(finisher);
        }
    }
```
在apply方法中，会把awaitCommit这个runnable对象存放到一个静态集合sFinishers。

### QueuedWork queue
```java
    public static void queue(Runnable work, boolean shouldDelay) {
        Handler handler = getHandler();

        synchronized (sLock) {
            sWork.add(work);

            if (shouldDelay && sCanDelay) {
                handler.sendEmptyMessageDelayed(QueuedWorkHandler.MSG_RUN, DELAY);
            } else {
                handler.sendEmptyMessage(QueuedWorkHandler.MSG_RUN);
            }
        }
    }
```
这个方法中，先获取Queuework内部的保存的静态Handler对象，接着根据shouldDelay标志位是否需要延时，而决定在handler发送MSG_RUN消息的时候有没有100毫秒的延时。

#### QueuedWork getHandler
```java
    /** {@link #getHandler() Lazily} created handler */
    @GuardedBy("sLock")
    private static Handler sHandler = null;

    private static Handler getHandler() {
        synchronized (sLock) {
            if (sHandler == null) {
                HandlerThread handlerThread = new HandlerThread("queued-work-looper",
                        Process.THREAD_PRIORITY_FOREGROUND);
                handlerThread.start();

                sHandler = new QueuedWorkHandler(handlerThread.getLooper());
            }
            return sHandler;
        }
    }
```
能看到在QueueWork对象中，保存着一个单例设计的sHandler对象。这个Handler是基于handlerThread中的线程生成的Looper。也就说，所有的入队操作最后都会切换到handlerThread这个名为queued-work-looper的线程中。

#### QueuedWorkHandler
```java
    private static class QueuedWorkHandler extends Handler {
        static final int MSG_RUN = 1;

        QueuedWorkHandler(Looper looper) {
            super(looper);
        }

        public void handleMessage(Message msg) {
            if (msg.what == MSG_RUN) {
                processPendingWork();
            }
        }
    }
```
在QueuedWorkHandler中只接受一种MSG_RUN消息的，并执行processPendingWork的方法。

#### processPendingWork 执行等待执行的任务
```java
    private static void processPendingWork() {
        long startTime = 0;

        synchronized (sProcessingWork) {
            LinkedList<Runnable> work;

            synchronized (sLock) {
                work = (LinkedList<Runnable>) sWork.clone();
                sWork.clear();

                // Remove all msg-s as all work will be processed now
                getHandler().removeMessages(QueuedWorkHandler.MSG_RUN);
            }

            if (work.size() > 0) {
                for (Runnable w : work) {
                    w.run();
                }

            }
        }
    }
```
在这过程中，实际上十分简单，就是把之前通过queue方法加入的runnable，从sWork只能够取出，并且移除掉所有的MSG_RUN的消息，清掉sWork的缓存，并执行所有的queue的Runnable对象。

知道怎么执行之后，我们回头看看设置进来的runnable对象writeToDiskRunnable。

#### writeToDiskRunnable 执行流程
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[SharedPreferencesImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/SharedPreferencesImpl.java)
```java
        final Runnable writeToDiskRunnable = new Runnable() {
                @Override
                public void run() {
                    synchronized (mWritingToDiskLock) {
                        writeToFile(mcr, isFromSyncCommit);
                    }
                    synchronized (mLock) {
                        mDiskWritesInFlight--;
                    }
                    if (postWriteRunnable != null) {
                        postWriteRunnable.run();
                    }
                }
            };
```
当执行完writeToFile写入磁盘方法后，减少mDiskWritesInFlight的计数，同时调用postWriteRunnable方法。这个方法实际上就是awaitCommit的runnable，实际上就是调用了mcr中的writtenToDiskLatch的阻塞await方法。


##### writeToFile
```java
    private void writeToFile(MemoryCommitResult mcr, boolean isFromSyncCommit) {
        long startTime = 0;
        long existsTime = 0;
        long backupExistsTime = 0;
        long outputStreamCreateTime = 0;
        long writeTime = 0;
        long fsyncTime = 0;
        long setPermTime = 0;
        long fstatTime = 0;
        long deleteTime = 0;


        boolean fileExists = mFile.exists();


        // Rename the current file so it may be used as a backup during the next read
        if (fileExists) {
            boolean needsWrite = false;

            // Only need to write if the disk state is older than this commit
            if (mDiskStateGeneration < mcr.memoryStateGeneration) {
                if (isFromSyncCommit) {
                    needsWrite = true;
                } else {
                    synchronized (mLock) {
                        if (mCurrentMemoryStateGeneration == mcr.memoryStateGeneration) {
                            needsWrite = true;
                        }
                    }
                }
            }

            if (!needsWrite) {
                mcr.setDiskWriteResult(false, true);
                return;
            }

            boolean backupFileExists = mBackupFile.exists();


            if (!backupFileExists) {
                if (!mFile.renameTo(mBackupFile)) {
                    mcr.setDiskWriteResult(false, false);
                    return;
                }
            } else {
                mFile.delete();
            }
        }

        try {
            FileOutputStream str = createFileOutputStream(mFile);


            if (str == null) {
                mcr.setDiskWriteResult(false, false);
                return;
            }
            XmlUtils.writeMapXml(mcr.mapToWriteToDisk, str);

            writeTime = System.currentTimeMillis();

            FileUtils.sync(str);

            fsyncTime = System.currentTimeMillis();

            str.close();
            ContextImpl.setFilePermissionsFromMode(mFile.getPath(), mMode, 0);


            try {
                final StructStat stat = Os.stat(mFile.getPath());
                synchronized (mLock) {
                    mStatTimestamp = stat.st_mtim;
                    mStatSize = stat.st_size;
                }
            } catch (ErrnoException e) {
                // Do nothing
            }

            // Writing was successful, delete the backup file if there is one.
            mBackupFile.delete();


            mDiskStateGeneration = mcr.memoryStateGeneration;

            mcr.setDiskWriteResult(true, true);

            long fsyncDuration = fsyncTime - writeTime;
            mSyncTimes.add((int) fsyncDuration);
            mNumSync++;


            return;
        } catch (XmlPullParserException e) {
            ...
        } catch (IOException e) {
            ...
        }

        // Clean up an unsuccessfully written file
        if (mFile.exists()) {
            if (!mFile.delete()) {
                ...
            }
        }
        mcr.setDiskWriteResult(false, false);
    }
```
这里面的可以分为如下几个步骤：
判断到mFile，需要缓存的文件存在则执行如下：
- 1.如果是commit的方式或者全局异步写入次数mDiskStateGeneration和mcr需要提交的memoryStateGeneration一致，此时needsWrite就为true。这么做有什么好处呢？有一个全局的SP操作计数，就能知道当前有多少线程进行了SP的操作，那么就没有必要，每一次都写入到磁盘，只需要写入最后一次的内存提交即可。如果发现需要提交的数据不是最后一次，则会调用mcr的setDiskWriteResult结束当前线程的等待。
```java
            if (mDiskStateGeneration < mcr.memoryStateGeneration) {
                if (isFromSyncCommit) {
                    needsWrite = true;
                } else {
                    synchronized (mLock) {
                        if (mCurrentMemoryStateGeneration == mcr.memoryStateGeneration) {
                            needsWrite = true;
                        }
                    }
                }
            }

            if (!needsWrite) {
                mcr.setDiskWriteResult(false, true);
                return;
            }
```

- 2.如果备份文件不存在，则会把当前的mFIle尝试着移动路径为备份文件mBackFile。如果连mFile的重命名失败就直接返回了。如果备份文件存在，则删除掉原来的mFile文件。
```java
            if (!backupFileExists) {
                if (!mFile.renameTo(mBackupFile)) {
                    mcr.setDiskWriteResult(false, false);
                    return;
                }
            } else {
                mFile.delete();
            }
```
在sp第一次初始化时候，会把尝试着备份文件转化为存储文件。如果是第一次创建sp对应的存储文件，那么备份文件必定不存在。在writeToFile这个方法中，就会把当前的file重命名为备份的file. 如果存在备份文件，说明之前已经存过东西了，并从文件中读取键值对到mMap全局变量中，可以直接删除掉整个File文件，其实就是相当于把file的存储文件给清空了。

- 3.把mMap的数据通过io写入到XML mFile文件中。
```java
            FileOutputStream str = createFileOutputStream(mFile);
            if (str == null) {
                mcr.setDiskWriteResult(false, false);
                return;
            }
            XmlUtils.writeMapXml(mcr.mapToWriteToDisk, str);
            writeTime = System.currentTimeMillis();
            FileUtils.sync(str);
            fsyncTime = System.currentTimeMillis();
            str.close();
```
- 4.如果写入操作成功了，那么备份文件也不需要存在了，直接删除了。并调用mcr的setDiskWriteResult，告诉阻塞的对象已经完成了io的操作。


到这里，大致上就完成了SP的读写流程了。


## 关于SP的思考与总结

### 总结
我们先来看那么几个时序图。
当SP启动的时候，就会就会开启一个线程从磁盘中读取，但是如果此时遇到了SP操作就会如下执行：

![SP启动.jpg](/images/SP启动.jpg)

十分简单的SP的初始化流程。

#### SP的备份机制
我们再去看看SP的备份机制。在SP的备份机制中，实际上是由一个.bak后缀的文件进行备份。

当loadFromDisk的时候，会生成一个线程读取Xml的数据到mMap的缓存中。能看到，第一次读取文件的时候，发现备份文件存在会进行如下处理：
```java
if (mBackupFile.exists()) {
                mFile.delete();
                mBackupFile.renameTo(mFile);
            }
```
把mFile的文件给删除掉，把mBackupFile重新命名为mFile(xml的缓存文件名)。那么这样做就能把上一次保存在mBackupFile中完好的数据继承到mFile中。


而mBackupFile一般来说是实在writeToFile的时候附带的副产物：
```java
            if (!backupFileExists) {
                if (!mFile.renameTo(mBackupFile)) {
                    mcr.setDiskWriteResult(false, false);
                    return;
                }
            } else {
                mFile.delete();
            }
```
假设，如果我们上一次以及之前所有的磁盘读写都成功了，那么备份文件就会和writeToFile小结中说的一样，每一次读写完毕会删除。

backupFile都不存在，就会把mFile重命名路径为mBackupFile，在每一次读写之前进行了一次备份。

从全局来看如果backupFile存在，说明了之前的读写出现了问题。此时可以分为两种情况：
- 1.初始化的时候发现backupFile存在，那么此时backupFile已经重新刷新了原来的mFile对象，也就说把之前数据出错了mFile回退到最后编辑的backupFile数据状态，并且保存到mMap中。从之后就不会存在backupFile这个备份文件了。

- 2.如果在读写过程中出现了异常，读写操作无法完成，则会生成一个备份文件backupFile。这个时候就会把之前那个mFile存储出错的数据文件，直接删除。因为读写过程中被异常退出了，很有可能读写的信息有误，造成下一次启动无法正常读取。干脆直接删掉mFile，重新建立一个新的mFile文件写入其中。如果这一次的成功了，就删掉备份文件。

换句话说，SP的备份机制，实际上备份的是上一次正常读写成功磁盘存储机制。


#### SP跨进程的mode在其中的作用
在整个流程中mode正在起作用的位置在writeToFile中,写如磁盘操作结束后的下面一行代码中：
```java
ContextImpl.setFilePermissionsFromMode(mFile.getPath(), mMode, 0);
```
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[app](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/)/[ContextImpl.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/app/ContextImpl.java)
```java
    static void setFilePermissionsFromMode(String name, int mode,
            int extraPermissions) {
        int perms = FileUtils.S_IRUSR|FileUtils.S_IWUSR
            |FileUtils.S_IRGRP|FileUtils.S_IWGRP
            |extraPermissions;
        if ((mode&MODE_WORLD_READABLE) != 0) {
            perms |= FileUtils.S_IROTH;
        }
        if ((mode&MODE_WORLD_WRITEABLE) != 0) {
            perms |= FileUtils.S_IWOTH;
        }
        FileUtils.setPermissions(name, perms, -1, -1);
    }
```

```java
    public static int setPermissions(String path, int mode, int uid, int gid) {
        try {
            Os.chmod(path, mode);
        } catch (ErrnoException e) {
            Slog.w(TAG, "Failed to chmod(" + path + "): " + e);
            return e.errno;
        }

        if (uid >= 0 || gid >= 0) {
            try {
                Os.chown(path, uid, gid);
            } catch (ErrnoException e) {
                Slog.w(TAG, "Failed to chown(" + path + "): " + e);
                return e.errno;
            }
        }

        return 0;
    }
```
```java
//用户
    public static final int S_IRWXU = 00700;
    public static final int S_IRUSR = 00400;
    public static final int S_IWUSR = 00200;
    public static final int S_IXUSR = 00100;
//组
    public static final int S_IRWXG = 00070;
    public static final int S_IRGRP = 00040;
    public static final int S_IWGRP = 00020;
    public static final int S_IXGRP = 00010;
//其他人
    public static final int S_IRWXO = 00007;
    public static final int S_IROTH = 00004;
    public static final int S_IWOTH = 00002;
    public static final int S_IXOTH = 00001;
```

其实可以看到这个过程中就是通过chmod方法设置了文件的在系统中的权限。从名称就能知道，这个方法每一次读写之后都会默认给用户和组都能够进行读写。

在这个方法会判断从上面传下来的mode，是否打开了MODE_WORLD_READABLE和MODE_WORLD_WRITEABLE。
```java
public static final int MODE_WORLD_WRITEABLE = 0x0002;
public static final int MODE_WORLD_READABLE = 0x0001;
```

我们来看看SP设置多进程读写时候的标志位：
```java
public static final int MODE_MULTI_PROCESS = 0x0004;
```
换算到二进制就是100和010，以及100和001相与都是0.连这里都没有进行处理的话，说明SP在Android 9.0根本没有进行多进程读写文件的互斥处理.

我们看看MODE_MULTI_PROCESS的注释：
```java
MODE_MULTI_PROCESS does not work reliably in
     * some versions of Android, and furthermore does not provide any
     * mechanism for reconciling concurrent modifications across
     * processes.  Applications should not attempt to use it.  Instead,
     * they should use an explicit cross-process data management
     * approach such as {@link android.content.ContentProvider ContentProvider}.
```
这里面已经说明了，在某些Android版本中SP将不会提供跨进程读写文件的保护，如果有需求，请使用ContentProvider。

最后上一副流程图进行总结整个流程：
![SP时序图.jpg](/images/SP时序图.jpg)


### 思考
能看到实际上我们通过Context获取sp对象，在这个过程中，我们完全可以复写Context中getSharePreferences的方法，进而返回自己定义的SharePreferences。当然我们需要自己实现SharePreferences以及SharePreferences.Editor.


同理我们可以看到MMKV中的实现：
```cpp
public class MMKV implements SharedPreferences, SharedPreferences.Editor 
```

那么，实际上我们这么无缝迁移MMKV到SP中:
```java
    override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
        val mmkv = MMKV.mmkvWithID(name,mode)

        if(mmkv.getBoolean("hasTransport",false)){
            var originPrefences = super.getSharedPreferences(name, mode)
            mmkv.importFromSharedPreferences(originPrefences)
            originPrefences.edit().clear().apply()
            mmkv.encode("hasTransport",true)
        }
        return mmkv
    }
```
只需要在Application，Activity，CP下复写该方法为如上，就能在上层使用了SP的方式，实际上底层却是调用了mmkv的方法。

了解到如何无缝使用MMKV之后，我们再来聊一下在MMKV一文中和大家提过SP的几个问题：
- 1.跨进程不安全 
- 2.加载缓慢 
- 3.全量写入 
- 4.卡顿 

#### SP跨进程不安全 
对于第一个问题，在上一节我们聊过了SP的实现。实际上它并没有对多进程读写进行保护

#### SP加载缓慢 
对于这个问题，其实就是指初始化的时候SPImpl的时候，新建立了一个线程进行读取Xml的数据：
```java
        new Thread("SharedPreferencesImpl-load") {
            public void run() {
                loadFromDisk();
            }
        }.start();
```
然而在SP每一次操作都必须等待这个线程读取完磁盘才能进行下一步的操作。很多开发者估计都是把SP操作放到ui线程中进行的吧。如果开发者不注意，保存的XML数据过于庞大，就会造成ui卡顿甚至ANR。

为了让该线程更加快速的处理，Android系统应该要把SP读取磁盘使用一个缓存线程池进行处理，线程可以立即执行
```java
private static volatile ExecutorService sCachedThreadPool = Executors.newCachedThreadPool();
private void startLoadFromDisk() {
        synchronized (this) {
            mLoaded = false;
        }

        sCachedThreadPool.execute(new Runnable() {
            @Override
            public void run() {
                loadFromDisk();
            }
        });
    }
```
通过这种方式，就能让在线程池中立即获取还存活的线程进行直接的处理磁盘读取任务。

当然，还有一点需要注意由于磁盘读取的和MMKV不一样，MMKV是直接通过共享内存的方式直接把内存文件映射到虚拟内存中，应用可以直接访问。而SP的读取则是通过普通的io读写，这样需要经过一次进入内核一次，就会造成速度上比mmap要慢上不少。

两者都应该注意写如数据的大小：
MMKV虽然有trim方法，但是并没有帮你监控虚拟内存的情况，这也是MMKV可以后续优化的地方，如果不注意数据的大小一味的存储，会造成虚拟内存爆炸导致应用异常。

SP由于是一口气从磁盘中读取所有的数据，数据过于庞大就会造成SP初始化十分慢，导致后续操作产生ANR。

#### 全量写入 
这个问题可以很容易的看到，在writeToFile方法中，是把所有从Xml缓存文件解析到的数据统统保存会缓存文件中，这样就会造成了写入十分缓慢。而反观MMKV，由于它本身就是支持append模式在后面映射内存末尾继续添加键值对，这样写入速度比起SP快的不是一星半点。

当然也是因为这种机制的问题，SP和MMKV的recover模式从根本的策略上不同。SP由于是全量读写，这样就能完成的保存一份备份文件。而MMKV一般是内存末尾追加模式以及多进程读写保护的策略，虽然读写很快，但是这也造成了MMKV很难对全文件进行一次备份处理，只能不断的保证最后一次读写正常，并尝试读取缓存文件中完好数据尽可能恢复完好的数据。

接下来比较Android 7.0低版本中SP的实现，我们翻翻以前老版本的SP的源码。我们看看Android 7.0的源码：
```java
 private void writeToFile(MemoryCommitResult mcr) {
        if (mFile.exists()) {
            if (!mcr.changesMade) {
                mcr.setDiskWriteResult(true);
                return;
            }
            if (!mBackupFile.exists()) {
                if (!mFile.renameTo(mBackupFile)) {
                    mcr.setDiskWriteResult(false);
                    return;
                }
            } else {
                mFile.delete();
            }
        }

        try {
            FileOutputStream str = createFileOutputStream(mFile);
            if (str == null) {
                mcr.setDiskWriteResult(false);
                return;
            }
            XmlUtils.writeMapXml(mcr.mapToWriteToDisk, str);
            FileUtils.sync(str);
            str.close();
            ContextImpl.setFilePermissionsFromMode(mFile.getPath(), mMode, 0);
            try {
                final StructStat stat = Os.stat(mFile.getPath());
                synchronized (this) {
                    mStatTimestamp = stat.st_mtime;
                    mStatSize = stat.st_size;
                }
            } catch (ErrnoException e) {
                // Do nothing
            }
            mBackupFile.delete();
            mcr.setDiskWriteResult(true);
            return;
        } catch (XmlPullParserException e) {
        } catch (IOException e) {
        }

        mcr.setDiskWriteResult(false);
    }
```
能看到在Android 7.0中并没有像Android 9.0一样，对apply异步写入进行一次needWrites的标志位判断，避免多次写入磁盘。在Android 7.0中只要有一个apply的操作，就会进行一次磁盘的读写，这样就会造成io的上繁忙，性能大大的降低。

在我看来，Android 9.0的优化方案也不是最好的。

在SP中有一个参数mDiskWritesInFlight对apply或者commit的同步操作进行计数。我们完全可以做成把多个apply合并成一个apply操作，只需要判断到mDiskWritesInFlight小于等于0，说明SP其他的操作经完成了，可以进行SharedPreferencesImpl.this.enqueueDiskWrite操作，这样的结果也不会发生变化，因为在这之前一直在操作内存。
```java
        public void apply() {
            final MemoryCommitResult mcr = commitToMemory();

            boolean hasDiskWritesInFlight = false;
            synchronized (SharedPreferencesImpl.this) {
                hasDiskWritesInFlight = mDiskWritesInFlight > 0;
            }

            if (!hasDiskWritesInFlight) {
                final Runnable awaitCommit = new Runnable() {
                    public void run() {
                        try {
                            mcr.writtenToDiskLatch.await();
                        } catch (InterruptedException ignored) {
                        }
                    }
                };

                QueuedWork.add(awaitCommit);

                Runnable postWriteRunnable = new Runnable() {
                    public void run() {
                        awaitCommit.run();
                        QueuedWork.remove(awaitCommit);
                    }
                };

                SharedPreferencesImpl.this.enqueueDiskWrite(mcr, postWriteRunnable);
            }

            notifyListeners(mcr);
        }
```
能通过这种方式减少apply的操作，减少QueueWork中遍历的任务队列。


#### 卡顿 
那么除了上文我说过的，因为SP读取XML缓存文件过大使得初始化时间太长而导致ANR之外。其实在AcitivtyThread中有什么一段代码，不知道你们有没有在我的Activity启动流程系列文章中有没有发现在onPause以及onStop生命周期一文中有这么一段代码：
```java
    public void handlePauseActivity(IBinder token, boolean finished, boolean userLeaving,
            int configChanges, PendingTransactionActions pendingActions, String reason) {
        ActivityClientRecord r = mActivities.get(token);
        if (r != null) {
            if (userLeaving) {
                performUserLeavingActivity(r);
            }

            r.activity.mConfigChangeFlags |= configChanges;
            performPauseActivity(r, finished, reason, pendingActions);

            // Make sure any pending writes are now committed.
            if (r.isPreHoneycomb()) {
                QueuedWork.waitToFinish();
            }
            mSomeActivitiesChanged = true;
        }
    }
```
```java
    public void handleStopActivity(IBinder token, boolean show, int configChanges,
            PendingTransactionActions pendingActions, boolean finalStateRequest, String reason) {
        final ActivityClientRecord r = mActivities.get(token);
        r.activity.mConfigChangeFlags |= configChanges;

        final StopInfo stopInfo = new StopInfo();
        performStopActivityInner(r, stopInfo, show, true /* saveState */, finalStateRequest,
                reason);

        updateVisibility(r, show);

        // Make sure any pending writes are now committed.
        if (!r.isPreHoneycomb()) {
            QueuedWork.waitToFinish();
        }

        stopInfo.setActivity(r);
        stopInfo.setState(r.state);
        stopInfo.setPersistentState(r.persistentState);
        pendingActions.setStopInfo(stopInfo);
        mSomeActivitiesChanged = true;
    }
```
能看到在低于Android api 11会在onPause时候调用QueuedWork的waitToFinish。大于11则会在onStop调用QueuedWork.waitToFinish.这两个方法都会对QueuedWork的中的任务执行进行等待，直到执行完毕。

#### QueuedWork waitToFinish
```java
    public static void waitToFinish() {
        long startTime = System.currentTimeMillis();
        boolean hadMessages = false;

        Handler handler = getHandler();

        synchronized (sLock) {
            if (handler.hasMessages(QueuedWorkHandler.MSG_RUN)) {
                // Delayed work will be processed at processPendingWork() below
                handler.removeMessages(QueuedWorkHandler.MSG_RUN);
...
            }

            // We should not delay any work as this might delay the finishers
            sCanDelay = false;
        }

        StrictMode.ThreadPolicy oldPolicy = StrictMode.allowThreadDiskWrites();
        try {
            processPendingWork();
        } finally {
            StrictMode.setThreadPolicy(oldPolicy);
        }

        try {
            while (true) {
                Runnable finisher;

                synchronized (sLock) {
                    finisher = sFinishers.poll();
                }

                if (finisher == null) {
                    break;
                }

                finisher.run();
            }
        } finally {
            sCanDelay = true;
        }

        synchronized (sLock) {
            long waitTime = System.currentTimeMillis() - startTime;

            if (waitTime > 0 || hadMessages) {
                mWaitTimes.add(Long.valueOf(waitTime).intValue());
                mNumWaits++;

....
            }
        }
    }
```
能看到，在这个过程中实际上就是上文我提到过的addFinisher的方法。这个方法实际上就是在apply异步同步到磁盘的Runnable对象awaitCommit。

从全局的设计来看，一个Finisher会对应一个执行磁盘写入的方法。所以在waitToFinish这个方法实际上就是检查还有多少个Finisher没有被销毁，那么就有多少任务还没有执行完成。

在processPendingWork执行完成之前，都需要调用finisher的run方法，对mcr中的CountDownLatch进行等待阻塞。

换句话说，当我们的SP写入耗时过大，就会造成Activity 暂停时候卡住，从而导致AMS服务那边的倒计时超时爆了ANR。而这种情况可能很会见的不少，因为SP本身就全量写入。

这四个缺点就是平时开发中遇到，并且通过源码分析后，发现系统实现不合理的地方。而MMKV都能对这四个问题有很好的弥补以及提升。

## 后话
关于存储优化的第一部分就完成了，不过关于存储还有很多可以聊聊，比如数据库等等。不过到这里我们先点到为止，后续我们继续View的绘制流程源码解析。

从这一篇文章来看，源码本身虽然经过千锤百炼，不过还是有不少设计不是很好的地方。SP除了这四个性能的问题之外，还有一些代码设计层面上我个人觉得不够好的地方，比如缓存对象为什么一定要用SharedPreferencesImpl，而不用SharedPreferences接口，这样系统就能缓存我们自定义的SP了。

不过这些都是后话了。



