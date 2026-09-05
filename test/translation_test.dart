/*
 * 机翻功能纯逻辑测试：配置序列化、文本分段、HTML 结构保持、token 保护。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/main.dart';
import 'package:pixez/translation/engine/openai_engine.dart';
import 'package:pixez/translation/engine/translate_engine.dart';
import 'package:pixez/translation/translation_cache.dart';
import 'package:pixez/translation/translation_queue.dart';
import 'package:pixez/translation/translation_service.dart';
import 'package:pixez/translation/translation_store.dart';
import 'package:pixez/translation/protect/html_text_extractor.dart';
import 'package:pixez/translation/protect/seq_protector.dart';
import 'package:pixez/translation/translation_config.dart';

void main() {
  group('TranslationConfig', () {
    test('默认配置与序列化往返', () {
      final cfg = TranslationConfig();
      expect(cfg.masterEnabled, true);
      expect(cfg.targetLang, 'auto');
      expect(cfg.effectiveEngineFor(TranslateContentType.tag),
          TranslateEngineOption.off);

      final decoded = TranslationConfig.decode(cfg.encode());
      expect(decoded.masterEnabled, cfg.masterEnabled);
      expect(decoded.targetLang, cfg.targetLang);
      expect(decoded.effectiveEngineFor(TranslateContentType.tag),
          TranslateEngineOption.off);
    });

    test('损坏 JSON 容错回默认', () {
      final cfg = TranslationConfig.decode('not a json');
      expect(cfg.masterEnabled, true);
      final empty = TranslationConfig.decode('');
      expect(empty.masterEnabled, true);
    });

    test('按类型独立配置与 OpenAI 未配置短路', () {
      final cfg = TranslationConfig().copyWith(byType: {
        TranslateContentType.tag:
            PerTypeTranslateConfig(engine: TranslateEngineOption.openai),
        TranslateContentType.title:
            PerTypeTranslateConfig(engine: TranslateEngineOption.bing),
      });
      // OpenAI 未配置 baseUrl 时视为关闭
      expect(cfg.effectiveEngineFor(TranslateContentType.tag),
          TranslateEngineOption.off);
      // Bing 免费通道已不可用，暂时隐藏并视为关闭
      expect(cfg.effectiveEngineFor(TranslateContentType.title),
          TranslateEngineOption.off);
      // 配置 baseUrl 后生效
      final cfg2 = cfg.copyWith(
          openai: OpenAiEngineConfig(baseUrl: 'http://127.0.0.1:11434'));
      expect(cfg2.effectiveEngineFor(TranslateContentType.tag),
          TranslateEngineOption.openai);
      // 总开关关闭时全部 off
      expect(cfg2.copyWith(masterEnabled: false).effectiveEngineFor(
          TranslateContentType.tag), TranslateEngineOption.off);
    });
  });

  group('TranslationSplitter', () {
    test('短文本原样返回', () {
      expect(TranslationSplitter.split('短文本'), ['短文本']);
    });

    test('长文本按句点分段', () {
      final text = ('これはテストです。' * 150);
      expect(text.length, greaterThan(900));
      final parts = TranslationSplitter.split(text);
      expect(parts.length, greaterThan(1));
      // 按序拼回与原文本一致
      expect(parts.join(), text);
      // 每段不超过上限+句点
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(900 + 1));
      }
    });

    test('无标点超长文本硬切', () {
      final text = 'a' * 2500;
      final parts = TranslationSplitter.split(text);
      expect(parts.length, greaterThan(1));
      expect(parts.join(), text);
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(900));
      }
    });
  });

  group('HtmlTextExtractor', () {
    test('提取文本节点、恢复结构', () {
      const html = '<br>ありがとうございます<br><a href="https://example.com">詳細</a>';
      final texts = HtmlTextExtractor.extractTexts(html);
      expect(texts, ['ありがとうございます', '詳細']);

      final restored =
          HtmlTextExtractor.restore(html, ['谢谢观看', '详情']);
      // 文本被替换、标签/链接保留（html/parser 会规范化引号等，不比较全等）
      expect(restored, contains('谢谢观看'));
      expect(restored, contains('详情'));
      expect(restored, contains('https://example.com'));
      expect(restored, contains('<a'));
      expect(restored, contains('</a>'));
      expect(restored, contains('<br>'));
    });

    test('空 HTML 安全', () {
      expect(HtmlTextExtractor.extractTexts(''), isEmpty);
      expect(HtmlTextExtractor.restore('', []), '');
    });
  });

  group('OpenAiEngine', () {
    test('chat completions URL 拼接规则', () {
      expect(OpenAiEngine.buildChatCompletionsUrl('https://api.deepseek.com/v1'),
          'https://api.deepseek.com/v1/chat/completions');
      expect(OpenAiEngine.buildChatCompletionsUrl('https://api.deepseek.com'),
          'https://api.deepseek.com/v1/chat/completions');
      expect(
          OpenAiEngine.buildChatCompletionsUrl(
              'https://api.deepseek.com/chat/completions'),
          'https://api.deepseek.com/chat/completions');
    });

    test('DeepSeek 端点关闭思考模式，其它端点不传 thinking', () {
      final deepseek = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(baseUrl: 'https://api.deepseek.com/v1'),
        texts: ['テスト'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate',
      );
      expect(deepseek['thinking'], {'type': 'disabled'});

      final other = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(baseUrl: 'https://api.example.com/v1'),
        texts: ['テスト'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate',
      );
      expect(other.containsKey('thinking'), false);
    });

    test('messages 包含完整翻译指令与文本数组', () {
      final body = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(baseUrl: 'https://api.deepseek.com/v1'),
        texts: ['こんにちは', 'おはよう'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate to zh-CN',
      );
      final messages = body['messages'] as List;
      expect(messages.length, 2);
      expect((messages[1] as Map)['content'], contains('こんにちは'));
      expect(body['model'], 'deepseek-v4-flash');
    });
  });

  group('TranslationService key 一致性', () {
    setUp(() {
      TranslationService.init(
        configProvider: () => TranslationConfig().copyWith(
          masterEnabled: true,
          byType: {
            TranslateContentType.caption:
                PerTypeTranslateConfig(engine: TranslateEngineOption.openai),
          },
          openai: OpenAiEngineConfig(baseUrl: 'http://127.0.0.1:11434'),
        ),
        uiLanguageProvider: () => 'zh-CN',
        caches: TranslationCacheStores(
          disk: _NoopDisk(),
          memory: TranslationMemoryCache(),
          store: TranslationStore(),
        ),
      );
    });

    test('keyOfText 与入队 key 一致（trim 统一）', () async {
      final service = TranslationService.instance;
      // 带首尾空格的节点文本（富文本常见，如 <br> 前空格）
      const raw = 'Bare soles here! ';
      final serviceKey = service.keyOfText(raw, TranslateContentType.caption);
      expect(serviceKey, isNotNull);
      final manualKey = translationCacheKey(raw.trim(),
          engine: 'openai', targetLang: 'zh-CN');
      expect(serviceKey, manualKey, reason: 'key 必须基于 trim 文本');
    });
  });

  group('SeqProtector', () {
    test('emoji token 保护与恢复', () {
      final raw = '太好了(heart)呀(star1)';
      final re = RegExp(r'\([A-Za-z0-9_]+\)');
      final texts = SeqProtector.extractTexts(raw, re);
      expect(texts, ['太好了', '呀']);
      final restored = SeqProtector.restore(raw, re, ['太好了', '哎']);
      expect(restored, contains('(heart)'));
      expect(restored, contains('(star1)'));
      expect(restored, '太好了(heart)哎(star1)');
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
