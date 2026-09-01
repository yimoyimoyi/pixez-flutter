import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/image_load_coordinator.dart';

/// ImageLoadCoordinator 单元测试：覆盖去重共享、引用计数、槽位调度、
/// 排队超时兜底等状态机逻辑（纯 Dart 组件，无 Flutter UI 依赖）。
/// 对应修复：F1（同 URL 去重放行）、F12（排队超时兜底）、
/// maxConcurrent=4（温和并发）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 占满全部槽位（maxConcurrent = 4）
  void fillSlots(ImageLoadCoordinator c) {
    for (var i = 0; i < ImageLoadCoordinator.maxConcurrent; i++) {
      expect(c.register('u$i', i, () {}), isTrue);
    }
  }

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
      fillSlots(c);
      // 第 5 个排队
      final ready = <String>[];
      expect(c.register('g', 4, () => ready.add('first')), isFalse);
      // 同 URL 再次排队：回调追加（不丢弃）
      expect(c.register('g', 4, () => ready.add('second')), isFalse);
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

  group('槽位调度与排队', () {
    test('maxConcurrent 满后剩余排队，release 时全量放行', () {
      final c = ImageLoadCoordinator.create();
      fillSlots(c);
      // 第 5 个排队
      final ready = <String>[];
      for (var i = 0; i < 5; i++) {
        c.register('q$i', 4, () => ready.add('q$i'));
      }
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent);
      expect(c.queueLength, 5);

      // 释放一个槽位 → 队列第一个被唤醒
      c.release('u0');
      expect(ready, ['q0']);
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent,
          reason: '释放 1 个补 1 个');
      c.dispose();
    });

    test('release 唤醒下一个排队者', () {
      final c = ImageLoadCoordinator.create();
      fillSlots(c);
      final ready = <String>[];
      expect(c.register('next', 4, () => ready.add('next')), isFalse);

      c.release('u0');
      expect(ready, ['next']);

      c.dispose();
    });

    test('queue 中同 URL 被 cancel：从队列移除', () {
      final c = ImageLoadCoordinator.create();
      fillSlots(c);
      c.register('pending', 4, () {});
      expect(c.queueLength, 1);
      c.cancel('pending');
      expect(c.queueLength, 0);

      c.dispose();
    });

    test('排队合并的多等待者：refCount 初始化为回调数，逐个释放才回收槽位', () {
      final c = ImageLoadCoordinator.create();
      fillSlots(c);
      // 两个组件等待同一 URL
      final ready = <String>[];
      expect(c.register('g', 4, () => ready.add('a')), isFalse);
      expect(c.register('g', 4, () => ready.add('b')), isFalse);

      // 释放一个槽位 → g 获槽位，两个回调都触发
      c.release('u0');
      expect(ready, ['a', 'b']);
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent,
          reason: 'g 占 1 槽，共 maxConcurrent 槽');

      // 第一个组件释放：引用递减，槽位保留
      c.release('g');
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent,
          reason: '第二个组件仍在加载，槽位不释放');
      // 最后一个组件释放：槽位真正回收
      c.release('g');
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent - 1);
      // 第三个同 URL 组件此时注册：应获得新槽位（不再误判在飞）
      final ready3 = <String>[];
      expect(c.register('g', 4, () => ready3.add('c')), isTrue);
      expect(c.activeCount, ImageLoadCoordinator.maxConcurrent);

      c.dispose();
    });
  });

  group('排队超时兜底（F12）', () {
    test('排队超过 queueTimeoutSeconds 直接放行', () {
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        final ready = <String>[];
        fillSlots(c);
        // 第 5 个排队
        expect(c.register('pending', 4, () => ready.add('pending')), isFalse);
        expect(c.queueLength, 1);

        // 超过排队超时（5s）：elapse 11s 触发 10s 周期清理定时器，
        // queuedAt 差值 11s > 5s → 放行
        async.elapse(const Duration(seconds: 11));
        expect(ready, ['pending'], reason: '排队超时应直接放行（绕过协调器）');
        expect(c.queueLength, 0);
        expect(c.activeCount, ImageLoadCoordinator.maxConcurrent,
            reason: '放行不占槽位（绕过协调器）');

        c.dispose();
      });
    });

    test('空闲时排队超时也放行（无活跃槽位也能触发清理定时器）', () {
      fakeAsync((async) {
        final c = ImageLoadCoordinator.create();
        // 首次注册即获槽位（启动清理定时器），然后立即释放
        expect(c.register('u0', 0, () {}), isTrue);
        c.release('u0');
        // 槽位全空时的排队（模拟槽位释放后重新排队）
        expect(c.register('pending', 0, () {}), isTrue);
        c.release('pending');
        // 队列空、定时器停止；再次排队需要新定时器
        expect(c.register('a', 0, () {}), isTrue);
        c.release('a');
        expect(c.activeCount, 0);
        expect(c.queueLength, 0);
        c.dispose();
      });
    });
  });
}
