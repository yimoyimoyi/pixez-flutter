/// 滑动判定工具类
/// 统一 Material 和 Fluent 版本的左右滑动切换逻辑

enum SwipeDirection {
  left,
  right,
  none,
}

class SwipeResult {
  final SwipeDirection direction;
  final bool accepted;

  const SwipeResult(this.direction, this.accepted);

  static const none = SwipeResult(SwipeDirection.none, false);
}

class SwipeEvaluator {
  /// 方向判定倍率（水平/垂直），水平位移需超过垂直位移的此倍率
  final double directionBias;

  /// 最小水平位移（像素），位移需超过此值才可能触发
  final double minHorizontalDistance;

  /// 最小水平速度（像素/秒），快速甩动即使距离短也能触发
  final double minHorizontalVelocity;

  /// 屏幕宽度比例阈值，位移需超过屏幕宽度的此比例
  final double screenWidthRatio;

  const SwipeEvaluator({
    this.directionBias = 1.5,
    this.minHorizontalDistance = 100.0,
    this.minHorizontalVelocity = 500.0,
    this.screenWidthRatio = 0.4,
  });

  /// 评估滑动是否应该触发页面切换
  ///
  /// [totalDx] 累计水平位移
  /// [totalDy] 累计垂直位移
  /// [velocityDx] 水平速度（像素/秒）
  /// [velocityDy] 垂直速度（像素/秒）
  /// [screenWidth] 屏幕宽度
  SwipeResult evaluate({
    required double totalDx,
    required double totalDy,
    required double velocityDx,
    required double velocityDy,
    required double screenWidth,
  }) {
    // 快速甩动判定：速度足够大且水平方向主导
    if (velocityDx.abs() > minHorizontalVelocity &&
        velocityDx.abs() > velocityDy.abs() * directionBias) {
      return velocityDx < 0
          ? const SwipeResult(SwipeDirection.left, true)
          : const SwipeResult(SwipeDirection.right, true);
    }

    // 位移判定：水平位移足够大且水平方向主导
    if (totalDx.abs() > minHorizontalDistance &&
        totalDx.abs() > totalDy.abs() * directionBias) {
      // 进一步检查是否超过屏幕比例阈值
      if (totalDx.abs() > screenWidth * screenWidthRatio) {
        return totalDx < 0
            ? const SwipeResult(SwipeDirection.left, true)
            : const SwipeResult(SwipeDirection.right, true);
      }
    }

    return SwipeResult.none;
  }
}
