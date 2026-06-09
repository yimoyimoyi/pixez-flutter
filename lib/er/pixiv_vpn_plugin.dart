/// Pixiv VPN MethodChannel 插件 (Flutter 端)
///
/// 通过 MethodChannel 控制 Android VpnService 的启停。
/// 首次使用需要用户授权 VPN 权限（系统对话框）。
library;

import 'package:flutter/services.dart';
import 'package:pixez/er/lprinter.dart';

class PixivVpnPlugin {
  static const _channel = MethodChannel('com.perol.dev/pixiv_vpn');

  /// 启动 VPN 服务
  /// 返回:
  ///   true               — 已启动
  ///   "permission_requested" — 需要用户授权，await 会等待授权完成
  ///   "permission_denied"    — 用户拒绝了 VPN 权限
  static Future<dynamic> start() async {
    try {
      final result = await _channel.invokeMethod('start');
      LPrinter.d('PixivVpn.start result: $result');
      return result;
    } catch (e) {
      LPrinter.d('PixivVpn.start error: $e');
      return 'error: $e';
    }
  }

  /// 停止 VPN 服务
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
      LPrinter.d('PixivVpn stopped');
    } catch (e) {
      LPrinter.d('PixivVpn.stop error: $e');
    }
  }

  /// 检查是否需要 VPN 权限授权
  static Future<bool> needsPermission() async {
    try {
      final result = await _channel.invokeMethod('prepare');
      return result == true;
    } catch (_) {
      return true;
    }
  }
}
