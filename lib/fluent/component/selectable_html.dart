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

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
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
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    initMethod();
  }

  @override
  Widget build(BuildContext context) {
    if (!_translationEnabled()) return _buildContent(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Observer(builder: (_) => _buildToggle()),
        Observer(builder: (_) => _buildContent(context)),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    return Container(
      child: HtmlWidget(
        _displayData(),
        customStylesBuilder: (e) {
          if (e.attributes.containsKey('href')) {
            final color = FluentTheme.of(context).accentColor;
            return {
              'color': '#${color.colorValue.toRadixString(16).substring(2, 8)}',
            };
          }
          return null;
        },
        onTapUrl: (String url) async {
          try {
            LPrinter.d("html tap url: $url");
            if (url.startsWith("pixiv")) {
              Leader.pushWithUri(context, Uri.parse(url));
            } else
              await launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalNonBrowserApplication,
              );
          } catch (e) {
            SharePlus.instance.share(ShareParams(text: url));
          }
          return true;
        },
      ),
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
    final isPending = _pending ||
        service.isPendingCaption(
          widget.data,
          widget.translateType!,
        );
    return Align(
      alignment: Alignment.centerLeft,
      child: HyperlinkButton(
        onPressed: () async {
          if (_pending) return;
          setState(() {
            _showTranslated = !_showTranslated;
          });
          if (_showTranslated) {
            setState(() {
              _pending = true;
            });
            final ok = await service.translateCaption(
              widget.data,
              widget.translateType!,
            );
            if (mounted) {
              setState(() {
                _pending = false;
              });
              if (!ok) {
                setState(() {
                  _showTranslated = false;
                });
                displayInfoBar(
                  context,
                  builder: (context, close) => InfoBar(
                    title: Text(
                      I18n.of(context).translation_failed +
                          TranslationService.instance.describeLastError(),
                    ),
                  ),
                );
              }
            }
          }
        },
        child: isPending
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                  SizedBox(width: 4),
                  Text('...'),
                ],
              )
            : Text(
                _showTranslated
                    ? I18n.of(context).translation_show_original
                    : I18n.of(context).translate,
                style: const TextStyle(fontSize: 13),
              ),
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
