/*
 * 翻译引擎抽象：所有引擎实现同一接口，按内容类型路由。
 * 约定：调用方传入的是"纯文本段"（HTML/emoji 等 token 必须在调用前剥离），
 * 引擎返回与输入等长、等序的结果列表。
 */

import 'package:crypto/crypto.dart';
import 'dart:convert';

abstract class TranslationEngine {
  String get id;

  /// 批量翻译；texts 非空且均已剥离 token。
  /// targetLang 为规范化 UI 语言码（如 'zh-CN'），引擎内部自行映射。
  /// [contextText] 为可选上下文段提示（如小说的前文原文），仅支持该参数的
  /// 引擎（OpenAI 类）拼入提示词提升连贯性；不支持者（Bing）忽略之。
  Future<List<String>> translateTexts(
    List<String> texts, {
    required String targetLang,
    String? sourceLang,
    String? contextText,
  });
}

/// 文本过长时按句子边界分段（无重叠），恢复时按序拼接。
class TranslationSplitter {
  static const int maxCharsPerSegment = 900;

  /// 返回原文的各段；若整体不超长则原样返回（单元素）。
  static List<String> split(String text) {
    if (text.length <= maxCharsPerSegment) return [text];
    final segments = <String>[];
    var last = 0;
    // 优先在句末标点/换行断开
    for (final m in RegExp(r'[。！？!?；;\n]').allMatches(text)) {
      segments.add(text.substring(last, m.end));
      last = m.end;
      if (text.length - last <= maxCharsPerSegment) break;
    }
    if (last < text.length) {
      // 尾部剩余（可能无标点），再按上限硬切
      segments.addAll(_splitHard(text.substring(last)));
    }
    return segments;
  }

  /// 无论标点按上限硬切
  static List<String> _splitHard(String segment) {
    if (segment.length <= maxCharsPerSegment) return [segment];
    final result = <String>[];
    for (var i = 0; i < segment.length; i += maxCharsPerSegment) {
      final end =
          i + maxCharsPerSegment > segment.length ? segment.length : i + maxCharsPerSegment;
      result.add(segment.substring(i, end));
    }
    return result;
  }
}

/// 生成翻译缓存 key（含引擎+目标语言+原文 hash），不含内容类型，跨类型共享缓存。
/// key 版本：v2 起新增"译文==原文视为失败不写缓存"校验；v1 旧缓存（含被错误
/// 结果污染的条目）在 provider 打开时清理，作废以防继续命中。
String translationCacheKey(String rawText, {required String engine, required String targetLang}) {
  final digest = sha1.convert(utf8.encode(rawText)).toString();
  return 'v2|$engine|$targetLang|${digest.substring(0, 16)}';
}
