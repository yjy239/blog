---
title: OpenGL学习(二) GLSL语言基础
top: false
cover: false
date: 2019-07-16 00:02:08
img:
tag:
description:
author: yjy239
summary:
tags:
- OpenGL
- 音视频
---
# 前言
我们对顶点数组对象(VAO)和顶点缓存对象(VBO)有了初步的印象之后。我们可以继续接触另一个OpenGL有趣的模块，GLSL语言。正是有了这门语言，才能在复杂的图形编程中，做了不少简化。

如果遇到问题请在这个地址找本人：[https://www.jianshu.com/p/9267e7b8640f](https://www.jianshu.com/p/9267e7b8640f)


# 正文
接着上一篇文章，在聊GLSL之前，先介绍一个常用的工具。我们不可能每一次都在一个字符串中编写一个GLSL的代码。我们需要更加好用的工具，让开发更加接近我们正常的编写手段。

## Shader的设计
实际上，在我们的编写OpenGL过程中，发现有很多共性。为什么我们不把他抽象成一个类去处理呢？

我们这一次，需要一个类去控制整个着色器编译流程。要控制其着色器程序读取文件中的字符串,还有一个标志位，用来判断是否已经编译成功，能够使用。

因为在OpenGL中，顶点着色器和片元着色器必须存在。因此作为构造函数穿进去。后续就会继续丰富这个类，加入更多的着色器。

Shader.hpp
```cpp
class Shader{
public:
    unsigned int ID;
    bool isSuccess = false;
    const char* mVertexPath;
    const char* mFragmentPath;
    
public:
    Shader(const char* vertexPath,const char* fragmentPath);
    void compile();
    void use();
    
    inline bool isCompileSuccess() const{
        return isSuccess;
    }
    ~Shader();
    
private:
    bool checkComplieErrors(unsigned int shader,std::string type);
};
```

我们需要一个编译所有传到Shader中的GLSL文件compile方法。其次还需要一个使用着色器程序的方法，以及一个判断当前编译是否正常的方法。以及一个私有的打印异常的方法。

## Shader的实现
首先实现构造函数。
```cpp
Shader::Shader(const char* vertexPath,const char* fragmentPath){
    mVertexPath = vertexPath;
    mFragmentPath = fragmentPath;
}
```

接着实现编译流程,我们需要读取从文件中读取字符串上来并且编译
```cpp
void Shader:: compile(){
    if(!mVertexPath || !mFragmentPath){
        cout<< "Error::Shader::please set file Path";
        return;
    }
    
    string vertexCode;
    string fragmentCode;
    ifstream vShaderFile;
    ifstream fShaderFile;
    
    vShaderFile.exceptions(ifstream::failbit | ifstream::badbit);
    fShaderFile.exceptions(ifstream::failbit | ifstream::badbit);
    
    try{
        vShaderFile.open(mVertexPath);
        fShaderFile.open(mFragmentPath);
        
        stringstream vShaderStream,fShaderStream;
        vShaderStream <<vShaderFile.rdbuf();
        fShaderStream << fShaderFile.rdbuf();
        
        vertexCode =vShaderStream.str();
        fragmentCode = fShaderStream.str();
        
        
    }catch(ifstream::failure e){
        cout<< "Error::Shader::file loaded fail";
    }
    
    if(vertexCode.empty()|| fragmentCode.empty()){
        return;
    }
    
    const char* vShaderCode = vertexCode.c_str();
    const char* fShaderCode =fragmentCode.c_str();
    
    GLuint vertexShader;
    //创建一个着色器类型
    vertexShader = glCreateShader(GL_VERTEX_SHADER);
    //把代码复制进着色器中
    glShaderSource(vertexShader, 1, &vShaderCode, NULL);
    //编译顶点着色器
    glCompileShader(vertexShader);
    
    //判断是否编译成功
    if(!checkComplieErrors(vertexShader, "VERTEX")){
        return;
    }
    
    ///下一个阶段是片段着色器
   
    GLuint fragmentShader;
    fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
    
    glShaderSource(fragmentShader, 1, &fShaderCode, NULL);
    
    glCompileShader(fragmentShader);
    
    if(!checkComplieErrors(fragmentShader, "Fragment")){
        return;
    }
    
    
    //链接，创建一个程序
    
    ID = glCreateProgram();
    
    //链接
    glAttachShader(ID, vertexShader);
    glAttachShader(ID, fragmentShader);
    glLinkProgram(ID);
    
    if(!checkComplieErrors(ID, "PROGRAM")){
        return;
    }
    
    //编译好了之后，删除着色器
    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);
    
    
    isSuccess = true;
}
```

我们这边继续按照原来的编译着色器程序的流程。每个着色器的都需要经历三个步骤，创建，代码拷贝，编译的顺序。最后把所有的着色器都绑定到着色器程序上，并且链接起来。完成之后，需要删除着色器。

异常警报提示如下：
```
bool Shader::checkComplieErrors(unsigned int shader, std::string type){
    int success;
    char infoLog[1024];
    if (type != "PROGRAM")
    {
        glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
        if (!success)
        {
            glGetShaderInfoLog(shader, 1024, NULL, infoLog);
            std::cout << "ERROR::SHADER_COMPILATION_ERROR of type: " << type << "\n" << infoLog << "\n -- --------------------------------------------------- -- " << std::endl;
            isSuccess = false;
            return false;
        }
    }else{
        glGetProgramiv(shader, GL_LINK_STATUS, &success);
        if (!success)
        {
            glGetProgramInfoLog(shader, 1024, NULL, infoLog);
            std::cout << "ERROR::PROGRAM_LINKING_ERROR of type: " << type << "\n" << infoLog << "\n -- --------------------------------------------------- -- " << std::endl;
            isSuccess = false;
            return false;
        }
    }
    
    return true;
}
```
这样就能完成了Shader的基础编译功能。

最后再提供一个use的方法，使用里面的着色器程序
```cpp
void Shader:: use(){
    glUseProgram(ID);
}
```

通过这种方式，我们就能把冗余的代码简化到如下这种情况：
```
Shader *shader = new Shader(vPath,fPath);
    shader->compile();
    if(shader&&shader->isCompileSuccess()){
        loop(window,VAO,VBO,shader);
    }
```

## GLSL的介绍
有了上面的工具之后，我们就能把注意力集中到编写GLSL的语言中。让我们介绍一下GLSL。

### GLSL基础类型
先介绍GLSL的支持的基础类型
![GLSL的支持的基础类型.png](/images/GLSL的支持的基础类型.png)

能看到除了支持我们常用的几种基本类型，OpenGL的GLSL语言本身就支持向量和矩阵。GPU这种设计比起CPU来说优势太大了。因为在图形学中矩阵可以说是极其基本的操作单位。

在这里面，我们能够看到一些OpenGL的设计。*vec(n)是指向量，向量中的*是什么类型的数据通过前缀i/u/b/d来确定，默认是float类型；向量中的n是指这个向量是的分量是多少。

同理在矩阵也是一样*mat(m)*(n)，前缀确定了矩阵中的数据是什么类型，而M*N是指这是一个怎么样的行列矩阵。

基本类型和C中用法差不多，这里说一下在GLSL中矩阵的操作:
```cpp
      vec3 v = vec3(0.0,2.0,3.0);
     ivec3 s = ivec3(v);
     
     
     vec4 color;
     vec3 rgb = vec3(color);//这样就能截断前三个数据
```

这里有这么一个规律，当分量更多的向量赋值给更加少的向量赋值的时候，其行为就和我们写c语言时候，int往char转化一样，丢失位数。通过这种做法能够获取截断的数据。

向量的赋值也很自由：
```cpp
     vec3 white = vec3(1.0);//white = (1.0,1.0,1.0)
     vec4 t = vec3(white,0.5);//(1.0,1.0,1.0,0.5)
```
能够任意的传入向量到另一个向量，从而做到赋值或者添加新的变量。当传入单一值的时候，就会默认让向量中所有的值都是一致。

矩阵的设置：
```cpp
     //相当于为对角赋值4.0
     m =  mat3(4.0) = (4.0,0,0
                       0,4.0,0
                       0,0,4.0)
     
     mat3 M = mat3(1.0,2.0,3.0,
                    4.0,5.0,6.0,
                    7.0,8.0,9.0);
   
     
```

我们设置矩阵的时候可以设置单一的值，这样就能设置矩阵的一条对角线上所有的值。

```cpp
     vec3 c1 = vec3(1.0,2.0,3.0);
     vec3 c2 = vec3(4.0,5.0,6.0);
     vec3 c3 = vec3(7.0,8.0,9.0);
     mat3 M = mat3(c1,c2,c3);
     
     vec2 c1 = vec2(1.0,2.0);
     vec2 c2 = vec2(4.0,5.0);
     vec2 c3 = vec2(7.0,8.0);
     
     mat3 M = mat3(c1,3.0,
                    c2,6.0,
                    c3,9.0);
     
     先设置列，在设置行
     这些结果都是矩阵：(1.0 4.0 7.0
                     2.0 5.0 8.0
                    3.0 4.0 9.0)
```
OpenGL中还能通过几个向量组成一个mat矩阵。不过，其设置的顺序是按照列的顺序竖直的向后摆放。也就是按照顺序设置行列式中的列。


当然，向量的分量或者矩阵，都可以看成一段特殊数组，可以通过[]和.访问到每个分量。
实际上为了便于分辨每个向量的作用，因此将每个每个位置设置为：
![分量的介绍.png](/images/分量的介绍.png)

```
 vec3 l = color.rrr
 这样相当于取了3次r位置
 
 color = color.abgr//反转每个color位置
 
 但是 vec2 pos;
 float zPos = pos.z;//2d不存在z
 
 还能如此：
 mat4 m = mat4(2.0);
 vec4 = z = m[2];  //这样就能获得4*4矩阵的第二列
 
 float y = m[1][1].这样能获得第一列第一行的数据。

```

能够看到的是，这种方式其实和Octave和Matlab十分相似。

当然还能构造结构体,并且用“.”访问里面的属性
```cpp
struct pos{
  vec3 pos;
  vec3 v;
  float life;
};

pos p = pos(pos,v,10.0);
```

## 数组
```cpp
float c[3];//3个float数组
float[3] c;
int i[];//为定义数组维度，可以稍后定义。

for(int i = 0;i < c.length;i++){
    c[i] *= 2.0;
}


同理，我们可以把矩阵看成n*n维度的数组
因此：
mat3x4 m;
int c = m.length();
int r = m[0].length();//获取第一列的长度

mat4 m;
float d[m.length()];//设置长度为矩阵大小。

float x[gl_in.length()].设置数组大小为顶点数组大小
```
实际上数组还是和Java语言中的差不多。

## 存储限制符
存储限制符是十分重要的一个概念，其控制了变量的作用。其中uniform尤为的重要。

- const 让一个变量变成只读。如果初始化是编译时常量，那么本身就是编译时常量。

- in 设置这个变量为着色器阶段的输入变量

- out 设置这个变量为着色器阶段输出变量

- uniform 设置这个变量为用户应用传递给着色器数据，他对于给定的图元而言，是一个常量。uniform变量在所有可用的着色阶段之间共享，必须定义为全局变量。任何变量的变量都可以是uniform变量。着色器无法写入，也无法改变。
```
uniform vrc4 color;
```
在着色器中，可以根据名字color来引用这个变量，但如果需要在用户应用中设置他的值，需要一些工作。

GLSL编译器会在链接着色器程序时创建一个uniform变量表。如果需要设置应用程序中的color值，首先获得color在列表中的索引，通过下面这个这个函数完成。
```
GLuint glGetuniformLocation(GLuint program,const char* name)

返回着色器程序中uniform变量name对应的索引值。name是一个以NULL结尾的字符串，不存在空格。如果name与启用的着色器程序所有的uniform都不相符或者name是一个内部保留的变色齐变量名称，则返回-1.

name 可以是单一变量名称，数组一个元素，或者结构体中一个域变量。

对于uniform变量数组，也可以只通过制定数组的名称来获取数组的第一个元素。

除非重新链接程序，不然这里的返回值不会变。

```

得到uniform变量对应索引值之后，我们可以通过glUnform*()或者glUniformMatrix*()系列函数来设置uniform变量值。

例子：
```cpp
//GLSL中：
float time;

//opengl编程中：
GLint timeLoc;
GLfloat timevalue;
int timeLoc = glGetUniformLocation(program,"time");
glUniform(timeLoc,timevalue);
```

### 获取以及写入 uniform

> void glUniform{1234}{fdi ui}(GLint location,TYPE value);

> void glUniform{1234}{fdi ui}v (GLint location,GLsizei count,TYPE value);

> void glUniformMatrix{234}{fdi ui}v (GLint location,GLsizei count,GLboolean transpose,GLfloat *value);

> void glUniformMatrix{2x2,2x4,3x2,3x4,4x2,4x3}{fdi ui}v (GLint location,GLsizei count,GLboolean transpose,GLfloat *value);

设置与location索引位置对应的uniform变量的值。其中向量形式的函数会载入count个数据的集合，并写入location位置的uniform变量。如果location是数组的起始索引，那么数组之后的连续count会被载入。

GLfloat形式的函数，可以载入但精度或者双精度的。

tranpose设置为GL_TRUE，那么values中的数据是以行顺序读入，否则按照行。


- buffer 和uniform很相似，设置应用共享一块可读写的内存，成为着色器的存储缓存

- shared 设置变量时本地工作组中共享，只能用于计算着色器。

##### 可以看到uniform和buffer都是OpenGL中GLSL语言和我们在CPU编程的程序传递数据的接口，十分重要。

# 控制流
和普遍的语言一模一样

但是多了discard终止着色器程序执行。

# 参数限制符
尽管GLSL中函数可以在运行之后修改和返回数据。但是它与C中不一样，没有引用和指针。不过与之对应，此时函数参数可以制定一个参数限定符号，来表明它是否需要在函数运行时将数据拷贝到函数，或者从函数中返回修改的数据。

![参数限制符.png](/images/参数限制符.png)


如果我们写出到一个没有设置上述修饰符的变量，会产生编译时错误。

如果我们需要在编译时验证函数是否修改了某个输入变量，可以使用const in类型变量来组织函数对变量进行写操作。不这么做，那么在函数中写入一个in类型的变量，相当于变量的局部拷贝进行了修改，因此只在函数自身范围内产生作用。

# 计算不变性

很有趣的是，glsl无法保证在不同着色器中，两个完全相同的计算世会得到完全一样的结果。这个情形与cpu端应用进行计算问题相同，即不同优化的方式会导致结果非常细微的差异。

为了确定不变性有两个关键字：
- invariant
- precise

这两个方法都需要在图形设备上完成计算过程，来确保同一表达式的结果可以保证重复性。但是，对于宿主计算机和图形硬件格子计算，这两个方法无法保证结果完全一致。

着色器编译时的常量表达式是由编译器的宿主计算机计算的，因此我们无法保证宿主计算机计算的结果与图形硬件的结果完全相同。

```cpp
uniform float ten;//假设应用程序设置这个值为10.0
const float f = sin(10.0);//宿主编译器负责计算
float g = sin(ten); //图形硬件负责计算
void main(){
    if(g == f){
        //这两个不一定相等
    }
}
```

## invariant

invariant限制符可以设置任何着色器的输出变量。他可以确保两个着色器的输出变量使用了同样的表达式，并且表达式变量也是相同，计算结果也是相同。

```cpp
invariant gl_Position;
invariant centroid out vec3 Color;
```
输出变量作用是将一个着色器的数据从一个阶段传递到下一个。可以在着色器用到某个变量或者内置变量之前的任何位置，对该变量设置关键字invariant。

在调试过程中可能需要全部变量编程invariant
```cpp
#pragma STDGL invariant(all)
```
但是这样对于着色器也会有所影响。

## precise
precise 限制符可以设置任何计算中的变量或者函数的返回值。不是增加精确度，而是增加计算的可复用。

我们通常在细分着色器用它避免几何形状的裂缝。

总体来说，如果必须保证某个表达式产生结果是一致的，即使表达式中的数据发生了变化也是如此，那么此时我们此时应该用precise而非invariant。

下面a和b的值发生交换，得到的结果也是不变。
此外即使c和d的值发生变换，或者a和c同时与b和d发生交换，也要计算相同结果。
```cpp
Location = a * b + c *d;

precise可以设置内置变量，用户变量或者函数的返回值。

precise gl_Position;
precise out vec3 Location;
precise vec3 subdivide(vec3 p1,vec3 p2){...}
```

着色器，关键字precise可以使用某个变量的任何位置设置个变量，并且可以修改已经声明过的变量。

编译器使用precise 一个实际影响，类似上面的表达是不能在使用两种不同的乘法命令同时参与计算。

例如第一次是普通乘法，第二次相乘使用混合乘加预算，因为这两个命令对于同一组值的计算可能可能出现微笑差异，而这种差异precise是不允许，因此编译会组织你在代码这么做。

但是混乘对性能提升很重要，因此GLSL提供了一个内置函数fma()代替原来的操作。

### 小结
可能这样还是很抽象，为什么GPU需要计算不变性而CPU不需要呢？这里有个神图，一看就懂。
![cpu和gpu硬件逻辑结构对比.png](/images/cpu和gpu硬件逻辑结构对比.png)

其中Control是控制器、ALU算术逻辑单元、Cache是cpu内部缓存、DRAM就是内存。
能看到GPU有许许多多的小的计算单元。而CPU则是有一个很大的强大计算模块，而GPU则是有很多不是那么强大的计算单元。

举个例子，CPU的计算单元相当于是一个大学教授在计算，而GPU则是成千上百和小学生在计算。由于计算机大部分都是由简单的计算逻辑组成，一个强大的大脑当然架不住很多简单大脑共同计算的速度快，因此GPU作为大量的并行计算工具是首选。这也是为什么在人工智能，大数据选择GPU作为计算工具也是这个原因。

话题又转回来。由于GPU本身含有大量的计算单元，这样就造成了，计算可能会因为每个计算单元的情况而出现微小的差异。因此GLSL需要计算不变性。

invariant 保证了每个阶段着色器的输出在使用相同的表达式，结果一致。
precise 保证了在着色器编程内部使用相同的表达式，结果一致。

## 实战演练 Uniform数据接口
介绍到这里，一个粗略的GLSL的语言总览已经有了。接下来就让我们实战演练一番。

我们在上一篇文章基础上，让整个Uniform增加随着时间的颜色变化而变化。

我们先编写一个顶点着色器的GLSL：
文件：veritex.glsl
```cpp
#version 330 core
layout(location = 0) in vec3 aPos;
void main(){
    gl_Position = vec4(aPos,1.0);
}
```

这样我就把顶点着色的输出设置为分量为4的向量，在原来的方位的向量上扩展为一个w分量(暂时不用理)。
文件：fragment.glsl
```cpp
#version 330 core
out vec4 mFragColor;
uniform vec4 mChangingColor;
void main(){
    mFragColor = mChangingColor;
}
```
在片元着色器上，渲染的颜色由片元着色器决定。

完成这两个之后，我们只需要编写如下代码，编译着色器程序,利用C++ 11特性回调Loop中的事件调用。
```cpp
 const char* vPath = "/Users/yjy/Desktop/iOS workspcae/first_opengl/glsl/veritex.glsl";
    const char* fPath = "/Users/yjy/Desktop/iOS workspcae/first_opengl/glsl/fragment.glsl";
    Shader *shader = new Shader(vPath,fPath);
    shader->compile();
    if(shader&&shader->isCompileSuccess()){
        mixColorTri(VAO,VBO);
        
        loop(window,VAO,VBO,shader,[](Shader *shader){
            //更新uniform颜色
            float timeValue = glfwGetTime();
            float colorValue = sin(timeValue) / 2.0 + 0.5f;
            //拿到uniform的位置索引
            int vertexColorLocation = glGetUniformLocation(shader->ID,"mChangingColor");
            glUniform4f(vertexColorLocation, colorValue, 0.0f, 0.0f, 1.0f);
        });
    }
```

flushTriangleToOpengl这个方法就是和上一篇文章创造并绑定顶点缓存对象和顶点数组对象，最后设定步长。
```cpp
void flushTriangleToOpengl(GLuint& VAO,GLuint& VBO){
    //我们要绘制三角形
    float vertices[] = {
        //位置             
        -0.5f, -0.5f, 0.0f,
        0.5f, -0.5f, 0.0f,
        0.0f,  0.5f, 0.0f
    };
    
    //生成分配VAO
    glGenVertexArrays(1,&VAO);
    //生成一个VBO缓存对象
    glGenBuffers(1, &VBO);
    
    //绑定VAO，注意在core模式，没有绑定VAO，opengl拒绝绘制任何东西
    glBindVertexArray(VAO);
    
    
    //绑定VBO
    glBindBuffer(GL_ARRAY_BUFFER, VBO);
    //复制顶点给opengl缓存
    //类型为GL_ARRAY_BUFFER 第二第三参数说明要放入缓存的多少，GL_STATIC_DRAW当画面不懂的时候推荐使用
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    
    //设定顶点属性指针
    //第一个参数指定我们要配置顶点属性，对应vertex glsl中location 确定位置
    //第二参数顶点大小，顶点属性是一个vec3，由3个值组成，大小是3
    //第三参数指定数据类型，都是float(glsl中vec*都是float)
    //第四个参数：是否被归一化
    //第五参数：步长，告诉我们连续的顶点属性组之间的间隔，这里是每一段都是3个float，所以是3*float
    //最后一个是偏移量
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,  3 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(0);
    
    glBindBuffer(GL_ARRAY_BUFFER,0);
    glBindVertexArray(0);
    
}
```

最后,我们利用C++ 11特性创建一个回调把，在创建一个事件循环：
```cpp
void loop(GLFWwindow *window,const GLuint VAO,const GLuint VBO,Shader *shader,function<void(Shader*)> handle){
    while(!glfwWindowShouldClose(window)){
        processInput(window);
        //交换颜色缓冲，他是一个存储着GLFW窗口每一个像素颜色值的大缓冲
        //会在这个迭代中用来绘制，并且显示在屏幕上
        glClearColor(0.2f, 0.3f, 0.3f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        
        //我们已经告诉，程序要数据什么数据，以及怎么解释整个数据
        //数据传输之后运行程序
        //glUseProgram(shaderProgram);
        shader->use();
        
        if(handle){
            handle(shader);
        }
        
        
        
        //绑定数据
        glBindVertexArray(VAO);
        //绘制一个三角形
        //从0开始，3个
        glDrawArrays(GL_TRIANGLES, 0, 3);
        
        //绘制矩形
        //glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_INT,0);
        
        glBindVertexArray(0);
        
        glfwSwapBuffers(window);
        //检查有没有触发事件，键盘输入，鼠标移动，更新噶 u 那个口耦
        glfwPollEvents();
    }
    
    glDeleteVertexArrays(1,&VAO);
    glDeleteBuffers(1, &VBO);
    
    glfwTerminate();
}
```
其核心就是这里，通过glGetUniformLocation获取uniform的索引，接着通过glUniform4f方法设置一个4个分量的颜色向量到片元着色器中着色。

这样就能做到，让整个三角形颜色随着时间动起来，从浅红一直变成深红。
![example_red.gif](/images/example_red.gif)

## 实战演练 GLSL顶点着色器layout的妙用
实际上在顶点着色器中有这么一行：
```cpp
layout(location = 0) in vec3 aPos;
```
layout中有location的字段。接下来，来看看这个字段是怎么运作。

还记得，glVertexAttribPointer这个方法指定了OpenGL如何解析读取顶点数据的方法。

这个方法的第一个参数实际上就是指定的是，将会写入到哪一个location的对应的in数据。

假设我们有这么一堆顶点数据：
```cpp
float vertices[] = {
        //位置            //颜色
        -0.5f,-0.5f,0.0f,1.0f,0.0f,0.0f,
        0.5f,-0.5f,0.0f,0.0f,1.0f,0.0f,
        0.0f,0.5f,0.0f,0.0f,0.0f,1.0f
    };
```
我们想要设置前3个是位置信息，而后三个是颜色信息的坐标参数，又是该如何解析呢？
```cpp
void mixColorTri(GLuint& VAO,GLuint& VBO){
    float vertices[] = {
        //位置            //着色
        -0.5f,-0.5f,0.0f,1.0f,0.0f,0.0f,
        0.5f,-0.5f,0.0f,0.0f,1.0f,0.0f,
        0.0f,0.5f,0.0f,0.0f,0.0f,1.0f
    };
    
    glGenVertexArrays(1,&VAO);
    glGenBuffers(1,&VBO);
    
    //绑定
    glBindVertexArray(VAO);
    glBindBuffer(GL_ARRAY_BUFFER,VBO);
    //绑定数据
    glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);
    
    //告诉opengl 每6个顶点往后读取下一个数据
    //这个0代表了 layout(location = 0)
    //最后一个参数是偏移量
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0);
    glEnableVertexAttribArray(0);
    
    //走3个float的偏移量，开始读取数据
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float)));
    glEnableVertexAttribArray(1);
    
    
    glBindBuffer(GL_ARRAY_BUFFER,0);
    glBindVertexArray(0);
    
}
```

![glVertexAttribPointer读取颜色顶点原理.png](/images/glVertexAttribPointer读取颜色顶点原理.png)


那么对应的顶点着色器呢？
```cpp
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
out vec3 ourColor;

void main(){
    gl_Position = vec4(aPos,1.0);
    ourColor = aColor;
}
```

片元着色器:
```cpp
#version 330 core
out vec4 FragmentColor;
in vec3 ourColor;

void main(){
    FragmentColor = vec4(ourColor,1.0);
}
```

记住每个着色器传递数据out和in之间的变量命名要一致，不然会出现着色器程序链接异常。

![彩色三角形.png](/images/彩色三角形.png)


## 实战演练 移动三角形
当我们变化颜色，处理更多的顶点信息了，就会想到怎么把这个三角形动起来。
编写一个顶点着色器
```cpp
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
uniform float offset;
out vec3 ourColor;
void main(){
    gl_Position = vec4(aPos.x + offset,aPos.y,aPos.z,1.0);
    ourColor = aColor;
}
```

接着为了方便我们处理uniform的数据设置，我们在Shader类新增下面方法：
```cpp
void Shader::setBool(const std::string &name,bool value) const{
    glUniform1i(glGetUniformLocation(ID,name.c_str()),(int)value);
}
void Shader:: setInt(const std::string &name,int value) const{
    glUniform1i(glGetUniformLocation(ID,name.c_str()),value);
}
void Shader:: setFloat(const std::string &name,float value) const{
    glUniform1f(glGetUniformLocation(ID,name.c_str()),value);
}
```

接着把这行改造成如下：
```cpp
if(shader&&shader->isCompileSuccess()){
        mixColorTri(VAO,VBO);
        static float init = 0.0f;
        loop(window,VAO,VBO,shader,[](Shader *shader){
            //更新uniform颜色
            init += 0.005;

            shader->setFloat("offset", init);
        });
    }
```
就能看到这个三角形快速的移动。
![example_move.gif](/images/example_move.gif)


## 总结
经过这几个实战演练，是不是对OpenGL的GLSL的理解，uniform以及对顶点数组对象又有了更加深刻的理解呢？

实际上GLSL语言还有不少特性，如buffer，子程序，独立的着色器程序等高级应用还没涉及到。看来革命尚未成功，继续努力才是