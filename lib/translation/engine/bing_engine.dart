/*
 * Bing / Microsoft Translator 免 key 机翻引擎（无认证端点）。
 * 微软于 2026-07 移除了旧公共 token 端点(edge.microsoft.com/translate/auth)，
 * 现采用无认证 successor：POST edge.microsoft.com/translate/translatetext
 *   - query: from=<lang>&to=<lang>&isEnterpriseClient=false（from 为空串=自动检测）
 *   - body: 裸 JSON 字符串数组（旧 [{Text}] 请求体已被拒绝）
 *   - 响应: [{ "translations": [{ "text": "..." }] }]
 * 无 SLA，高峰可能限流(429)，实现内做退避与 60s 熔断。
 */

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pixez/translation/engine/engine_http.dart';
import 'package:pixez/translation/engine/translate_engine.dart';

class BingEngine implements TranslationEngine {
  @override
  String get id => 'bing';

  /// 惰性创建（含系统代理识别），首次请求前 await
  Future<Dio>? _dioFuture;

  Future<Dio> _engineDio() => _dioFuture ??= createEngineDio();

  static const String _translateUrl =
      'https://edge.microsoft.com/translate/translatetext';

  DateTime _failedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// UI 语言码 -> 微软翻译端点接受的代码
  static Map<String, String> _langMap = {
    'en-US': 'en',
    'en': 'en',
    'ja': 'ja',
    'zh-CN': 'zh-Hans',
    'zh-TW': 'zh-Hant',
    'ko': 'ko',
    'ru': 'ru',
    'es': 'es',
    'tr': 'tr',
    'id': 'id',
    'fil': 'fil',
    'de': 'de',
    'vi': 'vi',
  };

  String _microsoftLangOf(String uiLang) => _langMap[uiLang] ?? 'en';

  Future<List<String>> _doTranslate(
    List<String> texts,
    String target, {
    String? sourceLang,
  }) async {
    final dio = await _engineDio();
    final resp = await dio.post(
      _translateUrl,
      queryParameters: {
        'from': sourceLang == null || sourceLang.isEmpty ? '' : sourceLang,
        'to': target,
        'isEnterpriseClient': false,
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        },
        validateStatus: (status) =>
            (status != null && status >= 200 && status < 300) ||
            status == 429 ||
            status == 500 || // 风控/过载：交重试逻辑处理
            status == 401 ||
            status == 403,
      ),
      // 关键：body 是裸 JSON 字符串数组，不是 [{Text:...}] 旧格式
      data: jsonEncode(texts),
    );
    return _parseTranslateResponse(resp);
  }

  List<String> _parseTranslateResponse(Response resp) {
    dynamic data = resp.data;
    // 微软 Edge 翻译端点返回 Content-Type: text/plain; charset=utf-8，
    // Dio 不会自动反序列化为 List，此处补充解析容错
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (e) {
        throw FormatException('failed to decode translate response: $e');
      }
    }
    if (data is! List) {
      throw FormatException('unexpected translate response');
    }
    return data.map((item) {
      final translations = item is Map ? item['translations'] : null;
      if (translations is List && translations.isNotEmpty) {
        final first = translations.first;
        if (first is Map) return first['text']?.toString() ?? '';
      }
      return '';
    }).toList();
  }

  @override
  Future<List<String>> translateTexts(
    List<String> texts, {
    required String targetLang,
    String? sourceLang,
    String? contextText,
  }) async {
    // Bing 端点不支持上下文提示，忽略 contextText
    if (texts.isEmpty) return texts;
    final target = _microsoftLangOf(targetLang);
    // 熔断期内直接失败（回退原文），避免风暴
    if (DateTime.now().isBefore(_failedUntil)) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: _translateUrl),
        reason: 'bing cooldown',
      );
    }
    // 429/403/500 退避重试
    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15)
    ];
    Object? lastErr;
    for (var i = 0; i < delays.length; i++) {
      try {
        return await _doTranslate(texts, target, sourceLang: sourceLang);
      } on DioException catch (e) {
        lastErr = e;
        final status = e.response?.statusCode;
        if (status != 429 && status != 500 && status != 401 && status != 403) {
          // 其他错误（404/网络）不重试，直接熔断
          break;
        }
      } catch (e) {
        lastErr = e;
        break;
      }
      if (i < delays.length - 1) {
        await Future.delayed(delays[i]);
      }
    }
    // 全部失败：进入 60s 熔断，期间短路回退原文
    _failedUntil = DateTime.now().add(Duration(seconds: 60));
    throw lastErr ?? Exception('bing translate failed');
  }
}
