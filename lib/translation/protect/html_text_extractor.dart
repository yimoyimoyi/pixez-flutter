/*
 * caption/简介 HTML 专用：解析 HTML DOM，仅翻译其中的文本节点（Text node），
 * 遍历结束后把译文写回原节点，标签/属性（<br>、<a href>、图片等）保持不动。
 * 使用本工具后，调用方传入引擎的全是纯文本，不存在 HTML 被机翻破坏的问题。
 *
 * 说明：html_parser.parse 会生成完整文档外壳(<html><body>)，恢复时只取
 * body 的子节点序列列表，保证输出与输入结构一致。
 */

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class HtmlTextExtractor {
  /// 纯 URL / 空白链接占位：不送翻译（模型只会原样返回或改写 URL）
  static final RegExp _urlOnlyRegex = RegExp(r'^https?://\S+$');

  /// 至少包含一个文字字符（Unicode Letter，含汉字、假名、字母等）。
  /// 纯标点、符号（如 ◆◇---===）、纯数字等装饰行不送翻译，避免模型破坏或误判失败。
  static final RegExp _hasLetterRegex = RegExp(r'[\p{L}]', unicode: true);

  /// 判断文本节点是否值得翻译（非空、非纯 URL、含有有效文字）
  static bool isTranslatableTextNode(String data) {
    final text = data.trim();
    if (text.isEmpty) return false;
    if (_urlOnlyRegex.hasMatch(text)) return false;
    if (!_hasLetterRegex.hasMatch(text)) return false;
    return true;
  }

  /// 提取 HTML 中所有可翻译文本节点内容（保持顺序）
  static List<String> extractTexts(String html) {
    final doc = html_parser.parse(html);
    final results = <String>[];
    for (final node in _walk(doc.body?.nodes ?? const [])) {
      if (node is Text && isTranslatableTextNode(node.data)) {
        results.add(node.data);
      }
    }
    return results;
  }

  /// 将翻译结果按序写回文本节点，返回译后 HTML 字符串
  static String restore(String html, List<String> translated) {
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return html;
    var index = 0;
    for (final node in _walk(body.nodes)) {
      if (node is Text && isTranslatableTextNode(node.data)) {
        if (index < translated.length) {
          final original = node.data;
          final trans = translated[index];
          // 保留原节点首尾的空格/换行/段首缩进排版
          final leading = RegExp(r'^\s*').firstMatch(original)?.group(0) ?? '';
          final trailing = RegExp(r'\s*$').firstMatch(original)?.group(0) ?? '';
          node.data = '$leading$trans$trailing';
          index++;
        }
      }
    }
    return body.nodes.map(_serialize).join();
  }

  /// Element/Text 直接序列化（html 包中只有 Element 有 outerHtml）
  static String _serialize(Node node) {
    if (node is Text) return _escapeHtml(node.data);
    if (node is Element) return node.outerHtml;
    return node.text ?? '';
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static Iterable<Node> _walk(List<Node> nodes) sync* {
    for (final node in nodes) {
      yield node;
      if (node is Element) {
        yield* _walk(node.nodes);
      }
    }
  }
}
