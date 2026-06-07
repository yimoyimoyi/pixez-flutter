import 'package:dio/dio.dart';
import 'package:pixez/network/network_mode.dart';

class PixivImageSource {
  static const String imageHost = 'i.pximg.net';
  static const String imageSHost = 's.pximg.net';

  /// 代理任意 Pixiv 域名 URL（登录、OAuth 等非图片请求）
  /// 当用户设置了自定义 pictureSource 时，将 Pixiv URL 改写为走代理
  static String resolvePixivUrl(
    String url, {
    required NetworkMode networkMode,
    required String? pictureSource,
  }) {
    try {
      final uri = Uri.parse(url);
      // 只有自定义图床 + 非标准模式才改写
      if (!networkMode.allowsImageSource) return url;
      final source = pictureSource?.trim();
      if (source == null || source.isEmpty || source == imageHost) return url;
      // 已经走代理的不再改写
      final sourceHost = Uri.parse(
        source.contains('://') ? source : 'https://$source',
      ).host;
      if (uri.host == sourceHost) return url;
      return _withSource(uri, source).toString();
    } catch (e) {
      return url;
    }
  }

  static String resolve(
    String url, {
    required NetworkMode networkMode,
    required String? pictureSource,
  }) {
    try {
      return resolveUri(
        Uri.parse(url),
        networkMode: networkMode,
        pictureSource: pictureSource,
      ).toString();
    } catch (e) {
      return url;
    }
  }

  static Uri resolveUri(
    Uri uri, {
    required NetworkMode networkMode,
    required String? pictureSource,
  }) {
    if (!networkMode.allowsImageSource) return uri;
    // 匹配所有 Pixiv 图片域名（i.pximg.net / s.pximg.net / *.pximg.net 等）
    if (!_isPixivImageHost(uri.host)) return uri;

    final source = pictureSource?.trim();
    if (source == null || source.isEmpty) return uri;
    if (source == imageHost) return uri;

    return _withSource(uri, source);
  }

  /// 判断是否为 Pixiv 图片域名（包括 pixivision CDN、各种 pximg 子域名）
  static bool _isPixivImageHost(String host) {
    // 官方图片 CDN
    if (host == imageHost || host == imageSHost) return true;
    // 所有 pximg 子域名（如 global.pximg.net, embed.pximg.net）
    if (host.endsWith('.pximg.net')) return true;
    // pixiv 子域名中的图片相关（排除 API/OAuth/账户域名）
    if (host.endsWith('.pixiv.net') &&
        host != 'app-api.pixiv.net' &&
        host != 'oauth.secure.pixiv.net' &&
        host != 'accounts.pixiv.net') return true;
    return false;
  }

  static Uri _withSource(Uri uri, String source) {
    final normalizedSource = source.startsWith('//')
        ? 'https:$source'
        : source.contains('://')
        ? source
        : 'https://$source';
    final sourceUri = Uri.parse(normalizedSource);
    if (sourceUri.host.isEmpty) return uri;

    return uri.replace(
      scheme: sourceUri.scheme.isEmpty ? uri.scheme : sourceUri.scheme,
      userInfo: sourceUri.userInfo,
      host: sourceUri.host,
      port: sourceUri.hasPort ? sourceUri.port : null,
      path: _joinPaths(sourceUri.path, uri.path),
    );
  }

  static String _joinPaths(String prefix, String suffix) {
    if (prefix.isEmpty || prefix == '/') return suffix;
    if (suffix.isEmpty || suffix == '/') return prefix;
    if (prefix.endsWith('/') && suffix.startsWith('/')) {
      return prefix + suffix.substring(1);
    }
    if (!prefix.endsWith('/') && !suffix.startsWith('/')) {
      return '$prefix/$suffix';
    }
    return '$prefix$suffix';
  }
}

class PixivImageSourceInterceptor extends Interceptor {
  final NetworkMode Function() networkMode;
  final String? Function() pictureSource;

  PixivImageSourceInterceptor({
    required this.networkMode,
    required this.pictureSource,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.path = PixivImageSource.resolveUri(
      options.uri,
      networkMode: networkMode(),
      pictureSource: pictureSource(),
    ).toString();
    options.baseUrl = '';
    options.queryParameters.clear();
    handler.next(options);
  }
}
