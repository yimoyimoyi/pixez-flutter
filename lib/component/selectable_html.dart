/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:pixez/component/picker/utils.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/supportor_plugin.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

class SelectableHtml extends StatefulWidget {
  final String data;

  /// 传入则启用"翻译/原文"切换（机翻 AI 翻译），null 保持老行为
  final TranslateContentType? translateType;
  final String? translateId;

  const SelectableHtml({
    Key? key,
    required this.data,
    this.translateType,
    this.translateId,
  }) : super(key: key);

  @override
  _SelectableHtmlState createState() => _SelectableHtmlState();
}

class _SelectableHtmlState extends State<SelectableHtml> {
  bool _showTranslated = false;

  @override
  void initState() {
    super.initState();
    initMethod();
  }

  @override
  Widget build(BuildContext context) {
    final content = Container(
      child: HtmlWidget(
        _displayData(),
        customStylesBuilder: (e) {
          if (e.attributes.containsKey('href')) {
            final color = Theme.of(context).colorScheme.primary;
            return {
              'color': color.toHexString(
                includeHashSign: true,
                enableAlpha: false,
              ),
            };
          }
          return null;
        },
        onTapUrl: (String url) async {
          try {
            LPrinter.d("html tap url: $url");
            bool result = await Leader.pushWithUri(context, Uri.parse(url));
            if (!result) {
              await launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalNonBrowserApplication,
              );
            }
          } catch (e) {
            SharePlus.instance.share(ShareParams(text: url));
          }
          return true;
        },
      ),
    );
    if (!_translationEnabled()) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Observer(builder: (_) => _buildToggle()),
        content,
      ],
    );
  }

  bool _translationEnabled() =>
      widget.translateType != null && widget.translateId != null;

  /// 显示内容：译文(全节点翻译完成) / 原文，Observer 追踪译文就绪后自动重建
  String _displayData() {
    if (!_translationEnabled() || !_showTranslated) return widget.data;
    return TranslationService.instance.translatedCaptionHtml(
          widget.data,
          widget.translateType!,
        ) ??
        widget.data;
  }

  Widget _buildToggle() {
    final service = TranslationService.instance;
    if (!service.isTypeEnabled(widget.translateType!)) {
      // 该内容类型未开启翻译：不显示按钮
      return const SizedBox.shrink();
    }
    final pending = service.isPendingCaption(
      widget.data,
      widget.translateType!,
    );
    return SizedBox(
      height: 32,
      child: TextButton.icon(
        icon: _showTranslated || pending
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.translate, size: 16),
        label: Text(
          _showTranslated
              ? I18n.of(context).translation_show_original
              : I18n.of(context).translate,
          style: const TextStyle(fontSize: 13),
        ),
        onPressed: () async {
          setState(() {
            _showTranslated = !_showTranslated;
          });
          if (_showTranslated) {
            final ok = await service.translateCaption(
              widget.data,
              widget.translateType!,
            );
            if (!ok && mounted) {
              final _reason = TranslationService.instance.describeLastError();
              BotToast.showText(
                text: I18n.of(context).translation_failed + _reason,
              );
            }
          }
        },
      ),
    );
  }

  bool supportTranslate = false;

  Future<void> initMethod() async {
    if (!Platform.isAndroid) return;
    bool results = await SupportorPlugin.processText();
    setState(() {
      supportTranslate = results;
    });
  }
}
