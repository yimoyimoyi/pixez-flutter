# 特辑/Spotlight 正文图片无法加载

## 现象

特辑（pixivision）文章详情页只能加载头图，正文中的插画图片全部加载失败。使用默认图床和自定义图床均有此问题。

测试 URL：`https://www.pixivision.net/zh/a/11639`

## 根因

**1. `PixivImageSource` 域名匹配过窄**

```dart
// 原代码：只匹配两个域名
if (uri.host != imageHost && uri.host != imageSHost) return uri;
// imageHost = 'i.pximg.net', imageSHost = 's.pximg.net'
```

特辑正文图片来自 `embed.pixiv.net` 等域名，不在匹配列表中，URL 不会被重写为代理地址，直接请求源站 → 网络不通。

**2. 代理路径丢失原始主机信息**

即使扩展了域名匹配，URL 被改写为 `https://proxy.example.com/pixivision/zh/a/11639/img.jpg`，代理（Worker）不知道原始主机是 `embed.pixiv.net` 还是 `i.pximg.net`，只能盲目尝试社区镜像（`i.pixiv.re`/`i.pixiv.cat`），而特辑内容不在这些镜像上。

## 修复

**1. 扩展域名匹配**

```dart
static bool _isPixivImageHost(String host) {
    if (host == imageHost || host == imageSHost) return true;
    if (host.endsWith('.pximg.net')) return true;
    if (host.endsWith('.pixiv.net') &&
        host != 'app-api.pixiv.net' &&
        host != 'oauth.secure.pixiv.net' &&
        host != 'accounts.pixiv.net') return true;
    return false;
}
```

**2. URL 改写时在路径中保留原始主机**

```dart
// 改前：https://embed.pixiv.net/a.jpg → https://proxy/a.jpg
// 改后：https://embed.pixiv.net/a.jpg → https://proxy/embed.pixiv.net/a.jpg
final pathWithHost = '/${uri.host}${uri.path}';
```

代理从路径首段提取原始主机（`embed.pixiv.net`），直接向上游请求。

## 涉及文件

- `lib/er/pixiv_image_source.dart`：`_isPixivImageHost()` + `_withSource()` 路径编码
- 代理端（Cloudflare Worker）需同步：`fetchImage()` 从路径首段提取上游主机
