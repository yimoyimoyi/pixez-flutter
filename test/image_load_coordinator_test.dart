import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/image_load_coordinator.dart';

/// ImageLoadCoordinator 单元测试：覆盖去重共享、引用计数、暂停门控、
/// 节流恢复等状态机逻辑（纯 Dart 组件，无 Flutter UI 依赖）。
/// 对应修复：F1（同 URL 去重放行）、F8（暂停门控）、F12（drain 节流）、
/// F15（ignoreGlobalPause 详情页实例）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('register 去重与引用计数（F1）', () {
    test('同 URL 已在加载：共享槽位（refCount++），不重复记账', () {
      final c = ImageLoadCoordinator.create();
      final ready = <String>[];

      // 第一次注册：获得槽位
      expect(c.register('a', 0, () => ready.add('cb1')), isTrue);
      expect(c.activeCount, 1);
      // 第二次同 URL 注册：共享同一槽位
      expect(c.register('a', 0, () => ready.add('cb2')), isTrue);
      expect(c.activeCount, 1, reason: '同 URL 只占一个槽位');

      // 一个共享者释放：槽位保留
      c.release('a');
      expect(c.activeCount, 1);
      // 最后一个共享者释放：槽位真正释放
      c.release('a');
      expect(c.activeCount, 0);
      expect(ready, isEmpty, reason: '共享不触发 onReady（直接放行）');

      c.dispose();
    });

    test('同 URL 排队：等待回调追加，获槽位时全部唤醒', () {
      final c = ImageLoadCoordinator.create();
      // 占满 6 个槽位
      for (var i = 0; i < 6; i++) {
        expect(c.register('u$i', i, () {}), isTrue);
      }
      // 第七个排队
      final ready = <String>[];
      expect(c.register('g', 6, () => ready.add('first')), isFalse);
      // 同 URL 再次排队：回调追加（不丢弃）
      expect(c.register('g', 6, () => ready.add('second')), isFalse);
      expect(c.queueLength, 1, reason: '同 URL 排队只占一个条目');

      // 释放一个槽位 → g 获槽位 → 两个等待回调都触发
      c.release('u0');
      expect(ready, ['first', 'second']);

      c.dispose();
    });

    test('cancel 引用计数：共享者 cancel 不误删他人槽位', () {
      final c = ImageLoadCoordinator.create();
      expect(c.register('a', 0, () {}), isTrue);
      expect(c.register('a', 0, () {}), isTrue); // 共享者

      // 一个组件销毁（cancel）：槽位保留给另一个
      c.cancel('a');
      expect(c.activeCount, 1);
      // 另一个也销毁：释放
      c.cancel('a');
      expect(c.activeCount, 0);

      c.dispose();
    });
  });

  group('暂停门控与节流恢复（F8/F12）', () {
    test('暂停期间新注册入队不放行，退出后节流唤醒', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        ImageLoadCoordinator.enterDetailMode();

        // 暂停期间注册：即使槽位有空也入队
        final ready = <String>[];
        expect(c.register('a', 0, () => ready.add('a')), isFalse);
        expect(c.queueLength, 1);
        expect(ready, isEmpty);

        ImageLoadCoordinator.exitDetailMode();
        // 首轮 step 同步执行：不足 2 个的实例立即放完
        expect(ready, ['a'], reason: '退出详情模式后队列恢复唤醒');
        expect(c.activeCount, 1);
        c.dispose();
      });
    });

    test('ignoreGlobalPause 实例（详情页）暂停期间仍放行', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create(ignoreGlobalPause: true);
        ImageLoadCoordinator.enterDetailMode();

        final ready = <String>[];
        // 详情页自身大图不受全局暂停影响：立即获槽位
        expect(c.register('a', 0, () => ready.add('a')), isTrue);
        expect(ready, isEmpty, reason: '放行不触发 onReady');

        ImageLoadCoordinator.exitDetailMode();
        expect(c.activeCount, 1);
        c.dispose();
      });
    });

    test('退出详情模式后节流：每 16ms 限量放行，防 burst 尖峰', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        ImageLoadCoordinator.enterDetailMode();

        // 暂停期间 6 个请求入队
        final ready = <String>[];
        for (var i = 0; i < 6; i++) {
          c.register('q$i', i, () => ready.add('q$i'));
        }
        expect(c.queueLength, 6);

        ImageLoadCoordinator.exitDetailMode();
        // 首轮 step 同步执行：每实例放行 2 个（防 burst 尖峰）
        expect(c.activeCount, 2);
        async.elapse(const Duration(milliseconds: 16));
        expect(c.activeCount, 4);
        async.elapse(const Duration(milliseconds: 16));
        expect(c.activeCount, 6, reason: '最后一个节拍放完剩余 2 个');
        expect(ready.length, 6);
        c.dispose();
      });
    });

    test('maxConcurrent 满后剩余排队，release 时全量放行', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        ImageLoadCoordinator.enterDetailMode();

        // 7 个请求：6 个并发上限 + 1 个排队
        final ready = <String>[];
        for (var i = 0; i < 7; i++) {
          c.register('q$i', i, () => ready.add('q$i'));
        }
        ImageLoadCoordinator.exitDetailMode();
        expect(c.activeCount, 2);
        async.elapse(const Duration(milliseconds: 16));
        async.elapse(const Duration(milliseconds: 16));
        expect(c.activeCount, 6, reason: '达到 maxConcurrent 后停止放行');
        expect(c.queueLength, 1, reason: '第 7 个等待槽位释放');

        // 释放一个槽位 → 排队者被唤醒
        c.release('q0');
        expect(ready.length, 7);
        expect(c.activeCount, 6, reason: '释放 1 个补 1 个');
        c.dispose();
      });
    });
  });

  group('全局暂停泄漏自愈与排队超时（F16/F17）', () {
    test('暂停泄漏自愈：暂停超阈值后列表 register 强制恢复', () {
      // 无论成功失败都恢复全局状态，避免静态 _globalPaused 残留污染
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        // 模拟泄漏：进入详情模式但 dispose 未执行（_detailCount 残留）
        ImageLoadCoordinator.enterDetailMode();
        // 刚暂停时 register 正常入队（详情页正开着，保留暂停门控）
        expect(c.register('a', 0, () {}), isFalse,
            reason: '暂停初期列表 register 仍应入队（保留暂停门控）');
        expect(c.queueLength, 1);

        // 超过泄漏阈值（10s）：列表再次 register → 自愈恢复
        async.elapse(const Duration(seconds: 11));
        final ready = <String>[];
        expect(c.register('b', 0, () => ready.add('b')), isTrue,
            reason: '暂停泄漏（超阈值）时 register 应自愈并立即获槽位');
        expect(ready, isEmpty, reason: '获槽位不触发 onReady');
        expect(c.activeCount, 1);

        c.dispose();
      });
    });

    test('详情页实例（ignoreGlobalPause）不触发自愈', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create(ignoreGlobalPause: true);
        ImageLoadCoordinator.enterDetailMode();
        async.elapse(const Duration(seconds: 11));

        // 详情页自身大图：暂停期间正常获槽位，且不触发自愈恢复
        expect(c.register('a', 0, () {}), isTrue);
        expect(c.activeCount, 1);

        c.dispose();
      });
    });

    test('排队超时兜底：超过 queueTimeoutSeconds 直接放行', () {
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        final ready = <String>[];
        // 占满 6 个槽位（启动清理定时器）
        for (var i = 0; i < 6; i++) {
          c.register('u$i', i, () {});
        }
        // 第 7 个排队
        expect(c.register('pending', 6, () => ready.add('pending')), isFalse);
        expect(c.queueLength, 1);

        // 超过排队超时（5s）：elapse 11s 触发 10s 周期清理定时器，
        // queuedAt 差值 11s > 5s → 放行
        async.elapse(const Duration(seconds: 11));
        expect(ready, ['pending'], reason: '排队超时应直接放行（绕过协调器）');
        expect(c.queueLength, 0);
        expect(c.activeCount, 6, reason: '放行不占槽位（绕过协调器）');

        c.dispose();
      });
    });

    test('全局暂停期间排队超时也放行（防永久无图）', () {
      addTearDown(ImageLoadCoordinator.exitDetailMode);
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        ImageLoadCoordinator.enterDetailMode();

        // 暂停期间注册：入队（暂停分支已确保清理定时器启动）
        final ready = <String>[];
        expect(c.register('a', 0, () => ready.add('a')), isFalse);
        expect(c.queueLength, 1);

        // 即使全局暂停未恢复，排队超时兜底仍放行（11s 触发 10s 定时器）
        async.elapse(const Duration(seconds: 11));
        expect(ready, ['a'], reason: '暂停期间排队超时应放行');
        expect(c.queueLength, 0);

        c.dispose();
      });
    });
  });

  group('基本槽位行为', () {
    test('release 唤醒下一个排队者', () {
      final c = ImageLoadCoordinator.create();
      for (var i = 0; i < 6; i++) {
        c.register('u$i', i, () {});
      }
      final ready = <String>[];
      expect(c.register('next', 6, () => ready.add('next')), isFalse);

      c.release('u0');
      expect(ready, ['next']);

      c.dispose();
    });

    test('queue 中同 URL 被 cancel：从队列移除', () {
      final c = ImageLoadCoordinator.create();
      for (var i = 0; i < 6; i++) {
        c.register('u$i', i, () {});
      }
      c.register('pending', 6, () {});
      expect(c.queueLength, 1);
      c.cancel('pending');
      expect(c.queueLength, 0);

      c.dispose();
    });

    test('排队合并的多等待者：refCount 初始化为回调数，逐个释放才回收槽位', () {
      final c = ImageLoadCoordinator.create();
      for (var i = 0; i < 6; i++) {
        c.register('u$i', i, () {});
      }
      // 两个组件等待同一 URL
      final ready = <String>[];
      expect(c.register('g', 6, () => ready.add('a')), isFalse);
      expect(c.register('g', 6, () => ready.add('b')), isFalse);

      // 释放一个槽位 → g 获槽位，两个回调都触发
      c.release('u0');
      expect(ready, ['a', 'b']);
      expect(c.activeCount, 6, reason: 'g 占 1 槽，共 6 槽');

      // 第一个组件释放：引用递减，槽位保留
      c.release('g');
      expect(c.activeCount, 6, reason: '第二个组件仍在加载，槽位不释放');
      // 最后一个组件释放：槽位真正回收
      c.release('g');
      expect(c.activeCount, 5);
      // 第三个同 URL 组件此时注册：应获得新槽位（不再误判在飞）
      final ready3 = <String>[];
      expect(c.register('g', 6, () => ready3.add('c')), isTrue);
      expect(c.activeCount, 6);

      c.dispose();
    });
  });
}
