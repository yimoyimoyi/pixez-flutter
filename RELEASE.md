# PixEz 独立版 Release Notes

> 基于 [Notsfsssf/pixez-flutter](https://github.com/Notsfsssf/pixez-flutter) `android 0.9.101`  
> 版本 `0.9.102 custom` · 包名 `com.perol.pixez.custom`（可与原版共存）

---

## 网络层

### 自定义图床下载修复
子 Isolate 下载时错误读取默认 `pictureSource`，导致自定义图床（Cloudflare Workers）走 compat SNI 绕过而 TLS 失败。改为从主 Isolate 传入正确的 `pictureSource` 显式判断。

### IP 池扩展（参考 Pixiv-Nginx）
- API IP 池：13 个（`210.140.139.137-138/149-150/154-162`）
- 图片 IP 池：10 个（`210.140.139.131-138/149-150`）
- `210.140.92.*` 段全部超时已移除
- DNS 解析优先级：IP 池 → DNS 缓存 → 系统 DNS

### DoH 端点更新
- 主：Yandex `77.88.8.1`
- 备：switch.ch `130.59.31.248/251`
- `119.29.29.29`、`1.1.1.1`、`8.8.8.8` 超时已移除

### URL 改写域名扩展
`PixivImageSource` 拦截器从仅匹配 `i.pximg.net`/`s.pximg.net` 扩展至所有 `*.pximg.net` 和 `*.pixiv.net`（排除 API/OAuth/账户域名），修复特辑（pixivision）正文图片不加载问题。

### URL 路径编码原始主机
`_withSource` 将原始主机编码到代理 URL 路径首段（`/original-host/path`），Worker 据此确定上游 Pixiv 主机，解决 `embed.pixiv.net` 等特辑图片域名代理失效。

---

## 登录

### 方案（分三层）
| 方式 | 说明 |
|---|---|
| 外部浏览器 | 优先，利用系统代理/VPN |
| 内部 WebView | Weiss 本地代理（已更新 .aar） |
| Token | rhttp compat 直连，备用 |

### Weiss 插件更新
基于 [UjuiUjuMandan/weiss](https://github.com/UjuiUjuMandan/weiss) fork（2026 update），用 Go 1.26 + NDK 27 重新编译：
- DoH：Yandex + switch.ch
- IP：`210.140.139.155`
- 禁用 dns.sb/adguard 端点

---

## 浏览体验

### 下载/加载重试
- 图片下载（fetcher）：3 次重试，指数退避 2s → 4s
- 图片浏览（PixivImage）：3 次自动重试，ValueKey 绕过缓存
- 动图下载（ugoira）：3 次重试

### 失效内容元信息保留
- 图片加载失败显示文件名 + 可选标题
- 小说正文加载失败保留标题/作者/封面等元信息

### 主页按钮
各详情页 AppBar 添加主页按钮（icon: 🏠）：
- 图片详情（单张/多张）
- 用户 Profile
- 小说阅读/系列/用户页

### Fluent 桌面端
TitleBar 返回键旁添加主页按钮，NavigationFramework 适配。

### Worker 冷启动预热（Cloudflare Workers）
- Flutter 端：`generatePixivCache` 后 fire-and-forget HEAD 预热
- Worker 端：cron 每 2 分钟保活（`triggers.crons`）
- Worker 端：ugoira zip 加载修复（Content-Type: `application/zip` 放行）

---

## 编译/签名

| 配置 | 值 |
|---|---|
| 包名 | `com.perol.pixez.custom` |
| 版本 | `0.9.102 custom` (10010021) |
| 签名 | 自签名 `pixez-release` |
| 网络安全 | `network_security_config.xml`（仅 localhost 放行 HTTP） |
| AndroidManifest | 移除 `package` 属性（AGP 8.13+） |
| 代码生成 | `build.yaml` 含 rhttp freezed scope |

---

## 部署清单

部署此版本需要同步更新 **Cloudflare Worker**：

```bash
cd piximage/mypixiv
npx wrangler deploy
```

Worker 修改：
1. ugoira `application/zip` Content-Type 放行
2. 路径首段提取原始 Pixiv 主机
3. cron 每 2 分钟保活（`wrangler.toml`）
