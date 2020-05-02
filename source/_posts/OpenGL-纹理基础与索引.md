---
title: OpenGL (三)纹理基础与索引
top: false
cover: false
date: 2019-07-27 23:33:12
img:
description:
author: yjy239
summary:
tags:
- OpenGL
- 音视频
---
# 前言
OpenGL的纹理实际上运用十分广泛，是OpenGL中的重点。如果你有看过Android底层的绘制原理，能够发现实际上，一般的ui界面，Android把会把像素点当作纹理数据绘制在屏幕上。

因此还是有必要稍微学习一下OpenGL的纹理。本文讲述的是OpenGL的纹理基础。

如果在本文遇到什么问题，请在[https://www.jianshu.com/p/9c58cd895fa5](https://www.jianshu.com/p/9c58cd895fa5)这里联系本人

# 正文
## 纹理介绍
从前面几节OpenGL我们可以清楚，OpenGL可以结合顶点数组对象，顶点缓存对象，使用OpenGL命令，生成各种图形。但是，有没有想过，如果需要图像看起来十分真实，就需要足够多的顶点，指定足够多的颜色。这样会产生许多额外的开销。

因此，诞生了纹理。纹理是一个2D图片(甚至也有1D，3D的纹理)，他可以添加物体细节。可以想像，实际上OpenGL可以建立了一个模型，但是还需要很多图像的细节，为了添加细节，把这个带着图像的纸贴在模型上。

>除了图像以外，纹理也可以用来存储大量的数据，可以把数据发送到着色器上。

比如说，我们可以把一个砖块的纹理贴在上两章的三角形上。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-d33c3078dc3f3b0e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

为了把纹理正确的映射到模型上，我们必须要知道纹理映射的坐标，指定三角形每个对应上纹理的哪个部分。

## 纹理坐标系
下面是上图的纹理坐标：
![纹理坐标系.png](https://upload-images.jianshu.io/upload_images/9880421-9f38f150b29e6895.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到这个纹理坐标和之前的OpenGL的顶点坐标系不太一样，这边的坐标系是以左下角为原点。

记得，这坐标系和顶点坐标系思路上不太一样。顶点坐标系相当于在一个三维空间中，找个位置构建一个2d/3d的模型。

但是纹理坐标系，一旦纹理加载了图片之后，想要获取到完整的图片，就要x轴(0,1)和y轴(0,1)整个的区域才能把这个图片读取出来。

举个例子：
如上图，我们希望添的图片左下角能对应三角形的左下角，右下角对应右下角，顶部对应三角形的中心。
那么我们可以创建一个如下的纹理坐标系：
```cpp
float texCoords[] = {
    0.0f, 0.0f, // 左下角
    1.0f, 0.0f, // 右下角
    0.5f, 1.0f // 上中
};
```

但是，注意到没有，这是个正方形的区域，如果遇到长方形的图片怎么办。OpenGL其实有自己的策略。这个稍后会继续谈到。

## 纹理环绕方式
注意到纹理坐标系的问题，这里就有OpenGL提供的几种解决这个问题的思路。

纹理坐标一般在(0,0),(1,1)浮动，如果我们纹理坐标设置到了坐标之外，那么会发生什么？OpenGL会默认重复这个图像。

但是实际上OpenGL除了这些之外还提供了其他的方式：
环绕方式 | 描述 
-|-
GL_REPEAT | 对纹理的默认行为。重复纹理图像。
GL_MIRRORED_REPEAT | 和GL_REPEAT一样，但每次重复图片是镜像放置的。
GL_CLAMP_TO_EDGE | 纹理坐标会被约束在0到1之间，超出的部分会重复纹理坐标的边缘，产生一种边缘被拉伸的效果。
GL_CLAMP_TO_BORDER | 超出的坐标为用户指定的边缘颜色。

![image.png](https://upload-images.jianshu.io/upload_images/9880421-a84e3dd364baf0ed.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
 
那么反过来说，如果小于当前的坐标呢？
OpenGL将会截取一部分的图像贴在整个模型上面。之后会在实战演练中见识到现象。

OpenGL在设置纹理的时候，可以设置纹理单元的绘制参数，调用如下方法：
```cpp
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_MIRRORED_REPEAT);
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_MIRRORED_REPEAT);
```
这个glTexParameteri，是设置纹理之前的做的参数设置，相当于构建构建一个纹理绘制的坐标之类的参数。
第一个参数是指：我们要绘制2d纹理，第二个参数是指：我们要设定的纹理轴中的行为，第三个参数是指：当这个纹理轴上的纹理超过了纹理坐标的范围，的表现形式。

在纹理中存在着s,t,r三种坐标轴:
![image.png](https://upload-images.jianshu.io/upload_images/9880421-0a9044484c146b3a.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

一般绘制2D，就在s和t轴上绘制。s我们可以类比x轴，t可以类比y轴。

如果我们选择了GL_CLAMP_TO_BORDER，如果当前的图像不是正方形，图像纹理将会把图像压缩到(0,0),(1,1)之间，剩下的部分会用黑色填充。我们可以传递一个float数组作为边缘的颜色值。
```cpp
float borderColor[] = { 1.0f, 1.0f, 0.0f, 1.0f };
glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor);
```


## 纹理过滤
纹理过滤实际上是对纹理中图像像素的处理策略。

纹理坐标不依赖分辨率，它可以是任意的浮点值，所以OpenGL需要知道纹理像素怎么映射到纹理坐标系中。当你有一个很大的物体但是纹理分辨率很低的时候就很重要了。

因此OpenGL提供了很多纹理过滤的方式，其中两种十分重要，这两种方式也会在OpenCV中涉及到这块东西的讲解：
- 1.邻近过滤(GL_NEAREST)
- 2.线性过滤(GL_LINEAR)

### 邻近过滤
邻近过滤是OpenGL默认的方式。当设置GL_NEAREST，OpenGL会挑选中心点最接近纹理坐标的像素值。
![邻近过滤.png](https://upload-images.jianshu.io/upload_images/9880421-ee6b91fc51583466.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

### 线性过滤
线性过滤会基于纹理坐标附近纹理像素值，做一个插值计算，计算出近似周边的像素值。一个纹理像素中心距离纹理坐标越近，其贡献越大。这就有点像一个掩码操作，通过一个核算出一个相关性。

下图你能看到返回的是一个周边像素的混合色：
![线性过滤.png](https://upload-images.jianshu.io/upload_images/9880421-dffd931fadc886d4.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


通过两者的比较我们不难发现，线性过滤的图像会柔和一点，而邻近过滤的图像就会增加对比度一点。

实际上这个操作和OpenCV的filter过滤器有这同工异曲之妙。当我们放大像素就有如下的效果：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-0d30cea60fa8788b.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能够发现GL_NEAREST更加偏向像素风格，每个颗粒会很大。而GL_LINEAR会平滑一点。

OpenCV对应的api
```cpp
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
```

## 多级渐远纹理
假设一下，当一个空间有上千物体，就需要上千纹理。有些纹理很远，其纹理难以和近的纹理难以有一个分辨率。由于远处的物体可能只产生很少的片段，OpenGL从高分辨率纹理中为这些片段获取正确的颜色值就很困难，因为它需要对一个跨过纹理很大部分的片段只拾取一个纹理颜色。在小物体上这会产生不真实的感觉，更不用说对它们使用高分辨率纹理浪费内存的问题了。

为了解决这个问题，OpenGL使用一种叫做多级渐远纹理(Mipmap)的概念来解决。

简单来说，他是一系列的纹理图像，后者是前者的1/2。其原理很简单，当距离观察者超过一定的阈值，OpenGL会使用不同的多级渐远纹理来处理，选择最适合当前距离的纹理。

由于距离远，解析度不高也不会被用户注意到。同时，多级渐远纹理另一加分之处是它的性能非常好。让我们看一下多级渐远纹理是什么样子的：
![多级渐远纹理](https://upload-images.jianshu.io/upload_images/9880421-2405453bde3363ff.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

手工创建多个纹理比较复杂，因此OpenGL提供了glGenerateMipmaps方法设置一系列多级渐远纹理.

在渲染过程中，切换多级渐远纹理级别(Level)时，OpenGL在两个不同级别的多级渐远纹理层之间会产生不真实的生硬边界，就像普通的纹理过滤一样，切换多级渐远纹理级别时你也可以在两个不同多级渐远纹理级别之间使用NEAREST和LINEAR过滤。

切换纹理方式|描述
-|-
GL_NEAREST_MIPMAP_NEAREST|使用最近邻的多级渐远纹理来匹配像素大小，并使用近邻插值进行纹理过滤
GL_LINEAR_MIPMAP_NEAREST|使用最近邻的多级渐远纹理来匹配像素大小，并且使用线性插值起进行纹理过滤。
GL_NEAREST_MIPMAP_LINEAR|在两个最匹配像素大小的多级渐远纹理之间进行线性插值，使用邻近插值进行采样
GL_LINEAR_MIPMAP_LINEAR|在两个邻近的多级渐远纹理之间使用线性插值，并使用线性插值进行采样

OpenGL提供的api：
```
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
```
GL_TEXTURE_MIN_FILTER代表缩小操作时候的纹理操作，GL_TEXTURE_MAG_FILTER代表渐远纹理级别切换时候操作。

注意一个常见的错误，放大不会使用多级渐远纹理。使用了会报错。

## 纹理常规开发流程
纹理的常见实际上和VAO，VBO十分相似。都是走一个套路，通过Gen函数创建对象，bind函数绑定对象，最后再传输数据。

首先通过下面这个函数，常见一个纹理对象：
```cpp
GLuint texture;
glGenTextures(1,&texture);
```

绑定：
```cpp
glBindTexture(GL_TEXTURE_2D,texture);
```

设置纹理坐标的参数：
```cpp
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_REPEAT);
    
    //    float borderColor[] = { 1.0f, 1.0f, 0.0f, 1.0f };
    //    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor);
    //设置纹理过滤
    //缩小时候
glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
```

最后再传输数据：
```cpp
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
 glGenerateMipmap(GL_TEXTURE_2D);
```
针对glTexImage2D进行讲解：
- 1.第一个参数：指定了纹理目标。设置为GL_TEXTURE_2D意味着会生成与当前绑定的纹理对象在同一个目标上的纹理（任何绑定到GL_TEXTURE_1D和GL_TEXTURE_3D的纹理不会受到影响）。

- 2.第二个参数：第二个参数为纹理指定多级渐远纹理的级别，如果你希望单独手动设置每个多级渐远纹理的级别的话。这里我们填0，也就是基本级别。

- 3.第三个参数告诉OpenGL我们希望把纹理储存为何种格式。我们的图像只有RGB值，因此我们也把纹理储存为RGB值(记住要符合图片通道数，如果是4通道是RGBA)。

- 4.第四个和第五个参数设置最终的纹理的宽度和高度。我们之前加载图像的时候储存了它们，所以我们使用对应的变量。
- 5.下个参数应该总是被设为0（历史遗留的问题）
- 6.第七第八个参数定义了源图的格式和数据类型。我们使用RGB值加载这个图像，并把它们储存为char(byte)数组，我们将会传入对应值
- 7.最后一个参数是真正的图像数据

当调用glTexImage2D时，当前绑定的纹理对象就会被附加上纹理图像。然而，目前只有基本级别(Base-level)的纹理图像被加载了，如果要使用多级渐远纹理，我们必须手动设置所有不同的图像（不断递增第二个参数）。或者，直接在生成纹理之后调用glGenerateMipmap。这会为当前绑定的纹理自动生成所有需要的多级渐远纹理。

## 索引绘制
在这里稍微聊聊索引。实际上，在我的第一篇OpenGL学习中，发现当我们绘制一个三角形会指定3个坐标，一个矩形就需要2个三角形，6个顶点组成三角形组合起来。

但是实际上这种操作会浪费内存，而且有很多冗余的顶点数据。为了解决这种情况OpenGL引入了索引的概念。

举一个例子：

不实用索引去绘制矩形，需要6个顶点，其中有2个顶点是冗余的。
```cpp
float vertices[] = {
    // 第一个三角形
    0.5f, 0.5f, 0.0f,   // 右上角
    0.5f, -0.5f, 0.0f,  // 右下角
    -0.5f, 0.5f, 0.0f,  // 左上角
    // 第二个三角形
    0.5f, -0.5f, 0.0f,  // 右下角
    -0.5f, -0.5f, 0.0f, // 左下角
    -0.5f, 0.5f, 0.0f   // 左上角
};
```

但是如果我们使用索引，只需要创建如下,2个数组，一个是顶点数组，一个是索引数组：
```cpp
float vertices[] = {
    0.5f, 0.5f, 0.0f,   // 右上角
    0.5f, -0.5f, 0.0f,  // 右下角
    -0.5f, -0.5f, 0.0f, // 左下角
    -0.5f, 0.5f, 0.0f   // 左上角
};

unsigned int indices[] = { // 注意索引从0开始! 
    0, 1, 3, // 第一个三角形
    1, 2, 3  // 第二个三角形
};
```
这样我们就能通过索引找到这些顶点，复用顶点并且绘制2个三角形。

### 索引的用法
同样的配方：
生成一个Gen对象：
```
GLuint EBO;
glGenBuffers(1, &EBO);
```

绑定对象，并且输入顶点信息：
```
glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, EBO);
glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

```

但是绘制顶点的方法却是出现了变化：
```
glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, EBO);
glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);
```
glDrawElements 第一个参数指定了我们绘制的模式，这个和glDrawArrays的一样。第二个参数是我们打算绘制顶点的个数，这里填6，也就是说我们一共需要绘制6个顶点。第三个参数是索引的类型，这里是GL_UNSIGNED_INT。最后一个参数里我们可以指定EBO中的偏移量（或者传递一个索引数组，但是这是当你不在使用索引缓冲对象的时候），但是我们会在这里填写0。

我们会使用glDrawElements，绘制6个顶点，其顺序是依照索引来绘制。这样就能绘制出一个矩形。

在这里解释一下，此时索引数组有两个：
- 1. 0，1，3 
- 2. 1，2，3
这些索引会根据之前编写好的glVertexAttribPointer，去寻找顶点数组对象对应缓存对象的数组，找到对应的顶点信息。

因此画出来的如下图：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-462d7f2013cc012e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


这里稍微解释一下索引绘制的存储原理。glDrawElements会通过GL_ELEMENT_ARRAY_BUFFER目标的EBO中获取索引。这意味着我们每一次渲染索引都需要绑定一次索引。不过顶点数组对象，同样可以保存索引的绑定状态，就和VBO一样。

VAO绑定时正在绑定的索引缓冲对象会被保存为VAO的元素缓冲对象。绑定VAO的同时也会自动绑定EBO。如下图：
![索引绑定.png](https://upload-images.jianshu.io/upload_images/9880421-51cac011dc826133.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

> 当目标是GL_ELEMENT_ARRAY_BUFFER的时候，VAO会储存glBindBuffer的函数调用。这也意味着它也会储存解绑调用，所以确保你没有在解绑VAO之前解绑索引数组缓冲，否则它就没有这个EBO配置了。

因此当我们调用glDelete函数的时候，记得最后才销毁VAO。


## 实战演练

### 绘制箱子
当我们熟知了纹理以及索引绘制的基础知识之后，开始实战环节。我们尝试着把一个箱子绘制到一个矩形中。

接下来的源码，为了避免和前面的文章产生重复性，在阅读了Android 的源码之后，抽象了一个渲染引擎。这里面还是很简单，只是做一个OpenGL渲染环境的初始化，让我们集中本文所学习到的知识。

首先初始化环境。
```cpp
 RenderEngine *engine = new RenderEngine();
    GLuint VAO;
    GLuint VBO;
    GLuint EBO;
    GLuint texture[] = {1};
    const char* vPath = "/Users/yjy/Desktop/iOS workspcae/first_opengl/Texture/vertex.glsl";
    const char* fPath = "/Users/yjy/Desktop/iOS workspcae/first_opengl/Texture/fragment.glsl";
    Shader *shader = new Shader(vPath,fPath);
    shader->compile();
```

接下来，灵活运用上一篇文章的知识，创建VAO，VBO，EBO(索引)。
```cpp
//要画矩形，因此要两个三角形
void flushRetriangle(GLuint& VAO,GLuint& VBO,GLuint& EBO){
    float vertices[] = {
        //位置
        // 右上角          //颜色              //纹理
        0.5f, 0.5f, 0.0f,   1.0f,0.0f,0.0f,  2.0f,2.0f,
        // 右下角
        0.5f, -0.5f, 0.0f,  0.0f,1.0f,0.0f,  2.0f,0.0f,
        // 左下角
        -0.5f, -0.5f, 0.0f, 0.0f,0.0f,1.0f,  0.0f,0.0f,
         // 左上角
        -0.5f, 0.5f, 0.0f,  1.0f,1.0f,0.0f,  0.0f,2.0f
    };
    
    unsigned int indices[] = { // 注意索引从0开始!
        0, 1, 3, // 第一个三角形
        1, 2, 3  // 第二个三角形
    };
    
    //分配VAO
    glGenVertexArrays(1,&VAO);
    //分配VBO
    glGenBuffers(1,&VBO);
    //分配EBO
    glGenBuffers(1,&EBO);
    
    //绑定
    glBindVertexArray(VAO);
    glBindBuffer(GL_ARRAY_BUFFER,VBO);
    
    //设置缓存数据
    glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);
    //索引
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,EBO);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER,sizeof(indices),indices,GL_STATIC_DRAW);
    
    
    //告诉OpenGL怎么读取数据
    //分成三次来读取
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,8 * sizeof(float),(void*)0);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,8* sizeof(float),(void*)(3 * sizeof(float)));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(2,2,GL_FLOAT,GL_FALSE,8* sizeof(float),(void*)(6 * sizeof(float)));
    glEnableVertexAttribArray(2);
    

    
    //解绑
    glBindBuffer(GL_ARRAY_BUFFER,0);
    //glBindTexture(GL_TEXTURE_2D,0);
    glBindVertexArray(0);
   
}

```
稍微解释一下，其核心原理，实际上就是把顶点，颜色，纹理都集中在一个地方处理，并且告诉OpenGL应该怎么读取整个数据。

因为有三种数据要读取，所以要告诉OpenGL读取数据该怎么移动，从哪里读取。并且设置3中location，放在顶点着色器中解析。

- 1.顶点数据，是float型，每次读取3个，每读取完一次就移动8*sizeof(float)的大小(作者是4字节大小*8),从第0个位置开始读取。
- 2.颜色数据，是float型，每次读取3个，每读取完一次就移动8*sizeof(float)的大小，从第3个位置开始读取.
- 3.纹理坐标数据，是float型，每次读取2个，每读取完一次就移动8*sizeof(float)的大小，从第6个位置开始读取.

这样就能正确的读取到缓存中所有的数据。

![image.png](https://upload-images.jianshu.io/upload_images/9880421-7870eb4d9016fb3c.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


最后再设置好绘制纹理的环境参数，以及读取纹理数据。
```cpp
bool initTexture(GLuint& texture,const char* str,bool isResver){
    //设置纹理信息
    //生成和绑定
    glGenTextures(1,&texture);
    glBindTexture(GL_TEXTURE_2D,texture);
    //绑定当前的纹理对象，设置环绕，过滤的方式
    //设置S轴和T轴，环绕方式
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_REPEAT);
    
//    float borderColor[] = { 1.0f, 1.0f, 0.0f, 1.0f };
//    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor);
    //设置纹理过滤
    //缩小时候
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    //切换级别
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    
    //加载图片生成wenli数据
    int width ,height,nrChannels;
    stbi_set_flip_vertically_on_load(isResver);
    GLubyte *data = stbi_load(str, &width, &height, &nrChannels, 0);

    if(data){
        if(nrChannels == 3){
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGB,width,height,0,GL_RGB,GL_UNSIGNED_BYTE,data);
        }else if(nrChannels == 4){
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
        }
        
        glGenerateMipmap(GL_TEXTURE_2D);
    }else{
        std::cout << "Failed to load texture" << std::endl;
        return false;
    }
    
    stbi_image_free(data);
    
    return true;
}
```
这里在读取图片数据的时候，我借助了stbi库去读取，它就是一个头文件，直接引入就能使用了。
设置了环绕类型为GL_REPEAT类型，纹理过滤是GL_LINEAR .
注意了，这里我们需要判断颜色通道，当在颜色通道在3的时候使用RGB，颜色通道为4的时候，使用RGBA，只有正确的设置了颜色通道才能正确的读取到图像数据。


关于颜色通道具体内容，可以看我的OpenCV的教程。能看到为什么Android系统时候的顺序是RGBA的顺序而不是OpenCV的ABGR的顺序，也是因为Android绘制底层使用了OpenGL进行绘制啊。

这里是源码的下半部分：
```cpp
    flushRetriangle(VAO, VBO, EBO);

    
    initTexture(texture[0], "/Users/yjy/Desktop/opengl/container.jpg",false);

    
    if(shader&&shader->isCompileSuccess()){
        
        shader->use();
        
        engine->loop(VAO, VBO, texture, 1,shader, [](Shader* shader,GLuint VAO,

            
            //箱子
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D,texture[0]);

            glBindVertexArray(VAO);
            glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
        });
    }
```

最后再来看看顶点着色器
```cpp
#version 330 core
layout(location = 0)in vec3 aPos;
layout(location = 1)in vec3 aColor;
layout(location = 2)in vec2 aTexCoord;

out vec2 TexCoord;

void main(){
    gl_Position = vec4(aPos,1.0);
    ourColor = aColor;
    TexCoord = aTexCoord;
}

```

还有片元着色器
```cpp
#version 330 core
out vec4 FragColor;
in vec2 TexCoord;
uniform sampler2D ourTexture;
void main(){
    FragColor = texture(ourTexture, TexCoord);
}

```

![image.png](https://upload-images.jianshu.io/upload_images/9880421-895e51b34156c088.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)


这样就能看到结果图了。

### 在箱子上面加一个笑脸，并且添加图片权重

你一定很奇怪为什么sampler2D采样器是一个uniform，我们却不用glUniform给它赋值。

使用glUniform1i，我们可以给纹理采样器分配一个位置值，这样的话我们能够在一个片段着色器中设置多个纹理。一个纹理的位置值通常称为一个纹理单元(Texture Unit)。一个纹理的默认纹理单元是0，它是默认的激活纹理单元，所以教程前面部分我们没有分配一个位置值。

纹理单元的主要目的是让我们在着色器中可以使用多于一个的纹理。通过把纹理单元赋值给采样器，我们可以一次绑定多个纹理，只要我们首先激活对应的纹理单元。就像glBindTexture一样，我们可以使用glActiveTexture激活纹理单元，传入我们需要使用的纹理单元：
```cpp
glActiveTexture(GL_TEXTURE0); // 在绑定纹理之前先激活纹理单元
glBindTexture(GL_TEXTURE_2D, texture);
```

激活纹理单元之后，接下来的glBindTexture函数调用会绑定这个纹理到当前激活的纹理单元，纹理单元GL_TEXTURE0默认总是被激活，所以我们在前面的例子里当我们使用glBindTexture的时候，无需激活任何纹理单元。

> OpenGL至少保证有16个纹理单元供你使用，也就是说你可以激活从GL_TEXTURE0到GL_TEXTRUE15。它们都是按顺序定义的，所以我们也可以通过GL_TEXTURE0 + 8的方式获得GL_TEXTURE8，这在当我们需要循环一些纹理单元的时候会很有用。

因此为了让这个片元着色器可以读取两个纹理数据，此时要在片元着色器多建立一个采样器，并且为其赋值id。并且调用glsl中的mix函数来为两张图片添加权重
```cpp
#version 330 core
out vec4 FragColor;
in vec3 ourColor;
in vec2 TexCoord;

uniform sampler2D ourTexture;
uniform sampler2D ourTexture2;

void main(){
    //mix = mix(x,y,a) = x * (1-a) + y * a
    //箱子 * 0.8 + 笑脸 * 0.2
    FragColor = mix(texture(ourTexture, TexCoord),texture(ourTexture2, TexCoord),0.2);
}
```

```cpp
    initTexture(texture[0], "/Users/yjy/Desktop/opengl/container.jpg",false);
    initTexture(texture[1], "/Users/yjy/Desktop/opengl/awesomeface.png",true);
    
    if(shader&&shader->isCompileSuccess()){
        
        shader->use();
        //设置的是纹理单元
        glUniform1i(glGetUniformLocation(shader->ID,"ourTexture"),0);
        shader->setInt("ourTexture2", 1);
        
        engine->loop(VAO, VBO, texture, 1,shader, [](Shader* shader,GLuint VAO,
                                                     GLuint* texture,GLFWwindow *window){
        
            
            //箱子
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D,texture[0]);
            
            //笑脸
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D,texture[1]);
            glBindVertexArray(VAO);
            glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
        });
    }
```

能够发现，此时采样次的id实际上和glActiveTexture激活的GL_TEXTUREN是一一对应的。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-3e91595b374479eb.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

## 改变纹理范围
当我们尝试这改变整个纹理范围，看看效果如何。
```cpp
float vertices[] = {
        //位置
        // 右上角          //颜色              //纹理
        0.5f, 0.5f, 0.0f,   1.0f,0.0f,0.0f,  2.0f,2.0f,
        // 右下角
        0.5f, -0.5f, 0.0f,  0.0f,1.0f,0.0f,  2.0f,0.0f,
        // 左下角
        -0.5f, -0.5f, 0.0f, 0.0f,0.0f,1.0f,  0.0f,0.0f,
         // 左上角
        -0.5f, 0.5f, 0.0f,  1.0f,1.0f,0.0f,  0.0f,2.0f
    };
```

当超过1的时候：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-6b757845c9faef6f.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

此时将会采用环绕方式，为重复，把这个图片添加到扩大的地方。

当小于1的时候：
```cpp
   //位置
        // 右上角          //颜色              //纹理
        0.5f, 0.5f, 0.0f,   1.0f,0.0f,0.0f,  0.5f,0.5f,
        // 右下角
        0.5f, -0.5f, 0.0f,  0.0f,1.0f,0.0f,  0.5f,0.0f,
        // 左下角
        -0.5f, -0.5f, 0.0f, 0.0f,0.0f,1.0f,  0.0f,0.0f,
         // 左上角
        -0.5f, 0.5f, 0.0f,  1.0f,1.0f,0.0f,  0.0f,0.5f
    };
```
![image.png](https://upload-images.jianshu.io/upload_images/9880421-e99cd92fc000e246.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到此时就是只有图片的四分之一,左下角。

# 总结
当了解了这些差不多，也就对纹理坐标有了初步的认识。下面有一个流程图，可以稍微阐述纹理坐标系，顶点坐标系的关系。
![纹理映射过程.png](https://upload-images.jianshu.io/upload_images/9880421-45235b312c912538.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

可以看见纹理的绘制的过程经历了两次不同的坐标系，这个必须记住了。明白了这个，掌握纹理的基础已经不远了。


























