---
title: Skia的初探(Skia的GN脚本编译与第一个Skia应用)
top: false
cover: false
date: 2019-09-26 08:31:24
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- 音视频
---
# 前言
如今大前端代表之一flutter十分火热，也是一种大的趋势。flutter与rn对大前端上的理解不同，rn是自上而下的大前端解决方案，而flutter是自下而上的大前端解决方案。为什么我说flutter是自下而上的解决方案呢？实际上这种解决思路也来源与移动端手机游戏开发，flutter绕开对每一个系统顶层ui api，直接对接系统底层的cpu，gpu。

Google是怎么做到的？实际上，如果翻开Android底层源码，我们会在external目录发现一个名为Skia的第三方库。Skia实际上是Google出品的Android绘制2D图形的核心库，在刚诞生之初就以在低性能的移动端中表现处高性能的水平受人侧目，但是大前端的技术十分众多繁杂，就像金子被沙子掩盖一般，不受大众的关注。

关于Skia如何在Android运作之后我会在Android重学系列中，和大家好好聊聊。

回到原来的话题，我们翻开官网，发现Skia原本支持chrome浏览器，Android，iOS，Mac，Web，Windows等平台上渲染图像。换句话说，经过这些年的发展，名声不显的Skia本身就具备了跨平台的能力。skia作为核心渲染库就是极好的选择。实际上我们能够看到这段时间Google的新技术，如flutter，新平台Fuchsia都是以它为核心渲染库。

学习东西就要学习本质，才能更好的掌握。因此，我们需要对Skia有一定的理解，本文将作为Skia的系列第一篇，从Skia如何编译开始。

# 正文

## 编译的准备
我们可以执行git如下的命令，把Skia源码从官方下载下来：
> git clone https://skia.googlesource.com/skia.git

当然，我们可以从github上搜索skia，下载下来。我就是这样做的。

第二步十分重要，我就踩了坑，编译老是缺少了文件,请安装了python之后，执行如下命令：
> cd skia
python2 tools/git-sync-deps

把skia编译，运行需要的第三方库全部下载下来。

## GN与ninja 脚本
我经过前段时间的学习，对编译有一点心得。当我信心满满的打开了Skia的目录的时候，发现我熟悉的CONFIGURE的文件呢？熟悉的CMake，Makefile呢？都不见了。取而代之的是BUILD.gn脚本。

GN脚本相关的资料不多，但是官方的资料还是挺详细的。GN脚本是什么？官方是怎么说的，如果CMake和Makefile是高级语言，那么GN和ninja则是相当于汇编语言的存在，存粹是为了编译速度而诞生的。我们翻开Android的源码，发现Android的编译工具经过了几次变迁，从mk到cmakelists，现在Android9.0使用的bp+GN脚本。关于bp文件，不是本文重点就不多赘述。

我在之前的CMake总结一文有讲解过，CMake是基于Makefile之上的很强大的编译工具。那么GN实际上是基于ninja之上的编译工具。

## ninja的简单介绍
ninja和Makefile很相似，我们类比学习一下。Makefile需要创建一个make文件，ninja则需要创建一个build.ninja文件。

和学习Makefile，这里我同样总结了，ninja需要清楚2个变量，1个规则，1个命令，就能完成build.ninja的编写。ninja没有自动变量，因为ninja是十分追求效率的编译工具，省略了自动变量的替换和检索。

### 一个规则
```shell
rule cc
 command = gcc -g -c ${in} -o ${out}
```
rule规则制定的是，一个规则cc这个命令实际上执行的是command赋值的命令。


### 一个命令
```shell
build hello.o: cc hello.c
```
命令build 实际上告诉ninja我们要编译的结果是hello.o，通过上面定义的cc规则，以hello.c作为输入参数。

从上文可以知道就是是一个gcc的编译命令。

### 2个变量
```shell
${out} ${in} 
```
分别指代的是build命令中输出对象，以及输入对象。

完整的一个简单build.ninja如下：
```shell
rule cc
 command = gcc -g -c ${in} -o ${out}
rule link
 command = gcc ${in} -o ${out}

build hello.o: cc hello.c
build hello : link hello.o
```

当我们编译好build.ninja之后，别忘了，调用ninja命令一下，就能自己找到当前目录下的脚本文件，进行编译。

## GN简单介绍
GN则稍微复杂点，提供了相当多的语法，以及复杂的流程，这里以GN脚本的开发流程为线索，铺开来聊聊。

GN脚本的简单开发流程：
- 1.编写.gn文件定义GN的配置文件位置，一般名字是BUILDCONFIGURE.gn.
- 2.编写BUILDCONFIGURE.gn,并且定义GN的需要使用的toolchain文件位置，因为GN不提供默认的编译方法，需要我们去实现对应的gcc等命令。
- 3.在toolchain文件的位置，编写一个BUILD.gn文件，实现其中各种编译工具的命令。
- 4.接着在.gn所在的文件目录中，编写BUILD.gn文件，这个文件才是我们真正的编译文件。
- 5.回到.gn的目录，执行如下命令完成编译:
> gn gen out/default //执行gn脚本，并且确定输出目录
ninja -C out/default //调用ninja执行由GN生成的ninja脚本完成编译。

大致分为4个步骤，让我按照流程一一讲解。

### 步骤一
定义一个名字为.gn文件：
```shell
buildconfig = "//BUILDCONFIG.gn"
```
//代表当前目录。因此这里定义的是当前目录下的BUILDCONFIG.gn文件。

### 步骤二
创建一个BUILDCONFIG.gn文件：
```shell
declare_args(){
} 

 set_default_toolchain("//toolchain:gcc")
 cflags_cc = [ "-std=c++11" ]
```
在这个文件中，必须定义set_default_toolchain方法，设置默认的编译工具的BUILD.gn配置信息位置。

declare_args，这个是一个方法，一般是GN脚本要编译动态库时候，需要的默认参数时候会调用declare_args这个方法，获取默认参数。

### 步骤三
上一个步骤定义的位置为（"//toolchain:gcc")，说明这个编译工具的配置未见在当前目录下的toolchain文件下面。
因此，我们需要创建一个toolchain文件夹，并且在toolchain文件下创建一个BUILD.gn文件。定义toolchain文件，实际上和ninja的rule类似，定义不同编译模式下的工具。这里我就获取chrome的toolchain，由于我是在mac上编译的，需要对这个文件做一点修改和调整。

```shell
toolchain("gcc") {
  tool("cc") {
    depfile = "{{output}}.d"
    command = "gcc -MMD -MF $depfile {{defines}} {{include_dirs}} {{cflags}} {{cflags_c}} -c {{source}} -o {{output}}"
    depsformat = "gcc"
    description = "CC {{output}}"
    outputs = [
      "{{source_out_dir}}/{{target_output_name}}.{{source_name_part}}.o",
    ]
  }
  tool("cxx") {
    depfile = "{{output}}.d"
    command = "g++ -MMD -MF $depfile {{defines}} {{include_dirs}} {{cflags}} {{cflags_cc}} -c {{source}} -o {{output}}"
    depsformat = "gcc"
    description = "CXX {{output}}"
    outputs = [
      "{{source_out_dir}}/{{target_output_name}}.{{source_name_part}}.o",
    ]
  }
  tool("alink") {
    rspfile = "{{output}}.rsp"
    command = "rm -f {{output}} && ar rcs {{output}} @$rspfile"
    description = "AR {{target_output_name}}{{output_extension}}"
    rspfile_content = "{{inputs}}"
    outputs = [
      "{{target_out_dir}}/{{target_output_name}}{{output_extension}}",
    ]
    default_output_extension = ".a"
    output_prefix = "lib"
  }
  tool("solink") {
    soname = "{{target_output_name}}{{output_extension}}"  # e.g. "libfoo.so".
    rspfile = soname + ".rsp"
    command = "g++ -shared {{ldflags}} -o $soname @$rspfile"
    rspfile_content = "-Wl,-all_load {{inputs}} {{solibs}} -Wl,-noall_load {{libs}}"
    description = "SOLINK $soname"
    # Use this for {{output_extension}} expansions unless a target manually
    # overrides it (in which case {{output_extension}} will be what the target
    # specifies).
    default_output_extension = ".so"
    outputs = [
      soname,
    ]
    link_output = soname
    depend_output = soname
    output_prefix = "lib"
  }
  tool("link") {
    outfile = "{{target_output_name}}{{output_extension}}"
    rspfile = "$outfile.rsp"
    command = "g++ {{ldflags}} -o $outfile @$rspfile {{solibs}} {{libs}}"
    description = "LINK $outfile"
    rspfile_content = "{{inputs}}"
    outputs = [
      outfile,
    ]
  }
  tool("stamp") {
    command = "touch {{output}}"
    description = "STAMP {{output}}"
  }
  tool("copy") {
    command = "cp -af {{source}} {{output}}"
    description = "COPY {{source}} {{output}}"
  }
}
```
能看到在这个BUILD.gn,中我们定义了一个toolchain这个好像方法的东西，toolchain中声明了一个"gcc"的名字。这种在GN脚本中称为模版，这是GN内置的模版。其作用相当于方法一般，能够被调用。toolchain这个模版本身带有着逻辑，当执行完这个作用域内的的所有行为之后，竟会执行模版内部的逻辑。

在toolchain中有许多tool("link")，tool(“solink”)等小的模版。这些内置模版，实际上代表着各种工具，如solink，代表着动态库的链接时候需要的命令，cxx,cc代表着编译阶段时候的命令。当GN脚本执行到某个阶段，将会调用tool中对应的命令。

在这里，我们所有的命令都需要做调整。比如在solink中，我们编写链接的命令，想要设定soname的时候，mac环境不支持soname，支持install_name。因此，我们需要成对应平台的对应的命令。

### 步骤四
编写属于我们的BUILD.gn脚本。
这里需要介绍几个，我们常用的内置模版。
> static_library： 编译静态库
> shared_library: 编译动态库
> executable: 编译执行文件
> source_set: 编译一种轻量的静态库。
> component: 可能是source_set也可能是shared_library，根据构建类型确定

这里举一个简单的例子，我们编译个执行hello_gn的执行文件，链接一个say_hello的动态链接库。写法如下：
```shell
shared_library("say_hello"){
 sources=["say_hello.c",]
}

executable("hello_gn"){
 sources = ["hello.c",]
 deps=[":say_hello",]
}
```
能看到，我们使用两个内置模版，自上而下的分别执行如下操作：
- 1.编译一个名字为say_hello的动态库。sources是这个模版里面识别的属性，代表着这个动态库对应的资源文件。
- 2.编译一个名字为hello_gn的可执行文件，资源文件是hello .c，同时需要依赖say_hello模版生成的产物。换句话说，可执行文件要链接上这个动态链接库。

这样就能完成了一次GN脚本的编写。最后执行第五步的命令，就能开始编译。

### GN的模版(template)
能看到在GN脚本的编写过程中，模版占了绝大部分的比重。那么我们该怎么自定义模版呢？

自定义模版规则有四条，如下：
- 1.定义一个template的作用域，并且在设置好target_name.如下定义了一个名字为opts的模版
```shell
template("opts"){
...
}
```

- 2.调用一个模版方法如下，以上面定义好的模版为例子
```shell
opts("target_name"){
}
```
调用的同时，要在里面编写一个target_name。用以识别模版不同的使用。其实可以类比为我们常用的泛型，target_name为泛型中具体的对象。

- 3.模版能够获取调用模版时候所有的属性，其方法个js很相似，通过invoker来获取。
举个例子
```shell
opts("target_name"){
enabled = true
}
```
我们能够在定义template的时候，通过invoker.enabled访问到调用时候enabled的参数。但是请注意，注意获取方式有两种：
1. 必须调用如下方法判断了模版调用者中存在该对象，才能获取属性，不然会报错。
```shell
if (defined(invoker.enabled)) {
      values = invoker.enabled
    }
```

2. 在获取参数之前调用如下语句：
```shell
visibility = [ ":*" ]
```
这样默认是所有的参数可见。但是必须注意了，所有调用方注入的参数在对应作用域必须使用，不然会报错。


- 4.每一个模版的参数如同方法一般，只存在在自己的作用域，如果需要把参数设置到已经在全局存在的参数。需要通过如下方法，把模版内的参数跨越作用域传送出去。
```shell
forward_variables_from(invoker,"*",[sources,cflags])
```

这个方法有三个参数:
第一个参数：要传输的对象invoker中的参数;
第二个参数：要传输到全局作用域的属性是什么,"*"代表着所有属性
第三个参数：哪些属性不需要传输出去。

明白了这些基础，我们就能更好的阅读Skia的GN脚本，甚至可以按照自己的心意裁剪Skia库。

更多关于GN脚本可以看官方文档：[https://gn.googlesource.com/gn/+/master/docs/](https://gn.googlesource.com/gn/+/master/docs/)

## 理解Skia GN脚本
打开skia源码根目录下的BUILD.gn。首先能看到，import几个gn目录下的gni文件：
```
import("gn/flutter_defines.gni")
import("gn/fuchsia_defines.gni")
import("gn/shared_sources.gni")

import("gn/skia.gni")
```
实际上前两个我们可以忽略，是把flutter和fuchsia一些参数需要依赖的数据添加进来。主要是后面两个gni脚本。

shared_sources脚本主要是导入了核心以及相关的模块。skia脚本则根据编译命令，平台设置一些默认值，以及设置编译工具链toolchain。

### Skia 2个重要的模版

#### opts
```shell
template("opts") {
  visibility = [ ":*" ]
  if (invoker.enabled) {
    source_set(target_name) {
      check_includes = false
      forward_variables_from(invoker, "*")
      configs += skia_library_configs 
    } 
  } else {
    # If not enabled, a phony empty target that swallows all otherwise unused variables. 
    source_set(target_name) {
      check_includes = false
      forward_variables_from(invoker,
                             "*",
                             [
                               "sources",
                               "cflags",
                             ])
    }
  }
}
```

这里就能看到Skia自己定义了一个模版opts的模版，用来控制编译平台需要对应需要的配置：
```shell
opts("armv7") {
  enabled = current_cpu == "arm"
  sources = skia_opts.armv7_sources + skia_opts.neon_sources
  cflags = []
}
```

能看到，当我们需要交叉编译会在命令参数中设置当前平台current_cpu，目标平台target_cpu。能看到会判断当前的平台是什么，并且一些新的资源配置。

#### optional
控制Skia，各个模块是否加入到Skia中，各个模块以什么方式编译进来。就以jpeg模块为例子：
```shell
optional("jpeg") {
  enabled = skia_use_libjpeg_turbo
  public_defines = [ "SK_HAS_JPEG_LIBRARY" ]

  deps = [
    "//third_party/libjpeg-turbo:libjpeg",
  ]
  public = [
    "include/encode/SkJpegEncoder.h",
  ]
  sources = [
    "src/codec/SkJpegCodec.cpp",
    "src/codec/SkJpegDecoderMgr.cpp",
    "src/codec/SkJpegUtility.cpp",
    "src/images/SkJPEGWriteUtility.cpp",
    "src/images/SkJpegEncoder.cpp",
  ]
}
```
能看到在jpeg模块依赖于third_party的libjpeg-turbo第三方库。公有开放出来的头文件是SkJpegEncoder，skia在这个第三方库之上封装的源码就在sources的集合中。每一个模块是否加入到编译中，由enabled来决定。

Skia对于每一个模块都是通过这种模式管理的。

#### Skia主体模块
经过对每一个模块的模版都定义之后，我们能看到component内置模版。
```shell
component("skia") {
...
}
```
实际上skia的静态/动态库就是以这里为主体，把各个模块的都依赖上。
```shell
  public_deps = [
    ":gpu",
    ":pdf",
    ":skcms",
  ]

  deps = [
    ":arm64",
    ":armv7",
    ":avx",
    ":compile_processors",
    ":crc32",
    ":fontmgr_android",//android的字体
    ":fontmgr_custom",
    ":fontmgr_custom_empty",
    ":fontmgr_empty",
    ":fontmgr_fontconfig",
    ":fontmgr_fuchsia",
    ":fontmgr_wasm",
    ":fontmgr_win",
    ":fontmgr_win_gdi",
    ":gif",//gif解析
    ":heif",
    ":hsw",
    ":jpeg",//jpeg解析
    ":none",
    ":png",//png解析
    ":raw",
    ":sksl_interpreter",
    ":skvm_jit",//skia 的jit
    ":sse2",
    ":sse41",
    ":sse42",
    ":ssse3",
    ":webp",//webp
    ":wuffs",
    ":xml",//xml解析库
  ]
```
就是这里把所有的模块都依赖上。

如果要裁剪库的朋友请注意，这些不仅仅是全部，在上面的gni中还有更多的定义，每一个依赖模块实际上很可能有第二个依赖模块。就以xml来说，实际上在xml.gni能看到会依赖上zlib这个zip解压模块。我们如果通过skia_enabled_zlib为false，但是xml为true，就会出现编译找不到对应文件的异常。

因此裁剪库的时候，我们需要理清楚每一个依赖库之间的依赖关系。
当依赖全部完成之后，Skia会根据平台做进一步资源依赖，最终完成编译。


### Skia编译命令
当我们理清楚这些之后，我们要交叉编译出一个arm平台上的Android skia需要依次执行如下命令，就能编译出一个完整的skia出来。当然我是为了方便，编写了一个脚本
```shell
bin/gn gen out/Shared -args='ndk="/Users/yjy/Library/Android/sdk/ndk/20.0.5594570" ndk_api=21  target_os="android" target_cpu="arm" is_component_build=true skia_use_libjpeg_turbo=true skia_enable_pdf=false skia_use_libpng=true skia_use_libwebp=true is_debug=false is_official_build=false'

ninja -C out/Shared
```

其中is_component_build，代表着这个时候是需要编译skia的动态库。target_cpu代表目标平台。skia_enable_pdf代表关闭pdf的模块。is_debug关闭skia的debug模式

### Skia编译总结和踩坑
实际上，在第一次上手Skia的编译的时候，踩了不少坑。主要也是对GN脚本不熟悉。网上有不少的问题，我好像都遇到了。

其中有一处，skia_use_system_xxx的标志参数需要讨论一下。这个参数打开的话就会从当前系统查找又没有对应的模块源码编译进去。比如说，我们打开skia_use_system_png，则会从系统中查找又没有libpng的源码编译进来，没有则报错。一般我们是关闭的。

第二处，当我们关闭了jpeg,设置了skia_use_libjpeg_turbo =false的时候。编译通过了，但是却出现如下的错误信息：
```
dlopen failed: cannot locate symbol '_ZN11SkJpegCodec6IsJpegEPKvj'
```
这个错误信息，是指未定义的符号，可以通过nm -u xxx.so查看未定义符号有什么。一般是需要链接的库没有链接进来。

能从这里面看到实际上是有一个SkJpegCodec的isJpeg方法没有定义到导致的异常。我翻了下源码，发现到skia的so库中必须编译如下这个cpp
```shell
"src/codec/SkCodec.cpp",
```
这个cpp中实际上调用了isJpeg方法。这就是异常的根本。虽然我们并没有编译近jpeg，但是耐不住核心库的解析类调用了啊。并不是网上所说的is_official_build没有打开。

当然，也有可能是我当前的代码是最新版本，导致现象不一致。

因此，我们要裁剪skia，还需要对skia的源码熟悉才行。这其实应该也是skia划分模块没有划分很好的坑。

哈哈，也就是我们常说的，组件化没有彻底。

## Skia第一个应用
skia第一个Android应用很简单：我们就写hello world。用两种方式来写。来验证我这段时间是否阅读懂了Canvas的机制。

CMakeLists的代码在这里就不放出了，很简单的。我们编写两个View，一个是基于Bitmap上修改，另一个是基于Surface的编写。

首先编写好两个native方法：
```java
public class SkiaUtils {
    static {
        System.loadLibrary("skia");
        System.loadLibrary("native-lib");
    }

    public static native void native_renderCanvas(Bitmap bitmap);

    public static native void native_render(Surface surface,int width,int height);
}

```

之前写代码都是静态注册jni，这次来试试动态注册jni：
```java
static const char* const className = "com/yjy/skiaapplication/SkiaUtils";
static const JNINativeMethod gMethods[] = {
        {"native_renderCanvas","(Landroid/graphics/Bitmap;)V",(void *)native_renderCanvas},
        {"native_render","(Landroid/view/Surface;II)V",(void *)native_render}
};


jint JNI_OnLoad(JavaVM *vm,void* reserved){
    JNIEnv *env = NULL;
    jint result;

    if(vm->GetEnv((void**)&env,JNI_VERSION_1_4)!=JNI_OK){
        return -1;
    }

    jclass clazz = env->FindClass(className);
    if(!clazz){
        LOGE("can not find class");
        return -1;
    }

    if(env->RegisterNatives(clazz,gMethods, sizeof(gMethods)/sizeof(gMethods[0])) < 0){
        LOGE("can not register method");
        return -1;
    }

    return JNI_VERSION_1_4;

}
```
很简单，这样就把方法注册到JNI中，熟悉源码的肯定对这种方法十分熟悉。

#### Skia基于Bitmap的编写
首先编写一个简单View
```java
public class SkiaView extends View {

    // Used to load the 'native-lib' library on application startup.

    static {
        System.loadLibrary("skia");
        System.loadLibrary("native-lib");
    }

    Bitmap bitmap;
    Paint paint = new Paint();

    public SkiaView(Context context) {
        super(context);
    }

    public SkiaView(Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
    }

    public SkiaView(Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        if(bitmap == null){
            bitmap=
                    Bitmap.createBitmap(canvas.getWidth(),canvas.getHeight(),
                            Bitmap.Config.ARGB_8888);
        }

        SkiaUtils.native_renderCanvas(bitmap);

        canvas.drawBitmap(bitmap,0,0,paint);
    }
}
```
很简单就是在onDraw的时候把bitmap传递到底层。把上面的bitmap绘制成我们需要的样子最后把图像绘制上去。

#### Skia绘制Bitmap
网上有很多Skia的资料，很遗憾无一例外都过时了，很多api都迁移和变化了，不过只是运用api是十分简单的事情，看看文档就能解决了。如果是Android开发看起来更加轻松，因为Skia几乎都是在SkCanvas上绘制，实际上对应的是Android的Canvas对象。每一个SkCanvas都对应上了Android中Canvas的Java api。


```cpp
extern "C"
JNIEXPORT void JNICALL
native_renderCanvas(JNIEnv *env, jobject thiz, jobject bitmap) {
    // TODO: implement native_renderCanvas()
    LOGE("native render");

    AndroidBitmapInfo info;
    int *pixel;
    int ret;

    ret = AndroidBitmap_getInfo(env,bitmap,&info);
    ret = AndroidBitmap_lockPixels(env,bitmap,(void**)&pixel);

    int width = info.width;
    int height = info.height;

    SkBitmap bm = SkBitmap();
    SkImageInfo image_info = SkImageInfo
            ::MakeS32(width,height,SkAlphaType::kOpaque_SkAlphaType);
    bm.setInfo(image_info,image_info.minRowBytes());
    bm.setPixels(pixel);

    SkCanvas background(bm);
    SkPaint paint;//画笔

    paint.setColor(SK_ColorBLACK);
    SkRect rect;//绘制一个矩形区域
    rect.set(SkIRect::MakeWH(width,height));

    background.drawRect(rect,paint);

    SkPaint paint2;
    paint2.setColor(SK_ColorBLUE);
    const char *str = "Hello Skia";

    SkFont skfont(SkTypeface::MakeDefault(),100);

    background.drawString(str,100,100,skfont,paint2);

    AndroidBitmap_unlockPixels(env,bitmap);
}
```

AndroidBitmap_getInfo获取bitmap中所有的信息。接着通过lock方法，把pixel的像素指针给关联起来，最后通过绘制背景和文字在SKCanvas上，呈现出一个Hello Skia方法。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-925f11d965db2b6e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


### Skia基于Surface绘制
好像很多文章都止步于绘制bitmap，没有其他想法。我倒是看到一个哥们直接获取Android源码的skia相关文件，编译出so库。这不失是一种好方法，这样就能编译出Android中纯净的Skia。

他的做法是把Canvas对象传到底层，直接通过GraphicsJNI把Java的Canvas转化为SkCanvas。我不知道这个作者是基于什么版本开发的，我反正一路看到Android 4.4就没兴趣看下去了。

GraphicsJNI本质上是获取Canvas中存着native对象的地址。但是这个地址对象并非是SkCanvas，而是SkiaCanvas。SkiaCanvas和SkCanvas并非继承关系，而是包含关系。虽然我当然能写一模一个的获取Java对象的方法，但是获取的SkiaCanvas对象，会对整个编程造成错误，甚至是误导。

关于这一块的源码理解，我们将会在Android重学系列，和大家好好讲讲它们之间的关系。

还有一种做法，了解音视频开发的哥们一定会熟悉，在Android中一种叫做NativeWindow的本地窗口，是用来在Surface上绘制。关于NativeWindow也会在Android重学系列和大家聊聊。

我们这一次借助NativeWindow来绘制Skia。

##### 编写一个简单的SurfaceView
```java
/**
 * <pre>
 *     author : yjy
 *     e-mail : yujunyu12@gmail.com
 *     time   : 2019/09/14
 *     desc   :
 *     version: 1.0
 * </pre>
 */
public class SkiaCanvasView extends SurfaceView implements SurfaceHolder.Callback2 {

    private SurfaceHolder mHolder;
    private HandlerThread mHandlerThread;
    private Handler mHandler;
    private static final int DRAW = 1;

    public SkiaCanvasView(Context context) {
        this(context,null);
    }

    public SkiaCanvasView(Context context, AttributeSet attrs) {
        this(context, attrs,0);
    }

    public SkiaCanvasView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }

    private void init(){
        mHandlerThread = new HandlerThread("Skia");
        mHolder = getHolder();
        mHolder.addCallback(this);
        mHandlerThread.start();
        mHandler = new SkiaHandler(mHandlerThread.getLooper());

    }

    @Override
    public void surfaceRedrawNeeded(SurfaceHolder holder) {

    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        Message message = new Message();
        message.what = DRAW;
        message.obj = holder.getSurface();
        message.arg1 = getWidth();
        message.arg2 = getHeight();
        mHandler.sendMessage(message);
        Log.e("create","width:"+getWidth());
        Log.e("create","height"+getHeight());
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {

    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        mHandlerThread.quit();
    }

    private  class SkiaHandler extends Handler{

        public SkiaHandler(Looper looper){
            super(looper);
        }

        @Override
        public void handleMessage(@NonNull Message msg) {
            super.handleMessage(msg);
            switch (msg.what){
                case DRAW:
             
                       SkiaUtils.native_render((Surface) msg.obj,msg.arg1,msg.arg2);
                    

                    break;
            }
        }
    }
}
```

很简单，不解释。

#### 绘制Skia
```cpp
extern "C"
JNIEXPORT void JNICALL
native_render(JNIEnv *env, jobject thiz, jobject jSurface,jint width,jint height){
    ANativeWindow *nativeWindow = ANativeWindow_fromSurface(env,jSurface);


    ANativeWindow_setBuffersGeometry(nativeWindow,  width, height, WINDOW_FORMAT_RGBA_8888);

    ANativeWindow_Buffer *buffer = new ANativeWindow_Buffer();

    ANativeWindow_lock(nativeWindow,buffer,0);


    int bpr = buffer->stride * 4;


    SkBitmap bitmap;
    SkImageInfo image_info = SkImageInfo
    ::MakeS32(buffer->width,buffer->height,SkAlphaType::kPremul_SkAlphaType);


    bitmap.setInfo(image_info,bpr);

    bitmap.setPixels(buffer->bits);

    SkCanvas *background = new SkCanvas(bitmap);
    SkPaint paint;

    paint.setColor(SK_ColorBLUE);
    SkRect rect;
    rect.set(SkIRect::MakeWH(width,height));

    background->drawRect(rect,paint);

    SkPaint paint2;
    paint2.setColor(SK_ColorWHITE);
    const char *str = "Hello Surface Skia";

    SkFont skfont(SkTypeface::MakeDefault(),100);

    background->drawString(str,100,100,skfont,paint2);

    SkImageInfo imageInfo = background->imageInfo();


    LOGE("row size:%d,buffer stride:%d",imageInfo.minRowBytes(),bpr);

    LOGE("before native_window stride:%d,width:%d,height:%d,format:%d",
            buffer->stride,buffer->width,buffer->height,buffer->format);

    int rowSize = imageInfo.minRowBytes();




    bool isCopy =  background->readPixels(imageInfo,buffer->bits,bpr,0,0);


    LOGE("after native_window stride:%d,width:%d,height:%d,format:%d",
         buffer->stride,buffer->width,buffer->height,buffer->format);

    ANativeWindow_unlockAndPost(nativeWindow);

}
```
readPixels 第一个参数是ImageInfo，图像信息;第二个是像素集合;第三个参数是是每一行的像素字节数；第四个参数是x方向的偏移量；第五个参数是y轴方向的偏移量。

能看到，我们同样是生成一个新的SkCanvas，把图像和文字绘制到上面，最后读取所有的像素点，并且把像素点的数据传送出去。

![image.png](https://upload-images.jianshu.io/upload_images/9880421-42a5e7889c4a9a57.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

这是怎么回事？为什么文字都变形了？？看起来整个文字被压缩了。当我放大整个显示范围时候，发现整个文字向右边倒下去了，并且被压缩了。

这个问题坑了快一个小时。当时其实已经有了初步猜测，如果了解OpenGL就知道，实际上在我们传输数据的时候，需要定义每一行要读取多少数据，要跳转多少位数。当一行的数据设置异常的时候，就图像就会出现异常。因为每一行读的数据多了，下一行实际上起点向后挪动了，这就是文字往右边倒的原因。

#### 解决
我当时翻阅了Android源码看到了，Android源码在测定每一行的时候，并非是通过imageInfo去计算一行最小字节数，而是通过nativeWindow中buffer的一行的像素*像素大小得到的每一行的字节数目。

经过打印确实nativeWindow中通过buffer得到的stride和minRowSize计算的结果不一样。有兴趣的可以去看看，minRowSize计算的是最小的行字节长度，实际上是有可能大于等于这个数字的。

于是，我把readPixels修改成如下：
```cpp
background->readPixels(imageInfo,buffer->bits,bpr,0,0);
```
如下图：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-91f1d1381d23941e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)



## 总结
Skia的初探先到这里，到这里也算是入门了。之后Skia相关的文章将会是关于Skia的源码解析篇。这也算是Android开发的好处，不需要过多熟悉Skia的api，因为我们在做Canvas的时候其实操作的就是SkCanvas的api。

从解决问题上的思路，可以明白阅读源码不仅仅是理解原理，更加重要的是，能解决看起来完全没头绪的问题，看起来不太可能的实现的功能。这也是我为什么热衷于阅读源码的原因。

最后，附上demo地址的demo:[https://github.com/yjy239/SkiaDemo](https://github.com/yjy239/SkiaDemo)
