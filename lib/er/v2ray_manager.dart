/// flutter_v2ray 管理器
///
/// 管理 V2Ray 生命周期，与 LoginProxy 配合使用。
library;

import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:pixez/er/lprinter.dart';

class V2RayManager {
  static FlutterV2ray? _instance;

  static bool get isRunning => _instance != null;

  /// 初始化并启动 V2Ray VPN
  /// [config] V2Ray JSON 配置字符串
  /// [onStatus] 状态变更回调
  static Future<bool> start({
    required String config,
    void Function(V2RayStatus status)? onStatus,
  }) async {
    try {
      _instance = FlutterV2ray(
        onStatusChanged: (status) {
          LPrinter.d('V2Ray status: ${status.state}');
          onStatus?.call(status);
        },
      );

      await _instance!.initializeV2Ray();
      LPrinter.d('V2Ray initialized');

      final permission = await _instance!.requestPermission();
      LPrinter.d('V2Ray permission: $permission');

      if (!permission) return false;

      await _instance!.startV2Ray(
        remark: 'PixEz',
        config: config,
        proxyOnly: false,
      );
      LPrinter.d('V2Ray started');
      return true;
    } catch (e) {
      LPrinter.d('V2Ray start error: $e');
      _instance = null;
      return false;
    }
  }

  /// 停止 V2Ray
  static Future<void> stop() async {
    try {
      await _instance?.stopV2Ray();
    } catch (e) {
      LPrinter.d('V2Ray stop error: $e');
    }
    _instance = null;
  }
}
