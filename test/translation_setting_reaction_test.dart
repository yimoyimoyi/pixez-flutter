/*
 * 翻译配置 observable 反应回归测试。
 * 回归背景：translateConfigJson 作为新 @observable 字段曾被 build_runner 过滤器
 * 遗漏生成代理（见 user_setting.g.dart 历史），导致读写不触发 MobX 反应、
 * 翻译设置页永不重建。本测试守护该链路。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    userSetting.translateConfigJson = '';
  });

  test('translateConfig getter 可被 MobX 反应追踪', () async {
    userSetting.prefs = await SharedPreferences.getInstance();
    final values = <bool>[];
    final dispose = autorun((_) {
      values.add(userSetting.translateConfig.masterEnabled);
    });
    await userSetting.setTranslateConfig(
        userSetting.translateConfig.copyWith(masterEnabled: false));
    await Future<void>.delayed(Duration.zero);
    dispose();
    // 初始一次 + 变更一次（若代理缺失只会是 [true]）
    expect(values, [true, false]);
  });
}
