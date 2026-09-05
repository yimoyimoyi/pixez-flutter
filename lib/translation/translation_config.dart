/*
 * 翻译配置模型：供 Pixez 内容(标签/标题/简介等)机翻/AI 翻译使用。
 * 配置序列化为单 JSON 字符串存入 SharedPreferences(user_setting 挂载)。
 */

import 'dart:convert';

/// 翻译内容类型
enum TranslateContentType { tag, title, caption, comment, novelBody, generic }

/// 每类内容可选的翻译方式
enum TranslateEngineOption { off, bing, openai }

/// 单内容类型的翻译配置
class PerTypeTranslateConfig {
  TranslateEngineOption engine;

  PerTypeTranslateConfig({this.engine = TranslateEngineOption.off});

  Map<String, dynamic> toJson() => {'engine': engine.name};

  factory PerTypeTranslateConfig.fromJson(Map<String, dynamic> json) {
    final name = json['engine'] as String? ?? 'off';
    return PerTypeTranslateConfig(engine: _engineFromName(name));
  }

  static TranslateEngineOption _engineFromName(String name) {
    return TranslateEngineOption.values.firstWhere(
      (e) => e.name == name,
      orElse: () => TranslateEngineOption.off,
    );
  }
}

/// OpenAI 兼容引擎参数（可指向 Ollama/DeepSeek/各类中转）
class OpenAiEngineConfig {
  String baseUrl;
  String apiKey;
  String model;
  double temperature;
  int timeoutSeconds;

  /// 思考模式（DeepSeek V4 专用；openai 时按 URL 判定）：
  /// false = 请求体带 thinking.type=disabled（默认，翻译提速降耗）；
  /// true  = 开启思考模式，可用 [reasoningEffort] 限制思考深度
  bool thinkingMode;
  String reasoningEffort; // 'low' | 'high' | 'max'（仅思考模式生效）

  /// 输出 token 上限（null = 不限制，仅 DeepSeek 思考模式建议限制以控费）
  int? maxTokens;

  OpenAiEngineConfig({
    this.baseUrl = '',
    this.apiKey = '',
    // 默认 DeepSeek（已验证与 OpenAI 格式兼容、无 QPS 限制、价格低）；可改为任意 OpenAI 兼容模型
    this.model = 'deepseek-v4-flash',
    this.temperature = 0.2,
    this.timeoutSeconds = 30,
    this.thinkingMode = false,
    this.reasoningEffort = 'low',
    this.maxTokens,
  });

  /// 是否已配置可用（baseUrl 必须是 http/https 地址）
  bool get isConfigured =>
      baseUrl.trim().startsWith('http://') ||
      baseUrl.trim().startsWith('https://');

  /// 是否 DeepSeek 后端（thinking 参数仅对其发送，避免其他端点参数校验拒绝）
  bool get isDeepSeek => baseUrl.toLowerCase().contains('deepseek');

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'timeoutSeconds': timeoutSeconds,
        'thinkingMode': thinkingMode,
        'reasoningEffort': reasoningEffort,
        'maxTokens': maxTokens,
      };

  factory OpenAiEngineConfig.fromJson(Map<String, dynamic> json) {
    return OpenAiEngineConfig(
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? 'deepseek-v4-flash',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.2,
      timeoutSeconds: json['timeoutSeconds'] as int? ?? 30,
      thinkingMode: json['thinkingMode'] as bool? ?? false,
      reasoningEffort: json['reasoningEffort'] as String? ?? 'low',
      maxTokens: json['maxTokens'] as int?,
    );
  }
}

/// 全局翻译配置（单 JSON key 存储）
class TranslationConfig {
  static const int currentVersion = 1;

  int version;
  bool masterEnabled;
  /// 'auto' 表示跟随界面语言；否则显式如 'zh-CN'/'zh-TW'/'en-US'/'ja'/...
  String targetLang;
  /// 源语言，null 表示自动检测（主要日语）
  String? sourceLang;
  OpenAiEngineConfig openai;
  Map<TranslateContentType, PerTypeTranslateConfig> byType;

  /// 小说正文翻译：单批最长字符（兜底值；单段超预算时由队列句边界二次切分）
  int novelBatchChars;
  /// 小说正文翻译：单批最多段落数（\n 拆段计数）
  int novelBatchSpanCap;
  /// 小说正文翻译：上下文段提示（前一段原文 ≤1200 字符随请求发送）
  bool useNovelContext;

  /// 最大并行请求数（全局；1 = 串行即旧行为；DeepSeek 无 QPS 限制，可安全提速）
  int maxConcurrency;

  static const int minBatchChars = 1000;
  static const int maxBatchChars = 20000;
  static const int minBatchSpanCap = 1;
  static const int maxBatchSpanCap = 50;
  static const int minConcurrency = 1;
  static const int maxConcurrencyLimit = 10;

  TranslationConfig({
    this.version = currentVersion,
    this.masterEnabled = true,
    this.targetLang = 'auto',
    this.sourceLang,
    OpenAiEngineConfig? openai,
    Map<TranslateContentType, PerTypeTranslateConfig>? byType,
    this.novelBatchChars = 6000,
    this.novelBatchSpanCap = 10,
    this.useNovelContext = true,
    this.maxConcurrency = 2,
  })  : openai = openai ?? OpenAiEngineConfig(),
        byType = byType ?? _defaults();

  static Map<TranslateContentType, PerTypeTranslateConfig> _defaults() {
    return {
      for (final type in TranslateContentType.values)
        type: PerTypeTranslateConfig(),
    };
  }

  /// 指定内容类型的有效引擎配置（总开关关闭或未配置时返回 off）
  TranslateEngineOption effectiveEngineFor(TranslateContentType type) {
    if (!masterEnabled) return TranslateEngineOption.off;
    final cfg = byType[type];
    if (cfg == null || cfg.engine == TranslateEngineOption.off) {
      return TranslateEngineOption.off;
    }
    // Bing 免 key 通道已被微软停用/风控（2026-09），暂时隐藏并视为关闭；
    // 枚举与存储保留，便于日后恢复
    if (cfg.engine == TranslateEngineOption.bing) {
      return TranslateEngineOption.off;
    }
    if (cfg.engine == TranslateEngineOption.openai && !openai.isConfigured) {
      // OpenAI 未配置 baseUrl 时视为关闭，避免无意义的请求
      return TranslateEngineOption.off;
    }
    return cfg.engine;
  }

  TranslationConfig copyWith({
    bool? masterEnabled,
    String? targetLang,
    String? sourceLang,
    OpenAiEngineConfig? openai,
    Map<TranslateContentType, PerTypeTranslateConfig>? byType,
    int? novelBatchChars,
    int? novelBatchSpanCap,
    bool? useNovelContext,
    int? maxConcurrency,
  }) {
    return TranslationConfig(
      version: version,
      masterEnabled: masterEnabled ?? this.masterEnabled,
      targetLang: targetLang ?? this.targetLang,
      sourceLang: sourceLang ?? this.sourceLang,
      openai: openai ?? this.openai,
      byType: byType ?? {...this.byType},
      novelBatchChars: novelBatchChars ?? this.novelBatchChars,
      novelBatchSpanCap: novelBatchSpanCap ?? this.novelBatchSpanCap,
      useNovelContext: useNovelContext ?? this.useNovelContext,
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'masterEnabled': masterEnabled,
        'targetLang': targetLang,
        'sourceLang': sourceLang,
        'openai': openai.toJson(),
        'byType': byType.map((k, v) => MapEntry(k.name, v.toJson())),
        'novelBatchChars': novelBatchChars,
        'novelBatchSpanCap': novelBatchSpanCap,
        'useNovelContext': useNovelContext,
        'maxConcurrency': maxConcurrency,
      };

  factory TranslationConfig.fromJson(Map<String, dynamic> json) {
    final rawByType = json['byType'] as Map<String, dynamic>? ?? {};
    final byType = <TranslateContentType, PerTypeTranslateConfig>{
      for (final type in TranslateContentType.values)
        type:
            PerTypeTranslateConfig.fromJson(rawByType[type.name] as Map<String, dynamic>? ?? {}),
    };
    return TranslationConfig(
      version: json['version'] as int? ?? currentVersion,
      masterEnabled: json['masterEnabled'] as bool? ?? true,
      targetLang: json['targetLang'] as String? ?? 'auto',
      sourceLang: json['sourceLang'] as String?,
      openai: OpenAiEngineConfig.fromJson(
          json['openai'] as Map<String, dynamic>? ?? {}),
      byType: byType,
      novelBatchChars: _clampInt(json['novelBatchChars'], minBatchChars,
          maxBatchChars, 6000),
      novelBatchSpanCap: _clampInt(json['novelBatchSpanCap'],
          minBatchSpanCap, maxBatchSpanCap, 10),
      useNovelContext: json['useNovelContext'] as bool? ?? true,
      maxConcurrency: _clampInt(json['maxConcurrency'], minConcurrency,
          maxConcurrencyLimit, 2),
    );
  }

  static int _clampInt(dynamic value, int min, int max, int fallback) {
    if (value is! num) return fallback;
    final v = value.toInt();
    return v < min ? min : (v > max ? max : v);
  }

  factory TranslationConfig.decode(String jsonStr) {
    if (jsonStr.isEmpty) return TranslationConfig();
    try {
      return TranslationConfig.fromJson(jsonDecode(jsonStr));
    } catch (_) {
      return TranslationConfig();
    }
  }

  String encode() => jsonEncode(toJson());
}
