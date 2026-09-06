/*
 * OpenAI 兼容格式 AI 翻译引擎。
 * POST {baseUrl}/v1/chat/completions 即可通吃官方 / Azure / 中转 / Ollama / DeepSeek 等。
 * 通过"整批 JSON 数组 + 系统提示"一次请求翻译多条文本，保持等长等序。
 */

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pixez/translation/engine/engine_http.dart';
import 'package:pixez/translation/engine/translate_engine.dart';
import 'package:pixez/translation/translation_config.dart';

class OpenAiEngine implements TranslationEngine {
  @override
  String get id => 'openai';

  final OpenAiEngineConfig config;
  OpenAiEngine(this.config);

  /// 目标语言的友好自然名（语言一致性提示用；未知码原样返回）
  static String _targetLangName(String lang) {
    switch (lang) {
      case 'zh-CN':
        return 'Simplified Chinese (简体中文)';
      case 'zh-TW':
        return 'Traditional Chinese (繁體中文)';
      case 'ja':
        return 'Japanese (日本語)';
      case 'ko':
        return 'Korean (한국어)';
      case 'en-US':
      case 'en':
        return 'English';
      default:
        return lang;
    }
  }

  /// user 提供的 baseUrl 可能以 /v1 结尾、到 /chat/completions、或裸域名，统一拼出完整端点
  static String buildChatCompletionsUrl(String baseUrl) {
    var url = baseUrl.trim();
    if (url.endsWith('/chat/completions')) return url;
    if (url.endsWith('/v1')) return '$url/chat/completions';
    return '$url/v1/chat/completions';
  }

  /// 组装请求体（可独立测试）：
  /// DeepSeek V4 默认开启思考模式（thinking.type=enabled）。
  /// 翻译场景默认关闭以提速降耗；用户可在设置开启思考并用 reasoningEffort 限制深度，
  /// maxTokens 限制输出长度控费。其它 OpenAI 兼容端点不传 thinking 字段（避免参数校验拒绝）。
  static Map<String, dynamic> buildCompletionsBody({
    required OpenAiEngineConfig config,
    required List<String> texts,
    required String targetLang,
    required String systemPrompt,
  }) {
    final body = <String, dynamic>{
      'model': config.model,
      'temperature': config.temperature,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': jsonEncode(texts)},
      ],
    };
    if (config.maxTokens != null && config.maxTokens! > 0) {
      body['max_tokens'] = config.maxTokens;
    }
    if (config.isDeepSeek) {
      body['thinking'] = {
        'type': config.thinkingMode ? 'enabled' : 'disabled',
      };
      if (config.thinkingMode) {
        body['reasoning_effort'] = config.reasoningEffort;
      }
    }
    return body;
  }

  @override
  Future<List<String>> translateTexts(
    List<String> texts, {
    required String targetLang,
    String? sourceLang,
    String? contextText,
  }) async {
    if (texts.isEmpty || !config.isConfigured) return texts;
    final dio = await createEngineDio(
      receiveTimeout: Duration(seconds: config.timeoutSeconds),
    );
    final headers = {'Content-Type': 'application/json'};
    if (config.apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey.trim()}';
    }
    final systemPrompt =
        'You are a translation engine. Translate the JSON array of strings given by the user '
        'into ${_targetLangName(targetLang)}. '
        'Strict requirements:\n'
        '1. Every translation must be written in ${_targetLangName(targetLang)} only. '
        'Never mix in the source language, English, or explanatory text.\n'
        '2. Translate the meaning faithfully; keep numbers, punctuation, emoji, '
        'proper nouns and formatting tokens like [P0] as-is.\n'
        '3. Return a JSON array with the same length and the same order as the input. '
        'Output ONLY the JSON array, nothing else.';
    final contextPrompt = contextText == null || contextText.isEmpty
        ? ''
        : '\nThe following is the preceding text (context, DO NOT translate it):\n'
            '${contextText.length > 1200 ? contextText.substring(0, 1200) : contextText}\n';
    final resp = await dio.post(
      buildChatCompletionsUrl(config.baseUrl),
      options: Options(headers: headers),
      data: buildCompletionsBody(
        config: config,
        texts: texts,
        targetLang: targetLang,
        systemPrompt: systemPrompt + contextPrompt,
      ),
    );

    final content = _extractContent(resp.data);
    if (content.isEmpty) {
      throw FormatException('empty completion');
    }
    // 剥离思维链、围栏或外围文字后解析
    final parsed = _parseJsonArray(content);
    if (parsed == null || parsed.length != texts.length) {
      throw FormatException(
          'bad completion array: got ${parsed?.length} expected ${texts.length}');
    }
    return parsed;
  }

  /// 鲁棒提取与解析 JSON 字符串数组（容错思维链、Markdown 围栏与前言/后记）
  List<String>? _parseJsonArray(String rawContent) {
    // 1. 直接尝试解析
    var parsed = _tryParseList(rawContent);
    if (parsed != null) return parsed;

    // 2. 剥离 <think>...</think> 标签内容
    var text = rawContent
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
        .trim();
    parsed = _tryParseList(text);
    if (parsed != null) return parsed;

    // 3. 剥离 ```json ... ``` 围栏
    final fenceMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', caseSensitive: false)
        .firstMatch(text);
    if (fenceMatch != null) {
      final insideFence = fenceMatch.group(1)!.trim();
      parsed = _tryParseList(insideFence);
      if (parsed != null) return parsed;
    }

    // 4. 提取最外层 [ ... ]
    final arrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(text);
    if (arrayMatch != null) {
      parsed = _tryParseList(arrayMatch.group(0)!);
      if (parsed != null) return parsed;
    }

    return null;
  }

  /// content 可能是嵌套字符串或对象结构，做多层提取
  String _extractContent(dynamic data) {
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return data;
      }
    }
    if (data is Map) {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final message = (choices.first as Map)['message'];
        if (message is Map) {
          final content = message['content'];
          if (content != null) return content.toString();
        }
      }
    }
    return data is String ? data : '';
  }

  List<String>? _tryParseList(String content) {
    try {
      final value = jsonDecode(content);
      if (value is List) {
        return value.map((e) => e?.toString() ?? '').toList();
      }
    } catch (_) {}
    return null;
  }
}
