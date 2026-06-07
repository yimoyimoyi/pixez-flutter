# PixEz 独立版 v0.9.102

基于 [Notsfsssf/pixez-flutter](https://github.com/Notsfsssf/pixez-flutter)，包名 `com.perol.pixez.custom`，与原版共存。

## 功能

**登录**
- 外部浏览器 OAuth（推荐）、内部 WebView（Weiss 代理）、Token 直登三种方式

**网络**
- 实测可用的 Pixiv IP 池（API 13 个 + 图片 10 个）+ DoH（Yandex / switch.ch）
- 自定义图床（Cloudflare Workers）下载修复，图片/动图/特辑均走代理
- Worker 冷启动预热（cron 保活 + Flutter 预载）

**浏览**
- 图片/下载/动图加载失败自动重试 3 次
- 失效图片显示文件名，小说正文失败保留标题封面等元信息
- 图片详情、小说、用户 Profile 等页面 AppBar 添加主页按钮

## 部署

```bash
# Worker（ugoira + cron 保活）
cd piximage/mypixiv && npx wrangler deploy
```
