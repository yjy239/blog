---
title: 效能笔记 Android单元测试与JUnit源码解析
top: false
cover: false
date: 2022-04-24 23:27:15
img:
tag: test
description:
author: yjy239
summary:
---

# 前言

进入大厂已经有一段时间了，这段时间确实接触了在外面未曾接触到很多东西。而在外界津津乐道的进阶知识点（什么native hook，性能监控，插件化），在大厂内部只是常识罢了。这群大牛早在16年的时候发文研究透了。

还是需要端正态度，从零开始吧。首先就来记录一下，这段时间研究的单元测试。因为在公司的项目中，都需要对测试的覆盖率进行扫描警告。如果覆盖率不达标，就会无法合并到主分支。

作为从小公司一步步成长起来，单元测试这一块只是有研究。在上一家公司，也只是对核心模块进行简单的单测，并没进行系统性的学习。前段时间翻阅了google 在github上各种单测的demo，以及学习的codelab 对单测有一个整体的理解了。


接下来，就以google的一些demo说说自己的见解和总结。


# 正文

## 单元测试概述

首先，先要明白单元测试的概念。什么是单元测试？为什么要做单元测试？

什么是单元测试：

- 单元测试是软件工程中降低开发成本，提高软件质量的方法之一。
- 单元测试是一项由开发人员或者测试人员对程序正确性进行校验的工作，用于检查被检查的代码功能是否正确。

为什么要做单元测试：

- 降低开发成本
- 边界检测提高代码质量
- 提高代码的设计的解耦度


在项目的迭代中，有一种模式名为`测试驱动开发`的方式。其含义是把迭代中每一个应用视为一系列的模块， 在开发设计每一个功能时候，就先编写一个测试，然后不断的添加断言在其中，在编写的设计的过程中同时考虑到隔离性正确性。

![testing-workflow.png](/images/testing-workflow.png)


实际上在正常开发中很多开发认为单元测试浪费大量的时间，反而拖慢了工程进度；也有可能是需求变动比较大，一直以测试的方式不断的驱动开发有点太理想了。


这种说法我也认可，但是只是局限于紧急上线的项目情况，但是最好事后还是补上单元测试。但是如果是在正常迭代的项目，个人认为单元测试是必不可少的。

特别是当考虑到代码需要单元测试时候，如果单元测试是比较好写，少了很多mock说明代码设计的不错，解耦和隔离都做的不错。


### 单元测试的组成

那么如何进行单元测试呢？一般来说，单元测试有一个十分经典的图，很好的划分了一个应用应该如何进行单元测试，单元测试到什么程度？

![测试金字塔.png](/images/测试金字塔.png)


实际上一个应用的单元测试可以分为三种程度测试，对应到Android开发中：

- 70%的小型测试：单元测试。对应到Android开发中是指本地单元测试(执行本地的JVM 如 `Mockito`)或者依赖测试模拟的Android环境进行单元测试(如`Robolectric `)。

- 20%的中型测试：集成测试. 对应到Android 开发中 就是使用`Espresso` 链接真机模拟真实操作

- 10%的大型测试：端对端测试。对应到Android开发中，就是使用如Google提供的 [Firebase 测试实验室](https://firebase.google.cn/docs/test-lab/) 在云端进行大规模测试你的应用，会通过验证不同的机型环境下你的应用是否能够正常运行。如在腾讯中，还会有录屏等功能分析视频中的帧数，校验元素的间距是否正常。往往是通过插桩等手段进行监控。


#### 单元测试的几种方式

单元测试往往是测试一个个类的测试其正确性。

实际上，随着工程的迭代，工程会越来越复杂。简单的单元测试是越来越难以满足需求：特别是一个需求比较复杂的时候，一个类将会依赖很多外来的类，这样测试一个类的时候往往还需要依赖外部类的正确性，这样就会出现无法确定单个类本身是否会出现被依赖类影响结果。

在大厂内部甚至会对单元测试的速度有限制。那么依赖网络请求和数据库的单测就更加不好做了。还会出现网络情况和数据库的情况出现对于同一种输入有不同的结果，如正确或者异常的情景。

因此在做单测又有一个原则：
> 有依赖外部输入请保证外部输出的正确性和稳定性。

因此，对于网络请求和数据库相关的单元测试一般都会想办法转化成内存级别的输入输出。对于网络和数据库相关的单测请再自己模块进行测试，保证业务和组件库的隔离。

为了解决上述种种问题，就诞生了测试替代(Test Doubles)的方式。其本质就是合理的隔离外部依赖，提高测试的正确性和速度。

|方式|含义
|--|--
|`Fake` (假对象)| 一般是单测依赖对象抽象出需要对外业务的接口。创建一个全新的对象实现该接口。而实现的方法将会重新实现，代替原来所有复杂的实现(如网络请求和数据库请求)。一般是用于`ViewModel` 中所控制的数据仓库对象，把其中相关磁盘存储，网络请求替换成内存级别的实现
|`Mock` (模拟对象)| 可以将类替换成一个全新对象，可以跟踪方法的运行情况。甚至允许类中的实现转化成空实现。但是mock出来的 |
| `Stub` (存根) | 将依赖类转化成一个无逻辑的，只返回结果的类|
|Dummy (虚拟对象)| 提供一个没有任何操作的测试代替对象给单测对象 |
|`Spy` (间谍)| 将可以跟踪被Spy持有的类的运行结果 |

最常见的方式就是，`Fake`,`Mock`,`Spy`。

Spy看起来和Mock有点相似。两者的区别是，Mock往往只关注方法是否被调用，不关心方法执行情况，因此会把Mock持有的类替换成空实现返回。

Spy相反，关心这个类中相关的实现。也可以通过Mockito等库强制将某个方法返回的方法设置为某个值

## Android的单元测试

这里直接单刀直入，来聊聊在Android开发中常用的几种单元测试的库。

- `JUnit4` 这是最基础的单元测试库。一般是在Android中的test的目录下，仅仅用于测试无关Android环境的Java 类，只提供了最基础的单元测试断言以及运行环境

- ` Mockito` 这是用于解决测试类对其他外部的依赖，用于验证方法的调用。这个库中包含了`mock`和`spy`两种解决外部依赖方案

- `PowerMock` 这个库可以看成`Mockito`的升级版。`Mock`存在着无法获取static静态对象和方法，private私有对象和方法的缺点。实际上单测需要获取这些私有对象来确定是否执行正确。`PowerMock`则很好的解决了这个缺点。

- `Robolectric` 本地模拟Android 环境运行Android相关的测试代码

- `Espresso` 这是生成一个单测的apk包在真机或者模拟机上运行单元测试代码

- `androidx.test.ext:junit`，`androidx.fragment:fragment-testing`等 提供一些Androidx的测试便捷库。

- `mockk`用于给kotlin使用的mock 测试库

- `JMock` 一个专门用于验证方法执行的Mock库


大致上用到的就是这些库，就能解决大部分的单元测试的用例。


#### JUnit4 使用

来看看JUnit4的使用。

首先在`build.gradle`中加入如下依赖：

```
androidTestImplementation "junit:junit:$junitVersion"
```


创建测试类ExampleUnitTest，并创建一个方法`addition_isCorrect`.注意该方法上要添加 `@Test`注解。

```kotlin
class ExampleUnitTest {
    @Test
    fun addition_isCorrect() {
        assertEquals(4, 2 + 2)
    }
}
```

能看到在这个方法中，通过一个断言`assertEquals`方法来判断参数左右两侧是否相等，来决定本方法的测试是否通过。

原则上一个单元测试的方法，最好职责单一。也就尽可能的本地单元测试尽可能少的断言。

在JUnit中，有几个重要的注解需要注意:
|注解|使用|
|-|-|
|@Test|代表当前方法为一个测试方法|
|@Before|在执行每一个测试方法之前的调用，一般做依赖类的准备操作|
|@After|执行完所有方法后的调用，一般进行资源回收|
|@Ignore|被忽略的测试方法|
|@BeforeClass|在类中所有方法运行前运行。必须是static void修饰的方法|
|@AfterClass|类最后运行的方法|
|@RunWith|指定该测试类使用某种运行器|
|@Parameters|指定测试类的测试数据集合|
|@Rule|重新定制测试类中方法的行为|
|@FixMethodOrder|指定测试类中方法的顺序|

其中，比较常用的注解：

- `@RunWith` 是指当前类运行的测试环境，一般注释在类智商。一般的Java运行环境默认是JUnit4。而在Android中，如果需要一些涉及到Android环境，可以添加`@AndroidJUnit4`。

则会初始化一个Instrument，在这个对象中进行hook。如果跟着我的系列一直看过来的，都知道实际上这个对象就是开发者的四大组件Activity 沟通到AMS的中间键.源码就不展开说了。

- `@Rule` 是指测试的规则。每一个测试的通用处理方式。我们可以自定义@Rule，让一个类的每一个测试方法增加前后日志，或者多执行几次测试方法。

知道这些注解后，来看看常用的断言(Asset)Api:

|断言|描述|
|-|-|
|assertNotEquals|断言预期传入值和实际值不相等|
|assertArrayEquals|断言预期传入数组和实际数组值相等|
|assertNull|断言传入对象是空|
|assertNotNull|断言传入对象不是空|
|assertTrue|断言为真|
|assertFalse|断言条件为假|
|assertSame|断言两个对象是同一个对象，相当于"=="|
|assertNotSame|断言两个对象不是同一个对象，相当于"!="|
|assertThat|断言实际值是否满足指定条件|


assertThat简单看看使用：

```java
assertThat(testedNumber, allOf(greaterThan(8), lessThan(16)));
```

这里是指该断言需要通过不抛出异常，需要如下两个条件：`testedNumber` 大于9，小于16.

当然，除此之外，还有匹配器。这里面匹配器是指来自`hamcrest`库中，为你扩展好的断言方法，可通过如下的方式进行依赖：
  
```
testImplementation "org.hamcrest:hamcrest-all:$hamcrestVersion"
```

如：

```java
assertThat(result.completedTasksPercent, `is`(0f))
```

判断completedTasksPercent是否是0f。

|匹配|说明例子|
|-|-|
|is|断言参数等于后面给出的匹配表达式|
|not|断言参数不等于后面给出的匹配表达式|
|equalTo|断言参数相等|
|equalToIgnoreCase|断言字符串忽略大小写是否相等|
|containString|断言字符包含字符串|
|startsWith|断言字符串以某字符串开始|
|endWith|断言字符串以某字符串结束|
|nullValue|断言参数的值为null|
|notNullValue|断言参数的值不为null|
|greaterThan|断言参数大于|
|lessThan|断言参数小于|
|greaterThanOrEqualTo|断言参数大于等于|
|lessThanOrEqualTo|断言参数小于等于|
|closeTo|断言浮点型数在某一范围内|
|allOf|断言符合所有条件，相当于&&|
|anyOf|断言符合某一个条件，相当于或|
|hasKey|断言Map集合包含有此键|
|hasValue|断言Map集合包含有此值|
|hasItem|断言迭代对象含有此元素|



### Mockito 

Mockito 可以说是Android单元测试中最常见的库。
这个库可以解决如下2个问题：

- 1.解决测试类对其他类的依赖
- 2.验证方法的调用

#### 1.解决测试类对其他类的依赖

为什么会出现这种问题，又解决了什么？先来看看开发中一个常见的例子：

一般在设计一个ViewModel。我们肯定不希望让外部了解内部过多的知道这个对象的内部设计和组成，保证知道最少原则，会通过如下的方式创建一个跟着ViewModelStore生命周期的ViewModel：

```kotlin
private val viewModel by viewModels<TaskDetailViewModel>()
```

或者通过Java进行如下的创建TasksViewModel：

```java
new ViewModelProvider(this).get(TasksViewModel.class);
```

这样做法快捷简单，如果一个ViewModel中没有任何一个依赖类这么设计是极好的。但是实际上，我们在使用ViewModel 并非是通过ViewModel直接通信获取数据的。往往会添加一个`Repository`作为中转站，通信到数据层。ViewModel只是用来联通View和Model之间的中间键，最多只是做一些转化工作，以及作为返回LiveData的接口。


下面是一副来自Google的经典的MVVM的设计图：

![androidx_mvvm设计.png](/images/androidx_mvvm设计.png)

换句话说，可以通过ViewModel灵活的决定Repository，Repository数据层是应该来自网络还是本地数据库。从而做到一些如二级缓存的设计。


那么在实际测试的时候，就会出现问题了。由于你的单测ViewModel/视图的时候是依赖网络或者数据库。那么就会出现网络异常，db缓慢等各种特殊情况。一个单测方法会出现多重结果，导致测试不通过。

为了杜绝这种情况，我们往往会做出如下的设计：

```java
class TasksViewModel(private val tasksRepository:ITasksRepository) : ViewModel()
```

让一个TaskModel 可以通过组合的方式决定一个数据层的来源.

既然ViewModel的构造函数发生了变化，相对的也需要对应ViewModelFactory的实现：

```kotlin
class TasksViewModelFactory(
        private val tasksRepository: ITasksRepository
) : ViewModelProvider.NewInstanceFactory() {
    override fun <T : ViewModel> create(modelClass: Class<T>) =
            (TasksViewModel(tasksRepository) as T)
}
```

```kotlin
private val viewModel by viewModels<TasksViewModel>() {
        TasksViewModelFactory((requireActivity().application as TodoApplication).taskRepository)
    }
```

通过这样的改造后就能实现组合的方式任意控制Repository。这样当需要单元测试的时候，自己可以创建一个虚假的Repository注入到ViewModel 中。从而实现规避网络和数据的通信。

为了能够让接口统一，一般的我们会为面向ViewModel的`Repository`抽象出统一接口层。之后ViewModel只需要面向`Repository`接口即可。


这种构建一个内存级别的`Repository` 交给ViewModel的方式，也就是我上面说的Fake方式。

每一个ViewModel都为了单元测试构建一个内存级别的虚假返回`Repository`对象。如果是业务量比较大，也是比较麻烦的一件事情。

也因为有如此需求，就诞生了Mockito一类的库。


##### Mockito 中mock方式使用：


一个Mock对象可以通过如下两种方式进行构建：

```java
mockEditor = Mockito.mock(SharedPreferences.Editor::class.java)
```

```
@RunWith(MockitoJUnitRunner::class)
@Mock private lateinit var mockEditor: SharedPreferences.Editor
```

下面这个注解方式本质上就是调用了Mockito.mock 方法。Mockito.mock 可以看成构建了一个SharedPreferences.Editor对象，只是里面都是空实现。也就是返回null或者0.

看看一个Mock对象的使用：

```kotlin
    private fun createBrokenMockSharedPreference(): SharedPreferencesHelper {
        // Mocking a commit that fails.
        given(mockBrokenEditor.commit()).willReturn(false)

        // Return the broken MockEditor when requesting it.
        given(mockBrokenSharedPreferences.edit()).willReturn(mockBrokenEditor)
        return SharedPreferencesHelper(mockBrokenSharedPreferences)
    }
```

在这里面的意思是当`mockBrokenEditor` 调用了`commit() ` 方法就会返回false。

当`mockBrokenSharedPreferences `调用了`edit()`方法，就会返回`mockBrokenEditor `对象。

能看到这个过程实际上决定一个Mock方法中对象每一个方法在特别条件下返回的结果。从而避免过多的构建Fake对象。

当然如果想要一个方法具体执行其中的内容，可以通过`doCallRealMethod`的方法执行。


##### Mockito 中的spy

Mockito除了了Mock方式之外，还有一种spy的方式。

```
 Mockito.spy(A())
```
这种方式，和Mock的区别就是。spy不会让所有的方法都返回空实现，而是有具体实现。

那么这种方式使用如下，并且关闭掉某个方法的返回：

```
val A = A()

 Mockito.spy(A)

doReturn(0).when(A).testPlus(Mockito.anyInt(),Mockito.anyInt())
```

这样可以保证A的testPlus方法具体实现不变的情况下，返回一个0.


##### 2.验证方法

在Mockito中，Mockito.verify是用来验证方法是否调用了。

```java
A a = Mockito.mock(A.class);
a.testPlus(1,1);
Mockito.verify(a).testPlus(1,1);
Mockito.verify(a,times(1)).testPlus(1,1);
Mockito.verify(a,atLeast(1)).testPlus(1,1);
```


### PowerMockito

Mockito看起来很美好，实际上还有不少的问题没办法解决。

往往我们都需要通过assert的断言来判断结果是否为正确执行。而在写代码的过程中，往往会把重要的缓存结果数据作为私有缓存在内存中。

但是Mockito无法访问私有变量，因此很多时候Mockito是无法满足日常的使用。

因此出现了PowerMockito，这个方案可以访问私有，静态，final的属性。

使用方式，详细可以阅读：https://github.com/powermock/powermock/wiki

先来看看使用,首先可以进行如下依赖：

```
    testImplementation "org.powermock:powermock-api-mockito:1.6.2"
    testImplementation "org.powermock:powermock-module-junit4:${powermock}"
    testImplementation "org.powermock:powermock-module-junit4-rule:${powermock}"
    testImplementation "org.powermock:powermock-classloading-xstream:${powermock}"
    testImplementation "org.powermock:powermock-core:${powermock}"
```

注意，api写成1.6.2.api从这个版本之后就没有更新了。

注意，本质上PowerMock 是对Mockito的一次扩展，因此需要把powerMock和Mock的版本对应上：

|Mockito|PowerMock|
|-|-|
|2.8.9+|	2.x|
|2.8.0-2.8.9|	1.7.x|
|2.7.5|	1.7.0RC4|
|2.4.0|	1.7.0RC2|
|2.0.0-beta - 2.0.42-beta|	1.6.5-1.7.0RC|
|1.10.8 - 1.10.x|	1.6.2 - 2.0|
|1.9.5-rc1 - 1.9.5|	1.5.0 - 1.5.6|
|1.9.0-rc1 & 1.9.0|	1.4.10 - 1.4.12|
|1.8.5|	1.3.9 - 1.4.9|
|1.8.4|	1.3.7 & 1.3.8|
|1.8.3|	1.3.6|
|1.8.1 & 1.8.2|	1.3.5|
|1.8|	1.3|
|1.7|	1.2.5|


下面是一个例子：

```java
@RunWith(PowerMockRunner.class)
// We prepare PartialMockClass for test because it's final or we need to mock private or static methods
@PrepareForTest(PartialMockClass.class)
public class YourTestCase {
    @Test
    public void spyingWithPowerMock() {        
        PartialMockClass classUnderTest = PowerMockito.spy(new PartialMockClass());

        // use Mockito to set up your expectation
        Mockito.when(classUnderTest.methodToMock()).thenReturn(value);

        // execute your test
        classUnderTest.execute();

        // Use Mockito.verify() to verify result
        Mockito.verify(mockObj, times(2)).methodToMock();
    }
}
```

- 1.`@RunWith(PowerMockRunner.class)` 首先添加一个运行环境`PowerMockRunner`
- 2.`@PrepareForTest` 设置需要PowerMock的mock类。

##### 1.读取私有对象

```java
PartialMockClass classUnderTest = PowerMockito.spy(new PartialMockClass());
Whitebox.getInternalState(classUnderTest,"mList");
```

##### 2.修改对象的私有对象

```java
PartialMockClass classUnderTest = PowerMockito.spy(new PartialMockClass());
PartialMockClass innerClass = PowerMockito.spy(new PartialMockClass());
Whitebox.setInternalState(classUnderTest,"innerClass",innerClass);
```


##### 3.Verify对象私有方法

```java
PowerMockito.verifyPrivate(mMockBrokenEditor,times(1)).invoke("add", 
                Mockito.anyInt(), Mockito.anyInt());
```

##### 4.调用私有方法

```java
   Whitebox.invokeMethod(A.class,"add",1,1);
```

##### 5.修改对象私有方法

```java
PowerMockito.replace(PowerMockito.method()).with(new InvocationHandler() {
            @Override
            public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                return null;
            }
        });
```

## 5.robolectric

#### 为什么需要`robolectric`?

注意到没有，在Android工程目录来说，存在着两种test：
![test类型.png](/images/test类型.png)

- test
- androidtest

最明显的区别就是，test可以直接在本地执行单元测试。androidtest需要连接真机/模拟机才能运行单元测试。

但是对于一个单元测试来说，链接真机的场景进行测试一般是大型测试需要模拟真实环境才需要的。或者说进行ui元素相关的校验才需要的测试。而绝大部分的测试都没有要求到ui元素校验，大多只是为了校验业务数据的是否正确。而这部分业务的校验依赖了android 系统的环境导致不能不链接真机/虚拟机。

而这种中小型的测试占了50%以上的情况都需要链接真机/虚拟机就太过浪费时间了，那么有没有办法在本地进行android测试呢？

实际上对于Android sdk来说。本地依赖的都是android 对外的开放的接口，如下,因此在没有下载源码之前所有的方法都返回RuntimeExpection的异常，并没有实际的实现。

所有的实现都是依赖Android机子中具体的实现。其实就是类似jdk和jre之间的关系一样。

为了能够加快测试的速度和测试脱离真机/模拟机的依赖，使得整个流程变得自动化以及可控，就需要`robolectric`。

为什么说`robolectric` 可以避免这个问题。主要的原因就是`robolectric`自己根据JVM的运行情况，获得了需要实现api的类。把接下来所有的运行都通过Instrument的入口，转化成自己的实现的代理类。

比如说，需要一个TextView。`robolectric`就会用一个ShadowTextView代替了TextView，从而摆脱了真机/模拟机的依赖。除此了根据android.jar  实现了自己的接口，还实现了获取控件的状态。比如ImageView，就多了getImageId的接口获取当前ImageView中设置的id信息。

#### robolectric 的使用：


首先进行如下依赖：
```
androidTestImplementation "org.robolectric:robolectric:${robolectricVersion}"
```

接着加入如下注释：

```java
@RunWith(RobolectricTestRunner.class)
@Config(application = TodoApplication.class, sdk = 23)
@PowerMockIgnore({"org.mockito.*","org.robolectric.*","android.*"})
public class SPTest {

    SharedPreferences sp;

    @Rule
    public PowerMockRule rule = new PowerMockRule();

    @Before
    public void setUp() {
        sp = RuntimeEnvironment.application.getSharedPreferences("test", Context.MODE_PRIVATE);
    }
}
```

- `@RunWith(RobolectricTestRunner.class)` 设置当前单元测试的运行环境为Robolectric

- Config 配置当前的Android的版本，以及Application

- `@PowerMockIgnore({"org.mockito.*","org.robolectric.*","android.*"})` 用于解决PowerMock 和 robolectric之间的冲突。

对于一些类就没有必要进行PowerMock了，因为PowerMock 有自己的ClassLoader，叫做MockClassLoader。而robolectric也有自己的ClassLoader，叫做sandClassLoader。会造成一个类加载到两个ClassLoader会出现异常。

- ` PowerMockRule ` 这个规则也是用于解决PowerMock 和 robolectric之间的冲突



当然，也可以使用androidx推荐的单元测试库：

```
   debugImplementation "androidx.fragment:fragment-testing:$fragmentVersion"
    debugImplementation "androidx.test:core:$androidXTestCoreVersion"


    // AndroidX Test - JVM testing
    testImplementation "androidx.test:core-ktx:$androidXTestCoreVersion"
    testImplementation "androidx.test.ext:junit:$androidXTestExtKotlinRunnerVersion"

    // AndroidX Test - Instrumented testing
    androidTestImplementation "androidx.test.ext:junit:$androidXTestExtKotlinRunnerVersion"
    androidTestImplementation "androidx.test.espresso:espresso-core:$espressoVersion"
    androidTestImplementation "androidx.test.espresso:espresso-contrib:$espressoVersion"
```

使用这套androidx的单元测试库，就会帮你解决一些关于robolectric的冲突。如果翻进去阅读源码，能发现在androidx单元测试库的入口会检测当前是否依赖了`robolectric`,如果依赖了所有的逻辑就会走到了`robolectric`中。

具体的例子如下：

```java
@RunWith(RobolectricTestRunner.class)
@Config(application = TodoApplication.class, sdk = 23)
@PrepareForTest(StaticClass.class)
@PowerMockIgnore({"org.mockito.*","org.robolectric.*","android.*"})
public class SPTest {

    SharedPreferences sp;

    @Rule
    public PowerMockRule rule = new PowerMockRule();

    @Before
    public void setUp() {
        sp = RuntimeEnvironment.application.getSharedPreferences("test", Context.MODE_PRIVATE);
    }

    @Test
    public void testOk() {
        sp.edit().putString("111","aaaaa").commit();

        String value = sp.getString("111","");

        Assert.assertEquals(value,"aaaaa");
    }

    @Test
    public void testPowerMock() {
        String value = "1111";

        PowerMockito.mockStatic(StaticClass.class);

        PowerMockito.when(StaticClass.ask()).thenReturn(value);

        Assert.assertEquals(StaticClass.ask(),value);
    }
}
```
这个类可以正确运行，代表了解决了Power Mock和Robolectric都能正确运行。


#### 校验Activity的跳转

```java
@Test
public void testStartActivity() {
        //按钮点击后跳转到下一个Activity
        forwardBtn.performClick();
        Intent expectedIntent = new Intent(sampleActivity, LoginActivity.class);
        Intent actualIntent = ShadowApplication.getInstance().getNextStartedActivity();
        assertEquals(expectedIntent, actualIntent);
    }
```

剩下的如Fragment，Dialog这里就不聊了，网上有很多相关的api使用。


### 6. Espresso

这个库，一般都是用于大型测试了。因为这个库需要链接真机运行进行单元测试。一般是进行ui测试才需要的。

这里可以使用androidx的espresso库，以及支持的fragment支持库：

```
    debugImplementation "androidx.fragment:fragment-testing:$fragmentVersion"
    debugImplementation "androidx.test:core:$androidXTestCoreVersion"


    // AndroidX Test - JVM testing
    testImplementation "androidx.test:core-ktx:$androidXTestCoreVersion"
    testImplementation "androidx.test.ext:junit:$androidXTestExtKotlinRunnerVersion"

    // AndroidX Test - Instrumented testing
    androidTestImplementation "androidx.test.ext:junit:$androidXTestExtKotlinRunnerVersion"
    androidTestImplementation "androidx.test.espresso:espresso-core:$espressoVersion"
    androidTestImplementation "androidx.test.espresso:espresso-contrib:$espressoVersion"

```

下面是一个简单的例子：

```kotlin
@MediumTest
@RunWith(AndroidJUnit4::class)
@ExperimentalCoroutinesApi
class TaskDetailFragmentTest {

    private lateinit var repository: ITasksRepository

    @Before
    fun initRepository() {
        repository = FakeAndroidTestRepository()
        ServiceLocator.tasksRepository = repository
    }

    @Test
    fun activeTaskDetails_DisplayedUI() = runBlockingTest {

        val activeTask = Task("Active Task", "AndroidX Rocks", false)
        repository.saveTask(activeTask)

        val bundle = TaskDetailFragmentArgs(activeTask.id).toBundle()
        launchFragmentInContainer<TaskDetailFragment>(bundle, R.style.AppTheme)

        onView(withId(R.id.task_detail_title_text)).check(matches(isDisplayed()))
        onView(withId(R.id.task_detail_title_text)).check(matches(withText("Active Task")))

        onView(withId(R.id.task_detail_description_text)).check(matches(isDisplayed()))
        onView(withId(R.id.task_detail_description_text)).check(matches(withText("AndroidX Rocks")))

        onView(withId(R.id.task_detail_complete_checkbox)).check(matches(isDisplayed()))

        onView(withId(R.id.task_detail_complete_checkbox)).check(matches(not(isChecked())))

    }

    @After
    fun cleanupDb() = runBlockingTest {
        ServiceLocator.resetRepository()
    }
}
```

- 1. launchFragmentInContainer 装载TaskDetailFragment到一个空Activity中。
- 2. onView 找到对应id的控件，并校验View的状态。如是否展示，内容是否一致。

整个Espresso 都是遵循这种onView找到view的模式来判断整个View的展示状态是否正确。


## Android JUnit源码分析

能看到所有的测试框架都是基于JUnit4的RunWith 重写运行环境实现的。这里的简单聊聊RunWith 背后的原理。

先来看看AS在执行单元测试的命令：

```
"/Applications/Android Studio.app/Contents/jre/jdk/Contents/Home/bin/java" 
-ea -Didea.test.cyclic.buffer.size=1048576 
-javaagent:..jar com.intellij.rt.junit.JUnitStarter 
-ideVersion5 -junit4 com.example.android.architecture.blueprints.todoapp.SPTest
```
首先找到设定在系统中的java执行文件，通过`javaagent`命令先执行依赖好的所有`premain `或者`agentmain ` 在执行`SPTest`单元测试之前进行字节码拦截。

`javaagent`这种方式可以类比成我们熟悉javaassist，ASM插桩的方式。在对应类之前，先执行`javaagent`中编写好的类转化器，对类进行插桩处理。关于这个命令的使用可以阅读这个文章:https://www.cnblogs.com/rickiyang/p/11368932.html.

其实有一个插桩库`byte buddy`就是通过这种方式实现的。而在单元测试中，如`mockito`就是由`byte buddy` 实现的。通过插桩的方式改变一个类中每个方法的行为以及每个方法的跟踪。

这里就不多聊，以后有空可以和大家聊聊。我们着重看看JUint的原理。

能看到当执行完所有类转化拦截器之后，就会执行`JUnitStarter`为入口，进入它的main方法。而进入这个main方法，携带了即将测试的单元测试类名，以及当前测试方式为`junit4 `.


来看看入口函数：

文件:https://android.googlesource.com/platform/tools/idea/+/e782c57d74000722f9db4c9426317410520670c6/plugins/junit_rt/src/com/intellij/rt/execution/junit/JUnitStarter.java

```java
  public static void main(String[] args) throws IOException {
...
    int exitCode = prepareStreamsAndStart(array, isJUnit4, listeners, name[0], out, err);
    System.exit(exitCode);
  }
```

看到入口函数是`prepareStreamsAndStart`.

```java
  private static int prepareStreamsAndStart(String[] args,
                                            final boolean isJUnit4,
                                            ArrayList listeners,
                                            String name,
                                            SegmentedOutputStream out,
                                            SegmentedOutputStream err) {
..
    try {
...
      IdeaTestRunner testRunner = (IdeaTestRunner)getAgentClass(isJUnit4).newInstance();
      testRunner.setStreams(out, err, 0);
      return testRunner.startRunnerWithArgs(args, listeners, name, !SM_RUNNER);
    }
    catch (Exception e) {
..
    }
    finally {
..
    }
  }

  static Class getAgentClass(boolean isJUnit4) throws ClassNotFoundException {
    return isJUnit4
           ? Class.forName("com.intellij.junit4.JUnit4IdeaTestRunner")
           : Class.forName("com.intellij.junit3.JUnit3IdeaTestRunner");
  }

```

核心就是调用了`JUnit4IdeaTestRunner`这个类`startRunnerWithArgs`的方法。

文件：https://android.googlesource.com/platform/tools/idea/+/e782c57d74000722f9db4c9426317410520670c6/plugins/junit_rt/src/com/intellij/junit4/JUnit4IdeaTestRunner.java?autodive=0%2F

```java
  public int startRunnerWithArgs(String[] args, ArrayList listeners, String name, boolean sendTree) {
    final Request request = JUnit4TestRunnerUtil.buildRequest(args, name, sendTree);
    if (request == null) return -1;
    final Runner testRunner = request.getRunner();
...
    try {
      final JUnitCore runner = new JUnitCore();
      runner.addListener(myTestsListener);
...
      long startTime = System.currentTimeMillis();
      Result result = runner.run(testRunner/*.sortWith(new Comparator() {
        public int compare(Object d1, Object d2) {
          return ((Description)d1).getDisplayName().compareTo(((Description)d2).getDisplayName());
        }
      })*/);
   ...
      return 0;
    }
    catch (Exception e) {
...
    }
  }
```

整个核心很简单，就是实例化`JUnitCore`对象，并调用`run`方法执行在命令中传入的类名。


##### JUnitCore run

接下来的源码都能直接在AS中搜到了，就不展示地址了。

```java
public Result run(Runner runner) {
        Result result = new Result();
        RunListener listener = result.createListener();
        notifier.addFirstListener(listener);
        try {
            notifier.fireTestRunStarted(runner.getDescription());
            runner.run(notifier);
            notifier.fireTestRunFinished(result);
        } finally {
            removeListener(listener);
        }
        return result;
    }
```

注意在这个过程中通过`JUnit4TestRunnerUtil.buildRequest`创建了一个`ClassRequest`这个对象,而这个对象通过`createRunner`创建一个Runner，并调用Runner的run方法开始进行单元测试。

在这个`ClassRequest`类中：
```java
 @Override
    protected Runner createRunner() {
        return new CustomAllDefaultPossibilitiesBuilder().safeRunnerForClass(fTestClass);
    }

    private class CustomAllDefaultPossibilitiesBuilder extends AllDefaultPossibilitiesBuilder {

        @Override
        protected RunnerBuilder suiteMethodBuilder() {
            return new CustomSuiteMethodBuilder();
        }
    }
```

```java
    public Runner safeRunnerForClass(Class<?> testClass) {
        try {
            Runner runner = runnerForClass(testClass);
            if (runner != null) {
                configureRunner(runner);
            }
            return runner;
        } catch (Throwable e) {
            return new ErrorReportingRunner(testClass, e);
        }
    }
```

能看到实际上是通过`runnerForClass`创建一个runner对象，并调用`configureRunner`方法处理类的`OrderWith`注解，判断是否需要顺序执行。

而这个runnerForClass 就是指`AllDefaultPossibilitiesBuilder`的runnerForClass方法。

#### AllDefaultPossibilitiesBuilder runnerForClass

```java
@Override
    public Runner runnerForClass(Class<?> testClass) throws Throwable {
        List<RunnerBuilder> builders = Arrays.asList(
                ignoredBuilder(),
                annotatedBuilder(),
                suiteMethodBuilder(),
                junit3Builder(),
                junit4Builder());

        for (RunnerBuilder each : builders) {
            Runner runner = each.safeRunnerForClass(testClass);
            if (runner != null) {
                return runner;
            }
        }
        return null;
    }
```

能看到`RunnerBuilder` 有如下几种RunnerBuilder：

- 1.IgnoredBuilder
- 2.AnnotatedBuilder
- 3.JUnit3Builder
- 4.JUnit4Builder

能看到这个设计实际上和okhttp的拦截器很相似。这几个Builder实际上就是负责了RunWith注解方法。

- 1.首先会查找类是否带上`Ignore`注解，是则忽略这个单元测试
- 2.然后`AnnotatedBuilder`会查找有没有内部类RunWith的注解，有就使用这个RunWith的运行环境。
- 3.接着确认RunWith的注解是否是`TestCase`是则会当作JUnit3进行处理
- 4.上面三个运行环境都是没有执行，就会默认当成JUnit4

#### `AnnotatedBuilder`：

```java
    @Override
    public Runner runnerForClass(Class<?> testClass) throws Exception {
        for (Class<?> currentTestClass = testClass; currentTestClass != null;
             currentTestClass = getEnclosingClassForNonStaticMemberClass(currentTestClass)) {
            RunWith annotation = currentTestClass.getAnnotation(RunWith.class);
            if (annotation != null) {
                return buildRunner(annotation.value(), testClass);
            }
        }
        return null;
    }

    private Class<?> getEnclosingClassForNonStaticMemberClass(Class<?> currentTestClass) {
        if (currentTestClass.isMemberClass() && !Modifier.isStatic(currentTestClass.getModifiers())) {
            return currentTestClass.getEnclosingClass();
        } else {
            return null;
        }
    }
```

在这个`runnerForClass` for循环中会不断的获取非静态成员类的的闭合类。其实就是相当于在，不断从内部类不断向外找，直到找到第一个带有RunWith注解的类。

此时就可以拿到这个RunWith 生成自己所需要的Runner对象。所有的第三方单元测试组件都是通过这个注解，从而让整个单元测试进入到第三方组件的控制中。如Mockito，Mockk，Robolectric都是这样实现的。

再来简单看看`JUnit4Builder`：

```java
public class JUnit4Builder extends RunnerBuilder {
    @Override
    public Runner runnerForClass(Class<?> testClass) throws Throwable {
        return new JUnit4(testClass);
    }
}

public final class JUnit4 extends BlockJUnit4ClassRunner {
    /**
     * Constructs a new instance of the default runner
     */
    public JUnit4(Class<?> klass) throws InitializationError {
        super(new TestClass(klass));
    }
}
```

##### ParentRunner run

来看看`JUnit4`这个的run方法，这个方法由基类`ParentRunner`实现

```java
    @Override
    public void run(final RunNotifier notifier) {
        EachTestNotifier testNotifier = new EachTestNotifier(notifier,
                getDescription());
        testNotifier.fireTestSuiteStarted();
        try {
            Statement statement = classBlock(notifier);
            statement.evaluate();
        } catch (AssumptionViolatedException e) {
            testNotifier.addFailedAssumption(e);
        } catch (StoppedByUserException e) {
            throw e;
        } catch (Throwable e) {
            testNotifier.addFailure(e);
        } finally {
            testNotifier.fireTestSuiteFinished();
        }
    }

    protected Statement classBlock(final RunNotifier notifier) {
        Statement statement = childrenInvoker(notifier);
        if (!areAllChildrenIgnored()) {
            statement = withBeforeClasses(statement);
            statement = withAfterClasses(statement);
            statement = withClassRules(statement);
            statement = withInterruptIsolation(statement);
        }
        return statement;
    }
```

能看到整个过程是使用Statement来代表JUnit4 在单元测试中的环境配置行为。

#### classBlock 实现

```java
    protected Statement withBeforeClasses(Statement statement) {
        List<FrameworkMethod> befores = this.testClass.getAnnotatedMethods(BeforeClass.class);
        return (Statement)(befores.isEmpty() ? statement : new RunBefores(statement, befores, (Object)null));
    }

    protected Statement withAfterClasses(Statement statement) {
        List<FrameworkMethod> afters = this.testClass.getAnnotatedMethods(AfterClass.class);
        return (Statement)(afters.isEmpty() ? statement : new RunAfters(statement, afters, (Object)null));
    }

    private Statement withClassRules(Statement statement) {
        List<TestRule> classRules = this.classRules();
        return (Statement)(classRules.isEmpty() ? statement : new RunRules(statement, classRules, this.getDescription()));
    }

    protected final Statement withInterruptIsolation(final Statement statement) {
        return new Statement() {
            @Override
            public void evaluate() throws Throwable {
                try {
                    statement.evaluate();
                } finally {
                    Thread.interrupted(); // clearing thread interrupted status for isolation
                }
            }
        };
    }
```

```java
    protected Statement childrenInvoker(final RunNotifier notifier) {
        return new Statement() {
            public void evaluate() {
                ParentRunner.this.runChildren(notifier);
            }
        };
    }

 private void runChildren(final RunNotifier notifier) {
        RunnerScheduler currentScheduler = this.scheduler;

        try {
            Iterator i$ = this.getFilteredChildren().iterator();

            while(i$.hasNext()) {
                final T each = i$.next();
                currentScheduler.schedule(new Runnable() {
                    public void run() {
                        ParentRunner.this.runChild(each, notifier);
                    }
                });
            }
        } finally {
            currentScheduler.finished();
        }

    }
```

能看到实际上是先取出注解`BeforeClass`,`AfterClass`,`ClassRule` 层层包裹起来。当执行的时候也是层层解开不断往底层回溯的通过`statement.evaluate`执行注解好的方法。

- 1.`childrenInvoker` 首先创造了一个statement 对象，这个对象的`evaluate` 调用了`runChild`方法。这里简称runChild的Statement
- 2.构建一个`RunBefores`的Statement对象，包裹住`runChild`Statment
- 3.构建一个`RunAfters `Statment对象包裹`RunBefores`
- 4.构建一个`RunRules`包裹`RunAfters ` 对象
- 5.withInterruptIsolation 生成一个抓异常的Statement把所有的执行全部catch住。


当run方法开始执行`evaluate`方法的时候。就会从`withInterruptIsolation`生成的Statement方法开始执行。

![JUnit_Statement.png](/images/JUnit_Statement.png)

来看看这几个`Statement`都完成了什么？先来看看最外层包裹的`RunRules`


#### RunRules

```java
public class RunRules extends Statement {
    private final Statement statement;

    public RunRules(Statement base, Iterable<TestRule> rules, Description description) {
        statement = applyAll(base, rules, description);
    }

    @Override
    public void evaluate() throws Throwable {
        statement.evaluate();
    }

    private static Statement applyAll(Statement result, Iterable<TestRule> rules,
            Description description) {
        for (TestRule each : rules) {
            result = each.apply(result, description);
        }
        return result;
    }
}
```
能看到`RunRules`在构造函数就会调用每一个`TestRule`对象的`apply`方法，实现每一个TestRule 所规定的规则。有的单元测试超时计算就是通过这种方式实现。

在evaluate的方法调用他包裹的对象。此时就是`RunAfters`对象


#### RunAfters

```java
public class RunAfters extends Statement {
    private final Statement next;

    private final Object target;

    private final List<FrameworkMethod> afters;

    public RunAfters(Statement next, List<FrameworkMethod> afters, Object target) {
        this.next = next;
        this.afters = afters;
        this.target = target;
    }

    @Override
    public void evaluate() throws Throwable {
        List<Throwable> errors = new ArrayList<Throwable>();
        try {
            next.evaluate();
        } catch (Throwable e) {
            errors.add(e);
        } finally {
            for (FrameworkMethod each : afters) {
                try {
                    invokeMethod(each);
                } catch (Throwable e) {
                    errors.add(e);
                }
            }
        }
        MultipleFailureException.assertEmpty(errors);
    }

    /**
     * @since 4.13
     */
    protected void invokeMethod(FrameworkMethod method) throws Throwable {
        method.invokeExplosively(target);
    }
}
```

能看到这个对象`evaluate`很简单，先调用他包裹的Statement对象后，再执行`invokeMethod`方法。`invokeMethod`实际上就是反射加了@ AfterClass的方法。

此时会先调用被包裹的`BeforeClass`的Statement

#### RunBefores

```java
public class RunBefores extends Statement {
    private final Statement next;

    private final Object target;

    private final List<FrameworkMethod> befores;

    public RunBefores(Statement next, List<FrameworkMethod> befores, Object target) {
        this.next = next;
        this.befores = befores;
        this.target = target;
    }

    @Override
    public void evaluate() throws Throwable {
        for (FrameworkMethod before : befores) {
            invokeMethod(before);
        }
        next.evaluate();
    }

    /**
     * @since 4.13
     */
    protected void invokeMethod(FrameworkMethod method) throws Throwable {
        method.invokeExplosively(target);
    }
```
能看到这个`evaluate`方法中，先执行了那些加了`BeforeClass`方法后·，再执行他包裹的Statement。此时这个Statement 就是runChild生成的Statement。

最后看看BlockJUnit4ClassRunner runChild方法

##### BlockJUnit4ClassRunner runChild

在JUnit4的父类`BlockJUnit4ClassRunner`中做了对`runChild`的实现

```java
    @Override
    protected void runChild(final FrameworkMethod method, RunNotifier notifier) {
        Description description = describeChild(method);
        if (isIgnored(method)) {
            notifier.fireTestIgnored(description);
        } else {
            Statement statement = new Statement() {
                @Override
                public void evaluate() throws Throwable {
                    methodBlock(method).evaluate();
                }
            };
            runLeaf(statement, description, notifier);
        }
    }
```
能看到如果不是加上ignore注解的方法，都会包裹一层Statement，并在这个Statement中的`evaluate`方法调用一次`methodBlock`方法。


#### BlockJUnit4ClassRunner methodBlock的实现

```java
    protected Statement methodBlock(final FrameworkMethod method) {
        Object test;
        try {
            test = new ReflectiveCallable() {
                @Override
                protected Object runReflectiveCall() throws Throwable {
                    return createTest(method);
                }
            }.run();
        } catch (Throwable e) {
            return new Fail(e);
        }

        Statement statement = methodInvoker(method, test);
        statement = possiblyExpectingExceptions(method, test, statement);
        statement = withPotentialTimeout(method, test, statement);
        statement = withBefores(method, test, statement);
        statement = withAfters(method, test, statement);
        statement = withRules(method, test, statement);
        statement = withInterruptIsolation(statement);
        return statement;
    }
```

这里就是处理每一个方法级别的处理注解。这里处理的逻辑和上面的逻辑一样。这里简单的说一下顺序：

- 1.先执行所有的加了`@Rule`注解的属性所对应的TestRule对象的apply方法
- 2.执行所有加了`@Before`的方法
- 3.紧接着，通过possiblyExpectingExceptions 包裹住后续方法需要catch的Exception
- 4.为每一个单元测试方法新增一个超时时间
- 5.反射执行单元测试

至此整个单元测试的流程就走通了，十分简单。


## 后话

只要摸清了JUnit的运行原理，才能对单元测试的编写中变得游刃有余。公司内部对单元测试由许多思考，着实让我大开眼界。比如如何对单元测试进行精确的计时，如何优化单元测试的速度，如何设计才是最为合适设计以及易于测试，如何设计自己的运行环境RunWith，编写自动化单元测试等等。这些大佬能做到这些事情无一例外的都对单元测试的源码有深刻了解才能做到。

我还是一个小萌新，需要继续埋头前行。
