/*
 * 选区文本翻译弹窗（通用类型：generic）。
 * 展示原文 → 触发翻译 → 显示译文 → 可复制译文。
 */

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';

class TranslationDialog extends StatefulWidget {
  final String text;
  const TranslationDialog({super.key, required this.text});

  @override
  State<TranslationDialog> createState() => _TranslationDialogState();
}

class _TranslationDialogState extends State<TranslationDialog> {
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !TranslationService.instance.hasTranslationOf(
            widget.text,
            TranslateContentType.generic,
          )) {
        _translate();
      }
    });
  }

  Future<void> _translate() async {
    setState(() => _translating = true);
    final ok = await TranslationService.instance.translateText(
      widget.text,
      TranslateContentType.generic,
    );
    if (!mounted) return;
    setState(() => _translating = false);
    if (!ok) {
      final _reason = TranslationService.instance.describeLastError();
      BotToast.showText(text: I18n.of(context).translation_failed + _reason);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = TranslationService.instance;
    return AlertDialog(
      title: Text(I18n.of(context).translate),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.text, style: const TextStyle(fontSize: 14)),
              const Divider(),
              Observer(
                builder: (_) {
                  final translated = service.translatedOf(
                    widget.text,
                    TranslateContentType.generic,
                  );
                  if (_translating) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  if (translated == null) {
                    return Text(I18n.of(context).translate);
                  }
                  return SelectableText(
                    translated,
                    style: const TextStyle(fontSize: 14),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            final t = service.translatedOf(
              widget.text,
              TranslateContentType.generic,
            );
            if (t != null) {
              Clipboard.setData(ClipboardData(text: t));
              BotToast.showText(text: I18n.of(context).copied_to_clipboard);
            }
          },
          child: Text(I18n.of(context).copy),
        ),
        TextButton(
          onPressed: _translating ? null : _translate,
          child: Text(I18n.of(context).translate),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(I18n.of(context).cancel),
        ),
      ],
    );
  }
}
