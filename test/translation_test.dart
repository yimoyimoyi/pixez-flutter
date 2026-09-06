import 'package:flutter_test/flutter_test.dart';
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
      // Bing 免费通道生效
      expect(cfg.effectiveEngineFor(TranslateContentType.title),
          TranslateEngineOption.bing);
      // 配置 baseUrl 后生效
      final cfg2 = cfg.copyWith(
          openai: OpenAiEngineConfig(baseUrl: 'http://127.0.0.1:11434'));
      expect(cfg2.effectiveEngineFor(TranslateContentType.tag),
          TranslateEngineOption.openai);
      // 总开关关闭时全部 off
      expect(cfg2.copyWith(masterEnabled: false).effectiveEngineFor(
          TranslateContentType.tag), TranslateEngineOption.off);
      expect(cfg2.copyWith(masterEnabled: false).effectiveEngineFor(
          TranslateContentType.title), TranslateEngineOption.off);
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
      expect(parts.length, 2);
      // 按序拼回与原文本一致
      expect(parts.join(), text);
      // 每段不超过上限
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(900));
      }
    });

    test('无标点超长文本硬切', () {
      final text = 'a' * 2500;
      final parts = TranslationSplitter.split(text);
      expect(parts.length, 3);
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

    test('DeepSeek 端点思考参数规范（thinking 与顶级 reasoning_effort）', () {
      final deepseek = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(baseUrl: 'https://api.deepseek.com/v1'),
        texts: ['テスト'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate',
      );
      expect(deepseek['thinking'], {'type': 'disabled'});
      expect(deepseek.containsKey('reasoning_effort'), false);

      final deepseekThinking = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(
          baseUrl: 'https://api.deepseek.com/v1',
          thinkingMode: true,
          reasoningEffort: 'low',
        ),
        texts: ['テスト'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate',
      );
      expect(deepseekThinking['thinking'], {'type': 'enabled'});
      expect(deepseekThinking['reasoning_effort'], 'low');

      final other = OpenAiEngine.buildCompletionsBody(
        config: OpenAiEngineConfig(baseUrl: 'https://api.example.com/v1'),
        texts: ['テスト'],
        targetLang: 'zh-CN',
        systemPrompt: 'translate',
      );
      expect(other.containsKey('thinking'), false);
      expect(other.containsKey('reasoning_effort'), false);
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
            TranslateContentType.comment:
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

    test('评论带首尾空白与换行时 key 一致', () async {
      final service = TranslationService.instance;
      const commentRaw = '\n  素敵な作品ですね！  \n';
      final key = service.keyOfText(commentRaw, TranslateContentType.comment);
      expect(key, translationCacheKey('素敵な作品ですね！', engine: 'openai', targetLang: 'zh-CN'));
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

  group('RichText and Multi-paragraph', () {
    test('纯符号装饰行与纯数字不被误提取为翻译节点', () {
      final raw = '◆◇◆◇<br />初めまして！<br />----------------<br />123456<br />よろしくお願いします！';
      final texts = HtmlTextExtractor.extractTexts(raw);
      expect(texts, ['初めまして！', 'よろしくお願いします！']);
    });

    test('恢复富文本时保留首尾空白与缩进排版', () {
      final raw = '　段落一<br />  段落二';
      final restored = HtmlTextExtractor.restore(raw, ['译文一', '译文二']);
      expect(restored, '　译文一<br>  译文二');
    });

    test('HTML 特殊字符在 Text 节点中被安全转义', () {
      final raw = '<b>テスト</b>';
      final restored = HtmlTextExtractor.restore(raw, ['1 < 2 & 3 > 0']);
      expect(restored, '<b>1 &lt; 2 &amp; 3 &gt; 0</b>');
    });

    test('多段富文本中部分节点缺失时平滑降级保留该节点原文', () {
      final service = TranslationService.instance;
      // 准备缓存：只给"段落一"写入译文，"段落二"缺失
      final key1 = service.keyOfText('段落一', TranslateContentType.caption);
      if (key1 != null) {
        service.caches.store.setResult(key1, 'Paragraph 1');
      }
      final html = '段落一<br />段落二';
      final result = service.translatedCaptionHtml(html, TranslateContentType.caption);
      expect(result, isNotNull);
      expect(result, contains('Paragraph 1'));
      expect(result, contains('段落二'));
    });

    test('作品 137177813 简介多段与链接混合结构的提取与平滑恢复', () {
      const caption =
          '&quot;owls have the ability to rotate their heads 270 degrees&quot;<br /><br />'
          'so you mean to tell me mumei can just do this? 👀<br /><br />'
          '(idk what tag to put here pertaining to the head twist lmao)<br /><br />'
          'discord server <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Fdiscord" target="_blank">https://nanotouko.github.io/discord</a><br />'
          'pixiv <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Fpixiv" target="_blank">https://nanotouko.github.io/pixiv</a><br />'
          'twitter/x <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Ftwitter" target="_blank">https://nanotouko.github.io/twitter</a><br />'
          'bluesky <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Fbsky" target="_blank">https://nanotouko.github.io/bsky</a><br />'
          'deviantart <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Fdeviantart" target="_blank">https://nanotouko.github.io/deviantart</a><br />'
          'commissions <a href="/jump.php?https%3A%2F%2Fnanotouko.github.io%2Fcommissions" target="_blank">https://nanotouko.github.io/commissions</a>';

      final texts = HtmlTextExtractor.extractTexts(caption);
      // 9 个文本节点被提取（链接中的纯 URL 被自动忽略，不送机翻）
      expect(texts.length, 9);
      expect(texts[0], '"owls have the ability to rotate their heads 270 degrees"');
      expect(texts[3], 'discord server ');
      expect(texts[8], 'commissions ');

      // 模拟只翻译了前两段，后面部分暂时未翻译（平滑降级）
      final service = TranslationService.instance;
      final key0 = service.keyOfText(texts[0], TranslateContentType.caption);
      if (key0 != null) {
        service.caches.store.setResult(key0, '“猫头鹰能旋转头部270度”');
      }
      final result = service.translatedCaptionHtml(caption, TranslateContentType.caption);
      expect(result, isNotNull);
      expect(result, contains('“猫头鹰能旋转头部270度”'));
      expect(result, contains('https://nanotouko.github.io/discord'));
      expect(result, contains('commissions'));
    });

    test('TranslationQueue 并发在途等待防重', () async {
      final queue = TranslationQueue.instance;
      final caches = TranslationCacheStores(
        disk: _NoopDisk(),
        memory: TranslationMemoryCache(),
        store: TranslationStore(),
      );

      var engineCallCount = 0;
      final fakeEngine = _FakeDelayedEngine(
        onTranslate: (texts) async {
          engineCallCount++;
          await Future.delayed(const Duration(milliseconds: 50));
          return texts.map((t) => 'trans_$t').toList();
        },
      );

      final item = MapEntry('k1', 'text1');
      // 同时发起两个并发 enqueue
      final f1 = queue.enqueue(fakeEngine, caches,
          items: [item], targetLang: 'zh-CN');
      final f2 = queue.enqueue(fakeEngine, caches,
          items: [item], targetLang: 'zh-CN');

      await Future.wait([f1, f2]);
      // 只有一个真正调用了底层引擎，第二个等待其完成
      expect(engineCallCount, 1);
      expect(caches.store.resultOf('k1'), 'trans_text1');
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

class _FakeDelayedEngine implements TranslationEngine {
  final Future<List<String>> Function(List<String> texts) onTranslate;

  _FakeDelayedEngine({required this.onTranslate});

  @override
  String get id => 'fake';

  @override
  Future<List<String>> translateTexts(
    List<String> texts, {
    required String targetLang,
    String? sourceLang,
    String? contextText,
  }) => onTranslate(texts);
}
