/*
 * 机翻/AI 翻译设置页（Fluent 皮肤）。
 * 配置即改即存（单 JSON key 写入 SharedPreferences）。
 */

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/translation/translation_config.dart';

class TranslationSettingPage extends StatefulWidget {
  const TranslationSettingPage({super.key});

  @override
  State<TranslationSettingPage> createState() => _TranslationSettingPageState();
}

class _TranslationSettingPageState extends State<TranslationSettingPage> {
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
    _temperatureController = TextEditingController(
      text: cfg.openai.temperature.toStringAsFixed(2),
    );
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

  @override
  Widget build(BuildContext context) {
    final i18n = I18n.of(context);
    return ScaffoldPage.scrollable(
      header: PageHeader(title: Text(i18n.translation_settings)),
      // 整体订阅配置 observable：修改后立即回显（ComboBox/开关值）
      children: [
        Observer(
          builder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(FluentIcons.translate),
                title: Text(i18n.translation_master_switch),
                trailing: ToggleSwitch(
                  checked: _config.masterEnabled,
                  onChanged: (value) {
                    _updateConfig((c) => c.copyWith(masterEnabled: value));
                  },
                ),
              ),
              ListTile(
                leading: const Icon(FluentIcons.globe),
                title: Text(i18n.translation_target_lang),
                trailing: ComboBox<String>(
                  value: _config.targetLang,
                  items: const [
                    ComboBoxItem(child: Text('跟随界面语言'), value: 'auto'),
                    ComboBoxItem(child: Text('简体中文'), value: 'zh-CN'),
                    ComboBoxItem(child: Text('繁體中文'), value: 'zh-TW'),
                    ComboBoxItem(child: Text('English'), value: 'en-US'),
                    ComboBoxItem(child: Text('日本語'), value: 'ja'),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    _updateConfig((c) => c.copyWith(targetLang: value));
                  },
                ),
              ),
              _textField(
                _concurrencyController,
                i18n.translation_max_concurrency,
                onUpdate: (v) {
                  final value = int.tryParse(v);
                  if (value != null &&
                      value >= TranslationConfig.minConcurrency &&
                      value <= TranslationConfig.maxConcurrencyLimit) {
                    _updateConfig((c) => c.copyWith(maxConcurrency: value));
                  }
                },
              ),
              const Divider(),
              // 每种内容类型独立选择翻译方式
              _engineSelector(
                context,
                TranslateContentType.tag,
                i18n.translation_content_tag,
              ),
              _engineSelector(
                context,
                TranslateContentType.title,
                i18n.translation_content_title,
              ),
              _engineSelector(
                context,
                TranslateContentType.caption,
                i18n.translation_content_caption,
              ),
              _engineSelector(
                context,
                TranslateContentType.comment,
                i18n.translation_content_comment,
              ),
              _engineSelector(
                context,
                TranslateContentType.novelBody,
                i18n.translation_content_novel_body,
              ),
              _engineSelector(
                context,
                TranslateContentType.generic,
                i18n.translation_content_generic,
              ),
              // Bing 机翻暂时隐藏（微软免 Key 通道已不可用）
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'OpenAI Compatible',
                  style: FluentTheme.of(context).typography.subtitle,
                ),
              ),
              // OpenAI 兼容参数
              _textField(
                _baseUrlController,
                i18n.translation_openai_base_url,
                onUpdate: (v) {
                  _updateOpenAi((c) => c.baseUrl = v.trim());
                },
              ),
              _textField(
                _apiKeyController,
                i18n.translation_openai_api_key,
                onUpdate: (v) {
                  _updateOpenAi((c) => c.apiKey = v.trim());
                },
              ),
              _textField(
                _modelController,
                i18n.translation_openai_model,
                onUpdate: (v) {
                  _updateOpenAi((c) => c.model = v.trim());
                },
              ),
              _textField(
                _temperatureController,
                i18n.translation_openai_temperature,
                onUpdate: (v) {
                  final value = double.tryParse(v);
                  if (value != null && value >= 0 && value <= 2) {
                    _updateOpenAi((c) => c.temperature = value);
                  }
                },
              ),
              ListTile(
                leading: const Icon(FluentIcons.translate),
                title: Text(i18n.translation_thinking_mode),
                subtitle: Text(i18n.translation_thinking_hint),
                trailing: ToggleSwitch(
                  checked: _config.openai.thinkingMode,
                  onChanged: (value) {
                    _updateOpenAi((c) => c.thinkingMode = value);
                  },
                ),
              ),
              if (_config.openai.thinkingMode)
                ListTile(
                  leading: const Icon(FluentIcons.translate),
                  title: Text(i18n.translation_reasoning_effort),
                  trailing: ComboBox<String>(
                    value: _config.openai.reasoningEffort,
                    items: const [
                      ComboBoxItem(child: Text('low'), value: 'low'),
                      ComboBoxItem(child: Text('high'), value: 'high'),
                      ComboBoxItem(child: Text('max'), value: 'max'),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _updateOpenAi((c) => c.reasoningEffort = value);
                    },
                  ),
                ),
              _textField(
                _maxTokensController,
                i18n.translation_max_tokens,
                onUpdate: (v) {
                  final value = int.tryParse(v);
                  _updateOpenAi((c) =>
                      c.maxTokens = (value != null && value > 0) ? value : null);
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  i18n.translation_novel_batch_title,
                  style: FluentTheme.of(context).typography.subtitle,
                ),
              ),
              // 小说正文翻译：批容量（段落数为准，字符为兜底）与上下文提示
              _textField(
                _batchCharsController,
                i18n.translation_batch_chars,
                onUpdate: (v) {
                  final value = int.tryParse(v);
                  if (value != null &&
                      value >= TranslationConfig.minBatchChars &&
                      value <= TranslationConfig.maxBatchChars) {
                    _updateConfig((c) => c.copyWith(novelBatchChars: value));
                  }
                },
              ),
              _textField(
                _batchSpanCapController,
                i18n.translation_batch_span_cap,
                onUpdate: (v) {
                  final value = int.tryParse(v);
                  if (value != null &&
                      value >= TranslationConfig.minBatchSpanCap &&
                      value <= TranslationConfig.maxBatchSpanCap) {
                    _updateConfig((c) => c.copyWith(novelBatchSpanCap: value));
                  }
                },
              ),
              ListTile(
                leading: const Icon(FluentIcons.translate),
                title: Text(i18n.translation_novel_context),
                subtitle: Text(i18n.translation_novel_context_hint),
                trailing: ToggleSwitch(
                  checked: _config.useNovelContext,
                  onChanged: (value) {
                    _updateConfig((c) => c.copyWith(useNovelContext: value));
                  },
                ),
              ),
            ], // Column children 闭合
          ), // Column
        ), // Observer
      ], // 外层 children
    );
  }

  Widget _engineSelector(
    BuildContext context,
    TranslateContentType type,
    String label,
  ) {
    // 存量 Bing 配置归一为"关闭"显示（effectiveEngineFor 已把 bing 视为 off）
    final raw = _config.byType[type]?.engine ?? TranslateEngineOption.off;
    final engine = raw == TranslateEngineOption.bing
        ? TranslateEngineOption.off
        : raw;
    return ListTile(
      leading: const Icon(FluentIcons.translate),
      title: Text(label),
      // 外层 Observer 已订阅配置变更，这里直接渲染即可回显
      trailing: ComboBox<TranslateEngineOption>(
        value: engine,
        items: [
          for (final opt in [
            TranslateEngineOption.off,
            TranslateEngineOption.openai,
          ])
            ComboBoxItem(child: Text(_engineLabel(opt)), value: opt),
        ],
        onChanged: (value) {
          if (value == null) return;
          _updateConfig(
            (c) => c.copyWith(
              byType: {
                ...c.byType,
                type: PerTypeTranslateConfig(engine: value),
              },
            ),
          );
        },
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
    required void Function(String) onUpdate,
  }) {
    // fluent_ui 的 TextBox 无 header/hint 参数，label 显示在输入框上方
    return ListTile(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(label, style: FluentTheme.of(context).typography.body),
          ),
          TextBox(controller: controller, onChanged: onUpdate),
        ],
      ),
    );
  }
}
