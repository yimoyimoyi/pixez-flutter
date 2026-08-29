import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';

void main() {
  group('PixezNetworkSettings.forHost', () {
    test('ECH 模式启用 ECH 并配置 keep-alive 保活（T4）', () {
      final s = PixezNetworkSettings.forHost(
        PixezNetworkSettings.appApiHost,
        NetworkMode.ech,
      );
      expect(s, isNotNull);
      expect(s!.enableEch, isTrue);
      expect(s.requireEch, isTrue);
      // T4：切后台回来不再撞死连接卡顿
      expect(s.timeoutSettings, isNotNull);
      expect(
        s.timeoutSettings!.keepAliveTimeout,
        const Duration(seconds: 60),
      );
      expect(s.timeoutSettings!.keepAlivePing, const Duration(seconds: 25));
      // 仅 ECH 分支有保活；timeout/connectTimeout 保持未设置（避免
      // 历史回归：connectTimeout 误杀慢连接、总超时挂起在途请求）
      expect(s.timeoutSettings!.timeout, isNull);
      expect(s.timeoutSettings!.connectTimeout, isNull);
    });

    test('compat 模式不设置超时（保活仅作用于 ECH 分支）', () {
      final s = PixezNetworkSettings.forHost(
        PixezNetworkSettings.appApiHost,
        NetworkMode.compat,
      );
      expect(s, isNotNull);
      expect(s!.timeoutSettings, isNull);
    });

    test('standard 模式返回 null', () {
      expect(
        PixezNetworkSettings.forHost(
          PixezNetworkSettings.appApiHost,
          NetworkMode.standard,
        ),
        isNull,
      );
    });
  });

  group('PixezNetworkSettings.forImages', () {
    test('ECH 模式下图片域走 compatible（无 ECH、无保活）', () {
      final s = PixezNetworkSettings.forImages(
        PixezNetworkSettings.imageHost,
        NetworkMode.ech,
      );
      expect(s, isNotNull);
      expect(s!.enableEch, isFalse);
      expect(s.timeoutSettings, isNull);
    });

    test('非图片域返回 null', () {
      expect(
        PixezNetworkSettings.forImages('example.com', NetworkMode.ech),
        isNull,
      );
    });
  });
}
