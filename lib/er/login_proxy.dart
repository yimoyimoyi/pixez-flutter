/// Pixiv 登录本地反向代理
///
/// WebView (HTTP) → 本地代理 → rhttp compat (HTTPS) → Pixiv 源站 IP
///
/// 为什么需要：
/// - Cloudflare Workers 出口 IP 被 Pixiv 封锁（403 Forbidden）
/// - compat 模式直连可以绕过，但 WebView TLS 栈不支持 sni:false
/// - 本代理在本地做 HTTP↔HTTPS 桥接，TLS 由 rhttp compat 处理
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

class LoginProxy {
  static HttpServer? _server;
  static Dio? _dio;

  static int get port => 9876;

  static Future<void> start() async {
    if (_server != null) return;

    final client = await r.RhttpCompatibleClient.createSync(
      settings: PixezNetworkSettings.compatible(),
    );
    _dio = Dio();
    _dio!.httpClientAdapter = ConversionLayerAdapter(client);
    _dio!.options.followRedirects = false;
    _dio!.options.validateStatus = (_) => true;

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    LPrinter.d("LoginProxy started on 127.0.0.1:$port");
    _server!.listen(_handleRequest);
  }

  static Future<void> stop() async {
    await _server?.close();
    _server = null;
    _dio?.close();
    _dio = null;
    LPrinter.d("LoginProxy stopped");
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    try {
      final targetHost = _resolveTargetHost(request);
      if (targetHost == null) {
        request.response.statusCode = 400;
        request.response.write("Bad Request");
        await request.response.close();
        return;
      }

      final targetUrl = _buildTargetUrl(targetHost, request.uri);

      LPrinter.d("Proxy: ${request.method} $targetUrl");

      // 构造请求头
      final headers = <String, dynamic>{
        'accept-language': 'zh-cn',
        'user-agent': 'PixivAndroidApp/5.0.166 (Android 10.0; Pixel C)',
      };
      request.headers.forEach((name, values) {
        if (name.toLowerCase() != 'host' &&
            name.toLowerCase() != 'content-length') {
          headers[name] = values.join(', ');
        }
      });

      // 读取请求体
      List<int>? body;
      if (request.method != 'GET' && request.method != 'HEAD') {
        body = await request.fold<List<int>>(<int>[], (prev, chunk) {
          prev.addAll(chunk);
          return prev;
        });
      }

      // 通过 rhttp compat 转发请求
      final response = await _dio!.requestUri(
        targetUrl,
        data: body,
        options: Options(
          method: request.method,
          responseType: ResponseType.bytes,
        )..headers!.addAll(headers),
      );

      final statusCode = response.statusCode ?? 502;
      request.response.statusCode = statusCode;

      // 复制响应头
      final respHeaders = response.headers.map;
      respHeaders.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower != 'content-encoding' &&
            lower != 'transfer-encoding' &&
            lower != 'content-length') {
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        }
      });

      // HTML 响应需要改写 URL
      final contentType = respHeaders['content-type']?.firstOrNull ?? '';
      final isHtml =
          contentType.contains('text/html') || contentType.contains('application/xhtml');

      if (isHtml && response.data != null) {
        String html = utf8.decode(response.data as List<int>);
        html = _rewriteHtml(html);
        request.response.headers.set('content-type', 'text/html; charset=utf-8');
        request.response.write(html);
      } else if (response.data != null) {
        request.response.add(response.data as List<int>);
      }

      await request.response.close();
    } catch (e, stack) {
      LPrinter.d("Proxy error: $e\n$stack");
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 从请求中解析目标 Pixiv 主机
  static String? _resolveTargetHost(HttpRequest request) {
    // 自定义 header
    final pixivHost = request.headers['x-pixiv-host']?.firstOrNull;
    if (pixivHost != null && pixivHost.endsWith('.pixiv.net')) {
      return pixivHost;
    }
    // 查询参数 __host
    final hostParam = request.uri.queryParameters['__host'];
    if (hostParam != null && hostParam.endsWith('.pixiv.net')) {
      return hostParam;
    }
    // 根据路径模式推断
    final path = request.uri.path;
    if (path.contains('accounts.pixiv.net')) return 'accounts.pixiv.net';
    if (path.contains('oauth.secure.pixiv.net')) return 'oauth.secure.pixiv.net';

    // 默认：登录入口
    return 'app-api.pixiv.net';
  }

  /// 改写 HTML 中 Pixiv URL，确保后续请求也走本代理
  static String _rewriteHtml(String html) {
    // 匹配 https://<host>.pixiv.net/something
    return html.replaceAllMapped(
      RegExp(r"https://([a-z0-9.-]+\.pixiv\.net)(\S*)", caseSensitive: false),
      (match) {
        final host = match.group(1)!;
        final rest = match.group(2) ?? '';
        return 'http://127.0.0.1:$port/__host=$host$rest';
      },
    );
  }

  /// 构造代理目标 URL（保留原始 query string）
  static Uri _buildTargetUrl(String host, Uri original) {
    final path = original.path;
    if (original.hasQuery) {
      return Uri.https(host, path, Uri.splitQueryString(original.query));
    }
    return Uri.https(host, path);
  }

  /// 构造供 WebView 加载的代理 URL
  static String proxyUrl(String originalUrl) {
    final uri = Uri.parse(originalUrl);
    final host = uri.host;
    final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    return 'http://127.0.0.1:$port/__host=$host$path';
  }
}
