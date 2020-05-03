---
title: Android 重学系列 渲染图层-图元缓冲队列初始化
top: false
cover: false
date: 2020-01-25 23:33:12
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android Framework
---
# 前言
经过上一篇文章，对开机启动动画的流程梳理，引出了实际上在开机启动动画中，并没有Activity，而是通过OpenGL es进行渲染，最后通过某种方式，把数据交给Android渲染系统。

本文，先来探索在调用OpenGL es进行渲染的前期准备。

如果遇到问题，可以来本文讨论[https://www.jianshu.com/p/a2b5f82cf75f](https://www.jianshu.com/p/a2b5f82cf75f)


# 正文
让我们回忆一下，上一篇开机动画OpenGL es 使用步骤，大致分为如下几个：
- 1.SurfaceComposerClient::getBuiltInDisplay 从SF中查询可用的物理屏幕
- 2.SurfaceComposerClient::getDisplayInfo 从SF中获取屏幕的详细信息
- 3.session()->createSurface 通过Client创建绘制平面控制中心
- 4.t.setLayer(control, 0x40000000) 设置当前layer的层级
- 5.control->getSurface 获取真正的绘制平面对象
- 6.eglGetDisplay 获取opengl es的默认主屏幕，加载OpenGL es
- 7.eglInitialize 初始化屏幕对象和着色器缓存
- 8.eglChooseConfig 自动筛选出最合适的配置
- 9.eglCreateWindowSurface 从Surface中创建一个opengl es的surface
- 10.eglCreateContext 创建当前opengl es 的上下文
- 11.eglQuerySurface 查找当前环境的宽高属性
- 12.eglMakeCurrent 把上下文Context，屏幕display还有渲染面surface,线程关联起来。
- 13.调用OpenGL es本身特性，绘制顶点，纹理等。
- 14. eglSwapBuffers 交换绘制好的缓冲区
- 15.销毁资源
我们就沿着这个逻辑看看在这个过程中Android的渲染系统在其中担任了什么角色。

## SurfaceComposerClient::getBuiltInDisplay
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[SurfaceComposerClient.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/SurfaceComposerClient.cpp)

```cpp
sp<IBinder> SurfaceComposerClient::getBuiltInDisplay(int32_t id) {
    return ComposerService::getComposerService()->getBuiltInDisplay(id);
}
```
ComposerService本质上是ISurfaceComposer 一个BpBinder对象，对应着BnBinder对象是SF，也就到了SF的getBuiltInDisplay。

### SF getBuiltInDisplay
```cpp
sp<IBinder> SurfaceFlinger::getBuiltInDisplay(int32_t id) {
    if (uint32_t(id) >= DisplayDevice::NUM_BUILTIN_DISPLAY_TYPES) {
        return nullptr;
    }
    return mBuiltinDisplays[id];
}
```
还记得我初始化第一篇聊过这个数据结构吗？mBuiltinDisplays 将会持有根据每一个displayID也同时displayType持有一个BBinder作为核心。然而此时的BBinder只是一个通信基础，还没有任何处理命令的逻辑。我们需要看下面那个方法做了什么？

## SurfaceComposerClient::getDisplayInfo 
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)

```cpp
status_t SurfaceComposerClient::getDisplayConfigs(
        const sp<IBinder>& display, Vector<DisplayInfo>* configs)
{
    return ComposerService::getComposerService()->getDisplayConfigs(display, configs);
}

int SurfaceComposerClient::getActiveConfig(const sp<IBinder>& display) {
    return ComposerService::getComposerService()->getActiveConfig(display);
}

status_t SurfaceComposerClient::getDisplayInfo(const sp<IBinder>& display,
        DisplayInfo* info) {
    Vector<DisplayInfo> configs;
    status_t result = getDisplayConfigs(display, &configs);
    if (result != NO_ERROR) {
        return result;
    }

    int activeId = getActiveConfig(display);
    if (activeId < 0) {
        ALOGE("No active configuration found");
        return NAME_NOT_FOUND;
    }

    *info = configs[static_cast<size_t>(activeId)];
    return NO_ERROR;
}
```
该方法通过了两次Binder通信进行屏幕数据的获取，第一次getDisplayConfigs，如果成功则getDisplayConfigs获取第二次。

### SF getDisplayConfigs
```cpp
status_t SurfaceFlinger::getDisplayConfigs(const sp<IBinder>& display,
        Vector<DisplayInfo>* configs) {
...

    int32_t type = NAME_NOT_FOUND;
    for (int i=0 ; i<DisplayDevice::NUM_BUILTIN_DISPLAY_TYPES ; i++) {
        if (display == mBuiltinDisplays[i]) {
            type = i;
            break;
        }
    }

    if (type < 0) {
        return type;
    }

    // TODO: Not sure if display density should handled by SF any longer
    class Density {
        static int getDensityFromProperty(char const* propName) {
            char property[PROPERTY_VALUE_MAX];
            int density = 0;
            if (property_get(propName, property, nullptr) > 0) {
                density = atoi(property);
            }
            return density;
        }
    public:
        static int getEmuDensity() {
            return getDensityFromProperty("qemu.sf.lcd_density"); }
        static int getBuildDensity()  {
            return getDensityFromProperty("ro.sf.lcd_density"); }
    };

    configs->clear();

    ConditionalLock _l(mStateLock,
            std::this_thread::get_id() != mMainThreadId);
    for (const auto& hwConfig : getHwComposer().getConfigs(type)) {
        DisplayInfo info = DisplayInfo();

        float xdpi = hwConfig->getDpiX();
        float ydpi = hwConfig->getDpiY();
//默认主屏幕的获取DPI的法则
        if (type == DisplayDevice::DISPLAY_PRIMARY) {
            // The density of the device is provided by a build property
            float density = Density::getBuildDensity() / 160.0f;
            if (density == 0) {
                // the build doesn't provide a density -- this is wrong!
                // use xdpi instead
                ALOGE("ro.sf.lcd_density must be defined as a build property");
                density = xdpi / 160.0f;
            }
            if (Density::getEmuDensity()) {
                xdpi = ydpi = density = Density::getEmuDensity();
                density /= 160.0f;
            }
            info.density = density;

            // TODO: this needs to go away (currently needed only by webkit)
            sp<const DisplayDevice> hw(getDefaultDisplayDeviceLocked());
            info.orientation = hw ? hw->getOrientation() : 0;
        } else {
...
        }

        info.w = hwConfig->getWidth();
        info.h = hwConfig->getHeight();
        info.xdpi = xdpi;
        info.ydpi = ydpi;
        info.fps = 1e9 / hwConfig->getVsyncPeriod();
        info.appVsyncOffset = vsyncPhaseOffsetNs;
        info.presentationDeadline = hwConfig->getVsyncPeriod() -
                sfVsyncPhaseOffsetNs + 1000000;

        info.secure = true;

        if (type == DisplayDevice::DISPLAY_PRIMARY &&
            mPrimaryDisplayOrientation & DisplayState::eOrientationSwapMask) {
            std::swap(info.w, info.h);
        }

        configs->push_back(info);
    }

    return NO_ERROR;
}
```
能看到这里BBinder实际并不是作为通信使用，而是作为对象标示。用来筛选出对应的屏幕的type是什么。

核心是下面这一段，先从HWComposer中获取该id的屏幕的信息，并且保存在DisplayInfo。我们关注Density，也就是dpi是怎么计算的。

> 解释一下dpi是什么，dpi是对角线每一个英寸下有多少像素。

计算就很简单就是一个普通勾股定理即可。

> 其实这个数值是由ro.sf.lcd_density和qemu.sf.lcd_density属性决定的。当然如果ro.sf.lcd_density没有数值，则density则是由HWC的getConfigs的xdpi/160决定。最后找找qemu.sf.lcd_density，如果有数值，则xdpi，ydpi全部都是它，但是density则是qemu.sf.lcd_density数值/160.换句话说，qemu.sf.lcd_density这个LCD全局参数起了决定性的因素。

当然，没有设置这两个属性，xdpi和ydpi则是默认的从HWC获取出来的数据,density 为xdpi/160f。

当然此时还会判断整个屏幕的横竖状态，最后在做一次宽高的颠倒。

### HWComposer getConfigs
```cpp
std::vector<std::shared_ptr<const HWC2::Display::Config>>
        HWComposer::getConfigs(int32_t displayId) const {
    RETURN_IF_INVALID_DISPLAY(displayId, {});

    auto& displayData = mDisplayData[displayId];
    auto configs = mDisplayData[displayId].hwcDisplay->getConfigs();
    if (displayData.configMap.empty()) {
        for (size_t i = 0; i < configs.size(); ++i) {
            displayData.configMap[i] = configs[i];
        }
    }
    return configs;
}
```
还记得在SF初始化中，当onHotPlugin进入到HWC之后，先添加到HWCDevice中，之后就会添加到mDisplayData中。其实就是HWC::Display对象。而这个对象在初始化的时候就会读取对应配置保存起来。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[DisplayHardware](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/)/[HWC2.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/DisplayHardware/HWC2.cpp)

```cpp
void Display::loadConfigs()
{
    ALOGV("[%" PRIu64 "] loadConfigs", mId);

    std::vector<Hwc2::Config> configIds;
    auto intError = mComposer.getDisplayConfigs(mId, &configIds);
    auto error = static_cast<Error>(intError);
    if (error != Error::None) {
        return;
    }

    for (auto configId : configIds) {
        loadConfig(configId);
    }
}

void Display::loadConfig(hwc2_config_t configId)
{
    ALOGV("[%" PRIu64 "] loadConfig(%u)", mId, configId);

    auto config = Config::Builder(*this, configId)
            .setWidth(getAttribute(configId, Attribute::Width))
            .setHeight(getAttribute(configId, Attribute::Height))
            .setVsyncPeriod(getAttribute(configId, Attribute::VsyncPeriod))
            .setDpiX(getAttribute(configId, Attribute::DpiX))
            .setDpiY(getAttribute(configId, Attribute::DpiY))
            .build();
    mConfigs.emplace(configId, std::move(config));
}


int32_t Display::getAttribute(hwc2_config_t configId, Attribute attribute)
{
    int32_t value = 0;
    auto intError = mComposer.getDisplayAttribute(mId, configId,
            static_cast<Hwc2::IComposerClient::Attribute>(attribute),
            &value);
    auto error = static_cast<Error>(intError);
    if (error != Error::None) {
        ALOGE("getDisplayAttribute(%" PRIu64 ", %u, %s) failed: %s (%d)", mId,
                configId, to_string(attribute).c_str(),
                to_string(error).c_str(), intError);
        return -1;
    }
    return value;
}
```
我们找到对应保存硬件的configId，最后通过getDisplayAttribute查找，每一个属性是什么。

此时就会到Hal层中读取屏幕信息。根据上两节的UML图就能知道本质上是通过hw_device_t和硬件进行通信，那么我们就继续以msm8960为基准阅读。
文件：/[hardware](http://androidxref.com/9.0.0_r3/xref/hardware/)/[qcom](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/)/[display](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/)/[msm8960](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/)/[libhwcomposer](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/)/[hwc.cpp](http://androidxref.com/9.0.0_r3/xref/hardware/qcom/display/msm8960/libhwcomposer/hwc.cpp)

```cpp
int hwc_getDisplayAttributes(struct hwc_composer_device_1* dev, int disp,
        uint32_t config, const uint32_t* attributes, int32_t* values) {

    hwc_context_t* ctx = (hwc_context_t*)(dev);
    //If hotpluggable displays are inactive return error
    if(disp == HWC_DISPLAY_EXTERNAL && !ctx->dpyAttr[disp].connected) {
        return -1;
    }

    //From HWComposer
    static const uint32_t DISPLAY_ATTRIBUTES[] = {
        HWC_DISPLAY_VSYNC_PERIOD,
        HWC_DISPLAY_WIDTH,
        HWC_DISPLAY_HEIGHT,
        HWC_DISPLAY_DPI_X,
        HWC_DISPLAY_DPI_Y,
        HWC_DISPLAY_NO_ATTRIBUTE,
    };

    const int NUM_DISPLAY_ATTRIBUTES = (sizeof(DISPLAY_ATTRIBUTES) /
            sizeof(DISPLAY_ATTRIBUTES)[0]);

    for (size_t i = 0; i < NUM_DISPLAY_ATTRIBUTES - 1; i++) {
        switch (attributes[i]) {
        case HWC_DISPLAY_VSYNC_PERIOD:
            values[i] = ctx->dpyAttr[disp].vsync_period;
            break;
        case HWC_DISPLAY_WIDTH:
            values[i] = ctx->dpyAttr[disp].xres;
            ALOGD("%s disp = %d, width = %d",__FUNCTION__, disp,
                    ctx->dpyAttr[disp].xres);
            break;
        case HWC_DISPLAY_HEIGHT:
            values[i] = ctx->dpyAttr[disp].yres;
            ALOGD("%s disp = %d, height = %d",__FUNCTION__, disp,
                    ctx->dpyAttr[disp].yres);
            break;
        case HWC_DISPLAY_DPI_X:
            values[i] = (int32_t) (ctx->dpyAttr[disp].xdpi*1000.0);
            break;
        case HWC_DISPLAY_DPI_Y:
            values[i] = (int32_t) (ctx->dpyAttr[disp].ydpi*1000.0);
            break;
        default:
            ALOGE("Unknown display attribute %d",
                    attributes[i]);
            return -EINVAL;
        }
    }
    return 0;
}
```
其实这个时候就是检测dpyAttr对应id中所有的ydpi，xdpi，xres，xdpi，vsync_period的信息。这个数组很熟悉，就是onHotPlugin的时候，通过uevent线程的socket回调上来的信息。

## SF getActiveConfig
```cpp
int SurfaceFlinger::getActiveConfig(const sp<IBinder>& display) {
    if (display == nullptr) {
        ALOGE("%s : display is nullptr", __func__);
        return BAD_VALUE;
    }

    sp<const DisplayDevice> device(getDisplayDevice(display));
    if (device != nullptr) {
        return device->getActiveConfig();
    }

    return BAD_VALUE;
}
```
 此时继续在用BBinder作为key，找到DisplayDevice，使用DisplayDevice的getActiveConfig。而这个对象是什么？其实就是onHotPlugin的时候，调用setupNewDisplayDeviceInternal，装载进来的参数。
```cpp
    if (state.type < DisplayDevice::DISPLAY_VIRTUAL) {
        hw->setActiveConfig(getHwComposer().getActiveConfigIndex(state.type));
    }
```
而这个参数还是调用了HWC的getActiveConfigIndex，从Hal中设置了活跃的ConfigId到DisplayDevice中。之后就能拿到这个活跃的ID了。

HWC的getActiveConfigIndex 本质上还是调用了HAL的getActiveConfig方法。而这个方法又是依赖setActiveConfig保存在HWC2On1Adapter::Display中。

什么时候设置呢？还记得我在WMS系列中聊过的[RootWindowConatiner]([https://www.jianshu.com/p/1fd180ea5d0e](https://www.jianshu.com/p/1fd180ea5d0e)
)的吗？它会调用performSurfacePlacement调用DisplayManagerService的performTraversal，通过SF设置当前活跃屏幕的id。它作为所有窗口的根窗口。同时在Activity onResume刷新界面之时，ViewRootImpl的performTraversals会调用聊到了WMS的relayout方法，这个方法刷新WMS中某个窗口的界面的时刻将会performSurfacePlacement。

通过这个方法，把WMS，DMS，SF全部串联起来。

### 小结
思路有点跑远了，getDisplayInfo实际做的事情拿到当前活跃的屏幕的屏幕信息。

## SurfaceComposerClient createSurface
我们来回忆下，这个方法是怎么使用的：
```cpp
    sp<SurfaceControl> control = session()->createSurface(String8("BootAnimation"),
            dinfo.w, dinfo.h, PIXEL_FORMAT_RGB_565);
```
能看到开机动画设置Surface，设置了Surface的名字，宽高以及Surface的像素格式是RGB-565.

注意，这里是整个SF渲染画面前期准备最为核心的步骤。

```cpp
sp<SurfaceControl> SurfaceComposerClient::createSurface(
        const String8& name,
        uint32_t w,
        uint32_t h,
        PixelFormat format,
        uint32_t flags,
        SurfaceControl* parent,
        int32_t windowType,
        int32_t ownerUid)
{
    sp<SurfaceControl> s;
    createSurfaceChecked(name, w, h, format, &s, flags, parent, windowType, ownerUid);
    return s;
}

status_t SurfaceComposerClient::createSurfaceChecked(
        const String8& name,
        uint32_t w,
        uint32_t h,
        PixelFormat format,
        sp<SurfaceControl>* outSurface,
        uint32_t flags,
        SurfaceControl* parent,
        int32_t windowType,
        int32_t ownerUid)
{
    sp<SurfaceControl> sur;
    status_t err = mStatus;

    if (mStatus == NO_ERROR) {
        sp<IBinder> handle;
        sp<IBinder> parentHandle;
        sp<IGraphicBufferProducer> gbp;

        if (parent != nullptr) {
            parentHandle = parent->getHandle();
        }
        err = mClient->createSurface(name, w, h, format, flags, parentHandle,
                windowType, ownerUid, &handle, &gbp);
        ALOGE_IF(err, "SurfaceComposerClient::createSurface error %s", strerror(-err));
        if (err == NO_ERROR) {
            *outSurface = new SurfaceControl(this, handle, gbp, true /* owned */);
        }
    }
    return err;
}
```
此时会调用SF的Client的createSurface创建一个SurfaceControl。能看到传入了一个十分重要的对象IGraphicBufferProducer，这个对象就是图元生产者。

### Client createSurface
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[Client.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/Client.cpp)
```cpp
status_t Client::createSurface(
        const String8& name,
        uint32_t w, uint32_t h, PixelFormat format, uint32_t flags,
        const sp<IBinder>& parentHandle, int32_t windowType, int32_t ownerUid,
        sp<IBinder>* handle,
        sp<IGraphicBufferProducer>* gbp)
{
    sp<Layer> parent = nullptr;
    if (parentHandle != nullptr) {
        auto layerHandle = reinterpret_cast<Layer::Handle*>(parentHandle.get());
        parent = layerHandle->owner.promote();
        if (parent == nullptr) {
            return NAME_NOT_FOUND;
        }
    }
    if (parent == nullptr) {
        bool parentDied;
        parent = getParentLayer(&parentDied);
        // If we had a parent, but it died, we've lost all
        // our capabilities.
        if (parentDied) {
            return NAME_NOT_FOUND;
        }
    }

    /*
     * createSurface must be called from the GL thread so that it can
     * have access to the GL context.
     */
    class MessageCreateLayer : public MessageBase {
        SurfaceFlinger* flinger;
        Client* client;
        sp<IBinder>* handle;
        sp<IGraphicBufferProducer>* gbp;
        status_t result;
        const String8& name;
        uint32_t w, h;
        PixelFormat format;
        uint32_t flags;
        sp<Layer>* parent;
        int32_t windowType;
        int32_t ownerUid;
    public:
        MessageCreateLayer(SurfaceFlinger* flinger,
                const String8& name, Client* client,
                uint32_t w, uint32_t h, PixelFormat format, uint32_t flags,
                sp<IBinder>* handle, int32_t windowType, int32_t ownerUid,
                sp<IGraphicBufferProducer>* gbp,
                sp<Layer>* parent)
            : flinger(flinger), client(client),
              handle(handle), gbp(gbp), result(NO_ERROR),
              name(name), w(w), h(h), format(format), flags(flags),
              parent(parent), windowType(windowType), ownerUid(ownerUid) {
        }
        status_t getResult() const { return result; }
        virtual bool handler() {
            result = flinger->createLayer(name, client, w, h, format, flags,
                    windowType, ownerUid, handle, gbp, parent);
            return true;
        }
    };

    sp<MessageBase> msg = new MessageCreateLayer(mFlinger.get(),
            name, this, w, h, format, flags, handle,
            windowType, ownerUid, gbp, &parent);
    mFlinger->postMessageSync(msg);
    return static_cast<MessageCreateLayer*>( msg.get() )->getResult();
}
```
该方法做了如下事情：
- 1.首先检测当前的需要绘制的面Layer是否有父Layer。有则获取parent的Layer。
- 2.构造一个Handler，等到下一个Loop才进行操作。这个操作就是通过SF调用createLayer创建一个Layer。注意这里继续把Binder接口IGraphicBufferProducer继续传下去。

### SF createLayer
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)

```cpp
status_t SurfaceFlinger::createLayer(
        const String8& name,
        const sp<Client>& client,
        uint32_t w, uint32_t h, PixelFormat format, uint32_t flags,
        int32_t windowType, int32_t ownerUid, sp<IBinder>* handle,
        sp<IGraphicBufferProducer>* gbp, sp<Layer>* parent)
{
    if (int32_t(w|h) < 0) {
        ALOGE("createLayer() failed, w or h is negative (w=%d, h=%d)",
                int(w), int(h));
        return BAD_VALUE;
    }

    status_t result = NO_ERROR;

    sp<Layer> layer;

    String8 uniqueName = getUniqueLayerName(name);

    switch (flags & ISurfaceComposerClient::eFXSurfaceMask) {
        case ISurfaceComposerClient::eFXSurfaceNormal:
            result = createBufferLayer(client,
                    uniqueName, w, h, flags, format,
                    handle, gbp, &layer);

            break;
        case ISurfaceComposerClient::eFXSurfaceColor:
            result = createColorLayer(client,
                    uniqueName, w, h, flags,
                    handle, &layer);
            break;
        default:
            result = BAD_VALUE;
            break;
    }

    if (result != NO_ERROR) {
        return result;
    }

    // window type is WINDOW_TYPE_DONT_SCREENSHOT from SurfaceControl.java
    // TODO b/64227542
    if (windowType == 441731) {
        windowType = 2024; // TYPE_NAVIGATION_BAR_PANEL
        layer->setPrimaryDisplayOnly();
    }

    layer->setInfo(windowType, ownerUid);

    result = addClientLayer(client, *handle, *gbp, layer, *parent);
    if (result != NO_ERROR) {
        return result;
    }
...
    return result;
}
```
核心的逻辑分为2步骤：
- 1.createBufferLayer 创建图层
- 2.addClientLayer 把图层添加到Client

能看到在SF在这个时候会根据当前传进来的type创建不同的Layer，分别是：
- 1.ISurfaceComposerClient::eFXSurfaceNormal 对应BufferLayer
- 2.ISurfaceComposerClient::eFXSurfaceColor 对应 ColorLayer

```cpp
eFXSurfaceNormal = 0x00000000,
eFXSurfaceColor = 0x00020000,
eFXSurfaceMask = 0x000F0000,
```
分别分别是指这2个数值。在这个时候默认0，创建的是BufferLayer。那么这两个Layer（图层）有什么区别呢？其实ColorLayer一般不会使用，BufferLayer内置一套消费者生产者的图元消费逻辑，能够持续不断的更新图元。然而ColorLayer中没有这些逻辑比较小巧，我们可以理解成一个无法变动的图层。在现在的复杂的UI交互里面，用武之地比较少。

以后遇到再解析ColorLayer，我们需要集中精力给BufferLayer。


#### createBufferLayer 创建图层
```cpp
status_t SurfaceFlinger::createBufferLayer(const sp<Client>& client,
        const String8& name, uint32_t w, uint32_t h, uint32_t flags, PixelFormat& format,
        sp<IBinder>* handle, sp<IGraphicBufferProducer>* gbp, sp<Layer>* outLayer)
{
    // initialize the surfaces
    switch (format) {
    case PIXEL_FORMAT_TRANSPARENT:
    case PIXEL_FORMAT_TRANSLUCENT:
        format = PIXEL_FORMAT_RGBA_8888;
        break;
    case PIXEL_FORMAT_OPAQUE:
        format = PIXEL_FORMAT_RGBX_8888;
        break;
    }

    sp<BufferLayer> layer = new BufferLayer(this, client, name, w, h, flags);
    status_t err = layer->setBuffers(w, h, format, flags);
    if (err == NO_ERROR) {
        *handle = layer->getHandle();
        *gbp = layer->getProducer();
        *outLayer = layer;
    }
    return err;
}
```
这里会判断传进来的format，如果是需要设定透明色，则强制设置format为RGBA_8888模式。最后生成一个BufferLayer，把BufferLayer中的句柄以及图元生产者返回客户端(此时是SurfaceComposerClient中的SurfaceControl)。



##### Layer的初始化
文件:/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[Layer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/Layer.cpp)
```
Layer::Layer(SurfaceFlinger* flinger, const sp<Client>& client, const String8& name, uint32_t w,
             uint32_t h, uint32_t flags)
      : contentDirty(false),
        sequence(uint32_t(android_atomic_inc(&sSequence))),
        mFlinger(flinger),
        mPremultipliedAlpha(true),
        mName(name),
        mTransactionFlags(0),
        mPendingStateMutex(),
        mPendingStates(),
        mQueuedFrames(0),
        mSidebandStreamChanged(false),
        mActiveBufferSlot(BufferQueue::INVALID_BUFFER_SLOT),
        mCurrentTransform(0),
        mOverrideScalingMode(-1),
        mCurrentOpacity(true),
        mCurrentFrameNumber(0),
        mFrameLatencyNeeded(false),
        mFiltering(false),
        mNeedsFiltering(false),
        mProtectedByApp(false),
        mClientRef(client),
        mPotentialCursor(false),
        mQueueItemLock(),
        mQueueItemCondition(),
        mQueueItems(),
        mLastFrameNumberReceived(0),
        mAutoRefresh(false),
        mFreezeGeometryUpdates(false),
        mCurrentChildren(LayerVector::StateSet::Current),
        mDrawingChildren(LayerVector::StateSet::Drawing) {
    mCurrentCrop.makeInvalid();

    uint32_t layerFlags = 0;
    if (flags & ISurfaceComposerClient::eHidden) layerFlags |= layer_state_t::eLayerHidden;
    if (flags & ISurfaceComposerClient::eOpaque) layerFlags |= layer_state_t::eLayerOpaque;
    if (flags & ISurfaceComposerClient::eSecure) layerFlags |= layer_state_t::eLayerSecure;

    mName = name;
    mTransactionName = String8("TX - ") + mName;

    mCurrentState.active.w = w;
    mCurrentState.active.h = h;
    mCurrentState.flags = layerFlags;
    mCurrentState.active.transform.set(0, 0);
    mCurrentState.crop.makeInvalid();
    mCurrentState.finalCrop.makeInvalid();
    mCurrentState.requestedFinalCrop = mCurrentState.finalCrop;
    mCurrentState.requestedCrop = mCurrentState.crop;
    mCurrentState.z = 0;
    mCurrentState.color.a = 1.0f;
    mCurrentState.layerStack = 0;
    mCurrentState.sequence = 0;
    mCurrentState.requested = mCurrentState.active;
    mCurrentState.appId = 0;
    mCurrentState.type = 0;

    // drawing state & current state are identical
    mDrawingState = mCurrentState;

    const auto& hwc = flinger->getHwComposer();
    const auto& activeConfig = hwc.getActiveConfig(HWC_DISPLAY_PRIMARY);
    nsecs_t displayPeriod = activeConfig->getVsyncPeriod();
    mFrameTracker.setDisplayRefreshPeriod(displayPeriod);

    CompositorTiming compositorTiming;
    flinger->getCompositorTiming(&compositorTiming);
    mFrameEventHistory.initializeCompositorTiming(compositorTiming);
}
```
只需要知道它持有了HWC，flinger等对象即可。

#### BufferLayer的初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayer.cpp)
```cpp

BufferLayer::BufferLayer(SurfaceFlinger* flinger, const sp<Client>& client, const String8& name,
                         uint32_t w, uint32_t h, uint32_t flags)
      : Layer(flinger, client, name, w, h, flags),
        mConsumer(nullptr),
        mTextureName(UINT32_MAX),
        mFormat(PIXEL_FORMAT_NONE),
        mCurrentScalingMode(NATIVE_WINDOW_SCALING_MODE_FREEZE),
        mBufferLatched(false),
        mPreviousFrameNumber(0),
        mUpdateTexImageFailed(false),
        mRefreshPending(false) {
    ALOGV("Creating Layer %s", name.string());

    mFlinger->getRenderEngine().genTextures(1, &mTextureName);
    mTexture.init(Texture::TEXTURE_EXTERNAL, mTextureName);

    if (flags & ISurfaceComposerClient::eNonPremultiplied) mPremultipliedAlpha = false;

    mCurrentState.requested = mCurrentState.active;

    // drawing state & current state are identical
    mDrawingState = mCurrentState;
}
```
这里面做了两件比较重要的事情：
- 1.genTextures借助RenderEngine生成名字为mTextureName纹理对象
- 2.初始化Texture对象，绑定mTextureName。Texture是一个纹理矩阵的辅助类很简单。

#### BufferLayer onFirstRef 设置图元缓冲队列
仅仅只是有BufferLayer还不够，需要建立起一套生产者，消费者还需要更多东西。在实例化之后的onFirstRef才是真正的核心。
```cpp
void BufferLayer::onFirstRef() {
    // Creates a custom BufferQueue for SurfaceFlingerConsumer to use
    sp<IGraphicBufferProducer> producer;
    sp<IGraphicBufferConsumer> consumer;
    BufferQueue::createBufferQueue(&producer, &consumer, true);
    mProducer = new MonitoredProducer(producer, mFlinger, this);
    mConsumer = new BufferLayerConsumer(consumer,
            mFlinger->getRenderEngine(), mTextureName, this);
    mConsumer->setConsumerUsageBits(getEffectiveUsage(0));
    mConsumer->setContentsChangedListener(this);
    mConsumer->setName(mName);

    if (mFlinger->isLayerTripleBufferingDisabled()) {
        mProducer->setMaxDequeuedBufferCount(2);
    }

    const sp<const DisplayDevice> hw(mFlinger->getDefaultDisplayDevice());
    updateTransformHint(hw);
}
```
在Layer中，我们明确能看到消费者和生产者字样。通过BufferQueue::createBufferQueue 创建核心的生产者和消费者之后最后包装，暴露外面的对象如下：
- 1.IGraphicBufferProducer 图元生产者对应MonitoredProducer
- 2.IGraphicBufferConsumer 图元消费者对应BufferLayerConsumer

紧接着有一个核心的逻辑，图元消费者设置了ContentsChangedListener监听，当需要刷新的时候，将会回调这个接口让消费者消费。

### BufferQueue::createBufferQueue 创建核心的生产者和消费者
```cpp
void BufferQueue::createBufferQueue(sp<IGraphicBufferProducer>* outProducer,
        sp<IGraphicBufferConsumer>* outConsumer,
        bool consumerIsSurfaceFlinger) {
    sp<BufferQueueCore> core(new BufferQueueCore());
    sp<IGraphicBufferProducer> producer(new BufferQueueProducer(core, consumerIsSurfaceFlinger));

    sp<IGraphicBufferConsumer> consumer(new BufferQueueConsumer(core));
    *outProducer = producer;
    *outConsumer = consumer;
}
```
整个核心有3个对象：
- 1.BufferQueueCore 缓冲队列
- 2.BufferQueueProducer 图元生产者
- 3.BufferQueueConsumer 图元消费者

#### BufferQueueCore 初始化
```cpp
BufferQueueCore::BufferQueueCore() :
    mMutex(),
    mIsAbandoned(false),
    mConsumerControlledByApp(false),
    mConsumerName(getUniqueName()),
    mConsumerListener(),
    mConsumerUsageBits(0),
    mConsumerIsProtected(false),
    mConnectedApi(NO_CONNECTED_API),
    mLinkedToDeath(),
    mConnectedProducerListener(),
    mSlots(),
    mQueue(),
    mFreeSlots(),
    mFreeBuffers(),
    mUnusedSlots(),
    mActiveBuffers(),
    mDequeueCondition(),
    mDequeueBufferCannotBlock(false),
    mDefaultBufferFormat(PIXEL_FORMAT_RGBA_8888),
    mDefaultWidth(1),
    mDefaultHeight(1),
    mDefaultBufferDataSpace(HAL_DATASPACE_UNKNOWN),
    mMaxBufferCount(BufferQueueDefs::NUM_BUFFER_SLOTS),
    mMaxAcquiredBufferCount(1),
    mMaxDequeuedBufferCount(1),
    mBufferHasBeenQueued(false),
    mFrameCounter(0),
    mTransformHint(0),
    mIsAllocating(false),
    mIsAllocatingCondition(),
    mAllowAllocation(true),
    mBufferAge(0),
    mGenerationNumber(0),
    mAsyncMode(false),
    mSharedBufferMode(false),
    mAutoRefresh(false),
    mSharedBufferSlot(INVALID_BUFFER_SLOT),
    mSharedBufferCache(Rect::INVALID_RECT, 0, NATIVE_WINDOW_SCALING_MODE_FREEZE,
            HAL_DATASPACE_UNKNOWN),
    mLastQueuedSlot(INVALID_BUFFER_SLOT),
    mUniqueId(getUniqueId())
{
    int numStartingBuffers = getMaxBufferCountLocked();
    for (int s = 0; s < numStartingBuffers; s++) {
        mFreeSlots.insert(s);
    }
    for (int s = numStartingBuffers; s < BufferQueueDefs::NUM_BUFFER_SLOTS;
            s++) {
        mUnusedSlots.push_front(s);
    }
}

int BufferQueueCore::getMaxBufferCountLocked() const {
    int maxBufferCount = mMaxAcquiredBufferCount + mMaxDequeuedBufferCount +
            ((mAsyncMode || mDequeueBufferCannotBlock) ? 1 : 0);

    // limit maxBufferCount by mMaxBufferCount always
    maxBufferCount = std::min(mMaxBufferCount, maxBufferCount);

    return maxBufferCount;
}
```
在Core中初始化了一个很重要Slot数组。我发现Android系统很喜欢Slot这种设计，rosalloc也是类似的设计。slot我暂时称为插槽。

能看到在这个插槽中准备了如下大小的当前Layer最大能申请的图元数以及最大入队图元数，此时两个同步模式的标志位都为false，因此就实际上maxBufferCount为2。mMaxBufferCount为一个编译常量64。

因此此时会设置大小为2的mFreeSlot，也就是2个大小空闲插槽。同时设置剩下62个为mUnusedSlots，是不使用的插槽。

这个插槽，我们能够知道实际就是一个缓冲队列，等待图元插进来。


### BufferQueueProducer 图元生产者初始化
先来看看头文件：
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[include](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/gui/)/[BufferQueueProducer.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/gui/BufferQueueProducer.h)
```cpp
class BufferQueueProducer : public BnGraphicBufferProducer,
                            private IBinder::DeathRecipient 
```
这个对象就是上面IGraphicBufferProducer，因此这个对象会在SF的Layer中存在一个，同时会传递给客户端。

```cpp
BufferQueueProducer::BufferQueueProducer(const sp<BufferQueueCore>& core,
        bool consumerIsSurfaceFlinger) :
    mCore(core),
    mSlots(core->mSlots),
    mConsumerName(),
    mStickyTransform(0),
    mConsumerIsSurfaceFlinger(consumerIsSurfaceFlinger),
    mLastQueueBufferFence(Fence::NO_FENCE),
    mLastQueuedTransform(0),
    mCallbackMutex(),
    mNextCallbackTicket(0),
    mCurrentCallbackTicket(0),
    mCallbackCondition(),
    mDequeueTimeout(-1) {}
```
关键是把当前的Slot传递进来。

### BufferQueueConsumer 图元消费者初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[BufferQueueConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/BufferQueueConsumer.cpp)

```cpp
BufferQueueConsumer::BufferQueueConsumer(const sp<BufferQueueCore>& core) :
    mCore(core),
    mSlots(core->mSlots),
    mConsumerName() {}
```
这里也很简单，持有了Slot缓冲队列。接下来看看他的包裹类。

#### BufferLayerConsumer 初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayerConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayerConsumer.cpp)
```cpp
BufferLayerConsumer::BufferLayerConsumer(const sp<IGraphicBufferConsumer>& bq,
                                         RE::RenderEngine& engine, uint32_t tex, Layer* layer)
      : ConsumerBase(bq, false),
        mCurrentCrop(Rect::EMPTY_RECT),
        mCurrentTransform(0),
        mCurrentScalingMode(NATIVE_WINDOW_SCALING_MODE_FREEZE),
        mCurrentFence(Fence::NO_FENCE),
        mCurrentTimestamp(0),
        mCurrentDataSpace(ui::Dataspace::UNKNOWN),
        mCurrentFrameNumber(0),
        mCurrentTransformToDisplayInverse(false),
        mCurrentSurfaceDamage(),
        mCurrentApi(0),
        mDefaultWidth(1),
        mDefaultHeight(1),
        mFilteringEnabled(true),
        mRE(engine),
        mTexName(tex),
        mLayer(layer),
        mCurrentTexture(BufferQueue::INVALID_BUFFER_SLOT) {

    memcpy(mCurrentTransformMatrix, mtxIdentity.asArray(), sizeof(mCurrentTransformMatrix));

    mConsumer->setConsumerUsageBits(DEFAULT_USAGE_FLAGS);
}
```
它除了持有一个IGraphicBufferConsumer之外，还初始化了一个类型为mat4的mtxIdentity矩阵。如果熟悉着色器语言就知道这个的含义。它就是一个4*4矩阵。


文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayerConsumer.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayerConsumer.h)
```cpp
class BufferLayerConsumer : public ConsumerBase 
```
可以看到他是继承了ConsumerBase，看看ConsumerBase初始化做了什么。

##### ConsumerBase 初始化
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[ConsumerBase.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/ConsumerBase.cpp)
```cpp
ConsumerBase::ConsumerBase(const sp<IGraphicBufferConsumer>& bufferQueue, bool controlledByApp) :
        mAbandoned(false),
        mConsumer(bufferQueue),
        mPrevFinalReleaseFence(Fence::NO_FENCE) {
    // Choose a name using the PID and a process-unique ID.
    mName = String8::format("unnamed-%d-%d", getpid(), createProcessUniqueId());

    wp<ConsumerListener> listener = static_cast<ConsumerListener*>(this);
    sp<IConsumerListener> proxy = new BufferQueue::ProxyConsumerListener(listener);

    status_t err = mConsumer->consumerConnect(proxy, controlledByApp);
    if (err != NO_ERROR) {
...
    } else {
        mConsumer->setConsumerName(mName);
    }
}
```
在ConsumerBase初始化中把当前这个对象转化为ConsumerListener，因为它继承了ConsumerListener。同时mConsumer就是IGraphicBufferConsumer也就是上面的BufferQueueConsumer对象。把当前对象封装成IConsumerListener，调用了consumerConnect注册监听,把行为链接到真正的消费者中。

##### BufferQueueConsumer consumerConnect
文件：[rameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[include](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/gui/)/[BufferQueueConsumer.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/include/gui/BufferQueueConsumer.h)
```cpp
    virtual status_t consumerConnect(const sp<IConsumerListener>& consumer,
            bool controlledByApp) {
        return connect(consumer, controlledByApp);
    }
```
```cpp
status_t BufferQueueConsumer::connect(
        const sp<IConsumerListener>& consumerListener, bool controlledByApp) {
...
    Mutex::Autolock lock(mCore->mMutex);

    if (mCore->mIsAbandoned) {
...
        return NO_INIT;
    }

    mCore->mConsumerListener = consumerListener;
    mCore->mConsumerControlledByApp = controlledByApp;

    return NO_ERROR;
}
```
此时就在BufferQueueCore中设置了消费者监听回调。

####BufferLayerConsumer setContentsChangedListener
接下来BufferLayerConsumer还需要注册一个新的监听是关于内容发生了变化也界面需要刷新的监听。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[BufferLayerConsumer.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/BufferLayerConsumer.cpp)

```cpp
void BufferLayerConsumer::setContentsChangedListener(const wp<ContentsChangedListener>& listener) {
    setFrameAvailableListener(listener);
    Mutex::Autolock lock(mMutex);
    mContentsChangedListener = listener;
}
```
此时会调用ConsumeBase的setFrameAvailableListener

#####  ConsumeBase setFrameAvailableListener
```cpp
void ConsumerBase::setFrameAvailableListener(
        const wp<FrameAvailableListener>& listener) {
    Mutex::Autolock lock(mFrameAvailableMutex);
    mFrameAvailableListener = listener;
}
```

这样就完成了整个监听的循环。类的嵌套太多，让我画一张UML图来整理下。
![Layer与缓冲队列的设计.png](/images/Layer与缓冲队列的设计.png)


> 总结一句话就是，因为FrameAvailableListener最终进入到BufferQueueCore中。当生产者生产了一个图元的时候就会从core中获取FrameAvailableListener调用监听，进入到ConsumeBase中，进一步的回调到BufferLayer中。最后到BufferLayer和SF执行后面的绘制步骤。



### addClientLayer
构造完Layer之后，就需要保存起来。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[services](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/)/[surfaceflinger](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/)/[SurfaceFlinger.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp)

```cpp
status_t SurfaceFlinger::addClientLayer(const sp<Client>& client,
        const sp<IBinder>& handle,
        const sp<IGraphicBufferProducer>& gbc,
        const sp<Layer>& lbc,
        const sp<Layer>& parent)
{
    {
        Mutex::Autolock _l(mStateLock);
       ...
        if (parent == nullptr) {
            mCurrentState.layersSortedByZ.add(lbc);
        } else {
            if (parent->isPendingRemoval()) {
                ALOGE("addClientLayer called with a removed parent");
                return NAME_NOT_FOUND;
            }
            parent->addChild(lbc);
        }

        if (gbc != nullptr) {
            mGraphicBufferProducerList.insert(IInterface::asBinder(gbc).get());
...
        }
        mLayersAdded = true;
        mNumLayers++;
    }

    client->attachLayer(handle, lbc);

    return NO_ERROR;
}
```
如果当前的图层Layer没有任何父Layer，则存储在mCurrentState的layersSortedByZ，也就是Z轴的最末尾，也就是当前渲染图层的最上层。如果有就绑定给父Layer。

最后生产者队列需要插入到mGraphicBufferProducerList全局集合中。

最后调用client的attachLayer把Client的Binder和生产者绑定起来。

##### Client  attachLayer
```cpp
void Client::attachLayer(const sp<IBinder>& handle, const sp<Layer>& layer)
{
    Mutex::Autolock _l(mLock);
    mLayers.add(handle, layer);
}
```
这样也同时存储在Client上。

### SurfaceControl 的初始化
经过上面的流程，完成了整一套的图元缓冲队列的构造。现在让我们回到SurfaceComposerClient中，继续SurfaceControl的初始化。
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[gui](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/)/[SurfaceControl.cpp](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/gui/SurfaceControl.cpp)

```cpp
SurfaceControl::SurfaceControl(
        const sp<SurfaceComposerClient>& client,
        const sp<IBinder>& handle,
        const sp<IGraphicBufferProducer>& gbp,
        bool owned)
    : mClient(client), mHandle(handle), mGraphicBufferProducer(gbp), mOwned(owned)
{
}
```

此时SurfaceControl同时持有了Client的Binder，图元生产者以及SurfaceComposerClient服务。

### SurfaceControl 生产Surface
当SurfaceControl有了之后，需要绘制像素，是绘制在SurfaceControl生成的Surface上。
```cpp
sp<Surface> SurfaceControl::generateSurfaceLocked() const
{
    // This surface is always consumed by SurfaceFlinger, so the
    // producerControlledByApp value doesn't matter; using false.
    mSurfaceData = new Surface(mGraphicBufferProducer, false);

    return mSurfaceData;
}

sp<Surface> SurfaceControl::getSurface() const
{
    Mutex::Autolock _l(mLock);
    if (mSurfaceData == 0) {
        return generateSurfaceLocked();
    }
    return mSurfaceData;
}
```
其实就是把图元生产者设置到Surface中。

### Surface的初始化
Surface才是面向我们客户端，开发者的绘制图层。我们不会直接操作图元生产者。一切的事情都交给Surface来发送。这里面包含了很重要的图元发送等逻辑。

```cpp
class Surface
    : public ANativeObjectBase<ANativeWindow, Surface, RefBase>
```
可以看到继承了一个ANativeObjectBase模版类，这个模版类只是处理引用计数，不过设计的很精巧，可以学习。
```cpp
template <typename NATIVE_TYPE, typename TYPE, typename REF,
        typename NATIVE_BASE = android_native_base_t>
class ANativeObjectBase : public NATIVE_TYPE, public REF
{
public:
    // Disambiguate between the incStrong in REF and NATIVE_TYPE
    void incStrong(const void* id) const {
        REF::incStrong(id);
    }
    void decStrong(const void* id) const {
        REF::decStrong(id);
    }

protected:
    typedef ANativeObjectBase<NATIVE_TYPE, TYPE, REF, NATIVE_BASE> BASE;
    ANativeObjectBase() : NATIVE_TYPE(), REF() {
        NATIVE_TYPE::common.incRef = incRef;
        NATIVE_TYPE::common.decRef = decRef;
    }
    static inline TYPE* getSelf(NATIVE_TYPE* self) {
        return static_cast<TYPE*>(self);
    }
    static inline TYPE const* getSelf(NATIVE_TYPE const* self) {
        return static_cast<TYPE const *>(self);
    }
    static inline TYPE* getSelf(NATIVE_BASE* base) {
        return getSelf(reinterpret_cast<NATIVE_TYPE*>(base));
    }
    static inline TYPE const * getSelf(NATIVE_BASE const* base) {
        return getSelf(reinterpret_cast<NATIVE_TYPE const*>(base));
    }
    static void incRef(NATIVE_BASE* base) {
        ANativeObjectBase* self = getSelf(base);
        self->incStrong(self);
    }
    static void decRef(NATIVE_BASE* base) {
        ANativeObjectBase* self = getSelf(base);
        self->decStrong(self);
    }
};

```
使用了模版了决定了继承关系。换句话说其实相当于一个Hook，在不改变设计结构下，增加了引用的特性。

#### ANativeWindow 结构体
文件：/[frameworks](http://androidxref.com/9.0.0_r3/xref/frameworks/)/[native](http://androidxref.com/9.0.0_r3/xref/frameworks/native/)/[libs](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/)/[nativewindow](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativewindow/)/[include](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativewindow/include/)/[system](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativewindow/include/system/)/[window.h](http://androidxref.com/9.0.0_r3/xref/frameworks/native/libs/nativewindow/include/system/window.h)

```cpp
struct ANativeWindow
{
#ifdef __cplusplus
    ANativeWindow()
        : flags(0), minSwapInterval(0), maxSwapInterval(0), xdpi(0), ydpi(0)
    {
        common.magic = ANDROID_NATIVE_WINDOW_MAGIC;
        common.version = sizeof(ANativeWindow);
        memset(common.reserved, 0, sizeof(common.reserved));
    }

    /* Implement the methods that sp<ANativeWindow> expects so that it
       can be used to automatically refcount ANativeWindow's. */
    void incStrong(const void* /*id*/) const {
        common.incRef(const_cast<android_native_base_t*>(&common));
    }
    void decStrong(const void* /*id*/) const {
        common.decRef(const_cast<android_native_base_t*>(&common));
    }
#endif

    struct android_native_base_t common;

    /* flags describing some attributes of this surface or its updater */
    const uint32_t flags;

    /* min swap interval supported by this updated */
    const int   minSwapInterval;

    /* max swap interval supported by this updated */
    const int   maxSwapInterval;

    /* horizontal and vertical resolution in DPI */
    const float xdpi;
    const float ydpi;

    intptr_t    oem[4];

    int     (*setSwapInterval)(struct ANativeWindow* window,
                int interval);

    int     (*dequeueBuffer_DEPRECATED)(struct ANativeWindow* window,
                struct ANativeWindowBuffer** buffer);

    int     (*lockBuffer_DEPRECATED)(struct ANativeWindow* window,
                struct ANativeWindowBuffer* buffer);

    int     (*queueBuffer_DEPRECATED)(struct ANativeWindow* window,
                struct ANativeWindowBuffer* buffer);

    int     (*query)(const struct ANativeWindow* window,
                int what, int* value);

    int     (*perform)(struct ANativeWindow* window,
                int operation, ... );

    int     (*cancelBuffer_DEPRECATED)(struct ANativeWindow* window,
                struct ANativeWindowBuffer* buffer);

    int     (*dequeueBuffer)(struct ANativeWindow* window,
                struct ANativeWindowBuffer** buffer, int* fenceFd);

    int     (*queueBuffer)(struct ANativeWindow* window,
                struct ANativeWindowBuffer* buffer, int fenceFd);

    int     (*cancelBuffer)(struct ANativeWindow* window,
                struct ANativeWindowBuffer* buffer, int fenceFd);
};
```
实际上，我们就能看到不少线索，别看叫做Window，实际上ANativeWindow不是作为图元存储的结构体，能从结构体中的方法指针看得出，实际上ANativeWindow是用来控制ANativeWindowBuffer 像素缓存的。大致上有四个操作，queueBuffer 图元入队，dequeueBuffer 图元出队，lockBuffer 图元锁定，query图元查找等。当然还有setSwapInterval交换缓冲。

我们再转过头看看整个Surface的初始化。
```cpp
Surface::Surface(const sp<IGraphicBufferProducer>& bufferProducer, bool controlledByApp)
      : mGraphicBufferProducer(bufferProducer),
        mCrop(Rect::EMPTY_RECT),
        mBufferAge(0),
        mGenerationNumber(0),
        mSharedBufferMode(false),
        mAutoRefresh(false),
        mSharedBufferSlot(BufferItem::INVALID_BUFFER_SLOT),
        mSharedBufferHasBeenQueued(false),
        mQueriedSupportedTimestamps(false),
        mFrameTimestampsSupportsPresent(false),
        mEnableFrameTimestamps(false),
        mFrameEventHistory(std::make_unique<ProducerFrameEventHistory>()) {
    // Initialize the ANativeWindow function pointers.
    ANativeWindow::setSwapInterval  = hook_setSwapInterval;
    ANativeWindow::dequeueBuffer    = hook_dequeueBuffer;
    ANativeWindow::cancelBuffer     = hook_cancelBuffer;
    ANativeWindow::queueBuffer      = hook_queueBuffer;
    ANativeWindow::query            = hook_query;
    ANativeWindow::perform          = hook_perform;

    ANativeWindow::dequeueBuffer_DEPRECATED = hook_dequeueBuffer_DEPRECATED;
    ANativeWindow::cancelBuffer_DEPRECATED  = hook_cancelBuffer_DEPRECATED;
    ANativeWindow::lockBuffer_DEPRECATED    = hook_lockBuffer_DEPRECATED;
    ANativeWindow::queueBuffer_DEPRECATED   = hook_queueBuffer_DEPRECATED;

    const_cast<int&>(ANativeWindow::minSwapInterval) = 0;
    const_cast<int&>(ANativeWindow::maxSwapInterval) = 1;

    mReqWidth = 0;
    mReqHeight = 0;
    mReqFormat = 0;
    mReqUsage = 0;
    mTimestamp = NATIVE_WINDOW_TIMESTAMP_AUTO;
    mDataSpace = Dataspace::UNKNOWN;
    mScalingMode = NATIVE_WINDOW_SCALING_MODE_FREEZE;
    mTransform = 0;
    mStickyTransform = 0;
    mDefaultWidth = 0;
    mDefaultHeight = 0;
    mUserWidth = 0;
    mUserHeight = 0;
    mTransformHint = 0;
    mConsumerRunningBehind = false;
    mConnectedToCpu = false;
    mProducerControlledByApp = controlledByApp;
    mSwapIntervalZero = false;
}
```
在Surface初始化的时候，同时为每一个方法指针都赋值了，让Surface拥有了操作的能力。

# 总结
关于BufferQueue 图元缓冲队列的初始化就到这里。在这个初始化流程中，初步的搭建了整个生产者-消费者模型。剩下的步骤就是生产图元，写入生产者，生产者把数据写进缓冲队列，通知消费者进行消费。

后面的步骤，我们慢慢再聊。老规矩用一幅图总结整个流程。

![SF的生产者消费者模型.png](/images/SF的生产者消费者模型.png)



总结一遍流程，本文总结了开机动画1-5的步骤。
- 1. getBuiltInDisplay 从BuiltInDisplay数组中获取当前的屏幕
- 2. getDisplayInfo 从SF中获取活跃的屏幕信息
- 3. createSurface 通过SF的Client对象创建了一个图元生产者，并且赋值给SurfaceControl中。
- 4. setLayer 设置layer 图层在Z轴上的层级
- 5. getSurface 通过SurfaceControl生产Surface对象，真正进行交互是Surface对象。

有了这些基础之后，下一篇文章就来聊聊，Android在OpenGL es上的封装。



