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
          // 优先使用预配置的源站 IP 池（参考 Pixiv-Nginx）
          final ips = _compatibleIps(host);
          if (ips.isNotEmpty) return ips;
          // 回退到 DNS 缓存结果
          final cached = _compatibleCachedIp(host);
          if (cached != null) return [cached];
          // 最后走系统 DNS
          return await InternetAddress.lookup(
            host,
          ).then((value) => value.map((e) => e.address).toList());
        },
      ),
    );
  }

  /// 返回源站 IP 池（多 IP，参考 Pixiv-Nginx upstream）
  static List<String> _compatibleIps(String host) {
    if (host == appApiHost || host == oauthHost || host == accountHost) {
      return Hoster.apiPool();
    }
    if (host == imageHost || host == imageStaticHost) {
      return Hoster.imagePool();
    }
    return const [];
  }

  /// 返回 DNS 缓存的单个 IP（回退用）
  static String? _compatibleCachedIp(String host) {
    if (host == appApiHost) return Hoster.api();
    if (host == oauthHost) return Hoster.oauth();
    if (host == imageHost) return Hoster.iPximgNet();
    if (host == imageStaticHost) return Hoster.sPximgNet();
    return null;
  }
}
