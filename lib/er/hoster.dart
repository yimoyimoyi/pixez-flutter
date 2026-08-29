import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:pixez/constants.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/onezero_response.dart';
import 'package:rhttp/rhttp.dart' as r;

/// TCP 探测结果缓存条目（TTL 按结果类型区分：非空 5 分钟/空 30 秒）
class _ProbeCacheEntry {
  final DateTime time;
  final List<String> alive;
  final Duration ttl;
  _ProbeCacheEntry(this.time, this.alive, this.ttl);
}

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

  /// Pixiv API 源站 IP 池（2026-08-30 综合更新）：
  /// - 用户网络直连实测（PixivToolkit 08-23）：161/151/162/157/153/154
  ///   可用，延迟 115-146ms → 新增 151/153/162
  /// - 池中原有 156/158/159/160 保留（06-17 实测正常；app-api 与
  ///   www.pixiv.net 解析集不同，用户环境工作正常）
  /// 2026-08-30 核查：Google DoH 解析 app-api 已指向 Cloudflare
  /// （104.18.42.239/172.64.145.17），但实测 SNI off（compat 模式）下
  /// Cloudflare 在 TLS 层直接拒绝（SEC_E_ILLEGAL_MESSAGE），不可入池；
  /// 代理出口探测本池 IP 均为 HTTP 421（出口 IP 信誉问题，非 IP 死亡）
  static const _apiIpPool = [
    '210.140.139.161',
    '210.140.139.151',
    '210.140.139.162',
    '210.140.139.157',
    '210.140.139.153',
    '210.140.139.154',
    '210.140.139.156',
    '210.140.139.158',
    '210.140.139.159',
    '210.140.139.160',
  ];

  /// Pixiv 图片源站 IP 池（2026-08-30 综合更新）：
  /// - 用户网络直连实测（PixivToolkit 08-23）：135/134/150/149/132/
  ///   136/137/131/133 可用，延迟 115-143ms
  /// - Google DoH 权威解析（08-30）：129-138（129/130 为 DNS 新增）
  /// - 149/150 已从 DNS 移除但物理可用（硬编码池不依赖 DNS，保留）；
  ///   129/130 为 DNS 新增（保留，等待实测确认）
  /// 按实测延迟排序（并行探测不受池大小影响）
  static const _imageIpPool = [
    '210.140.139.135',
    '210.140.139.134',
    '210.140.139.150',
    '210.140.139.149',
    '210.140.139.132',
    '210.140.139.136',
    '210.140.139.137',
    '210.140.139.131',
    '210.140.139.133',
    '210.140.139.129',
    '210.140.139.130',
    '210.140.139.138',
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

  static Dio httpClient = Dio(BaseOptions(baseUrl: 'https://1dot1dot1dot1.cloudflare-dns.com'));

  /// 共享的 DoH 客户端创建 Future：并发/重复调用只创建一次 rhttp client。
  /// 每次调用都新建 client 会反复替换 adapter，旧 client 无人 close 造成
  /// 资源泄漏（每次启动 dnsQueryAll 即泄漏 3 个）。
  static Future<Dio>? _dohClientFuture;

  static Future<Dio> createDioClient() {
    return _dohClientFuture ??= _createDohClient().catchError((Object e) {
      // 创建失败时重置，允许后续调用重试（避免永久持有 failed Future）
      _dohClientFuture = null;
      throw e;
    });
  }

  static Future<Dio> _createDohClient() async {
    final compatibleClient = await r.RhttpCompatibleClient.create(
      settings: r.ClientSettings(
        dnsSettings: r.DnsSettings.static(
          overrides: {
            "1dot1dot1dot1.cloudflare-dns.com": ['104.16.248.249', '104.16.249.249'],
          },
        ),
      ),
    );
    try {
      httpClient.httpClientAdapter.close(force: true);
    } catch (_) {}
    httpClient.httpClientAdapter = ConversionLayerAdapter(compatibleClient);
    return httpClient;
  }

  static Future<void> dnsQueryAll() async {
    // 顺带预热 IP 测速（fire-and-forget，不阻塞 DoH 查询）：
    // 启动后 ~1s 内完成测速，首次请求即可使用排序结果
    prewarmLatency();
    for (var key in [
      ImageHost,
      ImageSHost,
      'app-api.pixiv.net',
      'oauth.secure.pixiv.net',
    ]) {
      await dnsQuery(key);
    }
  }

  /// 后台 isolate 预热入口（逻辑与 [dnsQueryAll] 完全相同，
  /// 统一委托避免重复实现）
  static Future<void> dnsQueryFetcher() => dnsQueryAll();

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
    // DoH 已禁用：跳过查询，直接使用硬编码 IP 池
    if (userSetting.disableDoh) return;
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
          // 直接请求绝对 URL（备用服务器为完整 URL 含 /dns-query 路径）：
          // 不修改共享 httpClient 的 baseUrl，避免并发请求互相覆盖。
          // 原实现恒用主服务器 baseUrl，Yandex/switch.ch 备用服务器
          // 永远不生效
          final queryUrl =
              server.contains('/dns-query') ? server : '$server/dns-query';
          Response response = await httpClient.get(
            queryUrl,
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

  /// 是否已有动态缓存（不含硬编码常量池回退）。
  /// 用于区分"预热是否真正生效"（cachedIps 会回退到常量池导致恒非空）
  static bool hasDynamicCache(String host) => _map[host] != null;

  /// TCP 443 端口探测，筛出可连通的 IP（无须代理无须 DNS）
  static Future<List<String>> tcpProbe(
    List<String> ips, {
    Duration timeout = const Duration(milliseconds: 600),
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

  /// TCP 探测结果缓存：同一 IP 组合在 TTL 内不重复探测。
  /// 解决瀑布流滚动时每个请求都做 7~17 次探测的问题；
  /// 网络故障时的空结果被短 TTL 缓存，避免每次请求都阻塞等待探测超时
  ///（且断网恢复后能快速重新探测，避免"5 分钟直连假死"）。
  static final Map<String, _ProbeCacheEntry> _probeCache = {};
  /// 非空结果 TTL：5 分钟
  static const Duration _probeCacheTtl = Duration(minutes: 5);
  /// 空结果（探测全失败）短 TTL：30 秒——断网/切网恢复后能快速重探
  static const Duration _probeCacheEmptyTtl = Duration(seconds: 30);
  static const int _probeCacheMaxEntries = 64;
  /// in-flight 探测去重：缓存 miss 期间并发请求共享同一次探测，
  /// 避免首屏 N 个请求各自发起完整探测（探测风暴）
  static final Map<String, Future<List<String>>> _inflight = {};

  /// IP 延迟测速缓存：host → (按延迟升序排序的 IP, 测速时间)。
  /// 快速测速结果用于 resolver 优先返回快 IP（reqwest 按返回顺序
  /// 尝试连接，首个存活 IP 即被使用）
  static final Map<String, (List<String>, DateTime)> _latencyCache = {};
  /// 测速结果缓存 TTL：30 分钟——期间零测速开销；
  /// 过期后复用旧排序并后台刷新（懒触发，不阻塞请求路径）
  static const Duration _latencyTtl = Duration(minutes: 30);
  /// 测速 in-flight 去重：并发 miss 只触发一次测速
  static final Map<String, Future<void>> _latencyInflight = {};

  /// 后台触发一次测速刷新（带 in-flight 去重，不阻塞调用方）
  static void _refreshLatency(String host, List<String> ips) {
    if (_latencyInflight.containsKey(host)) return;
    final future = measureLatency(ips).then((sorted) {
      if (sorted.isNotEmpty) {
        _latencyCache[host] = (sorted, DateTime.now());
      }
    });
    _latencyInflight[host] = future;
    future.whenComplete(() => _latencyInflight.remove(host));
  }

  /// 快速测速：并行测量各 IP 的 TCP 443 连接延迟（毫秒），
  /// 按延迟升序返回可达 IP（不可达 IP 排除）。
  /// 轻量：单个超时 1s，并行执行，不阻塞调用方
  static Future<List<String>> measureLatency(
    List<String> ips, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final results = await Future.wait(ips.map((ip) async {
      final sw = Stopwatch()..start();
      try {
        final s = await Socket.connect(ip, 443, timeout: timeout);
        await s.close();
        return (ip, sw.elapsedMilliseconds);
      } catch (_) {
        return (ip, -1);
      }
    }));
    final alive = results.where((r) => r.$2 >= 0).toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    return alive.map((r) => r.$1).toList();
  }

  /// 获取测速排序后的 IP 列表：
  /// - 缓存 TTL 内命中：直接返回排序结果（零开销）
  /// - 过期但有历史排序：复用旧排序并后台重测（下次请求用新结果）
  /// - 无历史（首次）：返回原顺序（不阻塞请求路径）+ 后台首次测速
  static List<String> orderedIps(String host, List<String> ips) {
    if (ips.isEmpty) return ips;
    final entry = _latencyCache[host];
    if (entry != null) {
      if (DateTime.now().difference(entry.$2) < _latencyTtl) {
        return entry.$1;
      }
      _refreshLatency(host, ips);
      return entry.$1;
    }
    _refreshLatency(host, ips);
    return ips;
  }

  /// 启动预热：对 API/图片池各测速一次，写入 4 个域名缓存。
  /// 首次请求即可用排序结果（无需等待懒触发）
  static void prewarmLatency() {
    Future<void> warm(List<String> pool, List<String> hosts) async {
      final sorted = await measureLatency(pool);
      if (sorted.isNotEmpty) {
        final now = DateTime.now();
        for (final h in hosts) {
          _latencyCache[h] = (sorted, now);
        }
      }
    }

    // 按池去重：api/oauth 共用 API 池，i.pximg/s.pximg 共用图片池
    warm(_apiIpPool.toList(),
        ['app-api.pixiv.net', 'oauth.secure.pixiv.net']);
    warm(_imageIpPool.toList(), [ImageHost, ImageSHost]);
  }

  /// 带缓存的探测（结果与 IP 顺序无关）
  static Future<List<String>> tcpProbeCached(
    List<String> ips, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (ips.isEmpty) return const [];
    final key = ([...ips]..sort()).join(',');
    final entry = _probeCache[key];
    if (entry != null && DateTime.now().difference(entry.time) < entry.ttl) {
      return entry.alive;
    }
    // in-flight 去重：已有同组合探测在途则直接等待其结果
    final inFlight = _inflight[key];
    if (inFlight != null) return inFlight;
    final future = _doProbe(key, ips, timeout);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<List<String>> _doProbe(
      String key, List<String> ips, Duration timeout) async {
    final alive = await tcpProbe(ips, timeout: timeout);
    if (_probeCache.length >= _probeCacheMaxEntries) {
      _probeCache.clear(); // 超限整体清空，简单防膨胀
    }
    _probeCache[key] = _ProbeCacheEntry(
      DateTime.now(),
      alive,
      // 空结果短 TTL：断网恢复后快速重探；非空维持 5 分钟
      alive.isEmpty ? _probeCacheEmptyTtl : _probeCacheTtl,
    );
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
