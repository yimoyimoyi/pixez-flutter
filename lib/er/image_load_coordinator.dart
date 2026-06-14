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

class _LoadEntry implements Comparable<_LoadEntry> {
  final String url;
  int priority;
  final void Function() onReady;

  _LoadEntry({required this.url, required this.priority, required this.onReady});

  @override
  int compareTo(_LoadEntry other) => priority.compareTo(other.priority);
}

class ImageLoadCoordinator {
  /// 并发上限，与底层 HTTP 连接池匹配
  static const int maxConcurrent = 6;

  /// 离屏图片的优先级偏移量
  static const int _offScreenOffset = 100000;

  static final ImageLoadCoordinator instance = ImageLoadCoordinator._();
  ImageLoadCoordinator._();

  int _activeCount = 0;
  final Set<String> _activeUrls = {};
  final List<_LoadEntry> _queue = [];

  /// 当前可视范围 [start, end]（瀑布流 index）
  int _visibleStart = 0;
  int _visibleEnd = 0;

  /// 注册一个加载请求。
  ///
  /// 返回 true 表示可以立刻加载（获得槽位）。
  /// 返回 false 表示槽位已满，已加入排队，[onReady] 将在槽位释放时被调用。
  bool register(String url, int basePriority, void Function() onReady) {
    // 去重：已在活跃列表或队列中
    if (_activeUrls.contains(url)) return false;
    if (_queue.any((e) => e.url == url)) return false;

    final priority = _computePriority(basePriority);

    if (_activeCount < maxConcurrent) {
      _activeCount++;
      _activeUrls.add(url);
      return true;
    }

    _queue.add(_LoadEntry(url: url, priority: priority, onReady: onReady));
    _queue.sort(); // 保持按优先级升序排列
    return false;
  }

  /// 释放一个槽位（CachedNetworkImage 加载完成/失败后调用）
  void release(String url) {
    if (!_activeUrls.remove(url)) return;
    _activeCount--;
    _drainQueue();
  }

  /// 取消排队（PixivImage dispose 时调用）
  void cancel(String url) {
    if (_activeUrls.remove(url)) {
      _activeCount--;
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

  /// 计算最终优先级：可视范围外加上大偏移量
  int _computePriority(int basePriority) {
    if (basePriority < _visibleStart || basePriority > _visibleEnd) {
      return basePriority + _offScreenOffset;
    }
    return basePriority;
  }

  /// 滚动后重新排序队列中的等待项
  void _reprioritize() {
    if (_queue.isEmpty) return;
    for (final entry in _queue) {
      final rawPriority = entry.priority % _offScreenOffset;
      entry.priority = _computePriority(rawPriority);
    }
    _queue.sort();
  }

  /// 从队列取优先级最高的下一个（index 0，最小 priority），唤醒它
  void _drainQueue() {
    while (_activeCount < maxConcurrent && _queue.isNotEmpty) {
      final entry = _queue.removeAt(0); // 已排序，index 0 优先级最高
      if (_activeUrls.contains(entry.url)) continue;

      _activeCount++;
      _activeUrls.add(entry.url);
      entry.onReady();
    }
  }

  /// 调试用：获取当前活跃数和队列长度
  int get activeCount => _activeCount;
  int get queueLength => _queue.length;
}
