/*
 * 全局翻译队列：信号量限制的并行请求（maxConcurrency 可配，1=串行）。
 * 相同 key 去重（同一文本在标题/标签多次出现只发一次请求）。
 * 任何异常吞掉不抛（回退原文），日志走 LPrinter。
 */

import 'dart:async';

import 'package:pixez/er/lprinter.dart';
import 'package:pixez/translation/engine/translate_engine.dart';
import 'package:pixez/translation/translation_cache.dart';
import 'package:pixez/translation/translation_store.dart';

class TranslationCacheStores {
  final TranslationCacheProvider disk;
  final TranslationMemoryCache memory;
  final TranslationStore store;
  final int ttlSeconds;

  const TranslationCacheStores({
    required this.disk,
    required this.memory,
    required this.store,
    this.ttlSeconds = 180 * 24 * 3600,
  });
}

/// 判定"译文==原文"是否算失败：
/// - 文本含目标语言之外的书写系统（目标中文时含日文假名/谚文等）→ 模型没翻，判失败；
/// - 品牌名/专有名词/目标语言同源文本（如【Fantia】）被模型保留原文是合法行为 → 判保留。
/// 目前仅对中文目标做特判（Pixiv 主要日→中场景）；其它目标语言宽松（保留不判失败）。
bool isSameResultFailure(String original, String joined, String targetLang) {
  if (joined != original.trim()) return false; // 有差异即成功
  if (!targetLang.startsWith('zh')) return false;
  // 含日文假名/谚文 → 明确是外语，必须翻译，原样返回判失败
  return RegExp(r'[ぁ-ゖァ-ヺー]|[가-힣]').hasMatch(original);
}

/// 并发门闩：限制最大在途数（信号量；可独立测试）。
/// 许可上限跟随最近一次 [acquire] 的 limit（配置变化即时生效）。
class ConcurrencyGate {
  int _limit;
  int _running = 0;
  final List<Completer<void>> _waiters = [];

  ConcurrencyGate({int limit = 1}) : _limit = limit < 1 ? 1 : limit;

  /// 申请执行权；在途数达到上限时排队等待（被唤醒后重新检查）
  Future<void> acquire([int? limit]) async {
    if (limit != null && limit >= 1) _limit = limit;
    while (_running >= _limit) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    _running++;
  }

  /// 释放执行权并唤醒一个等待者（FIFO）
  void release() {
    _running--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}

class TranslationQueue {
  static TranslationQueue instance = TranslationQueue._();

  TranslationQueue._();

  /// 并行执行：并发门闩控制最大在途请求数（按调用方 maxConcurrency）；
  /// maxConcurrency=1 时退化为严格串行。
  final ConcurrencyGate _gate = ConcurrencyGate();
  final Set<String> _inflight = {};
  final Map<String, Completer<void>> _inflightCompleters = {};
  int _writeCount = 0;

  /// 最近一次失败的原始错误（供 UI 展示具体失败原因）
  String? lastError;

  /// 单次 HTTP 请求的字符预算（在 ≤100 段之上再加字符限制，防止超长富文本
  /// 单节点/单批膨胀到接近模型上下文上限导致超时或被服务端拒绝）
  static const int requestCharsCap = 6000;

  /// 入队一个翻译批次；引擎结果自动写缓存并推送到 store。
  /// [maxConcurrency] 为全局并行上限（1~10）。
  Future<void> enqueue(
    TranslationEngine engine,
    TranslationCacheStores caches, {
    required List<MapEntry<String, String>> items, // key -> text
    required String targetLang,
    String? sourceLang,
    String? contextText,
    int maxConcurrency = 1,
  }) async {
    // 收集已在途的异步任务，以便等候其完成
    final inFlightFutures = items
        .where((e) => _inflight.contains(e.key))
        .map((e) => _inflightCompleters[e.key]?.future)
        .whereType<Future<void>>()
        .toList();

    // 过滤在途与已完成缓存的 key
    final pending = items
        .where((e) =>
            !caches.memory.has(e.key) &&
            !caches.store.has(e.key) &&
            !_inflight.contains(e.key))
        .toList();

    if (pending.isEmpty) {
      if (inFlightFutures.isNotEmpty) {
        await Future.wait(inFlightFutures);
      }
      return;
    }

    for (final e in pending) {
      _inflight.add(e.key);
      _inflightCompleters[e.key] = Completer<void>();
      caches.store.markPending(e.key, true);
    }

    await _gate.acquire(maxConcurrency);
    try {
      await _run(engine, caches, pending,
          targetLang: targetLang,
          sourceLang: sourceLang,
          contextText: contextText);
    } finally {
      _gate.release();
    }

    if (inFlightFutures.isNotEmpty) {
      await Future.wait(inFlightFutures);
    }
  }

  Future<void> _run(
    TranslationEngine engine,
    TranslationCacheStores caches,
    List<MapEntry<String, String>> items, {
    required String targetLang,
    String? sourceLang,
    String? contextText,
  }) async {
    try {
      // 翻译前按顺序展开所有文本段（>900 字符自动分段）
      final needSplit = items.any((e) => e.value.length > 900);
      final segments = <String>[]; // 全部待翻文本
      final offsets = <int>[]; // 每条 items 在 segments 中的起始下标
      if (!needSplit) {
        for (final e in items) {
          offsets.add(segments.length);
          segments.add(e.value);
        }
      } else {
        for (final e in items) {
          offsets.add(segments.length);
          segments.addAll(TranslationSplitter.split(e.value));
        }
      }
      // 分段转发：每请求 ≤100 段 且 ≤requestCharsCap 字符（双限制，防超长请求）
      final results = <String>[];
      var i = 0;
      while (i < segments.length) {
        final part = <String>[];
        var chars = 0;
        while (i < segments.length &&
            part.length < 100 &&
            (chars == 0 || chars + segments[i].length <= requestCharsCap)) {
          part.add(segments[i]);
          chars += segments[i].length;
          i++;
        }
        if (part.isEmpty) break; // 理论不可达（split 段 ≤900），防御
        results.addAll(await engine.translateTexts(part,
            targetLang: targetLang,
            sourceLang: sourceLang,
            contextText: contextText));
      }
      // 按 items 拼回并写缓存
      var segIndex = 0;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final count = item.value.length > 900
            ? TranslationSplitter.split(item.value).length
            : 1;
        final parts = results.sublist(segIndex, segIndex + count);
        segIndex += count;
        final joined = parts.join('').trim();
        // 空译文视为失败不写缓存（可重试）。
        if (joined.isEmpty) {
          lastError = 'empty translation result';
          continue;
        }
        // 译文==原文：按目标语言书写特征区分——
        // 真外语未翻（如日文→中文返回日文）判失败不缓存；
        // 品牌名/专有名词等被模型合理保留原文则照常写缓存（避免误报失败）。
        if (isSameResultFailure(item.value, joined, targetLang)) {
          lastError =
              'translation equals original (may be untranslatable content)';
          continue;
        }
        await caches.disk.insert(TranslationCacheEntry(
          key: item.key,
          value: joined,
          expireTime:
              DateTime.now().millisecondsSinceEpoch + caches.ttlSeconds * 1000,
          dateTime: DateTime.now().millisecondsSinceEpoch,
        ));
        caches.memory.set(item.key, joined);
        caches.store.setResult(item.key, joined);
        _writeCount++;
        // 低频过期清理
        if (_writeCount % 500 == 0) {
          await caches.disk.deleteExpired();
        }
      }
    } catch (e) {
      lastError = e.toString();
      LPrinter.d('translation failed: $e');
      // 失败：不写任何 key，回退原文
    } finally {
      for (final e in items) {
        _inflight.remove(e.key);
        final c = _inflightCompleters.remove(e.key);
        if (c != null && !c.isCompleted) {
          c.complete();
        }
        caches.store.markPending(e.key, false);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100)); // 批间间隔
    }
  }

  /// 启动 warmup：磁盘未过期条目 -> 内存 + store（列表卡片因此可只读内存）
  Future<void> warmup(TranslationCacheStores caches) async {
    try {
      final entries = await caches.disk.getAllNotExpired();
      final map = <String, String>{
        for (final e in entries) e.key: e.value,
      };
      caches.memory.loadAll(map);
      caches.store.loadAll(map);
    } catch (e) {
      LPrinter.d('translation warmup failed: $e');
    }
  }
}
