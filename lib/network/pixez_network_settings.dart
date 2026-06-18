import 'dart:io';

import 'package:pixez/er/hoster.dart';
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
    if (mode == NetworkMode.ech) {
      return r.ClientSettings(
        enableEch: true,
        requireEch: true,
        httpVersionPref: r.HttpVersionPref.http1_1,
        tlsSettings: r.TlsSettings(verifyCertificates: false, sni: true),
        dnsSettings: r.DnsSettings.static(
          overrides: {
            appApiHost: ['104.18.10.118', '104.18.11.118'],
            oauthHost: ['104.18.10.118', '104.18.11.118'],
            accountHost: ['104.18.10.118', '104.18.11.118'],
          },
        ),
      );
    }
    return compatible();
  }

  static r.ClientSettings? forImages(NetworkMode mode, {String? pictureSource}) {
    if (mode == NetworkMode.standard) return null;
    return compatible();
  }

  static r.ClientSettings compatible() {
    return r.ClientSettings(
      tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
      httpVersionPref: r.HttpVersionPref.http1_1,
      dnsSettings: r.DnsSettings.dynamic(
        resolver: (host) async {
          // 第 1 层：硬编码 IP 池（实测可用，最快）
          final pool = _poolFor(host);
          if (pool.isNotEmpty) {
            final alive = await Hoster.tcpProbe(pool);
            if (alive.isNotEmpty) return alive;
          }

          // 第 2 层：DoH 动态缓存（跨代理预热，自动适应 IP 迁移）
          final cached = Hoster.cachedIps(host);
          if (cached.isNotEmpty) {
            final alive = await Hoster.tcpProbe(cached);
            if (alive.isNotEmpty) return alive;
          }

          // 第 3 层：系统 DNS
          return await InternetAddress.lookup(host)
              .then((v) => v.map((e) => e.address).toList());
        },
      ),
    );
  }

  /// 从硬编码池返回候选 IP（仅已知域名）
  static List<String> _poolFor(String host) {
    if (host == appApiHost || host == oauthHost || host == accountHost || host == visionHost) {
      return Hoster.apiPool();
    }
    if (host == imageHost || host == imageStaticHost) {
      return Hoster.imagePool();
    }
    return const [];
  }
}
