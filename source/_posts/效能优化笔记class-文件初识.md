---
title: 效能优化笔记class 文件初识
top: false
cover: false
date: 2021-03-23 17:23:16
img:
tag:
description:
author: yjy239
summary:
categories: JVM
tags:
- JVM
---

# 前言

我一直觉得我的学习态度和方法很有问题，不然也不会觉得自己走到一个奇怪的瓶颈。一个很特殊的怪圈，就是怎么学都达不到大厂的水准和效率。从现在开始需要端正自己的态度，低姿态学习。学的多，不如学的牢固稳妥。

后续的更新计划，只要加班不厉害，每周都会跟着辉哥的开课视频写一个效能笔记以及相关的扩展知识总结。

关于socket的源码解析以及jvm的源码解析，甚至计划中的RN的源码解析(内含修改RN通信机制，做到定制化和自定义)和Flutter引擎解析 相关的分享文章。会放缓节奏，1-2周更新一次。


辉哥第一部分的分享是Gradle解析和AMS插桩以及JVM源码加载字节码。第一课是jvm相关的知识，刚好我2020年一整年都零零散散的通读了android art虚拟机的源码。虽然还有不少的不明白地方，但是大致的流程还是明白的，听了辉哥的课程之后，发现辉哥的学习比我仔细多了，在这里就和大家分享一二。 关于更加详细的art虚拟机源码思想和设计，可以期待后续的jvm源码解析篇章。

如果遇到什么问题来到本文：https://www.jianshu.com/p/d00db1a7d6b1 互相讨论


# 正文

## class 文件格式初识

既然聊到jvm，就不得不聊到class字节码。要认识虚拟机的工作原理，首先要对class的字节码有一个初步的认识。

java是以class为单位进行编译到dex/odex中。而jvm需要正确运行应用程序，经过jvm初始化后，必须经过如下dex文件中的class项到内存中。

在聊class的皆在流程之前，我们需要对class文件有一定的了解。



整个class的文件结构如下：

![art-class文件结构.png](/images/art-class文件结构.png)


下面是一个具体的例子。让我一点点分析看看。


```java
public class Test implements ITest {
    protected String name;

    public static void main(String[] args){

    }

    private void testPrivate(){
        name = "aaaa";
    }

    @Override
    public void test() {

    }
}
```

通过javap 命令解析上面java代码对应的class文件如下：

```java
  Last modified 2021-1-14; size 629 bytes
  MD5 checksum 53794a254ed0673600201eac830d13c3
  Compiled from "Test.java"
public class com.pdm.spectrogram.Test implements com.pdm.spectrogram.ITest
  minor version: 0
  major version: 51
  flags: ACC_PUBLIC, ACC_SUPER
Constant pool:
   #1 = Methodref          #5.#24         // java/lang/Object."<init>":()V
   #2 = String             #25            // aaaa
   #3 = Fieldref           #4.#26         // com/pdm/spectrogram/Test.name:Ljava/lang/String;
   #4 = Class              #27            // com/pdm/spectrogram/Test
   #5 = Class              #28            // java/lang/Object
   #6 = Class              #29            // com/pdm/spectrogram/ITest
   #7 = Utf8               name
   #8 = Utf8               Ljava/lang/String;
   #9 = Utf8               <init>
  #10 = Utf8               ()V
  #11 = Utf8               Code
  #12 = Utf8               LineNumberTable
  #13 = Utf8               LocalVariableTable
  #14 = Utf8               this
  #15 = Utf8               Lcom/pdm/spectrogram/Test;
  #16 = Utf8               main
  #17 = Utf8               ([Ljava/lang/String;)V
  #18 = Utf8               args
  #19 = Utf8               [Ljava/lang/String;
  #20 = Utf8               testPrivate
  #21 = Utf8               test
  #22 = Utf8               SourceFile
  #23 = Utf8               Test.java
  #24 = NameAndType        #9:#10         // "<init>":()V
  #25 = Utf8               aaaa
  #26 = NameAndType        #7:#8          // name:Ljava/lang/String;
  #27 = Utf8               com/pdm/spectrogram/Test
  #28 = Utf8               java/lang/Object
  #29 = Utf8               com/pdm/spectrogram/ITest
{
  protected java.lang.String name;
    descriptor: Ljava/lang/String;
    flags: ACC_PROTECTED

  public com.pdm.spectrogram.Test();
    descriptor: ()V
    flags: ACC_PUBLIC
    Code:
      stack=1, locals=1, args_size=1
         0: aload_0
         1: invokespecial #1                  // Method java/lang/Object."<init>":()V
         4: return
      LineNumberTable:
        line 12: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       5     0  this   Lcom/pdm/spectrogram/Test;

  public static void main(java.lang.String[]);
    descriptor: ([Ljava/lang/String;)V
    flags: ACC_PUBLIC, ACC_STATIC
    Code:
      stack=0, locals=1, args_size=1
         0: return
      LineNumberTable:
        line 17: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       1     0  args   [Ljava/lang/String;

  public void test();
    descriptor: ()V
    flags: ACC_PUBLIC
    Code:
      stack=0, locals=1, args_size=1
         0: return
      LineNumberTable:
        line 26: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       1     0  this   Lcom/pdm/spectrogram/Test;
}
SourceFile: "Test.java"
```


class文件所对应的二进制文件如下：
```
  Offset: 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 	
00000000: CA FE BA BE 00 00 00 33 00 1E 0A 00 05 00 18 08    J~:>...3........
00000010: 00 19 09 00 04 00 1A 07 00 1B 07 00 1C 07 00 1D    ................
00000020: 01 00 04 6E 61 6D 65 01 00 12 4C 6A 61 76 61 2F    ...name...Ljava/
00000030: 6C 61 6E 67 2F 53 74 72 69 6E 67 3B 01 00 06 3C    lang/String;...<
00000040: 69 6E 69 74 3E 01 00 03 28 29 56 01 00 04 43 6F    init>...()V...Co
00000050: 64 65 01 00 0F 4C 69 6E 65 4E 75 6D 62 65 72 54    de...LineNumberT
00000060: 61 62 6C 65 01 00 12 4C 6F 63 61 6C 56 61 72 69    able...LocalVari
00000070: 61 62 6C 65 54 61 62 6C 65 01 00 04 74 68 69 73    ableTable...this
00000080: 01 00 1A 4C 63 6F 6D 2F 70 64 6D 2F 73 70 65 63    ...Lcom/pdm/spec
00000090: 74 72 6F 67 72 61 6D 2F 54 65 73 74 3B 01 00 04    trogram/Test;...
000000a0: 6D 61 69 6E 01 00 16 28 5B 4C 6A 61 76 61 2F 6C    main...([Ljava/l
000000b0: 61 6E 67 2F 53 74 72 69 6E 67 3B 29 56 01 00 04    ang/String;)V...
000000c0: 61 72 67 73 01 00 13 5B 4C 6A 61 76 61 2F 6C 61    args...[Ljava/la
000000d0: 6E 67 2F 53 74 72 69 6E 67 3B 01 00 0B 74 65 73    ng/String;...tes
000000e0: 74 50 72 69 76 61 74 65 01 00 04 74 65 73 74 01    tPrivate...test.
000000f0: 00 0A 53 6F 75 72 63 65 46 69 6C 65 01 00 09 54    ..SourceFile...T
00000100: 65 73 74 2E 6A 61 76 61 0C 00 09 00 0A 01 00 04    est.java........
00000110: 61 61 61 61 0C 00 07 00 08 01 00 18 63 6F 6D 2F    aaaa........com/
00000120: 70 64 6D 2F 73 70 65 63 74 72 6F 67 72 61 6D 2F    pdm/spectrogram/
00000130: 54 65 73 74 01 00 10 6A 61 76 61 2F 6C 61 6E 67    Test...java/lang
00000140: 2F 4F 62 6A 65 63 74 01 00 19 63 6F 6D 2F 70 64    /Object...com/pd
00000150: 6D 2F 73 70 65 63 74 72 6F 67 72 61 6D 2F 49 54    m/spectrogram/IT
00000160: 65 73 74 00 21 00 04 00 05 00 01 00 06 00 01 00    est.!...........
00000170: 04 00 07 00 08 00 00 00 04 00 01 00 09 00 0A 00    ................
00000180: 01 00 0B 00 00 00 2F 00 01 00 01 00 00 00 05 2A    ....../........*
00000190: B7 00 01 B1 00 00 00 02 00 0C 00 00 00 06 00 01    7..1............
000001a0: 00 00 00 0C 00 0D 00 00 00 0C 00 01 00 00 00 05    ................
000001b0: 00 0E 00 0F 00 00 00 09 00 10 00 11 00 01 00 0B    ................
000001c0: 00 00 00 2B 00 00 00 01 00 00 00 01 B1 00 00 00    ...+........1...
000001d0: 02 00 0C 00 00 00 06 00 01 00 00 00 11 00 0D 00    ................
000001e0: 00 00 0C 00 01 00 00 00 01 00 12 00 13 00 00 00    ................
000001f0: 02 00 14 00 0A 00 01 00 0B 00 00 00 35 00 02 00    ............5...
00000200: 01 00 00 00 07 2A 12 02 B5 00 03 B1 00 00 00 02    .....*..5..1....
00000210: 00 0C 00 00 00 0A 00 02 00 00 00 14 00 06 00 15    ................
00000220: 00 0D 00 00 00 0C 00 01 00 00 00 07 00 0E 00 0F    ................
00000230: 00 00 00 01 00 15 00 0A 00 01 00 0B 00 00 00 2B    ...............+
00000240: 00 00 00 01 00 00 00 01 B1 00 00 00 02 00 0C 00    ........1.......
00000250: 00 00 06 00 01 00 00 00 1A 00 0D 00 00 00 0C 00    ................
00000260: 01 00 00 00 01 00 0E 00 0F 00 00 00 01 00 16 00    ................
00000270: 00 00 02 00 17                                     .....
```

接下来，我们对应二进制文件来探索，class文件的格式。

- 1.二进制文件开头`CA FE BA BE` 这2个16进制是指class文件格式的标示符号。

- 2.接下来的`00 00 00 33` 是指版本号。其中`0000` 代表次版本号，`00 33`代表主版本号这里是指51。51是指jdk 1.7，00也就是次级版本号为0.所以是jdk 1.7.0

- 3.接下来就是常量池部分，首先`00 1E` 是指常量池中与多少个常量。1e就是30，在这里的class文件解析出来的常量池数量一共是29.为什么要加1，其实这是计算机习惯，也是规范。jvm会为0号位置的常量池做保留。


### 常量池解析

接下来看看常量池内容解析，要解析二进制中所代表的常量池,需要如下表格进行辅助：
![java常量池解析表.png](/images/java常量池解析表.png)

我们结合这个表格来解析上面我随手写的示例代码：

#### Methodref 的解析
第一行是`Methodref ` 也就是指java的方法，所对应的标示位是`0a`也就是10.从表中可以得知，这一行所对应的二进制代码也就是`0A 00 05 00 18`。

也就是上述class文件通过javap解析出来的`#1 = Methodref          #5.#24 `. 后面这个5和24是指后续的在常量池中位于第5位置和第24位置。

看看第5和第24个位置：

```
#5 = Class              #28            // java/lang/Object
```

能看到第5行指向了第28行,也就是utf8 的字符串指向了Object 这个资源：

```
 #28 = Utf8               java/lang/Object
```


第24行能看到这是一个特殊的类型`NameAndType` 这里指向了第9行(<init>)字符串，以及第10行`()V`字符串
```
 #24 = NameAndType        #9:#10         // "<init>":()V
```

记录`Test`的类继承了`Object`对象，并且拥有一个无参构造函数

#### String 的解析

第二行是
```
#2 = String             #25            // aaaa
```
这里是指String类型对应表中就是`08`，对应就是二进制表接下来的内容`08 00 19`。最后`19`从16进制转化过来就是`25`.说明指向了25行的常量数据:
```
#25 = Utf8               aaaa
```
也就是utf8 的aaa。

说明在这个class中，存在一个常量字符串`aaaa`


#### Fieldref 解析

常量池第三行是`Fieldref` 类型也就是class中的成员属性类型。对应在二进制的内容为`09 00 04 00 1A`。 `09`对应说明表中为 `Fieldref` 也就是成员变量的引用。

```
 #3 = Fieldref           #4.#26         // com/pdm/spectrogram/Test.name:Ljava/lang/String;
```

能看到这个属性类型，指向了`第4行`+`.`+`26行`；

```
#4 = Class              #27            // com/pdm/spectrogram/Test
```
```
#27 = Utf8               com/pdm/spectrogram/Test
```

第4行就是指这个类的包路径

```
#26 = NameAndType        #7:#8          // name:Ljava/lang/String;
```

```
   #7 = Utf8               name
   #8 = Utf8               Ljava/lang/String;
```

第26行则是一个用`NameAndType` 记录这是一个class中的成员类型

能看到最终指向了2个utf8的字符串，并合并成注释中的一样`com/pdm/spectrogram/Test.name:Ljava/lang/String;`

此时记录的是，在这个class类中，存在一个string类型的成员变量，其名字为name。

#### Class 的解析

```
#4 = Class              #27            // com/pdm/spectrogram/Test
```

这部分对应的是接下来二进制文件中的`07 00 1B`。 `07`代表了class的内容。

第27行则是指下面这个utf8的字符串数据
```
#27 = Utf8               com/pdm/spectrogram/Test
```

这里则记录了，这个class文件中存在一个`com/pdm/spectrogram/Test`的class。其实就是指当前这个测试类。

#### Utf8 解析

```
#7 = Utf8               name
```

这一行根据表中的内容可以的得知，utf8 对应的标示为`01`,而此时这个utf8所记录的才是真正对应的字符串内容：`01 00 04 6E 61 6D 65` 这里面记录的就是`name` 这个字符串


#### NameAndType 解析

我们来看看第24行：
```
#24 = NameAndType        #9:#10         // "<init>":()V
```
对应的二进制为`0C 00 09 00 0A`.`0C`会先作为标示位被认为是`NameAndType`类型。也就是带着类型的名字。而这里记录的就是一个无参数的构造函数的字符串拼接。


#### 总结

实际上class 文件中的常量池，是以`01` ~ `0C`的区间为标示位，来识别class文件中所有的数据。这些数据可能是引用，可能是真实的字符串。注意只有01(utf8类型)类型才是真正承载的字符串的内容, 其他都是被识别为引用，进行嵌套解析。



那么问题来了`01`~`0C` 区间会不会影响jvm 记录一些特殊字符串，导致class文件记录缺失呢？

实际上并不会，如果去查ascii表，就能巧妙的发现，这个区间的acsii对应的数据，是一些键盘操作，而不会记录在文本中。

而在class文件中，存储占比最大的部分就是常量池。因为他包含了class中所有的字符串字典。这么做也有一个很大的好处，把所有的字符串替换成引用保存在池子中，就能极大的减少一个class文件加载到内存后的大小。这种设计十分常见，在Android资源加载的专题中，也能看到实际上Android系统的AssetManager也是复用这一套体系。

有兴趣可以阅读我之前写的文章：https://www.jianshu.com/p/817a787910f2


#### 解析Class的访问标示位

由于已经知道了整个字符池的总长度，那么填充完常量池总长度后。接下来解析Class的访问标示位，访问标志位对应的的权限如下

| 权限             | 字节   | 意义                 |
| ---------------- | ------ | -------------------- |
| ACC_PUBLIC       | 0x0001 | public 权限          |
| ACC_PRIVATE      | 0x0002 | private权限          |
| ACC_PROTECTED    | 0x0004 | protected 权限       |
| ACC_STATIC       | 0x0008 | static 类型          |
| ACC_FINAL        | 0x0010 | final 权限           |
| ACC_SYNCHRONIZED | 0x0020 | 经过monitor 锁的区域 |
| ACC_SUPER        | 0x0020 | 继承了类或者接口     |
| ACC_VOLATILE     | 0x0040 | VOLATILE 修饰的字段  |
| ACC_NATIVE       | 0x0100 | java的native方法     |
| ACC_INTERFACE    | 0x0200 | 接口标志位           |
| ACC_ABSTRACT     | 0x0400 | 抽象类               |




`00 21 00 04 00 05 ` 仔细来看看这一段。

首先`00 21` 是指ACC_PUBLIC 的public的访问权限以及`super`的模式用于记录当调用了`invokspecial ` 指令时候对父类进行处理（也就是实现了继承）

接下来的`00 04`是指访问权限为`ACC_PUBLIC + ACC_SUPER`，且指向了常量池中4号引用也就是`Test`类。

往后读4个为`00 05`.转化过来就是指一个指向了`05`的索引。其实就是指Object类。这就是为什么java中所有的类都是继承于Object对象。因为在编译的时候，会把继承的类写入到class文件中。且可以知道Object对象实际上是`public final` 的权限。


#### 接口引用解析

在往后读4个：`00 01 00 06` 。 首先`01`是指当前只有1个接口对象，这个接口对象指向了常量池中的6号引用，也就是`ITest`的接口。



#### 属性引用

![art_fields.png](/images/art_fields.png)

对于class文件中，需要完整描述一个属性字段，需要如上几个内容才能描述完整。

分别是：权限，字段名索引，字段描述符的索引，属性表(字段的赋值内容)。

对应到javap的解析就是如下这一段：
```
  protected java.lang.String name;
    descriptor: Ljava/lang/String;
    flags: ACC_PROTECTED
```

在本文的案例，就是接着接口解析后这一段二进制`00 01 00 04 00 07 00 08 00 00`。

首先`00 01` 记录当前的有多少个字段。此时只有1个。`04`代表权限为`protected`， `00 07`代表引用索引为`7`指向的utf8的`name`字符串。`08`代表该属性的描述符号`Ljava/lang/String`。后面的`00 00 `说明所有的属性数量和属性信息都为0.


#### 方法引用

解析完属性之后，就会解析方法数量和方法表，在本文中，通过javap解析得到如下结果：

```
  public com.pdm.spectrogram.Test();
    descriptor: ()V
    flags: ACC_PUBLIC
    Code:
      stack=1, locals=1, args_size=1
         0: aload_0
         1: invokespecial #1                  // Method java/lang/Object."<init>":()V
         4: return
      LineNumberTable:
        line 12: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       5     0  this   Lcom/pdm/spectrogram/Test;

  public static void main(java.lang.String[]);
    descriptor: ([Ljava/lang/String;)V
    flags: ACC_PUBLIC, ACC_STATIC
    Code:
      stack=0, locals=1, args_size=1
         0: return
      LineNumberTable:
        line 17: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       1     0  args   [Ljava/lang/String;

  public void test();
    descriptor: ()V
    flags: ACC_PUBLIC
    Code:
      stack=0, locals=1, args_size=1
         0: return
      LineNumberTable:
        line 26: 0
      LocalVariableTable:
        Start  Length  Slot  Name   Signature
            0       1     0  this   Lcom/pdm/spectrogram/Test;
```

想要正确的描述一个方法，需要下面这些数据

![art_methods.png](/images/art_methods.png)


3个方法加上一个默认的构造函数一共4个方法。 我们用默认的构造函数为例子对应的二进制如下：
`00 04 00 01 00 09 00 0A 00 01 00 0B 00 00 00 2F`

我们拆解出来：`00 04`  是指一共有4个方法在这个class中。

`00 01` 代表`java/lang/Object."<init>":()V` 这是代表了父类的默认构造函数

`00 09` 代表`<init>`；`00 0A` 代表`()V` 到这里就完成了对当前class的默认构造函数的描述。

`00 01` 代表当前的方法有1个属性表

`00 0B` 代表常量池引用指向`Code`


接下来就是代码的内容了。


#### Code的解析

想要正确的解析Code，就需要理解这个表：
![code属性表.png](/images/code属性表.png)


`00 00 00 2F` 代表这个方法占用内存大小为`2F`,也就是`47`字节。前面的`00`说明默认的构造函数名指向占位的地方。


接下来就是这个方法的Code内容：


`00 01 00 01 00 00` 首先这里可以看成三个部分：`  stack=1, locals=1, args_size=0`

分别代表 方法栈为1，局部属性为1，方法参数为0

接下来就是`00 05 2A B7 00 01 B1`：

`00 05` 是指这个方法中包含了多少java指令。因此就能找到实际上整个方法的代码就是指`2A B7 00 01 B1`这一段二进制内容。


依次了解一下这些指令代表什么：

- `2A` `aload_0` 是将第一个引用变量推出
- `B7` `invokespecial ` 代表调用父类构造函数
- `00` 不做任何事情
- `01`  将null推到栈顶
- `B1` 调用return方法，结束当前的方法


### 类的加载流程

![art-类的加载过程.png](/images/art-类的加载过程.png)




当然我们一般都是都只是笼统的把上图中的蓝色区域步骤归纳出来：

- 1.setup 和 Load  一般都是把这两个一起说成加载 装载ClassLoader
- 2.link 则是链接，内含校验，准备，解析class方法 
- 3.初始化 初始化静态成员，静态代码，以及静态构造函数(clint)

也就是常说的：加载，校验，准备，解析，初始化。


而下面这张图，则完整的表示了jvm在运行期间，这5个步骤都做了什么？

![art-虚拟机的启动后半段.png](/images/art-虚拟机的启动后半段.png)


我们配合上面2张图来仔细聊聊jvm在这几个步骤中都做了什么？

当jvm 初始化好启动好jvm后，并加载第一个线程完。就会执行ClassLinker的DefineClass 方法开始加载class。

##### 加载class 文件

- 1.首先会加载静态成员变量
- 2.加载非静态成员变量
- 3.加载direct方法
- 4.加载代码段

在这里需要提及一个概念，在art虚拟机中会把方法 区分为三种：
- 1.direct 方法，也称为直接方法。这种方法是指private访问权限，static修饰方法，以及构造函数。

- 2.virtual 方法，也称为虚方法。这种方法是指除了private，static以及构造函数之外的方法。不包含父类继承的方法。

- 3.miranda 方法，也称为米兰达方法。这种方法是指那些继承了抽象类或者接口而没有实现的方法。最早的java虚拟机因为编写问题，导致无法找到这类型方法。为了修复这种特殊类型的方法，会在Link链接阶段，把这种方法保存到虚函数表中。


额外需要补充一点，java虚拟机常用的5种调用方法指令：
- invokestatic：用于调用静态方法。
- invokespecial：用于调用私有实例方法、构造器，以及使用 super 关键字调用父类的实例方法或构造器，和所实现接口的默认方法。
- invokevirtual：用于调用非私有实例方法。
- invokeinterface：用于调用接口方法。
- invokedynamic：用于调用动态方法。


通过这些了解后，就能明白实际上加载，也并非把一口气的方法都加载到内存中，而是分批进行加载。而这个阶段的完成，会为这个class打上一个`kStatusLoaded`标志位，避免重复加载同一个class文件。


而加载代码段和加载方法看起来有冲突。实际上不是如此，从我javap中可以得知java方法是指一个方法引用，而代码段是指代码引用(内含相关的虚拟机指令)。

对应在class编译过程中是两个不同的结构体进行存储，一个是`method_item`，一个`code_item`。

这个过程，会把java方法存放到方法引用表中,而每一个方法的又指向了每一个方法的代码段结构体，这个UML图就是如下设计：

![art-ArtMethod.png](/images/art-ArtMethod.png)

从数据结构上来看，加载到内存的class结构体，会有一个methods的数组指针，指向一块内存。这一块内存按照顺序，依次中保存了`direct`，`virtual`,`miranda`.

而这个数组并非直接指向了`ArtMethod`结构体，而是先指向了`PtrSizeField`结构体后，再通过该结构体的`entry_point_from_quick_compiled_code_`指向真正的`ArtMethod`结构体。这么做的好处什么呢？

这么做其实就是为了区分，是aot(机器码执行)还是jit(解释执行)的区别。如果是jit 则是走jit的指令翻译流程，如果是机器码则走机器码的指令执行流程。

关于更多的内容，可以关注我未来写的java虚拟机 方法是如何执行的源码分析篇章。


##### 校验 class文件


- 文件格式的校验：校验class文件的格式和对应的java版本是否符合规范
- 元数据校验：对类的元数据信息进行校验，保证不会出现不符合java规范的元数据
- 字节码校验：对类的方法体进行校验，保证不会出现危害java虚拟机的行为出现
- 符号引用校验：这个阶段发生在链接的第三个阶段解析 后打上的.主要是保证解析过程可以正确的执行。比如说，能否通过类导入的`import` 全类名路径找到对应类，访问其他类的方法和字段是否存在，且是否有对应的访问权限。

那么对应到第二副图中，也就是指`VerifyClass`方法。这个方法会调用`MethodVerifier.VerifyMethods`校验每一个方法.


当解析和初始化完毕之后，就会给class打上`kStatusVerify`标志位。确定已经校验完毕的避免再让class重新走一遍校验的流程。

注意class的校验分为两个步骤：

- 1.一个是`dex2oat`安装时候预编译校验上述的软错误。而这个步骤已经校验了90%的class中的校验问题。如果成功也会给这个class打上一个`kStatusVerified`

- 2.另一个是加载class 发现是一个需要泛型才能处理的class文件。此时才会等到app运行后，第一次加载class获取到上下文后，在进行一次校验。



而上图中的`VerifyClass` 放在初始化后面，这是java虚拟机做的最后一道保险措施。在初始化后，会看看有没有这个`kStatusVerified`标志位，没有再一次校验。



##### class的准备


- 会为静态属性字段申请内存，不包含非静态字段。非静态字段只会在是在实例化对象后才进行分配

- 初始化class的静态变量(也称为类变量)时候，没有任何赋值，则为其设置默认的值。

- 对于常量，会在编译阶段保存在字段表的ConstantValue中。当准备阶段结束之后就把让对应的常量指定为对应常量池中的数据。

对应在流程图的过程，就是对应LinkSuperclass，LinkMethods，LinkStaticFields，LinkInstanceFields 计算需要多少空间。

既然聊到了class在这个阶段中为静态变量分配内存，class的准备阶段和实例化阶段申请的内存有何不同呢？可以看看如下一图：

![art-Class内存分布.png](/images/art-Class内存分布.png)

能看到静态变量是跟着加载到内存class文件对应的对象。而实例化对象中的非静态变量则是跟着通过class实例化对象走的。

因此两者不是同一个东西，要区分。一个对象在jvm/art虚拟机中，实际上会存在一个加载到内存的class对象，会存在多个通过class对象实例化出来的对象。

当计算两者内存大小时候，静态属性，静态方法都要算入class对象中。而实例化对象需要算上父类对应的实例化的大小



##### class的解析

- class的解析并没有严格规定时间。只规定了在执行`newarray`,`new`,`putstatic`,`getfield`,`getstatic`等16个指令之前，需要对他们的所引用的符号进行解析。所以可以在类被虚拟机加载后解析，也能在调用这几个指令之前被解析

- 对于同一个符号可以进行多次解析。而且多次解析。除了invokedynamic以外，虚拟机可以对解析的结果进行缓存。

- 解析行为主要是面对类或者接口，字段，类方法，接口方法，方法类型，方法句柄和调用的点限定符，7种类型。

对应在流程图的过程，就是对应就是在校验完class和方法之后。如果没有打上解析的标志位`kStatusResolved`，就会调用`ClassLinker`的`Resolve`方法开始解析class中所有的方法，字段。





#### class 的初始化

- 初始化静态构造函数(类构造函数)<clinit>。这个过程会按照java文件中 编写的顺讯一次执行静态代码块，初始化静态变量。

- 在子类<clinit>静态构造函数执行之前，会默认的执行父类的静态构造函数

- 因为父类的静态构造函数优先执行，因此父类比起子类会优先执行静态代码段

- 如果一个类，不存在静态变量，不存在静态方法。那么就不会存在静态构造函数。

- 接口不能存在静态代码块，但是会存在静态变量。但是接口的静态构造函数的调用不会调用父类的静态构造函数，除非使用了父类的静态变量。同时接口的实现类也不会调用接口的静态构造函数

- class的初始化只会执行一次，因为会在内存中为这个class文件打上一个`kStatusInitialized`标志位。并且只会保证一个线程执行一次该类的静态构造函数。



#### class 的加载时机

实际上class的加载触发，实际上都是因为调用的虚拟机下一个ClassLinker的类，并调用的DefineClass方法。

常见场景有：

- 1.调用`new`指令
- 2.调用`getstatic`,`putstatic`,`invokestatic` 调用静态方法或者操作静态属性
- 3.反射调用类，会通过ClassLinker查找后，找到并没有缓存则装载
- 4.实例化一个子类，发现父类并没有加载
- 5.当使用 JDK 1.7 的动态语言支持时，如果一个 java.lang.invoke.MethodHandle 实例最后的解析结果 REF_getStatic、REF_putStatic、REF_invodeStatic 的方法句柄，并且这个方法句柄所对应的类没有进行过初始化，则需要先触发其初始化。



### jvm的双亲委派模型

```java
    protected Class<?> loadClass(String var1, boolean var2) throws ClassNotFoundException {
        synchronized(this.getClassLoadingLock(var1)) {
            Class var4 = this.findLoadedClass(var1);
            if (var4 == null) {
                long var5 = System.nanoTime();

                try {
                    if (this.parent != null) {
                        var4 = this.parent.loadClass(var1, false);
                    } else {
                        var4 = this.findBootstrapClassOrNull(var1);
                    }
                } catch (ClassNotFoundException var10) {
                }

                if (var4 == null) {
                    long var7 = System.nanoTime();
                    var4 = this.findClass(var1);
                    PerfCounter.getParentDelegationTime().addTime(var7 - var5);
                    PerfCounter.getFindClassTime().addElapsedTimeFrom(var7);
                    PerfCounter.getFindClasses().increment();
                }
            }

            if (var2) {
                this.resolveClass(var4);
            }

            return var4;
        }
    }
```

何为双亲委派机制。听起来的很玄乎，从上述代码看一看就知道，实际上是当前的classLoader在加载class的时候，并不会先从当前的ClassLoader中查找，而是先从更加上层的classLoader中查找。

关于这一点，我在[横向浅析Small,RePlugin两个插件化框架](https://www.jianshu.com/p/d824056f510b)一文中和大家简单的聊过。

也在[Android 重学系列 ActivityThread的初始化](https://www.jianshu.com/p/2b1d43ffeba6) 一文中简单的聊过在Application初始化时候会调用`LoadedApk.makeApplication ` 装载应用对应`PathClassLoader `。

在这里有一个总结图：

![art-ClassLoader.png](/images/art-ClassLoader.png)



## 致谢


最后感谢红橙Darren 的文章以及授课，以及本文文章的相关出处：

- https://www.jianshu.com/p/0248780eae06
- https://www.jianshu.com/p/252f381a6bc4

