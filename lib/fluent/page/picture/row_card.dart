import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:pixez/fluent/component/context_menu.dart';
import 'package:pixez/fluent/component/focus_wrap.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/ban_tag.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/fluent/page/search/result_page.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';

class RowCard extends StatelessWidget {
  final Tags f;

  /// true 时显示机翻译文（详情页标签翻译开关）；false 保持只显示官方译名/原文
  final bool showTranslated;
  RowCard(this.f, {this.showTranslated = false});

  @override
  Widget build(BuildContext context) {
    final translatedName = f.translatedName ??
        (showTranslated
            ? TranslationService.instance.translatedOf(f.name, TranslateContentType.tag)
            : null);
    return ContextMenu(
      child: FocusWrap(
        child: GestureDetector(
          child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                  text: "#${f.name}",
                  children: [
                    TextSpan(
                      text: " ",
                      style: FluentTheme.of(context).typography.caption,
                    ),
                    TextSpan(
                        text: translatedName ?? "~",
                        style: FluentTheme.of(context).typography.caption)
                  ],
                  style: FluentTheme.of(context)
                      .typography
                      .caption!
                      .copyWith(color: FluentTheme.of(context).accentColor))),
          onTap: () => _invoke(context),
        ),
        onInvoke: () => _invoke(context),
      ),
      items: [
        MenuFlyoutItem(
          text: Text(I18n.of(context).ban),
          onPressed: () async {
            await muteStore.insertBanTag(BanTagPersist(
              name: f.name,
              translateName: f.translatedName ?? "",
            ));
          },
        ),
        MenuFlyoutItem(
          text: Text(I18n.of(context).bookmark),
          onPressed: () async {
            await bookTagStore.bookTag(f.name);
          },
        ),
        MenuFlyoutItem(
          text: Text(I18n.of(context).copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: f.name));
            displayInfoBar(context,
                builder: (context, VoidCallback) => InfoBar(
                      title: Text(I18n.of(context).copied_to_clipboard),
                    ));
          },
        ),
      ],
    );
  }

  _invoke(BuildContext context) {
    Leader.push(
      context,
      ResultPage(
        word: f.name,
        translatedName: f.translatedName ?? "",
      ),
      icon: Icon(FluentIcons.show_results),
      title: Text(I18n.of(context).tag + ' #${f.name}'),
    );
  }
}
