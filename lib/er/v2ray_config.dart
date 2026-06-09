/// V2Ray 配置生成器
///
/// flutter_v2ray 原生端会创建 TUN 接口。
/// Xray 仅需要 socks 入口 + 路由规则。
library;

import 'dart:convert';

class V2RayConfig {
  /// 生成 V2Ray JSON 配置字符串
  /// flutter_v2ray 原生端创建 TUN，Xray 只处理 socks 入口 + 路由
  static String generate({int proxyPort = 9876}) {
    final config = {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'socks-in',
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'port': 10808,
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls'],
          },
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
              'domain:pixivsketch.net',
            ],
            'outboundTag': 'pixiv-proxy',
          },
          {
            'type': 'field',
            'network': 'tcp',
            'outboundTag': 'direct',
          },
          {
            'type': 'field',
            'network': 'udp',
            'outboundTag': 'direct',
          },
        ],
      },
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8'],
        'queryStrategy': 'UseIPv4',
      },
    };
    return jsonEncode(config);
  }
}
