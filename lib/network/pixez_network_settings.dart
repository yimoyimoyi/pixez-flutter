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
    if (host == appApiHost && mode == NetworkMode.ech) {
      return r.ClientSettings(
        enableEch: true,
        requireEch: true,
        httpVersionPref: r.HttpVersionPref.http1_1,
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

  static r.ClientSettings? forImages(NetworkMode mode, {String? pictureSource}) {
    if (mode == NetworkMode.standard) return null;
    return compatible();
  }

  static r.ClientSettings compatible() {
    return r.ClientSettings(
      tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
      httpVersionPref: r.HttpVersionPref.http1_1,
      dnsSettings: r.DnsSettings.static(
        overrides: {
          appApiHost: Hoster.apiPool(),
          oauthHost: Hoster.apiPool(),
          accountHost: Hoster.apiPool(),
          imageHost: Hoster.imagePool(),
          imageStaticHost: Hoster.imagePool(),
          visionHost: Hoster.apiPool(),
        },
      ),
    );
  }
}
