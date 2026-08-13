# 上游同步记录(Upstream Sync)

本文件记录本地 fork 与上游 [Notsfsssf/pixez-flutter](https://github.com/Notsfsssf/pixez-flutter) 的同步机制、已同步内容与决策,供后续持续同步对照使用。

## 历史背景:上游历史被 force push 重写

- 2026-08-13 上游 master 被 force push 重写:`31711f4c` 为**孤儿提交**(无父提交),与本地 fork 历史**无共同祖先**。
- 本地 fork 分叉点:`d4893fbd`(本地在其之上有 106 个提交)。
- 因此**不能**使用 `git merge upstream/master`(无共同祖先会判定 118 个文件冲突,上游树会删除本地 fork 独有文件)。
- 同步方式改为**内容级**:提取 `d4893fbd → 31711f4c` 增量,选择性 patch 应用。

## 同步点 Tag

| Tag | 指向 | 含义 |
|---|---|---|
| `sync-upstream-0.9.106` | `31711f4c` | 0.9.106 已合入的上游状态。后续同步以它为增量基线 |

后续每次同步完成后,更新 tag 指向新的上游头:
```bash
git tag -f sync-upstream-0.9.106 upstream/master
```

## 已同步内容(0.9.106)

| 类别 | 内容 |
|---|---|
| HapticUtil | 整体替换为上游版(节流 `minIntervalMs`、`success/error/warning`;本地接口为其子集,兼容) |
| 触觉反馈接入 | fetcher 下载成功/失败、illust_card 点击、save_store 保存、设置页开关等 10+ 页面 |
| 菜单改版 | illust_lighting/illust_row 右上角下拉式菜单(showGeneralDialog + 动画),git 三路自动合并零冲突 |
| 鼠标拖拽 | fluent 版 photo_zoom_page ScrollConfiguration(material 版此前已实现) |
| wakelock_plus_stub | 新增本地插件 + pubspec override(替换真实 wakelock_plus) |
| permission_handler | 12.0.3 → 13.0.1(**保留** iOS override,见下) |
| 其他 | 分享文本模板、版本号 0.9.106、intl_de、history/novel/theme 等页面小改 |
| l10n | 补齐 `haptic_feedback`(9 语言)与 `automatically_tag_when_bookmarking`(11 语言)缺失翻译 |

## 跳过清单(每次同步复查)

| 项 | 原因 | 决策 |
|---|---|---|
| `lib/page/picture/picture_list_page.dart` | 架构级冲突:本地 Listener 自定义手势系统(跟手/防闪烁/连滑保护)vs 上游系统手势;上游改动(ScrollConfiguration 鼠标支持)与本地功能重叠,价值≈0;嵌套无意义(本地恒 NeverScrollableScrollPhysics) | **永久保留本地**,除非上游对手势系统整体重构并评估 |
| `swipeChangeArtwork` 设置 | 本地手势系统旁路了该设置(恒可滑动)。如需恢复,在本地 `_onPointerMove` 前加条件判断(约 3 行),不要取上游代码 | 可选优化,待定 |
| android versionCode/versionName | 上游发布元数据,本地有独立版本策略(pubspec 1.9.85+502) | 跳过 |
| ios/Flutter/ephemeral 生成文件 | 工具链生成,不手动改 | 跳过 |
| permission_handler_apple override | **保留**本地 path override:ITMS-90683(App Store 审核拒绝)上游从未修复(issue #1543 关闭但无官方修复),移除有审核被拒风险。上游删除 override 仅因其不维护 iOS | 永久保留 |

## 后续同步步骤

```bash
# 1. 拉取上游
git fetch upstream
# 2. 提取增量(与历史是否重写无关,git diff 不依赖共同祖先)
git diff sync-upstream-0.9.106 upstream/master > /tmp/upstream.patch
# 3. 三路应用(本地树做 ours,冲突自动标记)
git apply --3way /tmp/upstream.patch
# 4. 检查跳过清单(picture_list 等文件是否被误包含,排除后重新应用)
# 5. 验证
flutter analyze
# 6. 提交后更新同步点
git tag -f sync-upstream-0.9.106 upstream/master
```

## 已建立机制备忘

- **缓存共享**:浏览缓存与下载缓存共享(1d5ac349 `feat: 实现浏览与下载共享磁盘缓存及下载回写`),后续上游若改动 fetcher/pixiv_image,合并时注意保留。
- **两分支统一**:fluent 版 `pixivCacheManager` 转发 material 版实例,fluent 页面上游改动若触碰缓存,保持该转发结构。
