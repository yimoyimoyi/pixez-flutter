/*
 * 翻译设置页交互回归测试：
 * 回归背景：translateConfigJson 作为新 @observable 字段曾被 build_runner 过滤器遗漏生成，
 * 导致读写不触发反应、设置页永不重建（详见 git 记录）。
 */

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/hello/setting/translation_setting_page.dart';
import 'package:pixez/src/generated/i18n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('翻译设置页：点击总开关生效', (tester) async {
    SharedPreferences.setMockInitialValues({});
    userSetting.prefs = await SharedPreferences.getInstance();
    userSetting.translateConfigJson = '';

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: const TranslationSettingPage(),
    ));
    await tester.pump();

    // 点击第一个 SwitchListTile（总开关）
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    expect(userSetting.translateConfig.masterEnabled, false,
        reason: '点击后 masterEnabled 应变为 false');

    // 再点击恢复
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    expect(userSetting.translateConfig.masterEnabled, true,
        reason: '再次点击后 masterEnabled 应恢复为 true');
  });
}
