# 说明

本站点基于Hexo博客引擎搭建, 且使用了[matery](https://github.com/blinkfox/hexo-theme-matery/blob/develop/README_CN.md)作为博客皮肤, 在此感谢相关开源大佬的贡献

# 开发流程

首先, 因为Hexo使用了nodejs搭建, 因此需要下一个[nodejs](http://nodejs.cn/download/)来提供支撑

下载安装好之后, 请进入项目根目录, 逐一运行以下代码

```
$ npm i
$ npm i hexo -g
$ hexo server
```

运行完毕后, 你将在你的terminal看到如下提示

```
INFO  Start processing
INFO  Hexo is running at http://localhost:4000 . Press Ctrl+C to stop.
```

此时证明已经开启博客引擎成功, 我们进入[http://localhost:4000](http://localhost:4000)即可看到页面

# 开始写文章

运行以下命令, 即可在`source/_posts`目录下创建一个`markdown`文件

``` bash
$ hexo new post '文章标题'
```

创建成功之后, 打开该文件, 可看到如下内容

```
---
title: 文章标题
top: false
cover: false
date: 2019-09-19 21:44:24
img: 
tag:
description:
author:
summary:
---
```

上方的标识提供给hexo来识别和分类, 建议大家进行填写, 其中各字段含义如下

- title: 文章标题
- top: 文章是否置顶
- cover: 文章是否作为banner轮播显示
- date: 日期, 会自动生成
- img: 文章的头图
- tag:  文章的tag, 用于分类
- category: 文章分类
- description: 文章描述
- author: 文章作者, 将于文章底部显示作者名
- summary: 文章摘要

接下来, 我们在下面的内容中直接写入markdown格式的文件即可

# 发布

写好你的文章后, 可以直接在[http://localhost:4000](http://localhost:4000)查看效果, 结果ok的话, 直接提交到仓库的master分支, 即可自动通过CI/CD发布

# 访问

[线上访问地址](http://blog.bu6.io)

# 另外

## 修改主题颜色

在主题文件的 /source/css/matery.css 文件中，搜索 .bg-color 来修改背景颜色：

``` css
/* 整体背景颜色，包括导航、移动端的导航、页尾、标签页等的背景颜色. */
.bg-color {
    background-image: linear-gradient(to right, #4cbf30 0%, #0f9d58 100%);
}

@-webkit-keyframes rainbow {
   /* 动态切换背景颜色. */
}

@keyframes rainbow {
    /* 动态切换背景颜色. */
}
```

## 修改 banner 图和文章特色图

你可以直接在 /source/medias/banner 文件夹中更换你喜欢的 banner 图片，主题代码中是每天动态切换一张，只需 7 张即可。如果你会 JavaScript 代码，可以修改成你自己喜欢切换逻辑，如：随机切换等，banner 切换的代码位置在 /layout/_partial/bg-cover-content.ejs 文件的 <script></script> 代码中：

``` js
$('.bg-cover').css('background-image', 'url(/medias/banner/' + new Date().getDay() + '.jpg)');
```

在 /source/medias/featureimages 文件夹中默认有 24 张特色图片，你可以再增加或者减少，并需要在 _config.yml 做同步修改。