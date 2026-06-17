import 'dart:io';

import 'package:pixez/er/hoster.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:rhttp/rhttp.dart' as r;

class PixezNetworkSettings {
  static const appApiHost = 'app-api.pixiv.net';
  static const oauthHost = 'oauth.secure.pixiv.net';
  static const accountHost = 'accounts.pixiv.net';
  static const imageHost = 'i.pximg.net';
  static const imageStaticHost = 's.pximg.net';
  static const visionHost = 'www.pixivision.net';

  static r.ClientSettings? forHost(String host, NetworkMode mode) {
    if (mode == NetworkMode.standard) return null;
    if (host == appApiHost && mode == NetworkMode.ech) {
      return r.ClientSettings(
        enableEch: true,
        requireEch: true,
        tlsSettings: r.TlsSettings(verifyCertificates: false, sni: true),
        dnsSettings: r.DnsSettings.static(
          overrides: {
            appApiHost: ['104.18.10.118', '104.18.11.118'],
          },
        ),
      );
    }
    return compatible();
  }

  /// [pictureSource] 可选，用于子 Isolate 场景传入正确的图床地址。
  /// 不传则读取全局 [userSetting.pictureSource]（仅主 Isolate 有效）。
  static r.ClientSettings? forImages(NetworkMode mode, {String? pictureSource}) {
    if (mode == NetworkMode.standard) return null;
    final source = pictureSource ?? userSetting.pictureSource;
    if (source != imageHost) return null;
    return compatible();
  }

  static r.ClientSettings compatible() {
    return r.ClientSettings(
      tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
      dnsSettings: r.DnsSettings.dynamic(
        resolver: (host) async {
          // 优先使用 DoH 动态缓存的 IP 池（能自动适应 Pixiv 服务器迁移）
          final cachedIps = _compatibleCachedIps(host);
          if (cachedIps.isNotEmpty) return cachedIps;
          // 源站硬编码 IP 池作为静态备用
          final poolIps = _compatibleIps(host);
          if (poolIps.isNotEmpty) return poolIps;
          // 最后走系统 DNS
          return await InternetAddress.lookup(
            host,
          ).then((value) => value.map((e) => e.address).toList());
        },
      ),
    );
  }

  /// 返回 DoH 动态缓存的 IP 列表（可能为空）
  static List<String> _compatibleCachedIps(String host) {
    return Hoster.cachedIps(host);
  }

  /// 返回源站 IP 池（多 IP，参考 Pixiv-Nginx upstream）
  static List<String> _compatibleIps(String host) {
    if (host == appApiHost || host == oauthHost || host == accountHost) {
      return Hoster.apiPool();
    }
    if (host == visionHost) {
      // .137/.138/.149/.150 对 pixivision 返回 421，只使用前 9 个已验证 IP
      return Hoster.apiPool().take(9).toList();
    }
    if (host == imageHost || host == imageStaticHost) {
      return Hoster.imagePool();
    }
    return const [];
  }
}
