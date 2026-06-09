/// Pixiv 登录本地反向代理
///
/// 参考 Workers proxyApi 的 redirect:'manual' + rewriteLocation 模式。
/// 关键差异：使用路径前缀编码目标主机，而非查询参数。
///
/// URL 格式: http://127.0.0.1:9876/{pixiv-host}/{path}?{query}
/// 示例: http://127.0.0.1:9876/app-api.pixiv.net/web/v1/login?code_challenge=...
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/login_cert.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

class LoginProxy {
  static HttpServer? _server;
  static Dio? _dio;

  static int get port => 9876;
  static int get httpsPort => 8443;

  /// HTTP 代理（回退用，reCAPTCHA 不可用）
  static Future<void> start() async {
    if (_server != null) return;

    final client = await r.RhttpCompatibleClient.createSync(
      settings: PixezNetworkSettings.compatible(),
    );
    _dio = Dio();
    _dio!.httpClientAdapter = ConversionLayerAdapter(client);
    _dio!.options.followRedirects = false;
    _dio!.options.maxRedirects = 999;
    _dio!.options.validateStatus = (_) => true;

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    LPrinter.d("LoginProxy HTTP started on 127.0.0.1:$port");
    _server!.listen(_handleRequest);
  }

  /// HTTPS 代理（VpnService DNS 劫持模式，reCAPTCHA 可用）
  static Future<void> startHttps() async {
    // 如果已有 HTTP 服务器在运行，先停止
    if (_server != null) {
      await stop();
    }

    final client = await r.RhttpCompatibleClient.createSync(
      settings: PixezNetworkSettings.compatible(),
    );
    _dio = Dio();
    _dio!.httpClientAdapter = ConversionLayerAdapter(client);
    _dio!.options.followRedirects = false;
    _dio!.options.maxRedirects = 999;
    _dio!.options.validateStatus = (_) => true;

    final ctx = LoginCert.createContext();
    _server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      httpsPort,
      ctx,
    );
    LPrinter.d("LoginProxy HTTPS started on 127.0.0.1:$httpsPort");
    _server!.listen(_handleRequest);
  }

  static Future<void> stop() async {
    await _server?.close();
    _server = null;
    _dio?.close();
    _dio = null;
    LPrinter.d("LoginProxy stopped");
  }

  /// 处理 V2Ray HTTP outbound 的 CONNECT 请求
  /// 格式: CONNECT app-api.pixiv.net:443 HTTP/1.1
  static Future<void> _handleConnect(HttpRequest request) async {
    final target = request.uri.toString(); // "app-api.pixiv.net:443"
    final idx = target.lastIndexOf(':');
    if (idx <= 0 || idx >= target.length - 1) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final host = target.substring(0, idx);
    final port = int.parse(target.substring(idx + 1));
    LPrinter.d("CONNECT $host:$port");

    try {
      // 发送 200 Connection Established
      request.response.statusCode = 200;
      request.response.headers.set('connection', 'keep-alive');
      await request.response.flush();

      // 获取底层 raw TCP socket
      final clientSocket = await request.response.detachSocket();

      // 连接到上游: pixiv 域名用源站 IP，非 pixiv 直接连
      Socket upstreamSocket;
      if (host.endsWith('.pixiv.net') || host == 'pixiv.net') {
        final ips = Hoster.apiPool();
        upstreamSocket = await Socket.connect(ips.first, port,
            timeout: Duration(seconds: 15));
      } else {
        upstreamSocket = await Socket.connect(host, port,
            timeout: Duration(seconds: 10));
      }

      // 双向字节中继
      await Future.wait([
        _relaySocket(clientSocket, upstreamSocket),
        _relaySocket(upstreamSocket, clientSocket),
      ]);
    } catch (e) {
      LPrinter.d("CONNECT error: $e");
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 单向 Socket → Socket 字节中继
  static Future<void> _relaySocket(Socket from, Socket to) async {
    final completer = Completer<void>();
    from.listen(
      (data) {
        to.add(data);
        to.flush();
      },
      onDone: () {
        to.close();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_) {
        to.close();
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: false,
    );
    return completer.future;
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    try {
      // V2Ray HTTP outbound CONNECT 模式
      if (request.method == 'CONNECT') {
        await _handleConnect(request);
        return;
      }

      final parsed = _parse(request);
      if (parsed == null) {
        request.response.statusCode = 400;
        request.response.write("Bad Request: cannot parse target host");
        await request.response.close();
        return;
      }
      final (targetHost, remainingPath, query) = parsed;

      final targetUrl = Uri.https(targetHost, remainingPath, query.isNotEmpty ? Uri.splitQueryString(query) : null);
      LPrinter.d("Proxy: ${request.method} $targetUrl");

      // 构造上游请求头
      final headers = <String, dynamic>{
        'host': targetHost,
        'accept-language': 'zh-cn',
        'user-agent': 'PixivAndroidApp/5.0.166 (Android 10.0; Pixel C)',
        'referer': 'https://app-api.pixiv.net/',
      };
      request.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower != 'host' && lower != 'content-length' && lower != 'referer') {
          headers[name] = values.join(', ');
        }
      });

      List<int>? body;
      if (request.method != 'GET' && request.method != 'HEAD') {
        body = await request.fold<List<int>>(<int>[], (prev, chunk) {
          prev.addAll(chunk);
          return prev;
        });
      }

      final response = await _dio!.requestUri(
        targetUrl,
        data: body,
        options: Options(
          method: request.method,
          responseType: ResponseType.bytes,
          headers: headers,
        ),
      );

      final statusCode = response.statusCode ?? 502;
      request.response.statusCode = statusCode;

      final respHeaders = response.headers.map;
      respHeaders.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == 'content-encoding' || lower == 'transfer-encoding') return;

        if (lower == 'location') {
          for (final v in values) {
            request.response.headers.add(name, _rewriteLocation(v));
          }
          return;
        }

        if (lower == 'set-cookie') {
          for (final v in values) {
            request.response.headers.add(name, _rewriteCookie(v));
          }
          return;
        }

        for (final v in values) {
          request.response.headers.add(name, v);
        }
      });

      final contentType = respHeaders['content-type']?.firstOrNull ?? '';
      final isRewritable = contentType.contains('text/html') ||
          contentType.contains('application/xhtml') ||
          contentType.contains('text/css') ||
          contentType.contains('application/javascript') ||
          contentType.contains('text/javascript');

      if (isRewritable && response.data != null) {
        String body = utf8.decode(response.data as List<int>);
        body = body.replaceAllMapped(
          RegExp(r'https://([a-z0-9.-]+\.pixiv\.net)(\S*)', caseSensitive: false),
          (m) => 'http://127.0.0.1:$port/${m.group(1)}${m.group(2)}',
        );
        request.response.headers.set('content-type', contentType);
        request.response.write(body);
      } else if (response.data != null) {
        request.response.add(response.data as List<int>);
      }

      await request.response.close();
    } catch (e, stack) {
      LPrinter.d("Proxy error: $e\n$stack");
      try {
        request.response
          ..statusCode = 502
          ..headers.set('content-type', 'text/plain; charset=utf-8')
          ..write('Proxy Error: $e');
        await request.response.close();
      } catch (_) {
        try { await request.response.close(); } catch (_) {}
      }
    }
  }

  // ============ URL/Header 改写 ============

  /// 改写 Location 头（参考 Workers rewriteLocation）
  /// https://accounts.pixiv.net/login → http://127.0.0.1:9876/accounts.pixiv.net/login
  static String _rewriteLocation(String url) {
    for (final host in _pixivHosts) {
      final prefix = 'https://$host';
      if (url.startsWith(prefix)) {
        return url.replaceFirst(prefix, 'http://127.0.0.1:$port/$host');
      }
    }
    return url;
  }

  /// 改写 Set-Cookie domain（确保 cookie 在代理域名下也能发送）
  static String _rewriteCookie(String cookie) {
    return cookie
        .replaceAll(RegExp(r'[Dd]omain=\s*\.?pixiv\.net'), 'Domain=127.0.0.1')
        .replaceAll(RegExp(r'[Dd]omain=\s*\.?pximg\.net'), 'Domain=127.0.0.1');
  }

  static const _pixivHosts = [
    'app-api.pixiv.net',
    'accounts.pixiv.net',
    'oauth.secure.pixiv.net',
    'www.pixiv.net',
    'pixiv.net',
    'i.pximg.net',
    's.pximg.net',
  ];

  // ============ 请求解析 ============

  /// 解析代理 URL，提取 (目标主机, 剩余路径, 查询字符串)
  /// URL 格式: http://127.0.0.1:9876/{pixiv-host}/{path}?{query}
  static (String, String, String)? _parse(HttpRequest request) {
    final segments = request.uri.pathSegments;
    if (segments.isEmpty) return null;

    final first = segments.first;
    if (!first.endsWith('.pixiv.net')) return null;

    final remainingPath = segments.length > 1
        ? '/${segments.skip(1).join('/')}'
        : '/';
    final query = request.uri.hasQuery ? request.uri.query : '';
    return (first, remainingPath, query);
  }

  /// 构造供 WebView 加载的代理 URL
  static String proxyUrl(String originalUrl) {
    final uri = Uri.parse(originalUrl);
    final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    return 'http://127.0.0.1:$port/${uri.host}$path';
  }
}
