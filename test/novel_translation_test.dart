/*
 * 小说正文翻译纯逻辑测试：段落统计、批预算分组、可译过滤器、配置容错。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_cache.dart';
import 'package:pixez/translation/translation_queue.dart';
import 'package:pixez/translation/translation_store.dart';
import 'package:pixez/translation/engine/translate_engine.dart';

class _FakeEngine implements TranslationEngine {
  int calls = 0;
  int running = 0;
  int peakConcurrent = 0;
  @override
  String get id => 'fake';
  @override
  Future<List<String>> translateTexts(List<String> texts,
      {required String targetLang, String? sourceLang, String? contextText}) async {
    calls++;
    running++;
    peakConcurrent = running > peakConcurrent ? running : peakConcurrent;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    running--;
    return texts; // 原样返回（键按原文寻址，结果不影响断言）
  }
}

void main() {
  group('isTranslatableSpan / novelTranslatableStats', () {
    test('过滤器：拒绝非 normal/空/回退键/URL', () {
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.normal, '本文')),
          true);
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.newPage, '')),
          false);
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.jumpUri, 'https://pixiv.net')),
          false);
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.normal, '')),
          false);
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.normal, '[uploadedimage:abc]')),
          false);
      expect(isTranslatableNovelSpan(
          NovelSpansData(NovelSpansType.normal, '見る https://ex.com へ')),
          false);
    });

    test('统计：\n 拆段、过滤空白段', () {
      final spans = [
        NovelSpansData(NovelSpansType.normal, '第一段\n第二段\n\n第三段'),
        NovelSpansData(NovelSpansType.normal, ''),
        NovelSpansData(NovelSpansType.normal, '[chapter]标题'), // 以 [ 开头回退键，跳过
        NovelSpansData(NovelSpansType.pixivImage, ''),
        NovelSpansData(NovelSpansType.normal, '章节标题'), // 正常标题（已剥括号），可译
      ];
      // 可译：第一个 span 内 3 个非空段 + 纯中文标题段
      final stats = novelTranslatableStats(spans);
      expect(stats.parasCount, 4);
      expect(stats.charsCount, greaterThan(4));
    });
  });

  group('buildNovelBatches', () {
    test('按段落数上限与字符兜底分组', () {
      final paras = List.generate(
        25,
        (i) => '段$i${'字' * 10}',
      ); // 每段 12+ 字符
      final batches = buildNovelBatches(paras,
          batchSpanCap: 10, batchChars: 6000);
      expect(batches.length, 3); // 10+10+5
      expect(batches.fold<int>(0, (a, b) => a + b.length), 25);
      // 保序
      expect(batches[0].first, 0);
      expect(batches[0].last, 9);
      expect(batches[1].first, 10);
    });

    test('字符兜底优先：单段超预算单独成批', () {
      final paras = ['短', '超长段' * 2000, '尾'];
      final batches = buildNovelBatches(paras,
          batchSpanCap: 2, batchChars: 100);
      // 第 0 段入批；第 1 段超预算 -> 单独成批；第 2 段单独
      expect(batches.length, 3);
      expect(batches[1], [1]);
    });
  });


  group('TranslationQueue 并发信号量', () {
    test('maxConcurrency 限制峰值的并行', () async {
      final queue = TranslationQueue.instance;
      final fake = _FakeEngine();
      final caches = TranslationCacheStores(
        disk: _NoopDisk(),
        memory: TranslationMemoryCache(),
        store: TranslationStore(),
      );
      final items = [
        for (var i = 0; i < 10; i++)
          MapEntry('v1|t|k$i', '段$i')
      ];
      final futures = [
        for (var i = 0; i < 10; i++)
          queue.enqueue(fake, caches,
              items: [items[i]],
              targetLang: 'zh-CN',
              maxConcurrency: 3)
      ];
      await Future.wait(futures);
      expect(fake.peakConcurrent, lessThanOrEqualTo(3));
      expect(fake.peakConcurrent, greaterThan(1)); // 确实并行
      expect(fake.calls, 10);
    });

    test('maxConcurrency=1 严格串行', () async {
      final queue = TranslationQueue.instance;
      final fake = _FakeEngine();
      final caches = TranslationCacheStores(
        disk: _NoopDisk(),
        memory: TranslationMemoryCache(),
        store: TranslationStore(),
      );
      for (var i = 0; i < 5; i++) {
        await queue.enqueue(fake, caches,
            items: [MapEntry('v1|t|s$i', '段$i')],
            targetLang: 'zh-CN',
            maxConcurrency: 1);
      }
      expect(fake.peakConcurrent, 1);
      expect(fake.calls, 5);
    });
  });

  group('TranslationConfig 小说参数', () {
    test('旧 JSON 缺 novelBody/批参数 -> 默认', () {
      final decoded = TranslationConfig.decode(
          '{"masterEnabled":true,"targetLang":"auto","openai":{}}');
      expect(decoded.effectiveEngineFor(TranslateContentType.novelBody),
          TranslateEngineOption.off);
      expect(decoded.novelBatchChars, 6000);
      expect(decoded.novelBatchSpanCap, 10);
      expect(decoded.useNovelContext, true);
    });

    test('批参数越界被钳制', () {
      final decoded = TranslationConfig.decode(
          '{"novelBatchChars":999999,"novelBatchSpanCap":0,"useNovelContext":false}');
      expect(decoded.novelBatchChars, TranslationConfig.maxBatchChars);
      expect(decoded.novelBatchSpanCap, TranslationConfig.minBatchSpanCap);
      expect(decoded.useNovelContext, false);
    });
  });
}

class _NoopDisk extends TranslationCacheProvider {
  @override
  Future<void> insert(TranslationCacheEntry entry) async {}

  @override
  Future<TranslationCacheEntry?> get(String key) async => null;

  @override
  Future<List<TranslationCacheEntry>> getAllNotExpired() async => [];
}
