import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/main.dart';

/// DetailModeScope 路由可见性测试：详情页被其他路由覆盖（如点击 tag
/// 跳转搜索页）时解除全局暂停，新页面图片立即可加载；返回详情页时
/// 恢复暂停（详情大图独占连接池）。对应修复：协调器暂停泄漏
///（dispose 未执行导致新页面图片永久排队）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 列表协调器（非详情页实例）：register 返回 true = 暂停已解除
  ImageLoadCoordinator createListCoordinator() =>
      ImageLoadCoordinator.create();

  testWidgets('详情页被覆盖时解除全局暂停，返回时恢复', (tester) async {
    addTearDown(() {
      // 兜底清理全局暂停状态（无论测试结果）
      ImageLoadCoordinator.exitDetailMode();
    });

    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routeObserver],
      home: DetailModeScope(
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        const Scaffold(body: Text('搜索页')),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ));

    // 详情页打开：全局暂停生效 → 列表 register 入队
    final list1 = createListCoordinator();
    expect(list1.register('a', 0, () {}), isFalse,
        reason: '详情页可见时应暂停列表加载（register 入队）');
    list1.dispose();

    // 模拟 tag 点击：push 搜索页 → 详情页被覆盖 → didPushNext 解除暂停
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final list2 = createListCoordinator();
    expect(list2.register('b', 0, () {}), isTrue,
        reason: '详情页被覆盖后暂停应解除，新页面图片立即可加载');
    list2.dispose();

    // 返回详情页 → didPopNext 恢复暂停
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    final list3 = createListCoordinator();
    expect(list3.register('c', 0, () {}), isFalse,
        reason: '返回详情页后应恢复暂停（详情大图独占连接池）');
    list3.dispose();
  });

  testWidgets('详情页销毁（pop 出栈）时全局暂停解除', (tester) async {
    addTearDown(() {
      ImageLoadCoordinator.exitDetailMode();
    });

    // 详情页作为压栈路由：从首页 push 进入
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routeObserver],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DetailModeScope(
                    child: Scaffold(body: Text('详情页')),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    // 进入详情页：全局暂停
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final list1 = createListCoordinator();
    expect(list1.register('a', 0, () {}), isFalse,
        reason: '详情页打开时应暂停列表加载');
    list1.dispose();

    // 详情页 pop 出栈（dispose）→ 暂停解除
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    final list2 = createListCoordinator();
    expect(list2.register('b', 0, () {}), isTrue,
        reason: '详情页销毁后暂停应解除');
    list2.dispose();
  });
}
