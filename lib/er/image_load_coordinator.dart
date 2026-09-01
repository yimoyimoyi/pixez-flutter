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

  _LoadEntry(
      {required this.url,
      required this.priority,
      required this.onReadyCallbacks,
      DateTime? queuedAt})
      : queuedAt = queuedAt ?? clock.now();

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
  /// 并发上限，与底层 HTTP 连接池匹配
  static const int maxConcurrent = 6;

  /// 离屏图片的优先级偏移量
  static const int _offScreenOffset = 100000;

  /// 槽位超时（秒）
  static const int slotTimeoutSeconds = 30;

  /// 排队超时（秒）：超过该时长未获槽位（全局暂停泄漏、槽位异常占用
  /// 等）直接放行加载，绕过协调器——杜绝"有列表但图片永远不加载"。
  /// 正常网络下单张图片 <5s，超时多为异常场景，放行代价可接受
  static const int queueTimeoutSeconds = 5;

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

  /// 泄漏判定定时器：详情模式进入 [leakThreshold] 后置位"已超阈值"，
  /// 供 register 自愈区分"详情页正开着"（刚暂停，列表入队合理）与
  /// "详情页已离开但 dispose 未执行"（暂停超时泄漏）。用 Timer 而非
  /// 时间戳比较：测试可推进（fakeAsync），且避免真实时钟依赖
  static Timer? _leakTimer;
  static bool _pausedExceeded = false;

  /// 暂停持续超过该时长后，列表实例 register 视为泄漏并强制恢复。
  /// 详情页正常浏览通常 <10s 即回到列表
  static const Duration leakThreshold = Duration(seconds: 10);

  /// 进入详情模式：暂停队列唤醒（不中断已活跃的请求）
  static void enterDetailMode() {
    _detailCount++;
    _globalPaused = true;
    _pausedExceeded = false;
    _leakTimer?.cancel();
    _leakTimer = Timer(leakThreshold, () {
      _pausedExceeded = true;
    });
  }

  /// 退出详情模式：恢复队列唤醒。
  /// 暂停期间可能无人释放槽位，需主动 drain 所有实例避免队列卡死。
  /// 恢复采用分帧节流：直接全量 drain 会在返回列表瞬间制造 N×6 并发
  /// 尖峰（多个常驻列表 × 每实例立即放满），与"保护连接池"目标相悖
  static void exitDetailMode() {
    if (_detailCount > 0) _detailCount--;
    _globalPaused = _detailCount > 0;
    _leakTimer?.cancel();
    _leakTimer = null;
    _pausedExceeded = false;
    if (!_globalPaused) {
      _scheduleThrottledDrain();
    }
  }

  /// 每帧每个实例最多放行的排队者数量（恢复节流）
  static const int _throttlePerFrame = 2;

  /// 节流恢复：每 16ms（≈一帧）每实例限量放行，直到队列放空或耗尽。
  /// 用定时器而非帧回调（addPostFrameCallback 在 flutter_test 的 pump
  /// 中不被驱动，无法测试；16ms 节拍在真实 UI 上同样接近一帧）
  static void _scheduleThrottledDrain() {
    var remaining = _instances.toList();
    void step() {
      final done = <ImageLoadCoordinator>[];
      for (final coordinator in remaining) {
        final released = coordinator._drainQueue(throttle: _throttlePerFrame);
        if (released < _throttlePerFrame) {
          done.add(coordinator); // 队列已空或放不满额，无需继续节流
        }
      }
      if (done.isNotEmpty) remaining.removeWhere(done.contains);
      if (remaining.isNotEmpty) {
        Timer(const Duration(milliseconds: 16), step);
      }
    }

    step();
  }

  /// 创建独立实例：每个列表页持有一个，隔离可视范围与队列状态，
  /// 避免多页面共享全局状态导致优先级错乱与队列饥饿。
  /// 页面销毁时应调用 [dispose] 释放。
  /// [ignoreGlobalPause] 为 true 时不受全局暂停影响——供详情页使用：
  /// 详情页自身的大图在 enterDetailMode 暂停期间仍须加载，否则会因
  /// 全局暂停入队而永不唤醒（死锁）
  factory ImageLoadCoordinator.create({bool ignoreGlobalPause = false}) =>
      ImageLoadCoordinator._(ignoreGlobalPause);

  ImageLoadCoordinator._([this.ignoreGlobalPause = false]) {
    _instances.add(this);
  }

  /// 是否忽略全局暂停（enterDetailMode/exitDetailMode）
  final bool ignoreGlobalPause;

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
    // 全局暂停泄漏自愈：列表实例（非详情页）在暂停**超过阈值**后仍
    // 尝试注册新图片，说明"详情页已离开但 dispose 未执行"（桌面端
    // 路由保留、详情页内跳转搜索页等）——强制恢复全局状态，避免列表
    // 图片永久排队（有列表但无图）。刚暂停（<10s）的 register 仍正常
    // 入队（详情页正开着，列表在栈下 rebuild）；详情页自身实例
    // ignoreGlobalPause=true 不参与
    if (_globalPaused && !ignoreGlobalPause && _pausedExceeded) {
      _detailCount = 0;
      _globalPaused = false;
      _leakTimer?.cancel();
      _leakTimer = null;
      _pausedExceeded = false;
      _scheduleThrottledDrain();
    }

    // 去重：同一 URL 已在加载中时，组件共享同一底层加载任务
    //（Flutter ImageCache 按 key 合并 pending），只记账一次。
    // 注意：此检查放于暂停门控之前——在飞请求共享不受暂停影响
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

    // 详情页暂停期间：新请求直接入队，恢复后统一唤醒（不发起新连接）。
    // 忽略暂停的实例（详情页自身大图）不受此限制
    if (_globalPaused && !ignoreGlobalPause) {
      _queue.add(_LoadEntry(
          url: url, priority: priority, onReadyCallbacks: [onReady]));
      _queue.sort();
      // 暂停期间可能无活跃槽位（定时器未启动）：入队即确保清理定时器，
      // 让排队超时兜底（queueTimeoutSeconds）也能覆盖暂停入队的项
      _ensureCleanupTimer();
      return false;
    }

    if (_activeSlots.length < maxConcurrent) {
      _activeSlots.add(_ActiveSlot(url: url));
      _activeUrls.add(url);
      _ensureCleanupTimer();
      return true;
    }

    _queue.add(_LoadEntry(
        url: url, priority: priority, onReadyCallbacks: [onReady]));
    _queue.sort();
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

  /// 释放队列中的排队者，返回实际放行数量。
  /// [throttle] < 0 表示不限量（正常路径）；≥0 时每帧限量（恢复节流）
  int _drainQueue({int throttle = -1}) {
    // 详情页打开期间不唤醒排队者：详情大图独占连接，返回列表后恢复
    //（忽略暂停的实例——详情页自身——不受此限制）
    if (_globalPaused && !ignoreGlobalPause) return 0;
    var released = 0;
    while (_activeSlots.length < maxConcurrent && _queue.isNotEmpty) {
      if (throttle >= 0 && released >= throttle) break;
      final entry = _queue.removeAt(0);
      if (_activeUrls.contains(entry.url)) continue;

      // refCount 初始化为等待回调数：合并的同 URL 多组件各自持有一份
      // 引用，任一组件 release/cancel 只递减自己的，最后一个才释放槽位
      _activeSlots.add(
          _ActiveSlot(url: entry.url, refCount: entry.onReadyCallbacks.length));
      _activeUrls.add(entry.url);
      for (final onReady in entry.onReadyCallbacks) {
        onReady();
      }
      released++;
    }
    return released;
  }

  /// 超时自动释放：清理超过 [slotTimeoutSeconds] 的槽位；
  /// 排队超过 [queueTimeoutSeconds] 的项直接放行（绕过协调器加载，
  /// 杜绝全局暂停泄漏等场景下的永久无图）
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

    // 排队超时兜底：入队超过阈值（含全局暂停期间入队的）直接放行
    final staleQueued = _queue
        .where((e) =>
            clock.now().difference(e.queuedAt) >
            const Duration(seconds: queueTimeoutSeconds))
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

/// 详情页作用域：进入时全局暂停列表协调器队列（enterDetailMode），
/// 销毁时自动恢复（exitDetailMode）。
///
/// 将 enter/exit 封装进 widget 生命周期，替代手写 initState/dispose
/// 配对：任何页面忘记配对或新增详情页忘记接线时，不会留下永久暂停
/// 的全局状态。注意：路由仍留在导航栈中（如桌面端临时路由切页签）时
/// dispose 不会执行，暂停状态随之保留——属已知限制
class DetailModeScope extends StatefulWidget {
  final Widget child;

  const DetailModeScope({super.key, required this.child});

  @override
  State<DetailModeScope> createState() => _DetailModeScopeState();
}

class _DetailModeScopeState extends State<DetailModeScope> {
  @override
  void initState() {
    super.initState();
    ImageLoadCoordinator.enterDetailMode();
  }

  @override
  void dispose() {
    ImageLoadCoordinator.exitDetailMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
