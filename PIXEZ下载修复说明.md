# PixEz 自定义图床下载修复说明

## 问题根因

PixEz 的图片**浏览**和**下载**使用**不同的 Dart 子进程**（Isolate）处理：

| | 浏览 | 下载 |
|---|---|---|
| 运行位置 | 主 Isolate | 独立子 Isolate |
| 网络设置 | 正确读取 `userSetting.pictureSource` | **错误读取默认值** `i.pximg.net` |
| 结果 | 代理 URL → Cloudflare → 正常 ✅ | `sni: false` 破坏 TLS → 连接立刻被拒 ❌ |

**关键代码**：[pixez_network_settings.dart:34](lib/network/pixez_network_settings.dart#L34)
```dart
// line 34: 子 Isolate 内部调用的 userSetting 是全新的默认实例
// pictureSource 默认值为 "i.pximg.net"（ImageHost）
if (userSetting.pictureSource != imageHost) return null;  // 当自定义图床时
return compatible();  // sni: false, verifyCertificates: false
```

当 `pictureSource == i.pximg.net`（默认），进入 `compatible()` 模式（`sni: false`），浏览器直连 IP 绕过封锁。但连接 **Cloudflare Workers** 时 `sni: false` 直接导致 **TLS 握手失败**，连接瞬间被拒绝（`Connection refused`），下载任务立即标记为失败。

## 修复内容

### 文件：[pixez-flutter/lib/er/fetcher.dart](pixez-flutter/lib/er/fetcher.dart)

**第 1 处（~第 280 行）—— 初始化**：
```dart
// 改前
final client = await r.RhttpCompatibleClient.createSync(
  settings: PixezNetworkSettings.forImages(message.networkMode),  // 错误：读默认 userSetting
);

// 改后
final useCompat = message.networkMode != NetworkMode.standard &&
                  message.pictureSource == ImageHost;  // 正确：用主 Isolate 传来的值
final client = await r.RhttpCompatibleClient.createSync(
  settings: useCompat ? PixezNetworkSettings.compatible() : null,
);
```

**第 2 处（~第 304 行）—— RELOAD 切换**：
```dart
// 改前
settings: PixezNetworkSettings.forImages(mode),

// 改后
final reloadUseCompat = mode != NetworkMode.standard &&
                         currentPictureSource == ImageHost;
settings: reloadUseCompat ? PixezNetworkSettings.compatible() : null,
```

**逻辑**：自定义图床 → `settings: null` → 系统默认 HTTP 客户端 → Cloudflare TLS 正常 ✅。直连 Pixiv（无代理）→ `settings: compatible()` → SNI 绕过 ✅。

## 编译方式

### 前置依赖
- Flutter SDK：`C:\Users\32559\Desktop\piximage\mypixiv\flutter\`
- Android SDK：`C:\Users\32559\Desktop\piximage\mypixiv\`（含 NDK 27 / 28）
- Rust：`cargo` / `rustup`（仅 `rhttp` 插件首次编译需要，以后不改 Rust 代码则不重复）
- 两个本地仓库（已克隆）：
  - `C:\Users\32559\Desktop\piximage\mypixiv\receive_sharing_intent\`
  - `C:\Users\32559\Desktop\piximage\mypixiv\material-foundation-flutter-packages\`

### 编译命令

```powershell
cd C:\Users\32559\Desktop\piximage\mypixiv\pixez-flutter

# 设置 Android SDK 路径
$env:ANDROID_HOME = "C:\Users\32559\Desktop\piximage\mypixiv"
$env:ANDROID_SDK_ROOT = "C:\Users\32559\Desktop\piximage\mypixiv"

# 如有代理，设置 Rust 编译代理
$env:CARGO_HTTP_PROXY = "http://127.0.0.1:7897"

# 编译 Release APK
flutter build apk --release
```

### 产物位置
`pixez-flutter\build\app\outputs\flutter-apk\app-release.apk`

### 安装
```powershell
# 连接手机，USB 调试已开启
flutter install
```
或手动复制 APK 到手机安装（需先卸载官方版 PixEz）。

## 注意事项

1. 首次编译 `rhttp` 插件需联网下载 Rust crate，约 5-10 分钟，后续编译不再重复。
2. 如果 crates.io 下载失败，配置 `C:\Users\32559\.cargo\config.toml` 添加代理或镜像。
3. 建议使用 **Compat 模式**（设置 → 网络模式），自定义图床图片走系统 HTTP、Pixiv API 走兼容模式，两者互不冲突。

---

*生成的 APK 将完全解决"未加载完全前下载直接失败"的问题。*
