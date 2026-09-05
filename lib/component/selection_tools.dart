/*
 * 选择菜单公共工具：向文本选择菜单插入"应用内翻译"项（generic 类型）。
 * 替换各页面复制粘贴的 Android 系统翻译注入点。
 */

import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_dialog.dart';
import 'package:pixez/translation/translation_service.dart';

/// 在选区菜单末尾插入"翻译"项；未开启选区翻译配置时不插入。
/// [selectionText] 为当前选中文本。
void addTranslateMenuItem(
  List<ContextMenuButtonItem> items, {
  required BuildContext context,
  required String selectionText,
}) {
  final service = TranslationService.instance;
  if (!service.isTypeEnabled(TranslateContentType.generic)) return;
  if (selectionText.trim().isEmpty) return;
  items.insert(
    items.length,
    ContextMenuButtonItem(
      label: I18n.of(context).translate,
      onPressed: () {
        ContextMenuController.removeAny();
        showDialog(
          context: context,
          builder: (_) => TranslationDialog(text: selectionText),
        );
      },
    ),
  );
}
