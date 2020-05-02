---
title: OpenGL(三)矩阵的基本使用
top: false
cover: false
date: 2019-08-17 11:39:15
img:
tag:
description:
author: yjy239
summary:
tags:
- 音视频
- OpenGL
---
# 前言
在就计算机视觉图形学中，矩阵是十分常见的计算单位。那么在OpenGL的学习中，矩阵的运算肯定是必不可少，因此本文将稍微总结一下OpenGL中使用矩阵来完成一些稍微复杂一点效果。

通过前面几篇文章的学习，大致已经明白了OpenGL的基本开发流程。了解OpenGL如何绘制，但是更多复杂的效果不可能通过如此之多的纹理，顶点去完成，我们需要一个更好的工具去处理图片效果，这个工具就是数学上的矩阵和向量。

如果遇到问题可以在这里[https://www.jianshu.com/p/4b7c0d59c87c](https://www.jianshu.com/p/4b7c0d59c87c)找到本人，欢迎讨论


# 正文
我将不会再一次花大量的篇幅重新介绍向量和矩阵，这里仅仅只是把常用的向量和矩阵操作过一遍。

## 向量
向量最基本的定义是一个方向，往哪里走，走到哪里。更加正式的来说，向量包含一个方向一个大小，如下：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-6091b05997c09306.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

这里有三个向量，能看到w，n，v都从各自的起点指向各自的终点，并且能够很轻易的算出其长度。

一个向量可以表示：$\vec{a} = ( \begin{matrix} x\\ y \\z \end{matrix} )$

### 向量的计算

#### 向量加减
向量加减，实际上就是对向量中每个分量进行加减
$( \begin{matrix} 1\\ 2 \\3 \end{matrix} ) + x = ( \begin{matrix} 1+x\\ 2+x \\3+x \end{matrix} )$

向量之间的加：
$(\begin{matrix} 1\\ 2 \\3 \end{matrix} ) + ( \begin{matrix} 4\\ 5 \\ 6 \end{matrix} )  = ( \begin{matrix} 1+4\\ 2+5 \\3+6 \end{matrix} )$

向量之间的加减在几何上意义如下：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-4a22ab27ddbe3266.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

减法可以看成加一个负数：
$( \begin {matrix} 1\\ 2 \\3 \end{matrix} ) + ( \begin{matrix} -4\\ -5 \\- 6 \end{matrix} )  =( \begin{matrix} 1\\ 2 \\3 \end{matrix} ) - ( \begin{matrix} 4\\ 5 \\ 6 \end{matrix} )  = ( \begin{matrix} 1-4\\ 2-5 \\3-6 \end {matrix} )$

### 向量的长度
我们使用勾股定理(Pythagoras Theorem)来获取向量的长度(Length)/大小(Magnitude)。如果你把向量的x与y分量画出来，该向量会和x与y分量为边形成一个三角形：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-7056c3ceead66a35.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

我们可以依据勾股定理把v向量的长度计算出来：
$||v|| = \sqrt{x^{2} + y^2}$



#### 向量的乘法
向量的乘法有两部分，点乘(内积)，叉乘(外积)。

##### 点乘：
$\vec{v} \cdot \vec{k} = ||v|| \cdot  ||k|| \cdot cos\theta$

如果用分量来表示其运算,就是每个分量之间相乘最后相加：
$(\begin{matrix} 1\\ 2 \\3 \end{matrix} ) \cdot ( \begin{matrix} 3\\ 4 \\5 \end{matrix})  = (1*3)+(2*4)+(3*5)$

几何意义：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-9d42b5b108b92d11.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
假设有两个向量a,b.如果这两个向量做点乘：
$\vec{a} \cdot \vec{b} = ||a|| \cdot  (||b|| \cdot cos\theta)$
因为点乘符合乘法交换律：可以扩起后面，能从涂上看到后面括号那部分实际上就是b在a上的投影，也就是上图的$a_{0}$。

所以$a_{0}$和a是一个方向上的，因此将会符合乘法交换律等基础性质。这些不多展开论述。


##### 叉乘：
$\vec{v} \times \vec{k} = ||v|| \times ||k|| \times sin\theta$

如果用分量来计算的就是如下：
假设有向量A和B，从左到右的排开每个向量的分量，每一行代表一个向量:
$|\begin{matrix} x & y & z\\ A_{x} & A_{y} & A_{z} \\ B_{x} & B_{y} & B_{z} \end{matrix} |$

$A \times B = ( \begin{matrix} A_{x}\\ A_{y} \\ A{z} \end{matrix} ) \times ( \begin{matrix} B_{x}\\ B_{y} \\ B_{z} \end{matrix} ) = ( \begin{matrix} A_{y} \times B_{z} - A_{z} \times B_{y} \\ A_{x} \times B_{z} - A{z} \times B_{x} \\ A_{x} \times B_{y} - A_{y} \times B_{x} \end{matrix} )$

实际上，我高中第一次学的时候，感觉不太好记叉乘。其实把上面那个行列式写出来，就很好记住了。计算那一列的数据，就获取另外两列分量，做交叉相乘以及相减。

几何上的意义：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-6bee950211c436b5.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

从上图能够明白实际上向量a叉乘b，就是找一个向量同时垂直于向量a和向量b的向量。实际上这个向量就是垂直于a和b构成的平面。

这里就不再赘述推导过程。

## 矩阵
简单来说矩阵就是一个矩形的数字、符号或表达式数组。矩阵中每一项叫做矩阵的元素.(最初的诞生是为了解决多元方程式)
下面是一个2×3矩阵的例子：
 $$  
  \left[
 \begin{matrix}
   1 & 2 & 3 \\
   4 & 5 & 6 
  \end{matrix}
  \right] 
$$ 
矩阵可以通过(i, j)进行索引，i是行，j是列，这就是上面的矩阵叫做2×3矩阵的原因（3列2行，也叫做矩阵的维度(Dimension)）。这与你在索引2D图像时的(x, y)相反，获取4的索引是(2, 1)（第二行，第一列）（译注：如果是图像索引应该是(1, 2)，先算列，再算行）。

### 矩阵的加减法
矩阵和标量相加
 $$ \left[\begin{matrix}
   1 & 2 & 3 \\
   4 & 5 & 6 
  \end{matrix} \right]  +3 = \left[\begin{matrix}
   1+3 & 2+3 & 3+3 \\
   4+3 & 5+3 & 6+3 
  \end{matrix} \right] $$ 

矩阵之间相加，必须是矩阵行列数相等才能互相相加：
 $$ \left [\begin{matrix}
   1 & 2 & 3 \\
   4 & 5 & 6 
  \end{matrix} \right]  + \left[\begin{matrix}
   1 & 2 & 3 \\
   4 & 5 & 6 
  \end {matrix} \right]  = \left[\begin{matrix}
   1+1 & 2+2 & 3+3 \\
   4+4 & 5+5 & 6+6
  \end{matrix} \right] $$ 

减法也是类似。

### 矩阵的乘法
矩阵乘法分为2部分，数乘和相乘。

#### 数乘
矩阵和标量相乘,矩阵与标量之间的乘法也是矩阵的每一个元素分别乘以该标量
 $$ \left [\begin{matrix}
   1 & 2 & 3 \\
   4 & 5 & 6 
  \end{matrix} \right] \cdot 3 = \left[\begin{matrix}
   1 \cdot 3 & 2 \cdot 3 & 3 \cdot 3 \\
   4 \cdot 3 & 5 \cdot 3 & 6 \cdot3
  \end{matrix} \right] $$ 

现在我们也就能明白为什么这些单独的数字要叫做标量(Scalar)了。简单来说，标量就是用它的值缩放(Scale)矩阵的所有元素

#### 矩阵的乘法
矩阵之间的乘法不见得有多复杂，但的确很难让人适应。矩阵乘法基本上意味着遵照规定好的法则进行相乘。当然，相乘还有一些限制：

1.只有当左侧矩阵的列数与右侧矩阵的行数相等，两个矩阵才能相乘。
2.矩阵相乘不遵守交换律(Commutative)，也就是说A⋅B≠B⋅A。

直接来看矩阵相乘的例子：
 $$ \left[\begin{matrix}
   1 & 2 \\
   3 & 4
  \end{matrix} \right] \cdot \left[\begin{matrix}
   5 & 6  \\
   7 & 8
  \end{matrix} \right]  = \left[\begin{matrix}
   1*5+2*7 & 1*6+2*8 \\
   3*5+4*7 & 3*6+4*8
  \end{matrix} \right] $$ 

![image.png](https://upload-images.jianshu.io/upload_images/9880421-1a81b74cd307518c.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
实际上计算过程就是矩阵的第1个元素就是第一行乘以第一列每个元素积的和。扩展一下就是如下公式：
$(AB)_{ij} = \sum_{k=1}^{p} a_{ik}b_{jk}$

矩阵还有除法也就是矩阵的逆，本文没有涉及，就不多介绍。

### 单位矩阵
实际上就是一个斜对角全是1，其他都是0的矩阵，数学上叫做$I$

在OpenGL中，由于某些原因我们通常使用4×4的变换矩阵，而其中最重要的原因就是大部分的向量都是4分量的
 $$  
  \left[
 \begin{matrix}
   1 & 0 & 0 & 0\\
   0 & 1 & 0 & 0 \\
   0 & 0 & 1 & 0 \\
    0 & 0 & 0 & 1
  \end {matrix}
  \right] 
$$ 
这个矩阵的特性很有趣，任何矩阵乘以单位矩阵都等于原来的矩阵

### 缩放
对一个向量进行缩放(Scaling)就是对向量的长度进行缩放，而保持它的方向不变。由于我们进行的是2维或3维操作，我们可以分别定义一个有2或3个缩放变量的向量，每个变量缩放一个轴(x、y或z)。

假如我们尝试缩放$\vec{v} = (3,2)$,沿着x轴方向缩小0.5倍数，沿着y轴放大2倍。
![image.png](https://upload-images.jianshu.io/upload_images/9880421-08cc392d3b6365a6.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

由于OpenGL通常在3d空间内操作，那么我们只要把z轴缩放设置为1就没有任何影响。

这种x轴和y轴缩放比例不一致的叫做不均匀缩放，而一致称为均匀缩放。实际上这个过程能够通过矩阵去完成。

还记得上面的单位矩阵吧。只要把缩放系数放到矩阵中对应1的位置就能控制对应轴的缩放系数。
 $$  
  \left[
 \begin{matrix}
   Sx & 0 & 0 & 0\\
   0 & Sx & 0 & 0 \\
   0 & 0 & Sz & 0 \\
    0 & 0 & 0 & 1
  \end{matrix}
  \right] \cdot \left[\begin{matrix}
   x  \\
   y  \\ 
  z \\
1
  \end{matrix} \right] = \left[\begin{matrix}
   x \cdot Sx  \\
   y  \cdot Sy \\ 
  z  \cdot Sz \\
1
  \end{matrix} \right]
$$ 

最后一个是w是构造3d模型，透视时候用的。暂时没涉及，就不细说。

### 位移
位移(Translation)是在原始向量的基础上加上另一个向量从而获得一个在不同位置的新向量的过程，从而在位移向量基础上移动了原始向量。我们已经讨论了向量加法，所以这应该不会太陌生。

和缩放矩阵一样，在4×4矩阵上有几个特别的位置用来执行特定的操作，对于位移来说它们是第四列最上面的3个值。如果我们把位移向量表示为(Tx,Ty,Tz)，我们就能把位移矩阵定义为：
 $$  
  \left [
 \begin{matrix}
   1 & 0 & 0 & Tx\\
   0 & 1 & 0 & Ty \\
   0 & 0 & 1 & Tz \\
    0 & 0 & 0 & 1
  \end {matrix}
  \right] \cdot \left[\begin{matrix}
   x  \\
   y  \\ 
  z \\
1
  \end{matrix} \right] = \left[\begin{matrix}
   x +Tx  \\
   y  + Ty \\ 
  z  + Tz \\
1
  \end{matrix} \right]
$$ 

### 旋转
上面几个的变换内容相对容易理解，在2D或3D空间中也容易表示出来，但旋转(Rotation)稍复杂些。

旋转对于刚入门的人来说是比较新鲜的东西。这里稍微写一下旋转的证明，我也花了点时间，证明了一遍，这边也算是一次总结。

#### 引入复数
为了证明旋转，我们会引入复数作为辅助。复数是什么？复数包含两个部分，一个实数部分，一个虚数部分，写法如下：
$z = a + bi$
a是一个实数，bi是一个虚数。i是什么？定义$i^2 = -1$

为什么使用复数来辅助，以前我刚学习的时候不懂。实际上在我们常用的物理学，数学，需要保留二维的信息的时候，往往需要复数来计算，因为复数本身性质决定的，复数本身相加，相乘只允许实数和虚数分开计算，举个例子：
$z1 = a + bi$,$z2 = c + di$
$z1+z2 = (a+b) + (b+d)i$

这样就能保留两个不同的信息了。实际上也像极了向量/矩阵相加。

#### 复数和矩阵的关系
从上面的公式，直觉上告诉我们复数的计算一定和矩阵元算相关，让我们探索一下复数和矩阵之间的关系。就以复数乘法为例子：
$z1 = a + bi$,$z2 = c + di$
$z1 * z2 =ac + adi + cbi + bdi^2 = (ac - bd)+(ad + cb)i$

如果我们把这个结果看成矩阵运算将会是如下一个矩阵运算,把矩阵第一行运算看成实部，第二行运算看成虚部：
$$  
  \left[
 \begin{matrix}
   a & -b \\
   b & a\\ 
  \end{matrix}
  \right] \cdot \left[\begin{matrix}
   c  \\
   d
  \end{matrix} \right]
$$ 

就不难看出，实际上复数的元算就是对 下面这个矩阵做变换运算$$  
  \left[
 \begin{matrix}
   a & -b \\
   b & a\\ 
  \end{matrix}
  \right]
$$ 

### 旋转的证明
先给出一个复数在复平面中表现：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-1bc258a43270a4a9.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

能看到在这个复平面中复数z的表示就是$z = a + bi$，这个向量的长度根据勾股定理很容易就求出来。

我们尝试着对复数的矩阵进行一次变形，目的就是为创造出一个角度和复数之间的关系,把每一项都除以$ / \sqrt{a^2 + b^2}$，提取出可以勾股定理创造出来的角度：
$$  
  \sqrt{a^2 + b^2} \cdot \left[
 \begin{matrix}
   a / \sqrt{a^2 + b^2}& -b / \sqrt{a^2 + b^2} \\
   b / \sqrt{a^2 + b^2} & a / \sqrt{a^2 + b^2}\\ 
  \end{matrix}
  \right] 
$$ 

根据勾股定理，可以把元算中每一项转化如下：
$$  
  \sqrt{a^2 + b^2} \cdot \left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] 
$$ 

很有趣，这样就构建出了角度的关系了。有了这些还不足。

矩阵的左侧还是有冗余的东西，我们想办法干掉它。此时很巧的是，矩阵右侧刚好就是这个复平面向量的模(长度)。

因此可以化简如下：
$$  
  ||z|| \cdot \left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] 
$$ 

又因为单位矩阵I乘以任何矩阵还是原来的矩阵：
$$  
  ||z|| \cdot\left[
 \begin{matrix}
   1 & 0 \\
   0 & 1\\ 
  \end {matrix}
  \right] \cdot\left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end {matrix}
  \right] = \left[
 \begin{matrix}
   ||z|| & 0 \\
   0 & ||z||\\ 
  \end{matrix}
  \right] \cdot\left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] 
$$ 

实际上这个结果就是3d的旋转缩放矩阵。不信？我们试试两个在复平面上的向量(0,1),(1,0)。
$$  
 \left[
 \begin{matrix}
   ||z|| & 0 \\
   0 & ||z||\\ 
  \end{matrix}
  \right] \cdot\left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] \cdot  \left[
 \begin{matrix}
   0  \\
   1 \\ 
  \end{matrix}
  \right] = \left[
 \begin{matrix}
   -||z||sin(\theta)  \\
   ||z||cos(\theta) \\ 
  \end{matrix}
  \right]
$$ 

$$  
 \left[
 \begin{matrix}
   ||z|| & 0 \\
   0 & ||z||\\ 
  \end{matrix}
  \right] \cdot\left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] \cdot  \left[
 \begin{matrix}
   1  \\
   0 \\ 
  \end{matrix}
  \right] = \left[
 \begin{matrix}
   ||z||cos(\theta)  \\
   ||z||sin(\theta) \\ 
  \end{matrix}
  \right]
$$ 

当复平面上的z长度为1时候，如下图：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-7b5bf09356a80a8b.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

因此下面这个矩阵是旋转时候的缩放矩阵：
$$\left[
 \begin{matrix}
   ||z|| & 0 \\
   0 & ||z||\\ 
  \end{matrix}
  \right] $$

下面这个是旋转矩阵：
$$\left[
 \begin{matrix}
   cos(\theta) & -sin(\theta) \\
   sin(\theta) & cos(\theta)\\ 
  \end{matrix}
  \right] $$

用复数表示如下：
$||z||(cos(\theta) - sin(\theta) i)$

那么我们可以由2d往3d推，可以很轻易得到如下三种情况：
当沿着x轴旋转，下面矩阵称为$R_{x}$：
 $$  
  \left[
 \begin{matrix}
   1 & 0 & 0 & 0\\
   0 & cos(\theta) & -sin(\theta)  & 0 \\
   0 & sin(\theta) & cos(\theta) & 0 \\
    0 & 0 & 0 & 1
  \end{matrix}
  \right] \cdot \left[\begin{matrix}
   x  \\
   y  \\ 
  z \\
1
  \end{matrix} \right] = \left[\begin{matrix}
   x   \\
   cosθ⋅y−sinθ⋅z \\ 
  sinθ⋅y+cosθ⋅z\\
1
  \end{matrix} \right]
$$ 

当沿着y轴旋转,下面矩阵称为$R_{y}$：
 $$  
  \left[
 \begin{matrix}
   cos(\theta)  & 0 & -sin(\theta) & 0\\
   0 & 1& 0  & 0 \\
   sin(\theta) & 0 & cos(\theta) & 0 \\
    0 & 0 & 0 & 1
  \end{matrix}
  \right] \cdot \left[\begin{matrix}
   x \\
   y  \\ 
  z \\
1
  \end{matrix} \right] = \left[\begin{matrix}
   cosθ⋅x+sinθ⋅z  \\
   y   \\ 
  −sinθ⋅x+cosθ⋅z \\
1
  \end{matrix} \right]
$$ 

当沿着z轴旋转,下面矩阵称为$R_{z}$：
 $$  
  \left[
 \begin{matrix}
   cos(\theta)  & -sin(\theta) & 0  & 0\\
   sin(\theta)&  cos(\theta)&0& 0 \\
    0 & 0 & 0 & 0 \\
    0 & 0 & 0 & 1
  \end {matrix}
  \right] \cdot \left[\begin{matrix}
   x \\
   y  \\ 
  z \\
1\\
  \end{matrix} \right] = \left[\begin{matrix}
   cosθ⋅x-sinθ⋅y  \\
   sinθ⋅x+cosθ⋅y  \\ 
  z \\
1
  \end{matrix} \right]
$$ 

有了这三个基础矩阵之后，我们可以做任意变化，比如先旋转z轴，再旋转x轴，最后旋转y轴。也就是把这三个矩阵从右到左乘起来,但是又因为可以转为复数，而复数符合乘法交换律，因此先转动哪一个都没问题。

换句话说就是，$R_{复合旋转} = R_{x} \cdot R_{y} \cdot R_{z}$

因此可以得到如下这个复合矩阵：
![image.png](https://upload-images.jianshu.io/upload_images/9880421-9285cd4eca2ba823.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

是不是很讨厌，很麻烦。更麻烦的在后面，这种基于欧拉角变换的旋转很容易就出现了万向节死锁。如果是做游戏动画的人一定对这个不陌生。

使用这种方式连续变换的时候，当出现x,y,z其中两个坐标系在同一水平面时候，另外一个轴的旋转范围就被限制住了。
如下：
![万向节死锁.gif](https://upload-images.jianshu.io/upload_images/9880421-b884fb2872ebb933.gif?imageMogr2/auto-orient/strip)


如何解决呢？这个时候就需要四元数了。本文将不涉及四元数，因此不做更多的详解，后面将会和大家聊聊。不过记住了，上面引入复数进行推到旋转公式的方式将会运用到四元数的推导中。本文先做一个铺垫。


有了这些理论基础之后，我们可以尝试编写代码。
## 实战演练
为了实践上面问题，我们这边继续沿用上一篇文章的笑脸箱子的代码，来实现三种效果，位移，旋转，缩放。

首先，我们要稍微改造一下原来的顶点着色器。开放一个uniform来操作顶点着色器中位置。
```cpp
#version 330 core
layout(location = 0)in vec3 aPos;
layout(location = 1)in vec3 aColor;
layout(location = 2)in vec2 aTexCoord;

out vec3 ourColor;
out vec2 TexCoord;

uniform mat4 transform;

void main(){
    gl_Position = transform*vec4(aPos,1.0);
    ourColor = aColor;
    TexCoord = aTexCoord;
}
```

通过transform乘法来对位置进行一次矩阵变换。因为在GLSL中已经确定好了是mat4.因此在外面也要创造一个4维的矩阵。

#### 操作一
先缩小一半，再绕着z轴90度旋转。
根据上面的公式，无论是位移，旋转还是缩放，我们只需要对着原矩阵依次做矩阵乘法即可。

先准备一个单位矩阵：
```cpp
GLfloat mat4[4][4] = {
            {1.0f,0.0f,0.0f,0.0f},
            {0.0f,1.0f,0.0f,0.0f},
            {0.0f,0.0f,1.0f,0.0f},
            {0.0f,0.0f,0.0f,1.0f}
        };
```

准备一个缩放的矩阵：
```cpp
GLfloat vec3[] = {
            //x    //y    //z
            0.5f,0.5f,1.0f
            
        };
```
根据公式，4维矩阵缩放操作：
```cpp
void scaleMat4(GLfloat dst[4][4],GLfloat src[4][4],GLfloat* vec){
    
    dst[0][0] = src[0][0] * vec[0];
    dst[1][1] = src[1][1] * vec[1];
    dst[2][2] = src[2][2] * vec[3];
    dst[3][3] = src[3][3];

}
```

根据公式的乘积结果，我直接写出沿着z轴旋转的方法
```cpp
void rotationZ(GLfloat dst[4][4],GLfloat src[4][4],double degree){
    double angle = PI * degree / 180.0;
    
    dst[0][0] = src[0][0]*cos(angle) - src[1][0]*sin(angle);
    dst[0][1] = src[0][1]*cos(angle) - src[1][1]*sin(angle);
    dst[0][2] = src[0][2]*cos(angle) - src[1][2]*sin(angle);
    dst[0][3] = src[0][3]*cos(angle) - src[1][3]*sin(angle);
    
    
    dst[1][0] = src[0][0]*sin(angle)  + src[1][0]*cos(angle);
    dst[1][1] = src[0][1]*sin(angle)  + src[1][1]*cos(angle);
    dst[1][2] = src[0][2]*sin(angle)  + src[1][2]*cos(angle);
    dst[1][3] = src[0][3]*sin(angle)  + src[1][3]*cos(angle);
    
    dst[2][0] = src[2][0];
    dst[2][1] = src[2][1];
    dst[2][2] = src[2][2];
    dst[2][3] = src[2][3];
    
    dst[3][0] = src[3][0];
    dst[3][1] = src[3][1];
    dst[3][2] = src[3][2];
    dst[3][3] = src[3][3];
}
```

此时我们在进入渲染loop之前依次调用：
```cpp
        scaleMat4(result,mat4, vec3);
        rotationZ(dst,result,90.0);

        GLuint transformLoc = glGetUniformLocation(shader->ID,"transform");
        glUniformMatrix4fv(transformLoc,1,GL_FALSE,&dst[0][0]);
```
读取uniform，并且把变换之后的矩阵首地址赋值给transform。由于GLSL中也是4维float型矩阵，刚好能够正常解析。

![image.png](https://upload-images.jianshu.io/upload_images/9880421-29e5ff541eb99769.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

这样就能看到了沿着x，y轴缩小了一般，同时沿着z轴顺时针旋转了90度。

其实我这么写旋转还是有问题，因为我直接计算变换后的矩阵，直接赋值。并没有很好的泛用性。每一次都要自己写这么麻烦的矩阵计算，对于开发来说不是很友好。

## glm
还好有一个[glm](https://github.com/g-truc/glm)库，专门辅助计算矩阵，向量。而且全是头文件，不需要编译直接引入即可。稍微阅读了源码，实际上是挺简单的一个库，抽象了mat以及vec类，并且复写里面的操作符。

用法很简单，同样的，我们要引入如下头文件：
```cpp
#include"glm/glm.hpp"
#include "glm/gtc/matrix_transform.hpp"
#include "glm/gtc/type_ptr.hpp"
```

初始化一个4维单位矩阵：
```cpp
glm::mat4 trans = glm::mat4(1.0f);
```

接着做着一样的缩放之后旋转代码：
```cpp
        trans = glm::rotate(trans, glm::radians(90.0f),glm::vec3(0.0,0.0,1.0));
        trans = glm::scale(trans, glm::vec3(0.5f,0.5f,1.0f));
        GLuint transformLoc = glGetUniformLocation(shader->ID,"transform");
        glUniformMatrix4fv(transformLoc,1,GL_FALSE,&trans[0][0]);
```
scale缩放的api需要传入一个向量，分别指的是x,y,z轴分别缩小放大多少，rotate旋转api，需要传递一个旋转的角度以及围绕哪几个轴旋转。

此时是沿着z轴，倍数为1的旋转。缩放为x，y缩小一般，轴不变

这样就有如此结果
![image.png](https://upload-images.jianshu.io/upload_images/9880421-87795e03a6d3b609.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

诶？奇怪了？怎么根据公式计算出来的是相反的呢？一个顺时针旋转了90度，一个逆时针旋转了90度。

让我们翻翻旋转的源码，实际上很简单：
```cpp
template<typename T, qualifier Q>
	GLM_FUNC_QUALIFIER mat<4, 4, T, Q> rotate(mat<4, 4, T, Q> const& m, T angle, vec<3, T, Q> const& v)
	{
		T const a = angle;
		T const c = cos(a);
		T const s = sin(a);

		vec<3, T, Q> axis(normalize(v));
		vec<3, T, Q> temp((T(1) - c) * axis);

		mat<4, 4, T, Q> Rotate;
		Rotate[0][0] = c + temp[0] * axis[0];
		Rotate[0][1] = temp[0] * axis[1] + s * axis[2];
		Rotate[0][2] = temp[0] * axis[2] - s * axis[1];

		Rotate[1][0] = temp[1] * axis[0] - s * axis[2];
		Rotate[1][1] = c + temp[1] * axis[1];
		Rotate[1][2] = temp[1] * axis[2] + s * axis[0];

		Rotate[2][0] = temp[2] * axis[0] + s * axis[1];
		Rotate[2][1] = temp[2] * axis[1] - s * axis[0];
		Rotate[2][2] = c + temp[2] * axis[2];

		mat<4, 4, T, Q> Result;
		Result[0] = m[0] * Rotate[0][0] + m[1] * Rotate[0][1] + m[2] * Rotate[0][2];
		Result[1] = m[0] * Rotate[1][0] + m[1] * Rotate[1][1] + m[2] * Rotate[1][2];
		Result[2] = m[0] * Rotate[2][0] + m[1] * Rotate[2][1] + m[2] * Rotate[2][2];
		Result[3] = m[3];
		return Result;
	}
```

这里面实际上就是上面复合旋转的公式。Rotate实际上是根据当前传进来的向量对复合旋转矩阵处理之后，再通过这个复合旋转矩阵计算结果。

我们注意到一点，所有关于z轴的计算全部从颠倒为负。这样的话，我上面的公式实际上等效glm下面这份代码：
```cpp
trans = glm::rotate(trans, glm::radians(90.0f),glm::vec3(0.0,0.0,-1.0));
```
沿着z轴的负半段进行旋转。

至于为什么这么做，下一篇文章会揭晓。主要是因为在OpenGL是右手坐标，向左边旋转才是在OpenGL的正向旋转方向。

#### 实战演练二
我们尝试着把它转动起来，只需要让uniform读取的数据根据时间变化而变化。
```cpp
        engine->loop(VAO, VBO, texture, 1,shader, [](Shader* shader,GLuint VAO,
                                                     GLuint* texture,GLFWwindow *window){
            

            
            glm::mat4 trans = glm::mat4(1.0f);
            trans = glm::translate(trans, glm::vec3(0.5f,-0.5f,0.0f));
//旋转根据时间来
            trans = glm::rotate(trans, (float)glfwGetTime(), glm::vec3(0.0f,0.0f,1.0f));
            

            GLuint transformLoc = glGetUniformLocation(shader->ID,"transform");
            glUniformMatrix4fv(transformLoc,1,GL_FALSE,glm::value_ptr(trans));
            
            //箱子
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D,texture[0]);
            
            //笑脸
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D,texture[1]);
            glBindVertexArray(VAO);
            glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
            
        });
```
如下：
![旋转笑脸.gif](https://upload-images.jianshu.io/upload_images/9880421-0872a22931ea5cc5.gif?imageMogr2/auto-orient/strip)

如果我们把旋转和位移的顺序变换了，会如何？
```
     glm::mat4 trans = glm::mat4(1.0f);
            trans = glm::rotate(trans, (float)glfwGetTime(), glm::vec3(0.0f,0.0f,1.0f));
            trans = glm::translate(trans, glm::vec3(0.5f,-0.5f,0.0f));
//旋转根据时间来

            

            GLuint transformLoc = glGetUniformLocation(shader->ID,"transform");
            glUniformMatrix4fv(transformLoc,1,GL_FALSE,glm::value_ptr(trans));
```
如下：
![旋转笑脸2.gif](https://upload-images.jianshu.io/upload_images/9880421-f900116d0aa5d65c.gif?imageMogr2/auto-orient/strip)

为什么会这样，原本我们把整个笑脸绘制在原点区域，先位移到左下角再旋转现象和我们料想的一样。

当我们先旋转再移动，实际上矩阵的叉乘本质是一个基变换的过程。基变换是什么东西？本文就不多讨论。我们可以想象旋转矩阵并不是旋转图片本身，而是旋转图片后面的坐标系，构成一个这个图片上所有新的坐标点，在这里就是给整个坐标旋转了90度。

经过基变换后的坐标系再次移动相同方向当然出现完全不一样的。这也是为什么矩阵的乘法，有左右顺序可言。


## 实战演练三
当我们需要花两个不同的笑脸，做不同的行为。比如说另一个笑脸跑到左上角，做缩放。
实际上还是一样对着原来的图片做一次矩阵变换，在调用一次glDrawElements绘制方法。

```cpp
engine->loop(VAO, VBO, texture, 1,shader, [](Shader* shader,GLuint VAO,
                                                     GLuint* texture,GLFWwindow *window){
            
            //            changeMixValue(window);
            //            shader->setFloat("mixValue", mixValue);
            
            glm::mat4 trans = glm::mat4(1.0f);
            trans = glm::translate(trans, glm::vec3(0.5f,-0.5f,0.0f));
            trans = glm::rotate(trans, (float)glfwGetTime(), glm::vec3(0.0f,0.0f,1.0f));
            
            
            
            GLuint transformLoc = glGetUniformLocation(shader->ID,"transform");
            glUniformMatrix4fv(transformLoc,1,GL_FALSE,glm::value_ptr(trans));
            
            //箱子
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D,texture[0]);
            
            //笑脸
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D,texture[1]);
            glBindVertexArray(VAO);
            glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
            
            trans = glm::mat4(1.0f);
            trans = glm::translate(trans, glm::vec3(-0.5f,0.5f,0.0f));
            float scale = sin(glfwGetTime());
            trans = glm::scale(trans, glm::vec3(scale,scale,scale));
            
            glUniformMatrix4fv(transformLoc,1,GL_FALSE,glm::value_ptr(trans));
            glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
            
        });
```
![旋转笑脸3.gif](https://upload-images.jianshu.io/upload_images/9880421-15967066cecbcd38.gif?imageMogr2/auto-orient/strip)

## 总结
本文只是介绍了一部分基础的矩阵变换知识。实际上，要深刻的理解计算机图形学，线性数学是一个很重要的工具。你可以看到我之前写的那一篇人工智能梯度下降推导，矩阵在计算机领域中是一个很基础且通用工具。不求掌握精通，但是至少能够各种熟悉操作，才能让我们的学习更加轻松。

写这篇文章和OpenCV的文章其实比起写Android底层源码分析还要痛苦。哈哈，很多数学工具都丢到爪哇国了。只是下意识知道怎么用，怎么回事，但是真的要提炼成文字，我真的必须翻阅很多数学资料，重新过一遍，证明一遍，才敢写出文章。