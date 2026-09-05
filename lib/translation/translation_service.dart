/*
 * 翻译功能统一入口（协调器）：
 * - 按内容类型路由到配置的引擎（关闭/Bing/AI），未开启该类型时按键返回 null，不做任何事
 * - key 一律基于"原文 hash + 引擎 + 目标语言"，跨内容类型共享缓存
 * - 请求经 TranslationQueue 串行执行；结果写入缓存(磁盘+内存)与 TranslationStore
 * - UI 通过 keyOfText/displayOf/translatedHtmlOf 只读查询；列表卡片只读内存缓存，零网络
 *
 * 依赖注入：main.dart 在 userSetting.askInit() 后调用 TranslationService.init(...)。
 */

import 'package:pixez/models/illust.dart';
import 'package:pixez/translation/engine/bing_engine.dart';
import 'package:pixez/translation/engine/openai_engine.dart';
import 'package:pixez/translation/engine/translate_engine.dart';
import 'package:pixez/translation/protect/html_text_extractor.dart';
import 'package:pixez/translation/protect/seq_protector.dart';
import 'package:pixez/translation/translation_cache.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_queue.dart';
import 'package:pixez/translation/translation_store.dart';

class TranslationService {
  TranslationService._();

  static TranslationService instance = TranslationService._();

  static TranslationCacheStores defaultCaches = TranslationCacheStores(
    disk: TranslationCacheProvider(),
    memory: TranslationMemoryCache(),
    store: TranslationStore(),
  );

  /// 全局初始化（main.dart 在 askInit 之后调用）
  static Future<void> init({
    required TranslationConfig Function() configProvider,
    required String Function() uiLanguageProvider,
    TranslationCacheStores? caches,
  }) async {
    if (caches != null) {
      defaultCaches = caches;
    }
    _configProvider = configProvider;
    _uiLanguageProvider = uiLanguageProvider;
    await TranslationQueue.instance.warmup(defaultCaches);
  }

  static TranslationConfig Function() _configProvider =
      () => TranslationConfig();
  static String Function() _uiLanguageProvider = () => 'en-US';

  TranslationConfig get config => _configProvider();

  TranslationCacheStores get caches => defaultCaches;

  /// 最近一次翻译失败的原始错误（供 UI 提示定位；并发下为最后一次）
  String? get lastError => TranslationQueue.instance.lastError;

  /// 格式化失败原因（供 BotToast/InfoBar 展示）
  String describeLastError() {
    final e = lastError;
    if (e == null) return '';
    if (e.contains('Timeout') || e.contains('timed out')) {
      return ' (timeout)';
    }
    if (e.contains('429')) return ' (HTTP 429 rate limited)';
    if (RegExp(r'status code of (\d{3})').hasMatch(e)) {
      return ' (HTTP ${RegExp(r'status code of (\d{3})').firstMatch(e)!.group(1)})';
    }
    if (e.length > 60) return ' (${e.substring(0, 57)}...)';
    return ' ($e)';
  }

  BingEngine? _bing;

  /// 引擎解析：按配置返回；openai 每次读最新配置（无状态），bing 复用（token 缓存）
  TranslationEngine? _engineFor(TranslateContentType type) {
    final opt = config.effectiveEngineFor(type);
    if (opt == TranslateEngineOption.off) return null;
    if (opt == TranslateEngineOption.bing) {
      return _bing ??= BingEngine();
    }
    return OpenAiEngine(config.openai);
  }

  /// 目标语言解析：'auto' 跟随界面语言 <Languages[languageNum].language>
  String resolveTargetLang() {
    final target = config.targetLang;
    if (target.isNotEmpty && target != 'auto') return target;
    final uiLang = _uiLanguageProvider();
    return uiLang.isEmpty ? 'en-US' : uiLang;
  }

  /// 判断某内容类型当前是否启用了翻译
  bool isTypeEnabled(TranslateContentType type) => _engineFor(type) != null;

  /// 计算某段纯文本的缓存 key；该内容类型未开启时返回 null（UI 据此显示原文）。
  /// 注意：key 一律基于 trim 后的文本 —— 与 enqueueTexts/translateCaption 入队
  /// 所用的 key 保持一致，避免"同一节点两把 key"导致判定 miss（曾致富文本
  /// 简介尾随空格节点永远显示翻译失败）。
  String? keyOfText(String raw, TranslateContentType type) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final engine = _engineFor(type);
    if (engine == null) return null;
    return translationCacheKey(text,
        engine: engine.id, targetLang: resolveTargetLang());
  }

  /// 判定某段文本是否已有译文（含内存缓存）
  bool hasTranslationOf(String raw, TranslateContentType type) {
    final key = keyOfText(raw, type);
    if (key == null) return false;
    return caches.store.has(key) || caches.memory.has(key);
  }

  /// 该段文本是否正在翻译中（按钮转圈提示用）
  bool isPendingOf(String raw, TranslateContentType type) {
    final key = keyOfText(raw, type);
    return key != null && caches.store.pending.contains(key);
  }

  /// 取译文（无则 null），供 UI 显示
  String? translatedOf(String raw, TranslateContentType type) {
    final key = keyOfText(raw, type);
    if (key == null) return null;
    return caches.store.resultOf(key);
  }

  /// 触发翻译一段纯文本（幂等：已有结果/在途直接返回）。
  /// 返回是否已有译文（false = 请求失败/无结果，便于 UI 给出失败提示）。
  Future<bool> translateText(String raw, TranslateContentType type) async {
    final text = raw.trim();
    if (text.isEmpty) return true;
    final engine = _engineFor(type);
    if (engine == null) return true; // 未配置视为无操作
    final key = translationCacheKey(text,
        engine: engine.id, targetLang: resolveTargetLang());
    if (caches.store.has(key) || caches.memory.has(key)) return true;
    await TranslationQueue.instance.enqueue(engine, defaultCaches,
        items: [MapEntry(key, text)],
        targetLang: resolveTargetLang(),
        sourceLang: config.sourceLang,
        maxConcurrency: config.maxConcurrency);
    return caches.store.has(key) || caches.memory.has(key);
  }

  // ---------- 批量入口（小说正文等按段批量场景） ----------

  /// 批量翻译一组文本段（同一批一次请求）：seen 去重、过滤已缓存/在途、单批入队。
  /// 返回本批新入队条数（0 = 全部已缓存/在途，用于续传零成本跳过）。
  Future<int> enqueueTexts(
    List<String> texts,
    TranslateContentType type, {
    String? contextText,
  }) async {
    final engine = _engineFor(type);
    if (engine == null) return 0;
    final target = resolveTargetLang();
    final items = <MapEntry<String, String>>[];
    final seen = <String>{};
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      final key = translationCacheKey(trimmed,
          engine: engine.id, targetLang: target);
      if (caches.store.has(key) || caches.memory.has(key)) continue;
      if (caches.store.pending.contains(key)) continue;
      items.add(MapEntry(key, trimmed));
    }
    if (items.isEmpty) return 0;
    await TranslationQueue.instance.enqueue(engine, defaultCaches,
        items: items,
        targetLang: target,
        sourceLang: config.sourceLang,
        contextText: contextText,
        maxConcurrency: config.maxConcurrency);
    return items.length;
  }

  // ---------- 小说正文 ----------

  /// 小说 span 的段落级译文拼接：按 `\n` 拆段、逐段取译文，缺译段保留原文。
  /// 返回 null 表示无任何段落有译文（调用方显示原文）。
  /// 仅当 novelBody 类型开启时生效。
  String? translatedNovelBodyText(String text) {
    if (!isTypeEnabled(TranslateContentType.novelBody)) return null;
    final paras = text.split('\n');
    var changed = false;
    final result = paras.map((p) {
      if (p.trim().isEmpty) return p;
      final t = translatedOf(p, TranslateContentType.novelBody);
      if (t != null) {
        changed = true;
        final leading = RegExp(r'^\s*').firstMatch(p)?.group(0) ?? '';
        final trailing = RegExp(r'\s*$').firstMatch(p)?.group(0) ?? '';
        return '$leading$t$trailing';
      }
      return p;
    }).join('\n');
    return changed ? result : null;
  }

  // ---------- 标题 ----------

  /// 标题译文 key（未开启标题翻译时 null）
  String? titleKey(String title) => keyOfText(title, TranslateContentType.title);

  /// 列表卡片/详情页标题显示值：译文 ?? 原文
  String displayTitle(String title) =>
      translatedOf(title, TranslateContentType.title) ?? title;

  Future<bool> translateTitle(String title) =>
      translateText(title, TranslateContentType.title);

  // ---------- 标签 ----------

  /// 标签译文 key（未开启标签翻译时 null）
  String? tagKey(String name) => keyOfText(name, TranslateContentType.tag);

  /// 标签显示值：服务器 translatedName 优先 > 译文 > 原文
  String displayTagName(String name, String? serverTranslatedName) {
    if (serverTranslatedName != null && serverTranslatedName.isNotEmpty) {
      return serverTranslatedName;
    }
    return translatedOf(name, TranslateContentType.tag) ?? name;
  }

  /// 批量翻译作品缺失官方译名的标签（每次进入详情页触发一次，幂等）。
  /// 返回是否产生了至少一条译文（false = 请求失败，便于 UI 提示）。
  Future<bool> translateTags(Illusts illusts) async {
    final engine = _engineFor(TranslateContentType.tag);
    if (engine == null) return true;
    final items = <MapEntry<String, String>>[];
    final seen = <String>{};
    for (final tag in illusts.tags) {
      if (tag.translatedName != null && tag.translatedName!.isNotEmpty) {
        continue;
      }
      final name = tag.name.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      items.add(MapEntry(
        translationCacheKey(name,
            engine: engine.id, targetLang: resolveTargetLang()),
        name,
      ));
    }
    if (items.isEmpty) return true;
    await TranslationQueue.instance.enqueue(engine, defaultCaches,
        items: items,
        targetLang: resolveTargetLang(),
        sourceLang: config.sourceLang,
        maxConcurrency: config.maxConcurrency);
    // 全部失败时无任何结果
    return items.any((e) =>
        caches.store.has(e.key) || caches.memory.has(e.key));
  }

  // ---------- caption / 简介（HTML 结构保持） ----------

  /// caption 译文 HTML：逐文本节点恢复；只要至少一个节点有译文即可呈现译文，
  /// 缺失译文的节点平滑回退该节点自身原文（避免单个专有名词/纯符号未翻致整篇失败）。
  String? translatedCaptionHtml(String rawHtml, TranslateContentType type) {
    final texts = HtmlTextExtractor.extractTexts(rawHtml);
    if (texts.isEmpty) return null;
    final translations = <String>[];
    var hasAnyTranslation = false;
    for (final text in texts) {
      final key = keyOfText(text, type);
      final value = key != null
          ? (caches.store.resultOf(key) ?? caches.memory.get(key))
          : null;
      if (value != null && value.isNotEmpty) {
        hasAnyTranslation = true;
        translations.add(value);
      } else {
        translations.add(text.trim());
      }
    }
    if (!hasAnyTranslation) return null;
    return HtmlTextExtractor.restore(rawHtml, translations);
  }

  /// 触发 caption 翻译（逐文本节点入队，跨作品共享短句缓存）。
  /// 返回是否产出完整译文 HTML（false = 请求失败，便于 UI 提示）。
  Future<bool> translateCaption(String rawHtml, TranslateContentType type) async {
    final engine = _engineFor(type);
    if (engine == null) return true;
    final texts = HtmlTextExtractor.extractTexts(rawHtml);
    if (texts.isEmpty) return true;
    final items = <MapEntry<String, String>>[];
    final seen = <String>{};
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      items.add(MapEntry(
        translationCacheKey(trimmed,
            engine: engine.id, targetLang: resolveTargetLang()),
        trimmed,
      ));
    }
    if (items.isEmpty) return true;
    await TranslationQueue.instance.enqueue(engine, defaultCaches,
        items: items,
        targetLang: resolveTargetLang(),
        sourceLang: config.sourceLang,
        maxConcurrency: config.maxConcurrency);
    return translatedCaptionHtml(rawHtml, type) != null;
  }

  /// 是否已全部翻译（用于按钮"已翻译"提示）
  bool hasTranslationOfCaption(String rawHtml, TranslateContentType type) {
    return translatedCaptionHtml(rawHtml, type) != null;
  }

  // ---------- 评论（含 (emoji) token 保护） ----------

  /// 评论正文的 emoji token（与 CommentEmojiText 的解析一致）
  static final RegExp commentEmojiRegex = RegExp(r'\([A-Za-z0-9_]+\)');

  /// 触发整条评论翻译：文本段批译（共享短句缓存），恢复后以"整条原文 hash"为 key 缓存
  Future<bool> translateComment(String rawComment) async {
    final type = TranslateContentType.comment;
    final engine = _engineFor(type);
    if (engine == null) return true;
    final texts = SeqProtector.extractTexts(rawComment, commentEmojiRegex);
    if (texts.isEmpty) return true;
    // 仅对缺失译文的段入队（短句跨评论共享）
    final items = <MapEntry<String, String>>[];
    final seen = <String>{};
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      final key = translationCacheKey(trimmed,
          engine: engine.id, targetLang: resolveTargetLang());
      if (caches.store.has(key) || caches.memory.has(key)) continue;
      items.add(MapEntry(key, trimmed));
    }
    if (items.isNotEmpty) {
      await TranslationQueue.instance.enqueue(engine, defaultCaches,
          items: items,
          targetLang: resolveTargetLang(),
          sourceLang: config.sourceLang,
          maxConcurrency: config.maxConcurrency);
    }
    // 所有文本段已齐，恢复整条译文并缓存（整条 key 供 UI 直接读取）
    final translatedSegments = <String>[];
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      final value = _translatedCached(trimmed, engine.id, resolveTargetLang());
      if (value == null) return false;
      translatedSegments.add(value);
    }
    final whole = SeqProtector.restore(
        rawComment, commentEmojiRegex, translatedSegments);
    if (whole.trim().isEmpty) return false;
    final wholeKey = translationCacheKey(rawComment,
        engine: engine.id, targetLang: resolveTargetLang());
    if (!caches.store.has(wholeKey)) {
      await caches.disk.insert(TranslationCacheEntry(
        key: wholeKey,
        value: whole,
        expireTime:
            DateTime.now().millisecondsSinceEpoch + caches.ttlSeconds * 1000,
        dateTime: DateTime.now().millisecondsSinceEpoch,
      ));
      caches.memory.set(wholeKey, whole);
      caches.store.setResult(wholeKey, whole);
    }
    return true;
  }

  String? _translatedCached(String text, String engineId, String targetLang) {
    final key =
        translationCacheKey(text, engine: engineId, targetLang: targetLang);
    return caches.store.resultOf(key) ?? caches.memory.get(key);
  }

  /// caption 是否任一文本节点正在翻译中（按钮转圈提示用）
  bool isPendingCaption(String rawHtml, TranslateContentType type) {
    final texts = HtmlTextExtractor.extractTexts(rawHtml);
    for (final text in texts) {
      final key = keyOfText(text, type);
      if (key != null && caches.store.pending.contains(key)) return true;
    }
    return false;
  }
}
