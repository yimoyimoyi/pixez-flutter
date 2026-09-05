/*
 * 机翻/AI 翻译设置页（Material 皮肤）。
 * 配置即改即存（单 JSON key 写入 SharedPreferences）。
 */

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/translation/engine/bing_engine.dart';
import 'package:pixez/translation/translation_config.dart';

class TranslationSettingPage extends StatefulWidget {
  const TranslationSettingPage({super.key});

  @override
  State<TranslationSettingPage> createState() => _TranslationSettingPageState();
}

class _TranslationSettingPageState extends State<TranslationSettingPage> {
  bool _testingBing = false;
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late TextEditingController _temperatureController;
  late TextEditingController _maxTokensController;
  late TextEditingController _batchCharsController;
  late TextEditingController _batchSpanCapController;
  late TextEditingController _concurrencyController;

  TranslationConfig get _config => userSetting.translateConfig;

  @override
  void initState() {
    super.initState();
    final cfg = _config;
    _baseUrlController = TextEditingController(text: cfg.openai.baseUrl);
    _apiKeyController = TextEditingController(text: cfg.openai.apiKey);
    _modelController = TextEditingController(text: cfg.openai.model);
    _temperatureController =
        TextEditingController(text: cfg.openai.temperature.toStringAsFixed(2));
    _maxTokensController =
        TextEditingController(text: cfg.openai.maxTokens?.toString() ?? '');
    _batchCharsController =
        TextEditingController(text: cfg.novelBatchChars.toString());
    _batchSpanCapController =
        TextEditingController(text: cfg.novelBatchSpanCap.toString());
    _concurrencyController =
        TextEditingController(text: cfg.maxConcurrency.toString());
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _temperatureController.dispose();
    _maxTokensController.dispose();
    _batchCharsController.dispose();
    _batchSpanCapController.dispose();
    _concurrencyController.dispose();
    super.dispose();
  }

  void _updateConfig(TranslationConfig Function(TranslationConfig) updater) {
    userSetting.setTranslateConfig(updater(_config));
  }

  /// 修改 OpenAI 兼容配置且保留其他字段
  void _updateOpenAi(void Function(OpenAiEngineConfig) updater) {
    final o = _config.openai;
    final n = OpenAiEngineConfig(
      baseUrl: o.baseUrl,
      apiKey: o.apiKey,
      model: o.model,
      temperature: o.temperature,
      timeoutSeconds: o.timeoutSeconds,
      thinkingMode: o.thinkingMode,
      reasoningEffort: o.reasoningEffort,
      maxTokens: o.maxTokens,
    );
    updater(n);
    _updateConfig((c) => c.copyWith(openai: n));
  }

  Future<void> _testBing(BuildContext context) async {
    setState(() => _testingBing = true);
    try {
      final engine = BingEngine();
      final results =
          await engine.translateTexts(['こんにちは'], targetLang: 'zh-Hans');
      if (results.isNotEmpty && results.first.isNotEmpty) {
        BotToast.showText(
            text: 'Bing 机翻连接正常: こんにちは -> ${results.first}');
      } else {
        BotToast.showText(text: 'Bing 机翻响应异常，未返回有效结果');
      }
    } catch (e) {
      BotToast.showText(text: 'Bing 机翻连接失败: $e');
    } finally {
      if (mounted) setState(() => _testingBing = false);
    }
  }

  void _applyAllToBing() {
    _updateConfig((c) => c.copyWith(
          byType: {
            ...c.byType,
            TranslateContentType.tag:
                PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
            TranslateContentType.title:
                PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
            TranslateContentType.caption:
                PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
            TranslateContentType.comment:
                PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
            TranslateContentType.generic:
                PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
          },
        ));
    BotToast.showText(text: '已将标签、标题、简介、评论、选区设为 Bing 机翻');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(I18n.of(context).translation_settings)),
      body: Observer(
        builder: (context) {
          final cfg = _config;
          final languageOptions = [
            I18n.of(context).translation_target_lang_auto,
            '简体中文',
            '繁體中文',
            'English',
            '日本語',
          ];
          final languageValues = ['auto', 'zh-CN', 'zh-TW', 'en-US', 'ja'];
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                value: cfg.masterEnabled,
                title: Text(I18n.of(context).translation_master_switch),
                onChanged: (value) {
                  _updateConfig((c) => c.copyWith(masterEnabled: value));
                },
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(I18n.of(context).translation_target_lang),
                trailing: DropdownButton<String>(
                  value: cfg.targetLang,
                  onChanged: (value) {
                    if (value == null) return;
                    _updateConfig((c) => c.copyWith(targetLang: value));
                  },
                  items: [
                    for (var i = 0; i < languageValues.length; i++)
                      DropdownMenuItem(
                        value: languageValues[i],
                        child: Text(languageOptions[i]),
                      ),
                  ],
                ),
              ),
              _textField(_concurrencyController,
                  I18n.of(context).translation_max_concurrency,
                  keyboardType: TextInputType.number, onUpdate: (v) {
                final value = int.tryParse(v);
                if (value != null &&
                    value >= TranslationConfig.minConcurrency &&
                    value <= TranslationConfig.maxConcurrencyLimit) {
                  _updateConfig((c) => c.copyWith(maxConcurrency: value));
                }
              }),
              const Divider(),
              // 每种内容类型独立选择翻译方式（Bing 机翻暂时隐藏）
              _engineSelector(context, TranslateContentType.tag,
                  I18n.of(context).translation_content_tag),
              _engineSelector(context, TranslateContentType.title,
                  I18n.of(context).translation_content_title),
              _engineSelector(context, TranslateContentType.caption,
                  I18n.of(context).translation_content_caption),
              _engineSelector(context, TranslateContentType.comment,
                  I18n.of(context).translation_content_comment),
              _engineSelector(context, TranslateContentType.novelBody,
                  I18n.of(context).translation_content_novel_body),
              _engineSelector(context, TranslateContentType.generic,
                  I18n.of(context).translation_content_generic),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  I18n.of(context).translation_engine_bing,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(I18n.of(context).translation_engine_bing),
                subtitle: const Text(
                    '微软 Edge 免费机翻通道（免 Key 开箱即用），支持标签、标题、简介与短文本翻译；自动适配系统代理。'),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      icon: _testingBing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check, size: 18),
                      label: const Text('测试连通性'),
                      onPressed:
                          _testingBing ? null : () => _testBing(context),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      icon: const Icon(Icons.done_all, size: 18),
                      label: const Text('一键设为机翻'),
                      onPressed: _applyAllToBing,
                    ),
                  ],
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'OpenAI Compatible',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              // OpenAI 兼容参数
              _textField(_baseUrlController,
                  I18n.of(context).translation_openai_base_url,
                  hint: 'https://api.deepseek.com/v1',
                  keyboardType: TextInputType.url, onUpdate: (v) {
                _updateOpenAi((c) => c.baseUrl = v.trim());
              }),
              _textField(_apiKeyController,
                  I18n.of(context).translation_openai_api_key,
                  hint: 'sk-...', onUpdate: (v) {
                _updateOpenAi((c) => c.apiKey = v.trim());
              }),
              _textField(_modelController,
                  I18n.of(context).translation_openai_model,
                  hint: 'deepseek-v4-flash', onUpdate: (v) {
                _updateOpenAi((c) => c.model = v.trim());
              }),
              _textField(_temperatureController,
                  I18n.of(context).translation_openai_temperature,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onUpdate: (v) {
                final value = double.tryParse(v);
                if (value != null && value >= 0 && value <= 2) {
                  _updateOpenAi((c) => c.temperature = value);
                }
              }),
              SwitchListTile(
                title: Text(I18n.of(context).translation_thinking_mode),
                subtitle: Text(I18n.of(context).translation_thinking_hint),
                value: cfg.openai.thinkingMode,
                onChanged: (value) {
                  _updateOpenAi((c) => c.thinkingMode = value);
                },
              ),
              if (cfg.openai.thinkingMode)
                ListTile(
                  leading: const Icon(Icons.psychology),
                  title: Text(I18n.of(context).translation_reasoning_effort),
                  trailing: DropdownButton<String>(
                    value: cfg.openai.reasoningEffort,
                    items: [
                      for (final level in ['low', 'high', 'max'])
                        DropdownMenuItem(
                          value: level,
                          child: Text(level),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _updateOpenAi((c) => c.reasoningEffort = value);
                    },
                  ),
                ),
              _textField(_maxTokensController,
                  I18n.of(context).translation_max_tokens,
                  keyboardType: TextInputType.number, onUpdate: (v) {
                final value = int.tryParse(v);
                _updateOpenAi((c) => c.maxTokens =
                    (value != null && value > 0) ? value : null);
              }),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  I18n.of(context).translation_novel_batch_title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              // 小说正文翻译：批容量（段落数为准，字符为兜底）与上下文提示
              _textField(_batchCharsController,
                  I18n.of(context).translation_batch_chars,
                  keyboardType: TextInputType.number, onUpdate: (v) {
                final value = int.tryParse(v);
                if (value != null && value >= TranslationConfig.minBatchChars && value <= TranslationConfig.maxBatchChars) {
                  _updateConfig((c) => c.copyWith(novelBatchChars: value));
                }
              }),
              _textField(_batchSpanCapController,
                  I18n.of(context).translation_batch_span_cap,
                  keyboardType: TextInputType.number, onUpdate: (v) {
                final value = int.tryParse(v);
                if (value != null && value >= TranslationConfig.minBatchSpanCap && value <= TranslationConfig.maxBatchSpanCap) {
                  _updateConfig((c) => c.copyWith(novelBatchSpanCap: value));
                }
              }),
              SwitchListTile(
                title: Text(I18n.of(context).translation_novel_context),
                subtitle: Text(I18n.of(context).translation_novel_context_hint),
                value: cfg.useNovelContext,
                onChanged: (value) {
                  _updateConfig((c) => c.copyWith(useNovelContext: value));
                },
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  /// 一行内容类型：标题 + 翻译方式下拉
  Widget _engineSelector(
      BuildContext context, TranslateContentType type, String label) {
    final engine =
        _config.byType[type]?.engine ?? TranslateEngineOption.off;
    return ListTile(
      leading: const Icon(Icons.translate),
      title: Text(label),
      trailing: DropdownButton<TranslateEngineOption>(
        value: engine,
        onChanged: (value) {
          if (value == null) return;
          _updateConfig((c) => c.copyWith(byType: {
                ...c.byType,
                type: PerTypeTranslateConfig(engine: value),
              }));
        },
        items: [
          TranslateEngineOption.off,
          TranslateEngineOption.bing,
          TranslateEngineOption.openai,
        ].map((opt) => DropdownMenuItem(
              value: opt,
              child: Text(_engineLabel(opt)),
            )).toList(),
      ),
    );
  }

  String _engineLabel(TranslateEngineOption opt) {
    final i18n = I18n.of(context);
    switch (opt) {
      case TranslateEngineOption.off:
        return i18n.translation_engine_off;
      case TranslateEngineOption.bing:
        return i18n.translation_engine_bing;
      case TranslateEngineOption.openai:
        return i18n.translation_engine_openai;
    }
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
    required void Function(String) onUpdate,
  }) {
    return ListTile(
      title: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: onUpdate,
      ),
    );
  }
}
