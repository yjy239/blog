---
title: OpenGL(四)坐标系
top: false
cover: false
date: 2019-09-26 08:29:07
img:
description:
author: yjy239
summary:
mathjax: true
categories: OpenGL
tags:
- 音视频
- OpenGL
---
# 前言
在前两章，总结有顶点坐标，纹理坐标。实际上在这之上还有更多的坐标。作者经过学习后，在本文总结一番。

上一篇：[OpenGL矩阵](https://www.jianshu.com/p/4b7c0d59c87c)


# 正文
OpenGL希望每一次运行顶点着色器之后，我们所见到的顶点坐标都转化为标准化设备坐标(NDC)。

也就是说，每个顶点的x,y,z都应该在[-1,1]之间，超出这个范围都应该看不见。我们通常会自己设定一个坐标范围，之后顶点着色器中所有的坐标都会转化为标准化设备坐标，然后这些坐标经历光栅器，转化为屏幕上的二维坐标或者像素。

将坐标转化标准化坐标，在转化为屏幕上的坐标都是分步骤来的，中间经历多个坐标系。把物体的坐标变换到几个过渡坐标系，优点在于一些操作就会就会很简单，大致分为如下5个坐标系统：
- 1.局部空间
- 2.世界空间
- 3.观察空间
- 4.裁剪空间
- 5.屏幕空间

为了将坐标从一个坐标系变换到另一个坐标系，我们需要几个变换矩阵来完成这个过程。

分别是模型，观察和投影。我们的顶点坐标起始于局部空间，也称为局部坐标。经过模型变换之后，就变成了世界空间。经过观察变换之后就变成了观察空间，经过投影变换之后就变化为裁剪坐标，最后输出到设备，变成屏幕坐标。

过程如下图：
![OpenGL坐标系.png](/images/OpenGL坐标系.png)

稍微说明一下，对各个变换的理解。

局部坐标就是没有处理，最初的我们传入顶点着色器的坐标。在这个过程我们，可能会存在两种坐标一种叫做顶点坐标，一种是纹理坐标。这个过程我理解为把一个物体构造起来。

世界坐标是经过模型矩阵变化之后的坐标。这过程我是这么理解的，假如有这么一个3D的世界，我们物体已经构建好了，那么接下来就是把这个物体要摆在这个世界的哪里，需要从原点位移多少，旋转的角度等等。

观察坐标，是上面的坐标再一次经过观察矩阵进行变换得来。实际上这个过程，我们可以形象的比喻成，我们的眼睛从哪个方向去看这个世界中的物体。

最后一个裁剪坐标，是经过投影矩阵变换得来。我们可以形象比喻为如下这种状况，我们通过摄像机或者眼睛去观察，往往投影在我们的样子是经过类似投影机生成的图像，生成一个用2d图像代表的3d图像。

如下图，一个无限延伸的铁路，在现实世界中是一个平行的铁轨，在我们的眼睛中是一个在地平线初相交的两条直线。
![平行轨道.png](/images/平行轨道.png)

由投影矩阵创建的观察箱(Viewing Box)被称为平截头体(Frustum)，每个出现在平截头体范围内的坐标都会最终出现在用户的屏幕上。将特定范围内的坐标转化到标准化设备坐标系的过程（而且它很容易被映射到2D观察空间坐标）被称之为投影(Projection)，因为使用投影矩阵能将3D坐标投影(Project)到很容易映射到2D的标准化设备坐标系中。

一旦所有顶点被变换到裁剪空间，最终的操作——透视除法(Perspective Division)将会执行，在这个过程中我们将位置向量的x，y，z分量分别除以向量的齐次w分量；透视除法是将4D裁剪空间坐标变换为3D标准化设备坐标的过程。这一步会在每一个顶点着色器运行的最后被自动执行。

在这一阶段之后，最终的坐标将会被映射到屏幕空间中（使用glViewport中的设定），并被变换成片段。

将观察坐标变换为裁剪坐标的投影矩阵可以为两种不同的形式，每种形式都定义了不同的平截头体。我们可以选择创建一个正射投影矩阵(Orthographic Projection Matrix)或一个透视投影矩阵(Perspective Projection Matrix)。

## 投影矩阵
从上面的小结，我们能够轻松的理解到，世界空间，观察坐标，实际上就是对原来的顶点坐标做一次矩阵左乘操作。但是这个投影矩阵比较特殊，分为 正射投影矩阵以及透视矩阵，这些有研究的价值。

### 正射投影矩阵
正射投影矩阵构成一个立方体平截头，它定义了一个裁剪空间，在这个空间之外的所有顶点都会被裁剪掉。
![正射投影矩阵.png](/images/正射投影矩阵.png)

我们定义这个裁剪的空间的时候，能够定义宽高和远平面以及近平面。任何超出近平面和远平面的坐标都会被裁剪掉。正射平截头把平截头体内部的坐标最后都转化为屏幕坐标，因为每个向量的w分量都没有进行改变；如果w分量等于1.0，透视除法则不会改变这个坐标。

举个形象的例子，我们通过一个笔直的镜头，通过正方形隧道看到远方的物体的正视图，左视图，俯视图等情况。


当初我看到这里的第一反应是，正射投影矩阵是这样的，但是像素点究竟经过什么变换，最后变到哪里，投射到哪里去，对着一切的一切都是蒙蔽。为此，为了弄懂它，实际上我需要对正射投影矩阵证明有一定的了解。

#### 正射投影矩阵证明
我们从上面的定义能够理解到，正射投影矩阵的作用就是把一个物体能够在一个[-1,1]范围内显示出来，我们可以把这个过程看成一次缩放和位移的过程。
![正射投影矩阵证明.png](/images/正射投影矩阵证明.png)

如果灰色的物体就是就是原来的世界坐标中的物体。我们要经过一定的变换的得到把视图容纳到下面这个x,y,z坐标系。


假如我们取立方体其中一面，如果面中的边缘点都能投影到[-1,1]之间。那么这个立方体就能容纳到我们的NDC坐标中。假设立方体一面中如上图有三个如此的点：(l,t,-n),(r,t,-n),(r,b,-n).

为什么我们倒着z轴过来设置点呢？因为OpenGL和DirectX不一样，是一个右手坐标系。
 > 按照惯例，OpenGL是一个右手坐标系。简单来说，就是正x轴在你的右手边，正y轴朝上，而正z轴是朝向后方的。想象你的屏幕处于三个轴的中心，则正z轴穿过你的屏幕朝向你。

定义这个立方体中的某个点$(x_{p},y_{p},z_{p})$投影到到未知的NDC坐标系的$x_{n},y_{n},z_{n}$

我们以X轴上的$x_{p}$为例子进行推导。

对于x轴上的点，已知：$l\leq x_{p} \leq r$
我们稍微做一下变化，为了让立方体内x的点位于[-1,1]：
$0\leq x_{p} - l \leq r - l$ =  $0\leq \frac{x_{p} - l}{r - l}\leq 1$

但是这样还是不够符合我们的范围，大致上只有一半，因此我们还进一步对这个范围做一次变换,先乘以2，再减1：
$(0 \leq \frac{2x_{p} - 2l}{2r - 2l} \leq 2) - 1$ = $-1\leq \frac{2x_{p} - 2l}{2r - 2l} - 1\leq 1$

 =  $-1\leq \frac{2x_{p} }{r - l} + \frac{r+l}{r-l} \leq 1$

这样就能通过乘法和减法，简单的把这个$x_{p}$压缩到[-1,1]之间，也就是说对应到了$x_{n}$

我们可以得到第一个点：$x_{n} = \frac{2x_{p} }{r - l} - \frac{r+l}{r-l} $

同理我们可以得到y轴上的点关系：
$y_{n} =  \frac{2y_{p} }{t - b} - \frac{t+b}{t-b}$

假如立方体，z轴方向,最近是n的距离，最远处是一个f的距离。
$n\leq z_{p} \leq f$

根据OpenGL这个右手坐标，我们需要把物体的z轴投影到NDC的z轴的[-1,1].因此我们可以按照上面的z轴一样做变换。
$ 0<z_{p} - n < f - n $ 

$ (0 < \frac{z_{p} - n}{f - n} < 1) * 2 - 1$ 
= $ 0 < \frac{2z_{p} - 2n}{f - n} < 2  - 1$
= $ -1 < \frac{2z_{p} - n - f}{f - n} < 1 $
= $ -1 < \frac{2z_{p} }{f - n}  - \frac{n + f}{f - n} < 1 $

同理可以得到下面一个等式：
$z_{n} =\frac{2z_{p} }{f - n}  - \frac{n + f}{f - n} $

我们得到几个对应关系之后，我们就能写出如下的正射投影矩阵
> $ \begin{matrix}
   \frac{2 }{r - l}  & 0 & 0 &   - \frac{r+l}{r-l} 
\\\   0 & \frac{2}{t - b}  & 0 & - \frac{t+b}{t-b} 
\\\   0 & 0 & \frac{2}{f - n}  & - \frac{n + f}{f - n}   
\\\   0 & 0 & 0 & 1 
  \end{matrix} $

但是实际上，如果我们的视体是对称的(r = -l,t = -b)，那么我们可以通过这条件，得到一个更加简单的矩阵。
> $ \begin{matrix}
   \frac{1 }{r }  & 0 & 0 &   0 
\\\   0 & \frac{1}{t }  & 0 & 0 
\\\   0 & 0 & \frac{2}{f - n}  & - \frac{n + f}{f - n}   
\\\   0 & 0 & 0 & 1 
  \end{matrix} $

这就是正射投影矩阵来源。这是十分简单的证明过程，接下来透视矩阵会稍微复杂一点点，需要适当的使用一点三角函数。

### 透视投影矩阵
透视投影，实际上就是模拟我们的人眼，能够把3d的映像转化为了2d像素投影在屏幕上，就像上面我举的铁轨例子。

这个投影矩阵将给定的平截头体范围映射到裁剪空间，除此之外还修改了每个顶点坐标的w值，从而使得离观察者越远的顶点坐标w分量越大。被变换到裁剪空间的坐标都会在-w到w的范围之间（任何大于这个范围的坐标都会被裁剪掉）。

OpenGL要求所有可见的坐标都落在-1.0到1.0范围内，作为顶点着色器最后的输出，因此，一旦坐标在裁剪空间内之后，透视除法就会被应用到裁剪空间坐标上:
$out = (\begin{matrix} \frac{x}{w} \\\ \frac{y}{w} \\\ \frac{z}{w} \end {matrix} )$

顶点坐标的每个分量都会除以它的w分量，距离观察者越远顶点坐标就会越小。这是也是w分量非常重要的另一个原因，它能够帮助我们进行透视投影。最后的结果坐标就是处于标准化设备空间中的。

#### 齐次坐标系
这里面涉及到一个新的概念，齐次坐标系。
我们先来理解以下齐次性：
> 一般地，在数学里面，如果一个函数的自变量乘以一个系数，那么这个函数将乘以这个系数的k次方，我们称这个函数为k次齐次函数，也就是：
如果函数 f(v)满足
f(ax)=a^k f(x),
其中，x是输入变量，k是整数，a是非零的实数，则称f(x)是k次齐次函数。
 
比如：一次齐次函数就是线性函数2.多项式函数 f(x,y)=x^2+y^2
因为f(ax,ay)=a^2f(x,y),所以f(x,y)是2次齐次函数。
 
齐次性在数学中描述的是函数的一个倍数的性质。

在理解了齐次性之后，我们就能比较好的理解齐次坐标系。
#### 齐次坐标
在数学里，齐次坐标（homogeneous coordinates），或投影坐标（projective coordinates）是指一个用于投影几何里的坐标系统，如同用于欧氏几何里的笛卡儿坐标一般。

实投影平面可以看作是一个具有额外点的欧氏平面，这些点称之为无穷远点，并被认为是位于一条新的线上（该线称之为无穷远线）。每一个无穷远点对应至一个方向（由一条线之斜率给出），可非正式地定义为一个点自原点朝该方向移动之极限。在欧氏平面里的平行线可看成会在对应其共同方向之无穷远点上相交。给定欧氏平面上的一点 (x, y)，对任意非零实数 Z，三元组 (xZ, yZ, Z) 即称之为该点的齐次坐标。依据定义，将齐次坐标内的数值乘上同一个非零实数，可得到同一点的另一组齐次坐标。例如，笛卡儿坐标上的点 (1,2) 在齐次坐标中即可标示成 (1,2,1) 或 (2,4,2)。原来的笛卡儿坐标可透过将前两个数值除以第三个数值取回。因此，与笛卡儿坐标不同，一个点可以有无限多个齐次坐标表示法。

一条通过原点 (0, 0) 的线之方程可写作 nx + my = 0，其中 n 及 m 不能同时为 0。以参数表示，则能写成 x = mt, y = − nt。令 Z=1/t，则线上的点之笛卡儿坐标可写作 (m/Z, − n/Z)。在齐次坐标下，则写成 (m, − n, Z)。当 t 趋向无限大，亦即点远离原点时，Z 会趋近于 0，而该点的齐次坐标则会变成 (m, −n, 0)。因此，可定义 (m, −n, 0) 为对应 nx + my = 0 这条线之方向的无穷远点之齐次坐标。因为欧氏平面上的每条线都会与透过原点的某一条线平行，且因为平行线会有相同的无穷远点，欧氏平面每条线上的无穷远点都有其齐次坐标。

概括来说：

- 投影平面上的任何点都可以表示成一三元组 (X, Y, Z)，称之为该点的'齐次坐标或投影坐标，其中 X、Y 及 Z 不全为 0。
- 以齐次坐标表表示的点，若该坐标内的数值全乘上一相同非零实数，仍会表示该点。
- 相反地，两个齐次坐标表示同一点，当且仅当其中一个齐次坐标可由另一个齐次坐标乘上一相同非零常数得取得。
- 当 Z 不为 0，则该点表示欧氏平面上的该 (X/Z, Y/Z)。
- 当 Z 为 0，则该点表示一无穷远点。
- 注意，三元组 (0, 0, 0) 不表示任何点。原点表示为 (0, 0, 1)[3]。

#### 齐次坐标系为什么在计算机视觉中运用广泛？
主要有两点：
- 1.区分向量还是点
- 2.更加易于仿射(线性)变换

##### 1.区分向量还是点
（1） 从普通坐标转成齐次坐标时： 
如果（x,y,z）是向量，那么齐次坐标为（x,y,z,0） 
如果（x,y,z）是 3D 点，那么齐次坐标为 （x,y,z,1）

（2） 从齐次坐标转成普通坐标时： 
如果 （x,y,z,1）(3D点)，在普通坐标系下为（x,y,z） 
如果 （x,y,z,0）(向量)，在普通坐标系下为（x,y,z）

这样就能通过w的分量来察觉到是点还是向量

##### 2.更加易于仿射(线性)变换
对于平移,旋转和缩放，都通过矩阵的乘法完成的。在之前的文章我都是默认使用齐次坐标系进行计算。假如我们放弃了齐次坐标系，使用传统的坐标系会如何？

就以最简单的平移为例子。
首先一个矢量来表示空间中的一个点：r=[rx,ry,rz]r=[rx,ry,rz] 
如果我们要将其平移， 平移的矢量为：t=[tx,ty,tz]t=[tx,ty,tz] 
那么正常的做法就是：r+t=[rx+tx,ry+ty,rz+tz]


假如我们不使用齐次坐标系需要一个图像平移，那么我们就需要一个移动矩阵m乘以原来坐标像素矩阵r,办到以下的情况
$t * r = [t_{x} + r_{x},t_{y} + r_{y},t_{z} + r_{z}]$
很可惜，我们无法找到这么一个矩阵。

但是如果我们加多一个维度w，就能找到这么一个矩阵
$\left[ \begin{matrix}
   1 & 0 & 0 &  t_{x} 
\\\   0 & 1  & 0 & t_{y}
\\\   0 & 0 & 1  & t_{z} 
\\\   0 & 0 & 0 & 1 
  \end {matrix} \right]  * [m_{x},m_{y},m_{z},1] = [t_{x}+r_{x},t_{y}+r_{y},t_{z}+r_{z},1]$ 

这就是齐次坐标系的便利。我们就在这个基础上做投影矩阵的推导。

#### 透视投影矩阵的推导
![透视投影矩阵的推导.png](/images/透视投影矩阵的推导.png)

能看到此时的平截头像一个梯形。小的那一面叫做近平面，大的那一面叫做远平面。这个梯形是怎么来的？实际上如下图，就像一个摄像机以一定大小的视角对这个空间的观察：
![透视投影矩阵参数介绍.png](/images/透视投影矩阵参数介绍.png)

能看到整个梯形的平截头，是由一个摄像机，以fov的角度观察世界，摄像机距离外面世界的距离就是摄像机到近平面的距离。远平面就是指我们能够看到最远的地方是哪里，物体摆放的位置超出了远平面，就看不到了。

我们能够根据上面的图，如果原点是我们的视角，从这个视角看出去，就能构成一个三角形。
![DirectX的左手坐标系透视投影图解剖图.png](/images/DirectX的左手坐标系透视投影图解剖图.png)

我们能够轻松的看到，此时刚好以fov的角度构成一个直角三角形。不妨把整个透视投影过程看成：把平截头内的点，投射到近平面上。我们要求的透视投影点，就是上面黑色的点。

我们拆开了x,y轴拆开观察，就如下情况
![OpenGL右手坐标系解剖图.png](/images/OpenGL右手坐标系解剖图.png)

我们就根据这两个图分别对x，y轴的平截头投影到NDC的证明。

老规矩，我们收集一下图中有用的信息。
 - 视角原点到近平面的距离为n,距离远平面为f
- 已知平截头内一点$(x_{e},y_{e},z_{e})$
- 已知视角角度$\theta$
- 求投影点$(x_{n},y_{n},z_{n})$

因为是来自同一个角度，同一个原点的两条射线。因此原点,z轴相交的点(0,0,-n)，$(x_{n},y_{n},z_{n})$构成的三角形A，和原点，$(0,0,-z_{e})$,$(x_{e},y_{e},z_{e})$构成的三角形B是相似三角形。

因此，我们能够得到如下的比例：
$\frac{x_{p}}{x_{e}} = \frac{-n}{z_{e}}$
稍微转化一下：
$ x_{p}= \frac{n*x_{e}}{-z_{e}}$

同理：
$ y_{p}= \frac{n*y_{e}}{-z_{e}}$

能看到，此时的投影后的x和y都依赖于$-z_{e}$.
我们根据齐次坐标系知道如下的等式：
> 裁剪矩阵 = 投影矩阵 * 空间矩阵
$\left[ \begin{matrix}
   x_{clip} 
\\\   y_{clip}  
\\\   z_{clip}     
\\\   w_{clip} 
  \end{matrix} \right]  = M_{projection}  * \left[ \begin{matrix}
   x_{eye} 
\\\   y_{eye}  
\\\   z_{eye}    
\\\   w_{eye} 
  \end {matrix} \right] $ 

> NDC 矩阵 = 裁剪矩阵 / w分量
$\left[ \begin{matrix}
   x_{ndc} 
\\\   y_{ndc}  
 \\\  z_{ndc} 
  \end{matrix} \right]  = \left[ \begin{matrix}
   x_{clip} / w_{clip}
\\\   y_{clip}  / w_{clip}
\\\   z_{clip} / w_{clip} 
  \end {matrix} \right]$

因此，我们为了让空间矩阵可以正确的除以$-z_{e}$。因此我们需要构造如下的矩阵：
![ze矩阵.png](/images/ze矩阵.png)

我们已经推导出了投影矩阵的w分量的参数。让我们继续推导x，y，z上的分量。
根据我们在正射投影推导出来的结果，在透视投影也同样适用。我们同样要把平截头内所有点，都压缩到NDC的[-1,1]之内。因此，正射投影的结论一样能够放到这里来使用。

> 正射投影矩阵中：
$x_{n} = \frac{2x_{p} }{r - l} - \frac{r+l}{r-l} $
$y_{n} =  \frac{2y_{p} }{t - b} - \frac{t+b}{t-b}$

不过这只是简单的做缩放和位移。在透视投影中，平截头内和NDC两个点之间还需要依赖$z_{e}$

$x_{n} = \frac{2*\frac{n*y_{e}}{-z_{e}} }{r - l} - \frac{r+l}{r-l} $

我们可以把它化简为除以w的分量
$x_{n} = \frac{\left( \frac{2n}{r-l} * x_{e} + \frac{r+l}{r-l} *z_{e}  \right)}{-z_{e}} $

$y_{n} = \frac{\left( \frac{2n}{t-b} * y_{e} + \frac{t+b}{t-b} *z_{e}  \right)}{-z_{e}} $

这样我们就能获得透视投影矩阵x,y的分量
$ \left[ \begin{matrix}
   \frac{2n}{r-l} & 0 & \frac{r+l}{r-l} &  0 
\\\   0 & \frac{2n}{t-b}  & \frac{t+b}{t-b} & 0 \\
\\\   . & . & . & .   \\
\\\   0 & 0 & -1 & 0 
  \end{matrix} \right] $

这样，我们就还差z轴的分量还没有求出来。但是我们知道，z轴不依赖x，y轴。因此，我们可以把矩阵写出如下形式：
$ \left[ \begin{matrix}
   \frac{2n}{r-l} & 0 & \frac{r+l}{r-l} &  0 \\
\\\   0 & \frac{2n}{t-b}  & \frac{t+b}{t-b} & 0 \\
\\\   0 & 0 & A & B   \\
\\\   0 & 0 & -1 & 0 
  \end{matrix} \right] $

就可以写出如下等式：
$z_{n} = \frac{A*z_{e}+B}{-z_{e}}$ 

但是我们根据定义，能够知道这个$z_{n}$坐标将会压缩在[-1,1]的区间。换句话说我们带入$(0,0,-n),(0,0,-f)$必定对应上-1和1之间。

2个未知数，两个连立方程式，必定有解。
$\frac{-A*n+B}{n} = -1$
$\frac{-A*f+B}{f} = 1$

求解A，B：
$A =- \frac{f+n}{f-n}$
$B =- \frac{2n}{f-n} $

此时我们就完成了透视投影矩阵的推导：
> $ \left[ \begin{matrix}
   \frac{2n}{r-l} & 0 & \frac{r+l}{r-l} &  0 \\
\\\   0 & \frac{2n}{t-b}  & \frac{t+b}{t-b} & 0 \\
\\\   0 & 0 & -\frac{f+n}{f-n} & - \frac{2n}{f-n}   \\
\\\   0 & 0 & -1 & 0 
  \end{matrix} \right] $

同样的，如果视体是对称的，我们一样可以获得一个简化的矩阵
> $ \left[ \begin{matrix}
   \frac{n}{r} & 0 & 0 &  0 \\
\\\   0 & \frac{n}{t}  & 0 & 0 \\
\\\   0 & 0 & - \frac{f+n}{f-n} & - \frac{2n}{f-n}   \\
\\\   0 & 0 & -1 & 0 
  \end {matrix} \right] $

这样就把正射投影矩阵和透视投影矩阵证明完毕。

## 实战演练

### 从世界空间某个角度观察图片
那么我们开发中是不是要这么麻烦的处理编写投影矩阵呢？实际上glm已经已经提供了相关的函数了：
正射投影：
```cpp
glm::ortho(0.0f, 800.0f, 0.0f, 600.0f, 0.1f, 100.0f);
```
前两个参数指定了平截头体的左右坐标，第三和第四参数指定了平截头体的底部和顶部。通过这四个参数我们定义了近平面和远平面的大小，然后第五和第六个参数则定义了近平面和远平面的距离。这个投影矩阵会将处于这些x，y，z值范围内的坐标变换为标准化设备坐标。

透视投影矩阵：
```cpp
glm::mat4 proj = glm::perspective(glm::radians(45.0f), (float)width/(float)height, 0.1f, 100.0f);
```

它的第一个参数定义了fov的值，它表示的是视野(Field of View)，并且设置了观察空间的大小。如果想要一个真实的观察效果，它的值通常设置为45.0f，但想要一个末日风格的结果你可以将其设置一个更大的值。第二个参数设置了宽高比，由视口的宽除以高所得。第三和第四个参数设置了平截头体的近和远平面。我们通常设置近距离为0.1f，而远距离设为100.0f。所有在近平面和远平面内且处于平截头体内的顶点都会被渲染。

如果我们把摄像机放到z轴上方，看一个在世界坐标上，沿着x轴做向上反转-55度的笑脸箱子，该如何处理？

我们继续沿用上一期的代码，做一定的修改

首先编写对应的顶点着色器
```cpp
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aTexCoord;

out vec2 TexCoord;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

void main(){
    gl_Position =  projection * view * model * vec4(aPos,1.0);
    
    TexCoord = vec2(aTexCoord.x,aTexCoord.y);
}
```

设定好之后，我们去处理世界空间，观察者空间，投影空间的矩阵：
```cpp
        shader->use();
        //设置的是纹理单元
        glUniform1i(glGetUniformLocation(shader->ID,"ourTexture"),0);
        shader->setInt("ourTexture2", 1);

        //模型矩阵
        //物体坐标变换到世界坐标
        //把它从局部坐标，摆到世界中，是沿着x轴旋转-55度
        glm::mat4 model = glm::mat4(1.0f);
        model = glm::rotate(model, glm::radians(-55.0f), glm::vec3(1.0f,0.0f,0.0f));
        //观察矩阵
        //观察的位置的移动
        //从世界坐标到观察空间
        //模拟我们摄像机，沿着z轴向后移3个单位
        glm::mat4 view = glm::mat4(1.0f);
        view = glm::translate(view, glm::vec3(0.0,0.0,-3.0f));

        //投影矩阵
        //观察到裁剪空间
        glm::mat4 projection = glm::mat4(1.0f);
        projection = glm::perspective(glm::radians(45.0f),
                                      ((float)engine->screenWidth)/((float)engine->screenHeight), 0.1f, 100.0f);

        GLuint modelLoc = glGetUniformLocation(shader->ID,"model");
        glUniformMatrix4fv(modelLoc,1,GL_FALSE,&model[0][0]);

        GLuint viewLoc = glGetUniformLocation(shader->ID,"view");
        glUniformMatrix4fv(viewLoc,1,GL_FALSE,&view[0][0]);

        GLuint projectionLoc = glGetUniformLocation(shader->ID,"projection");
        glUniformMatrix4fv(projectionLoc,1,GL_FALSE,&projection[0][0]);


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

![投影矩阵下的图片.png](/images/投影矩阵下的图片.png)

### 从世界空间观察某个3d物体。
我们先通过36点顶点坐标构造一个立方体：
```cpp
void create3D(GLuint& VAO,GLuint& VBO){
    float vertices[] = {
        -0.5f, -0.5f, -0.5f,  0.0f, 0.0f,
        0.5f, -0.5f, -0.5f,  1.0f, 0.0f,
        0.5f,  0.5f, -0.5f,  1.0f, 1.0f,
        0.5f,  0.5f, -0.5f,  1.0f, 1.0f,
        -0.5f,  0.5f, -0.5f,  0.0f, 1.0f,
        -0.5f, -0.5f, -0.5f,  0.0f, 0.0f,
        
        -0.5f, -0.5f,  0.5f,  0.0f, 0.0f,
        0.5f, -0.5f,  0.5f,  1.0f, 0.0f,
        0.5f,  0.5f,  0.5f,  1.0f, 1.0f,
        0.5f,  0.5f,  0.5f,  1.0f, 1.0f,
        -0.5f,  0.5f,  0.5f,  0.0f, 1.0f,
        -0.5f, -0.5f,  0.5f,  0.0f, 0.0f,
        
        -0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        -0.5f,  0.5f, -0.5f,  1.0f, 1.0f,
        -0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        -0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        -0.5f, -0.5f,  0.5f,  0.0f, 0.0f,
        -0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        
        0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        0.5f,  0.5f, -0.5f,  1.0f, 1.0f,
        0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        0.5f, -0.5f,  0.5f,  0.0f, 0.0f,
        0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        
        -0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        0.5f, -0.5f, -0.5f,  1.0f, 1.0f,
        0.5f, -0.5f,  0.5f,  1.0f, 0.0f,
        0.5f, -0.5f,  0.5f,  1.0f, 0.0f,
        -0.5f, -0.5f,  0.5f,  0.0f, 0.0f,
        -0.5f, -0.5f, -0.5f,  0.0f, 1.0f,
        
        -0.5f,  0.5f, -0.5f,  0.0f, 1.0f,
        0.5f,  0.5f, -0.5f,  1.0f, 1.0f,
        0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        0.5f,  0.5f,  0.5f,  1.0f, 0.0f,
        -0.5f,  0.5f,  0.5f,  0.0f, 0.0f,
        -0.5f,  0.5f, -0.5f,  0.0f, 1.0f
    };
    
    glGenVertexArrays(1,&VAO);
    glBindVertexArray(VAO);
    
    glGenBuffers(1,&VBO);
    glBindBuffer(GL_ARRAY_BUFFER,VBO);
    
    glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,5*sizeof(float),(void*)0);
    glEnableVertexAttribArray(0);
    
    glVertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,5*sizeof(float),(void*)(3*sizeof(float)));
    glEnableVertexAttribArray(1);
    
    //glBindVertexArray(0);
    
}

```

紧接着绘制：
```cpp
void showOneCube(Shader *shader){
    //模型矩阵
    //物体坐标变换到世界坐标
    //把它从局部坐标，摆到世界中，是沿着x轴旋转90度
    glm::mat4 model = glm::mat4(1.0f);
    model = glm::rotate(model, glm::radians(90.0f), glm::vec3(0.5f,1.0f,0.0f));
    //观察矩阵
    //观察的位置的移动
    //从世界坐标到观察空间
    //模拟我们摄像机，沿着z轴向后移3个单位
    glm::mat4 view = glm::mat4(1.0f);
    view = glm::translate(view, glm::vec3(0.0,0.0,-3.0f));
    
    //投影矩阵
    //观察到裁剪空间
    glm::mat4 projection = glm::mat4(1.0f);
    projection = glm::perspective(glm::radians(45.0f),
                                  (width/height), 0.1f, 100.0f);
    
    //            GLuint modelLoc = glGetUniformLocation(shader->ID,"model");
    //            glUniformMatrix4fv(modelLoc,1,GL_FALSE,&model[0][0]);
    shader->setMat4("model", &model[0][0]);
    
    //            GLuint viewLoc = glGetUniformLocation(shader->ID,"view");
    //            glUniformMatrix4fv(viewLoc,1,GL_FALSE,&view[0][0]);
    
    shader->setMat4("view", &view[0][0]);
    
    shader->setMat4("projection", &projection[0][0]);
    
    //            GLuint projectionLoc = glGetUniformLocation(shader->ID,"projection");
    //            glUniformMatrix4fv(projectionLoc,1,GL_FALSE,&projection[0][0]);
}
```
```cpp
if(shader&&shader->isCompileSuccess()){

        shader->use();
        //设置的是纹理单元
        glUniform1i(glGetUniformLocation(shader->ID,"ourTexture"),0);
        shader->setInt("ourTexture2", 1);


        width = (float)engine->screenWidth;
        height = (float)engine->screenHeight;

        glEnable(GL_DEPTH_TEST);

        engine->loop(VAO, VBO, texture, 1,shader, [](Shader* shader,GLuint VAO,
                                                     GLuint* texture,GLFWwindow *window){


            //箱子
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D,texture[0]);

            //笑脸
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D,texture[1]);



            showOneCube(shader);

            //showMoreCube(shader);

            glBindVertexArray(VAO);
            glDrawArrays(GL_TRIANGLES, 0, 36);


        });
    }
```

![笑脸立方体.png](/images/笑脸立方体.png)

### 绘制更多的立方体并且转动起来
如果我们需要让3的倍数的立方体旋转起来又如何？

我们需要更多的世界坐标来设置立方体：
```cpp
float width = 0;
float height = 0;
//世界坐标
glm::vec3 cubePositions[] = {
    glm::vec3( 0.0f,  0.0f,  0.0f),
    glm::vec3( 2.0f,  5.0f, -15.0f),
    glm::vec3(-1.5f, -2.2f, -2.5f),
    glm::vec3(-3.8f, -2.0f, -12.3f),
    glm::vec3( 2.4f, -0.4f, -3.5f),
    glm::vec3(-1.7f,  3.0f, -7.5f),
    glm::vec3( 1.3f, -2.0f, -2.5f),
    glm::vec3( 1.5f,  2.0f, -2.5f),
    glm::vec3( 1.5f,  0.2f, -1.5f),
    glm::vec3(-1.3f,  1.0f, -1.5f)
};
```

循环绘制：
```cpp
void showMoreCube(Shader *shader){
    glm::mat4 view = glm::mat4(1.0f);
    glm::mat4 projection = glm::mat4(1.0f);
    
    view = glm::translate(view, glm::vec3(0.0,0.0,-3.0f));
    projection = glm::perspective(glm::radians(45.0f),
                                  (width/height), 0.1f, 100.0f);
    
    shader->setMat4("view", glm::value_ptr(view));
    shader->setMat4("projection", glm::value_ptr(projection));
    
    for(int i = 0;i<10;i++){
        glm::mat4 model = glm::mat4(1.0f);
        
        
        model = glm::translate(model, cubePositions[i]);
        float angle = 20.0f * i;
        if(i % 3 == 0){
            model = glm::rotate(model, (float)glfwGetTime(), glm::vec3(1.0f,3.0f,0.5f));
        }else{
            model = glm::rotate(model, angle, glm::vec3(1.0f,3.0f,0.5f));
        }
        
        shader->setMat4("model", glm::value_ptr(model));
        
        glDrawArrays(GL_TRIANGLES,0,36);
    }
}
```

![世界中的旋转立方体.gif](images/世界中的旋转立方体.gif)


## 总结
OpenGL的有5个坐标系，局部空间，世界空间，观察空间，裁剪空间，屏幕空间。

我们能够通过如下的公式来对一个在局部空间中用顶点坐标构建的物体做变换到一个从摄像机角度观察的世界中的物体：
$M_{clip} = M_{projection} * M_{view} * M_{model} *M_{local}$

当我们要从裁剪坐标换算到NDC坐标，要符合如下公式：
$\left[ \begin{matrix}
   x_{ndc} \\
   y_{ndc}  \\
   z_{ndc} \\
  \end {matrix} \right]  = \left[ \begin{matrix}
   x_{clip} / w_{clip} \\
   y_{clip}  / w_{clip} \\
   z_{clip} / w_{clip} \\
  \end{matrix}\right]$

实际上这就是所有坐标之间的关系。