/// V2Ray 配置生成器
library;

import 'dart:convert';

class V2RayConfig {
  /// 生成 V2Ray 直通测试配置（所有流量直接，仅验证 TUN+DNS）
  static String testDirect() {
    return jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'socks-in',
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'port': 10808,
          'settings': {'udp': true},
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
        },
      ],
      'outbounds': [
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {},
        },
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          {'type': 'field', 'network': 'tcp', 'outboundTag': 'direct'},
          {'type': 'field', 'network': 'udp', 'outboundTag': 'direct'},
        ],
      },
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8'],
        'queryStrategy': 'UseIPv4',
      },
    });
  }

  /// 正式配置
  static String generate({int proxyPort = 9876}) {
    return jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'socks-in',
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'port': 10808,
          'settings': {'udp': true},
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
        },
      ],
      'outbounds': [
        {
          'tag': 'pixiv-proxy',
          'protocol': 'http',
          'settings': {
            'servers': [
              {'address': '127.0.0.1', 'port': proxyPort},
            ],
          },
        },
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {},
        },
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'domain': [
              'domain:pixiv.net',
              'domain:pximg.net',
              'domain:pixivision.net',
            ],
            'outboundTag': 'pixiv-proxy',
          },
          {'type': 'field', 'network': 'tcp', 'outboundTag': 'direct'},
          {'type': 'field', 'network': 'udp', 'outboundTag': 'direct'},
        ],
      },
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8'],
        'queryStrategy': 'UseIPv4',
      },
    });
  }
}
