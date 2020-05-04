---
title: Android 重学系列 渲染图层-OpenGL es上的封装(下)
top: false
cover: false
date: 2020-01-27 19:43:13
img:
tag:
description:
author: yjy239
summary:
categories: SurfaceFlinger
tags:
- Android
- Android Framework
---
# 前言
经过上一篇对OpenGL es的环境搭建，了解几个关键的数据结构，本文将会解析软件模拟纹理的绘制流程。

先摆一张，OpenGL es上下文的数据结构:
![OpenGL上下文结构.png](/images/OpenGL上下文结构.png)

在阅读本文时候，我们需要时刻记住这个图。

如果问题，可以来本文讨论[https://www.jianshu.com/p/29ab1b15cd2a](https://www.jianshu.com/p/29ab1b15cd2a)



# 正文
回去看看我之前写的OpenGL 的[纹理与索引](https://www.jianshu.com/p/9c58cd895fa5)一文，纹理的核心步骤如下：
- 1.glGenTextures 生成一个纹理句柄
- 2.glBindTexture 绑定纹理句柄
- 3.glTexParameteri 设置纹理参数
- 4.glTexImage2D 输入到像素数据到纹理
- 5.glActiveTexture 激活纹理
- 6.glDrawElements 绘制到屏幕
- 7.eglSwapBuffers 交换缓冲区，显示到屏幕

## glGenTextures
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[texture.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/texture.cpp)
```cpp
void glGenTextures(GLsizei n, GLuint *textures)
{
    ogles_context_t* c = ogles_context_t::get();
    if (n<0) {
        ogles_error(c, GL_INVALID_VALUE);
        return;
    }
    // generate unique (shared) texture names
    c->surfaceManager->getToken(n, textures);
}
```
先获取当前线程的上下文ogles_context_t。surfaceManager是指EGLSurfaceManager指针。EGLSurfaceManager继承于TokenManager，getToken是属于TokenManager。

### TokenManager getToken
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[TokenManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/TokenManager.cpp)

```cpp
status_t TokenManager::getToken(GLsizei n, GLuint *tokens)
{
    Mutex::Autolock _l(mLock);
    for (GLsizei i=0 ; i<n ; i++)
        *tokens++ = mTokenizer.acquire();
    return NO_ERROR;
}
```

文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[Tokenizer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/Tokenizer.cpp)
```cpp
uint32_t Tokenizer::acquire()
{
    if (!mRanges.size() || mRanges[0].first) {
        _insertTokenAt(0,0);
        return 0;
    }
    
    // just extend the first run
    const run_t& run = mRanges[0];
    uint32_t token = run.first + run.length;
    _insertTokenAt(token, 1);
    return token;
}

```
实际上这里的意思就是计算token的数值。这个token其实由mRanges的vector控制。mRanges的元素其实是run_t结构体，而token则是由run_t的first和length组成。

当第一次生成一个句柄时候，会在0位置插入0,length为1，返回0.不是第一次的时候，新的token为第0个的first+length。

## glBindTexture
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[texture.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/texture.cpp)
```cpp
void glBindTexture(GLenum target, GLuint texture)
{
    ogles_context_t* c = ogles_context_t::get();
...

    // Bind or create a texture
    sp<EGLTextureObject> tex;
    if (texture == 0) {
        // 0 is our local texture object
        tex = c->textures.defaultTexture;
    } else {
        tex = c->surfaceManager->texture(texture);
        if (ggl_unlikely(tex == 0)) {
            tex = c->surfaceManager->createTexture(texture);
            if (tex == 0) {
                ogles_error(c, GL_OUT_OF_MEMORY);
                return;
            }
        }
    }
    bindTextureTmu(c, c->textures.active, texture, tex);
}
```
EGLTextureObject指一个纹理对象。如果glBindTexture为0，则是一个默认纹理对象。因此当我们关闭一个纹理的时候，就要把glBindTexture的句柄设置为0.

否则EGLSurfaceManager调用texture获取该id的EGLTextureObject，如果找不到创建一个createTexture创建一个该id对应的纹理对象。

最后调用bindTextureTmu，把texture_state_t中的active，texture(纹理句柄)，找到或者生成新的纹理对象进行处理。

文件：[ameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[TextureObjectManager.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/TextureObjectManager.cpp)

```cpp
sp<EGLTextureObject> EGLSurfaceManager::texture(GLuint name)
{
    Mutex::Autolock _l(mLock);
    const ssize_t index = mTextures.indexOfKey(name);
    if (index >= 0)
        return mTextures.valueAt(index);
    return 0;
}
```
 mTextures是一个KeyedVector。你可以暂时是做一个SparseArray即可。里面保存了当前key对应的EGLTextureObject，找不到返回0.
```cpp
sp<EGLTextureObject> EGLSurfaceManager::createTexture(GLuint name)
{
    sp<EGLTextureObject> result;

    Mutex::Autolock _l(mLock);
    if (mTextures.indexOfKey(name) >= 0)
        return result; // already exists!

    result = new EGLTextureObject();

    status_t err = mTextures.add(name, result);
    if (err < 0)
        result.clear();

    return result;
}
```
此时进行了EGLTextureObject初始化并且添加到mTextures。

### EGLTextureObject 初始化
```cpp
class EGLTextureObject : public LightRefBase<EGLTextureObject>
{
public:
                    EGLTextureObject();
                   ~EGLTextureObject();

    status_t    setSurface(GGLSurface const* s);
    status_t    setImage(ANativeWindowBuffer* buffer);
    void        setImageBits(void* vaddr) { surface.data = (GGLubyte*)vaddr; }

    status_t            reallocate(GLint level,
                            int w, int h, int s,
                            int format, int compressedFormat, int bpr);
    inline  size_t      size() const { return mSize; }
    const GGLSurface&   mip(int lod) const;
    GGLSurface&         editMip(int lod);
    bool                hasMipmaps() const { return mMipmaps!=0; }
    bool                isComplete() const { return mIsComplete; }
    void                copyParameters(const sp<EGLTextureObject>& old);

private:
        status_t        allocateMipmaps();
            void        freeMipmaps();
            void        init();
    size_t              mSize;
    GGLSurface          *mMipmaps;
    int                 mNumExtraLod;
    bool                mIsComplete;

public:
    GGLSurface          surface;
    GLenum              wraps;
    GLenum              wrapt;
    GLenum              min_filter;
    GLenum              mag_filter;
    GLenum              internalformat;
    GLint               crop_rect[4];
    GLint               generate_mipmap;
    GLint               direct;
    ANativeWindowBuffer* buffer;
};
```
能看到里面很多熟悉的结构体。GGLSurface;s，t轴等参数。

```cpp
EGLTextureObject::EGLTextureObject()
    : mSize(0)
{
    init();
}
void EGLTextureObject::init()
{
    memset(&surface, 0, sizeof(surface));
    surface.version = sizeof(surface);
    mMipmaps = 0;
    mNumExtraLod = 0;
    mIsComplete = false;
    wraps = GL_REPEAT;
    wrapt = GL_REPEAT;
    min_filter = GL_LINEAR;
    mag_filter = GL_LINEAR;
    internalformat = 0;
    memset(crop_rect, 0, sizeof(crop_rect));
    generate_mipmap = GL_FALSE;
    direct = GL_FALSE;
    buffer = 0;
}
```
在这里初始化EGLTextureObject中的参数。s和t默认是重复，同时像素是线性过滤器，ANativeWindowBuffer初始化为0.

### bindTextureTmu 更新纹理状态机
```cpp
    bindTextureTmu(c, c->textures.active, texture, tex);
```

```cpp
void bindTextureTmu(
    ogles_context_t* c, int tmu, GLuint texture, const sp<EGLTextureObject>& tex)
{
    if (tex.get() == c->textures.tmu[tmu].texture)
        return;

    // free the reference to the previously bound object
    texture_unit_t& u(c->textures.tmu[tmu]);
    if (u.texture)
        u.texture->decStrong(c);

    // bind this texture to the current active texture unit
    // and add a reference to this texture object
    u.texture = tex.get();
    u.texture->incStrong(c);
    u.name = texture;
    invalidate_texture(c, tmu);
}
```
tmu就是texture_state_t中active的句柄其实就是texture_state_t 中 tmu数组中的index。如果此时绑定的纹理和当前已经激活的纹理是同一个index，则直接返回。

否则，把EGLTextureObject 添加到active句柄(index)的位置。也就是说texture_unit_t其实对应就是EGLTextureObject。这样ogles_context_t上下文的活跃纹理就是新的纹理对象，其中texture_unit_t的name会记录当前我们设置的句柄值。



设置参数就跳过，我们直接看核心函数glTexImage2D。

## glTexImage2D 加载图像数据
 一般用法如下：
```cpp
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
```

```cpp
void glTexImage2D(
        GLenum target, GLint level, GLint internalformat,
        GLsizei width, GLsizei height, GLint border,
        GLenum format, GLenum type, const GLvoid *pixels)
{
    ogles_context_t* c = ogles_context_t::get();
//target只能是GL_TEXTURE_2D
    if (target != GL_TEXTURE_2D) {
        ogles_error(c, GL_INVALID_ENUM);
        return;
    }
...

    int32_t size = 0;
    GGLSurface* surface = 0;
    int error = createTextureSurface(c, &surface, &size,
            level, format, type, width, height);
...

    if (pixels) {
        const int32_t formatIdx = convertGLPixelFormat(format, type);
        const GGLFormat& pixelFormat(c->rasterizer.formats[formatIdx]);
        const int32_t align = c->textures.unpackAlignment-1;
        const int32_t bpr = ((width * pixelFormat.size) + align) & ~align;
        const int32_t stride = bpr / pixelFormat.size;

        GGLSurface userSurface;
        userSurface.version = sizeof(userSurface);
        userSurface.width  = width;
        userSurface.height = height;
        userSurface.stride = stride;
        userSurface.format = formatIdx;
        userSurface.compressedFormat = 0;
        userSurface.data = (GLubyte*)pixels;

        int err = copyPixels(c, *surface, 0, 0, userSurface, 0, 0, width, height);
        if (err) {
            ogles_error(c, err);
            return;
        }
        generateMipmap(c, level);
    }
}
```
- 1.target在OpenGL es只支持GL_TEXTURE_2D
- 2.createTextureSurface 创建一个纹理临时图层
- 3.传进来的像素指针数组不为空，调用copyPixels拷贝。
- 4.generateMipmap 处理状态机

### createTextureSurface 获取一个纹理临时图层
```cpp
int createTextureSurface(ogles_context_t* c,
        GGLSurface** outSurface, int32_t* outSize, GLint level,
        GLenum format, GLenum type, GLsizei width, GLsizei height,
        GLenum compressedFormat = 0)
{
    // convert the pixelformat to one we can handle
    const int32_t formatIdx = convertGLPixelFormat(format, type);
    if (formatIdx == 0) { // we don't know what to do with this
        return GL_INVALID_OPERATION;
    }

    // figure out the size we need as well as the stride
    const GGLFormat& pixelFormat(c->rasterizer.formats[formatIdx]);
    const int32_t align = c->textures.unpackAlignment-1;
    const int32_t bpr = ((width * pixelFormat.size) + align) & ~align;
    const size_t size = bpr * height;
    const int32_t stride = bpr / pixelFormat.size;

    if (level > 0) {
        const int active = c->textures.active;
        EGLTextureObject* tex = c->textures.tmu[active].texture;
        status_t err = tex->reallocate(level,
                width, height, stride, formatIdx, compressedFormat, bpr);
        if (err != NO_ERROR)
            return GL_OUT_OF_MEMORY;
        GGLSurface& surface = tex->editMip(level);
        *outSurface = &surface;
        *outSize = size;
        return 0;
    }

    sp<EGLTextureObject> tex = getAndBindActiveTextureObject(c);
    status_t err = tex->reallocate(level,
            width, height, stride, formatIdx, compressedFormat, bpr);
    if (err != NO_ERROR)
        return GL_OUT_OF_MEMORY;

    tex->internalformat = format;
    *outSurface = &tex->surface;
    *outSize = size;
    return 0;
}
```
这里面level一般是0.不为0说明指定多级渐远纹理的级别。则从当前正在活跃textures找到EGLTextureObject。这里我们先按照0的情况处理。

level为0则调用getAndBindActiveTextureObject查找EGLTextureObject，接着调用reallocate，重新为EGLTextureObject设置宽高，读取数据数据的步数。最后获取EGLTextureObject中的GGLSurface 。

#### getAndBindActiveTextureObject
```cpp
static __attribute__((noinline))
sp<EGLTextureObject> getAndBindActiveTextureObject(ogles_context_t* c)
{
    sp<EGLTextureObject> tex;
    const int active = c->textures.active;
    const GLuint name = c->textures.tmu[active].name;

    // free the reference to the previously bound object
    texture_unit_t& u(c->textures.tmu[active]);
    if (u.texture)
        u.texture->decStrong(c);

    if (name == 0) {
        tex = c->textures.defaultTexture;
        for (int i=0 ; i<GGL_TEXTURE_UNIT_COUNT ; i++) {
            if (c->textures.tmu[i].texture == tex.get())
                invalidate_texture(c, i);
        }
    } else {
        // get a new texture object for that name
        tex = c->surfaceManager->replaceTexture(name);
    }

    u.texture = tex.get();
    u.texture->incStrong(c);
    u.name = name;
    invalidate_texture(c, active);
    return tex;
}
```
在glBindTexture一步中，把活跃纹理已经设置新的纹理对象。这个方法通过active的位置找到tmu中name对象。如果name是0，则说明是默认的纹理对象。否则将会调用EGLSurfaceManager的replaceTexture。

#### EGLSurfaceManager replaceTexture
```cpp
sp<EGLTextureObject> EGLSurfaceManager::replaceTexture(GLuint name)
{
    sp<EGLTextureObject> tex;
    Mutex::Autolock _l(mLock);
    const ssize_t index = mTextures.indexOfKey(name);
    if (index >= 0) {
        const sp<EGLTextureObject>& old = mTextures.valueAt(index);
        const uint32_t refs = old->getStrongCount();
        if (ggl_likely(refs == 1)) {
            // we're the only owner
            tex = old;
        } else {
            // keep the texture's parameters
            tex = new EGLTextureObject();
            tex->copyParameters(old);
            mTextures.removeItemsAt(index);
            mTextures.add(name, tex);
        }
    }
    return tex;
}
```
此时会从name(也就是我们在glBindTexture时候的target)尝试找到之前通过createTexture存在mTextures的纹理对象。

此时会检测一下，纹理对象中强引用计数，如果又有一个引用则不变。如果引用不为1，则会把原来的移除掉重新生成一个新的查到原来的位置。这里面目的只是为了保证引用计数能够正常工作。

所以getAndBindActiveTextureObject其实就会返回之前设置好的active中的新纹理对象EGLTextureObject。

#### EGLTextureObject reallocate
```cpp
status_t EGLTextureObject::reallocate(
        GLint level, int w, int h, int s,
        int format, int compressedFormat, int bpr)
{
    const size_t size = h * bpr;
    if (level == 0)
    {
        if (size!=mSize || !surface.data) {
            if (mSize && surface.data) {
                free(surface.data);
            }
            surface.data = (GGLubyte*)malloc(size);
            if (!surface.data) {
                mSize = 0;
                mIsComplete = false;
                return NO_MEMORY;
            }
            mSize = size;
        }
        surface.version = sizeof(GGLSurface);
        surface.width  = w;
        surface.height = h;
        surface.stride = s;
        surface.format = format;
        surface.compressedFormat = compressedFormat;
        if (mMipmaps)
            freeMipmaps();
        mIsComplete = true;
    }
    else
    {
...
    }
    return NO_ERROR;
}
```
其实这里面的工作就是释放了GGLSurface中的数据内存，重新申请一套内存，并且设置当前纹理相关的数据进去。而GGLSurface这个结构体也很简单：
```cpp
typedef struct {
    GGLsizei    version;    // always set to sizeof(GGLSurface)
    GGLuint     width;      // width in pixels
    GGLuint     height;     // height in pixels
    GGLint      stride;     // stride in pixels
    GGLubyte*   data;       // pointer to the bits
    GGLubyte    format;     // pixel format
    GGLubyte    rfu[3];     // must be zero
    // these values are dependent on the used format
    union {
        GGLint  compressedFormat;
        GGLint  vstride;
    };
    void*       reserved;
} GGLSurface;
```
至此createTextureSurface就可以通过活跃的纹理，拿到纹理对象中临时的绘制图层。

#### copyPixels 拷贝像素数据到纹理图层中
```cpp
        const int32_t formatIdx = convertGLPixelFormat(format, type);
        const GGLFormat& pixelFormat(c->rasterizer.formats[formatIdx]);
        const int32_t align = c->textures.unpackAlignment-1;
        const int32_t bpr = ((width * pixelFormat.size) + align) & ~align;
        const int32_t stride = bpr / pixelFormat.size;

        GGLSurface userSurface;
        userSurface.version = sizeof(userSurface);
        userSurface.width  = width;
        userSurface.height = height;
        userSurface.stride = stride;
        userSurface.format = formatIdx;
        userSurface.compressedFormat = 0;
        userSurface.data = (GLubyte*)pixels;

        int err = copyPixels(c, *surface, 0, 0, userSurface, 0, 0, width, height);
```

```cpp
static __attribute__((noinline))
int copyPixels(
        ogles_context_t* c,
        const GGLSurface& dst,
        GLint xoffset, GLint yoffset,
        const GGLSurface& src,
        GLint x, GLint y, GLsizei w, GLsizei h)
{
    if ((dst.format == src.format) &&
        (dst.stride == src.stride) &&
        (dst.width == src.width) &&
        (dst.height == src.height) &&
        (dst.stride > 0) &&
        ((x|y) == 0) &&
        ((xoffset|yoffset) == 0))
    {
        // this is a common case...
        const GGLFormat& pixelFormat(c->rasterizer.formats[src.format]);
        const size_t size = src.height * src.stride * pixelFormat.size;
        memcpy(dst.data, src.data, size);
        return 0;
    }

    // use pixel-flinger to handle all the conversions
    GGLContext* ggl = getRasterizer(c);
    if (!ggl) {
        // the only reason this would fail is because we ran out of memory
        return GL_OUT_OF_MEMORY;
    }

    ggl->colorBuffer(ggl, &dst);
    ggl->bindTexture(ggl, &src);
    ggl->texCoord2i(ggl, x-xoffset, y-yoffset);
    ggl->recti(ggl, xoffset, yoffset, xoffset+w, yoffset+h);
    return 0;
}
```
首先看到此时会进行userface临时纹理图层和纹理图层比较规格。如果一致，则获取当前的像素颜色规格，找到更加精确的surface大小，把glTexImage2D中的pixel像素的数据拷贝到纹理的的GGLSurface中。

这是绝大部分情况，也是当前的逻辑。当然遇到两个规格不同的surface需要拷贝数据，则需要把逻辑交给GGLContext处理。这里暂时不考虑。因为userface的规格参数是拷贝纹理的GGLSurface的。

#### generateMipmap 
```cpp
void generateMipmap(ogles_context_t* c, GLint level)
{
    if (level == 0) {
        const int active = c->textures.active;
        EGLTextureObject* tex = c->textures.tmu[active].texture;
        if (tex->generate_mipmap) {
            if (buildAPyramid(c, tex) != NO_ERROR) {
                ogles_error(c, GL_OUT_OF_MEMORY);
                return;
            }
        }
    }
}
```
generate_mipmap 此时为false，将不会走进buildAPyramid。

## glActiveTexture 激活纹理
```cpp
void glActiveTexture(GLenum texture)
{
    ogles_context_t* c = ogles_context_t::get();
    if (uint32_t(texture-GL_TEXTURE0) > uint32_t(GGL_TEXTURE_UNIT_COUNT)) {
        ogles_error(c, GL_INVALID_ENUM);
        return;
    }
    c->textures.active = texture - GL_TEXTURE0;
    c->rasterizer.procs.activeTexture(c, c->textures.active);
}
```
关键是c->rasterizer.procs.activeTexture。rasterizer是指context_t，而procs则是GGLContext。

### GGLContext activeTexture 
文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libpixelflinger](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/)/[pixelflinger.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/pixelflinger.cpp)

```cpp
static void ggl_activeTexture(void* con, GGLuint tmu)
{
    GGL_CONTEXT(c, con);
    if (tmu >= GGLuint(GGL_TEXTURE_UNIT_COUNT)) {
        ggl_error(c, GGL_INVALID_ENUM);
        return;
    }
    c->activeTMUIndex = tmu;
    c->activeTMU = &(c->state.texture[tmu]);
}
```
此时c是context_t，就是很简单的把context_t中activeTMUIndex设置为当前的纹理句柄，通过句柄找到对应的纹理对象，赋值到activeTMU。

这样context _t状态管理器就拿到了活跃的纹理对象。

## glDrawElements 绘制到屏幕
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[array.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/array.cpp)
```cpp
void glDrawElements(
    GLenum mode, GLsizei count, GLenum type, const GLvoid *indices)
{
    ogles_context_t* c = ogles_context_t::get();
...
    switch (mode) {
    case GL_POINTS:
    case GL_LINE_STRIP:
    case GL_LINE_LOOP:
    case GL_LINES:
    case GL_TRIANGLE_STRIP:
    case GL_TRIANGLE_FAN:
    case GL_TRIANGLES:
        break;
    default:
        ogles_error(c, GL_INVALID_ENUM);
        return;
    }
    switch (type) {
    case GL_UNSIGNED_BYTE:
    case GL_UNSIGNED_SHORT:
        c->arrays.indicesType = type;
        break;
    default:
        ogles_error(c, GL_INVALID_ENUM);
        return;
    }
    if (count == 0 || !c->arrays.vertex.enable)
        return;
    if ((c->cull.enable) && (c->cull.cullFace == GL_FRONT_AND_BACK))
        return; // all triangles are culled

    // clear the vertex-cache
    c->vc.clear();
    validate_arrays(c, mode);

    // if indices are in a buffer object, the pointer is treated as an
    // offset in that buffer.
    if (c->arrays.element_array_buffer) {
        indices = c->arrays.element_array_buffer->data + uintptr_t(indices);
    }

    const uint32_t enables = c->rasterizer.state.enables;
    if (enables & GGL_ENABLE_TMUS)
        ogles_lock_textures(c);

    drawElementsPrims[mode](c, count, indices);
    
    if (enables & GGL_ENABLE_TMUS)
        ogles_unlock_textures(c);

    
#if VC_CACHE_STATISTICS
    c->vc.total = count;
    c->vc.dump_stats(mode);
#endif
}
```
这个方法的核心实际上是检测array_machine_t结构体，绘制顶点，绘制三角形，检查绑定在顶点数组对象的纹理。

### 校验拷贝olgs_context_t数据到state_t
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[texture.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/texture.cpp)

```cpp
static __attribute__((noinline))
void validate_tmu(ogles_context_t* c, int i)
{
    texture_unit_t& u(c->textures.tmu[i]);
    if (u.dirty) {
        u.dirty = 0;
        c->rasterizer.procs.activeTexture(c, i);
        c->rasterizer.procs.bindTexture(c, &(u.texture->surface));
        c->rasterizer.procs.texGeni(c, GGL_S,
                GGL_TEXTURE_GEN_MODE, GGL_AUTOMATIC);
        c->rasterizer.procs.texGeni(c, GGL_T,
                GGL_TEXTURE_GEN_MODE, GGL_AUTOMATIC);
        c->rasterizer.procs.texParameteri(c, GGL_TEXTURE_2D,
                GGL_TEXTURE_WRAP_S, u.texture->wraps);
        c->rasterizer.procs.texParameteri(c, GGL_TEXTURE_2D,
                GGL_TEXTURE_WRAP_T, u.texture->wrapt);
        c->rasterizer.procs.texParameteri(c, GGL_TEXTURE_2D,
                GGL_TEXTURE_MIN_FILTER, u.texture->min_filter);
        c->rasterizer.procs.texParameteri(c, GGL_TEXTURE_2D,
                GGL_TEXTURE_MAG_FILTER, u.texture->mag_filter);

        // disable this texture unit if it's not complete
        if (!u.texture->isComplete()) {
            c->rasterizer.procs.disable(c, GGL_TEXTURE_2D);
        }
    }
}
```

在这个过程中会获取之前放在ogles_context_t.texture_state中的数据，全部拷贝到state_t.

### 绘制核心
可以去看看底层核心：
文件：/[system](http://androidxref.com/9.0.0_r3/xref/system/)/[core](http://androidxref.com/9.0.0_r3/xref/system/core/)/[libpixelflinger](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/)/[scanline.cpp](http://androidxref.com/9.0.0_r3/xref/system/core/libpixelflinger/scanline.cpp)

```cpp
void scanline(context_t* c)
{
    const uint32_t enables = c->state.enables;
    const int xs = c->iterators.xl;
    const int x1 = c->iterators.xr;
	int xc = x1 - xs;
    const int16_t* covPtr = c->state.buffers.coverage + xs;

    // All iterated values are sampled at the pixel center

    // reset iterators for that scanline...
    GGLcolor r, g, b, a;
    iterators_t& ci = c->iterators;
...

    // z iterators are 1.31
    GGLfixed z = (xs * c->shade.dzdx) + ci.ydzdy;
    GGLfixed f = (xs * c->shade.dfdx) + ci.ydfdy;

    struct {
        GGLfixed s, t;
    } tc[GGL_TEXTURE_UNIT_COUNT];
    if (enables & GGL_ENABLE_TMUS) {
        for (int i=0 ; i<GGL_TEXTURE_UNIT_COUNT ; ++i) {
            if (c->state.texture[i].enable) {
                texture_iterators_t& ti = c->state.texture[i].iterators;
                if (enables & GGL_ENABLE_W) {
                    tc[i].s = ti.ydsdy;
                    tc[i].t = ti.ydtdy;
                } else {
                    tc[i].s = (xs * ti.dsdx) + ti.ydsdy;
                    tc[i].t = (xs * ti.dtdx) + ti.ydtdy;
                }
            }
        }
    }

    pixel_t fragment;
    pixel_t texel;
    pixel_t fb;

	uint32_t x = xs;
	uint32_t y = c->iterators.y;

	while (xc--) {
    
        { // just a scope

		// read color (convert to 8 bits by keeping only the integer part)
        fragment.s[1] = fragment.s[2] =
        fragment.s[3] = fragment.s[0] = 8;
        fragment.c[1] = r >> (GGL_COLOR_BITS-8);
        fragment.c[2] = g >> (GGL_COLOR_BITS-8);
        fragment.c[3] = b >> (GGL_COLOR_BITS-8);
        fragment.c[0] = a >> (GGL_COLOR_BITS-8);

		// texturing
        if (enables & GGL_ENABLE_TMUS) {
            for (int i=0 ; i<GGL_TEXTURE_UNIT_COUNT ; ++i) {
                texture_t& tx = c->state.texture[i];
                if (!tx.enable)
                    continue;
                texture_iterators_t& ti = tx.iterators;
                int32_t u, v;

                // s-coordinate
                if (tx.s_coord != GGL_ONE_TO_ONE) {
                    const int w = tx.surface.width;
                    u = wrapping(tc[i].s, w, tx.s_wrap);
                    tc[i].s += ti.dsdx;
                } else {
                    u = (((tx.shade.is0>>16) + x)<<16) + FIXED_HALF;
                }

                // t-coordinate
                if (tx.t_coord != GGL_ONE_TO_ONE) {
                    const int h = tx.surface.height;
                    v = wrapping(tc[i].t, h, tx.t_wrap);
                    tc[i].t += ti.dtdx;
                } else {
                    v = (((tx.shade.it0>>16) + y)<<16) + FIXED_HALF;
                }

                // read texture
                if (tx.mag_filter == GGL_NEAREST &&
                    tx.min_filter == GGL_NEAREST)
                {
                    u >>= 16;
                    v >>= 16;
                    tx.surface.read(&tx.surface, c, u, v, &texel);
                } else {
                    const int w = tx.surface.width;
                    const int h = tx.surface.height;
                    u -= FIXED_HALF;
                    v -= FIXED_HALF;
                    int u0 = u >> 16;
                    int v0 = v >> 16;
                    int u1 = u0 + 1;
                    int v1 = v0 + 1;
                    if (tx.s_wrap == GGL_REPEAT) {
                        if (u0<0)  u0 += w;
                        if (u1<0)  u1 += w;
                        if (u0>=w) u0 -= w;
                        if (u1>=w) u1 -= w;
                    } else {
                        if (u0<0)  u0 = 0;
                        if (u1<0)  u1 = 0;
                        if (u0>=w) u0 = w-1;
                        if (u1>=w) u1 = w-1;
                    }
                    if (tx.t_wrap == GGL_REPEAT) {
                        if (v0<0)  v0 += h;
                        if (v1<0)  v1 += h;
                        if (v0>=h) v0 -= h;
                        if (v1>=h) v1 -= h;
                    } else {
                        if (v0<0)  v0 = 0;
                        if (v1<0)  v1 = 0;
                        if (v0>=h) v0 = h-1;
                        if (v1>=h) v1 = h-1;
                    }
                    pixel_t texels[4];
                    uint32_t mm[4];
                    tx.surface.read(&tx.surface, c, u0, v0, &texels[0]);
                    tx.surface.read(&tx.surface, c, u0, v1, &texels[1]);
                    tx.surface.read(&tx.surface, c, u1, v0, &texels[2]);
                    tx.surface.read(&tx.surface, c, u1, v1, &texels[3]);
                    u = (u >> 12) & 0xF; 
                    v = (v >> 12) & 0xF;
                    u += u>>3;
                    v += v>>3;
                    mm[0] = (0x10 - u) * (0x10 - v);
                    mm[1] = (0x10 - u) * v;
                    mm[2] = u * (0x10 - v);
                    mm[3] = 0x100 - (mm[0] + mm[1] + mm[2]);
                    for (int j=0 ; j<4 ; j++) {
                        texel.s[j] = texels[0].s[j];
                        if (!texel.s[j]) continue;
                        texel.s[j] += 8;
                        texel.c[j] =    texels[0].c[j]*mm[0] +
                                        texels[1].c[j]*mm[1] +
                                        texels[2].c[j]*mm[2] +
                                        texels[3].c[j]*mm[3] ;
                    }
                }

                // Texture environnement...
                for (int j=0 ; j<4 ; j++) {
                    uint32_t& Cf = fragment.c[j];
                    uint32_t& Ct = texel.c[j];
                    uint8_t& sf  = fragment.s[j];
                    uint8_t& st  = texel.s[j];
                    uint32_t At = texel.c[0];
                    uint8_t sat = texel.s[0];
                    switch (tx.env) {
                    case GGL_REPLACE:
                        if (st) {
                            Cf = Ct;
                            sf = st;
                        }
                        break;
                    case GGL_MODULATE:
                        if (st) {
                            uint32_t factor = Ct + (Ct>>(st-1));
                            Cf = (Cf * factor) >> st;
                        }
                        break;
                    case GGL_DECAL:
                        if (sat) {
                            rescale(Cf, sf, Ct, st);
                            Cf += ((Ct - Cf) * (At + (At>>(sat-1)))) >> sat;
                        }
                        break;
                    case GGL_BLEND:
                        if (st) {
                            uint32_t Cc = tx.env_color[i];
                            if (sf>8)       Cc = (Cc * ((1<<sf)-1))>>8;
                            else if (sf<8)  Cc = (Cc - (Cc>>(8-sf)))>>(8-sf);
                            uint32_t factor = Ct + (Ct>>(st-1));
                            Cf = ((((1<<st) - factor) * Cf) + Ct*Cc)>>st;
                        }
                        break;
                    case GGL_ADD:
                        if (st) {
                            rescale(Cf, sf, Ct, st);
                            Cf += Ct;
                        }
                        break;
                    }
                }
            }
		}
    
        // coverage application
        if (enables & GGL_ENABLE_AA) {
...
        }
        
        // alpha-test  透明测试
        if (enables & GGL_ENABLE_ALPHA_TEST) {
          ...
        }
        
        // depth test 深度测试
        if (c->state.buffers.depth.format) {
           ....
        }

        // 雾化效果
        if (enables & GGL_ENABLE_FOG) {
           ....
        }

        //混合
        if (enables & GGL_ENABLE_BLENDING) {
            ...
        }

		// write,调用framebuffer_t的写方法
        c->state.buffers.color.write(
                &(c->state.buffers.color), c, x, y, &fragment);
        }

discard:
		// iterate...
        x += 1;
        if (enables & GGL_ENABLE_SMOOTH) {
            r += c->shade.drdx;
            g += c->shade.dgdx;
            b += c->shade.dbdx;
            a += c->shade.dadx;
        }
        z += c->shade.dzdx;
        f += c->shade.dfdx;
	}
}
```
流程如下
- 1.处理纹理
- 2.处理片元覆盖
- 3.透明测试
- 4.深度测试
- 5.雾化效果
- 6.混合纹理
- 6.处理过的像素点将会调用 context_t 中state_t中的framebuffer_t中color中的write方法。这就是上一篇文章聊过的。在OpenGL es makeCurrent时候将会把Surface中存储数据段的地址和framebuffer_t中color的bit字段关联起来。

如果对这些算法感兴趣，可以看看他们对像素的操作。

我们来看看framebuffer_t中的write方法。当通过glDrawArrays的时候，会调用trianglex_validate进行校验，同时赋值函数指针：
```cpp
static void pick_read_write(surface_t* s)
{
    // Choose best reader/writers.
    switch (s->format) {
        case GGL_PIXEL_FORMAT_RGBA_8888:    s->read = readABGR8888;  break;
        case GGL_PIXEL_FORMAT_RGB_565:      s->read = readRGB565;    break;
        default:                            s->read = read_pixel;    break;
    }
    s->write = write_pixel;
}
```

```cpp
void write_pixel(const surface_t* s, context_t* c,
        uint32_t x, uint32_t y, const pixel_t* pixel)
{


    int dither = -1;
    if (c->state.enables & GGL_ENABLE_DITHER) {
        dither = c->ditherMatrix[ (x & GGL_DITHER_MASK) +
                ((y & GGL_DITHER_MASK)<<GGL_DITHER_ORDER_SHIFT) ];
    }

    const GGLFormat* f = &(c->formats[s->format]);
    int32_t index = x + (s->stride * y);
    uint8_t* const data = s->data + index * f->size;
        
    uint32_t mask = 0;
    uint32_t v = 0;
    for (int i=0 ; i<4 ; i++) {
        const int component_mask = 1 << i;
        if (f->components>=GGL_LUMINANCE &&
                (i==GGLFormat::GREEN || i==GGLFormat::BLUE)) {
            // destinations L formats don't have G or B
            continue;
        }
        const int l = f->c[i].l;
        const int h = f->c[i].h;
        if (h && (c->state.mask.color & component_mask)) {
            mask |= (((1<<(h-l))-1)<<l);
            uint32_t u = pixel->c[i];
            int32_t pixelSize = pixel->s[i];
            if (pixelSize < (h-l)) {
                u = expand(u, pixelSize, h-l);
                pixelSize = h-l;
            }
            v = downshift_component(v, u, pixelSize, 0, h, l, 0, 0, dither);
        }
    }

    if ((c->state.mask.color != 0xF) || 
        (c->state.enables & GGL_ENABLE_LOGIC_OP)) {
        uint32_t d = 0;
        switch (f->size) {
            case 1:	d = *data;									break;
            case 2:	d = *(uint16_t*)data;						break;
            case 3:	d = (data[2]<<16)|(data[1]<<8)|data[0];     break;
            case 4:	d = GGL_RGBA_TO_HOST(*(uint32_t*)data);		break;
        }
        if (c->state.enables & GGL_ENABLE_LOGIC_OP) {
            v = logic_op(c->state.logic_op.opcode, v, d);            
            v &= mask;
        }
        v |= (d & ~mask);
    }

    switch (f->size) {
        case 1:		*data = v;									break;
        case 2:		*(uint16_t*)data = v;						break;
        case 3:
            data[0] = v;
            data[1] = v>>8;
            data[2] = v>>16;
            break;
        case 4:		*(uint32_t*)data = GGL_HOST_TO_RGBA(v);     break;
    }
}
```
在这个方法里面，如果没办法完全看懂没关系，但是能知道获取了surface_t中的data字段，这个字段刚好和Surface的bit地址绑定起来，此时写进去数据，就是写进Surface的bit字段中。

写进去了，但是怎么显示到屏幕呢？

## eglSwapBuffers 交换缓冲区，显示到屏幕
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/)/[EGL](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/)/[eglApi.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libs/EGL/eglApi.cpp)

```cpp
EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface)
{
    return eglSwapBuffersWithDamageKHR(dpy, surface, NULL, 0);
}
```
```cpp
EGLBoolean eglSwapBuffersWithDamageKHR(EGLDisplay dpy, EGLSurface draw,
        EGLint *rects, EGLint n_rects)
{
    ATRACE_CALL();
    clearError();

    const egl_display_ptr dp = validate_display(dpy);
    if (!dp) return EGL_FALSE;

    SurfaceRef _s(dp.get(), draw);
...

    std::vector<android_native_rect_t> androidRects((size_t)n_rects);
    for (int r = 0; r < n_rects; ++r) {
        int offset = r * 4;
        int x = rects[offset];
        int y = rects[offset + 1];
        int width = rects[offset + 2];
        int height = rects[offset + 3];
        android_native_rect_t androidRect;
        androidRect.left = x;
        androidRect.top = y + height;
        androidRect.right = x + width;
        androidRect.bottom = y;
        androidRects.push_back(androidRect);
    }
    native_window_set_surface_damage(s->getNativeWindow(), androidRects.data(), androidRects.size());

    if (s->cnx->egl.eglSwapBuffersWithDamageKHR) {
        return s->cnx->egl.eglSwapBuffersWithDamageKHR(dp->disp.dpy, s->surface,
                rects, n_rects);
    } else {
        return s->cnx->egl.eglSwapBuffers(dp->disp.dpy, s->surface);
    }
}
```
能看到这里面的核心逻辑，首先拿到整个绘制的区域，接着调用native_window_set_surface_damage设置内容，最后根据OpenGL
es是否包含eglSwapBuffersWithDamageKHR方法来决定，如果包含这个优化的方法，就调用Android平台优化过的eglSwapBuffersWithDamageKHR交换缓冲区方法，否则将会调用通用eglSwapBuffers。

### OpenGL es eglSwapBuffers
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[opengl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/)/[libagl](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/)/[egl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/opengl/libagl/egl.cpp)

```cpp
 EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface draw)
{
...

    egl_surface_t* d = static_cast<egl_surface_t*>(draw);
...

    // post the surface
    d->swapBuffers();

    // if it's bound to a context, update the buffer
    if (d->ctx != EGL_NO_CONTEXT) {
        d->bindDrawSurface((ogles_context_t*)d->ctx);
        // if this surface is also the read surface of the context
        // it is bound to, make sure to update the read buffer as well.
        // The EGL spec is a little unclear about this.
        egl_context_t* c = egl_context_t::context(d->ctx);
        if (c->read == draw) {
            d->bindReadSurface((ogles_context_t*)d->ctx);
        }
    }

    return EGL_TRUE;
}
```
核心方法就是调用egl_surface_t的swapBuffers。而egl_surface_t其实就是上一篇文章解析过的egl_window_surface_v2_t对象。下面这个函数就是引出整个图元状态和申请的核心逻辑。

### egl_window_surface_v2_t swapBuffers
```cpp
EGLBoolean egl_window_surface_v2_t::swapBuffers()
{
...

    if (previousBuffer) {
        previousBuffer->common.decRef(&previousBuffer->common); 
        previousBuffer = 0;
    }
    
    unlock(buffer);
    previousBuffer = buffer;
    nativeWindow->queueBuffer(nativeWindow, buffer, -1);
    buffer = 0;

    // dequeue a new buffer
    int fenceFd = -1;
    if (nativeWindow->dequeueBuffer(nativeWindow, &buffer, &fenceFd) == NO_ERROR) {
        sp<Fence> fence(new Fence(fenceFd));
        if (fence->wait(Fence::TIMEOUT_NEVER)) {
            nativeWindow->cancelBuffer(nativeWindow, buffer, fenceFd);
            return setError(EGL_BAD_ALLOC, EGL_FALSE);
        }

        // reallocate the depth-buffer if needed
        if ((width != buffer->width) || (height != buffer->height)) {
            // TODO: we probably should reset the swap rect here
            // if the window size has changed
            width = buffer->width;
            height = buffer->height;
            if (depth.data) {
                free(depth.data);
                depth.width   = width;
                depth.height  = height;
                depth.stride  = buffer->stride;
                uint64_t allocSize = static_cast<uint64_t>(depth.stride) *
                        static_cast<uint64_t>(depth.height) * 2;
                if (depth.stride < 0 || depth.height > INT_MAX ||
                        allocSize > UINT32_MAX) {
                    setError(EGL_BAD_ALLOC, EGL_FALSE);
                    return EGL_FALSE;
                }
                depth.data    = (GGLubyte*)malloc(allocSize);
                if (depth.data == 0) {
                    setError(EGL_BAD_ALLOC, EGL_FALSE);
                    return EGL_FALSE;
                }
            }
        }

        // keep a reference on the buffer
        buffer->common.incRef(&buffer->common);

        // finally pin the buffer down
        if (lock(buffer, GRALLOC_USAGE_SW_READ_OFTEN |
                GRALLOC_USAGE_SW_WRITE_OFTEN, &bits) != NO_ERROR) {
...
        }
    } else {
        return setError(EGL_BAD_CURRENT_SURFACE, EGL_FALSE);
    }

    return EGL_TRUE;
}
```

在这个过程中做了两个十分重要的事情：
- 1.调用了nativeWindow->queueBuffer 把之前通过egl_window_surface_v2_t申请出来的图元进行queue进入相关的参数生成一个个BufferItem插入到缓冲队列中,等待消费
- 2.调用了nativeWindow->dequeueBuffer 把buffer设置进去并且根据图元生产者那边返回来的slotId(也就是从freeSlot和freebuffer中找到的空闲GraphicBuffer对应缓冲队列的index)返回，也会按照需求新生成一个新的GraphicBuffer。

一般来说，都是先调用dequeue生产一个新的GraphicBuffer，之后调用queueBuffer把当前的图元对应的BufferItem放到缓冲队列。那么这里面的意思很简单，就是swapBuffers绘制上一帧数的内容，接着生成新的一帧，继续在OpenGL es中绘制。

这里能第一次看到fence同步栅的存在。其实原因很简单，一般来说CPU不知道GPU什么时候会完成，需要一个同步栅去通过GPU和CPU。

## Android平台 OpenGL es的优化

能看到其实在纹理过程中，涉及到了不少临时图层，如果遇到纹理十分大时候，临时图层来来去去的拷贝十分影响速度。因此在Android中使用了直接纹理机制。

其核心的思想是，不需要临时图层，Android系统直接提供ANativeBuffer，你们绘制在上面就好了。

使用方法如下：
```cpp
//生成一个直接纹理缓冲
EGLImageKHR eglSrcImage = eglCreateImageKHR(eglDisplay,
EGL_NO_CONTEXT,EGL_NATIVE_BUFFER_ANDROID,(EGLClientBuffer)&sSrcBuffer,0);
//生成
glGenTextures(1,&texID);
//绑定
glBindTexture(GL_TEXTURE_2D,texID);
//存储数据
glEGLImageTargetTexture2DOES(GL_TEXTURE_2D,eglSrcImage);
```

我们需要生成一个EGLImage对象，承载像素数据，记者直接操作EGLImage。其中EGLClientBuffer这个参数就是ANativeWindowBuffer。

### eglCreateImageKHR
```cpp
EGLImageKHR eglCreateImageKHR(EGLDisplay dpy, EGLContext ctx, EGLenum target,
        EGLClientBuffer buffer, const EGLint *attrib_list)
{
    clearError();

    const egl_display_ptr dp = validate_display(dpy);
    if (!dp) return EGL_NO_IMAGE_KHR;

    ContextRef _c(dp.get(), ctx);
    egl_context_t * const c = _c.get();

    std::vector<EGLint> strippedAttribList;
    for (const EGLint *attr = attrib_list; attr && attr[0] != EGL_NONE; attr += 2) {
        if (attr[0] == EGL_GL_COLORSPACE_KHR &&
            dp->haveExtension("EGL_EXT_image_gl_colorspace")) {
            if (attr[1] != EGL_GL_COLORSPACE_LINEAR_KHR &&
                attr[1] != EGL_GL_COLORSPACE_SRGB_KHR) {
                continue;
            }
        }
        strippedAttribList.push_back(attr[0]);
        strippedAttribList.push_back(attr[1]);
    }
    strippedAttribList.push_back(EGL_NONE);

    EGLImageKHR result = EGL_NO_IMAGE_KHR;
    egl_connection_t* const cnx = &gEGLImpl;
    if (cnx->dso && cnx->egl.eglCreateImageKHR) {
        result = cnx->egl.eglCreateImageKHR(
                dp->disp.dpy,
                c ? c->context : EGL_NO_CONTEXT,
                target, buffer, strippedAttribList.data());
    }
    return result;
}
```
核心方法很简单就是获取屏幕中的配置参数，调用了OpenGL es的eglCreateImageKHR。

### OpenGL es的eglCreateImageKHR
```cpp
EGLImageKHR eglCreateImageKHR(EGLDisplay dpy, EGLContext ctx, EGLenum target,
        EGLClientBuffer buffer, const EGLint* /*attrib_list*/)
{
    if (egl_display_t::is_valid(dpy) == EGL_FALSE) {
        return setError(EGL_BAD_DISPLAY, EGL_NO_IMAGE_KHR);
    }
    if (ctx != EGL_NO_CONTEXT) {
        return setError(EGL_BAD_CONTEXT, EGL_NO_IMAGE_KHR);
    }
    if (target != EGL_NATIVE_BUFFER_ANDROID) {
        return setError(EGL_BAD_PARAMETER, EGL_NO_IMAGE_KHR);
    }

    ANativeWindowBuffer* native_buffer = (ANativeWindowBuffer*)buffer;

    if (native_buffer->common.magic != ANDROID_NATIVE_BUFFER_MAGIC)
        return setError(EGL_BAD_PARAMETER, EGL_NO_IMAGE_KHR);

    if (native_buffer->common.version != sizeof(ANativeWindowBuffer))
        return setError(EGL_BAD_PARAMETER, EGL_NO_IMAGE_KHR);

    switch (native_buffer->format) {
        case HAL_PIXEL_FORMAT_RGBA_8888:
        case HAL_PIXEL_FORMAT_RGBX_8888:
        case HAL_PIXEL_FORMAT_RGB_888:
        case HAL_PIXEL_FORMAT_RGB_565:
        case HAL_PIXEL_FORMAT_BGRA_8888:
            break;
        default:
            return setError(EGL_BAD_PARAMETER, EGL_NO_IMAGE_KHR);
    }

    native_buffer->common.incRef(&native_buffer->common);
    return (EGLImageKHR)native_buffer;
}
```

在这里面完全没有做什么工作，就是检测了像素规格，把ANativeWindowBuffer强转为EGLImageKHR返回。


### glEGLImageTargetTexture2DOES
```cpp
void glEGLImageTargetTexture2DOES(GLenum target, GLeglImageOES image)
{
    ogles_context_t* c = ogles_context_t::get();
...
    ANativeWindowBuffer* native_buffer = (ANativeWindowBuffer*)image;
...
    // bind it to the texture unit
    sp<EGLTextureObject> tex = getAndBindActiveTextureObject(c);
    tex->setImage(native_buffer);
}
```

能看到此时会拿到当前活跃target对应的EGLTextureObject，并且设置到Image中，其实就是设置到EGLTextureObject中的buffer参数中。

这样就就不会有一次glTextImage2D一样有一个中间图层诞生，这样加速了整个图层计算速度。同时让OpenGL es可以和Skia等其他画笔进行快速协调合作。



## 总结
先用一张图总结一下：
![OpenGLes纹理绘制过程.png](/images/OpenGLes纹理绘制过程.png)


到这里，我就把Android对OpenGL es的纹理开发流程的源码重新梳理了一遍，对整个机制有了更加深刻的理解。

其实第一次接触OpenGL es为什么要先glGen接着glBind生成一个顶点/缓冲/纹理等对象进行操作。内部是怎么一个机制，真的套路都是背的。阅读源码之后，才知道原来是这么简单。

- 每一个glGen其实就是诞生找到一个合适空闲句柄，每一个glBind这个时候才是把句柄和OpenGL es底层的对象真的绑定起来，并且让ogles_context_t持有当前操作对象。这也是为什么我们需要glBind之后才进行操作。而且一般句柄为0在OpenGL es中，在管理数组中要么是默认要么就是无效，所以我们接触绑定可以把句柄设置为0.

- 当我们调用一次glTextImge2D的时候，将数据传到一个临时的图层中进行拷贝持有。因此，我们每一次不需要的时候，记得要glDelete对应的纹理还有其他对象，因为会不少临时变量占用不释放。

- 除了顶点和缓冲之外，如纹理，深度测试，透明测试，雾化，裁剪等需要图层需要图层承载的操作，都会设置到state_t一个象征着当前操作都设置进去的操作的参数。就以纹理绘制为例子，ogles_context_t 的texture的数组保存着EGLTextureObject，在state_t保存着每一个EGLTextureObject对应的参数，当绘制的时候将会

- 所有图层(framebuffer_t)都是在一个state_t一个当前状态结构体控制，context_t则是状态控制器，能够快捷的获得一些需要的参数。

- 如纹理这种特殊一点，需要进行一次激活，让最外层的上下文持有当前的活跃对象。也是因为纹理的特殊性不像顶点和缓冲，有时候不需要绘制。

- glDrawArrays 和 glDrawElements 才是把统统这些操作绘制到一个临时的图层。

- eglSwapBuffer 它的作用就是真正把图元绘制到各个平台中。

有了本文的铺垫，引出了GraphicBuffer这个对象，它是怎么诞生的，又是怎么传输的。下一篇文章将会和大家聊聊，GraphicBuffer的生成，以及Android新版本引入的GraphicBuffer的内核控制机制ion.c，来比较比较ashmem之间的区别，看看为什么Android要抛弃它。





















