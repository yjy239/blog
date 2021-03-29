---
title: Android重学系列 PackageManagerService的启动与安装(下)
top: false
cover: false
date: 2020-08-31 00:23:41
img:
tag:
description:
author: yjy239
summary:
categories: PMS
tags:
- Android
- Android Framework
---


# 前言
 之前和大家聊完了PMS的启动原理，本文继续介绍当进行安装的时候，PMS做了什么事情。

# 正文
先来看看在Android 中如何吊起安装界面：
```java
 public static void installApk(Context context, String apkPath) {
        if (context == null || TextUtils.isEmpty(apkPath)) {
            return;
        }
 
        File file = new File(apkPath);
        Intent intent = new Intent(Intent.ACTION_VIEW);
 
        //判读版本是否在7.0以上
        if (Build.VERSION.SDK_INT >= 24) {
            Log.v(TAG,"7.0以上，正在安装apk...");
            Uri apkUri = FileProvider.getUriForFile(context, "com.yjy.fileprovider", file);

            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
        } else {
            Log.v(TAG,"7.0以下，正在安装apk...");
            intent.setDataAndType(Uri.fromFile(file), "application/vnd.android.package-archive");
        }
 
        context.startActivity(intent);
}
```

能看到其实是启动了一个特殊的意图,设置了data和type:`application/vnd.android.package-archive`.

我们可以看看`AndroidManifest.xml `
/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[PackageInstaller](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/)/[AndroidManifest.xml](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/AndroidManifest.xml)
```xml
        <activity android:name=".InstallStart"
                android:exported="true"
                android:excludeFromRecents="true">
            <intent-filter android:priority="1">
                <action android:name="android.intent.action.VIEW" />
                <action android:name="android.intent.action.INSTALL_PACKAGE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:scheme="file" />
                <data android:scheme="content" />
                <data android:mimeType="application/vnd.android.package-archive" />
            </intent-filter>
            <intent-filter android:priority="1">
                <action android:name="android.intent.action.INSTALL_PACKAGE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:scheme="file" />
                <data android:scheme="package" />
                <data android:scheme="content" />
            </intent-filter>
            <intent-filter android:priority="1">
                <action android:name="android.content.pm.action.CONFIRM_PERMISSIONS" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
        </activity>
```
其实除了通过`application/vnd.android.package-archive`能打开之外，还能通过action为`android.intent.action.INSTALL_PACKAGE`以及`"android.content.pm.action.CONFIRM_PERMISSIONS`能打开安装的Activity对象`InstallStart`。

### InstallStart 获取需要安装的包
```java
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mIPackageManager = AppGlobals.getPackageManager();
        Intent intent = getIntent();
        String callingPackage = getCallingPackage();

        // If the activity was started via a PackageInstaller session, we retrieve the calling
        // package from that session
        int sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
        if (callingPackage == null && sessionId != -1) {
            PackageInstaller packageInstaller = getPackageManager().getPackageInstaller();
            PackageInstaller.SessionInfo sessionInfo = packageInstaller.getSessionInfo(sessionId);
            callingPackage = (sessionInfo != null) ? sessionInfo.getInstallerPackageName() : null;
        }

        final ApplicationInfo sourceInfo = getSourceInfo(callingPackage);
        final int originatingUid = getOriginatingUid(sourceInfo);
        boolean isTrustedSource = false;
        if (sourceInfo != null
                && (sourceInfo.privateFlags & ApplicationInfo.PRIVATE_FLAG_PRIVILEGED) != 0) {
            isTrustedSource = intent.getBooleanExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, false);
        }

        if (!isTrustedSource && originatingUid != PackageInstaller.SessionParams.UID_UNKNOWN) {
            final int targetSdkVersion = getMaxTargetSdkVersionForUid(this, originatingUid);
            if (targetSdkVersion < 0) {

                mAbortInstall = true;
            } else if (targetSdkVersion >= Build.VERSION_CODES.O && !declaresAppOpPermission(
                    originatingUid, Manifest.permission.REQUEST_INSTALL_PACKAGES)) {
...
                mAbortInstall = true;
            }
        }
        if (mAbortInstall) {
            setResult(RESULT_CANCELED);
            finish();
            return;
        }

        Intent nextActivity = new Intent(intent);
        nextActivity.setFlags(Intent.FLAG_ACTIVITY_FORWARD_RESULT);

        nextActivity.putExtra(PackageInstallerActivity.EXTRA_CALLING_PACKAGE, callingPackage);
        nextActivity.putExtra(PackageInstallerActivity.EXTRA_ORIGINAL_SOURCE_INFO, sourceInfo);
        nextActivity.putExtra(Intent.EXTRA_ORIGINATING_UID, originatingUid);

        if (PackageInstaller.ACTION_CONFIRM_PERMISSIONS.equals(intent.getAction())) {
            nextActivity.setClass(this, PackageInstallerActivity.class);
        } else {
            Uri packageUri = intent.getData();

            if (packageUri != null && (packageUri.getScheme().equals(ContentResolver.SCHEME_FILE)
                    || packageUri.getScheme().equals(ContentResolver.SCHEME_CONTENT))) {

                nextActivity.setClass(this, InstallStaging.class);
            } else if (packageUri != null && packageUri.getScheme().equals(
                    PackageInstallerActivity.SCHEME_PACKAGE)) {
                nextActivity.setClass(this, PackageInstallerActivity.class);
            } else {
                Intent result = new Intent();
                result.putExtra(Intent.EXTRA_INSTALL_RESULT,
                        PackageManager.INSTALL_FAILED_INVALID_URI);
                setResult(RESULT_FIRST_USER, result);

                nextActivity = null;
            }
        }

        if (nextActivity != null) {
            startActivity(nextActivity);
        }
        finish();
    }
```
很简单，这个过程做了如下事情：
- 1.判断当前的apk包是否是可信任来源，如果是不可信任来源，且没有申请不可信任来源包安装权限，则会强制结束当前的Activity。
- 2.此时就会从data从获取到我们传递进来的apk包的地址uri，并且设置下一个启动的Activity为InstallStaging
- 3.启动InstallStaging 这个Activity

值得注意的是：
- 1.如果我们使用另一种安装方式，设置的是Intent的action为`ACTION_CONFIRM_PERMISSIONS`(也就是`android.content.pm.action.CONFIRM_PERMISSIONS`)，则会直接启动PackageInstallerActivity
- 1.如果此时我们的uri不是`file`和`content`开头的协议，但是是`package`协议也是直接启动PackageInstallerActivity

### InstallStaging 包安装确认界面
文件:/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[PackageInstaller](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/)/[packageinstaller](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/packageinstaller/)/[InstallStaging.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/packageinstaller/InstallStaging.java)
这是一个带着旋转进度条和一个取消按钮的页面，核心方法在onResume
```java
    protected void onResume() {
        super.onResume();

        if (mStagingTask == null) {
            if (mStagedFile == null) {
                try {
                    mStagedFile = TemporaryFileManager.getStagedFile(this);
                } catch (IOException e) {
                    showError();
                    return;
                }
            }

            mStagingTask = new StagingAsyncTask();
            mStagingTask.execute(getIntent().getData());
        }
    }
```

在这里构建了一个临时文件：
```java
    public static File getStagedFile(@NonNull Context context) throws IOException {
        return File.createTempFile("package", ".apk", context.getNoBackupFilesDir());
    }
```
这个文件建立在当前应用私有目录下的no_backup文件夹上。也就是`/data/no_backup/packagexxx.apk` 这个临时文件。


并启动StagingAsyncTask这个AysncTask任务。这个AysncTask就没必要聊了，都是老生常谈的东西了，现在都是用LoaderManager了。如果实在好奇可以阅读我很早以前写过的[AsyncTask与LoaderManager](https://www.jianshu.com/p/b6b98520ef00)。


#### StagingAsyncTask
```java
    private final class StagingAsyncTask extends AsyncTask<Uri, Void, Boolean> {
        @Override
        protected Boolean doInBackground(Uri... params) {
            if (params == null || params.length <= 0) {
                return false;
            }
            Uri packageUri = params[0];
            try (InputStream in = getContentResolver().openInputStream(packageUri)) {

                if (in == null) {
                    return false;
                }

                try (OutputStream out = new FileOutputStream(mStagedFile)) {
                    byte[] buffer = new byte[1024 * 1024];
                    int bytesRead;
                    while ((bytesRead = in.read(buffer)) >= 0) {
                        if (isCancelled()) {
                            return false;
                        }
                        out.write(buffer, 0, bytesRead);
                    }
                }
            } catch (IOException | SecurityException | IllegalStateException e) {
                return false;
            }
            return true;
        }

        @Override
        protected void onPostExecute(Boolean success) {
            if (success) {
                Intent installIntent = new Intent(getIntent());
                installIntent.setClass(InstallStaging.this, DeleteStagedFileOnResult.class);
                installIntent.setData(Uri.fromFile(mStagedFile));

                if (installIntent.getBooleanExtra(Intent.EXTRA_RETURN_RESULT, false)) {
                    installIntent.addFlags(Intent.FLAG_ACTIVITY_FORWARD_RESULT);
                }

                installIntent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
                startActivity(installIntent);

                InstallStaging.this.finish();
            } else {
                showError();
            }
        }
    }
```
- 1.doInBackground 是指在异步线程池中处理的事务。doInBackground中实际上就是把uri中需要安装的apk拷贝到临时文件中。

- 2.onPostExecute 当拷贝任务处理完之后，就会把当前的临时文件作为Intent的参数，跳转到DeleteStagedFileOnResult中。


### DeleteStagedFileOnResult 
```java
public class DeleteStagedFileOnResult extends Activity {
    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        if (savedInstanceState == null) {
            Intent installIntent = new Intent(getIntent());
            installIntent.setClass(this, PackageInstallerActivity.class);

            installIntent.setFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
            startActivityForResult(installIntent, 0);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        File sourceFile = new File(getIntent().getData().getPath());
        sourceFile.delete();

        setResult(resultCode, data);
        finish();
    }
}
```
这个过程很简单就是启动到PackageInstallerActivity中。如果PackageInstallerActivity安装失败了，就会退出PackageInstallerActivity界面在DeleteStagedFileOnResult的onActivityResult中删除这个临时文件。

### PackageInstallerActivity 安装界面
先来看看onCreate
```java
    protected void onCreate(Bundle icicle) {
        super.onCreate(null);

        if (icicle != null) {
            mAllowUnknownSources = icicle.getBoolean(ALLOW_UNKNOWN_SOURCES_KEY);
        }

        mPm = getPackageManager();
        mIpm = AppGlobals.getPackageManager();
        mAppOpsManager = (AppOpsManager) getSystemService(Context.APP_OPS_SERVICE);
        mInstaller = mPm.getPackageInstaller();
        mUserManager = (UserManager) getSystemService(Context.USER_SERVICE);

        final Intent intent = getIntent();

        mCallingPackage = intent.getStringExtra(EXTRA_CALLING_PACKAGE);
        mSourceInfo = intent.getParcelableExtra(EXTRA_ORIGINAL_SOURCE_INFO);
        mOriginatingUid = intent.getIntExtra(Intent.EXTRA_ORIGINATING_UID,
                PackageInstaller.SessionParams.UID_UNKNOWN);
        mOriginatingPackage = (mOriginatingUid != PackageInstaller.SessionParams.UID_UNKNOWN)
                ? getPackageNameForUid(mOriginatingUid) : null;


        final Uri packageUri;

        if (PackageInstaller.ACTION_CONFIRM_PERMISSIONS.equals(intent.getAction())) {
            final int sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
            final PackageInstaller.SessionInfo info = mInstaller.getSessionInfo(sessionId);
            if (info == null || !info.sealed || info.resolvedBaseCodePath == null) {
                finish();
                return;
            }

            mSessionId = sessionId;
            packageUri = Uri.fromFile(new File(info.resolvedBaseCodePath));
            mOriginatingURI = null;
            mReferrerURI = null;
        } else {
            mSessionId = -1;
            packageUri = intent.getData();
            mOriginatingURI = intent.getParcelableExtra(Intent.EXTRA_ORIGINATING_URI);
            mReferrerURI = intent.getParcelableExtra(Intent.EXTRA_REFERRER);
        }

...
        boolean wasSetUp = processPackageUri(packageUri);
        if (!wasSetUp) {
            return;
        }

...
        checkIfAllowedAndInitiateInstall();
    }
```
- 1.能看到如果使用`application/vnd.android.package-archive`另外两种模式进行安装，那么就会获取保存在Intent中的ApplicationInfo对象，获取其中的resolvedBaseCodePath也就是代码文件路径

- 2.如果是使用`application/vnd.android.package-archive` 则通过Intent的getData获取到保存在其中的临时文件。

- 3.processPackageUri 扫描路径对应的包

- 4.checkIfAllowedAndInitiateInstall 启动安装

#### processPackageUri
```java
    private boolean processPackageUri(final Uri packageUri) {
        mPackageURI = packageUri;

        final String scheme = packageUri.getScheme();

        switch (scheme) {
            case SCHEME_PACKAGE: {
                try {
                    mPkgInfo = mPm.getPackageInfo(packageUri.getSchemeSpecificPart(),
                            PackageManager.GET_PERMISSIONS
                                    | PackageManager.MATCH_UNINSTALLED_PACKAGES);
                } catch (NameNotFoundException e) {
                }
                if (mPkgInfo == null) {
                    showDialogInner(DLG_PACKAGE_ERROR);
                    setPmResult(PackageManager.INSTALL_FAILED_INVALID_APK);
                    return false;
                }
                mAppSnippet = new PackageUtil.AppSnippet(mPm.getApplicationLabel(mPkgInfo.applicationInfo),
                        mPm.getApplicationIcon(mPkgInfo.applicationInfo));
            } break;

            case ContentResolver.SCHEME_FILE: {
                File sourceFile = new File(packageUri.getPath());
                PackageParser.Package parsed = PackageUtil.getPackageInfo(this, sourceFile);

                if (parsed == null) {

                    showDialogInner(DLG_PACKAGE_ERROR);
                    setPmResult(PackageManager.INSTALL_FAILED_INVALID_APK);
                    return false;
                }
                mPkgInfo = PackageParser.generatePackageInfo(parsed, null,
                        PackageManager.GET_PERMISSIONS, 0, 0, null,
                        new PackageUserState());
                mAppSnippet = PackageUtil.getAppSnippet(this, mPkgInfo.applicationInfo, sourceFile);
            } break;

            default: {
                throw new IllegalArgumentException("Unexpected URI scheme " + packageUri);
            }
        }

        return true;
    }
```
先把uri缓存到全局的mPackageURI
在这个过程中，会解析两种uri：
- 1.`package`协议开头的uri：这种uri会通过PMS的getPackageInfo通过getSchemeSpecificPart获取对应apk文件对应的PackageInfo信息
- 2.`file`协议开头的uri，则使用PMS的generatePackageInfo方法获取apk文件中的package信息

##### PackageParser generatePackageInfo
PMS的generatePackageInfo，最终会调用PackageParser的generatePackageInfo
```java
   public static PackageInfo generatePackageInfo(PackageParser.Package p,
            int gids[], int flags, long firstInstallTime, long lastUpdateTime,
            Set<String> grantedPermissions, PackageUserState state, int userId) {
        if (!checkUseInstalledOrHidden(flags, state, p.applicationInfo) || !p.isMatch(flags)) {
            return null;
        }
        PackageInfo pi = new PackageInfo();
        pi.packageName = p.packageName;
        pi.splitNames = p.splitNames;
        pi.versionCode = p.mVersionCode;
        pi.versionCodeMajor = p.mVersionCodeMajor;
        pi.baseRevisionCode = p.baseRevisionCode;
        pi.splitRevisionCodes = p.splitRevisionCodes;
        pi.versionName = p.mVersionName;
        pi.sharedUserId = p.mSharedUserId;
        pi.sharedUserLabel = p.mSharedUserLabel;
        pi.applicationInfo = generateApplicationInfo(p, flags, state, userId);
        pi.installLocation = p.installLocation;
        pi.isStub = p.isStub;
        pi.coreApp = p.coreApp;
        if ((pi.applicationInfo.flags&ApplicationInfo.FLAG_SYSTEM) != 0
                || (pi.applicationInfo.flags&ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0) {
            pi.requiredForAllUsers = p.mRequiredForAllUsers;
        }
        pi.restrictedAccountType = p.mRestrictedAccountType;
        pi.requiredAccountType = p.mRequiredAccountType;
        pi.overlayTarget = p.mOverlayTarget;
        pi.overlayCategory = p.mOverlayCategory;
        pi.overlayPriority = p.mOverlayPriority;
        pi.mOverlayIsStatic = p.mOverlayIsStatic;
        pi.compileSdkVersion = p.mCompileSdkVersion;
        pi.compileSdkVersionCodename = p.mCompileSdkVersionCodename;
        pi.firstInstallTime = firstInstallTime;
        pi.lastUpdateTime = lastUpdateTime;
        if ((flags&PackageManager.GET_GIDS) != 0) {
            pi.gids = gids;
        }
        if ((flags&PackageManager.GET_CONFIGURATIONS) != 0) {
            int N = p.configPreferences != null ? p.configPreferences.size() : 0;
            if (N > 0) {
                pi.configPreferences = new ConfigurationInfo[N];
                p.configPreferences.toArray(pi.configPreferences);
            }
            N = p.reqFeatures != null ? p.reqFeatures.size() : 0;
            if (N > 0) {
                pi.reqFeatures = new FeatureInfo[N];
                p.reqFeatures.toArray(pi.reqFeatures);
            }
            N = p.featureGroups != null ? p.featureGroups.size() : 0;
            if (N > 0) {
                pi.featureGroups = new FeatureGroupInfo[N];
                p.featureGroups.toArray(pi.featureGroups);
            }
        }
        if ((flags & PackageManager.GET_ACTIVITIES) != 0) {
            final int N = p.activities.size();
            if (N > 0) {
                int num = 0;
                final ActivityInfo[] res = new ActivityInfo[N];
                for (int i = 0; i < N; i++) {
                    final Activity a = p.activities.get(i);
                    if (state.isMatch(a.info, flags)) {
                        res[num++] = generateActivityInfo(a, flags, state, userId);
                    }
                }
                pi.activities = ArrayUtils.trimToSize(res, num);
            }
        }
        if ((flags & PackageManager.GET_RECEIVERS) != 0) {
            final int N = p.receivers.size();
            if (N > 0) {
                int num = 0;
                final ActivityInfo[] res = new ActivityInfo[N];
                for (int i = 0; i < N; i++) {
                    final Activity a = p.receivers.get(i);
                    if (state.isMatch(a.info, flags)) {
                        res[num++] = generateActivityInfo(a, flags, state, userId);
                    }
                }
                pi.receivers = ArrayUtils.trimToSize(res, num);
            }
        }
        if ((flags & PackageManager.GET_SERVICES) != 0) {
            final int N = p.services.size();
            if (N > 0) {
                int num = 0;
                final ServiceInfo[] res = new ServiceInfo[N];
                for (int i = 0; i < N; i++) {
                    final Service s = p.services.get(i);
                    if (state.isMatch(s.info, flags)) {
                        res[num++] = generateServiceInfo(s, flags, state, userId);
                    }
                }
                pi.services = ArrayUtils.trimToSize(res, num);
            }
        }
        if ((flags & PackageManager.GET_PROVIDERS) != 0) {
            final int N = p.providers.size();
            if (N > 0) {
                int num = 0;
                final ProviderInfo[] res = new ProviderInfo[N];
                for (int i = 0; i < N; i++) {
                    final Provider pr = p.providers.get(i);
                    if (state.isMatch(pr.info, flags)) {
                        res[num++] = generateProviderInfo(pr, flags, state, userId);
                    }
                }
                pi.providers = ArrayUtils.trimToSize(res, num);
            }
        }
        if ((flags&PackageManager.GET_INSTRUMENTATION) != 0) {
            int N = p.instrumentation.size();
            if (N > 0) {
                pi.instrumentation = new InstrumentationInfo[N];
                for (int i=0; i<N; i++) {
                    pi.instrumentation[i] = generateInstrumentationInfo(
                            p.instrumentation.get(i), flags);
                }
            }
        }
        if ((flags&PackageManager.GET_PERMISSIONS) != 0) {
            int N = p.permissions.size();
            if (N > 0) {
                pi.permissions = new PermissionInfo[N];
                for (int i=0; i<N; i++) {
                    pi.permissions[i] = generatePermissionInfo(p.permissions.get(i), flags);
                }
            }
            N = p.requestedPermissions.size();
            if (N > 0) {
                pi.requestedPermissions = new String[N];
                pi.requestedPermissionsFlags = new int[N];
                for (int i=0; i<N; i++) {
                    final String perm = p.requestedPermissions.get(i);
                    pi.requestedPermissions[i] = perm;
                    pi.requestedPermissionsFlags[i] |= PackageInfo.REQUESTED_PERMISSION_REQUIRED;
                    if (grantedPermissions != null && grantedPermissions.contains(perm)) {
                        pi.requestedPermissionsFlags[i] |= PackageInfo.REQUESTED_PERMISSION_GRANTED;
                    }
                }
            }
        }

        if ((flags&PackageManager.GET_SIGNATURES) != 0) {
            if (p.mSigningDetails.hasPastSigningCertificates()) {

                pi.signatures = new Signature[1];
                pi.signatures[0] = p.mSigningDetails.pastSigningCertificates[0];
            } else if (p.mSigningDetails.hasSignatures()) {
                int numberOfSigs = p.mSigningDetails.signatures.length;
                pi.signatures = new Signature[numberOfSigs];
                System.arraycopy(p.mSigningDetails.signatures, 0, pi.signatures, 0, numberOfSigs);
            }
        }

        if ((flags & PackageManager.GET_SIGNING_CERTIFICATES) != 0) {
            if (p.mSigningDetails != SigningDetails.UNKNOWN) {

                pi.signingInfo = new SigningInfo(p.mSigningDetails);
            } else {
                pi.signingInfo = null;
            }
        }
        return pi;
    }
```
能看到generatePackageInfo的方法实际上只解析了四大组件的内容以及权限相关的标签。还没有上一篇文章中扫描apk做的事情齐全。不过倒是拿到了apk包所有运行需要的基础信息。

#### checkIfAllowedAndInitiateInstall
```java
    private void checkIfAllowedAndInitiateInstall() {
...

        if (mAllowUnknownSources || !isInstallRequestFromUnknownSource(getIntent())) {
            initiateInstall();
        } else {
....
        }
    }
```
核心就是这样一行，允许安装未知来源的文件判断，initiateInstall
```java
    private void initiateInstall() {
        String pkgName = mPkgInfo.packageName;
        String[] oldName = mPm.canonicalToCurrentPackageNames(new String[] { pkgName });
        if (oldName != null && oldName.length > 0 && oldName[0] != null) {
            pkgName = oldName[0];
            mPkgInfo.packageName = pkgName;
            mPkgInfo.applicationInfo.packageName = pkgName;
        }
        try {
            mAppInfo = mPm.getApplicationInfo(pkgName,
                    PackageManager.MATCH_UNINSTALLED_PACKAGES);
            if ((mAppInfo.flags&ApplicationInfo.FLAG_INSTALLED) == 0) {
                mAppInfo = null;
            }
        } catch (NameNotFoundException e) {
            mAppInfo = null;
        }

        startInstallConfirm();
    }
```
通过PMS的getApplicationInfo方法，获取当前Android系统中是否已经安装了当前的app，如果能找到mAppInfo对象，说明是安装了，则调用startInstallConfirm刷新按钮的内容，是`安装`还是`更新`.
```java
    private void startInstallConfirm() {
        // We might need to show permissions, load layout with permissions
        if (mAppInfo != null) {
            bindUi(R.layout.install_confirm_perm_update, true);
        } else {
            bindUi(R.layout.install_confirm_perm, true);
        }
...
}
```

#### PackageInstallerActivity 点击安装按钮
```java
    public void onClick(View v) {
        if (v == mOk) {
            if (mOk.isEnabled()) {
                if (mOkCanInstall || mScrollView == null) {
                    if (mSessionId != -1) {
                        mInstaller.setPermissionsResult(mSessionId, true);
                        finish();
                    } else {
                        startInstall();
                    }
                } else {
                    mScrollView.pageScroll(View.FOCUS_DOWN);
                }
            }
        } else if (v == mCancel) {
            setResult(RESULT_CANCELED);
            if (mSessionId != -1) {
                mInstaller.setPermissionsResult(mSessionId, false);
            }
            finish();
        }
    }
```
这个过程就很简单了，如果点击了安装的按钮，则调用startInstall启动安装等待界面。
```java
   private void startInstall() {
        Intent newIntent = new Intent();
        newIntent.putExtra(PackageUtil.INTENT_ATTR_APPLICATION_INFO,
                mPkgInfo.applicationInfo);
        newIntent.setData(mPackageURI);
        newIntent.setClass(this, InstallInstalling.class);
        String installerPackageName = getIntent().getStringExtra(
                Intent.EXTRA_INSTALLER_PACKAGE_NAME);
        if (mOriginatingURI != null) {
            newIntent.putExtra(Intent.EXTRA_ORIGINATING_URI, mOriginatingURI);
        }
        if (mReferrerURI != null) {
            newIntent.putExtra(Intent.EXTRA_REFERRER, mReferrerURI);
        }
        if (mOriginatingUid != PackageInstaller.SessionParams.UID_UNKNOWN) {
            newIntent.putExtra(Intent.EXTRA_ORIGINATING_UID, mOriginatingUid);
        }
        if (installerPackageName != null) {
            newIntent.putExtra(Intent.EXTRA_INSTALLER_PACKAGE_NAME,
                    installerPackageName);
        }
        if (getIntent().getBooleanExtra(Intent.EXTRA_RETURN_RESULT, false)) {
            newIntent.putExtra(Intent.EXTRA_RETURN_RESULT, true);
        }
        newIntent.addFlags(Intent.FLAG_ACTIVITY_FORWARD_RESULT);
        startActivity(newIntent);
        finish();
    }
```
从这一段代码，就能看到把mPackageURI放入Intent的Data中，并且启动了InstallInstalling 这个Activity。

### InstallInstalling 安装等待界面
文件：/[packages](http://androidxref.com/9.0.0_r3/xref/packages/)/[apps](http://androidxref.com/9.0.0_r3/xref/packages/apps/)/[PackageInstaller](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/)/[src](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/)/[com](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/)/[android](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/)/[packageinstaller](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/packageinstaller/)/[InstallInstalling.java](http://androidxref.com/9.0.0_r3/xref/packages/apps/PackageInstaller/src/com/android/packageinstaller/InstallInstalling.java)

先来看看InstallInstalling的onCreate方法

```java
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        setContentView(R.layout.install_installing);

        ApplicationInfo appInfo = getIntent()
                .getParcelableExtra(PackageUtil.INTENT_ATTR_APPLICATION_INFO);
        mPackageURI = getIntent().getData();

        if ("package".equals(mPackageURI.getScheme())) {
            try {
                getPackageManager().installExistingPackage(appInfo.packageName);
                launchSuccess();
            } catch (PackageManager.NameNotFoundException e) {
                launchFailure(PackageManager.INSTALL_FAILED_INTERNAL_ERROR, null);
            }
        } else {
            final File sourceFile = new File(mPackageURI.getPath());
            PackageUtil.initSnippetForNewApp(this, PackageUtil.getAppSnippet(this, appInfo,
                    sourceFile), R.id.app_snippet);

            if (savedInstanceState != null) {
...
            } else {
                PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                        PackageInstaller.SessionParams.MODE_FULL_INSTALL);
                params.installFlags = PackageManager.INSTALL_FULL_APP;
                params.referrerUri = getIntent().getParcelableExtra(Intent.EXTRA_REFERRER);
                params.originatingUri = getIntent()
                        .getParcelableExtra(Intent.EXTRA_ORIGINATING_URI);
                params.originatingUid = getIntent().getIntExtra(Intent.EXTRA_ORIGINATING_UID,
                        UID_UNKNOWN);
                params.installerPackageName =
                        getIntent().getStringExtra(Intent.EXTRA_INSTALLER_PACKAGE_NAME);

                File file = new File(mPackageURI.getPath());
                try {
                    PackageParser.PackageLite pkg = PackageParser.parsePackageLite(file, 0);
                    params.setAppPackageName(pkg.packageName);
                    params.setInstallLocation(pkg.installLocation);
                    params.setSize(
                            PackageHelper.calculateInstalledSize(pkg, false, params.abiOverride));
                } catch (PackageParser.PackageParserException e) {

                    params.setSize(file.length());
                } catch (IOException e) {

                    params.setSize(file.length());
                }

                try {
                    mInstallId = InstallEventReceiver
                            .addObserver(this, EventResultPersister.GENERATE_NEW_ID,
                                    this::launchFinishBasedOnResult);
                } catch (EventResultPersister.OutOfIdsException e) {
                    launchFailure(PackageManager.INSTALL_FAILED_INTERNAL_ERROR, null);
                }

                try {
                    mSessionId = getPackageManager().getPackageInstaller().createSession(params);
                } catch (IOException e) {
                    launchFailure(PackageManager.INSTALL_FAILED_INTERNAL_ERROR, null);
                }
            }

...
            mSessionCallback = new InstallSessionCallback();
        }
    }
```
这个过程分为两种：
- 1.如果是`package`协议，则调用PMS的installExistingPackage方法，并且调用launchSuccess，告诉用户这个apk已经安装成功了

- 2.剩下只可能是`file`协议，则获取PackageUri对应的临时文件，先通过PackageParser.parsePackageLite 解析出Package包的中apk的AndroidManifest的versionCode，安装路径等包含一个apk包中基础数据的PackageLite。

- 3.注册InstallEventReceiver 一个安装完成的广播监听。

- 4.调用PMS的getPackageInstaller.createSession 创建一个Session，并获得对应的sessionID。

核心的后面的2两点，我们依次看看都做了什么

#### InstallEventReceiver.addObserver
```java
public class InstallEventReceiver extends BroadcastReceiver {
    private static final Object sLock = new Object();
    private static EventResultPersister sReceiver;

    @NonNull private static EventResultPersister getReceiver(@NonNull Context context) {
        synchronized (sLock) {
            if (sReceiver == null) {
                sReceiver = new EventResultPersister(
                        TemporaryFileManager.getInstallStateFile(context));
            }
        }

        return sReceiver;
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        getReceiver(context).onEventReceived(context, intent);
    }


    static int addObserver(@NonNull Context context, int id,
            @NonNull EventResultPersister.EventResultObserver observer)
            throws EventResultPersister.OutOfIdsException {
        return getReceiver(context).addObserver(id, observer);
    }
}
```
这个类很简答，实际上就是实例化一个静态EventResultPersister对象后，并且调用EventResultPersister的addObserver，把监听事件注册到里面。注意InstallEventReceiver接受的广播是`com.android.packageinstaller.ACTION_INSTALL_COMMIT`

##### EventResultPersister  实例化
```java
    EventResultPersister(@NonNull File resultFile) {
        mResultsFile = new AtomicFile(resultFile);
        mCounter = GENERATE_NEW_ID + 1;

        try (FileInputStream stream = mResultsFile.openRead()) {
            XmlPullParser parser = Xml.newPullParser();
            parser.setInput(stream, StandardCharsets.UTF_8.name());

            nextElement(parser);
            while (parser.getEventType() != XmlPullParser.END_DOCUMENT) {
                String tagName = parser.getName();
                if ("results".equals(tagName)) {
                    mCounter = readIntAttribute(parser, "counter");
                } else if ("result".equals(tagName)) {
                    int id = readIntAttribute(parser, "id");
                    int status = readIntAttribute(parser, "status");
                    int legacyStatus = readIntAttribute(parser, "legacyStatus");
                    String statusMessage = readStringAttribute(parser, "statusMessage");

                    mResults.put(id, new EventResult(status, legacyStatus, statusMessage));
                } else {
                    throw new Exception("unexpected tag");
                }

                nextElement(parser);
            }
        } catch (Exception e) {
            mResults.clear();
            writeState();
        }
    }
```
这个过程也很简单，就是读取`no_backup`文件夹下的`install_results.xml`xml文件
```java
    public static File getInstallStateFile(@NonNull Context context) {
        return new File(context.getNoBackupFilesDir(), "install_results.xml");
    }
```
`install_results.xml`实际上可以获取到Android每一次安装后记录，每新增一个apk的安装都会递增id。并且该id就对应上不同安装的结果，如`status`,`legacyStatus`,`statusMessage`都会记录在这个文件中。

当安装完后，分发的消息就会同步到这个文件中，这样就能保证需要分发的安装完成的事件可以保证分发出去。

#####  EventResultPersister addObserver
```java
    int addObserver(int id, @NonNull EventResultObserver observer)
            throws OutOfIdsException {
        synchronized (mLock) {
            int resultIndex = -1;

            if (id == GENERATE_NEW_ID) {
                id = getNewId();
            } else {
                resultIndex = mResults.indexOfKey(id);
            }

            // Check if we can instantly call back
            if (resultIndex >= 0) {
                EventResult result = mResults.valueAt(resultIndex);

                observer.onResult(result.status, result.legacyStatus, result.message);
                mResults.removeAt(resultIndex);
                writeState();
            } else {
                mObservers.put(id, observer);
            }
        }
        return id;
    }
```
- 此时的id是GENERATE_NEW_ID，因此会通过getNewId对应的id会从0依次递增，并且把EventResultObserver记录id和observer，等到后面安装完成后，在通过id获取observer回调到外面的Activity。

- 如果id不为GENERATE_NEW_ID，则尝试从mResults中获取，如果能找到，说明需要告诉监听者这个apk已经安装好了，则回调EventResultObserver的onResult方法。


#### ContextImpl getPackageManager 获取ApplicationPackageManager

在继续聊getPackageInstaller之前，先来看看getPackageManager在App进程端实际上访问的是哪个对象？

```java
    public PackageManager getPackageManager() {
        if (mPackageManager != null) {
            return mPackageManager;
        }

        IPackageManager pm = ActivityThread.getPackageManager();
        if (pm != null) {
            return (mPackageManager = new ApplicationPackageManager(this, pm));
        }
        return null;
    }
```
能看到实际上App进程是不会直接访问PMS的，而是通过一层ApplicationPackageManager对PMS进行方法。

#### ApplicationPackageManager getPackageInstaller
```java
    public PackageInstaller getPackageInstaller() {
        synchronized (mLock) {
            if (mInstaller == null) {
                try {
                    mInstaller = new PackageInstaller(mPM.getPackageInstaller(),
                            mContext.getPackageName(), mContext.getUserId());
                } catch (RemoteException e) {
                    throw e.rethrowFromSystemServer();
                }
            }
            return mInstaller;
        }
    }
```
能看到这里实际上拿的是PMS的Binder方法，通过getPackageInstaller获取到PackageInstallerService后，再包装到PackageInstaller。App进程正是通过PackageInstaller进一步的访问SystemServer端的PackageInstallerService对象。

#### PMS的getPackageInstaller.createSession
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/)/[com](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/)/[server](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/)/[PackageManagerService.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/services/core/java/com/android/server/pm/PackageManagerService.java)

```java
    public IPackageInstaller getPackageInstaller() {
        if (getInstantAppPackageName(Binder.getCallingUid()) != null) {
            return null;
        }
        return mInstallerService;
    }
```
能看到实际上是获取了mInstallerService，而这个Service在上一篇文章和大家聊过了但是并没有重点聊，实际上就是PackageInstallerService对象。

#### PackageInstallerService的初始化
```java
   public PackageInstallerService(Context context, PackageManagerService pm) {
        mContext = context;
        mPm = pm;
        mPermissionManager = LocalServices.getService(PermissionManagerInternal.class);

        mInstallThread = new HandlerThread(TAG);
        mInstallThread.start();

        mInstallHandler = new Handler(mInstallThread.getLooper());

        mCallbacks = new Callbacks(mInstallThread.getLooper());

        mSessionsFile = new AtomicFile(
                new File(Environment.getDataSystemDirectory(), "install_sessions.xml"),
                "package-session");
        mSessionsDir = new File(Environment.getDataSystemDirectory(), "install_sessions");
        mSessionsDir.mkdirs();
    }

    public void systemReady() {
        mAppOps = mContext.getSystemService(AppOpsManager.class);

        synchronized (mSessions) {
            readSessionsLocked();

            reconcileStagesLocked(StorageManager.UUID_PRIVATE_INTERNAL, false /*isInstant*/);
            reconcileStagesLocked(StorageManager.UUID_PRIVATE_INTERNAL, true /*isInstant*/);

            final ArraySet<File> unclaimedIcons = newArraySet(
                    mSessionsDir.listFiles());

            for (int i = 0; i < mSessions.size(); i++) {
                final PackageInstallerSession session = mSessions.valueAt(i);
                unclaimedIcons.remove(buildAppIconFile(session.sessionId));
            }

            for (File icon : unclaimedIcons) {
                icon.delete();
            }
        }
    }
```
- 1.在构造函数中，先初始化了如下2个文件：
- `/data/system/install_sessions.xml`
- `/data/system/install_sessions/` 目录

其次就是PMS的systemReady会调用PackageInstallerService的systemReady。

- 2.调用readSessionsLocked方法，读取缓存在xml中的数据，并且依据这些数据生成PackageInstallerSession对象
```java
    private void readSessionsLocked() {
      
        mSessions.clear();

        FileInputStream fis = null;
        try {
            fis = mSessionsFile.openRead();
            final XmlPullParser in = Xml.newPullParser();
            in.setInput(fis, StandardCharsets.UTF_8.name());

            int type;
            while ((type = in.next()) != END_DOCUMENT) {
                if (type == START_TAG) {
                    final String tag = in.getName();
                    if (PackageInstallerSession.TAG_SESSION.equals(tag)) {
                        final PackageInstallerSession session;
                        try {
                            session = PackageInstallerSession.readFromXml(in, mInternalCallback,
                                    mContext, mPm, mInstallThread.getLooper(), mSessionsDir);
                        } catch (Exception e) {
                            continue;
                        }

                        final long age = System.currentTimeMillis() - session.createdMillis;

                        final boolean valid;
                        if (age >= MAX_AGE_MILLIS) {
                            valid = false;
                        } else {
                            valid = true;
                        }

                        if (valid) {
                            mSessions.put(session.sessionId, session);
                        } else {

                            addHistoricalSessionLocked(session);
                        }
                        mAllocatedSessions.put(session.sessionId, true);
                    }
                }
            }
        } catch (FileNotFoundException e) {
            // Missing sessions are okay, probably first boot
        } catch (IOException | XmlPullParserException e) {
            Slog.wtf(TAG, "Failed reading install sessions", e);
        } finally {
            IoUtils.closeQuietly(fis);
        }
    }
```
能看到这个过程通过解析xml的数据后，就能通过这些数据生成一个个PackageInstallerSession对象，如果还有效则保存在mSessions。接着不管是否有效都会保存在mAllocatedSessions，告诉Android系统已经实例化了这么多的Seesion对象。

- 3.reconcileStagesLocked 清除安装阶段性的临时文件
```java
    private void reconcileStagesLocked(String volumeUuid, boolean isEphemeral) {
        final File stagingDir = buildStagingDir(volumeUuid, isEphemeral);
        final ArraySet<File> unclaimedStages = newArraySet(
                stagingDir.listFiles(sStageFilter));

        for (int i = 0; i < mSessions.size(); i++) {
            final PackageInstallerSession session = mSessions.valueAt(i);
            unclaimedStages.remove(session.stageDir);
        }

        for (File stage : unclaimedStages) {
            synchronized (mPm.mInstallLock) {
                mPm.removeCodePathLI(stage);
            }
        }
    }

    private static final FilenameFilter sStageFilter = new FilenameFilter() {
        @Override
        public boolean accept(File dir, String name) {
            return isStageName(name);
        }
    };

    public static boolean isStageName(String name) {
        final boolean isFile = name.startsWith("vmdl") && name.endsWith(".tmp");
        final boolean isContainer = name.startsWith("smdl") && name.endsWith(".tmp");
        final boolean isLegacyContainer = name.startsWith("smdl2tmp");
        return isFile || isContainer || isLegacyContainer;
    }

    private File buildStagingDir(String volumeUuid, boolean isEphemeral) {
        return Environment.getDataAppDirectory(volumeUuid);
    }
```
- 实际上在volumeUuid对应的参数就是`StorageManager.UUID_PRIVATE_INTERNAL`而他是一个为null的static final的成员变量。因此实际上就是构建了一个`/data/app`的目录。

- 拿到该目录下所有的数据临时数据，这些临时数据一般为(`vmdlxx.tmp`,`smdlxxx.tmp`,`smdl2tmpxxx`)，从这个集合中挑选出没有session对应的临时文件并删除。

- 遍历这些临时数据，调用PMS的removeCodePathLI，移除缓存在PMS这些临时文件对应的扫描结果

- 4.遍历`/data/system/install_sessions/`中所有的文件，并且从unclaimedIcons集合移除每一个Session对象的`app_icon.sessionId.png`也就是临时的安装应用图标，最后删除剩下哪些没有sessionId对应的临时应用图标文件。
```java
    private File buildAppIconFile(int sessionId) {
        return new File(mSessionsDir, "app_icon." + sessionId + ".png");
    }
```

#### PackageInstaller createSession
/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[base](http://androidxref.com/9.0.0_r3/xref/frameworks/base/)/[core](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/)/[java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/)/[android](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/)/[content](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/)/[pm](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/)/[PackageInstaller.java](http://androidxref.com/9.0.0_r3/xref/frameworks/base/core/java/android/content/pm/PackageInstaller.java)

```java
    public int createSession(@NonNull SessionParams params) throws IOException {
        try {
            final String installerPackage;
            if (params.installerPackageName == null) {
                installerPackage = mInstallerPackageName;
            } else {
                installerPackage = params.installerPackageName;
            }

            return mInstaller.createSession(params, installerPackage, mUserId);
        } catch (RuntimeException e) {
            ExceptionUtils.maybeUnwrapIOException(e);
            throw e;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
这个过程很简单，就是调用了PackageInstallerService的createSession，而这个方法最终会调用到createSessionInternal中


##### PackageInstallerService createSessionInternal

```java
   private int createSessionInternal(SessionParams params, String installerPackageName, int userId)
            throws IOException {
...
        if ((callingUid == Process.SHELL_UID) || (callingUid == Process.ROOT_UID)) {
            params.installFlags |= PackageManager.INSTALL_FROM_ADB;

        } else {

            if (mContext.checkCallingOrSelfPermission(Manifest.permission.INSTALL_PACKAGES) !=
                    PackageManager.PERMISSION_GRANTED) {
                mAppOps.checkPackage(callingUid, installerPackageName);
            }

            params.installFlags &= ~PackageManager.INSTALL_FROM_ADB;
            params.installFlags &= ~PackageManager.INSTALL_ALL_USERS;
            params.installFlags |= PackageManager.INSTALL_REPLACE_EXISTING;
            if ((params.installFlags & PackageManager.INSTALL_VIRTUAL_PRELOAD) != 0
                    && !mPm.isCallerVerifier(callingUid)) {
                params.installFlags &= ~PackageManager.INSTALL_VIRTUAL_PRELOAD;
            }
        }

...
        // Defensively resize giant app icons
        if (params.appIcon != null) {
            final ActivityManager am = (ActivityManager) mContext.getSystemService(
                    Context.ACTIVITY_SERVICE);
            final int iconSize = am.getLauncherLargeIconSize();
            if ((params.appIcon.getWidth() > iconSize * 2)
                    || (params.appIcon.getHeight() > iconSize * 2)) {
                params.appIcon = Bitmap.createScaledBitmap(params.appIcon, iconSize, iconSize,
                        true);
            }
        }

        if ((params.installFlags & PackageManager.INSTALL_INTERNAL) != 0) {
....
        } else if ((params.installFlags & PackageManager.INSTALL_EXTERNAL) != 0) {
....

        } else if ((params.installFlags & PackageManager.INSTALL_FORCE_VOLUME_UUID) != 0) {

....

        } else {

            params.setInstallFlagsInternal();

            final long ident = Binder.clearCallingIdentity();
            try {
                params.volumeUuid = PackageHelper.resolveInstallVolume(mContext, params);
            } finally {
                Binder.restoreCallingIdentity(ident);
            }
        }

...

        final int sessionId;
        final PackageInstallerSession session;
        synchronized (mSessions) {
            final int activeCount = getSessionCount(mSessions, callingUid);
...
            final int historicalCount = mHistoricalSessionsByInstaller.get(callingUid);
...
            sessionId = allocateSessionIdLocked();
        }

        final long createdMillis = System.currentTimeMillis();
        // We're staging to exactly one location
        File stageDir = null;
        String stageCid = null;
        if ((params.installFlags & PackageManager.INSTALL_INTERNAL) != 0) {
            final boolean isInstant =
                    (params.installFlags & PackageManager.INSTALL_INSTANT_APP) != 0;
            stageDir = buildStageDir(params.volumeUuid, sessionId, isInstant);
        } else {
            stageCid = buildExternalStageCid(sessionId);
        }

        session = new PackageInstallerSession(mInternalCallback, mContext, mPm,
                mInstallThread.getLooper(), sessionId, userId, installerPackageName, callingUid,
                params, createdMillis, stageDir, stageCid, false, false);

        synchronized (mSessions) {
            mSessions.put(sessionId, session);
        }

        mCallbacks.notifySessionCreated(session.sessionId, session.userId);
        writeSessionsAsync();
        return sessionId;
    }
```
  - 1.从ActivityManager 获取全局配置下，当前配置下的dp数值以及图标大小，从而计算出应用图标对应的bitmap大小，并提前申请出内存出来.

  - 2.PackageHelper.resolveInstallVolume 拿到磁盘中最合适安装的扇区的uuid，保存到SessionParams的volumeUuid中。setInstallFlagsInternal设置installFlags带上INSTALL_INTERNAL
```java
        public void setInstallFlagsInternal() {
            installFlags |= PackageManager.INSTALL_INTERNAL;
            installFlags &= ~PackageManager.INSTALL_EXTERNAL;
        }
```

  - 3.从Int的最大数值内挑选一个没有使用过的随机数，成为新的PackageInstallerSession的id。

  - 4.如果PackageManager.INSTALL_INTERNAL不为空，则会通过buildStageDir方法生成一个特殊文件：
```java
    private File buildStageDir(String volumeUuid, int sessionId, boolean isEphemeral) {
        final File stagingDir = buildStagingDir(volumeUuid, isEphemeral);
        return new File(stagingDir, "vmdl" + sessionId + ".tmp");
    }
    private File buildStagingDir(String volumeUuid, boolean isEphemeral) {
        return Environment.getDataAppDirectory(volumeUuid);
    }
```
```java
    public static File getDataAppDirectory(String volumeUuid) {
        return new File(getDataDirectory(volumeUuid), "app");
    }

    public static File getDataDirectory(String volumeUuid) {
        if (TextUtils.isEmpty(volumeUuid)) {
            return DIR_ANDROID_DATA;
        } else {
            return new File("/mnt/expand/" + volumeUuid);
        }
    }
```
当不传入需要安装的扇区uuid时候则为`/data/app/vmdlsessionId.tmp`文件，但是如果传入了，整个文件就变成了`/data/app/volumeUuid/vmdlsessionId.tmp`

注意此时如果能在私有磁盘(也就是内置存储器)内找到剩余空间进行安装`/data/app/vmdlsessionId.tmp`，如果找不到则安装到`/mnt/expand/volumeUuid/vmdlsessionId.tmp`(也就是类似U盘的外部存储器)

  - 5.否则则生成一个新的名字`smdlsessionid.tmp`名字保存到PackageInstallerSession中。

  - 6.生成一个PackageInstallerSession对象，并保存到mSessions这个Map中，唤醒监听者notifySessionCreated的Session创建成功的监听

  - 7.writeSessionsAsync 通过IO线程，调用PackageInstallerSession的write方法，把数据全部写入到PackageInstallerSession的
```java
    private void writeSessionsLocked() {
        FileOutputStream fos = null;
        try {
            fos = mSessionsFile.startWrite();

            XmlSerializer out = new FastXmlSerializer();
            out.setOutput(fos, StandardCharsets.UTF_8.name());
            out.startDocument(null, true);
            out.startTag(null, TAG_SESSIONS);
            final int size = mSessions.size();
            for (int i = 0; i < size; i++) {
                final PackageInstallerSession session = mSessions.valueAt(i);
                session.write(out, mSessionsDir);
            }
            out.endTag(null, TAG_SESSIONS);
            out.endDocument();

            mSessionsFile.finishWrite(fos);
        } catch (IOException e) {
            if (fos != null) {
                mSessionsFile.failWrite(fos);
            }
        }
    }
```
其实这个过程就很简单了，就是往`/data/system/install_sessions.xml`中写入当前PackageInstallerSession的配置数据。

#### InstallInstalling onResume
onCreate考察完了，我们来看看onResume.
```java
    protected void onResume() {
        super.onResume();

        if (mInstallingTask == null) {
            PackageInstaller installer = getPackageManager().getPackageInstaller();
            PackageInstaller.SessionInfo sessionInfo = installer.getSessionInfo(mSessionId);

            if (sessionInfo != null && !sessionInfo.isActive()) {
                mInstallingTask = new InstallingAsyncTask();
                mInstallingTask.execute();
            } else {
                // we will receive a broadcast when the install is finished
                mCancelButton.setEnabled(false);
                setFinishOnTouchOutside(false);
            }
        }
    }
```
在onCreate的过程通过PackageInstallerService的CreateSession方法获取到每一个Session对应的id，此时通过id反过来找到每一个SessionInfo，并开始执行这个InstallingAsyncTask这个AsyncTask。



#### InstallingAsyncTask的异步执行
```java
        @Override
        protected PackageInstaller.Session doInBackground(Void... params) {
            PackageInstaller.Session session;
            try {
                session = getPackageManager().getPackageInstaller().openSession(mSessionId);
            } catch (IOException e) {
                return null;
            }

            session.setStagingProgress(0);

            try {
                File file = new File(mPackageURI.getPath());

                try (InputStream in = new FileInputStream(file)) {
                    long sizeBytes = file.length();
                    try (OutputStream out = session
                            .openWrite("PackageInstaller", 0, sizeBytes)) {
                        byte[] buffer = new byte[1024 * 1024];
                        while (true) {
                            int numRead = in.read(buffer);

                            if (numRead == -1) {
                                session.fsync(out);
                                break;
                            }

                            if (isCancelled()) {
                                session.close();
                                break;
                            }

                            out.write(buffer, 0, numRead);
                            if (sizeBytes > 0) {
                                float fraction = ((float) numRead / (float) sizeBytes);
                                session.addProgress(fraction);
                            }
                        }
                    }
                }

                return session;
            } catch (IOException | SecurityException e) {
                session.close();

                return null;
            } finally {
                synchronized (this) {
                    isDone = true;
                    notifyAll();
                }
            }
        }
```
实际上，InstallingAsyncTask的异步线程的工作就是在通过PackageInstallerService.openSession方法打开一个session，并通过FileInputStream读取临时apk文件的数据流，并通过session.openWrite ，把临时apk数据往session的OutputSream中写入。

依次看看openSession和openWrite都做了什么？

##### PackageInstaller openSession
```java
    public @NonNull Session openSession(int sessionId) throws IOException {
        try {
            return new Session(mInstaller.openSession(sessionId));
        } catch (RuntimeException e) {
            ExceptionUtils.maybeUnwrapIOException(e);
            throw e;
        } catch (RemoteException e) {
            throw e.rethrowFromSystemServer();
        }
    }
```
很简单，调用了PackageInstallerService的openSession，获得IPackageInstallerSession这个Binder对象，并且包装成一个Session对象返回。

##### PackageInstallerService openSession
```java
    private IPackageInstallerSession openSessionInternal(int sessionId) throws IOException {
        synchronized (mSessions) {
            final PackageInstallerSession session = mSessions.get(sessionId);
...
            session.open();
            return session;
        }
    }
```
核心还是PacakgeInstallerSession的open方法。
```java
    public void open() throws IOException {
        if (mActiveCount.getAndIncrement() == 0) {
            mCallback.onSessionActiveChanged(this, true);
        }

        boolean wasPrepared;
        synchronized (mLock) {
            wasPrepared = mPrepared;
            if (!mPrepared) {
                if (stageDir != null) {
                    prepareStageDir(stageDir);
                } else {
                    throw new IllegalArgumentException("stageDir must be set");
                }

                mPrepared = true;
            }
        }

        if (!wasPrepared) {
            mCallback.onSessionPrepared(this);
        }
    }

    static void prepareStageDir(File stageDir) throws IOException {

        try {
            Os.mkdir(stageDir.getAbsolutePath(), 0755);
            Os.chmod(stageDir.getAbsolutePath(), 0755);
        } catch (ErrnoException e) {
     
            throw new IOException("Failed to prepare session dir: " + stageDir, e);
        }

        if (!SELinux.restorecon(stageDir)) {
            throw new IOException("Failed to restorecon session dir: " + stageDir);
        }
    }
```
这里实际上就是给安装的目录做了准备的工作，把`/mnt/expand/volumeUuid/vmdlsessionId.tmp`这个文件设置权限为0755,也就是当前用户允许操作所有权限，同用户组或者其他用户的权限只能读执行。

##### PackageInstaller.Session openWrite
```java
        public @NonNull OutputStream openWrite(@NonNull String name, long offsetBytes,
                long lengthBytes) throws IOException {
            try {
                if (ENABLE_REVOCABLE_FD) {
                    return new ParcelFileDescriptor.AutoCloseOutputStream(
                            mSession.openWrite(name, offsetBytes, lengthBytes));
                } else {
                    final ParcelFileDescriptor clientSocket = mSession.openWrite(name,
                            offsetBytes, lengthBytes);
                    return new FileBridge.FileBridgeOutputStream(clientSocket);
                }
            } catch (RuntimeException e) {
                ExceptionUtils.maybeUnwrapIOException(e);
                throw e;
            } catch (RemoteException e) {
                throw e.rethrowFromSystemServer();
            }
        }
```
核心还是调用PackageInstallerSession的openWrite后，获取到ParcelFileDescriptor对象通过ParcelFileDescriptor.AutoCloseOutputStream或者FileBridge.FileBridgeOutputStream封装成OutputStream。

而PackageInstallerSession的openWrite核心会调用到doWriteInternal。这里我们先只关注ENABLE_REVOCABLE_FD为false的情况。

##### PackageInstallerSession doWriteInternal
```java

    private ParcelFileDescriptor doWriteInternal(String name, long offsetBytes, long lengthBytes,
            ParcelFileDescriptor incomingFd) throws IOException {

        final RevocableFileDescriptor fd;
        final FileBridge bridge;
        final File stageDir;
        synchronized (mLock) {
            assertCallerIsOwnerOrRootLocked();
            assertPreparedAndNotSealedLocked("openWrite");

            if (PackageInstaller.ENABLE_REVOCABLE_FD) {
                fd = new RevocableFileDescriptor();
                bridge = null;
                mFds.add(fd);
            } else {
                fd = null;
                bridge = new FileBridge();
                mBridges.add(bridge);
            }

            stageDir = resolveStageDirLocked();
        }

        try {
            if (!FileUtils.isValidExtFilename(name)) {
                throw new IllegalArgumentException("Invalid name: " + name);
            }
            final File target;
            final long identity = Binder.clearCallingIdentity();
            try {
                target = new File(stageDir, name);
            } finally {
                Binder.restoreCallingIdentity(identity);
            }

            final FileDescriptor targetFd = Os.open(target.getAbsolutePath(),
                    O_CREAT | O_WRONLY, 0644);
            Os.chmod(target.getAbsolutePath(), 0644);


...

            if (offsetBytes > 0) {
                Os.lseek(targetFd, offsetBytes, OsConstants.SEEK_SET);
            }
...
            if (incomingFd != null) {
...
            } else if (PackageInstaller.ENABLE_REVOCABLE_FD) {
...
            } else {
                bridge.setTargetFile(targetFd);
                bridge.start();
                return new ParcelFileDescriptor(bridge.getClientSocket());
            }

        } catch (ErrnoException e) {
            throw e.rethrowAsIOException();
        }
    }
```
- 1.就是根据stageDir目录下生成一个特殊的文件，其实就是
`/data/app/vmdlsessionId.tmp/PackageInstaller`.并调用Os.open创建这个文件，这个文件的权限是0644，也就是本用户能读写，其他和同一个用户组只能读。

- 2.创建一个新的FileBridge对象，把需要写入的对象设置到FileBridge中，并调用start方法，最后获取FileBridge的getClientSocket，设置到ParcelFileDescriptor。

##### FileBridge 原理
```java
public class FileBridge extends Thread {
    private static final String TAG = "FileBridge";

    // TODO: consider extending to support bidirectional IO

    private static final int MSG_LENGTH = 8;

    /** CMD_WRITE [len] [data] */
    private static final int CMD_WRITE = 1;
    /** CMD_FSYNC */
    private static final int CMD_FSYNC = 2;
    /** CMD_CLOSE */
    private static final int CMD_CLOSE = 3;

    private FileDescriptor mTarget;

    private final FileDescriptor mServer = new FileDescriptor();
    private final FileDescriptor mClient = new FileDescriptor();

    private volatile boolean mClosed;

    public FileBridge() {
        try {
            Os.socketpair(AF_UNIX, SOCK_STREAM, 0, mServer, mClient);
        } catch (ErrnoException e) {
           ...
        }
    }

    public boolean isClosed() {
        return mClosed;
    }

    public void forceClose() {
        IoUtils.closeQuietly(mTarget);
        IoUtils.closeQuietly(mServer);
        IoUtils.closeQuietly(mClient);
        mClosed = true;
    }

    public void setTargetFile(FileDescriptor target) {
        mTarget = target;
    }

    public FileDescriptor getClientSocket() {
        return mClient;
    }

    @Override
    public void run() {
        final byte[] temp = new byte[8192];
        try {
            while (IoBridge.read(mServer, temp, 0, MSG_LENGTH) == MSG_LENGTH) {
                final int cmd = Memory.peekInt(temp, 0, ByteOrder.BIG_ENDIAN);
                if (cmd == CMD_WRITE) {
                    // Shuttle data into local file
                    int len = Memory.peekInt(temp, 4, ByteOrder.BIG_ENDIAN);
                    while (len > 0) {
                        int n = IoBridge.read(mServer, temp, 0, Math.min(temp.length, len));
...
                        IoBridge.write(mTarget, temp, 0, n);
                        len -= n;
                    }

                } else if (cmd == CMD_FSYNC) {
                    Os.fsync(mTarget);
                    IoBridge.write(mServer, temp, 0, MSG_LENGTH);
                } else if (cmd == CMD_CLOSE) {
                    Os.fsync(mTarget);
                    Os.close(mTarget);
                    mClosed = true;
                    IoBridge.write(mServer, temp, 0, MSG_LENGTH);
                    break;
                }
            }

        } catch (ErrnoException | IOException e) {
        } finally {
            forceClose();
        }
    }
}
```
FileBridge在构造函数中，通过 Os.socketpair 生成一对socket。一旦启动了线程，FileBridge就会开始监听mServer 服务端的socket是否有数据到来，有数据到来，则开始分析当前的命令是什么并执行相应的操作，命令结构如下：
| socket数据 | 头8位高4位 | 头8位低4位 | 头8位的决定的长度内容 |
| ---------- | ---------- | ---------- | --------------------- |
| 意义       | 命令       | 长度       | 传递过来的数据内容    |

- 先从mServer的服务端socket读取当前数据的命令和命令中对应数据的长度

- CMD_WRITE 说明需要开始写入数据，从socket中读取长度对应的内容，并把当前的数据写入到设置到FileBridge中的mTarget中

- CMD_FSYNC 则把mTarget对应缓存数据刷到mTarget这个文件中

- CMD_CLOSE 则关闭服务端socket的监听和需要写入的文件fd。


##### FileBridgeOutputStream 写入原理
```java
        public void write(byte[] buffer, int byteOffset, int byteCount) throws IOException {
            Arrays.checkOffsetAndCount(buffer.length, byteOffset, byteCount);
            Memory.pokeInt(mTemp, 0, CMD_WRITE, ByteOrder.BIG_ENDIAN);
            Memory.pokeInt(mTemp, 4, byteCount, ByteOrder.BIG_ENDIAN);
            IoBridge.write(mClient, mTemp, 0, MSG_LENGTH);
            IoBridge.write(mClient, buffer, byteOffset, byteCount);
        }
```
整个流程就是不断的往mClient 的socket端口写入数据，先写入命令CMD_WRITE，然后byteCount但是这个过程是以BIG_ENDIAN写入，因此两个顺序是颠倒的。最后是apk包数据内容。

当写完数据之后，就会调用FileBridgeOutputStream的fsync方法。

```java
        public void fsync() throws IOException {
            writeCommandAndBlock(CMD_FSYNC, "fsync()");
        }

        private void writeCommandAndBlock(int cmd, String cmdString) throws IOException {
            Memory.pokeInt(mTemp, 0, cmd, ByteOrder.BIG_ENDIAN);
            IoBridge.write(mClient, mTemp, 0, MSG_LENGTH);

            if (IoBridge.read(mClient, mTemp, 0, MSG_LENGTH) == MSG_LENGTH) {
                if (Memory.peekInt(mTemp, 0, ByteOrder.BIG_ENDIAN) == cmd) {
                    return;
                }
            }

            throw new IOException("Failed to execute " + cmdString + " across bridge");
        }
```
这个过程很简单就是写入了一个CMD_FSYNC命令交给正在监听的FileBridge处理，调用Os.fsync从缓存刷入磁盘。

通过这种方式，就把临时文件`/data/no_backup/packagexxx.apk`拷贝到`/data/app/vmdlsessionId.tmp/PackageInstaller`中。



#### InstallingAsyncTask onPostExecute
当拷贝app的事件完成之后，就会回到主线程回调InstallingAsyncTask的onPostExecute。

```java
        protected void onPostExecute(PackageInstaller.Session session) {
            if (session != null) {
                Intent broadcastIntent = new Intent(BROADCAST_ACTION);
                broadcastIntent.setFlags(Intent.FLAG_RECEIVER_FOREGROUND);
                broadcastIntent.setPackage(
                        getPackageManager().getPermissionControllerPackageName());
                broadcastIntent.putExtra(EventResultPersister.EXTRA_ID, mInstallId);

                PendingIntent pendingIntent = PendingIntent.getBroadcast(
                        InstallInstalling.this,
                        mInstallId,
                        broadcastIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT);

                session.commit(pendingIntent.getIntentSender());
                mCancelButton.setEnabled(false);
                setFinishOnTouchOutside(false);
            } else {
                ...
            }
        }
```
构造一个BROADCAST_ACTION(`com.android.packageinstaller.ACTION_INSTALL_COMMIT`)的PendingIntent广播，调用session的commit方法，进行发送。


##### PackageInstaller.Session commit
```java
        public void commit(@NonNull IntentSender statusReceiver) {
            try {
                mSession.commit(statusReceiver, false);
            } catch (RemoteException e) {
                throw e.rethrowFromSystemServer();
            }
        }
```
实际上就是调用了PackageInstallerSession的commit方法。

##### PackageInstallerSession commit
```java
    public void commit(@NonNull IntentSender statusReceiver, boolean forTransfer) {
        Preconditions.checkNotNull(statusReceiver);

        final boolean wasSealed;
        synchronized (mLock) {
            assertCallerIsOwnerOrRootLocked();
            assertPreparedAndNotDestroyedLocked("commit");

            final PackageInstallObserverAdapter adapter = new PackageInstallObserverAdapter(
                    mContext, statusReceiver, sessionId,
                    isInstallerDeviceOwnerOrAffiliatedProfileOwnerLocked(), userId);
            mRemoteObserver = adapter.getBinder();

...
            wasSealed = mSealed;
            if (!mSealed) {
                try {
                    sealAndValidateLocked();
                } catch (IOException e) {
...
                } catch (PackageManagerException e) {
...
                    return;
                }
            }

            mClientProgress = 1f;
            computeProgressLocked(true);

            mActiveCount.incrementAndGet();

            mCommitted = true;
            mHandler.obtainMessage(MSG_COMMIT).sendToTarget();
        }

        if (!wasSealed) {
            mCallback.onSessionSealedBlocking(this);
        }
    }

```
- 1.构建一个PackageInstallObserverAdapter对象，并获取其中的Binder对象也就是IPackageInstallObserver2.
```java
    private final IPackageInstallObserver2.Stub mBinder = new IPackageInstallObserver2.Stub() {
        @Override
        public void onUserActionRequired(Intent intent) {
            PackageInstallObserver.this.onUserActionRequired(intent);
        }

        @Override
        public void onPackageInstalled(String basePackageName, int returnCode,
                String msg, Bundle extras) {
            PackageInstallObserver.this.onPackageInstalled(basePackageName, returnCode, msg,
                    extras);
        }
    };
```
这个Binder将会监听从远程端发送过来onPackageInstalled安装完毕的消息。

- 2.sealAndValidateLocked 把当前拷贝过来的文件进行一次重命名，并且清除该文件夹下可能安装过的临时文件

- 3.computeProgressLocked 计算进度并且回调

- 4.发送MSG_COMMIT 的Handler消息

核心是来看看后面2点。

##### sealAndValidateLocked
```java
    private void sealAndValidateLocked() throws PackageManagerException, IOException {
        assertNoWriteFileTransfersOpenLocked();
        assertPreparedAndNotDestroyedLocked("sealing of session");

        final PackageInfo pkgInfo = mPm.getPackageInfo(
                params.appPackageName, PackageManager.GET_SIGNATURES
                        | PackageManager.MATCH_STATIC_SHARED_LIBRARIES /*flags*/, userId);

        resolveStageDirLocked();

        mSealed = true;

        try {
            validateInstallLocked(pkgInfo);
        } catch (PackageManagerException e) {
            throw e;
        } catch (Throwable e) {

            throw new PackageManagerException(e);
        }

    }
```
能看到这个过程先通过PMS的getPackageInfo获取包内容，接着调用validateInstallLocked根据包内容进一步的处理事务。
```java
    private File resolveStageDirLocked() throws IOException {
        if (mResolvedStageDir == null) {
            if (stageDir != null) {
                mResolvedStageDir = stageDir;
            } else {
                throw new IOException("Missing stageDir");
            }
        }
        return mResolvedStageDir;
    }
```
设置了mResolvedStageDir为stageDir，也就是`/data/app/vmdlsessionId.tmp/`




```java
   private void validateInstallLocked(@Nullable PackageInfo pkgInfo)
            throws PackageManagerException {
        mPackageName = null;
        mVersionCode = -1;
        mSigningDetails = PackageParser.SigningDetails.UNKNOWN;

        mResolvedBaseFile = null;
        mResolvedStagedFiles.clear();
        mResolvedInheritedFiles.clear();

        try {
            resolveStageDirLocked();
        } catch (IOException e) {
...
        }

        final File[] removedFiles = mResolvedStageDir.listFiles(sRemovedFilter);
        final List<String> removeSplitList = new ArrayList<>();
        if (!ArrayUtils.isEmpty(removedFiles)) {
            for (File removedFile : removedFiles) {
                final String fileName = removedFile.getName();
                final String splitName = fileName.substring(
                        0, fileName.length() - REMOVE_SPLIT_MARKER_EXTENSION.length());
                removeSplitList.add(splitName);
            }
        }

        final File[] addedFiles = mResolvedStageDir.listFiles(sAddedFilter);
...

        final ArraySet<String> stagedSplits = new ArraySet<>();
        for (File addedFile : addedFiles) {
            final ApkLite apk;
            try {
                apk = PackageParser.parseApkLite(
                        addedFile, PackageParser.PARSE_COLLECT_CERTIFICATES);
            } catch (PackageParserException e) {
                throw PackageManagerException.from(e);
            }

...
            if (mPackageName == null) {
                mPackageName = apk.packageName;
                mVersionCode = apk.getLongVersionCode();
            }
            if (mSigningDetails == PackageParser.SigningDetails.UNKNOWN) {
                mSigningDetails = apk.signingDetails;
            }
...
            final String targetName;
            if (apk.splitName == null) {
                targetName = "base" + APK_FILE_EXTENSION;
            } else {
                targetName = "split_" + apk.splitName + APK_FILE_EXTENSION;
            }
...
            final File targetFile = new File(mResolvedStageDir, targetName);
            maybeRenameFile(addedFile, targetFile);

            // Base is coming from session
            if (apk.splitName == null) {
                mResolvedBaseFile = targetFile;
            }

            mResolvedStagedFiles.add(targetFile);

            final File dexMetadataFile = DexMetadataHelper.findDexMetadataForFile(addedFile);
            if (dexMetadataFile != null) {
...
                final File targetDexMetadataFile = new File(mResolvedStageDir,
                        DexMetadataHelper.buildDexMetadataPathForApk(targetName));
                mResolvedStagedFiles.add(targetDexMetadataFile);
                maybeRenameFile(dexMetadataFile, targetDexMetadataFile);
            }
        }

...

        if (params.mode == SessionParams.MODE_FULL_INSTALL) {
...

        } else {
...
        }
    }
```
- 1.resolveStageDirLocked 做的事情其实就是把stageDir赋值给mResolvedStageDir中，也就是`/data/app/vmdlsessionId.tmp/`

- 2.遍历mResolvedStageDir文件夹中`/data/app/vmdlsessionId.tmp/`所有的文件，能通过sRemovedFilter和sAddedFilter识别出哪些文件需要删除，哪些文件是本次需要添加到安装流程中。
```java
    private static final FileFilter sAddedFilter = new FileFilter() {
        @Override
        public boolean accept(File file) {
            if (file.isDirectory()) return false;
            if (file.getName().endsWith(REMOVE_SPLIT_MARKER_EXTENSION)) return false;
            if (DexMetadataHelper.isDexMetadataFile(file)) return false;
            return true;
        }
    };

    private static final String REMOVE_SPLIT_MARKER_EXTENSION = ".removed";
    private static final FileFilter sRemovedFilter = new FileFilter() {
        @Override
        public boolean accept(File file) {
            if (file.isDirectory()) return false;
            if (!file.getName().endsWith(REMOVE_SPLIT_MARKER_EXTENSION)) return false;
            return true;
        }
    };
```
对于需要删除的都是带了`.remove`后缀的文件，需要添加到安装的除了目录文件，`.dm`，`.remove`的文件。

- 3.拿到这些需要添加到安装的流程的文件后，则对每一个apk包通过PackageParser.parseApkLite解析出AndroidManifest最顶层的xml内容出来。获得其版本号，包名，签名等数据，并以包名为基础转化为两种形式的名字：
  - 1.如果apk没有进行分割,则名字为`base.apk`
  - 2.如果分割，则为 `split_splitname.apk`
并在`/data/app/vmdlsessionId.tmp/`中生成一个该文件名的实例File(也就是`/data/app/vmdlsessionId.tmp/base.apk`)，最后添加到mResolvedStagedFiles集合中。接着校验这个apk文件在有没有对应的`包名.dm`文件，存在则生成一个`/data/app/vmdlsessionId.tmp/base.dm`文件.

#### PackageInstallSession计算安装进度原理
```java
    private void computeProgressLocked(boolean forcePublish) {
        mProgress = MathUtils.constrain(mClientProgress * 0.8f, 0f, 0.8f)
                + MathUtils.constrain(mInternalProgress * 0.2f, 0f, 0.2f);

        if (forcePublish || Math.abs(mProgress - mReportedProgress) >= 0.01) {
            mReportedProgress = mProgress;
            mCallback.onSessionProgressChanged(this, mProgress);
        }
    }
```
决定当前安装进度的有两个，是mClientProgress和mInternalProgress。mClientProgress是指来自PackageInstallerSession之外的PMS的安装进度，另一方面就是mInternalProgress也就是PackageInstallSession本身的进度.

> mClientProgress的进度要乘以0.8,并且把这个结果约束到0～0.8之间。
> mInternalProgress的进度需要乘以0.5,并且把结果约束到0～0.2之间



#### PackageInstallSession 发送MSG_COMMIT 的Handler消息
在PackageInstallerService的mInstallThread中接收到MSG_COMMIT，就会执行commitLocked方法：
```java
    private void commitLocked()
            throws PackageManagerException {
...

        if (params.mode == SessionParams.MODE_INHERIT_EXISTING) {
            try {
                final List<File> fromFiles = mResolvedInheritedFiles;
                final File toDir = resolveStageDirLocked();

                if (isLinkPossible(fromFiles, toDir)) {
                    if (!mResolvedInstructionSets.isEmpty()) {
                        final File oatDir = new File(toDir, "oat");
                        createOatDirs(mResolvedInstructionSets, oatDir);
                    }
                    if (!mResolvedNativeLibPaths.isEmpty()) {
                        for (String libPath : mResolvedNativeLibPaths) {
                            final int splitIndex = libPath.lastIndexOf('/');
                            if (splitIndex < 0 || splitIndex >= libPath.length() - 1) {
                                continue;
                            }
                            final String libDirPath = libPath.substring(1, splitIndex);
                            final File libDir = new File(toDir, libDirPath);
                            if (!libDir.exists()) {
                                NativeLibraryHelper.createNativeLibrarySubdir(libDir);
                            }
                            final String archDirPath = libPath.substring(splitIndex + 1);
                            NativeLibraryHelper.createNativeLibrarySubdir(
                                    new File(libDir, archDirPath));
                        }
                    }
                    linkFiles(fromFiles, toDir, mInheritedFilesBase);
                } else {
                    copyFiles(fromFiles, toDir);
                }
            } catch (IOException e) {
...
            }
        }

        mInternalProgress = 0.5f;
        computeProgressLocked(true);

        extractNativeLibraries(mResolvedStageDir, params.abiOverride, mayInheritNativeLibs());

        final IPackageInstallObserver2 localObserver = new IPackageInstallObserver2.Stub() {
            @Override
            public void onUserActionRequired(Intent intent) {
                throw new IllegalStateException();
            }

            @Override
            public void onPackageInstalled(String basePackageName, int returnCode, String msg,
                    Bundle extras) {
                destroyInternal();
                dispatchSessionFinished(returnCode, msg, extras);
            }
        };

        final UserHandle user;
        if ((params.installFlags & PackageManager.INSTALL_ALL_USERS) != 0) {
            user = UserHandle.ALL;
        } else {
            user = new UserHandle(userId);
        }

        mRelinquished = true;
        mPm.installStage(mPackageName, stageDir, localObserver, params,
                mInstallerPackageName, mInstallerUid, user, mSigningDetails);
    }
```

- 1.如果是SessionParams.MODE_INHERIT_EXISTING安装模式，那么说明是进行安装覆盖，则会遍历该目录下所有的文件。通过isLinkPossible来检查安装原有的文件和当前的原有的文件，mResolvedInheritedFiles中的文件是否可以进行覆盖，如果文件信息一致说明可以覆盖，不能则直接拷贝到`/data/app/vmdlsessionId.tmp/`目录下。

- 2.mInternalProgress 设置为0.5，并且更新进度条回调给正在监听的Activity

- 3.extractNativeLibraries 
```java
    private static void extractNativeLibraries(File packageDir, String abiOverride, boolean inherit)
            throws PackageManagerException {
        final File libDir = new File(packageDir, NativeLibraryHelper.LIB_DIR_NAME);
        if (!inherit) {
            NativeLibraryHelper.removeNativeBinariesFromDirLI(libDir, true);
        }

        NativeLibraryHelper.Handle handle = null;
        try {
            handle = NativeLibraryHelper.Handle.create(packageDir);
            final int res = NativeLibraryHelper.copyNativeBinariesWithOverride(handle, libDir,
                    abiOverride);
...
        } catch (IOException e) {
...
        } finally {
            IoUtils.closeQuietly(handle);
        }
    }
```
创建`/data/app/vmdlsessionId.tmp/lib`，copyNativeBinariesWithOverride并在这个文件下创建该系统支持的一系列的如64位，32位的arm-v7的so库保存目录

- 4.把localObserver这个本地Binder作为参数调用PMS的installStage方法，此时安装步骤将会转移到PMS中。之后等到PMS到达了某个阶段就会回调到onPackageInstalled，从而得知PMS那边安装完成了。


#### PMS installStage PMS中的安装步骤
```java
    void installStage(String packageName, File stagedDir,
            IPackageInstallObserver2 observer, PackageInstaller.SessionParams sessionParams,
            String installerPackageName, int installerUid, UserHandle user,
            PackageParser.SigningDetails signingDetails) {

        final VerificationInfo verificationInfo = new VerificationInfo(
                sessionParams.originatingUri, sessionParams.referrerUri,
                sessionParams.originatingUid, installerUid);

        final OriginInfo origin = OriginInfo.fromStagedFile(stagedDir);

        final Message msg = mHandler.obtainMessage(INIT_COPY);
        final int installReason = fixUpInstallReason(installerPackageName, installerUid,
                sessionParams.installReason);
        final InstallParams params = new InstallParams(origin, null, observer,
                sessionParams.installFlags, installerPackageName, sessionParams.volumeUuid,
                verificationInfo, user, sessionParams.abiOverride,
                sessionParams.grantedRuntimePermissions, signingDetails, installReason);
        
        msg.obj = params;
...
        mHandler.sendMessage(msg);
    }


```

```java

        static OriginInfo fromStagedFile(File file) {
            return new OriginInfo(file, true, false);
        }

        private OriginInfo(File file, boolean staged, boolean existing) {
            this.file = file;
            this.staged = staged;
            this.existing = existing;

            if (file != null) {
                resolvedPath = file.getAbsolutePath();
                resolvedFile = file;
            } else {
                resolvedPath = null;
                resolvedFile = null;
            }
        }
```
很见到就是发送了一个INIT_COPY的handler消息，并且把stagedDir信息存储到OriginInfo中。OriginInfo记录了stageDir的路径也就是`/data/app/vmdlsessionId.tmp`

##### PackageHandler 处理INIT_COPY消息
```java
                case INIT_COPY: {
                    HandlerParams params = (HandlerParams) msg.obj;
                    int idx = mPendingInstalls.size();

                    if (!mBound) {
                        if (!connectToService()) {
                            params.serviceError();
                            return;
                        } else {
                            mPendingInstalls.add(idx, params);
                        }
                    } else {
                        mPendingInstalls.add(idx, params);
                        if (idx == 0) {
                            mHandler.sendEmptyMessage(MCS_BOUND);
                        }
                    }
                }
```
首先第一次安装的时候mBound必定是false，就会调用connectToService尝试的绑定一个Service，如果绑定成功则把此时的安装参数HandlerParams保存到mPendingInstalls。

##### PackageHandler connectToService
```java
    public static final ComponentName DEFAULT_CONTAINER_COMPONENT = new ComponentName(
            DEFAULT_CONTAINER_PACKAGE,
            "com.android.defcontainer.DefaultContainerService");

        private boolean connectToService() {
            Intent service = new Intent().setComponent(DEFAULT_CONTAINER_COMPONENT);
            Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT);
            if (mContext.bindServiceAsUser(service, mDefContainerConn,
                    Context.BIND_AUTO_CREATE, UserHandle.SYSTEM)) {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND);
                mBound = true;
                return true;
            }
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND);
            return false;
        }
```
能看到此时先提高进程优先级到THREAD_PRIORITY_DEFAULT；并启动了一个DefaultContainerService服务，同时绑定了mDefContainerConn。成功后把进程设置回THREAD_PRIORITY_BACKGROUND。

```java
    class DefaultContainerConnection implements ServiceConnection {
        public void onServiceConnected(ComponentName name, IBinder service) {
            final IMediaContainerService imcs = IMediaContainerService.Stub
                    .asInterface(Binder.allowBlocking(service));
            mHandler.sendMessage(mHandler.obtainMessage(MCS_BOUND, imcs));
        }

        public void onServiceDisconnected(ComponentName name) {
          
        }
    }
```
值得注意的是，DefaultContainerConnection会监听Service启动后返回的Binder并且发送一个MCS_BOUND消息。

##### DefaultContainerService的Binder对象
实际上我们不需要关系这哥Service是启动都做了什么，我们关心的是返回的Binder是什么，具体的实现先不看，直接看看它的aidl接口
```java
interface IMediaContainerService {
    int copyPackage(String packagePath, in IParcelFileDescriptorFactory target);

    PackageInfoLite getMinimalPackageInfo(String packagePath, int flags, String abiOverride);
    ObbInfo getObbInfo(String filename);
    void clearDirectory(String directory);
    long calculateInstalledSize(String packagePath, String abiOverride);
}
```
很简单，就是关于PMS中进行apk包相关的操作。

#### PackageHandler 处理MCS_BOUND消息
```java
                case MCS_BOUND: {
                    if (msg.obj != null) {
                        mContainerService = (IMediaContainerService) msg.obj;
                    }
                    if (mContainerService == null) {
...
                    } else if (mPendingInstalls.size() > 0) {
                        HandlerParams params = mPendingInstalls.get(0);
                        if (params != null) {
                            if (params.startCopy()) {
                                if (mPendingInstalls.size() > 0) {
                                    mPendingInstalls.remove(0);
                                }
                                if (mPendingInstalls.size() == 0) {
                                    if (mBound) {
                                        removeMessages(MCS_UNBIND);
                                        Message ubmsg = obtainMessage(MCS_UNBIND);
                                        sendMessageDelayed(ubmsg, 10000);
                                    }
                                } else {
                                    mHandler.sendEmptyMessage(MCS_BOUND);
                                }
                            }
                        }
                    } else {
...
                    }
                    break;
                }
```
能看到在PMS的ServiceThread handleThread线程中会检查mPendingInstalls是否有需要安装的对象，有则从mPendingInstalls的头部获取HandlerParams，调用HandlerParams.startCopy方法进行拷贝，知道消费完mPendingInstalls中所有的任务则进行解绑。


##### PMS.HandlerParams startCopy
```java
        private static final int MAX_RETRIES = 4;
        final boolean startCopy() {
            boolean res;
            try {

                if (++mRetries > MAX_RETRIES) {
                    mHandler.sendEmptyMessage(MCS_GIVE_UP);
                    handleServiceError();
                    return false;
                } else {
                    handleStartCopy();
                    res = true;
                }
            } catch (RemoteException e) {
                mHandler.sendEmptyMessage(MCS_RECONNECT);
                res = false;
            }
            handleReturnCode();
            return res;
        }

```
在这个拷贝的步骤会重新的尝试4次，但是正常步骤则是调用handleStartCopy开始拷贝安装后，再调用handleReturnCode返回状态码

###### PMS.HandlerParams handleStartCopy
```java
        public void handleStartCopy() throws RemoteException {
            int ret = PackageManager.INSTALL_SUCCEEDED;

            if (origin.staged) {
                if (origin.file != null) {
                    installFlags |= PackageManager.INSTALL_INTERNAL;
                    installFlags &= ~PackageManager.INSTALL_EXTERNAL;
                } else {
                }
            }

            final boolean onSd = (installFlags & PackageManager.INSTALL_EXTERNAL) != 0;
            final boolean onInt = (installFlags & PackageManager.INSTALL_INTERNAL) != 0;
            final boolean ephemeral = (installFlags & PackageManager.INSTALL_INSTANT_APP) != 0;
            PackageInfoLite pkgLite = null;

            if (onInt && onSd) {
...
            } else if (onSd && ephemeral) {
...
            } else {
                pkgLite = mContainerService.getMinimalPackageInfo(origin.resolvedPath, installFlags,
                        packageAbiOverride);

...
            }

...

            final InstallArgs args = createInstallArgs(this);
            mArgs = args;

            if (ret == PackageManager.INSTALL_SUCCEEDED) {

                UserHandle verifierUser = getUser();
                if (verifierUser == UserHandle.ALL) {
                    verifierUser = UserHandle.SYSTEM;
                }

                final int requiredUid = mRequiredVerifierPackage == null ? -1
                        : getPackageUid(mRequiredVerifierPackage, MATCH_DEBUG_TRIAGED_MISSING,
                                verifierUser.getIdentifier());
                final int installerUid =
                        verificationInfo == null ? -1 : verificationInfo.installerUid;
                if (!origin.existing && requiredUid != -1
                        && isVerificationEnabled(
                                verifierUser.getIdentifier(), installFlags, installerUid)) {
                    final Intent verification = new Intent(
                            Intent.ACTION_PACKAGE_NEEDS_VERIFICATION);
                    verification.addFlags(Intent.FLAG_RECEIVER_FOREGROUND);
                    verification.setDataAndType(Uri.fromFile(new File(origin.resolvedPath)),
                            PACKAGE_MIME_TYPE);
                    verification.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);

                    final List<ResolveInfo> receivers = queryIntentReceiversInternal(verification,
                            PACKAGE_MIME_TYPE, 0, verifierUser.getIdentifier(),
                            false /*allowDynamicSplits*/);


                    final int verificationId = mPendingVerificationToken++;

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_ID, verificationId);

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_INSTALLER_PACKAGE,
                            installerPackageName);

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_INSTALL_FLAGS,
                            installFlags);

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_PACKAGE_NAME,
                            pkgLite.packageName);

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_VERSION_CODE,
                            pkgLite.versionCode);

                    verification.putExtra(PackageManager.EXTRA_VERIFICATION_LONG_VERSION_CODE,
                            pkgLite.getLongVersionCode());

                    if (verificationInfo != null) {
                        if (verificationInfo.originatingUri != null) {
                            verification.putExtra(Intent.EXTRA_ORIGINATING_URI,
                                    verificationInfo.originatingUri);
                        }
                        if (verificationInfo.referrer != null) {
                            verification.putExtra(Intent.EXTRA_REFERRER,
                                    verificationInfo.referrer);
                        }
                        if (verificationInfo.originatingUid >= 0) {
                            verification.putExtra(Intent.EXTRA_ORIGINATING_UID,
                                    verificationInfo.originatingUid);
                        }
                        if (verificationInfo.installerUid >= 0) {
                            verification.putExtra(PackageManager.EXTRA_VERIFICATION_INSTALLER_UID,
                                    verificationInfo.installerUid);
                        }
                    }

                    final PackageVerificationState verificationState = new PackageVerificationState(
                            requiredUid, args);

                    mPendingVerification.append(verificationId, verificationState);

                    final List<ComponentName> sufficientVerifiers = matchVerifiers(pkgLite,
                            receivers, verificationState);

                    DeviceIdleController.LocalService idleController = getDeviceIdleController();
                    final long idleDuration = getVerificationTimeout();

                    if (sufficientVerifiers != null) {
                        final int N = sufficientVerifiers.size();
                        if (N == 0) {
                            ret = PackageManager.INSTALL_FAILED_VERIFICATION_FAILURE;
                        } else {
                            for (int i = 0; i < N; i++) {
                                final ComponentName verifierComponent = sufficientVerifiers.get(i);
                                idleController.addPowerSaveTempWhitelistApp(Process.myUid(),
                                        verifierComponent.getPackageName(), idleDuration,
                                        verifierUser.getIdentifier(), false, "package verifier");

                                final Intent sufficientIntent = new Intent(verification);
                                sufficientIntent.setComponent(verifierComponent);
                                mContext.sendBroadcastAsUser(sufficientIntent, verifierUser);
                            }
                        }
                    }

                    final ComponentName requiredVerifierComponent = matchComponentForVerifier(
                            mRequiredVerifierPackage, receivers);
                    if (ret == PackageManager.INSTALL_SUCCEEDED
                            && mRequiredVerifierPackage != null) {

                        verification.setComponent(requiredVerifierComponent);
                        idleController.addPowerSaveTempWhitelistApp(Process.myUid(),
                                mRequiredVerifierPackage, idleDuration,
                                verifierUser.getIdentifier(), false, "package verifier");
                        mContext.sendOrderedBroadcastAsUser(verification, verifierUser,
                                android.Manifest.permission.PACKAGE_VERIFICATION_AGENT,
                                new BroadcastReceiver() {
                                    @Override
                                    public void onReceive(Context context, Intent intent) {
                                        final Message msg = mHandler
                                                .obtainMessage(CHECK_PENDING_VERIFICATION);
                                        msg.arg1 = verificationId;
                                        mHandler.sendMessageDelayed(msg, getVerificationTimeout());
                                    }
                                }, null, 0, null, null);

                        mArgs = null;
                    }
                } else {

                    ret = args.copyApk(mContainerService, true);
                }
            }

            mRet = ret;
        }
```

- 1.调用IMediaContainerService的getMinimalPackageInfo方法，扫描安装apk到Android系统中。

- 2.通过createInstallArgs构建InstallArgs对象，如果getMinimalPackageInfo的安装成功了，则会进行判断该包是否已经安装过且isVerificationEnabled是否允许进行包校验器进行校验。
```java
    private InstallArgs createInstallArgs(InstallParams params) {
        if (params.move != null) {
            return new MoveInstallArgs(params);
        } else {
            return new FileInstallArgs(params);
        }
    }
```
注意我们此时是FileInstallArgs，我们只考虑第一次安装apk包的情况

- 3.如果可以进行包校验,则通过data为`"application/vnd.android.package-archive"`调用queryIntentReceiversInternal方法查找有没有注册在Android系统中的包校验广播接受者；通过matchVerifiers筛选出当前合适的包校验器，最后依次发送广播，让包校验接受者根据包名，versionCode，packageName，安装来源等信息进行校验


- 4.不如出现不满足进行校验的条件，则调用InstallArgs.copyApk进行进一步的拷贝操作。


关于包校验器这里就不多聊了，核心是第1点和第4点，让我们依次看看IMediaContainerService.getMinimalPackageInfo以及InstallArgs.copyApk

##### DefaultContainerService getMinimalPackageInfo
```java
        public PackageInfoLite getMinimalPackageInfo(String packagePath, int flags,
                String abiOverride) {
            final Context context = DefaultContainerService.this;

            PackageInfoLite ret = new PackageInfoLite();

            final File packageFile = new File(packagePath);
            final PackageParser.PackageLite pkg;
            final long sizeBytes;
            try {
                pkg = PackageParser.parsePackageLite(packageFile, 0);
                sizeBytes = PackageHelper.calculateInstalledSize(pkg, abiOverride);
            } catch (PackageParserException | IOException e) {

...
            }

            final int recommendedInstallLocation;
            final long token = Binder.clearCallingIdentity();
            try {
                recommendedInstallLocation = PackageHelper.resolveInstallLocation(context,
                        pkg.packageName, pkg.installLocation, sizeBytes, flags);
            } finally {
                Binder.restoreCallingIdentity(token);
            }

            ret.packageName = pkg.packageName;
            ret.splitNames = pkg.splitNames;
            ret.versionCode = pkg.versionCode;
            ret.versionCodeMajor = pkg.versionCodeMajor;
            ret.baseRevisionCode = pkg.baseRevisionCode;
            ret.splitRevisionCodes = pkg.splitRevisionCodes;
            ret.installLocation = pkg.installLocation;
            ret.verifiers = pkg.verifiers;
            ret.recommendedInstallLocation = recommendedInstallLocation;
            ret.multiArch = pkg.multiArch;

            return ret;
        }
```
- 1.PackageParser.parsePackageLite 对apk包进行解析
- 2.PackageHelper.calculateInstalledSize 对安装后的包进行大小统计
- 3.PackageHelper.resolveInstallLocation 计算出返回的结果

###### PackageParser.parsePackageLite
```java
    public static PackageLite parsePackageLite(File packageFile, int flags)
            throws PackageParserException {
        if (packageFile.isDirectory()) {
            return parseClusterPackageLite(packageFile, flags);
        } else {
            return parseMonolithicPackageLite(packageFile, flags);
        }
    }
```
到这个方法就是解析包中的AndroidManifest最外层的数据.拿到版本号，包名，包的路径等等不包含四大组件的基础信息。注意这里将会走目录的分支，parseClusterPackageLite。这个方法其实和parseMonolithicPackageLite作用十分相似，核心还是遍历这个目录里面所有的apk文件，以splitName为key，ApkLite为value保存起来，并且找出null为key对应的baseApk的value，从而确认这个apk安装包的基础包是什么。



###### PackageHelper.calculateInstalledSize
```java
    public static long calculateInstalledSize(PackageLite pkg, NativeLibraryHelper.Handle handle,
            String abiOverride) throws IOException {
        long sizeBytes = 0;


        for (String codePath : pkg.getAllCodePaths()) {
            final File codeFile = new File(codePath);
            sizeBytes += codeFile.length();
        }


        sizeBytes += DexMetadataHelper.getPackageDexMetadataSize(pkg);

        sizeBytes += NativeLibraryHelper.sumNativeBinariesWithOverride(handle, abiOverride);

        return sizeBytes;
    }
```
计算结果是：
> 安装后大小 = 每一个包安装路径下文件的大小(`/data/app/vmdlsessionId.tmp/base.apk`)+ `.dm`后缀的文件大小 + `so`库大小


##### FileInstallArgs.copyApk
```java
        int copyApk(IMediaContainerService imcs, boolean temp) throws RemoteException {
            Trace.traceBegin(TRACE_TAG_PACKAGE_MANAGER, "copyApk");
            try {
                return doCopyApk(imcs, temp);
            } finally {
                Trace.traceEnd(TRACE_TAG_PACKAGE_MANAGER);
            }
        }

        private int doCopyApk(IMediaContainerService imcs, boolean temp) throws RemoteException {
            if (origin.staged) {
                codeFile = origin.file;
                resourceFile = origin.file;
                return PackageManager.INSTALL_SUCCEEDED;
            }

            try {
                final boolean isEphemeral = (installFlags & PackageManager.INSTALL_INSTANT_APP) != 0;
                final File tempDir =
                        mInstallerService.allocateStageDirLegacy(volumeUuid, isEphemeral);
                codeFile = tempDir;
                resourceFile = tempDir;
            } catch (IOException e) {
...
            }

            final IParcelFileDescriptorFactory target = new IParcelFileDescriptorFactory.Stub() {
                @Override
                public ParcelFileDescriptor open(String name, int mode) throws RemoteException {

                    try {
                        final File file = new File(codeFile, name);
                        final FileDescriptor fd = Os.open(file.getAbsolutePath(),
                                O_RDWR | O_CREAT, 0644);
                        Os.chmod(file.getAbsolutePath(), 0644);
                        return new ParcelFileDescriptor(fd);
                    } catch (ErrnoException e) {

                    }
                }
            };

            int ret = PackageManager.INSTALL_SUCCEEDED;
            ret = imcs.copyPackage(origin.file.getAbsolutePath(), target);
            if (ret != PackageManager.INSTALL_SUCCEEDED) {
                return ret;
            }

            final File libraryRoot = new File(codeFile, LIB_DIR_NAME);
            NativeLibraryHelper.Handle handle = null;
            try {
                handle = NativeLibraryHelper.Handle.create(codeFile);
                ret = NativeLibraryHelper.copyNativeBinariesWithOverride(handle, libraryRoot,
                        abiOverride);
            } catch (IOException e) {
           ...
            } finally {
                IoUtils.closeQuietly(handle);
            }

            return ret;
        }
```

- 1.PackageInstallerService.allocateStageDirLegacy 获取一个全新的sessionId对应目录：`/data/app/vmdlsessionId.tmp/`目录，把code和资源的路径都设置到同一处。

- 2.实例化一个IParcelFileDescriptorFactory接口，用于设置每一个创建文件时候确定权限为0644。

- 3.IMediaContainerService.copyPackage 把保存在OriginInfo的File(`/data/app/vmdlsessionId.tmp/`)拷贝到IParcelFileDescriptorFactory的路径中。

- 3.codeFile 下设置一个lib文件夹，里面包含了不同平台的so库。

###### IMediaContainerService.copyPackage
核心方法如下：
```java
        public int copyPackage(String packagePath, IParcelFileDescriptorFactory target) {
            if (packagePath == null || target == null) {
                return PackageManager.INSTALL_FAILED_INVALID_URI;
            }

            PackageLite pkg = null;
            try {
                final File packageFile = new File(packagePath);
                pkg = PackageParser.parsePackageLite(packageFile, 0);
                return copyPackageInner(pkg, target);
            } catch (PackageParserException | IOException | RemoteException e) {
...
            }
        }

    private int copyPackageInner(PackageLite pkg, IParcelFileDescriptorFactory target)
            throws IOException, RemoteException {
        copyFile(pkg.baseCodePath, target, "base.apk");
        if (!ArrayUtils.isEmpty(pkg.splitNames)) {
            for (int i = 0; i < pkg.splitNames.length; i++) {
                copyFile(pkg.splitCodePaths[i], target, "split_" + pkg.splitNames[i] + ".apk");
            }
        }

        return PackageManager.INSTALL_SUCCEEDED;
    }
```
把`/data/app/vmdlsessionId.tmp/`下的文件apk资源往另一个sessionId对应的`/data/app/vmdlsessionId.tmp/base.apk`复制拷贝。



###### PMS.HandlerParams handleReturnCode
```java
        void handleReturnCode() {
            if (mArgs != null) {
                processPendingInstall(mArgs, mRet);
            }
        }
```
```java
    private void processPendingInstall(final InstallArgs args, final int currentStatus) {

        mHandler.post(new Runnable() {
            public void run() {
                mHandler.removeCallbacks(this);

                PackageInstalledInfo res = new PackageInstalledInfo();
                res.setReturnCode(currentStatus);
                res.uid = -1;
                res.pkg = null;
                res.removedInfo = null;
                if (res.returnCode == PackageManager.INSTALL_SUCCEEDED) {
                    args.doPreInstall(res.returnCode);
                    synchronized (mInstallLock) {
                        installPackageTracedLI(args, res);
                    }
                    args.doPostInstall(res.returnCode, res.uid);
                }
....

                if (!doRestore) {

                    Message msg = mHandler.obtainMessage(POST_INSTALL, token, 0);
                    mHandler.sendMessage(msg);
                }
        });
    }

```
- 1.InstallArgs.doPreInstall 安装失败则清除安装过程中的临时文件
- 2.installPackageTracedLI 安装扫描apk包
- 3.InstallArgs.doPostInstall 清除缓存在Installd的缓存
- 4.发送POST_INSTALL Handler消息到ServiceThread中处理


##### PMS installPackageTracedLI
```java
    private void installPackageLI(InstallArgs args, PackageInstalledInfo res) {
...

        final PackageParser pp = new PackageParser();
        pp.setSeparateProcesses(mSeparateProcesses);
        pp.setDisplayMetrics(mMetrics);
        pp.setCallback(mPackageParserCallback);
        final PackageParser.Package pkg;
        try {
            pkg = pp.parsePackage(tmpPackageFile, parseFlags);
            DexMetadataHelper.validatePackageDexMetadata(pkg);
        } catch (PackageParserException e) {
...
        } finally {
...
        }

...

        if (TextUtils.isEmpty(pkg.cpuAbiOverride)) {
            pkg.cpuAbiOverride = args.abiOverride;
        }

        String pkgName = res.name = pkg.packageName;
...
        try {
            if (args.signingDetails != PackageParser.SigningDetails.UNKNOWN) {
                pkg.setSigningDetails(args.signingDetails);
            } else {
                PackageParser.collectCertificates(pkg, false /* skipVerify */);
            }
        } catch (PackageParserException e) {
            res.setError("Failed collect during installPackageLI", e);
            return;
        }

...

        pp = null;
        String oldCodePath = null;
        boolean systemApp = false;
        synchronized (mPackages) {
...

            PackageSetting ps = mSettings.mPackages.get(pkgName);
            if (ps != null) {
...
            }

            int N = pkg.permissions.size();
            for (int i = N-1; i >= 0; i--) {
                final PackageParser.Permission perm = pkg.permissions.get(i);
                final BasePermission bp =
                        (BasePermission) mPermissionManager.getPermissionTEMP(perm.info.name);

                if ((perm.info.protectionLevel & PermissionInfo.PROTECTION_FLAG_INSTANT) != 0
                        && !systemApp) {
                    perm.info.protectionLevel &= ~PermissionInfo.PROTECTION_FLAG_INSTANT;
                }

                if (bp != null) {

                    final boolean sigsOk;
                    final String sourcePackageName = bp.getSourcePackageName();
                    final PackageSettingBase sourcePackageSetting = bp.getSourcePackageSetting();
                    final KeySetManagerService ksms = mSettings.mKeySetManagerService;
                    if (sourcePackageName.equals(pkg.packageName)
                            && (ksms.shouldCheckUpgradeKeySetLocked(
                                    sourcePackageSetting, scanFlags))) {
                        sigsOk = ksms.checkUpgradeKeySetLocked(sourcePackageSetting, pkg);
                    } else {

                        if (sourcePackageSetting.signatures.mSigningDetails.checkCapability(
                                        pkg.mSigningDetails,
                                        PackageParser.SigningDetails.CertCapabilities.PERMISSION)) {
                            sigsOk = true;
                        } else if (pkg.mSigningDetails.checkCapability(
                                        sourcePackageSetting.signatures.mSigningDetails,
                                        PackageParser.SigningDetails.CertCapabilities.PERMISSION)) {

                            sourcePackageSetting.signatures.mSigningDetails = pkg.mSigningDetails;
                            sigsOk = true;
                        } else {
                            sigsOk = false;
                        }
                    }
                    if (!sigsOk) {

...
                    } else if (!PLATFORM_PACKAGE_NAME.equals(pkg.packageName)) {

                        if ((perm.info.protectionLevel & PermissionInfo.PROTECTION_MASK_BASE)
                                == PermissionInfo.PROTECTION_DANGEROUS) {
                            if (bp != null && !bp.isRuntime()) {

                                perm.info.protectionLevel = bp.getProtectionLevel();
                            }
                        }
                    }
                }
            }
        }

...

        if (args.move != null) {
...
        } else if (!forwardLocked && !pkg.applicationInfo.isExternalAsec()) {
....
        }

        if (!args.doRename(res.returnCode, pkg, oldCodePath)) {

            return;
        }

        if (PackageManagerServiceUtils.isApkVerityEnabled()) {
            String apkPath = null;
            synchronized (mPackages) {

                final PackageSetting ps = mSettings.mPackages.get(pkgName);
                if (ps != null && ps.isPrivileged()) {
                    apkPath = pkg.baseCodePath;
                }
            }

            if (apkPath != null) {
                final VerityUtils.SetupResult result =
                        VerityUtils.generateApkVeritySetupData(apkPath);
                if (result.isOk()) {
                    FileDescriptor fd = result.getUnownedFileDescriptor();
                    try {
                        final byte[] signedRootHash = VerityUtils.generateFsverityRootHash(apkPath);
                        mInstaller.installApkVerity(apkPath, fd, result.getContentSize());
                        mInstaller.assertFsverityRootHashMatches(apkPath, signedRootHash);
                    } catch (InstallerException | IOException | DigestException |
...
                    } finally {
                        IoUtils.closeQuietly(fd);
                    }
                } else if (result.isFailed()) {
...
                } else {

                }
            }
        }

..

        try (PackageFreezer freezer = freezePackageForInstall(pkgName, installFlags,
                "installPackageLI")) {
            if (replace) {
...
            } else {
                installNewPackageLIF(pkg, parseFlags, scanFlags | SCAN_DELETE_DATA_ON_FAILURES,
                        args.user, installerPackageName, volumeUuid, res, args.installReason);
            }
        }

        mArtManagerService.prepareAppProfiles(pkg, resolveUserIds(args.user.getIdentifier()));


        final boolean performDexopt = (res.returnCode == PackageManager.INSTALL_SUCCEEDED)
                && !forwardLocked
                && !pkg.applicationInfo.isExternalAsec()
                && (!instantApp || Global.getInt(mContext.getContentResolver(),
                Global.INSTANT_APP_DEXOPT_ENABLED, 0) != 0)
                && ((pkg.applicationInfo.flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0);

        if (performDexopt) {

            DexoptOptions dexoptOptions = new DexoptOptions(pkg.packageName,
                    REASON_INSTALL,
                    DexoptOptions.DEXOPT_BOOT_COMPLETE |
                    DexoptOptions.DEXOPT_INSTALL_WITH_DEX_METADATA_FILE);
            mPackageDexOptimizer.performDexOpt(pkg, pkg.usesLibraryFiles,
                    null /* instructionSets */,
                    getOrCreateCompilerPackageStats(pkg),
                    mDexManager.getPackageUseInfoOrDefault(pkg.packageName),
                    dexoptOptions);

        }


        BackgroundDexOptService.notifyPackageChanged(pkg.packageName);

        synchronized (mPackages) {
            final PackageSetting ps = mSettings.mPackages.get(pkgName);
            if (ps != null) {
                res.newUsers = ps.queryInstalledUsers(sUserManager.getUserIds(), true);
                ps.setUpdateAvailable(false /*updateAvailable*/);
            }

...
        }
    }
```
分为如下几步：
- 1.PackageParser.parsePackage 扫描apk包中完整的`AndroidManifest.xml`内容，并把解析的package结果缓存到磁盘和内存中

- 2.往Package对象中设置好签名信息

- 3.从Settings中获取是否有当前包名对应的PackageSetting 包配置信息，此时还没有则跳开这里的if。获取PermissionManagerService查询权限信息。如果还是能查到，说明是包的升级，此时会进行包权限的校验。判断前后两次是不是内部包含的包权限内容都是一致，而只是顺序变了。当然如果之前没有安装，或者内容不一致，都会触发KeySetManagerService的checkUpgradeKeySetLocked进行更新

- 4.调用InstallArgs.doRename 把当前的包的名字给更新了

- 5.判断当前是否允许对包进行校验，如果允许则调用VerityUtils.generateApkVeritySetupData 对包的签名进行校验,校验通过根路径则调用Installd服务进一步调用installApkVerity进行校验。详细就不说了

- 6.installNewPackageLIF 
```java
    private void installNewPackageLIF(PackageParser.Package pkg, final @ParseFlags int parseFlags,
            final @ScanFlags int scanFlags, UserHandle user, String installerPackageName,
            String volumeUuid, PackageInstalledInfo res, int installReason) {

        String pkgName = pkg.packageName;

        synchronized(mPackages) {
            final String renamedPackage = mSettings.getRenamedPackageLPr(pkgName);
            if (renamedPackage != null) {
                return;
            }
            if (mPackages.containsKey(pkgName)) {

                return;
            }
        }

        try {
            PackageParser.Package newPackage = scanPackageTracedLI(pkg, parseFlags, scanFlags,
                    System.currentTimeMillis(), user);

            updateSettingsLI(newPackage, installerPackageName, null, res, user, installReason);

            if (res.returnCode == PackageManager.INSTALL_SUCCEEDED) {
                prepareAppDataAfterInstallLIF(newPackage);

            } else {
...
            }
        } catch (PackageManagerException e) {
          
        }

    }
```
  - 1.调用scanPackageTracedLI 扫描包内容，此时其实已经解析过一次包内容，在这里能直接获得缓存。

  - 2.updateSettingsLI 更新Settings中的包配置对象也就是PackageSettings对象以及往Settings的`package.list`和`package.xml`写入配置内容。关于这两个文件可以阅读[PackageManagerService的启动与安装(上)](https://www.jianshu.com/p/2afddb959b67)。

  - 3.prepareAppDataAfterInstallLIF核心还是调用了prepareAppDataLeafLIF方法，关于这个方法还是可以阅读[PackageManagerService的启动与安装(上)](https://www.jianshu.com/p/2afddb959b67)。实际上就是给下面编译优化的结果文件，创建对应的目录在每一个包下面创建`cache`或者`code_cache `文件夹，并且生成加速dex2oat编译的`.prof`文件.


- 7.prepareAppProfiles 调用`/system/bin/profman`生成加速dex2oat编译的`.prof`文件


- 8.PackageDexOptimizer.performDexOpt 进行dexopt 对dex文件进行优化

我们再来看看其中核心的scanPackageTracedLI 以及InstallArgs.doRename

##### PMS scanPackageTracedLI
```java
    private PackageParser.Package scanPackageLI(File scanFile, int parseFlags, int scanFlags,
            long currentTime, UserHandle user) throws PackageManagerException {
        PackageParser pp = new PackageParser();
        pp.setSeparateProcesses(mSeparateProcesses);
        pp.setOnlyCoreApps(mOnlyCore);
        pp.setDisplayMetrics(mMetrics);
        pp.setCallback(mPackageParserCallback);

        final PackageParser.Package pkg;
        try {
            pkg = pp.parsePackage(scanFile, parseFlags);
        } catch (PackageParserException e) {

        } finally {
          
        }

        if (pkg.applicationInfo.isStaticSharedLibrary()) {
            renameStaticSharedLibraryPackage(pkg);
        }
        return scanPackageChildLI(pkg, parseFlags, scanFlags, currentTime, user);
    }
```
这里面的很简单又一次的调用了parsePackage，这一次是直接从缓存中读取出了完成的package信息，接着调用scanPackageChildLI。

###### scanPackageChildLI
```java
    private PackageParser.Package scanPackageChildLI(PackageParser.Package pkg,
            final @ParseFlags int parseFlags, @ScanFlags int scanFlags, long currentTime,
            @Nullable UserHandle user)
                    throws PackageManagerException {
        if ((scanFlags & SCAN_CHECK_ONLY) == 0) {
            if (pkg.childPackages != null && pkg.childPackages.size() > 0) {
                scanFlags |= SCAN_CHECK_ONLY;
            }
        } else {
            scanFlags &= ~SCAN_CHECK_ONLY;
        }

        // Scan the parent
        PackageParser.Package scannedPkg = addForInitLI(pkg, parseFlags,
                scanFlags, currentTime, user);

        final int childCount = (pkg.childPackages != null) ? pkg.childPackages.size() : 0;
        for (int i = 0; i < childCount; i++) {
            PackageParser.Package childPackage = pkg.childPackages.get(i);
            addForInitLI(childPackage, parseFlags, scanFlags,
                    currentTime, user);
        }

        if ((scanFlags & SCAN_CHECK_ONLY) != 0) {
            return scanPackageChildLI(pkg, parseFlags, scanFlags, currentTime, user);
        }

        return scannedPkg;
    }
```
在这里面会不断的递归整个目录结构中所有的可能的子包。我们不需要理解也ok，关键是addForInitLI 对每一个安装包的package会进行一次初始化。这个方法对于新包来说核心的逻辑在于其中的`scanPackageNewLI`

###### scanPackageNewLI
```java
    private PackageParser.Package scanPackageNewLI(@NonNull PackageParser.Package pkg,
            final @ParseFlags int parseFlags, @ScanFlags int scanFlags, long currentTime,
            @Nullable UserHandle user) throws PackageManagerException {
...
        scanFlags = adjustScanFlags(scanFlags, pkgSetting, disabledPkgSetting, user, pkg);
        synchronized (mPackages) {
...
            boolean scanSucceeded = false;
            try {
                final ScanRequest request = new ScanRequest(pkg, sharedUserSetting,
                        pkgSetting == null ? null : pkgSetting.pkg, pkgSetting, disabledPkgSetting,
                        originalPkgSetting, realPkgName, parseFlags, scanFlags,
                        (pkg == mPlatformPackage), user);
                final ScanResult result = scanPackageOnlyLI(request, mFactoryTest, currentTime);
                if (result.success) {
                    commitScanResultsLocked(request, result);
                }
                scanSucceeded = true;
            } finally {
...
            }
        }
        return pkg;
    }

```
核心是调用了commitScanResultsLocked，这个方法对把扫描后的内容同步到PackageSettings，等待后续的写入到缓存文件中。对于全新的包则会做如下处理:
```java
        if (newPkgSettingCreated) {
            if (originalPkgSetting != null) {
                mSettings.addRenamedPackageLPw(pkg.packageName, originalPkgSetting.name);
            }
            mSettings.addUserToSettingLPw(pkgSetting);

            if (originalPkgSetting != null && (scanFlags & SCAN_CHECK_ONLY) == 0) {
                mTransferedPackages.add(originalPkgSetting.name);
            }
        }
```
核心就是Settings的addUserToSettingLPw 为新的包分配全新的userId。
```java
    void addUserToSettingLPw(PackageSetting p) throws PackageManagerException {
        if (p.appId == 0) {
            p.appId = newUserIdLPw(p);
        } else {
            addUserIdLPw(p.appId, p, p.name);
        }
        if (p.appId < 0) {
       ...
        }
    }
```
在ApplicationInfo 没有记录appid也就是没有分配过userId的情况下，会调用newUserIdLPw进行分配
```java
public static final int FIRST_APPLICATION_UID = 10000;
 public static final int LAST_APPLICATION_UID = 19999;
```
```java
    private int newUserIdLPw(Object obj) {
        final int N = mUserIds.size();
        for (int i = mFirstAvailableUid; i < N; i++) {
            if (mUserIds.get(i) == null) {
                mUserIds.set(i, obj);
                return Process.FIRST_APPLICATION_UID + i;
            }
        }


        if (N > (Process.LAST_APPLICATION_UID-Process.FIRST_APPLICATION_UID)) {
            return -1;
        }

        mUserIds.add(obj);
        return Process.FIRST_APPLICATION_UID + N;
    }
```
实际上就查找当前的mUserIds中有多少空闲的uid，找到则拿到对应的index,设置UserId为：
> uid = 10000 + index


##### InstallArgs.doRename
```java
        boolean doRename(int status, PackageParser.Package pkg, String oldCodePath) {

            final File targetDir = codeFile.getParentFile();
            final File beforeCodeFile = codeFile;
            final File afterCodeFile = getNextCodePath(targetDir, pkg.packageName);

            try {
                Os.rename(beforeCodeFile.getAbsolutePath(), afterCodeFile.getAbsolutePath());
            } catch (ErrnoException e) {
                return false;
            }

            if (!SELinux.restoreconRecursive(afterCodeFile)) {
                return false;
            }

            codeFile = afterCodeFile;
            resourceFile = afterCodeFile;

            try {
                pkg.setCodePath(afterCodeFile.getCanonicalPath());
            } catch (IOException e) {
                return false;
            }
            pkg.setBaseCodePath(FileUtils.rewriteAfterRename(beforeCodeFile,
                    afterCodeFile, pkg.baseCodePath));
            pkg.setSplitCodePaths(FileUtils.rewriteAfterRename(beforeCodeFile,
                    afterCodeFile, pkg.splitCodePaths));

            // Reflect the rename in app info
            pkg.setApplicationVolumeUuid(pkg.volumeUuid);
            pkg.setApplicationInfoCodePath(pkg.codePath);
            pkg.setApplicationInfoBaseCodePath(pkg.baseCodePath);
            pkg.setApplicationInfoSplitCodePaths(pkg.splitCodePaths);
            pkg.setApplicationInfoResourcePath(pkg.codePath);
            pkg.setApplicationInfoBaseResourcePath(pkg.baseCodePath);
            pkg.setApplicationInfoSplitResourcePaths(pkg.splitCodePaths);

            return true;
        }
```
在这里存在两种路径，一种是变化前的路径，名字为`/data/app/vmdlsessionId/base.apk`,另一种是安装后的路径，通过如下getNextCodePath方法获得：
```java
    private File getNextCodePath(File targetDir, String packageName) {
        File result;
        SecureRandom random = new SecureRandom();
        byte[] bytes = new byte[16];
        do {
            random.nextBytes(bytes);
            String suffix = Base64.encodeToString(bytes, Base64.URL_SAFE | Base64.NO_WRAP);
            result = new File(targetDir, packageName + "-" + suffix);
        } while (result.exists());
        return result;
    }
```
targetDir是指`/data/app/vmdlsessionId.tmp/`的父目录`/data/app/` 那么此时就是设置为`/data/app/包名-随机数`

##### 发送POST_INSTALL Handler消息到PackageHandler中处理
当安装完成后就会发送POST_INSTALL 处理安装完的内容
```java
                case POST_INSTALL: {
                    PostInstallData data = mRunningInstalls.get(msg.arg1);
                    final boolean didRestore = (msg.arg2 != 0);
                    mRunningInstalls.delete(msg.arg1);

                    if (data != null) {
                        InstallArgs args = data.args;
                        PackageInstalledInfo parentRes = data.res;

                        final boolean grantPermissions = (args.installFlags
                                & PackageManager.INSTALL_GRANT_RUNTIME_PERMISSIONS) != 0;
                        final boolean killApp = (args.installFlags
                                & PackageManager.INSTALL_DONT_KILL_APP) == 0;
                        final boolean virtualPreload = ((args.installFlags
                                & PackageManager.INSTALL_VIRTUAL_PRELOAD) != 0);
                        final String[] grantedPermissions = args.installGrantPermissions;

                        handlePackagePostInstall(parentRes, grantPermissions, killApp,
                                virtualPreload, grantedPermissions, didRestore,
                                args.installerPackageName, args.observer);

                        final int childCount = (parentRes.addedChildPackages != null)
                                ? parentRes.addedChildPackages.size() : 0;
                        for (int i = 0; i < childCount; i++) {
                            PackageInstalledInfo childRes = parentRes.addedChildPackages.valueAt(i);
                            handlePackagePostInstall(childRes, grantPermissions, killApp,
                                    virtualPreload, grantedPermissions, false /*didRestore*/,
                                    args.installerPackageName, args.observer);
                        }


                    } else {
                    }
                } break;
```
核心方法是handlePackagePostInstall，这个方法发送了如下几种广播：
- 1.Intent.ACTION_PACKAGE_ADDED 包添加广播
- 2.Intent.ACTION_PACKAGE_REPLACED 包替换广播
最后还会获取到保存在InstallArgs的IPackageInstallObserver2 ，回调onPackageInstalled。也就是在PackageInstallSession的commit流程中生成的对象，而这个方法又会调用dispatchSessionFinished


#### PackageInstallSession dispatchSessionFinished
```java
    private void dispatchSessionFinished(int returnCode, String msg, Bundle extras) {
        final IPackageInstallObserver2 observer;
        final String packageName;
        synchronized (mLock) {
            mFinalStatus = returnCode;
            mFinalMessage = msg;

            observer = mRemoteObserver;
            packageName = mPackageName;
        }

        if (observer != null) {
            final SomeArgs args = SomeArgs.obtain();
            args.arg1 = packageName;
            args.arg2 = msg;
            args.arg3 = extras;
            args.arg4 = observer;
            args.argi1 = returnCode;

            mHandler.obtainMessage(MSG_ON_PACKAGE_INSTALLED, args).sendToTarget();
        }

        final boolean success = (returnCode == PackageManager.INSTALL_SUCCEEDED);

        final boolean isNewInstall = extras == null || !extras.getBoolean(Intent.EXTRA_REPLACING);
        if (success && isNewInstall) {
            mPm.sendSessionCommitBroadcast(generateInfo(), userId);
        }

        mCallback.onSessionFinished(this, success);
    }
```
做了三件事情：
- 1.发送Handler消息MSG_ON_PACKAGE_INSTALLED
- 2.发送了一个ACTION_SESSION_COMMITTED广播 发送到InstallEventReceiver
- 3.回调了onSessionFinished

其中第一点的MSG_ON_PACKAGE_INSTALLED的消息处理中又调用了Binder对象mRemoteObserver的onPackageInstalled。此时就会调用PackageInstallObserver也就是PackageInstallerService. PackageInstallObserverAdapter的onPackageInstalled。

##### PackageInstallObserverAdapter的onPackageInstalled
```java
        public void onPackageInstalled(String basePackageName, int returnCode, String msg,
                Bundle extras) {
            if (PackageManager.INSTALL_SUCCEEDED == returnCode && mShowNotification) {
                boolean update = (extras != null) && extras.getBoolean(Intent.EXTRA_REPLACING);
                Notification notification = buildSuccessNotification(mContext,
                        mContext.getResources()
                                .getString(update ? R.string.package_updated_device_owner :
                                        R.string.package_installed_device_owner),
                        basePackageName,
                        mUserId);
                if (notification != null) {
                    NotificationManager notificationManager = (NotificationManager)
                            mContext.getSystemService(Context.NOTIFICATION_SERVICE);
                    notificationManager.notify(basePackageName,
                            SystemMessage.NOTE_PACKAGE_STATE,
                            notification);
                }
            }
            final Intent fillIn = new Intent();
            fillIn.putExtra(PackageInstaller.EXTRA_PACKAGE_NAME, basePackageName);
            fillIn.putExtra(PackageInstaller.EXTRA_SESSION_ID, mSessionId);
            fillIn.putExtra(PackageInstaller.EXTRA_STATUS,
                    PackageManager.installStatusToPublicStatus(returnCode));
            fillIn.putExtra(PackageInstaller.EXTRA_STATUS_MESSAGE,
                    PackageManager.installStatusToString(returnCode, msg));
            fillIn.putExtra(PackageInstaller.EXTRA_LEGACY_STATUS, returnCode);
            if (extras != null) {
                final String existing = extras.getString(
                        PackageManager.EXTRA_FAILURE_EXISTING_PACKAGE);
                if (!TextUtils.isEmpty(existing)) {
                    fillIn.putExtra(PackageInstaller.EXTRA_OTHER_PACKAGE_NAME, existing);
                }
            }
            try {
                mTarget.sendIntent(mContext, 0, fillIn, null, null);
            } catch (SendIntentException ignored) {
            }
        }
    }
```
能看到此时就会调用NotificationManager 出现一个通知栏告诉用户已经安装好了apk了。

##### InstallEventReceiver 接受到广播后的处理
当这个对象接受到广播后，就会调用EventResultPersister的onEventReceived
```java
    void onEventReceived(@NonNull Context context, @NonNull Intent intent) {
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, 0);

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            context.startActivity(intent.getParcelableExtra(Intent.EXTRA_INTENT));

            return;
        }

        int id = intent.getIntExtra(EXTRA_ID, 0);
        String statusMessage = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
        int legacyStatus = intent.getIntExtra(PackageInstaller.EXTRA_LEGACY_STATUS, 0);

        EventResultObserver observerToCall = null;
        synchronized (mLock) {
            int numObservers = mObservers.size();
            for (int i = 0; i < numObservers; i++) {
                if (mObservers.keyAt(i) == id) {
                    observerToCall = mObservers.valueAt(i);
                    mObservers.removeAt(i);

                    break;
                }
            }

            if (observerToCall != null) {
                observerToCall.onResult(status, legacyStatus, statusMessage);
            } else {
                mResults.put(id, new EventResult(status, legacyStatus, statusMessage));
                writeState();
            }
        }
    }
```
这里很简单从EXTRA_ID 中获取当前EventResultObserver对应的id，并且回调onResult。此时就会回调到InstallInstalling的launchFinishBasedOnResult方法中。

##### InstallInstalling launchFinishBasedOnResult
```java
    private void launchFinishBasedOnResult(int statusCode, int legacyStatus, String statusMessage) {
        if (statusCode == PackageInstaller.STATUS_SUCCESS) {
            launchSuccess();
        } else {
            launchFailure(legacyStatus, statusMessage);
        }
    }
```
很简单就是显示成功或者失败的页面。

## 总结
到这里PMS的安装全流程就解析完了，虽然有不少的地方说不详细，但是总体架构在这里了，需要探索哪一点可以继续根据这个框架去阅读源码即可。老规矩，先上一个时序图，流程很长，注意这里我没有把所有的AysncTask中的流程显示出来，能意会就好：
![PMS安装流程.jpg](/images/PMS安装流程.jpg)

在PMS的安装过程，总结来说就是两个步骤：
- 1.拷贝apk
- 2.解析apk，把解析的内容缓存到Andoid系统，把包内容保存在配置中。



apk的拷贝过程，经过了如下几次变化，我们以此为线索梳理其流程：
- 1.`来源apk uri` -> `/data/no_backup/packagexxx.apk` .

- 2.`/data/no_backup/packagexxx.apk` 
 -> `/data/app/vmdlsessionId.tmp/PackageInstaller` 这个过程中还记录了PackageInstallerSession的记录，保存在`/data/system/install_sessions.xml` 中。这个过程是通过PackageInstallerService创建一个Session对象时候进行记录，这样就能得知Android系统中曾经出现过多少次安装记录，可能出现多少残余的数据需要清除。 

- 3.`/data/app/vmdlsessionId.tmp/PackageInstaller` -> 会变化为另外一个sessionId对应的`/data/app/vmdlsessionId.tmp/base.apk` 这个过程因为可能会复用sessionId，因此需要先删除一些之前可能遗留下来的残留文件，接着就会创建一个临时的`/data/app/vmdlsessionId.tmp/lib`保存so库 


- 4.`/data/app/vmdlsessionId2.tmp/base.apk` 重命名为 `/data/app/包名-随机数` 
在这个过程最为核心，就是整个PMS的安装核心如下：
  - 4.1.PackageParser.parsePackage 解析包AndroidManifest所有内容，缓存到`data/system/package_cache/包名_0`中

  - 4.2.scanPackageTracedLI 虽然这个方法也有扫描包内容的能力，但是这里更加重要的是为每一个apk包设置好PackageSettings对象，准备写入到Settings中`packages.xml`中，并为每一个新安装的apk设置好自己的userid(10000 + index).

  - 4.3. updateSettingsLI  把包配置设置到`packages.xml`

  - 4.4. prepareAppDataAfterInstallLIF, prepareAppProfiles,PackageDexOptimizer.performDexOpt都是对dex文件的优化提供环境:
    - 4.4.1prepareAppDataAfterInstallLIF提供目录结构`/data/user/用户ID/包名/cache` 或`/data/user/用户ID/包名/code_cache`
    - 4.4.2.调用了Installd的fixupAppData方法,创建一个/data/user/用户id和/data/data目录，也就是我们常见的/data/user/0./data/user/用户id是/data/data的软链接
    - 4.4.2.prepareAppProfiles 提供加速编译的文件
    - 4.4.3.performDexOpt 执行dexopt


- 4.5. doRename 重命名

- 5.最后发送POST_INSTALL消息，通过IPackageInstallObserver2回调，通知此时又调用DefaultContainerService记录好的Binder的onPackageInstalled 展示一个通知栏通知，告诉用户已经安装完毕

- 6.IPackageInstallObserver2回调 回调中也会发送一个广播消息，告诉正在等待安装结果的InstallInstalling 页面展示安装成功提示。

## 后话
到这里PMS的全流程就结束了，能看到有一个很核心的内容，performDexOpt是是如何优化dex还没有聊到。这是一个比较重要的内容，但是学习的门槛有点高，需要熟悉ART 虚拟机。

不过没关系，我对ART虚拟机源码也来回看了几遍，之后我会开启新的篇章，名为JVM基础系列，让我们恶补一下关于Java的“基础”吧，看看网上哪些优化的言论，看看网上哪些常用的说法是否正确。要达到这个能力还需要自己亲自去底层看看ART是怎么设计的。通过对JVM的理解，可以加深对Java编程的理解。

在这之前，我们还只是在单机世界中兜兜转转，下一个篇章应该是来总结网络相关的知识，就以解析OkHttp开始，看看socket的底层设计吧。








