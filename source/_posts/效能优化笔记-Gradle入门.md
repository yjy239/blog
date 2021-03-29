---
title: 效能优化笔记 Gradle入门
top: false
cover: false
date: 2021-03-23 23:32:28
img:
tag:
description:
author: yjy239
summary:
categories: Gradle
tags:
- Gradle
---
# 前言

本文将会聊聊这两周以来学习的Gradle 脚本知识点。先后阅读了`Gradle in Action` 以及`Gradle for Android`. 总的来说,`Gradle in Action` 从Gradle脚本起源以及构建开始聊起来，会让人对`Gradle`有宏观的印象。而`Gradle for Android` 则更加倾向于`Android`开发中,`Gradle`脚本都做了什么，以及一些常用的技巧。

如果是新人入门，可以先阅读`Gradle in Action`.而`Gradle for Android` 我个人认为差强人意，如果是对分渠道打包等小技巧不太熟悉的入门开发者，可以阅读。但是我希望的介绍Android 编译插件`AppExtension` 的每个执行任务介绍和源码并没有介绍，着实让人遗憾。

我为了加强学习，我把Gradle的源码大致看了一边，发现这两本书说的都不太准确，可能还有点过时了。

现在结合辉哥的课程，Gradle源码以及自己的踩坑经历来总结一下Gradle的知识点。


# 正文

## 1.Gradle 概论
Gradle为何物？Gradle 究竟和常见的构建脚本有什么区别？

先来看看Java老项目中，常用的构建脚本`Ant`和`Maven`。这两者都是使用XML描述整个构建逻辑。导致了维护构建代码成为了噩梦。而后Maven推出现的`Mojo`以及Ant推出的`Ivy`都是为了弥补这种问题. 然后在Maven中编写插件进行依赖是一个很麻烦的事情。

为了解决这些问题，并让构建工具可以拥有可读性以及更加具有表达性。以动态语言Groovy为核心的Gradle就诞生了。

### 1.1Gradle 特性

#### 1.1.1 可表达性的构建语言以及底层Api

摒弃XML 形式进行构建描述，转而使用动态语言构成的DSL描述Gradle脚本.

而对于整个构建脚本，规范了如下核心api：
![gradle核心api.png](/images/gradle核心api.png)


- 1.project 指代整个工程的构建对象。可以通过该对象获取此次构建所有的任务，依赖，仓库，插件等。

- 2.RepositoryHandler 负责了对应管理依赖组件仓库

- 3.DependencyHandler 负责了当前项目依赖的组件

- 4.Task 负责当前组件中需要执行的任务

- 5.TaskContainer 承载了当前构建脚本的所有的任务

- 6.Action 是存在于Task中真正的执行逻辑。

- 7.ExtensionContainer 是指各种插件扩展的集合。比如在Android构建插件AppPlugin就被这个容器管理。


当我们需要编写一个简单的Gradle脚本时候，只需要写好如下内容，就能完成一次简单的Gradle构建脚本编写。

```
apply plugin: 'com.android.application'


buildscript {
    repositories {
        google()
        jcenter()
    }
    dependencies {
...
    }
}


android{
}


dependencies {
 ...
}
```

而这些大括号包裹起来的，实际上就是指代project中对应对象的模块。当Gradle脚本运行时候，会从上往下的执行代码段。而这些通过括号包起来的对象，就是配置在对应插件的内容。

当执行到插件部分时候，就会取出括号内容进行执行。

比如此时就是先发现`apply plugin: 'com.android.application'`就会在project中保存好此插件，当打包流程走到了需要执行插件的时期， 就会执行Android打包的插件。

#### 1.1.2 Gradle 就是Groovy

Gradle本身就是通过Groovy 语言构成的。而Groovy本身也是基于JVM设计的一套字节码设计的语言。因此可以完美兼容Java，kotlin编译插件。也就是说可以完美对接壮大的Java社区。

基于Groovy的语言的表达性，除了在Gradle脚本中写下简易的Task任务：

```
task("hello") {
    println("--- hello")
}
```

还能创建一个Groovy文件，通过如下方式创建一个Task。
```
project.getTasks().create("hello",{
            println("--- hello")
        })
```

#### 1.1.3 灵活的约定能力

Gradle脚本和Maven完全不同的是其灵活的约定能力。比如Maven很武断只允许一个工程包含一个工程源码目录以及一个jar包。而Gradle没有这种约定，完全可以通过脚本逻辑自己决定多个工程源码目录，生产多个不同jar包。


#### 1.1.4 强大的鲁棒和依赖管理功能

- 1.Gradle 可以做到传递性依赖，可以把依赖下来的库需要依赖的组件都依赖下来。

- 2.对比Maven和Ivy，当发生异常时候，就算实现相同也不能保证不同机器之间能复现这种情况。仓库可能会因为项目而改变，就算有一点点不同，缓存的依赖也会认为解析过了，导致构建失败。而Gradle所以的子模块都会当成子项目可以独立运行和构建，会找到那些需要重新构建的子模块，不需要重新构建的直接缓存在本地。


#### 1.1.5 可扩展的构建

这里是指，可以轻易的对Gradle打包周期进行扩展。同时Gradle可以清楚哪一块任务是增量编译，哪一块需要重新编译。还能把功能测试，单元测试集成到构建的过程中。

另一点，可以编写一个插件复用于构建行为，并进行维护，发布。


## 2.Gradle的生命周期

对Gradle有了大致印象后，来聊聊更加实际的。Gradle脚本构建生命周期。

### 2.1 Gradle 构建的三大基本要素

我们先抛开java或者Android的打包插件。来看看Gradle默认的构建的三大要素：

- 1.project 
- 2.task
- 3.property


在这里面project可以是多项目，每个项目可以是多task，每个task可以是多个参数property。

![gradle脚本元素.png](/images/gradle脚本元素.png)

注意我们常说的插件，依赖，仓库都隶属于项目当中。


除此之外，我们还经常通过定义如下，来扩展属性：
```
ext{
 prop = 123
}

println project.ext.prop
```



### 2.2.Gradle 生命周期

在`Gradle in Action` 和`Gradle for Android`两本书中，把Gradle脚本构建大致拆分为如下三个生命周期：
- 1.初始化
- 2.配置
- 3.执行

然而，经过阅读了`Gradle 5.6.1`的源码之后，发现并不准确。实际上整个流程如下：
![gradle生命周期.png](/images/gradle生命周期.png)


大致上可以分为如下6个阶段

- 1.初始化

- 2.读取配置文件

- 3.配置项目

- 4.构建项目任务的执行环图

- 5.根据执行环图执行项目的任务

- 6.结束

我们根据这个生命周期图，和简单的浏览一遍关键源码来看看这些周期都做了什么？

### 2.2.1.构建初始化

有考虑过AndroidStudio是开始构建脚本的吗？可能有的人注意过，当我们命令执行开始编译，或者输入命令执行执行构建的某个的任务的时候(如GreenDao 构建Dao文件)，会输入如下类似的命令： `.gradlew app:clean`。

同样的，在jenkins上编写远程服务器命令脚本，需要打一个debug包，我们往往会输入如下命令:`.gradlew app:assembleDebug`。

那么gradlew 命令是什么东西呢？实际上就是AS在根目录下写好的一个脚本
![gradlew.png](/images/gradlew.png)

在Linux和MacOS是指这个`gradlew`的shell脚本。Window则是指`gradlew.bat`脚本。

其中在`gradlew`脚本中最核心的是指下面这一段：
```
eval set -- $DEFAULT_JVM_OPTS $JAVA_OPTS $GRADLE_OPTS "\"-Dorg.gradle.appname=$APP_BASE_NAME\"" -classpath "\"$CLASSPATH\"" org.gradle.wrapper.GradleWrapperMain "$APP_ARGS"

exec "$JAVACMD" "$@"
```

- eval 可以把外部参数替换为本次执行命令中需要的参数
- 在eval 后接上set，代表本次shell脚本见鬼执行set命令
- $@ 是指本次输入到脚本中所有的参数
- exec 说明此时需要启动一个新的进程启动后面的命令` "$JAVACMD"  "$@"`。则是指启动一个进程，这个进程将会执行`bin/java`的方式执行java程序，而这个程序的入口就是`/gradle/wrapper/gradle-wrapper.jar`下的`org.gradle.wrapper.GradleWrapperMain`的main方法。

如果熟悉shell编程和Gradle脚本参数的高手，完全可以修改shell脚本的命令行，让AS的编译定制化。


当Gradle构建进程启动后，另一个核心的事件，就是需要注册Gradle构建脚本默认的服务插件。


当进程启动后，会读取`META_INF/service`文件夹下的`org.gradle.internal.service.scopes.PluginServiceRegistry`文件中对应的启动插件。

```
org.gradle.caching.internal.BuildCacheServices
org.gradle.internal.service.scopes.ExecutionServices
org.gradle.instantexecution.InstantExecutionServices
org.gradle.workers.internal.WorkersServices
org.gradle.api.internal.artifacts.DependencyServices
org.gradle.composite.internal.CompositeBuildServices
org.gradle.tooling.internal.provider.LauncherServices
org.gradle.plugin.internal.PluginUsePluginServiceRegistry
org.gradle.internal.resource.transport.http.HttpResourcesPluginServiceRegistry
org.gradle.vcs.internal.services.VersionControlServices
org.gradle.caching.http.internal.HttpBuildCacheServiceServices
org.gradle.buildinit.plugins.internal.services.BuildInitServices
org.gradle.api.reporting.components.internal.DiagnosticsServices
org.gradle.plugins.ide.internal.tooling.ToolingModelServices
org.gradle.plugins.ide.internal.IdeServices
org.gradle.ide.xcode.internal.services.XcodeServices
org.gradle.api.publish.ivy.internal.IvyServices
org.gradle.language.java.internal.JavaToolChainServiceRegistry
org.gradle.language.java.internal.JavaLanguagePluginServiceRegistry
org.gradle.language.jvm.internal.JvmPluginServiceRegistry
org.gradle.language.nativeplatform.internal.registry.NativeLanguageServices
org.gradle.language.scala.internal.toolchain.ScalaToolChainServiceRegistry
org.gradle.api.publish.maven.internal.MavenPublishServices
org.gradle.platform.base.internal.registry.ComponentModelBaseServiceRegistry
org.gradle.jvm.internal.services.PlatformJvmServices
org.gradle.nativeplatform.internal.services.NativeBinaryServices
org.gradle.play.internal.toolchain.PlayToolChainServiceRegistry
org.gradle.api.internal.tasks.CompileServices
org.gradle.api.plugins.internal.PluginAuthorServices
org.gradle.api.publish.internal.service.PublishServices
org.gradle.internal.resource.transport.gcp.gcs.GcsResourcesPluginServiceRegistry
org.gradle.internal.resource.transport.aws.s3.S3ResourcesPluginServiceRegistry
org.gradle.internal.resource.transport.sftp.SftpResourcesPluginServiceRegistry
org.gradle.api.internal.tasks.testing.TestingBasePluginServiceRegistry
org.gradle.jvm.test.internal.services.JvmTestingServices
org.gradle.nativeplatform.test.internal.services.NativeTestingServices
org.gradle.language.cpp.internal.tooling.ToolingNativeServices
```

这些全局插件服务最后都会注册到`DefaultServiceRegistry`。其中最核心的就是`CompositeBuildServices` 这个服务将会生成一个`DefaultGradleLauncher `象征构建的对象。之后所有的生命周期都从`DefaultGradleLauncher`发起。

注意构建期间大部分的运行服务其实是由`BuildTreeScopeServices `构建的`BuildScopeServices `提供的。

这个流程是不是很像Android Groovy插件注册的流程。

注意从`DefaultGradleLauncher` 这个对象中，Gradle就严格定义了，每一个周期的行为和名字。Gradle生命周期构建生命周期指的就是如下的枚举类：

```java
    private static enum Stage {
        LoadSettings,
        Configure,
        TaskGraph,
        RunTasks {
            String getDisplayName() {
                return "Build";
            }
        },
        Finished;

        private Stage() {
        }

        String getDisplayName() {
            return this.name();
        }
    }
```


### 2.2.2.读取配置文件(LoadSettings)

整个构建执行入口如下：

```java
    public GradleInternal executeTasks() {
        this.doBuildStages(DefaultGradleLauncher.Stage.RunTasks);
        return this.gradle;
    }
```

核心就是`doBuildStages`方法,该方法调用doClassicBuildStages：

```java
    private void doClassicBuildStages(DefaultGradleLauncher.Stage upTo) {
        this.prepareSettings();
        if (upTo != DefaultGradleLauncher.Stage.LoadSettings) {
            this.prepareProjects();
            if (upTo != DefaultGradleLauncher.Stage.Configure) {
                this.prepareTaskExecution();
                if (upTo != DefaultGradleLauncher.Stage.TaskGraph) {
                    this.instantExecution.saveTaskGraph();
                    this.runWork();
                }
            }
        }
    }
```

能看到实际上就是一层层的递进整个生命周期：LoadSettings -> Configure -> TaskGraph -> RunTasks

在`LoadSettings` 中分别做了如下3件事情：

#### 2.2.2.1.加载init文件下的全局Gradle文件

首先，构建的时候会通过通过`InitScriptHandler `服务读取init文件夹下的gradle文件。核心代码如下：

```java
    public void findScripts(Collection<File> scripts) {
        File userInitScript = this.resolveScriptFile(this.userHomeDir, "init");
        if (userInitScript != null) {
            scripts.add(userInitScript);
        }

        this.findScriptsInDir(new File(this.userHomeDir, "init.d"), scripts);
    }


    public void findScripts(Collection<File> scripts) {
        if (this.gradleHome != null) {
            this.findScriptsInDir(new File(this.gradleHome, "init.d"), scripts);
        }
    }
```
可以看到实际上整个构成就是读取Gradle具体执行目录下的`init`文件夹和`init.d`的gradle文件。

如这个命令`gradle --init-script init.gradle clean`. 通过`--init-script` 参数设置全局的查找`init`文件夹下`.gradle`文件。


#### 2.2.2.2.查找settings.gradle

```java
public BuildLayout getLayoutFor(BuildLayoutConfiguration configuration) {
        if (configuration.isUseEmptySettings()) {
            return this.buildLayoutFrom(configuration, (File)null);
        } else {
            File explicitSettingsFile = configuration.getSettingsFile();
            if (explicitSettingsFile != null) {
                if (!explicitSettingsFile.isFile()) {
                    throw new MissingResourceException(explicitSettingsFile.toURI(), String.format("Could not read settings file '%s' as it does not exist.", explicitSettingsFile.getAbsolutePath()));
                } else {
                    return this.buildLayoutFrom(configuration, explicitSettingsFile);
                }
            } else {
                File currentDir = configuration.getCurrentDir();
                boolean searchUpwards = configuration.isSearchUpwards();
                return this.getLayoutFor(currentDir, searchUpwards ? null : currentDir.getParentFile());
            }
        }
    }
```


```java
    BuildLayout getLayoutFor(File currentDir, File stopAt) {
        File settingsFile = this.findExistingSettingsFileIn(currentDir);
        if (settingsFile != null) {
            return this.layout(currentDir, settingsFile);
        } else {
            for(File candidate = currentDir.getParentFile(); candidate != null && !candidate.equals(stopAt); candidate = candidate.getParentFile()) {
                settingsFile = this.findExistingSettingsFileIn(candidate);
                if (settingsFile == null) {
                    settingsFile = this.findExistingSettingsFileIn(new File(candidate, "master"));
                }

                if (settingsFile != null) {
                    return this.layout(candidate, settingsFile);
                }
            }

            return this.layout(currentDir, new File(currentDir, "settings.gradle"));
        }
    }
```

这两段代码做了如事情：
- 1.如果设置了`useEmptySettings`,说明不需要查找settings.gradle。这么样做，需要通过自己的脚本手动设置一个`settings.gradle`文件，或者在默认位置有一个。

- 2.如果通过`-c`或者`--settings-file ` 的方式设置好了`settings.gradle` 文件也可以直接返回。

- 3.从当前目录不断的向上层递归查找，`settings.gradle`文件.同时`master`文件夹也在搜索范围内。

#### 2.2.2.3.编译buildSrc子模块

一般的，每个项目想要编译一套本项目的插件，一般都会新建一个名为`buildSrc`的文件夹。在这个文件夹中写好插件需要的`groovy`文件。这是因为在Gradle脚本中，默认一个子模块名字为`buildSrc`就是项目的编译插件。


在这里通过`DefaultSettingsPreparer ` 的`prepareSettings `方法开始查找配置文件时候，调用的`findAndLoadSettings`方法：
```java
    private SettingsInternal findSettingsAndLoadIfAppropriate(GradleInternal gradle, StartParameter startParameter) {
        SettingsLocation settingsLocation = this.findSettings(startParameter);
        ClassLoaderScope buildSourceClassLoaderScope = this.buildSourceBuilder.buildAndCreateClassLoader(settingsLocation.getSettingsDir(), startParameter);
        return this.settingsProcessor.process(gradle, settingsLocation, buildSourceClassLoaderScope, startParameter);
    }
```

```java
    public ClassLoaderScope buildAndCreateClassLoader(File rootDir, StartParameter containingBuildParameters) {
        File buildSrcDir = new File(rootDir, "buildSrc");
        ClassPath classpath = this.createBuildSourceClasspath(buildSrcDir, containingBuildParameters);
        return this.classLoaderScope.createChild(buildSrcDir.getAbsolutePath()).export(classpath).lock();
    }
```

能看到此时会找到根目录下的`buildSrc`文件，组成一个ClassPath，然后进行编译。

#### 2.2.2.4.解析gradle.properties

```java
    void loadProperties(File settingsDir, StartParameterInternal startParameter, Map<String, String> systemProperties, Map<String, String> envProperties) {
        this.defaultProperties.clear();
        this.overrideProperties.clear();
        this.addGradleProperties(this.defaultProperties, new File(startParameter.getGradleHomeDir(), "gradle.properties"));
        this.addGradleProperties(this.defaultProperties, new File(settingsDir, "gradle.properties"));
        this.addGradleProperties(this.overrideProperties, new File(startParameter.getGradleUserHomeDir(), "gradle.properties"));
        this.setSystemProperties(startParameter.getSystemPropertiesArgs());
        this.overrideProperties.putAll(this.getEnvProjectProperties(envProperties));
        this.overrideProperties.putAll(this.getSystemProjectProperties(systemProperties));
        this.overrideProperties.putAll(startParameter.getProjectProperties());
    }

```

在这里解析如下几种位置的`gradle.properties`:
- 1.`gradle home dir`（gradle 具体执行文件夹） 文件夹下的`gradle.properties`
- 2.`gradle user dir` （用户gradle 根目录）文件夹下的`gradle.properties`
- 3.解析启动构建时候命令行设置的系统参数
- 4.解析设置在环境变量参数
- 5.解析设置在系统配置参数
- 6.解析启动构建时候命令行传进来的项目参数

这也是为什么我们在不同位置设置的`gradle.properties` 参数，都能在插件运行时候生效的原因。

#### 2.2.2.5.解析settings.gradle

```java
public SettingsInternal process(GradleInternal gradle,
                                SettingsLocation settingsLocation,
                                ClassLoaderScope buildRootClassLoaderScope,
                                StartParameter startParameter) {
    Map<String, String> properties = propertiesLoader.mergeProperties(Collections.<String, String>emptyMap());
    TextResourceScriptSource settingsScript = new TextResourceScriptSource(textResourceLoader.loadFile("settings file", settingsLocation.getSettingsFile()));
    SettingsInternal settings = settingsFactory.createSettings(gradle, settingsLocation.getSettingsDir(), settingsScript, properties, startParameter, buildRootClassLoaderScope);
    applySettingsScript(settingsScript, settings);
    return settings;
}
```

当找到所有的数据后就会合并参数，生成 `DefaultSettings `对象并保存其中。


### 2.2.3. 配置生成Project对象（Config）

#### 2.2.3.1 根据settings.gradle生成Project对象

```java
    public void load(SettingsInternal settings, GradleInternal gradle) {
        this.load(settings.getRootProject(), settings.getDefaultProject(), gradle, settings.getRootClassLoaderScope());
    }

    private void load(ProjectDescriptor rootProjectDescriptor, ProjectDescriptor defaultProject, GradleInternal gradle, ClassLoaderScope buildRootClassLoaderScope) {
        this.createProjects(rootProjectDescriptor, gradle, buildRootClassLoaderScope);
        this.attachDefaultProject(defaultProject, gradle);
    }


private void attachDefaultProject(ProjectDescriptor defaultProject, GradleInternal gradle) {
        gradle.setDefaultProject((ProjectInternal)gradle.getRootProject().getProjectRegistry().getProject(defaultProject.getPath()));
    }

    private void createProjects(ProjectDescriptor rootProjectDescriptor, GradleInternal gradle, ClassLoaderScope buildRootClassLoaderScope) {
        ProjectInternal rootProject = this.projectFactory.createProject(rootProjectDescriptor, (ProjectInternal)null, gradle, buildRootClassLoaderScope.createChild("root-project"), buildRootClassLoaderScope);
        gradle.setRootProject(rootProject);
        this.addProjects(rootProject, rootProjectDescriptor, gradle, buildRootClassLoaderScope);
    }

    private void addProjects(ProjectInternal parent, ProjectDescriptor parentProjectDescriptor, GradleInternal gradle, ClassLoaderScope buildRootClassLoaderScope) {
        Iterator var5 = parentProjectDescriptor.getChildren().iterator();

        while(var5.hasNext()) {
            ProjectDescriptor childProjectDescriptor = (ProjectDescriptor)var5.next();
            ProjectInternal childProject = this.projectFactory.createProject(childProjectDescriptor, parent, gradle, parent.getClassLoaderScope().createChild("project-" + childProjectDescriptor.getName()), buildRootClassLoaderScope);
            this.addProjects(childProject, childProjectDescriptor, gradle, buildRootClassLoaderScope);
        }

    }
```

能看到这个过程就是从settings.gradle 文件中取出所有的项目，通过`projectFactory.createProject`生成一个新的`project`对象，最后`addProjects`保存起来。

```java
    public DefaultProject createProject(ProjectDescriptor projectDescriptor, ProjectInternal parent, GradleInternal gradle, ClassLoaderScope selfClassLoaderScope, ClassLoaderScope baseClassLoaderScope) {
        File buildFile = projectDescriptor.getBuildFile();
        TextResource resource = this.resourceLoader.loadFile("build file", buildFile);
        ScriptSource source = new TextResourceScriptSource(resource);
        DefaultProject project = (DefaultProject)this.instantiator.newInstance(DefaultProject.class, new Object[]{projectDescriptor.getName(), parent, projectDescriptor.getProjectDir(), buildFile, source, gradle, gradle.getServiceRegistryFactory(), selfClassLoaderScope, baseClassLoaderScope});
        project.beforeEvaluate(new Action<Project>() {
            public void execute(Project project) {
                NameValidator.validate(project.getName(), "project name", DefaultProjectDescriptor.INVALID_NAME_IN_INCLUDE_HINT);
            }
        });
        if (parent != null) {
            parent.addChildProject(project);
        }

        this.projectRegistry.addProject(project);
        return project;
    }
```

而这个过程就是通过settings找到对应子模块以及对应子模块的`build.gradle`位置，并创建`DefaultProject`对象，并添加到需要依赖的父项目中。最后注册到`ProjectRegistry`中。


### 2.2.4.构建项目任务的执行环图(TaskGraph)

在这个过程中为，我分为2个阶段：
- 1.根据settings遍历所有的子模块，生成每个模块对应Project对象
- 2.根据任务之间的依赖生成一个任务，项目有向无环图。


#### 2.2.4.1 根据任务之间的依赖生成一个任务，项目有向无环图

整个构建的核心对象，是通过`GradleScopeServices`生成的

```java
BuildConfigurationActionExecuter createBuildConfigurationActionExecuter(CommandLineTaskParser commandLineTaskParser, TaskSelector taskSelector, ProjectConfigurer projectConfigurer, ProjectStateRegistry projectStateRegistry) {
    List<BuildConfigurationAction> taskSelectionActions = new LinkedList<BuildConfigurationAction>();
    // 添加 DefaultTasksBuildExecutionAction
    taskSelectionActions.add(new DefaultTasksBuildExecutionAction(projectConfigurer));
    // 添加 TaskNameResolvingBuildConfigurationAction
    taskSelectionActions.add(new TaskNameResolvingBuildConfigurationAction(commandLineTaskParser));
    // 添加 ExcludedTaskFilteringBuildConfigurationAction
    return new DefaultBuildConfigurationActionExecuter(Arrays.asList(new ExcludedTaskFilteringBuildConfigurationAction(taskSelector)), taskSelectionActions, projectStateRegistry);
}
```

核心对象为：

- 1. ExcludedTaskFilteringBuildConfigurationAction 通过 `-x` 或者 `--exclude-task` 制定好Task添加到任务集合中。

- 2. DefaultTasksBuildExecutionAction 如果没有设定制定执行任务，就会设置默认的任务执行，并且传递启动进程时候的构建参数

- 3. TaskNameResolvingBuildConfigurationAction  此时会解析每个模块中所有任务(把`app:clean` 拆分成app模块到clean任务)，并分析所有任务的依赖关系放到`TaskGraph`容器中

### 2.2.5.执行任务( RunTasks)

核心入口是`DefaultGradleLauncher`的`runWork`方法

```java
    private void runWork() {
        if (this.stage != DefaultGradleLauncher.Stage.TaskGraph) {
            throw new IllegalStateException("Cannot execute tasks: current stage = " + this.stage);
        } else {
            List<Throwable> taskFailures = new ArrayList();
            this.buildExecuter.execute(this.gradle, taskFailures);
            if (!taskFailures.isEmpty()) {
                throw new MultipleBuildFailures(taskFailures);
            } else {
                this.stage = DefaultGradleLauncher.Stage.RunTasks;
            }
        }
    }
```

```java
    BuildWorkExecutor createBuildExecuter(StyledTextOutputFactory textOutputFactory, IncludedBuildControllers includedBuildControllers, BuildOperationExecutor buildOperationExecutor) {
        return new BuildOperationFiringBuildWorkerExecutor(new IncludedBuildLifecycleBuildWorkExecutor(new DefaultBuildWorkExecutor(Arrays.asList(new DryRunBuildExecutionAction(textOutputFactory), new SelectedTaskExecutionAction())), includedBuildControllers), buildOperationExecutor);
    }
```

最终通过`BuildWorkExecutor `开始执行所有的任务。可以看到实际上返回的是`BuildOperationFiringBuildWorkerExecutor`对象。而这个对象实际上是一个门面对象，包含了执行任务之前的预处理，以及任务的执行。


在这个过程中做了如下几件事情：
- 1.处理`--dry-run`命令
- 2.执行任务的预处理
- 3.开启线程执行任务



#### 2.2.5.1.处理`--dry-run`命令

```java
public void execute(BuildExecutionContext context, Collection<? super Throwable> taskFailures) {
        GradleInternal gradle = context.getGradle();
        if (gradle.getStartParameter().isDryRun()) {
            Iterator var4 = gradle.getTaskGraph().getAllTasks().iterator();

            while(var4.hasNext()) {
                Task task = (Task)var4.next();
                this.textOutputFactory
                    .create(DryRunBuildExecutionAction.class)
                    .append(((TaskInternal)task)
                    .getIdentityPath().getPath())
                    .append(" ").style(Style.ProgressStatus)
                    .append("SKIPPED").println();
            }
        } else {
            context.proceed();
        }

    }
```

这个过程能看到如果构建启动带上了`--dry-run`参数。能看到此时跳过了所有的任务，直接往后执行。

换句话说，当我们需要快速配置项目，比如说第一次加载工程时候。不想要依赖和构建工程，完全可以使用这个命令跳过这些任务，减少执行时间。

##### 2.2.5.2.任务的预处理

```java
TaskExecuter createTaskExecuter(TaskExecutionModeResolver repository,
                                BuildCacheController buildCacheController,
                                TaskInputsListener inputsListener,
                                TaskActionListener actionListener,
                                OutputChangeListener outputChangeListener,
                                ClassLoaderHierarchyHasher classLoaderHierarchyHasher,
                                TaskSnapshotter taskSnapshotter,
                                FileCollectionFingerprinterRegistry fingerprinterRegistry,
                                BuildOperationExecutor buildOperationExecutor,
                                AsyncWorkTracker asyncWorkTracker,
                                BuildOutputCleanupRegistry cleanupRegistry,
                                ExecutionHistoryStore executionHistoryStore,
                                OutputFilesRepository outputFilesRepository,
                                BuildScanPluginApplied buildScanPlugin,
                                FileCollectionFactory fileCollectionFactory,
                                PropertyWalker propertyWalker,
                                TaskExecutionGraphInternal taskExecutionGraph,
                                TaskExecutionListener taskExecutionListener,
                                TaskListenerInternal taskListenerInternal,
                                TaskCacheabilityResolver taskCacheabilityResolver,
                                WorkExecutor<AfterPreviousExecutionContext, CachingResult> workExecutor,
                                ReservedFileSystemLocationRegistry reservedFileSystemLocationRegistry,
                                ListenerManager listenerManager
) {

    boolean buildCacheEnabled = buildCacheController.isEnabled();
    boolean scanPluginApplied = buildScanPlugin.isBuildScanPluginApplied();
    // 这个 executer 才是真正执行 task 的
    TaskExecuter executer = new ExecuteActionsTaskExecuter(
        buildCacheEnabled,
        scanPluginApplied,
        taskSnapshotter,
        executionHistoryStore,
        buildOperationExecutor,
        asyncWorkTracker,
        actionListener,
        taskCacheabilityResolver,
        fingerprinterRegistry,
        classLoaderHierarchyHasher,
        workExecutor,
        listenerManager
    );
    // 下面这些都是装饰
    executer = new ValidatingTaskExecuter(executer, reservedFileSystemLocationRegistry);
    executer = new SkipEmptySourceFilesTaskExecuter(inputsListener, executionHistoryStore, cleanupRegistry, outputChangeListener, executer);
    executer = new ResolveBeforeExecutionOutputsTaskExecuter(taskSnapshotter, executer);
    if (buildCacheEnabled || scanPluginApplied) {
        executer = new StartSnapshotTaskInputsBuildOperationTaskExecuter(buildOperationExecutor, executer);
    }
    executer = new ResolveAfterPreviousExecutionStateTaskExecuter(executionHistoryStore, executer);
    executer = new CleanupStaleOutputsExecuter(cleanupRegistry, outputFilesRepository, buildOperationExecutor, outputChangeListener, executer);
    executer = new FinalizePropertiesTaskExecuter(executer);
    executer = new ResolveTaskExecutionModeExecuter(repository, fileCollectionFactory, propertyWalker, executer);
    executer = new SkipTaskWithNoActionsExecuter(taskExecutionGraph, executer);
    executer = new SkipOnlyIfTaskExecuter(executer);
    executer = new CatchExceptionTaskExecuter(executer);
    executer = new EventFiringTaskExecuter(buildOperationExecutor, taskExecutionListener, taskListenerInternal, executer);
    return executer;
}
```

任务执行器通过装饰者设计层层包装。

ExecuteActionsTaskExecuter 为真正执行Task任务对象

接下来就从最外层的核心嵌套装饰者开始介绍

- 1.EventFiringTaskExecuter 回调一个构建之前的监听
- 2.CatchExceptionTaskExecuter 为这个任务添加`try -catch`
- 3.SkipOnlyIfTaskExecuter 判断到在task中设置`onlyif`方法，根据该boolean方法判断当前的Task是否跳过。
- 4.SkipTaskWithNoActionsExecuter 跳过那些通过`dry-run`之类的方法，蒋设置为`skip`的任务
- 5.ResolveTaskExecutionModeExecuter 解析Task属性，如输出和输出。获取Task的`Execution Mode`执行模式。执行模式决定了当前的Task是否加载缓存代替执行任务，决定是否记录缓存。
- 6. SkipEmptySourceFilesTaskExecuter 跳过那些没有任何输入文件的任务
- 7.ValidatingTaskExecuter 对Task的属性进行校验

#### 2.2.5.3.执行任务

核心是`TaskExecution` 中的`execute` 方法

```java
        public WorkResult execute(@Nullable InputChangesInternal inputChanges) {
            this.task.getState().setExecuting(true);

            WorkResult var2;
            try {
                ExecuteActionsTaskExecuter.LOGGER.debug("Executing actions for {}.", this.task);
                ExecuteActionsTaskExecuter.this.actionListener.beforeActions(this.task);
                ExecuteActionsTaskExecuter.this.executeActions(this.task, inputChanges);
                var2 = this.task.getState().getDidWork() ? WorkResult.DID_WORK : WorkResult.DID_NO_WORK;
            } finally {
                this.task.getState().setExecuting(false);
                ExecuteActionsTaskExecuter.this.actionListener.afterActions(this.task);
            }

            return var2;
        }
```

- 1.会回调执行钱的监听
- 2.executeActions 会执行Task中的Action中的execute方法。
- 3.为当前的任务打上标识位。

### 2.2.6 结束

实际上很简单，没做什么事情就是回调构建结束的监听。

#### 2.2.7.总结

实际上在Gradle脚本中我们可以为上面6个生命周期添加监听。如下图：
![gradle生命周期监听.png](/images/gradle生命周期监听.png)




## 3.Groovy和build.gradle 之间的关系

本文将不会聊太多的Groovy的语法。关于Groovy的语法，如果熟悉kotlin的是十分容易上手的。

能看到在生命周期中，通过`settings.gradle`找到每个子模块的`build.gradle`文件。并且会尝试着在Config的过程中，找到Project后，并执行每一个子项目的`build.gradle`文件。

虽然表现形式不同，文件后缀不同，但是`build.gradle`的确是一个`groovy`的脚本。之所以可以表现出如此洁净的方式，也得益于Groovy的闭包设计。

那么问题来了。`build.gradle`是如何执行，才能让`build.gradle`文件和Gradle构建联系到一起呢？


先来看看一个简单`build.gradle`脚本：

```java
apply plugin: 'com.android.application'
apply plugin: 'kotlin-android'
apply plugin: 'kotlin-android-extensions'
apply plugin: 'com.image.monitor'

android {
    compileSdkVersion 30
    buildToolsVersion "30.0.2"

    defaultConfig {
        applicationId "com.yjy.gradletest"
        minSdkVersion 21
        targetSdkVersion 30
        versionCode 1
        versionName "1.0"

        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"

    }

    buildTypes {
        release {
            minifyEnabled false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }

    compileOptions {
        sourceCompatibility 1.8
        targetCompatibility 1.8
    }
}

task("hello") {
    println("--- hello")
}


dependencies {
    implementation fileTree(dir: "libs", include: ["*.jar"])
    implementation "org.jetbrains.kotlin:kotlin-stdlib:$kotlin_version"
    implementation 'androidx.core:core-ktx:1.1.0'
    implementation 'androidx.appcompat:appcompat:1.1.0'
    implementation 'androidx.constraintlayout:constraintlayout:2.0.4'
    testImplementation 'junit:junit:4.12'
    androidTestImplementation 'androidx.test.ext:junit:1.1.2'
    androidTestImplementation 'androidx.test.espresso:espresso-core:3.3.0'

}
```

能看到这里面有了一个Android模块构建的基本要素：
- `android` 构建插件
- 自定义插件
- `android` 构建插件
- 依赖

这种写法也必定可以转化为`.groovy`后缀的文件写法。但是这样不直观，我们可以直接看看build.gradle 转化的class文件就能一目了然整个`build.gradle`是如何执行的。

我们可以下载安装groovy环境，并调用命令`groovyc classes build.gradle`。把上述`build.gradle`文件转化为下面直观的class文件：

```java
public class build extends Script {
    public build() {
        CallSite[] var1 = $getCallSiteArray();
        super();
    }

    public build(Binding context) {
        CallSite[] var2 = $getCallSiteArray();
        super(context);
    }

    public static void main(String... args) {
        CallSite[] var1 = $getCallSiteArray();
        var1[0].call(InvokerHelper.class, build.class, args);
    }

    public Object run() {
        CallSite[] var1 = $getCallSiteArray();
        var1[1].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "com.android.application"}));
        var1[2].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "kotlin-android"}));
        var1[3].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "kotlin-android-extensions"}));
        var1[4].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "com.image.monitor"}));

        final class _run_closure1 extends Closure implements GeneratedClosure {
            public _run_closure1(Object _outerInstance, Object _thisObject) {
                CallSite[] var3 = $getCallSiteArray();
                super(_outerInstance, _thisObject);
            }

            public Object doCall(Object it) {
                CallSite[] var2 = $getCallSiteArray();
                var2[0].callCurrent(this, 30);
                var2[1].callCurrent(this, "30.0.2");

                final class _closure4 extends Closure implements GeneratedClosure {
                    public _closure4(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();
                        var2[0].callCurrent(this, "com.yjy.gradletest");
                        var2[1].callCurrent(this, 15);
                        var2[2].callCurrent(this, 30);
                        var2[3].callCurrent(this, 1);
                        var2[4].callCurrent(this, "1.0");
                        return var2[5].callCurrent(this, "androidx.test.runner.AndroidJUnitRunner");
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }
                }

                var2[2].callCurrent(this, new _closure4(this, this.getThisObject()));

                final class _closure5 extends Closure implements GeneratedClosure {
                    public _closure5(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();

                        final class _closure7 extends Closure implements GeneratedClosure {
                            public _closure7(Object _outerInstance, Object _thisObject) {
                                CallSite[] var3 = $getCallSiteArray();
                                super(_outerInstance, _thisObject);
                            }

                            public Object doCall(Object it) {
                                CallSite[] var2 = $getCallSiteArray();
                                var2[0].callCurrent(this, false);
                                return var2[1].callCurrent(this, var2[2].callCurrent(this, "proguard-android-optimize.txt"), "proguard-rules.pro");
                            }

                            @Generated
                            public Object doCall() {
                                CallSite[] var1 = $getCallSiteArray();
                                return this.doCall((Object)null);
                            }
                        }

                        return var2[0].callCurrent(this, new _closure7(this, this.getThisObject()));
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }
                }

                var2[3].callCurrent(this, new _closure5(this, this.getThisObject()));

                final class _closure6 extends Closure implements GeneratedClosure {
                    public _closure6(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();
                        var2[0].callCurrent(this, $const$0);
                        return var2[1].callCurrent(this, $const$0);
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }

                    static {
                        __$swapInit();
                    }
                }

                return var2[4].callCurrent(this, new _closure6(this, this.getThisObject()));
            }

            @Generated
            public Object doCall() {
                CallSite[] var1 = $getCallSiteArray();
                return this.doCall((Object)null);
            }
        }

        var1[5].callCurrent(this, new _run_closure1(this, this));

        final class _run_closure2 extends Closure implements GeneratedClosure {
            public _run_closure2(Object _outerInstance, Object _thisObject) {
                CallSite[] var3 = $getCallSiteArray();
                super(_outerInstance, _thisObject);
            }

            public Object doCall(Object it) {
                CallSite[] var2 = $getCallSiteArray();
                return var2[0].callCurrent(this, "--- hello");
            }

            @Generated
            public Object doCall() {
                CallSite[] var1 = $getCallSiteArray();
                return this.doCall((Object)null);
            }
        }

        var1[6].callCurrent(this, "hello", new _run_closure2(this, this));

        final class _run_closure3 extends Closure implements GeneratedClosure {
            public _run_closure3(Object _outerInstance, Object _thisObject) {
                CallSite[] var3 = $getCallSiteArray();
                super(_outerInstance, _thisObject);
            }

            public Object doCall(Object it) {
                CallSite[] var2 = $getCallSiteArray();
                var2[0].callCurrent(this, var2[1].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"dir", "libs", "include", ScriptBytecodeAdapter.createList(new Object[]{"*.jar"})})));
                var2[2].callCurrent(this, new GStringImpl(new Object[]{var2[3].callGroovyObjectGetProperty(this)}, new String[]{"org.jetbrains.kotlin:kotlin-stdlib:", ""}));
                var2[4].callCurrent(this, "androidx.core:core-ktx:1.1.0");
                var2[5].callCurrent(this, "androidx.appcompat:appcompat:1.1.0");
                var2[6].callCurrent(this, "androidx.constraintlayout:constraintlayout:2.0.4");
                var2[7].callCurrent(this, "junit:junit:4.12");
                var2[8].callCurrent(this, "androidx.test.ext:junit:1.1.2");
                return var2[9].callCurrent(this, "androidx.test.espresso:espresso-core:3.3.0");
            }

            @Generated
            public Object doCall() {
                CallSite[] var1 = $getCallSiteArray();
                return this.doCall((Object)null);
            }
        }

        return var1[7].callCurrent(this, new _run_closure3(this, this));
    }
}
```

实际上`build.gradle` 文件整体是一个带着`main`函数的，且继承于`Script`的`build`类。

在Config阶段时候，构建完Project对象后，就会通过读取build.gradle文件的每一行数据，转化成类似上述的`class`文件。

#### 3.0. CallSite机制的介绍

在这个class文件中，很难看到有对象直接调用方法。取而代之的是通过`$getCallSiteArray` 方法间接的调用方法。



这种机制在Groovy脚本中成为`CallSite` 机制。 本质是是为了解决JVM 实现动态语言慢的原因。因为JVM的方法执行等都是静态编译完成的，几乎所有信息在编译阶段都能获得，这样就造成了基于JVM 实现的动态语言缓慢的原因之一。

为了解决这个问题，在`Groovy 1.6` 之后，就引入`CallSite` 机制。实际上就是通过反射等方式调用方法。获得一个方法下对应类型参数的执行结果缓存。也不会在编译阶段就绑定好方法和方法描述符之间的关系。而是等到运行时候在确定。

用通俗一点的话，就是每一行的执行都通过反射参数的方式进行占位，只有等到运行时候才能确定真正运行对象。

#### 3.1.build.gradle 的执行入口
在这个类中，会调用main方法的核心方法。

```java
    public static void main(String... args) {
        CallSite[] var1 = $getCallSiteArray();
        var1[0].call(InvokerHelper.class, build.class, args);
    }
```

实际上这里调用的是`InvokerHelper`的`runScript`方法。这个方法会构建一个构建根据传入的`build`类构建`build`对象，并反射调用run方法。


#### 3.2.build.gradle的构建内容

在`build.gradle` 转化的class文件中可以分为3个闭包对象，以及设置插件部分。

##### 3.2.1.设置插件部分与执行插件原理

```java
        CallSite[] var1 = $getCallSiteArray();
        var1[1].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "com.android.application"}));
        var1[2].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "kotlin-android"}));
        var1[3].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "kotlin-android-extensions"}));
        var1[4].callCurrent(this, ScriptBytecodeAdapter.createMap(new Object[]{"plugin", "com.image.monitor"}));
```

这一部分实际上做的是，调用了`DefaultProject` 的`apply`方法。
```java
    public void apply(Map<String, ?> options) {
        DefaultObjectConfigurationAction action = this.createObjectConfigurationAction();
        ConfigureUtil.configureByMap(options, action);
        action.execute();
    }
```

此时会生成`DefaultObjectConfigurationAction` 对象，并以当前map的key为索引找到`DefaultObjectConfigurationAction`对应的方法，把Map的的value注入进去。

比如在这里，我们设置了一个Android构建插件`com.android.application`.此时会生成一个`DefaultObjectConfigurationAction`  对象。而在这个对象中，存在如下一个`plugin`方法。此时`ConfigureUtil.configureByMap` 就会反射该方法，并把`com.android.application` 为参数反射该方法。

并添加到`DefaultObjectConfigurationAction`准备执行`actions` 队列中。等到后续的时机在通过这个`Runnable`对象，执行到Android构建插件中。

```java
    public ObjectConfigurationAction plugin(final String pluginId) {
        this.actions.add(new Runnable() {
            public void run() {
                DefaultObjectConfigurationAction.this.applyType(pluginId);
            }
        });
        return this;
    }
```


当`configureByMap`执行结束后，就会执行`DefaultObjectConfigurationAction`的`execute`方法执行actions的准备执行队列，在这里执行的是`applyType`方法。


每一个String类型的插件，都会先从缓存查找是否缓存了对应字符串对应的插件类对象。会把每一个插件对应的缓存类都缓存到`idMappings`中，如下：

```java
this.idMappings = CacheBuilder.newBuilder().build(new CacheLoader<DefaultPluginRegistry.PluginIdLookupCacheKey, Optional<PluginImplementation<?>>>() {
            public Optional<PluginImplementation<?>> load(DefaultPluginRegistry.PluginIdLookupCacheKey key) throws Exception {
                PluginId pluginId = key.getId();
                ClassLoader classLoader = key.getClassLoader();
                PluginDescriptorLocator locator = new ClassloaderBackedPluginDescriptorLocator(classLoader);
                PluginDescriptor pluginDescriptor = locator.findPluginDescriptor(pluginId.toString());
                if (pluginDescriptor == null) {
                    return Optional.absent();
                } else {
                    String implClassName = pluginDescriptor.getImplementationClassName();
                    if (!GUtil.isTrue(implClassName)) {
                        throw new InvalidPluginException(String.format("No implementation class specified for plugin '%s' in %s.", pluginId, pluginDescriptor));
                    } else {
                        Class implClass;
                        try {
                            implClass = classLoader.loadClass(implClassName);
                        } catch (ClassNotFoundException var10) {
                            throw new InvalidPluginException(String.format("Could not find implementation class '%s' for plugin '%s' specified in %s.", implClassName, pluginId, pluginDescriptor), var10);
                        }

                        PotentialPlugin<?> potentialPlugin = pluginInspector.inspect(implClass);
                        PluginImplementation<Object> withId = DefaultPluginRegistry.this.new RegistryAwarePluginImplementation(classLoader, pluginId, potentialPlugin);
                        return (Optional)Cast.uncheckedCast(Optional.of(withId));
                    }
                }
            }
        });
```

首先每一个通过plugin方法设置进来的插件，都会包装成一个`PluginId`。此时会尝试的获取缓存，获取不到则通过如下两行代码获取字符串对应的插件入口类：
```java
 String implClassName = pluginDescriptor.getImplementationClassName();
                    if (!GUtil.isTrue(implClassName)) {
...
                    } else {
                        Class implClass;
                        try {
                            implClass = classLoader.loadClass(implClassName);
                        } catch (ClassNotFoundException var10) {
                            ...
                        }

                        PotentialPlugin<?> potentialPlugin = pluginInspector.inspect(implClass);
                        PluginImplementation<Object> withId = DefaultPluginRegistry.this.new RegistryAwarePluginImplementation(classLoader, pluginId, potentialPlugin);
                        return (Optional)Cast.uncheckedCast(Optional.of(withId));
                    }
```
```
    public String getImplementationClassName() {
        Properties properties = GUtil.loadProperties(this.propertiesFileUrl);
        return properties.getProperty("implementation-class");
    }
```

能看到此时就是获取了对应的插件包路径中的`implementation-class` 属性。

这也是为什么，我们编写自定义插件的时候，必须要`META-INF/gradle-plugin`的`.properties`文件写入
```
implementation-class=com.yjy.plugin.ImageMonitor
```

才能让Gradle脚本找到对应的插件执行入口。


当找到入口类后就会实例化对象，并在如下`DefaultPluginManager`的`addPlugin`方法作为入口
```java
    private void addPlugin(Runnable adder, PluginImplementation<?> plugin, String pluginId, Class<?> pluginClass) {
        boolean imperative = plugin.isImperative();
        if (imperative) {
            Plugin<?> pluginInstance = this.producePluginInstance(pluginClass);
            if (plugin.isHasRules()) {
                this.target.applyImperativeRulesHybrid(pluginId, pluginInstance);
            } else {
                this.target.applyImperative(pluginId, pluginInstance);
            }

            this.instances.put(pluginClass, pluginInstance);
            this.pluginContainer.pluginAdded(pluginInstance);
        } else {
            this.target.applyRules(pluginId, pluginClass);
        }

        adder.run();
    }
```

调用每一个插件中的`apply`方法。



#### 3.2.2. Android 插件闭包属性

```java
final class _run_closure1 extends Closure implements GeneratedClosure {
            public _run_closure1(Object _outerInstance, Object _thisObject) {
                CallSite[] var3 = $getCallSiteArray();
                super(_outerInstance, _thisObject);
            }

            public Object doCall(Object it) {
                CallSite[] var2 = $getCallSiteArray();
                var2[0].callCurrent(this, 30);
                var2[1].callCurrent(this, "30.0.2");

                final class _closure4 extends Closure implements GeneratedClosure {
                    public _closure4(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();
                        var2[0].callCurrent(this, "com.yjy.gradletest");
                        var2[1].callCurrent(this, 15);
                        var2[2].callCurrent(this, 30);
                        var2[3].callCurrent(this, 1);
                        var2[4].callCurrent(this, "1.0");
                        return var2[5].callCurrent(this, "androidx.test.runner.AndroidJUnitRunner");
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }
                }

                var2[2].callCurrent(this, new _closure4(this, this.getThisObject()));

                final class _closure5 extends Closure implements GeneratedClosure {
                    public _closure5(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();

                        final class _closure7 extends Closure implements GeneratedClosure {
                            public _closure7(Object _outerInstance, Object _thisObject) {
                                CallSite[] var3 = $getCallSiteArray();
                                super(_outerInstance, _thisObject);
                            }

                            public Object doCall(Object it) {
                                CallSite[] var2 = $getCallSiteArray();
                                var2[0].callCurrent(this, false);
                                return var2[1].callCurrent(this, var2[2].callCurrent(this, "proguard-android-optimize.txt"), "proguard-rules.pro");
                            }

                            @Generated
                            public Object doCall() {
                                CallSite[] var1 = $getCallSiteArray();
                                return this.doCall((Object)null);
                            }
                        }

                        return var2[0].callCurrent(this, new _closure7(this, this.getThisObject()));
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }
                }

                var2[3].callCurrent(this, new _closure5(this, this.getThisObject()));

                final class _closure6 extends Closure implements GeneratedClosure {
                    public _closure6(Object _outerInstance, Object _thisObject) {
                        CallSite[] var3 = $getCallSiteArray();
                        super(_outerInstance, _thisObject);
                    }

                    public Object doCall(Object it) {
                        CallSite[] var2 = $getCallSiteArray();
                        var2[0].callCurrent(this, $const$0);
                        return var2[1].callCurrent(this, $const$0);
                    }

                    @Generated
                    public Object doCall() {
                        CallSite[] var1 = $getCallSiteArray();
                        return this.doCall((Object)null);
                    }

                    static {
                        __$swapInit();
                    }
                }

                return var2[4].callCurrent(this, new _closure6(this, this.getThisObject()));
            }

            @Generated
            public Object doCall() {
                CallSite[] var1 = $getCallSiteArray();
                return this.doCall((Object)null);
            }
        }

        var1[5].callCurrent(this, new _run_closure1(this, this));
```

```
android {
    compileSdkVersion 30
    buildToolsVersion "30.0.2"

    defaultConfig {
        applicationId "com.yjy.gradletest"
        minSdkVersion 21
        targetSdkVersion 30
        versionCode 1
        versionName "1.0"

        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"

    }

    buildTypes {
        release {
            minifyEnabled false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }

    compileOptions {
        sourceCompatibility 1.8
        targetCompatibility 1.8
    }
}
```

class 文件的闭包层级对应上`build.gradle` 中的`android` 闭包模块。而这个对象实际上指的就是`com.android.application` 插件 中设置的 扩展对象`AppExtension`.

- 闭包`defaultConfig`  对应在`BaseExtension` 中的`defaultConfig`  方法。
- 闭包`buildTypes` 对应在`BaseExtension` 中的`buildTypes`  方法。
- 闭包`compileOptions`对应在`BaseExtension` 中的 `compileOptions` 方法。



## 4.Android插件的周期

通过第二节，我们熟悉了Gradle的基本生命周期。通过简单的扫一遍生命周期源码对Gradle有一个初步的熟悉。

通过第三节得知了Groovy脚本和build.gradle 之间的关系。并了解了实际上所有的Android项目打包构建操作都是来源于插件`com.android.application` .

现在再来聊聊Android 插件的周期。


从Gradle的生命周期，我们可以得知在`Config`生命周期中，会从根项目开始解析每一个子模块的`build.gradle`文件，在Config阶段把其中的插件信息收集起来并执行。


从`3.2.1` 节可以得知，实际上所有的插件都是从gradle安装目录下,和当前写在`build.gradle`的插件名相同的`. properties ` 文件。 实现类的入口为`implementation-class` 所对应的全类名。



从`build.gradle` 开始看看Android插件`apply plugin: 'com.android.application'`.对应在如下文件名`com.android.application.properties`：

```
implementation-class=com.android.build.gradle.AppPlugin
```

此时会在`PluginManager` 中实例化这个`AppPlugin`  对象，并执行这个对象的`apply` 方法。 当然这个过程会校验，这个class是否是可以转化为`Plugin`接口实现的对象。

### 4.1.AppPlugin 注册扩展对象

```java
public class AppPlugin extends AbstractAppPlugin {
    @Inject
    public AppPlugin(
            ToolingModelBuilderRegistry registry, SoftwareComponentFactory componentFactory) {
        super(registry, componentFactory, true /*isBaseApplication*/);
    }

    @Override
    protected void pluginSpecificApply(@NonNull Project project) {
    }

    @Override
    protected void registerModelBuilder(
            @NonNull ToolingModelBuilderRegistry registry,
            @NonNull GlobalScope globalScope,
            @NonNull VariantManager variantManager,
            @NonNull BaseExtension extension,
            @NonNull ExtraModelInfo extraModelInfo) {
        registry.register(
                new AppModelBuilder(
                        globalScope,
                        variantManager,
                        taskManager,
                        (BaseAppModuleExtension) extension,
                        extraModelInfo,
                        getProjectType()));
    }

    @Override
    @NonNull
    protected Class<? extends AppExtension> getExtensionClass() {
        return BaseAppModuleExtension.class;
    }
....
}

```

AppPlugin 继承了`AbstractAppPlugin ` ，实现了`Plugin`接口。在基类`AbstractAppPlugin`中：

```java
    protected BaseExtension createExtension(
            @NonNull Project project,
            @NonNull ProjectOptions projectOptions,
            @NonNull GlobalScope globalScope,
            @NonNull NamedDomainObjectContainer<BuildType> buildTypeContainer,
            @NonNull NamedDomainObjectContainer<ProductFlavor> productFlavorContainer,
            @NonNull NamedDomainObjectContainer<SigningConfig> signingConfigContainer,
            @NonNull NamedDomainObjectContainer<BaseVariantOutput> buildOutputs,
            @NonNull SourceSetManager sourceSetManager,
            @NonNull ExtraModelInfo extraModelInfo) {
        return project.getExtensions()
                .create(
                        "android",
                        getExtensionClass(),
                        project,
                        projectOptions,
                        globalScope,
                        buildTypeContainer,
                        productFlavorContainer,
                        signingConfigContainer,
                        buildOutputs,
                        sourceSetManager,
                        extraModelInfo,
                        isBaseApplication);
    }
```
通过如下方法，为AppPlugin注册了一个`android`的扩展`BaseAppModuleExtension`对象，并保存在`ExtensionContainer`中。 实现了这个扩展对象，并注册在`ExtensionContainer` 中，就能在`build.gradle`  使用`android` 闭包了。

后续的执行步骤，都会从这个android闭包中，获取对应的数据，从而做到可配置的构建打包。


### 4.2. AppPlugin 执行入口

```java
    public final void apply(@NonNull Project project) {
        CrashReporting.runAction(
                () -> {
                    basePluginApply(project);
                    pluginSpecificApply(project);
                });
    }
```

- 1.basePluginApply 则是构建整个Android包的入口方法
- 2.pluginSpecificApply 用于处理如Feature动态模块的

```java
private void basePluginApply(@NonNull Project project) {
        // We run by default in headless mode, so the JVM doesn't steal focus.
        System.setProperty("java.awt.headless", "true");

        this.project = project;
....
        threadRecorder.record(
                ExecutionType.BASE_PLUGIN_PROJECT_CONFIGURE,
                project.getPath(),
                null,
                this::configureProject);

        threadRecorder.record(
                ExecutionType.BASE_PLUGIN_PROJECT_BASE_EXTENSION_CREATION,
                project.getPath(),
                null,
                this::configureExtension);

        threadRecorder.record(
                ExecutionType.BASE_PLUGIN_PROJECT_TASKS_CREATION,
                project.getPath(),
                null,
                this::createTasks);
    }
```

核心是三部分线程池中执行的三个函数：
- 1.configureProject 为工程配置`JavaBasePlugin`,并创建了一个`assemble`任务容器，并监听了项目的构建结束行为后，清除缓存，关闭工作中线程。

- 2.configureExtension 为`AppPlugin` 配置`BaseVariantOutput` 输出扩展对象;同时通过4.1节的`createExtension`创建`android`扩展对象；创建任务管理者、发布渠道管理者;添加`buildTypeContainer`接收到打包结束的监听，并根据签名进行签名。

- 3.createTasks 创建任务 监听project的`BeforeEvaluate`,在项目执行build脚本之前添加一些前置的任务。监听project的`afterEvaluate`添加并运行Apk包打包的任务。

核心代码在BasePlugin 下：

```java
final void createAndroidTasks() {

...
List<VariantScope> variantScopes = variantManager.createAndroidTasks();
...
    }
```

通过`variantManager` 创建Android 的构建打包核心任务。

```java
    public void createTasksForVariantData(final VariantScope variantScope) {
        final BaseVariantData variantData = variantScope.getVariantData();
        final VariantType variantType = variantData.getType();
        final GradleVariantConfiguration variantConfig = variantScope.getVariantConfiguration();

        taskManager.createAssembleTask(variantData);
        if (variantType.isBaseModule()) {
            taskManager.createBundleTask(variantData);
        }

        if (variantType.isTestComponent()) {
...
        } else {
            taskManager.createTasksForVariantScope(
                    variantScope,
                    variantScopes
                            .stream()
                            .filter(TaskManager::isLintVariant)
                            .collect(Collectors.toList()));
        }
    }
```

核心是通过`ApplicationTaskManager` 调用的`createTasksForVariantScope` 创建Android的打包任务。

### 4.3 Android 构建的任务

```java
public void createTasksForVariantScope(
            @NonNull final VariantScope variantScope,
            @NonNull List<VariantScope> variantScopesForLint) {
...
        // Create all current streams (dependencies mostly at this point)
        createDependencyStreams(variantScope);

        // Add a task to publish the applicationId.
        createApplicationIdWriterTask(variantScope);


...

        // Add a task to check the manifest
        taskFactory.register(new CheckManifest.CreationAction(variantScope));

        // Add a task to process the manifest(s)
        createMergeApkManifestsTask(variantScope);

        // Add a task to create the res values
        createGenerateResValuesTask(variantScope);

        // Add a task to compile renderscript files.
        createRenderscriptTask(variantScope);

        // Add a task to merge the resource folders
        createMergeResourcesTasks(variantScope);

        // Add tasks to compile shader
        createShaderTask(variantScope);

        // Add a task to merge the asset folders
        createMergeAssetsTask(variantScope);

        // Add a task to create the BuildConfig class
        createBuildConfigTask(variantScope);

        // Add a task to process the Android Resources and generate source files
        createApkProcessResTask(variantScope);

        registerRClassTransformStream(variantScope);

        // Add a task to process the java resources
        createProcessJavaResTask(variantScope);

        createAidlTask(variantScope);

        // Add external native build tasks
        createExternalNativeBuildJsonGenerators(variantScope);
        createExternalNativeBuildTasks(variantScope);

        // Add a task to merge the jni libs folders
        createMergeJniLibFoldersTasks(variantScope);

        // Add feature related tasks if necessary
        if (variantScope.getType().isBaseModule()) {
...
        } else {
        ...
        }

        // Add data binding tasks if enabled
        createDataBindingTasksIfNecessary(variantScope);

        // Add a compile task
        createCompileTask(variantScope);

        taskFactory.register(new StripDebugSymbolsTask.CreationAction(variantScope));

        if (variantScope.getVariantData().getMultiOutputPolicy().equals(MultiOutputPolicy.SPLITS)) {
            if (extension.getBuildToolsRevision().getMajor() < 21) {
                throw new RuntimeException(
                        "Pure splits can only be used with buildtools 21 and later");
            }

            createSplitTasks(variantScope);
        }

        createPackagingTask(variantScope);

        maybeCreateLintVitalTask(
                (ApkVariantData) variantScope.getVariantData(), variantScopesForLint);

        // Create the lint tasks, if enabled
        createLintTasks(variantScope, variantScopesForLint);

        taskFactory.register(new PackagedDependenciesWriterTask.CreationAction(variantScope));

        createDynamicBundleTask(variantScope);

        taskFactory.register(new ApkZipPackagingTask.CreationAction(variantScope));

        if (!variantScope.getGlobalScope().hasDynamicFeatures()) {
            createSoftwareComponent(variantScope, "_apk", APK_PUBLICATION);
        }
        createSoftwareComponent(variantScope, "_aab", AAB_PUBLICATION);
    }
```

- 1.createDependencyStreams 创建依赖库的读取流保存在`TransformManager`中，等待后续的TransformClasses流程使用

- 2. createApplicationIdWriterTask 读取`build.gradle`中`android`闭包的ApplicationId。

- 3.CheckManifest.CreationAction 校验Manifest.xml 格式是否正常

- 4.createMergeApkManifestsTask 合并所有模块的Manifest.xml

- 5.createGenerateResValuesTask  创建每个资源所对应的id

- 6.createRenderscriptTask 编译`renderscript` 文件

- 7.createMergeResourcesTasks 合并资源任务

- 8.createShaderTask 编译`Shader`着色器文件

- 9.createMergeAssetsTask 合并`asset`文件夹的内容

- 10.createBuildConfigTask 生成`BuildConfig.class` 文件任务

- 11.createApkProcessResTask 替换id为R文件中对应的ID，并且进行aapt2的资源文件进行混淆。

- 12.registerRClassTransformStream 为`TransformManager` 添加资源文件流，为后续添加自定义转化资源id做准备

- 13.createProcessJavaResTask 通过Java 源代码到同一个目录下

- 14.createAidlTask 转化`aidl`文件为class文件

- 15.createExternalNativeBuildJsonGenerators，createExternalNativeBuildTasks，createMergeJniLibFoldersTasks 处理jni模块并进行编译

- 16.createDataBindingTasksIfNecessary 处理dataBinding任务

- 17.createCompileTask 编译java代码，并且进行混淆

- 18.createPackagingTask 进行apk的打包

- 19.PackagedDependenciesWriterTask 打包进依赖文件

- 20.ApkZipPackagingTask 把所有生成的多个apk包等编译产物进行进一步的打包。如多渠道打包时候，可以把多个apk进行打包。

这些任务都有自己的所属的任务组，也有自己的依赖顺序。当在`RunTasks`阶段的时候，就会运行并且编译。细节方面本文就暂时不聊，等到后续有机会会一个个任务的看看Android插件是如何执行的。

用一副很经典的图总结如下：

![android打包流程.png](/images/android打包流程.png)



## 5.自定义插件

如何自定义插件，已经从上述4节有了初步的了解。现在来实战一下，我们写一个Transform 把所有继承于`ImageView`的对象都转化为自定义的ImageView从而监听所有ImageView的行为：

当我们需要添加一个插件如下：
```
apply plugin: 'com.image.monitor'
```

我们可以新建一个`buildSrc`模块，并在文件夹main下建立`/resources/META-INF/gradle-plugins` 文件夹，并创建一个和插件名一致的文件：`com.image.monitor.properties`

并写入如下内容，实现入口类名：

```
implementation-class=com.yjy.plugin.ImageMonitor
```


### 5.1 ImageMonitor 入口内容

```groovy
class ImageMonitor implements Plugin<Project>{

    @Override
    void apply(Project project) {
       // println "project -->"+project

        // 找到android 插件
        def android = project.extensions.getByType(AppExtension)
        //注册一个新的transform
        android.registerTransform(new ImageTransform())
    }
}
```

一般的流程首先找到`AppExtension` 扩展对象。这个对象就是AppPlugin注册好的对外扩展对象。并调用`registerTransform` 添加自定义的`ImageTransform`.


当配置阶段解析执行`buildSrc`后，就会把`ImageTransform`对象 保存到`TransformManager`中。此时会等到`Android` 最顶层项目的`build.gradle `执行`apply` 方法后，会把`TransformManager` 中注册的转化器转为`TransformTask`任务 全部设置到 该模块编译完Java模块后，合并转化dex之前。

因此`Transform` 可以处理每个模块的源码，以及链接的第三方库。注意，是没办法处理Android源码。

### 5.2.ImageTransform 实现

```java
class ImageTransform extends Transform{

    @Override
    String getName() {
        return "ImageTransform"
    }

    //关注的目标
    @Override
    Set<QualifiedContent.ContentType> getInputTypes() {
        return TransformManager.CONTENT_CLASS
    }

    @Override
    Set<? super QualifiedContent.Scope> getScopes() {
        return TransformManager.SCOPE_FULL_PROJECT
    }

    // 增量编译
    @Override
    boolean isIncremental() {
        return false
    }

    @Override
    void transform(TransformInvocation transformInvocation) throws TransformException, InterruptedException, IOException {
        super.transform(transformInvocation)

        Collection<TransformInput> inputs = transformInvocation.inputs
        TransformOutputProvider outputs = transformInvocation.outputProvider

        if(outputs != null){
            outputs.deleteAll()
        }

        inputs.each { TransformInput input ->
            // 处理自己写的代码
            input.directoryInputs.each { DirectoryInput dicInput ->
                handleDicInput(dicInput,outputs)
            }

            // 处理引入的包
            input.jarInputs.each { JarInput jarInput ->
               handleJarInput(jarInput,outputs)
            }


        }
    }

    void handleJarInput(JarInput jarInput,TransformOutputProvider outputs){
        if(jarInput.file.absolutePath.endsWith(".jar")){
            // 先拷贝到一个临时的jar ，然后在从临时的jar拷贝回去
            def jarName = jarInput.name
            def md5Name = DigestUtils.md5Hex(jarInput.file.getAbsolutePath())

            if(jarName.endsWith(".jar")){
                jarName = jarName.substring(0,jarName.length() - 4)
            }

            JarFile jarFile = new JarFile(jarInput.file)
            Enumeration enumeration = jarFile.entries()

            File tmpFile  = new File(jarInput.file.getParent()+File.separator+"class_temp.jar")

            if(tmpFile.exists()){
                tmpFile.delete()
            }

            JarOutputStream jarOutputStream = new JarOutputStream(new FileOutputStream(tmpFile))


            while (enumeration.hasMoreElements()){

                JarEntry entry = (JarEntry)enumeration.nextElement()
                // println("zipEntry->" + entry)
                String entryName = entry.name
                def zipEntry = new ZipEntry(entryName)
                def inputStream = jarFile.getInputStream(zipEntry)
                // println("zipEntry->" + entryName)

                if(filterClass(entryName)){
                    jarOutputStream.putNextEntry(zipEntry)
                    ClassReader classReader = new ClassReader(IOUtils.toByteArray(inputStream))
                    def writer = new ClassWriter(0)

                    ClassVisitor visitor = new MonitorImageClassVisitor(writer)

                    classReader.accept(visitor,ClassReader.EXPAND_FRAMES)

                    byte[] code = writer.toByteArray()
                    jarOutputStream.write(code)
                }else{
                    // 不是class文件 直接写到临时的jar中
                    jarOutputStream.putNextEntry(zipEntry)
                    jarOutputStream.write(IOUtils.toByteArray(inputStream))
                }


                jarOutputStream.closeEntry()
                // println("zipEntry close->" + entryName)
            }

            jarOutputStream.close()
            jarFile.close()

            //input 写入到 output
            def dest = outputs.getContentLocation(jarName+md5Name,
                    jarInput.contentTypes,jarInput.scopes, Format.JAR)

//            println("copy name->" + jarName+md5Name)
//
//            println("copy ->" + dest)

            FileUtils.copyFile(tmpFile,dest)

            tmpFile.delete()

        }


    }


    void handleDicInput(DirectoryInput dicInput,TransformOutputProvider outputs){
        if(dicInput.file.isDirectory()){
            dicInput.file.eachFileRecurse { File file ->
                String name = file.name
                if(filterClass(name)){
                    ClassReader reader = new ClassReader(file.bytes)
                    ClassWriter writer = new ClassWriter(0)

                    // 修改这里就好
                    ClassVisitor visitor = new MonitorImageClassVisitor(writer)

                    reader.accept(visitor,ClassReader.EXPAND_FRAMES)

                    // 覆盖dic
                    byte[] code =writer.toByteArray()
                    FileOutputStream out = new FileOutputStream(file.
                            parentFile.absolutePath+File.separator+name)
                    out.write(code)

                    out.close()

                }
            }
        }

        //input 写入到 output
        def dest = outputs.getContentLocation(dicInput.name,
                dicInput.contentTypes,dicInput.scopes, Format.DIRECTORY)

        FileUtils.copyDirectory(dicInput.file,dest)
    }

    boolean filterClass(String className){
        return ((className.endsWith(".class"))&& (!className.startsWith("R\$"))
                && (!"R.class".equals(className))&&(!"BuildConfig.class".equals(className)))
    }
}
```

- getInputTypes 在生成`TramsformTask` 之前会根据该方法找到转化器关注的数据流，从而封装成一个任务。 这里代表的是，关注class文件

- getScopes 代表该转化器作用的范围

- isIncremental 是否增量更新


- transform 方法是关注的输入流传进来后，经过这边的处理转化为输出流输出出去。

- 本文中`handleDicInput` 代表了遍历文件夹中所有的class文件，通过MonitorImageClassVisitor 对文件流进行修改处理，并覆盖在原来的class文件上

- 本文中`handleJarInput` 代表遍历该模块链接的所有的jar包。先解压jar包的内容，再把里面的class流进行修改后再拷贝到全新的jar包中。最后把该新jar包覆盖到老的上面

最后两点其实都是模版代码。


### 5.2. ClassVisitor

```java
public class MonitorImageClassVisitor extends ClassVisitor {

    public MonitorImageClassVisitor(ClassVisitor cv) {
        super(Opcodes.ASM6, cv);
    }


    @Override
    public void visit(int version, int access, String name, String signature, String superName, String[] interfaces) {

        if("android/widget/ImageView".equals(superName)&&!"com/yjy/gradletest/MonitorImageView".equals(name)){
            System.out.println("superName ->"+superName+ " name->"+name);
            superName = "com/yjy/gradletest/MonitorImageView";
            System.out.println("superName ->"+superName+ " name->"+name);
        }

        super.visit(version, access, name, signature, superName, interfaces);
    }

    @Override
    public AnnotationVisitor visitAnnotation(String descriptor, boolean visible) {
        return super.visitAnnotation(descriptor, visible);
    }

    @Override
    public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {

        MethodVisitor visitor = super.visitMethod(access, name, descriptor, signature, exceptions);
        SampleMethodVisitor methodVisitor=new SampleMethodVisitor(visitor,access,name,descriptor);
        return methodVisitor;
    }


    @Override
    public FieldVisitor visitField(int access, String name, String descriptor, String signature, Object value) {
        return super.visitField(access, name, descriptor, signature, value);
    }
}
```

该方法实际上是用于通过ClassReader监听遍历class数据流。当检测到不同的属性或者方法会回调。

`visitMethod` 是指访问每一个class中的方法。而这边返回自定义的`AdviceAdapter` 对象则是对当前方法加工后的返回。

`AdviceAdapter` 来源于ASM库对`MethodVisitor`的封装。

本文中`visit` 方法是访问到的每一个class文件流的回调。此时会判断当前的父类是`android/widget/ImageView`并且不是`com/yjy/gradletest/MonitorImageView`类。那么就把这种ImageView全部继承于`com/yjy/gradletest/MonitorImageView`。

这样就能在`com/yjy/gradletest/MonitorImageView` 中监听到所有操作ImageView的信息。


### 5.3. AdviceAdapter

```java
class SampleMethodVisitor extends AdviceAdapter {
    private String mMethodName;

    public SampleMethodVisitor(MethodVisitor methodVisitor,int access,String methodName,String des) {
        super(Opcodes.ASM6, methodVisitor,access,methodName,des);
        this.mMethodName = methodName;
    }

    @Override
    public AnnotationVisitor visitAnnotation(String descriptor, boolean visible) {
        return super.visitAnnotation(descriptor, visible);
    }

    @Override
    public void visitParameter(String name, int access) {
        super.visitParameter(name, access);
    }


    /**
     * 访问到每一行
     * @param opcode
     * @param owner
     * @param name
     * @param descriptor
     * @param isInterface
     */
    @Override
    public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
        if(mMethodName.equals("onCreate")&&owner.equals("androidx/appcompat/app/AppCompatActivity")){
            System.out.println("visit methodName ->"+mMethodName);
            // 访问方法
            mv.visitLdcInsn("TAG");
            mv.visitLdcInsn("enterMethod");
            mv.visitMethodInsn(Opcodes.INVOKESTATIC,"android/util/Log","e",
                    "(Ljava/lang/String;Ljava/lang/String;)I",false);
            mv.visitInsn(POP);
        }
        super.visitMethodInsn(opcode, owner, name, descriptor, isInterface);
//        if(name.equals("onCreate")){
//            System.out.println("owner:"+owner+" name:"+name);
//        }

    }

    @Override
    public void visitCode() {

        super.visitCode();

    }

    @Override
    public void visitEnd() {

        super.visitEnd();
    }
}
```

- visitAnnotation 访问方法的注解

- visitParameter 访问方法参数

- visitMethodInsn 访问方法每一行

- visitEnd 访问结束


整个AdviceAdapter生命执行的流程如下：
> visitAnnotationDefault?
( visitAnnotation | visitParameterAnnotation | visitAttribute )*
( visitCode
( visitTryCatchBlock | visitLabel | visitFrame | visitXxxInsn |
visitLocalVariable | visitLineNumber )*
visitMaxs )?
visitEnd


可以在我们关心的流程中，class中每一个方法，每一个属性，每一个注解做到自己想要ASM插桩，或者修改。

本文在`visitMethodInsn` 中检测到当前方法所属的class为`androidx/appcompat/app/AppCompatActivity` 并且是`onCreate`方法，就会添加一个 `Log.e("TAG","enterMethod")` 方法的打印。



### 5.4.自定义插件 总结

这里写入新的方法在每一行方法中，并非是像aspectj 直接hook那些字符串模版匹配的方法，直接通过反射设置到原来方法前后。而这里则是省去了反射，直接通过字节码的方式，写入方法。

如果我们不太能根据写出来的方法对应字节码，不妨使用`AMS ByteCode OutLine` 插件转化出来复制到需要的位置即可。


这种方式实际上在很多地方都有用到。比如说在RePlugin中对插件的处理，比如说在性能优化中通过这种ASM插桩检测慢方法，anr等。学会这种方式，就能完成更多看起来不太可能实现功能。

这种方式我也在写业务中使用。比如说进行全局的插桩权限申请流程，从而做到权限申请之前做自己的特殊业务流程。


## 6.总结

最后感谢这个系列的文章：

- [Gradle源码分析](https://www.jianshu.com/p/625bc82003d7)
- [CallSite机制](https://blog.csdn.net/johnny_jian/article/details/83362796)
- [辉哥的Gradle 插件 + ASM 实战 - 监控图片加载告警](https://www.jianshu.com/p/206d00dfd683)

本文花了很长时间撰写。需要的资料和基础散落在不同的地方。辉哥推荐的两本书也只是基础介绍，并没有对Gradle有深度的剖析，看完了还是云里雾里，需要自己看一遍Gradle的运行源码。而且Groovy的发展十分快，很多资料也是散落在不同的第方法，着实花了不少时间。

这里并非是什么高深的文章,仅仅只是对Gradle的入门，对整个Gradle有一个统筹的印象。实际上我们编写Android项目时候，可以阅读通过Extension 暴露出来的android 扩展对象做到更多有趣的事情。

下篇来聊聊，如何捕捉Java层和native层的异常。