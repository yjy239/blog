---
title: AndroidStudio CMakeList的总结
top: false
cover: false
date: 2019-06-22 17:11:27
img:
description:
author: yjy239
summary:
categories: CMakeList
tags:
- Linux
---
 如果遇到什么有问题的请在这里联系我：[https://www.jianshu.com/p/445d5cbe166d](https://www.jianshu.com/p/445d5cbe166d)

# 背景
CMakeList这个东西对于所有的Linux，Android开发者都是很熟悉的东西。但是Android的Java应用开发很少关注这个，这段时间跟着辉哥系统的学了CMakeList，发现之前对CMakeList的理解很浅，特此写一篇学习总结。

# 正文
CMakeList本质上是cmake的一个脚本文件，用于跨平台管理c/c++/java项目的。聊到CMake，就不得不聊一下Linux开发中的makefile 工具。

### C的程序编译流程
在理解make工具如何构建的时候，我们先要熟悉一个c语言的程序是经过几个步骤编译的。实际上就是指gcc的编译流程。
gcc将会分为如下几个步骤：
- 1.预处理阶段
调用命令：
```
gcc -E -o hello.i hello.c
```
这个命令则作用是生成.i文件。这个步骤完成的行为是，展开宏定义，展开inlcude文件。

- 2.预编译阶段
调用命令：
```
gcc -S -o hello.s hello.i
```
gcc在该命令才会检测代码规范性，检测代码是否有误，最后生成汇编文件.s文件。

- 3.汇编阶段
调用命令：
```
gcc -c -o hello.o hello.s
```
把.s文件翻译成.o文件，里面全是机器指令

- 4.链接阶段
调用命令：
```
gcc -o hello hello.o
```
计算逻辑地址，合并数据段，有些函数是在另一个函数的。

## makefile 工具
如果每一次编写好一个文件都要调用一次gcc的命令，这样实在是太过繁琐，而且在在每一次编译的流程都一致情况下，就诞生了makefile，这个工具帮助我们管理编译项目。

我们看看makefile如何帮助我们编译项目。
首先创建一个Makefile文件。接着按照以下三个原则编写makefile脚本。
记住一个规则，两个函数,三个自动变量。

#### 一个规则
一个规则有两个思想，若想生成目标文件，先要检测规则中的依赖是否存在。
- 1. 如果不存在则会寻找是否有完整的规则来完成该依赖条件
- 2.会检查规则中的目标是否需要更新，必须先检查他所有依赖目标
```
a.out:a.c
	gcc a.c -o a.out
```

这里的意思是，要生成a.out需要依赖a.c文件，而这个依赖对应的命令是
```
gcc a.c -o a.out
```
记住这中间不存在任何空格，当编写对应的命令时候需要直接使用Tab按键进行缩紧，才能被makefile识别。

因此我们每一次改动文件，makefile会根据依赖文件的更改日期来决定当前要生成的目标是否需要更新

#### 两个函数
##### 第一个函数
```
src = $(wildcard *.cpp)
```
找到当前目录下所有后缀为 .cpp 的文件，然后赋值给 src
##### 第二个函数
```
obj = $(patsubst %cpp,%o,$(src))
```
就是把src变量里的所有后缀为 .cpp 的文件替换成 .o 文件

#### 三个自动变量
$@：表示规则中的目标
$^  ：表示规则中所有的依赖条件，组成一个列表，以空格隔开，如果这个列表有重复项则消除重复
$<  ： 表示规则中的第一个依赖条件，如果运行在模式套用中，相当于依次取出依赖条件套用该模式规则

举个例子：

```
src = $(wildcard *.cpp)
obj = $(patsubst %cpp,%o,$(src))


hello.out:$(obj)
	gcc $^ -o $@

div.o:div.cpp
	gcc -c $< -o $@

add.o:add.cpp
	gcc -c $< -o $@

sub.o:sub.cpp
	gcc -c $< -o $@

hello.o:hello.cpp
	gcc -c $< -o $@



# $(***)取变量值
clean:
	rm -f $(obj) hello.out

# 生成伪目标
.PHONY:clean
```
能看到，这里要生成一个hello.out一个执行文件。首先要依赖所有.o文件。这里的.o文件，分别是指div.o,add.o,sub.o,hello.o。而这些文件都分别依赖了对应的.cpp文件。

每个依赖下面都有对应的 gcc -c $< -o $@ 实际上就是指gcc -c add.cpp -o add.o.这样通过依赖树，就能生成一个执行文件。但是实际上还能更加简化：
```
src = $(wildcard *.cpp)
obj = $(patsubst %cpp,%o,$(src))


hello.out:$(obj)
	gcc $^ -o $@

#模式规则
# gcc -c $(src) -o $(obj)
# o文件依赖cpp文件
%o:%cpp
	gcc -c $< -o $@

# $(***)取变量值
clean:
	rm -f $(obj) hello.out

# 生成伪目标
.PHONY:clean
```
实际上能够通过上面%o:%cpp,通过一条简单的依赖规则，就能简化上面大量的依赖规则。

makefile的总结暂时到这里，接下来总结cmake。

## cmake
cmake是基于makefile之上的跨平台管理工具，比起makefile又简单了不少。会通过简单的命令生成一个Makefile进行编译工程。
先介绍几个基础的API。

> PROJECT (HELLO) 为cmake的工程命名

> INCLUDE_DIRECTORIES (${PROJECT_SOURCE_DIR}/include) 指定头文件目录在哪里

> LINK_DIRECTORIES (${PROJECT_SOURCE_DIR}/lib) 指定生成的文件对应的链接库

> ADD_EXECUTABLE (hello hello.cpp) 生成一个执行文件

> TARGET_LINK_LIBRARIES (hello math) 链接其他的动态/静态库

> AUX_SOURCE_DIRECTORY(${CMAKE_SOURCE_DIR}/src/main/cpp SRC_LIST) 收集该目录下的源码文件到SRC_LIST变量中

> ADD_LIBRARY(native-lib SHARED ${SRC_LIST}) 根据源文件生成一个动态库

最后在通过上述api的编写生成一个CMakeLists.txt目录下，使用cmake .就能自动生成对应的Makefile文件，最后再make命令就能完成编译了。

但是对于AndroidStudio来说，没必要调用命令，当使用点击了make的按钮时候，就会如果cmake .一样的效果了。

## 案例一
一个简单的例子，如果有如下这么一个目录文件
![一个CmakeList工程实例.png](/images/一个CmakeList工程实例.png)


那么我们要做的事情首先先以CMakeList.txt作为基准文件坐标，去寻找其他目录文件。

首先确定include文件在app/main/cpp/include中，接着确定其他需要链接的第三方库在jniLibs中。那么我们就写下如下两行
```
cmake_minimum_required(VERSION 3.4.1)

#PROJECT(music-player)

include_directories(src/main/cpp/include)

# 指定so在哪个目录下
link_directories(${PROJECT_SOURCE_DIR}/src/main/jniLibs/armeabi-v7a)
```

接着我们需要收集所有的源文件,到一个变量中,方法有两个。
```
# 收集下所有的源文件 到src_list
 aux_source_directory(${CMAKE_SOURCE_DIR}/src/main/cpp SRC_LIST)

# 收集所有的cpp文件以及c文件到SRC_LIST
#file(GLOB SRC_LIST ${PROJECT_SOURCE_DIR}/src/main/cpp/*.cpp ${PROJECT_SOURCE_DIR}/src/main/cpp/*.h)
```

接着我们还需要找到一个Android对应的日志库
```
# 查找一个动态库
find_library(log-lib log)
```
这个方法和link_directories有点相似。官方推荐使用find_library，因为找不到对应的第三方库文件，就会报错。但是要这么做的话，就需要先add_library进来。新手使用find_library，而熟悉一点的使用link_directories更好。

接下来就要生成我们c++工程对应的动态链接库。
```
# 指定生成动态库
add_library(music_player SHARED ${SRC_LIST})
```
可以看到的时候，由于我们收集了cpp目录下所有的源文件到了SRC_LIST变量，以后再也不需要每一次添加文件都在这里面写一个文件对应的目录。当每一次添加源文件，为了避免AndroidStudio找不到，还是需要点击以下refresh linked c++ project的按钮。

最后记得要链接所有的动态库到我们的music_player中。
```
target_link_libraries(music_player
        android
        ${log-lib}
        avutil-55
        avcodec-57
        avdevice-57
        avfilter-6
        avformat-57
        postproc-54
        swresample-2
        swscale-4)
```

## 案例二
这是来自张绍文的第一篇学习breakpad的cmake工程。
该目录文件结构如下：
![一个CmakeList子工程实例.png](/images/一个CmakeList子工程实例.png)

能够看到的是这个工程有两个CMakeLists.txt。而这种情况更加常见，因为做大型一点的项目往往都是按照模块拆分开来，通过各自模块的CMakeList.txt管理各自子工程。这里要介绍一个新的api。

> add_subdirectory 该api是控制子目录下的CMakeLists.txt。当通过这个api指定了目录，将会找到子目录下的CMakeLists.txt，并且执行里面的命令。

#### breakpad子目录CMakeLists.txt
我们先来看看子目录external/libbreakpad里面的CMakeLists.txt。
```
cmake_minimum_required(VERSION 3.4.1)

set(BREAKPAD_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${BREAKPAD_ROOT}/src ${BREAKPAD_ROOT}/src/common/android/include)


file(GLOB BREAKPAD_SOURCES_COMMON
        ${BREAKPAD_ROOT}/src/client/linux/crash_generation/crash_generation_client.cc
        ${BREAKPAD_ROOT}/src/client/linux/dump_writer_common/thread_info.cc
        ${BREAKPAD_ROOT}/src/client/linux/dump_writer_common/ucontext_reader.cc
        ${BREAKPAD_ROOT}/src/client/linux/handler/exception_handler.cc
        ${BREAKPAD_ROOT}/src/client/linux/handler/minidump_descriptor.cc
        ${BREAKPAD_ROOT}/src/client/linux/log/log.cc
        ${BREAKPAD_ROOT}/src/client/linux/microdump_writer/microdump_writer.cc
        ${BREAKPAD_ROOT}/src/client/linux/minidump_writer/linux_dumper.cc
        ${BREAKPAD_ROOT}/src/client/linux/minidump_writer/linux_ptrace_dumper.cc
        ${BREAKPAD_ROOT}/src/client/linux/minidump_writer/minidump_writer.cc
        ${BREAKPAD_ROOT}/src/client/minidump_file_writer.cc
        ${BREAKPAD_ROOT}/src/common/convert_UTF.c
        ${BREAKPAD_ROOT}/src/common/md5.cc
        ${BREAKPAD_ROOT}/src/common/string_conversion.cc
        ${BREAKPAD_ROOT}/src/common/linux/elfutils.cc
        ${BREAKPAD_ROOT}/src/common/linux/file_id.cc
        ${BREAKPAD_ROOT}/src/common/linux/guid_creator.cc
        ${BREAKPAD_ROOT}/src/common/linux/linux_libc_support.cc
        ${BREAKPAD_ROOT}/src/common/linux/memory_mapped_file.cc
        ${BREAKPAD_ROOT}/src/common/linux/safe_readlink.cc

        )

file(GLOB BREAKPAD_ASM_SOURCE ${BREAKPAD_ROOT}/src/common/android/breakpad_getcontext.S
        )

set_source_files_properties(${BREAKPAD_ASM_SOURCE} PROPERTIES LANGUAGE C)

add_library(breakpad STATIC ${BREAKPAD_SOURCES_COMMON} ${BREAKPAD_ASM_SOURCE})

target_link_libraries(breakpad log)
```

能看到的是，首先通过set命令指定了一个BREAKPAD_ROOT变量是当前这个cmakelists.txt的目录。

接着，确定了头文件有两处，第一处是CMakeLists.txt所在的目录下的src，第二个是CMakeLists.txt所在的目录下src/common/android/include。

接着通过file收集源文件。因为收集的比较复杂，因此使用了file 命令收集符合标志的文件。

通过set_source_files_properties 来告诉BREAKPAD_ASM_SOURCE下面的汇编文件以C语言的方式编译。

醉着通过add_library生成breakpad文件，并且target_link_libraries链接上了Android的日志库。

#### breakpad父目录CMakeLists.txt 的控制
```
cmake_minimum_required(VERSION 3.4.1)
project(breakpad-core)

set(ENABLE_INPROCESS ON)
set(ENABLE_OUTOFPROCESS ON)
set(ENABLE_LIBCORKSCREW ON)
set(ENABLE_LIBUNWIND ON)
set(ENABLE_LIBUNWINDSTACK ON)
set(ENABLE_CXXABI ON)
set(ENABLE_STACKSCAN ON)

if (${ENABLE_INPROCESS})
    add_definitions(-DENABLE_INPROCESS)
endif ()
if (${ENABLE_OUTOFPROCESS})
    add_definitions(-DENABLE_OUTOFPROCESS)
endif ()


set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Werror=implicit-function-declaration")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++11 ")

# breakpad
include_directories(external/libbreakpad/src external/libbreakpad/src/common/android/include)
add_subdirectory(external/libbreakpad)
list(APPEND LINK_LIBRARIES breakpad)

add_library(breakpad-core SHARED
        breakpad.cpp)
target_link_libraries(breakpad-core ${LINK_LIBRARIES}
        log)
```

能看到在父目录中的CMakeLists的控制更加偏向整个工程的全局控制。首先打开了各种编译时候的开关。

设置了头文件目录，能够发现这里的子模块头文件，又一次被声明。当我们尝试的注释掉这一行。发现编译是无法通过。也就是说，子模块添加的头文件并不能被父模块识别。

add_subdirectory 告诉CMakeLists.txt要管理哪个子模块的内容。

其好处就是我们通过
```
list(APPEND LINK_LIBRARIES breakpad)
```
把先前的add_library生成的breakpad动态库动态放到LINK_LIBRARIES中。这样就添加了需要链接的动态库内容。

接着还是走老套路，add_library生成对应的动态/静态库，接着链接。

# 总结
以上就是CMakeLists.txt的基本内容，熟知这些操作之后，在AndroidStudio编写任何的c++项目不会为如何管理项目头疼了。

但是记住，当我们链接进新的的动态库的时候，请注意这个动态库是用什么编写的。如果我们写的是c++工程，但是缺直接引用了对应的头文件,就会爆链接异常。请使用extern “C”的方式引用头文件。
```cpp
extern "C" {
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavformat/avformat.h>
}
```

这个问题，在我刚搞CMakeLists.txt的时候，出现的，弄的我以为是我的脚本写错了呢。