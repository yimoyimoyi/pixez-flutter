import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/onezero_response.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

class Hoster {
  static Map<String, dynamic> _map = Map();
  static Map<String, dynamic> _constMap = {
    "app-api.pixiv.net": "210.140.139.155",
    "oauth.secure.pixiv.net": "210.140.139.155",
    "i.pximg.net": "210.140.139.133",
    "s.pximg.net": "210.140.139.133",
    "doh": "https://77.88.8.1/dns-query", // Yandex DNS (主)
  };

  /// DoH 备用服务器列表（参考 weiss 2026 update）
  static const _fallbackDohServers = [
    "https://77.88.8.8/dns-query", // Yandex DNS (备)
    "https://130.59.31.248/dns-query", // switch.ch DNS
    "https://130.59.31.251/dns-query", // switch.ch DNS (备)
    "https://119.29.29.29/dns-query", // Tencent DNS (Pixiv-Nginx)
  ];

  /// Pixiv API 源站 IP 池（参考 Pixiv-Nginx www-pixiv-net upstream）
  static const _apiIpPool = [
    '210.140.139.154',
    '210.140.139.155',
    '210.140.139.156',
    '210.140.139.157',
    '210.140.139.158',
    '210.140.139.159',
    '210.140.139.160',
    '210.140.139.161',
    '210.140.139.162',
  ];

  /// Pixiv 图片源站 IP 池（参考 Pixiv-Nginx i-pximg-net upstream）
  static const _imageIpPool = [
    '210.140.92.141',
    '210.140.92.142',
    '210.140.92.143',
    '210.140.92.144',
    '210.140.92.145',
    '210.140.92.146',
    '210.140.92.148',
    '210.140.92.149',
    '210.140.139.131',
    '210.140.139.132',
    '210.140.139.133',
    '210.140.139.134',
    '210.140.139.135',
    '210.140.139.136',
  ];
  static Map<String, dynamic> hardMap() {
    return _map.isEmpty ? _constMap : _map;
  }

  /// API 源站 IP 池（用于 rhttp DNS 多 IP 解析）
  static List<String> apiPool() => List.unmodifiable(_apiIpPool);

  /// 图片源站 IP 池
  static List<String> imagePool() => List.unmodifiable(_imageIpPool);

  static final List<String> QUERY_HOST = [
    ImageHost,
    ImageSHost,
    'app-api.pixiv.net',
    'oauth.secure.pixiv.net',
  ];

  static Dio httpClient = Dio(BaseOptions(baseUrl: 'https://1.1.1.1'));
  static r.RhttpCompatibleClient? compatibleClient;

  static Future<Dio> createDioClient() async {
    if (compatibleClient == null) {
      return httpClient;
    }
    compatibleClient ??= await r.RhttpCompatibleClient.create(
      settings: userSetting.networkMode.usesCompatibleConnection
          ? PixezNetworkSettings.compatible()
          : null,
    );
    httpClient.httpClientAdapter = ConversionLayerAdapter(compatibleClient!);
    return httpClient;
  }

  static Future<void> dnsQueryAll() async {
    for (var key in [ImageHost, ImageSHost]) {
      await dnsQuery(key);
    }
  }

  static Future<void> dnsQueryFetcher() async {
    for (var key in [ImageHost, ImageSHost]) {
      await dnsQuery(key);
    }
  }

  static Future<void> initMap() async {
    try {
      for (var key in QUERY_HOST) {
        final value = Prefer.getString('h_hoster_$key');
        if (value != null) {
          _map[key] = value;
        }
      }
    } catch (e) {
      LPrinter.d(e);
    }
  }

  static Future<void> dnsQuery(String name) async {
    try {
      await createDioClient();
      // 遍历 DoH 服务器列表查询 DNS
      final servers = [
        (_map["doh"] as String?) ?? _constMap["doh"] as String,
        ..._fallbackDohServers,
      ];
      OnezeroResponse? model;
      for (final server in servers) {
        try {
          Response response = await httpClient.get(
            '/dns-query',
            options: Options(headers: {'accept': 'application/dns-json'}),
            queryParameters: {'name': name},
          );
          final res = OnezeroResponse.fromJson(jsonDecode(response.data));
          if (res.answer.isNotEmpty) {
            model = res;
            break;
          }
        } catch (e) {
          LPrinter.d("DoH $server failed: $e");
          continue;
        }
      }
      // 所有 DoH 都失败则回退到空结果（使用硬编码 IP）
      if (model == null) {
        model = OnezeroResponse.fromJson({"Answer": []});
      }
      final answer = model.answer.toList();
      answer.sort((l, r) => r.ttl.compareTo(l.ttl));
      final host = answer.first.data;
      if (host.contains('.')) {
        final num = host.split('.');
        bool allNum = num.every((element) => int.tryParse(element) != null);
        if (allNum) {
          _map[name] = host;
          Prefer.setString('h_hoster_$name', host);
        }
      }
      LPrinter.d(host);
    } catch (e) {
      LPrinter.d(e);
    }
  }

  static String iPximgNet() {
    final key = "i.pximg.net";
    final result = _map[key];
    if (result == null) return _constMap[key];
    return result;
  }

  static String sPximgNet() {
    final key = "s.pximg.net";
    final result = _map[key];
    if (result == null) return _constMap[key];
    return result;
  }

  static String doh() {
    final key = "doh";
    final result = _map[key];
    if (result == null) return _constMap[key];
    return result;
  }

  static String oauth() {
    final key = "oauth.secure.pixiv.net";
    final result = _map[key];
    if (result == null) return _constMap[key];
    return result;
  }

  static String api() {
    final key = "app-api.pixiv.net";
    final result = _map[key];
    if (result == null) return _constMap[key];
    return result;
  }

  static String host(String url) {
    return splashStore.host;
  }

  static Map<String, String> header({String? url}) {
    Map<String, String> map = {
      "referer": "https://app-api.pixiv.net/",
      "User-Agent": "PixivIOSApp/5.8.0",
    };
    return map;
  }
}
