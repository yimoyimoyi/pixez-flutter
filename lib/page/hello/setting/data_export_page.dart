import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/glance_illust_persist.dart';
import 'package:pixez/page/history/history_store.dart';
import 'package:pixez/utils/cache_utils.dart';

class DataExportPage extends HookConsumerWidget {
  const DataExportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(I18n.of(context).app_data)),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Card(
              margin: EdgeInsets.all(8.0),
              child: _buildColumn(context, ref),
            ),
            Container(height: MediaQuery.of(context).padding.bottom + 20),
          ],
        ),
      ),
    );
  }

  Widget _buildColumn(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(I18n.of(context).export_title),
          subtitle: Text(I18n.of(context).export_tag_history),
          onTap: () async {
            try {
              await tagHistoryStore.exportData(context);
            } catch (e) {
              print(e);
            }
          },
        ),
        ListTile(
          title: Text(I18n.of(context).import_title),
          subtitle: Text(I18n.of(context).import_tag_history),
          onTap: () async {
            try {
              await tagHistoryStore.importData();
            } catch (e) {
              print(e);
              BotToast.showText(text: e.toString());
            }
          },
        ),
        Divider(),
        ListTile(
          title: Text(I18n.of(context).export_title),
          subtitle: Text(I18n.of(context).export_bookmark_tag),
          onTap: () async {
            try {
              await bookTagStore.exportData(context);
            } catch (e) {
              print(e);
            }
          },
        ),
        ListTile(
          title: Text(I18n.of(context).import_title),
          subtitle: Text(I18n.of(context).import_bookmark_tag),
          onTap: () async {
            try {
              await bookTagStore.importData();
            } catch (e) {
              print(e);
              BotToast.showText(text: e.toString());
            }
          },
        ),
        Divider(),
        ListTile(
          title: Text(I18n.of(context).export_title),
          subtitle: Text(I18n.of(context).export_illust_history),
          onTap: () async {
            try {
              await ref.read(historyProvider.notifier).fetch();
              await ref.read(historyProvider.notifier).exportData(context);
            } catch (e) {
              print(e);
            }
          },
        ),
        ListTile(
          title: Text(I18n.of(context).import_title),
          subtitle: Text(I18n.of(context).import_illust_history),
          onTap: () async {
            try {
              await ref.read(historyProvider.notifier).fetch();
              await ref.read(historyProvider.notifier).importData();
            } catch (e) {
              print(e);
              BotToast.showText(text: e.toString());
            }
          },
        ),
        Divider(),
        ListTile(
          title: Text(I18n.of(context).export_title),
          subtitle: Text(I18n.of(context).export_novel_history),
          onTap: () async {
            try {
              await novelHistoryStore.fetch();
              await novelHistoryStore.exportData(context);
            } catch (e) {
              print(e);
            }
          },
        ),
        ListTile(
          title: Text(I18n.of(context).import_title),
          subtitle: Text(I18n.of(context).import_novel_history),
          onTap: () async {
            try {
              await novelHistoryStore.fetch();
              await novelHistoryStore.importData();
            } catch (e) {
              print(e);
              BotToast.showText(text: e.toString());
            }
          },
        ),
        Divider(),
        ListTile(
          title: Text(I18n.of(context).export_title),
          subtitle: Text(I18n.of(context).export_mute_data),
          onTap: () async {
            try {
              await muteStore.export(context);
            } catch (e) {
              print(e);
            }
          },
        ),
        ListTile(
          title: Text(I18n.of(context).import_title),
          subtitle: Text(I18n.of(context).import_mute_data),
          onTap: () async {
            try {
              await muteStore.importFile();
            } catch (e) {
              print(e);
              BotToast.showText(text: e.toString());
            }
          },
        ),
        const Divider(),
        _CacheSection(),
      ],
    );
  }

  void cleanGlanceData() async {
    GlanceIllustPersistProvider glanceIllustPersistProvider =
        GlanceIllustPersistProvider();
    await glanceIllustPersistProvider.open();
    await glanceIllustPersistProvider.deleteAll();
    await glanceIllustPersistProvider.close();
  }
}

class _CacheSection extends StatefulWidget {
  @override
  State<_CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends State<_CacheSection> {
  String _imageCacheSize = '计算中…';
  String _novelCacheSize = '计算中…';

  @override
  void initState() {
    super.initState();
    _refreshSizes();
  }

  Future<void> _refreshSizes() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      final dioCache = Directory('${tmpDir.path}/dioCache');
      int imageBytes = 0;
      if (await dioCache.exists()) {
        await for (final f in dioCache.list(recursive: true)) {
          if (f is File) imageBytes += await f.length();
        }
      }
      final appDir = await getApplicationSupportDirectory();
      final novelCache = Directory('${appDir.path}/novel_text_cache');
      int novelBytes = 0;
      if (await novelCache.exists()) {
        await for (final f in novelCache.list(recursive: true)) {
          if (f is File) novelBytes += await f.length();
        }
      }
      if (mounted) {
        setState(() {
          _imageCacheSize = _fmt(imageBytes);
          _novelCacheSize = _fmt(novelBytes);
        });
      }
    } catch (e) {
      print('_refreshSizes error: $e');
    }
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _clearImage() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.of(context).clear_all_cache),
        content: Text('清除所有图片缓存（$_imageCacheSize）？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(I18n.of(context).cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(I18n.of(context).ok)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await pixivCacheManager?.emptyCache();
      final tmpDir = await getTemporaryDirectory();
      final dioCache = Directory('${tmpDir.path}/dioCache');
      if (await dioCache.exists()) {
        await dioCache.delete(recursive: true);
        await dioCache.create();
      }
      await _refreshSizes();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('图片缓存已清除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清除失败: $e')));
      }
    }
  }

  Future<void> _clearNovel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除小说缓存'),
        content: Text('清除所有小说正文缓存（$_novelCacheSize）？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(I18n.of(context).cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(I18n.of(context).ok)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final appDir = await getApplicationSupportDirectory();
      final novelCache = Directory('${appDir.path}/novel_text_cache');
      if (await novelCache.exists()) {
        await novelCache.delete(recursive: true);
      }
      await _refreshSizes();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('小说缓存已清除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清除失败: $e')));
      }
    }
  }

  Future<void> _saveImageCache() async {
    // 注意：不再请求存储权限 —— Android 13+ 的 READ/WRITE_EXTERNAL_STORAGE
    // 已废弃且权限被永久拒绝；Android 10+ 的 getExternalStorageDirectory()
    // 返回应用专属目录，本身不需要任何权限。iOS 无外部存储，用文档目录。
    try {
      final tmpDir = await getTemporaryDirectory();
      final srcDir = Directory('${tmpDir.path}/dioCache');
      if (!await srcDir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂无缓存可保存')));
        }
        return;
      }
      final dlDir = Platform.isIOS
          ? await getApplicationDocumentsDirectory()
          : await getExternalStorageDirectory();
      if (dlDir == null) throw Exception('无法访问存储目录');
      final destPath = '${dlDir.path}/pixez_cache';
      // 复制在 isolate 中执行，避免大缓存下主 isolate 卡顿
      final copied = await compute(
        copyCacheDirectoryTo,
        (src: srcDir.path, dest: destPath),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存 $copied 个文件到 $destPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.image),
          title: const Text('图片缓存'),
          subtitle: Text(_imageCacheSize),
          trailing: const Icon(Icons.delete_outline),
          onTap: _clearImage,
        ),
        ListTile(
          leading: const Icon(Icons.book),
          title: const Text('小说正文缓存'),
          subtitle: Text(_novelCacheSize),
          trailing: const Icon(Icons.delete_outline),
          onTap: _clearNovel,
        ),
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('保存图片缓存'),
          subtitle: const Text('复制到下载目录，避免系统清理'),
          onTap: _saveImageCache,
        ),
      ],
    );
  }
}
