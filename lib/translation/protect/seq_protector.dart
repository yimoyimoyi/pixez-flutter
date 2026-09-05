/*
 * 通用"原文 + 受保护 token 混排"翻译工具：
 * 将原文按 token 正则切分为 [文本段|token] 序列，只翻译文本段，按序回填。
 * 保证 token（如评论中的 (emoji) 代码、小说 [pixivimage:] 语法）100% 原样保留，
 * 无论机翻还是 AI 都不会改动它们。
 */

class SeqProtector {
  /// 切分：返回所有需要翻译的纯文本段（空段/纯空白跳过）
  static List<String> extractTexts(String raw, RegExp tokenRegex) {
    return _parts(raw, tokenRegex)
        .where((p) => p.isText && p.text.trim().isNotEmpty)
        .map((p) => p.text)
        .toList();
  }

  /// 把翻译后的文本段按序回填进原字符串
  static String restore(String raw, RegExp tokenRegex, List<String> translated) {
    var index = 0;
    return _parts(raw, tokenRegex).map((p) {
      if (p.isText) {
        if (p.text.trim().isEmpty) return p.text;
        final result = (index < translated.length) ? translated[index] : p.text;
        index++;
        return result;
      }
      return p.raw;
    }).join();
  }

  static List<_Part> _parts(String raw, RegExp tokenRegex) {
    final parts = <_Part>[];
    var last = 0;
    for (final m in tokenRegex.allMatches(raw)) {
      if (m.start > last) parts.add(_Part.text(raw.substring(last, m.start)));
      parts.add(_Part.token(m.group(0)!));
      last = m.end;
    }
    if (last < raw.length) parts.add(_Part.text(raw.substring(last)));
    return parts;
  }
}

class _Part {
  final bool isText;
  final String raw;
  final String text;
  _Part._(this.isText, this.raw, this.text);
  factory _Part.text(String t) => _Part._(true, t, t);
  factory _Part.token(String t) => _Part._(false, t, t);
}
