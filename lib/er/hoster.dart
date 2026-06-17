import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
    "app-api.pixiv.net": "210.140.139.154",
    "oauth.secure.pixiv.net": "210.140.139.154",
    "i.pximg.net": "210.140.139.133",
    "s.pximg.net": "210.140.139.133",
    "doh": "https://77.88.8.1/dns-query", // Yandex DNS (主)
  };

  /// DoH 备用服务器列表（当前环境可用：Yandex + switch.ch）
  static const _fallbackDohServers = [
    "https://77.88.8.8/dns-query", // Yandex DNS (备)
    "https://130.59.31.248/dns-query", // switch.ch DNS
    "https://130.59.31.251/dns-query", // switch.ch DNS (备)
  ];

  /// Pixiv API 源站 IP 池（2026-06-17 实测 SNI_OFF 可用）
  /// .154/.156-.161：app-api + oauth 均正常
  /// .162：app-api 正常，oauth 超时，移除
  /// .155：已死，移除
  /// .137/.138/.149/.150：API 返回 421，移至图片池
  static const _apiIpPool = [
    '210.140.139.154',
    '210.140.139.156',
    '210.140.139.157',
    '210.140.139.158',
    '210.140.139.159',
    '210.140.139.160',
    '210.140.139.161',
  ];

  /// Pixiv 图片源站 IP 池（2026-06-17 实测 SNI_OFF 可用，全 10 个 OK）
  static const _imageIpPool = [
    '210.140.139.131',
    '210.140.139.132',
    '210.140.139.133',
    '210.140.139.134',
    '210.140.139.135',
    '210.140.139.136',
    '210.140.139.137',
    '210.140.139.138',
    '210.140.139.149',
    '210.140.139.150',
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

  static Dio httpClient = Dio(BaseOptions(baseUrl: 'https://77.88.8.1'));
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
    for (var key in [
      ImageHost,
      ImageSHost,
      'app-api.pixiv.net',
      'oauth.secure.pixiv.net',
    ]) {
      await dnsQuery(key);
    }
  }

  static Future<void> dnsQueryFetcher() async {
    for (var key in [
      ImageHost,
      ImageSHost,
      'app-api.pixiv.net',
      'oauth.secure.pixiv.net',
    ]) {
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
      final answers = model.answer.toList();
      answers.sort((l, r) => r.ttl.compareTo(l.ttl));
      // 收集所有有效 IPv4 地址
      final ips = answers
          .map((a) => a.data)
          .where((ip) =>
              ip.contains('.') &&
              ip.split('.').every((e) => int.tryParse(e) != null))
          .toList();
      if (ips.isNotEmpty) {
        _map[name] = ips.join(',');
        Prefer.setString('h_hoster_$name', ips.join(','));
      }
      LPrinter.d(ips.join(','));
    } catch (e) {
      LPrinter.d(e);
    }
  }

  /// 获取指定域名的动态缓存 IP 列表（逗号分隔），与 _constMap 值格式兼容
  static List<String> cachedIps(String host) {
    final result = _map[host] as String?;
    if (result == null || result.isEmpty) {
      final fallback = _constMap[host] as String?;
      if (fallback == null || fallback.isEmpty) return [];
      return fallback.split(',');
    }
    return result.split(',');
  }

  /// TCP 443 端口探测，筛出可连通的 IP（无须代理无须 DNS）
  static Future<List<String>> tcpProbe(
    List<String> ips, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final alive = <String>[];
    await Future.wait(ips.map((ip) async {
      try {
        final s = await Socket.connect(ip, 443, timeout: timeout);
        await s.close();
        alive.add(ip);
      } catch (_) {}
    }));
    return alive;
  }

  /// 通过代理预热 DNS 缓存（供 compat 模式无代理时使用）
  static Future<void> warmUpDns(String proxyHost, int proxyPort) async {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 5);
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (url) => 'PROXY $proxyHost:$proxyPort';
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );

    final servers = [
      (_map["doh"] as String?) ?? _constMap["doh"] as String,
      ..._fallbackDohServers,
    ];

    for (final host in [
      'app-api.pixiv.net',
      'oauth.secure.pixiv.net',
      ImageHost,
      ImageSHost,
    ]) {
      for (final server in servers) {
        try {
          final resp = await dio.get(
            server,
            queryParameters: {'name': host, 'type': 'A'},
            options: Options(headers: {'accept': 'application/dns-json'}),
          );
          final model = OnezeroResponse.fromJson(jsonDecode(resp.data));
          if (model.answer.isNotEmpty) {
            final ips = model.answer
                .map((a) => a.data)
                .where((ip) =>
                    ip.contains('.') &&
                    ip.split('.').every((e) => int.tryParse(e) != null))
                .toList();
            if (ips.isNotEmpty) {
              _map[host] = ips.join(',');
              Prefer.setString('h_hoster_$host', ips.join(','));
              LPrinter.d('warmUpDns $host -> ${ips.join(",")}');
            }
            break;
          }
        } catch (e) {
          LPrinter.d('warmUpDns $server for $host: $e');
          continue;
        }
      }
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
