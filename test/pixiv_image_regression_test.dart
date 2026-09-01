/*
 * 图片加载防白屏回归测试
 *
 * 覆盖详情页白屏/显示异常问题的核心防线（详见 git 历史：
 * 1a8693de 预解码 → 761eb18b 加固 → 225bc467 gaplessPlayback →
 * 825259bd memCacheWidth → f02d59b9 代际校验）：
 *
 * 场景 B：切换图片时缓存命中直显（_checkCacheOnUrlChange → Image.memory），
 *         不经过 CachedNetworkImage 的 placeholder/淡入（f2054085）
 * 场景 C：按显示宽度解码（memCacheWidth 传递），防止大图全尺寸解码 OOM
 *
 * 双端一致性：Material 与 Fluent 两套 PixivImage 关键防线必须同步
 *
 * 环境限制（重要）：
 * - testWidgets 的 FakeAsync 中真实磁盘 IO（dart:io readAsBytes）永不
 *   完成，Fake 使用 MemoryFileSystem（读写走 microtask，pump 时推进）
 * - CachedNetworkImageProvider 的 decode 链使用 ImmutableBuffer（engine
 *   异步 API），在 flutter_test 中永不完成 → CachedNetworkImage 无法
 *   真正显示图片（imageBuilder/_imageShown 不触发）。因此：
 *   * "图片真正显示"的断言不可行，场景 D（_imageShown 守卫拦截已显示
 *     图片的晚到字节）无法 widget 测试，由真实设备验证（825259bd）
 *   * 本文件只验证不依赖显示的防线：方案 B 字节直显、解码宽度、参数透传
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/component/pixiv_image.dart' as material_image;

// 1x1 透明 PNG
final Uint8List kPngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x64, 0xF8, 0xCF, 0x50, //
  0x0F, 0x00, 0x0D, 0x06, 0x01, 0x9A, 0x35, 0xF4, 0x6B, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// 可控的假缓存管理器（继承具体类 CacheManager 以匹配全局变量类型）：
/// - [disk] 模拟磁盘缓存（url -> 字节），命中 getFileStream/getFileFromCache
/// - [holdStreams] 指定 url 的 getFileStream 挂起（Completer 控制，无
///   Timer 残留）：模拟"网络加载慢于磁盘查询"，保证场景 B 中
///   _checkCacheOnUrlChange 先于 CachedNetworkImage 完成
class FakeCacheManager extends CacheManager {
  final Map<String, Uint8List> disk;
  final Map<String, Completer<void>> holdStreams = {};
  /// 磁盘查询模拟未命中（getFileFromCache 返回 null），但网络分支
  /// （getFileStream）仍命中——避免 CachedNetworkImage 走 errorWidget
  /// 触发 _tryLoadFallback 的 Dio 网络与重试 Timer
  final Set<String> cacheLookupMiss = {};
  int _fileSeq = 0;

  FakeCacheManager(this.disk) : super(Config('pixez_test_cache'));

  // 内存文件系统：FakeAsync 中真实磁盘 IO 永不完成（见文件头注释）
  final _fs = MemoryFileSystem();

  FileInfo _infoFor(String url, Uint8List bytes) {
    final f = _fs
        .file('pixez_test_${_fileSeq++}_${url.hashCode.toRadixString(16)}.png');
    f.writeAsBytesSync(bytes);
    return FileInfo(f, FileSource.Cache,
        DateTime.now().add(const Duration(days: 30)), url);
  }

  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key, Map<String, String>? headers, bool withProgress = false}) async* {
    final hold = holdStreams[url];
    if (hold != null) await hold.future;
    final bytes = disk[url];
    if (bytes == null) {
      // async* 中 throw 作为 stream 错误事件发射（与真实 CacheManager 一致）
      throw Exception('not cached: $url');
    }
    yield _infoFor(url, bytes);
  }

  @override
  Future<FileInfo?> getFileFromCache(String url,
      {bool ignoreMemCache = false}) async {
    final bytes = disk[url];
    if (bytes == null || cacheLookupMiss.contains(url)) return null;
    return _infoFor(url, bytes);
  }
}

/// 树中是否存在 image 类型匹配的 Image widget（含 OctoImage 骨架）
bool _hasImageOfType(WidgetTester tester, bool Function(ImageProvider) test) {
  for (final image in tester.widgetList<Image>(find.byType(Image))) {
    if (test(image.image)) return true;
  }
  return false;
}

/// 多次 pump 直到条件满足或超时（placeholder 的进度环动画会让
/// pumpAndSettle 永不结束，只能用固定时长推进）
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 干净的测试宿主：提供 MaterialApp 与可切换 url 的容器
class _Host extends StatefulWidget {
  final String initialUrl;
  final int? memCacheWidth;

  const _Host({super.key, required this.initialUrl, this.memCacheWidth});

  @override
  _HostState createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String url = widget.initialUrl;

  void changeUrl(String next) {
    setState(() => url = next);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: material_image.PixivImage(
          url,
          width: 400, // 小于告警阈值（800），避免测试输出噪音
          memCacheWidth: widget.memCacheWidth,
        ),
      ),
    );
  }
}

void main() {
  setUp(() {
    material_image.pixivCacheManager = null;
  });

  tearDown(() {
    material_image.pixivCacheManager = null;
  });

  group('场景 B：切换图片缓存命中直显', () {
    testWidgets('切换后命中磁盘缓存 → Image.memory 直显（无 placeholder 窗口）',
        (tester) async {
      const urlA = 'http://test.local/b-a.png';
      const urlB = 'http://test.local/b-b.png';
      final fake = FakeCacheManager({urlA: kPngBytes, urlB: kPngBytes});
      // 让网络分支（getFileStream）挂起：保证缓存字节先到，方案 B 直显
      //（真实场景中磁盘查询通常也快于网络下载）
      fake.holdStreams[urlB] = Completer<void>();
      material_image.pixivCacheManager = fake;

      final hostKey = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: hostKey, initialUrl: urlA));
      await tester.pump();

      // 切换到 B：_checkCacheOnUrlChange 命中 → 方案 B（MemoryImage 直显）
      hostKey.currentState!.changeUrl(urlB);
      await _pumpUntil(
        tester,
        () => _hasImageOfType(tester, (p) => p is MemoryImage),
      );
      expect(_hasImageOfType(tester, (p) => p is MemoryImage), isTrue,
          reason: '缓存命中后应走方案 B：Image.memory 直显，'
              '不经过 placeholder/淡入（防切换白屏）');
      expect(_hasImageOfType(tester, (p) => p is CachedNetworkImageProvider),
          isFalse,
          reason: '切换后不应回退到 CachedNetworkImage 网络分支');
      // 放行网络分支（其 stream 已无监听者，随 stream 取消丢弃）
      fake.holdStreams[urlB]!.complete();
    });

    testWidgets('缓存未命中 → 正常走 CachedNetworkImage 分支', (tester) async {
      const urlA = 'http://test.local/b-c.png';
      const urlB = 'http://test.local/b-d.png';
      // B 磁盘查询模拟未命中（方案 B 无法直显），但网络分支命中：
      // 走 CachedNetworkImage 网络分支，且不触发 errorWidget/Dio
      final fake = FakeCacheManager({urlA: kPngBytes, urlB: kPngBytes});
      fake.cacheLookupMiss.add(urlB);
      material_image.pixivCacheManager = fake;

      final hostKey = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: hostKey, initialUrl: urlA));
      await tester.pump();

      hostKey.currentState!.changeUrl(urlB);
      await tester.pump();
      await tester.pump();
      // 未命中：无 MemoryImage，网络分支（骨架）仍在树中
      expect(_hasImageOfType(tester, (p) => p is MemoryImage), isFalse,
          reason: '缓存未命中时不得走方案 B');
      expect(_hasImageOfType(tester, (p) => p is CachedNetworkImageProvider),
          isTrue,
          reason: '未命中时应走 CachedNetworkImage 网络分支');
    });
  });

  group('场景 C：按显示宽度解码', () {
    testWidgets('方案 B 分支：Image.memory 按 memCacheWidth 缩放解码',
        (tester) async {
      const url = 'http://test.local/c-a.png';
      final fake = FakeCacheManager({url: kPngBytes});
      // 网络分支挂起：确保走方案 B（Image.memory）
      fake.holdStreams[url] = Completer<void>();
      material_image.pixivCacheManager = fake;

      await tester.pumpWidget(const _Host(initialUrl: url, memCacheWidth: 300));
      await _pumpUntil(
        tester,
        // Image.memory(cacheWidth:) 内部包装为 ResizeImage(MemoryImage)
        () => _hasImageOfType(tester, (p) => p is ResizeImage),
      );

      final resized = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => i.image)
          .whereType<ResizeImage>()
          .first;
      expect(resized.width, 300,
          reason: '大图必须按显示宽度解码，防止全尺寸解码 OOM 白屏');
      fake.holdStreams[url]!.complete();
    });

    testWidgets('网络分支：memCacheWidth 透传给 CachedNetworkImage',
        (tester) async {
      const url = 'http://test.local/c-b.png';
      // 磁盘命中（无 url 变化不触发方案 B），走 CachedNetworkImage 网络分支
      final fake = FakeCacheManager({url: kPngBytes});
      material_image.pixivCacheManager = fake;

      await tester.pumpWidget(const _Host(initialUrl: url, memCacheWidth: 300));
      await tester.pump();

      final cached =
          tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(cached, isNotEmpty, reason: '应构建 CachedNetworkImage 网络分支');
      for (final c in cached) {
        expect(c.memCacheWidth, 300,
            reason: '大图必须按显示宽度解码，防止全尺寸解码 OOM 白屏');
      }
    });
  });

  group('双端一致性：Material/Fluent 防线同步', () {
    test('关键防白屏字段与方法在两端同步存在', () {
      final material = File(
        '${Directory.current.path}${Platform.pathSeparator}'
        'lib${Platform.pathSeparator}component${Platform.pathSeparator}pixiv_image.dart',
      ).readAsStringSync();
      final fluent = File(
        '${Directory.current.path}${Platform.pathSeparator}'
        'lib${Platform.pathSeparator}fluent${Platform.pathSeparator}component'
        '${Platform.pathSeparator}pixiv_image.dart',
      ).readAsStringSync();

      // 防白屏/防闪烁的关键防线：任一缺失即视为双端不同步
      const guards = <String>[
        '_imageShown', // 已显示后禁止缓存字节覆盖（防"图变白再淡入"）
        '_cachedBytes', // 磁盘字节直显（切换/返回白屏）
        'gaplessPlayback', // TickerMode 恢复时不清帧（返回白屏）
        'memCacheWidth', // 按显示宽度解码（防 OOM 白屏）
        '_checkCacheOnUrlChange', // 切换缓存直显
        '_tryCacheBypass', // 排队中缓存命中绕过协调器
        '未传 memCacheWidth', // 大图漏配告警
      ];
      for (final guard in guards) {
        expect(material.contains(guard), isTrue,
            reason: 'Material 端缺失防线: $guard');
        expect(fluent.contains(guard), isTrue,
            reason: 'Fluent 端缺失防线: $guard —— 必须与 Material 同步');
      }
    });
  });
}
