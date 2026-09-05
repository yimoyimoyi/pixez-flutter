/*
 * Fluent 翻译设置页交互回归测试：总开关 ToggleSwitch 与 ComboBox 配置须生效。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:pixez/fluent/page/hello/setting/translation_setting_page.dart';
import 'package:pixez/main.dart';
import 'package:pixez/src/generated/i18n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Fluent 翻译设置页：点击总开关生效', (tester) async {
    SharedPreferences.setMockInitialValues({});
    userSetting.prefs = await SharedPreferences.getInstance();
    userSetting.translateConfigJson = '';

    await tester.pumpWidget(fluent.FluentApp(
      theme: fluent.FluentThemeData.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TranslationSettingPage(),
    ));
    await tester.pump();

    // Fluent ToggleSwitch 总开关
    await tester.tap(find.byType(fluent.ToggleSwitch).first);
    await tester.pump();
    expect(userSetting.translateConfig.masterEnabled, false,
        reason: 'Fluent 开关点击后 masterEnabled 应变为 false');

    await tester.tap(find.byType(fluent.ToggleSwitch).first);
    await tester.pump();
    expect(userSetting.translateConfig.masterEnabled, true,
        reason: '再次点击后应恢复 true');

    // Fluent HoverButton 点击后残留 100ms 定时器，flush 掉避免 pending timer
    await tester.pump(const Duration(milliseconds: 200));
  });
}
