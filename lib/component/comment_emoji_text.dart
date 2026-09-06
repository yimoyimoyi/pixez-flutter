import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/page/comment/comment_store.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';

/// 评论富文本：(emoji代码) 渲染为图片；可选开启机翻/AI 翻译切换
class CommentEmojiText extends StatefulWidget {
  final String text;

  /// 传入则启用"翻译/原文"切换（评论翻译配置），null 保持老行为
  final TranslateContentType? translateType;

  const CommentEmojiText({Key? key, required this.text, this.translateType})
    : super(key: key);

  @override
  _CommentEmojiTextState createState() => _CommentEmojiTextState();
}

class _CommentEmojiTextState extends State<CommentEmojiText> {
  bool _showTranslated = false;

  TranslationService get _service => TranslationService.instance;

  String get _displayText {
    if (widget.translateType == null || !_showTranslated) return widget.text;
    return _service.translatedOf(widget.text, widget.translateType!) ??
        widget.text;
  }

  Future<void> _toggleTranslate() async {
    setState(() {
      _showTranslated = !_showTranslated;
    });
    if (_showTranslated) {
      final ok = await _service.translateComment(widget.text);
      if (!ok && mounted) {
        setState(() {
          _showTranslated = false;
        });
        final _reason = TranslationService.instance.describeLastError();
        BotToast.showText(text: I18n.of(context).translation_failed + _reason);
      }
    }
  }

  bool get _pending =>
      _service.isPendingOf(widget.text, TranslateContentType.comment);

  @override
  Widget build(BuildContext context) {
    if (widget.translateType == null) {
      return Text.rich(
        TextSpan(
          style: Theme.of(context).textTheme.bodyMedium,
          children: buildCommentSpans(_displayText, context),
        ),
      );
    }
    final enabled = _service.isTypeEnabled(widget.translateType!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (enabled)
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              height: 24,
              child: Observer(
                builder: (_) => TextButton(
                  onPressed: _toggleTranslate,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 24),
                  ),
                  child: Text(
                    _pending
                        ? '...'
                        : (_showTranslated
                              ? I18n.of(context).translation_show_original
                              : I18n.of(context).translate),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        Observer(
          builder: (_) => Text.rich(
            TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: buildCommentSpans(_displayText, context),
            ),
          ),
        ),
      ],
    );
  }

  /// 解析 (emoji代码) 为 WidgetSpan/TextSpan（译文经过保护恢复，token 原样）
  static List<InlineSpan> buildCommentSpans(String text, BuildContext context) {
    List<InlineSpan> spans = [];
    String template = "";
    String emojiText = "";
    bool emojiCollecting = false;
    for (var element in text.characters) {
      if (element == '(') {
        if (template.isNotEmpty) {
          spans.add(TextSpan(text: template));
          template = "";
        }
        emojiCollecting = true;
      } else if (element == ')') {
        if (emojiText.isNotEmpty) {
          final key = "($emojiText)";
          if (emojisMap.containsKey(key)) {
            spans.add(
              WidgetSpan(
                child: Image.asset(
                  'assets/emojis/${emojisMap[key]}',
                  width: 20,
                  height: 20,
                ),
              ),
            );
          } else {
            spans.add(TextSpan(text: "($emojiText)"));
            template = "";
          }
        }
        emojiCollecting = false;
        emojiText = "";
      } else {
        if (emojiCollecting)
          emojiText += element;
        else
          template += element;
      }
    }
    if (template.isNotEmpty) {
      spans.add(TextSpan(text: template));
    }
    return spans;
  }
}
