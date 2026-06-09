/// V2Ray 配置生成器
///
/// 生成无节点 V2Ray 配置：
/// - TUN 入口（VPN 模式）
/// - freedom outbound（直连）
/// - HTTP outbound → LoginProxy:9876（Pixiv 流量）
/// - DNS 使用标准公共 DNS
library;

import 'dart:convert';

class V2RayConfig {
  /// 生成 V2Ray JSON 配置字符串
  /// [proxyPort] LoginProxy 的 HTTP 端口（默认 9876）
  /// [directDns] 非 Pixiv 域名使用的 DNS
  static String generate({int proxyPort = 9876, String directDns = '1.1.1.1'}) {
    final config = {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'tun-in',
          'protocol': 'tun',
          'settings': {
            'dev': 'tun0',
            'mtu': 1500,
            'gateway': '10.0.0.1',
            'dns': '1.1.1.1',
          },
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls'],
          },
        },
        {
          'tag': 'dns-in',
          'protocol': 'dokodemo-door',
          'port': 53,
          'listen': '127.0.0.1',
          'settings': {
            'address': directDns,
            'port': 53,
            'network': 'udp',
          },
        },
      ],
      'outbounds': [
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {},
        },
        {
          'tag': 'pixiv-proxy',
          'protocol': 'http',
          'settings': {
            'servers': [
              {
                'address': '127.0.0.1',
                'port': proxyPort,
              }
            ],
          },
        },
        // DNS outbound uses direct
        {
          'tag': 'dns-out',
          'protocol': 'dns',
          'settings': {},
        },
      ],
      'routing': {
        'domainStrategy': 'IPOnDemand',
        'rules': [
          // Pixiv 域名 → HTTP 代理
          {
            'type': 'field',
            'domain': [
              'domain:pixiv.net',
              'domain:pximg.net',
              'domain:pixivision.net',
              'domain:pixivsketch.net',
            ],
            'outboundTag': 'pixiv-proxy',
          },
          // DNS 直通
          {
            'type': 'field',
            'inboundTag': ['dns-in'],
            'outboundTag': 'dns-out',
          },
          // 所有其他流量直连
          {
            'type': 'field',
            'network': 'udp',
            'outboundTag': 'direct',
          },
          {
            'type': 'field',
            'network': 'tcp',
            'outboundTag': 'direct',
          },
        ],
      },
      'dns': {
        'servers': [
          directDns,
          '8.8.8.8',
          'localhost',
        ],
        'queryStrategy': 'UseIPv4',
      },
    };

    return jsonEncode(config);
  }
}
