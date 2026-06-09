/// V2Ray 配置生成器
///
/// flutter_v2ray 创建 VpnService TUN 接口。
/// Xray 配置必须有 tun inbound 才能从 TUN 读取流量进行路由。
library;

import 'dart:convert';

class V2RayConfig {
  static String generate({int proxyPort = 9876}) {
    return jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'tun-in',
          'protocol': 'tun',
          'settings': {
            'dev': 'tun@',
            'mtu': 1500,
          },
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
        'domainStrategy': 'AsIs',
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
        'hosts': {
          'domain:pixiv.net': '210.140.139.154',
          'domain:pximg.net': '210.140.139.131',
          'www.pixivision.net': '210.140.139.154',
        },
        'servers': ['localhost', '223.5.5.5'],
        'queryStrategy': 'UseIPv4',
        'disableFallback': false,
      },
    });
  }
}
