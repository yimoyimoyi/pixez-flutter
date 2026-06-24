/// 滑动相关常量定义
/// 集中管理所有滑动判定阈值，便于调整和维护

class SwipeConstants {
  /// 方向判定倍率：水平位移需超过垂直位移的此倍率
  static const double directionBias = 1.5;

  /// 最小水平位移（像素）
  static const double minSwipeDistance = 100.0;

  /// 最小水平速度（像素/秒）
  static const double minSwipeVelocity = 500.0;

  /// 屏幕宽度比例阈值
  static const double screenWidthRatio = 0.4;

  /// bounceBack 动画时长（毫秒）
  static const int bounceBackDurationMs = 150;

  /// bounceBack 动画曲线
  static const String bounceBackCurve = 'easeInOut';
}
