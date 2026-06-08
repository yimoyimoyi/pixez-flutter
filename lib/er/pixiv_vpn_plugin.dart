/// Pixiv VPN MethodChannel 插件 (Flutter 端)
///
/// 通过 MethodChannel 控制 Android VpnService 的启停。
library;

import 'package:flutter/services.dart';

class PixivVpnPlugin {
  static const _channel = MethodChannel('com.perol.dev/pixiv_vpn');

  /// 启动 VPN 服务
  /// 返回 true 表示已启动，"need_permission" 表示需要用户授权
  static Future<dynamic> start() async {
    return await _channel.invokeMethod('start');
  }

  /// 停止 VPN 服务
  static Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  /// 检查是否需要 VPN 权限授权
  static Future<bool> needsPermission() async {
    final result = await _channel.invokeMethod('prepare');
    return result == true;
  }
}
