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
/// - 泄漏会导致所有后续图片永久排队

import 'dart:async';
import 'package:flutter/widgets.dart';

class _LoadEntry implements Comparable<_LoadEntry> {
  final String url;
  int priority;
  final void Function() onReady;

  _LoadEntry({required this.url, required this.priority, required this.onReady});

  @override
  int compareTo(_LoadEntry other) => priority.compareTo(other.priority);
}

class _ActiveSlot {
  final String url;
  final DateTime startTime;
  _ActiveSlot({required this.url}) : startTime = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(startTime) > const Duration(seconds: 30);
}

class ImageLoadCoordinator {
  /// 并发上限，与底层 HTTP 连接池匹配
  static const int maxConcurrent = 6;

  /// 离屏图片的优先级偏移量
  static const int _offScreenOffset = 100000;

  /// 槽位超时（秒）
  static const int slotTimeoutSeconds = 30;

  /// 全局回退实例（无列表作用域的 PixivImage 使用，如非列表场景）
  static final ImageLoadCoordinator instance = ImageLoadCoordinator._();

  /// 全局实例注册表：exitDetailMode 恢复时主动唤醒所有实例的队列。
  /// 否则"最后一个 release 发生在暂停期间"时队列无人唤醒
  static final Set<ImageLoadCoordinator> _instances = {};

  /// 详情页打开期间冻结所有列表协调器的队列推进：栈下的列表页仍在
  /// 悄悄抓取屏外缩略图，会与详情页大图争同一个 rhttp 连接池。
  /// 引用计数支持嵌套详情页（详情页再开详情页）。
  static int _detailCount = 0;
  static bool _globalPaused = false;

  /// 进入详情模式：暂停队列唤醒（不中断已活跃的请求）
  static void enterDetailMode() {
    _detailCount++;
    _globalPaused = true;
  }

  /// 退出详情模式：恢复队列唤醒。
  /// 暂停期间可能无人释放槽位，需主动 drain 所有实例避免队列卡死
  static void exitDetailMode() {
    if (_detailCount > 0) _detailCount--;
    _globalPaused = _detailCount > 0;
    if (!_globalPaused) {
      for (final coordinator in _instances.toList()) {
        coordinator._drainQueue();
      }
    }
  }

  /// 创建独立实例：每个列表页持有一个，隔离可视范围与队列状态，
  /// 避免多页面共享全局状态导致优先级错乱与队列饥饿。
  /// 页面销毁时应调用 [dispose] 释放
  factory ImageLoadCoordinator.create() => ImageLoadCoordinator._();

  ImageLoadCoordinator._() {
    _instances.add(this);
  }

  /// 从列表作用域取协调器：子树中存在 [ImageCoordinatorScope] 时使用
  /// 独立实例，否则回退全局实例
  static ImageLoadCoordinator of(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<ImageCoordinatorScope>();
    return scope?.coordinator ?? instance;
  }

  /// 释放实例占用的定时器与队列（页面 dispose 时调用）。
  /// 实例不再使用时不会残留周期定时器与排队项
  void dispose() {
    _instances.remove(this);
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
    // 先去重
    if (_activeUrls.contains(url)) return false;
    if (_queue.any((e) => e.url == url)) return false;

    final priority = _computePriority(basePriority);

    if (_activeSlots.length < maxConcurrent) {
      _activeSlots.add(_ActiveSlot(url: url));
      _activeUrls.add(url);
      _ensureCleanupTimer();
      return true;
    }

    _queue.add(_LoadEntry(url: url, priority: priority, onReady: onReady));
    _queue.sort();
    return false;
  }

  /// 释放一个槽位（CachedNetworkImage 加载完成/失败后调用）
  void release(String url) {
    if (!_activeUrls.remove(url)) return;
    _activeSlots.removeWhere((s) => s.url == url);
    _drainQueue();
  }

  /// 取消排队（PixivImage dispose 时调用）
  void cancel(String url) {
    if (_activeUrls.remove(url)) {
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

  void _drainQueue() {
    // 详情页打开期间不唤醒排队者：详情大图独占连接，返回列表后恢复
    if (_globalPaused) return;
    while (_activeSlots.length < maxConcurrent && _queue.isNotEmpty) {
      final entry = _queue.removeAt(0);
      if (_activeUrls.contains(entry.url)) continue;

      _activeSlots.add(_ActiveSlot(url: entry.url));
      _activeUrls.add(entry.url);
      entry.onReady();
    }
  }

  /// 超时自动释放：清理超过 [slotTimeoutSeconds] 的槽位
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
    if (expired.isNotEmpty) {
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
