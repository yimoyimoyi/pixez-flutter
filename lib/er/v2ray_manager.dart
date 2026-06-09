/// flutter_v2ray 管理器
library;

import 'package:flutter_v2ray/flutter_v2ray.dart';

class V2RayManager {
  static FlutterV2ray? _instance;

  static bool get isRunning => _instance != null;

  static Future<bool> start({
    required String config,
    void Function(V2RayStatus status)? onStatus,
  }) async {
    try {
      print('[V2Ray] Creating instance...');
      _instance = FlutterV2ray(
        onStatusChanged: (status) {
          print('[V2Ray] Status: ${status.state}');
          onStatus?.call(status);
        },
      );

      print('[V2Ray] Initializing...');
      await _instance!.initializeV2Ray();
      print('[V2Ray] Initialized');

      print('[V2Ray] Requesting permission...');
      final permission = await _instance!.requestPermission();
      print('[V2Ray] Permission result: $permission');

      if (!permission) {
        print('[V2Ray] Permission denied');
        _instance = null;
        return false;
      }

      print('[V2Ray] Starting with config: ${config.length} chars');
      await _instance!.startV2Ray(
        remark: 'PixEz',
        config: config,
        proxyOnly: false,
      );
      print('[V2Ray] Started successfully');
      return true;
    } catch (e, s) {
      print('[V2Ray] Error: $e');
      print('[V2Ray] Stack: $s');
      _instance = null;
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      print('[V2Ray] Stopping...');
      await _instance?.stopV2Ray();
      print('[V2Ray] Stopped');
    } catch (e) {
      print('[V2Ray] Stop error: $e');
    }
    _instance = null;
  }
}
