/// 图片加载协调器
///
/// 按瀑布流 index 顺序（从上到下）控制 PixivImage 的网络请求并发数。
/// 首屏所有可见卡片同步构建时，只有前 maxConcurrent 张允许立即加载 CachedNetworkImage，
/// 其余显示占位符并排队等待。当槽位释放后，按优先级（index 顺序）唤醒下一个等待者。
///
/// 优先级规则：
/// - 数字越小越优先（对应瀑布流顶部的 index）
/// - 可视范围外的图片被加上 large offset，确保可见区域优先
/// - 缓存命中的图片跳过排队立即显示（由调用方在 register 前自行判断）
///
/// 槽位保护：
/// - 每个活跃槽位有 30 秒超时，超时自动释放防止泄漏
/// - 排队超过 5 秒直接放行（绕过协调器），杜绝任何原因导致的永久无图
///
/// 设计说明（去全局暂停机制后）：
/// - 不再有 enterDetailMode/exitDetailMode 全局暂停——该机制依赖组件
///   生命周期配对，路由保留/覆盖时 dispose 不执行会泄漏，导致"有列表
///   但图片永久排队"的回归，需多层补丁（自愈/超时/路由观察）修复
/// - 每个列表页持独立实例（槽位隔离）；栈下页面不滚动、不注册新图片，
///   与详情大图的连接争抢窗口 ≤ maxConcurrent 个在途缩略图（<1s）
/// - maxConcurrent 4 配合"栈下不滚动"天然限流，连接池压力温和

import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

class _LoadEntry implements Comparable<_LoadEntry> {
  final String url;
  int priority;
  // 同一 URL 可能有多个等待组件（重复作品/头像），获槽位时全部唤醒
  final List<void Function()> onReadyCallbacks;
  // 入队时间：排队超时兜底（杜绝任何原因导致的永久排队无图）。
  // 用 clock.now() 而非 DateTime.now()：fakeAsync 测试可推进时钟
  final DateTime queuedAt;

  _LoadEntry({
    required this.url,
    required this.priority,
    required this.onReadyCallbacks,
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? clock.now();

  @override
  int compareTo(_LoadEntry other) => priority.compareTo(other.priority);
}

class _ActiveSlot {
  final String url;
  final DateTime startTime;
  // 同一 URL 的共享者引用计数：多组件并发注册同一 URL 只占一个槽位，
  // 各方 release/cancel 递减，归零才真正释放，避免共享者误删他人槽位。
  // 初始值 = 获槽位条目的等待回调数（排队合并的多组件各自占一份引用）
  int refCount;
  _ActiveSlot({required this.url, int refCount = 1})
    : startTime = clock.now(),
      refCount = refCount;

  bool get isExpired =>
      clock.now().difference(startTime) > const Duration(seconds: 30);
}

class ImageLoadCoordinator {
  /// 并发上限，与底层 HTTP 连接池匹配（4 为温和并发：列表/详情/全局
  /// 实例叠加时峰值 12，连接池压力可控）
  static const int maxConcurrent = 4;

  /// 离屏图片的优先级偏移量
  static const int _offScreenOffset = 100000;

  /// 槽位超时（秒）
  static const int slotTimeoutSeconds = 30;

  /// 排队超时（秒）：超过该时长未获槽位（槽位异常占用等）直接放行
  /// 加载，绕过协调器——杜绝"有列表但图片永远不加载"。
  /// 正常网络下单张图片 <5s，超时多为异常场景，放行代价可接受
  static const int queueTimeoutSeconds = 5;

  /// 全局回退实例（无列表作用域的 PixivImage 使用，如非列表场景）
  static final ImageLoadCoordinator instance = ImageLoadCoordinator._();

  /// 创建独立实例：每个列表页持有一个，隔离可视范围与队列状态，
  /// 避免多页面共享全局状态导致优先级错乱与队列饥饿。
  /// 页面销毁时应调用 [dispose] 释放。
  factory ImageLoadCoordinator.create() => ImageLoadCoordinator._();

  ImageLoadCoordinator._();

  /// 从列表作用域取协调器：子树中存在 [ImageCoordinatorScope] 时使用
  /// 独立实例，否则回退全局实例
  static ImageLoadCoordinator of(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<ImageCoordinatorScope>();
    return scope?.coordinator ?? instance;
  }

  /// 释放实例占用的定时器与队列（页面 dispose 时调用）。
  /// 实例不再使用时不会残留周期定时器与排队项
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _activeSlots.clear();
    _activeUrls.clear();
    _queue.clear();
  }

  final List<_ActiveSlot> _activeSlots = [];
  final Set<String> _activeUrls = {};
  final List<_LoadEntry> _queue = [];

  /// 当前可视范围 [start, end]（瀑布流 index）
  int _visibleStart = 0;
  int _visibleEnd = 0;

  /// 周期性清理定时器
  Timer? _cleanupTimer;

  void _ensureCleanupTimer() {
    _cleanupTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => _expireStaleSlots(),
    );
  }

  /// 注册一个加载请求。
  ///
  /// 返回 true 表示可以立刻加载（获得槽位）。
  /// 返回 false 表示槽位已满，已加入排队，[onReady] 将在槽位释放时被调用。
  bool register(String url, int basePriority, void Function() onReady) {
    // 去重：同一 URL 已在加载中时，组件共享同一底层加载任务
    //（Flutter ImageCache 按 key 合并 pending），只记账一次。
    for (final slot in _activeSlots) {
      if (slot.url == url) {
        slot.refCount++;
        return true;
      }
    }
    // 同一 URL 已在排队：追加等待回调，获槽位时一并唤醒
    if (_queue.any((e) => e.url == url)) {
      _queue.firstWhere((e) => e.url == url).onReadyCallbacks.add(onReady);
      return false;
    }

    final priority = _computePriority(basePriority);

    if (_activeSlots.length < maxConcurrent) {
      _activeSlots.add(_ActiveSlot(url: url));
      _activeUrls.add(url);
      _ensureCleanupTimer();
      return true;
    }

    _queue.add(
      _LoadEntry(url: url, priority: priority, onReadyCallbacks: [onReady]),
    );
    _queue.sort();
    // 入队即确保清理定时器：排队超时兜底（queueTimeoutSeconds）覆盖
    // 所有入队项（槽位满时定时器可能未启动——首次注册即获槽位除外）
    _ensureCleanupTimer();
    return false;
  }

  /// 释放一个槽位（CachedNetworkImage 加载完成/失败后调用）
  void release(String url) {
    if (!_activeUrls.contains(url)) return;
    for (final slot in _activeSlots) {
      if (slot.url == url) {
        slot.refCount--;
        if (slot.refCount > 0) return; // 仍有共享者，不释放
      }
    }
    _activeUrls.remove(url);
    _activeSlots.removeWhere((s) => s.url == url);
    _drainQueue();
  }

  /// 取消排队（PixivImage dispose 时调用）
  void cancel(String url) {
    if (_activeUrls.contains(url)) {
      for (final slot in _activeSlots) {
        if (slot.url == url) {
          slot.refCount--;
          if (slot.refCount > 0) return; // 仍有共享者，不释放
        }
      }
      _activeUrls.remove(url);
      _activeSlots.removeWhere((s) => s.url == url);
      _drainQueue();
    } else {
      _queue.removeWhere((e) => e.url == url);
    }
  }

  /// 更新可视范围（由 LightingList 滚动监听触发）
  void updateVisibleRange(int start, int end) {
    if (start == _visibleStart && end == _visibleEnd) return;
    _visibleStart = start;
    _visibleEnd = end;
    _reprioritize();
  }

  /// 计算最终优先级
  int _computePriority(int basePriority) {
    if (basePriority < _visibleStart || basePriority > _visibleEnd) {
      return basePriority + _offScreenOffset;
    }
    return basePriority;
  }

  void _reprioritize() {
    if (_queue.isEmpty) return;
    for (final entry in _queue) {
      final rawPriority = entry.priority % _offScreenOffset;
      entry.priority = _computePriority(rawPriority);
    }
    _queue.sort();
  }

  /// 释放队列中的排队者，返回实际放行数量
  int _drainQueue() {
    var released = 0;
    while (_activeSlots.length < maxConcurrent && _queue.isNotEmpty) {
      final entry = _queue.removeAt(0);
      if (_activeUrls.contains(entry.url)) continue;

      // refCount 初始化为等待回调数：合并的同 URL 多组件各自持有一份
      // 引用，任一组件 release/cancel 只递减自己的，最后一个才释放槽位
      _activeSlots.add(
        _ActiveSlot(url: entry.url, refCount: entry.onReadyCallbacks.length),
      );
      _activeUrls.add(entry.url);
      for (final onReady in entry.onReadyCallbacks) {
        onReady();
      }
      released++;
    }
    return released;
  }

  /// 超时自动释放：清理超过 [slotTimeoutSeconds] 的槽位；
  /// 排队超过 [queueTimeoutSeconds] 的项直接放行（绕过协调器加载）
  void _expireStaleSlots() {
    final expired = <String>[];
    for (final slot in _activeSlots) {
      if (slot.isExpired) {
        expired.add(slot.url);
      }
    }
    for (final url in expired) {
      _activeUrls.remove(url);
      _activeSlots.removeWhere((s) => s.url == url);
    }

    // 排队超时兜底：入队超过阈值的直接放行
    final staleQueued = _queue
        .where(
          (e) =>
              clock.now().difference(e.queuedAt) >
              const Duration(seconds: queueTimeoutSeconds),
        )
        .toList();
    for (final entry in staleQueued) {
      _queue.remove(entry);
      for (final onReady in entry.onReadyCallbacks) {
        onReady();
      }
    }

    if (expired.isNotEmpty || staleQueued.isNotEmpty) {
      _drainQueue();
    }

    // 没有活跃槽位时停止定时器
    if (_activeSlots.isEmpty && _queue.isEmpty) {
      _cleanupTimer?.cancel();
      _cleanupTimer = null;
    }
  }

  /// 调试用
  int get activeCount => _activeSlots.length;
  int get queueLength => _queue.length;
}

/// 列表作用域：为子树中的 PixivImage 提供独立的图片加载协调器实例。
///
/// 每个列表页（LightingList 等）在 build 时包一层，其可视范围与排队
/// 状态独立于其他页面，避免：
/// - 一个页面的 `updateVisibleRange()` 改变全局可视范围，干扰其他页面优先级
/// - 不同列表 index 语义混用（瀑布流 index vs 搜索列表 index）
/// - 一个页面槽位不释放导致其他页面图片永久排队
class ImageCoordinatorScope extends InheritedWidget {
  final ImageLoadCoordinator coordinator;

  const ImageCoordinatorScope({
    super.key,
    required this.coordinator,
    required super.child,
  });

  @override
  bool updateShouldNotify(ImageCoordinatorScope oldWidget) =>
      coordinator != oldWidget.coordinator;
}
