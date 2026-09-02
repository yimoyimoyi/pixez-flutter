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
        tlsSettings: r.TlsSettings(
          verifyCertificates: true,
          rootCertSource: r.RootCertSource.webpki,
          sni: true,
        ),
        // ECH 模式保活：切后台一段时间后 NAT/服务端会断开空闲连接，
        // 回来时首请求会撞死连接卡顿。keepAlive 只作用于已建立的空闲
        // 连接（TCP keepalive + HTTP/2 PING），不影响首连与慢请求
        timeoutSettings: r.TimeoutSettings(
          // 保底超时（区别于 compatible 模式的回滚教训——该语义针对
          // 图片慢连接与息屏在途请求，而此处只覆盖 ECH 直连 API 的
          // 建连/握手/响应头真空段）：切网、黑洞、半死连接下把"挂起"
          // 变成可重试的失败。正常 ECH 直连 <1s，总预算 5s + 拦截器
          // 1 次重试 → 端到端最坏 ~10s 收敛（不再 2~10 分钟无声转圈）
          timeout: const Duration(seconds: 5),
          // TCP 建连单独收紧：SYN 黑洞 3s 判死，不吞总预算
          connectTimeout: const Duration(seconds: 3),
          keepAliveTimeout: const Duration(seconds: 60),
          keepAlivePing: const Duration(seconds: 25),
        ),
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

  static r.ClientSettings? forImages(String? host, NetworkMode mode) {
    if (mode == NetworkMode.standard) return null;
    if (host != imageHost) return null;
    return compatible();
  }

  static r.ClientSettings compatible() {
    return r.ClientSettings(
      // 注意：不设置 timeoutSettings（曾尝试总超时/连接超时，带来两个
      // 回归后回滚）：① connectTimeout 误杀慢连接（推荐画师头像不加载）；
      // ② 总超时导致临时息屏（>2 分钟）后挂起的在途请求直接失败。
      // 挂起兜底由 dio 层 receiveTimeout（30s chunk 间隔）+ 图片组件
      // _scheduleRetry 退避重试承担
      tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
      httpVersionPref: r.HttpVersionPref.http1_1,
      dnsSettings: r.DnsSettings.dynamic(
        resolver: (host) async {
          try {
            // 第 1 层：硬编码 IP 池（实测可用，最快）。
            // 探测结果带 TTL 缓存，避免每个请求重复探测
            final pool = _poolFor(host);
            var poolFailed = false;
            if (pool.isNotEmpty) {
              final alive = await Hoster.tcpProbeCached(pool);
              if (alive.isNotEmpty) {
                // 按快速测速结果排序：优先返回低延迟 IP
                //（reqwest 按返回顺序尝试连接，首个存活即被使用）
                return Hoster.orderedIps(host, alive);
              }
              // 池全部探测失败：记录状态，第 2 层不再过滤池成员——
              // pixiv 源站 IP 集中在同一 C 段，池死不代表 DoH 缓存中
              // 的同段 IP 也死；原实现按"池成员"过滤会把存活 IP 一并
              // 滤掉，导致直接落入被污染的系统 DNS
              poolFailed = true;
            }

            // 第 2 层：DoH 动态缓存（跨代理预热，自动适应 IP 迁移）。
            // 仅当池探测存活（不会走到这）或池为空时排除池成员；
            // 池全部失败时保留全部 DoH 缓存 IP 参与探测
            final cached = Hoster.cachedIps(host)
                .where((ip) => poolFailed || !pool.contains(ip))
                .toList();
            if (cached.isNotEmpty) {
              // 与第 3 层系统 DNS 并行：最坏延迟从串行 ~4s 降至 ~2s
              final results = await Future.wait([
                Hoster.tcpProbeCached(cached),
                _systemLookup(host),
              ]);
              if (results[0].isNotEmpty) {
                // 按快速测速结果排序（同上）
                return Hoster.orderedIps(host, results[0]);
              }
              if (results[1].isNotEmpty) return results[1];
              return const [];
            }

            // 第 3 层：系统 DNS（无 DoH 缓存时）
            return _systemLookup(host);
          } catch (_) {
            // 断网/切换网络时系统 DNS 解析会抛 SocketException。
            // 绝不能把异常抛给 rhttp：frb 会将 Dart 异常回传给 Rust 侧
            // 生成代码的 ans.expect(...) 触发 Rust panic（Android 原生层
            // abort → app 闪退）。返回空列表，由 rhttp 报连接错误
            //（走正常 DioException 路径）。
            return const [];
          }
        },
      ),
    );
  }

  /// 系统 DNS 解析（带异常兜底：断网抛 SocketException 时返回空）
  static Future<List<String>> _systemLookup(String host) async {
    try {
      final v = await InternetAddress.lookup(host);
      return v.map((e) => e.address).toList();
    } catch (_) {
      return const [];
    }
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
