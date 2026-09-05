/*
 * 翻译引擎专用 HTTP 客户端工厂。
 * 翻译服务多为国外/指定地址，用户网络常需代理(如 Clash)：
 *  - 优先读环境变量 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY
 *  - Windows 下读系统代理(注册表 Internet Settings)
 *  - 都没有则直连
 */

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

String? _cachedProxy;

/// 解析当前应使用的 HTTP 代理（无则 null=直连）
Future<String?> resolveSystemProxy() async {
  if (_cachedProxy != null) return _cachedProxy;
  String? proxy = _proxyFromEnv();
  if (proxy == null && Platform.isWindows) {
    proxy = await _proxyFromRegistry();
  }
  _cachedProxy = proxy;
  return proxy;
}

String? _proxyFromEnv() {
  for (final name in ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy']) {
    final value = Platform.environment[name];
    if (value != null && value.trim().isNotEmpty) {
      final uri = Uri.tryParse(value.trim());
      final host = uri != null && uri.host.isNotEmpty
          ? '${uri.host}:${(uri.port != 0 ? uri.port : 80)}'
          : value.trim();
      return host;
    }
  }
  return null;
}

Future<String?> _proxyFromRegistry() async {
  try {
    final result = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      '/v',
      'ProxyEnable',
    ]);
    if (result.exitCode == 0 && result.stdout.toString().contains('0x1')) {
      final result2 = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'ProxyServer',
      ]);
      if (result2.exitCode == 0) {
        final lines = (result2.stdout as String).split('\n');
        for (final line in lines) {
          final match =
              RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch(line);
          if (match != null) return match.group(1);
        }
      }
    }
  } catch (_) {
    // 注册表读取失败忽略，回到直连
  }
  return null;
}

/// 创建翻译引擎专用 Dio（独立域名，不挂 Pixiv Hoster）
Future<Dio> createEngineDio({
  Duration? connectTimeout,
  Duration? receiveTimeout,
}) async {
  final proxy = await resolveSystemProxy();
  final adapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      if (proxy != null && proxy.isNotEmpty) {
        // 非 loopback 直连目标时走代理；本地服务(Ollama)与代理自身保持直连
        client.findProxy = (uri) {
          final host = uri.host;
          if (host == 'localhost' ||
              host == '127.0.0.1' ||
              host == '0.0.0.0') {
            return 'DIRECT';
          }
          return 'PROXY $proxy';
        };
      }
      return client;
    },
  );
  final dio = Dio(BaseOptions(
    connectTimeout: connectTimeout ?? Duration(seconds: 10),
    receiveTimeout: receiveTimeout ?? Duration(seconds: 30),
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}
