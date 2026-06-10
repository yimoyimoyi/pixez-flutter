import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:path_provider/path_provider.dart';

class AppCachePage extends StatefulWidget {
  @override
  _AppCachePageState createState() => _AppCachePageState();
}

class _AppCachePageState extends State<AppCachePage> {
  String _imageCacheSize = '计算中…';
  String _novelCacheSize = '计算中…';

  @override
  void initState() {
    super.initState();
    _refreshSizes();
  }

  Future<void> _refreshSizes() async {
    final appDir = await getApplicationSupportDirectory();
    // 图片缓存目录（与 pixivCacheManager 一致）
    final dioCache = Directory('${appDir.path}/dioCache');
    int imageBytes = 0;
    if (await dioCache.exists()) {
      await for (final f in dioCache.list(recursive: true)) {
        if (f is File) imageBytes += await f.length();
      }
    }
    // 小说正文缓存
    final novelCache = Directory('${appDir.path}/novel_text_cache');
    int novelBytes = 0;
    if (await novelCache.exists()) {
      await for (final f in novelCache.list(recursive: true)) {
        if (f is File) novelBytes += await f.length();
      }
    }
    if (mounted) {
      setState(() {
        _imageCacheSize = _formatBytes(imageBytes);
        _novelCacheSize = _formatBytes(novelBytes);
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _clearImageCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.of(context).clear_all_cache),
        content: Text('将清除所有图片缓存文件（$_imageCacheSize）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(I18n.of(context).cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(I18n.of(context).ok)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      // 清空 pixivCacheManager
      await pixivCacheManager?.emptyCache();
      // 清空 dioCache 目录
      final appDir = await getApplicationSupportDirectory();
      final dioCache = Directory('${appDir.path}/dioCache');
      if (await dioCache.exists()) {
        await dioCache.delete(recursive: true);
        await dioCache.create();
      }
      await _refreshSizes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片缓存已清除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清除失败: $e')));
      }
    }
  }

  Future<void> _clearNovelCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除小说缓存'),
        content: Text('将清除所有小说正文缓存（$_novelCacheSize）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(I18n.of(context).cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(I18n.of(context).ok)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final appDir = await getApplicationSupportDirectory();
      final novelCache = Directory('${appDir.path}/novel_text_cache');
      if (await novelCache.exists()) {
        await novelCache.delete(recursive: true);
      }
      await _refreshSizes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('小说缓存已清除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清除失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('缓存管理')),
      body: ListView(
        children: [
          // 图片缓存
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('图片缓存'),
            subtitle: Text(_imageCacheSize),
            trailing: const Icon(Icons.delete_outline),
            onTap: _clearImageCache,
          ),
          // 小说正文缓存
          ListTile(
            leading: const Icon(Icons.book),
            title: const Text('小说正文缓存'),
            subtitle: Text(_novelCacheSize),
            trailing: const Icon(Icons.delete_outline),
            onTap: _clearNovelCache,
          ),
          const Divider(),
          // 缓存数量限制
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('最大缓存图片数'),
            subtitle: const Text('当前: 500 张（30天过期）'),
          ),
          // Flutter 内存缓存
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('内存缓存上限'),
            subtitle: const Text('当前: 200 MB'),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '图片使用 disk-cache + memory-cache 双缓存策略。浏览过的图片会保存到本地，30天内再次访问时直接使用缓存。小说正文也会在阅读后缓存，即使作品被删除仍可继续阅读。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
